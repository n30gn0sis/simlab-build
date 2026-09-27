#!/usr/bin/env bash
#
# r770-malcolm-deploy.sh — load Malcolm's images from a bundle and prove the
# load was COMPLETE, then install, configure, authenticate, rebind, start and
# verify Malcolm. Runs with no network, which is the condition it must
# satisfy on the real air-gapped R770.
#
#   load <bundle-dir>          docker load the tarball, then assert every tag
#   assert-tags <bundle-dir>   the tag check alone
#   install <bundle-dir>       unzip the bundle's Malcolm installer into MALCOLM_ROOT
#   configure <config-json>    Malcolm's install.py --non-interactive --configure,
#                              importing <config-json>
#   auth <bundle-dir> --password-file FILE [--user NAME] [--force]
#                              Malcolm's auth_setup, unattended, fed HASHES only.
#                              --force re-runs EVERY --auth-generate-* flag: on an
#                              initialized stack that regenerates the internal
#                              postgres/netbox/valkey/opensearch/keycloak
#                              credentials too. It is not a password-change path.
#   bind-loopback              nginx-proxy 0.0.0.0:443:443[/tcp] -> 127.0.0.1:8443:443[/tcp]
#   start                      Malcolm's own ./scripts/start --quiet (refused before bind-loopback)
#   health [--timeout SECS]    every service running+healthy; only 127.0.0.1:8443 published
#   verify --password-file FILE [--user NAME]
#                              loopback PCAP -> Malcolm's upload dir (read from the
#                              upload: service's bind mount in docker-compose.yml);
#                              Arkime sessions, Zeek logs, zeek container healthy
#
# `docker load` reports success even when the resulting tag set is incomplete,
# which is why import-bundle.md step 3b requires verifying loaded tags against
# the bundle's own image-list files.
#
# The analyst password is read from a root-owned, mode 600 or 400, non-symlink
# file into a shell variable and only ever leaves it on a pipe (stdin of
# openssl, htpasswd-in-docker, curl -K -). It is never in argv, the environment,
# a log, or the output. Its HASHES do go to auth_setup in argv -- Malcolm's only
# unattended interface -- so the MD5-crypt hash is briefly visible to local
# users in the process list while auth_setup runs (htpasswd gets bcrypt).
#
#   0  done, already done, or every check PASSed
#   1  refused (REFUSE: nothing changed), or failed (FAIL: see the output)
#
# Design: docs/superpowers/specs/2026-09-26-analyst-stack-design.md
#         (§ scripts/r770-malcolm-deploy.sh); command shapes from
#         docs/plans/r770-install-runbook.md Part 8.
#
# Test overrides:
#   MALCOLM_ROOT            install root (default /opt/malcolm)
#   MALCOLM_COMPOSE         compose command (default "docker compose")
#   MALCOLM_START           start command, run in $MALCOLM_ROOT/malcolm (default "./scripts/start --quiet")
#   MALCOLM_POLL_SECS       health/verify poll interval (default 10)
#   MALCOLM_TMPDIR          where verify writes its capture (default /tmp)
#   VERIFY_TIMEOUT          verify's wait for Arkime/Zeek (default 300)
#   VERIFY_CAPTURE_SECS     length of the loopback capture (default 20)
set -euo pipefail

MALCOLM_ROOT="${MALCOLM_ROOT:-/opt/malcolm}"
MD="$MALCOLM_ROOT/malcolm"
COMPOSE_FILE="$MD/docker-compose.yml"
STAMP_DIR="$MALCOLM_ROOT/.r770-deploy"
POLL_SECS="${MALCOLM_POLL_SECS:-10}"
# Malcolm 26.08's compose file (line 1459) has `    - 0.0.0.0:443:443`, no /tcp;
# both spellings are accepted and the suffix is kept.
OPEN_RE='^    - 0\.0\.0\.0:443:443(/tcp)?$'
LOOP_RE='^    - 127\.0\.0\.1:8443:443(/tcp)?$'
PORTAL_URL='https://127.0.0.1:8443'
VERIFY_TMP=""
VERIFY_PID=""
# Malcolm's upload service: the container path its PHP uploader writes to.
UPLOAD_TARGET='/var/www/upload/server/php/chroot/files'

