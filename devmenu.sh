#!/bin/bash

set -euo pipefail
shopt -s extglob

# Variables
gituser="modem7"
gitrepo="docker-devenv"
gitfolder="Environments"
buildername="DockerDevBuilder"

# Colours
BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BRIGHT=$(tput bold)
NORMAL=$(tput sgr0)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)

# Functions
pfnorm() {
    printf '\n%s' "$1"
}

pf() {
    printf '%s' "$1"
}

pfspc() {
    printf '%s\n' "$1"
}

pfnl() {
    printf '\n%s\n' "$1"
}

pfindent() {
    printf '\n%29s\n' "$1"
}

ctrl_c () {
    pfnl "User pressed Ctrl + C. Exiting script..."
    exit 1
}

tc() {
    set ${*,,} ; echo ${*^} ;
}

pfnorm "========================================="
pfindent "Checking Dependencies"
pfnorm "========================================="
pfnorm "Checking if dependencies are installed..."
pkg_list=(docker-ce jq)
for pkg in "${pkg_list[@]}"
do
  titlecase=$(tc $pkg)
    if dpkg-query -l $pkg > /dev/null 2>&1;
     then
       pfnorm "~ $titlecase is...${GREEN}installed${NORMAL}"
     else
       pfnorm "~ $titlecase is...${RED}not installed${NORMAL}"
       pfnorm "Exiting Script. ${UNDERLINE}Install $pkg.${NORMAL}"
       pfnorm "========================================="
       exit
    fi
done
pfnl "========================================="

cat << "EOF"
      ____             _             
     |  _ \  ___   ___| | _____ _ __ 
     | | | |/ _ \ / __| |/ / _ | `__|
     | |_| | (_) | (__|   |  __| |   
     |____/ \___/ \___|_|\_\___|_|   
=========================================
EOF

# Trap CTRL+C
trap ctrl_c INT

PS3="Choose Option: "
dev_list=($(curl -fks https://api.github.com/repos/$gituser/$gitrepo/contents/$gitfolder | jq '. [] | .name' | tr -d '[]," '))
dev_env_options=${dev_list[0]};
for ((i=1; i<${#dev_list[@]}; i++)); do
        dev_env_options="$dev_env_options|${dev_list[i]}"
done
pfnl "Select an option:"
select dev_name in "${dev_list[@]}" "Prune" "Quit"; do
pfnl "You've selected: ${GREEN}${dev_name}${NORMAL}"
lowerdev=$(echo $dev_name | tr '[:upper:]' '[:lower:]')
    case $dev_name in
      +($dev_env_options))
          pfnorm "Creating buildx builder..."
          if docker buildx create --use --name "$buildername" > /dev/null 2>&1; then
              pfnl "Builder $buildername created..."
            else
              pfnl "Builder already created, using ${buildername}..."
              docker buildx use "$buildername"
          fi
          pfnorm "Creating $dev_name Environment..."
          docker buildx build --rm=true --build-arg BUILDKIT_INLINE_CACHE=1 --load -t $lowerdev:dev https://github.com/$gituser/$gitrepo.git#:$gitfolder/$dev_name
          clear
          pf "========================================="
          pfnorm "Activating $dev_name Dev Environment..."
          pfnl "Press CTRL + D or type exit to leave the container."
          docker run --rm -it --name "$dev_name"Dev"$RANDOM" --hostname "$dev_name"Dev"$RANDOM" "$lowerdev:dev"
          break
          ;;
      "Prune")
          pfnorm "Clearing Docker cache..."
          docker system prune -af
          pfnl  "Removing Docker buildx builder..."
          if docker buildx rm "$buildername" > /dev/null 2>&1; then
              pfnl "Builder $buildername removed."
              pfnl "Going back to choice select..."
            else
              pfnl "Builder already removed, no action performed."
              pfnl "Going back to choice select..."
          fi
          pfnorm "========================================="
          REPLY=
          ;;
      "Quit")
          pfnl "Exiting script..."
          break
          ;;
       *)
          pfnorm "========================================="
          pfnorm "${RED}Invalid option:${NORMAL} \"$REPLY\". Try again."
          pfnl "========================================="
          REPLY=
          ;;
    esac
done

exit 0
