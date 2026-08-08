# Docker Dev Environments Modernization — Design

Date: 2026-08-08

## Goals

- Make the repo usable by any stranger who finds it on GitHub, not just modem7's homelab.
- Add real CI: verify every buildable environment actually builds, lint Dockerfiles, the bash menu, and the PowerShell menu.
- Publish prebuilt images so users don't have to build from source every time (scalability).
- Modernize the menu script's UX (fzf-based selection) and fix its host-dependency check.
- Let users add packages to a container without forking the repo.
- Give users a persistent local workspace that survives the container being removed.
- Replace the hardcoded Apt-Cacher-NG IP with automatic proxy discovery (`auto-apt-proxy`).
- Rewrite the README for a first-time visitor.
- Add VS Code Dev Containers (`devcontainer.json`) support, one per environment, so any of these environments can be dropped into a user's own project.
- Add native Windows support via a `devmenu.ps1` PowerShell port — no WSL required, just Docker Desktop.
- Add a `bats-core` unit test suite covering devmenu.sh's pure logic (slug conversion, requirements parsing, external-image detection).
- Expand the environment catalog to match what's actually popular for dev containers today: add Node.js, Go, and Rust; replace the bespoke `Alpine_Network_Debug` environment with a thin wrapper around `nicolaka/netshoot` (the de facto standard network-troubleshooting image) instead of maintaining a competing package list.

## Non-goals

- A compiled CLI (Go/Python) replacing the shell scripts. Bash + fzf (and a PowerShell equivalent for Windows) was chosen to keep both dependency-light and auditable.
- A Pester test suite for devmenu.ps1. It's lint-checked (PSScriptAnalyzer) and covered by the same manual smoke test as devmenu.sh; a full parallel unit-test framework for the Windows port is out of scope for this pass.
- Any environment maintenance/package curation for `NetworkTools` — it's a passthrough to the upstream `nicolaka/netshoot` image, not something this repo builds or publishes itself.
- Any other new environments beyond Node.js, Go, and Rust (e.g. .NET, Java) — can be added later following the same template once this lands.

## Current state (for reference)

- `devmenu.sh` lists environments via a live GitHub API call, builds each one straight from the GitHub URL as remote build context (`docker buildx build ... https://github.com/...#:Environments/$name`), and runs it `--rm -it` with no volumes.
- Host dependency check uses `dpkg-query -l docker-ce jq`, which is Debian/Ubuntu-`apt`-specific and breaks for anyone who installed Docker via Docker Desktop, snap, or any non-dpkg-tracked method.
- `Environments/Debian` and `Environments/Ubuntu` Dockerfiles hardcode `192.168.0.254:3142` and netcat-probe it to decide whether to configure an apt proxy — a private homelab detail baked into a public repo.
- `Environments/Alpine_Network_Debug` is a hand-maintained package list on Alpine for network troubleshooting, duplicating what `nicolaka/netshoot` already does as a widely-used standard.
- No CI beyond an issue/PR auto-assign workflow. Nothing verifies the Dockerfiles build or that devmenu.sh is valid.
- README tells users to fork the repo to customize anything.
- No Windows-native path, no devcontainer.json, no test suite.

## Environment catalog (target)

| Folder | Base | Kind |
|---|---|---|
| `Alpine` | `alpine:edge` | Dockerfile (apk) |
| `Alpine_Python` | `python:alpine3.17` | Dockerfile (apk) |
| `Debian` | `debian` | Dockerfile (apt + auto-apt-proxy) |
| `Ubuntu` | `ubuntu` | Dockerfile (apt + auto-apt-proxy) |
| `NodeJS` | `node:lts-bookworm` | Dockerfile (apt + auto-apt-proxy) |
| `Go` | `golang:bookworm` | Dockerfile (apt + auto-apt-proxy) |
| `Rust` | `rust:bookworm` | Dockerfile (apt + auto-apt-proxy) |
| `NetworkTools` | — | external image passthrough (`nicolaka/netshoot:latest`), replaces `Alpine_Network_Debug` |

`NodeJS`/`Go`/`Rust` follow the exact same Dockerfile template as Debian/Ubuntu (auto-apt-proxy, `ARG EXTRA_PACKAGES`, same baseline `requirements.txt`), just swapping the `FROM` line for the official language image — this is why they're cheap to add once the Debian/Ubuntu template task is done.

## External-image environments

An environment folder can be **either**:
- A normal buildable environment: has a `Dockerfile` (+ `requirements.txt`, optional `requirements.local.txt`).
- An **external-image passthrough**: has an `external-image.txt` file containing a single fully-qualified image reference (e.g. `nicolaka/netshoot:latest`) and no `Dockerfile`.

