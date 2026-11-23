#!/usr/bin/env bash
# Creates the JFrog Project (+ a new project-admin user), Artifactory repositories,
# the GitHub Actions OIDC integration and the AppTrust application for the sample app.
# Idempotent: anything that already exists is skipped.
#
# Requires: jf (JFrog CLI with `jf apptrust`), jq, openssl, and a CLI server logged in with
# `jf login` (web login) as a platform admin. Every setting comes from the root .env.
# No tokens are used or needed.
#
#   ./setup.sh               # create everything
#   DRY_RUN=1 ./setup.sh     # print what would happen, change nothing
#   NO_COLOR=1 ./setup.sh    # plain output
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then GITHUB_REPOSITORY="owner/repo"
  else die "GITHUB_REPOSITORY is not set" "Set GITHUB_REPOSITORY=owner/repo in the root .env: the only repo allowed to use OIDC"; fi
fi
GITHUB_ORG="${GITHUB_ORG:-${GITHUB_REPOSITORY%%/*}}"   # JFrog needs the (case-sensitive) org for the GitHub OIDC provider
BUILD_NAME="${BUILD_NAME:-${GITHUB_REPOSITORY#*/}}"     # the build name CI publishes (ci.yml: the repository name)
BUILD_INFO_REPO="$PROJECT_KEY-build-info"               # build repository JFrog creates with the project

# ---- Builders -----------------------------------------------------------------
local_repo() { # <key> <packageType> <environment> [description]
  jq -n --arg key "$1" --arg pt "$2" --arg env "$3" --arg desc "${4:-}" --arg proj "$PROJECT_KEY" '
    {key:$key, rclass:"local", packageType:$pt, projectKey:$proj, xrayIndex:true,
     description:(if $desc != "" then $desc else "Sample app \($pt) (\($env))" end),
     environments:(if $env == "" then [] else [$env] end)}
    + (if $pt == "docker" then {dockerApiVersion:"V2"} else {} end)'
}

remote_repo() { # <key> <packageType> <url>
  jq -n --arg key "$1" --arg pt "$2" --arg url "$3" --arg proj "$PROJECT_KEY" '
    {key:$key, rclass:"remote", packageType:$pt, url:$url, projectKey:$proj,
     xrayIndex:true, description:"Proxy of \($url)"}
    + (if $pt == "maven" then {handleReleases:true, handleSnapshots:false, curated:true} else {} end)
    + (if $pt == "docker" then {enableTokenAuthentication:true, externalDependenciesEnabled:false} else {} end)'
}

virtual_repo() { # <key> <packageType> <defaultDeploymentRepo> <member>...
  local key="$1" pt="$2" deploy="$3"; shift 3
  printf '%s\n' "$@" | jq -R . | jq -s --arg key "$key" --arg pt "$pt" --arg deploy "$deploy" --arg proj "$PROJECT_KEY" '
    {key:$key, rclass:"virtual", packageType:$pt, projectKey:$proj, xrayIndex:true,
     repositories:., defaultDeploymentRepo:$deploy,
     description:"Resolve and deploy \($pt) through one URL"}'
}

# ---- Ensure steps -------------------------------------------------------------
ensure_project() {
  if exists "/access/api/v1/projects/$PROJECT_KEY"; then status exists project "$PROJECT_KEY" "$PROJECT_NAME"; return; fi
  apply create project "$PROJECT_KEY" "$PROJECT_NAME" POST /access/api/v1/projects "$(jq -n \
    --arg key "$PROJECT_KEY" --arg name "$PROJECT_NAME" \
    '{project_key:$key, display_name:$name, description:"Sample Java/Maven app",
      admin_privileges:{manage_members:true, manage_resources:true, index_resources:true}}')"
}

