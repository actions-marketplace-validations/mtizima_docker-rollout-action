#!/usr/bin/env bash
# Removes everything the e2e tests created.
set -uo pipefail
docker ps -aq --filter label=com.docker.compose.project=dra-e2e | xargs -r docker rm -f 2>/dev/null
docker rm -f dra-e2e-server dra-e2e-registry 2>/dev/null
docker network rm dra-e2e_default 2>/dev/null
true
