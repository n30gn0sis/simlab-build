#!/usr/bin/env bats
# Test the GENERATED RULES, not their application. Applying real firewall
# rules from a test suite is how a machine locks itself out.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-airgap-sim.sh"
    export AIRGAP_DRY_RUN=1
    export AIRGAP_LAN=192.168.4.0/22
}

@test "block always exempts the management LAN" {
    run "$SCRIPT" block
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"192.168.4.0/22"* ]]
    [[ "$output" == *"ACCEPT"* ]]
}

@test "block always exempts loopback" {
    run "$SCRIPT" block
    [[ "$output" == *"127.0.0.0/8"* ]]
}

@test "the LAN accept rule precedes the catch-all drop" {
    run "$SCRIPT" block
    lan=$(echo "$output" | grep -n '192.168.4.0/22' | head -1 | cut -d: -f1)
    drop=$(echo "$output" | grep -n 'DROP' | tail -1 | cut -d: -f1)
    [ "$lan" -lt "$drop" ]
}

@test "block refuses to run without scheduling an auto-revert" {
    run "$SCRIPT" block
    [[ "$output" == *"auto-revert"* ]]
}

@test "an invalid --minutes value is rejected, not silently defaulted" {
    run "$SCRIPT" block --minutes abc
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"minutes"* ]]
}

@test "unblock is idempotent" {
    run "$SCRIPT" unblock
    [ "$status" -eq 0 ]
    run "$SCRIPT" unblock
    [ "$status" -eq 0 ]
}

# --- Forwarded-path coverage -------------------------------------------------
# Container traffic is FORWARDED, not locally generated, so it never traverses
# OUTPUT. A simulator that filters only OUTPUT leaves running containers with
# live internet while reporting BLOCKED -- the rehearsal would certify "deploys
# offline" against a stack that was quietly online. Docker publishes the
# DOCKER-USER chain for precisely this hook.

@test "block also filters the forwarded path containers actually use" {
    run "$SCRIPT" block
    echo "$output"
    [[ "$output" == *"DOCKER-USER"* ]]
}

@test "the forwarded path gets its own catch-all drop" {
    run "$SCRIPT" block
    echo "$output"
    [ "$(echo "$output" | grep -c 'DOCKER-USER.*DROP')" -ge 1 ]
}

@test "the forwarded path exempts the management LAN before dropping" {
    run "$SCRIPT" block
    lan=$(echo "$output" | grep -n 'DOCKER-USER.*192.168.4.0/22' | head -1 | cut -d: -f1)
    drop=$(echo "$output" | grep -n 'DOCKER-USER.*DROP' | tail -1 | cut -d: -f1)
    [ -n "$lan" ]
    [ "$lan" -lt "$drop" ]
}

@test "unblock tears down the forwarded-path rules too" {
    run "$SCRIPT" unblock
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DOCKER-USER"* ]] || [[ "$output" == *"dry run"* ]]
}

# --- status must never guess ---------------------------------------------------
# iptables -C exits 4 (not 1) when it cannot query the table at all -- the
# unprivileged case. Treating that as "rule absent" reports OPEN while egress
# is actually blocked: observed on the staging VM 2026-09-12, and it is exactly
# the false pass the simulator exists to prevent.

@test "status refuses to report OPEN when iptables cannot be queried" {
    unset AIRGAP_DRY_RUN
    stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
    printf '#!/bin/sh\necho "iptables v1.8: Permission denied (you must be root)" >&2\nexit 4\n' > "$stub/iptables"
    chmod +x "$stub/iptables"
    PATH="$stub:$PATH" run "$SCRIPT" status
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"OPEN"* ]]
    [[ "$output" == *"root"* ]]
}

@test "status still reports OPEN when iptables answers 'rule absent'" {
    unset AIRGAP_DRY_RUN
    stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/iptables"
    chmod +x "$stub/iptables"
    PATH="$stub:$PATH" run "$SCRIPT" status
    [ "$status" -eq 0 ]
    [[ "$output" == "OPEN" ]]
}

# --- the auto-revert must be cancellable ----------------------------------------
# The revert is a detached "sleep N; unblock". On 2026-09-12 a block, an unblock
# and a second block left the FIRST sleeper alive; it fired an hour later and
# silently removed the second block. Both unblock and a fresh block must kill a
# pending sleeper, and the sleeper must be findable -- so its PID is recorded.
# These run the real (non-dry) code path against a stub iptables that accepts
# everything, with the run dir relocated so nothing touches /run.

stub_iptables() {
    stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
    # -D must eventually fail (unblock loops "delete until absent"); all else succeeds
    printf '#!/bin/sh\ncase "$1" in -D) exit 1;; esac\nexit 0\n' > "$stub/iptables"; chmod +x "$stub/iptables"
    PATH="$stub:$PATH"; export PATH
    unset AIRGAP_DRY_RUN
    export AIRGAP_RUN_DIR="$BATS_TEST_TMPDIR/run"; mkdir -p "$AIRGAP_RUN_DIR"
}

@test "block records the auto-revert sleeper's PID" {
    stub_iptables
    run "$SCRIPT" block --minutes 1
    [ "$status" -eq 0 ]
    [ -s "$AIRGAP_RUN_DIR/r770-airgap-sim.pid" ]
    pid=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    kill -0 "$pid"
    "$SCRIPT" unblock >/dev/null
}

@test "unblock kills the pending auto-revert sleeper" {
    stub_iptables
    "$SCRIPT" block --minutes 1 >/dev/null
    pid=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    kill -0 "$pid"
    run "$SCRIPT" unblock
    [ "$status" -eq 0 ]
    sleep 0.5
    ! kill -0 "$pid" 2>/dev/null
    [ ! -e "$AIRGAP_RUN_DIR/r770-airgap-sim.pid" ]
}

@test "a second block cancels the first block's sleeper before scheduling its own" {
    stub_iptables
    "$SCRIPT" block --minutes 1 >/dev/null
    first=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    "$SCRIPT" block --minutes 2 >/dev/null
    second=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    [ "$first" != "$second" ]
    sleep 0.5
    ! kill -0 "$first" 2>/dev/null
    kill -0 "$second"
    "$SCRIPT" unblock >/dev/null
}