die()    { echo "r770-malcolm-deploy: $*" >&2; exit 1; }
refuse() { die "REFUSE  $*"; }   # pre-mutation checks only
fail()   { die "FAIL    $*"; }   # a mutating or checking command failed

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

require_root() {
    local uid
    uid=$(id -u) || refuse "cannot determine uid"
    [ "$uid" = 0 ] || refuse "must run as root (Malcolm's installer, auth_setup and start all need it)"
}

compose_cmd() {  # the compose command as an array, in COMPOSE
    read -r -a COMPOSE <<< "${MALCOLM_COMPOSE:-docker compose}"
    [ "${#COMPOSE[@]}" -gt 0 ] || refuse "MALCOLM_COMPOSE is empty"
}

require_compose_file() {
    [ -f "$COMPOSE_FILE" ] || refuse "not installed/configured: no $COMPOSE_FILE"
}

# install.py location: Malcolm 26.08's docker_install zip has install.py (with
# installer/, malcolm_*.py and malcolm_<ts>.tar.gz) at its TOP level, no
# scripts/ dir. scripts/install.py (the runbook's path) is only a fallback.
find_installer() {
    local c
    for c in "$MALCOLM_ROOT/install.py" "$MALCOLM_ROOT/scripts/install.py"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

sha_of() { sha256sum < "$1" | awk '{print $1}'; }

have_env_files() { compgen -G "$MD/config/*.env" > /dev/null; }

valid_user() {
    [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || refuse "invalid user name: $1"
}

# Password file: not a symlink, a regular file owned by root (uid 0), mode 600
# or 400, first line non-empty. Sets PW.
# Uses `read` (a builtin), so the secret never appears in any argv.
read_password_file() {
    local f=$1 st owner mode
    [ ! -L "$f" ] || refuse "password file $f is a symlink — give the real file"
    [ -f "$f" ] || refuse "password file not found: $f"
    st=$(stat -c '%u %a' "$f") || refuse "cannot stat $f"
    read -r owner mode <<< "$st"
    [ "$owner" = 0 ] || refuse "password file $f is owned by uid $owner, must be owned by root (uid 0)"
    case $mode in
        600|400) ;;
        *) refuse "password file $f is mode $mode, must be 600 or 400" ;;
    esac
    PW=""
    IFS= read -r PW < "$f" || true
    PW=${PW%$'\r'}
    [ -n "$PW" ] || refuse "password file $f is empty"
}

# Escape for a double-quoted curl config value (curl -K): \ and ".
curl_quote() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# `<name> <state> <health>` for every container, including exited ones.
compose_ps() {
    # timeout: a hung daemon must not outlast health's or verify's deadline.
    (cd "$MD" && timeout 30 "${COMPOSE[@]}" ps --all --format '{{.Name}} {{.State}} {{.Health}}')
}

# From compose_ps output: the services that are not running+healthy. A service
# without a healthcheck (empty Health) counts if it is running.
not_ready() {
    awk 'NF { if ($2 != "running" || (NF >= 3 && $3 != "healthy"))
                  printf "%s(%s%s) ", $1, $2, (NF >= 3 ? "/" $3 : "") }'
}

image_list() {
    local f="$1/malcolm/image-list.txt"
    [ -s "$f" ] || die "missing or empty $f — is this a bundle directory?"
    local out
    out=$(grep -vE '^[[:space:]]*(#|$)' "$f" || true)
    [ -n "$out" ] || die "no image tags in $f — only comments or blank lines"
    printf '%s\n' "$out"
}

