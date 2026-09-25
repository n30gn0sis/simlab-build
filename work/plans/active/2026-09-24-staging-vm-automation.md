# Staging VM 9770 — rebuild, scoped access, automated rehearsals — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** VM 9770 rebuilt to its recorded spec with a clean snapshot, a token scoped to 9770 only, a tested driver script, and one full cut + import rehearsal run from this session with its evidence recorded.

**Architecture:** Task 1 is repo code (driver + tests + credential guard), suitable for a subagent. Tasks 2–5 act on the Proxmox host and the VM with credentials, so **the controller runs them inline**; no subagent ever receives the root password or the token. Root@pam is used only in Tasks 2–4, through a session ticket held in a shell variable. After Task 4 everything goes through the scoped token.

**Tech Stack:** bash, bats, shellcheck, curl + the Proxmox VE 9.2 REST API, python3 (JSON), gpg, OpenSSH, cloud-init.

**Spec:** `docs/superpowers/specs/2026-09-24-staging-vm-automation-design.md`

## Global Constraints

- VM spec owner: `state/inventory/staging-vm-9770.md`. Rebuild to it exactly; reference it, don't restate its figures elsewhere.
- Target is always node `proxmox`, VMID `9770`. Never touch guests 100, 101, 104, 106, 108 or 128, and **never start 100 or 108 during a run** (build record watch list).
- Root credentials: used only in Tasks 2–4, held only in a shell variable for one command, never written to a file, log, commit or subagent prompt. Remind the operator to change the password afterwards.
- Token: `claude-staging@pve!lxc101`, role `SimlabStaging` = `VM.Audit,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback`, ACL `/vms/9770` only. Secret only in `/root/.config/simlab/pve-token` (mode 0600). Never printed.
- TLS to Proxmox is verified with the pinned leaf certificate `/root/.config/simlab/pve-ca.pem` (the API serves only its leaf; curl 8.5 accepts it as a partial-chain anchor, checked 2026-09-24). Never `-k` once the pin exists.
- Snapshot `clean-2026-09-24`: taken cold (VM stopped), no `vmstate`.
- The bundle never transits the host filesystem: it is built and rehearsed inside the VM only.
- Rehearsal cuts are **test cuts, not for transfer**. Manual-item stand-ins are named `SYNTHETIC-*`.
- New scripts must be shellcheck-clean with **no exclusions**. `git add` before `./tests/run.sh`, which must be green before each commit.
- Commit messages end with the attribution lines from the session's system reminder.
- `$SCRATCH` = this session's scratchpad directory (`/tmp/claude-0/-root-git-simlab-build/<session>/scratchpad`); evidence is collected there before it is written into `state/`.

## File map

| File | Task | Responsibility |
|---|---|---|
| `scripts/r770-staging-vm.sh` | 1 | Driver: status / rollback / start / stop / wait-ssh for VM 9770 |
| `tests/staging-vm.bats` | 1 | Stubbed curl/ssh tests |
| `tests/no-credentials.bats` | 1 | Also reject tracked PVE/GitHub token secrets |
| `tests/lint.bats`, `tests/README.md`, `README.md` | 1 | Register |
| `state/inventory/staging-vm-9770.md` | 2–4 | "Rebuilt 2026-09-24" section |
| `state/inventory/staging-rehearsal-<date>.md` | 5 | Rehearsal evidence |
| `state/inventory/bundles.md`, `state/BUILD-STATE.md` | 4, 5 | Staging row, cycle log (test cut) |
| outside the repo: `/root/.ssh/id_ed25519_staging{,.pub}`, `/root/.config/simlab/{pve-token,pve-ca.pem}` | 2, 4 | Session key, token, pinned cert |

---

### Task 1: The driver script, its tests, and the credential guard

**Files:**
- Create: `scripts/r770-staging-vm.sh` (0755), `tests/staging-vm.bats`
- Modify: `tests/no-credentials.bats` (append one test), `tests/lint.bats:10`, `tests/README.md`, `README.md`

