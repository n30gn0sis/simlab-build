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
