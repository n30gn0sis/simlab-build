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
    # health fails hard before Malcolm is even installed (no compose file
    # yet) — that is expected on a fresh system, not a blocking dependency.
    # check has nothing real to block on; apply does the actual install.
    return 0
}

malcolm_plan() {
    # No native dry-run verb; health is the closest read-only view of
    # current state, best-effort (it may legitimately fail before install).
    "$MALCOLM_DEPLOY" health || true
}

malcolm_apply() {
    local dir=${MALCOLM_BUNDLE_DIR:-} config=${MALCOLM_CONFIG_JSON:-} \
        pwfile=${MALCOLM_PASSWORD_FILE:-} user=${MALCOLM_USER:-analyst}
    if [ -z "$dir" ] || [ -z "$config" ] || [ -z "$pwfile" ]; then
        printf 'malcolm_apply: MALCOLM_BUNDLE_DIR, MALCOLM_CONFIG_JSON and MALCOLM_PASSWORD_FILE must all be set\n' >&2
        return 1
    fi

    "$MALCOLM_DEPLOY" load "$dir" \
        || { printf 'malcolm_apply: halted — load failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" assert-tags "$dir" \
        || { printf 'malcolm_apply: halted — assert-tags failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" install "$dir" \
        || { printf 'malcolm_apply: halted — install failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" configure "$config" \
        || { printf 'malcolm_apply: halted — configure failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" auth "$dir" --password-file "$pwfile" --user "$user" \
        || { printf 'malcolm_apply: halted — auth failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" bind-loopback \
        || { printf 'malcolm_apply: halted — bind-loopback failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" start \
        || { printf 'malcolm_apply: halted — start failed\n' >&2; return 1; }
    "$MALCOLM_DEPLOY" health \
        || { printf 'malcolm_apply: halted — health failed\n' >&2; return 1; }
}

malcolm_verify() {
    local pwfile=${MALCOLM_PASSWORD_FILE:-} user=${MALCOLM_USER:-analyst}
    if [ -z "$pwfile" ]; then
        printf 'malcolm_verify: MALCOLM_PASSWORD_FILE must be set\n' >&2
        return 1
    fi
    "$MALCOLM_DEPLOY" verify --password-file "$pwfile" --user "$user"
}

UFW_SCRIPT=${UFW_SCRIPT:-"$(dirname "${BASH_SOURCE[0]}")/r770-ufw.sh"}

ufw_check() {
    "$UFW_SCRIPT" plan
}

ufw_plan() {
    "$UFW_SCRIPT" plan
}

ufw_apply() {
    local rc tmp
    tmp=$(mktemp)
    "$UFW_SCRIPT" apply "$@" | tee "$tmp"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        return "$rc"
    fi
    # r770-ufw.sh's own idempotency: when the rules already match, apply
    # prints "already applied" and exits 0 WITHOUT arming a new dead-man
    # switch. Only report "armed, confirm needed" when something was
    # actually armed — confirmed against the real script, which leaves no
    # new backup dir or pending-switch marker in the already-applied case.
    if grep -q "already applied" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    printf 'ufw_apply: armed — open a NEW ssh session and run "r770-ufw.sh confirm" to keep it, or it auto-disables\n' >&2
    return 4
}

ufw_verify() {
    "$UFW_SCRIPT" verify
}
