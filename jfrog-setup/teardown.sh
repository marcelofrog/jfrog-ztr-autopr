#!/usr/bin/env bash
# Resets the demo: deletes everything setup.sh created (AppTrust app, OIDC provider + mapping,
# repositories AND the artifacts in them, the project, and the project-admin user).
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
if [[ "$DRY_RUN" == 1 ]]; then kv "Mode" "${YELLOW}DRY RUN: nothing will be deleted${RESET}"
else kv "Mode" "${RED}live: deletion is permanent${RESET}"; fi

# ---- Warning box: exactly what goes away ----------------------------------------
box_add r "WARNING  THIS PERMANENTLY DELETES THE FOLLOWING"
box_add y "Repositories are deleted WITH ALL THEIR ARTIFACTS."
box_add n ""
bl() { printf '%-14s%s' "$1" "$2"; }   # aligned label/value inside the box
box_add n "$(bl Project "$PROJECT_KEY")"
box_add n "$(bl "AppTrust app" "$APP_KEY")"
box_add n "$(bl OIDC "provider $OIDC_PROVIDER_NAME (and mapping $OIDC_MAPPING_NAME)")"
box_add n "$(bl User "$PROJECT_ADMIN_USER")"
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

section "GitHub OIDC"
remove oidc "$OIDC_MAPPING_NAME" "mapping" \
  "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings/$OIDC_MAPPING_NAME" \
  "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings/$OIDC_MAPPING_NAME"
remove oidc "$OIDC_PROVIDER_NAME" "provider" "/access/api/v1/oidc/$OIDC_PROVIDER_NAME" "/access/api/v1/oidc/$OIDC_PROVIDER_NAME"

# Virtuals before the repos they contain, then everything else.
section "Repositories"
for repo in "${VIRTUAL_REPOS[@]}" "${OTHER_REPOS[@]}"; do
  remove repo "$repo" "" "/artifactory/api/repositories/$repo" "/artifactory/api/repositories/$repo"
done

# The project must be empty of repos before it can be deleted.
section "User and project"
remove user "$PROJECT_ADMIN_USER" "" "/access/api/v2/users/$PROJECT_ADMIN_USER" "/access/api/v2/users/$PROJECT_ADMIN_USER"
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
