#!/usr/bin/env bash
#
# r770-storage-apply.sh — Phase 3: create the lab LVs in VG ubuntu-vg0.
#
# Runs ON the R770, as root. It never names a block device: it acts only on
# LVs inside the VG discovery confirmed (state/BUILD-STATE.md).
#
# Design: docs/superpowers/specs/2026-09-23-phase2-3-storage-design.md
# Layout owner: docs/plans/r770-network-lab-buildout.md §3.2. LAYOUT below is a
# permitted copy, because this script runs where the repo does not; the test
# suite fails if the two disagree. Change the design first, then this table.
#
#   --plan              default. Read-only: state, proposed action, exact commands
#   --apply --lv NAME   create, format, fstab and mount ONE LV
#   --grow-var          grow lv-var to 50 GiB online. NOT reversible online.
#
#   0  done, or nothing to do
#   1  refused (nothing changed) or failed (fstab restored; see output)
#
# Test overrides: STORAGE_FSTAB, STORAGE_ROOT (prefix for mount-point dirs).
set -uo pipefail

VG=ubuntu-vg0
FSTAB="${STORAGE_FSTAB:-/etc/fstab}"
ROOT="${STORAGE_ROOT:-}"
VAR_LV=lv-var
VAR_TARGET_G=50
MIN_FREE_PCT=5

# name        GiB  fs   mount point
LAYOUT="
lv_docker     250  ext4 /var/lib/docker
lv_pcap      3328  xfs  /data/pcap
lv_index     1024  xfs  /data/index
lv_staging    250  xfs  /data/staging
lv_vms        500  xfs  /srv/vms
lv_gns3       400  xfs  /srv/gns3
lv_work       200  xfs  /srv/work
lv_backup     250  xfs  /srv/backup
"

die() { printf 'REFUSE  %s\n' "$*"; exit 1; }

layout_row() { awk -v n="$1" '$1 == n' <<< "$LAYOUT"; }

vg_field() {  # vg_field size|free -> GiB
    vgs --noheadings --nosuffix --units g -o "vg_$1" "$VG" 2>/dev/null | tr -d ' '
}

lv_size() {  # lv_size NAME -> GiB, empty if the LV does not exist
    lvs --noheadings --nosuffix --units g -o lv_size "$VG/$1" 2>/dev/null | tr -d ' '
}

lv_fs() { blkid -s TYPE -o value "/dev/$VG/$1" 2>/dev/null; }

fstab_has() { awk -v m="$1" '$1 !~ /^#/ && $2 == m {f = 1} END {exit !f}' "$FSTAB"; }

dir_nonempty() { [ -d "$ROOT$1" ] && [ -n "$(ls -A "$ROOT$1")" ]; }

is_mounted() { findmnt -n "$1" >/dev/null 2>&1; }

ge() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a >= b)}'; }

sub() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a - b}'; }

room_reason() {  # room_reason FREE NEED VGSIZE -> empty when there is room
    awk -v f="$1" -v n="$2" -v s="$3" -v p="$MIN_FREE_PCT" 'BEGIN {
        if (f < n)                printf "VG free %.2fG < %.2fG needed", f, n
        else if (f - n < s*p/100) printf "would leave %.2fG free, under the %d%% reserve floor (%.2fG)", f - n, p, s*p/100
    }'
}

# classify NAME SIZE FS MP FREE VGSIZE -> SKIP | CREATE | REFUSE: <reason>
classify() {
    local name=$1 size=$2 fs=$3 mp=$4 free=$5 vgsize=$6 cur curfs reason
    cur=$(lv_size "$name")
    if [ -n "$cur" ]; then
        curfs=$(lv_fs "$name")
        if ! awk -v a="$cur" -v b="$size" 'BEGIN {exit !(a == b)}' || [ "$curfs" != "$fs" ]; then
            echo "REFUSE: $VG/$name exists as ${cur}G ${curfs:-unformatted}; layout wants ${size}G $fs"
        elif is_mounted "$mp" && fstab_has "$mp"; then
            echo "SKIP"
        else
            echo "REFUSE: $VG/$name exists but is not both mounted at $mp and in fstab — partially applied; inspect, then remove with: umount $mp; lvremove $VG/$name"
        fi
        return
    fi
    if is_mounted "$mp";   then echo "REFUSE: $mp is already a mount point"; return; fi
    if dir_nonempty "$mp"; then echo "REFUSE: $mp exists and is not empty"; return; fi
    if fstab_has "$mp";    then echo "REFUSE: $FSTAB already has an entry for $mp"; return; fi
    reason=$(room_reason "$free" "$size" "$vgsize")
    if [ -n "$reason" ]; then echo "REFUSE: $reason"; return; fi
    echo "CREATE"
}

