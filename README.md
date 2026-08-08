# Docker Dev Environments
[![CI](https://github.com/modem7/docker-devenv/actions/workflows/ci.yml/badge.svg)](https://github.com/modem7/docker-devenv/actions/workflows/ci.yml)
[![Publish Images](https://github.com/modem7/docker-devenv/actions/workflows/publish.yml/badge.svg)](https://github.com/modem7/docker-devenv/actions/workflows/publish.yml)
[![GitHub latest commit](https://badgen.net/github/last-commit/modem7/docker-devenv)](https://GitHub.com/modem7/docker-devenv/commit/)

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/modem7)

---

# Purpose

Quickly spin up a disposable, Docker-based dev environment with the tools
you need — no manual setup, no polluting your host machine. Pick an
environment, get a shell (or a VS Code Dev Container), do your work in a
persistent local folder, and throw the container away when you're done.

Works for anyone: no personal configuration is baked in anywhere in this
repo.

---

# Requirements

- **Docker** — [install instructions](https://docs.docker.com/engine/install/) (Linux/macOS) or [Docker Desktop](https://docs.docker.com/desktop/) (Windows/macOS)
- **jq** — `sudo apt-get install jq` / `brew install jq` / `winget install jqlang.jq`
- **fzf** — `sudo apt-get install fzf` / `brew install fzf` / `winget install fzf`

---

# Quickstart

Clone the repo first — the menu scripts read the `Environments/` folder
locally and need a real checkout (this is also what makes customization and
persistent workspaces possible):

```bash
git clone https://github.com/modem7/docker-devenv.git
cd docker-devenv
```

**Linux / macOS:**
```bash
./devmenu.sh
```

**Windows (PowerShell, no WSL required):**
```powershell
.\devmenu.ps1
```

Pick an environment, choose **pull** (fast, prebuilt) or **build**
(local Dockerfile + any customizations), pick a workspace folder to persist
your work in, and you're in a shell.

---

# Environments

| Environment | Base | Description |
|---|---|---|
| [Alpine](Environments/Alpine/README.md) | `alpine:edge` | Minimal general-purpose environment |
| [Alpine_Python](Environments/Alpine_Python/README.md) | `python:alpine3.17` | Alpine + Python dev toolchain |
| [Debian](Environments/Debian/README.md) | `debian` | General-purpose, apt-based |
| [Ubuntu](Environments/Ubuntu/README.md) | `ubuntu` | General-purpose, apt-based |
| [NodeJS](Environments/NodeJS/README.md) | `node:lts-bookworm` | Node.js LTS |
| [Go](Environments/Go/README.md) | `golang:bookworm` | Go toolchain |
| [Rust](Environments/Rust/README.md) | `rust:bookworm` | Rust + cargo |
| [NetworkTools](Environments/NetworkTools/README.md) | — | Passthrough to [`nicolaka/netshoot`](https://github.com/nicolaka/netshoot) for network troubleshooting |

---

# Customizing a container

Drop extra packages into `Environments/<Name>/requirements.local.txt` (one
per line, `#` for comments — same format as the tracked `requirements.txt`)
and choose **build** instead of **pull** in the menu. This file is
gitignored, so your customizations stay local. Doesn't apply to
`NetworkTools` (it's a passthrough to an upstream image, nothing to build).

---

# Persistent workspace

Every run mounts a host folder to `/workspace` inside the container, so
your work survives the container being removed. The menu prompts for a
path (default: `./workspace/<environment>`), or set `DEVMENU_WORKSPACE`
(`devmenu.sh`) to skip the prompt.

---

# Using as a VS Code Dev Container

Each `Environments/<Name>/` folder includes a `.devcontainer/devcontainer.json`.
This repo is a utility repo, not something you develop inside directly — to
use an environment as a Dev Container for your own project, copy that
environment's folder (Dockerfile + `.devcontainer/`, or just `.devcontainer/`
for `NetworkTools`) into your project, then use VS Code's
**Dev Containers: Reopen in Container**.

---

# How it works

- **Pull** downloads a prebuilt multi-arch (`amd64`/`arm64`) image from
  `ghcr.io/modem7/docker-devenv-<environment>` — published by CI on every
  merge to `master` and refreshed weekly to pick up upstream security
  patches.
- **Build** builds from the local Dockerfile, including anything in your
  `requirements.local.txt`.
- Every pull request runs CI: each environment's Dockerfile builds and is
  linted with hadolint, `devmenu.sh` is shellchecked and unit-tested with
  bats-core, and `devmenu.ps1` is linted with PSScriptAnalyzer.

---

# Screenshot
<img width="1208" height="569" alt="image" src="https://github.com/user-attachments/assets/fc339c08-fa9a-41e4-acb8-fa7fd85f6f87" />
