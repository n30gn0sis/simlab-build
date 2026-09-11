#!/usr/bin/env bash
#
# r770-airgap-sim.sh — simulate the air gap on the staging VM so an offline
# deployment can be rehearsed while we still have internet to fix what breaks.
#
#   block [--minutes N]   drop internet egress, keep the LAN and loopback
#   unblock               restore egress, cancel the timer
#   status                BLOCKED / OPEN, plus time remaining
#
# SAFETY: block ALWAYS schedules an unconditional unblock (default 30 min).
# A firewall change you cannot undo from the far side of that firewall is the
# exact failure this exists to prevent -- the same discipline as `netplan try`
# in the R770 runbook.
#
# TWO CHAINS, NOT ONE. Host processes (curl, dockerd pulling an image) emit
# locally-generated packets, which traverse OUTPUT. Traffic from a RUNNING
# CONTAINER is forwarded, and never traverses OUTPUT at all -- it goes through
# FORWARD, where Docker publishes the DOCKER-USER chain as the supported hook.
# Filtering only OUTPUT would leave the Malcolm stack with live internet while
# this script reported BLOCKED, and the rehearsal would certify "deploys
# offline" against a stack that was quietly online. Malcolm's components fetch
# rule updates, GeoIP and OUI feeds at startup, so that false pass is the
# expensive one: the R770 has genuinely no route and would behave differently.
#
# AIRGAP_DRY_RUN=1 prints the rules instead of applying them (used by tests).
set -euo pipefail

LAN="${AIRGAP_LAN:-192.168.4.0/22}"
DRY="${AIRGAP_DRY_RUN:-0}"
MARK="r770-airgap-sim"
TIMER="/run/${MARK}.deadline"
DOCKER_CHAIN="DOCKER-USER"

die() { echo "r770-airgap-sim: $*" >&2; exit 1; }

apply() { if [ "$DRY" = "1" ]; then echo "iptables $*"; else iptables "$@"; fi; }

# Docker creates DOCKER-USER when the daemon starts. If the daemon has never
# run, create it and jump FORWARD into it ourselves, so the forwarded path is
# covered whether or not Docker is up yet.
ensure_docker_chain() {
    if [ "$DRY" = "1" ]; then
        echo "iptables -N ${DOCKER_CHAIN} (if absent)"
        echo "iptables -I FORWARD 1 -j ${DOCKER_CHAIN} (if absent)"
        return 0
    fi
    if ! iptables -n -L "$DOCKER_CHAIN" >/dev/null 2>&1; then
        iptables -N "$DOCKER_CHAIN"
    fi
    iptables -C FORWARD -j "$DOCKER_CHAIN" 2>/dev/null \
        || iptables -I FORWARD 1 -j "$DOCKER_CHAIN"
}

cmd_block() {
    local minutes=30
    while [ $# -gt 0 ]; do
        case $1 in
            --minutes)
                minutes=${2:-}
                [[ "$minutes" =~ ^[0-9]+$ ]] || die "--minutes must be a whole number, got '${minutes:-}'"
                if ! { [ "$minutes" -ge 1 ] && [ "$minutes" -le 240 ]; }; then
                    die "--minutes must be 1-240"
                fi
                shift ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done

    # Locally-generated traffic. Order is load-bearing: every ACCEPT must
    # precede the catch-all DROP.
    apply -I OUTPUT 1 -o lo -j ACCEPT
    apply -I OUTPUT 2 -d "127.0.0.0/8" -j ACCEPT
    apply -I OUTPUT 3 -d "$LAN" -j ACCEPT
    apply -I OUTPUT 4 -d 172.16.0.0/12 -j ACCEPT      # docker bridges
    apply -A OUTPUT -m comment --comment "$MARK" -j DROP

    # Forwarded traffic -- the path every container actually uses.
    # ESTABLISHED,RELATED first so return packets for permitted flows survive;
    # the internet never gets a flow established in the first place, because
    # the outbound SYN meets the DROP below.
    ensure_docker_chain
    apply -I "$DOCKER_CHAIN" 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    apply -I "$DOCKER_CHAIN" 2 -d "127.0.0.0/8" -j ACCEPT
    apply -I "$DOCKER_CHAIN" 3 -d "$LAN" -j ACCEPT
    apply -I "$DOCKER_CHAIN" 4 -d 172.16.0.0/12 -j ACCEPT   # container-to-container
    apply -A "$DOCKER_CHAIN" -m comment --comment "$MARK" -j DROP

    echo "auto-revert scheduled in ${minutes} minute(s)"
    if [ "$DRY" != "1" ]; then
        local self
        self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
        date -d "+${minutes} minutes" +%s > "$TIMER"
        setsid bash -c "sleep $((minutes*60)); '$self' unblock" >/dev/null 2>&1 &
    fi
}

cmd_unblock() {
    if [ "$DRY" = "1" ]; then
        echo "iptables -D OUTPUT ... (dry run)"
        echo "iptables -D ${DOCKER_CHAIN} ... (dry run)"
        return 0
    fi
    while iptables -D OUTPUT -m comment --comment "$MARK" -j DROP 2>/dev/null; do :; done
    iptables -D OUTPUT -d 172.16.0.0/12 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -d "$LAN" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -d "127.0.0.0/8" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true

    if iptables -n -L "$DOCKER_CHAIN" >/dev/null 2>&1; then
        while iptables -D "$DOCKER_CHAIN" -m comment --comment "$MARK" -j DROP 2>/dev/null; do :; done
        iptables -D "$DOCKER_CHAIN" -d 172.16.0.0/12 -j ACCEPT 2>/dev/null || true
        iptables -D "$DOCKER_CHAIN" -d "$LAN" -j ACCEPT 2>/dev/null || true
        iptables -D "$DOCKER_CHAIN" -d "127.0.0.0/8" -j ACCEPT 2>/dev/null || true
        iptables -D "$DOCKER_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi

    rm -f "$TIMER"
    echo "egress restored"
}

# BLOCKED only if BOTH paths are closed. A half-applied block is reported as
# PARTIAL rather than OPEN, because "OPEN" would invite a retry that stacks a
# second set of rules on top of the first.
cmd_status() {
    local out=0 fwd=0
    iptables -C OUTPUT -m comment --comment "$MARK" -j DROP 2>/dev/null && out=1
    iptables -C "$DOCKER_CHAIN" -m comment --comment "$MARK" -j DROP 2>/dev/null && fwd=1

    if [ "$out" = 1 ] && [ "$fwd" = 1 ]; then
        if [ -r "$TIMER" ]; then
            echo "BLOCKED ($(( $(cat "$TIMER") - $(date +%s) ))s until auto-revert)"
        else
            echo "BLOCKED (no timer found - run unblock)"
        fi
    elif [ "$out" = 1 ] || [ "$fwd" = 1 ]; then
        echo "PARTIAL (OUTPUT=${out} ${DOCKER_CHAIN}=${fwd}) - run unblock, then block again"
    else
        echo "OPEN"
    fi
}

case "${1:-}" in
    block)   shift; cmd_block "$@" ;;
    unblock) cmd_unblock ;;
    status)  cmd_status ;;
    *)       die "usage: r770-airgap-sim.sh block [--minutes N] | unblock | status" ;;
esac
