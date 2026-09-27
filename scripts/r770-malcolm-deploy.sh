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
#                              importing <config-json>: the top-level install.py
#                              (in MALCOLM_ROOT) the first time, which extracts
#                              the tree; once malcolm/scripts/install.py exists,
#                              that one (in malcolm/) -- the top-level one aborts
#                              on an existing tree. Then bind-loopback again.
#   auth <bundle-dir> --password-file FILE [--user NAME] [--force]
#                              Malcolm's auth_setup, unattended, fed HASHES only.
#                              --force re-runs EVERY --auth-generate-* flag: on an
#                              initialized stack that regenerates the internal
#                              postgres/netbox/valkey/opensearch/keycloak
#                              credentials too. It is not a password-change path.
#   bind-loopback              nginx-proxy 0.0.0.0:443:443[/tcp] -> 127.0.0.1:8443:443[/tcp]
#                              (the file keeps its owner)
#   start                      Malcolm's own ./scripts/start --quiet (refused before bind-loopback)
#   health [--timeout SECS]    every service running+healthy; only 127.0.0.1:8443 published
#   verify --password-file FILE [--user NAME]
#                              loopback PCAP -> Malcolm's upload dir (read from the
#                              upload: service's bind mount in docker-compose.yml);
#                              Arkime sessions, Zeek logs, zeek container healthy
#
# The script runs as root and drops privileges only for Malcolm's own tools.
# $MD/scripts/{auth_setup,start,...} are all symlinks to control.py, which
# refuses root: getuid/geteuid 0, or getpass.getuser() == root -- and
# getpass reads LOGNAME/USER first, which sudo sets to root. So auth_setup and
# start run as the PUID user from $MD/config/process.env (the file the
# containers use): runuser -u USER -- env HOME USER LOGNAME set to that user.
# PUID/PGID come from processUserId/processGroupId in the config JSON that
# configure imports; the installer rewrites process.env from them on every
# configure, so that JSON -- never process.env -- is where to change them.
# It is refused if process.env is missing, PUID/PGID are missing or not
# numbers, PUID is 0, the uid has no passwd entry, PGID is not that user's
# primary gid (runuser uses the passwd gid), or the user is not in the docker
# group. HOME is the passwd home when the user owns it and can write it, else
# $MD (a system user's home, e.g. /opt/malcolm, is often root's).
#
# Before either verb the script makes the tree and the host data dirs named by
# the compose binds -- the upload: service's upload dir, pcap-monitor's /pcap
# source (pcapDir) and opensearch's data source (indexDir) -- belong to
# PUID:PGID. Each bind source must be canonical (realpath -m, as written, no
# symlink) and allowlisted: strictly under $MD, or exactly pcapDir,
# pcapDir/upload or indexDir as the config configure last imported names them
# (its copy in $STAMP_DIR); with no copy, any path strictly under /data except
# /data/pcap. /, any top-level dir, /data and /data/pcap (the LV root holding
# cases/ and archived/) are never allowed. Anything else refuses with nothing
# changed. A data dir outside $MD whose filesystem is in fstab but not
# mounted is refused with nothing changed: the longest `findmnt --fstab`
# target that is the dir or an ancestor of it must pass `mountpoint -q` (an
# unmounted LV mountpoint is an empty root-owned dir, so its existence proves
# nothing). With no such fstab entry the dir is not checked. A missing data
# dir is then created (its parent must exist) so docker does not create it
# root-owned. $MD is chowned -R unless every entry already is PUID:PGID; a
# data dir is chowned -R when it or a direct child is not PUID:PGID, so a
# populated index is not walked on every start. install.py (configure) runs
# as root, as Malcolm allows.
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
#   MALCOLM_START           start command, run in $MALCOLM_ROOT/malcolm as the PUID user
#                           (default "./scripts/start --quiet")
#   MALCOLM_POLL_SECS       health/verify poll interval (default 10)
#   MALCOLM_TMPDIR          where verify writes its capture (default /tmp)
#   VERIFY_TIMEOUT          verify's wait for Arkime/Zeek (default 300)
#   VERIFY_CAPTURE_SECS     length of the loopback capture (default 20)
#   MALCOLM_DATA_ROOT       the data root of the fixed allowlist rule (default /data)
set -euo pipefail

