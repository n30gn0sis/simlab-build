#!/usr/bin/env bash
# scen-lib.sh — shared functions for the reference-PCAP harness (spec §8).
# Sourced by scen-prep, scen-run, scen-check, scen-ingest, scen-clear. No side
# effects at source time. Every path is an env var with a default so bats can
# redirect it.
set -euo pipefail

SCEN_REPO="${SCEN_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCEN_PROFILES="${SCEN_PROFILES:-$SCEN_REPO/scenarios/profiles}"
SCEN_CASES="${SCEN_CASES:-/data/pcap/cases}"
SCEN_CAPTURE_PORTS="${SCEN_CAPTURE_PORTS:-}"      # Phase 9 list, space-separated
SCEN_LOG="${SCEN_LOG:-}"

log() {  # UTC with milliseconds, to stdout and (if set) $SCEN_LOG — spec §8.5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    printf '%s %s\n' "$ts" "$*"
    if [ -n "$SCEN_LOG" ]; then printf '%s %s\n' "$ts" "$*" >> "$SCEN_LOG"; fi
}
die() { echo "ERROR: $*" >&2; exit 1; }

# profile_load <name> — exports P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE
profile_load() {
    local f="$SCEN_PROFILES/$1.conf" k v line
    [ -f "$f" ] || die "no such profile: $1 ($f)"
    P_RATE_DOWN='' P_RATE_UP='' P_DELAY='' P_JITTER='' P_LOSS='' P_NOTE=''
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        case "$k" in
            RATE_DOWN|RATE_UP|DELAY|JITTER|LOSS|NOTE) printf -v "P_$k" '%s' "$v" ;;
            *) die "profile $1: unknown key $k" ;;
        esac
    done < "$f"
    export P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE
}

# guard_iface <iface> — CLAUDE.md rule 8 / spec §6.1: lab segments only.
guard_iface() {
    local i="$1" p
    for p in $SCEN_CAPTURE_PORTS; do
        [ "$i" = "$p" ] && { echo "refused: $i is a capture port" >&2; return 1; }
    done
    case "$i" in
        br-lab-t[0-9][0-9]|br-lab-i[0-9][0-9]|br-lab-ext|veth-*) return 0 ;;
        *) echo "refused: $i is not a lab transit/inner bridge or veth (mgmt, capture, mirror and host bridges are off limits)" >&2; return 1 ;;
    esac
}

# manifest_get <run.yaml> <a.b.c> — scalar on stdout; exit 1 if the path is absent, empty for null.
manifest_get() {
    python3 -I - "$1" "$2" <<'PY' || return 1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    if not isinstance(d, dict) or k not in d: sys.exit(1)
    d = d[k]
print('' if d is None else d)
PY
}
# manifest_list <run.yaml> <list-key> <field> — one value per list item.
manifest_list() {
    python3 -I - "$1" "$2" "$3" <<'PY' || return 1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])).get(sys.argv[2]) or []
for item in d: print(item.get(sys.argv[3], ''))
PY
}
# manifest_set_json <run.yaml> <json-patch> — merge a patch into the manifest in place.
# Keys: times_utc / results (dicts, merged key by key) and node_digests ({node: digest},
# set as nodes[].digest by name). Fails (and leaves the file untouched) on any error.
manifest_set_json() {
    python3 -I - "$1" "$2" <<'PY' || return 1
import json, os, sys, yaml
path, patch = sys.argv[1], json.loads(sys.argv[2])
d = yaml.safe_load(open(path))
for k, v in patch.items():
    if k == 'node_digests':
        for n in d.get('nodes') or []:
            if n.get('name') in v: n['digest'] = v[n['name']]
    else:
        if not isinstance(d.get(k), dict): d[k] = {}
        d[k].update(v)
d_, b_ = os.path.split(path)
tmp = os.path.join(d_, '.' + b_ + '.tmp')
try:
    with open(tmp, 'w') as f: yaml.safe_dump(d, f, sort_keys=False, allow_unicode=True)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp): os.remove(tmp)
    raise
PY
}
run_dir_for() {
    local sc id
    sc=$(manifest_get "$1" scenario) || return 1
    id=$(manifest_get "$1" run_id) || return 1
    echo "$SCEN_CASES/$sc/$id"
}
