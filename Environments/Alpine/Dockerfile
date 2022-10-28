# syntax = docker/dockerfile:1

FROM alpine:edge
LABEL maintainer="modem7"

# Install Environment
RUN <<EOF
    set -xe
    echo -e "Installing Packages..."
    apk add --no-cache \
        tzdata \
        curl \
        wget \
        git \
        bash \
        openssl \
        unzip \
        sudo \
        docker-bash-completion \
        htop \
        iftop \
        nano \
        bash-completion
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