For a passthrough environment: devmenu.sh/devmenu.ps1 skip the Pull/Build choice entirely (nothing to build) and `docker pull` the referenced image directly; CI's build-test and publish jobs skip it (there's nothing of ours to build, lint, or publish); its `devcontainer.json` uses `"image": "..."` instead of `"build": {...}`; its README documents that it's a thin wrapper and links to the upstream project, and notes that `requirements.local.txt` customization doesn't apply to it.

`NetworkTools` is the only passthrough environment for this pass.

## Repository layout (target)

```
docker-devenv/
├── devmenu.sh
├── devmenu.ps1
├── Environments/
│   └── <Name>/
│       ├── Dockerfile                # omitted for external-image environments
│       ├── requirements.txt          # omitted for external-image environments
│       ├── requirements.local.txt    # optional, gitignored, user additions
│       ├── external-image.txt        # only present for external-image environments
│       ├── .devcontainer/
│       │   └── devcontainer.json
│       └── README.md
├── tests/
│   └── devmenu.bats
├── workspace/                        # gitignored, bind-mount root, one subdir per env
├── .github/workflows/
│   ├── ci.yml                        # build+lint+test verification, PR/push
│   ├── publish.yml                   # multi-arch build+push to GHCR, merge to master + weekly cron
│   └── autoassign.yml                # unchanged
├── .gitignore                        # new: workspace/, requirements.local.txt
└── README.md                         # rewritten
```

## devmenu.sh (rewrite)

- **Dependency check**: replace `dpkg-query -l docker-ce jq` with `command -v docker`, `command -v jq`, `command -v fzf`. Real portability bug fix — the old check fails for any Docker install that isn't apt-tracked.
- **Requires running from inside a local clone**: check for `./Environments`; if missing, print the exact `git clone` command and exit.
- **Listing environments**: read `Environments/*` directories locally instead of hitting the GitHub API.
- **Selection UX**: fzf for the environment list. For a normal environment, a second fzf prompt: **Pull prebuilt (fast)** [default] vs **Build locally (customize)**. For an external-image environment, this second prompt is skipped — it's always a pull of the referenced image.
  - Pull path (normal env): `docker pull ghcr.io/modem7/docker-devenv-<env-slug>:latest`, where `<env-slug>` is the folder name lowercased with underscores converted to hyphens.
  - Pull path (external-image env): `docker pull <contents of external-image.txt>`.
  - Build path: reads `requirements.local.txt` if present, passes it as `--build-arg EXTRA_PACKAGES="..."`; builds from the local Dockerfile (local context, not a remote git URL).
- **Workspace prompt**: ask for a host path, default `./workspace/<env-slug>`; `mkdir -p` it if missing; empty input accepts the default.
- **Run**: `docker run --rm -it -v "<workspace>":/workspace --name "<Name>Dev$RANDOM" --hostname "<Name>Dev$RANDOM" <image>` — image already has `WORKDIR /workspace`. Drops `-it` automatically when stdin/stdout aren't a TTY (enables scripted/CI smoke testing).
- **Scriptability**: `DEVMENU_ENV`, `DEVMENU_ACTION`, `DEVMENU_WORKSPACE`, `DEVMENU_CMD` environment variables let each interactive prompt be pre-supplied, so the whole flow can be driven non-interactively for automated smoke testing without changing the default interactive UX.
- **Prune / Quit**: unchanged behavior. Ctrl+C trap unchanged.

## devmenu.ps1 (Windows-native port)

A PowerShell script mirroring devmenu.sh's behavior one-to-one — same dependency check (docker/jq/fzf, via `Get-Command`), same local-clone requirement, same fzf-driven selection (fzf ships a native Windows binary and works identically from PowerShell), same pull/build/external-image logic, same workspace prompt (`Read-Host` with a default), same `docker run`/`docker pull`/`docker buildx build` invocations. No WSL dependency — works with just Docker Desktop and the three CLI tools installed natively (via winget/choco/scoop). Linted with PSScriptAnalyzer in CI, the PowerShell equivalent of the shellcheck job. Not covered by the bats-core suite (see Non-goals) — verified by the same manual end-to-end smoke test as devmenu.sh.

## Dockerfiles

- All buildable environments (everything except `NetworkTools`) gain:
  - `ARG EXTRA_PACKAGES=""`, appended to the existing package-install command (`apk add` / `apt-get install`).
  - `WORKDIR /workspace`.
- Debian-family environments (Debian, Ubuntu, NodeJS, Go, Rust):
  - **Remove** the `APTIP`/`APTPORT`/`APTFILE` build args and the netcat-probe-and-write-apt-conf block entirely (Debian/Ubuntu only had this to begin with; NodeJS/Go/Rust are new and never had it).
  - Install `auto-apt-proxy` as an early step (before the main package install) so apt-get transparently uses whatever proxy it discovers on the build host's network, or goes direct if none is found. Confirmed installable on both current `debian:latest` and `ubuntu:latest` base images.