cmd_assert_tags() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: assert-tags <bundle-dir>"
    [ -d "$dir" ] || die "not a directory: $dir"

    # Read the list BEFORE the loop, into the current shell. Feeding the loop
    # from `< <(image_list ...)` puts image_list in a subshell, where its die()
    # exits that subshell only: the loop then sees EOF, `missing` stays 0, and
    # a bundle with NO image list at all is reported "all images present".
    # On the R770 that would wave through an incomplete load -- the precise
    # failure this script exists to catch.
    local list present missing=0
    list=$(image_list "$dir")
    present=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

    while IFS= read -r want; do
        [ -n "$want" ] || continue
        if printf '%s\n' "$present" | grep -qxF "$want"; then
            echo "ok      $want"
        else
            echo "MISSING $want"
            missing=$((missing + 1))
        fi
    done <<< "$list"

    [ "$missing" -eq 0 ] ||
        die "$missing image(s) missing after load — the tarball is incomplete or the load failed"
    echo "all images present"
}

cmd_load() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: load <bundle-dir>"
    local tar
    tar=$(find "$dir/malcolm" -maxdepth 1 -name 'malcolm-images-*.tar.gz' | head -1)
    [ -n "$tar" ] || die "no malcolm-images-*.tar.gz under $dir/malcolm"
    echo "loading $tar ..."
    docker load -i "$tar"
    cmd_assert_tags "$dir"
}

# ── install ──────────────────────────────────────────────────────────────────

cmd_install() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: install <bundle-dir>"
    [ -d "$dir/malcolm" ] || refuse "not a bundle directory (no malcolm/): $dir"
    require_root

    local zips n zip sum stamp
    zips=$(find "$dir/malcolm" -maxdepth 1 -name 'malcolm-*-docker_install.zip' | sort)
    n=$(grep -c . <<< "$zips" || true)
    [ "$n" -eq 1 ] || refuse "expected exactly one malcolm-*-docker_install.zip in $dir/malcolm, found $n"
    zip=$zips
    sum=$(sha_of "$zip") || fail "cannot hash $zip"

    # An existing install (unpacked or configured) is only ever confirmed, never
    # overwritten: unpacking a different zip over it is an upgrade, and an
    # upgrade is a deliberate operator step (runbook Part 8.1).
    if [ -f "$COMPOSE_FILE" ] || find_installer > /dev/null; then
        stamp=$(cat "$STAMP_DIR/install.sha256" 2>/dev/null || true)
        if [ -n "$stamp" ] && [ "$stamp" = "$sum" ]; then
            echo "already installed: $(basename "$zip") (sha256 $sum) in $MALCOLM_ROOT"
            return 0
        fi
        [ -n "$stamp" ] ||
            refuse "$MALCOLM_ROOT holds a Malcolm tree but no install stamp ($STAMP_DIR/install.sha256): it may be from an interrupted install or a pre-script install — inspect it, then move $MALCOLM_ROOT aside before re-running install (bundled $(basename "$zip"): $sum); nothing changed"
        refuse "$MALCOLM_ROOT already holds a Malcolm install from a different zip (installed: $stamp; bundled $(basename "$zip"): $sum) — upgrading is a deliberate operator step, see runbook Part 8.1; nothing changed"
    fi

    mkdir -p "$MALCOLM_ROOT" "$STAMP_DIR" || fail "cannot create $MALCOLM_ROOT"
    echo "unpacking $zip -> $MALCOLM_ROOT"
    unzip -q -o "$zip" -d "$MALCOLM_ROOT" || fail "unzip of $zip failed"
    find_installer > /dev/null ||
        fail "no install.py under $MALCOLM_ROOT after unzip — not a Malcolm docker_install zip?"
    # The 2026-09-16 rehearsal copied the bundle's compose file next to the
    # unpacked installer (work/plans/archive/2026-09-16-vm-deployment-test.md Task 3).
    if [ -f "$dir/malcolm/docker-compose.yml" ]; then
        cp "$dir/malcolm/docker-compose.yml" "$MALCOLM_ROOT/docker-compose.yml" ||
            fail "cannot copy the bundle's docker-compose.yml"
    fi
    printf '%s\n' "$sum" > "$STAMP_DIR/install.sha256" || fail "cannot write install stamp"
    echo "PASS    installed $(basename "$zip") into $MALCOLM_ROOT"
}

