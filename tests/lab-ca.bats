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
#   $S/ca_build_counter       bumped on every build-ca, so ca.crt content is
#                             unique per build (lets tests assert "unchanged")
#   $S/fail_build_once        if present, the NEXT build-server-full fails and
#                             the flag is consumed (models a post-revoke failure)
#   $S/openssl_verify_rc      exit code for `openssl verify`         (default 0)
#   $S/openssl_checkend_rc    exit code for `openssl x509 -checkend` (default 0)
#   $S/openssl_san            stdout for `openssl x509 -ext subjectAltName`
#   $S/openssl_pubkey_crt     stdout for `openssl x509 -noout -pubkey`
#   $S/openssl_pubkey_key     stdout for `openssl pkey -pubout`

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
    for t in bash env cat sed awk grep tr cp mv mkdir chmod rm date stat cmp install find; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    stub id 'echo "$FAKE_UID"'

    # openssl: verify / -ext subjectAltName / -checkend / -pubkey / pkey
    # -pubout, all answered from knobs. Defaults make everything PASS.
    printf 'X509v3 Subject Alternative Name:\n    DNS:portal.lab, DNS:malcolm.lab, DNS:docs.lab, DNS:gns3.lab, DNS:monitoring.lab\n' > "$S/openssl_san"
    echo "PUBKEY-MATCH" > "$S/openssl_pubkey_crt"
    echo "PUBKEY-MATCH" > "$S/openssl_pubkey_key"
    stub openssl '
        case "$1" in
            verify)
                rc="$(cat "$S/openssl_verify_rc" 2>/dev/null || echo 0)"
                exit "$rc" ;;
            x509)
                shift
                ext=0; checkend=0; pubkey=0
                for a; do
                    case "$a" in
                        -ext) ext=1 ;;
                        -checkend) checkend=1 ;;
                        -pubkey) pubkey=1 ;;
                    esac
                done
                if [ "$pubkey" -eq 1 ]; then
                    cat "$S/openssl_pubkey_crt"; exit 0
                elif [ "$ext" -eq 1 ]; then
                    cat "$S/openssl_san"; exit 0
                elif [ "$checkend" -eq 1 ]; then
                    rc="$(cat "$S/openssl_checkend_rc" 2>/dev/null || echo 0)"
                    exit "$rc"
                fi
                exit 1 ;;
            pkey)
                cat "$S/openssl_pubkey_key"; exit 0 ;;
            *) exit 1 ;;
        esac'

    # easyrsa stub: logs full argv, then fabricates the pki files a real
    # easy-rsa 3.1.7 init-pki/build-ca/build-server-full/revoke run would
    # leave -- including an index.txt, so a revoke-then-reissue can be told
    # apart from a plain reissue, and a unique ca.crt per build-ca, so "the
    # CA is unchanged" is an assertion that can actually fail.
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
        # Real easy-rsa in batch mode wipes an existing pki/ silently -- the
        # very hazard Important 1 guards against, so the stub must model it.
        rm -rf "$pki"
        mkdir -p "$pki/private" "$pki/issued" "$pki/reqs"
        : > "$pki/index.txt"
        ;;
    *"revoke lab"*)
        if [ -f "$pki/index.txt" ]; then
            awk 'BEGIN{FS=OFS="\t"} $1=="V" && index($0,"CN=lab")>0 {$1="R"; $3="20260101000000Z"} {print}' \
                "$pki/index.txt" > "$pki/index.txt.new" && mv "$pki/index.txt.new" "$pki/index.txt"
        fi
        rm -f "$pki/issued/lab.crt"
        ;;
    *"build-server-full"*)
        if [ -f "$S/fail_build_once" ]; then
            rm -f "$S/fail_build_once"
            echo "stub-easyrsa: forced build-server-full failure" >&2
            exit 7
        fi
        mkdir -p "$pki/issued" "$pki/private" "$pki/reqs"
        echo "fake lab cert" > "$pki/issued/lab.crt"
        echo "fake lab key"  > "$pki/private/lab.key"
        echo "fake lab req"  > "$pki/reqs/lab.req"
        printf 'V\t99991231235959Z\t\t%s\tunknown\t/CN=lab\n' "$$" >> "$pki/index.txt"
        ;;
    *"build-ca"*)
        mkdir -p "$pki/private"
        n=$(( $(cat "$S/ca_build_counter" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$S/ca_build_counter"
        echo "fake ca cert #$n" > "$pki/ca.crt"
        echo "fake ca key #$n"  > "$pki/private/ca.key"
        ;;
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

snapshot() { find "$LABCA_DIR" "$LABCA_SSL_DIR" -type f -exec sha256sum {} + 2>/dev/null | sort; }

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

# ── Important 1: a partial or lost PKI must never be silently regenerated ──

@test "plan refuses when the PKI exists but ca.crt is missing" {
    mkdir -p "$LABCA_DIR/pki/private" "$LABCA_DIR/pki/issued" "$LABCA_DIR/pki/reqs"
    echo "orphan ca key" > "$LABCA_DIR/pki/private/ca.key"
    run run_ca plan
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"incomplete"* ]]
    [[ "$output" == *"Restore the PKI from backup"* ]]
    no_easyrsa_calls
}

@test "plan refuses when the PKI exists but private/ca.key is missing" {
    mkdir -p "$LABCA_DIR/pki/private" "$LABCA_DIR/pki/issued" "$LABCA_DIR/pki/reqs"
    echo "orphan ca cert" > "$LABCA_DIR/pki/ca.crt"
    run run_ca plan
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"incomplete"* ]]
    [[ "$output" == *"Restore the PKI from backup"* ]]
    no_easyrsa_calls
}

