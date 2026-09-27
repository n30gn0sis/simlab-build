#!/usr/bin/env bats
#
# r770-ufw.sh changes firewall policy on a box reached only over SSH, so what
# matters most is: nothing is guessed, the allow rules land before anything can
# deny, the dead-man switch is armed before the deny, and it can only be
# cancelled from a NEW session.
#
# ufw, ip, ss, iptables-save, tar, id, sleep and setsid are stubs backed by a
# state directory ($S). The script sees ONLY the stubs plus a fixed list of real
# tools, so the test host's firewall can never answer (or be changed).
#
#   $S/active                present = ufw active
#   $S/def_in, $S/def_out    default policies (deny / allow)
#   $S/added                 `ufw show added` rule lines
#   $S/allow_noop            present = `ufw allow` succeeds but records nothing
#   $S/enable_rc             exit code for `ufw --force enable` (default 0)
#   $S/route, $S/route_fail  `ip route get` output override / make it fail
#   $S/addr                  `ip -o -4 addr show dev <if>` output
#   $S/ss                    `ss -H -ltn` output
#   $S/sleep_fast            present = the sleeper's long sleep lasts 1.5 s
#   $S/calls                 every mutating call, in order
#
# The sleeper tests run the real detached-sleeper code path (as the airgap-sim
# tests do) with the run dir relocated into $BATS_TEST_TMPDIR; the sleep stub
# makes the "N minutes" a real 600 s sleep that teardown kills.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-ufw.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export UFW_RUN_DIR="$BATS_TEST_TMPDIR/run"
    export UFW_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
    export UFW_ETC_DIR="$BATS_TEST_TMPDIR/etc/ufw"
    export UFW_SSH_CONNECTION="10.10.10.5 50001 10.10.10.31 22"
    export FAKE_UID=0
    unset UFW_DRY_RUN
    mkdir -p "$BIN" "$REAL" "$S" "$UFW_RUN_DIR" "$UFW_ETC_DIR"
    for t in bash env awk sed grep tr cat cp mv mkdir ls date head tail rm sort find dirname basename wc touch cut; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    export REAL_SLEEP REAL_SETSID
    REAL_SLEEP=$(command -v sleep); REAL_SETSID=$(command -v setsid)
    TEST_PATH="$BIN:$REAL"

    echo "ENABLED=no" > "$UFW_ETC_DIR/ufw.conf"
    echo deny > "$S/def_in"; echo allow > "$S/def_out"
    printf '2: eno1    inet 10.10.10.31/24 metric 100 brd 10.10.10.255 scope global dynamic eno1\\       valid_lft 86000sec preferred_lft 86000sec\n' > "$S/addr"
    printf '%s\n' \
        'LISTEN 0      4096   127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=610,fd=15))' \
        'LISTEN 0      4096       0.0.0.0:22          0.0.0.0:*    users:(("sshd",pid=900,fd=3))' \
        'LISTEN 0      511        0.0.0.0:443         0.0.0.0:*    users:(("nginx",pid=1200,fd=6),("nginx",pid=1199,fd=6))' \
        'LISTEN 0      4096     127.0.0.1:9200        0.0.0.0:*    users:(("docker-proxy",pid=3100,fd=4))' \
        'LISTEN 0      4096         [::1]:5601           [::]:*    users:(("docker-proxy",pid=3200,fd=4))' \
        'LISTEN 0      4096          [::]:22             [::]:*    users:(("sshd",pid=900,fd=4))' > "$S/ss"

    stub id 'echo "$FAKE_UID"'
    stub ufw 'log() { echo "ufw $*" >> "$S/calls"; }
