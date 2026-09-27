#!/usr/bin/env bash
#
# r770-portal.sh — install and verify the analyst portal: the portal.lab,
# malcolm.lab and docs.lab nginx vhosts, a :443 catch-all that rejects any
# other name, the shared analyst htpasswd, the static portal page, and the
# offline MkDocs build of the analyst wiki.
#
# Runs as root, on the target box, from a directory "site/" that holds copies
# of this repo's config/ and docs/analyst-wiki/ (the bundle's delivery path).
# The site root defaults to the script's own dir's parent; see PORTAL_SITE.
#
#   plan                   default. Read-only: current state, proposed changes
#   apply                  build docs.lab and install the portal page (outside
#                          nginx), then install conf.d/snippets/vhosts/htpasswd
#                          under nginx, test and reload nginx
#   verify [--host <ip>] [--cacert <file>] [--user <name>] [--password-file <file>]
#                          curl each site for 401 (no creds) and 200 (with
#                          creds); on the box (no --host) also checks that
#                          only nginx listens on :443
#
# apply refuses, changing nothing, unless: running as root; $PORTAL_NGINX_DIR/
# ssl/{lab.crt,lab.key,ca.crt} all exist (r770-lab-ca.sh apply runs first);
# $PORTAL_MALCOLM_HTPASSWD exists (Malcolm auth runs first); every source file
# exists; the mkdocs image is known and loaded.
#
# Then, in this order:
#   1. docs.lab and the portal page, under $PORTAL_WWW. The docs are rebuilt
#      only when the source stamp (sha256 over mkdocs.yml, the analyst-wiki
#      *.md and the mkdocs image ID) differs from the one kept beside the last
#      build, and replaced by a directory swap. Nothing under nginx is touched
#      yet, so a failed build leaves nginx exactly as it was, with no backup.
#   2. nginx. The change set is computed first; if it is empty, no backup is
#      taken. Otherwise $PORTAL_NGINX_DIR is backed up (a 0600 tarball in the
#      0700 $PORTAL_BACKUP_DIR — it holds ssl/lab.key), and ANY failure from
#      there until `nginx -t` has passed restores that backup and does not
#      reload.
#   3. nginx is reloaded only if its config changed. If nothing changed but
#      nginx is not running, apply says so and exits 1.
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
# "portal malcolm docs"), PORTAL_BACKUP_DIR (default /var/backups/r770-portal),
# PORTAL_WWW_GROUP (default www-data), PORTAL_MKDOCS_IMAGE (default: the
# mkdocs-material entry of the bundle's docker/monitoring-image-list.txt,
# which the fetch script's pin block owns — see OWNERS.md).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_SITE="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE="${PORTAL_SITE:-$DEFAULT_SITE}"
NGINX_DIR="${PORTAL_NGINX_DIR:-/etc/nginx}"
WWW="${PORTAL_WWW:-/srv/www}"
MALCOLM_HTPASSWD="${PORTAL_MALCOLM_HTPASSWD:-/opt/malcolm/malcolm/nginx/htpasswd}"
SITES="${PORTAL_SITES:-portal malcolm docs}"
BACKUP_DIR="${PORTAL_BACKUP_DIR:-/var/backups/r770-portal}"
WWW_GROUP="${PORTAL_WWW_GROUP:-www-data}"
# site/ sits at the bundle root, beside docker/monitoring-image-list.txt.
IMAGE_LIST="$SITE/../docker/monitoring-image-list.txt"
DEFAULT_VHOST="00-default-reject.conf"
DOCS_STAMP=".r770-source.sha256"

read -r -a SITES_ARR <<< "$SITES"
VHOSTS=("$DEFAULT_VHOST")
for _s in "${SITES_ARR[@]}"; do VHOSTS+=("$_s.lab.conf"); done
unset _s

# Set by cmd_apply once the nginx backup exists, cleared once `nginx -t` has
# passed. While set, every exit restores the backup (see on_exit).
RESTORE_FROM=""
TMP_BUILD=""

die() {  # pre-mutation checks only
    if [ -n "$RESTORE_FROM" ]; then printf 'FAIL    %s\n' "$*"; else printf 'REFUSE  %s\n' "$*"; fi
    exit 1
}
fail() { printf 'FAIL    %s\n' "$*"; exit 1; }  # a mutating command itself failed

