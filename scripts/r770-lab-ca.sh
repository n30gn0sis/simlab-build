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
#   apply --reissue-cert   also rebuild the cert (old cert/key/req moved
#                           aside, timestamped) — the CA is still kept.
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
CERT_CRT="$PKI_DIR/issued/lab.crt"
CERT_KEY="$PKI_DIR/private/lab.key"
CERT_REQ="$PKI_DIR/reqs/lab.req"

die() { echo "r770-lab-ca: $*" >&2; exit 1; }

build_san() {
    local n out=""
    for n in $LABCA_NAMES; do
        out="${out:+$out,}DNS:$n"
    done
    printf '%s' "$out"
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
    local ts f
    ts=$(date +%Y%m%dT%H%M%S)
    echo "REISSUE cert lab — moving previous cert/key/req aside (timestamp $ts)"
    for f in "$CERT_CRT" "$CERT_KEY" "$CERT_REQ"; do
        [ -e "$f" ] || continue
        mv -f "$f" "${f}.pre-reissue-${ts}" || die "could not move aside $f"
    done
    issue_cert
}

install_file() {  # install_file SRC DEST MODE
    local src=$1 dest=$2 mode=$3
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo "SKIP    $dest already installed"
        return 0
    fi
    install -m "$mode" "$src" "$dest" || die "could not install $dest"
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

    mkdir -p "$LABCA_SSL_DIR" || die "could not create $LABCA_SSL_DIR"
    install_file "$CERT_CRT" "$LABCA_SSL_DIR/lab.crt" 0644
    install_file "$CERT_KEY" "$LABCA_SSL_DIR/lab.key" 0600
    install_file "$CA_CRT"   "$LABCA_SSL_DIR/ca.crt"  0644
}

cmd_verify() {
    local crt="$LABCA_SSL_DIR/lab.crt" key="$LABCA_SSL_DIR/lab.key" ca="$LABCA_SSL_DIR/ca.crt"
    local ok=0 name san_out mode

    if openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1; then
        echo "PASS    chain verifies ($crt against $ca)"
    else
        echo "FAIL    chain does not verify ($crt against $ca)"
        ok=1
    fi

    san_out=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true)
    for name in $LABCA_NAMES; do
        if grep -qF "DNS:$name" <<< "$san_out"; then
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
