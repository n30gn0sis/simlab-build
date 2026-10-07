#!/usr/bin/env bats
# scen-events.sh: validated, timed event engine sourced by scen-run.
# Stubs in bin/, allowlisted real tools in real/ (PATH limited to those two).
setup() {
    LIBDIR="$BATS_TEST_DIRNAME/../scripts/scenarios"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"
    mkdir -p "$BIN" "$REAL" "$S"
    for t in bash env python3 date mkdir cat grep sed awk printf dirname basename readlink sleep chmod rm wc head tail; do
        p=$(type -P $t) && ln -sf "$p" "$REAL/$t"
    done
    export SCEN_LOG="$BATS_TEST_TMPDIR/events.log" S LIBDIR
    unset SCEN_EXEC SCEN_CAPTURE_PORTS
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    stub ip 'echo "ip $*" >> "$S/calls"'
    stub wan-apply 'echo "wan-apply $*" >> "$S/calls"'
    stub wan-clear 'echo "wan-clear $*" >> "$S/calls"'
    stub docker 'echo "docker $*" >> "$S/calls"'
    export PATH="$BIN:$REAL"
    EV="$BATS_TEST_TMPDIR/ev.yaml"
    PAST=$(( $(date +%s) - 100 ))      # t0 in the past: nothing sleeps
}
# drive <events-file> [t0] [prelude] — source the engine, run it, print APPLIED at the end.
drive() {
    bash -c 'source "$LIBDIR/scen-events.sh"; APPLIED="${3:-}"; eval "${4:-:}"; events_run "$1" "$2"; echo "APPLIED=[$APPLIED]"' _ "$1" "${2:-$PAST}" "${3:-}" "${4:-}"
}

