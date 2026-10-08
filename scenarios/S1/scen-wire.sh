#!/usr/bin/env bash
# scen-wire.sh [--dry-run] [--end a|b|c] <container> <bridge> <ifname> <cidr> [gw]
# Part-B staging helper. Joins a network_mode:none container to a lab bridge with a veth
# pair: the bridge-side end is veth-<bridge suffix><end> (e.g. veth-t01a — the name
# the manifest's impairment.iface and guard_iface use); the peer moves into the
# container's netns as <ifname>, gets <cidr>, and [gw] becomes the default route.
# --end distinguishes several containers on one bridge (default a).
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../scripts/scenarios/scen-lib.sh"

DRY=0; END=a
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --end) END="${2:?--end needs a|b|c}"; shift 2 ;;
        *) break ;;
    esac
done
if [ $# -lt 4 ] || [ $# -gt 5 ]; then
    die "usage: scen-wire.sh [--dry-run] [--end a|b|c] <container> <bridge> <ifname> <cidr> [gw]"
fi
ctr="$1"; br="$2"; ifn="$3"; cidr="$4"; gw="${5:-}"
[[ $END =~ ^[abc]$ ]] || die "--end must be a, b or c"
[[ $ctr =~ ^[A-Za-z0-9._-]+$ ]] || die "bad container name: $ctr"
[[ $br =~ ^br-lab-(t[0-9][0-9]|i[0-9][0-9])$ ]] || die "bridge must be br-lab-tNN or br-lab-iNN (got $br)"
[[ $ifn =~ ^[a-z][a-z0-9]{0,10}$ ]] || die "bad interface name: $ifn"
[[ $cidr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "bad CIDR: $cidr"
[ -z "$gw" ] || [[ $gw =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "bad gateway: $gw"

host_if="veth-${br#br-lab-}$END"; peer_if="$host_if-c"
guard_iface "$br" || exit 1
guard_iface "$host_if" || exit 1

CTR="${SCEN_CTR:-docker}"
run() { if [ "$DRY" -eq 1 ]; then echo "+ $*"; else "$@"; fi; }

if [ "$DRY" -eq 1 ]; then pid="<pid of $ctr>"; else
    [ ! -e "${SCEN_SYSNET:-/sys/class/net}/$host_if" ] || die "$host_if already exists; remove it first"
    pid=$("$CTR" inspect -f '{{.State.Pid}}' "$ctr") || die "cannot inspect $ctr"
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die "$ctr is not running (pid '$pid')"
fi

run ip link add "$host_if" type veth peer name "$peer_if"
run ip link set "$peer_if" netns "$pid"
run nsenter -t "$pid" -n ip link set "$peer_if" name "$ifn"
run ip link set "$host_if" master "$br"
run ip link set "$host_if" up
run nsenter -t "$pid" -n ip addr add "$cidr" dev "$ifn"
run nsenter -t "$pid" -n ip link set "$ifn" up
if [ -n "$gw" ]; then run nsenter -t "$pid" -n ip route add default via "$gw"; fi
