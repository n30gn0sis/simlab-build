#!/usr/bin/env bash
#
# r770-ufw.sh — host firewall for the analyst stack: deny incoming by default,
# allow SSH and 443/tcp ONLY on the management interface, from the management
# subnet. Runs ON the target box (VM 9771 for the proof run, the R770 later), as
# root, from an SSH session.
#
#   plan                 default. Read-only: discovered management path, current
#                        `ufw status verbose`, the proposed ruleset
#   apply [--minutes N]  back up, add the allow rules, arm the dead-man switch,
#                        then deny-by-default and enable. N = 1-60, default 10
#   confirm              run from a NEW ssh session: cancels the auto-revert
#   verify               read-only: UFW active, both allow rules present, default
#                        incoming deny, no pending auto-revert, and no
#                        docker-proxy (or unidentified) non-loopback listener;
#                        other host listeners beyond :22/:443 WARN (UFW filters them)
#   revert               restore /etc/ufw from the newest pre-apply backup and
#                        cancel any pending auto-revert
#
#   0  done, nothing to do, or every check passed
#   1  refused (REFUSE: nothing changed), failed (FAIL: the output says what
#      changed and what is still armed), or a verify check failed
#
# LOSING SSH IS THE WORST FAILURE, so:
#   - nothing is guessed: the management interface, subnet and SSH port come from
#     the live session ($SSH_CONNECTION -> `ip route get` -> `ip addr`). Any gap,
#     or a client that the proposed rule would NOT admit, is a REFUSE;
#   - the allow rules are added and read back from `ufw show added` before the
#     default policy changes or UFW is enabled;
#   - the auto-revert sleeper (`ufw --force disable` after N minutes) is armed
#     BEFORE the deny policy and the enable, so a dropped session or a dying
#     script mid-apply still undoes itself. SIGHUP is ignored during apply;
#   - confirm refuses from the session that ran apply: only a NEW connection
#     proves the firewall admits new SSH connections.
#
# The detached sleeper is the pattern from scripts/r770-airgap-sim.sh, including
# its lesson: a pending sleeper is cancelled before a new one is armed, or the
# first one fires later and silently undoes the current state.
#
# Design: docs/superpowers/specs/2026-09-26-analyst-stack-design.md
#         ("scripts/r770-ufw.sh plan | apply | confirm | verify | revert")
#
# Test overrides: UFW_RUN_DIR (default /run), UFW_BACKUP_DIR (default
# /var/backups/r770-ufw), UFW_ETC_DIR (default /etc/ufw), UFW_SSH_CONNECTION
# (default $SSH_CONNECTION; set-but-empty counts as empty), UFW_DRY_RUN=1 prints
# the ufw commands (and skips backup and sleeper) instead of running them.
set -uo pipefail
export LC_ALL=C

RUN_DIR="${UFW_RUN_DIR:-/run}"
BACKUP_DIR="${UFW_BACKUP_DIR:-/var/backups/r770-ufw}"
ETC_DIR="${UFW_ETC_DIR:-/etc/ufw}"
CONN="${UFW_SSH_CONNECTION-${SSH_CONNECTION:-}}"
DRY="${UFW_DRY_RUN:-0}"
MARK="r770-ufw"
PIDFILE="$RUN_DIR/$MARK.pid"            # the detached auto-revert sleeper
TIMER="$RUN_DIR/$MARK.deadline"         # epoch seconds when it fires
PORTFILE="$RUN_DIR/$MARK.client-port"   # client port of the session that ran apply
LAST_REVERT="$BACKUP_DIR/last-revert"   # set by revert, cleared by apply
HTTPS_PORT=443

die()  { printf 'REFUSE  %s\n' "$*" >&2; exit 1; }   # before any change
fail() { printf 'FAIL    %s\n' "$*" >&2; exit 1; }   # a mutating step failed
info() { printf 'INFO    %s\n' "$*"; }
warn() { printf 'WARN    %s\n' "$*"; }

usage() { die "usage: r770-ufw.sh [plan | apply [--minutes N] | confirm | verify | revert]"; }

need_root() { [ "$(id -u 2>/dev/null)" = 0 ] || die "must run as root (ufw, /etc/ufw, $RUN_DIR)"; }

# ── discovery ────────────────────────────────────────────────────────────────