@test "sourcing has no side effects" {
    run bash -c 'source "$LIBDIR/scen-events.sh"; declare -F events_run'
    [ "$status" -eq 0 ]; [ "$output" = events_run ]
    [ ! -e "$SCEN_LOG" ]; [ ! -e "$S/calls" ]
}
@test "executes events in order at their offsets and logs each with a timestamp" {
    run drive "$BATS_TEST_DIRNAME/fixtures/events-basic.yaml"; [ "$status" -eq 0 ]
    [ "$(grep -c '^20.*event t=' "$SCEN_LOG")" -eq 5 ]
    [ "$(grep -c 'FAILED' "$SCEN_LOG" || true)" -eq 0 ]
    grep -q 'event t=0 note text=baseline traffic running$' "$SCEN_LOG"
    grep -q 'event t=1 link-down target=br-lab-t01:veth-t01a$' "$SCEN_LOG"
    grep -q 'event t=2 exec node=gw-a cmd=swanctl --list-sas$' "$SCEN_LOG"
    [ "$(cat "$S/calls")" = "ip link set veth-t01a down
ip link set veth-t01a up
wan-apply lte-poor veth-t01a
docker exec -i gw-a sh -c swanctl --list-sas" ]
    # log order is event order
    run grep -o 'event t=[0-9] [a-z-]*' "$SCEN_LOG"
    [ "${lines[*]}" = "event t=0 note event t=1 link-down event t=1 link-up event t=2 wan-apply event t=2 exec" ]
}
@test "waits until t0+t before an event that is not yet due" {
    printf -- '- {t: 2, action: note, text: later}\n' > "$EV"
    start=$(date +%s)
    run drive "$EV" "$start"; [ "$status" -eq 0 ]
    [ $(( $(date +%s) - start )) -ge 1 ]
    grep -q 'event t=2 note' "$SCEN_LOG"
}
@test "does not sleep for events already overdue" {
    printf -- '- {t: 5, action: note, text: late}\n' > "$EV"
    start=$(date +%s)
    run drive "$EV" "$PAST"; [ "$status" -eq 0 ]
    [ $(( $(date +%s) - start )) -le 1 ]
}
@test "wan-apply appends the iface to APPLIED and wan-clear removes it" {
    printf -- '- {t: 0, action: wan-apply, profile: lte-poor, iface: veth-t01a}\n- {t: 0, action: wan-apply, profile: lte-poor, iface: veth-t02a}\n' > "$EV"
    run drive "$EV" "$PAST" " veth-x9"; [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "APPLIED=[ veth-x9 veth-t01a veth-t02a]" ]
    printf -- '- {t: 0, action: wan-clear, iface: veth-t01a}\n' > "$EV"
    run drive "$EV" "$PAST" " veth-t01a veth-t02a"; [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "APPLIED=[ veth-t02a]" ]
    grep -q '^wan-clear veth-t01a$' "$S/calls"
}
@test "a failed wan-clear leaves the iface in APPLIED for the cleanup trap" {
    stub wan-clear 'exit 4'
    printf -- '- {t: 0, action: wan-clear, iface: veth-t01a}\n' > "$EV"
    run drive "$EV" "$PAST" " veth-t01a"; [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "APPLIED=[ veth-t01a]" ]
    grep -q 'event t=0 wan-clear FAILED rc=4' "$SCEN_LOG"
}
@test "a failing event is logged FAILED rc=n and later events still run" {
    stub ip 'exit 2'
    run drive "$BATS_TEST_DIRNAME/fixtures/events-basic.yaml"; [ "$status" -eq 0 ]
    grep -q 'event t=1 link-down FAILED rc=2' "$SCEN_LOG"
    grep -q 'event t=1 link-up FAILED rc=2' "$SCEN_LOG"
    grep -q '^docker exec -i gw-a sh -c swanctl --list-sas$' "$S/calls"
}
@test "exec honours SCEN_EXEC and passes the command as one argument" {
    printf -- '- {t: 0, action: exec, node: gw-a, cmd: "echo a; echo b"}\n' > "$EV"
    stub sudo 'echo "sudo $# $*" >> "$S/calls"'
    SCEN_EXEC="sudo -n" run drive "$EV"; [ "$status" -eq 0 ]
    grep -qx 'sudo 5 -n gw-a sh -c echo a; echo b' "$S/calls"
}
@test "link-down on a management port is refused before any event runs" {
    printf -- '- {t: 0, action: note, text: first}\n- {t: 1, action: link-down, target: "br-lab-t01:lacp-trunk.10"}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]
    [[ "$output" == *"refused: lacp-trunk.10"* ]]
    [ ! -e "$S/calls" ]; [ ! -e "$SCEN_LOG" ]
}
@test "wan-apply on a capture port is refused before any event runs" {
    printf -- '- {t: 0, action: note, text: first}\n- {t: 1, action: wan-apply, profile: p, iface: veth-cap1}\n' > "$EV"
    SCEN_CAPTURE_PORTS="veth-cap1" run drive "$EV"; [ "$status" -eq 1 ]
    [[ "$output" == *"refused: veth-cap1 is a capture port"* ]]
    [ ! -e "$S/calls" ]; [ ! -e "$SCEN_LOG" ]
}
@test "wan-clear on a non-lab interface is refused" {
    printf -- '- {t: 0, action: wan-clear, iface: eno1}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"refused: eno1"* ]]
    [ ! -e "$S/calls" ]
}
@test "unknown action is refused up front" {
    printf -- '- {t: 0, action: note, text: first}\n- {t: 1, action: reboot, node: gw-a}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]
    [[ "$output" == *"unknown action reboot"* ]]
    [ ! -e "$SCEN_LOG" ]
}
@test "missing required keys are refused" {
    printf -- '- {t: 0, action: exec, node: gw-a}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"missing cmd"* ]]
    printf -- '- {t: 0, action: wan-apply, iface: veth-t01a}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"missing profile"* ]]
    printf -- '- {t: 0, action: link-down, target: nocolon}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"<bridge>:<port>"* ]]
    [ ! -e "$SCEN_LOG" ]
}
@test "negative, non-numeric and decreasing t are refused" {
    printf -- '- {t: -1, action: note, text: x}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"non-negative integer"* ]]
    printf -- '- {t: soon, action: note, text: x}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"non-negative integer"* ]]
    printf -- '- {t: 3, action: note, text: x}\n- {t: 2, action: note, text: y}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 1 ]; [[ "$output" == *"earlier than the previous"* ]]
    [ ! -e "$SCEN_LOG" ]
}
@test "gns3-link-suspend is logged as unsupported and does not abort" {
    printf -- '- {t: 0, action: gns3-link-suspend, link: l1}\n- {t: 0, action: gns3-link-resume, link: l1}\n- {t: 1, action: note, text: after}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 0 ]
    grep -q 'event t=0 gns3-link-suspend unsupported until O4 — skipped' "$SCEN_LOG"
    grep -q 'event t=0 gns3-link-resume unsupported until O4 — skipped' "$SCEN_LOG"
    grep -q 'event t=1 note text=after' "$SCEN_LOG"
    [ ! -e "$S/calls" ]
}
@test "an events mapping with an events list, and an empty list, are accepted" {
    printf 'events:\n  - {t: 0, action: note, text: m}\n' > "$EV"
    run drive "$EV"; [ "$status" -eq 0 ]; grep -q 'event t=0 note text=m' "$SCEN_LOG"
    echo 'events: []' > "$EV"
    run drive "$EV"; [ "$status" -eq 0 ]
}
@test "a missing events file is refused" {
    run drive "$BATS_TEST_TMPDIR/none.yaml"; [ "$status" -eq 1 ]; [[ "$output" == *"no such events file"* ]]
}
