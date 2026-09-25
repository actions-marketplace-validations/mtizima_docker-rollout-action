# shellcheck shell=bash
# Input variables (PROJECT_DIR, SERVICES, COMPOSE_FILES, …) are declared by src/deploy.sh.
# shellcheck disable=SC2153
# Server side. Not executed directly: src/deploy.sh prepends the input values
# (as `declare` statements) and appends the `main` call, then pipes it into `bash -s`.
# Output goes back to the runner log, so GitHub workflow commands (::group:: etc.) work.

TEMP_DOCKER_CONFIG=""

group() { printf '::group::%s\n' "$*"; }
endgroup() { echo '::endgroup::'; }
warn() { printf '::warning::%s\n' "$*"; }
error() {
  printf '::error::%s\n' "$*"
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DOCKER_CONFIG" ]]; then
    rm -rf -- "$TEMP_DOCKER_CONFIG"
  fi
}

check_prerequisites() {
  command -v docker >/dev/null || error "docker is not installed on the server."
  docker info >/dev/null 2>&1 ||
    error "User '$(id -un)' cannot talk to the Docker daemon (add it to the 'docker' group?)."
  docker compose version >/dev/null 2>&1 || error "Docker Compose v2 plugin (docker compose) is required."
}

upload_files() {
  ((${#UPLOAD_DESTS[@]} > 0)) || return 0
  group "Upload files"
  local i dest
  for i in "${!UPLOAD_DESTS[@]}"; do
    dest="${UPLOAD_DESTS[$i]}"
    mkdir -p -- "$(dirname -- "$dest")"
    printf '%s' "${UPLOAD_DATA[$i]}" | base64 -d >"$dest.dra-tmp"
    mv -f -- "$dest.dra-tmp" "$dest"
    echo "$dest"
  done
  endgroup
}

install_rollout() {
  local plugin_dir="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
  local installed=""
  # Without the plugin `docker rollout --version` prints the Docker version instead of failing.
  installed="$(docker rollout --version 2>/dev/null | grep '^docker-rollout version' || true)"

  if [[ -n "$installed" && "$ROLLOUT_INSTALL" != always ]]; then
    echo "Using $installed"
    return 0
  fi
  [[ "$ROLLOUT_INSTALL" != never ]] || error "docker-rollout is not installed and rollout-install is 'never'."

  group "Install docker-rollout $ROLLOUT_VERSION"
  local url="https://github.com/wowu/docker-rollout/releases/download/$ROLLOUT_VERSION/docker-rollout"
  mkdir -p -- "$plugin_dir"
  if command -v curl >/dev/null; then
    curl -fsSL --retry 3 -o "$plugin_dir/docker-rollout.dra-tmp" "$url"
  elif command -v wget >/dev/null; then
    wget -q -O "$plugin_dir/docker-rollout.dra-tmp" "$url"
  else
    error "curl or wget is required to install docker-rollout."
  fi
  head -n 1 "$plugin_dir/docker-rollout.dra-tmp" | grep -q '^#!' ||
    error "Downloaded docker-rollout from $url is not a script."
  chmod +x "$plugin_dir/docker-rollout.dra-tmp"
  mv -f -- "$plugin_dir/docker-rollout.dra-tmp" "$plugin_dir/docker-rollout"
  docker rollout --version
  endgroup
}

# Logs into the registry using a throwaway DOCKER_CONFIG, so credentials are never
# written to the user's ~/.docker/config.json and disappear right after the deploy.
registry_login() {
  [[ -n "$REGISTRY" ]] || return 0
  group "Log into $REGISTRY"
  local orig="${DOCKER_CONFIG:-$HOME/.docker}"
  TEMP_DOCKER_CONFIG="$(mktemp -d)"
  chmod 700 "$TEMP_DOCKER_CONFIG"
  if [[ -f "$orig/config.json" ]]; then
    cp -- "$orig/config.json" "$TEMP_DOCKER_CONFIG/config.json"
  fi
  local sub
  for sub in cli-plugins contexts; do
    if [[ -d "$orig/$sub" ]]; then
      ln -s -- "$orig/$sub" "$TEMP_DOCKER_CONFIG/$sub"
    fi
  done
  export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
  printf '%s' "$REGISTRY_PASSWORD" |
    docker login "$REGISTRY" --username "$REGISTRY_USERNAME" --password-stdin
  endgroup
}

pull_images() {
  [[ "$PULL" == true ]] || return 0
  group "Pull images"
  docker compose pull --quiet "${SERVICES[@]}" "${UP_SERVICES[@]}"
  endgroup
}

# docker-rollout can only verify readiness through a Docker healthcheck. The check looks at
# the currently running containers: on the first deploy there are none and the rollout is
# a plain `compose up` anyway.
check_healthchecks() {
  [[ "$HEALTHCHECK" != ignore ]] || return 0
  local service id
  for service in "${SERVICES[@]}"; do
    id="$(docker compose ps --quiet "$service" | head -n 1)"
    [[ -n "$id" ]] || continue
    if [[ -z "$(docker inspect --format '{{if .State.Health}}yes{{end}}' "$id")" ]]; then
      local message="Service '$service' has no healthcheck: docker-rollout will just wait ${WAIT}s and switch traffic without knowing whether the new container is ready."
      if [[ "$HEALTHCHECK" == require ]]; then
        error "$message"
      fi
      warn "$message"
    fi
  done
}

run_hook() {
  local name="$1" command="$2"
  [[ -n "$command" ]] || return 0
  group "$name"
  bash -c "$command" </dev/null || error "$name failed."
  endgroup
}

rollout() {
  local service args=(--timeout "$TIMEOUT" --wait "$WAIT" --wait-after-healthy "$WAIT_AFTER_HEALTHY")
  if [[ -n "$PRE_STOP_HOOK" ]]; then
    args+=(--pre-stop-hook "$PRE_STOP_HOOK")
  fi
  for service in "${SERVICES[@]}"; do
    group "Roll out $service"
    docker rollout "${args[@]}" "$service" || error "Rollout of '$service' failed, old containers keep serving."
    endgroup
  done
}

up_services() {
  ((${#UP_SERVICES[@]} > 0)) || return 0
  group "Update ${UP_SERVICES[*]}"
  docker compose up --detach "${UP_FLAGS[@]}" "${UP_SERVICES[@]}"
  endgroup
}

prune_images() {
  [[ "$PRUNE" == true ]] || return 0
  group "Prune dangling images"
  docker image prune --force
  endgroup
}

main() {
  trap cleanup EXIT

  check_prerequisites
  mkdir -p -- "$PROJECT_DIR"
  cd -- "$PROJECT_DIR" || error "Cannot enter $PROJECT_DIR."

  export COMPOSE_PATH_SEPARATOR=:
  if ((${#COMPOSE_FILES[@]} > 0)); then
    COMPOSE_FILE="$(
      IFS=:
      echo "${COMPOSE_FILES[*]}"
    )"
    export COMPOSE_FILE
  fi
  if [[ -n "$PROJECT_NAME" ]]; then
    export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
  fi

  upload_files
  install_rollout
  registry_login
  pull_images
  check_healthchecks
  run_hook "Pre-deploy" "$PRE_DEPLOY"
  rollout
  up_services
  run_hook "Post-deploy" "$POST_DEPLOY"
  prune_images
  echo "✅ Deployed to $(uname -n):$PWD"
}
