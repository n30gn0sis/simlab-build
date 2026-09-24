#!/usr/bin/env bash
#
# r770-phase3-run.sh — the operator's two Phase 3 steps on the R770, as one
# reviewed script instead of pasted command blocks.
#
# Runs ON the R770, as root, from the transfer drive: r770-storage-apply.sh
# must sit beside it. This session cannot reach the R770, so the operator runs
# it and pastes the output back — tee it to a log.
#
#   check              read-only: identity, storage-script hash, the VD's
#                      discard support (Phase 2 item 3), fstab's last byte,
#                      and the storage plan
#   apply [--fstrim]   grow /var, create every LV (lv_pcap last), enable
#                      fstrim.timer only with --fstrim, then post-checks.
#                      Stops at the first failure.
#
# Design: docs/superpowers/specs/2026-09-24-bundle-to-r770-design.md
#
# Test overrides: PHASE3_STORAGE, PHASE3_SYS, PHASE3_FSTAB.
set -uo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
STORAGE="${PHASE3_STORAGE:-$HERE/r770-storage-apply.sh}"
SYS="${PHASE3_SYS:-/sys}"
FSTAB="${PHASE3_FSTAB:-/etc/fstab}"
VG=ubuntu-vg0
LV_ORDER=(lv_docker lv_index lv_staging lv_vms lv_gns3 lv_work lv_backup lv_pcap)
MOUNTS=(/var /var/lib/docker /data/index /data/staging /srv/vms /srv/gns3 /srv/work /srv/backup /data/pcap)

die()  { printf 'REFUSE  %s\n' "$*"; exit 1; }
step() { printf '\n== %s\n' "$*"; }
run()  { printf '$ %s\n' "$*"; "$@"; }

check() {
    local pv vd f
    step "identity"
    run hostname
    printf 'product_serial=%s\n' "$(cat "$SYS/class/dmi/id/product_serial")"
    step "storage script"
    run sha256sum "$STORAGE"
    step "PV of $VG"
    pv=$(pvs --noheadings -o pv_name,vg_name | awk -v vg="$VG" '$2 == vg {print $1}')
    [ -n "$pv" ] || { echo "no PV found for $VG — stop"; return 1; }
    vd=$(lsblk -no PKNAME "$pv" | head -1)
    vd=${vd:-$(basename "$pv")}      # a whole-disk PV has no parent
    echo "PV=$pv VD=/dev/$vd"
    step "discard (Phase 2 item 3)"
    run lsblk -D "/dev/$vd"
    for f in discard_granularity discard_max_bytes discard_max_hw_bytes; do
        printf '%s=%s\n' "$f" "$(cat "$SYS/block/$vd/queue/$f")"
    done
    step "fstab last byte (must be \\n)"
    tail -c1 "$FSTAB" | od -c | head -1
    step "storage plan"
    run bash "$STORAGE" --plan
}

apply() {
    local fstrim=$1 lv
    step "grow /var"
    run bash "$STORAGE" --grow-var || return 1
    for lv in "${LV_ORDER[@]}"; do
        step "apply $lv"
        run bash "$STORAGE" --apply --lv "$lv" || return 1
    done
    step "fstrim.timer"
    if [ "$fstrim" = 1 ]; then
        run systemctl enable --now fstrim.timer || return 1
    else
        echo "left disabled — the VD does not advertise discard (Phase 2 item 3)"
    fi
    step "post-checks"
    run bash "$STORAGE" --plan || return 1
    run findmnt --verify || return 1
    run df -h "${MOUNTS[@]}"
}

[ "$(id -u)" = 0 ] || die "must run as root"
case "${1:-}" in
    check)
        [ $# -eq 1 ] || die "check takes no arguments"
        check; exit $? ;;
    apply)
        case "${2:-}" in
            "")       [ $# -eq 1 ] || die "unexpected argument"; apply 0 ;;
            --fstrim) [ $# -eq 2 ] || die "unexpected argument"; apply 1 ;;
            *)        die "unknown argument: $2" ;;
        esac
        exit $? ;;
    *)  die "usage: $0 check | apply [--fstrim]" ;;
esac
