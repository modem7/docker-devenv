# Docker Dev Environments Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize `docker-devenv` end to end — portable Dockerfiles (no hardcoded homelab IPs), an fzf-driven `devmenu.sh` (plus a native `devmenu.ps1` Windows port), customizable/persistent-workspace containers, an expanded environment catalog, VS Code Dev Containers support, real CI (build/lint/unit-test verification + GHCR image publishing), and a rewritten README.

**Architecture:** Every environment lives in `Environments/<Name>/` and is either *buildable* (has a `Dockerfile`) or an *external-image passthrough* (has `external-image.txt` naming an upstream image, e.g. `nicolaka/netshoot`). `devmenu.sh`/`devmenu.ps1` discover environments by reading that directory locally (no GitHub API calls), let the user pick pull-vs-build via fzf, and mount a persistent host workspace at `/workspace`. CI discovers the same directory to build a matrix; buildable environments get built+linted on every PR and built+pushed to GHCR on merge.

**Tech Stack:** Bash (+fzf, jq), PowerShell 7+ (+fzf), Docker Buildx, GitHub Actions, bats-core, shellcheck, hadolint, PSScriptAnalyzer.

## Global Constraints

- Repo: `modem7/docker-devenv`, working branch `modernize-devenv` (already pushed, tracking `origin/modernize-devenv`). Never commit to `master` directly.
- Design spec is the source of truth for behavior: `docs/superpowers/specs/2026-08-08-modernization-design.md`. If a task here seems to contradict it, the spec wins — stop and reconcile.
- Every environment folder name must start with a letter (Docker container-naming rule; also keeps GHCR slugs sane). All 8 target environments already satisfy this.
- GHCR image naming: `ghcr.io/modem7/docker-devenv-<slug>`, where `<slug>` = folder name lowercased with `_` replaced by `-`.
- `EXTRA_PACKAGES` build-arg convention: every buildable Dockerfile declares `ARG EXTRA_PACKAGES=""` and appends `$EXTRA_PACKAGES` to its package-install command.
- Every buildable Dockerfile sets `WORKDIR /workspace`.
- Status/progress output in both menu scripts must never be mixed into a value returned via `$(...)`/command substitution — this plan hit and fixed exactly that bug during design verification (see Task 2). Follow the out-parameter pattern used there.
- Don't run `docker system prune` during verification steps in this plan — it clears the whole host's Docker cache, not just this project's. Prune logic is verified by code review, not live execution.

---

## Task 1: Add `.gitignore`

**Files:**
- Create: `.gitignore`

**Interfaces:**
- Produces: ignore rules that later tasks (workspace creation, local package overrides) depend on to avoid accidentally committing user-local state.

- [ ] **Step 1: Write the file**

```gitignore
/workspace/
Environments/*/requirements.local.txt
```

- [ ] **Step 2: Verify it actually ignores the right things**

```bash
mkdir -p workspace/tmp-check && touch workspace/tmp-check/file.txt
touch Environments/Alpine/requirements.local.txt
git status --porcelain
```

Expected: no output (both paths are ignored, nothing shows as untracked).

- [ ] **Step 3: Clean up the check and commit**

```bash
rm -rf workspace Environments/Alpine/requirements.local.txt
git add .gitignore
git commit -m "Add .gitignore for local workspace and package overrides"
```

---

## Task 2: Rewrite `devmenu.sh`

**Files:**
- Modify: `devmenu.sh` (full rewrite)

