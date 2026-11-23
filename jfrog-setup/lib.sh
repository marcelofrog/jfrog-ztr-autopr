#!/usr/bin/env bash
# Shared helpers for setup.sh and teardown.sh. Source it; do not run it.
# shellcheck disable=SC2034  # variables are used by the sourcing scripts

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=config.env
source ./config.env

DRY_RUN="${DRY_RUN:-0}"
ASSUME_EXISTS="${ASSUME_EXISTS:-0}"   # dry-run only: pretend every resource exists (teardown)

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
if [[ "$DRY_RUN" != 1 ]]; then
  command -v jf >/dev/null || { echo "JFrog CLI (jf) is required" >&2; exit 1; }
fi

# ---- Server: FQDN + CLI server id come from the root .env (via config.env); auth comes from the CLI --
# No tokens are read or stored here. `jf login` (web login) created the CLI's credentials;
# every `jf` call below uses them, and anything that needs a raw token mints a short-lived one.
if [[ "$DRY_RUN" == 1 ]]; then
  JFROG_FQDN="${JFROG_FQDN:-<jfrog-fqdn>}"; JFROG_SERVER_ID="${JFROG_SERVER_ID:-<cli-server-id>}"
fi
if [[ -z "$JFROG_FQDN" || -z "$JFROG_SERVER_ID" ]]; then
  echo "Set JFROG_FQDN and JFROG_SERVER_ID in the root .env (or the environment)." >&2
  echo "No .env yet? Create it from the template:  cp .env.sample .env" >&2
  exit 1
fi
JFROG_FQDN="${JFROG_FQDN#*://}"; JFROG_FQDN="${JFROG_FQDN%%/*}"   # tolerate a pasted URL
JFROG_URL="https://$JFROG_FQDN"
SID="$JFROG_SERVER_ID"

if [[ "$DRY_RUN" != 1 ]]; then
  # The CLI server must exist and must point at the configured FQDN (never silently use another instance).
  cfg="$(jf c show "$SID" --format=json 2>/dev/null || true)"
  CLI_URL="$(jq -r 'if type == "array" then .[0] else . end | .url // empty' <<<"$cfg" 2>/dev/null || true)"
  CLI_USER="$(jq -r 'if type == "array" then .[0] else . end | .user // empty' <<<"$cfg" 2>/dev/null || true)"
  if [[ -z "$CLI_URL" ]]; then
    echo "JFrog CLI server '$SID' not found. Log in with:  jf login   (server id: $SID, URL: $JFROG_URL)" >&2
    exit 1
  fi
  cli_host="${CLI_URL#*://}"; cli_host="${cli_host%%/*}"
  if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$cli_host")" != "$(tr '[:upper:]' '[:lower:]' <<<"$JFROG_FQDN")" ]]; then
    echo "CLI server '$SID' points at '$cli_host' but JFROG_FQDN is '$JFROG_FQDN' (root .env). Fix one of them." >&2
    exit 1
  fi
fi

# short_lived_token [ttl-seconds]: prints a new access token for the CLI's logged-in user.
# Default 1 hour. The token is never written to disk by these scripts.
short_lived_token() {
  local token
  token="$(jf atc --server-id "$SID" --expiry="${1:-3600}" \
             --description="jfrog-setup short-lived token" --format=json 2>/dev/null \
           | jq -r '.access_token // .accessToken // empty')"
  [[ -n "$token" ]] || { echo "Could not mint a token with 'jf atc'. Run 'jf login' for server '$SID'." >&2; return 1; }
  printf '%s' "$token"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- Names (<project>-<format>-<role>) ----------------------------------------
P="$PROJECT_KEY"
MAVEN_DEV="$P-maven-dev-local";   MAVEN_PROD="$P-maven-prod-local"
MAVEN_REMOTE="$P-maven-remote";   MAVEN_VIRTUAL="$P-maven-virtual"
MAVEN_PATCH="$P-maven-patch-local"   # local patch repo for JFrog ZTR; first in the Maven virtual
DOCKER_DEV="$P-docker-dev-local"; DOCKER_PROD="$P-docker-prod-local"
DOCKER_REMOTE="$P-docker-remote"; DOCKER_VIRTUAL="$P-docker-virtual"
VIRTUAL_REPOS=("$MAVEN_VIRTUAL" "$DOCKER_VIRTUAL")
OTHER_REPOS=("$MAVEN_PATCH" "$MAVEN_DEV" "$MAVEN_PROD" "$MAVEN_REMOTE" "$DOCKER_DEV" "$DOCKER_PROD" "$DOCKER_REMOTE")

# ---- Helpers ------------------------------------------------------------------
# exists <path>: true when GET <path> returns 2xx.
exists() {
  if [[ "$DRY_RUN" == 1 ]]; then [[ "$ASSUME_EXISTS" == 1 ]]; return; fi
  jf api --server-id "$SID" "$1" >/dev/null 2>&1
}

# send <METHOD> <path> [json]: fails loudly (body + status) on non-2xx.
send() {
  local method="$1" path="$2" body="${3:-}" args=()
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "  [dry-run] $method $path"
    [[ -n "$body" ]] && echo "$body" | jq -c . | sed 's/^/            /'
    return 0
  fi
  if [[ -n "$body" ]]; then
    printf '%s' "$body" >"$TMP/body.json"
    args=(-H "Content-Type: application/json" --input "$TMP/body.json")
  fi
  if ! jf api --server-id "$SID" "$path" -X "$method" ${args[@]+"${args[@]}"} >"$TMP/out" 2>"$TMP/err"; then
    echo "FAILED: $method $path" >&2; cat "$TMP/err" "$TMP/out" >&2
    grep -q '401' "$TMP/err" && echo "Hint: session expired. Run:  jf login   (server id: $SID)" >&2
    exit 1
  fi
}
