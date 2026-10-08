setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../images/wan-emu/wan-emu.sh"
    export SCEN_PROFILES="$BATS_TEST_DIRNAME/../scenarios/profiles"
    export SCEN_REPO="$BATS_TEST_DIRNAME/.."
}
@test "dry-run apply builds br0 and shapes both directions from branch-wan" {
    run "$SCRIPT" --dry-run apply branch-wan
    [ "$status" -eq 0 ]
    [[ "$output" == *"ip link add br0 type bridge"* ]]
    [[ "$output" == *"tc qdisc replace dev eth1 root handle 1: htb default 10"* ]]
    [[ "$output" == *"tc class replace dev eth1 parent 1: classid 1:10 htb rate 20mbit"* ]]
    [[ "$output" == *"tc qdisc replace dev eth1 parent 1:10 handle 10: netem delay 40ms 5ms loss 0.2%"* ]]
    [[ "$output" == *"tc class replace dev eth0 parent 1: classid 1:10 htb rate 20mbit"* ]]
}
@test "dry-run apply with an asymmetric profile puts RATE_DOWN on eth1 and RATE_UP on eth0" {
    run "$SCRIPT" --dry-run apply lte-poor
    [[ "$output" == *"dev eth1 parent 1: classid 1:10 htb rate 5mbit"* ]]
    [[ "$output" == *"dev eth0 parent 1: classid 1:10 htb rate 1mbit"* ]]
}
@test "dry-run apply omits netem when the profile has no delay/jitter/loss" {
    run "$SCRIPT" --dry-run apply congested-uplink
    [[ "$output" != *"netem"* ]]
    [[ "$output" == *"htb rate 50mbit"* ]]
}
@test "dry-run clear deletes root qdiscs on both legs only" {
    run "$SCRIPT" --dry-run clear
    [ "$output" = $'tc qdisc del dev eth1 root\ntc qdisc del dev eth0 root' ]
}
@test "apply with an unknown profile fails" {
    run "$SCRIPT" --dry-run apply nope
    [ "$status" -eq 1 ]
}
@test "dry-run apply is idempotent: re-applying emits identical commands" {
    run "$SCRIPT" --dry-run apply branch-wan
    first="$output"
    run "$SCRIPT" --dry-run apply branch-wan
    [ "$output" = "$first" ]
    [[ "$output" != *"qdisc add"* && "$output" != *"class add"* ]]
}