print_cmds() {  # print_cmds NAME SIZE FS MP
    printf '        %s\n' \
        "lvcreate --yes --wipesignatures y -n $1 -L ${2}G $VG" \
        "mkfs.$3 /dev/$VG/$1" \
        "mkdir -p $4" \
        "cp -p $FSTAB $FSTAB.pre-$1-<timestamp>" \
        "echo 'UUID=<uuid of /dev/$VG/$1> $4 $3 noatime,nofail 0 2' >> $FSTAB" \
        "systemctl daemon-reload" \
        "findmnt --verify --tab-file $FSTAB" \
        "mount --fstab $FSTAB $4"
}

plan() {
    local free vgsize refused=0 cur delta reason name size fs mp verdict
    free=$(vg_field free); vgsize=$(vg_field size)
    echo "== storage plan: VG $VG size ${vgsize}G, free ${free}G =="

    # lv-var first: it is the first thing applied.
    cur=$(lv_size "$VAR_LV")
    if [ -z "$cur" ]; then
        echo "REFUSE  $VAR_LV not found in $VG"; refused=1
    elif ge "$cur" "$VAR_TARGET_G"; then
        echo "SKIP    $VAR_LV — already ${cur}G"
    else
        delta=$(sub "$VAR_TARGET_G" "$cur")
        reason=$(room_reason "$free" "$delta" "$vgsize")
        if [ -n "$reason" ]; then
            echo "REFUSE  $VAR_LV — $reason"; refused=1
        else
            echo "GROW    $VAR_LV ${cur}G -> ${VAR_TARGET_G}G  (online; NOT reversible online)"
            printf '        %s\n' "lvextend --resizefs -L ${VAR_TARGET_G}G $VG/$VAR_LV"
            free=$(sub "$free" "$delta")
        fi
    fi

    while read -r name size fs mp; do
        [ -n "$name" ] || continue
        verdict=$(classify "$name" "$size" "$fs" "$mp" "$free" "$vgsize")
        case "$verdict" in
            SKIP)   echo "SKIP    $name — already applied" ;;
            CREATE) echo "CREATE  $name ${size}G $fs $mp"
                    print_cmds "$name" "$size" "$fs" "$mp"
                    free=$(sub "$free" "$size") ;;
            *)      echo "REFUSE  $name — ${verdict#REFUSE: }"; refused=1 ;;
        esac
    done <<< "$LAYOUT"

    echo "== VG free after this plan: ${free}G of ${vgsize}G =="
    return "$refused"
}

fail_after_lv() {  # fail_after_lv NAME MESSAGE
    printf 'FAIL    %s\n        the empty LV was left in place; to remove it: lvremove %s/%s\n' "$2" "$VG" "$1"
    exit 1
}

restore_fstab() {  # restore_fstab BACKUP -> 0 only when FSTAB is byte-identical to BACKUP again
    local tmp="$FSTAB.restore.$$"
    cp -p "$1" "$tmp" && mv -f "$tmp" "$FSTAB" && cmp -s "$1" "$FSTAB"
}

rollback_fstab() {  # rollback_fstab BACKUP NAME REASON
    if restore_fstab "$1"; then
        systemctl daemon-reload
        fail_after_lv "$2" "$3 — $FSTAB restored from $1"
    else
        printf 'FAIL    %s RESTORE FAILED — restore it by hand now: cp -p %s %s\n        the empty LV was left in place; to remove it: lvremove %s/%s\n' "$FSTAB" "$1" "$FSTAB" "$VG" "$2"
        exit 1
    fi
}

