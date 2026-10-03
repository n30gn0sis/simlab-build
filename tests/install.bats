#!/usr/bin/env bats
#
# r770-install.sh is the resumable orchestrator for the R770 install
# sub-projects. What matters: BUILD-STATE's Status cell is parsed correctly
# (and never silently defaults on a parse failure), gated steps stop for an
# explicit --confirm, unregistered steps halt cleanly, and a failure for
# real halts the whole run.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-install.sh"
    T="$BATS_TEST_TMPDIR"
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