on_exit() {
    local rc=$?
    # A second Ctrl-C must not cut a restore short between rm -rf and untar;
    # ignored signals are inherited by the tar child as well.
    trap '' INT TERM HUP
    [ -z "$TMP_BUILD" ] || rm -rf "$TMP_BUILD"
    if [ -n "$RESTORE_FROM" ]; then
        local backup=$RESTORE_FROM
        RESTORE_FROM=""
        [ "$rc" -ne 0 ] || rc=1
        if restore_nginx "$backup"; then
            echo "FAIL    apply stopped part-way; $NGINX_DIR is back to its state before this run (backup $backup). nginx was NOT reloaded."
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

# ── the mkdocs image ─────────────────────────────────────────────────────────

# resolve_mkdocs_image -> prints the image, or nothing. Never restates a tag:
# the fetch script's pin block owns it and writes it to the bundle's list.
resolve_mkdocs_image() {
    if [ -n "${PORTAL_MKDOCS_IMAGE:-}" ]; then
        printf '%s\n' "$PORTAL_MKDOCS_IMAGE"
        return
    fi
    [ -f "$IMAGE_LIST" ] || return 0
    grep -m1 '/mkdocs-material:' "$IMAGE_LIST" || true
}
MKDOCS_IMAGE="$(resolve_mkdocs_image)"

image_id() { docker image inspect --format '{{.Id}}' "$MKDOCS_IMAGE" 2>/dev/null; }

# docs_source_hash IMAGE_ID -> sha256 over mkdocs.yml, the wiki pages (name
# and content, byte-sorted by name) and the image ID. mkdocs output itself is
# not reproducible (sitemap lastmod, gzip timestamps), so it is never compared.
docs_source_hash() {
    local id=$1
    (
        cd "$SITE" || exit 1
        sha256sum config/docs/mkdocs.yml || exit 1
        printf '%s\n' docs/analyst-wiki/*.md | LC_ALL=C sort | while IFS= read -r f; do
            sha256sum "$f" || exit 1
        done || exit 1
        printf 'image %s\n' "$id"
    ) | sha256sum | awk '{print $1}'
}

docs_current() {  # docs_current HASH -> 0 if $WWW/docs was built from HASH
    [ -d "$WWW/docs" ] && [ "$(cat "$WWW/docs/$DOCS_STAMP" 2>/dev/null)" = "$1" ]
}

# ── nginx items ──────────────────────────────────────────────────────────────

# nginx_items -> one "kind|source|dest" per line, everything apply owns under
# nginx: conf.d (http-level), snippets, the vhosts, their symlinks, htpasswd.
nginx_items() {
    local f v
    for f in "$SITE"/config/nginx/conf.d/*; do
        [ -e "$f" ] && echo "file|$f|$NGINX_DIR/conf.d/$(basename "$f")"
    done
    for f in "$SITE"/config/nginx/snippets/*; do
        [ -e "$f" ] && echo "file|$f|$NGINX_DIR/snippets/$(basename "$f")"
    done
    for v in "${VHOSTS[@]}"; do
        echo "file|$SITE/config/nginx/$v|$NGINX_DIR/sites-available/$v"
        echo "link|../sites-available/$v|$NGINX_DIR/sites-enabled/$v"
    done
    echo "htpasswd|$MALCOLM_HTPASSWD|$NGINX_DIR/lab.htpasswd"
}

item_current() {  # item_current KIND SRC DEST -> 0 if DEST already matches
    local kind=$1 src=$2 dest=$3
    case "$kind" in
        file)     [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" ;;
        link)     [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ] ;;
        htpasswd) [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" \
                      && [ "$(stat -c '%a %G' "$dest")" = "640 $WWW_GROUP" ] ;;
        *)        return 1 ;;
    esac
}

item_install() {  # item_install KIND SRC DEST -- fails (FAIL) on any error
    local kind=$1 src=$2 dest=$3
    mkdir -p "$(dirname "$dest")" || fail "mkdir $(dirname "$dest") failed"
    case "$kind" in
        file)     { rm -f "$dest" && cp "$src" "$dest"; } || fail "cp $src -> $dest failed" ;;
        link)     ln -sfn "$src" "$dest" || fail "symlink $dest -> $src failed" ;;
        # one step, so the file never exists with a wider mode or group
        htpasswd) install -m0640 -o root -g "$WWW_GROUP" "$src" "$dest" \
                      || fail "install -m0640 -o root -g $WWW_GROUP $src $dest failed" ;;
    esac
    echo "INSTALL             $dest"
}

backup_nginx() {  # -> prints the backup path on stdout, or nothing on failure
    local backup
    { mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"; } || return 1
    # mktemp: unique name, created 0600 before tar writes a byte into it
    backup=$(mktemp --suffix=.tar.gz "$BACKUP_DIR/nginx-$(date +%Y%m%dT%H%M%S)-XXXXXX") || return 1
    if ! ( umask 077 && tar -C "$(dirname "$NGINX_DIR")" -czf "$backup" "$(basename "$NGINX_DIR")" ); then
        rm -f "$backup"
        return 1
    fi
    chmod 600 "$backup" || return 1
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

# ── outside nginx: portal page and docs ─────────────────────────────────────

install_portal_page() {  # -> 0 if changed, 1 if already installed
    local src="$SITE/config/portal/index.html" dest="$WWW/portal/index.html"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo "already installed  $dest"
        return 1
    fi
    mkdir -p "$WWW/portal" || fail "mkdir $WWW/portal failed"
    cp "$src" "$dest" || fail "cp $src -> $dest failed"
    echo "INSTALL             $dest"
    return 0
}

build_docs() {  # build_docs HASH -> 0 if $WWW/docs changed, 1 if already installed
    local hash=$1
    if docs_current "$hash"; then
        echo "already installed  $WWW/docs"
        return 1
    fi
    TMP_BUILD=$(mktemp -d) || fail "mktemp for the docs build failed"
    mkdir -p "$TMP_BUILD/docs" || fail "mkdir $TMP_BUILD/docs failed"
    cp "$SITE/config/docs/mkdocs.yml" "$TMP_BUILD/mkdocs.yml" || fail "copy mkdocs.yml failed"
    cp "$SITE"/docs/analyst-wiki/*.md "$TMP_BUILD/docs/" || fail "copy docs/analyst-wiki failed"

    docker run --rm --pull never --network none -v "$TMP_BUILD:/docs" "$MKDOCS_IMAGE" build \
        || fail "mkdocs build failed — nothing under $WWW/docs or $NGINX_DIR changed"
    [ -d "$TMP_BUILD/site" ] || fail "mkdocs build produced no site/ directory — nothing under $WWW/docs or $NGINX_DIR changed"

    # build beside the live tree, then swap by rename
    mkdir -p "$WWW" || fail "mkdir $WWW failed"
    rm -rf "$WWW/docs.new" "$WWW/docs.old" || fail "could not clear a stale $WWW/docs.new or docs.old"
    cp -a "$TMP_BUILD/site" "$WWW/docs.new" || fail "copy built docs to $WWW/docs.new failed"
    printf '%s\n' "$hash" > "$WWW/docs.new/$DOCS_STAMP" || fail "write $WWW/docs.new/$DOCS_STAMP failed"
    if [ -d "$WWW/docs" ]; then
        mv "$WWW/docs" "$WWW/docs.old" || fail "mv $WWW/docs -> $WWW/docs.old failed"
    fi
    mv "$WWW/docs.new" "$WWW/docs" \
        || fail "mv $WWW/docs.new -> $WWW/docs failed — the previous build is at $WWW/docs.old"
    rm -rf "$WWW/docs.old" || echo "WARN    could not remove $WWW/docs.old — remove it by hand"
    echo "INSTALL             $WWW/docs"
    return 0
}

# ── verbs ────────────────────────────────────────────────────────────────────

# preflight REPORT -> 0 if apply may proceed. Prints a REFUSE line for every
# unmet precondition; with REPORT=1 (plan) also a PASS line for each met one.
# Read-only.
preflight() {
    local report=$1 bad=0 f kind src dest
    check() {  # check RC PASS-MESSAGE REFUSE-MESSAGE
        if [ "$1" = 0 ]; then
            [ "$report" = 0 ] || echo "PASS    $2"
        else
            echo "REFUSE  $3"
            bad=1
        fi
    }
    for f in "$NGINX_DIR/ssl/lab.crt" "$NGINX_DIR/ssl/lab.key" "$NGINX_DIR/ssl/ca.crt"; do
        [ -f "$f" ]; check $? "$f present" "$f missing — run r770-lab-ca.sh apply first"
    done
    [ -f "$MALCOLM_HTPASSWD" ]
    check $? "$MALCOLM_HTPASSWD present" "$MALCOLM_HTPASSWD missing — run Malcolm's auth step first"
    while IFS='|' read -r kind src dest; do
        [ "$kind" = link ] || [ -f "$src" ] || check 1 "" "missing source $src"
    done < <(nginx_items)
    for f in "$SITE/config/portal/index.html" "$SITE/config/docs/mkdocs.yml"; do
        [ -f "$f" ] || check 1 "" "missing source $f"
    done
    compgen -G "$SITE/docs/analyst-wiki/*.md" >/dev/null \
        || check 1 "" "missing source $SITE/docs/analyst-wiki/*.md"
    [ -n "$MKDOCS_IMAGE" ]
    check $? "mkdocs image $MKDOCS_IMAGE" \
        "mkdocs image unknown — $IMAGE_LIST is missing or names no mkdocs-material image; set PORTAL_MKDOCS_IMAGE"
    if [ -n "$MKDOCS_IMAGE" ]; then
        image_id >/dev/null
        check $? "mkdocs image loaded" \
            "mkdocs image $MKDOCS_IMAGE is not loaded — load the bundle's monitoring images first (runbook Part 5)"
    fi
    return "$bad"
}

cmd_plan() {
    [ $# -eq 0 ] || die "plan takes no arguments"
    local refuse=0 kind src dest id

    echo "== portal plan =="
    echo "site root:        $SITE"
    echo "nginx dir:        $NGINX_DIR"
    echo "www root:         $WWW"
    echo "backup dir:       $BACKUP_DIR"
    echo "malcolm htpasswd: $MALCOLM_HTPASSWD"
    echo "sites:            $SITES"
    echo "mkdocs image:     ${MKDOCS_IMAGE:-(unknown)}"
    echo

    if [ "$(id -u)" = 0 ]; then
        echo "PASS    running as root"
    else
        echo "WARN    not running as root — apply will refuse"
    fi
    preflight 1 || refuse=1

    echo
    echo "-- would install --"
    if [ -f "$SITE/config/portal/index.html" ] && [ -f "$WWW/portal/index.html" ] \
            && cmp -s "$SITE/config/portal/index.html" "$WWW/portal/index.html"; then
        echo "already installed  $WWW/portal/index.html"
    else
        echo "INSTALL             $WWW/portal/index.html"
    fi
    if [ -n "$MKDOCS_IMAGE" ] && id=$(image_id) && docs_current "$(docs_source_hash "$id")"; then
        echo "already installed  $WWW/docs  (source stamp matches)"
    else
        echo "BUILD               $WWW/docs  (docker run --rm --pull never --network none -v <tmp>:/docs ${MKDOCS_IMAGE:-<image>} build)"
    fi
    while IFS='|' read -r kind src dest; do
        if item_current "$kind" "$src" "$dest"; then
            echo "already installed  $dest"
        else
            echo "INSTALL             $dest"
        fi
    done < <(nginx_items)

    return "$refuse"
}

cmd_apply() {
    [ $# -eq 0 ] || die "apply takes no arguments"
    [ "$(id -u)" = 0 ] || die "must run as root"
    preflight 0 || exit 1

    # 1. outside nginx — a failure here leaves nginx untouched and unbacked-up
    local id hash
    id=$(image_id) || die "mkdocs image $MKDOCS_IMAGE not loaded"
    hash=$(docs_source_hash "$id") || die "could not hash the docs sources"
    [ -n "$hash" ] || die "could not hash the docs sources"
    install_portal_page || true
    build_docs "$hash" || true

    # 2. nginx — change set first; back up only if something will change
    local kind src dest pending=()
    while IFS='|' read -r kind src dest; do
        if item_current "$kind" "$src" "$dest"; then
            echo "already installed  $dest"
        else
            pending+=("$kind|$src|$dest")
        fi
    done < <(nginx_items)

    local backup item
    if [ "${#pending[@]}" -gt 0 ]; then
        backup=$(backup_nginx) || fail "backup of $NGINX_DIR failed — nothing under $NGINX_DIR changed"
        echo "BACKUP  $backup"
        RESTORE_FROM=$backup
        for item in "${pending[@]}"; do
            IFS='|' read -r kind src dest <<< "$item"
            item_install "$kind" "$src" "$dest"
        done
    fi

    local test_out
    if ! test_out=$(nginx -t 2>&1); then
        echo "FAIL    nginx -t failed:"
        printf '%s\n' "$test_out" | sed 's/^/        /'
        [ -n "$RESTORE_FROM" ] || echo "FAIL    apply changed nothing under $NGINX_DIR — the existing config already fails nginx -t"
        exit 1  # on_exit restores the backup, if one was taken
    fi
    echo "PASS    nginx -t"
    RESTORE_FROM=""

    if [ "${#pending[@]}" -gt 0 ]; then
        systemctl reload nginx \
            || fail "systemctl reload nginx failed — the new config is installed and passes nginx -t; is nginx running? (systemctl status nginx; start it with: systemctl start nginx)"
        echo "DONE    nginx reloaded"
    elif ! systemctl is-active --quiet nginx; then
        fail "no nginx config changes, but nginx is not active — the config passes nginx -t; start it with: systemctl start nginx"
    else
        echo "DONE    no nginx config changes — nginx not reloaded"
    fi
}

# check_listeners -> PASS/FAIL: only nginx listens on a wildcard :443
check_listeners() {
    local out line addr bad=0
    out=$(ss -H -ltnp 2>&1) || { echo "FAIL    ss -ltnp failed: $out"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        addr=$(awk '{print $4}' <<< "$line")
        case "$addr" in
            0.0.0.0:443|'[::]:443'|'*:443')
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

VERIFY_USAGE="usage: r770-portal.sh verify [--host <ip>] [--cacert <file>] [--user <name> --password-file <file>]"

# curl_quote STRING -> STRING escaped for a double-quoted curl config value
curl_quote() {
    local s=${1//\\/\\\\}
    printf '%s' "${s//\"/\\\"}"
}

cmd_verify() {
    local host=127.0.0.1 host_given=0 cacert="$NGINX_DIR/ssl/ca.crt" user="" password_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --host|--cacert|--user|--password-file)
                { [ $# -ge 2 ] && [ -n "$2" ]; } || die "$1 needs a value — $VERIFY_USAGE" ;;
        esac
        case "$1" in
            --host)           host=$2; host_given=1; shift 2 ;;
            --cacert)         cacert=$2; shift 2 ;;
            --user)           user=$2; shift 2 ;;
            --password-file)  password_file=$2; shift 2 ;;
            *) die "unknown argument: $1 — $VERIFY_USAGE" ;;
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

    local password="" creds_line=""
    if [ "$have_creds" -eq 1 ]; then
        password=$(cat "$password_file") || die "could not read the password file $password_file"
        [ -n "$password" ] || die "the password file $password_file is empty"
        case "$user$password" in
            *$'\n'*|*$'\r'*) die "the user or password contains a line break — the password file must hold one line" ;;
        esac
        creds_line=$(printf 'user = "%s:%s"' "$(curl_quote "$user")" "$(curl_quote "$password")")
    fi

    local site code overall=0
    local curl_args=(-s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 30)
    for site in "${SITES_ARR[@]}"; do
        code=$(curl "${curl_args[@]}" \
                    --resolve "$site.lab:443:$host" --cacert "$cacert" "https://$site.lab/")
        if [ "$code" = 401 ]; then
            echo "PASS    $site.lab -> 401 without credentials"
        else
            echo "FAIL    $site.lab -> $code without credentials (want 401)"
            overall=1
        fi

        if [ "$have_creds" -eq 1 ]; then
            code=$(printf '%s\n' "$creds_line" \
                    | curl "${curl_args[@]}" -K - \
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
