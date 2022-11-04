#!/bin/bash

set -euo pipefail
shopt -s extglob

# Variables
gituser="modem7"
gitrepo="docker-devenv"
gitfolder="Environments"
buildername="DockerDevBuilder"
failuremsg=""

# Colours
RED="\e[31m"
GREEN="\e[32m"
END="\e[0m"

echo "========================================="
printf "        Checking Dependencies\n"
echo "========================================="
printf "Checking if dependencies are installed...\n"
pkg_list=(docker jq)
tc() { set ${*,,} ; echo ${*^} ; }
for pkg in "${pkg_list[@]}"
do
  titlecase=$(tc $pkg)
  isinstalled=$(dpkg-query -l $pkg > /dev/null 2>&1)
    if [ $? -eq 0 ];
     then
       printf "~ $titlecase is...${GREEN}installed${END}\n"
     else
       printf "~ $titlecase is...${RED}not installed${END}\n"
       printf "Exiting Script. Install $pkg.\n"
       echo "========================================="
       exit
    fi
done
echo "========================================="

cat << "EOF" 
      ____             _             
     |  _ \  ___   ___| | _____ _ __ 
     | | | |/ _ \ / __| |/ / _ | '__|
     | |_| | (_) | (__|   |  __| |   
     |____/ \___/ \___|_|\_\___|_|   
=========================================
EOF

ctrl_c () {
    echo -e "\nUser pressed Ctrl + C. Exiting script...\n"
    exit 1
}

# Trap CTRL+C
trap ctrl_c INT

PS3="Choose Option: "
dev_list=($(curl -fks https://api.github.com/repos/$gituser/$gitrepo/contents/$gitfolder | jq '. [] | .name' | tr -d '[]," '))
dev_env_options=${dev_list[0]};
for ((i=1; i<${#dev_list[@]}; i++)); do
        dev_env_options="$dev_env_options|${dev_list[i]}"
done
echo -e "\nSelect an option:\n"
select dev_name in "${dev_list[@]}" "Prune" "Quit"; do
echo -e "\nYou've selected ${GREEN}${dev_name}${END}\n"
lowerdev=$(echo $dev_name | tr '[:upper:]' '[:lower:]')
    case $dev_name in
      +($dev_env_options))
          echo "Creating buildx builder..."
          if docker buildx create --use --name "$buildername" > /dev/null 2>&1; then
              echo -e "\nBuilder $buildername created..."
            else
              echo -e "Builder already created, using "$buildername"...\n"
              docker buildx use "$buildername"
          fi
          echo "Creating $dev_name Environment..."
          docker buildx build --rm=true --build-arg BUILDKIT_INLINE_CACHE=1 --load -t $lowerdev:dev https://github.com/$gituser/$gitrepo.git#:$gitfolder/$dev_name
          clear
          echo "========================================="
          echo "Activating $dev_name Dev Environment..."
          echo "Press CTRL + D or type exit to leave the container"
          docker run --rm -it --name "$dev_name"Dev"$RANDOM" --hostname "$dev_name"Dev"$RANDOM" "$lowerdev:dev" & dockerrun_pid=$!
          break
          ;;
      "Prune")
          echo "Clearing Docker cache..."
          docker system prune -af
          echo -e "\nRemoving Docker buildx builder..."
          if docker buildx rm "$buildername" > /dev/null 2>&1; then
              echo -e "\nBuilder $buildername removed"
            else
              echo -e "Builder already removed, no action performed\n"
          fi
          exec bash $0
          ;;
      "Quit")
          echo "Exiting script..."
          break
          ;;
       *)
          echo "Invalid option $REPLY"
          exec bash $0
          ;;
    esac
done

exit 0