**Interfaces:**
- Produces: CLI `r770-staging-vm.sh status | rollback <snap> | start | stop | wait-ssh [secs]`. Exit 0 ok / 1 refused or failed (message on stderr prefixed `staging-vm:`). Env overrides `STAGING_PVE_URL`, `STAGING_PVE_TOKEN_FILE`, `STAGING_PVE_CA`, `STAGING_VM_HOST`, `STAGING_POLL_SECS`, `STAGING_TASK_TRIES`. Defaults: `https://192.168.4.21:8006/api2/json`, `/root/.config/simlab/pve-token`, `/root/.config/simlab/pve-ca.pem`, `ubuntu@192.168.4.28`.

- [ ] **Step 1: Write the tests** — create `tests/staging-vm.bats`:

```bash
#!/usr/bin/env bats
#
# r770-staging-vm.sh drives a real VM on a hypervisor that also hosts other
# guests, so these tests pin the target (every call is node proxmox, VMID 9770),
# the ordering (a running VM is stopped before a rollback), task-failure
# handling, and that the API token is never printed.
#
# curl and ssh are stubs. curl answers from a small state directory ($S):
#   $S/state   the VM's power state (running|stopped)
#   $S/exit    the exitstatus every task ends with (default OK)
#   $S/calls   "METHOD URL" for every API call

SECRET="11111111-2222-3333-4444-555555555555"

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-staging-vm.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"; mkdir -p "$BIN" "$REAL" "$S"
    for t in bash env python3 stat head sleep cat; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    export STAGING_PVE_URL="https://pve.test:8006/api2/json"
    export STAGING_PVE_TOKEN_FILE="$BATS_TEST_TMPDIR/pve-token"
    export STAGING_PVE_CA="$BATS_TEST_TMPDIR/pve-ca.pem"
    export STAGING_VM_HOST="ubuntu@vm.test"
    export STAGING_POLL_SECS=0 STAGING_TASK_TRIES=5
    printf 'claude-staging@pve!lxc101=%s\n' "$SECRET" > "$STAGING_PVE_TOKEN_FILE"
    chmod 600 "$STAGING_PVE_TOKEN_FILE"
    echo "fake ca" > "$STAGING_PVE_CA"
    echo stopped > "$S/state"

    stub curl '
m=GET; prev=""; u=""
for a; do [ "$prev" = -X ] && m=$a; prev=$a; u=$a; done
echo "$m $u" >> "$S/calls"
[ -f "$S/curl_fail" ] && { echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; }
case "$m $u" in
  "GET "*/status/current) printf "{\"data\":{\"status\":\"%s\",\"uptime\":42}}\n" "$(cat "$S/state")" ;;
  "GET "*/snapshot) echo "{\"data\":[{\"name\":\"clean-2026-09-24\"},{\"name\":\"current\"}]}" ;;
  "GET "*/tasks/*/status) printf "{\"data\":{\"status\":\"stopped\",\"exitstatus\":\"%s\"}}\n" "$(cat "$S/exit" 2>/dev/null || echo OK)" ;;
  "POST "*/status/start) echo running > "$S/state"; echo "{\"data\":\"UPID:proxmox:1:qmstart\"}" ;;
  "POST "*/status/shutdown) echo stopped > "$S/state"; echo "{\"data\":\"UPID:proxmox:2:qmshutdown\"}" ;;
  "POST "*/rollback) echo "{\"data\":\"UPID:proxmox:3:qmrollback\"}" ;;
  *) echo "unexpected $m $u" >&2; exit 22 ;;
esac'
    stub ssh 'n=$(cat "$S/ssh_n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$S/ssh_n"; [ "$n" -ge "$(cat "$S/ssh_ok_at" 2>/dev/null || echo 1)" ]'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

svm() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

every_call_targets_9770() {
    ! grep -vE '^(GET|POST) https://pve\.test:8006/api2/json/nodes/proxmox/(qemu/9770/|tasks/)' "$S/calls"
}

@test "status prints power state and snapshot names, only for VM 9770" {
    run svm status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"vm 9770: stopped"* ]]
    [[ "$output" == *"snapshots: clean-2026-09-24"* ]]
    every_call_targets_9770
}

@test "start on a stopped VM posts start and waits for the task" {
    run svm start
    [ "$status" -eq 0 ]
    grep -q '^POST .*/qemu/9770/status/start$' "$S/calls"
    grep -q '^GET .*/tasks/UPID:proxmox:1:qmstart/status$' "$S/calls"
    every_call_targets_9770
}

@test "start on a running VM does nothing" {
    echo running > "$S/state"
    run svm start
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    ! grep -q '^POST' "$S/calls"
}

@test "rollback stops a running VM before rolling back" {
    echo running > "$S/state"
    run svm rollback clean-2026-09-24
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    [ "$(grep '^POST' "$S/calls" | sed 's|.*/qemu/9770/||')" = "status/shutdown
snapshot/clean-2026-09-24/rollback" ]
    every_call_targets_9770
}

@test "rollback on a stopped VM goes straight to the rollback" {
    run svm rollback clean-2026-09-24
    [ "$status" -eq 0 ]
    [ "$(grep -c '^POST' "$S/calls")" -eq 1 ]
    grep -q '^POST .*/snapshot/clean-2026-09-24/rollback$' "$S/calls"
}

@test "rollback needs a snapshot name" {
    run svm rollback
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a snapshot name"* ]]
    [ ! -s "$S/calls" ]
}

@test "a task that does not end OK fails the command" {
    echo "command 'qm start' failed: exit code 1" > "$S/exit"
    run svm start
    [ "$status" -eq 1 ]
    [[ "$output" == *"ended with: command 'qm start' failed"* ]]
}

@test "refuses a missing token file without calling the API" {
    rm "$STAGING_PVE_TOKEN_FILE"
    run svm status
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
    [ ! -s "$S/calls" ]
}

@test "refuses a token file readable by others" {
    chmod 644 "$STAGING_PVE_TOKEN_FILE"
    run svm status
    [ "$status" -eq 1 ]
    [[ "$output" == *"mode 644"* ]]
    [ ! -s "$S/calls" ]
}

@test "the token secret never appears in output, even when the API fails" {
    run svm status
    [[ "$output" != *"$SECRET"* ]]
    touch "$S/curl_fail"
    run svm rollback clean-2026-09-24
    [ "$status" -eq 1 ]
    [[ "$output" != *"$SECRET"* ]]
}

@test "wait-ssh returns once ssh answers" {
    echo 3 > "$S/ssh_ok_at"
    run svm wait-ssh 30
    [ "$status" -eq 0 ]
    [ "$(cat "$S/ssh_n")" -eq 3 ]
}

@test "wait-ssh gives up after its timeout" {
    echo 999999 > "$S/ssh_ok_at"
    run svm wait-ssh 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"not up after 1s"* ]]
}

@test "refuses an unknown command" {
    run svm destroy
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}
```

