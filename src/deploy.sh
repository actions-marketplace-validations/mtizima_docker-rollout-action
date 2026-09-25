#!/usr/bin/env bash
# Runner side: validates inputs, prepares SSH and streams src/remote.sh to the server.
#
# Everything the server needs travels in a single `ssh … bash -s` session: input values are
# serialized with `declare -p` (safe re-quoting for bash), uploaded files are embedded as
# base64, and secrets never appear in a command line on either side.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

error() {
  printf '::error::%s\n' "$*"
  exit 1
}

# Splits a whitespace/newline-separated list into the named array.
split_words() {
  local -n _out="$1"
  read -r -d '' -a _out <<<"$2" || true
}

require() {
  [[ -n "${!1:-}" ]] || error "Input '$2' is required."
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

input_name() {
  local name="${1,,}"
  echo "${name//_/-}"
}

is_bool() { [[ "$1" == true || "$1" == false ]]; }

validate() {
  require DRA_HOST host
  require DRA_USER user
  require DRA_SSH_KEY ssh-key
  require DRA_PROJECT_DIR project-dir

  local name
  for name in PORT TIMEOUT WAIT WAIT_AFTER_HEALTHY; do
    local var="DRA_$name"
    is_uint "${!var}" || error "Input '$(input_name "$name")' must be a non-negative integer, got '${!var}'."
  done
  for name in PULL PRUNE; do
    local var="DRA_$name"
    is_bool "${!var}" || error "Input '$(input_name "$name")' must be 'true' or 'false', got '${!var}'."
  done

  case "$DRA_HEALTHCHECK" in warn | require | ignore) ;;
  *) error "Input 'healthcheck' must be warn, require or ignore, got '$DRA_HEALTHCHECK'." ;;
  esac
  case "$DRA_ROLLOUT_INSTALL" in if-missing | always | never) ;;
  *) error "Input 'rollout-install' must be if-missing, always or never, got '$DRA_ROLLOUT_INSTALL'." ;;
  esac
  [[ "$DRA_ROLLOUT_VERSION" =~ ^v[0-9]+(\.[0-9]+)*$ ]] ||
    error "Input 'rollout-version' must look like v0.14, got '$DRA_ROLLOUT_VERSION'."

  if [[ -n "$DRA_REGISTRY" ]]; then
    [[ -n "$DRA_REGISTRY_USERNAME" && -n "$DRA_REGISTRY_PASSWORD" ]] ||
      error "Inputs 'registry-username' and 'registry-password' are required when 'registry' is set."
  fi

  split_words SERVICES "$DRA_SERVICES"
  split_words UP_SERVICES "$DRA_UP_SERVICES"
  ((${#SERVICES[@]} + ${#UP_SERVICES[@]} > 0)) ||
    error "Nothing to deploy: set 'services' and/or 'up-services'."
}

# Reads the `files` input into UPLOAD_DESTS / UPLOAD_DATA (base64).
collect_files() {
  UPLOAD_DESTS=()
  UPLOAD_DATA=()
  local line src dest
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == *:* ]]; then
      src="${line%%:*}"
      dest="${line#*:}"
    else
      src="$line"
      dest="$(basename -- "$src")"
    fi
    [[ -n "$src" && -n "$dest" ]] || error "Invalid 'files' entry: '$line'."
    [[ -f "$src" ]] || error "File to upload not found: '$src'."
    UPLOAD_DESTS+=("$dest")
    UPLOAD_DATA+=("$(base64 <"$src" | tr -d '\n')")
  done <<<"$DRA_FILES"
}

