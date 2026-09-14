#!/usr/bin/env bats
#
# The fetch downloads for hours and cannot run in a sandbox, so these tests
# cover only its SELECTION logic: which stages a given command line runs, in
# what order, and that --list/--dry-run touch no network. One real section
# (manual) is run for real -- it writes a README and nothing else.
#
# Every network tool is stubbed to log and fail, so an unexpected download
# attempt shows up as a line in $NET rather than as a hang.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-offline-fetch.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    NET="$BATS_TEST_TMPDIR/net.log"; : > "$NET"
    export BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
    export SEED_FROM=none
    export FETCH_NET_LOG="$NET"
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; *) echo "docker $*" >> "$FETCH_NET_LOG"; exit 1;; esac'
    stub curl   'echo "curl $*" >> "$FETCH_NET_LOG"; exit 7'
    stub wget   'echo "wget $*" >> "$FETCH_NET_LOG"; exit 4'
    PATH="$BIN:$PATH"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

ALL="preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual manifest"

# selected <output> -- the stage names the dry run says it would execute, in order
selected() { echo "$1" | grep -oE '^\s*(would run|run) +[a-z0-9]+' | awk '{print $NF}' | tr '\n' ' ' | sed 's/ $//'; }

@test "--list names every stage in fixed order" {
    run "$SCRIPT" --list
    echo "$output"
    [ "$status" -eq 0 ]
    for s in $ALL; do [[ "$output" == *"$s"* ]]; done
    [ "$(echo "$output" | grep -oE '^\s*[a-z0-9]+' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" = "$ALL" ]
    [ ! -s "$NET" ]
}

@test "--list shows a stage as done when its completion marker exists" {
    mkdir -p "$BUNDLE_DIR/.stamps" "$BUNDLE_DIR/dell"
    touch "$BUNDLE_DIR/.stamps/01-apt.done"; echo x > "$BUNDLE_DIR/dell/README.txt"
    run "$SCRIPT" --list
    echo "$output"
    [[ "$(echo "$output" | grep -E '^\s*apt ')" == *done* ]]
    [[ "$(echo "$output" | grep -E '^\s*manual ')" == *done* ]]
    [[ "$(echo "$output" | grep -E '^\s*iso ')" != *done* ]]
}

@test "--dry-run with no selection would run every stage, in order, touching nothing" {
    run "$SCRIPT" --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(selected "$output")" = "$ALL" ]
    [ ! -s "$NET" ]
}

@test "--only runs the named stages in the fixed order, and never implies manifest" {
    run "$SCRIPT" --only enrichment,apt --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(selected "$output")" = "apt enrichment" ]
}

@test "--skip removes stages and keeps the rest in order" {
    run "$SCRIPT" --skip docs,manifest,preflight --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(selected "$output")" = "apt iso malcolm monitoring gns3 appliances enrichment manual" ]
}

@test "an unknown stage name is rejected by name, before anything runs" {
    run "$SCRIPT" --only nope --dry-run
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
    [ ! -s "$NET" ]
}

@test "an unknown option is rejected rather than ignored" {
    run "$SCRIPT" --bogus
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--bogus"* ]]
}

@test "--only manual runs for real: writes the Dell README, touches no network, runs no manifest" {
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/dell/README.txt" ]
    [ ! -e "$BUNDLE_DIR/MANIFEST.sha256" ]
    [ ! -s "$NET" ]
}

@test "a sectioned run appends to BUNDLE_NOTES.md instead of wiping the full run's notes" {
    mkdir -p "$BUNDLE_DIR"
    printf '# earlier full run\n- Malcolm images saved\n' > "$BUNDLE_DIR/BUNDLE_NOTES.md"
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'Malcolm images saved' "$BUNDLE_DIR/BUNDLE_NOTES.md"
    grep -qE 'rerun|section' "$BUNDLE_DIR/BUNDLE_NOTES.md"
}