# ── configure ────────────────────────────────────────────────────────────────

cmd_configure() {
    local json=${1:-}
    [ -n "$json" ] || die "usage: configure <config-json>"
    [ -s "$json" ] || refuse "config file missing or empty: $json"
    require_root
    local installer
    installer=$(find_installer) || refuse "not installed: no install.py under $MALCOLM_ROOT (run install first)"

    local abs want
    abs="$(cd "$(dirname "$json")" && pwd)/$(basename "$json")"
    want=$(sha_of "$abs") || fail "cannot hash $abs"
    if have_env_files && [ "$(cat "$STAMP_DIR/configure.sha256" 2>/dev/null || true)" = "$want" ]; then
        echo "already configured from this config (sha256 $want)"
        return 0
    fi

    echo "configuring Malcolm from $abs"
    # --defaults is NOT passed: it conflicts with --import-malcolm-config-file.
    (cd "$MALCOLM_ROOT" && python3 "$installer" --non-interactive --configure --skip-splash \
        --import-malcolm-config-file "$abs") < /dev/null || fail "Malcolm's install.py --configure failed"
    have_env_files || fail "install.py exited 0 but wrote no $MD/config/*.env"
    mkdir -p "$STAMP_DIR" || fail "cannot create $STAMP_DIR"
    printf '%s\n' "$want" > "$STAMP_DIR/configure.sha256" || fail "cannot write configure stamp"
    echo "PASS    configured (sha256 $want)"
    echo "NOTE    the installer rewrites docker-compose.yml: run bind-loopback again before start"
}

# ── auth ─────────────────────────────────────────────────────────────────────

cmd_auth() {
    local dir="" pwfile="" user=analyst force=0
    while [ $# -gt 0 ]; do
        case $1 in
            --password-file) [ $# -ge 2 ] || die "--password-file needs a value"; pwfile=$2; shift 2 ;;
            --user)          [ $# -ge 2 ] || die "--user needs a value"; user=$2; shift 2 ;;
            --force)         force=1; shift ;;
            -*)              die "auth: unknown option $1" ;;
            *)               [ -z "$dir" ] || die "auth: unexpected argument $1"; dir=$1; shift ;;
        esac
    done
    if [ -z "$dir" ] || [ -z "$pwfile" ]; then
        die "usage: auth <bundle-dir> --password-file FILE [--user NAME] [--force]"
    fi
    valid_user "$user"
    [ -d "$dir" ] || refuse "not a directory: $dir"
    require_root
    [ -x "$MD/scripts/auth_setup" ] || refuse "not installed: no $MD/scripts/auth_setup"
    have_env_files || refuse "not configured: no $MD/config/*.env (run configure first)"

    if [ -s "$MD/nginx/htpasswd" ] && [ "$force" -eq 0 ]; then
        echo "already authenticated: $MD/nginx/htpasswd exists (use --force to redo)"
        return 0
    fi

    local list img n
    list=$(image_list "$dir")
    img=$(grep -E '/nginx-proxy:[^[:space:]]+$' <<< "$list" || true)
    n=$(grep -c . <<< "$img" || true)
    [ "$n" -eq 1 ] || refuse "expected one nginx-proxy image in $dir/malcolm/image-list.txt, found $n"

    local PW h_ssl h_ht out
    read_password_file "$pwfile"

    if ! h_ssl=$(printf '%s\n' "$PW" | openssl passwd -1 -stdin); then
        PW=""; fail "openssl passwd failed"
    fi
    if ! out=$(printf '%s\n' "$PW" | docker run --rm -i --pull never --network none \
                   --entrypoint htpasswd "$img" -niBC 10 ''); then
        PW=""; fail "htpasswd in $img failed (is the image loaded?)"
    fi
    PW=""
    h_ht=$(printf '%s' "${out#:}" | tr -d '\r\n')
    [[ $h_ssl == \$1\$* ]] || fail "openssl did not return an MD5-crypt hash"
    [[ $h_ht == \$2[aby]\$* ]] || fail "htpasswd did not return a bcrypt hash"

    echo "running Malcolm's auth_setup for user $user (hashes only)"
    (cd "$MD" && ./scripts/auth_setup --auth-noninteractive --auth-method basic \
        --auth-admin-username "$user" \
        --auth-admin-password-openssl "$h_ssl" --auth-admin-password-htpasswd "$h_ht" \
        --auth-generate-webcerts --auth-generate-fwcerts \
        --auth-generate-netbox-passwords --auth-generate-valkey-password \
        --auth-generate-postgres-password --auth-generate-opensearch-internal-creds \
        --auth-generate-keycloak-db-password) < /dev/null || fail "auth_setup failed"
    [ -s "$MD/nginx/htpasswd" ] || fail "auth_setup exited 0 but $MD/nginx/htpasswd is missing or empty"
    echo "PASS    auth: htpasswd written for $user"
}

