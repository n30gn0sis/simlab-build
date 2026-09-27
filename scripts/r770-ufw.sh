#!/usr/bin/env bash
#
# r770-ufw.sh — host firewall for the analyst stack: deny incoming by default,
# allow SSH and 443/tcp ONLY on the management interface, from the management
# subnet. Runs ON the target box (VM 9771 for the proof run, the R770 later), as
# root, from an SSH session. Under sudo, keep the session variable:
#   sudo --preserve-env=SSH_CONNECTION ./r770-ufw.sh <verb>
# (sudo's env_reset strips it, and every verb that needs it then refuses).
#
#   plan                 default. Read-only: discovered management path, current
#                        `ufw status verbose`, the proposed ruleset
#   apply [--minutes N]  back up, add the allow rules, arm the dead-man switch,
#                        then deny-by-default and enable. N = 1-60, default 10.
#                        Refuses while an earlier switch is still pending
#                        (confirm or revert first): it never supersedes one
#   confirm              run from a NEW ssh session: cancels the auto-revert
#   verify               read-only, see "verify's scope" below
#   revert               restore /etc/ufw and /etc/default/ufw from the newest
#                        pre-apply backup. If that backup had UFW enabled, the
#                        re-enable is guarded by the same dead-man switch
#                        (10 minutes) and needs `confirm` from a NEW session,
#                        exactly as apply does; otherwise UFW is left disabled
#                        and any pending switch is cancelled. The re-enable
#                        checks the CURRENT session, not the restored rules: if
#                        the backup's rules do not admit SSH, the new session
#                        cannot connect, confirm never runs, and recovery relies
#                        on the switch firing (fail-open: UFW disabled). A
#                        backup from before /etc/default/ufw was captured
#                        (d9581cb) can still revert to DISABLED, with a WARN
#                        that /etc/default/ufw is left as is; revert to
#                        ENABLED from it is refused
#
#   0  done, nothing to do, or every check passed
#   1  refused (REFUSE: nothing changed), failed (FAIL: the output says what
#      changed and what is still armed), or a verify check failed
#
# LOSING SSH IS THE WORST FAILURE, so:
#   - nothing is guessed: the management interface, subnet and SSH port come from
#     the live session ($SSH_CONNECTION -> `ip route get` -> `ip addr`). Any gap,
#     or a client that the proposed rule would NOT admit, is a REFUSE. Set
#     UFW_EXPECT_IFACE to the inventory's management interface to also REFUSE
#     when discovery lands anywhere else;
#   - the allow rules are added and read back from `ufw show added` before the
#     default policy changes or UFW is enabled;
#   - the auto-revert sleeper is armed BEFORE the deny policy and the enable, so
#     a dropped session or a dying script mid-apply still undoes itself. SIGHUP
#     is ignored during apply. The switch runs `ufw --force disable`: it FAILS
#     OPEN (no firewall at all), it does not restore the previous ruleset — run
#     revert afterwards for that;
#   - confirm proves a NEW connection: it refuses unless its own client
#     ip:port was NOT among the established sshd connections recorded when UFW
#     was enabled AND is established now (`ss`). A session that was open before
#     the enable rides on conntrack and proves nothing. Open the new session
#     with `ssh -o ControlMaster=no -o ControlPath=none ...`: a multiplexed
#     ssh reuses the recorded TCP connection, and confirm refuses it. If the
#     switch fires while confirm runs, confirm FAILs (re-run apply).
#
# The sleeper has limits, and plan/apply say so:
#   - it is a process in the SSH session's scope. If logind has
#     KillUserProcesses=yes it dies with that session, so plan and apply REFUSE.
#     The live value comes from `busctl get-property org.freedesktop.login1
#     ... KillUserProcesses`; only if busctl is missing or fails are the files
#     parsed: logind.conf, then the *.conf drop-ins from /etc, /run,
#     /usr/local/lib and /usr/lib systemd/logind.conf.d (a name in an earlier
#     directory hides the same name in a later one), in file-name order, last
#     setting wins. [Section] headers are not tracked;
#   - a REBOOT inside the window loses it, while UFW stays enabled (ufw.conf
#     has ENABLED=yes). Do not reboot until confirm has run.
#
# verify's scope: UFW state and rules, the pending switch, and what listens or
# is published on this host — non-loopback listeners from `ss -ltnp`, and
# Docker's nat DOCKER chain (DNAT rules published on any address other than
# 127.0.0.1 bypass UFW, docker-proxy or not: userland-proxy:false leaves no
# listener to see; IPv4 only — ports Docker publishes through ip6tables are NOT
# checked). A docker-proxy or unidentified non-loopback listener FAILs.
# Other host listeners beyond SSH/443 are a WARN: UFW's INPUT chain does filter
# them, so they are reachable only if a rule admits them, but they are still
# worth knowing about. Reachability from outside is NOT checked here — a box
# cannot see itself from the far side of its own firewall; the proof run checks
# it from a second host (`nc` against the open and closed ports).
#
# The detached sleeper is the pattern from scripts/r770-airgap-sim.sh, including
# its lesson: a pending sleeper is cancelled before a new one is armed, or the
# first one fires later and silently undoes the current state.
#
# Design: docs/superpowers/specs/2026-09-26-analyst-stack-design.md
#         ("scripts/r770-ufw.sh plan | apply | confirm | verify | revert")
#
# Operator option: UFW_EXPECT_IFACE (see above).
# Test overrides: UFW_RUN_DIR (default /run), UFW_BACKUP_DIR (default
# /var/backups/r770-ufw), UFW_ETC_DIR (default /etc/ufw), UFW_DEFAULT_FILE
# (default /etc/default/ufw), UFW_LOGIND_ROOT (default empty: prefixed to
# every logind.conf path of the file fallback),
# UFW_DRY_RUN=1 prints the ufw commands (and skips backup and sleeper) instead
# of running them. UFW_SSH_CONNECTION replaces $SSH_CONNECTION ONLY when
# UFW_TEST=1 (set-but-empty counts as empty); otherwise it is ignored.
set -uo pipefail
export LC_ALL=C

