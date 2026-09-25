#!/usr/bin/env bash
# Runs the e2e scenarios locally by calling src/deploy.sh the same way action.yml does.
# CI runs the same scenarios through the real action (see .github/workflows/test.yml).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export DRA_TEST_DIR="${DRA_TEST_DIR:-$(mktemp -d)}"
export REGISTRY_PORT="${REGISTRY_PORT:-15000}" SSH_PORT="${SSH_PORT:-2222}" TRAEFIK_PORT="${TRAEFIK_PORT:-18080}"
cd "$root"

trap 'bash test/teardown.sh' EXIT
bash test/setup.sh

deploy() {
  env \
    DRA_HOST=127.0.0.1 DRA_PORT="$SSH_PORT" DRA_USER=deploy \
    DRA_SSH_KEY="$(cat "$DRA_TEST_DIR/id_ed25519")" \
    DRA_KNOWN_HOSTS="$(cat "$DRA_TEST_DIR/known_hosts")" \
    DRA_PROJECT_DIR=apps/e2e \
    DRA_FILES="test/fixture/compose.yml
$DRA_TEST_DIR/app.env:.env" \
    DRA_COMPOSE_FILES="" DRA_PROJECT_NAME="" \
    DRA_SERVICES=app DRA_UP_SERVICES="traefik worker" DRA_UP_FLAGS="--remove-orphans" \
    DRA_PULL=true \
    DRA_REGISTRY="localhost:$REGISTRY_PORT" DRA_REGISTRY_USERNAME=tester DRA_REGISTRY_PASSWORD=secret \
    DRA_PRE_DEPLOY="docker compose run --rm app sh -c 'echo migrating' && touch pre-deploy.done" \
    DRA_POST_DEPLOY="" \
    DRA_HEALTHCHECK=require DRA_TIMEOUT=20 DRA_WAIT=10 DRA_WAIT_AFTER_HEALTHY=0 \
    DRA_PRE_STOP_HOOK="touch /tmp/drain && sleep 3" \
    DRA_ROLLOUT_INSTALL=if-missing DRA_ROLLOUT_VERSION=v0.14 DRA_PRUNE=false \
    "$@" bash src/deploy.sh
}

step() { printf '\n\033[1;34m### %s\033[0m\n' "$*"; }

step "1. First deploy (v1)"
bash test/env.sh 1 >"$DRA_TEST_DIR/app.env"
deploy
bash test/expect-version.sh 1

step "2. Zero-downtime deploy under load (v2)"
bash test/env.sh 2 >"$DRA_TEST_DIR/app.env"
bash test/load.sh start "$DRA_TEST_DIR/load.log"
deploy
bash test/load.sh stop "$DRA_TEST_DIR/load.log"
bash test/expect-version.sh 2

step "3. Broken release is rolled back, traffic unaffected"
bash test/env.sh 3 1 >"$DRA_TEST_DIR/app.env"
bash test/load.sh start "$DRA_TEST_DIR/load.log"
if deploy; then
  echo "deploy of a broken release must fail"
  exit 1
fi
bash test/load.sh stop "$DRA_TEST_DIR/load.log"
bash test/expect-version.sh 2

step "4. Side effects"
bash test/assert-side-effects.sh

step "5. Invalid input is rejected before connecting"
if deploy DRA_HEALTHCHECK=sometimes 2>&1 | tee "$DRA_TEST_DIR/invalid.log"; then
  echo "invalid input must fail"
  exit 1
fi
grep -q "Input 'healthcheck' must be" "$DRA_TEST_DIR/invalid.log"

printf '\n\033[1;32mAll e2e scenarios passed\033[0m\n'
