#!/usr/bin/env bash
# scen-events.sh — timed event engine for scen-run (spec §8.4). SOURCED, not executed:
# defining the functions has no side effects.
#   events_run <events.yaml> <t0_epoch>
# The whole list is validated before the first event runs; a bad event dies the run
# up front. A failing event is logged "FAILED rc=<n>" and the run continues — the
# captures are the product, the log is the evidence.
# Uses from the caller: log die guard_iface (scen-lib.sh), SCEN_EXEC, APPLIED.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/scen-lib.sh"

SCEN_EXEC="${SCEN_EXEC:-docker exec -i}"
EV_SEP=$'\x1f'      # field separator: not whitespace, so empty fields survive `read`

# events_dump <file> — one event per line: t US action US key=value US key=value …
# Accepts a top-level list, or a mapping with an `events:` list.
events_dump() {
    python3 -I - "$1" <<'PY' || return 1
import sys, yaml
SEP = '\x1f'
d = yaml.safe_load(open(sys.argv[1]))
if isinstance(d, dict):
    d = d.get('events')
if d is None:
    d = []
if not isinstance(d, list):
    sys.exit('events must be a list')
for i, e in enumerate(d, 1):
    if not isinstance(e, dict):
        sys.exit(f'event {i}: not a mapping')
    t, act = e.get('t'), e.get('action')
    f = ['true' if isinstance(t, bool) else str(t), str(act)]
    for k, v in e.items():
        if k in ('t', 'action'):
            continue
        s = str(v)
        if SEP in s or '\n' in s or '\r' in s:
            sys.exit(f'event {i}: {k} contains a control character')
        f.append(f'{k}={s}')
    print(SEP.join(f))
PY
}

# ev_arg <key> — value of key in the current event's fields (EV_F); empty if absent.
ev_arg() {
    local f
    for f in "${EV_F[@]:2}"; do
        [ "${f%%=*}" = "$1" ] && { printf '%s' "${f#*=}"; return 0; }
    done
    return 0
}
ev_require() {  # ev_require <n> <key>…
    local n="$1" k; shift
    for k in "$@"; do
        [ -n "$(ev_arg "$k")" ] || die "event $n (${EV_F[1]}): missing $k"
    done
}

# events_validate <dump> — dies on the first problem; executes nothing.
events_validate() {
    local line n=0 prev=0 t a target
    while IFS= read -r line; do
        n=$((n + 1))
        IFS="$EV_SEP" read -r -a EV_F <<< "$line"
        t="${EV_F[0]}"; a="${EV_F[1]:-}"
        [[ "$t" =~ ^[0-9]+$ ]] || die "event $n: t must be a non-negative integer (got '$t')"
        t=$((10#$t))
        [ "$t" -ge "$prev" ] || die "event $n: t=$t is earlier than the previous event (t=$prev)"
        prev="$t"
        case "$a" in
            note)   ev_require "$n" text ;;
            link-down|link-up)
                ev_require "$n" target
                target=$(ev_arg target)
                [[ "$target" =~ ^[^:]+:[^:]+$ ]] || die "event $n ($a): target must be <bridge>:<port> (got '$target')"
                guard_iface "${target%%:*}" || exit 1
                guard_iface "${target#*:}" || exit 1 ;;
            wan-apply) ev_require "$n" profile iface; guard_iface "$(ev_arg iface)" || exit 1 ;;
            wan-clear) ev_require "$n" iface; guard_iface "$(ev_arg iface)" || exit 1 ;;
            exec)   ev_require "$n" node cmd ;;
            gns3-link-suspend|gns3-link-resume) ;;
            *) die "event $n: unknown action $a" ;;
        esac
    done <<< "$1"
}

# events_forget <iface> — drop iface from APPLIED once it is cleared.
events_forget() {
    local i keep=''
    for i in ${APPLIED:-}; do [ "$i" = "$1" ] || keep="$keep $i"; done
    APPLIED="$keep"
}

# events_exec_one — run the event in EV_F; always returns 0.
events_exec_one() {
    local t="${EV_F[0]}" a="${EV_F[1]}" rc=0 args='' f target iface
    for f in "${EV_F[@]:2}"; do args="$args $f"; done
    case "$a" in
        gns3-link-suspend|gns3-link-resume)
            log "event t=$t $a unsupported until O4 — skipped"; return 0 ;;
    esac
    log "event t=$t $a${args}"
    case "$a" in
        note) ;;
        link-down|link-up)
            target=$(ev_arg target)
            ip link set "${target#*:}" "${a#link-}" || rc=$? ;;
        wan-apply)
            iface=$(ev_arg iface)
            # Recorded before the apply: a half-applied qdisc must still be cleared.
            APPLIED="${APPLIED:-} $iface"
            wan-apply "$(ev_arg profile)" "$iface" || rc=$? ;;
        wan-clear)
            iface=$(ev_arg iface)
            wan-clear "$iface" && events_forget "$iface" || rc=$? ;;
        exec)
            # shellcheck disable=SC2086  # SCEN_EXEC is word-split on purpose
            $SCEN_EXEC "$(ev_arg node)" sh -c "$(ev_arg cmd)" || rc=$? ;;
    esac
    [ "$rc" -eq 0 ] || log "event t=$t $a FAILED rc=$rc"
    return 0
}

events_run() {
    local file="$1" t0="$2" dump line now delay
    [ -f "$file" ] || die "no such events file: $file"
    [[ "$t0" =~ ^[0-9]+$ ]] || die "events_run: t0 must be an epoch (got '$t0')"
    dump=$(events_dump "$file") || die "cannot read events: $file"
    [ -n "$dump" ] || return 0
    events_validate "$dump"
    while IFS= read -r line; do
        IFS="$EV_SEP" read -r -a EV_F <<< "$line"
        EV_F[0]=$((10#${EV_F[0]}))
        now=$(date +%s)
        delay=$((t0 + EV_F[0] - now))
        if [ "$delay" -gt 0 ]; then sleep "$delay"; fi
        events_exec_one
    done <<< "$dump"
}
