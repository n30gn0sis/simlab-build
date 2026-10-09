#!/usr/bin/env bats
# Content of scenarios/S0 and scenarios/S1: manifests, swanctl, secrets generator, wiring helper.
setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$ROOT/scripts/scenarios/scen-lib.sh"
    export SCEN_PROFILES="$ROOT/scenarios/profiles"
    T="$BATS_TEST_TMPDIR"
}
lib() { bash -c "source '$LIB'; $*"; }

@test "every scenarios/*/run.yaml has the required keys and passes manifest_get" {
    for m in "$ROOT"/scenarios/S*/run.yaml; do
        for k in run_id scenario underlay variant spec_version capture.cap_mb capture.ring traffic.script traffic.node events; do
            run lib "manifest_get '$m' $k"; [ "$status" -eq 0 ] || { echo "$m lacks $k"; false; }
        done
    done
}
@test "every profile referenced by a manifest exists" {
    for m in "$ROOT"/scenarios/S*/run.yaml; do
        for p in $(lib "manifest_list '$m' impairment profile"); do
            run lib "profile_load '$p'"; [ "$status" -eq 0 ] || { echo "$m: bad profile $p"; false; }
        done
    done
}
@test "every manifest-referenced script and events file exists" {
    for m in "$ROOT"/scenarios/S*/run.yaml; do
        d=$(dirname "$m")
        [ -f "$d/$(lib "manifest_get '$m' traffic.script")" ]
        [ -f "$d/$(lib "manifest_get '$m' events")" ]
        [ -f "$d/expected.md" ]
    done
}
@test "S0 has no ipsec block and no endpoint nodes; S1 has two endpoints" {
    run grep -q '^ipsec:' "$ROOT/scenarios/S0/run.yaml"; [ "$status" -ne 0 ]
    run grep -q 'role: endpoint' "$ROOT/scenarios/S0/run.yaml"; [ "$status" -ne 0 ]
    [ "$(grep -c 'role: endpoint' "$ROOT/scenarios/S1/run.yaml")" -eq 2 ]
}
@test "S1 swanctl confs are mirror images: both trap" {
    a="$ROOT/scenarios/S1/swanctl/gw-a.conf"; b="$ROOT/scenarios/S1/swanctl/gw-b.conf"
    grep -q 'start_action = trap' "$a"; grep -q 'start_action = trap' "$b"
    grep -q 'local_ts  = 10.200.1.0/24' "$a"; grep -q 'local_ts  = 10.200.2.0/24' "$b"
    grep -q 'remote_ts = 10.200.2.0/24' "$a"; grep -q 'remote_ts = 10.200.1.0/24' "$b"
    grep -q 'local_addrs  = 198.18.1.2' "$a"; grep -q 'local_addrs  = 198.18.2.2' "$b"
    grep -q 'id = gw-a.site-a.lab' "$a"; grep -q 'id = gw-b.site-b.lab' "$b"
    # MOBIKE floats the IKE_SA to UDP 4500 after IKE_AUTH even without NAT (X2 FAIL
    # on the staging VM); static site-to-site does not need it.
    grep -q '^    mobike = no$' "$a"; grep -q '^    mobike = no$' "$b"
    # swanctl.conf is one key per line: "auth = psk  id = x" parses as auth = "psk  id = x"
    # (staging rehearsal 2026-10-09: "invalid value for: auth, config discarded").
    for f in "$a" "$b"; do
        run grep -E '=.*[[:space:]][a-z_]+ =' "$f"; [ "$status" -ne 0 ]
        [ "$(grep -c '^      auth = psk$' "$f")" -eq 2 ]
    done
}
@test "gen-secrets.sh writes a gitignored secrets.conf and the ground-truth copy" {
    cp -r "$ROOT/scenarios/S1" "$T/S1"
    RUN_DIR="$T/run" run "$ROOT/scenarios/S1/gen-secrets.sh" "$T/S1"; [ "$status" -eq 0 ]
    grep -qE 'secret = "[0-9a-f]{64}"' "$T/S1/swanctl/secrets.conf"
    [ "$(stat -c %a "$T/S1/swanctl/secrets.conf")" = 600 ]
    [ "$(stat -c %a "$T/run/gt/psk.txt")" = 600 ]
    grep -q "$(cat "$T/run/gt/psk.txt")" "$T/S1/swanctl/secrets.conf"
    git -C "$ROOT" check-ignore -q scenarios/S1/swanctl/secrets.conf
}
@test "no scenario file carries a version pin or a real secret" {
    run grep -rE 'secret = "[0-9a-f]{64}"' "$ROOT/scenarios/"; [ "$status" -ne 0 ]
    pins=$(grep -hE '(:|@sha256:)[0-9a-f]{12,}|:v?[0-9]+\.[0-9]+\.[0-9]+' "$ROOT"/scenarios/S*/run.yaml "$ROOT"/scenarios/S1/staging-compose.yaml | grep -v '0\.0\.0-fixture' || true)
    [ -z "$pins" ]
}
@test "scen-wire.sh --dry-run prints the veth, netns, bridge, address and route commands" {
    run "$ROOT/scenarios/S1/scen-wire.sh" --dry-run gw-a br-lab-t01 eth0 198.18.1.2/30 198.18.1.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"ip link add veth-t01a type veth peer name veth-t01a-c"* ]]
    [[ "$output" == *"ip link set veth-t01a master br-lab-t01"* ]]
    [[ "$output" == *"netns"* ]]
    [[ "$output" == *"ip addr add 198.18.1.2/30 dev eth0"* ]]
    [[ "$output" == *"ip route add default via 198.18.1.1"* ]]
}
@test "scen-wire.sh refuses a bridge that is not a lab bridge" {
    run "$ROOT/scenarios/S1/scen-wire.sh" --dry-run gw-a br-mgmt eth0 198.18.1.2/30
    [ "$status" -ne 0 ]
    [[ "$output" == *"bridge must be br-lab-"* ]]
}

