#!/usr/bin/env bash
# Shared helpers for setup.sh, teardown.sh and local-build.sh. Source it; do not run it.
# shellcheck disable=SC2034  # variables are used by the sourcing scripts

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd .. && pwd)"   # the project root (the directory with pom.xml)

# ==== Output: colors, symbols, boxes ============================================
# Colors only appear on a terminal. NO_COLOR=1 turns them off, FORCE_COLOR=1 forces them on.
_want_color() { [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && { [[ -t "$1" ]] || [[ -n "${FORCE_COLOR:-}" ]]; }; }

if _want_color 1; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[1;31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; WHITE=$'\033[1;97m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; RESET=''
fi
if _want_color 2; then
  E_RED=$'\033[1;31m'; E_YELLOW=$'\033[33m'; E_DIM=$'\033[2m'; E_RESET=$'\033[0m'
else
  E_RED=''; E_YELLOW=''; E_DIM=''; E_RESET=''
fi

# Unicode symbols unless the locale says otherwise (then plain ASCII).
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  ""|*[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
    OK_SYM="✔"; FAIL_SYM="✖"; WARN_SYM="⚠"; ARROW="›"; DOT="·"; HR="━" ;;
  *)
    OK_SYM="+"; FAIL_SYM="x"; WARN_SYM="!"; ARROW=">"; DOT="-"; HR="-" ;;
esac
WIDTH=66

rep() { local n="$1" ch="$2" s; (( n < 0 )) && n=0; s="$(printf '%*s' "$n" '')"; printf '%s' "${s// /$ch}"; }

# section <title>: a cyan rule with the title.
section() { printf '\n%s%s%s %s %s%s\n' "$BOLD" "$CYAN" "$HR$HR" "$1" "$(rep $((WIDTH - ${#1} - 4)) "$HR")" "$RESET"; }
# kv <label> <value>: aligned "label  value" line.
kv() { printf '  %s%-18s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }
info() { printf '  %s%s %s%s\n' "$DIM" "$ARROW" "$*" "$RESET"; }
warn() { printf '  %s%s %s%s\n' "$YELLOW" "$WARN_SYM" "$*" "$RESET"; }
good() { printf '\n  %s%s %s%s\n' "$BOLD$GREEN" "$OK_SYM" "$*" "$RESET"; }
caution() { printf '\n  %s%s %s%s\n' "$BOLD$YELLOW" "$WARN_SYM" "$*" "$RESET"; }
# Errors go to stderr: fail <message>, hint <suggestion>, die <message> [hint...].
fail() { printf '\n%s%s %s%s\n' "$E_RED" "$FAIL_SYM" "$*" "$E_RESET" >&2; }
hint() { printf '    %s%s %s%s\n' "$E_YELLOW" "$ARROW" "$*" "$E_RESET" >&2; }
die() { local h; fail "$1"; shift; for h in "$@"; do hint "$h"; done; exit 1; }

# Boxes: box_add <style> <text>... then box_render <color> <round|heavy>.
# Styles: n normal, b bold, d dim, r bold red, y bold yellow, p password highlight.
# Keep box text ASCII so the right border lines up.
BOX_S=(); BOX_T=()
box_add() { BOX_S+=("$1"); BOX_T+=("$2"); }
box_render() {
  local color="$1" style="$2" w=58 i t s sty pad tl tr bl br h v
  for t in "${BOX_T[@]}"; do if (( ${#t} > w )); then w=${#t}; fi; done
  if [[ "$HR" == "━" ]]; then
    if [[ "$style" == heavy ]]; then tl="┏"; tr="┓"; bl="┗"; br="┛"; h="━"; v="┃"
    else tl="╭"; tr="╮"; bl="╰"; br="╯"; h="─"; v="│"; fi
  else tl="+"; tr="+"; bl="+"; br="+"; h="-"; v="|"; fi
  printf '\n  %s%s%s%s%s\n' "$color" "$tl" "$(rep $((w + 2)) "$h")" "$tr" "$RESET"
  for ((i = 0; i < ${#BOX_T[@]}; i++)); do
    s="${BOX_S[$i]}"; t="${BOX_T[$i]}"; pad=$((w - ${#t}))
    case "$s" in
      b) sty="$BOLD" ;; d) sty="$DIM" ;; r) sty="$RED" ;; y) sty="$BOLD$YELLOW" ;; p) sty="$WHITE" ;; *) sty="" ;;
    esac
    printf '  %s%s%s %s%s%s%*s %s%s%s\n' "$color" "$v" "$RESET" "$sty" "$t" "$RESET" "$pad" "" "$color" "$v" "$RESET"
  done
  printf '  %s%s%s%s%s\n' "$color" "$bl" "$(rep $((w + 2)) "$h")" "$br" "$RESET"
  BOX_S=(); BOX_T=()
}
# banner <title> [subtitle]
banner() { box_add b "$1"; if [[ -n "${2:-}" ]]; then box_add d "$2"; fi; box_render "$CYAN" round; }

# ---- Status lines and counters --------------------------------------------------
N_CHANGED=0; N_UNCHANGED=0
# status <create|assign|update|delete|exists|absent> <kind> <name> [detail]
status() {
  local act="$1" kind="$2" name="$3" detail="${4:-}" sym col label nm
  case "$act" in
    create) N_CHANGED=$((N_CHANGED + 1)); nm="$BOLD"
            if [[ "$DRY_RUN" == 1 ]]; then sym="$ARROW"; col="$YELLOW"; label="would create"
            else sym="$OK_SYM"; col="$GREEN"; label="created"; fi ;;
    assign) N_CHANGED=$((N_CHANGED + 1)); nm="$BOLD"
            if [[ "$DRY_RUN" == 1 ]]; then sym="$ARROW"; col="$YELLOW"; label="would assign"
            else sym="$OK_SYM"; col="$GREEN"; label="assigned"; fi ;;
    update) N_CHANGED=$((N_CHANGED + 1)); nm="$BOLD"
            if [[ "$DRY_RUN" == 1 ]]; then sym="$ARROW"; col="$YELLOW"; label="would update"
            else sym="$OK_SYM"; col="$GREEN"; label="updated"; fi ;;
    delete) N_CHANGED=$((N_CHANGED + 1)); nm="$BOLD"
            if [[ "$DRY_RUN" == 1 ]]; then sym="$ARROW"; col="$YELLOW"; label="would delete"
            else sym="$OK_SYM"; col="$RED"; label="deleted"; fi ;;
    exists) N_UNCHANGED=$((N_UNCHANGED + 1)); sym="$DOT"; col="$DIM"; label="exists"; nm="$DIM" ;;
    absent) N_UNCHANGED=$((N_UNCHANGED + 1)); sym="$DOT"; col="$DIM"; label="absent"; nm="$DIM" ;;
  esac
  printf '  %s%s %-13s%s %s%-9s%s %s%s%s' "$col" "$sym" "$label" "$RESET" "$DIM" "$kind" "$RESET" "$nm" "$name" "$RESET"
  if [[ -n "$detail" ]]; then printf '  %s%s%s' "$DIM" "$detail" "$RESET"; fi
  printf '\n'
}