@test "plan refuses when a CA is installed but the PKI is gone" {
    mkdir -p "$LABCA_SSL_DIR"
    echo "installed ca, no source" > "$LABCA_SSL_DIR/ca.crt"
    run run_ca plan
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no PKI at"* ]]
    [[ "$output" == *"already installed"* ]]
    [[ "$output" == *"move $LABCA_SSL_DIR/ca.crt aside deliberately"* ]]
    no_easyrsa_calls
}

@test "apply refuses when the PKI exists but is incomplete, and changes nothing" {
    mkdir -p "$LABCA_DIR/pki/private" "$LABCA_DIR/pki/issued" "$LABCA_DIR/pki/reqs"
    echo "orphan ca key" > "$LABCA_DIR/pki/private/ca.key"
    chmod 0751 "$LABCA_DIR"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"incomplete"* ]]
    no_easyrsa_calls
    [ "$(stat -c '%a' "$LABCA_DIR")" = "751" ]
    [ ! -e "$LABCA_SSL_DIR" ]
}

@test "apply refuses when a CA is installed but the PKI is gone, and changes nothing" {
    mkdir -p "$LABCA_SSL_DIR"
    echo "installed ca, no source" > "$LABCA_SSL_DIR/ca.crt"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already installed"* ]]
    no_easyrsa_calls
    [ ! -e "$LABCA_DIR" ]
    [ "$(cat "$LABCA_SSL_DIR/ca.crt")" = "installed ca, no source" ]
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

@test "apply leaves no temp files behind in the ssl dir (atomic install)" {
    run_ca apply
    run find "$LABCA_SSL_DIR" -maxdepth 1 -name '.*.tmp.*'
    [ -z "$output" ]
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

@test "install_file re-applies the mode even when the content is unchanged" {
    run_ca apply
    chmod 644 "$LABCA_SSL_DIR/lab.key"
    : > "$S/easyrsa_calls"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lab.key already installed"* ]]
    [ "$(stat -c '%a' "$LABCA_SSL_DIR/lab.key")" = "600" ]
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
    [ "$(grep -c 'init-pki' "$S/easyrsa_calls")" -eq 0 ]
    [ "$(grep -c 'build-ca' "$S/easyrsa_calls")" -eq 0 ]
    [ "$(grep -c 'build-server-full' "$S/easyrsa_calls")" -eq 1 ]
    [ -f "$LABCA_SSL_DIR/lab.crt" ]
}

@test "apply refuses to install a mismatched cert/key pair" {
    run_ca apply
    rm -f "$LABCA_DIR/pki/private/lab.key"
    : > "$S/easyrsa_calls"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mismatched pair"* ]]
    no_easyrsa_calls
}

# ── --reissue-cert (revoke, then build-server-full — proven on real easy-rsa 3.1.7) ──

@test "--reissue-cert revokes the previous cert, issues a new one, and keeps the CA" {
    run_ca apply
    old_ca_crt="$(cat "$LABCA_DIR/pki/ca.crt")"
    old_ca_key="$(cat "$LABCA_DIR/pki/private/ca.key")"
    : > "$S/easyrsa_calls"
    run run_ca apply --reissue-cert
    echo "$output"; cat "$S/easyrsa_calls"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA already exists — kept"* ]]
    [[ "$output" == *"REISSUE cert lab"* ]]

    [ "$(grep -c 'init-pki' "$S/easyrsa_calls")" -eq 0 ]
    [ "$(grep -c 'build-ca' "$S/easyrsa_calls")" -eq 0 ]
    [ "$(grep -c 'revoke lab' "$S/easyrsa_calls")" -eq 1 ]
    [ "$(grep -c 'build-server-full' "$S/easyrsa_calls")" -eq 1 ]

    revoke_line=$(grep -n 'revoke lab' "$S/easyrsa_calls" | cut -d: -f1)
    build_line=$(grep -n 'build-server-full' "$S/easyrsa_calls" | cut -d: -f1)
    [ "$revoke_line" -lt "$build_line" ]

    # the CA is byte-for-byte unchanged (unique per-build content in the stub)
    [ "$(cat "$LABCA_DIR/pki/ca.crt")" = "$old_ca_crt" ]
    [ "$(cat "$LABCA_DIR/pki/private/ca.key")" = "$old_ca_key" ]

    # index.txt ends with the revoked original (R) then the fresh issue (V)
    last_two="$(tail -n2 "$LABCA_DIR/pki/index.txt" | cut -f1)"
    [ "$(sed -n '1p' <<< "$last_two")" = "R" ]
    [ "$(sed -n '2p' <<< "$last_two")" = "V" ]

    [ -f "$LABCA_DIR/pki/issued/lab.crt" ]
    ! ls "$LABCA_DIR"/pki/issued/lab.crt.pre-reissue-* >/dev/null 2>&1
}

@test "--reissue-cert dies clearly if the build fails after revoke, and the next apply just issues a fresh cert" {
    run_ca apply
    old_ca_crt="$(cat "$LABCA_DIR/pki/ca.crt")"
    : > "$S/fail_build_once"
    run run_ca apply --reissue-cert
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"revok"* ]]
    [[ "$output" == *"easyrsa build-server-full failed"* ]]
    [[ "$output" == *"next apply"* ]]
    [ ! -f "$LABCA_DIR/pki/issued/lab.crt" ]
    [ "$(cat "$LABCA_DIR/pki/ca.crt")" = "$old_ca_crt" ]

    : > "$S/easyrsa_calls"
    run run_ca apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA already exists — kept"* ]]
    [[ "$output" == *"ISSUE   cert lab"* ]]
    [ "$(grep -c 'init-pki' "$S/easyrsa_calls")" -eq 0 ]
    [ "$(grep -c 'build-ca' "$S/easyrsa_calls")" -eq 0 ]
    [ -f "$LABCA_DIR/pki/issued/lab.crt" ]
}