# The harness addresses nodes by container name (scen-wire.sh, $SCEN_EXEC <node>,
# docker cp <node>:/gt); Compose's default <project>-<service>-1 names would break all three.
@test "staging-compose pins container_name to the node name on every service" {
    f="$ROOT/scenarios/S1/staging-compose.yaml"
    python3 -I - "$f" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
want = {'gw-a': 'gw-a', 'gw-b': 'gw-b', 'gw-a-s1': 'gw-a', 'gw-b-s1': 'gw-b',
        'isp1': 'isp1', 'host-a': 'host-a', 'host-b': 'host-b', 'svc-b': 'svc-b'}
got = {k: v.get('container_name') for k, v in d['services'].items()}
assert got == want, got
# two services may share a container name only when their profiles never overlap
for a, b in [('gw-a', 'gw-a-s1'), ('gw-b', 'gw-b-s1')]:
    assert not set(d['services'][a]['profiles']) & set(d['services'][b]['profiles']), (a, b)
# /gt must be an anonymous volume so -V gives every run a fresh ground truth
for g in ('gw-a-s1', 'gw-b-s1'):
    assert '/gt' in d['services'][g]['volumes'], g
assert not d.get('volumes'), d.get('volumes')
PY
}

# When nothing answers, 50 requests x their own timeouts would outrun the 240 s timeline.
@test "traffic scripts budget the http and dns phases" {
    for f in "$ROOT"/scenarios/S0/traffic/profile-basic.sh "$ROOT"/scenarios/S1/traffic/profile-basic.sh; do
        grep -q '^http() { phase; for .*; do budget || break;' "$f"
        grep -q '^dns()  { phase; for .*; do budget || break;' "$f"
        grep -q '^budget() {.*-lt 60' "$f"
        # the whole 240 s load must carry two-way traffic, or DPD fires mid-run (X6, 2026-10-09)
        grep -q '^( while \[ \$(( \$(date +%s) - T0 )) -lt 240 \]; do ping -c 1 -W 1 "\$SRV" >/dev/null 2>&1; sleep 1; done ) &$' "$f"
        grep -q '^wait "\$KEEPALIVE"$' "$f"
        # UDP datagrams must fit the tunnel MTU, or the UDP phase is empty (2026-10-09)
        grep -q '^udp()  { step iperf3 .* -u -b 5M -l 1200 -t 30; }$' "$f"
        grep -q '^sleep 40$' "$f"
    done
}