# ── bind-loopback ────────────────────────────────────────────────────────────

cmd_bind_loopback() {
    require_root
    require_compose_file
    local open loop bak
    open=$(grep -cE "$OPEN_RE" "$COMPOSE_FILE" || true)
    loop=$(grep -cE "$LOOP_RE" "$COMPOSE_FILE" || true)

    if [ "$open" -eq 0 ] && [ "$loop" -ge 1 ] && ! grep -qF '0.0.0.0:443:443' "$COMPOSE_FILE"; then
        echo "already bound: nginx-proxy publishes 127.0.0.1:8443 only"
        return 0
    fi
    [ "$open" -eq 1 ] ||
        refuse "expected exactly one line matching '$OPEN_RE' in $COMPOSE_FILE, found $open — not editing"

    bak="$COMPOSE_FILE.bak-$(date +%Y%m%dT%H%M%S)"
    cp -p "$COMPOSE_FILE" "$bak" || fail "cannot back up $COMPOSE_FILE"
    echo "backup: $bak"
    sed -E -i 's#^    - 0\.0\.0\.0:443:443(/tcp)?$#    - 127.0.0.1:8443:443\1#' "$COMPOSE_FILE" ||
        fail "sed on $COMPOSE_FILE failed; restore with: cp -p $bak $COMPOSE_FILE"
    open=$(grep -cE "$OPEN_RE" "$COMPOSE_FILE" || true)
    if [ "$open" -ne 0 ] || ! grep -qE "$LOOP_RE" "$COMPOSE_FILE"; then
        fail "rebind did not take; restore with: cp -p $bak $COMPOSE_FILE"
    fi
    echo "PASS    nginx-proxy rebound: 0.0.0.0:443:443 -> 127.0.0.1:8443:443 (rollback: cp -p $bak $COMPOSE_FILE)"
}

# ── start ────────────────────────────────────────────────────────────────────

cmd_start() {
    require_root
    require_compose_file
    grep -qF '0.0.0.0:443:443' "$COMPOSE_FILE" &&
        refuse "$COMPOSE_FILE still publishes 0.0.0.0:443 — run bind-loopback first"
    grep -qE "$LOOP_RE" "$COMPOSE_FILE" ||
        refuse "$COMPOSE_FILE has no 127.0.0.1:8443:443 mapping — run bind-loopback first"
    compose_cmd

    local ps
    if ps=$(compose_ps 2> /dev/null) && [ -n "$ps" ] &&
        [ -z "$(awk 'NF && $2 != "running"' <<< "$ps")" ]; then
        echo "already running: $(grep -c . <<< "$ps") containers up (check with: health)"
        return 0
    fi

    local start
    # scripts/start is control.py, which tails logs forever after starting
    # unless -q/--quiet ("Don't show logs as part of start/stop operations").
    read -r -a start <<< "${MALCOLM_START:-./scripts/start --quiet}"
    echo "starting Malcolm with its own start script"
    (cd "$MD" && "${start[@]}") < /dev/null || fail "Malcolm's start script failed"
    echo "PASS    start script returned 0 (now run: health)"
}

