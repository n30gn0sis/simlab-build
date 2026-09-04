#!/usr/bin/env bats

load helpers/fixtures

setup() {
    BUNDLE="$BATS_TEST_TMPDIR/bundle-20260904"
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-bundle.sh"
    make_bundle "$BUNDLE"
}

@test "manifest covers every payload file" {
    run "$SCRIPT" manifest "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'apt/example_1.0_amd64.deb'  "$BUNDLE/MANIFEST.sha256"
    grep -q 'BUNDLE_NOTES.md'            "$BUNDLE/MANIFEST.sha256"
    grep -q 'dell/README.txt'            "$BUNDLE/MANIFEST.sha256"
}

@test "manifest excludes itself and .stamps" {
    run "$SCRIPT" manifest "$BUNDLE"
    [ "$status" -eq 0 ]
    ! grep -q 'MANIFEST.sha256' "$BUNDLE/MANIFEST.sha256"
    ! grep -q '.stamps'         "$BUNDLE/MANIFEST.sha256"
}

@test "refuses an empty bundle instead of writing a '-' entry" {
    empty="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$empty"
    run "$SCRIPT" manifest "$empty"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to write an empty manifest"* ]]
    [ ! -e "$empty/MANIFEST.sha256" ]
}

@test "refuses when an incomplete download is present" {
    echo half > "$BUNDLE/malcolm/malcolm-images-26.08.0.tar.gz.part"
    run "$SCRIPT" manifest "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"incomplete download"* ]]
    [ ! -e "$BUNDLE/MANIFEST.sha256" ]
}

@test "manifest is reproducible" {
    "$SCRIPT" manifest "$BUNDLE"
    cp "$BUNDLE/MANIFEST.sha256" "$BATS_TEST_TMPDIR/first"
    "$SCRIPT" manifest "$BUNDLE"
    diff "$BATS_TEST_TMPDIR/first" "$BUNDLE/MANIFEST.sha256"
}

@test "handles a filename with a space" {
    echo dup > "$BUNDLE/dell/Broadcom NIC firmware.EXE"
    run "$SCRIPT" manifest "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'Broadcom NIC firmware.EXE' "$BUNDLE/MANIFEST.sha256"
    run bash -c "cd '$BUNDLE' && sha256sum -c --quiet MANIFEST.sha256"
    [ "$status" -eq 0 ]
}

@test "leaves no temp file inside the bundle" {
    "$SCRIPT" manifest "$BUNDLE"
    run find "$BUNDLE" -name 'MANIFEST.sha256.*'
    [ -z "$output" ]
}
