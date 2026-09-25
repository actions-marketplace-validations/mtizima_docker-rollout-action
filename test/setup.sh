#!/usr/bin/env bash
# Starts the e2e environment: a password-protected registry with the app image and an SSH
# "server" container. Writes the SSH key and known_hosts into $DRA_TEST_DIR.
set -euo pipefail

cd "$(dirname "$0")"
: "${DRA_TEST_DIR:?}"
mkdir -p "$DRA_TEST_DIR"

REGISTRY_PORT="${REGISTRY_PORT:-15000}"
SSH_PORT="${SSH_PORT:-2222}"

bash ./teardown.sh >/dev/null 2>&1 || true

# Registry with basic auth.
docker run --rm --entrypoint htpasswd httpd:2-alpine -Bbn tester secret >"$DRA_TEST_DIR/htpasswd"
docker run -d --name dra-e2e-registry -p "127.0.0.1:$REGISTRY_PORT:5000" \
  -v "$DRA_TEST_DIR/htpasswd:/auth/htpasswd:ro" \
  -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=e2e \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:3 >/dev/null

export DOCKER_CONFIG="$DRA_TEST_DIR/docker-config"
mkdir -p "$DOCKER_CONFIG"
for _ in $(seq 30); do
  echo secret | docker login "localhost:$REGISTRY_PORT" -u tester --password-stdin >/dev/null 2>&1 && break
  sleep 1
done
docker pull -q nginx:1.29-alpine >/dev/null
docker tag nginx:1.29-alpine "localhost:$REGISTRY_PORT/dra-app:1"
docker push -q "localhost:$REGISTRY_PORT/dra-app:1" >/dev/null
docker rmi "localhost:$REGISTRY_PORT/dra-app:1" >/dev/null
unset DOCKER_CONFIG

# SSH server.
rm -f "$DRA_TEST_DIR/id_ed25519" "$DRA_TEST_DIR/id_ed25519.pub"
ssh-keygen -q -t ed25519 -N '' -f "$DRA_TEST_DIR/id_ed25519"
docker build -q -t dra-e2e-server server >/dev/null
docker run -d --name dra-e2e-server -p "127.0.0.1:$SSH_PORT:22" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AUTHORIZED_KEY="$(cat "$DRA_TEST_DIR/id_ed25519.pub")" \
  dra-e2e-server >/dev/null

for _ in $(seq 30); do
  if ssh-keyscan -p "$SSH_PORT" 127.0.0.1 >"$DRA_TEST_DIR/known_hosts" 2>/dev/null &&
    [[ -s "$DRA_TEST_DIR/known_hosts" ]]; then
    break
  fi
  sleep 1
done
[[ -s "$DRA_TEST_DIR/known_hosts" ]] || { docker logs dra-e2e-server; exit 1; }
echo "e2e environment is up (ssh 127.0.0.1:$SSH_PORT, registry localhost:$REGISTRY_PORT)"