# ── health ───────────────────────────────────────────────────────────────────

# Listening sockets: 127.0.0.1:8443 must be there; nothing docker-proxy on
# the wildcard 443, and no docker-proxy on any non-loopback address on any
# port. Needs -p (root) to tell docker-proxy from the portal nginx.
check_ports() {
    local ss_out bad=0 line
    ss_out=$(ss -H -ltnp) || { echo "FAIL    ss -H -ltnp failed"; return 1; }
    if awk '$4 == "127.0.0.1:8443" {f = 1} END {exit !f}' <<< "$ss_out"; then
        echo "PASS    127.0.0.1:8443 is listening"
    else
        echo "FAIL    nothing listening on 127.0.0.1:8443"; bad=1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case $line in
            *docker-proxy*) echo "FAIL    Malcolm published on a wildcard 443: $line"; bad=1 ;;
            *users:*)       echo "info    443 wildcard held by a non-docker process: $line" ;;
            *)              echo "FAIL    wildcard 443 listener with no owner shown (run as root): $line"; bad=1 ;;
        esac
    done < <(awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):443$/' <<< "$ss_out")
    # Every other docker-proxy listener must be on loopback (wildcard 443 was
    # reported above).
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "FAIL    docker-proxy published on a non-loopback address: $line"; bad=1
    done < <(awk '/"docker-proxy"/ && $4 !~ /^(127\.0\.0\.1|\[::1\]):[0-9]+$/ &&
                  $4 !~ /^(0\.0\.0\.0|\[::\]|\*):443$/' <<< "$ss_out")
    [ "$bad" -eq 0 ] && echo "PASS    no docker-proxy on 0.0.0.0:443 or [::]:443, none off loopback"
    return "$bad"
}

cmd_health() {
    local timeout=600
    while [ $# -gt 0 ]; do
        case $1 in
            --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
            *)         die "usage: health [--timeout SECS]" ;;
        esac
    done
    is_uint "$timeout" || die "--timeout must be a whole number of seconds"
    is_uint "$POLL_SECS" || die "MALCOLM_POLL_SECS must be a whole number"
    require_compose_file
    compose_cmd

    local deadline=$((SECONDS + timeout)) ps bad
    while :; do
        if ps=$(compose_ps 2> /dev/null); then
            if [ -n "$ps" ]; then bad=$(not_ready <<< "$ps"); else bad="(no containers)"; fi
        else
            bad="(compose ps failed)"
        fi
        [ -z "$bad" ] && break
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "FAIL    not healthy after ${timeout}s: $bad"
            return 1
        fi
        sleep "$POLL_SECS"
    done
    echo "PASS    all $(grep -c . <<< "$ps") services running and healthy"
    check_ports
}

# ── verify ───────────────────────────────────────────────────────────────────

