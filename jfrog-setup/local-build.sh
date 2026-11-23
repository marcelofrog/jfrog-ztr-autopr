#!/usr/bin/env bash
# Builds, tests and containerizes the app on your machine, entirely through JFrog.
# Host and CLI server id come from the root .env; credentials come from your `jf login` session:
# a short-lived token is minted with the CLI for Maven and Docker and is never written to disk.
#
#   ./local-build.sh              # mvn verify, then docker build
#   ./local-build.sh --no-docker  # mvn verify only
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$DRY_RUN" != 1 ]] || { echo "DRY_RUN is not supported here." >&2; exit 1; }
cd .. # repo root

echo "Minting a 1-hour token for ${CLI_USER:-the CLI user} on $JFROG_FQDN (server id: $SID)"
TOKEN="$(short_lived_token 3600)"

# ci/settings.xml reads these. They only exist in this process tree.
export JF_URL="$JFROG_URL" JF_MAVEN_REPO="$MAVEN_VIRTUAL" JF_USER="$CLI_USER" JF_ACCESS_TOKEN="$TOKEN"
mvn -B -s ci/settings.xml verify

if [[ "${1:-}" != "--no-docker" ]]; then
  printf '%s' "$TOKEN" | docker login "$JFROG_FQDN" -u "$CLI_USER" --password-stdin
  docker build --build-arg "BASE_REGISTRY=$JFROG_FQDN/$DOCKER_VIRTUAL" \
    -t "$JFROG_FQDN/$DOCKER_DEV/sample-app:local" .
  echo "Built $JFROG_FQDN/$DOCKER_DEV/sample-app:local"
fi
