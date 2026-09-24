#!/usr/bin/env bats
#
# r770-storage-apply.sh writes filesystems on the R770, so what matters most
# here is the refusals: every one of them must exit non-zero and change nothing.
#
# LVM, blkid, findmnt, mount and systemctl are all stubs backed by a state
# directory ($S). The script sees ONLY the stubs plus a fixed list of real
# tools, so a real LVM on the test host can never answer for the fake VG.
#
#   $S/vg_size, $S/vg_free    GiB, as vgs --units g --nosuffix prints them
#   $S/lv/<name>              "<size_GiB> <fs>"   (fs empty until mkfs)
#   $S/mounted                one mount point per line
#   $S/verify_rc              exit code for `findmnt --verify` (default 0)
#   $S/calls                  every mutating call, one per line

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-storage-apply.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export STORAGE_ROOT="$BATS_TEST_TMPDIR/root"
    export STORAGE_FSTAB="$BATS_TEST_TMPDIR/fstab"
    export FAKE_UID=0
    mkdir -p "$BIN" "$REAL" "$S/lv" "$STORAGE_ROOT"
    for t in bash env awk sed grep tr cat cp mkdir ls date head tail rm cmp; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    # A VG shaped like discovery found it (GiB; owner: state/BUILD-STATE.md), lv-var 6G.
    echo 7153 > "$S/vg_size"; echo 7004 > "$S/vg_free"
    echo "6 ext4" > "$S/lv/lv-var"
    printf '%s\n' \
        '/dev/disk/by-id/dm-uuid-LVM-root / ext4 defaults 0 1' \
        '/dev/disk/by-id/dm-uuid-LVM-var /var ext4 defaults 0 1' > "$STORAGE_FSTAB"
    cp "$STORAGE_FSTAB" "$BATS_TEST_TMPDIR/fstab.orig"

    stub id        'echo "$FAKE_UID"'
    stub vgs       'case "$*" in *vg_size*) echo "  $(cat "$S/vg_size").00";; *vg_free*) echo "  $(cat "$S/vg_free").00";; *) [ -f "$S/vg_size" ];; esac'
    stub lvs       'for a; do t=$a; done; f="$S/lv/${t#*/}"; [ -f "$f" ] || exit 5; read -r sz _ < "$f"; echo "  ${sz}.00"'
    stub blkid     'k=$2; for a; do d=$a; done; n=${d##*/}; f="$S/lv/$n"; [ -f "$f" ] || exit 2; read -r _ fs < "$f"; [ -n "$fs" ] || exit 2; if [ "$k" = UUID ]; then echo "uuid-$n"; else echo "$fs"; fi'
    stub lvcreate  'echo "lvcreate $*" >> "$S/calls"; while [ $# -gt 0 ]; do case $1 in -n) n=$2; shift;; -L) l=${2%G}; shift;; esac; shift; done; echo "$l" > "$S/lv/$n"'
    stub mkfs.xfs  'echo "mkfs.xfs $*" >> "$S/calls"; n=${1##*/}; read -r sz _ < "$S/lv/$n"; echo "$sz xfs" > "$S/lv/$n"'
    stub mkfs.ext4 'echo "mkfs.ext4 $*" >> "$S/calls"; n=${1##*/}; read -r sz _ < "$S/lv/$n"; echo "$sz ext4" > "$S/lv/$n"'
    stub lvextend  'echo "lvextend $*" >> "$S/calls"; echo "50 ext4" > "$S/lv/lv-var"'
    stub systemctl 'echo "systemctl $*" >> "$S/calls"'
    stub mount     'echo "mount $*" >> "$S/calls"; for a; do t=$a; done; echo "$t" >> "$S/mounted"'
    stub findmnt   'if [ "$1" = --verify ]; then echo "findmnt $*" >> "$S/calls"; exit "$(cat "$S/verify_rc" 2>/dev/null || echo 0)"; fi; for a; do t=$a; done; grep -qxF "$t" "$S/mounted" 2>/dev/null || exit 1; echo "$t"'
}

stub() {  # stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

apply_script() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

no_mutations() { [ ! -s "$S/calls" ] || { cat "$S/calls"; false; }; }

fstab_unchanged() { cmp "$STORAGE_FSTAB" "$BATS_TEST_TMPDIR/fstab.orig"; }

# ── plan mode ────────────────────────────────────────────────────────────────

@test "plan on the discovered VG proposes the grow and all eight LVs, changes nothing" {
    run apply_script --plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GROW    lv-var"* ]]
    [ "$(grep -c '^CREATE  ' <<< "$output")" -eq 8 ]
    [[ "$output" == *"lvcreate --yes --wipesignatures y -n lv_pcap -L 3328G ubuntu-vg0"* ]]
    no_mutations
    fstab_unchanged
}

@test "no arguments means --plan" {
    run apply_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"== storage plan"* ]]
    no_mutations
}

@test "plan refuses when the layout would breach the 5% reserve floor" {
    echo 6500 > "$S/vg_free"
    run apply_script --plan
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reserve floor"* ]]
    no_mutations
}

# ── refusals common to every mode ────────────────────────────────────────────

@test "refuses to run as a non-root user" {
    FAKE_UID=1000 run apply_script --plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"must run as root"* ]]
    no_mutations
}

@test "refuses when the VG is absent" {
    rm "$S/vg_size"
    run apply_script --plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"VG ubuntu-vg0 not found"* ]]
}

@test "refuses an unknown argument" {
    run apply_script --frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument"* ]]
}

# ── layout drift guard ───────────────────────────────────────────────────────
# buildout §3.2 owns the layout (OWNERS.md). The script carries a copy because
# it runs on an air-gapped host with no repo; this test keeps the copy honest.

@test "the script's LAYOUT matches buildout §3.2 exactly" {
    design="$(awk -F'|' '$2 ~ /^ *lv_/ {
                  name=$2; mp=$3; fs=tolower($4); sz=$5
                  gsub(/[ `*]/, "", name); gsub(/[ `*]/, "", mp); gsub(/[ *]/, "", fs); gsub(/\*/, "", sz)
                  split(sz, p, " "); g = (p[2] == "TiB") ? p[1] * 1024 : p[1]
                  printf "%s %d %s %s\n", name, g, fs, mp }' \
                  "$BATS_TEST_DIRNAME/../docs/plans/r770-network-lab-buildout.md" | sort)"
    script="$(sed -n '/^LAYOUT="/,/^"$/p' "$SCRIPT" | awk 'NF == 4 {print $1, $2, $3, $4}' | sort)"
    echo "design:"; echo "$design"; echo "script:"; echo "$script"
    [ "$(wc -l <<< "$design")" -eq 8 ]
    [ "$design" = "$script" ]
}