case "$*" in
    "status verbose"|status)
        if [ -f "$S/active" ]; then
            echo "Status: active"; echo "Logging: on (low)"
            echo "Default: $(cat "$S/def_in") (incoming), $(cat "$S/def_out") (outgoing), disabled (routed)"
            echo "New profiles: skip"
        else echo "Status: inactive"; fi ;;
    "show added")
        echo "Added user rules (see '"'"'ufw status'"'"' for running firewall):"
        if [ -s "$S/added" ]; then cat "$S/added"; else echo "(None)"; fi ;;
    allow*)
        log "$@"
        [ -f "$S/allow_noop" ] || grep -qxF "ufw $*" "$S/added" 2>/dev/null || echo "ufw $*" >> "$S/added"
        echo "Rules updated" ;;
    "default deny incoming")  log "$@"; echo deny > "$S/def_in" ;;
    "default allow outgoing") log "$@"; echo allow > "$S/def_out" ;;
    "--force enable")  log "$@"; rc=$(cat "$S/enable_rc" 2>/dev/null || echo 0); [ "$rc" -eq 0 ] || exit "$rc"; touch "$S/active" ;;
    "--force disable") log "$@"; rm -f "$S/active" ;;
    *) log "$@"; exit 1 ;;
esac'
    stub ip 'case "$*" in
    "-o route get "*)
        if [ -f "$S/route_fail" ]; then echo "RTNETLINK answers: Network is unreachable" >&2; exit 2; fi
        if [ -f "$S/route" ]; then cat "$S/route"; else echo "$4 dev eno1 src 10.10.10.31 uid 0 \\    cache"; fi ;;
    "-o -4 addr show dev "*) cat "$S/addr" ;;
    *) exit 1 ;;
esac'
    stub ss '[ "$*" = "-H -ltnp" ] || exit 9; cat "$S/ss"'
    stub iptables-save 'echo "iptables-save" >> "$S/calls"; printf "*filter\nCOMMIT\n"'
    stub tar 'echo "tar $*" >> "$S/calls"
prev=""; for a; do if [ "$prev" = -czf ]; then echo fake > "$a"; fi; prev=$a; done'
    stub setsid 'echo "setsid" >> "$S/calls"; exec "$REAL_SETSID" "$@"'
    stub sleep 'case $1 in 0.*) exec "$REAL_SLEEP" "$1" ;; esac
echo "sleep $*" >> "$S/calls"
if [ -f "$S/sleep_fast" ]; then exec "$REAL_SLEEP" 1.5; fi
exec "$REAL_SLEEP" 600'
}

# Kill every sleeper this test armed, including any a broken script leaked.
teardown() {
    local pid
    for pid in $(pgrep -f -- "r770-ufw-autorevert $UFW_RUN_DIR/" 2>/dev/null); do
        kill -- "-$pid" 2>/dev/null || true
    done
}

stub() {  # stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

ufw_sh() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

# bats does not fail a test on a bare `! cmd`, so negations go through functions.
dead()       { ! kill -0 "$1" 2>/dev/null; }
not_called() { ! grep -q -- "$1" "$S/calls"; }

no_mutations() { [ ! -s "$S/calls" ] || { cat "$S/calls"; false; }; }

# Mutating calls without the sleeper's asynchronous "sleep" line.
calls() { grep -v '^sleep ' "$S/calls"; }

line_of() { calls | grep -nxF "$1" | head -1 | cut -d: -f1; }

R22="ufw allow in on eno1 from 10.10.10.0/24 to any port 22 proto tcp"
R443="ufw allow in on eno1 from 10.10.10.0/24 to any port 443 proto tcp"

# Leave the box as a confirmed apply would.
applied_state() {
    touch "$S/active"; printf '%s\n%s\n' "$R22" "$R443" > "$S/added"
}

# ── discovery ────────────────────────────────────────────────────────────────

@test "discovery: interface, subnet (10.10.10.31/24 -> 10.10.10.0/24) and ssh port" {
    run ufw_sh plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"interface=eno1 subnet=10.10.10.0/24 ssh_port=22"* ]]
}