RUN_DIR="${UFW_RUN_DIR:-/run}"
BACKUP_DIR="${UFW_BACKUP_DIR:-/var/backups/r770-ufw}"
ETC_DIR="${UFW_ETC_DIR:-/etc/ufw}"
DEFAULT_FILE="${UFW_DEFAULT_FILE:-/etc/default/ufw}"
LOGIND_ROOT="${UFW_LOGIND_ROOT:-}"
LOGIND_SRC=""
EXPECT_IF="${UFW_EXPECT_IFACE:-}"
if [ "${UFW_TEST:-0}" = 1 ]; then
    CONN="${UFW_SSH_CONNECTION-${SSH_CONNECTION:-}}"
else
    CONN="${SSH_CONNECTION:-}"
fi
DRY="${UFW_DRY_RUN:-0}"
MARK="r770-ufw"
PIDFILE="$RUN_DIR/$MARK.pid"            # the detached auto-revert sleeper
TIMER="$RUN_DIR/$MARK.deadline"         # epoch seconds when it fires
ESTFILE="$RUN_DIR/$MARK.established"    # sshd peers (ip:port) established at enable time
SSHPORTFILE="$RUN_DIR/$MARK.ssh-port"   # the sshd port those were read on
LAST_REVERT="$BACKUP_DIR/last-revert"   # set by revert, cleared by apply
HTTPS_PORT=443
REVERT_MINUTES=10
SLEEPER_WAIT_TICKS=500                  # x 0.02 s = 10 s for the sleeper to start

die()  { printf 'REFUSE  %s\n' "$*" >&2; exit 1; }   # before any change
fail() { printf 'FAIL    %s\n' "$*" >&2; exit 1; }   # a mutating step failed
info() { printf 'INFO    %s\n' "$*"; }
warn() { printf 'WARN    %s\n' "$*"; }

usage() { die "usage: r770-ufw.sh [plan | apply [--minutes N] | confirm | verify | revert]"; }

need_root() { [ "$(id -u 2>/dev/null)" = 0 ] || die "must run as root (ufw, /etc/ufw, $RUN_DIR)"; }

# An empty session variable under sudo is almost always env_reset, not a console.
need_conn() {  # need_conn WHAT
    [ -z "$CONN" ] || return 0
    if [ -n "${SUDO_USER:-}" ]; then
        die "SSH_CONNECTION is empty under sudo (env_reset strips it): run 'sudo --preserve-env=SSH_CONNECTION $0 ...' from an SSH session; $1"
    fi
    die "SSH_CONNECTION is empty: $1"
}

# ── discovery ────────────────────────────────────────────────────────────────

