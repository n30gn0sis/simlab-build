#!/usr/bin/env bats
# scen-bridges.sh: guarded lab bridge create/destroy.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-bridges.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; CALLS="$BATS_TEST_TMPDIR/calls"
    export SCEN_SYSNET="$BATS_TEST_TMPDIR/sysnet" CALLS
    mkdir -p "$BIN" "$REAL" "$SCEN_SYSNET"; : > "$CALLS"
    for t in bash env date mkdir cat grep sed printf dirname basename readlink ls rm; do
        p=$(type -P $t) && ln -sf "$p" "$REAL/$t"
    done
    for t in ip sysctl; do
        printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$t" > "$BIN/$t"
    done
    chmod +x "$BIN"/*
    export SCEN_REPO="$BATS_TEST_DIRNAME/.." SCEN_CAPTURE_PORTS=""
    export PATH="$BIN:$REAL"
}

@test "dry-run create prints exactly the three commands and no ip addr" {
    run "$SCRIPT" create --dry-run br-lab-t01
    echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "ip link add br-lab-t01 type bridge" ]
    [ "${lines[1]}" = "ip link set br-lab-t01 up" ]
    [ "${lines[2]}" = "sysctl -qw net.ipv6.conf.br-lab-t01.disable_ipv6=1" ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "$output" != *"ip addr"* ]]
    [ ! -s "$CALLS" ]
}

@test "real create runs the commands for each bridge and never ip addr" {
    run "$SCRIPT" create br-lab-i01 br-lab-ext
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'ip link add br-lab-i01 type bridge' "$CALLS"
    grep -qx 'ip link set br-lab-ext up' "$CALLS"
    grep -qx 'sysctl -qw net.ipv6.conf.br-lab-ext.disable_ipv6=1' "$CALLS"
    [ "$(grep -c 'addr' "$CALLS")" -eq 0 ]
}

@test "refuses br-lab-t1 (two digits required)" {
    run "$SCRIPT" create br-lab-t1; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *refused* ]]; [ ! -s "$CALLS" ]
}
@test "refuses br-lab-t001" {
    run "$SCRIPT" create br-lab-t001; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *refused* ]]; [ ! -s "$CALLS" ]
}
@test "refuses br-lab-mgmt" {
    run "$SCRIPT" create br-lab-mgmt; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *refused* ]]; [ ! -s "$CALLS" ]
}
@test "refuses br-mirror" {
    run "$SCRIPT" create br-mirror; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *refused* ]]; [ ! -s "$CALLS" ]
}
@test "refuses veth-x even though guard_iface allows veth-*" {
    run "$SCRIPT" create veth-x; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *refused* ]]; [ ! -s "$CALLS" ]
}
@test "a bad name anywhere in the list stops everything before any command" {
    run "$SCRIPT" create br-lab-t01 br-mirror; echo "$output"
    [ "$status" -ne 0 ]; [ ! -s "$CALLS" ]
}
@test "refuses a capture port" {
    SCEN_CAPTURE_PORTS="br-lab-t01" run "$SCRIPT" create br-lab-t01; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *"capture port"* ]]; [ ! -s "$CALLS" ]
}

@test "destroy refuses a bridge with members without --force" {
    mkdir -p "$SCEN_SYSNET/br-lab-t01/brif/veth-t01a"
    run "$SCRIPT" destroy br-lab-t01; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *"member"* ]]
    [ "$(grep -c 'link del' "$CALLS")" -eq 0 ]
}
@test "destroy --force removes a bridge with members" {
    mkdir -p "$SCEN_SYSNET/br-lab-t01/brif/veth-t01a"
    run "$SCRIPT" destroy --force br-lab-t01; echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'ip link del br-lab-t01' "$CALLS"
}
@test "destroy removes an empty bridge" {
    mkdir -p "$SCEN_SYSNET/br-lab-t02/brif"
    run "$SCRIPT" destroy br-lab-t02; echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'ip link del br-lab-t02' "$CALLS"
}
@test "destroy --dry-run prints the command" {
    mkdir -p "$SCEN_SYSNET/br-lab-t02/brif"
    run "$SCRIPT" destroy --dry-run br-lab-t02; echo "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "ip link del br-lab-t02" ]
    [ ! -s "$CALLS" ]
}
@test "destroy of a nonexistent bridge is logged and skipped" {
    run "$SCRIPT" destroy br-lab-t09; echo "$output"
    [ "$status" -eq 0 ]; [[ "$output" == *"does not exist"* ]]; [ ! -s "$CALLS" ]
}
@test "create on an existing bridge skips the add but still sets up and sysctls" {
    mkdir -p "$SCEN_SYSNET/br-lab-t01"
    run "$SCRIPT" create br-lab-t01; echo "$output"
    [ "$status" -eq 0 ]; [[ "$output" == *"already exists"* ]]
    [ "$(grep -c 'link add' "$CALLS")" -eq 0 ]
    grep -qx 'ip link set br-lab-t01 up' "$CALLS"
    grep -qx 'sysctl -qw net.ipv6.conf.br-lab-t01.disable_ipv6=1' "$CALLS"
}
@test "header carries the fold-in note" {
    grep -qxF "# Temporary until lab-transit.sh (Phase 7) — fold in, don't fork." "$SCRIPT"
}
