#!/usr/bin/env bats
#
# r770-lab-ca.sh manages the internal CA and one server cert, so what matters
# most here is that it NEVER regenerates an existing CA, and that a
# --reissue-cert rebuilds the cert alone. id, openssl and easyrsa are all
# stubs backed by a state directory ($S); the script sees ONLY the stubs plus
# a fixed list of real read-only-ish tools, so a real easy-rsa or openssl on
# the test host can never answer for it.
#
#   $S/easyrsa_calls          every easyrsa invocation, one per line (full argv)
#   $S/openssl_verify_rc      exit code for `openssl verify`        (default 0)
#   $S/openssl_checkend_rc    exit code for `openssl x509 -checkend` (default 0)
#   $S/openssl_san            stdout for `openssl x509 -ext subjectAltName`

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-lab-ca.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export LABCA_DIR="$BATS_TEST_TMPDIR/ca"
    export LABCA_SSL_DIR="$BATS_TEST_TMPDIR/ssl"
    export LABCA_EASYRSA="$BIN/easyrsa-real"
    export LABCA_NAMES="portal.lab malcolm.lab docs.lab gns3.lab monitoring.lab"
    export LABCA_MIN_DAYS=30
    export FAKE_UID=0
    mkdir -p "$BIN" "$REAL" "$S"

    # A fixed list of real, read-only-ish tools. `install`/`mkdir`/`chmod`/`mv`
    # never need real root here because they only touch paths this test user
    # owns under $BATS_TEST_TMPDIR, and none of them chown.
    for t in bash env cat sed awk grep tr cp mv mkdir chmod rm date stat cmp install; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    stub id 'echo "$FAKE_UID"'

    # openssl: verify / -ext subjectAltName / -checkend, all answered from knobs.
    printf 'X509v3 Subject Alternative Name:\n    DNS:portal.lab, DNS:malcolm.lab, DNS:docs.lab, DNS:gns3.lab, DNS:monitoring.lab\n' > "$S/openssl_san"
    stub openssl '
        case "$1" in
            verify)
                rc="$(cat "$S/openssl_verify_rc" 2>/dev/null || echo 0)"
                exit "$rc" ;;
            x509)
                shift
                ext=0; checkend=0
                for a; do
                    case "$a" in
                        -ext) ext=1 ;;
                        -checkend) checkend=1 ;;
                    esac
                done
                if [ "$ext" -eq 1 ]; then
                    cat "$S/openssl_san"; exit 0
                elif [ "$checkend" -eq 1 ]; then
                    rc="$(cat "$S/openssl_checkend_rc" 2>/dev/null || echo 0)"
                    exit "$rc"
                fi
                exit 1 ;;
            *) exit 1 ;;
        esac'

    # easyrsa stub: logs full argv, then fabricates the pki files a real
    # easy-rsa 3.1.7 init-pki/build-ca/build-server-full run would leave.
    cat > "$LABCA_EASYRSA" <<'EASYRSA'
#!/usr/bin/env bash
printf 'BATCH=%s CN=%s -- %s\n' "${EASYRSA_BATCH:-}" "${EASYRSA_REQ_CN:-}" "$*" >> "$S/easyrsa_calls"
pki=""
for a in "$@"; do
    case "$a" in
        --pki-dir=*) pki="${a#--pki-dir=}" ;;
    esac
done
[ -n "$pki" ] || { echo "stub-easyrsa: no --pki-dir given" >&2; exit 9; }
case "$*" in
    *"init-pki"*)
        mkdir -p "$pki/private" "$pki/issued" "$pki/reqs" ;;
    *"build-server-full"*)
        mkdir -p "$pki/issued" "$pki/private" "$pki/reqs"
        echo "fake lab cert" > "$pki/issued/lab.crt"
        echo "fake lab key"  > "$pki/private/lab.key"
        echo "fake lab req"  > "$pki/reqs/lab.req" ;;
    *"build-ca"*)
        mkdir -p "$pki/private"
        echo "fake ca cert" > "$pki/ca.crt"
        echo "fake ca key"  > "$pki/private/ca.key" ;;
    *)
        echo "stub-easyrsa: unknown command: $*" >&2
        exit 9 ;;
esac
EASYRSA
    chmod +x "$LABCA_EASYRSA"
}