@test "discovery: a non-octet prefix is computed correctly (172.16.5.200/20 -> 172.16.0.0/20)" {
    export UFW_SSH_CONNECTION="172.16.9.7 40000 172.16.5.200 2222"
    echo "172.16.9.7 dev lacp-trunk.10 src 172.16.5.200 uid 0" > "$S/route"
    echo '7: lacp-trunk.10    inet 172.16.5.200/20 brd 172.16.15.255 scope global lacp-trunk.10' > "$S/addr"
    run ufw_sh plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"interface=lacp-trunk.10 subnet=172.16.0.0/20 ssh_port=2222"* ]]
    [[ "$output" == *"ufw allow in on lacp-trunk.10 from 172.16.0.0/20 to any port 2222 proto tcp"* ]]
}

@test "discovery: refuses when SSH_CONNECTION is empty" {
    export UFW_SSH_CONNECTION=""
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"SSH_CONNECTION is empty"* ]]
    no_mutations
}

@test "discovery: refuses when ip route get fails" {
    touch "$S/route_fail"
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"ip route get 10.10.10.5 failed"* ]]
    no_mutations
}

@test "discovery: refuses when the server address is not on the routed interface" {
    echo '2: eno1    inet 10.10.20.31/24 brd 10.10.20.255 scope global eno1' > "$S/addr"
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"10.10.10.31 is not an IPv4 address on eno1"* ]]
    no_mutations
}

@test "discovery: refuses a client outside the subnet (the rule would cut this session off)" {
    export UFW_SSH_CONNECTION="10.99.0.5 50001 10.10.10.31 22"
    echo "10.99.0.5 via 10.10.10.1 dev eno1 src 10.10.10.31 uid 0" > "$S/route"
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"outside 10.10.10.0/24"* ]]
    no_mutations
}

@test "discovery: refuses a session routed via lo, and an IPv6 session" {
    echo "local 10.10.10.5 dev lo table local src 10.10.10.31 uid 0" > "$S/route"
    run ufw_sh apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"via lo"* ]]
    export UFW_SSH_CONNECTION="fe80::1 50001 fe80::2 22"
    run ufw_sh apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"IPv6"* ]]
    no_mutations
}

# ── plan ─────────────────────────────────────────────────────────────────────

@test "plan (and the default verb) shows current status and the proposed ruleset, changes nothing" {
    for verb in plan ""; do
        run ufw_sh $verb
        echo "$output"
        [ "$status" -eq 0 ]
        [[ "$output" == *"Status: inactive"* ]]
        [[ "$output" == *"ufw default deny incoming"* ]]
        [[ "$output" == *"ufw default allow outgoing"* ]]
        [[ "$output" == *"$R22"* ]]
        [[ "$output" == *"$R443"* ]]
    done
    no_mutations
    [ -z "$(ls -A "$UFW_RUN_DIR")" ]
    [ ! -e "$UFW_BACKUP_DIR" ]
}

@test "plan warns about existing rules apply will not remove" {
    echo "ufw allow 8080/tcp" > "$S/added"
    run ufw_sh plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"*"will NOT remove"* ]]
    [[ "$output" == *"ufw allow 8080/tcp"* ]]
    no_mutations
}

# ── apply ────────────────────────────────────────────────────────────────────

@test "apply: backup, then allow rules, then sleeper, then default deny, then enable -- exact order" {
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 0 ]
    calls
    expected="iptables-save"
    [ "$(calls | sed -n 1p)" = "tar -C $BATS_TEST_TMPDIR/etc -czf $(ls -d "$UFW_BACKUP_DIR"/2*)/etc-ufw.tgz ufw" ]
    [ "$(calls | sed -n 2p)" = "$expected" ]
    [ "$(calls | sed -n 3p)" = "$R22" ]
    [ "$(calls | sed -n 4p)" = "$R443" ]
    [ "$(calls | sed -n 5p)" = "setsid" ]
    [ "$(calls | sed -n 6p)" = "ufw default deny incoming" ]
    [ "$(calls | sed -n 7p)" = "ufw default allow outgoing" ]
    [ "$(calls | sed -n 8p)" = "ufw --force enable" ]
    [ "$(calls | wc -l)" -eq 8 ]
}

