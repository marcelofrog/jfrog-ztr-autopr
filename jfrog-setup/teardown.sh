#!/usr/bin/env bash
# Resets the demo: deletes everything setup.sh created (AppTrust app, OIDC provider + mapping,
# repositories AND the artifacts in them, the project, and the project-admin user).
# Re-run ./setup.sh afterwards for a clean environment.
#
#   ./teardown.sh            # asks you to type the project key
#   ./teardown.sh --yes      # no prompt (CI / scripts)
#   DRY_RUN=1 ./teardown.sh  # list what would be deleted
set -euo pipefail
ASSUME_EXISTS=1   # dry-run lists every resource
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "Server: $SID ($JFROG_FQDN)"
echo "This PERMANENTLY deletes, with all their artifacts:"
echo "  project $PROJECT_KEY, repos ${VIRTUAL_REPOS[*]} ${OTHER_REPOS[*]},"
echo "  AppTrust app $APP_KEY, OIDC provider $OIDC_PROVIDER_NAME, user $PROJECT_ADMIN_USER"

if [[ "$DRY_RUN" != 1 && "${1:-}" != "--yes" ]]; then
  [[ -t 0 ]] || { echo "Not a terminal; pass --yes to confirm." >&2; exit 1; }
  read -r -p "Type the project key ($PROJECT_KEY) to continue: " answer
  [[ "$answer" == "$PROJECT_KEY" ]] || { echo "Aborted."; exit 1; }
fi

# remove <label> <GET path> <DELETE path>: delete if present, skip otherwise.
remove() {
  if exists "$2"; then echo "delete   $1"; send DELETE "$3"; else echo "absent   $1"; fi
}

# AppTrust app first (it references the project).
if exists "/apptrust/api/v1/applications/$APP_KEY"; then
  echo "delete   app $APP_KEY"
  if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry-run] jf apptrust app-delete $APP_KEY"
  elif ! jf apptrust app-delete "$APP_KEY" --server-id "$SID" >"$TMP/out" 2>&1; then
    echo "FAILED: jf apptrust app-delete (delete its versions first?)" >&2; cat "$TMP/out" >&2; exit 1
  fi
else
  echo "absent   app $APP_KEY"
fi

remove "oidc mapping $OIDC_MAPPING_NAME" \
  "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings/$OIDC_MAPPING_NAME" \
  "/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings/$OIDC_MAPPING_NAME"
remove "oidc provider $OIDC_PROVIDER_NAME" "/access/api/v1/oidc/$OIDC_PROVIDER_NAME" "/access/api/v1/oidc/$OIDC_PROVIDER_NAME"

# Virtuals before the repos they contain, then everything else.
for repo in "${VIRTUAL_REPOS[@]}" "${OTHER_REPOS[@]}"; do
  remove "repo $repo" "/artifactory/api/repositories/$repo" "/artifactory/api/repositories/$repo"
done

# The project must be empty of repos before it can be deleted.
remove "user $PROJECT_ADMIN_USER" "/access/api/v2/users/$PROJECT_ADMIN_USER" "/access/api/v2/users/$PROJECT_ADMIN_USER"
remove "project $PROJECT_KEY" "/access/api/v1/projects/$PROJECT_KEY" "/access/api/v1/projects/$PROJECT_KEY"

echo "Teardown complete. Run ./setup.sh to recreate the demo environment."