MALCOLM_ROOT="${MALCOLM_ROOT:-/opt/malcolm}"
MD="$MALCOLM_ROOT/malcolm"
COMPOSE_FILE="$MD/docker-compose.yml"
STAMP_DIR="$MALCOLM_ROOT/.r770-deploy"
# The config JSON configure last imported successfully (its sha256 is in
# configure.sha256): where own_for_malcolm reads pcapDir and indexDir.
CONFIG_COPY="$STAMP_DIR/malcolm-config.json"
DATA_ROOT="${MALCOLM_DATA_ROOT:-/data}"
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
    [ "$uid" = 0 ] || refuse "must run as root (it drops to Malcolm's PUID user for auth_setup and start itself)"
}

# ── Malcolm's own user ───────────────────────────────────────────────────────

PROCESS_ENV="$MD/config/process.env"
# Container-side bind targets whose host sources are pcapDir and indexDir.
PCAP_TARGET='/pcap'
INDEX_TARGET='/usr/share/opensearch/data'

# Every value of KEY= in process.env: quotes, CR and trailing blanks stripped.
process_env_value() {
    sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" "$PROCESS_ENV" |
        tr -d "\r\"'" | sed -E 's/[[:space:]]+$//'
}

# Where PUID/PGID really come from: every refusal about them points here.
FIX_IDS="set processUserId/processGroupId in the config JSON that configure imports (config/malcolm/malcolm-config.json) and re-run configure — the installer rewrites process.env from it"

