#!/usr/bin/env bats
# scen-run core: captures, impairment, traffic, trap cleanup, drop stats.
# Stubs in bin/, allowlisted real tools in real/ (PATH limited to those two).
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-run"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"; RUN="$BATS_TEST_TMPDIR/run"
    mkdir -p "$BIN" "$REAL" "$S" "$RUN/traffic" "$RUN/events"
    for t in bash env python3 date mkdir cat grep sed awk printf dirname basename readlink paste sleep pgrep pkill chmod rm wc seq tail head cut sha256sum uptime find sort touch mv; do
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
a = sys.argv[1:]; n = os.path.basename(a[a.index('-w') + 1])[:-len('.pcap')]; S = os.environ['S']
open(a[a.index('-w') + 1] + '0', 'a').close()  # -C/-W: the first ring file is <name>.pcap0
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
    stub docker 'echo "docker $*" >> "$S/calls"; case "$1" in exec) cat > "$S/traffic-stdin";; esac'
    cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$RUN/run.yaml"
    echo 'echo hello-traffic' > "$RUN/traffic/profile-basic.sh"
    echo 'events: []' > "$RUN/events/s1-baseline.yaml"
    export PATH="$BIN:$REAL"
}
teardown() { pkill -f "$RUN" 2>/dev/null || true; }

@test "starts one tcpdump per capture point with cap and ring, then stops them" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    for n in outer-t01 outer-t02 inner-i01 inner-i02; do
        grep -q -- "^-Z root -i br-lab-[a-z0-9]* -w $RUN/$n.pcap -C 1024 -W 2 -s 0 -n -U -B 65536$" "$S/tcpdump.$n"
        [ -f "$RUN/$n-0.pcap" ]; [ ! -e "$RUN/$n.pcap0" ]   # tcpdump's ring name renamed after stop
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
    [ -f "$RUN/outer-t01-0.pcap" ]; [ ! -e "$RUN/outer-t01.pcap0" ]   # aborted runs get final names too
}
# bash defers a trap until the foreground command returns: a plain sleep until the next
# event held cleanup for the whole gap (H6 on the staging VM, 2026-10-09).
@test "SIGTERM during a long gap between events cleans up within seconds" {
    stub docker 'exec sleep 60'
    printf -- '- {t: 0, action: note, text: start}\n- {t: 600, action: note, text: end}\n' > "$RUN/events/s1-baseline.yaml"
    "$SCRIPT" "$RUN/run.yaml" >/dev/null & pid=$!
    for _ in $(seq 50); do grep -q 'event t=0' "$RUN/events.log" 2>/dev/null && break; sleep 0.1; done
    start=$(date +%s); kill -TERM $pid; rc=0; wait $pid || rc=$?
    [ $(( $(date +%s) - start )) -lt 10 ]
    [ "$rc" -eq 143 ]
    run pgrep -f "tcpdump.*$RUN"; [ "$status" -ne 0 ]
    run pgrep -f "^sleep 600$"; [ "$status" -ne 0 ]
    grep -q 'wan-clear veth-t01a' "$S/calls"
    tail -1 "$RUN/events.log" | grep -q aborted
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

# ---- Task 7c: ground truth, manifest actuals, sha256sums ----
# docker stub for 7c: cp populates the destination dir, image inspect answers per $S/inspect-*.
gt_docker() {
    stub docker 'echo "docker $*" >> "$S/calls"
case "$1" in
  cp) src="${2%%:*}"; [ ! -f "$S/nogt-$src" ] || { echo "Error: no such path /gt in $src" >&2; exit 1; }
      mkdir -p "${@: -1}"; touch "${@: -1}/keys";;
  image) img="${@: -1}"; f="$S/inspect-$(basename "${img%%:*}")"
      case "$*" in
        *RepoDigests*) [ -f "$f.digest" ] && cat "$f.digest" || exit 1;;
        *.Id*) [ -f "$f.id" ] && cat "$f.id" || exit 1;;
      esac;;
  *) cat > "$S/traffic-stdin";;
