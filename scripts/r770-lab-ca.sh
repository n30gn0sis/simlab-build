#!/usr/bin/env bash
#
# r770-lab-ca.sh — internal easy-rsa CA for the analyst stack's TLS.
#
# Runs ON the target box, as root. Owns one CA and one five-name server
# certificate (CN=lab), installed where config/nginx/snippets/lab-tls.conf
# expects them. Never regenerates an existing CA: a new CA silently
# invalidates every client that trusted the old one (the 2026-09-16 lesson).
# A certificate reissue only ever happens via the explicit --reissue-cert.
#
#   plan                   default. Read-only: CA create/keep, cert
#                           issue/keep, install/skip. Changes nothing.
#   apply                  create the CA if absent (never touch an existing
#                           one), issue the cert if absent, install into
#                           LABCA_SSL_DIR.
#   apply --reissue-cert   also rebuild the cert: easyrsa revokes the old
#                           one, then build-server-full issues a new one
#                           (index.txt: R then V) — the CA is still kept.
#   verify                 chain, SANs, expiry and key mode; PASS/FAIL per
#                           check.
#   export-ca              print the installed CA certificate to stdout.
#
#   0  done, or nothing to do
#   1  refused (nothing changed) or a verify check FAILed
#
# Design: docs/superpowers/specs/2026-09-26-analyst-stack-design.md
#   ("scripts/r770-lab-ca.sh").
#
# Env overrides (tests):
#   LABCA_DIR        CA working dir + pki root      (default /etc/r770-ca)
#   LABCA_SSL_DIR     nginx TLS install dir          (default /etc/nginx/ssl)
#   LABCA_EASYRSA     path to the easyrsa script     (default /usr/share/easy-rsa/easyrsa)
#   LABCA_NAMES       space-separated SAN names      (default "portal.lab malcolm.lab docs.lab gns3.lab monitoring.lab")
#   LABCA_MIN_DAYS    verify's expiry floor, in days (default 30)
#
# "root-owned" for the installed files is achieved by requiring root to run
# this script at all (files a root process creates are root-owned); this
# script does not chown, so it never needs a privilege it might not have.
set -uo pipefail

LABCA_DIR="${LABCA_DIR:-/etc/r770-ca}"
LABCA_SSL_DIR="${LABCA_SSL_DIR:-/etc/nginx/ssl}"
LABCA_EASYRSA="${LABCA_EASYRSA:-/usr/share/easy-rsa/easyrsa}"
LABCA_NAMES="${LABCA_NAMES:-portal.lab malcolm.lab docs.lab gns3.lab monitoring.lab}"
LABCA_MIN_DAYS="${LABCA_MIN_DAYS:-30}"

PKI_DIR="$LABCA_DIR/pki"
CA_CRT="$PKI_DIR/ca.crt"
CA_KEY="$PKI_DIR/private/ca.key"
CERT_CRT="$PKI_DIR/issued/lab.crt"
CERT_KEY="$PKI_DIR/private/lab.key"

die() { echo "r770-lab-ca: $*" >&2; exit 1; }

build_san() {
    local n out=""
    for n in $LABCA_NAMES; do
        out="${out:+$out,}DNS:$n"
    done
    printf '%s' "$out"
}

# match_san SAN_TEXT NAME -- whole-token match against an
# `openssl x509 -ext subjectAltName` dump, so "DNS:portal.labx" never
# satisfies a check for "portal.lab" (a plain substring grep would).
match_san() {
    local out="$1" name="$2" tok
    for tok in $(tr ',' ' ' <<< "$out"); do
        [ "$tok" = "DNS:$name" ] && return 0
    done
    return 1
}

# pki_problem -- prints a non-empty message and returns success when the PKI
# is in a state apply must never touch, silence (and failure) when it's sane.
# A partial pki/ (from an interrupted run, a bad restore, or a lost disk) is
# NOT "no CA yet": easyrsa init-pki in batch mode wipes pki/ unconditionally,
# so treating it as absent would silently mint a new CA no client trusts.
# Likewise, an installed ca.crt with no pki/ behind it must never be
# "helpfully" replaced by a fresh one.
pki_problem() {
    if [ -d "$PKI_DIR" ]; then
        if [ ! -f "$CA_CRT" ] || [ ! -f "$CA_KEY" ]; then
            echo "PKI at $PKI_DIR exists but is incomplete (missing ca.crt or private/ca.key) -- refusing to touch it. Restore the PKI from backup, or move $PKI_DIR aside deliberately if a new CA is truly intended."
        fi
    elif [ -f "$LABCA_SSL_DIR/ca.crt" ]; then
        echo "no PKI at $PKI_DIR, but a CA is already installed at $LABCA_SSL_DIR/ca.crt. Clients trust that CA. Restore the PKI from backup, or move $LABCA_SSL_DIR/ca.crt aside deliberately if a new CA is truly intended."
    fi
}

