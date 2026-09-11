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
