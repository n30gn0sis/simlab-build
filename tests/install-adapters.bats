#!/usr/bin/env bats
#
# scripts/r770-install-adapters.sh translates each phase script's real CLI
# (none of which natively speak check/plan/apply/verify) into that contract.
# Every real script is a stub here; nothing touches a real system.

setup() {
    ADAPTERS="$BATS_TEST_DIRNAME/../scripts/r770-install-adapters.sh"
    T="$BATS_TEST_TMPDIR"
    export PHASE3_RUN="$T/phase3-run.sh"
}

stub_phase3_run() {
    cat > "$PHASE3_RUN" <<EOF
#!/usr/bin/env bash
echo "phase3-run \$*" >> "$T/calls"
case "\$1" in
    check) exit "\${CHECK_EXIT:-0}" ;;
    apply) exit "\${APPLY_EXIT:-0}" ;;
esac
EOF
    chmod +x "$PHASE3_RUN"
}

@test "storage_check exits 0 when phase3-run check succeeds" {
    stub_phase3_run
    CHECK_EXIT=0 run bash -c "source '$ADAPTERS'; storage_check"
    [ "$status" -eq 0 ]
}

@test "storage_check exits 2 when phase3-run check fails (unmet dependency)" {
    stub_phase3_run
    CHECK_EXIT=1 run bash -c "source '$ADAPTERS'; storage_check"
    [ "$status" -eq 2 ]
}

@test "storage_plan runs phase3-run check (it already shows the plan)" {
    stub_phase3_run
    run bash -c "source '$ADAPTERS'; storage_plan"
    [ "$status" -eq 0 ]
    grep -q "phase3-run check" "$T/calls"
}

@test "storage_apply runs phase3-run apply and propagates failure" {
    stub_phase3_run
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; storage_apply"
    [ "$status" -eq 1 ]
    grep -q "phase3-run apply" "$T/calls"
}

@test "storage_verify re-runs check as the post-apply proof" {
    stub_phase3_run
    CHECK_EXIT=0 run bash -c "source '$ADAPTERS'; storage_verify"
    [ "$status" -eq 0 ]
}

stub_lab_ca() {
    cat > "$LAB_CA" <<EOF
#!/usr/bin/env bash
echo "lab-ca \$*" >> "$T/calls"
case "\$1" in
    plan)   [ -n "\${PLAN_OUTPUT:-}" ] && echo "\$PLAN_OUTPUT"; exit "\${PLAN_EXIT:-0}" ;;
    apply)  exit "\${APPLY_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
esac
EOF
    chmod +x "$LAB_CA"
}

@test "labca_check exits 0 (apply is idempotent; check never blocks)" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    run bash -c "source '$ADAPTERS'; labca_check"
    [ "$status" -eq 0 ]
}

@test "labca_plan surfaces the real plan output" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    PLAN_OUTPUT="nothing to do — CA already issued" run bash -c "source '$ADAPTERS'; labca_plan"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
}

@test "labca_apply propagates failure" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; labca_apply"
    [ "$status" -eq 1 ]
}

@test "labca_verify calls the real verify verb" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    VERIFY_EXIT=0 run bash -c "source '$ADAPTERS'; labca_verify"
    [ "$status" -eq 0 ]
    grep -q "lab-ca verify" "$T/calls"
}

stub_portal() {
    cat > "$PORTAL" <<EOF
#!/usr/bin/env bash
echo "portal \$*" >> "$T/calls"
case "\$1" in
    plan)   exit "\${PLAN_EXIT:-0}" ;;
    apply)  exit "\${APPLY_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
esac
EOF
    chmod +x "$PORTAL"
}

@test "portal_check exits 0 (apply re-applies config idempotently)" {
    export PORTAL="$T/portal.sh"; stub_portal
    run bash -c "source '$ADAPTERS'; portal_check"
    [ "$status" -eq 0 ]
}

@test "portal_plan, apply and verify call the matching real verb" {
    export PORTAL="$T/portal.sh"; stub_portal
    run bash -c "source '$ADAPTERS'; portal_plan"
    [ "$status" -eq 0 ]
    run bash -c "source '$ADAPTERS'; portal_apply"
    [ "$status" -eq 0 ]
    run bash -c "source '$ADAPTERS'; portal_verify"
    [ "$status" -eq 0 ]
    grep -q "portal plan" "$T/calls"
    grep -q "portal apply" "$T/calls"
    grep -q "portal verify" "$T/calls"
}

@test "portal_apply propagates failure" {
    export PORTAL="$T/portal.sh"; stub_portal
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; portal_apply"
    [ "$status" -eq 1 ]
}

stub_malcolm() {
    cat > "$MALCOLM_DEPLOY" <<EOF
#!/usr/bin/env bash
echo "malcolm \$1" >> "$T/calls"
if [ -n "\${FAIL_AT:-}" ] && [ "\$1" = "\$FAIL_AT" ]; then exit 1; fi
case "\$1" in
    health) exit "\${HEALTH_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
esac
exit 0
EOF
    chmod +x "$MALCOLM_DEPLOY"
}

@test "malcolm_check runs health as a read-only proxy for current state" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    run bash -c "source '$ADAPTERS'; malcolm_check"
    [ "$status" -eq 0 ]
    grep -q "malcolm health" "$T/calls"
}

@test "malcolm_apply runs every sub-verb in order on a clean run" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 0 ]
    for v in load assert-tags install configure auth bind-loopback start health; do
        grep -q "malcolm $v" "$T/calls"
    done
}

@test "malcolm_apply halts at the first sub-verb that fails and runs nothing after it" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    FAIL_AT=auth run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 1 ]
    [[ "$output" == *"auth"* ]]
    grep -q "malcolm configure" "$T/calls"
    ! grep -q "malcolm bind-loopback" "$T/calls"
    ! grep -q "malcolm start" "$T/calls"
}

@test "malcolm_verify calls the real verify verb" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    VERIFY_EXIT=0 run bash -c "source '$ADAPTERS'; malcolm_verify"
    [ "$status" -eq 0 ]
    grep -q "malcolm verify" "$T/calls"
}

stub_ufw() {
    cat > "$UFW_SCRIPT" <<EOF
#!/usr/bin/env bash
echo "ufw \$*" >> "$T/calls"
case "\$1" in
    plan)   exit "\${PLAN_EXIT:-0}" ;;
    apply)  exit "\${APPLY_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
    confirm) exit "\${CONFIRM_EXIT:-0}" ;;
esac
EOF
    chmod +x "$UFW_SCRIPT"
}

@test "ufw_check exits 0 (plan shows SKIP rows when nothing changed)" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    run bash -c "source '$ADAPTERS'; ufw_check"
    [ "$status" -eq 0 ]
}

@test "ufw_apply exits 4 on a successful arm, never calling confirm itself" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    APPLY_EXIT=0 run bash -c "source '$ADAPTERS'; ufw_apply"
    [ "$status" -eq 4 ]
    [[ "$output" == *"new"*"session"* ]] || [[ "$output" == *"confirm"* ]]
    ! grep -q "ufw confirm" "$T/calls"
}

@test "ufw_apply exits 1, not 4, when the real apply itself failed" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; ufw_apply"
    [ "$status" -eq 1 ]
}

@test "ufw_verify calls the real verify verb" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    VERIFY_EXIT=0 run bash -c "source '$ADAPTERS'; ufw_verify"
    [ "$status" -eq 0 ]
    grep -q "ufw verify" "$T/calls"
}