is_ipv4() {
    local IFS=. o
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    for o in $1; do [ $((10#$o)) -le 255 ] || return 1; done
}

ip2int() { local IFS=. a b c d; read -r a b c d <<< "$1"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ $((10#$1)) -ge 1 ] && [ $((10#$1)) -le 65535 ]; }

# Sets CLIENT_IP CLIENT_PORT SERVER_IP SSH_PORT MGMT_IF MGMT_NET, or refuses.
discover() {
    local extra route cidr prefix mask net
    [ -n "$CONN" ] || die "SSH_CONNECTION is empty: run this from an SSH session (the management path is read from it, never guessed)"
    read -r CLIENT_IP CLIENT_PORT SERVER_IP SSH_PORT extra <<< "$CONN"
    { [ -n "${SSH_PORT:-}" ] && [ -z "${extra:-}" ]; } || die "SSH_CONNECTION is not 'client_ip client_port server_ip server_port': '$CONN'"
    { is_ipv4 "$CLIENT_IP" && is_ipv4 "$SERVER_IP"; } || die "SSH_CONNECTION is not an IPv4 session ('$CONN'); IPv6 management is not supported"
    { is_port "$CLIENT_PORT" && is_port "$SSH_PORT"; } || die "SSH_CONNECTION has a bad port: '$CONN'"

    route="$(ip -o route get "$CLIENT_IP" 2>/dev/null)" || die "ip route get $CLIENT_IP failed"
    MGMT_IF="$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<< "$route")"
    [ -n "$MGMT_IF" ] || die "no 'dev' in 'ip route get $CLIENT_IP' output: $route"
    [ "$MGMT_IF" != lo ] || die "the SSH client $CLIENT_IP routes via lo: not a management session"
    [[ "$MGMT_IF" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || die "unexpected interface name '$MGMT_IF'"

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

has_rule() { grep -qxF "$1" <<< "$2"; }

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
cancel_sleeper() {
    local pid
    if [ -r "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE")"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$PIDFILE" "$TIMER" "$PORTFILE"
}

arm_sleeper() {  # arm_sleeper MINUTES
    local secs=$(( $1 * 60 )) i=0 deadline
    cancel_sleeper
    deadline="$(date -d "+$1 minutes" +%s)" || return 1
    echo "$deadline" > "$TIMER" || return 1
    echo "$CLIENT_PORT" > "$PORTFILE" || return 1
    # The sleeper records its own session-leader PID and removes that record
    # before disabling, so nothing later mistakes a fired sleeper for a pending one.
    setsid bash -c "echo \$\$ > \"\$1\"; sleep \"\$2\"; rm -f \"\$1\" \"\$3\" \"\$4\"; ufw --force disable" \
        r770-ufw-autorevert "$PIDFILE" "$secs" "$TIMER" "$PORTFILE" \
        </dev/null >/dev/null 2>&1 3>&- &
    while [ ! -s "$PIDFILE" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
    sleeper_pending
}

# ── verbs ────────────────────────────────────────────────────────────────────

cmd_plan() {
    need_root
    discover
    echo "== CURRENT (ufw status verbose) =="
    ufw status verbose 2>&1 || warn "ufw status failed"
    echo "== PROPOSED =="
    proposed | sed 's/^/  /'
    local extra; extra="$(extra_rules "$(added_rules)")"
    [ -z "$extra" ] || { warn "existing rules apply will NOT remove (verify fails on them):"; printf '%s' "$extra" | sed 's/^/  /'; }
    info "apply backs up $ETC_DIR and iptables-save to $BACKUP_DIR/<timestamp> first, and arms a 'ufw --force disable' after N minutes (default 10) that only 'confirm' from a NEW ssh session cancels"
    info "plan changed nothing"
}

run_ufw() {
    if [ "$DRY" = 1 ]; then echo "ufw $*"; return 0; fi
    ufw "$@"
}

take_backup() {
    local dir pending=no
    sleeper_pending && pending=yes
    dir="$BACKUP_DIR/$(date +%Y%m%dT%H%M%S.%N)" || return 1
    mkdir -p "$BACKUP_DIR" && mkdir "$dir" || return 1
    tar -C "$(dirname "$ETC_DIR")" -czf "$dir/etc-ufw.tgz" "$(basename "$ETC_DIR")" || return 1
    [ -s "$dir/etc-ufw.tgz" ] || return 1
    cp "$ETC_DIR/ufw.conf" "$dir/ufw.conf" || return 1
    iptables-save > "$dir/iptables-save.txt" || return 1
    # A backup taken while an earlier apply is still unconfirmed holds THAT
    # apply's firewall, not the pre-apply state: revert skips it.
    echo "taken_while_pending=$pending" > "$dir/meta" || return 1
    rm -f "$LAST_REVERT"
    echo "$dir"
}

cmd_apply() {
    local minutes=10 status added dir
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

    status="$(ufw status verbose 2>&1)" || die "ufw status failed: $status"
    added="$(added_rules)"
    if grep -q '^Status: active' <<< "$status" && grep -q 'deny (incoming)' <<< "$status" \
        && [ -n "$added" ] && [ "$(sort <<< "$added")" = "$(printf '%s\n%s\n' "$(rule "$SSH_PORT")" "$(rule "$HTTPS_PORT")" | sort)" ] \
        && ! sleeper_pending; then
        echo "already applied: UFW active with exactly the management rules, no auto-revert pending"
        return 0
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
        { has_rule "$(rule "$SSH_PORT")" "$added" && has_rule "$(rule "$HTTPS_PORT")" "$added"; } \
            || fail "allow rules not visible in 'ufw show added'; default policy and enable untouched. Got:"$'\n'"$added"
        info "allow rules confirmed in 'ufw show added'"

        # Dead-man switch BEFORE the deny: if anything below cuts us off, it still fires.
        arm_sleeper "$minutes" || fail "auto-revert sleeper did not start; allow rules added but the default policy is unchanged and UFW was NOT enabled"
        info "auto-revert armed: 'ufw --force disable' in $minutes minute(s) (pid $(cat "$PIDFILE"))"
    fi

    run_ufw default deny incoming   || fail "ufw default deny incoming failed; auto-revert still armed"
    run_ufw default allow outgoing  || fail "ufw default allow outgoing failed; auto-revert still armed"
    run_ufw --force enable          || fail "ufw --force enable failed; auto-revert still armed"

    echo
    echo "################################################################################"
    echo "#  run 'r770-ufw.sh confirm' from a NEW ssh session within $minutes minutes,"
    echo "#  or UFW turns itself off"
    echo "################################################################################"
}

cmd_confirm() {
    need_root
    local port recorded
    sleeper_pending || die "no auto-revert pending: nothing to confirm (if apply ran, the sleeper may already have fired: check 'ufw status')"
    [ -n "$CONN" ] || die "SSH_CONNECTION is empty: confirm must run from a NEW ssh session"
    read -r _ port _ <<< "$CONN"
    recorded="$(cat "$PORTFILE" 2>/dev/null)"
    [ -n "$recorded" ] || die "no client port recorded at apply time ($PORTFILE): cannot prove this is a new session"
    [ "$port" != "$recorded" ] || die "this is the session that ran apply (client port $port): open a NEW ssh session and confirm from there"
    cancel_sleeper
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

cmd_revert() {
    need_root
    local src
    if [ -s "$LAST_REVERT" ] && ! sleeper_pending; then
        echo "already reverted (from $(cat "$LAST_REVERT")); no apply since"
        return 0
    fi
    src="$(restore_source)" || die "no pre-apply backup under $BACKUP_DIR: nothing to revert to"
    { [ -s "$src/etc-ufw.tgz" ] && [ -r "$src/ufw.conf" ]; } || die "backup $src is incomplete"
    info "restoring from $src"
    ufw --force disable || fail "ufw --force disable failed; nothing restored"
    tar -C "$(dirname "$ETC_DIR")" -xzf "$src/etc-ufw.tgz" \
        || fail "restoring $ETC_DIR from $src failed; UFW is DISABLED"
    if grep -q '^ENABLED=yes' "$src/ufw.conf"; then
        ufw --force enable || fail "restored $ETC_DIR but ufw --force enable failed; UFW is DISABLED"
        info "backup had ENABLED=yes: UFW re-enabled on the restored rules"
    else
        info "backup had UFW disabled: left disabled"
    fi
    cancel_sleeper
    echo "$src" > "$LAST_REVERT"
    echo "reverted to $src; auto-revert cancelled"
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
    local fails=0 status added extra listeners line local_addr addr port proc offenders=""
    pass()  { printf 'PASS    %s\n' "$*"; }
    vfail() { printf 'FAIL    %s\n' "$*"; fails=$((fails + 1)); }

    status="$(ufw status verbose 2>&1)"
    if grep -q '^Status: active' <<< "$status"; then pass "ufw is active"; else vfail "ufw is not active"; fi
    if grep -q 'deny (incoming)' <<< "$status"; then pass "default incoming is deny"; else vfail "default incoming is not deny"; fi
    added="$(added_rules)"
    for port in "$SSH_PORT" "$HTTPS_PORT"; do
        if has_rule "$(rule "$port")" "$added"; then pass "rule: $(rule "$port")"; else vfail "missing rule: $(rule "$port")"; fi
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
