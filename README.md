# Docker Dev Environments
[![GitHub latest commit](https://badgen.net/github/last-commit/modem7/docker-devenv)](https://GitHub.com/modem7/docker-devenv/commit/)

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/modem7)

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

# Environments
- [Alpine](https://github.com/modem7/docker-devenv/blob/master/Environments/Alpine/README.md)
- [Alpine_Network_Debug](https://github.com/modem7/docker-devenv/blob/master/Environments/Alpine_Network_Debug/README.md)
- [Alpine_Python](https://github.com/modem7/docker-devenv/blob/master/Environments/Alpine_Python/README.md)
- [Debian](https://github.com/modem7/docker-devenv/blob/master/Environments/Debian/README.md)
- [Ubuntu](https://github.com/modem7/docker-devenv/blob/master/Environments/Ubuntu/README.md)

---

# Usage

## Download and run script:
In your console, run the following commands:

Note: This has only been made for use in Debian/Ubuntu based systems currently.

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