# show_request <label> [json]: dry-run view of a call. Passwords are masked.
show_request() {
  printf '      %s%s %s%s\n' "$DIM" "$ARROW" "$1" "$RESET"
  if [[ -n "${2:-}" ]]; then
    printf '        %s%s%s\n' "$DIM" "$(jq -c 'if type == "object" and has("password") then .password = "********" else . end' <<<"$2")" "$RESET"
  fi
}

# ==== Configuration and prerequisites ============================================
# shellcheck source=config.env
source ./config.env

DRY_RUN="${DRY_RUN:-0}"
ASSUME_EXISTS="${ASSUME_EXISTS:-0}"   # dry-run only: pretend every resource exists (teardown)

command -v jq >/dev/null || die "jq is required" "Install it, for example: brew install jq"
if [[ "$DRY_RUN" != 1 ]]; then
  command -v jf >/dev/null || die "JFrog CLI (jf) is required" "Install it: https://jfrog.com/getcli"
fi

# ---- Server: FQDN + CLI server id come from the root .env (via config.env); auth comes from the CLI --
# No tokens are read or stored here. `jf login` (web login) created the CLI's credentials;
# every `jf` call below uses them, and anything that needs a raw token mints a short-lived one.
if [[ "$DRY_RUN" == 1 ]]; then
  JFROG_FQDN="${JFROG_FQDN:-<jfrog-fqdn>}"; JFROG_SERVER_ID="${JFROG_SERVER_ID:-<cli-server-id>}"
