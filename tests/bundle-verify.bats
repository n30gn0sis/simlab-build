#!/usr/bin/env bats

load helpers/fixtures

setup() {
    BUNDLE="$BATS_TEST_TMPDIR/bundle-20260904"
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-bundle.sh"
    make_bundle "$BUNDLE"
    stage_manual "$BUNDLE"          # a bundle ready to travel
    "$SCRIPT" manifest "$BUNDLE"
}

# ── the three defects confirmed against the old command (exit 0 on all three) ──

@test "a manual file added after the manifest fails as a stale manifest" {
    echo "fake fortigate qcow2" > "$BUNDLE/gns3/appliances/fortios.qcow2"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not in MANIFEST.sha256"* ]]
    [[ "$output" == *"fortios.qcow2"* ]]
}

@test "a leftover .part fails" {
    echo half > "$BUNDLE/malcolm/malcolm-images-26.08.0.tar.gz.part"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"incomplete download"* ]]
}

@test "a manifest generated from empty input fails, and does not hang" {
    printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -\n' \
        > "$BUNDLE/MANIFEST.sha256"
    # stdin is deliberately left OPEN but silent. To sha256sum, the '-' entry
    # means stdin, so an unguarded checker blocks here until killed — and it
    # only misbehaves this way when stdin is open, which is the interactive
    # case, not the harness case. timeout turns that hang into status 124.
    # A '-' entry is poison twice over, both verified directly against
    # sha256sum: with stdin CLOSED it matches the empty-input hash and returns
    # 0 (the bundle "passes"), and with stdin OPEN it blocks forever waiting on
    # input. So this runs with stdin deliberately open and under a timeout, and
    # asserts the end state: refused, not hung. Three independent guards in the
    # script produce that outcome, so this asserts behaviour rather than
    # isolating any one of them.
    run timeout 10 bash -c '"$1" verify "$2" < <(sleep 30)' _ "$SCRIPT" "$BUNDLE"
    echo "$output"
    [ "$status" -ne 124 ]          # 124 == it hung
    [ "$status" -eq 1 ]
    [[ "$output" == *"verifies nothing"* ]]
}

# ── ordinary integrity ────────────────────────────────────────────────────────

@test "a complete, unmodified bundle passes" {
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "a modified file fails" {
    echo tampered > "$BUNDLE/apt/example_1.0_amd64.deb"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checksum verification failed"* ]]
}

@test "a deleted file fails" {
    rm "$BUNDLE/enrichment/oui.txt"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
}

@test "a missing manifest fails" {
    rm "$BUNDLE/MANIFEST.sha256"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be trusted"* ]]
}

@test "a bundle whose .stamps changed still passes" {
    touch "$BUNDLE/.stamps/docs"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
}

# ── WARN triage: distinguishable from both pass and failure ───────────────────

@test "unresolved WARN lines in the notes warn but do not fail" {
    echo "- WARN: oui.txt fetch failed — retry manually" >> "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESULT: PASS WITH WARNINGS"* ]]
    [[ "$output" == *"oui.txt fetch failed"* ]]
}

@test "--strict promotes warnings to failure" {
    echo "- WARN: docs mirror failed" >> "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE" --strict
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RESULT: FAIL (--strict)"* ]]
}

@test "unstaged manual categories warn" {
    rm "$BUNDLE/dell/BIOS_R770_1.7.5.EXE" \
       "$BUNDLE/gns3/appliances/vios-adventerprisek9.qcow2"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"dell/ holds only README.txt"* ]]
    [[ "$output" == *"gns3/appliances/ holds only README.txt"* ]]
}

@test "a missing BUNDLE_NOTES.md warns" {
    rm "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"BUNDLE_NOTES.md missing"* ]]
}

@test "a failure outranks a warning" {
    echo "- WARN: something" >> "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    echo tampered > "$BUNDLE/apt/example_1.0_amd64.deb"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RESULT: FAIL"* ]]
}

@test "an unknown option is rejected" {
    run "$SCRIPT" verify "$BUNDLE" --wat
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "a manifest with a GNU-escaped path is refused" {
    # GNU sha256sum prefixes a line with a backslash when the path contains a
    # backslash or newline, and encodes the path. Such a manifest cannot be
    # round-tripped by this tool, so it must be refused rather than
    # half-understood. Regression guard: this branch was silently broken twice
    # while fixing an unrelated lint warning, and nothing caught it.
    printf '\\e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  ./odd\\path\n' \
        >> "$BUNDLE/MANIFEST.sha256"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"escaped path"* ]]
}
