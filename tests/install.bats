#!/usr/bin/env bats
#
# r770-install.sh is the resumable orchestrator for the R770 install
# sub-projects. What matters: BUILD-STATE's Status cell is parsed correctly
# (and never silently defaults on a parse failure), gated steps stop for an
# explicit --confirm, unregistered steps halt cleanly, and a failure for
# real halts the whole run.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-install.sh"
    export T="$BATS_TEST_TMPDIR"
    export BS="$T/BUILD-STATE.md"
}

make_build_state() {
    cat > "$BS" <<'EOF'
# Build State

## Phases

| # | Phase | Depends on | Destructive? | Status | Evidence |
|---|---|---|---|---|---|
| 1 | Hardware discovery | — | No | **VERIFIED** | `inventory/x.md` |
| 3 | Storage layout | 1,2 | **Lower than planned** | **READY** *(note)* | — |
| 10 | Malcolm deployment | 6,9,3 | No | NOT STARTED | — |
EOF
}

@test "phase_status reads a plain VERIFIED status" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 1 '$BS'"
    [ "$status" -eq 0 ]
    [ "$output" = "VERIFIED" ]
}

@test "phase_status strips markdown bold and trailing notes" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 3 '$BS'"
    [ "$status" -eq 0 ]
    [ "$output" = "READY" ]
}

@test "phase_status reads a plain NOT STARTED status" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 10 '$BS'"
    [ "$status" -eq 0 ]
    [ "$output" = "NOT STARTED" ]
}

@test "phase_status fails loudly when the phase row is missing" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 99 '$BS'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no row for phase 99"* ]]
}

@test "phase_status fails loudly when the Status cell has no recognized keyword" {
    cat > "$BS" <<'EOF'
| # | Phase | Depends on | Destructive? | Status | Evidence |
|---|---|---|---|---|---|
| 5 | Networking | 4 | High | *(garbled)* | — |
EOF
    run bash -c "source '$SCRIPT' --source-only; phase_status 5 '$BS'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unrecognized status"* ]]
}

@test "STEP_IDS lists storage before the sub-project 2 steps, in dependency order" {
    run bash -c "source '$SCRIPT' --source-only; echo \"\${STEP_IDS[@]}\""
    [ "$status" -eq 0 ]
    [ "$output" = "storage labca malcolm portal ufw" ]
}

