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
    # Validates arguments the way the real r770-malcolm-deploy.sh does:
    # load/assert-tags/install need a bundle-dir, configure needs a config
    # path, auth/verify need --password-file. A call missing what the real
    # script requires fails here too, so a wrong adapter can't pass by
    # accident.
    cat > "$MALCOLM_DEPLOY" <<EOF
#!/usr/bin/env bash
echo "malcolm \$*" >> "$T/calls"
if [ -n "\${FAIL_AT:-}" ] && [ "\$1" = "\$FAIL_AT" ]; then exit 1; fi
case "\$1" in
    load|assert-tags|install)
        [ -n "\${2:-}" ] || { echo "usage: \$1 <bundle-dir>" >&2; exit 1; } ;;
    configure)
        [ -n "\${2:-}" ] || { echo "usage: configure <config-json>" >&2; exit 1; } ;;
    auth)
        [ -n "\${2:-}" ] && [[ " \$* " == *" --password-file "* ]] \
            || { echo "usage: auth <bundle-dir> --password-file FILE" >&2; exit 1; } ;;
    verify)
        [[ " \$* " == *" --password-file "* ]] \
            || { echo "usage: verify --password-file FILE" >&2; exit 1; } ;;
esac
exit 0
EOF
    chmod +x "$MALCOLM_DEPLOY"
}

@test "malcolm_check never blocks — it must not fail before Malcolm is even installed" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    run bash -c "source '$ADAPTERS'; malcolm_check"
    [ "$status" -eq 0 ]
}

@test "malcolm_apply refuses to run without the bundle dir, config and password-file env vars set" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 1 ]
    [ ! -f "$T/calls" ]
}

@test "malcolm_apply passes each verb the real arguments it needs, in order" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    export MALCOLM_BUNDLE_DIR="$T/bundle" MALCOLM_CONFIG_JSON="$T/config.json" MALCOLM_PASSWORD_FILE="$T/pw"
    run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 0 ]
    grep -q "malcolm load $T/bundle" "$T/calls"
    grep -q "malcolm assert-tags $T/bundle" "$T/calls"
    grep -q "malcolm install $T/bundle" "$T/calls"
    grep -q "malcolm configure $T/config.json" "$T/calls"
    grep -q "malcolm auth $T/bundle --password-file $T/pw --user analyst" "$T/calls"
    grep -q "malcolm bind-loopback" "$T/calls"
    grep -q "malcolm start" "$T/calls"
    grep -q "malcolm health" "$T/calls"
}

@test "malcolm_apply halts at the first sub-verb that fails and runs nothing after it" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    export MALCOLM_BUNDLE_DIR="$T/bundle" MALCOLM_CONFIG_JSON="$T/config.json" MALCOLM_PASSWORD_FILE="$T/pw"
    FAIL_AT=auth run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 1 ]
    [[ "$output" == *"auth"* ]]
    grep -q "malcolm configure" "$T/calls"
    ! grep -q "malcolm bind-loopback" "$T/calls"
    ! grep -q "malcolm start" "$T/calls"
}

@test "malcolm_verify requires MALCOLM_PASSWORD_FILE and calls verify with it" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    export MALCOLM_PASSWORD_FILE="$T/pw"
    run bash -c "source '$ADAPTERS'; malcolm_verify"
    [ "$status" -eq 0 ]
    grep -q "malcolm verify --password-file $T/pw --user analyst" "$T/calls"
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
