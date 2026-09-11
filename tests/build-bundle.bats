#!/usr/bin/env bats
#
# The orchestrator's value is ORDER and REFUSAL, so that is what these test.
# Every child script is stubbed and records itself to an order log; the suite
# downloads nothing, reaches no registry, and builds no real bundle.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-build-bundle.sh"
    ORDER="$BATS_TEST_TMPDIR/order.log"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    : > "$ORDER"
    export BUILD_ORDER_LOG="$ORDER"
    export BUILD_BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
    export BUILD_ASSUME_YES=1          # no prompt unless a test wants one
    mkdir -p "$BUILD_BUNDLE_DIR"

    child preflight 0
    child fetch     0
    child manifest  0
    child verify    0
}

# child <name> <exit> — a stub that logs itself, then exits with <exit>
child() {
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$BUILD_ORDER_LOG"\nexit %s\n' "$1" "$2" \
        > "$BIN/$1"
    chmod +x "$BIN/$1"
    case "$1" in
        preflight) export BUILD_PREFLIGHT="$BIN/preflight" ;;
        fetch)     export BUILD_FETCH="$BIN/fetch" ;;
        manifest)  export BUILD_MANIFEST_CMD="$BIN/manifest" ;;
        verify)    export BUILD_VERIFY_CMD="$BIN/verify" ;;
    esac
}

order() { cut -d' ' -f1 "$ORDER" | tr '\n' ' '; }

@test "the happy path runs preflight, fetch, manifest, verify — in that order" {
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(order)" = "preflight fetch manifest verify " ]
}

@test "a failed preflight aborts BEFORE the fetch downloads anything" {
    child preflight 1
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [ "$(order)" = "preflight " ]
}

@test "preflight warnings do not abort when the operator has accepted them" {
    child preflight 2
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(order)" == preflight\ fetch* ]]
}

@test "preflight warnings DO stop an unattended run that has not accepted them" {
    child preflight 2
    unset BUILD_ASSUME_YES
    run "$SCRIPT" --non-interactive
    echo "$output"
    [ "$status" -ne 0 ]
    [ "$(order)" = "preflight " ]
}

@test "a failed fetch does not go on to manifest or verify" {
    child fetch 1
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
    [ "$(order)" = "preflight fetch " ]
}

@test "the manifest is regenerated AFTER the manual-items pause, never before" {
    # The documented footgun: a manifest written before the Dell firmware and
    # licensed appliances were staged cannot see them, and the gate then passes
    # a bundle whose manual content is entirely unverified.
    run "$SCRIPT"
    echo "$output"
    m=$(grep -n '^manifest' "$ORDER" | cut -d: -f1)
    f=$(grep -n '^fetch'    "$ORDER" | cut -d: -f1)
    [ "$f" -lt "$m" ]
    [[ "$output" == *"dell"* ]]
    [[ "$output" == *"appliance"* ]]
}

@test "the gate runs --strict, so warnings cannot ride out on the media" {
    run "$SCRIPT"
    echo "$output"
    grep -q '^verify.*--strict' "$ORDER"
}

@test "a failed gate fails the whole run" {
    child verify 1
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 1 ]
}

@test "a gate that warns surfaces as warnings, not silent success" {
    child verify 2
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 2 ]
}

@test "an unknown option is rejected rather than ignored" {
    run "$SCRIPT" --wat
    echo "$output"
    [ "$status" -ne 0 ]
}

# --- pack mode ---------------------------------------------------------------

@test "--pack emits a self-extracting script carrying all four scripts" {
    run "$SCRIPT" --pack
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    for s in r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh; do
        grep -q "$s" "$BATS_TEST_TMPDIR/packed.sh"
    done
}

@test "the packed script is valid bash" {
    run "$SCRIPT" --pack
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    run bash -n "$BATS_TEST_TMPDIR/packed.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "a packed bundle-builder is gitignored — base64 hides pins from the guard" {
    cd "$BATS_TEST_DIRNAME/.."
    run git check-ignore -q r770-bundle-builder.sh
    [ "$status" -eq 0 ]
}
