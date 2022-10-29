# syntax = docker/dockerfile:1

FROM python:alpine3.16
LABEL maintainer="modem7"

# Install Environment
RUN <<EOF
    set -xe
    echo -e "Installing Packages..."
    apk add --update \
        acl-dev \
        alpine-sdk \
        attr-dev \
        bash \
        bash-completion \
        bzip2-dev \
        curl \
        docker-bash-completion \
        fuse-dev \
        git \
        htop \
        iftop \
        libffi-dev \
        linux-headers \
        lz4-dev \
        nano \
        ncurses-dev \
        openssl \
        openssl-dev \
        py3-pip \
        py3-pkgconfig \
        py3-setuptools \
        py3-wheel \
        py3-xxhash \
        python3-dev \
        readline-dev \
        sqlite-dev \
        sudo \
        tree \
        tzdata \
        unzip \
        wget \
        xz-dev \
        zlib-dev
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
