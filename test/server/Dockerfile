# Disposable "server" for end-to-end tests: sshd + docker CLI talking to the host daemon
# through a mounted socket. A non-root `deploy` user gets access via the socket's group.
FROM docker:29-cli

RUN apk add --no-cache bash curl openssh-server \
    && adduser -D -s /bin/bash deploy \
    && passwd -u deploy \
    && ssh-keygen -A \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' \
        'AllowUsers deploy' >> /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
