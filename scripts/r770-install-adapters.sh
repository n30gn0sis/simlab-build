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

PORTAL=${PORTAL:-"$(dirname "${BASH_SOURCE[0]}")/r770-portal.sh"}

portal_check() {
    return 0
}

portal_plan() {
    "$PORTAL" plan "$@"
}

portal_apply() {
    "$PORTAL" apply "$@"
}

portal_verify() {
    "$PORTAL" verify "$@"
}

MALCOLM_DEPLOY=${MALCOLM_DEPLOY:-"$(dirname "${BASH_SOURCE[0]}")/r770-malcolm-deploy.sh"}

malcolm_check() {
    "$MALCOLM_DEPLOY" health
}

malcolm_plan() {
    # No native dry-run verb; health is the closest read-only view of
    # current state. Known limitation, not a true diff — see the design
    # spec's "contract mismatch" risk.
    "$MALCOLM_DEPLOY" health
}

malcolm_apply() {
    local verb
    for verb in load assert-tags install configure auth bind-loopback start health; do
        if ! "$MALCOLM_DEPLOY" "$verb"; then
            printf 'malcolm_apply: halted — %s failed\n' "$verb" >&2
            return 1
        fi
    done
}

malcolm_verify() {
    "$MALCOLM_DEPLOY" verify
}

UFW_SCRIPT=${UFW_SCRIPT:-"$(dirname "${BASH_SOURCE[0]}")/r770-ufw.sh"}

ufw_check() {
    "$UFW_SCRIPT" plan
}

ufw_plan() {
    "$UFW_SCRIPT" plan
}

ufw_apply() {
    local rc
    "$UFW_SCRIPT" apply "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'ufw_apply: armed — open a NEW ssh session and run "r770-ufw.sh confirm" to keep it, or it auto-disables\n' >&2
        return 4
    fi
    return "$rc"
}

ufw_verify() {
    "$UFW_SCRIPT" verify
}
