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