# New (non-platform-admin) user who becomes Project Admin of the project.
ensure_project_admin() {
  if exists "/access/api/v2/users/$PROJECT_ADMIN_USER"; then
    status exists user "$PROJECT_ADMIN_USER" "$PROJECT_ADMIN_EMAIL"
  else
    if [[ -z "$PROJECT_ADMIN_PASSWORD" ]]; then
      PROJECT_ADMIN_PASSWORD="Aa1!$(openssl rand -hex 12)"
      GENERATED_PASSWORD=1
    fi
    apply create user "$PROJECT_ADMIN_USER" "$PROJECT_ADMIN_EMAIL, not a platform admin" POST /access/api/v2/users "$(jq -n \
      --arg u "$PROJECT_ADMIN_USER" --arg e "$PROJECT_ADMIN_EMAIL" --arg p "$PROJECT_ADMIN_PASSWORD" \
      '{username:$u, email:$e, password:$p, admin:false, profile_updatable:true}')"
  fi
  apply assign member "$PROJECT_ADMIN_USER" "Project Admin on $PROJECT_KEY" \
    PUT "/access/api/v1/projects/$PROJECT_KEY/users/$PROJECT_ADMIN_USER" \
    "$(jq -n --arg u "$PROJECT_ADMIN_USER" '{name:$u, roles:["Project Admin"]}')"
}

# repo_flag_patch <desired json> <current json>
# The create body carries xrayIndex, and curated for the Maven remote. Returns the
# partial update (or {}) still needed on a repository that already exists.
# Artifactory does not return xrayIndex for virtual repos (it is only sent on create), so a missing
# key is not treated as "off".
repo_flag_patch() {
  jq -c -n --argjson want "$1" --argjson have "$2" '
    (if ($want.xrayIndex == true and ($have | has("xrayIndex")) and $have.xrayIndex != true) then {xrayIndex: true} else {} end)
    + (if ($want.curated == true and $have.curated != true) then {curated: true} else {} end)'
}

ensure_repo() { # <key> <json> <detail>
  local key="$1" json="$2" detail="$3" current patch
  if [[ "$DRY_RUN" == 1 ]]; then
    if exists "/artifactory/api/repositories/$key"; then status exists repo "$key" "$detail"; return; fi
    apply create repo "$key" "$detail" PUT "/artifactory/api/repositories/$key" "$json"
    return
  fi
  if ! jf api --server-id "$SID" "/artifactory/api/repositories/$key" >"$TMP/repo.json" 2>"$TMP/err"; then
    apply create repo "$key" "$detail" PUT "/artifactory/api/repositories/$key" "$json"
    return
  fi
  current="$(cat "$TMP/repo.json")"
  patch="$(repo_flag_patch "$json" "$current")"
  if [[ "$patch" == "{}" ]]; then status exists repo "$key" "$detail"; return; fi
  # POST updates; PUT creates. The body is only the flags that are still off.
  apply update repo "$key" "$detail" POST "/artifactory/api/repositories/$key" "$patch"
}

# Xray build indexing for the project's build repository (<project>-build-info). Xray scans the builds
# CI publishes there once they are indexed. Indexing is selected by a build name pattern, so it can be
# configured before the first build exists. The API cannot read patterns back: a build that is already
# in the indexed list counts as "exists"; otherwise the (idempotent) pattern update is sent.
ensure_build_indexing() {
  local detail="$BUILD_INFO_REPO $DOT pattern $BUILD_INDEX_PATTERN $DOT project $PROJECT_KEY"
  local path="/xray/api/v1/binMgr/default/builds?projectKey=$PROJECT_KEY" body
  body="$(jq -n --arg p "$BUILD_INDEX_PATTERN" '{patterns:{include_patterns:[$p], exclude_patterns:[]}}')"
  if [[ "$DRY_RUN" != 1 ]] && jf api --server-id "$SID" "$path" >"$TMP/builds.json" 2>/dev/null \
     && jq -e --arg n "$BUILD_NAME" '(.indexed_builds // []) | index($n) != null' "$TMP/builds.json" >/dev/null; then
    status exists xray-builds "$BUILD_INFO_REPO" "build $BUILD_NAME is indexed"
    return
  fi
  apply update xray-builds "$BUILD_INFO_REPO" "$detail" PUT "$path" "$body"
}

