#!/usr/bin/env bash
# Creates the JFrog Project (+ a new project-admin user), Artifactory repositories,
# the GitHub Actions OIDC integration and the AppTrust application for the sample app.
# Idempotent: anything that already exists is skipped.
#
# Requires: jf (JFrog CLI with `jf apptrust`), jq, openssl, and a CLI server logged in with
# `jf login` (web login) as a platform admin. JFROG_FQDN and JFROG_SERVER_ID come from the root .env.
# No tokens are used or needed.
#
#   GITHUB_REPOSITORY=owner/repo ./setup.sh     # create everything
#   DRY_RUN=1 GITHUB_REPOSITORY=owner/repo ./setup.sh   # print requests, change nothing
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then GITHUB_REPOSITORY="owner/repo"
  else echo "Set GITHUB_REPOSITORY=owner/repo (root .env or environment): the only repo allowed to use OIDC." >&2; exit 1; fi
fi
echo "Server: $SID ($JFROG_FQDN)  Project: $PROJECT_KEY  Application: $APP_KEY  GitHub: $GITHUB_REPOSITORY"

# ---- Builders -----------------------------------------------------------------
local_repo() { # <key> <packageType> <environment> [description]
  jq -n --arg key "$1" --arg pt "$2" --arg env "$3" --arg desc "${4:-}" --arg proj "$PROJECT_KEY" '
    {key:$key, rclass:"local", packageType:$pt, projectKey:$proj,
     description:(if $desc != "" then $desc else "Sample app \($pt) (\($env))" end),
     environments:(if $env == "" then [] else [$env] end)}
    + (if $pt == "docker" then {dockerApiVersion:"V2"} else {} end)'
}

remote_repo() { # <key> <packageType> <url>
  jq -n --arg key "$1" --arg pt "$2" --arg url "$3" --arg proj "$PROJECT_KEY" '
    {key:$key, rclass:"remote", packageType:$pt, url:$url, projectKey:$proj,
     description:"Proxy of \($url)"}
    + (if $pt == "maven" then {handleReleases:true, handleSnapshots:false} else {} end)
    + (if $pt == "docker" then {enableTokenAuthentication:true, externalDependenciesEnabled:false} else {} end)'
}

virtual_repo() { # <key> <packageType> <defaultDeploymentRepo> <member>...
  local key="$1" pt="$2" deploy="$3"; shift 3
  printf '%s\n' "$@" | jq -R . | jq -s --arg key "$key" --arg pt "$pt" --arg deploy "$deploy" --arg proj "$PROJECT_KEY" '
    {key:$key, rclass:"virtual", packageType:$pt, projectKey:$proj,
     repositories:., defaultDeploymentRepo:$deploy,
     description:"Resolve and deploy \($pt) through one URL"}'
}

# ---- Ensure steps -------------------------------------------------------------
ensure_project() {
  if exists "/access/api/v1/projects/$PROJECT_KEY"; then echo "project  $PROJECT_KEY: exists"; return; fi
  echo "project  $PROJECT_KEY: creating"
  send POST /access/api/v1/projects "$(jq -n \
    --arg key "$PROJECT_KEY" --arg name "$PROJECT_NAME" \
    '{project_key:$key, display_name:$name, description:"Sample Java/Maven app",
      admin_privileges:{manage_members:true, manage_resources:true, index_resources:true}}')"
}

# New (non-platform-admin) user who becomes Project Admin of the project.
ensure_project_admin() {
  if exists "/access/api/v2/users/$PROJECT_ADMIN_USER"; then
    echo "user     $PROJECT_ADMIN_USER: exists"
  else
    if [[ -z "$PROJECT_ADMIN_PASSWORD" ]]; then
      PROJECT_ADMIN_PASSWORD="Aa1!$(openssl rand -hex 12)"
      GENERATED_PASSWORD=1
    fi
    echo "user     $PROJECT_ADMIN_USER: creating"
    send POST /access/api/v2/users "$(jq -n \
      --arg u "$PROJECT_ADMIN_USER" --arg e "$PROJECT_ADMIN_EMAIL" --arg p "$PROJECT_ADMIN_PASSWORD" \
      '{username:$u, email:$e, password:$p, admin:false, profile_updatable:true}')"
  fi
  echo "member   $PROJECT_ADMIN_USER -> Project Admin on $PROJECT_KEY"
  send PUT "/access/api/v1/projects/$PROJECT_KEY/users/$PROJECT_ADMIN_USER" \
    "$(jq -n --arg u "$PROJECT_ADMIN_USER" '{name:$u, roles:["Project Admin"]}')"
}

ensure_repo() { # <key> <json>
  if exists "/artifactory/api/repositories/$1"; then echo "repo     $1: exists"; return; fi
  echo "repo     $1: creating"
  send PUT "/artifactory/api/repositories/$1" "$2"
}

