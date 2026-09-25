#!/usr/bin/env bash
# Runs a command on the e2e server as the deploy user.
exec docker exec -u deploy -w /home/deploy dra-e2e-server bash -c "$*"