esac'
}
@test "collects /gt from every endpoint node and skips the others" {
    gt_docker
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ -e "$RUN/gt/gw-a/keys" ]; [ -e "$RUN/gt/gw-b/keys" ]
    [ ! -e "$RUN/gt/gw-a/gt" ]
    [ ! -d "$RUN/gt/isp1" ]; [ ! -d "$RUN/gt/host-a" ]
    grep -q '^docker cp gw-a:/gt/\. ' "$S/calls"
    run grep -q 'docker cp isp1' "$S/calls"; [ "$status" -ne 0 ]
}
@test "SCEN_CP overrides the copy command" {
    gt_docker
    stub mycp 'echo "mycp $*" >> "$S/calls"; mkdir -p "$2"; touch "$2/custom"'
    SCEN_CP=mycp run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ -e "$RUN/gt/gw-a/custom" ]; [ -e "$RUN/gt/gw-b/custom" ]
    grep -q "^mycp gw-a $RUN/gt/gw-a/\$" "$S/calls"
}
@test "a node without /gt yields a MISSING marker with the error, exit 0" {
    gt_docker; touch "$S/nogt-gw-b"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ -f "$RUN/gt/gw-b/MISSING" ]
    grep -q 'no such path /gt' "$RUN/gt/gw-b/MISSING"
    [ ! -e "$RUN/gt/gw-b/keys" ]; [ -e "$RUN/gt/gw-a/keys" ]
    grep -q 'gt gw-b MISSING' "$RUN/events.log"
    grep -q '^gt/gw-b/MISSING$\|  gt/gw-b/MISSING$' "$RUN/sha256sums"
}
@test "fills times_utc and writes sorted sha256sums covering pcaps and gt" {
    gt_docker
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    st=$(python3 -I -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1]))["times_utc"]; print(d["start"], d["end"])' "$RUN/run.yaml")
    [[ "$st" =~ ^20[0-9-]+T[0-9:]+Z\ 20[0-9-]+T[0-9:]+Z$ ]]
    grep -q 'outer-t01-0.pcap$' "$RUN/sha256sums"
    grep -q ' gt/gw-a/keys$' "$RUN/sha256sums"
    grep -q ' run.yaml$' "$RUN/sha256sums"
    run grep -E 'sha256sums$|\.pids|\.tcpdump' "$RUN/sha256sums"; [ "$status" -ne 0 ]
    (cd "$RUN" && sha256sum -c --quiet sha256sums)
    awk '{print $2}' "$RUN/sha256sums" > "$S/names"; LC_ALL=C sort -c "$S/names"
}
@test "records the image digest per node, falling back to .Id then unknown" {
    gt_docker
    echo 'localhost/lab/ipsec-ss@sha256:aaa' > "$S/inspect-ipsec-ss.digest"
    echo 'sha256:bbb' > "$S/inspect-frr.id"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    d() { python3 -I -c 'import sys,yaml; print({n["name"]: n.get("digest") for n in yaml.safe_load(open(sys.argv[1]))["nodes"]}[sys.argv[2]])' "$RUN/run.yaml" "$1"; }
    [ "$(d gw-a)" = "localhost/lab/ipsec-ss@sha256:aaa" ]
    [ "$(d gw-b)" = "localhost/lab/ipsec-ss@sha256:aaa" ]
    [ "$(d isp1)" = "sha256:bbb" ]
    [ "$(d host-a)" = "unknown" ]
}
@test "host load is appended to results.notes, keeping existing notes" {
    gt_docker
    echo "1.25 0.90 0.80 1/200 123" > "$S/loadavg"; export SCEN_LOADAVG="$S/loadavg"
    sed -i 's/notes: ""/notes: "operator note"/' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    n=$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["results"]["notes"])' "$RUN/run.yaml")
    [[ "$n" == *"operator note"* ]]; [[ "$n" == *"host load (1m): 1.25"* ]]
    [[ "$n" != *"not a clean reference"* ]]
}
@test "a traffic-failure run still collects, and its notes say not a clean reference" {
    gt_docker
    stub docker 'echo "docker $*" >> "$S/calls"; case "$1" in cp) mkdir -p "${@: -1}"; touch "${@: -1}/keys";; image) exit 1;; *) exit 7;; esac'
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 3 ]
    [ -e "$RUN/gt/gw-a/keys" ]; [ -f "$RUN/sha256sums" ]
    n=$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["results"]["notes"])' "$RUN/run.yaml")
    [[ "$n" == *"traffic rc=7 — not a clean reference"* ]]
}
@test "a missing loadavg is recorded as unknown and the run still succeeds" {
    gt_docker
    SCEN_LOADAVG="$S/nope" run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    n=$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["results"]["notes"])' "$RUN/run.yaml")
    [[ "$n" == *"host load (1m): unknown"* ]]
}
@test "a failing sha256sum dies and publishes no sha256sums or temp file" {
    gt_docker
    stub sha256sum 'for a; do case "$a" in *BADFILE*) exit 1;; esac; done; exec "'"$REAL"'/sha256sum" "$@"'
    stub mycp 'mkdir -p "$2"; touch "$2/BADFILE"'
    SCEN_CP=mycp run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -ne 0 ]
    [ ! -e "$RUN/sha256sums" ]; [ ! -e "$RUN/.sha256sums.tmp" ]
    [[ "$output" == *"cannot write sha256sums"* ]]
}
@test "a custom SCEN_CP that reads stdin cannot swallow later nodes" {
    gt_docker
    stub mycp 'cat >/dev/null; mkdir -p "$2"; touch "$2/k"'
    SCEN_CP=mycp run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ -e "$RUN/gt/gw-a/k" ]; [ -e "$RUN/gt/gw-b/k" ]
}
@test "notes keep a literal em dash and no manifest temp file is left behind" {
    gt_docker
    stub docker 'case "$1" in cp) mkdir -p "${@: -1}";; image) exit 1;; *) exit 7;; esac'
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 3 ]
    grep -q 'not a clean reference' "$RUN/run.yaml"; grep -q '—' "$RUN/run.yaml"
    [ -z "$(find "$RUN" -maxdepth 1 -name '*.tmp')" ]
}

