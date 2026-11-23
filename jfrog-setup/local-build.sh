#!/usr/bin/env bash
# Builds, tests and containerizes the app on your machine, entirely through JFrog.
# Host and CLI server id come from the root .env. Maven runs as `jf mvn`, which reads
# .jfrog/projects/maven.yaml (written by setup.sh) and uses your `jf login` session.
# Docker login uses a short-lived token minted with the CLI; it is never written to disk.
#
#   ./local-build.sh              # jf mvn verify, then docker build
#   ./local-build.sh --no-docker  # jf mvn verify only
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$DRY_RUN" != 1 ]] || die "DRY_RUN is not supported here"
cd "$REPO_ROOT"

banner "JFrog local build" "Maven build and Docker image, resolved through JFrog"
echo
kv "Server" "$SID ($JFROG_FQDN)"
kv "Maven repo" "$MAVEN_VIRTUAL"
kv "Docker base" "$JFROG_FQDN/$DOCKER_VIRTUAL"

# jf mvn refuses to run without this file, and a file for another CLI server would
# authenticate against the wrong instance.
MAVEN_CFG=".jfrog/projects/maven.yaml"
[[ -f "$MAVEN_CFG" ]] || die "No JFrog Maven config ($MAVEN_CFG)" \
  "Run ./jfrog-setup/setup.sh first. It writes the config that jf mvn reads."
cfg_servers="$(awk '/^[[:space:]]*serverId:/{print $2}' "$MAVEN_CFG" | sort -u)"
[[ "$cfg_servers" == "$SID" ]] || die "Maven config points at CLI server '${cfg_servers:-<none>}', not '$SID'" \
  "Re-run ./jfrog-setup/setup.sh to rewrite $MAVEN_CFG"

section "Build tools"
ensure_build_tools

section "Maven build and test"
info "jf mvn verify, releases and snapshots from $MAVEN_VIRTUAL"
jf mvn -B verify

if [[ "${1:-}" != "--no-docker" ]]; then
  section "Docker image"
  info "Minting a 1-hour token for ${CLI_USER:-the CLI user} (Docker login only, not written to disk)"
  TOKEN="$(short_lived_token 3600)"
  printf '%s' "$TOKEN" | docker login "$JFROG_FQDN" -u "$CLI_USER" --password-stdin
  docker build --build-arg "BASE_REGISTRY=$JFROG_FQDN/$DOCKER_VIRTUAL" \
    -t "$JFROG_FQDN/$DOCKER_DEV/sample-app:local" .
  good "Built $JFROG_FQDN/$DOCKER_DEV/sample-app:local"
else
  good "Maven build complete (Docker skipped)"
fi
echo
