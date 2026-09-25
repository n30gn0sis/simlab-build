#!/usr/bin/env bash
#
# r770-staging-vm.sh — drive staging VM 9770 on the Proxmox host, from the
# Claude Code session's LXC. Never runs on the VM or the R770.
#
#   status              power state, uptime and snapshot names
#   rollback <snap>     stop the VM if running, then roll back to <snap>
#   start | stop        power, waiting for the Proxmox task to finish
#                       (stop = ACPI shutdown, forced after 120 s)
#   wait-ssh [secs]     wait until the VM answers SSH (default 300 s)
#
# The target is fixed: node proxmox, VMID 9770. The API token (scoped by its
# role to /vms/9770 only) is read from a mode-600 file outside the repo, and
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
VM_HOST="${STAGING_VM_HOST:-ubuntu@192.168.4.72}"
POLL="${STAGING_POLL_SECS:-2}"
TRIES="${STAGING_TASK_TRIES:-300}"
NODE=proxmox
VMID=9770
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
    curl -sS --fail --cacert "$CA" -X "$method" \
        -H "Authorization: PVEAPIToken=$TOKEN" "$@" "$PVE_URL$path"
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
print("vm 9770:", d.get("status"), "uptime", d.get("uptime", 0))' <<< "$out"
    out=$(api GET "$BASE/snapshot") || die "could not list snapshots"
    python3 -c 'import json,sys
names = [s["name"] for s in json.load(sys.stdin)["data"] if s["name"] != "current"]
print("snapshots:", " ".join(names) if names else "(none)")' <<< "$out"
}

cmd_start() {
    [ "$(vm_state)" = running ] && { echo "vm 9770 already running"; return 0; }
    post_task "$BASE/status/start"
    echo "vm 9770 started"
}

cmd_stop() {
    [ "$(vm_state)" = stopped ] && { echo "vm 9770 already stopped"; return 0; }
    post_task "$BASE/status/shutdown" -d timeout=120 -d forceStop=1
    echo "vm 9770 stopped"
}

cmd_rollback() {
    local snap=${1:-}
    [ -n "$snap" ] || die "rollback needs a snapshot name"
    cmd_stop
    post_task "$BASE/snapshot/$snap/rollback"
    echo "vm 9770 rolled back to $snap"
}

cmd_wait_ssh() {
    local secs=${1:-300} end
    end=$((SECONDS + secs))
    while [ "$SECONDS" -lt "$end" ]; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM_HOST" true 2>/dev/null; then
            echo "ssh to $VM_HOST is up"
            return 0
        fi
        sleep "$POLL"
    done
    die "ssh to $VM_HOST not up after ${secs}s"
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
