#!/usr/bin/env bats
#
# r770-phase3-run.sh sequences the storage script on the R770. What matters:
# `check` never mutates, `apply` runs in the agreed order (lv_pcap last) and
# stops at the first failure, and fstrim.timer is only enabled when asked.
#
# The storage script is itself a stub here ($PHASE3_STORAGE) that logs its
# arguments and fails when they contain $S/fail_on. Every other tool the script
# calls is a stub or a real read-only tool on a fixed list.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-phase3-run.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"; mkdir -p "$BIN" "$REAL" "$S"
    for t in bash env awk head tail od cat basename dirname printf; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"
    export FAKE_UID=0

    export PHASE3_STORAGE="$BATS_TEST_TMPDIR/storage.sh"
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "storage $*" >> "$S/calls"' \
        'if [ -f "$S/fail_on" ] && [[ " $* " == *" $(cat "$S/fail_on") "* ]]; then exit 1; fi' \
        > "$PHASE3_STORAGE"
    chmod +x "$PHASE3_STORAGE"

    export PHASE3_SYS="$BATS_TEST_TMPDIR/sys"
    mkdir -p "$PHASE3_SYS/class/dmi/id" "$PHASE3_SYS/block/sda/queue"
    echo G8WFGH4 > "$PHASE3_SYS/class/dmi/id/product_serial"
    echo 4096 > "$PHASE3_SYS/block/sda/queue/discard_granularity"
    echo 2147450880 > "$PHASE3_SYS/block/sda/queue/discard_max_bytes"
    echo 2147450880 > "$PHASE3_SYS/block/sda/queue/discard_max_hw_bytes"
    export PHASE3_FSTAB="$BATS_TEST_TMPDIR/fstab"; echo '/dev/x / ext4 defaults 0 1' > "$PHASE3_FSTAB"
    echo sda > "$S/pkname"

    stub id        'echo "$FAKE_UID"'
    stub hostname  'echo testbed'
    stub sha256sum 'echo "abc123  $1"'
    stub pvs       'echo "  /dev/sda3 ubuntu-vg0"'
    stub lsblk     'echo "lsblk $*" >> "$S/reads"; if [ "$1" = -no ]; then cat "$S/pkname"; else echo "NAME DISC-GRAN DISC-MAX"; fi'
    stub systemctl 'echo "systemctl $*" >> "$S/calls"'
    stub findmnt   'echo "findmnt $*" >> "$S/calls"'
    stub df        'echo "df $*" >> "$S/calls"'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

p3() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

@test "apply grows /var, then every LV in order with lv_pcap last, then re-plans" {
    run p3 apply
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    expected="storage --grow-var
storage --apply --lv lv_docker
storage --apply --lv lv_index
storage --apply --lv lv_staging
storage --apply --lv lv_vms
storage --apply --lv lv_gns3
storage --apply --lv lv_work
storage --apply --lv lv_backup
storage --apply --lv lv_pcap
storage --plan"
    [ "$(grep '^storage ' "$S/calls")" = "$expected" ]
    grep -q '^findmnt --verify$' "$S/calls"
}

@test "apply without --fstrim leaves fstrim.timer alone and says so" {
    run p3 apply
    [ "$status" -eq 0 ]
    ! grep -q '^systemctl' "$S/calls"
    [[ "$output" == *"left disabled"* ]]
}

@test "apply --fstrim enables fstrim.timer" {
    run p3 apply --fstrim
    [ "$status" -eq 0 ]
    grep -qx 'systemctl enable --now fstrim.timer' "$S/calls"
}

@test "apply stops at the first failing LV" {
    echo lv_vms > "$S/fail_on"
    run p3 apply
    [ "$status" -eq 1 ]
    grep -q 'lv_vms' "$S/calls"
    ! grep -q 'lv_gns3' "$S/calls"
    ! grep -q -- '--plan' "$S/calls"
}

@test "apply stops when growing /var fails" {
    echo --grow-var > "$S/fail_on"
    run p3 apply
    [ "$status" -eq 1 ]
    [ "$(cat "$S/calls")" = "storage --grow-var" ]
}

@test "check is read-only: the storage script is only asked to --plan" {
    run p3 check
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$S/calls")" = "storage --plan" ]
    [[ "$output" == *"product_serial=G8WFGH4"* ]]
    [[ "$output" == *"PV=/dev/sda3 VD=/dev/sda"* ]]
    [[ "$output" == *"discard_max_bytes=2147450880"* ]]
    grep -qx 'lsblk -D /dev/sda' "$S/reads"
}

@test "check uses the PV itself when it is a whole disk" {
    : > "$S/pkname"
    stub pvs 'echo "  /dev/sda ubuntu-vg0"'
    run p3 check
    [ "$status" -eq 0 ]
    [[ "$output" == *"PV=/dev/sda VD=/dev/sda"* ]]
}

@test "check stops when no PV belongs to the VG" {
    stub pvs 'echo "  /dev/sdz3 other-vg"'
    run p3 check
    [ "$status" -eq 1 ]
    [[ "$output" == *"no PV found for ubuntu-vg0"* ]]
    [ ! -s "$S/calls" ]
}

@test "refuses a non-root user, an unknown mode and stray arguments" {
    FAKE_UID=1000 run p3 check
    [ "$status" -eq 1 ]; [[ "$output" == *"must run as root"* ]]
    run p3 frobnicate
    [ "$status" -eq 1 ]; [[ "$output" == *"usage"* ]]
    run p3 apply --fstrim extra
    [ "$status" -eq 1 ]
    run p3 check extra
    [ "$status" -eq 1 ]
    [ ! -s "$S/calls" ]
}
