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
    ! grep -q '^ipsec:' "$ROOT/scenarios/S0/run.yaml"
    ! grep -q 'role: endpoint' "$ROOT/scenarios/S0/run.yaml"
    [ "$(grep -c 'role: endpoint' "$ROOT/scenarios/S1/run.yaml")" -eq 2 ]
}
@test "S1 swanctl confs are mirror images: gw-a starts, gw-b traps" {
    a="$ROOT/scenarios/S1/swanctl/gw-a.conf"; b="$ROOT/scenarios/S1/swanctl/gw-b.conf"
    grep -q 'start_action = start' "$a"; grep -q 'start_action = trap' "$b"
    grep -q 'local_ts  = 10.200.1.0/24' "$a"; grep -q 'local_ts  = 10.200.2.0/24' "$b"
    grep -q 'remote_ts = 10.200.2.0/24' "$a"; grep -q 'remote_ts = 10.200.1.0/24' "$b"
    grep -q 'local_addrs  = 198.18.1.2' "$a"; grep -q 'local_addrs  = 198.18.2.2' "$b"
    grep -q 'id = gw-a.site-a.lab' "$a"; grep -q 'id = gw-b.site-b.lab' "$b"
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
    ! grep -rE 'secret = "[0-9a-f]{64}"' "$ROOT/scenarios/"
    ! grep -rhE '(:|@sha256:)[0-9a-f]{12,}|:v?[0-9]+\.[0-9]+\.[0-9]+' "$ROOT"/scenarios/S*/run.yaml "$ROOT"/scenarios/S1/staging-compose.yaml | grep -v '0\.0\.0-fixture'
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
}