- Alpine-based environments (Alpine, Alpine_Python): only the `EXTRA_PACKAGES` arg and `WORKDIR` change apply; no proxy-discovery equivalent.
- `NetworkTools` has no Dockerfile at all (see External-image environments).

## devcontainer.json (VS Code Dev Containers)

One `Environments/<Name>/.devcontainer/devcontainer.json` per environment (including `NetworkTools`). For buildable environments it references the sibling Dockerfile via `"build": {"dockerfile": "../Dockerfile", "context": ".."}`; for `NetworkTools` it uses `"image": "nicolaka/netshoot:latest"` directly. All of them set `"workspaceMount"` to bind the folder VS Code was opened on to `/workspace`, and `"workspaceFolder": "/workspace"` — matching devmenu.sh/devmenu.ps1's own workspace convention. Since this repo is a utility repo rather than something you develop inside of, the README documents that a user copies the relevant `Environments/<Name>` folder (Dockerfile + `.devcontainer/`) into their own project to use it as a Dev Container, rather than opening this repo directly.

## CI — `ci.yml` (verification: PR + push to master)

- `discover` job: lists `Environments/*` subdirectories, classifies each as `build` (has a Dockerfile) or `external` (has `external-image.txt`), emits a JSON matrix with a `type` field for each.
- `build-test` job (matrix over `type == build` environments only): `docker buildx build` each Dockerfile locally (no push); run `hadolint` against each Dockerfile.
- `shellcheck` job: shellcheck against `devmenu.sh`.
- `psscriptanalyzer` job: PSScriptAnalyzer against `devmenu.ps1` (GitHub's `ubuntu-latest` runners ship PowerShell Core).
- `bats` job: installs bats-core, runs `tests/devmenu.bats`.
- All jobs are required PR status checks.

## CI — `publish.yml` (registry publish: merge to master + weekly cron)

- Trigger: `push` to `master` filtered to `Environments/**` changes, plus a weekly `schedule` cron.
- Matrix over `type == build` environments only (never `NetworkTools` — nothing of ours to publish for a passthrough). Multi-arch build (`linux/amd64`, `linux/arm64`) and push to `ghcr.io/modem7/docker-devenv-<env-slug>:latest` and `:<short-sha>`.
- Uses the workflow's built-in `GITHUB_TOKEN` with `packages: write` permission.

## README rewrite

Plain-English purpose statement → requirements with per-OS install one-liners (Docker, jq, fzf) → quickstart for both Linux/macOS (`devmenu.sh`) and Windows (`devmenu.ps1`) → environment table (8 rows, description, link to per-env README) → "Customizing a container" (`requirements.local.txt`, noting it doesn't apply to `NetworkTools`) → "Persistent workspace" → "Using as a VS Code Dev Container" (copy the folder into your own project) → "How it works" (pull vs. build, CI/publish pipeline, badges) → license and buymeacoffee links kept.

## Data flow

`./devmenu.sh` (or `devmenu.ps1`, run from inside a clone) → dependency check → fzf-select environment → if external-image, pull that image directly; otherwise fzf-select Pull/Build → [Pull: `docker pull ghcr.io/...`] or [Build: read optional `requirements.local.txt` → `docker buildx build` locally] → prompt workspace path → `mkdir -p` if needed → `docker run -v <workspace>:/workspace --rm -it <image>` → shell opens in `/workspace` → on exit, container removed; workspace persists on host; image stays cached locally.

## Error handling

- Missing dependency (docker/jq/fzf): name the exact tool + install hint, exit non-zero.
- Not run from inside a repo clone: print the `git clone` command, exit non-zero.
- Docker daemon unreachable: surface Docker's own error text.
- Build failure: propagate Docker's error, exit non-zero, no silent retry.
- Pull failure (offline/rate-limited/not yet published): suggest the "Build locally" option (where applicable — not for external-image environments, which have no build path) instead of crashing.
- Ctrl+C: existing trap/cleanup behavior retained.

## Testing

- CI's `build-test` (per-environment Docker build) is the primary regression test for Dockerfiles.
- `hadolint` catches Dockerfile anti-patterns.
- `shellcheck` / `psscriptanalyzer` catch script bugs before merge.
- `bats-core` unit-tests devmenu.sh's pure functions: environment-name-to-slug conversion, `requirements.local.txt` parsing, and external-image detection/resolution.
- No devmenu.ps1 unit-test suite (see Non-goals) — covered by lint + manual smoke test.
- Manual end-to-end smoke test (pull path, build path, workspace mount) for each buildable environment, plus a pull-only smoke test for `NetworkTools`, done once during implementation before considering the work complete.
