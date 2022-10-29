# syntax = docker/dockerfile:1

FROM ubuntu
LABEL maintainer="modem7"

ENV DEBIAN_FRONTEND=noninteractive
ARG APTIP="192.168.0.254"
ARG APTPORT="3142"
ARG APTFILE="/etc/apt/apt.conf.d/00proxy"
ENV TZ="Europe/London"

SHELL ["/bin/bash", "-c"]

COPY requirements.txt /requirements.txt

# Setup Apt-Cacher-NG if it exists
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -x
    apt-get update
    apt-get -y install netcat
    nc -z -w1 $APTIP $APTPORT
    if [ $? == 0 ]; then
      echo "Apt-Cacher-NG found. Applying settings"
      tee $APTFILE << APTEOF
      Acquire {
       HTTP::proxy "http://$APTIP:$APTPORT";
       HTTPS::proxy "http://$APTIP:$APTPORT";
      }
APTEOF
    else
        echo "Apt-Cacher-NG not found. Not applying settings"
    fi
EOF

# Install Environment
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    rm -fv /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    echo "$TZ" > /etc/timezone
    sed 's/#.*//' /requirements.txt | xargs apt-get -y install --no-install-recommends
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