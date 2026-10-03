#!/usr/bin/env bash
# scripts/r770-install.sh — resumable orchestrator for the R770 install sub-projects.
#
# Drives sub-project 0's Phase 3 piece and sub-project 2 (lab-CA, Malcolm,
# portal, UFW) through a check/plan/apply/verify contract. See
# docs/superpowers/specs/2026-10-03-r770-install-orchestrator-design.md.
#
# Resumability note: the storage step's skip decision reads
# state/BUILD-STATE.md's Phase 3 row directly (one step, one phase). The
# lab-CA/Malcolm/portal/UFW steps map to phases 10 and 13 at a coarser grain
# than BUILD-STATE can resolve per-step, so their skip decision instead comes
# from each script's own idempotent plan/health/verify output. BUILD-STATE
# Phase 10/13 rows are still written once every step mapping to that phase
# verifies — that's the record, not the input.
set -euo pipefail

die()  { printf 'REFUSE  %s\n' "$*" >&2; exit 1; }

# phase_status <phase_num> <build_state_file>
# Prints the Status cell for a Phases-table row, stripped of markdown bold
# and any trailing parenthetical note. Exits 1 if the row is missing or the
# cell has no recognized keyword — never silently defaults.
phase_status() {
    local phase=$1 file=$2
    local line
    line=$(awk -F'|' -v n="$phase" '
        {
            f2 = $2
            gsub(/^ +| +$/, "", f2)
            if (f2 == n) { print; found=1 }
        }
        END { if (!found) exit 1 }
    ' "$file") || die "phase_status: no row for phase $phase in $file"

    local raw status
    raw=$(printf '%s' "$line" | awk -F'|' '{print $6}')
    raw=${raw//\*/}
    raw=$(printf '%s' "$raw" | sed -E 's/\([^)]*\)//g')
    raw=$(printf '%s' "$raw" | sed -E 's/^ +| +$//g')

    case "$raw" in
        "NOT STARTED"|READY|BLOCKED|APPLIED|VERIFIED*) status=$raw ;;
        *) die "phase_status: unrecognized status '$raw' for phase $phase" ;;
    esac
    case "$status" in
        VERIFIED*) status=VERIFIED ;;
    esac
    printf '%s\n' "$status"
}

STEP_IDS=(storage labca malcolm portal ufw)

step_gated() {
    case "$1" in
        storage|ufw) return 0 ;;
        labca|malcolm|portal) return 1 ;;
        *) die "step_gated: unknown step '$1'" ;;
    esac
}

step_build_state_phase() {
    case "$1" in
        storage) printf '3\n'; return 0 ;;
        labca|malcolm|portal|ufw) return 1 ;;
        *) die "step_build_state_phase: unknown step '$1'" ;;
    esac
}

step_registered() {
    local id=$1
    declare -F "${id}_check" >/dev/null \
        && declare -F "${id}_plan" >/dev/null \
        && declare -F "${id}_apply" >/dev/null \
        && declare -F "${id}_verify" >/dev/null
}

if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi

die "scripts/r770-install.sh: no further CLI yet — later tasks add --list/--only/--confirm"
