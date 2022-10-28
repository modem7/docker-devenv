# Docker Dev Environments
[![GitHub latest commit](https://badgen.net/github/last-commit/modem7/docker-devenv)](https://GitHub.com/modem7/docker-devenv/commit/)

---

# Purpose
This repo is to quickly create ephemeral Docker based Development environments with everything that you may require.

If you need a customised environment, please fork this repo, customise as you wish and update the relevant script locations to your repo.

---

# Requirements
- Docker
- Curl
- JQ

---

# Usage

## *WARNING*: Do not run arbitrary scripts without checking them first:
Please have a look over the [script](https://github.com/modem7/docker-devenv/blob/master/devmenu.sh) prior to running and make sure you're comfortable with it. 

## Run the following in your console:

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
