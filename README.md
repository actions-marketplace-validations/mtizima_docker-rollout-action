# Docker Rollout Deploy

[![Test](https://github.com/mtizima/docker-rollout-action/actions/workflows/test.yml/badge.svg)](https://github.com/mtizima/docker-rollout-action/actions/workflows/test.yml)

Zero-downtime deploys of Docker Compose services to your own server, straight from GitHub Actions.

The action connects over SSH, uploads your compose/env files, pulls images, runs migrations and
updates services with [docker-rollout](https://github.com/wowu/docker-rollout): the new container
is started next to the old one, and the old one is removed only after the new one is healthy.
A release that fails its healthcheck is rolled back automatically. The old containers keep
serving traffic the whole time.

No Kubernetes, no Swarm, no agents on the server. You need Docker, a reverse proxy
(Traefik, nginx-proxy, Caddy…) and SSH access.

```yaml
- uses: mtizima/docker-rollout-action@v1
  with:
    host: ${{ secrets.SSH_HOST }}
    user: deploy
    ssh-key: ${{ secrets.SSH_KEY }}
    known-hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
    project-dir: /opt/myapp
    services: web
```

## Features

- **Zero downtime**, verified in CI: every change is deployed under constant load and the
  test fails if a single request fails.
- **Automatic rollback**: if the new containers never become healthy, they are removed and the
  old ones keep running. The step fails, so you get notified.
- **Migrations**: `pre-deploy` runs after the pull and before the switch, and a failure aborts the deploy.
- **Handles the whole stack**: services with `container_name`/`ports` (workers, databases,
  the proxy itself) are updated with a regular `docker compose up -d`.
- **Secure by default**: the host key is pinned, secrets are never put on a command line, and
  registry credentials live in a temporary `DOCKER_CONFIG` that is deleted after the deploy.
- **One SSH session**, plain Bash, no Node.js, nothing to install on the runner. The
  docker-rollout plugin is installed on the server automatically if it is missing.
- Readable logs: every stage is a collapsible group, and the job summary shows what was deployed.

## Full example

Build images in the workflow, then deploy with migrations:

```yaml
name: Deploy

on:
  push:
    branches: [main]

concurrency:
  group: deploy-production
  cancel-in-progress: false

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v5

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v7
        with:
          push: true
          tags: ghcr.io/${{ github.repository }}:latest

      - uses: mtizima/docker-rollout-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          user: ${{ secrets.SSH_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          known-hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
          project-dir: /opt/myapp
          # local path : path on the server (relative to project-dir)
          files: |
            deploy/compose.prod.yml:compose.yml
          registry: ghcr.io
          registry-username: ${{ github.actor }}
          registry-password: ${{ secrets.GITHUB_TOKEN }}
          pre-deploy: docker compose run --rm web ./manage.py migrate
          services: web
          up-services: worker redis
          up-flags: --remove-orphans
          pre-stop-hook: touch /tmp/drain && sleep 10
          healthcheck: require
```

## What happens on the server

All steps run in one SSH session inside `project-dir`:

1. Upload `files`.
2. Install the docker-rollout plugin if it is missing.
3. Log into `registry` (credentials go to a temporary Docker config).
4. `docker compose pull` for `services` and `up-services`.
5. Check that `services` have a healthcheck (see `healthcheck`).
6. Run `pre-deploy`.
7. `docker rollout <service>` for each of `services`, one by one.
8. `docker compose up -d` for `up-services`.
9. Run `post-deploy`, and `docker image prune -f` if `prune` is enabled.

Any failure stops the deploy and fails the step.

## Inputs

| Input | Default | Description |
|---|---|---|
| `host` | **required** | SSH host. |
| `port` | `22` | SSH port. |
| `user` | **required** | SSH user. Must be able to run `docker` without sudo. |
| `ssh-key` | **required** | Private SSH key without a passphrase. |
| `known-hosts` | | known_hosts line(s) of the server: `ssh-keyscan -p <port> <host>`. If empty, the key is fetched at runtime (TOFU) with a warning. |
| `project-dir` | **required** | Compose project directory on the server. Created if missing. |
| `files` | | Files to upload, one per line: `local` or `local:remote`. |
| `compose-files` | | Compose files on the server, whitespace-separated. Exported as `COMPOSE_FILE`, so hooks see them too. |
| `project-name` | | Compose project name (`COMPOSE_PROJECT_NAME`). |
| `services` | | Services to roll out with zero downtime, in order. |
| `up-services` | | Services to update with `docker compose up -d` after the rollout. |
| `up-flags` | | Extra flags for `docker compose up -d`, e.g. `--remove-orphans`. |
| `pull` | `true` | Pull images of `services` and `up-services` first. |
| `registry` | | Registry to log into on the server, e.g. `ghcr.io`. |
| `registry-username` | | Registry username. |
| `registry-password` | | Registry password or token. |
| `pre-deploy` | | Shell command run before the rollout, e.g. migrations. |
| `post-deploy` | | Shell command run after a successful deploy. |
| `healthcheck` | `warn` | Rolled-out service without a healthcheck: `warn`, `require` (fail) or `ignore`. |
| `timeout` | `60` | Seconds to wait for new containers to become healthy. |
| `wait` | `10` | Seconds to wait when there is no healthcheck. |
| `wait-after-healthy` | `0` | Extra seconds to wait after the new containers are healthy. |
| `pre-stop-hook` | | Command run in old containers before stopping them (connection draining). |
| `rollout-install` | `if-missing` | Install docker-rollout on the server: `if-missing`, `always`, `never`. |
| `rollout-version` | `v0.14` | docker-rollout release to install. |
| `prune` | `false` | Remove dangling images after the deploy. |

At least one of `services` and `up-services` must be set.

## Requirements

**Server:** Docker with the Compose v2 plugin, `bash` 4.4+, `curl` or `wget` (only to install
docker-rollout), and an SSH user in the `docker` group.

**Runner:** any Linux runner with `ssh` and `base64` (e.g. `ubuntu-latest`).

**Services in `services`** (docker-rollout limitations):

- no `container_name` and no published `ports`, because two containers of the service run side by side
  during the deploy. Put a reverse proxy in front and route to the service through it;
- a Docker **healthcheck**. Without one, docker-rollout only waits `wait` seconds and cannot know
  whether the new container is ready to take traffic.

## Truly zero downtime: connection draining

A healthcheck makes sure traffic goes to the new container only once it is ready. The old
container still needs to be taken out of the proxy **before** it stops. Otherwise requests
in flight at that moment fail. Our own tests show this: without draining, every deploy dropped
a few requests with `502`. With draining, zero requests were dropped.

Make the healthcheck fail while `/tmp/drain` exists:

```yaml
services:
  web:
    image: ghcr.io/me/web:latest
    healthcheck:
      test: test ! -f /tmp/drain && curl -fsS http://localhost:8000/health
      interval: 5s
      retries: 1
    labels:
      traefik.enable: "true"
      traefik.http.routers.web.rule: Host(`example.com`)
```

and deploy with:

```yaml
    pre-stop-hook: touch /tmp/drain && sleep 10
```

The `sleep` must be longer than `interval × retries` plus the time needed to finish open requests.
See the [docker-rollout docs](https://docker-rollout.wowu.dev/container-draining) for details.

## Security notes

- Always set `known-hosts`. Get the value once from a trusted machine:
  `ssh-keyscan -p 22 your.server` → save it as the `SSH_KNOWN_HOSTS` secret.
- Use a dedicated deploy user and key. Note that membership in the `docker` group is
  root-equivalent on that server.
- Input values are sent to the server in the SSH session's stdin, never as command-line
  arguments, so they don't show up in `ps` on either side. `registry-password` is masked
  in the logs.

## Testing

`test/run-local.sh` spins up a throwaway SSH "server" container, a password-protected registry and
Traefik on your local Docker, then runs the scenarios: first deploy, deploy under load (must drop
zero requests), a broken release (must fail, roll back and still drop zero requests), side effects
(no credentials left behind, etc.) and input validation. CI runs the same scenarios through the
real action.

```bash
bash test/run-local.sh
```

## License

[MIT](LICENSE). docker-rollout itself is © Karol Musur, MIT.