is_ipv4() {
    local IFS=. o
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    for o in $1; do [ $((10#$o)) -le 255 ] || return 1; done
}

ip2int() { local IFS=. a b c d; read -r a b c d <<< "$1"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ $((10#$1)) -ge 1 ] && [ $((10#$1)) -le 65535 ]; }

# Sets CLIENT_IP CLIENT_PORT SERVER_IP SSH_PORT from $CONN, or refuses.
parse_conn() {
    local extra
    read -r CLIENT_IP CLIENT_PORT SERVER_IP SSH_PORT extra <<< "$CONN"
    { [ -n "${SSH_PORT:-}" ] && [ -z "${extra:-}" ]; } || die "SSH_CONNECTION is not 'client_ip client_port server_ip server_port': '$CONN'"
    { is_ipv4 "$CLIENT_IP" && is_ipv4 "$SERVER_IP"; } || die "SSH_CONNECTION is not an IPv4 session ('$CONN'); IPv6 management is not supported"
    { is_port "$CLIENT_PORT" && is_port "$SSH_PORT"; } || die "SSH_CONNECTION has a bad port: '$CONN'"
}

# Sets CLIENT_IP CLIENT_PORT SERVER_IP SSH_PORT MGMT_IF MGMT_NET, or refuses.
discover() {
    local route cidr prefix mask net
    need_conn "run this from an SSH session (the management path is read from it, never guessed)"
    parse_conn

    route="$(ip -o route get "$CLIENT_IP" 2>/dev/null)" || die "ip route get $CLIENT_IP failed"
    MGMT_IF="$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<< "$route")"
    [ -n "$MGMT_IF" ] || die "no 'dev' in 'ip route get $CLIENT_IP' output: $route"
    [ "$MGMT_IF" != lo ] || die "the SSH client $CLIENT_IP routes via lo: not a management session"
    [[ "$MGMT_IF" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || die "unexpected interface name '$MGMT_IF'"
    [ -z "$EXPECT_IF" ] || [ "$MGMT_IF" = "$EXPECT_IF" ] \
        || die "discovered interface $MGMT_IF is not UFW_EXPECT_IFACE=$EXPECT_IF: this session does not arrive on the expected management interface"

    cidr="$(ip -o -4 addr show dev "$MGMT_IF" 2>/dev/null \
        | awk -v ip="$SERVER_IP" '{for (i = 1; i < NF; i++) if ($i == "inet") {split($(i + 1), a, "/"); if (a[1] == ip) {print $(i + 1); exit}}}')"
    [ -n "$cidr" ] || die "server address $SERVER_IP is not an IPv4 address on $MGMT_IF"
    prefix="${cidr#*/}"
    { [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -ge 1 ] && [ "$prefix" -le 32 ]; } || die "bad prefix length in '$cidr' on $MGMT_IF"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    net=$(( $(ip2int "$SERVER_IP") & mask ))
    MGMT_NET="$(int2ip "$net")/$prefix"

    # The rule admits only $MGMT_NET. A client outside it (routed in via a
    # gateway) would be cut off the moment UFW enables: refuse.
    [ $(( $(ip2int "$CLIENT_IP") & mask )) -eq "$net" ] \
        || die "SSH client $CLIENT_IP is outside $MGMT_NET on $MGMT_IF: the proposed rules would not admit this session"

    printf 'DISCOVERED  interface=%s subnet=%s ssh_port=%s (client %s:%s -> %s:%s)\n' \
        "$MGMT_IF" "$MGMT_NET" "$SSH_PORT" "$CLIENT_IP" "$CLIENT_PORT" "$SERVER_IP" "$SSH_PORT"
}

rule() { echo "ufw allow in on $MGMT_IF from $MGMT_NET to any port $1 proto tcp"; }

proposed() {
    echo "ufw default deny incoming"
    echo "ufw default allow outgoing"
    rule "$SSH_PORT"
    rule "$HTTPS_PORT"
}

# `ufw show added` lines, whitespace-normalised, one rule per line.
added_rules() { ufw show added 2>/dev/null | awk '$1 == "ufw" {$1 = $1; print}'; }

has_line() { grep -qxF "$1" <<< "$2"; }

# Rules present in `ufw show added` that are not ours.
extra_rules() {
    local r out=""
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ "$r" = "$(rule "$SSH_PORT")" ] || [ "$r" = "$(rule "$HTTPS_PORT")" ] || out+="$r"$'\n'
    done <<< "$1"
    printf '%s' "$out"
}

# ── the dead-man switch ──────────────────────────────────────────────────────

sleeper_pending() {
    local pid
    [ -r "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Kill a pending auto-revert sleeper, if any. Without this, apply/revert/apply
# leaves the FIRST sleeper alive and it fires later, disabling the current
# firewall behind the operator's back (the airgap-sim lesson, 2026-09-12). The
# sleeper is its own session, so killing the group takes the sleep and the shell.
# Returns 0 only if it killed a live sleeper: 1 means there was none to kill
# (never armed, or it already fired: it removes its pidfile, then disables).
cancel_sleeper() {
    local pid killed=1
    if [ -r "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE")"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null; then killed=0; fi
        fi
    fi
    rm -f "$PIDFILE" "$TIMER" "$ESTFILE" "$SSHPORTFILE"
    return "$killed"
}

arm_sleeper() {  # arm_sleeper MINUTES
    local secs=$(( $1 * 60 )) i=0 deadline launched
    cancel_sleeper
    deadline="$(date -d "+$1 minutes" +%s)" || return 1
    echo "$deadline" > "$TIMER" || return 1
    # The sleeper records its own session-leader PID and removes that record
    # before disabling, so nothing later mistakes a fired sleeper for a pending one.
    setsid bash -c "echo \$\$ > \"\$1\"; sleep \"\$2\"; rm -f \"\$1\" \"\$3\" \"\$4\" \"\$5\"; ufw --force disable" \
        r770-ufw-autorevert "$PIDFILE" "$secs" "$TIMER" "$ESTFILE" "$SSHPORTFILE" \
        </dev/null >/dev/null 2>&1 3>&- &
    launched=$!
    while [ ! -s "$PIDFILE" ] && [ "$i" -lt "$SLEEPER_WAIT_TICKS" ]; do sleep 0.02; i=$((i + 1)); done
    if [ ! -s "$PIDFILE" ]; then
        # Too slow to be trusted: take down whatever we launched so it cannot
        # start (and fire) later, unaccounted for.
        kill -- "-$launched" 2>/dev/null || kill "$launched" 2>/dev/null || true
        rm -f "$PIDFILE" "$TIMER"
        warn "auto-revert sleeper wrote no pidfile within $(( SLEEPER_WAIT_TICKS / 50 )) s; killed its process group ($launched)"
        return 1
    fi
    sleeper_pending
}

# Effective logind KillUserProcesses. The live value (busctl) wins; the file
# parse is the fallback when busctl is missing, fails, or answers oddly. Sets
# LOGIND_SRC to where the answer came from.
LOGIND_DROPIN_DIRS=(/etc /run /usr/local/lib /usr/lib)   # systemd's precedence, highest first
logind_kills_sleeper() {
    local out d f name names="" v="" line files=()
    if out="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager KillUserProcesses 2>/dev/null)"; then
        LOGIND_SRC="busctl, the live logind value"
        case "$out" in
            "b true")  return 0 ;;
            "b false") return 1 ;;
        esac
    fi
    # Fallback: the main file, then every drop-in name found in any of the
    # four directories — taken from the highest-precedence directory that has
    # it — in file-name order. Last setting wins.
    LOGIND_SRC="$LOGIND_ROOT/etc/systemd/logind.conf and logind.conf.d drop-ins (busctl unavailable)"
    for d in "${LOGIND_DROPIN_DIRS[@]}"; do
        for f in "$LOGIND_ROOT$d/systemd/logind.conf.d"/*.conf; do
            [ -e "$f" ] && names+="${f##*/}"$'\n'
        done
    done
    files=("$LOGIND_ROOT/etc/systemd/logind.conf")
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        for d in "${LOGIND_DROPIN_DIRS[@]}"; do
            f="$LOGIND_ROOT$d/systemd/logind.conf.d/$name"
            if [ -e "$f" ]; then files+=("$f"); break; fi
        done
    done < <(printf '%s' "$names" | sort -u)
    for f in "${files[@]}"; do
        [ -r "$f" ] || continue
        line="$(sed -n 's/^[[:space:]]*KillUserProcesses[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$f" | tail -1)"
        [ -z "$line" ] || v="$line"
    done
    case "${v,,}" in yes|true|on|1) return 0 ;; esac
    return 1
}

# Established sshd connections on port $1, as peer ip:port, one per line.
established_peers() {
    local out
    out="$(ss -Htn state established "( sport = :$1 )" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
    awk '{p = $4; if (p ~ /^\[::ffff:[0-9.]+\]:[0-9]+$/) {sub(/^\[::ffff:/, "", p); sub(/\]/, "", p)} if (p != "") print p}' <<< "$out" | sort -u
}

# Everything the switch needs, checked before ANY change (plan runs it too).
switch_preflight() {
    local peers
    ! logind_kills_sleeper \
        || die "logind has KillUserProcesses=yes (per $LOGIND_SRC): the auto-revert sleeper would die with this SSH session, leaving no dead-man switch"
    peers="$(established_peers "$SSH_PORT")" || die "ss could not list established connections on :$SSH_PORT: confirm could not prove a new session"
    has_line "$CLIENT_IP:$CLIENT_PORT" "$peers" \
        || die "this session ($CLIENT_IP:$CLIENT_PORT) is not an established connection on :$SSH_PORT per ss: SSH_CONNECTION cannot be trusted, and confirm could not prove a new session"
}

switch_arm() {  # switch_arm MINUTES STATE-IF-IT-FAILS
    arm_sleeper "$1" || fail "auto-revert sleeper did not start; $2"
    info "auto-revert armed: 'ufw --force disable' in $1 minute(s) (pid $(cat "$PIDFILE")) — fail-open, not a restore"
}

# After the enable: record who was already connected, then say what to do.
switch_finish() {  # switch_finish MINUTES
    local peers
    if ! peers="$(established_peers "$SSH_PORT")" || [ -z "$peers" ]; then
        fail "UFW is enabled but ss could not record the established sessions: confirm cannot work, the auto-revert is still armed and will fire (or run revert)"
    fi
    { printf '%s\n' "$peers" > "$ESTFILE" && echo "$SSH_PORT" > "$SSHPORTFILE"; } \
        || fail "UFW is enabled but $ESTFILE could not be written: the auto-revert is still armed and will fire (or run revert)"
    echo
    echo "################################################################################"
    echo "#  run 'r770-ufw.sh confirm' from a NEW ssh session within $1 minutes,"
    echo "#  or UFW turns itself off (fail-open: 'ufw --force disable', not a restore)"
    echo "#  do NOT reboot before confirm: a reboot loses the switch, UFW stays enabled"
    echo "################################################################################"
}

# ── verbs ────────────────────────────────────────────────────────────────────

cmd_plan() {
    need_root
    discover
    switch_preflight
    echo "== CURRENT (ufw status verbose) =="
    ufw status verbose 2>&1 || warn "ufw status failed"
    echo "== PROPOSED =="
    proposed | sed 's/^/  /'
    local extra; extra="$(extra_rules "$(added_rules)")"
    [ -z "$extra" ] || { warn "existing rules apply will NOT remove (verify fails on them):"; printf '%s' "$extra" | sed 's/^/  /'; }
    info "apply backs up $ETC_DIR, $DEFAULT_FILE and iptables-save to $BACKUP_DIR/<timestamp> first, and arms a dead-man switch that only 'confirm' from a NEW ssh session cancels"
    info "the switch runs 'ufw --force disable' after N minutes (default 10): it fails OPEN (no firewall), it does not restore the old rules — run revert for that"
    info "a reboot inside the window loses the switch while UFW stays enabled: do not reboot before confirm"
    info "plan changed nothing"
}

run_ufw() {
    if [ "$DRY" = 1 ]; then echo "ufw $*"; return 0; fi
    ufw "$@"
}

take_backup() {
    local dir pending=no
    umask 077
    sleeper_pending && pending=yes
    dir="$BACKUP_DIR/$(date +%Y%m%dT%H%M%S.%N)" || return 1
    mkdir -p "$BACKUP_DIR" && mkdir "$dir" || return 1
    tar -C "$(dirname "$ETC_DIR")" -czf "$dir/etc-ufw.tgz" "$(basename "$ETC_DIR")" || return 1
    [ -s "$dir/etc-ufw.tgz" ] || return 1
    cp "$ETC_DIR/ufw.conf" "$dir/ufw.conf" || return 1
    # `ufw default ...` writes DEFAULT_*_POLICY here, not under /etc/ufw.
    cp "$DEFAULT_FILE" "$dir/default-ufw" || return 1
    iptables-save > "$dir/iptables-save.txt" || return 1
    # A backup taken while an earlier apply is still unconfirmed holds THAT
    # apply's firewall, not the pre-apply state: revert skips it. (apply now
    # refuses while a switch is pending; this stays as a second line.)
    echo "taken_while_pending=$pending" > "$dir/meta" || return 1
    rm -f "$LAST_REVERT"
    echo "$dir"
}

cmd_apply() {
    local minutes=10 status added dir armfail
    while [ $# -gt 0 ]; do
        case $1 in
            --minutes)
                minutes="${2:-}"
                [[ "$minutes" =~ ^[0-9]+$ ]] || die "--minutes must be a whole number, got '$minutes'"
                { [ $((10#$minutes)) -ge 1 ] && [ $((10#$minutes)) -le 60 ]; } || die "--minutes must be 1-60, got '$minutes'"
                minutes=$((10#$minutes))
                shift ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done
    need_root
    discover

    # One switch at a time. Superseding would cancel the pending one before the
    # new one is proven to start, with UFW already enabled.
    ! sleeper_pending \
        || die "an auto-revert from an earlier apply/revert is still pending (fires at $(date -d "@$(cat "$TIMER" 2>/dev/null || echo 0)" 2>/dev/null)): run confirm from a NEW ssh session, or revert, then apply again"

    status="$(ufw status verbose 2>&1)" || die "ufw status failed: $status"
    added="$(added_rules)"
    if grep -q '^Status: active' <<< "$status" && grep -q 'deny (incoming)' <<< "$status" \
        && [ -n "$added" ] && [ "$(sort <<< "$added")" = "$(printf '%s\n%s\n' "$(rule "$SSH_PORT")" "$(rule "$HTTPS_PORT")" | sort)" ]; then
        echo "already applied: UFW active with exactly the management rules, no auto-revert pending"
        return 0
    fi

    switch_preflight

    # What an arm failure leaves behind depends on whether UFW was already on.
    if grep -q '^Status: active' <<< "$status"; then
        armfail="the two allow rules were added and are live (UFW was already active before apply); the default policy is unchanged and UFW's enabled state was not touched"
    else
        armfail="nothing changed beyond the two allow rules: the default policy is unchanged and UFW was NOT enabled"
    fi

    echo "== CURRENT =="; printf '%s\n' "$status"
    echo "== PROPOSED =="; proposed | sed 's/^/  /'
    [ -z "$(extra_rules "$added")" ] || warn "existing non-management rules stay in place (run plan to list them)"

    # A dropped session must not kill apply half way.
    trap '' HUP

    if [ "$DRY" = 1 ]; then
        info "dry run: no backup, no auto-revert sleeper"
    else
        dir="$(take_backup)" || fail "backup to $BACKUP_DIR failed; nothing changed in ufw"
        info "backup: $dir"
    fi

    # Allow rules FIRST, and read them back before anything can deny.
    run_ufw allow in on "$MGMT_IF" from "$MGMT_NET" to any port "$SSH_PORT" proto tcp \
        || fail "adding the SSH allow rule failed; default policy and enable untouched"
    run_ufw allow in on "$MGMT_IF" from "$MGMT_NET" to any port "$HTTPS_PORT" proto tcp \
        || fail "adding the 443 allow rule failed; default policy and enable untouched"
    if [ "$DRY" != 1 ]; then
        added="$(added_rules)"
        { has_line "$(rule "$SSH_PORT")" "$added" && has_line "$(rule "$HTTPS_PORT")" "$added"; } \
            || fail "allow rules not visible in 'ufw show added'; default policy and enable untouched. Got:"$'\n'"$added"
        info "allow rules confirmed in 'ufw show added'"

        # Dead-man switch BEFORE the deny: if anything below cuts us off, it still fires.
        switch_arm "$minutes" "$armfail"
    fi

    run_ufw default deny incoming   || fail "ufw default deny incoming failed; auto-revert still armed"
    run_ufw default allow outgoing  || fail "ufw default allow outgoing failed; auto-revert still armed"
    run_ufw --force enable          || fail "ufw --force enable failed; auto-revert still armed"

    [ "$DRY" = 1 ] || switch_finish "$minutes"
}

cmd_confirm() {
    need_root
    local port recorded now status
    sleeper_pending || die "no auto-revert pending: nothing to confirm (if apply ran, the sleeper may already have fired: check 'ufw status')"
    need_conn "confirm must run from a NEW ssh session"
    parse_conn
    port="$(cat "$SSHPORTFILE" 2>/dev/null)"
    { [ -r "$ESTFILE" ] && [ -n "$port" ]; } \
        || die "no established-session record from the enable ($ESTFILE): cannot prove this is a new session (if apply is still running, wait for its banner)"
    recorded="$(cat "$ESTFILE")"
    [ "$SSH_PORT" = "$port" ] || die "this session is on port $SSH_PORT, not the sshd port $port the policy was applied for"
    ! has_line "$CLIENT_IP:$CLIENT_PORT" "$recorded" \
        || die "this session ($CLIENT_IP:$CLIENT_PORT) was already open when UFW was enabled: confirm from a session opened AFTER apply"
    now="$(established_peers "$port")" || die "ss could not list established connections on :$port: cannot prove a new session"
    has_line "$CLIENT_IP:$CLIENT_PORT" "$now" \
        || die "this session ($CLIENT_IP:$CLIENT_PORT) is not an established connection on :$port per ss: confirm from a session opened AFTER apply"
    # The switch was pending at the top. If there is no live sleeper to kill
    # now, it fired in between: it removes its pidfile, then disables UFW.
    cancel_sleeper \
        || fail "the auto-revert fired during confirm; UFW is being disabled — re-run apply"
    # Belt and braces: it may have fired after the kill check and before the kill.
    status="$(ufw status 2>&1)"
    grep -q '^Status: active' <<< "$status" \
        || fail "the switch fired; UFW is disabled — re-run apply (ufw status: $(head -1 <<< "$status"))"
    echo "UFW confirmed; auto-revert cancelled"
}

# Newest backup that holds a pre-apply state.
restore_source() {
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        grep -qx 'taken_while_pending=no' "$BACKUP_DIR/$d/meta" 2>/dev/null && { echo "$BACKUP_DIR/$d"; return 0; }
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
    return 1
}

ufw_active() { ufw status 2>/dev/null | grep -q '^Status: active'; }

# The recorded revert is done only if nothing is pending and UFW is in the
# state its backup had: a revert whose re-enable failed, or whose switch fired,
# is not done, and revert must be able to run again.
revert_done() {
    local rec
    [ -s "$LAST_REVERT" ] || return 1
    ! sleeper_pending || return 1
    rec="$(cat "$LAST_REVERT")"
    [ -r "$rec/ufw.conf" ] || return 1
    if grep -q '^ENABLED=yes' "$rec/ufw.conf"; then ufw_active; else ! ufw_active; fi
}

cmd_revert() {
    need_root
    local src enable=no have_default=yes
    if revert_done; then
        echo "already reverted (from $(cat "$LAST_REVERT")); no apply since"
        return 0
    fi
    src="$(restore_source)" || die "no pre-apply backup under $BACKUP_DIR: nothing to revert to"
    { [ -s "$src/etc-ufw.tgz" ] && [ -r "$src/ufw.conf" ]; } || die "backup $src is incomplete"
    # Backups taken before default-ufw was captured (d9581cb) lack it.
    [ -r "$src/default-ufw" ] || have_default=no
    if grep -q '^ENABLED=yes' "$src/ufw.conf"; then
        [ "$have_default" = yes ] \
            || die "backup $src has no default-ufw (taken before /etc/default/ufw was captured): re-enabling on its rules with today's default policy is not a revert — refused"
        # Re-enabling a restored ruleset is a firewall change like apply: it
        # needs the same discovery, the same switch and a confirm.
        enable=yes
        discover
        switch_preflight
    fi
    info "restoring from $src"
    trap '' HUP
    rm -f "$LAST_REVERT"
    ufw --force disable || fail "ufw --force disable failed; nothing restored"
    tar -C "$(dirname "$ETC_DIR")" -xzf "$src/etc-ufw.tgz" \
        || fail "restoring $ETC_DIR from $src failed; UFW is DISABLED"
    if [ "$have_default" = yes ]; then
        cp "$src/default-ufw" "$DEFAULT_FILE" \
            || fail "restoring $DEFAULT_FILE from $src failed; UFW is DISABLED"
    else
        warn "backup $src predates default-ufw capture: $DEFAULT_FILE was not captured and is left as is"
    fi
    if [ "$enable" = yes ]; then
        switch_arm "$REVERT_MINUTES" "restored $ETC_DIR and $DEFAULT_FILE, UFW left DISABLED; revert can be run again"
        ufw --force enable || fail "restored $ETC_DIR but ufw --force enable failed; auto-revert still armed; revert can be run again"
        # Only now is the revert done (revert_done still re-checks UFW's state).
        echo "$src" > "$LAST_REVERT"
        info "backup had ENABLED=yes: UFW re-enabled on the restored rules, under the dead-man switch"
        echo "reverted to $src"
        switch_finish "$REVERT_MINUTES"
    else
        cancel_sleeper || true
        echo "$src" > "$LAST_REVERT"
        info "backup had UFW disabled: left disabled"
        echo "reverted to $src; auto-revert cancelled"
    fi
}

is_loopback() {
    case $1 in
        127.*|'[::1]'|'[::ffff:127.'*) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_verify() {
    need_root
    discover
    local fails=0 status added extra listeners line local_addr addr port proc offenders="" nat rc dnat_bad=""
    pass()  { printf 'PASS    %s\n' "$*"; }
    vfail() { printf 'FAIL    %s\n' "$*"; fails=$((fails + 1)); }

    status="$(ufw status verbose 2>&1)"
    if grep -q '^Status: active' <<< "$status"; then pass "ufw is active"; else vfail "ufw is not active"; fi
    if grep -q 'deny (incoming)' <<< "$status"; then pass "default incoming is deny"; else vfail "default incoming is not deny"; fi
    added="$(added_rules)"
    for port in "$SSH_PORT" "$HTTPS_PORT"; do
        if has_line "$(rule "$port")" "$added"; then pass "rule: $(rule "$port")"; else vfail "missing rule: $(rule "$port")"; fi
    done
    extra="$(extra_rules "$added")"
    if [ -z "$extra" ]; then pass "no other allow rules"; else vfail "rules beyond the management policy:"$'\n'"$extra"; fi

    if sleeper_pending; then
        warn "auto-revert still pending (fires at $(date -d "@$(cat "$TIMER" 2>/dev/null || echo 0)" 2>/dev/null)): run confirm from a new ssh session"
    else
        pass "no auto-revert pending"
    fi

    # Docker-published ports bypass UFW (DNAT happens before the INPUT chain),
    # so a non-loopback docker-proxy listener is a hole: FAIL. Host services
    # (dnsmasq on the R770 package set, say) ARE filtered by UFW: WARN only.
    # Without process info the two cannot be told apart: FAIL.
    listeners="$(ss -H -ltnp 2>&1)" || { vfail "ss -H -ltnp failed: $listeners"; listeners=""; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local_addr="$(awk '{print $4}' <<< "$line")"
        port="${local_addr##*:}"
        addr="${local_addr%:*}"
        addr="${addr%%\%*}"
        is_loopback "$addr" && continue
        proc="$(sed -n 's/.*users:((\"\([^"]*\)\".*/\1/p' <<< "$line")"
        if [ -z "$proc" ]; then
            offenders+="$local_addr "
            printf 'FAIL    non-loopback listener %s shows no process (ss -p needs root)\n' "$local_addr"
        elif [ "$proc" = docker-proxy ]; then
            offenders+="$local_addr "
            printf 'FAIL    docker-proxy publishes %s past UFW\n' "$local_addr"
        else
            case $port in 22|"$SSH_PORT"|"$HTTPS_PORT") continue ;; esac
            warn "non-loopback listener $local_addr ($proc): filtered by UFW"
        fi
    done <<< "$listeners"
    if [ -z "$offenders" ]; then pass "no docker-proxy or unidentified non-loopback listeners"; else fails=$((fails + 1)); fi

    # With userland-proxy:false there is no docker-proxy to see, only DNAT
    # rules. Any DNAT in Docker's nat chain not pinned to -d 127.0.0.1/32 is
    # published on a reachable address, past UFW.
    nat="$(iptables -t nat -S DOCKER 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        if grep -qi 'no chain' <<< "$nat"; then
            pass "no Docker nat chain: nothing published by DNAT"
        else
            vfail "iptables -t nat -S DOCKER failed (exit $rc): $nat"
        fi
    else
        while IFS= read -r line; do
            [[ "$line" == *" -j DNAT"* ]] || continue
            if [[ " $line " == *" -d 127.0.0.1/32 "* ]] && [[ " $line " != *" ! -d 127.0.0.1/32 "* ]]; then continue; fi
            dnat_bad+="$line"$'\n'
            printf 'FAIL    Docker DNAT not restricted to 127.0.0.1 (published past UFW): %s\n' "$line"
        done <<< "$nat"
        if [ -z "$dnat_bad" ]; then pass "every Docker DNAT rule is restricted to 127.0.0.1"; else fails=$((fails + 1)); fi
    fi

    if [ "$fails" -eq 0 ]; then echo "RESULT: PASS"; return 0; fi
    echo "RESULT: FAIL ($fails)"
    return 1
}

case "${1:-plan}" in
    plan)    shift $(( $# > 0 ? 1 : 0 )); [ $# -eq 0 ] || usage; cmd_plan ;;
    apply)   shift; cmd_apply "$@" ;;
    confirm) shift; [ $# -eq 0 ] || usage; cmd_confirm ;;
    verify)  shift; [ $# -eq 0 ] || usage; cmd_verify ;;
    revert)  shift; [ $# -eq 0 ] || usage; cmd_revert ;;
    *)       usage ;;
esac
