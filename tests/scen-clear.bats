#!/usr/bin/env bats
# scen-clear: impairment + capture cleanup with baseline RTT check.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-clear"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; RUN="$BATS_TEST_TMPDIR/run"
    CALLS="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$BIN" "$REAL" "$RUN"; : > "$CALLS"
    for t in bash env python3 date mkdir cat grep sed awk printf dirname basename readlink cp rm chmod; do
        p=$(type -P $t) && ln -sf "$p" "$REAL/$t"
    done
    export CALLS SCEN_REPO="$BATS_TEST_DIRNAME/.." SHOW_OUT="" PING_OUT="" PING_RC=0
    cat > "$BIN/wan-clear" <<'S'
#!/bin/bash
echo "wan-clear $*" >> "$CALLS"
S
    cat > "$BIN/wan-show" <<'S'
#!/bin/bash
printf '%s' "$SHOW_OUT"
S
    cat > "$BIN/pkill" <<'S'
#!/bin/bash
echo "pkill $*" >> "$CALLS"
exit "${PKILL_RC:-0}"
S
    cat > "$BIN/ping" <<'S'
#!/bin/bash
printf '%s' "$PING_OUT"
exit "$PING_RC"
S
    chmod +x "$BIN"/*
    cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$RUN/run.yaml"
    export PATH="$BIN:$REAL"
}

add_baseline() { printf 'baseline: {target: 198.18.2.2, rtt_ms: %s}\n' "$1" >> "$RUN/run.yaml"; }

@test "clears every manifest iface and only those" {
    sed -i 's|^impairment:.*|impairment:\n  - {mechanism: M1, profile: p, iface: veth-t01a, direction: "A->B"}\n  - {mechanism: M1, profile: p, iface: br-lab-t02, direction: "B->A"}|; /^  - {mechanism: M1, profile: branch-wan/d' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^wan-clear' "$CALLS")" -eq 2 ]
    grep -qx 'wan-clear veth-t01a' "$CALLS"
    grep -qx 'wan-clear br-lab-t02' "$CALLS"
}

@test "refuses a manifest iface that guard_iface rejects, clearing nothing" {
    sed -i 's/iface: veth-t01a/iface: eno1/' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refused"* ]]
    [ "$(grep -c '^wan-clear' "$CALLS")" -eq 0 ]
}

@test "M2-only manifest clears nothing on the host" {
    sed -i 's/mechanism: M1/mechanism: M2/' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^wan-clear' "$CALLS")" -eq 0 ]
    [[ "$output" == *"nothing to clear on host"* ]]
}

@test "a failing wan-clear only warns" {
    printf '#!/bin/bash\nexit 1\n' > "$BIN/wan-clear"
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}

@test "kills only captures under the run dir" {
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    line=$(grep '^pkill' "$CALLS")
    [[ "$line" == *"-INT"* ]]
    [[ "$line" == *"tcpdump .* -w "* ]]
    [[ "$line" == *"$RUN/"* ]]
}

@test "no matching capture is not an error" {
    PKILL_RC=1 run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "exits 1 and prints the leftovers when wan-show is still non-empty" {
    SHOW_OUT=$'veth-t01a: qdisc netem\n' run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"veth-t01a: qdisc netem"* ]]
    [[ "$output" == *"still present"* ]]
}

@test "RTT OK when ping mean is within 1 ms of baseline" {
    add_baseline 0.4
    PING_OUT=$'rtt min/avg/max/mdev = 0.300/1.100/1.900/0.200 ms\n' run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTT OK (1.100 ms vs baseline 0.4)"* ]]
}

@test "RTT DRIFT when ping mean is more than 1 ms from baseline, exit still 0" {
    add_baseline 0.4
    PING_OUT=$'rtt min/avg/max/mdev = 1.0/12.5/20.0/2.0 ms\n' run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTT DRIFT (12.5 ms vs baseline 0.4)"* ]]
}

@test "RTT UNKNOWN when ping fails" {
    add_baseline 0.4
    PING_RC=1 run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTT UNKNOWN (ping failed)"* ]]
}

@test "no RTT check when baseline is absent or rtt_ms is null" {
    run "$SCRIPT" "$RUN/run.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != *RTT* ]]
    printf 'baseline: {target: 198.18.2.2, rtt_ms: null}\n' >> "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != *RTT* ]]
}

@test "pkill failure (rc 2) warns and exits 1" {
    PKILL_RC=2 run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARN: pkill failed rc=2"* ]]
}

@test "RTT OK survives a decimal-comma locale" {
    add_baseline 0.4
    export LC_ALL=de_DE.UTF-8
    PING_OUT=$'rtt min/avg/max/mdev = 0.300/1.100/1.900/0.200 ms\n' run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTT OK (1.100 ms vs baseline 0.4)"* ]]
}

@test "a refused iface later in the list clears nothing" {
    sed -i 's|^impairment:.*|impairment:\n  - {mechanism: M1, profile: p, iface: veth-t01a, direction: "A->B"}\n  - {mechanism: M1, profile: p, iface: eno1, direction: "B->A"}|; /^  - {mechanism: M1, profile: branch-wan/d' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -ne 0 ]
    [ "$(grep -c '^wan-clear' "$CALLS")" -eq 0 ]
}

@test "empty impairment list is fine" {
    sed -i 's|^impairment:.*|impairment: []|; /^  - {mechanism: M1, profile: branch-wan/d' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^wan-clear' "$CALLS")" -eq 0 ]
}

@test "walks the events file: clears wan-apply ifaces and brings link-down ports up" {
    printf '#!/bin/bash\necho "ip $*" >> "$CALLS"\n' > "$BIN/ip"; chmod +x "$BIN/ip"
    mkdir -p "$RUN/events"
    cat > "$RUN/events/s1-baseline.yaml" <<'YAML'
- {t: 5, action: wan-apply, profile: branch-wan, iface: veth-t02a}
- {t: 9, action: link-down, target: "br-lab-t01:veth-t01a"}
YAML
    run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'wan-clear veth-t02a' "$CALLS"
    grep -qx 'ip link set veth-t01a up' "$CALLS"
}
@test "an events file naming a refused iface clears nothing from events and fails" {
    printf '#!/bin/bash\necho "ip $*" >> "$CALLS"\n' > "$BIN/ip"; chmod +x "$BIN/ip"
    mkdir -p "$RUN/events"
    printf -- '- {t: 9, action: link-down, target: "br-lab-t01:lacp-trunk"}\n' > "$RUN/events/s1-baseline.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -ne 0 ]
    run grep -q '^ip ' "$CALLS"; [ "$status" -ne 0 ]
}
