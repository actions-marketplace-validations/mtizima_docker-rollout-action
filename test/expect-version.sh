#!/usr/bin/env bash
# Asserts the app answers with the given version (waits up to 30s for a fresh stack).
set -euo pipefail
body=""
for _ in $(seq 30); do
  body="$(curl -fsS --max-time 5 "http://127.0.0.1:${TRAEFIK_PORT:-18080}/" 2>/dev/null || true)"
  [[ "$body" == "$1" ]] && { echo "app serves version $1"; exit 0; }
  sleep 1
done
echo "expected version '$1', got '$body'"
exit 1
