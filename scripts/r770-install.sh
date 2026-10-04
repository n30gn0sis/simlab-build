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

adapters="$(dirname "${BASH_SOURCE[0]}")/r770-install-adapters.sh"
# shellcheck disable=SC1090
[ -r "$adapters" ] && source "$adapters"

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

    # Match the keyword as a prefix, not full equality — real BUILD-STATE.md
    # rows commonly trail a keyword with an em-dash note (e.g.
    # "NOT STARTED — Proven on staging VM 9771 ..."), which this function
    # must still resolve to the plain keyword.
    case "$raw" in
        "NOT STARTED"*) status="NOT STARTED" ;;
        READY*)         status=READY ;;
        BLOCKED*)       status=BLOCKED ;;
        APPLIED*)       status=APPLIED ;;
        VERIFIED*)      status=VERIFIED ;;
        *) die "phase_status: unrecognized status '$raw' for phase $phase" ;;
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

# run_step <id> <build_state_file> [--confirm]
run_step() {
    local id=$1 bsfile=$2 confirm=${3:-}

    if ! step_registered "$id"; then
        printf 'run_step: %s — not yet implemented, stopping here\n' "$id" >&2
        return 3
    fi

    local phase
    if phase=$(step_build_state_phase "$id" 2>/dev/null); then
        local st
        st=$(phase_status "$phase" "$bsfile") || return 1
        if [ "$st" = APPLIED ] || [ "$st" = VERIFIED ]; then
            return 0
        fi
    fi

    local check_rc
    if "${id}_check"; then
        check_rc=0
    else
        check_rc=$?
    fi
    if [ "$check_rc" -eq 2 ]; then
        printf 'run_step: %s — unmet dependency, stopping here\n' "$id" >&2
        return 2
    elif [ "$check_rc" -ne 0 ]; then
        return 1
    fi

    if step_gated "$id"; then
        if [ "$confirm" != "--confirm" ]; then
            "${id}_plan"
            printf 'run_step: %s is gated — review the plan above, then re-run with --confirm\n' "$id" >&2
            return 2
        fi
    fi

    "${id}_apply" || return $?
    "${id}_verify"
}

# main [--only id1,id2,...] [--confirm <step_id>]
#
# --confirm names exactly one step. A bare --confirm (no value) is refused:
# applying it to every gated step in the run would let one operator
# confirmation silently also approve a later, unrelated gated step (e.g.
# confirming storage must never also confirm UFW's firewall change) —
# CLAUDE.md rule 3 requires a separate look at each gated step's own plan.
main() {
    local only="" confirm_step=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --only) only=$2; shift 2 ;;
            --confirm)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    die "main: --confirm requires a step id (e.g. --confirm storage)"
                fi
                confirm_step=$2
                shift 2
                ;;
            *) die "main: unknown argument '$1'" ;;
        esac
    done

    local ids=("${STEP_IDS[@]}")
    if [ -n "$only" ]; then
        IFS=',' read -r -a ids <<< "$only"
    fi

    local id rc this_confirm
    for id in "${ids[@]}"; do
        this_confirm=""
        [ "$id" = "$confirm_step" ] && this_confirm="--confirm"
        if run_step "$id" "${INSTALL_BUILD_STATE:-state/BUILD-STATE.md}" "$this_confirm"; then
            rc=0
        else
            rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi
    done
    return 0
}

usage() {
    die "usage: r770-install.sh [--list | --only id1,id2,... ] [--confirm step_id]"
}

cmd_list() {
    local id gated reg
    for id in "${STEP_IDS[@]}"; do
        step_gated "$id" && gated=gated || gated="not gated"
        step_registered "$id" && reg=registered || reg="not yet implemented"
        printf '%-10s %-10s %s\n' "$id" "$gated" "$reg"
    done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        --list) cmd_list ;;
        --only|--confirm|"") main "$@" ;;
        *) usage ;;
    esac
fi