@test "apply takes a backup of /etc/ufw, ufw.conf and iptables-save before touching ufw" {
    run ufw_sh apply
    [ "$status" -eq 0 ]
    dir=$(ls -d "$UFW_BACKUP_DIR"/2*)
    [ -s "$dir/etc-ufw.tgz" ]
    grep -qx 'ENABLED=no' "$dir/ufw.conf"
    grep -q '^\*filter' "$dir/iptables-save.txt"
    grep -qx 'taken_while_pending=no' "$dir/meta"
    [[ "$output" == *"backup: $dir"* ]]
    [ "$(line_of iptables-save)" -lt "$(line_of "$R22")" ]
}

@test "apply refuses to deny or enable if the allow rules do not show in 'ufw show added'" {
    touch "$S/allow_noop"
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"*"not visible in 'ufw show added'"* ]]
    not_called 'default deny'
    not_called 'enable'
    not_called 'setsid'
    [ ! -f "$S/active" ]
}

@test "apply schedules exactly one sleeper, records deadline and client port, and says so loudly" {
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^setsid$' "$S/calls")" -eq 1 ]
    pid=$(cat "$UFW_RUN_DIR/r770-ufw.pid")
    kill -0 "$pid"
    [ "$(cat "$UFW_RUN_DIR/r770-ufw.client-port")" = 50001 ]
    now=$(date +%s); dl=$(cat "$UFW_RUN_DIR/r770-ufw.deadline")
    [ $((dl - now)) -gt 590 ] && [ $((dl - now)) -le 600 ]
    [[ "$output" == *"run 'r770-ufw.sh confirm' from a NEW ssh session within 10 minutes"* ]]
    [[ "$output" == *"or UFW turns itself off"* ]]
    for i in $(seq 50); do grep -q '^sleep 600$' "$S/calls" && break; "$REAL_SLEEP" 0.05; done
    grep -qx 'sleep 600' "$S/calls"
}

@test "a second apply cancels the first apply's sleeper before arming its own" {
    ufw_sh apply --minutes 1 >/dev/null
    first=$(cat "$UFW_RUN_DIR/r770-ufw.pid")
    kill -0 "$first"
    run ufw_sh apply --minutes 2
    [ "$status" -eq 0 ]
    second=$(cat "$UFW_RUN_DIR/r770-ufw.pid")
    [ "$first" != "$second" ]
    "$REAL_SLEEP" 0.5
    dead "$first"
    kill -0 "$second"
    # The second backup holds the first apply's firewall: revert must skip it.
    [ "$(grep -lx 'taken_while_pending=yes' "$UFW_BACKUP_DIR"/*/meta | wc -l)" -eq 1 ]
}

@test "the sleeper, when it fires, disables ufw" {
    touch "$S/sleep_fast"
    run ufw_sh apply --minutes 1
    [ "$status" -eq 0 ]
    for i in $(seq 100); do grep -q -- '--force disable' "$S/calls" && break; "$REAL_SLEEP" 0.05; done
    grep -qx 'sleep 60' "$S/calls"
    grep -qx 'ufw --force disable' "$S/calls"
    [ ! -f "$S/active" ]
    [ ! -e "$UFW_RUN_DIR/r770-ufw.pid" ]
}

@test "apply --minutes: rejects non-numbers, 0 and 61; 60 is accepted" {
    for bad in abc 0 61 ""; do
        run ufw_sh apply --minutes $bad
        echo "$bad: $output"
        [ "$status" -eq 1 ]
        [[ "$output" == *"--minutes"* ]]
    done
    no_mutations
    run ufw_sh apply --minutes 60
    [ "$status" -eq 0 ]
    [[ "$output" == *"within 60 minutes"* ]]
}

@test "apply refuses an unknown argument" {
    run ufw_sh apply --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument"* ]]
    no_mutations
}

@test "apply is idempotent: confirmed state is reported 'already applied' and nothing runs" {
    applied_state
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already applied"* ]]
    no_mutations
}

@test "apply is NOT 'already applied' while the rules differ" {
    touch "$S/active"; echo "$R22" > "$S/added"
    run ufw_sh apply
    [ "$status" -eq 0 ]
    [[ "$output" != *"already applied"* ]]
    grep -qxF "$R443" "$S/calls"
}

