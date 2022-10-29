# Docker Dev Environments
[![GitHub latest commit](https://badgen.net/github/last-commit/modem7/docker-devenv)](https://GitHub.com/modem7/docker-devenv/commit/)

---

# Purpose
This repo is to quickly create ephemeral Docker based Development environments with everything that you may require.

If you need a customised environment, please fork this repo, customise as you wish and update the relevant script locations to your repo.

---

# Requirements
- Docker ([install instructions](https://docs.docker.com/engine/install/))
- Curl (`apt-get install curl`)
- JQ (`apt-get install jq`)

---

# Usage

## Script Outcome:
When you run the script, it will grab a list of available environment from the Github repo (Environments can be found [here](https://github.com/modem7/docker-devenv/tree/master/Environments)).

When you choose one of the Environment options (e.g Alpine, Ubuntu etc), the script will build the Dockerfile located inside the environment folder in the repo, and then it'll run the dev container using the built image. 

### High level script workflow:
- Script downloaded
- Dev Env option selected
- - Build command run `DOCKER_BUILDKIT=1 docker build -t $lowerdev:dev https://github.com/$gituser/$gitrepo.git -f /Environments/$dev_name/Dockerfile`
- - Container start command run `docker run --rm -it --name "$dev_name"Dev --hostname "$dev_name"Dev "$lowerdev:dev"`
- Dev Container starts up ready to use

---

## *WARNING*: Do not run arbitrary scripts without checking them first:
Please have a look over the [script](https://github.com/modem7/docker-devenv/blob/master/devmenu.sh) prior to running and make sure you're comfortable with it. 

## Download and run script:
In your console, run the following commands:

Note: This has only been made for use in Debian based systems currently.

curl:
```
curl -s https://raw.githubusercontent.com/modem7/docker-devenv/master/devmenu.sh > /tmp/devmenu.sh && bash /tmp/devmenu.sh
```

If you use SSH to your Docker server via Windows Terminal/Powershell:
```
ssh -t user@ip "curl -sk https://raw.githubusercontent.com/modem7/docker-devenv/master/devmenu.sh > /tmp/devmenu.sh && bash /tmp/devmenu.sh"
```

Choose the appropriate option to generate your dev environment. 

---

# Screenshot
![image](https://user-images.githubusercontent.com/4349962/198807913-eefcc8ae-8e20-42a3-8879-44adb4795bcf.png)