- [ ] **Step 2: Run — expect failure.** `bats tests/staging-vm.bats` → all 13 FAIL (script missing).

- [ ] **Step 3: Write the script** — create `scripts/r770-staging-vm.sh`, `chmod 0755`:

```bash
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
VM_HOST="${STAGING_VM_HOST:-ubuntu@192.168.4.28}"
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
```

- [ ] **Step 4: Run — expect pass.** `bats tests/staging-vm.bats` → 13/13.

- [ ] **Step 5: Credential guard.** Append to `tests/no-credentials.bats`:

```bash
@test "no API token secret is tracked (Proxmox or GitHub)" {
    cd "$BATS_TEST_DIRNAME/.."
    run git grep -nE 'PVEAPIToken=[^ "$]+=[0-9a-f]{8}-[0-9a-f]{4}-|![a-z0-9]+=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|github_pat_[A-Za-z0-9_]{30,}|ghp_[A-Za-z0-9]{30,}' -- ':!tests/'
    [ "$status" -ne 0 ]
}
```
Prove it bites before relying on it: `printf 'x!lxc101=11111111-2222-3333-4444-555555555555\n' > /tmp/guard-probe.md && cp /tmp/guard-probe.md docs/guard-probe.md && git add docs/guard-probe.md && bats tests/no-credentials.bats -f 'API token'` → FAIL; then `git rm -f --cached docs/guard-probe.md && rm docs/guard-probe.md` and re-run → PASS.

