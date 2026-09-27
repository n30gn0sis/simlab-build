#!/usr/bin/env bash
#
# r770-staging-vm.sh — drive a staging VM (9770 or 9771) on the Proxmox host, from the
# Claude Code session's LXC. Never runs on the VM or the R770.
#
#   status              power state, uptime and snapshot names
#   rollback <snap>     stop the VM if running, then roll back to <snap>
#   start | stop        power, waiting for the Proxmox task to finish
#                       (stop = ACPI shutdown, forced after 120 s)
#   wait-ssh [secs]     wait until the VM answers SSH (default 300 s)
#
# The target is pinned: node proxmox, VMID 9770 by default, or 9771 with
# STAGING_VMID=9771 — nothing else (9771 is a clone for a second session,
# 2026-09-25). The API token (scoped by its role to /vms/9770 and /vms/9771 only) is read from a mode-600 file outside the repo, and
# the Proxmox CA is pinned rather than skipped with -k.
#
# Design: docs/superpowers/specs/2026-09-24-staging-vm-automation-design.md
# VM spec owner: state/inventory/staging-vm-9770.md
#
# Test overrides: STAGING_PVE_URL, STAGING_PVE_TOKEN_FILE, STAGING_PVE_CA,
# STAGING_VM_HOST, STAGING_POLL_SECS, STAGING_TASK_TRIES.
set -uo pipefail

PVE_URL="${STAGING_PVE_URL:-https://192.168.4.21:8006/api2/json}"
TOKEN_FILE="${STAGING_PVE_TOKEN_FILE:-/root/.config/simlab/pve-token}"
CA="${STAGING_PVE_CA:-/root/.config/simlab/pve-ca.pem}"
POLL="${STAGING_POLL_SECS:-2}"
TRIES="${STAGING_TASK_TRIES:-300}"
NODE=proxmox
VMID="${STAGING_VMID-9770}"
case "$VMID" in
    9770) DEFAULT_HOST="ubuntu@192.168.4.78" ;;   # DHCP reservation for BC:24:11:97:70:01 (operator, 2026-09-25)
    9771) DEFAULT_HOST="ubuntu@192.168.4.26" ;;   # DHCP reservation for BC:24:11:E7:AF:99 (operator, 2026-09-26)
    *)    printf 'staging-vm: STAGING_VMID must be 9770 or 9771, got "%s"\n' "$VMID" >&2; exit 1 ;;
esac
VM_HOST="${STAGING_VM_HOST:-$DEFAULT_HOST}"
BASE="/nodes/$NODE/qemu/$VMID"
TOKEN=""

die() { printf 'staging-vm: %s\n' "$*" >&2; exit 1; }

load_token() {
    local mode
    [ -f "$TOKEN_FILE" ] || die "token file $TOKEN_FILE not found"
    mode=$(stat -c %a "$TOKEN_FILE")
    case "$mode" in 600|400) ;; *) die "token file $TOKEN_FILE is mode $mode — must be 600 or 400" ;; esac
    TOKEN=$(head -n1 "$TOKEN_FILE")
    [[ "$TOKEN" == *@*'!'*=* ]] || die "token file is not in user@realm!tokenid=secret form"
    [ -f "$CA" ] || die "Proxmox CA $CA not found"
}

api() {  # api METHOD PATH [extra curl args] -> response JSON on stdout
    local method=$1 path=$2
    shift 2
    curl -sS --fail --cacert "$CA" -X "$method" -K - "$@" "$PVE_URL$path" \
        <<< "header = \"Authorization: PVEAPIToken=$TOKEN\""
}

# jfield KEY — print data[KEY] (or data itself when KEY is empty) from JSON on stdin
jfield() {
    python3 -c 'import json,sys
d = json.load(sys.stdin)["data"]
k = sys.argv[1]
print(d if k == "" else d.get(k, ""))' "$1"
}

vm_state() {
    local out
    out=$(api GET "$BASE/status/current") || die "could not read VM $VMID status"
    jfield status <<< "$out"
}

wait_task() {  # wait_task UPID — returns once the task stopped with exitstatus OK
    local upid=$1 out st es i
    for ((i = 0; i < TRIES; i++)); do
        out=$(api GET "/nodes/$NODE/tasks/$upid/status") || die "could not read task $upid"
        st=$(jfield status <<< "$out")
        if [ "$st" = stopped ]; then
            es=$(jfield exitstatus <<< "$out")
            [ "$es" = OK ] || die "task $upid ended with: $es"
            return 0
        fi
        sleep "$POLL"
    done
    die "task $upid did not finish after $TRIES polls"
}

post_task() {  # post_task PATH [curl -d args] — POST, then wait for the returned task
    local path=$1 out upid
    shift
    out=$(api POST "$path" "$@") || die "POST $path failed"
    upid=$(jfield "" <<< "$out")
    [ -n "$upid" ] || die "POST $path returned no task id"
    wait_task "$upid"
}

cmd_status() {
    local out
    out=$(api GET "$BASE/status/current") || die "could not read VM $VMID status"
    python3 -c 'import json,sys
d = json.load(sys.stdin)["data"]
print("vm " + sys.argv[1] + ":", d.get("status"), "uptime", d.get("uptime", 0))' "$VMID" <<< "$out"
    out=$(api GET "$BASE/snapshot") || die "could not list snapshots"
    python3 -c 'import json,sys
names = [s["name"] for s in json.load(sys.stdin)["data"] if s["name"] != "current"]
print("snapshots:", " ".join(names) if names else "(none)")' <<< "$out"
}

cmd_start() {
    local st
    st=$(vm_state) || exit 1
    [ "$st" = running ] && { echo "vm $VMID already running"; return 0; }
    post_task "$BASE/status/start"
    echo "vm $VMID started"
}

cmd_stop() {
    local st
    st=$(vm_state) || exit 1
    [ "$st" = stopped ] && { echo "vm $VMID already stopped"; return 0; }
    post_task "$BASE/status/shutdown" -d timeout=120 -d forceStop=1
    echo "vm $VMID stopped"
}

cmd_rollback() {
    local snap=${1:-}
    [ -n "$snap" ] || die "rollback needs a snapshot name"
    [[ "$snap" =~ ^[A-Za-z][A-Za-z0-9_-]{0,39}$ ]] || die "invalid snapshot name: $snap"
    cmd_stop
    post_task "$BASE/snapshot/$snap/rollback"
    echo "vm $VMID rolled back to $snap"
}

cmd_wait_ssh() {
    local secs=${1:-300} end last_err=""
    [ -n "$VM_HOST" ] || die "no default host for VM $VMID — set STAGING_VM_HOST=ubuntu@<address>"
    end=$((SECONDS + secs))
    while [ "$SECONDS" -lt "$end" ]; do
        if last_err=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM_HOST" true 2>&1 1>/dev/null); then
            echo "ssh to $VM_HOST is up"
            return 0
        fi
        sleep "$POLL"
    done
    die "ssh to $VM_HOST not up after ${secs}s${last_err:+: $last_err}"
}

case "${1:-}" in
    status|start|stop|rollback|wait-ssh) ;;
    *) die "usage: $0 status | rollback <snap> | start | stop | wait-ssh [secs]" ;;
esac
cmd=$1
shift
if [ "$cmd" = wait-ssh ]; then
    cmd_wait_ssh "$@"
    exit $?
fi
load_token
case "$cmd" in
    status)   cmd_status ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    rollback) cmd_rollback "$@" ;;
esac
