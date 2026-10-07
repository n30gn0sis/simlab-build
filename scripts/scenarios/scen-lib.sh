#!/usr/bin/env bash
# scen-lib.sh — shared functions for the reference-PCAP harness (spec §8).
# Sourced by scen-prep, scen-run, scen-check, scen-ingest, scen-clear. No side
# effects at source time. Every path is an env var with a default so bats can
# redirect it.
set -euo pipefail

SCEN_REPO="${SCEN_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCEN_PROFILES="${SCEN_PROFILES:-$SCEN_REPO/scenarios/profiles}"
SCEN_CASES="${SCEN_CASES:-/data/pcap/cases}"
SCEN_CAPTURE_PORTS="${SCEN_CAPTURE_PORTS:-}"      # Phase 9 list, space-separated
SCEN_LOG="${SCEN_LOG:-}"

log() {  # UTC with milliseconds, to stdout and (if set) $SCEN_LOG — spec §8.5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    printf '%s %s\n' "$ts" "$*"
    if [ -n "$SCEN_LOG" ]; then printf '%s %s\n' "$ts" "$*" >> "$SCEN_LOG"; fi
}
die() { echo "ERROR: $*" >&2; exit 1; }

# profile_load <name> — exports P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE
profile_load() {
    local f="$SCEN_PROFILES/$1.conf" k v line
    [ -f "$f" ] || die "no such profile: $1 ($f)"
    P_RATE_DOWN='' P_RATE_UP='' P_DELAY='' P_JITTER='' P_LOSS='' P_NOTE=''
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        case "$k" in
            RATE_DOWN|RATE_UP|DELAY|JITTER|LOSS|NOTE) printf -v "P_$k" '%s' "$v" ;;
            *) die "profile $1: unknown key $k" ;;
        esac
    done < "$f"
    export P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE
}

# guard_iface <iface> — CLAUDE.md rule 8 / spec §6.1: lab segments only.
guard_iface() {
    local i="$1" p
    for p in $SCEN_CAPTURE_PORTS; do
        [ "$i" = "$p" ] && { echo "refused: $i is a capture port" >&2; return 1; }
    done
    case "$i" in
        br-lab-t[0-9][0-9]|br-lab-i[0-9][0-9]|br-lab-ext|veth-*) return 0 ;;
        *) echo "refused: $i is not a lab transit/inner bridge or veth (mgmt, capture, mirror and host bridges are off limits)" >&2; return 1 ;;
    esac
}