- [ ] **Step 6: Register.**
  - `tests/lint.bats` line 10 → `    run shellcheck scripts/r770-bundle.sh scripts/r770-storage-apply.sh scripts/r770-phase3-run.sh scripts/r770-staging-vm.sh tests/run.sh`
  - `tests/README.md`: `Fourteen suites.` → `Fifteen suites.`; add row
    `| `staging-vm.bats` | `r770-staging-vm.sh` against stubbed curl/ssh: every API call targets node proxmox / VMID 9770, rollback stops a running VM first, a task not ending OK fails, a missing or world-readable token file is refused, and the token secret is never printed |`
  - `README.md` "What's here", after the `r770-phase3-run.sh` row:
    `| `scripts/r770-staging-vm.sh` | Drives staging VM 9770 on the Proxmox host from the Claude session (`status`, `rollback <snap>`, `start`, `stop`, `wait-ssh`) with a token scoped to that VM only; never runs on the VM or the R770 |`

- [ ] **Step 7: Suite + commit.** `git add scripts/r770-staging-vm.sh tests/staging-vm.bats tests/no-credentials.bats tests/lint.bats tests/README.md README.md && ./tests/run.sh` → green; commit `"Add r770-staging-vm.sh — scoped-token driver for staging VM 9770; guard against tracked token secrets"`.

---

### Task 2: Rebuild VM 9770 (controller only — root, one-time)

**Files:** none in the repo yet (evidence collected to the scratchpad for Task 4).

**Interfaces:** Produces VM 9770 running from the pinned image with this session's key; `/root/.ssh/id_ed25519_staging`; the VM's host-key fingerprint.