# The invocation form design.md fixes: options before the command, run from
# inside LABCA_DIR, EASYRSA_BATCH=1 always exported.
easyrsa_init_and_ca() {
    (
        cd "$LABCA_DIR" || exit 1
        EASYRSA_BATCH=1 EASYRSA_REQ_CN="R770 Lab CA" "$LABCA_EASYRSA" --pki-dir="$PKI_DIR" init-pki &&
        EASYRSA_BATCH=1 EASYRSA_REQ_CN="R770 Lab CA" "$LABCA_EASYRSA" --pki-dir="$PKI_DIR" build-ca nopass
    )
}

easyrsa_issue() {  # easyrsa_issue SAN
    (
        cd "$LABCA_DIR" || exit 1
        EASYRSA_BATCH=1 "$LABCA_EASYRSA" --pki-dir="$PKI_DIR" --subject-alt-name="$1" build-server-full lab nopass
    )
}

easyrsa_revoke() {
    (
        cd "$LABCA_DIR" || exit 1
        EASYRSA_BATCH=1 "$LABCA_EASYRSA" --pki-dir="$PKI_DIR" revoke lab
    )
}

create_ca() {
    echo "CREATE  CA in $LABCA_DIR (CN=\"R770 Lab CA\")"
    easyrsa_init_and_ca || die "easyrsa CA creation failed (init-pki/build-ca)"
    [ -f "$CA_CRT" ] || die "easyrsa reported success but $CA_CRT is missing"
}

issue_cert() {
    local san; san=$(build_san)
    echo "ISSUE   cert lab (SANs: $LABCA_NAMES)"
    easyrsa_issue "$san" || die "easyrsa build-server-full failed"
    [ -f "$CERT_CRT" ] || die "easyrsa reported success but $CERT_CRT is missing"
}

reissue_cert() {
    # Real easy-rsa 3.1.7 (confirmed on VM 9771): moving the old cert/key/req
    # aside leaves index.txt with two "V" entries for the same cert -- the
    # old one is never revoked. `revoke lab` then `build-server-full lab
    # nopass` is the clean sequence: index.txt ends R (revoked) then V
    # (freshly issued). If the build fails after the revoke, die loudly; the
    # CA is untouched either way, and CERT_CRT is gone, so the next plain
    # `apply` sees no cert and issues a fresh one -- no special recovery path
    # needed.
    local san; san=$(build_san)
    echo "REISSUE cert lab — revoking the previous cert, then issuing a new one"
    easyrsa_revoke || die "easyrsa revoke failed for cert lab -- the CA and the previous cert are unchanged"
    echo "ISSUE   cert lab (SANs: $LABCA_NAMES)"
    easyrsa_issue "$san" || die "easyrsa build-server-full failed after revoking the previous cert lab -- the CA is unaffected; the next apply will see no cert and issue a fresh one"
    [ -f "$CERT_CRT" ] || die "easyrsa reported success but $CERT_CRT is missing"
}

install_file() {  # install_file SRC DEST MODE
    local src=$1 dest=$2 mode=$3 tmp
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        # Content already matches, but mode may have drifted (e.g. a key
        # left at 0644) -- re-apply it every time, not only on first install.
        chmod "$mode" "$dest" || die "could not chmod $dest"
        echo "SKIP    $dest already installed"
        return 0
    fi
    tmp="$(dirname "$dest")/.$(basename "$dest").tmp.$$"
    install -m "$mode" "$src" "$tmp" || die "could not stage $dest"
    mv -f "$tmp" "$dest" || die "could not install $dest"
    echo "INSTALL $dest (mode $mode)"
}