@test "a manifest without events runs to completion and logs that no events were given" {
    sed -i '/^events:/d' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    grep -q 'events: none in manifest' "$RUN/events.log"
    run grep -q aborted "$RUN/events.log"; [ "$status" -ne 0 ]
    tail -1 "$RUN/events.log" | grep -q 'run complete'
}
@test "a bad event (unknown action) stops scen-run before any tcpdump starts" {
    printf -- '- {t: 0, action: frobnicate}\n' > "$RUN/events/s1-baseline.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]
    [[ "$output" == *"unknown action"* ]]
    [ -z "$(ls "$S"/tcpdump.* 2>/dev/null)" ]
}
@test "a link-down event on the management port stops scen-run before any tcpdump starts" {
    printf -- '- {t: 0, action: link-down, target: "br-lab-t01:lacp-trunk"}\n' > "$RUN/events/s1-baseline.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]
    [ -z "$(ls "$S"/tcpdump.* 2>/dev/null)" ]
}
@test "a wan-apply event with a missing profile stops scen-run before any tcpdump starts" {
    printf -- '- {t: 0, action: wan-apply, profile: no-such-profile, iface: veth-t01a}\n' > "$RUN/events/s1-baseline.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]
    [[ "$output" == *"event 1 (wan-apply)"* ]]
    [ -z "$(ls "$S"/tcpdump.* 2>/dev/null)" ]
    [ ! -f "$S/calls" ]
}
@test "SIGTERM after a link-down event brings the port back up in cleanup" {
    stub ip 'echo "ip $*" >> "$S/calls"'
    stub docker 'exec sleep 60'
    printf -- '- {t: 0, action: link-down, target: "br-lab-t01:veth-t01a"}\n' > "$RUN/events/s1-baseline.yaml"
    "$SCRIPT" "$RUN/run.yaml" >/dev/null & pid=$!
    for _ in $(seq 50); do grep -q 'ip link set veth-t01a down' "$S/calls" 2>/dev/null && break; sleep 0.1; done
    sleep 0.3; kill -TERM $pid; rc=0; wait $pid || rc=$?
    [ "$rc" -eq 143 ]
    grep -q '^ip link set veth-t01a up$' "$S/calls"
    grep -q 'left down by scenario' "$RUN/events.log"
}
@test "a port left down at the end of a normal run is logged and brought up" {
    stub ip 'echo "ip $*" >> "$S/calls"'
    printf -- '- {t: 0, action: link-down, target: "br-lab-t01:veth-t01a"}\n' > "$RUN/events/s1-baseline.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    grep -q '^ip link set veth-t01a up$' "$S/calls"
    grep -q 'veth-t01a left down by scenario' "$RUN/events.log"
}
@test "a full capture ring is logged and noted in results.notes" {
    cat > "$BIN/tcpdump" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys, time
a = sys.argv[1:]; w = a[a.index('-w') + 1]
for i in range(int(a[a.index('-W') + 1])): open(f'{w}{i:02d}', 'a').close()
def stop(*_):
    sys.stderr.write('0 packets captured\n0 packets dropped by kernel\n'); sys.stderr.flush(); sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True: time.sleep(1)
STUB
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    grep -q 'outer-t01: ring full (2 files)' "$RUN/events.log"
    grep -q 'ring full: outer-t01, outer-t02, inner-i01, inner-i02' "$RUN/run.yaml"
    [ -f "$RUN/outer-t01-00.pcap" ] && [ -f "$RUN/outer-t01-01.pcap" ]   # tcpdump's padding is kept
    [ -z "$(find "$RUN" -maxdepth 1 -name '*.pcap[0-9]*')" ]
}
@test "a bare <name>.pcap (no ring suffix) becomes <name>-0.pcap; an existing target is left alone" {
    cat > "$BIN/tcpdump" <<'STUB'
#!/usr/bin/env python3
import signal, sys, time
a = sys.argv[1:]; w = a[a.index('-w') + 1]
open(w, 'a').close()
if w.endswith('outer-t02.pcap'): open(w[:-len('.pcap')] + '-0.pcap', 'w').write('older')
def stop(*_):
    sys.stderr.write('0 packets captured\n0 packets dropped by kernel\n'); sys.stderr.flush(); sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True: time.sleep(1)
STUB
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    [ -f "$RUN/outer-t01-0.pcap" ]; [ ! -e "$RUN/outer-t01.pcap" ]
    [ "$(cat "$RUN/outer-t02-0.pcap")" = older ]; [ -f "$RUN/outer-t02.pcap" ]
    grep -q 'outer-t02.pcap: outer-t02-0.pcap exists, not renamed' "$RUN/events.log"
}
@test "a ring that has not wrapped adds no note" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    run grep -q 'ring full' "$RUN/events.log"; [ "$status" -ne 0 ]
}
@test "traffic that outlives the last event by SCEN_TRAFFIC_GRACE is abandoned: rc 124, exit 3, in-node stop sent" {
    stub docker 'echo "docker $*" >> "$S/calls"; case "$1" in exec) case "$*" in *"sh -c"*) exit 0;; esac; exec sleep 60;; esac'
    SCEN_TRAFFIC_GRACE=2 run "$SCRIPT" "$RUN/run.yaml"
    echo "$output"
    [ "$status" -eq 3 ]
    grep -q 'traffic still running 2s after the last event — abandoning it (rc 124)' "$RUN/events.log"
    grep -q 'traffic rc=124' "$RUN/events.log"
    grep -q '^docker exec -i host-a sh -c kill' "$S/calls"
    run pgrep -f "tcpdump.*$RUN"; [ "$status" -ne 0 ]
    grep -q 'wan-clear veth-t01a' "$S/calls"
}
@test "SCEN_TRAFFIC_GRACE=0 waits for traffic without bound" {
    stub docker 'echo "docker $*" >> "$S/calls"; case "$1" in exec) sleep 3; cat > "$S/traffic-stdin";; esac'
    SCEN_TRAFFIC_GRACE=0 run "$SCRIPT" "$RUN/run.yaml"
    [ "$status" -eq 0 ]
    grep -q 'traffic done' "$RUN/events.log"
    run grep -q 'abandoning' "$RUN/events.log"; [ "$status" -ne 0 ]
}