setup_ssh() {
  workdir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/docker-rollout.XXXXXX")"
  trap 'rm -rf "$workdir"' EXIT

  install -m 600 /dev/null "$workdir/key"
  printf '%s\n' "$DRA_SSH_KEY" >"$workdir/key"

  if [[ -n "$DRA_KNOWN_HOSTS" ]]; then
    printf '%s\n' "$DRA_KNOWN_HOSTS" >"$workdir/known_hosts"
  else
    printf '::warning::%s\n' "Input 'known-hosts' is empty: trusting the host key from ssh-keyscan (TOFU). Pin it with 'known-hosts' to protect against MITM."
    ssh-keyscan -T 15 -p "$DRA_PORT" "$DRA_HOST" >"$workdir/known_hosts" 2>/dev/null ||
      error "ssh-keyscan failed for $DRA_HOST:$DRA_PORT."
    [[ -s "$workdir/known_hosts" ]] || error "ssh-keyscan returned no keys for $DRA_HOST:$DRA_PORT."
  fi

  ssh_cmd=(
    ssh -i "$workdir/key" -p "$DRA_PORT"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$workdir/known_hosts"
    -o ConnectTimeout=20
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    -o LogLevel=ERROR
    "$DRA_USER@$DRA_HOST"
  )
}

# Prints the bash program executed on the server.
build_payload() {
  local PROJECT_DIR="$DRA_PROJECT_DIR" PROJECT_NAME="$DRA_PROJECT_NAME"
  local -a COMPOSE_FILES UP_FLAGS
  local PULL="$DRA_PULL" PRUNE="$DRA_PRUNE"
  local REGISTRY="$DRA_REGISTRY" REGISTRY_USERNAME="$DRA_REGISTRY_USERNAME"
  local REGISTRY_PASSWORD="$DRA_REGISTRY_PASSWORD"
  local PRE_DEPLOY="$DRA_PRE_DEPLOY" POST_DEPLOY="$DRA_POST_DEPLOY"
  local HEALTHCHECK="$DRA_HEALTHCHECK" TIMEOUT="$DRA_TIMEOUT" WAIT="$DRA_WAIT"
  local WAIT_AFTER_HEALTHY="$DRA_WAIT_AFTER_HEALTHY" PRE_STOP_HOOK="$DRA_PRE_STOP_HOOK"
  local ROLLOUT_INSTALL="$DRA_ROLLOUT_INSTALL" ROLLOUT_VERSION="$DRA_ROLLOUT_VERSION"
  split_words COMPOSE_FILES "$DRA_COMPOSE_FILES"
  split_words UP_FLAGS "$DRA_UP_FLAGS"

  echo 'set -euo pipefail'
  declare -p PROJECT_DIR COMPOSE_FILES PROJECT_NAME SERVICES UP_SERVICES UP_FLAGS PULL PRUNE \
    REGISTRY REGISTRY_USERNAME REGISTRY_PASSWORD PRE_DEPLOY POST_DEPLOY HEALTHCHECK TIMEOUT \
    WAIT WAIT_AFTER_HEALTHY PRE_STOP_HOOK ROLLOUT_INSTALL ROLLOUT_VERSION UPLOAD_DESTS UPLOAD_DATA
  cat "$here/remote.sh"
  # stdin of the deploy is detached from this script, so commands like `docker compose run`
  # cannot swallow the rest of the payload.
  echo 'main </dev/null'
}

write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "### 🚀 Docker rollout deploy"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Server | \`$DRA_USER@$DRA_HOST:$DRA_PROJECT_DIR\` |"
    [[ ${#SERVICES[@]} -gt 0 ]] && echo "| Rolled out | \`${SERVICES[*]}\` |"
    [[ ${#UP_SERVICES[@]} -gt 0 ]] && echo "| Updated | \`${UP_SERVICES[*]}\` |"
    echo "| Duration | $1 s |"
  } >>"$GITHUB_STEP_SUMMARY"
}

main() {
  validate
  collect_files
  setup_ssh
  [[ -n "$DRA_REGISTRY_PASSWORD" ]] && printf '::add-mask::%s\n' "$DRA_REGISTRY_PASSWORD"

  local started=$SECONDS
  build_payload | "${ssh_cmd[@]}" bash -s
  write_summary $((SECONDS - started))
}

main
