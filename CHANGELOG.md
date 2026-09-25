# Changelog

## v1.0.0

First release.

- Zero-downtime rollout of Compose services over SSH with docker-rollout.
- File upload, registry login with an ephemeral Docker config, image pull.
- `pre-deploy` / `post-deploy` hooks, `up-services` for services that can't be rolled out.
- Healthcheck policy (`warn` / `require` / `ignore`), connection draining via `pre-stop-hook`.
- Automatic installation of the docker-rollout plugin on the server.
- End-to-end tests under load: zero failed requests on deploy and on rollback of a broken release.