**Interfaces:**
- Produces (used by Task 3's tests and by end users): `env_slug(name)`, `parse_extra_packages(file)`, `is_external_image(name)`, `resolve_image_ref(name, slug)`, `list_environments()` — all pure, side-effect-free, safe to call via `$(...)`.
- Produces: `pull_image(name, slug)` and `build_image(name, slug)`, which set a global `RESOLVED_IMAGE` (do **not** call these via `$(...)` — their internal `docker`/status output would corrupt a captured return value, which is exactly the bug this task's manual verification below caught and fixed).
- Produces: `resolve_workspace(slug)`, which sets a global `RESOLVED_WORKSPACE`, same reasoning.
- Consumes: nothing from other tasks — this is a leaf script driven entirely by the `Environments/` directory contents at runtime.
- Scriptable via env vars: `DEVMENU_ENV`, `DEVMENU_ACTION` (`pull`|`build`), `DEVMENU_WORKSPACE`, `DEVMENU_CMD` — each bypasses the corresponding interactive prompt. Used by this task's own verification and by Task 13's end-to-end check.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Variables
gituser="modem7"
gitrepo="docker-devenv"
gitfolder="Environments"
buildername="DockerDevBuilder"
registry="ghcr.io/${gituser}"

# Colours
GREEN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
NORMAL=$(tput sgr0 2>/dev/null || true)

# Status/progress messages go to stderr, never stdout: several functions
# below return their result via stdout to a $(...) caller, and anything
# this prints to stdout would silently corrupt that value.
pfnl() {
    printf '\n%s\n' "$1" >&2
}

ctrl_c() {
    pfnl "User pressed Ctrl + C. Exiting script..."
    exit 1
}

# Alpine_Network_Debug -> alpine-network-debug
env_slug() {
    local name="$1"
    printf '%s' "${name,,}" | tr '_' '-'
}

# Strip '#' comments from a requirements-style file and print remaining
# packages space-separated. Prints nothing if the file doesn't exist.
parse_extra_packages() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed 's/#.*//' "$file" | tr '\n' ' ' | xargs || true
}

is_external_image() {
    [[ -f "${gitfolder}/${1}/external-image.txt" ]]
}

resolve_image_ref() {
    local name="$1" slug="$2"
    if is_external_image "$name"; then
        tr -d '[:space:]' < "${gitfolder}/${name}/external-image.txt"
    else
        printf '%s' "${registry}/${gitrepo}-${slug}:latest"
    fi
}

check_dependencies() {
    pfnl "========================================="
    pfnl "Checking dependencies..."
    local missing=()
    for cmd in docker jq fzf; do
        if command -v "$cmd" > /dev/null 2>&1; then
            pfnl "~ $cmd is...${GREEN}installed${NORMAL}"
        else
            pfnl "~ $cmd is...${RED}not installed${NORMAL}"
            missing+=("$cmd")
        fi
    done
    if ((${#missing[@]} > 0)); then
        pfnl "Install the missing dependencies:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                docker) pfnl "  docker: https://docs.docker.com/engine/install/" ;;
                jq)     pfnl "  jq:  sudo apt-get install jq    (or: brew install jq)" ;;
                fzf)    pfnl "  fzf: sudo apt-get install fzf   (or: brew install fzf)" ;;
            esac
        done
        exit 1
    fi
}

check_repo_root() {
    if [[ ! -d "$gitfolder" ]]; then
        pfnl "${RED}This script must be run from inside a clone of the repo.${NORMAL}"
        pfnl "Run: git clone https://github.com/${gituser}/${gitrepo}.git && cd ${gitrepo} && ./devmenu.sh"
        exit 1
    fi
}

list_environments() {
    local dir
    for dir in "$gitfolder"/*/; do
        [[ -d "$dir" ]] || continue
        basename "$dir"
    done | sort
}

select_environment() {
    if [[ -n "${DEVMENU_ENV:-}" ]]; then
        printf '%s' "$DEVMENU_ENV"
        return
    fi
    { list_environments; printf 'Prune\nQuit\n'; } | fzf --prompt="Choose Option: " --height=15 --border
}

select_action() {
    if [[ -n "${DEVMENU_ACTION:-}" ]]; then
        printf '%s' "$DEVMENU_ACTION"
        return
    fi
    printf 'pull\nbuild\n' | fzf --prompt="Pull prebuilt or build locally? " --height=8 --border \
        --header="pull = fast, prebuilt image | build = local Dockerfile + customization"
}

# Sets RESOLVED_WORKSPACE as an out-parameter (see build_image/pull_image
# below for why this repo avoids returning docker/fzf-adjacent results via
# stdout command substitution).
resolve_workspace() {
    local slug="$1"
    local default_dir="./workspace/${slug}"
    local workspace
    if [[ -n "${DEVMENU_WORKSPACE:-}" ]]; then
        workspace="$DEVMENU_WORKSPACE"
    else
        read -r -p "Workspace directory to mount at /workspace [${default_dir}]: " workspace
        workspace="${workspace:-$default_dir}"
    fi
    mkdir -p "$workspace"
    RESOLVED_WORKSPACE=$(cd "$workspace" && pwd)
}

# Sets RESOLVED_IMAGE as an out-parameter rather than returning via stdout:
# `docker pull`'s own progress output goes to stdout, and capturing this
# function with $(...) would silently mix that progress text into the
# "return value".
pull_image() {
    local name="$1" slug="$2"
    local image
    image=$(resolve_image_ref "$name" "$slug")
    pfnl "Pulling ${image}..."
    if docker pull "$image"; then
        RESOLVED_IMAGE="$image"
    else
        pfnl "${RED}Pull failed.${NORMAL} The image may not be published yet, or you're offline."
        if ! is_external_image "$name"; then
            pfnl "Try again and choose the 'build' option instead."
        fi
        exit 1
    fi
}

# Sets RESOLVED_IMAGE as an out-parameter (see pull_image above — same
# reasoning applies to `docker buildx build`'s stdout progress output).
build_image() {
    local name="$1"
    local slug="$2"
    local context="${gitfolder}/${name}"
    local extra_packages
    extra_packages=$(parse_extra_packages "${context}/requirements.local.txt")

    pfnl "Creating buildx builder..."
    if docker buildx create --use --name "$buildername" > /dev/null 2>&1; then
        pfnl "Builder $buildername created..."
    else
        pfnl "Builder already exists, using ${buildername}..."
        docker buildx use "$buildername"
    fi

    pfnl "Building ${name}..."
    docker buildx build --rm=true --build-arg BUILDKIT_INLINE_CACHE=1 \
        --build-arg "EXTRA_PACKAGES=${extra_packages}" \
        --load -t "${slug}:dev" "$context"
    RESOLVED_IMAGE="${slug}:dev"
}

run_container() {
    local name="$1"
    local image="$2"
    local workspace="$3"
    local container_name="${name}Dev${RANDOM}"

    pfnl "========================================="
    pfnl "Activating ${name} Dev Environment..."
    local tty_args=(-it)
    if [[ ! -t 0 || ! -t 1 ]]; then
        tty_args=()
    fi
    if [[ -n "${DEVMENU_CMD:-}" ]]; then
        docker run --rm "${tty_args[@]}" -v "${workspace}:/workspace" \
            --name "$container_name" --hostname "$container_name" \
            "$image" bash -lc "$DEVMENU_CMD"
    else
        pfnl "Press CTRL + D or type exit to leave the container."
        docker run --rm "${tty_args[@]}" -v "${workspace}:/workspace" \
            --name "$container_name" --hostname "$container_name" \
            "$image"
    fi
}

prune() {
    pfnl "Clearing Docker cache..."
    docker system prune -af
    pfnl "Removing Docker buildx builder..."
    if docker buildx rm "$buildername" > /dev/null 2>&1; then
        pfnl "Builder $buildername removed."
    else
        pfnl "Builder already removed, no action performed."
    fi
}

main() {
    check_dependencies
    check_repo_root
    trap ctrl_c INT

    cat << "BANNER" >&2
      ____             _
     |  _ \  ___   ___| | _____ _ __
     | | | |/ _ \ / __| |/ / _ | `__|
     | |_| | (_) | (__|   |  __| |
     |____/ \___/ \___|_|\_\___|_|
=========================================
BANNER

    local name
    if ! name=$(select_environment) || [[ -z "$name" ]]; then
        pfnl "No selection made. Exiting."
        exit 0
    fi

    case "$name" in
        Prune)
            prune
            exit 0
            ;;
        Quit)
            pfnl "Exiting script..."
            exit 0
            ;;
    esac

    local slug
    slug=$(env_slug "$name")

    local action
    if is_external_image "$name"; then
        action="pull"
    elif ! action=$(select_action) || [[ -z "$action" ]]; then
        pfnl "No action selected. Exiting."
        exit 0
    fi

    local image
    if [[ "$action" == "pull" ]]; then
        pull_image "$name" "$slug"
    else
        build_image "$name" "$slug"
    fi
    image="$RESOLVED_IMAGE"

    resolve_workspace "$slug"
    local workspace="$RESOLVED_WORKSPACE"

    run_container "$name" "$image" "$workspace"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 2: Make it executable, syntax-check, and lint**

```bash
chmod +x devmenu.sh
bash -n devmenu.sh && echo "syntax OK"
shellcheck devmenu.sh
```

Expected: `syntax OK`, and shellcheck produces no output (no warnings).

- [ ] **Step 3: Non-interactive end-to-end smoke test against the real Alpine environment**

```bash
rm -rf /tmp/devmenu-smoke-ws
DEVMENU_ENV=Alpine DEVMENU_ACTION=build DEVMENU_WORKSPACE=/tmp/devmenu-smoke-ws \
    DEVMENU_CMD="pwd && touch /workspace/marker.txt" ./devmenu.sh
ls /tmp/devmenu-smoke-ws/marker.txt
```

Expected: the build completes, the container prints its working directory, and `/tmp/devmenu-smoke-ws/marker.txt` exists on the host afterward (proves the volume mount round-trips). Clean up afterward: `rm -rf /tmp/devmenu-smoke-ws`, and `docker rmi alpine:dev` (the test build tag).

- [ ] **Step 4: Non-interactive smoke test of the external-image path**

```bash
mkdir -p Environments/_SmokeTest
echo "alpine:latest" > Environments/_SmokeTest/external-image.txt
rm -rf /tmp/devmenu-smoke-ws2
DEVMENU_ENV=_SmokeTest DEVMENU_WORKSPACE=/tmp/devmenu-smoke-ws2 \
    DEVMENU_CMD="echo external-image-path-ok" ./devmenu.sh
rm -rf Environments/_SmokeTest /tmp/devmenu-smoke-ws2
```

Expected: no `pull`/`build` prompt appears (it's skipped entirely for external-image environments), `alpine:latest` is pulled, and the container prints `external-image-path-ok`. Note: a leading underscore in the environment name would make Docker reject the container name — irrelevant for real environment names (Task 6's global constraint already requires names to start with a letter), but don't reuse `_SmokeTest` as a template for anything real.

- [ ] **Step 5: Commit**

```bash
git add devmenu.sh
git commit -m "Rewrite devmenu.sh: fzf UX, local discovery, customization, workspace volumes"
```

---

## Task 3: Add the bats-core unit test suite for `devmenu.sh`

**Files:**
- Create: `tests/devmenu.bats`

**Interfaces:**
- Consumes: `env_slug`, `parse_extra_packages`, `is_external_image`, `resolve_image_ref`, `list_environments` from `devmenu.sh` (Task 2) — sourced directly, not invoked as a subprocess.

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../devmenu.sh"
}

@test "env_slug lowercases and hyphenates underscores" {
    result="$(env_slug "Alpine_Network_Debug")"
    [ "$result" = "alpine-network-debug" ]
}

@test "env_slug leaves a simple name lowercase" {
    result="$(env_slug "Ubuntu")"
    [ "$result" = "ubuntu" ]
}

@test "parse_extra_packages strips comments and joins with spaces" {
    tmpfile="$(mktemp)"
    printf '# comment\nfoo\nbar  # inline comment\n\nbaz\n' > "$tmpfile"
    result="$(parse_extra_packages "$tmpfile")"
    rm -f "$tmpfile"
    [ "$result" = "foo bar baz" ]
}

@test "parse_extra_packages prints nothing for a missing file" {
    result="$(parse_extra_packages "/nonexistent/path/requirements.local.txt")"
    [ "$result" = "" ]
}

@test "is_external_image is true when external-image.txt exists" {
    tmpdir="$(mktemp -d)"
    gitfolder="$tmpdir"
    mkdir -p "$tmpdir/NetworkTools"
    echo "nicolaka/netshoot:latest" > "$tmpdir/NetworkTools/external-image.txt"
    run is_external_image "NetworkTools"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
}

@test "is_external_image is false when there is a Dockerfile instead" {
    tmpdir="$(mktemp -d)"
    gitfolder="$tmpdir"
    mkdir -p "$tmpdir/Alpine"
    touch "$tmpdir/Alpine/Dockerfile"
    run is_external_image "Alpine"
    rm -rf "$tmpdir"
    [ "$status" -eq 1 ]
}

@test "resolve_image_ref returns the GHCR path for a normal environment" {
    result="$(resolve_image_ref "Ubuntu" "ubuntu")"
    [ "$result" = "ghcr.io/modem7/docker-devenv-ubuntu:latest" ]
}

@test "resolve_image_ref returns the external image reference when present" {
    tmpdir="$(mktemp -d)"
    gitfolder="$tmpdir"
    mkdir -p "$tmpdir/NetworkTools"
    printf '  nicolaka/netshoot:latest  \n' > "$tmpdir/NetworkTools/external-image.txt"
    result="$(resolve_image_ref "NetworkTools" "networktools")"
    rm -rf "$tmpdir"
    [ "$result" = "nicolaka/netshoot:latest" ]
}

@test "list_environments lists directories sorted" {
    tmpdir="$(mktemp -d)"
    gitfolder="$tmpdir"
    mkdir -p "$tmpdir/Ubuntu" "$tmpdir/Alpine" "$tmpdir/Debian"
    result="$(list_environments)"
    rm -rf "$tmpdir"
    expected=$'Alpine\nDebian\nUbuntu'
    [ "$result" = "$expected" ]
}
```

- [ ] **Step 2: Run the suite**

```bash
bats tests/devmenu.bats
```

Expected: `9` tests, all `ok`.

- [ ] **Step 3: Commit**

```bash
git add tests/devmenu.bats
git commit -m "Add bats-core unit tests for devmenu.sh's pure functions"
```

---

## Task 4: Update Alpine-family Dockerfiles (`Alpine`, `Alpine_Python`)

**Files:**
- Modify: `Environments/Alpine/Dockerfile`
- Modify: `Environments/Alpine_Python/Dockerfile`

**Interfaces:**
- Produces: `ARG EXTRA_PACKAGES=""` contract that `devmenu.sh`'s `build_image` (Task 2) already passes via `--build-arg`.

- [ ] **Step 1: Replace `Environments/Alpine/Dockerfile`**

```dockerfile
# syntax = docker/dockerfile:1

FROM alpine:edge
LABEL maintainer="modem7"

ARG EXTRA_PACKAGES=""

COPY --link requirements.txt /requirements.txt

# hadolint ignore=DL4006
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    <<EOF
    set -xe
    ln -vs /var/cache/apk /etc/apk/cache
    echo "Installing Packages..."
    sed 's/#.*//' /requirements.txt | xargs apk add --update $EXTRA_PACKAGES
EOF

# Set Bash environment
RUN <<EOF
    set -xe
    sed -e 's;/bin/ash$;/bin/bash;g' -i /etc/passwd
    cat <<FIRST > ~/.bashrc
    PS1="\[\e[1;32m\]\u@\h:\[\e[0m\]\w\[\e[1;32m\]$ \[\e[0m\]"
FIRST
    cat <<SECOND >> ~/.profile
    if [ "\${SHELL}x" = "/bin/bashx" ]; then
      if [ -f "\${HOME}/.bashrc" ]; then
        . "\${HOME}/.bashrc"
      fi
    fi
SECOND
EOF

WORKDIR /workspace

CMD [ "/bin/bash" ]
```

(Note: dropped the `-e` from `echo -e "Installing Packages..."` — no escape sequences were in that string, and hadolint flags `echo -e` as undefined in POSIX sh. Added a `hadolint ignore=DL4006` comment instead of setting `SHELL` explicitly — Alpine's `ash` doesn't support `-o pipefail`, so forcing it would break the build.)

- [ ] **Step 2: Replace `Environments/Alpine_Python/Dockerfile`** — identical to the above except the `FROM` line:

```dockerfile
# syntax = docker/dockerfile:1

FROM python:alpine3.17
LABEL maintainer="modem7"

ARG EXTRA_PACKAGES=""

COPY --link requirements.txt /requirements.txt

# hadolint ignore=DL4006
RUN --mount=type=cache,id=apk,sharing=locked,target=/var/cache/apk \
    <<EOF
    set -xe
    ln -vs /var/cache/apk /etc/apk/cache
    echo "Installing Packages..."
    sed 's/#.*//' /requirements.txt | xargs apk add --update $EXTRA_PACKAGES
EOF

# Set Bash environment
RUN <<EOF
    set -xe
    sed -e 's;/bin/ash$;/bin/bash;g' -i /etc/passwd
    cat <<FIRST > ~/.bashrc
    PS1="\[\e[1;32m\]\u@\h:\[\e[0m\]\w\[\e[1;32m\]$ \[\e[0m\]"
FIRST
    cat <<SECOND >> ~/.profile
    if [ "\${SHELL}x" = "/bin/bashx" ]; then
      if [ -f "\${HOME}/.bashrc" ]; then
        . "\${HOME}/.bashrc"
      fi
    fi
SECOND
EOF

WORKDIR /workspace

CMD [ "/bin/bash" ]
```

- [ ] **Step 3: Build and lint both, with and without `EXTRA_PACKAGES`**

```bash
docker run --rm -i hadolint/hadolint < Environments/Alpine/Dockerfile
docker run --rm -i hadolint/hadolint < Environments/Alpine_Python/Dockerfile
docker buildx build --load -t alpine-verify:dev Environments/Alpine
docker buildx build --build-arg EXTRA_PACKAGES=tree --load -t alpine-verify2:dev Environments/Alpine
docker run --rm alpine-verify2:dev bash -c "pwd && which tree"
docker buildx build --load -t alpine-python-verify:dev Environments/Alpine_Python
```

Expected: hadolint produces no output for either file; all three builds succeed; the container prints `/workspace` then the path to `tree`.

- [ ] **Step 4: Clean up test images and commit**

```bash
docker rmi alpine-verify:dev alpine-verify2:dev alpine-python-verify:dev
git add Environments/Alpine/Dockerfile Environments/Alpine_Python/Dockerfile
git commit -m "Add EXTRA_PACKAGES customization and /workspace to Alpine-family Dockerfiles"
```

---

## Task 5: Update Debian & Ubuntu Dockerfiles (auto-apt-proxy)

**Files:**
- Modify: `Environments/Debian/Dockerfile`
- Modify: `Environments/Ubuntu/Dockerfile`

**Interfaces:**
- Produces: same `ARG EXTRA_PACKAGES=""` contract as Task 4, plus removal of the hardcoded `192.168.0.254:3142` proxy IP (replaced by `auto-apt-proxy`, confirmed installable on both `debian:latest` and `ubuntu:latest` during design verification).

- [ ] **Step 1: Replace `Environments/Debian/Dockerfile`**

```dockerfile
# syntax = docker/dockerfile:1

FROM debian
LABEL maintainer="modem7"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ="Europe/London"
ARG EXTRA_PACKAGES=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --link requirements.txt /requirements.txt

# Discover an apt proxy automatically, if one exists on the build host's
# network. Falls back to direct downloads otherwise.
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    apt-get update
    apt-get -y install --no-install-recommends auto-apt-proxy
EOF

# Install Environment
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    rm -fv /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    echo "$TZ" > /etc/timezone
    sed 's/#.*//' /requirements.txt | xargs apt-get -y install --no-install-recommends $EXTRA_PACKAGES
EOF

# Set Bash environment
RUN <<EOF
    set -xe
    cat <<FIRST > ~/.bashrc
    PS1="\[\e[1;32m\]\u@\h:\[\e[0m\]\w\[\e[1;32m\]$ \[\e[0m\]"
FIRST
    cat <<SECOND >> ~/.profile
    if [ "\${SHELL}x" = "/bin/bashx" ]; then
      if [ -f "\${HOME}/.bashrc" ]; then
        . "\${HOME}/.bashrc"
      fi
    fi
SECOND
EOF

WORKDIR /workspace

CMD [ "/bin/bash" ]
```

(Removed the `APTIP`/`APTPORT`/`APTFILE` args and the netcat-probe block entirely, and dropped the Alpine-only `sed 's;/bin/ash$;/bin/bash;g'` line — Debian never has `/bin/ash`, it was always a no-op here.)

- [ ] **Step 2: Replace `Environments/Ubuntu/Dockerfile`** — identical except the `FROM` line:

```dockerfile
# syntax = docker/dockerfile:1

FROM ubuntu
LABEL maintainer="modem7"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ="Europe/London"
ARG EXTRA_PACKAGES=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --link requirements.txt /requirements.txt

# Discover an apt proxy automatically, if one exists on the build host's
# network. Falls back to direct downloads otherwise.
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    apt-get update
    apt-get -y install --no-install-recommends auto-apt-proxy
EOF

# Install Environment
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    rm -fv /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    echo "$TZ" > /etc/timezone
    sed 's/#.*//' /requirements.txt | xargs apt-get -y install --no-install-recommends $EXTRA_PACKAGES
EOF

# Set Bash environment
RUN <<EOF
    set -xe
    cat <<FIRST > ~/.bashrc
    PS1="\[\e[1;32m\]\u@\h:\[\e[0m\]\w\[\e[1;32m\]$ \[\e[0m\]"
FIRST
    cat <<SECOND >> ~/.profile
    if [ "\${SHELL}x" = "/bin/bashx" ]; then
      if [ -f "\${HOME}/.bashrc" ]; then
        . "\${HOME}/.bashrc"
      fi
    fi
SECOND
EOF

WORKDIR /workspace

CMD [ "/bin/bash" ]
```

- [ ] **Step 3: Build and verify both, with and without `EXTRA_PACKAGES`**

```bash
docker buildx build --load -t debian-verify:dev Environments/Debian
docker buildx build --build-arg EXTRA_PACKAGES=tree --load -t debian-verify2:dev Environments/Debian
docker run --rm debian-verify2:dev bash -c "pwd && which tree"
docker buildx build --load -t ubuntu-verify:dev Environments/Ubuntu
docker buildx build --build-arg EXTRA_PACKAGES=tree --load -t ubuntu-verify2:dev Environments/Ubuntu
docker run --rm ubuntu-verify2:dev bash -c "pwd && which tree"
docker run --rm -i hadolint/hadolint < Environments/Debian/Dockerfile
docker run --rm -i hadolint/hadolint < Environments/Ubuntu/Dockerfile
```

Expected: all four builds succeed; both containers print `/workspace` then the path to `tree`; hadolint shows only the pre-existing `DL3006`/`DL3008` warnings (untagged `FROM`, unpinned apt versions) that are intentional for a "dev environment that tracks latest" tool — no new warnings.

- [ ] **Step 4: Clean up test images and commit**

```bash
docker rmi debian-verify:dev debian-verify2:dev ubuntu-verify:dev ubuntu-verify2:dev
git add Environments/Debian/Dockerfile Environments/Ubuntu/Dockerfile
git commit -m "Replace hardcoded Apt-Cacher-NG IP with auto-apt-proxy discovery"
```

---

## Task 6: Add NodeJS, Go, and Rust environments

**Files:**
- Create: `Environments/NodeJS/{Dockerfile,requirements.txt,README.md}`
- Create: `Environments/Go/{Dockerfile,requirements.txt,README.md}`
- Create: `Environments/Rust/{Dockerfile,requirements.txt,README.md}`

**Interfaces:**
- Consumes: the Debian-family Dockerfile template verified in Task 5 (auto-apt-proxy + `EXTRA_PACKAGES` + `WORKDIR /workspace`) — these three environments are that exact template with only the `FROM` line changed, confirmed available: `node:lts-bookworm`, `golang:bookworm`, `rust:bookworm`.
- Produces: three new entries `list_environments()` (Task 2) will pick up automatically, and three new matrix entries for CI (Tasks 10/11).

- [ ] **Step 1: `Environments/NodeJS/requirements.txt`**

```
#Packages to install

# Standard Packages
bash-completion
ca-certificates
coreutils
curl
git
jq
nano
tzdata
wget
```

- [ ] **Step 2: `Environments/NodeJS/Dockerfile`**

```dockerfile
# syntax = docker/dockerfile:1

FROM node:lts-bookworm
LABEL maintainer="modem7"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ="Europe/London"
ARG EXTRA_PACKAGES=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --link requirements.txt /requirements.txt

# Discover an apt proxy automatically, if one exists on the build host's
# network. Falls back to direct downloads otherwise.
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    apt-get update
    apt-get -y install --no-install-recommends auto-apt-proxy
EOF

# Install Environment
RUN --mount=type=cache,id=aptcache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=libcache,target=/var/lib/apt,sharing=locked \
    <<EOF
    set -xe
    rm -fv /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    echo "$TZ" > /etc/timezone
    sed 's/#.*//' /requirements.txt | xargs apt-get -y install --no-install-recommends $EXTRA_PACKAGES
EOF

# Set Bash environment
RUN <<EOF
    set -xe
    cat <<FIRST > ~/.bashrc
    PS1="\[\e[1;32m\]\u@\h:\[\e[0m\]\w\[\e[1;32m\]$ \[\e[0m\]"
FIRST
    cat <<SECOND >> ~/.profile
    if [ "\${SHELL}x" = "/bin/bashx" ]; then
      if [ -f "\${HOME}/.bashrc" ]; then
        . "\${HOME}/.bashrc"
      fi
    fi
SECOND
EOF

WORKDIR /workspace

CMD [ "/bin/bash" ]
```

- [ ] **Step 3: `Environments/NodeJS/README.md`**

```markdown
# NodeJS Dev Environment

Based on `node:lts-bookworm` (Node.js LTS on Debian bookworm).

---

# Included packages
## Standard Packages
- bash-completion
- ca-certificates
- coreutils
- curl
- git
- jq
- nano
- tzdata
- wget

Node.js, npm, and their toolchain come from the base image itself.
```

- [ ] **Step 4: Repeat for Go — `Environments/Go/requirements.txt`** (identical content to NodeJS's), **`Environments/Go/Dockerfile`** (identical to NodeJS's Dockerfile except `FROM golang:bookworm`), **`Environments/Go/README.md`**:

```markdown
# Go Dev Environment

Based on `golang:bookworm` (Go toolchain on Debian bookworm).

---

# Included packages
## Standard Packages
- bash-completion
- ca-certificates
- coreutils
- curl
- git
- jq
- nano
- tzdata
- wget

The Go toolchain comes from the base image itself.
```

- [ ] **Step 5: Repeat for Rust — `Environments/Rust/requirements.txt`** (identical content), **`Environments/Rust/Dockerfile`** (identical except `FROM rust:bookworm`), **`Environments/Rust/README.md`**:

```markdown
# Rust Dev Environment

Based on `rust:bookworm` (Rust + cargo on Debian bookworm).

---

# Included packages
## Standard Packages
- bash-completion
- ca-certificates
- coreutils
- curl
- git
- jq
- nano
- tzdata
- wget

Rust and cargo come from the base image itself.
```

- [ ] **Step 6: Build, run, and lint all three**

```bash
for env in NodeJS Go Rust; do
    echo "=== $env ==="
    docker run --rm -i hadolint/hadolint < "Environments/$env/Dockerfile"
    docker buildx build --load -t "${env,,}-verify:dev" "Environments/$env"
done
docker run --rm nodejs-verify:dev bash -c "pwd && node --version"
docker run --rm go-verify:dev bash -c "pwd && go version"
docker run --rm rust-verify:dev bash -c "pwd && rustc --version"
```

Expected: hadolint shows only the same pre-existing `DL3006`/`DL3008` warnings as Debian/Ubuntu; all three builds succeed; each container prints `/workspace` then its language runtime's version.

- [ ] **Step 7: Clean up test images and commit**

```bash
docker rmi nodejs-verify:dev go-verify:dev rust-verify:dev
git add Environments/NodeJS Environments/Go Environments/Rust
git commit -m "Add NodeJS, Go, and Rust dev environments"
```

---

## Task 7: Replace `Alpine_Network_Debug` with `NetworkTools` (netshoot passthrough)

**Files:**
- Delete: `Environments/Alpine_Network_Debug/` (Dockerfile, requirements.txt, README.md)
- Create: `Environments/NetworkTools/external-image.txt`
- Create: `Environments/NetworkTools/README.md`

**Interfaces:**
- Produces: the one and only `external-image.txt`-based environment that `is_external_image`/`resolve_image_ref` (Task 2) and CI's discovery logic (Tasks 10/11) branch on.

- [ ] **Step 1: Remove the old environment**

```bash
git rm -r Environments/Alpine_Network_Debug
```

- [ ] **Step 2: Create `Environments/NetworkTools/external-image.txt`**

```
nicolaka/netshoot:latest
```

(No trailing newline requirement — `resolve_image_ref` strips all whitespace via `tr -d '[:space:]'`.)

- [ ] **Step 3: Create `Environments/NetworkTools/README.md`**

```markdown
# NetworkTools Dev Environment

This environment doesn't build its own image — it's a thin passthrough to
[`nicolaka/netshoot`](https://github.com/nicolaka/netshoot), the de facto
standard Docker network-troubleshooting image. Selecting it in
`devmenu.sh`/`devmenu.ps1` pulls `nicolaka/netshoot:latest` directly; there's
no "build locally" option and `requirements.local.txt` customization doesn't
apply here.

netshoot bundles (among others): `iproute2`, `iputils`, `dig`/`drill`,
`curl`, `nmap`, `tcpdump`, `tshark`, `mtr`, `iperf3`, `socat`, `ngrep`,
`conntrack`, and `ss`. See the
[netshoot README](https://github.com/nicolaka/netshoot#readme) for the full
list and usage notes.
```

- [ ] **Step 4: Verify no leftover references to the old name**

```bash
grep -rn "Alpine_Network_Debug" . --exclude-dir=.git --exclude-dir=docs || echo "no references found"
```

Expected: `no references found` (README.md and devcontainer.json for the new environments are added in later tasks and won't reference the old name either).

- [ ] **Step 5: Commit**

```bash
git add Environments/NetworkTools
git commit -m "Replace Alpine_Network_Debug with a netshoot passthrough (NetworkTools)"
```

---

## Task 8: Add `devmenu.ps1` (native Windows port)

**Files:**
- Create: `devmenu.ps1`

**Interfaces:**
- Mirrors every function in `devmenu.sh` (Task 2) one-to-one: `Get-EnvSlug`, `Get-ExtraPackages`, `Test-ExternalImage`, `Resolve-ImageRef`, `Get-Environments` are pure; `Invoke-Pull`/`Invoke-Build`/`Resolve-Workspace` are the PowerShell equivalents of the bash out-parameter functions (here they return via PowerShell's normal function output, which — unlike bash `$(...)` — does *not* capture `Write-Host` output, so no equivalent bug applies).
- Same `DEVMENU_ENV`/`DEVMENU_ACTION`/`DEVMENU_WORKSPACE`/`DEVMENU_CMD` environment-variable overrides as `devmenu.sh`.

- [ ] **Step 1: Write the script**

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GitUser = 'modem7'
$GitRepo = 'docker-devenv'
$GitFolder = 'Environments'
$BuilderName = 'DockerDevBuilder'
$Registry = "ghcr.io/$GitUser"

function Get-EnvSlug {
    param([Parameter(Mandatory)][string]$Name)
    $Name.ToLowerInvariant() -replace '_', '-'
}

function Get-ExtraPackages {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $lines = Get-Content -LiteralPath $Path | ForEach-Object { ($_ -replace '#.*', '').Trim() }
    ($lines | Where-Object { $_ -ne '' }) -join ' '
}

function Test-ExternalImage {
    param([Parameter(Mandatory)][string]$Name)
    Test-Path -LiteralPath (Join-Path $GitFolder $Name 'external-image.txt') -PathType Leaf
}

function Resolve-ImageRef {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Slug)
    if (Test-ExternalImage -Name $Name) {
        (Get-Content -LiteralPath (Join-Path $GitFolder $Name 'external-image.txt') -Raw).Trim()
    } else {
        "${Registry}/${GitRepo}-${Slug}:latest"
    }
}

function Test-Dependencies {
    Write-Host "`n========================================="
    Write-Host "Checking dependencies..."
    $missing = @()
    foreach ($cmd in 'docker', 'jq', 'fzf') {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Write-Host "~ $cmd is...installed" -ForegroundColor Green
        } else {
            Write-Host "~ $cmd is...not installed" -ForegroundColor Red
            $missing += $cmd
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "Install the missing dependencies:"
        foreach ($cmd in $missing) {
            switch ($cmd) {
                'docker' { Write-Host "  docker: https://docs.docker.com/desktop/install/windows-install/" }
                'jq'     { Write-Host "  jq:  winget install jqlang.jq   (or: choco install jq)" }
                'fzf'    { Write-Host "  fzf: winget install fzf         (or: choco install fzf)" }
            }
        }
        exit 1
    }
}

function Test-RepoRoot {
    if (-not (Test-Path -LiteralPath $GitFolder -PathType Container)) {
        Write-Host "This script must be run from inside a clone of the repo." -ForegroundColor Red
        Write-Host "Run: git clone https://github.com/$GitUser/$GitRepo.git; cd $GitRepo; .\devmenu.ps1"
        exit 1
    }
}

function Get-Environments {
    Get-ChildItem -LiteralPath $GitFolder -Directory | Sort-Object Name | Select-Object -ExpandProperty Name
}

function Select-Environment {
    if ($env:DEVMENU_ENV) { return $env:DEVMENU_ENV }
    $options = @(Get-Environments) + @('Prune', 'Quit')
    $options | fzf --prompt="Choose Option: " --height=15 --border
}

function Select-Action {
    if ($env:DEVMENU_ACTION) { return $env:DEVMENU_ACTION }
    @('pull', 'build') | fzf --prompt="Pull prebuilt or build locally? " --height=8 --border `
        --header="pull = fast, prebuilt image | build = local Dockerfile + customization"
}

function Resolve-Workspace {
    param([Parameter(Mandatory)][string]$Slug)
    $default = ".\workspace\$Slug"
    if ($env:DEVMENU_WORKSPACE) {
        $workspace = $env:DEVMENU_WORKSPACE
    } else {
        $typed = Read-Host "Workspace directory to mount at /workspace [$default]"
        $workspace = if ([string]::IsNullOrWhiteSpace($typed)) { $default } else { $typed }
    }
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    (Resolve-Path -LiteralPath $workspace).Path
}

function Invoke-Pull {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Slug)
    $image = Resolve-ImageRef -Name $Name -Slug $Slug
    Write-Host "`nPulling $image..."
    docker pull $image
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pull failed. The image may not be published yet, or you're offline." -ForegroundColor Red
        if (-not (Test-ExternalImage -Name $Name)) {
            Write-Host "Try again and choose the 'build' option instead."
        }
        exit 1
    }
    $image
}

function Invoke-Build {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Slug)
    $context = Join-Path $GitFolder $Name
    $extraPackages = Get-ExtraPackages -Path (Join-Path $context 'requirements.local.txt')

    Write-Host "`nCreating buildx builder..."
    docker buildx create --use --name $BuilderName *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Builder already exists, using $BuilderName..."
        docker buildx use $BuilderName
    }

    Write-Host "Building $Name..."
    docker buildx build --rm=true --build-arg BUILDKIT_INLINE_CACHE=1 `
        --build-arg "EXTRA_PACKAGES=$extraPackages" `
        --load -t "${Slug}:dev" $context
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed." -ForegroundColor Red
        exit 1
    }
    "${Slug}:dev"
}