stub() {  # stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

run_ca() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

no_easyrsa_calls() { [ ! -s "$S/easyrsa_calls" ] || { cat "$S/easyrsa_calls"; false; }; }

# ── refusals common to every verb ───────────────────────────────────────────

@test "refuses to run as a non-root user" {
    FAKE_UID=1000 run run_ca plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"must run as root"* ]]
}

@test "refuses an unknown verb" {
    run run_ca frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown verb: frobnicate"* ]]
    no_easyrsa_calls
}

# ── plan ─────────────────────────────────────────────────────────────────────

@test "plan on an empty state proposes CA create, cert issue and both installs, changes nothing" {
    run run_ca plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CREATE  CA in $LABCA_DIR"* ]]
    [[ "$output" == *"ISSUE   cert lab"* ]]
    [[ "$output" == *"INSTALL $LABCA_SSL_DIR/lab.crt"* ]]
    [[ "$output" == *"INSTALL $LABCA_SSL_DIR/lab.key"* ]]
    [[ "$output" == *"INSTALL $LABCA_SSL_DIR/ca.crt"* ]]
    no_easyrsa_calls
    [ ! -e "$LABCA_DIR" ]
    [ ! -e "$LABCA_SSL_DIR" ]
}

@test "no arguments means plan" {
    run run_ca
    [ "$status" -eq 0 ]
    [[ "$output" == *"== r770-lab-ca plan =="* ]]
    no_easyrsa_calls
}

@test "plan refuses an unexpected extra argument" {
    run run_ca plan --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument: --bogus"* ]]
}

# ── first apply ──────────────────────────────────────────────────────────────

@test "first apply creates the CA and cert, installs with the right modes" {
    run run_ca apply
    echo "$output"; cat "$S/easyrsa_calls"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CREATE  CA in $LABCA_DIR"* ]]
    [[ "$output" == *"ISSUE   cert lab"* ]]
    [ "$(grep -c 'init-pki' "$S/easyrsa_calls")" -eq 1 ]
    [ "$(grep -c 'build-ca' "$S/easyrsa_calls")" -eq 1 ]
    [ "$(grep -c 'build-server-full' "$S/easyrsa_calls")" -eq 1 ]

    [ -f "$LABCA_DIR/pki/ca.crt" ]
    [ -f "$LABCA_DIR/pki/issued/lab.crt" ]
    [ -f "$LABCA_DIR/pki/private/lab.key" ]
    [ "$(stat -c '%a' "$LABCA_DIR")" = "700" ]

    [ -f "$LABCA_SSL_DIR/lab.crt" ]; [ "$(stat -c '%a' "$LABCA_SSL_DIR/lab.crt")" = "644" ]
    [ -f "$LABCA_SSL_DIR/lab.key" ]; [ "$(stat -c '%a' "$LABCA_SSL_DIR/lab.key")" = "600" ]
    [ -f "$LABCA_SSL_DIR/ca.crt" ];  [ "$(stat -c '%a' "$LABCA_SSL_DIR/ca.crt")" = "644" ]
    cmp -s "$LABCA_DIR/pki/issued/lab.crt" "$LABCA_SSL_DIR/lab.crt"
    cmp -s "$LABCA_DIR/pki/private/lab.key" "$LABCA_SSL_DIR/lab.key"
    cmp -s "$LABCA_DIR/pki/ca.crt" "$LABCA_SSL_DIR/ca.crt"
}

@test "the build-server-full invocation carries all five SAN names" {
    run run_ca apply
    [ "$status" -eq 0 ]
    line=$(grep 'build-server-full' "$S/easyrsa_calls")
    echo "$line"
    for n in portal.lab malcolm.lab docs.lab gns3.lab monitoring.lab; do
        [[ "$line" == *"DNS:$n"* ]]
    done
    [[ "$line" == *"--pki-dir=$LABCA_DIR/pki"* ]]
}

@test "the CA is built with EASYRSA_BATCH=1 and EASYRSA_REQ_CN \"R770 Lab CA\"" {
    run run_ca apply
    [ "$status" -eq 0 ]
    line=$(grep 'init-pki' "$S/easyrsa_calls")
    [[ "$line" == "BATCH=1 CN=R770 Lab CA -- "* ]]
    line=$(grep 'build-ca nopass' "$S/easyrsa_calls")
    [[ "$line" == "BATCH=1 CN=R770 Lab CA -- "* ]]
}

# ── idempotency ──────────────────────────────────────────────────────────────

