# syntax = docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

FROM alpine:edge@sha256:9a341ff2287c54b86425cbee0141114d811ae69d88a36019087be6d896cef241
LABEL maintainer="modem7"

COPY --link requirements.txt /requirements.txt

# Install Environment
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    <<EOF
    set -xe
    ln -vs /var/cache/apk /etc/apk/cache
    echo -e "Installing Packages..."
    sed 's/#.*//' /requirements.txt | xargs apk add --update
EOF

# Set Bash environment
RUN <<EOF
    set -xe
    sed -e 's;/bin/ash$;/bin/bash;g' -i /etc/passwd
    cat <<FIRST > ~/.bashrc
    PS1="\[\e[1;32m\]\u@\h:\[\e[0m\]\w\[\e[1;32m\]$ \[\e[0m\]"
FIRST
    cat <<SECOND >> ~/.profile
    if [ "\${SHELL}x" = "/bin/bashx" ]; then
      if [ -f "\${HOME}/.bashrc" ]; then
        . "\${HOME}/.bashrc"
      fi
    fi
SECOND
EOF

CMD [ "/bin/bash" ]
