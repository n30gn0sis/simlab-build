#!/usr/bin/env bats
# Test the GENERATED RULES, not their application. Applying real firewall
# rules from a test suite is how a machine locks itself out.

#
# Tests that run the real (non-dry) code path do so with PATH = a stub dir plus
# a fixed list of real tools ($STUB_PATH), so the real iptables, ip6tables and
# nft can never be reached -- not by the script, and not by a sleeper that
# outlives its test (bats deletes the stub dir; a plain "$stub:$PATH" would
# then fall through to the real iptables when the sleeper fires "unblock").
# teardown kills every sleeper recorded under this test's AIRGAP_RUN_DIR.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-airgap-sim.sh"
    export AIRGAP_DRY_RUN=1
    export AIRGAP_LAN=192.168.4.0/22
    export AIRGAP_RUN_DIR="$BATS_TEST_TMPDIR/run"; mkdir -p "$AIRGAP_RUN_DIR"
    stub="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; mkdir -p "$stub" "$REAL"
    # What r770-airgap-sim.sh and its sleeper call, besides iptables.
    for t in bash cat rm date dirname basename setsid sleep; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    STUB_PATH="$stub:$REAL"
}

# Kill every sleeper this test armed, including any a failing test leaked.
# Without pgrep a leaked sleeper could not be found: that is an error, not a
# silent skip.
reap_sleepers() {
    local pid pids
    if [ -r "$AIRGAP_RUN_DIR/r770-airgap-sim.pid" ]; then
        pid=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
        [ -z "$pid" ] || kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
    command -v pgrep >/dev/null || { echo "teardown: pgrep not found; cannot reap sleepers under $AIRGAP_RUN_DIR" >&2; return 1; }
    pids=$(pgrep -f -- "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    for pid in $pids; do
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    done
}

teardown() { reap_sleepers; }

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

# UFW's own ufw-track-output chain (created whenever ufw is active) contains
# unconditional ACCEPTs for NEW outbound tcp/udp connections, installed in
# OUTPUT ahead of anything appended with -A. A DROP appended at the tail of
# OUTPUT (-A OUTPUT ... DROP) never gets evaluated for such packets: they are
# already ACCEPTed by ufw's chain jump before reaching it, and iptables
# traversal stops there. Observed live on VM 9771 (2026-09-28): `block`
# reported BLOCKED and the DROP rule showed 0 packets matched after a
# successful `curl` to a real internet host, while egress was demonstrably
# not blocked. The fix is to INSERT the DROP at a fixed early position (right
# after the 4 ACCEPT rules this script itself inserts at positions 1-4) so it
# is evaluated before any rule -- ufw's included -- that a different tool
# appended to OUTPUT before this script ever ran.
@test "the catch-all drop is inserted at a fixed early position, not appended after whatever else is already in OUTPUT" {
    run "$SCRIPT" block
    echo "$output"
    [[ "$output" == *"iptables -I OUTPUT 5 -m comment --comment r770-airgap-sim -j DROP"* ]]
    [[ "$output" != *"iptables -A OUTPUT -m comment --comment r770-airgap-sim -j DROP"* ]]
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
    printf '#!/bin/sh\necho "iptables v1.8: Permission denied (you must be root)" >&2\nexit 4\n' > "$stub/iptables"
    chmod +x "$stub/iptables"
    PATH="$STUB_PATH" run "$SCRIPT" status
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"OPEN"* ]]
    [[ "$output" == *"root"* ]]
}

@test "status still reports OPEN when iptables answers 'rule absent'" {
    unset AIRGAP_DRY_RUN
    printf '#!/bin/sh\nexit 1\n' > "$stub/iptables"
    chmod +x "$stub/iptables"
    PATH="$STUB_PATH" run "$SCRIPT" status
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
    # -D must eventually fail (unblock loops "delete until absent"); all else succeeds
    printf '#!/bin/sh\ncase "$1" in -D) exit 1;; esac\nexit 0\n' > "$stub/iptables"; chmod +x "$stub/iptables"
    unset AIRGAP_DRY_RUN
}

# The script, and any sleeper it detaches, see only the stubs and $REAL.
sim() { PATH="$STUB_PATH" "$SCRIPT" "$@"; }

@test "the stubbed PATH reaches the iptables stub and never a real iptables, ip6tables or nft" {
    stub_iptables
    [ "$(PATH="$STUB_PATH" command -v iptables)" = "$stub/iptables" ]
    run env PATH="$STUB_PATH" "$REAL/bash" -c 'command -v ip6tables || command -v nft || command -v iptables-legacy || command -v iptables-nft'
    echo "$output"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "teardown's reaper kills a pending sleeper, and fails loudly when pgrep is missing" {
    stub_iptables
    sim block --minutes 1 >/dev/null
    pid=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    kill -0 "$pid"
    rm -f "$AIRGAP_RUN_DIR/r770-airgap-sim.pid"   # found by pgrep, not the pidfile
    reap_sleepers
    sleep 0.3
    run kill -0 "$pid"
    [ "$status" -ne 0 ]
    run "$REAL/bash" -c "PATH=/nonexistent; AIRGAP_RUN_DIR='$AIRGAP_RUN_DIR'; $(declare -f reap_sleepers); reap_sleepers"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pgrep not found"* ]]
}

@test "block records the auto-revert sleeper's PID" {
    stub_iptables
    run sim block --minutes 1
    [ "$status" -eq 0 ]
    [ -s "$AIRGAP_RUN_DIR/r770-airgap-sim.pid" ]
    pid=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    kill -0 "$pid"
    sim unblock >/dev/null
}

@test "unblock kills the pending auto-revert sleeper" {
    stub_iptables
    sim block --minutes 1 >/dev/null
    pid=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    kill -0 "$pid"
    run sim unblock
    [ "$status" -eq 0 ]
    sleep 0.5
    run kill -0 "$pid"
    [ "$status" -ne 0 ]
    [ ! -e "$AIRGAP_RUN_DIR/r770-airgap-sim.pid" ]
}

@test "a second block cancels the first block's sleeper before scheduling its own" {
    stub_iptables
    sim block --minutes 1 >/dev/null
    first=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    sim block --minutes 2 >/dev/null
    second=$(cat "$AIRGAP_RUN_DIR/r770-airgap-sim.pid")
    [ "$first" != "$second" ]
    sleep 0.5
    run kill -0 "$first"
    [ "$status" -ne 0 ]
    kill -0 "$second"
    sim unblock >/dev/null
}
