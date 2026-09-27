#!/usr/bin/env bash
#
# r770-portal.sh — install and verify the analyst portal: the portal.lab,
# malcolm.lab and docs.lab nginx vhosts, the shared analyst htpasswd, the
# static portal page, and the offline MkDocs build of the analyst wiki.
#
# Runs as root, on the target box, from a directory "site/" that holds copies
# of this repo's config/ and docs/analyst-wiki/ (the bundle's delivery path).
# The site root defaults to the script's own dir's parent; see PORTAL_SITE.
#
#   plan                   default. Read-only: current state, proposed changes
#   apply                  install snippets/vhosts/htpasswd/portal page,
#                          build docs.lab, test and reload nginx
#   verify [--host <ip>] [--cacert <file>] [--user <name>] [--password-file <file>]
#                          curl each site for 401 (no creds) and 200 (with
#                          creds); on the box (no --host) also checks that
#                          only nginx listens on :443
#
# apply refuses unless: running as root; $PORTAL_NGINX_DIR/ssl/{lab.crt,lab.key,
# ca.crt} all exist (r770-lab-ca.sh apply runs first); $PORTAL_MALCOLM_HTPASSWD
# exists (Malcolm auth runs first). It backs up $PORTAL_NGINX_DIR before
# touching it and restores that backup — without reloading — if `nginx -t`
# fails afterwards. Every install step is idempotent: a file already byte-
# identical to its source is reported "already installed", and nginx is
# reloaded only if something actually changed.
#
# Design: docs/superpowers/specs/2026-09-26-analyst-stack-design.md
#   ("scripts/r770-portal.sh")
#
#   0  done, or nothing to do
#   1  refused (REFUSE: nothing changed) or failed (FAIL: see the output for
#      what changed and how to undo it) or a check failed (FAIL, verify only)
#
# Test overrides: PORTAL_SITE (source root), PORTAL_NGINX_DIR (default
# /etc/nginx), PORTAL_WWW (default /srv/www), PORTAL_MALCOLM_HTPASSWD
# (default /opt/malcolm/malcolm/nginx/htpasswd), PORTAL_SITES (default
# "portal malcolm docs"), PORTAL_MKDOCS_IMAGE (default
# squidfunk/mkdocs-material:latest).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_SITE="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE="${PORTAL_SITE:-$DEFAULT_SITE}"
NGINX_DIR="${PORTAL_NGINX_DIR:-/etc/nginx}"
WWW="${PORTAL_WWW:-/srv/www}"
MALCOLM_HTPASSWD="${PORTAL_MALCOLM_HTPASSWD:-/opt/malcolm/malcolm/nginx/htpasswd}"
SITES="${PORTAL_SITES:-portal malcolm docs}"
MKDOCS_IMAGE="${PORTAL_MKDOCS_IMAGE:-squidfunk/mkdocs-material:latest}"

read -r -a SITES_ARR <<< "$SITES"

die()  { printf 'REFUSE  %s\n' "$*"; exit 1; }  # pre-mutation checks only
fail() { printf 'FAIL    %s\n' "$*"; exit 1; }  # a mutating command itself failed

# install_file SRC DEST [MODE] -> 0 if DEST changed, 1 if already installed
install_file() {
    local src=$1 dest=$2 mode=${3:-}
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo "already installed  $dest"
        [ -z "$mode" ] || chmod "$mode" "$dest" || fail "chmod $mode $dest failed"
        return 1
    fi
    mkdir -p "$(dirname "$dest")" || fail "mkdir $(dirname "$dest") failed"
    cp "$src" "$dest" || fail "cp $src -> $dest failed"
    [ -z "$mode" ] || chmod "$mode" "$dest" || fail "chmod $mode $dest failed"
    echo "INSTALL             $dest"
    return 0
}

plan_file() {  # plan_file SRC DEST -- read-only echo of what install_file would do
    local src=$1 dest=$2
    if [ -f "$dest" ] && cmp -s "$src" "$dest" 2>/dev/null; then
        echo "already installed  $dest"
    else
        echo "INSTALL             $dest"
    fi
}

symlink_ok() {  # symlink_ok LINK TARGET -> 0 if LINK already points at TARGET
    [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]
}

backup_nginx() {  # -> prints the backup path on stdout, or nothing on failure
    local parent base backup
    parent=$(dirname "$NGINX_DIR")
    base=$(basename "$NGINX_DIR")
    backup="$NGINX_DIR-backup-$(date +%Y%m%dT%H%M%S).tar.gz"
    tar -C "$parent" -czf "$backup" "$base" || return 1
    printf '%s\n' "$backup"
}

restore_nginx() {  # restore_nginx BACKUP
    local backup=$1 parent
    parent=$(dirname "$NGINX_DIR")
    rm -rf "$NGINX_DIR" \
        || { printf 'FAIL    could not remove %s for restore — restore it by hand: rm -rf %s; tar -C %s -xzf %s\n' \
                    "$NGINX_DIR" "$NGINX_DIR" "$parent" "$backup"; return 1; }
    tar -C "$parent" -xzf "$backup" \
        || { printf 'FAIL    restore from %s FAILED — restore it by hand now: tar -C %s -xzf %s\n' \
                    "$backup" "$parent" "$backup"; return 1; }
    printf 'RESTORE %s restored from %s\n' "$NGINX_DIR" "$backup"
}