@test "apply --reissue-cert with no existing cert just issues one" {
    run run_ca apply --reissue-cert
    [ "$status" -eq 0 ]
    [[ "$output" == *"ISSUE   cert lab"* ]]
    [[ "$output" != *"REISSUE"* ]]
    [ "$(grep -c 'revoke lab' "$S/easyrsa_calls")" -eq 0 ]
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
    [ "$(grep -c '^PASS' <<< "$output")" -eq 10 ]
    [ "$(grep -c '^FAIL' <<< "$output")" -eq 0 ]
}

@test "verify changes nothing" {
    run_ca apply
    before="$(snapshot)"
    run run_ca verify
    after="$(snapshot)"
    [ "$before" = "$after" ]
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

@test "verify fails when a SAN entry is a longer name, not an exact token match" {
    run_ca apply
    printf 'X509v3 Subject Alternative Name:\n    DNS:portal.labx, DNS:malcolm.lab, DNS:docs.lab, DNS:gns3.lab, DNS:monitoring.lab\n' > "$S/openssl_san"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    SAN missing DNS:portal.lab"* ]]
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

@test "verify fails when the installed key does not match the cert's public key" {
    run_ca apply
    echo "DIFFERENT-PUBKEY" > "$S/openssl_pubkey_key"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"public key mismatch"* ]]
}

@test "verify fails when the installed ca.crt does not match the CA's pki/ca.crt" {
    run_ca apply
    echo "tampered ca" > "$LABCA_SSL_DIR/ca.crt"
    run run_ca verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match $LABCA_DIR/pki/ca.crt"* ]]
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

@test "export-ca changes nothing" {
    run_ca apply
    before="$(snapshot)"
    run run_ca export-ca
    after="$(snapshot)"
    [ "$before" = "$after" ]
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