@test "apply: a failed enable is reported and the sleeper stays armed" {
    echo 1 > "$S/enable_rc"
    run ufw_sh apply
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"*"enable failed; auto-revert still armed"* ]]
    kill -0 "$(cat "$UFW_RUN_DIR/r770-ufw.pid")"
}

@test "UFW_DRY_RUN prints the ufw commands in order and changes nothing" {
    run env UFW_DRY_RUN=1 PATH="$TEST_PATH" "$SCRIPT" apply
    echo "$output"
    [ "$status" -eq 0 ]
    a=$(grep -nxF "$R22" <<< "$output" | cut -d: -f1)
    d=$(grep -nx 'ufw default deny incoming' <<< "$output" | cut -d: -f1)
    e=$(grep -nx 'ufw --force enable' <<< "$output" | cut -d: -f1)
    [ -n "$a" ] && [ "$a" -lt "$d" ] && [ "$d" -lt "$e" ]
    no_mutations
    [ ! -e "$UFW_BACKUP_DIR" ]
}

# ── confirm ──────────────────────────────────────────────────────────────────

@test "confirm refuses from the session that ran apply (same client port)" {
    ufw_sh apply >/dev/null
    pid=$(cat "$UFW_RUN_DIR/r770-ufw.pid")
    run ufw_sh confirm
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"NEW ssh session"* ]]
    kill -0 "$pid"
}

@test "confirm from a new session (different client port) cancels the sleeper" {
    ufw_sh apply >/dev/null
    pid=$(cat "$UFW_RUN_DIR/r770-ufw.pid")
    UFW_SSH_CONNECTION="10.10.10.5 50002 10.10.10.31 22" run ufw_sh confirm
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UFW confirmed; auto-revert cancelled"* ]]
    "$REAL_SLEEP" 0.5
    dead "$pid"
    [ -z "$(ls -A "$UFW_RUN_DIR")" ]
    not_called '--force disable'
    # and now apply reports the confirmed state as done
    run ufw_sh apply
    [[ "$output" == *"already applied"* ]]
}

@test "confirm refuses when no sleeper is pending" {
    run ufw_sh confirm
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"no auto-revert pending"* ]]
}

@test "confirm refuses with an empty SSH_CONNECTION" {
    ufw_sh apply >/dev/null
    UFW_SSH_CONNECTION="" run ufw_sh confirm
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"SSH_CONNECTION is empty"* ]]
    kill -0 "$(cat "$UFW_RUN_DIR/r770-ufw.pid")"
}

# ── revert ───────────────────────────────────────────────────────────────────

@test "revert restores the pre-apply backup, leaves ufw disabled per ENABLED=no, and cancels the sleeper" {
    ufw_sh apply >/dev/null
    first=$(ls -d "$UFW_BACKUP_DIR"/2*)
    ufw_sh apply >/dev/null   # a second, still-pending apply: its backup must be skipped
    pid=$(cat "$UFW_RUN_DIR/r770-ufw.pid")
    : > "$S/calls"
    run ufw_sh revert
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(calls | sed -n 1p)" = "ufw --force disable" ]
    [ "$(calls | sed -n 2p)" = "tar -C $BATS_TEST_TMPDIR/etc -xzf $first/etc-ufw.tgz" ]
    [ "$(calls | wc -l)" -eq 2 ]
    [[ "$output" == *"reverted to $first; auto-revert cancelled"* ]]
    "$REAL_SLEEP" 0.5
    dead "$pid"
    [ ! -e "$UFW_RUN_DIR/r770-ufw.pid" ]
}

@test "revert re-enables ufw only when the backup had ENABLED=yes" {
    echo "ENABLED=yes" > "$UFW_ETC_DIR/ufw.conf"
    ufw_sh apply >/dev/null
    : > "$S/calls"
    run ufw_sh revert
    [ "$status" -eq 0 ]
    [ "$(calls | sed -n 3p)" = "ufw --force enable" ]
}

