#!/usr/bin/env bats
# scen-run core: captures, impairment, traffic, trap cleanup, drop stats.
# Stubs in bin/, allowlisted real tools in real/ (PATH limited to those two).
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-run"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"; RUN="$BATS_TEST_TMPDIR/run"
    mkdir -p "$BIN" "$REAL" "$S" "$RUN/traffic" "$RUN/events"
    for t in bash env python3 date mkdir cat grep sed awk printf dirname basename readlink paste sleep pgrep pkill chmod rm wc seq tail head cut; do
        p=$(type -P $t) && ln -sf "$p" "$REAL/$t"
    done
    export SCEN_REPO="$BATS_TEST_DIRNAME/.." SCEN_CAPTURE_SETTLE=0.3 S
    unset SCEN_EXEC
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    # tcpdump stub: record args, wait for INT, then print the summary like the real one.
    # Python, not bash: a bash script cannot trap SIGINT when its parent was started
    # asynchronously (the signal arrives ignored) — real tcpdump installs its own handler.
    cat > "$BIN/tcpdump" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys, time
a = sys.argv[1:]; n = os.path.basename(a[a.index('-w') + 1])[:-len('.pcapng')]; S = os.environ['S']
open(f'{S}/tcpdump.{n}', 'w').write(' '.join(a) + '\n')
open(f'{S}/order', 'a').write(f'tcpdump-start {n}\n')
def stop(*_):
    open(f'{S}/order', 'a').write(f'tcpdump-stop {n}\n')
    sys.stderr.write('0 packets captured\n0 packets dropped by kernel\n'); sys.stderr.flush(); sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True: time.sleep(1)
STUB
    chmod +x "$BIN/tcpdump"
    stub wan-apply 'echo "wan-apply $*" >> "$S/calls"; echo "wan-apply $*" >> "$S/order"'
    stub wan-clear 'echo "wan-clear $*" >> "$S/calls"; echo "wan-clear $*" >> "$S/order"'
    stub docker 'echo "docker $*" >> "$S/calls"; cat > "$S/traffic-stdin"'
    cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$RUN/run.yaml"
    echo 'echo hello-traffic' > "$RUN/traffic/profile-basic.sh"
    echo 'events: []' > "$RUN/events/s1-baseline.yaml"
    export PATH="$BIN:$REAL"
}
teardown() { pkill -f "$RUN" 2>/dev/null || true; }