# Malcolm's upload directory on the host: the source of the bind mount whose
# target is $UPLOAD_TARGET, inside the `  upload:` service of the compose file.
# pcapDir moves it (the R770 config puts it under /data/pcap/raw), so it is
# read from the file Malcolm actually runs, never assumed. A relative source
# resolves against $MD, the compose file's directory. Refuses (exit 1 from
# this subshell; the caller exits) if there is not exactly one, or it is not
# a directory.
upload_dir() {
    local srcs n src
    srcs=$(awk -v want="$UPLOAD_TARGET" '
        function val(v) {
            sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            gsub(/^["\047]|["\047]$/, "", v)
            return v
        }
        /^[ \t]*(#|$)/ { next }
        /^[^ ]/         { inup = 0; next }
        /^  [^ ]/       { inup = ($0 ~ /^  upload:[ \t]*$/); src = ""; tgt = ""; next }
        !inup           { next }
        /^[ \t]*- /     { src = ""; tgt = "" }
        { line = $0; sub(/^[ \t]*(- )?[ \t]*/, "", line) }
        line ~ /^source:/ { src = val(line) }
        line ~ /^target:/ { tgt = val(line) }
        src != "" && tgt == want { print src; src = ""; tgt = "" }
    ' "$COMPOSE_FILE") || refuse "cannot read $COMPOSE_FILE"
    n=$(grep -c . <<< "$srcs" || true)
    [ "$n" -eq 1 ] ||
        refuse "expected one bind mount with target $UPLOAD_TARGET in the upload: service of $COMPOSE_FILE, found $n — cannot tell where Malcolm takes uploads"
    src=$srcs
    case $src in
        /*) ;;
        *)  src="$MD/${src#./}" ;;
    esac
    [ -d "$src" ] ||
        refuse "upload directory $src (from the upload: service in $COMPOSE_FILE) does not exist — is Malcolm installed and started?"
    printf '%s\n' "$src"
}

cmd_verify() {
    local pwfile="" user=analyst
    while [ $# -gt 0 ]; do
        case $1 in
            --password-file) [ $# -ge 2 ] || die "--password-file needs a value"; pwfile=$2; shift 2 ;;
            --user)          [ $# -ge 2 ] || die "--user needs a value"; user=$2; shift 2 ;;
            *)               die "usage: verify --password-file FILE [--user NAME]" ;;
        esac
    done
    [ -n "$pwfile" ] || die "usage: verify --password-file FILE [--user NAME]"
    valid_user "$user"
    local timeout=${VERIFY_TIMEOUT:-300} secs=${VERIFY_CAPTURE_SECS:-20}
    is_uint "$timeout" || die "VERIFY_TIMEOUT must be a whole number"
    is_uint "$secs" || die "VERIFY_CAPTURE_SECS must be a whole number"
    is_uint "$POLL_SECS" || die "MALCOLM_POLL_SECS must be a whole number"
    require_root
    require_compose_file
    local updir
    updir=$(upload_dir) || exit 1
    compose_cmd
    local PW
    read_password_file "$pwfile"
    local cred
    cred=$(curl_quote "$user:$PW")
    PW=""

    local tmp pcap marker i t0 fails=0
    tmp=$(mktemp -d "${MALCOLM_TMPDIR:-/tmp}/r770-malcolm-verify.XXXXXX") || fail "mktemp failed"
    VERIFY_TMP=$tmp
    # Globals, not locals: the trap runs after this function has returned.
    trap '[ -z "$VERIFY_PID" ] || kill "$VERIFY_PID" 2> /dev/null; rm -rf "$VERIFY_TMP"' EXIT
    pcap="$tmp/r770-verify-$(date +%Y%m%dT%H%M%S).pcap"
    marker="$tmp/marker"

    echo "capturing loopback 8443 for ${secs}s while probing $PORTAL_URL/"
    # Arkime's query window opens just before the capture, so an earlier run's
    # sessions can never satisfy this one.
    t0=$(( $(date +%s) - 5 ))
    tcpdump -i lo -U -Z root -w "$pcap" tcp port 8443 > "$tmp/tcpdump.log" 2>&1 &
    VERIFY_PID=$!
    for i in 1 2 3 4 5; do
        sleep $((secs / 5))
        curl -sk -o /dev/null --max-time 5 "$PORTAL_URL/" || true
        echo "  probe $i"
    done
    kill -INT "$VERIFY_PID" 2> /dev/null || true
    wait "$VERIFY_PID" || true
    VERIFY_PID=""

    local size
    size=$(wc -c < "$pcap" 2> /dev/null || echo 0)
    if [ "$size" -gt 24 ]; then
        echo "PASS    capture: $size bytes"
    else
        echo "FAIL    capture: $pcap empty or missing ($(tr '\n' ' ' < "$tmp/tcpdump.log" 2> /dev/null || true))"
        return 1
    fi

    local name dest
    name=$(basename "$pcap")
    dest="$updir/$name"
    : > "$marker"
    # Copy under a hidden name, then rename, so Malcolm never sees a partial file.
    if ! { cp "$pcap" "$updir/.$name.part" && chmod 0644 "$updir/.$name.part" &&
           mv "$updir/.$name.part" "$dest"; }; then
        fail "cannot place $name in $updir"
    fi
    echo "PASS    uploaded: $dest"

    local deadline=$((SECONDS + timeout)) arkime=0 zeek=0 resp count
    while :; do
        if [ "$arkime" -eq 0 ]; then
            resp=$(printf 'user = "%s"\n' "$cred" |
                curl -sk --max-time 20 -K - \
                    "$PORTAL_URL/arkime/api/sessions?startTime=$t0&stopTime=$(( $(date +%s) + 60 ))&expression=port%3D%3D8443" 2> /dev/null || true)
            count=$(sed -n 's/.*"recordsFiltered":[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<< "$resp" | head -1)
            [ -n "$count" ] && [ "$count" -gt 0 ] && arkime=$count
        fi
        if [ "$zeek" -eq 0 ] && [ -d "$MD/zeek-logs" ] &&
            [ -n "$(find "$MD/zeek-logs" -type f -newer "$marker" -print -quit 2> /dev/null)" ]; then
            zeek=1
        fi
        [ "$arkime" -gt 0 ] && [ "$zeek" -eq 1 ] && break
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep "$POLL_SECS"
    done
    cred=""

    if [ "$arkime" -gt 0 ]; then
        echo "PASS    arkime: $arkime session(s) on port 8443 since the capture started"
    else
        echo "FAIL    arkime: no sessions for the capture within ${timeout}s"; fails=$((fails + 1))
    fi
    if [ "$zeek" -eq 1 ]; then
        echo "PASS    zeek: new log files under $MD/zeek-logs"
    else
        echo "FAIL    zeek: no new files under $MD/zeek-logs within ${timeout}s"; fails=$((fails + 1))
    fi

    local ps zl
    ps=$(compose_ps 2> /dev/null || true)
    zl=$(awk '$1 ~ /-zeek-[0-9]+$/' <<< "$ps")
    if [ -n "$zl" ] && [ -z "$(not_ready <<< "$zl")" ]; then
        echo "PASS    zeek container: $zl"
    else
        echo "FAIL    zeek container not running+healthy: ${zl:-absent} (it needs NET_RAW/NET_ADMIN)"
        fails=$((fails + 1))
    fi

    [ "$fails" -eq 0 ] || { echo "verify: $fails check(s) FAILED"; return 1; }
    echo "verify: all checks PASS"
}

case "${1:-}" in
    load)          shift; cmd_load "$@" ;;
    assert-tags)   shift; cmd_assert_tags "$@" ;;
    install)       shift; cmd_install "$@" ;;
    configure)     shift; cmd_configure "$@" ;;
    auth)          shift; cmd_auth "$@" ;;
    bind-loopback) shift; cmd_bind_loopback "$@" ;;
    start)         shift; cmd_start "$@" ;;
    health)        shift; cmd_health "$@" ;;
    verify)        shift; cmd_verify "$@" ;;
    *)             die "usage: r770-malcolm-deploy.sh load|assert-tags|install <bundle-dir> | configure <json> | auth <bundle-dir> --password-file F [--user N] [--force: regenerates ALL internal creds] | bind-loopback | start | health | verify --password-file F [--user N]" ;;
esac