# Local Maven config for `jf mvn`: resolve and deploy, releases and snapshots, through the Maven virtual.
# Written to <repo root>/.jfrog/projects/maven.yaml. It names your CLI server id, so it is machine-specific.
ensure_maven_config() {
  local file="$REPO_ROOT/.jfrog/projects/maven.yaml" detail="resolve + deploy via $MAVEN_VIRTUAL"
  local -a args=(--server-id-resolve="$SID" --server-id-deploy="$SID"
    --repo-resolve-releases="$MAVEN_VIRTUAL" --repo-resolve-snapshots="$MAVEN_VIRTUAL"
    --repo-deploy-releases="$MAVEN_VIRTUAL" --repo-deploy-snapshots="$MAVEN_VIRTUAL")
  if [[ "$DRY_RUN" == 1 ]]; then
    status create maven-config ".jfrog/projects/maven.yaml" "$detail"
    show_request "jf mvn-config ${args[*]}"
    return
  fi
  # Generate in a scratch dir, then compare: an identical file on disk counts as "exists".
  local gen="$TMP/mvn-config"
  mkdir -p "$gen"
  if ! (cd "$gen" && jf mvn-config "${args[@]}" >"$TMP/out" 2>&1); then
    fail "jf mvn-config failed"
    printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/out" >&2; printf '%s\n' "$E_RESET" >&2
    exit 1
  fi
  if [[ -f "$file" ]] && cmp -s "$gen/.jfrog/projects/maven.yaml" "$file"; then
    status exists maven-config ".jfrog/projects/maven.yaml" "$detail"; return
  fi
  local replaces=""; [[ -f "$file" ]] && replaces=" (replaces the previous file)"
  mkdir -p "$(dirname "$file")"
  cp "$gen/.jfrog/projects/maven.yaml" "$file"
  status create maven-config ".jfrog/projects/maven.yaml" "$detail$replaces"
}

# role_scope <project> <comma-separated roles>
# "Developer,Release Manager" -> applied-permissions/roles:<project>:"Developer","Release Manager"
role_scope() {
  local project="$1" role out=""
  local -a list
  IFS=',' read -r -a list <<<"$2"
  for role in "${list[@]}"; do
    role="${role#"${role%%[![:space:]]*}"}"; role="${role%"${role##*[![:space:]]}"}"
    [[ -n "$role" ]] || continue
    out+="${out:+,}\"$role\""
  done
  printf '%s' "applied-permissions/roles:$project:$out"
}

# GitHub Actions OIDC: provider + one identity mapping limited to this repository.
# Workflows exchange their GitHub token for a short-lived, project-scoped JFrog token.
ensure_oidc() {
  local scope
  scope="$(role_scope "$PROJECT_KEY" "$CI_PROJECT_ROLES")"
  local pdetail="provider $DOT GitHub org $GITHUB_ORG $DOT audience $OIDC_AUDIENCE"
  local mdetail="mapping $DOT $GITHUB_REPOSITORY -> $CI_PROJECT_ROLES on $PROJECT_KEY"
  if exists "/access/api/v1/oidc/$OIDC_PROVIDER_NAME"; then
    status exists oidc "$OIDC_PROVIDER_NAME" "$pdetail"
  else
    apply create oidc "$OIDC_PROVIDER_NAME" "$pdetail" POST /access/api/v1/oidc "$(jq -n \
      --arg n "$OIDC_PROVIDER_NAME" --arg iss "$OIDC_ISSUER_URL" --arg aud "$OIDC_AUDIENCE" --arg org "$GITHUB_ORG" \
      '{name:$n, description:"GitHub Actions", issuer_url:$iss, provider_type:"GitHub", audience:$aud, organization:$org}')"
  fi
  if exists "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings/$OIDC_MAPPING_NAME"; then
    status exists oidc "$OIDC_MAPPING_NAME" "$mdetail"
  else
    apply create oidc "$OIDC_MAPPING_NAME" "$mdetail" POST "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings" "$(jq -n \
      --arg n "$OIDC_MAPPING_NAME" --arg repo "$GITHUB_REPOSITORY" --arg user "$CI_TOKEN_USERNAME" \
      --arg scope "$scope" --argjson ttl "$CI_TOKEN_TTL_SECONDS" \
      '{name:$n, description:"CI for \($repo)", priority:1,
        claims:{repository:$repo},
        token_spec:{username:$user, scope:$scope, audience:"*@*", expires_in:$ttl}}')"
  fi
}

ensure_app() {
  local detail="$APP_NAME $DOT project $PROJECT_KEY"
  if exists "/apptrust/api/v1/applications/$APP_KEY"; then status exists app "$APP_KEY" "$detail"; return; fi
  if [[ "$DRY_RUN" == 1 ]]; then
    status create app "$APP_KEY" "$detail"
    show_request "jf apptrust app-create $APP_KEY --project=$PROJECT_KEY"
    return
  fi
  if ! jf apptrust app-create "$APP_KEY" --server-id "$SID" --project="$PROJECT_KEY" \
        --application-name="$APP_NAME" --desc="$APP_DESCRIPTION" \
        --business-criticality="$APP_CRITICALITY" --maturity-level="$APP_MATURITY" \
        >"$TMP/out" 2>&1; then
    if grep -qiE 'already exists|conflict|409' "$TMP/out"; then status exists app "$APP_KEY" "$detail"; return
    else
      fail "jf apptrust app-create failed"
      printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/out" >&2; printf '%s\n' "$E_RESET" >&2
      exit 1
    fi
  fi
  status create app "$APP_KEY" "$detail"
}