# The user Malcolm's containers and control.py run as. Sets M_USER M_UID M_GID
# M_HOME, or refuses (nothing has changed yet when it does).
malcolm_user() {
    local puid pgid ent name uid gid home groups hst
    [ -f "$PROCESS_ENV" ] ||
        refuse "no $PROCESS_ENV — Malcolm's configure writes PUID/PGID there from processUserId/processGroupId in the imported config JSON (run configure first)"
    puid=$(process_env_value PUID) || refuse "cannot read $PROCESS_ENV"
    pgid=$(process_env_value PGID) || refuse "cannot read $PROCESS_ENV"
    { is_uint "$puid" && [ "$(grep -c . <<< "$puid")" -eq 1 ]; } ||
        refuse "PUID in $PROCESS_ENV is missing, repeated or not a number ('${puid//$'\n'/ }') — $FIX_IDS"
    { is_uint "$pgid" && [ "$(grep -c . <<< "$pgid")" -eq 1 ]; } ||
        refuse "PGID in $PROCESS_ENV is missing, repeated or not a number ('${pgid//$'\n'/ }') — $FIX_IDS"
    [ "$puid" -ne 0 ] ||
        refuse "PUID in $PROCESS_ENV is 0: Malcolm's control.py refuses to run as root — $FIX_IDS, naming a non-root user in the docker group"
    ent=$(getent passwd "$puid") ||
        refuse "PUID $puid (from $PROCESS_ENV) has no passwd entry — create that user, or $FIX_IDS"
    IFS=: read -r name _ uid gid _ home _ <<< "$ent"
    [ "$uid" = "$puid" ] || refuse "getent passwd $puid returned uid '$uid' — $FIX_IDS"
    [[ $name =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || refuse "PUID $puid maps to an unusable user name: $name"
    # runuser takes the group from passwd, not from PGID: a mismatch would
    # give everything auth_setup and start write the wrong group.
    [ "$gid" = "$pgid" ] ||
        refuse "PGID $pgid (from $PROCESS_ENV) is not the primary gid of user $name ('$gid' in passwd): runuser would run with gid $gid and files would get the wrong group — $FIX_IDS"
    [ -n "$home" ] || refuse "user $name (PUID $puid) has no home directory in passwd"
    groups=$(id -nG "$name") || refuse "cannot list the groups of $name"
    [[ " $groups " == *" docker "* ]] ||
        refuse "user $name (PUID $puid from $PROCESS_ENV) is not in the docker group — add them: usermod -aG docker $name"
    command -v runuser > /dev/null || refuse "runuser not found (util-linux)"
    # A system user's home (the planned malcolm user's is /opt/malcolm) is
    # often root's; tools that write under HOME would then fail. Use it only
    # when the user owns it and can write it, else $MD, which own_for_malcolm
    # makes theirs before anything runs as them.
    hst=""
    [ -d "$home" ] && hst=$(stat -c %u "$home" 2> /dev/null)-$(stat -c %A "$home" 2> /dev/null)
    if [[ $hst != "$puid"-??w* ]]; then
        echo "note    $name's home $home is missing or not theirs to write; HOME=$MD for Malcolm's tools"
        home=$MD
    fi
    M_USER=$name M_UID=$puid M_GID=$pgid M_HOME=$home
}

# Host sources of the bind mounts with container path TARGET in compose
# service SVC, one per line, relative ones resolved against $MD.
bind_sources() {
    local svc=$1 want=$2 src
    awk -v svc="$svc" -v want="$want" '
        function val(v) {
            sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            gsub(/^["\047]|["\047]$/, "", v)
            return v
        }
        /^[ \t]*(#|$)/ { next }
        /^[^ ]/         { inup = 0; next }
        /^  [^ ]/       { inup = ($0 == "  " svc ":" || $0 ~ ("^  " svc ":[ \t]+$")); src = ""; tgt = ""; next }
        !inup           { next }
        /^[ \t]*- /     { src = ""; tgt = "" }
        { line = $0; sub(/^[ \t]*(- )?[ \t]*/, "", line) }
        line ~ /^source:/ { src = val(line) }
        line ~ /^target:/ { tgt = val(line) }
        src != "" && tgt == want { print src; src = ""; tgt = "" }
    ' "$COMPOSE_FILE" | while IFS= read -r src; do
        case $src in
            /*) printf '%s\n' "$src" ;;
            *)  printf '%s\n' "$MD/${src#./}" ;;
        esac
    done
}

# The storage dirs the imported config names, one per line: pcapDir,
# pcapDir/upload (the upload: service's source) and indexDir -- only the
# absolute ones, and none when useDefaultStorageLocations is true (the
# installer then ignores both). Read from $CONFIG_COPY, and only while its
# sha256 is the one configure recorded. Returns 2 when there is no such copy
# (the caller falls back to the fixed /data rule), 1 when it cannot be read.
config_storage_dirs() {
    [ -f "$CONFIG_COPY" ] && [ -f "$STAMP_DIR/configure.sha256" ] || return 2
    [ "$(sha_of "$CONFIG_COPY")" = "$(cat "$STAMP_DIR/configure.sha256")" ] || return 2
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
c = c.get("configuration", c) if isinstance(c, dict) else None
if not isinstance(c, dict):
    sys.exit(1)
if c.get("useDefaultStorageLocations") is True:
    sys.exit(0)
ok = lambda v: isinstance(v, str) and v.startswith("/") and "\n" not in v
p, i = c.get("pcapDir"), c.get("indexDir")
if ok(p):
    print(p)
    print(p.rstrip("/") + "/upload")
if ok(i):
    print(i)
' "$CONFIG_COPY" || return 1
}

# Refuse (nothing has changed yet) unless bind source D may be chowned -R.
# NAMED: config_storage_dirs output, or the word "fixed" for the /data rule.
check_data_dir() {
    local d=$1 named=$2 c
    [ ! -L "$d" ] ||
        refuse "Malcolm data dir $d (a bind source in $COMPOSE_FILE) is a symlink — not chowning through it; nothing changed"
    c=$(realpath -m -- "$d") || refuse "cannot canonicalise Malcolm data dir $d; nothing changed"
    [ "$c" = "$d" ] ||
        refuse "Malcolm data dir $d (a bind source in $COMPOSE_FILE) is not canonical: it resolves to $c — not chowning it; nothing changed"
    case $d in "$MD"/?*) return 0 ;; esac
    # Never /, a top-level dir, the data root, or /data/pcap: the LV root that
    # holds cases/ and archived/ besides pcapDir.
    if [[ ! $d =~ ^/[^/]+/. ]] || [ "$d" = "$DATA_ROOT" ] || [ "$d" = "$DATA_ROOT/pcap" ]; then
        refuse "a Malcolm bind source in $COMPOSE_FILE is $d — never chowning /, a top-level dir, $DATA_ROOT or $DATA_ROOT/pcap; nothing changed"
    fi
    if [ "$named" = fixed ]; then
        case $d in "$DATA_ROOT"/?*) return 0 ;; esac
        refuse "Malcolm data dir $d is neither under $MD nor under $DATA_ROOT (and no imported config copy $CONFIG_COPY names it) — not chowning it; nothing changed"
    fi
    grep -qxF -- "$d" <<< "$named" && return 0
    refuse "Malcolm data dir $d is neither under $MD nor pcapDir, pcapDir/upload or indexDir of the imported config ($CONFIG_COPY) — not chowning it; nothing changed"
}

# Refuse (nothing has changed yet) when data dir D, outside $MD, lies on a
# filesystem /etc/fstab names that is not mounted. An unmounted LV mountpoint
# is an empty root-owned dir, so "the parent exists" proves nothing: mkdir and
# chown would land on the root filesystem, under the mount. FSTAB: the targets
# of `findmnt --fstab`, one per line; the longest one that is D or an ancestor
# of D is the one that must be mounted. No such entry: nothing to check.
check_mounted() {
    local d=$1 fstab=$2 t best=""
    case $d in "$MD"/?*) return 0 ;; esac
    while IFS= read -r t; do
        case $t in /*) ;; *) continue ;; esac   # swap's "none", blanks
        case $d/ in "${t%/}"/*) ;; *) continue ;; esac
        [ "${#t}" -gt "${#best}" ] && best=$t
    done <<< "$fstab"
    [ -n "$best" ] || return 0
    mountpoint -q -- "$best" ||
        refuse "Malcolm data dir $d lies under $best: $best is in fstab but not mounted — mount it first; nothing changed"
}

# Make the tree and the data dirs Malcolm's containers write to belong to
# M_UID:M_GID, as in the rehearsal (a user-owned tree). The installer chowns
# only config/; nginx/, scripts/, docker-compose.yml etc. stay root's. See the
# header for the allowlist. -h: symlinks (scripts/* -> control.py) are changed
# themselves, never followed.
own_for_malcolm() {
    local owner="$M_UID:$M_GID" d dirs="" named rc fstab
    if [ -f "$COMPOSE_FILE" ]; then
        # Sorted, so a parent comes before its children: it is created first,
        # and once it is chowned -R a child is already the PUID's and skipped.
        dirs=$( { bind_sources upload "$UPLOAD_TARGET"
                  bind_sources pcap-monitor "$PCAP_TARGET"
                  bind_sources opensearch "$INDEX_TARGET"; } | LC_ALL=C sort -u) ||
            fail "cannot read the data-dir binds from $COMPOSE_FILE"
    fi
    if [ -n "$dirs" ]; then
        rc=0; named=$(config_storage_dirs) || rc=$?
        case $rc in
            0) ;;
            2) named=fixed ;;
            *) refuse "cannot read pcapDir/indexDir from $CONFIG_COPY; nothing changed" ;;
        esac
        if ! command -v findmnt > /dev/null || ! command -v mountpoint > /dev/null; then
            refuse "findmnt and mountpoint (util-linux) are needed to check the data dirs' storage is mounted; nothing changed"
        fi
        fstab=$(findmnt --fstab -n -o TARGET 2>/dev/null || true)
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            check_data_dir "$d" "$named"
            check_mounted "$d" "$fstab"
            # A missing dir is created below; a missing parent (one that is not
            # itself a data dir created first) means storage is not mounted.
            [ -e "$d" ] || [ -d "$(dirname "$d")" ] || grep -qxF -- "$(dirname "$d")" <<< "$dirs" ||
                refuse "Malcolm data dir $d is missing and so is its parent $(dirname "$d") — is the storage mounted? nothing changed"
        done <<< "$dirs"
        # Create what is missing now, as root then chowned below: left to
        # docker, a missing bind source is created root-owned.
        while IFS= read -r d; do
            if [ -z "$d" ] || [ -e "$d" ]; then continue; fi
            echo "mkdir $d (a Malcolm data dir, missing)"
            mkdir -- "$d" || fail "mkdir $d failed"
        done <<< "$dirs"
    fi
    if [ -n "$(find "$MD" \( ! -uid "$M_UID" -o ! -gid "$M_GID" \) -print -quit)" ]; then
        echo "chown -R $owner $MD (Malcolm's PUID/PGID, user $M_USER)"
        chown -R -h "$owner" -- "$MD" || fail "chown -R $owner $MD failed"
    fi
    while IFS= read -r d; do
        case $d in
            ""|"$MD"/*) continue ;;   # empty, or covered by the $MD step
        esac
        [ -d "$d" ] || continue
        # The dir itself or a direct child (root-owned subdirs docker or an
        # earlier root run left) not PUID:PGID: walk it. Else leave it.
        [ -n "$(find "$d" -maxdepth 1 \( ! -uid "$M_UID" -o ! -gid "$M_GID" \) -print -quit)" ] || continue
        echo "chown -R $owner $d (a Malcolm data dir, not all the PUID's)"
        chown -R -h "$owner" -- "$d" || fail "chown -R $owner $d failed"
    done <<< "$dirs"
}

# Run a command as Malcolm's user with a clean identity: control.py's getpass
# check reads LOGNAME/USER, which sudo set to root. The caller sets cwd and
# stdin. runuser keeps the environment otherwise (DOCKER_HOST etc.).
as_malcolm() {
    runuser -u "$M_USER" -- env HOME="$M_HOME" USER="$M_USER" LOGNAME="$M_USER" "$@"
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
# This top-level installer extracts the tarball into $MD, so it can configure
# only ONCE: with $MD present it aborts ("$MD already exists, please specify a
# different installation path"). Once the tree exists, configure uses the
# tree's own installer instead (tree_installer).
find_installer() {
    local c
    for c in "$MALCOLM_ROOT/install.py" "$MALCOLM_ROOT/scripts/install.py"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# The extracted tree's own installer ($MD/scripts/configure is a symlink to
# it): Malcolm's supported reconfigure path, run from $MD. No tarball step.
TREE_INSTALLER_REL=scripts/install.py
tree_installer() { [ -f "$MD/$TREE_INSTALLER_REL" ]; }

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
    # install never runs an installer; it only unzips, and never over a tree.
    if [ -d "$MD" ] || [ -f "$COMPOSE_FILE" ] || find_installer > /dev/null; then
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
    # Pick the installer by state: the extracted tree's own scripts/install.py,
    # run from $MD, once $MD holds it (a reconfigure -- the top-level one would
    # abort on the existing $MD); else the top-level one, run from
    # $MALCOLM_ROOT, which extracts the tree first. Same flags either way.
    local installer cwd
    if tree_installer; then
        installer=$TREE_INSTALLER_REL cwd=$MD
    else
        installer=$(find_installer) || refuse "not installed: no install.py under $MALCOLM_ROOT (run install first)"
        cwd=$MALCOLM_ROOT
    fi

    local abs want
    abs="$(cd "$(dirname "$json")" && pwd)/$(basename "$json")"
    want=$(sha_of "$abs") || fail "cannot hash $abs"
    if have_env_files && [ "$(cat "$STAMP_DIR/configure.sha256" 2>/dev/null || true)" = "$want" ]; then
        # A stamp from before the copy was kept, or a copy since altered:
        # (re)write it from this config, whose sha256 the stamp already holds.
        cmp -s -- "$abs" "$CONFIG_COPY" ||
            cp "$abs" "$CONFIG_COPY" || fail "cannot keep a copy of $abs in $CONFIG_COPY"
        echo "already configured from this config (sha256 $want)"
        return 0
    fi

    echo "configuring Malcolm from $abs with $installer (in $cwd)"
    # --defaults is NOT passed: it conflicts with --import-malcolm-config-file.
    (cd "$cwd" && python3 "$installer" --non-interactive --configure --skip-splash \
        --import-malcolm-config-file "$abs") < /dev/null || fail "Malcolm's install.py --configure failed"
    have_env_files || fail "install.py exited 0 but wrote no $MD/config/*.env"
    mkdir -p "$STAMP_DIR" || fail "cannot create $STAMP_DIR"
    # The copy own_for_malcolm reads pcapDir/indexDir from; it is trusted only
    # while its sha256 matches the stamp, so write it first.
    cp "$abs" "$CONFIG_COPY" || fail "cannot keep a copy of $abs in $CONFIG_COPY"
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
    malcolm_user

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

    own_for_malcolm
    echo "running Malcolm's auth_setup as $M_USER for user $user (hashes only)"
    (cd "$MD" && as_malcolm ./scripts/auth_setup --auth-noninteractive --auth-method basic \
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
    # sed -i writes a new file; give it back the original's owner (Malcolm's
    # PUID once auth/start have run) -- the backup was taken with cp -p.
    chown --reference="$bak" -- "$COMPOSE_FILE" ||
        fail "cannot restore the owner of $COMPOSE_FILE; restore with: cp -p $bak $COMPOSE_FILE"
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
    malcolm_user
    own_for_malcolm
    echo "starting Malcolm with its own start script, as $M_USER"
    (cd "$MD" && as_malcolm "${start[@]}") < /dev/null || fail "Malcolm's start script failed"
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
    srcs=$(bind_sources upload "$UPLOAD_TARGET") || refuse "cannot read $COMPOSE_FILE"
    n=$(grep -c . <<< "$srcs" || true)
    [ "$n" -eq 1 ] ||
        refuse "expected one bind mount with target $UPLOAD_TARGET in the upload: service of $COMPOSE_FILE, found $n — cannot tell where Malcolm takes uploads"
    src=$srcs
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
        # $MD/zeek-logs is Malcolm's in-tree default. The R770 config leaves
        # zeekLogDir unset (<MALCOLM_CONFIG_NONE>), and the 26.08 installer
        # falls back to the in-tree default for any unset storage dir
        # (installer/actions/shared.py get_or_default: config value or
        # DEFAULT_*), so zeekLogDir stays ./zeek-logs. Setting zeekLogDir
        # moves it, and this check must then read it from the compose file.
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
