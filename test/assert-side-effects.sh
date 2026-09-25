#!/usr/bin/env bash
# Checks what a successful v2 deploy followed by a failed broken one must leave behind.
set -euo pipefail
cd "$(dirname "$0")/.."
REGISTRY_PORT="${REGISTRY_PORT:-15000}"

check() {
  local name="$1"
  shift
  if "$@"; then echo "ok: $name"; else echo "FAILED: $name"; exit 1; fi
}
check "pre-deploy ran" bash test/server-exec.sh 'test -f apps/e2e/pre-deploy.done'
check "no registry credentials left on the server" \
  bash test/server-exec.sh "! grep -rq localhost:$REGISTRY_PORT .docker /tmp 2>/dev/null"
check "docker-rollout installed" bash test/server-exec.sh 'test -x .docker/cli-plugins/docker-rollout'
check "worker updated via up-services" bash -c 'docker logs dra-e2e-worker 2>&1 | grep -qx "worker 2"'
# shellcheck disable=SC2016 # expanded by the inner bash
check "exactly one app container" \
  bash -c '[[ $(docker ps -q --filter label=com.docker.compose.project=dra-e2e --filter label=com.docker.compose.service=app | wc -l) == 1 ]]'