apply_lv() {
    local row name size fs mp verdict uuid backup
    row=$(layout_row "$1")
    [ -n "$row" ] || die "no LV named '$1' in the layout (names: $(awk 'NF {printf "%s ", $1}' <<< "$LAYOUT"))"
    read -r name size fs mp <<< "$row"
    verdict=$(classify "$name" "$size" "$fs" "$mp" "$(vg_field free)" "$(vg_field size)")
    case "$verdict" in
        SKIP)    echo "SKIP    $name — already applied"; return 0 ;;
        REFUSE*) die "$name — ${verdict#REFUSE: }" ;;
    esac

    findmnt --verify --tab-file "$FSTAB" >/dev/null || die "$FSTAB does not pass findmnt --verify as it stands — fix it first; nothing changed"

    echo "APPLY   $name ${size}G $fs $mp"
    lvcreate --yes --wipesignatures y -n "$name" -L "${size}G" "$VG" \
        || die "lvcreate failed — nothing else changed"
    "mkfs.$fs" "/dev/$VG/$name" || fail_after_lv "$name" "mkfs.$fs failed"
    mkdir -p "$ROOT$mp"         || fail_after_lv "$name" "mkdir $mp failed"
    uuid=$(blkid -s UUID -o value "/dev/$VG/$name")
    [ -n "$uuid" ]              || fail_after_lv "$name" "no filesystem UUID on /dev/$VG/$name"

    backup="$FSTAB.pre-$name-$(date +%Y%m%dT%H%M%S)"
    cp -p "$FSTAB" "$backup"    || fail_after_lv "$name" "could not back up $FSTAB"
    printf 'UUID=%s %s %s noatime,nofail 0 2\n' "$uuid" "$mp" "$fs" >> "$FSTAB" \
        || rollback_fstab "$backup" "$name" "could not append to $FSTAB"
    systemctl daemon-reload
    if ! findmnt --verify --tab-file "$FSTAB" >/dev/null || ! mount --fstab "$FSTAB" "$mp"; then
        rollback_fstab "$backup" "$name" "fstab verify or mount failed"
    fi
    is_mounted "$mp" || rollback_fstab "$backup" "$name" "mount reported success but $mp is not mounted"
    echo "DONE    $name mounted at $mp (fstab backup: $backup)"
    findmnt -n -o SOURCE,FSTYPE,SIZE,OPTIONS "$mp" || true   # evidence only
}

grow_var() {
    local cur free vgsize delta reason
    cur=$(lv_size "$VAR_LV")
    [ -n "$cur" ] || die "$VAR_LV not found in $VG"
    if ge "$cur" "$VAR_TARGET_G"; then echo "SKIP    $VAR_LV — already ${cur}G"; return 0; fi
    free=$(vg_field free); vgsize=$(vg_field size)
    delta=$(sub "$VAR_TARGET_G" "$cur")
    reason=$(room_reason "$free" "$delta" "$vgsize")
    [ -z "$reason" ] || die "$VAR_LV — $reason"
    echo "GROW    $VAR_LV ${cur}G -> ${VAR_TARGET_G}G  (online; NOT reversible online)"
    lvextend --resizefs -L "${VAR_TARGET_G}G" "$VG/$VAR_LV" || die "lvextend/resizefs failed — the LV may already have grown; check: lvs $VG/$VAR_LV; df -h /var"
    findmnt -n -o SOURCE,FSTYPE,SIZE /var || true   # evidence only
}

MODE=plan; LV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plan)     MODE=plan ;;
        --apply)    MODE=apply ;;
        --lv)       LV="${2:-}"; shift ;;
        --grow-var) MODE=grow ;;
        *)          die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "must run as root (LVM and $FSTAB)"
vgs "$VG" >/dev/null 2>&1 || die "VG $VG not found — discovery says it exists; stop and re-run discovery"

case "$MODE" in
    plan)  plan; exit $? ;;
    apply) [ -n "$LV" ] || die "--apply needs --lv NAME"; apply_lv "$LV" ;;
    grow)  grow_var ;;
esac