# GitHub Actions OIDC: provider + one identity mapping limited to this repository.
# Workflows exchange their GitHub token for a short-lived, project-scoped JFrog token.
ensure_oidc() {
  if exists "/access/api/v1/oidc/$OIDC_PROVIDER_NAME"; then
    echo "oidc     provider $OIDC_PROVIDER_NAME: exists"
  else
    echo "oidc     provider $OIDC_PROVIDER_NAME: creating"
    send POST /access/api/v1/oidc "$(jq -n \
      --arg n "$OIDC_PROVIDER_NAME" --arg iss "$OIDC_ISSUER_URL" --arg aud "$OIDC_AUDIENCE" \
      '{name:$n, description:"GitHub Actions", issuer_url:$iss, provider_type:"GitHub", audience:$aud}')"
  fi
  if exists "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings/$OIDC_MAPPING_NAME"; then
    echo "oidc     mapping $OIDC_MAPPING_NAME: exists"
  else
    echo "oidc     mapping $OIDC_MAPPING_NAME: creating ($GITHUB_REPOSITORY -> $CI_PROJECT_ROLE on $PROJECT_KEY)"
    send POST "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings" "$(jq -n \
      --arg n "$OIDC_MAPPING_NAME" --arg repo "$GITHUB_REPOSITORY" --arg user "$CI_TOKEN_USERNAME" \
      --arg scope "applied-permissions/roles:$PROJECT_KEY:$CI_PROJECT_ROLE" --argjson ttl "$CI_TOKEN_TTL_SECONDS" \
      '{name:$n, description:"CI for \($repo)", priority:1,
        claims:{repository:$repo},
        token_spec:{username:$user, scope:$scope, audience:"*@*", expires_in:$ttl}}')"
  fi
}

ensure_app() {
  if exists "/apptrust/api/v1/applications/$APP_KEY"; then echo "app      $APP_KEY: exists"; return; fi
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "app      $APP_KEY: [dry-run] jf apptrust app-create $APP_KEY --project=$PROJECT_KEY"; return
  fi
  echo "app      $APP_KEY: creating"
  if ! jf apptrust app-create "$APP_KEY" --server-id "$SID" --project="$PROJECT_KEY" \
        --application-name="$APP_NAME" --desc="$APP_DESCRIPTION" \
        --business-criticality="$APP_CRITICALITY" --maturity-level="$APP_MATURITY" \
        >"$TMP/out" 2>&1; then
    if grep -qiE 'already exists|conflict|409' "$TMP/out"; then echo "app      $APP_KEY: exists"
    else echo "FAILED: jf apptrust app-create" >&2; cat "$TMP/out" >&2; exit 1; fi
  fi
}

# ---- Create (project first; locals, remotes, then the virtuals that aggregate them)
GENERATED_PASSWORD=0
ensure_project
ensure_project_admin

ensure_repo "$MAVEN_DEV"     "$(local_repo "$MAVEN_DEV"   maven  "$DEV_ENVIRONMENT")"
ensure_repo "$MAVEN_PROD"    "$(local_repo "$MAVEN_PROD"  maven  "$PROD_ENVIRONMENT")"
# Patch repo for JFrog ZTR: no environment (not part of promotion), holds patched libraries.
ensure_repo "$MAVEN_PATCH"   "$(local_repo "$MAVEN_PATCH" maven  "" "Local patch repo for JFrog ZTR")"
ensure_repo "$DOCKER_DEV"    "$(local_repo "$DOCKER_DEV"  docker "$DEV_ENVIRONMENT")"
ensure_repo "$DOCKER_PROD"   "$(local_repo "$DOCKER_PROD" docker "$PROD_ENVIRONMENT")"
ensure_repo "$MAVEN_REMOTE"  "$(remote_repo "$MAVEN_REMOTE"  maven  "$MAVEN_UPSTREAM_URL")"
ensure_repo "$DOCKER_REMOTE" "$(remote_repo "$DOCKER_REMOTE" docker "$DOCKER_UPSTREAM_URL")"
ensure_repo "$MAVEN_VIRTUAL"  "$(virtual_repo "$MAVEN_VIRTUAL"  maven  "$MAVEN_DEV"  "$MAVEN_PATCH" "$MAVEN_DEV"  "$MAVEN_PROD"  "$MAVEN_REMOTE")"
ensure_repo "$DOCKER_VIRTUAL" "$(virtual_repo "$DOCKER_VIRTUAL" docker "$DOCKER_DEV" "$DOCKER_DEV" "$DOCKER_PROD" "$DOCKER_REMOTE")"

ensure_oidc
ensure_app

# ---- Summary ------------------------------------------------------------------
cat <<EOF

Done. No secrets are needed in GitHub. Set these repository VARIABLES
(Settings > Secrets and variables > Actions > Variables) on $GITHUB_REPOSITORY:

  JF_URL=$JFROG_URL
  JF_PROJECT_KEY=$PROJECT_KEY
  JF_OIDC_PROVIDER=$OIDC_PROVIDER_NAME     (optional; this is the default)

Workflow tokens are issued as role "$CI_PROJECT_ROLE" on project "$PROJECT_KEY", for repo "$GITHUB_REPOSITORY" only.

Repositories:
  Maven   resolve+deploy: $MAVEN_VIRTUAL  ($MAVEN_PATCH, $MAVEN_DEV, $MAVEN_PROD, $MAVEN_REMOTE)
  Docker  pull:           $DOCKER_VIRTUAL  ($DOCKER_DEV, $DOCKER_PROD, $DOCKER_REMOTE)
  Docker  push (CI):      $DOCKER_DEV

Project admin: $PROJECT_ADMIN_USER (Project Admin of $PROJECT_KEY)
EOF
if [[ "$GENERATED_PASSWORD" == 1 ]]; then
  echo "  Generated password (shown once): $PROJECT_ADMIN_PASSWORD"
fi