# GitHub repository VARIABLES the workflow reads, set with the gh CLI. There are no secrets:
# the workflow authenticates with OIDC. A variable that already has the right value is left alone.
ensure_github_vars() {
  local pair name value json current count act
  if [[ "$DRY_RUN" == 1 ]]; then
    json='[]'
  else
    command -v gh >/dev/null || die "gh (GitHub CLI) is required" "Install it: brew install gh, then: gh auth login"
    gh auth status >/dev/null 2>&1 || die "gh is not logged in" "Run: gh auth login (needs admin on $GITHUB_REPOSITORY)"
    if ! json="$(gh variable list -R "$GITHUB_REPOSITORY" --json name,value 2>"$TMP/err")"; then
      fail "Could not list variables for $GITHUB_REPOSITORY"
      printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/err" >&2; printf '%s\n' "$E_RESET" >&2
      hint "Check that you have admin rights on $GITHUB_REPOSITORY"
      exit 1
    fi
  fi
  for pair in \
    "JF_URL=$JFROG_URL" \
    "JF_PROJECT_KEY=$PROJECT_KEY" \
    "JF_OIDC_PROVIDER=$OIDC_PROVIDER_NAME" \
    "JF_OIDC_AUDIENCE=$OIDC_AUDIENCE"
  do
    name="${pair%%=*}"; value="${pair#*=}"
    count="$(jq --arg n "$name" '[.[] | select(.name == $n)] | length' <<<"$json")"
    current="$(jq -r --arg n "$name" '[.[] | select(.name == $n)][0].value // empty' <<<"$json")"
    if [[ "$count" == 0 ]]; then act=create
    elif [[ "$current" == "$value" ]]; then status exists variable "$name" "$value"; continue
    else act=update; fi

    if [[ "$DRY_RUN" == 1 ]]; then
      status "$act" variable "$name" "$value"
      show_request "gh variable set $name --body $value -R $GITHUB_REPOSITORY"
      continue
    fi
    if ! gh variable set "$name" --body "$value" -R "$GITHUB_REPOSITORY" >"$TMP/out" 2>"$TMP/err"; then
      fail "gh variable set $name failed"
      printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/err" "$TMP/out" >&2; printf '%s\n' "$E_RESET" >&2
      exit 1
    fi
    status "$act" variable "$name" "$value"
  done
}

# ==== Run ========================================================================
GENERATED_PASSWORD=0

banner "JFrog demo setup" "project, admin user, repositories, GitHub OIDC, AppTrust application"
echo
kv "Server" "$SID ($JFROG_FQDN)"
kv "Project" "$PROJECT_KEY ($PROJECT_NAME)"
kv "Application" "$APP_KEY ($APP_NAME)"
kv "GitHub repo" "$GITHUB_REPOSITORY (org: $GITHUB_ORG)"
if [[ "$DRY_RUN" == 1 ]]; then kv "Mode" "${YELLOW}DRY RUN: nothing will be changed${RESET}"
else kv "Mode" "live"; fi

section "Build tools"
ensure_build_tools

section "Project and access"
ensure_project
ensure_project_admin

