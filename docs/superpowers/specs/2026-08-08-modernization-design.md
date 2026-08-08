# Docker Dev Environments Modernization — Design

Date: 2026-08-08

## Goals

- Make the repo usable by any stranger who finds it on GitHub, not just modem7's homelab.
- Add real CI: verify every environment actually builds, lint Dockerfiles and the menu script.
- Publish prebuilt images so users don't have to build from source every time (scalability).
- Modernize the menu script's UX (fzf-based selection) and fix its host-dependency check.
- Let users add packages to a container without forking the repo.
- Give users a persistent local workspace that survives the container being removed.
- Replace the hardcoded Apt-Cacher-NG IP with automatic proxy discovery (`auto-apt-proxy`).
- Rewrite the README for a first-time visitor.

## Non-goals

- Adding new environments beyond the current 5 (Alpine, Alpine_Network_Debug, Alpine_Python, Debian, Ubuntu).
- A compiled CLI (Go/Python). Bash + fzf was chosen to keep the tool dependency-light and auditable.
- VS Code `devcontainer.json` / Dev Containers spec integration.
- Native Windows support beyond what Docker Desktop + WSL already provide (matches the project's existing Debian/Ubuntu-host assumption).
- A devmenu.sh unit test suite — it's a thin orchestration layer over docker/fzf; CI's build/lint checks cover the real risk surface.

## Current state (for reference)

- `devmenu.sh` lists environments via a live GitHub API call, builds each one straight from the GitHub URL as remote build context (`docker buildx build ... https://github.com/...#:Environments/$name`), and runs it `--rm -it` with no volumes.
- Host dependency check uses `dpkg-query -l docker-ce jq`, which is Debian/Ubuntu-`apt`-specific and breaks for anyone who installed Docker via Docker Desktop, snap, or any non-dpkg-tracked method.
- `Environments/Debian` and `Environments/Ubuntu` Dockerfiles hardcode `192.168.0.254:3142` and netcat-probe it to decide whether to configure an apt proxy — a private homelab detail baked into a public repo.
- No CI beyond an issue/PR auto-assign workflow. Nothing verifies the Dockerfiles build or that devmenu.sh is valid.
- README tells users to fork the repo to customize anything.

## Repository layout (target)

```
docker-devenv/
├── devmenu.sh
├── Environments/
│   └── <Name>/
│       ├── Dockerfile
│       ├── requirements.txt          # base packages, tracked
│       ├── requirements.local.txt    # optional, gitignored, user additions
│       └── README.md
├── workspace/                        # gitignored, bind-mount root, one subdir per env
├── .github/workflows/
│   ├── ci.yml                        # build+lint verification, PR/push
│   ├── publish.yml                   # multi-arch build+push to GHCR, merge to master + weekly cron
│   └── autoassign.yml                # unchanged
├── .gitignore                        # new: workspace/, requirements.local.txt
└── README.md                         # rewritten
```

## devmenu.sh (rewrite)

- **Dependency check**: replace `dpkg-query -l docker-ce jq` with `command -v docker`, `command -v jq`, `command -v fzf`. This is a real portability bug fix, not just a style change — the old check fails for any Docker install that isn't apt-tracked.
- **Requires running from inside a local clone**: check for `./Environments`; if missing, print the exact `git clone https://github.com/modem7/docker-devenv.git` command and exit. This trade-off (losing the one-line curl flow) is what makes local override files and persistent volumes possible.
- **Listing environments**: read `Environments/*` directories locally instead of hitting the GitHub API — instant, works offline once cloned.
- **Selection UX**: fzf for the environment list (fuzzy search replaces the numbered `select` menu). After picking an environment, a second fzf prompt: **Pull prebuilt (fast)** [default] vs **Build locally (customize)**.
  - Pull path: `docker pull ghcr.io/modem7/docker-devenv-<env-slug>:latest`, where `<env-slug>` is the environment folder name lowercased with underscores converted to hyphens (e.g. `Alpine_Network_Debug` → `alpine-network-debug`).
  - Build path: if `Environments/<Name>/requirements.local.txt` exists, read it (same comment-stripping as `requirements.txt`), pass its contents as `--build-arg EXTRA_PACKAGES="..."`; build from the local Dockerfile using the existing buildx-builder pattern (local context now, not a remote git URL).
- **Workspace prompt**: ask for a host path, default `./workspace/<env-slug>`; `mkdir -p` it if missing; empty input accepts the default.
- **Run**: `docker run --rm -it -v "<workspace>":/workspace --name "<Name>Dev$RANDOM" --hostname "<Name>Dev$RANDOM" <image>` — image already has `WORKDIR /workspace` so the shell opens there.
- **Prune / Quit**: unchanged behavior (system prune + remove buildx builder / clean exit). Ctrl+C trap unchanged.

## Dockerfiles

- All 5 environments gain:
  - `ARG EXTRA_PACKAGES=""`, appended to the existing package-install command (`apk add` / `apt-get install`).
  - `WORKDIR /workspace` (also ensures the mount point exists in the image).
- Debian and Ubuntu additionally:
  - **Remove** the `APTIP`/`APTPORT`/`APTFILE` build args and the netcat-probe-and-write-apt-conf block entirely.
  - Install `auto-apt-proxy` as an early step (before the main package install) so apt-get transparently uses whatever proxy it discovers on the build host's network (via avahi/well-known-address probing), or goes direct if none is found. Zero configuration, works on any user's LAN, no personal IP baked into a public Dockerfile.
- Alpine-based environments (Alpine, Alpine_Network_Debug, Alpine_Python): no proxy-discovery equivalent needed/requested; only the `EXTRA_PACKAGES` arg and `WORKDIR` change apply.

## CI — `ci.yml` (verification: PR + push to master)

- `discover` job: lists `Environments/*` subdirectories, emits a JSON matrix.
- `build-test` job (matrix over discovered environments): `docker buildx build` each Dockerfile using its local directory as context (no push) to confirm it builds cleanly; run `hadolint` against each Dockerfile.
- `shellcheck` job: run shellcheck against `devmenu.sh`.
- All three are required PR status checks.

## CI — `publish.yml` (registry publish: merge to master + weekly cron)

- Trigger: `push` to `master` filtered to `Environments/**` changes, plus a weekly `schedule` cron (picks up upstream base-image security patches even with no repo changes).
- Matrix over discovered environments; multi-arch build (`linux/amd64`, `linux/arm64` via buildx+QEMU) and push to `ghcr.io/modem7/docker-devenv-<env-slug>:latest` and `:<short-sha>`.
- Uses the workflow's built-in `GITHUB_TOKEN` with `packages: write` permission — no extra secrets to manage.

## README rewrite

Sections, in order: plain-English purpose statement for a first-time visitor → requirements with per-OS install one-liners (Docker, jq, fzf) → quickstart (`git clone` + `cd` + `./devmenu.sh`, replacing the old curl\|bash instructions) → environment table (name, one-line description, link to per-env README) → "Customizing a container" (how `requirements.local.txt` works) → "Persistent workspace" (how the volume prompt/mount works) → "How it works" (pull vs. build, CI/publish pipeline, build-status + published-image badges) → license and buymeacoffee links kept as-is.

## Data flow

`./devmenu.sh` (run from inside a clone) → dependency check (docker/jq/fzf) → fzf-select environment → fzf-select Pull/Build → \[Pull: `docker pull ghcr.io/...`] or \[Build: read optional `requirements.local.txt` → `docker buildx build` locally] → prompt workspace path → `mkdir -p` if needed → `docker run -v <workspace>:/workspace --rm -it <image>` → shell opens in `/workspace` → on exit, container is removed (`--rm`); workspace contents persist on host; image (pulled or built) stays cached locally for next run.

## Error handling

- Missing dependency (docker/jq/fzf): name the exact tool + a one-line install hint, exit non-zero.
- Not run from inside a repo clone: print the `git clone` command, exit non-zero.
- Docker daemon unreachable: surface Docker's own error text, don't swallow it.
- Build failure: `set -euo pipefail` already in place; let Docker's error propagate, exit non-zero, no silent retry.
- GHCR pull failure (offline/rate-limited/image not yet published): print a message suggesting the "Build locally" option instead of crashing.
- Ctrl+C: existing trap/cleanup behavior retained.

## Testing

- CI's `build-test` (per-environment Docker build) is the primary regression test — every Dockerfile must build clean on every PR.
- `hadolint` catches Dockerfile anti-patterns (missing pinned versions, etc.) as they're introduced.
- `shellcheck` catches devmenu.sh bugs before merge.
- No devmenu.sh unit test suite (see Non-goals) — the meaningful risk surface (does it build, is the bash valid) is covered above.
- Manual end-to-end smoke test (pull path, build path, workspace mount) for each of the 5 environments, done once during implementation before considering the work complete.
