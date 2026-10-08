#!/usr/bin/env bash
# wan-emu — L2 bump-in-the-wire impairment node (spec §5.4, mechanism M2).
# eth0 <-> br0 <-> eth1. Shaping is egress: eth1 egress = A->B (RATE_DOWN),
# eth0 egress = B->A (RATE_UP). Reads the same profiles/*.conf as wan-apply.
set -euo pipefail
# shellcheck source=/dev/null
. "${SCEN_LIB:-${SCEN_REPO:-/opt/scen}/scripts/scenarios/scen-lib.sh}"

DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
run() { if [ "$DRY" = 1 ]; then echo "$*"; else "$@"; fi; }

netem_args() {  # from P_* → "delay 40ms 5ms loss 0.2%" or empty
    local a=""
    [ -n "$P_DELAY" ] && a="delay $P_DELAY${P_JITTER:+ $P_JITTER}"
    [ -n "$P_LOSS" ] && [ "$P_LOSS" != "0%" ] && a="$a${a:+ }loss $P_LOSS"
    echo "$a"
}
shape() {  # shape <dev> <rate>
    run tc qdisc replace dev "$1" root handle 1: htb default 10
    run tc class replace dev "$1" parent 1: classid 1:10 htb rate "$2"
    local n; n=$(netem_args)
    # shellcheck disable=SC2086
    [ -n "$n" ] && run tc qdisc replace dev "$1" parent 1:10 handle 10: netem $n
    return 0
}
bridge_up() {
    run ip link add br0 type bridge || true   # tolerate an existing bridge (re-apply)
    run ip link set eth0 master br0; run ip link set eth1 master br0
    run ip link set br0 up
}
case "${1:-}" in
    apply) profile_load "$2"; bridge_up
           shape eth1 "${P_RATE_DOWN:-1000mbit}"; shape eth0 "${P_RATE_UP:-1000mbit}" ;;
    clear) run tc qdisc del dev eth1 root || true; run tc qdisc del dev eth0 root || true ;;  # missing qdisc is fine
    show)  tc qdisc show dev eth1; tc qdisc show dev eth0 ;;
    *) die "usage: wan-emu.sh [--dry-run] apply <profile> | show | clear" ;;
esac
