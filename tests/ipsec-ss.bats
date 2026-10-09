# ipsec-ss entrypoint: stubs in bin/, a small allowlist of real tools in real/,
# PATH limited to those, nothing written outside $BATS_TEST_TMPDIR.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../images/ipsec-ss/entrypoint.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"
    mkdir -p "$BIN" "$REAL" "$S"; export S
    for t in bash sh sleep date mkdir cat printf grep ls timeout kill rm head cut wc chmod; do
        p=$(command -v "$t") && ln -sf "$p" "$REAL/$t"
    done
    export GT="$BATS_TEST_TMPDIR/gt" CHARON="$BIN/charon" WAIT_SECS=2 SA_SNAPSHOT_SECS=1 START_WAIT_SECS=3
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    stub ip      '[ -f "$S/ifaces" ] && grep -qx "$3" "$S/ifaces"'       # ip link show <if>
    # --stats answers (and is logged) only once charon has started, i.e. vici is ready
    stub swanctl 'case "$1" in --stats) grep -qx charon "$S/calls" || exit 1 ;; esac
echo "swanctl $*" >> "$S/calls"
case "$1" in --stats) ;; *) echo "s1-net: INSTALLED" ;; esac'
    stub charon  'echo charon >> "$S/calls"; sleep 30'
    PATH="$BIN:$REAL"
}
@test "waits for every iface, starts charon, waits for vici, loads config, snapshots SAs periodically" {
    printf 'eth0\neth1\n' > "$S/ifaces"
    run timeout 5 "$SCRIPT"
    [ "$status" -eq 124 ]
    [ "$(head -n1 "$S/calls")" = charon ]
    stats=$(grep -n -- "--stats" "$S/calls" | head -n1 | cut -d: -f1)
    load=$(grep -n -- "--load-all" "$S/calls" | head -n1 | cut -d: -f1)
    [ -n "$stats" ] && [ -n "$load" ] && [ "$stats" -lt "$load" ]
    [ -d "$GT/keys" ]; ls "$GT"/sa/*.txt | grep -q 'Z.txt$'
    [ "$(ls "$GT"/sa/*.txt | wc -l)" -ge 2 ]
    grep -q INSTALLED "$GT"/sa/*.txt
}
@test "container exits with charon's status when charon dies" {
    printf 'eth0\neth1\n' > "$S/ifaces"
    stub charon 'echo charon >> "$S/calls"; sleep 1; exit 3'
    run timeout 10 "$SCRIPT"
    [ "$status" -eq 3 ]
}
@test "gives up with exit 1 when vici never answers" {
    printf 'eth0\neth1\n' > "$S/ifaces"
    stub swanctl 'exit 1'
    START_WAIT_SECS=2 run timeout 10 "$SCRIPT"
    [ "$status" -eq 1 ]; [[ "$output" == *"charon/vici not ready after 2s"* ]]
}
@test "exits 1 naming the missing iface after WAIT_SECS" {
    printf 'eth0\n' > "$S/ifaces"
    run "$SCRIPT"
    [ "$status" -eq 1 ]; [[ "$output" == *"iface eth1 missing"* ]]
    ! grep -q charon "$S/calls" 2>/dev/null
}
@test "WAIT_IFACES overrides the interface list" {
    printf 'eth0\n' > "$S/ifaces"
    WAIT_IFACES=eth0 run timeout 4 "$SCRIPT"
    grep -q charon "$S/calls"
}

# Probe O3: no noble package ships save-keys, so the Dockerfile must build it from the
# matching source package and guard against the source and binary versions drifting.
@test "Dockerfile builds save-keys from Ubuntu's strongswan source and copies it into the plugin dir" {
    DF="$BATS_TEST_DIRNAME/../images/ipsec-ss/Dockerfile"
    grep -q '^FROM ubuntu:24.04 AS save-keys-builder$' "$DF"
    grep -q 'apt-get source strongswan' "$DF"
    grep -q -- '--enable-save-keys' "$DF"
    grep -q '^COPY --from=save-keys-builder /save-keys.so /usr/lib/ipsec/plugins/libstrongswan-save-keys.so$' "$DF"
    grep -q 'dpkg-parsechangelog -S Version > /save-keys.version' "$DF"
    # the guard compares the source version with the installed strongswan-charon and fails the build
    grep -q "save-keys.version)\" = \"\$(dpkg-query -W -f='\${Version}' strongswan-charon)\"" "$DF"
    [ "$(grep -c '^FROM ubuntu:24.04' "$DF")" -eq 2 ]
}

# strongswan.d/charon/*.conf is included inside charon { plugins { } }; strongswan.d/*.conf at
# top level. A wrapped save-keys block lands at charon.plugins.charon.plugins.* and never loads.
@test "save-keys.conf is a bare plugin block and logging.conf a top-level charon block" {
    D="$BATS_TEST_DIRNAME/../images/ipsec-ss/strongswan.d"
    [ "$(grep -v '^#' "$D/save-keys.conf" | grep -c '^save-keys {')" -eq 1 ]
    run grep -E '^\s*(charon|plugins) \{' "$D/save-keys.conf"; [ "$status" -ne 0 ]
    grep -q 'load = yes' "$D/save-keys.conf"
    grep -q 'wireshark_keys = /gt/keys' "$D/save-keys.conf"
    [ "$(grep -c '^charon {' "$D/logging.conf")" -eq 1 ]
    grep -q 'path = /gt/charon.log' "$D/logging.conf"
    grep -q 'strongswan.d/charon/save-keys.conf' "$BATS_TEST_DIRNAME/../images/ipsec-ss/Dockerfile"
    grep -q 'strongswan.d/charon-logging.conf' "$BATS_TEST_DIRNAME/../images/ipsec-ss/Dockerfile"
}
