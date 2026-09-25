#!/bin/sh
set -eu

# Give `deploy` access to the mounted Docker socket without touching its permissions.
gid="$(stat -c %g /var/run/docker.sock)"
group="$(getent group "$gid" | cut -d: -f1 || true)"
if [ -z "$group" ]; then
  group=dockerhost
  addgroup -g "$gid" "$group"
fi
addgroup deploy "$group"

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
printf '%s\n' "$AUTHORIZED_KEY" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

exec /usr/sbin/sshd -D -e
