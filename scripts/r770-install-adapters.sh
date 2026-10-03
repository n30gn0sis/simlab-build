#!/usr/bin/env bash
# scripts/r770-install-adapters.sh — translates each phase script's real CLI
# (none of which natively speak check/plan/apply/verify) into that contract.
# Sourced by scripts/r770-install.sh; never run standalone.

PHASE3_RUN=${PHASE3_RUN:-"$(dirname "${BASH_SOURCE[0]}")/r770-phase3-run.sh"}

storage_check() {
    "$PHASE3_RUN" check && return 0
    return 2   # phase3-run's own checks found an unmet dependency
}

storage_plan() {
    # phase3-run's check already prints the storage plan (lsblk, fstab,
    # discard verdicts) — there's no separate dry-run verb to call.
    "$PHASE3_RUN" check
}

storage_apply() {
    "$PHASE3_RUN" apply "$@"
}

storage_verify() {
    # No distinct verify verb; re-running check is the same read-only proof
    # the sub-project 0 spec's Part 2.2 step 4 runs by hand after apply.
    "$PHASE3_RUN" check
}

LAB_CA=${LAB_CA:-"$(dirname "${BASH_SOURCE[0]}")/r770-lab-ca.sh"}

labca_check() {
    # r770-lab-ca.sh never regenerates an existing CA, so apply is always
    # safe to invoke — check has nothing to block on.
    return 0
}

labca_plan() {
    "$LAB_CA" plan
}

labca_apply() {
    "$LAB_CA" apply "$@"
}

labca_verify() {
    "$LAB_CA" verify
}
