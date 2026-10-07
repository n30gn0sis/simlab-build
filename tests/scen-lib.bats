# scen-lib.sh: profile loading, interface guard, timestamped log. Pure functions;
# nothing here touches a real host.
setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-lib.sh"
    export SCEN_PROFILES="$BATS_TEST_DIRNAME/../scenarios/profiles"
    export T="$BATS_TEST_TMPDIR"
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
