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