@test "a second apply is a no-op and the CA is never rebuilt" {
    run_ca apply
    : > "$S/easyrsa_calls"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA already exists — kept"* ]]
    [[ "$output" == *"cert already issued — kept"* ]]
    [[ "$output" == *"lab.crt already installed"* ]]
    [[ "$output" == *"lab.key already installed"* ]]
    [[ "$output" == *"ca.crt already installed"* ]]
    no_easyrsa_calls
}

@test "an existing CA is kept even when the cert is missing" {
    run_ca apply
    rm -f "$LABCA_DIR/pki/issued/lab.crt" "$LABCA_SSL_DIR/lab.crt"
    : > "$S/easyrsa_calls"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA already exists — kept"* ]]
    [[ "$output" == *"ISSUE   cert lab"* ]]
    ! grep -q 'init-pki' "$S/easyrsa_calls"
    ! grep -q 'build-ca' "$S/easyrsa_calls"
    grep -q 'build-server-full' "$S/easyrsa_calls"
    [ -f "$LABCA_SSL_DIR/lab.crt" ]
}

# ── --reissue-cert ───────────────────────────────────────────────────────────

@test "--reissue-cert rebuilds only the cert and keeps the CA" {
    run_ca apply
    old_ca_crt="$(cat "$LABCA_DIR/pki/ca.crt")"
    : > "$S/easyrsa_calls"
    run run_ca apply --reissue-cert
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA already exists — kept"* ]]
    [[ "$output" == *"REISSUE cert lab"* ]]
    ! grep -q 'init-pki' "$S/easyrsa_calls"
    ! grep -q 'build-ca' "$S/easyrsa_calls"
    [ "$(grep -c 'build-server-full' "$S/easyrsa_calls")" -eq 1 ]
    [ "$(cat "$LABCA_DIR/pki/ca.crt")" = "$old_ca_crt" ]
    ls "$LABCA_DIR"/pki/issued/lab.crt.pre-reissue-* >/dev/null
    ls "$LABCA_DIR"/pki/private/lab.key.pre-reissue-* >/dev/null
    ls "$LABCA_DIR"/pki/reqs/lab.req.pre-reissue-* >/dev/null
}

@test "apply --reissue-cert with no existing cert just issues one" {
    run run_ca apply --reissue-cert
    [ "$status" -eq 0 ]
    [[ "$output" == *"ISSUE   cert lab"* ]]
    [[ "$output" != *"REISSUE"* ]]
}

@test "apply refuses an unknown flag" {
    run run_ca apply --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument to apply: --bogus"* ]]
    no_easyrsa_calls
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify passes every check against a freshly applied cert" {
    run_ca apply
    run run_ca verify
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^PASS' <<< "$output")" -ge 7 ]
    [ "$(grep -c '^FAIL' <<< "$output")" -eq 0 ]
}

@test "verify fails on a missing SAN" {
    run_ca apply
    printf 'X509v3 Subject Alternative Name:\n    DNS:portal.lab, DNS:malcolm.lab\n' > "$S/openssl_san"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    SAN missing DNS:docs.lab"* ]]
    [[ "$output" == *"FAIL    SAN missing DNS:gns3.lab"* ]]
    [[ "$output" == *"FAIL    SAN missing DNS:monitoring.lab"* ]]
    [[ "$output" == *"PASS    SAN has DNS:portal.lab"* ]]
}

@test "verify fails on expiry" {
    run_ca apply
    echo 1 > "$S/openssl_checkend_rc"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    cert expires within 30 days"* ]]
}

@test "verify fails on a bad chain" {
    run_ca apply
    echo 1 > "$S/openssl_verify_rc"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    chain does not verify"* ]]
}

@test "verify fails on a wrongly-permissioned key" {
    run_ca apply
    chmod 644 "$LABCA_SSL_DIR/lab.key"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    $LABCA_SSL_DIR/lab.key is mode 644, expected 600"* ]]
}

@test "verify refuses an unexpected extra argument" {
    run run_ca verify --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument: --bogus"* ]]
}

# ── export-ca ────────────────────────────────────────────────────────────────

@test "export-ca prints the installed CA certificate" {
    run_ca apply
    run run_ca export-ca
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$LABCA_SSL_DIR/ca.crt")" ]
}

@test "export-ca refuses when no CA is installed" {
    run run_ca export-ca
    [ "$status" -eq 1 ]
    [[ "$output" == *"no CA installed"* ]]
}

@test "export-ca refuses an unexpected extra argument" {
    run_ca apply
    run run_ca export-ca --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument: --bogus"* ]]
}