@test "starts one tcpdump per capture point with cap and ring, then stops them" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    for n in outer-t01 outer-t02 inner-i01 inner-i02; do
        grep -q -- "-w $RUN/$n.pcapng -C 1024 -W 2 -s 0 -n -U" "$S/tcpdump.$n"
    done
    [ "$(wc -l < "$RUN/.pids")" -eq 4 ]
    [[ "$output" == *"captures up"* ]]
    run pgrep -f "tcpdump.*$RUN"; [ "$status" -ne 0 ]
}
@test "runs the traffic script through SCEN_EXEC on the traffic node" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    grep -q '^docker exec -i host-a sh -s$' "$S/calls"
    grep -q hello-traffic "$S/traffic-stdin"
}
@test "applies impairment after captures start and clears it before captures stop" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    ln() { grep -n "$1" "$S/order" | head -1 | cut -d: -f1; }
    [ "$(ln tcpdump-start)" -lt "$(ln 'wan-apply branch-wan veth-t01a')" ]
    [ "$(ln 'wan-apply branch-wan veth-t01a')" -lt "$(ln 'wan-clear veth-t01a')" ]
    [ "$(ln 'wan-clear veth-t01a')" -lt "$(ln tcpdump-stop)" ]
    [ "$(grep -c 'wan-clear' "$S/calls")" -eq 1 ]
}
@test "M2 and M3 impairments are logged, never applied" {
    sed -i 's|^  - {mechanism: M1.*|  - {mechanism: M2, profile: lossy, node: gw-a, direction: "A->B"}\n  - {mechanism: M3, profile: adhoc, direction: "A->B"}|' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ ! -f "$S/calls" ] || { run grep -q wan- "$S/calls"; [ "$status" -ne 0 ]; }
    grep -q 'impairment M2 lossy on node gw-a' "$RUN/events.log"
    grep -q 'impairment M3 adhoc' "$RUN/events.log"
}
@test "writes capture-stats.txt with one line per capture point" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ "$(grep -c 'dropped by kernel' "$RUN/capture-stats.txt")" -eq 4 ]
    grep -qx 'outer-t01: 0 packets dropped by kernel' "$RUN/capture-stats.txt"
}
@test "a capture without a summary is reported UNKNOWN, not zero" {
    stub tcpdump 'exec sleep 300'
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ "$(grep -c 'UNKNOWN (no tcpdump summary)' "$RUN/capture-stats.txt")" -eq 4 ]
}
@test "logs that the event engine is absent when scen-events.sh is not there" {
    [ ! -f "$BATS_TEST_DIRNAME/../scripts/scenarios/scen-events.sh" ] || skip "engine present"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    grep -q 'events: engine not present, skipping' "$RUN/events.log"
}
@test "trap cleanup on SIGTERM leaves no capture and clears every iface it impaired" {
    stub docker 'exec sleep 60'          # traffic hangs
    "$SCRIPT" "$RUN/run.yaml" >/dev/null & pid=$!
    for _ in $(seq 50); do grep -q 'wan-apply' "$S/calls" 2>/dev/null && break; sleep 0.1; done
    sleep 0.5; kill -TERM $pid; rc=0; wait $pid || rc=$?
    [ "$rc" -eq 143 ]
    run pgrep -f "tcpdump.*$RUN"; [ "$status" -ne 0 ]
    grep -q 'wan-clear veth-t01a' "$S/calls"
    tail -1 "$RUN/events.log" | grep -q aborted
    [ -d "$RUN" ]
    [ "$(grep -c 'tcpdump-stop' "$S/order")" -eq 4 ]
}
@test "a wan-apply that fails midway is still cleared, captures stop, run aborts" {
    stub wan-apply 'echo "wan-apply $*" >> "$S/calls"; exit 1'
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -ne 0 ]
    grep -q 'wan-clear veth-t01a' "$S/calls"
    [ "$(grep -c 'tcpdump-stop' "$S/order")" -eq 4 ]
    tail -1 "$RUN/events.log" | grep -q aborted
}
@test "a failing traffic run still stops captures and clears impairment, exits 3, not aborted" {
    stub docker 'echo "docker $*" >> "$S/calls"; exit 7'
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 3 ]
    grep -q 'traffic rc=7' "$RUN/events.log"
    grep -q 'wan-clear veth-t01a' "$S/calls"
    [ "$(grep -c 'tcpdump-stop' "$S/order")" -eq 4 ]
    [ "$(grep -c 'dropped by kernel' "$RUN/capture-stats.txt")" -eq 4 ]
    run grep -q aborted "$RUN/events.log"; [ "$status" -ne 0 ]
}
@test "refuses to start when a capture point fails guard_iface" {
    sed -i 's/bridge: br-lab-t02/bridge: br-mirror/' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]; [ ! -f "$S/tcpdump.outer-t01" ]
    [[ "$output" == *"refused: br-mirror"* ]]
}
@test "refuses to start when an impairment iface is the management VLAN" {
    sed -i 's/iface: veth-t01a/iface: lacp-trunk.10/' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]
    [ ! -f "$S/tcpdump.outer-t01" ]; [ ! -f "$S/calls" ]
}
@test "refuses a missing traffic script before starting anything" {
    rm "$RUN/traffic/profile-basic.sh"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]; [ ! -f "$S/tcpdump.outer-t01" ]
}
@test "with the event engine present, scen-run runs the events file and logs each event" {
    [ -f "$BATS_TEST_DIRNAME/../scripts/scenarios/scen-events.sh" ] || skip "engine absent"
    stub ip 'echo "ip $*" >> "$S/calls"'
    cat > "$RUN/events/s1-baseline.yaml" <<'YAML'
- {t: 0, action: note, text: "baseline"}
- {t: 0, action: link-down, target: "br-lab-t01:veth-t01a"}
- {t: 0, action: link-up, target: "br-lab-t01:veth-t01a"}
YAML
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ "$(grep -c '^20.*event t=0 ' "$RUN/events.log")" -eq 3 ]
    grep -q '^ip link set veth-t01a down$' "$S/calls"
    grep -q '^ip link set veth-t01a up$' "$S/calls"
    run grep -q 'engine not present' "$RUN/events.log"; [ "$status" -ne 0 ]
}