@test "step_gated is true for storage and ufw, false for labca/malcolm/portal" {
    run bash -c "source '$SCRIPT' --source-only; step_gated storage"
    [ "$status" -eq 0 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated ufw"
    [ "$status" -eq 0 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated labca"
    [ "$status" -eq 1 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated malcolm"
    [ "$status" -eq 1 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated portal"
    [ "$status" -eq 1 ]
}

@test "step_build_state_phase resolves storage to phase 3 and fails for labca" {
    run bash -c "source '$SCRIPT' --source-only; step_build_state_phase storage"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
    run bash -c "source '$SCRIPT' --source-only; step_build_state_phase labca"
    [ "$status" -eq 1 ]
}

@test "step_registered is false for a step with no adapter functions defined" {
    run bash -c "source '$SCRIPT' --source-only; step_registered notreal"
    [ "$status" -eq 1 ]
}

@test "step_registered is true once the four verb functions exist" {
    run bash -c "source '$SCRIPT' --source-only
        storage_check() { :; }; storage_plan() { :; }
        storage_apply() { :; }; storage_verify() { :; }
        step_registered storage"
    [ "$status" -eq 0 ]
}

fake_adapter() {
    # fake_adapter <id> <check_exit> <apply_exit> <verify_exit>
    local id=$1
    eval "${id}_check() { echo \"${id}_check\" >> \"$T/calls\"; return $2; }"
    eval "${id}_plan()  { echo \"${id}_plan\"  >> \"$T/calls\"; return 0; }"
    eval "${id}_apply() { echo \"${id}_apply\" >> \"$T/calls\"; return $3; }"
    eval "${id}_verify(){ echo \"${id}_verify\" >> \"$T/calls\"; return $4; }"
}

@test "run_step skips a step whose mapped BUILD-STATE phase is already VERIFIED" {
    make_build_state   # phase 1 is VERIFIED in the fixture; alias storage to it for this test
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { [ \"\$1\" = storage ] && echo 1 || return 1; }
        $(declare -f fake_adapter); fake_adapter storage 0 0 0
        run_step storage '$BS'"
    [ "$status" -eq 0 ]
    [ ! -f "$T/calls" ]   # never even called check — BUILD-STATE already says VERIFIED
}

@test "run_step halts with exit 3 on the first unregistered step" {
    # "notreal" stands in for a future sub-project (e.g. docker) that has a
    # STEP_IDS entry but no script yet — every real step today is registered.
    run bash -c "source '$SCRIPT' --source-only; run_step notreal '$BS'"
    [ "$status" -eq 3 ]
    [[ "$output" == *"not yet implemented"* ]]
}

@test "run_step halts with exit 2 at a gated step with no --confirm, printing the plan" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter); fake_adapter storage 0 0 0
        run_step storage '$BS'"
    [ "$status" -eq 2 ]
    grep -q storage_plan "$T/calls"
    ! grep -q storage_apply "$T/calls"
}

@test "run_step proceeds through apply+verify at a gated step when --confirm is given" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter); fake_adapter storage 0 0 0
        run_step storage '$BS' --confirm"
    [ "$status" -eq 0 ]
    grep -q storage_check "$T/calls"
    grep -q storage_apply "$T/calls"
    grep -q storage_verify "$T/calls"
}

@test "run_step prints the unmet-dependency message rather than silently dying to errexit" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        storage_check() { return 2; }; storage_plan() { :; }; storage_apply() { :; }; storage_verify() { :; }
        run_step storage '$BS'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unmet dependency"* ]]
}

@test "run_step re-checks before apply across two separate invocations (not trusting an earlier plan)" {
    # Each CLI invocation of r770-install.sh is its own process; this
    # exercises that reality directly rather than two bare calls in one
    # process (which set -e would short-circuit after the first failure).
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        storage_check() { echo storage_check >> '$T/calls'; return 0; }
        storage_plan() { :; }; storage_apply() { :; return 0; }; storage_verify() { :; return 0; }
        run_step storage '$BS'"
    [ "$status" -eq 2 ]
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        storage_check() { echo storage_check >> '$T/calls'; return 0; }
        storage_plan() { :; }; storage_apply() { :; return 0; }; storage_verify() { :; return 0; }
        run_step storage '$BS' --confirm"
    [ "$status" -eq 0 ]
    [ "$(grep -c storage_check "$T/calls")" -eq 2 ]
}

@test "run_step surfaces a non-gated step's apply failure as exit 1 with real output" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter); fake_adapter labca 0 1 0
        run_step labca '$BS'"
    [ "$status" -eq 1 ]
}

@test "run_step passes through exit 4 from an adapter (ufw-style armed state) unchanged" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        ufw_check() { return 0; }; ufw_plan() { :; }
        ufw_apply() { echo 'armed — needs a new-session confirm' >&2; return 4; }
        ufw_verify() { :; }
        run_step ufw '$BS' --confirm"
    [ "$status" -eq 4 ]
}

@test "--list prints every step with its gated and registered status" {
    run bash "$SCRIPT" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"storage"*"gated"* ]]
    [[ "$output" == *"labca"*"not gated"* ]]
}

@test "an unknown flag exits 1 with a usage message" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}

@test "main stops the whole run at the first halting step and does not run later ones" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter)
        fake_adapter storage 0 0 0
        main --only storage,notreal --confirm"
    [ "$status" -eq 3 ]   # notreal has no adapter — stands in for a future sub-project
    grep -q storage_apply "$T/calls"
}
