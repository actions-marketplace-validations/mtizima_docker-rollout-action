#!/usr/bin/env bash
# Writes the .env uploaded with a deploy: test/env.sh <version> [broken] > file
cat <<ENV
APP_IMAGE=localhost:${REGISTRY_PORT:-15000}/dra-app:1
APP_VERSION=$1
APP_BROKEN=${2:-0}
TRAEFIK_PORT=${TRAEFIK_PORT:-18080}
ENV
