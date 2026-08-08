# syntax = docker/dockerfile:1

FROM python:alpine
LABEL maintainer="modem7"

ARG EXTRA_PACKAGES=""

COPY --link requirements.txt /requirements.txt

# hadolint ignore=DL4006
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    <<EOF
    set -xe
    ln -vs /var/cache/apk /etc/apk/cache
    echo "Installing Packages..."
    sed 's/#.*//' /requirements.txt | xargs apk add --update $EXTRA_PACKAGES
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

WORKDIR /workspace

CMD [ "/bin/bash" ]