fi
if [[ -z "$JFROG_FQDN" || -z "$JFROG_SERVER_ID" ]]; then
  die "JFROG_FQDN and JFROG_SERVER_ID are not set" "Set both in the root .env"
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
    die "JFrog CLI server '$SID' not found" "Log in with:  jf login   (server id: $SID, URL: $JFROG_URL)"
  fi
  cli_host="${CLI_URL#*://}"; cli_host="${cli_host%%/*}"
  if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$cli_host")" != "$(tr '[:upper:]' '[:lower:]' <<<"$JFROG_FQDN")" ]]; then
    die "CLI server '$SID' points at '$cli_host' but JFROG_FQDN is '$JFROG_FQDN'" "Fix one of them in the root .env or with: jf config"
  fi
fi

# ==== Maven and Java ============================================================
# jf mvn runs the mvn binary. It looks on PATH, or at $M2_HOME/bin when M2_HOME is the Maven
# install directory (the one that contains bin and lib). A stale JAVA_HOME breaks that binary
# even when `java` itself is on PATH.

resolve_path() { # <path>: absolute path with symlinks resolved
  local p="$1" t i
  [[ "$p" == */* ]] || p="$(command -v "$p" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  if [[ "$p" != /* ]]; then p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"; fi
  for ((i = 0; i < 20; i++)); do
    [[ -L "$p" ]] || break
    t="$(readlink "$p")"
    if [[ "$t" != /* ]]; then t="$(cd "$(dirname "$p")" && pwd)/$t"; fi
    p="$t"
  done
  printf '%s\n' "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
}

is_java_home() { # <dir>
  [[ -n "${1:-}" && -x "$1/bin/java" ]] && "$1/bin/java" -version >/dev/null 2>&1
}

is_maven_home() { # <dir>: install directory, with bin/mvn and lib/maven-core-*.jar
  local jar
  [[ -n "${1:-}" && -x "$1/bin/mvn" && -d "$1/lib" ]] || return 1
  for jar in "$1"/lib/maven-core-*.jar; do
    [[ -f "$jar" ]] && return 0
  done
  return 1
}

# maven_home_from_mvn <path-to-mvn> [depth]: prints the install directory (contains bin and lib).
# Prefers a Homebrew libexec next to the binary over the versioned Cellar path a wrapper execs.
maven_home_from_mvn() {
  local p="$1" depth="${2:-0}" dir home target
  if (( depth > 10 )); then return 1; fi
  [[ -n "$p" ]] || return 1
  if [[ "$p" != /* ]]; then p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"; fi
  dir="$(cd "$(dirname "$p")" && pwd)"
  home="$(cd "$dir/.." && pwd)"
  if is_maven_home "$home"; then printf '%s\n' "$home"; return 0; fi
  if is_maven_home "$home/libexec"; then printf '%s\n' "$home/libexec"; return 0; fi
  if [[ -L "$p" ]]; then
    target="$(readlink "$p")"
    [[ "$target" == /* ]] || target="$dir/$target"
    if [[ "$target" != "$p" ]]; then maven_home_from_mvn "$target" $((depth + 1)) || return 1; return 0; fi
  fi
  if [[ -f "$p" ]]; then
    target="$(sed -n 's/.*exec "\([^"]*\/mvn\)".*/\1/p' "$p" | head -1)"
    if [[ -z "$target" ]]; then target="$(sed -n 's/.*exec \([^ ]*\/mvn\).*/\1/p' "$p" | head -1)"; fi
    if [[ -n "$target" && "$target" != "$p" && -e "$target" ]]; then
      maven_home_from_mvn "$target" $((depth + 1)) || return 1
      return 0
    fi
  fi
  return 1
}

# Homebrew's active install is /opt/homebrew/opt/maven (a symlink). Prefer that over the
# versioned Cellar path, so a brew upgrade does not leave a stale M2_HOME.
prefer_brew_maven_home() {
  local home="$1" real stable
  real="$(cd "$home" && pwd -P)"
  for stable in /opt/homebrew/opt/maven/libexec /usr/local/opt/maven/libexec; do
    if is_maven_home "$stable" && [[ "$(cd "$stable" && pwd -P)" == "$real" ]]; then
      printf '%s\n' "$stable"
      return 0
    fi
  done
  printf '%s\n' "$home"
}

find_java_home() {
  local h
  if is_java_home "${JAVA_HOME:-}"; then printf '%s\n' "$JAVA_HOME"; return 0; fi
  if [[ -x /usr/libexec/java_home ]]; then
    h="$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home 2>/dev/null || true)"
    if is_java_home "$h"; then printf '%s\n' "$h"; return 0; fi
  fi
  for h in \
    /opt/homebrew/opt/openjdk@21 \
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@21 \
    /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    /usr/lib/jvm/java-21-openjdk-amd64 \
    /usr/lib/jvm/java-21-openjdk \
    /usr/lib/jvm/java-21
  do
    if is_java_home "$h"; then printf '%s\n' "$h"; return 0; fi
  done
  if command -v java >/dev/null 2>&1; then
    h="$(resolve_path "$(command -v java)")" || true
    if [[ -n "$h" ]]; then
      h="$(cd "$(dirname "$h")/.." && pwd)"
      if is_java_home "$h"; then printf '%s\n' "$h"; return 0; fi
    fi
  fi
  return 1
}

find_mvn_binary() { # ignores PATH: used when `mvn` is missing or does not run
  local c d found="" newest=0 m ng=0
  for c in \
    /opt/homebrew/bin/mvn \
    /usr/local/bin/mvn \
    /opt/homebrew/opt/maven/bin/mvn \
    /usr/local/opt/maven/bin/mvn \
    "$HOME/.sdkman/candidates/maven/current/bin/mvn"
  do
    if [[ -x "$c" ]]; then printf '%s\n' "$c"; return 0; fi
  done
  if command -v brew >/dev/null 2>&1; then
    c="$(brew --prefix maven 2>/dev/null || true)"
    if [[ -n "$c" && -x "$c/bin/mvn" ]]; then printf '%s\n' "$c/bin/mvn"; return 0; fi
    if [[ -n "$c" && -x "$c/libexec/bin/mvn" ]]; then printf '%s\n' "$c/libexec/bin/mvn"; return 0; fi
  fi
  shopt -q nullglob && ng=1
  shopt -s nullglob
  for d in /opt/homebrew/Cellar/maven/*/libexec /usr/local/Cellar/maven/*/libexec /opt/apache-maven-* /usr/local/apache-maven-* /opt/maven /usr/local/maven; do
    [[ -x "$d/bin/mvn" ]] || continue
    m="$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo 0)"
    if (( m >= newest )); then newest=$m; found="$d/bin/mvn"; fi
  done
  [[ "$ng" == 1 ]] || shopt -u nullglob
  [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
  return 1
}

# upsert_env <KEY> <value>: set KEY="value" in the root .env. Returns 0 when the file changed.
upsert_env() {
  local key="$1" val="$2" file="$REPO_ROOT/.env" tmp found=0 line
  [[ -f "$file" ]] || return 1
  if grep -F -x -q "${key}=\"${val}\"" "$file" || grep -F -x -q "${key}=${val}" "$file"; then return 1; fi
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then printf '%s="%s"\n' "$key" "$val"; found=1
    else printf '%s\n' "$line"; fi
  done < "$file" > "$tmp"
  if [[ "$found" == 0 ]]; then
    if ! grep -q '^# Build tools' "$tmp"; then
      printf '\n# Build tools. Written by setup.sh when mvn or java is not on PATH.\n# M2_HOME is the Maven directory that contains bin and lib.\n' >> "$tmp"
    fi
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

# ensure_build_tools: `java` and `mvn` must actually run. Missing tools are searched for
# and recorded in the root .env (JAVA_HOME, M2_HOME) so later scripts pick them up.
ensure_build_tools() {
  local java_home mvn_bin maven_home on_path=0
  java_home="$(find_java_home)" || die "No JDK found" \
    "Install JDK 21, or set JAVA_HOME in the root .env to a directory whose bin/java runs"
  if ! is_java_home "${JAVA_HOME:-}"; then
    export JAVA_HOME="$java_home"
    if upsert_env JAVA_HOME "$java_home"; then
      info "java was not on PATH, or JAVA_HOME did not run. Wrote JAVA_HOME=$java_home to .env"
    fi
  fi
  case ":$PATH:" in *":$JAVA_HOME/bin:"*) ;; *) PATH="$JAVA_HOME/bin:$PATH" ;; esac
  export PATH

  if ! is_maven_home "${M2_HOME:-}"; then
    if command -v mvn >/dev/null 2>&1; then mvn_bin="$(command -v mvn)"; on_path=1
    else mvn_bin="$(find_mvn_binary)" || die "mvn was not found" \
      "Install Maven, or set M2_HOME in the root .env to the directory that contains bin and lib"; fi
    maven_home="$(maven_home_from_mvn "$mvn_bin")" || die "Found $mvn_bin, but it is not inside a Maven install" \
      "Set M2_HOME to the directory that contains bin and lib"
    maven_home="$(prefer_brew_maven_home "$maven_home")"
    export M2_HOME="$maven_home"
    if upsert_env M2_HOME "$maven_home"; then
      if [[ "$on_path" == 1 ]]; then info "Wrote M2_HOME=$maven_home to .env"
      else info "mvn was not on PATH. Wrote M2_HOME=$maven_home to .env"; fi
    fi
  fi
  case ":$PATH:" in *":$M2_HOME/bin:"*) ;; *) PATH="$M2_HOME/bin:$PATH" ;; esac
  export PATH
  mvn -version >/dev/null 2>&1 || die "mvn at $M2_HOME/bin/mvn did not run" \
    "JAVA_HOME is $JAVA_HOME. M2_HOME must be the directory that contains bin and lib"
  kv "Java" "$JAVA_HOME"
  kv "Maven" "$M2_HOME"
}