plan_install() {  # plan_install SRC DEST MODE
    local src=$1 dest=$2 mode=$3
    if [ -f "$src" ] && [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo "SKIP    $dest already installed"
    else
        echo "INSTALL $dest (mode $mode)"
    fi
}

cmd_plan() {
    echo "== r770-lab-ca plan =="
    local problem; problem=$(pki_problem)
    if [ -n "$problem" ]; then
        echo "REFUSE  $problem"
        echo "== plan only — no changes made =="
        return 1
    fi
    if [ -f "$CA_CRT" ]; then
        echo "KEEP    CA exists in $LABCA_DIR — never regenerated"
    else
        echo "CREATE  CA in $LABCA_DIR (init-pki, build-ca nopass, CN=\"R770 Lab CA\")"
    fi
    if [ -f "$CERT_CRT" ]; then
        echo "KEEP    cert lab already issued (use --reissue-cert to rebuild it)"
    else
        echo "ISSUE   cert lab (SANs: $(build_san))"
    fi
    plan_install "$CERT_CRT" "$LABCA_SSL_DIR/lab.crt" 0644
    plan_install "$CERT_KEY" "$LABCA_SSL_DIR/lab.key" 0600
    plan_install "$CA_CRT"   "$LABCA_SSL_DIR/ca.crt"  0644
    echo "== plan only — no changes made =="
}

cmd_apply() {
    local reissue=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --reissue-cert) reissue=1 ;;
            *) die "unknown argument to apply: $1" ;;
        esac
        shift
    done

    local problem; problem=$(pki_problem)
    [ -z "$problem" ] || die "$problem"

    mkdir -p "$LABCA_DIR"   || die "could not create $LABCA_DIR"
    chmod 0700 "$LABCA_DIR" || die "could not chmod 0700 $LABCA_DIR"

    if [ -f "$CA_CRT" ]; then
        echo "CA already exists — kept"
    else
        create_ca
    fi

    if [ "$reissue" -eq 1 ] && [ -f "$CERT_CRT" ]; then
        reissue_cert
    elif [ -f "$CERT_CRT" ]; then
        echo "cert already issued — kept"
    else
        issue_cert
    fi

    # Never install half a pair: a lab.crt with no matching lab.key (or vice
    # versa) is worse than not installing at all.
    if [ ! -f "$CERT_CRT" ] || [ ! -f "$CERT_KEY" ]; then
        die "cert lab is incomplete (missing $CERT_CRT or $CERT_KEY) -- refusing to install a mismatched pair"
    fi

    mkdir -p "$LABCA_SSL_DIR" || die "could not create $LABCA_SSL_DIR"
    install_file "$CERT_CRT" "$LABCA_SSL_DIR/lab.crt" 0644
    install_file "$CERT_KEY" "$LABCA_SSL_DIR/lab.key" 0600
    install_file "$CA_CRT"   "$LABCA_SSL_DIR/ca.crt"  0644
}

cmd_verify() {
    local crt="$LABCA_SSL_DIR/lab.crt" key="$LABCA_SSL_DIR/lab.key" ca="$LABCA_SSL_DIR/ca.crt"
    local ok=0 name san_out mode pub_crt pub_key

    if openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1; then
        echo "PASS    chain verifies ($crt against $ca)"
    else
        echo "FAIL    chain does not verify ($crt against $ca)"
        ok=1
    fi

    san_out=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true)
    for name in $LABCA_NAMES; do
        if match_san "$san_out" "$name"; then
            echo "PASS    SAN has DNS:$name"
        else
            echo "FAIL    SAN missing DNS:$name"
            ok=1
        fi
    done

    if openssl x509 -in "$crt" -noout -checkend "$((LABCA_MIN_DAYS * 86400))" >/dev/null 2>&1; then
        echo "PASS    cert valid for at least $LABCA_MIN_DAYS more days"
    else
        echo "FAIL    cert expires within $LABCA_MIN_DAYS days"
        ok=1
    fi

    mode=$(stat -c '%a' "$key" 2>/dev/null || echo "")
    if [ "$mode" = "600" ]; then
        echo "PASS    $key is mode 600"
    else
        echo "FAIL    $key is mode ${mode:-missing}, expected 600"
        ok=1
    fi

    pub_crt=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)
    pub_key=$(openssl pkey -in "$key" -pubout 2>/dev/null)
    if [ -n "$pub_crt" ] && [ "$pub_crt" = "$pub_key" ]; then
        echo "PASS    $key's public key matches $crt"
    else
        echo "FAIL    $key does not match $crt (public key mismatch)"
        ok=1
    fi

    if [ -f "$CA_CRT" ] && cmp -s "$CA_CRT" "$ca"; then
        echo "PASS    installed $ca matches $CA_CRT"
    else
        echo "FAIL    installed $ca does not match $CA_CRT (or it is missing)"
        ok=1
    fi

    return "$ok"
}

cmd_export_ca() {
    local ca="$LABCA_SSL_DIR/ca.crt"
    [ -f "$ca" ] || die "no CA installed at $ca — run apply first"
    cat "$ca"
}

VERB="${1:-plan}"
[ $# -eq 0 ] || shift

[ "$(id -u)" = 0 ] || die "must run as root"

case "$VERB" in
    plan)      [ $# -eq 0 ] || die "unknown argument: $1"; cmd_plan ;;
    verify)    [ $# -eq 0 ] || die "unknown argument: $1"; cmd_verify ;;
    export-ca) [ $# -eq 0 ] || die "unknown argument: $1"; cmd_export_ca ;;
    apply)     cmd_apply "$@" ;;
    *)         die "unknown verb: $VERB (expected plan, apply, verify, export-ca)" ;;
esac
