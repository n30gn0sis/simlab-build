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
