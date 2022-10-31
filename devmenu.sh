#!/bin/bash

set -euo pipefail

# Variables
gituser="modem7"
gitrepo="docker-devenv"
gitfolder="Environments"

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

PS3="Choose Option: "
dev_list=($(curl -fks https://api.github.com/repos/$gituser/$gitrepo/contents/$gitfolder | jq '. [] | .name' | tr -d '[]," '))
dev_list_array="${dev_list[*]}"
dev_list_array_pipe="${dev_list_array// /|}"
dev_list+=( "Prune" "Quit" )
echo -e "\nSelect an option:\n"
select dev_name in "${dev_list[@]}"; do
echo -e "\nYou've selected ${GREEN}${dev_name}${END}\n"
lowerdev=$(echo $dev_name | tr '[:upper:]' '[:lower:]')
    eval "case \"$dev_name\" in
      "$dev_list_array_pipe")
          echo "Creating $dev_name Environment"
          docker buildx build --rm=true --build-arg BUILDKIT_INLINE_CACHE=1 --load -t $lowerdev:dev https://github.com/$gituser/$gitrepo.git#:$gitfolder/$dev_name \
          && clear \
          && echo "=========================================" \
          && echo "Activating $dev_name Dev Environment..." \
          && echo "Press CTRL + D or type exit to leave the container" \
          && docker run --rm -it --name "$dev_name"Dev --hostname "$dev_name"Dev "$lowerdev:dev"
          break
          ;;
      "Prune")
          echo "Clearing Docker cache."
          docker system prune -af
          exec bash $0
          ;;
      "Quit")
          echo "Exiting script"
          exit
          ;;
       *) echo "invalid option $REPLY";;
    esac"
done

exit 0