@test "revert is idempotent" {
    ufw_sh apply >/dev/null
    ufw_sh revert >/dev/null
    : > "$S/calls"
    run ufw_sh revert
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already reverted"* ]]
    no_mutations
}

@test "revert refuses when there is no backup" {
    run ufw_sh revert
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"no pre-apply backup"* ]]
    no_mutations
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify passes when only 22 and 443 listen on non-loopback addresses" {
    applied_state
    run ufw_sh verify
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS    ufw is active"* ]]
    [[ "$output" == *"PASS    default incoming is deny"* ]]
    [[ "$output" == *"PASS    rule: $R22"* ]]
    [[ "$output" == *"PASS    rule: $R443"* ]]
    [[ "$output" == *"PASS    no docker-proxy or unidentified non-loopback listeners"* ]]
    [[ "$output" != *"WARN"* ]]
    [[ "$output" == *"RESULT: PASS"* ]]
    no_mutations
}

@test "verify FAILs on a docker-proxy listener on 0.0.0.0:8443 (published past UFW)" {
    applied_state
    echo 'LISTEN 0      4096       0.0.0.0:8443        0.0.0.0:*    users:(("docker-proxy",pid=3300,fd=4))' >> "$S/ss"
    echo 'LISTEN 0      4096          [::]:8443           [::]:*    users:(("docker-proxy",pid=3301,fd=4))' >> "$S/ss"
    run ufw_sh verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    docker-proxy publishes 0.0.0.0:8443 past UFW"* ]]
    [[ "$output" == *"FAIL    docker-proxy publishes [::]:8443 past UFW"* ]]
    [[ "$output" == *"RESULT: FAIL"* ]]
}

@test "verify WARNs (exit 0) on a host service such as dnsmasq on the LAN: UFW filters it" {
    applied_state
    echo 'LISTEN 0      32     192.168.4.26:53         0.0.0.0:*    users:(("dnsmasq",pid=1500,fd=5))' >> "$S/ss"
    run ufw_sh verify
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN    non-loopback listener 192.168.4.26:53 (dnsmasq): filtered by UFW"* ]]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "verify FAILs on a non-loopback listener with no process info" {
    applied_state
    echo 'LISTEN 0      4096       0.0.0.0:9000        0.0.0.0:*' >> "$S/ss"
    run ufw_sh verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    non-loopback listener 0.0.0.0:9000 shows no process"* ]]
}

@test "verify FAILs on docker-proxy even on 443 (nginx must own it)" {
    applied_state
    echo 'LISTEN 0      4096     10.10.10.31:443       0.0.0.0:*    users:(("docker-proxy",pid=3400,fd=4))' >> "$S/ss"
    run ufw_sh verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    docker-proxy publishes 10.10.10.31:443 past UFW"* ]]
}

@test "verify fails when ufw is inactive, default allows, a rule is missing, or extra rules exist" {
    run ufw_sh verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    ufw is not active"* ]]
    [[ "$output" == *"FAIL    missing rule: $R443"* ]]
    applied_state; echo allow > "$S/def_in"; echo "ufw allow 8080/tcp" >> "$S/added"
    run ufw_sh verify
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL    default incoming is not deny"* ]]
    [[ "$output" == *"ufw allow 8080/tcp"* ]]
}

@test "verify warns (does not fail) while the auto-revert is still pending" {
    ufw_sh apply >/dev/null
    : > "$S/calls"
    run ufw_sh verify
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"*"auto-revert still pending"* ]]
    no_mutations
}

# ── refusals ─────────────────────────────────────────────────────────────────

@test "every verb refuses a non-root caller and changes nothing" {
    export FAKE_UID=1000
    for verb in plan apply confirm verify revert; do
        run ufw_sh $verb
        echo "$verb: $output"
        [ "$status" -eq 1 ]
        [[ "$output" == *"REFUSE"*"must run as root"* ]]
    done
    no_mutations
}

@test "an unknown verb is refused" {
    run ufw_sh enable
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSE"*"usage"* ]]
    no_mutations
}