- [ ] **Step 1: Pre-flight (read-only).** Log in with a ticket held in a shell variable only:
```bash
PVE=https://192.168.4.21:8006/api2/json
TICKET=$(curl -sk -d username=root@pam --data-urlencode "password=$PW" $PVE/access/ticket | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];print(d["ticket"]+"\n"+d["CSRFPreventionToken"])')
```
(`$PW` set in the same command line from the operator's message; never exported, never echoed.) Confirm: 9770 absent (`GET /nodes/proxmox/qemu/9770/status/current` → error), guests 100 and 108 stopped, `local-lvm` used % and `local` avail recorded, `local` content includes `import`. Any surprise → stop and ask.

- [ ] **Step 2: Verify the image in this session.**
```bash
U=https://cloud-images.ubuntu.com/releases/noble/release-20260826
W=$SCRATCH/img && mkdir -p $W && cd $W
curl -fsSO $U/SHA256SUMS && curl -fsSO $U/SHA256SUMS.gpg
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81
gpg --verify SHA256SUMS.gpg SHA256SUMS            # must say "Good signature" from the UEC key with that fingerprint
SUM=$(awk '$2=="*ubuntu-24.04-server-cloudimg-amd64.img"{print $1}' SHA256SUMS); echo "$SUM"
```
Fingerprint must equal the one in `staging-vm-9770.md`. Save the verify output.

- [ ] **Step 3: Download onto the host with Proxmox checking the hash.** `POST /nodes/proxmox/storage/local/download-url` with `content=import`, `filename=noble-cloudimg-20260826.qcow2`, `url=$U/ubuntu-24.04-server-cloudimg-amd64.img`, `checksum=$SUM`, `checksum-algorithm=sha256`; poll the returned task to `OK`. (The file is qcow2 despite the `.img` name; the `.qcow2` filename makes Proxmox import it as such.)

- [ ] **Step 4: Session SSH key.** `ssh-keygen -t ed25519 -N '' -C claude-lxc101-staging-2026-09-24 -f /root/.ssh/id_ed25519_staging`, and add to `/root/.ssh/config`:
```
Host 192.168.4.28
    User ubuntu
    IdentityFile /root/.ssh/id_ed25519_staging
    IdentitiesOnly yes
```

- [ ] **Step 5: Create the VM** — `POST /nodes/proxmox/qemu` with, per the build record: `vmid=9770 name=r770-staging ostype=l26 cpu=host cores=6 numa=0 memory=8192 balloon=0 scsihw=virtio-scsi-single scsi0=local-lvm:0,import-from=local:import/noble-cloudimg-20260826.qcow2,discard=on,ssd=1,iothread=1,backup=0,mbps_wr=250,mbps_wr_max=400 ide2=local-lvm:cloudinit boot=order=scsi0 net0=virtio=BC:24:11:97:70:01,bridge=vmbr0 serial0=socket agent=1 onboot=0 ciuser=ubuntu ipconfig0=ip=dhcp sshkeys=<url-encoded /root/.ssh/id_ed25519_staging.pub>` (`--data-urlencode` for `sshkeys`; Proxmox requires it double-encoded — encode the key once with `python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.stdin.read().strip(), safe=""))'` and pass that via `--data-urlencode`). Poll to `OK`. Then `PUT /nodes/proxmox/qemu/9770/resize` `disk=scsi0 size=400G`. Compare `GET .../config` against every row of the build record's as-built table; any mismatch → fix before start.

- [ ] **Step 6: Start and reach it.** `POST .../status/start`, poll `OK`; wait for `ssh 192.168.4.28 true` (accept-new host key on first contact); record `ssh-keyscan -t ed25519 192.168.4.28 | ssh-keygen -lf -` as the new host-key fingerprint.

---

### Task 3: Provision, re-run the record's gates, cold snapshot (controller)

**Interfaces:** Consumes Task 2's VM. Produces snapshot `clean-2026-09-24`.

- [ ] **Step 1: Provision** over SSH (as the build record's "Installed" section):
```bash
ssh 192.168.4.28 'set -e
sudo apt-get update && sudo apt-get -y install ca-certificates curl gnupg pigz jq rsync wget unzip qemu-guest-agent tmux git
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ubuntu
sudo fallocate -l 8G /swap.img && sudo chmod 600 /swap.img && sudo mkswap /swap.img && sudo swapon /swap.img
echo "/swap.img none swap sw 0 0" | sudo tee -a /etc/fstab
sudo systemctl enable --now qemu-guest-agent fstrim.timer docker'
```
- [ ] **Step 2: Gates** (each output saved): `systemd-detect-virt` = kvm; `lsblk` + `df -h /` shows the root grown to ~the full 400 GiB; `/` free ≥ 150 G; `docker run --rm hello-world`; `docker pull ubuntu:24.04 && docker pull python:3.12-slim`; in-container apt egress `docker run --rm ubuntu:24.04 bash -c 'apt-get update >/dev/null && echo ok'`; `command -v pigz`; `swapon --show`; `systemctl is-enabled fstrim.timer`; `docker version --format '{{.Server.Version}}'`.
- [ ] **Step 3: Clean for the snapshot:** `docker system prune -a -f` (removes the gate images — the cut pulls its own), `sudo apt-get clean`, `history -c`. Then `POST .../status/shutdown` (timeout 120) → poll `OK` → `GET .../status/current` = stopped.
- [ ] **Step 4: Snapshot:** `POST /nodes/proxmox/qemu/9770/snapshot` with `snapname=clean-2026-09-24`, `vmstate=0`, `description=Rebuilt 2026-09-24; Docker CE + helpers; session key; no bundle, no images`. Poll `OK`. `GET .../snapshot` lists it.

---

### Task 4: Scoped token, pinned cert, driver smoke test, record (controller)

**Files:** Modify `state/inventory/staging-vm-9770.md`, `state/BUILD-STATE.md`.

- [ ] **Step 1: Pin the certificate.** `echo | openssl s_client -connect 192.168.4.21:8006 2>/dev/null | openssl x509 > /root/.config/simlab/pve-ca.pem` (mkdir -p, mode 0644). Record its SHA-256 fingerprint (`openssl x509 -noout -fingerprint -sha256`) and confirm it equals `GET /nodes/proxmox/certificates/info` → `pve-ssl.pem` fingerprint (root-authenticated call, so the pin is proven against the host's own view).
- [ ] **Step 2: Role, user, token, ACLs** (root ticket + CSRF header):
  - `POST /access/roles` `roleid=SimlabStaging privs=VM.Audit,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback`
  - `POST /access/users` `userid=claude-staging@pve comment=Claude session LXC 101 - staging VM 9770 only`
  - `POST /access/users/claude-staging@pve/token/lxc101` `privsep=1 comment=staging VM 9770` → capture `data.value` straight into the file, never to the terminal: `umask 077; … | python3 -c '…print("claude-staging@pve!lxc101="+d["value"])' > /root/.config/simlab/pve-token`
  - `PUT /access/acl` `path=/vms/9770 roles=SimlabStaging users=claude-staging@pve`
  - `PUT /access/acl` `path=/vms/9770 roles=SimlabStaging tokens=claude-staging@pve!lxc101`
- [ ] **Step 3: Smoke test with the token only** (drop the root ticket: `unset TICKET PW`):
```bash
./scripts/r770-staging-vm.sh status        # vm 9770: stopped · snapshots: clean-2026-09-24
curl -sS --cacert /root/.config/simlab/pve-ca.pem -H "Authorization: PVEAPIToken=$(cat /root/.config/simlab/pve-token)" \
  https://192.168.4.21:8006/api2/json/nodes/proxmox/qemu/101/status/current -o /dev/null -w '%{http_code}\n'   # must be 403
```
The second call proves the scope: the token cannot read another guest.
- [ ] **Step 4: Record.** `state/inventory/staging-vm-9770.md` — new section "Rebuilt 2026-09-24": why (VM found absent), image verify output (fingerprint + `sha256sum` line), the config diff check result, host-key fingerprint, gate table with results, snapshot name/time/cold/no-vmstate, access model (user/role/ACL/token id — **no secret**), pinned-cert fingerprint, and that the root password must be rotated. Mark the old `pre-fetch` snapshot, the LXC-101 `claude-lxc101-rehearsal` key and the 2026-09-11 password as gone with the old VM. `BUILD-STATE.md`: staging-host row updated (rebuilt 2026-09-24, snapshot `clean-2026-09-24`, driven by `scripts/r770-staging-vm.sh`) and a log entry. `git add` → `./tests/run.sh` → commit `"Rebuild staging VM 9770; scoped token; clean snapshot"`.

---

### Task 5: First automated cut + import rehearsal (controller)

**Files:** Create `state/inventory/staging-rehearsal-<date>.md`; modify `state/inventory/bundles.md`, `state/BUILD-STATE.md`.

- [ ] **Step 1: Pre-run.** `r770-staging-vm.sh status` (expect stopped, snapshot `clean-2026-09-24` listed). The token cannot see other guests or host memory, so ask the operator to confirm VMs 100 and 108 stay stopped for the run. Then `rollback clean-2026-09-24 && start && wait-ssh 300`.
- [ ] **Step 2: Cut** (inside the VM; `tmux` so an SSH drop cannot kill it):
```bash
ssh 192.168.4.28 'git clone https://github.com/n30gn0sis/simlab-build.git ~/simlab-build && cd ~/simlab-build && git log --oneline -1'
ssh 192.168.4.28 'cd ~/simlab-build && ./scripts/r770-staging-preflight.sh; echo "preflight exit=$?"' | tee $SCRATCH/preflight.log
ssh 192.168.4.28 "tmux new -d -s cut 'cd ~/simlab-build && sudo -E ./scripts/r770-build-bundle.sh 2>&1 | tee ~/cut.log; echo \"cut exit=\${PIPESTATUS[0]}\" >> ~/cut.log'"
```
Poll `ssh 192.168.4.28 'tail -3 ~/cut.log'` every few minutes from a background loop. **At the manual-items pause** (the log shows the builder waiting): `ssh 192.168.4.28 'B=$(ls -d ~/simlab-build/bundle-* | tail -1); echo synthetic > $B/dell/SYNTHETIC-dell-placeholder.txt; echo synthetic > $B/gns3/appliances/SYNTHETIC-appliance-placeholder.txt'`, then send the builder's continue keystroke with `tmux send-keys -t cut Enter` (read the builder's prompt text first and match what it asks for). Wait for `cut exit=`.
- [ ] **Step 3: Collect cut evidence:** `scp 192.168.4.28:cut.log $SCRATCH/`; `grep -E 'WARN|FAIL' bundle-*/BUNDLE_NOTES.md`; `du -sh` and `find -type f | wc -l` of the bundle. Exit 1 → stop, debug from the log (superpowers:systematic-debugging). Exit 2 → disposition each WARN in the evidence file (expected: the synthetic manual items).
- [ ] **Step 4: Import rehearsal** (install runbook Parts 1.2–1.4 and 3, the VM standing in for the R770; `/data/staging` is a plain directory here):
```bash
ssh 192.168.4.28 'set -u; B=$(ls -d ~/simlab-build/bundle-* | tail -1); N=$(basename $B)
cd $B && ./r770-bundle.sh verify .; echo "verify-src exit=$?"
sudo mkdir -p /data/staging && sudo cp -a $B /data/staging/
cd /data/staging/$N && ./r770-bundle.sh verify .; echo "verify-copy exit=$?"
sudo mkdir -p /srv/repo && sudo cp -a /data/staging/$N/apt /srv/repo/ && ls /srv/repo/apt/Packages.gz
sudo tar czf /root/apt-sources-rehearsal.tar.gz /etc/apt/sources.list /etc/apt/sources.list.d/
sudo mv /etc/apt/sources.list.d /etc/apt/sources.list.d.upstream && sudo mkdir -p /etc/apt/sources.list.d
sudo sh -c ": > /etc/apt/sources.list"
echo "deb [trusted=yes] file:/srv/repo/apt ./" | sudo tee /etc/apt/sources.list.d/r770-local.list
sudo apt-get update 2>&1 | tee ~/apt-update.log
apt-cache policy docker-ce | head -8
sudo apt-get install --dry-run docker-ce 2>&1 | tail -5' 2>&1 | tee $SCRATCH/import.log
```
Pass criteria: both verify exits 0 or 2 (same WARNs as the cut); `apt update` output names only `file:/srv/repo/apt`; `docker-ce` candidate from `file:/srv/repo/apt ./`; dry run resolves without error. (Part 3.4's snapd purge / motd changes are skipped on the staging VM — it is not the R770 and rolls back anyway; note this in the evidence.)
- [ ] **Step 5: Stop.** `r770-staging-vm.sh stop`.
- [ ] **Step 6: Record.** `state/inventory/staging-rehearsal-<date>.md`: VM snapshot used, repo commit cut from, preflight exit, cut exit + summary, WARN list with dispositions, size + file count, verify exits (source, copy), APT before/after, `apt update` / policy / dry-run output, what was skipped and why, **"TEST CUT — NOT FOR TRANSFER; manual items were SYNTHETIC"** in the first line. `bundles.md`: cycle row marked test cut (size/count recorded here, their owner). `BUILD-STATE.md` log entry. `git add` → `./tests/run.sh` → commit `"First automated cut + import rehearsal on rebuilt VM 9770 (test cut, not for transfer)"`.