# short_lived_token [ttl-seconds]: prints a new access token for the CLI's logged-in user.
# Default 1 hour. The token is never written to disk by these scripts.
short_lived_token() {
  local token
  token="$(jf atc --server-id "$SID" --expiry="${1:-3600}" \
             --description="jfrog-setup short-lived token" --format=json 2>/dev/null \
           | jq -r '.access_token // .accessToken // empty')"
  if [[ -z "$token" ]]; then
    fail "Could not mint a token with 'jf atc'"; hint "Run 'jf login' for server '$SID'"; return 1
  fi
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

# ==== API helpers ================================================================
# exists <path>: true when GET <path> returns 2xx.
exists() {
  if [[ "$DRY_RUN" == 1 ]]; then [[ "$ASSUME_EXISTS" == 1 ]]; return; fi
  jf api --server-id "$SID" "$1" >/dev/null 2>&1
}

# send <METHOD> <path> [json]: fails loudly (status + body) on non-2xx.
send() {
  local method="$1" path="$2" body="${3:-}" args=()
  if [[ "$DRY_RUN" == 1 ]]; then show_request "$method $path" "$body"; return 0; fi
  if [[ -n "$body" ]]; then
    printf '%s' "$body" >"$TMP/body.json"
    args=(-H "Content-Type: application/json" --input "$TMP/body.json")
  fi
  if ! jf api --server-id "$SID" "$path" -X "$method" ${args[@]+"${args[@]}"} >"$TMP/out" 2>"$TMP/err"; then
    fail "Request failed: $method $path"
    printf '%s' "$E_DIM" >&2; sed 's/^/      /' "$TMP/err" "$TMP/out" >&2; printf '%s\n' "$E_RESET" >&2
    if grep -q '401' "$TMP/err"; then hint "Session expired. Run:  jf login   (server id: $SID)"; fi
    exit 1
  fi
}

# apply <create|assign|delete> <kind> <name> <detail> <METHOD> <path> [json]
# Sends the request and prints one status line. In a dry run it prints the plan and the request.
apply() {
  local act="$1" kind="$2" name="$3" detail="$4"; shift 4
  if [[ "$DRY_RUN" == 1 ]]; then status "$act" "$kind" "$name" "$detail"; send "$@"
  else send "$@"; status "$act" "$kind" "$name" "$detail"; fi
}
