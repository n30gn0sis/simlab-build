# ipsec-ss entrypoint: stubs in bin/, a small allowlist of real tools in real/,
# PATH limited to those, nothing written outside $BATS_TEST_TMPDIR.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../images/ipsec-ss/entrypoint.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"
    mkdir -p "$BIN" "$REAL" "$S"; export S
    for t in bash sh sleep date mkdir cat printf grep ls timeout kill rm; do
        p=$(command -v "$t") && ln -sf "$p" "$REAL/$t"
    done
    export GT="$BATS_TEST_TMPDIR/gt" CHARON="$BIN/charon" WAIT_SECS=2 SA_SNAPSHOT_SECS=1
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    stub ip      '[ -f "$S/ifaces" ] && grep -qx "$3" "$S/ifaces"'       # ip link show <if>
    stub swanctl 'echo "swanctl $*" >> "$S/calls"; echo "s1-net: INSTALLED"'
    stub charon  'echo charon >> "$S/calls"; sleep 30'
    PATH="$BIN:$REAL"
}
@test "waits for every iface, then starts charon, loads config and snapshots SAs into /gt" {
    printf 'eth0\neth1\n' > "$S/ifaces"
    run timeout 3 "$SCRIPT"
    grep -q charon "$S/calls"; grep -q -- "--load-all" "$S/calls"
    [ -d "$GT/keys" ]; ls "$GT"/sa/*.txt | grep -q 'Z.txt$'
    grep -q INSTALLED "$GT"/sa/*.txt
}
@test "exits 1 naming the missing iface after WAIT_SECS" {
    printf 'eth0\n' > "$S/ifaces"
    run "$SCRIPT"
    [ "$status" -eq 1 ]; [[ "$output" == *"iface eth1 missing"* ]]
    ! grep -q charon "$S/calls" 2>/dev/null
}
@test "WAIT_IFACES overrides the interface list" {
    printf 'eth0\n' > "$S/ifaces"
    WAIT_IFACES=eth0 run timeout 3 "$SCRIPT"
    grep -q charon "$S/calls"
}
