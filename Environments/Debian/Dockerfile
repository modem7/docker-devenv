# syntax = docker/dockerfile:1

FROM debian
LABEL maintainer="modem7"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ="Europe/London"
ARG EXTRA_PACKAGES=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --link requirements.txt /requirements.txt

# Discover an apt proxy automatically, if one exists on the build host's
# network. Falls back to direct downloads otherwise.
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    apt-get update
    apt-get -y install --no-install-recommends auto-apt-proxy
EOF

# Install Environment
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    rm -fv /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    echo "$TZ" > /etc/timezone
    sed 's/#.*//' /requirements.txt | xargs apt-get -y install --no-install-recommends $EXTRA_PACKAGES
EOF

# Set Bash environment
RUN <<EOF
    set -xe
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