build_docs() {  # -> 0 if $WWW/docs changed, 1 if already installed
    local tmp
    tmp=$(mktemp -d) || fail "mktemp for the docs build failed"
    mkdir -p "$tmp/docs" || fail "mkdir $tmp/docs failed"
    cp "$SITE/config/docs/mkdocs.yml" "$tmp/mkdocs.yml" || fail "copy mkdocs.yml failed"
    cp "$SITE"/docs/analyst-wiki/*.md "$tmp/docs/" || fail "copy docs/analyst-wiki failed"

    docker run --rm --network none -v "$tmp:/docs" "$MKDOCS_IMAGE" build \
        || fail "mkdocs build failed"
    [ -d "$tmp/site" ] || fail "mkdocs build produced no site/ directory in $tmp"

    if [ -d "$WWW/docs" ] && diff -rq "$tmp/site" "$WWW/docs" >/dev/null 2>&1; then
        echo "already installed  $WWW/docs"
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$WWW" || fail "mkdir $WWW failed"
    rm -rf "$WWW/docs" || fail "could not remove old $WWW/docs"
    cp -a "$tmp/site" "$WWW/docs" || fail "copy built docs to $WWW/docs failed"
    echo "INSTALL             $WWW/docs"
    rm -rf "$tmp"
    return 0
}

cmd_plan() {
    [ $# -eq 0 ] || die "plan takes no arguments"
    local refuse=0 f site

    echo "== portal plan =="
    echo "site root:        $SITE"
    echo "nginx dir:        $NGINX_DIR"
    echo "www root:         $WWW"
    echo "malcolm htpasswd: $MALCOLM_HTPASSWD"
    echo "sites:            $SITES"
    echo "mkdocs image:     $MKDOCS_IMAGE"
    echo

    if [ "$(id -u)" = 0 ]; then
        echo "PASS    running as root"
    else
        echo "WARN    not running as root — apply will refuse"
    fi

    for f in "$NGINX_DIR/ssl/lab.crt" "$NGINX_DIR/ssl/lab.key" "$NGINX_DIR/ssl/ca.crt"; do
        if [ -f "$f" ]; then
            echo "PASS    $f present"
        else
            echo "REFUSE  $f missing — apply will refuse until r770-lab-ca.sh apply has run"
            refuse=1
        fi
    done

    if [ -f "$MALCOLM_HTPASSWD" ]; then
        echo "PASS    $MALCOLM_HTPASSWD present"
    else
        echo "REFUSE  $MALCOLM_HTPASSWD missing — apply will refuse until Malcolm auth has run"
        refuse=1
    fi

    echo
    echo "-- would install --"
    for f in "$SITE"/config/nginx/snippets/*; do
        [ -e "$f" ] || continue
        plan_file "$f" "$NGINX_DIR/snippets/$(basename "$f")"
    done
    for site in "${SITES_ARR[@]}"; do
        plan_file "$SITE/config/nginx/$site.lab.conf" "$NGINX_DIR/sites-available/$site.lab.conf"
        if symlink_ok "$NGINX_DIR/sites-enabled/$site.lab.conf" "../sites-available/$site.lab.conf"; then
            echo "already installed  $NGINX_DIR/sites-enabled/$site.lab.conf"
        else
            echo "INSTALL             $NGINX_DIR/sites-enabled/$site.lab.conf (symlink)"
        fi
    done
    plan_file "$MALCOLM_HTPASSWD" "$NGINX_DIR/lab.htpasswd"
    plan_file "$SITE/config/portal/index.html" "$WWW/portal/index.html"
    echo "BUILD               $WWW/docs  (docker run --rm --network none -v <tmp>:/docs $MKDOCS_IMAGE build)"

    return "$refuse"
}

cmd_apply() {
    [ $# -eq 0 ] || die "apply takes no arguments"
    [ "$(id -u)" = 0 ] || die "must run as root"

    local f missing=""
    for f in "$NGINX_DIR/ssl/lab.crt" "$NGINX_DIR/ssl/lab.key" "$NGINX_DIR/ssl/ca.crt"; do
        [ -f "$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] || die "missing CA-issued file(s):$missing — run r770-lab-ca.sh apply first"
    [ -f "$MALCOLM_HTPASSWD" ] || die "missing $MALCOLM_HTPASSWD — run Malcolm's auth step first"

    local backup
    backup=$(backup_nginx) || fail "backup of $NGINX_DIR failed"
    echo "BACKUP  $backup"

    local changed=0
    mkdir -p "$NGINX_DIR/snippets" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" \
        || fail "could not create $NGINX_DIR subdirectories"

    for f in "$SITE"/config/nginx/snippets/*; do
        [ -e "$f" ] || continue
        if install_file "$f" "$NGINX_DIR/snippets/$(basename "$f")"; then changed=1; fi
    done

    local site
    for site in "${SITES_ARR[@]}"; do
        f="$SITE/config/nginx/$site.lab.conf"
        [ -f "$f" ] || die "missing vhost source $f"
        if install_file "$f" "$NGINX_DIR/sites-available/$site.lab.conf"; then changed=1; fi
        if symlink_ok "$NGINX_DIR/sites-enabled/$site.lab.conf" "../sites-available/$site.lab.conf"; then
            echo "already installed  $NGINX_DIR/sites-enabled/$site.lab.conf"
        else
            ln -sf "../sites-available/$site.lab.conf" "$NGINX_DIR/sites-enabled/$site.lab.conf" \
                || fail "symlink for $site.lab failed"
            echo "INSTALL             $NGINX_DIR/sites-enabled/$site.lab.conf"
            changed=1
        fi
    done

    if install_file "$MALCOLM_HTPASSWD" "$NGINX_DIR/lab.htpasswd" 0640; then changed=1; fi
    chgrp www-data "$NGINX_DIR/lab.htpasswd" || fail "chgrp www-data $NGINX_DIR/lab.htpasswd failed"

    mkdir -p "$WWW/portal" || fail "mkdir $WWW/portal failed"
    if install_file "$SITE/config/portal/index.html" "$WWW/portal/index.html"; then changed=1; fi

    if build_docs; then changed=1; fi

    local test_out
    if ! test_out=$(nginx -t 2>&1); then
        echo "FAIL    nginx -t failed:"
        printf '%s\n' "$test_out" | sed 's/^/        /'
        restore_nginx "$backup"
        exit 1
    fi
    echo "PASS    nginx -t"

    if [ "$changed" = 1 ]; then
        systemctl reload nginx || fail "systemctl reload nginx failed"
        echo "DONE    nginx reloaded"
    else
        echo "DONE    no changes — nginx not reloaded"
    fi
}

# check_listeners -> PASS/FAIL: only nginx listens on 0.0.0.0:443 or [::]:443
check_listeners() {
    local out line addr bad=0
    out=$(ss -H -ltnp 2>&1) || { echo "FAIL    ss -ltnp failed: $out"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        addr=$(awk '{print $4}' <<< "$line")
        case "$addr" in
            0.0.0.0:443|'[::]:443')
                if ! grep -q '"nginx"' <<< "$line"; then
                    echo "FAIL    $addr is listening but not owned by nginx: $line"
                    bad=1
                fi
                ;;
        esac
    done <<< "$out"
    if [ "$bad" -eq 0 ]; then
        echo "PASS    only nginx listens on :443"
        return 0
    fi
    return 1
}

cmd_verify() {
    local host=127.0.0.1 host_given=0 cacert="$NGINX_DIR/ssl/ca.crt" user="" password_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --host)           host=${2:-}; host_given=1; shift 2 ;;
            --cacert)         cacert=${2:-}; shift 2 ;;
            --user)           user=${2:-}; shift 2 ;;
            --password-file)  password_file=${2:-}; shift 2 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    local have_creds=0
    if [ -n "$user" ] || [ -n "$password_file" ]; then
        { [ -n "$user" ] && [ -n "$password_file" ]; } \
            || die "--user and --password-file must be given together"
        [ -f "$password_file" ] || die "password file not found: $password_file"
        have_creds=1
    fi
    [ -f "$cacert" ] || die "CA cert not found: $cacert"

    local password=""
    [ "$have_creds" -eq 1 ] && password=$(cat "$password_file")

    local site code overall=0
    for site in "${SITES_ARR[@]}"; do
        code=$(curl -s -o /dev/null -w '%{http_code}' \
                    --resolve "$site.lab:443:$host" --cacert "$cacert" "https://$site.lab/")
        if [ "$code" = 401 ]; then
            echo "PASS    $site.lab -> 401 without credentials"
        else
            echo "FAIL    $site.lab -> $code without credentials (want 401)"
            overall=1
        fi

        if [ "$have_creds" -eq 1 ]; then
            code=$(printf 'user = "%s:%s"\n' "$user" "$password" \
                    | curl -s -o /dev/null -w '%{http_code}' -K - \
                          --resolve "$site.lab:443:$host" --cacert "$cacert" "https://$site.lab/")
            if [ "$code" = 200 ]; then
                echo "PASS    $site.lab -> 200 with credentials"
            else
                echo "FAIL    $site.lab -> $code with credentials (want 200)"
                overall=1
            fi
        else
            echo "WARN    $site.lab -> no credentials given, skipping the 200 check"
        fi
    done

    if [ "$host_given" -eq 0 ]; then
        check_listeners || overall=1
    fi

    return "$overall"
}

VERB="${1:-plan}"
[ $# -eq 0 ] || shift
case "$VERB" in
    plan)   cmd_plan "$@" ;;
    apply)  cmd_apply "$@" ;;
    verify) cmd_verify "$@" ;;
    *)      die "unknown verb: $VERB (expected plan, apply or verify)" ;;
esac
