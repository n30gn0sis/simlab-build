#!/usr/bin/env bats
#
# The staging preflight decides whether a host may build a bundle. Its job is
# to fail BEFORE hours of downloading, so every check here asserts the refusal
# happens, not merely that the script runs.
#
# Everything is driven through stubs and an injected os-release: the suite must
# reach no daemon, read no real disk, and pass identically on Ubuntu and RHEL.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-staging-preflight.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    export PATH="$BIN:$PATH"
    export PREFLIGHT_SKIP_EGRESS=1          # never touch a registry from a test
    export PREFLIGHT_BUNDLE_DIR="$BATS_TEST_TMPDIR"
    os_release ubuntu 24.04
    stub systemd-detect-virt 'echo kvm'
    stub df 'echo "/dev/x 1 1 999999999999 1% /"'
    stub pigz 'exit 0'          # a healthy host has it; one test removes it
}

os_release() {  # os_release <id> <version_id>
    printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s %s"\n' "$1" "$2" "$1" "$2" \
        > "$BATS_TEST_TMPDIR/os-release"
    export PREFLIGHT_OS_RELEASE="$BATS_TEST_TMPDIR/os-release"
}

stub() {  # stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

unstub() { rm -f "$BIN/$1"; }

@test "a healthy Ubuntu host with docker passes" {
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "a healthy RHEL 8 host with rootful podman passes" {
    os_release rhel 8.10
    unstub docker
    stub podman 'case "$1" in --version) echo "podman version 4.9.4";; info) exit 0;; esac'
    stub id 'echo 0'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "RHEL is recognised as a supported staging OS, not rejected" {
    os_release rhel 8.10
    unstub docker
    stub podman 'case "$1" in --version) echo "podman version 4.9.4";; info) exit 0;; esac'
    stub id 'echo 0'
    run "$SCRIPT"
    echo "$output"
    [[ "$output" == *"rhel"* ]] || [[ "$output" == *"RHEL"* ]]
    [[ "$output" != *"unsupported"* ]]
}

@test "an LXC container is refused — Docker in LXC fights overlayfs" {
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    stub systemd-detect-virt 'echo lxc'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lxc"* ]]
}

@test "podman older than 3.0 is refused — no --multi-image-archive" {
    os_release rhel 8.4
    unstub docker
    stub podman 'case "$1" in --version) echo "podman version 2.2.1";; info) exit 0;; esac'
    stub id 'echo 0'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"multi-image-archive"* ]] || [[ "$output" == *"3.0"* ]]
}

@test "rootless podman is refused, and says to use sudo" {
    os_release rhel 8.10
    unstub docker
    stub podman 'case "$1" in --version) echo "podman version 4.9.4";; info) exit 0;; esac'
    stub id 'echo 1000'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo"* ]]
}

@test "Docker CE on RHEL is refused — it conflicts with container-tools" {
    os_release rhel 8.10
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"container-tools"* ]]
}

@test "too little free disk is refused before any download starts" {
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    stub df 'echo "/dev/x 1 1 1048576 99% /"'      # 1 GiB free, in 1K blocks
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"150"* ]]
}

@test "no container runtime at all is refused" {
    unstub docker
    unstub podman
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
}

@test "a broken daemon is refused even when the client exists" {
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 1;; esac'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
}

@test "an unsupported distro warns but does not fail" {
    os_release fedora 41
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 2 ]
}

@test "the verifier that must ship inside the bundle is checked for" {
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    run "$SCRIPT"
    echo "$output"
    [[ "$output" == *"r770-bundle.sh"* ]]
}

@test "pigz absent warns but does not fail — gzip still works, just slower" {
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; info) exit 0;; esac'
    unstub pigz
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pigz"* ]]
}