function Invoke-RunContainer {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Image, [Parameter(Mandatory)][string]$Workspace)
    $containerName = "${Name}Dev$(Get-Random)"
    Write-Host "`n========================================="
    Write-Host "Activating $Name Dev Environment..."
    if ($env:DEVMENU_CMD) {
        docker run --rm -v "${Workspace}:/workspace" --name $containerName --hostname $containerName $Image bash -lc "$env:DEVMENU_CMD"
    } else {
        Write-Host "Press CTRL + D or type exit to leave the container."
        docker run --rm -it -v "${Workspace}:/workspace" --name $containerName --hostname $containerName $Image
    }
}

function Invoke-Prune {
    Write-Host "`nClearing Docker cache..."
    docker system prune -af
    Write-Host "Removing Docker buildx builder..."
    docker buildx rm $BuilderName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Builder $BuilderName removed."
    } else {
        Write-Host "Builder already removed, no action performed."
    }
}

function Main {
    Test-Dependencies
    Test-RepoRoot

    Write-Host @'
      ____             _
     |  _ \  ___   ___| | _____ _ __
     | | | |/ _ \ / __| |/ / _ | `__|
     | |_| | (_) | (__|   |  __| |
     |____/ \___/ \___|_|\_\___|_|
=========================================
'@

    $name = Select-Environment
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Host "No selection made. Exiting."
        return
    }

    switch ($name) {
        'Prune' { Invoke-Prune; return }
        'Quit'  { Write-Host "Exiting script..."; return }
    }

    $slug = Get-EnvSlug -Name $name

    if (Test-ExternalImage -Name $name) {
        $action = 'pull'
    } else {
        $action = Select-Action
        if ([string]::IsNullOrWhiteSpace($action)) {
            Write-Host "No action selected. Exiting."
            return
        }
    }

    if ($action -eq 'pull') {
        $image = Invoke-Pull -Name $name -Slug $slug
    } else {
        $image = Invoke-Build -Name $name -Slug $slug
    }

    $workspace = Resolve-Workspace -Slug $slug
    Invoke-RunContainer -Name $name -Image $image -Workspace $workspace
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
```

- [ ] **Step 2: Verify as best as possible without local PowerShell**

This dev VM doesn't have `pwsh` installed, so full local verification isn't possible here — the real gate is CI's `psscriptanalyzer` job (Task 10), which runs on GitHub's `ubuntu-latest` runners that ship PowerShell Core. Before committing, re-read the script once against `devmenu.sh` function-by-function to confirm parity (dependency check, repo-root check, discovery, external-image branch, pull/build, workspace resolution, run, prune) — every function above has a named bash counterpart from Task 2.

- [ ] **Step 3: Commit**

```bash
git add devmenu.ps1
git commit -m "Add devmenu.ps1: native Windows port of devmenu.sh (no WSL required)"
```

- [ ] **Step 4: Flag for follow-up verification**

Note in the PR description (Task 13) that `devmenu.ps1` has not been run on an actual Windows machine — CI lint plus manual code-parity review are the only verification performed during this implementation pass.

---

## Task 9: Add `devcontainer.json` for all 8 environments

**Files:**
- Create: `Environments/Alpine/.devcontainer/devcontainer.json`
- Create: `Environments/Alpine_Python/.devcontainer/devcontainer.json`
- Create: `Environments/Debian/.devcontainer/devcontainer.json`
- Create: `Environments/Ubuntu/.devcontainer/devcontainer.json`
- Create: `Environments/NodeJS/.devcontainer/devcontainer.json`
- Create: `Environments/Go/.devcontainer/devcontainer.json`
- Create: `Environments/Rust/.devcontainer/devcontainer.json`
- Create: `Environments/NetworkTools/.devcontainer/devcontainer.json`

**Interfaces:**
- Consumes: each buildable environment's `../Dockerfile`; `NetworkTools`'s `external-image.txt` content (`nicolaka/netshoot:latest`) inlined directly since devcontainer.json can't read that file at VS Code's parse time.

- [ ] **Step 1: Create the 7 buildable environments' devcontainer.json** — identical template, one file per environment, only `name` differs. For `Environments/Alpine/.devcontainer/devcontainer.json`:

```json
{
  "name": "Alpine Dev Environment",
  "build": {
    "dockerfile": "../Dockerfile",
    "context": ".."
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace"
}
```

Repeat for `Alpine_Python` (`"name": "Alpine_Python Dev Environment"`), `Debian`, `Ubuntu`, `NodeJS`, `Go`, `Rust` — same structure, `name` matching the folder.

- [ ] **Step 2: Create `Environments/NetworkTools/.devcontainer/devcontainer.json`**

```json
{
  "name": "NetworkTools Dev Environment",
  "image": "nicolaka/netshoot:latest",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace"
}
```

- [ ] **Step 3: Validate all 8 are well-formed JSON**

```bash
for f in Environments/*/.devcontainer/devcontainer.json; do
    python3 -c "import json,sys; json.load(open(sys.argv[1])); print('OK: ' + sys.argv[1])" "$f"
done
```

Expected: 8 lines, each `OK: Environments/<Name>/.devcontainer/devcontainer.json`.

- [ ] **Step 4: Commit**

```bash
git add Environments/*/.devcontainer
git commit -m "Add devcontainer.json to every environment for VS Code Dev Containers support"
```

---

## Task 10: Add `.github/workflows/ci.yml`

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `devmenu.sh` (shellcheck), `devmenu.ps1` (PSScriptAnalyzer), `tests/devmenu.bats` (bats), every `Environments/*/Dockerfile` (build + hadolint) — all produced by Tasks 2–9.

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [master]

jobs:
  discover:
    runs-on: ubuntu-latest
    outputs:
      build_environments: ${{ steps.list.outputs.build_environments }}
    steps:
      - uses: actions/checkout@v4
      - id: list
        run: |
          envs=$(for d in Environments/*/; do
            name=$(basename "$d")
            if [ -f "${d}Dockerfile" ]; then
              printf '%s\n' "$name"
            fi
          done | sort)
          json=$(printf '%s\n' "$envs" | jq -R -s -c 'split("\n") | map(select(length > 0))')
          echo "build_environments=$json" >> "$GITHUB_OUTPUT"

  build-test:
    needs: discover
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        environment: ${{ fromJson(needs.discover.outputs.build_environments) }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Build ${{ matrix.environment }}
        uses: docker/build-push-action@v6
        with:
          context: Environments/${{ matrix.environment }}
          push: false
          tags: docker-devenv-${{ matrix.environment }}:ci
      - name: Lint Dockerfile
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Environments/${{ matrix.environment }}/Dockerfile

  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Shellcheck devmenu.sh
        uses: ludeeus/action-shellcheck@2.0.0
        with:
          scandir: '.'

  psscriptanalyzer:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run PSScriptAnalyzer on devmenu.ps1
        shell: pwsh
        run: |
          Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
          $results = Invoke-ScriptAnalyzer -Path ./devmenu.ps1 -Severity Warning,Error
          $results | Format-Table -AutoSize
          if ($results.Count -gt 0) { exit 1 }

  bats:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats
      - name: Run devmenu.sh test suite
        run: bats tests/devmenu.bats
```

- [ ] **Step 2: Validate YAML syntax locally**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('valid YAML')"
```

Expected: `valid YAML`.

- [ ] **Step 3: Dry-run the discover job's matrix logic locally** (the actual GitHub Actions execution can only be verified once pushed, but the shell logic inside the `discover` job is plain bash and can be checked now)

```bash
envs=$(for d in Environments/*/; do
    name=$(basename "$d")
    if [ -f "${d}Dockerfile" ]; then
        printf '%s\n' "$name"
    fi
done | sort)
printf '%s\n' "$envs" | jq -R -s -c 'split("\n") | map(select(length > 0))'
```

Expected: a JSON array containing exactly `Alpine`, `Alpine_Python`, `Debian`, `Go`, `NodeJS`, `Rust`, `Ubuntu` (7 entries — `NetworkTools` correctly excluded since it has no `Dockerfile`).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI: per-environment Docker build+hadolint, shellcheck, PSScriptAnalyzer, bats"
```

---

## Task 11: Add `.github/workflows/publish.yml`

**Files:**
- Create: `.github/workflows/publish.yml`

**Interfaces:**
- Consumes: the same `discover` logic pattern as Task 10 (duplicated rather than shared via a composite action — acceptable for two ~6-line blocks in a repo this size).
- Produces: `ghcr.io/modem7/docker-devenv-<slug>:latest` and `:<short-sha>` images that `devmenu.sh`/`devmenu.ps1`'s `pull_image`/`Invoke-Pull` (Tasks 2/8) already reference.

- [ ] **Step 1: Write the workflow**

```yaml
name: Publish Images

on:
  push:
    branches: [master]
    paths:
      - 'Environments/**'
  schedule:
    - cron: '0 3 * * 1'
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  discover:
    runs-on: ubuntu-latest
    outputs:
      build_environments: ${{ steps.list.outputs.build_environments }}
    steps:
      - uses: actions/checkout@v4
      - id: list
        run: |
          envs=$(for d in Environments/*/; do
            name=$(basename "$d")
            if [ -f "${d}Dockerfile" ]; then
              printf '%s\n' "$name"
            fi
          done | sort)
          json=$(printf '%s\n' "$envs" | jq -R -s -c 'split("\n") | map(select(length > 0))')
          echo "build_environments=$json" >> "$GITHUB_OUTPUT"

  publish:
    needs: discover
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        environment: ${{ fromJson(needs.discover.outputs.build_environments) }}
    steps:
      - uses: actions/checkout@v4
      - name: Compute image slug and short sha
        id: meta
        run: |
          slug=$(echo "${{ matrix.environment }}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
          echo "slug=$slug" >> "$GITHUB_OUTPUT"
          echo "short_sha=${GITHUB_SHA:0:7}" >> "$GITHUB_OUTPUT"
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push ${{ matrix.environment }}
        uses: docker/build-push-action@v6
        with:
          context: Environments/${{ matrix.environment }}
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/docker-devenv-${{ steps.meta.outputs.slug }}:latest
            ghcr.io/${{ github.repository_owner }}/docker-devenv-${{ steps.meta.outputs.slug }}:${{ steps.meta.outputs.short_sha }}
```

- [ ] **Step 2: Validate YAML syntax locally**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/publish.yml')); print('valid YAML')"
```

Expected: `valid YAML`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/publish.yml
git commit -m "Add publish workflow: multi-arch GHCR images on merge to master + weekly cron"
```

- [ ] **Step 4: Flag for follow-up verification**

Note in the PR description (Task 13) that the actual registry push can only be verified after this branch merges to `master` (it doesn't trigger on pull requests) — watch the first scheduled/merge-triggered run in the Actions tab once merged.

---

## Task 12: Rewrite `README.md`

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the final environment catalog (Tasks 6/7), both menu scripts (Tasks 2/8), the customization/workspace contracts (Task 2), devcontainer support (Task 9), and the CI/publish pipeline (Tasks 10/11) — this task just documents what every prior task built.

- [ ] **Step 1: Replace the file**

```markdown
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
![image](https://user-images.githubusercontent.com/4349962/198807913-eefcc8ae-8e20-42a3-8879-44adb4795bcf.png)
```

- [ ] **Step 2: Verify every link target exists**

```bash
for f in Environments/Alpine/README.md Environments/Alpine_Python/README.md \
         Environments/Debian/README.md Environments/Ubuntu/README.md \
         Environments/NodeJS/README.md Environments/Go/README.md \
         Environments/Rust/README.md Environments/NetworkTools/README.md; do
    [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
```

Expected: 8 `OK:` lines, no `MISSING:`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Rewrite README for public use: quickstart, environment table, customization docs"
```

---

## Task 13: End-to-end verification, push, and open the PR

**Files:** none (verification only).

**Interfaces:** exercises the full system built by Tasks 1–12 together.

- [ ] **Step 1: Full local verification sweep**

```bash
bash -n devmenu.sh && shellcheck devmenu.sh && echo "devmenu.sh OK"
bats tests/devmenu.bats
for f in Environments/*/Dockerfile; do
    echo "=== $f ==="
    docker run --rm -i hadolint/hadolint < "$f" || true
done
python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ['.github/workflows/ci.yml','.github/workflows/publish.yml']]; print('workflows valid')"
```

Expected: all green, matching each task's own verification from earlier (no new failures).

- [ ] **Step 2: End-to-end smoke test for a second buildable environment (belt-and-suspenders beyond Task 2's Alpine test) and the NetworkTools passthrough**

```bash
rm -rf /tmp/devmenu-final-ws1 /tmp/devmenu-final-ws2
DEVMENU_ENV=Ubuntu DEVMENU_ACTION=build DEVMENU_WORKSPACE=/tmp/devmenu-final-ws1 \
    DEVMENU_CMD="pwd && whoami" ./devmenu.sh
DEVMENU_ENV=NetworkTools DEVMENU_WORKSPACE=/tmp/devmenu-final-ws2 \
    DEVMENU_CMD="pwd && which nmap tcpdump" ./devmenu.sh
rm -rf /tmp/devmenu-final-ws1 /tmp/devmenu-final-ws2
docker rmi ubuntu:dev
```

Expected: first run prints `/workspace` then `root`; second run pulls `nicolaka/netshoot:latest`, skips the pull/build prompt, and prints `/workspace` followed by paths to `nmap` and `tcpdump`.

- [ ] **Step 3: Confirm the working tree is clean and review the full diff**

```bash
git status --porcelain
git log --oneline origin/master..HEAD
git diff --stat origin/master..HEAD
```

Expected: no untracked/modified files; the commit list matches Tasks 1–12 in order; the diffstat shows the expected file set (no accidental leftovers from smoke testing).

- [ ] **Step 4: Push and open the PR**

```bash
git push origin modernize-devenv
gh pr create --title "Modernize docker-devenv: CI, fzf menu, customization, new environments" --body "$(cat <<'EOF'
## Summary
- Rewrites devmenu.sh (fzf UX, local discovery, no more remote-context builds) and adds a devmenu.ps1 native Windows port
- Adds ARG EXTRA_PACKAGES customization and persistent /workspace volume mounts to every buildable environment
- Replaces the hardcoded Apt-Cacher-NG IP with auto-apt-proxy auto-discovery on Debian/Ubuntu-family Dockerfiles
- Adds NodeJS, Go, and Rust environments; replaces Alpine_Network_Debug with a nicolaka/netshoot passthrough (NetworkTools)
- Adds devcontainer.json to every environment for VS Code Dev Containers support
- Adds real CI: per-environment Docker build + hadolint, shellcheck, PSScriptAnalyzer, bats-core unit tests for devmenu.sh
- Adds a publish workflow: multi-arch (amd64/arm64) images pushed to GHCR on merge to master + weekly cron for security patches
- Rewrites the README for a first-time visitor

## Design
See docs/superpowers/specs/2026-08-08-modernization-design.md for the full design doc.

## Known follow-ups
- devmenu.ps1 has been code-reviewed for parity with devmenu.sh and will be linted by CI's psscriptanalyzer job, but has not been run on an actual Windows machine yet.
- publish.yml's actual registry push can only be verified after this merges to master (it doesn't trigger on PRs) — watch the first run in the Actions tab post-merge.

## Test plan
- [x] Every Dockerfile builds locally, with and without EXTRA_PACKAGES (Tasks 4-6)
- [x] hadolint clean (only pre-existing, intentional DL3006/DL3008 warnings on apt-based images)
- [x] devmenu.sh: bash -n, shellcheck, and bats all pass; end-to-end smoke tests for a build-path environment, an external-image environment, and a second build-path environment
- [x] All 8 devcontainer.json files are valid JSON
- [x] Both workflow YAML files parse successfully
- [ ] CI itself passing on this PR (check the Actions tab once opened)
- [ ] Manual run of devmenu.ps1 on a real Windows machine
EOF
)"
```

- [ ] **Step 5: Watch the CI run and fix forward if anything fails**

```bash
gh pr checks --watch
```

If any check fails, read the failure, fix the specific issue in a new commit on this branch (don't force-push over history unless asked), and re-push. Do not merge until CI is green — merging is a separate, explicit decision for the user to make.
