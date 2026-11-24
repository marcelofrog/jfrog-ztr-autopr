#!/usr/bin/env bash
# Resets the demo: deletes everything setup.sh created (AppTrust app, the builds CI published,
# repositories AND the artifacts in them, the project, the project-admin user and the CI user).
# The OIDC provider <owner>/<repo>@github belongs to the Frogbot GitHub integration and is not touched.
# Re-run ./setup.sh afterwards for a clean environment.
#
#   ./teardown.sh            # asks you to type the project key
#   ./teardown.sh --yes      # no prompt (CI / scripts)
#   DRY_RUN=1 ./teardown.sh  # list what would be deleted
#   NO_COLOR=1 ./teardown.sh # plain output
set -euo pipefail
ASSUME_EXISTS=1   # dry-run lists every resource
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# remove <kind> <name> <detail> <GET path> <DELETE path>: delete if present, skip otherwise.
remove() {
  if exists "$4"; then apply delete "$1" "$2" "$3" DELETE "$5"; else status absent "$1" "$2" "$3"; fi
}

banner "JFrog demo teardown" "deletes everything setup.sh created"
echo
kv "Server" "$SID ($JFROG_FQDN)"
kv "Project" "$PROJECT_KEY ($PROJECT_NAME)"
BUILD_INFO_REPO="$PROJECT_KEY-build-info"               # build repository JFrog creates with the project
BUILD_NAME="${BUILD_NAME:-${GITHUB_REPOSITORY#*/}}"     # the build name CI publishes (ci.yml: the repository name)
if [[ "$DRY_RUN" == 1 ]]; then kv "Mode" "${YELLOW}DRY RUN: nothing will be deleted${RESET}"
else kv "Mode" "${RED}live: deletion is permanent${RESET}"; fi

# ---- Warning box: exactly what goes away ----------------------------------------
box_add r "WARNING  THIS PERMANENTLY DELETES THE FOLLOWING"
box_add y "Repositories are deleted WITH ALL THEIR ARTIFACTS."
box_add n ""
bl() { printf '%-14s%s' "$1" "$2"; }   # aligned label/value inside the box
box_add n "$(bl Project "$PROJECT_KEY")"
box_add n "$(bl "AppTrust app" "$APP_KEY")"
box_add n "$(bl User "$PROJECT_ADMIN_USER")"
box_add n "$(bl "CI user" "$CI_USER")"
box_add n "$(bl Builds "all builds in $BUILD_INFO_REPO")"
box_add n "$(bl Repositories "$(( ${#VIRTUAL_REPOS[@]} + ${#OTHER_REPOS[@]} ))")"
for repo in "${VIRTUAL_REPOS[@]}" "${OTHER_REPOS[@]}"; do box_add d "  - $repo"; done
box_render "$RED" heavy

if [[ "$DRY_RUN" != 1 && "${1:-}" != "--yes" ]]; then
  [[ -t 0 ]] || die "Not a terminal: cannot ask for confirmation" "Pass --yes to confirm without a prompt"
  printf -v prompt '\n  %sType the project key (%s) to confirm:%s ' "$BOLD" "$PROJECT_KEY" "$RESET"
  read -r -p "$prompt" answer
  if [[ "$answer" != "$PROJECT_KEY" ]]; then warn "Aborted: nothing was deleted"; echo; exit 1; fi
fi

# AppTrust app first (it references the project).
section "AppTrust"
if exists "/apptrust/api/v1/applications/$APP_KEY"; then
  if [[ "$DRY_RUN" == 1 ]]; then
    status delete app "$APP_KEY" "$APP_NAME"
    show_request "jf apptrust app-delete $APP_KEY"
  else
    if ! jf apptrust app-delete "$APP_KEY" --server-id "$SID" >"$TMP/out" 2>&1; then
      fail "jf apptrust app-delete failed"
      printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/out" >&2; printf '%s\n' "$E_RESET" >&2
      hint "An application with versions cannot be deleted: delete its versions first (jf apptrust version-delete)"
      exit 1
    fi
    status delete app "$APP_KEY" "$APP_NAME"
  fi
else
  status absent app "$APP_KEY" "$APP_NAME"
fi

# Builds CI published to the project's build repository (<project>-build-info). Deleting the project does NOT
# remove them: the build repository and its builds stay behind. So delete every build of the project, all
# build numbers, while we can still list them by project key.
section "Builds"
builds=()
if [[ "$DRY_RUN" == 1 ]]; then
  # A dry run cannot list the server's builds: show the one CI publishes.
  [[ -z "$BUILD_NAME" ]] || builds=("$BUILD_NAME")
elif jf api --server-id "$SID" "/artifactory/api/build?project=$PROJECT_KEY" >"$TMP/builds.json" 2>"$TMP/err"; then
  while IFS= read -r b; do [[ -z "$b" ]] || builds+=("$b"); done \
    < <(jq -r '(.builds // [])[].uri | ltrimstr("/")' "$TMP/builds.json")   # the uri is already URL-encoded
elif grep -qE '401|403' "$TMP/err"; then
  fail "Could not list the builds of $PROJECT_KEY"
  printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/err" >&2; printf '%s\n' "$E_RESET" >&2
  hint "Session expired or not allowed. Run:  jf login   (server id: $SID)"
  exit 1
fi   # any other failure (404) means the project has no builds
if (( ${#builds[@]} == 0 )); then
  status absent build "${BUILD_NAME:-none}" "no builds in $BUILD_INFO_REPO"
fi
for b in ${builds[@]+"${builds[@]}"}; do
  apply delete build "$b" "all build numbers in $BUILD_INFO_REPO" \
    DELETE "/artifactory/api/build/$b?deleteAll=1&project=$PROJECT_KEY"
done

# Virtuals before the repos they contain, then everything else.
section "Repositories"
for repo in "${VIRTUAL_REPOS[@]}" "${OTHER_REPOS[@]}"; do
  remove repo "$repo" "" "/artifactory/api/repositories/$repo" "/artifactory/api/repositories/$repo"
done

# The project must be empty of repos before it can be deleted.
section "User and project"
remove user "$PROJECT_ADMIN_USER" "" "/access/api/v2/users/$PROJECT_ADMIN_USER" "/access/api/v2/users/$PROJECT_ADMIN_USER"
remove user "$CI_USER" "CI user" "/access/api/v2/users/$CI_USER" "/access/api/v2/users/$CI_USER"
remove project "$PROJECT_KEY" "$PROJECT_NAME" "/access/api/v1/projects/$PROJECT_KEY" "/access/api/v1/projects/$PROJECT_KEY"

# ---- Summary ------------------------------------------------------------------
if [[ "$DRY_RUN" == 1 ]]; then
  caution "Dry run complete: nothing was deleted ($N_CHANGED would be deleted)"
  info "Run again without DRY_RUN=1 to delete"
else
  good "Teardown complete: $N_CHANGED deleted, $N_UNCHANGED already absent"
  info "Run ./setup.sh to recreate the demo environment"
fi
echo
