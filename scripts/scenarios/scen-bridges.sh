#!/usr/bin/env bash
# Temporary until lab-transit.sh (Phase 7) — fold in, don't fork.
# The fabric script from the (unfiled) lab-fabric.md will own the lab bridges;
# this exists so staging and bats can create them today.
#
# scen-bridges.sh create|destroy [--dry-run] [--force] <bridge>...
# Bridges are br-lab-tNN, br-lab-iNN or br-lab-ext only. create never assigns
# an address (IPv6 is disabled on the bridge); destroy refuses a bridge that
# still has member ports unless --force.
set -euo pipefail
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=/dev/null
source "$HERE/scen-lib.sh"

SCEN_SYSNET="${SCEN_SYSNET:-/sys/class/net}"
usage() { die "usage: scen-bridges.sh create|destroy [--dry-run] [--force] <bridge>..."; }

[ $# -ge 1 ] || usage
ACTION="$1"; shift
case "$ACTION" in create|destroy) ;; *) usage ;; esac
DRY=0 FORCE=0 BRIDGES=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        -*) usage ;;
        *) BRIDGES+=("$a") ;;
    esac
done
[ "${#BRIDGES[@]}" -gt 0 ] || usage

# Validate every name before touching anything.
for b in "${BRIDGES[@]}"; do
    guard_iface "$b" || exit 1
    [[ $b =~ ^br-lab-(t|i)[0-9]{2}$ || $b == br-lab-ext ]] || die "refused: $b is not a lab bridge name (br-lab-tNN, br-lab-iNN, br-lab-ext)"
done

run() {  # run <cmd...> — print under --dry-run, else log and execute
    if [ "$DRY" = 1 ]; then echo "$*"; else log "+ $*"; "$@"; fi
}

for b in "${BRIDGES[@]}"; do
    case "$ACTION" in
    create)
        if [ -d "$SCEN_SYSNET/$b" ]; then log "$b already exists"
        else run ip link add "$b" type bridge; fi
        run ip link set "$b" up
        run sysctl -qw "net.ipv6.conf.$b.disable_ipv6=1"
        ;;
    destroy)
        if [ ! -d "$SCEN_SYSNET/$b" ]; then log "$b does not exist, skipped"; continue; fi
        if [ "$FORCE" = 0 ] && [ -n "$(ls -A "$SCEN_SYSNET/$b/brif" 2>/dev/null)" ]; then
            die "refused: $b has member ports (use --force)"
        fi
        run ip link del "$b"
        ;;
    esac
done
