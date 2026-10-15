#!/usr/bin/env bats
# scen-prep: the prerequisite gate. Stubs in bin/, allowlisted real tools in real/.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-prep"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"; mkdir -p "$BIN" "$REAL" "$S"
    for t in bash env rm rmdir python3 date mkdir cp cat grep sed awk printf dirname basename readlink; do p=$(type -P $t) && ln -sf "$p" "$REAL/$t"; done
    export SCEN_REPO="$BATS_TEST_DIRNAME/.." SCEN_CASES="$BATS_TEST_TMPDIR/cases" SCEN_SYSNET="$BATS_TEST_TMPDIR/sysnet"
    export SCEN_MODULES_FILE="$BATS_TEST_TMPDIR/modules" SCEN_FREE_FLOOR_GB=1 S
    mkdir -p "$SCEN_SYSNET"/br-lab-t01 "$SCEN_SYSNET"/br-lab-t02 "$SCEN_SYSNET"/br-lab-i01 "$SCEN_SYSNET"/br-lab-i02
    printf 'xfrm_user 1\nxfrm_interface 1\nesp4 1\n' > "$SCEN_MODULES_FILE"
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    stub wan-show 'cat "$S/wanshow" 2>/dev/null || true'
    stub df 'echo "Filesystem 1K-blocks Used Available Use% Mounted"; echo "x 1 1 $(cat "$S/free_kb") 1% /data/pcap"'
    echo $((500*1024*1024)) > "$S/free_kb"
    mkdir -p "$BATS_TEST_TMPDIR/S1"; cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$BATS_TEST_TMPDIR/S1/run.yaml"
    export PATH="$BIN:$REAL"
}
@test "creates the run dir and copies the manifest when every check passes" {
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    [ -f "$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z/run.yaml" ]
    [[ "$output" == *"$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z" ]]
}
@test "copies traffic/, events/ and expected.md beside run.yaml" {
    mkdir -p "$BATS_TEST_TMPDIR/S1/traffic" "$BATS_TEST_TMPDIR/S1/events"
    echo t > "$BATS_TEST_TMPDIR/S1/traffic/profile-basic.sh"
    echo e > "$BATS_TEST_TMPDIR/S1/events/s1-baseline.yaml"
    echo x > "$BATS_TEST_TMPDIR/S1/expected.md"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    d="$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z"
    [ -f "$d/traffic/profile-basic.sh" ]; [ -f "$d/events/s1-baseline.yaml" ]; [ -f "$d/expected.md" ]
}
@test "refuses when a module is missing" {
    printf 'xfrm_user 1\n' > "$SCEN_MODULES_FILE"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"esp4"* ]]
    [ ! -d "$SCEN_CASES" ]
}
@test "refuses when a capture bridge does not exist" {
    rmdir "$SCEN_SYSNET/br-lab-i02"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"br-lab-i02"* ]]
}
@test "refuses a manifest whose iface is the management VLAN" {
    sed -i 's/iface: veth-t01a/iface: lacp-trunk.10/' "$BATS_TEST_TMPDIR/S1/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"refused: lacp-trunk.10"* ]]
    [ ! -d "$SCEN_CASES" ]
}
@test "refuses when wan-show is not clean" {
    echo "veth-t01a: netem delay 40ms" > "$S/wanshow"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"wan-show not clean"* ]]
}
@test "refuses when cap×points exceeds free space, showing the arithmetic" {
    echo $((3*1024*1024)) > "$S/free_kb"      # 3 GB free; manifest: cap 1024 MB × ring 2 × 4 points = 8 GB
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"8192 MB needed"* ]]
}
@test "refuses below the free-space floor even if the run would fit" {
    echo $((100*1024*1024)) > "$S/free_kb"      # 100 GB free: fits the 8 GB run, below the floor
    SCEN_FREE_FLOOR_GB=200 run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"floor"* ]]
}
@test "refuses a non-numeric cap_mb, naming the key" {
    sed -i 's/cap_mb: 1024/cap_mb: abc/' "$BATS_TEST_TMPDIR/S1/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"capture.cap_mb must be a positive integer"* ]]
    [ ! -d "$SCEN_CASES" ]
}
@test "refuses ring 0" {
    sed -i 's/ring: 2/ring: 0/' "$BATS_TEST_TMPDIR/S1/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"capture.ring must be a positive integer"* ]]
}
@test "refuses a run_id that escapes the cases tree" {
    sed -i 's|^run_id: .*|run_id: ../escape|' "$BATS_TEST_TMPDIR/S1/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"run_id must match"* ]]
    [ ! -d "$SCEN_CASES" ]
}
@test "refuses a manifest with no run_id" {
    sed -i '/^run_id:/d' "$BATS_TEST_TMPDIR/S1/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"run_id"* ]]
    [ ! -d "$SCEN_CASES" ]
}
@test "refuses to re-run onto an existing run dir and leaves it unchanged" {
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    d="$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z"; echo marker >> "$d/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"run dir already exists"* ]]
    grep -qx marker "$d/run.yaml"
}
@test "--images rewrites fixture tags from the list file, leaves unmatched images alone" {
    printf 'localhost/lab/ipsec-ss:20261015\nlocalhost/lab/svc-targets:20261015\n' > "$S/images.list"
    run "$SCRIPT" --images "$S/images.list" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    [[ "$output" == *"no list entry for quay.io/frrouting/frr"* ]]
    r="$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z/run.yaml"
    run grep -q 'ipsec-ss:0.0.0-fixture' "$r"; [ "$status" -ne 0 ]
    [ "$(grep -c 'localhost/lab/ipsec-ss:20261015' "$r")" -eq 2 ]
    grep -q 'quay.io/frrouting/frr:0.0.0-fixture' "$r"
    grep -q 'docker.io/nicolaka/netshoot:latest' "$r"
    grep -q 'ipsec-ss:0.0.0-fixture' "$BATS_TEST_TMPDIR/S1/run.yaml"
}
@test "--images with a missing list file fails before creating the run dir" {
    run "$SCRIPT" --images "$S/nope.list" "$BATS_TEST_TMPDIR/S1"; [ "$status" -ne 0 ]
    [ ! -e "$SCEN_CASES/S1" ]
}

@test "--images given twice: the second list (real FRR tag) rewrites the FRR node too" {
    printf 'localhost/lab/ipsec-ss:T9\n' > "$S/lab.list"
    printf '# node images\ndocker.io/nicolaka/netshoot:latest\nquay.io/frrouting/frr:T9\n' > "$S/nodes.list"
    run "$SCRIPT" --images "$S/lab.list" --images "$S/nodes.list" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    r="$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z/run.yaml"
    grep -q 'quay.io/frrouting/frr:T9' "$r"
    [[ "$output" == *"fixture tags remaining: 0"* ]]
    run grep -q ':0.0.0-fixture' "$r"; [ "$status" -ne 0 ]
}
@test "--images with one list warns about the fixture tag left on the FRR node" {
    printf 'localhost/lab/ipsec-ss:T9\n' > "$S/lab.list"
    run "$SCRIPT" --images "$S/lab.list" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: fixture tag left: quay.io/frrouting/frr:0.0.0-fixture (node isp1)"* ]]
    [[ "$output" == *"fixture tags remaining: 1"* ]]
}
