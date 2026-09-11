#!/usr/bin/env bash
#
# r770-malcolm-deploy.sh — load Malcolm's images from a bundle and prove the
# load was COMPLETE. Runs with no network, which is the condition it must
# satisfy on the real air-gapped R770.
#
#   load <bundle-dir>          docker load the tarball, then assert every tag
#   assert-tags <bundle-dir>   the tag check alone
#
# `docker load` reports success even when the resulting tag set is incomplete,
# which is why import-bundle.md step 3b requires verifying loaded tags against
# the bundle's own image-list files.
set -euo pipefail

die() { echo "r770-malcolm-deploy: $*" >&2; exit 1; }

image_list() {
    local f="$1/malcolm/image-list.txt"
    [ -s "$f" ] || die "missing or empty $f — is this a bundle directory?"
    local out
    out=$(grep -vE '^[[:space:]]*(#|$)' "$f" || true)
    [ -n "$out" ] || die "no image tags in $f — only comments or blank lines"
    printf '%s\n' "$out"
}

cmd_assert_tags() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: assert-tags <bundle-dir>"
    [ -d "$dir" ] || die "not a directory: $dir"

    # Read the list BEFORE the loop, into the current shell. Feeding the loop
    # from `< <(image_list ...)` puts image_list in a subshell, where its die()
    # exits that subshell only: the loop then sees EOF, `missing` stays 0, and
    # a bundle with NO image list at all is reported "all images present".
    # On the R770 that would wave through an incomplete load -- the precise
    # failure this script exists to catch.
    local list present missing=0
    list=$(image_list "$dir")
    present=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

    while IFS= read -r want; do
        [ -n "$want" ] || continue
        if printf '%s\n' "$present" | grep -qxF "$want"; then
            echo "ok      $want"
        else
            echo "MISSING $want"
            missing=$((missing + 1))
        fi
    done <<< "$list"

    [ "$missing" -eq 0 ] ||
        die "$missing image(s) missing after load — the tarball is incomplete or the load failed"
    echo "all images present"
}

cmd_load() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: load <bundle-dir>"
    local tar
    tar=$(find "$dir/malcolm" -maxdepth 1 -name 'malcolm-images-*.tar.gz' | head -1)
    [ -n "$tar" ] || die "no malcolm-images-*.tar.gz under $dir/malcolm"
    echo "loading $tar ..."
    docker load -i "$tar"
    cmd_assert_tags "$dir"
}

case "${1:-}" in
    load)        shift; cmd_load "$@" ;;
    assert-tags) shift; cmd_assert_tags "$@" ;;
    *)           die "usage: r770-malcolm-deploy.sh load|assert-tags <bundle-dir>" ;;
esac
