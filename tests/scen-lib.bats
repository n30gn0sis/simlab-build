# scen-lib.sh: profile loading, interface guard, timestamped log. Pure functions;
# nothing here touches a real host.
setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-lib.sh"
    export SCEN_PROFILES="$BATS_TEST_DIRNAME/../scenarios/profiles"
    export T="$BATS_TEST_TMPDIR"
    cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$T/run.yaml"
}
lib() { bash -c "source '$LIB'; $*"; }

@test "profile_load exports every field of branch-wan" {
    run lib 'profile_load branch-wan && echo "$P_RATE_DOWN $P_DELAY $P_JITTER $P_LOSS"'
    [ "$status" -eq 0 ]
    [ "$output" = "20mbit 40ms 5ms 0.2%" ]
}
@test "profile_load leaves absent fields empty" {
    run lib 'profile_load congested-uplink && echo "[$P_DELAY][$P_RATE_DOWN]"'
    [ "$output" = "[][50mbit]" ]
}
@test "profile_load fails on a missing profile" {
    run lib 'profile_load no-such-profile'
    [ "$status" -eq 1 ]; [[ "$output" == *"no such profile"* ]]
}
@test "profile_load rejects an unknown key" {
    mkdir -p "$T/p"; printf 'RATE_DOWN=1mbit\nBOGUS=1\n' > "$T/p/x.conf"
    SCEN_PROFILES="$T/p" run lib 'profile_load x'
    [ "$status" -eq 1 ]; [[ "$output" == *"unknown key BOGUS"* ]]
}
@test "guard_iface allows lab bridges and veths, refuses mgmt/capture/mirror" {
    for ok in br-lab-t01 br-lab-i12 br-lab-ext veth-t01a; do
        run lib "guard_iface $ok"; [ "$status" -eq 0 ]
    done
    for bad in lacp-trunk lacp-trunk.10 eno17295np0 ens5f0 bond0 br-mirror mirror0 br-lab-mgmt br-lab-nat lo; do
        run lib "guard_iface $bad"; [ "$status" -eq 1 ]; [[ "$output" == *"refused"* ]]
    done
}
@test "guard_iface also refuses anything in SCEN_CAPTURE_PORTS" {
    SCEN_CAPTURE_PORTS="br-lab-t99" run lib 'guard_iface br-lab-t99'
    [ "$status" -eq 1 ]; [[ "$output" == *"capture port"* ]]
}
@test "log writes a UTC millisecond timestamp and appends to SCEN_LOG" {
    SCEN_LOG="$T/events.log" run lib 'log "traffic start"'
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\ traffic\ start$ ]]
    grep -q "traffic start" "$T/events.log"
}

@test "manifest_get reads scalars by dotted path" {
    run lib "manifest_get '$T/run.yaml' run_id";          [ "$output" = "S1-W1-ss-20261001T1400Z" ]
    run lib "manifest_get '$T/run.yaml' ipsec.child_rekey_s"; [ "$output" = "120" ]
    run lib "manifest_get '$T/run.yaml' nope.nope"; [ "$status" -eq 1 ]
}
@test "manifest_get prints empty for a null value" {
    run lib "manifest_get '$T/run.yaml' times_utc.start"; [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "manifest_list returns one field per list item" {
    run lib "manifest_list '$T/run.yaml' capture_points bridge"
    [ "$output" = $'br-lab-t01\nbr-lab-t02\nbr-lab-i01\nbr-lab-i02' ]
    run lib "manifest_list '$T/run.yaml' impairment iface"; [ "$output" = "veth-t01a" ]
}
@test "run_dir_for is cases/scenario/run_id" {
    SCEN_CASES=/x run lib "run_dir_for '$T/run.yaml'"; [ "$output" = "/x/S1/S1-W1-ss-20261001T1400Z" ]
}