# Locals first, then remotes, then the virtuals that aggregate them.
section "Repositories"
envd() { printf '%s' "${1:-no environment}"; }
ensure_repo "$MAVEN_DEV"     "$(local_repo "$MAVEN_DEV"   maven  "$DEV_ENVIRONMENT")"  "local maven $DOT env $(envd "$DEV_ENVIRONMENT") $DOT Xray"
ensure_repo "$MAVEN_PROD"    "$(local_repo "$MAVEN_PROD"  maven  "$PROD_ENVIRONMENT")" "local maven $DOT env $(envd "$PROD_ENVIRONMENT") $DOT Xray"
# Patch repo for JFrog ZTR: no environment (not part of promotion), holds patched libraries.
ensure_repo "$MAVEN_PATCH"   "$(local_repo "$MAVEN_PATCH" maven  "" "Local patch repo for JFrog ZTR")" "local maven $DOT JFrog ZTR patches, resolved first $DOT Xray"
ensure_repo "$DOCKER_DEV"    "$(local_repo "$DOCKER_DEV"  docker "$DEV_ENVIRONMENT")"  "local docker $DOT env $(envd "$DEV_ENVIRONMENT") $DOT Xray"
ensure_repo "$DOCKER_PROD"   "$(local_repo "$DOCKER_PROD" docker "$PROD_ENVIRONMENT")" "local docker $DOT env $(envd "$PROD_ENVIRONMENT") $DOT Xray"
ensure_repo "$MAVEN_REMOTE"  "$(remote_repo "$MAVEN_REMOTE"  maven  "$MAVEN_UPSTREAM_URL")"  "remote maven $DOT $MAVEN_UPSTREAM_URL $DOT Xray, Curation"
ensure_repo "$DOCKER_REMOTE" "$(remote_repo "$DOCKER_REMOTE" docker "$DOCKER_UPSTREAM_URL")" "remote docker $DOT $DOCKER_UPSTREAM_URL $DOT Xray"
ensure_repo "$MAVEN_VIRTUAL"  "$(virtual_repo "$MAVEN_VIRTUAL"  maven  "$MAVEN_DEV"  "$MAVEN_PATCH" "$MAVEN_DEV"  "$MAVEN_PROD"  "$MAVEN_REMOTE")" "virtual maven $DOT patch, dev, prod, remote $DOT Xray"
ensure_repo "$DOCKER_VIRTUAL" "$(virtual_repo "$DOCKER_VIRTUAL" docker "$DOCKER_DEV" "$DOCKER_DEV" "$DOCKER_PROD" "$DOCKER_REMOTE")" "virtual docker $DOT dev, prod, remote $DOT Xray"

section "Xray build indexing"
ensure_build_indexing

section "Maven project config"
ensure_maven_config

section "GitHub OIDC"
ensure_oidc

section "AppTrust"
ensure_app

section "GitHub repository variables"
ensure_github_vars

# ==== Summary ====================================================================
if [[ "$DRY_RUN" == 1 ]]; then
  caution "Dry run complete: nothing was changed ($N_CHANGED would change, $N_UNCHANGED already in place)"
  info "Run again without DRY_RUN=1 to apply"
else
  good "Setup complete: $N_CHANGED created or assigned, $N_UNCHANGED already in place"
fi

section "What you have now"
kv "Maven virtual" "$MAVEN_VIRTUAL"
kv "  members" "patch-local, dev-local, prod-local, remote (in this order)"
kv "Maven config" "$MAVEN_VIRTUAL for releases and snapshots (jf mvn; plain mvn ignores it)"
kv "Docker virtual" "$DOCKER_VIRTUAL"
kv "  members" "dev-local, prod-local, remote"
kv "Docker push (CI)" "$DOCKER_DEV"
kv "CI access" "roles $CI_PROJECT_ROLES on $PROJECT_KEY, only for $GITHUB_REPOSITORY (OIDC)"
kv "Project admin" "$PROJECT_ADMIN_USER (Project Admin of $PROJECT_KEY)"
kv "Xray" "indexing on for every repository, and for builds in $BUILD_INFO_REPO (pattern $BUILD_INDEX_PATTERN)"
kv "Curation" "$MAVEN_REMOTE"

kv "GitHub variables" "JF_URL, JF_PROJECT_KEY, JF_OIDC_PROVIDER, JF_OIDC_AUDIENCE on $GITHUB_REPOSITORY (no secrets)"

# The generated password goes last so it is the last thing on screen.
if [[ "$GENERATED_PASSWORD" == 1 ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    echo; info "A password for $PROJECT_ADMIN_USER would be generated and shown once at the end of a real run"
  else
    box_add r "WARNING  SAVE THIS PASSWORD NOW: IT IS SHOWN ONLY ONCE"
    box_add n ""
    box_add n "User       $PROJECT_ADMIN_USER"
    box_add p "Password   $PROJECT_ADMIN_PASSWORD"
    box_add n ""
    box_add d "It is not stored anywhere and cannot be shown again."
    box_add d "Lost it? Reset it in the JFrog UI: Administration > Users."
    box_render "$YELLOW" heavy
  fi
fi
echo
