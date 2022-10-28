#!/bin/bash

gituser="modem7"
gitrepo="docker-devenv"
gitfolder="Environments"

printf "\nChecking if dependencies are installed...\n"
pkg_list=(docker jq)
tc() { set ${*,,} ; echo ${*^} ; }
for pkg in "${pkg_list[@]}"
do
  titlecase=$(tc $pkg)
  isinstalled=$(dpkg-query -l $pkg > /dev/null 2>&1)
    if [ $? -eq 0 ];
     then
       printf "$titlecase is installed\n"
     else
       printf "\n$titlecase is not installed...Exiting Script\n"
       exit
    fi
done

PS3='Choose Option: '
dev_list=$(curl -ks https://api.github.com/repos/$gituser/$gitrepo/contents/$gitfolder | jq --raw-output 'map(.name)| .[]')
dev_list+=" Prune"
dev_list+=" Quit"
echo -e "\nSelect which Dev environment you want:\n"
select dev_name in ${dev_list}; do
echo -e "\nYou've selected ${dev_name}\n"
lowerdev=$(echo $dev_name | tr '[:upper:]' '[:lower:]')
    case $dev_name in
      "$dev_name")
          echo "Creating $dev_name Environment"
          DOCKER_BUILDKIT=1 docker build -t $lowerdev:dev https://github.com/$gituser/$gitrepo.git -f /Environments/$dev_name/Dockerfile
          docker run --rm -it --name "$dev_name"Dev --hostname "$dev_name"Dev "$lowerdev:dev"
          break
          ;;
      "Prune")
          echo "Clearing Docker cache."
          docker system prune -af
          break
          ;;
	  "Quit")
	    echo "Exiting script"
	    exit
	    ;;
        *) echo "invalid option $REPLY";;
    esac
done

exit 0
