#!/usr/bin/env bash
#
# r770-precheck.sh — Phase 1 hardware discovery & precheck
# Dell PowerEdge R770 network-analysis lab buildout (see r770-network-lab-buildout.md)
#
# STRICTLY READ-ONLY. This script inspects the system and writes a report.
# It changes NOTHING: no packages installed, no config touched, no state modified.
#
# Usage:   sudo ./r770-precheck.sh
#          (runs without sudo too, but PERC/SMART/dmidecode sections will be skipped)
#
# Output:  ./r770-precheck-<hostname>-<timestamp>/   (full per-section logs)
#          ./r770-precheck-<hostname>-<timestamp>.tar.gz  (bundle to send back)
#          plus a PASS/WARN/FAIL summary on stdout.
#
# Expected hardware (checks are calibrated to this; mismatches WARN, not fail):
#   2 x Intel Xeon 6 6515P (32 cores / 64 threads), 128 GB DDR5, PERC NVMe RAID1,
#   2 x Broadcom quad-port 10GbE OCP (8 capture ports), integrated mgmt NIC, iDRAC.

set -u
umask 077

# ── setup ────────────────────────────────────────────────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
HN="$(hostname -s 2>/dev/null || echo unknown)"
OUT="./r770-precheck-${HN}-${TS}"
mkdir -p "$OUT"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        echo "NOTE: not root and passwordless sudo unavailable — privileged sections will be skipped."
        echo "      Re-run with sudo for PERC, SMART, dmidecode, and full dmesg coverage."
    fi
else
    SUDO=""
fi

priv() {  # run privileged if possible, else record skip; tolerate missing binaries
    case "$1" in
        bash|sh) : ;;  # compound commands: let them run
        *) command -v "$1" >/dev/null 2>&1 || { echo "[not installed] $1"; return 127; } ;;
    esac
    if [ "$(id -u)" -eq 0 ]; then "$@"; elif [ -n "$SUDO" ]; then $SUDO "$@"; else echo "[skipped: needs root] $*"; return 127; fi
}

PASS=0; WARN=0; FAIL=0
RESULTS="$OUT/00-summary.txt"
: > "$RESULTS"
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1" | tee -a "$RESULTS"; }
warn() { WARN=$((WARN+1)); printf 'WARN  %s\n' "$1" | tee -a "$RESULTS"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1" | tee -a "$RESULTS"; }

section() {  # section <file> <title> — start a section log
    SEC="$OUT/$1"
    printf '\n==== %s ====\n' "$2"
    printf '# %s\n# generated %s\n\n' "$2" "$(date -Is)" > "$SEC"
}
run() {  # run <cmd...> — log a command and its output into current section
    { printf '\n$ %s\n' "$*"; "$@" 2>&1; } >> "$SEC"
}
runp() { # privileged variant
    { printf '\n$ (sudo) %s\n' "$*"; priv "$@"; } >> "$SEC"
}
have() { command -v "$1" >/dev/null 2>&1; }

echo "R770 precheck starting — output in $OUT (read-only inspection, no changes)"

# ── 1. identity / OS ─────────────────────────────────────────────────────────
section 01-os.txt "Identity / OS"
run hostnamectl
run uname -a
run cat /etc/os-release
run uptime
if grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
    ok "Ubuntu 24.04 LTS detected"
else
    warn "OS is not Ubuntu 24.04 LTS ($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")) — confirm intended release"
fi

# ── 2. CPU / NUMA / virtualization ───────────────────────────────────────────
section 02-cpu.txt "CPU / NUMA / virtualization"
run lscpu
run lscpu -e
runp dmidecode -t processor
if have numactl; then run numactl --hardware; else echo "numactl not installed (fine for discovery; install later)" >> "$SEC"; fi
runp dmesg -t --level=info,warn,err
# keep only iommu lines from that big dump in the section, plus full copy for the bundle
priv dmesg 2>/dev/null | grep -i -E 'iommu|dmar' > "$OUT/02b-iommu-dmesg.txt" || true

SOCKETS=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}')
CORES=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')
CPUS=$(nproc 2>/dev/null || echo 0)
NUMA_NODES=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2);print $2}')

[ "${SOCKETS:-0}" = "2" ] && ok "2 CPU sockets populated" \
    || fail "Expected 2 sockets, found ${SOCKETS:-unknown} — verify second 6515P is installed/seated"
TOTAL_CORES=$(( ${SOCKETS:-0} * ${CORES:-0} ))
[ "$TOTAL_CORES" -eq 32 ] && ok "32 physical cores visible" \
    || warn "Expected 32 physical cores, found ${TOTAL_CORES} — verify BIOS core settings"
[ "${CPUS}" -eq 64 ] && ok "64 logical threads visible (SMT on)" \
    || warn "Expected 64 threads, found ${CPUS} — check Hyper-Threading in BIOS"
case "${NUMA_NODES:-0}" in
    2) ok "2 NUMA nodes (standard dual-socket layout)";;
    4) warn "4 NUMA nodes — sub-NUMA clustering is enabled; §8 socket split must use the real node map";;
    1) fail "1 NUMA node reported on a dual-socket box — check BIOS NUMA/memory interleave settings";;
    *) warn "NUMA node count: ${NUMA_NODES:-unknown} — review manually";;
esac
if grep -q -m1 vmx /proc/cpuinfo; then ok "Intel VT-x (vmx) flag present"; else fail "vmx flag missing — enable Intel Virtualization Technology in BIOS"; fi
if priv dmesg 2>/dev/null | grep -qi -E 'DMAR|IOMMU.*enabled'; then ok "IOMMU/VT-d activity visible in dmesg"; else warn "No IOMMU/DMAR evidence in dmesg — verify VT-d in BIOS (needed only for passthrough; not fatal)"; fi
if [ -e /dev/kvm ]; then ok "/dev/kvm present"; else warn "/dev/kvm absent (normal pre-install; KVM modules load in Phase 7)"; fi

# ── 3. memory ────────────────────────────────────────────────────────────────
section 03-memory.txt "Memory"
run free -h
run lsmem
runp dmidecode -t memory
MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
if [ "${MEM_GB:-0}" -ge 120 ]; then ok "~128 GB RAM visible (${MEM_GB} GiB)"; else fail "Expected ~128 GB RAM, see ${MEM_GB} GiB — check DIMM seating/config"; fi
DIMMS=$(priv dmidecode -t memory 2>/dev/null | grep -c '^\s*Size: [0-9]' 2>/dev/null); DIMMS=$(echo "${DIMMS:-0}" | head -1)
case "$DIMMS" in (''|*[!0-9]*) DIMMS=0;; esac
if [ "${DIMMS:-0}" -eq 8 ]; then
    ok "8 DIMMs populated (4/socket = half of 8 channels each; §8 bandwidth caveat applies)"
elif [ "${DIMMS:-0}" -eq 0 ]; then
    warn "DIMM population not readable (needs root) — verify 8 x 16GB and per-socket placement manually"
else
    warn "DIMM count ${DIMMS} (expected 8) — record actual population and per-socket balance"
fi
# per-socket balance hint
priv dmidecode -t memory 2>/dev/null | grep -E 'Locator|Size|Speed|Rank' > "$OUT/03b-dimm-map.txt" || true
if have edac-util; then run edac-util --report=full; fi

# ── 4. platform / firmware / boot ────────────────────────────────────────────
section 04-platform.txt "Platform / firmware / boot"
runp dmidecode -t system
runp dmidecode -t bios
run ls /sys/firmware/efi
if [ -d /sys/firmware/efi ]; then ok "UEFI boot mode"; else warn "Legacy BIOS boot mode — UEFI expected on R770; verify intended"; fi
if have mokutil; then
    run mokutil --sb-state
    SB=$(mokutil --sb-state 2>/dev/null | head -1)
    echo "Secure Boot: ${SB:-unknown}" >> "$RESULTS"
else
    echo "mokutil not installed — Secure Boot state unknown" >> "$SEC"
fi
MODEL=$(priv dmidecode -s system-product-name 2>/dev/null || true)
case "$MODEL" in
    *R770*) ok "Chassis reports PowerEdge R770";;
    "")     warn "System model unreadable (needs root)";;
    *)      warn "System model is '$MODEL' (expected PowerEdge R770)";;
esac

# ── 5. storage ───────────────────────────────────────────────────────────────
section 05-storage.txt "Storage"
run lsblk -e7 -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
run findmnt --real
run df -h
runp fdisk -l
run bash -c "lspci -nn | grep -i -E 'raid|storage|nvme|sas' || true"
if have nvme; then runp nvme list; else echo "nvme-cli not installed" >> "$SEC"; fi
if have smartctl; then
    runp smartctl --scan
    # health per scanned device
    priv smartctl --scan 2>/dev/null | awk '{print $1}' | while read -r dev; do
        { printf '\n$ (sudo) smartctl -H %s\n' "$dev"; priv smartctl -H "$dev"; } >> "$SEC"
    done
else
    echo "smartmontools not installed — SMART health deferred to Phase 2" >> "$SEC"
fi
# PERC
PERCCLI=""
for c in perccli2 perccli storcli2 storcli; do have "$c" && { PERCCLI="$c"; break; }; done
if [ -n "$PERCCLI" ]; then
    runp "$PERCCLI" /call show
    runp "$PERCCLI" /call/vall show all
    runp "$PERCCLI" /call/eall/sall show
    ok "PERC CLI ($PERCCLI) present — VD/PD details captured"
else
    warn "No perccli/storcli found — PERC VD layout, cache policy, and usable capacity UNVERIFIED (top unknown in the plan). Install Dell's perccli in Phase 2."
fi
# usable-capacity sanity: largest block device
LARGEST=$(lsblk -b -d -n -e7 -o SIZE 2>/dev/null | sort -n | tail -1)
if [ -n "${LARGEST:-}" ] && [ "$LARGEST" -gt 0 ]; then
    LARGEST_TB=$(awk -v b="$LARGEST" 'BEGIN{printf "%.1f", b/1e12}')
    echo "Largest block device: ${LARGEST_TB} TB" >> "$RESULTS"
    awk -v t="$LARGEST_TB" 'BEGIN{exit !(t>=7.0)}' && ok "RAID VD ≈ ${LARGEST_TB} TB — looks like ~8 TB usable: scale up lv_pcap/lv_index per plan §3.2" \
    || { awk -v t="$LARGEST_TB" 'BEGIN{exit !(t>=3.4)}' && ok "RAID VD ≈ ${LARGEST_TB} TB — matches worst-case ~4 TB usable model in §3" \
    || warn "Largest device is ${LARGEST_TB} TB — neither ~4 TB nor ~8 TB; re-derive the §3 storage layout from actual capacity"; }
fi

# ── 6. PCIe / NICs ───────────────────────────────────────────────────────────
section 06-nics.txt "PCIe / NICs"
run bash -c "lspci -nn | grep -i ethernet || true"
run lspci -tv
run ip -br link
run ip -br addr
run ip route
run ip -d link
IFACES=$(ls /sys/class/net | grep -v -E '^(lo|docker|veth|br-|virbr|tap|ovs)' || true)
for i in $IFACES; do
    {
        printf '\n──── interface: %s ────\n' "$i"
        printf '$ ethtool %s\n' "$i";        priv ethtool "$i" 2>&1
        printf '\n$ ethtool -i %s\n' "$i";   priv ethtool -i "$i" 2>&1
        printf '\n$ ethtool -l %s\n' "$i";   priv ethtool -l "$i" 2>&1
        printf '\n$ ethtool -g %s\n' "$i";   priv ethtool -g "$i" 2>&1
        printf '\n$ ethtool -k %s | offloads\n' "$i"; priv ethtool -k "$i" 2>&1 | grep -E 'gro|large-receive|tcp-segmentation|generic-segmentation|checksum|vlan'
        NUMA_F="/sys/class/net/$i/device/numa_node"
        [ -r "$NUMA_F" ] && printf '\nNUMA node: %s\n' "$(cat "$NUMA_F")"
        MAC=$(cat "/sys/class/net/$i/address" 2>/dev/null); printf 'MAC: %s\n' "${MAC:-?}"
    } >> "$SEC"
done
BNXT=$(for i in $IFACES; do d=$(priv ethtool -i "$i" 2>/dev/null | awk '/^driver:/{print $2}'); [ "$d" = "bnxt_en" ] && echo "$i"; done)
BNXT_COUNT=$(echo "$BNXT" | grep -c . 2>/dev/null); BNXT_COUNT=$(echo "${BNXT_COUNT:-0}" | head -1)
case "$BNXT_COUNT" in (''|*[!0-9]*) BNXT_COUNT=0;; esac
# This chassis (tag G8WFGH4) presents TEN bnxt_en ports: 8 x 10GBASE-T capture
# ports (two BCM57412 OCP quads) PLUS the 2 x 25G SFP28 pair (BCM57414, PCIe
# slot 9) carrying the management bond. Expecting exactly 8 fired a false WARN
# on 2026-09-02 — see state/inventory/r770-discovery-findings.md §2.2.
if [ "${BNXT_COUNT:-0}" -eq 10 ]; then
    ok "10 Broadcom (bnxt_en) ports detected — 8 capture + 2 management: $(echo "$BNXT" | tr '\n' ' ')"
elif [ "${BNXT_COUNT:-0}" -eq 8 ]; then
    ok "8 Broadcom (bnxt_en) ports detected: $(echo "$BNXT" | tr '\n' ' ')"
elif [ "${BNXT_COUNT:-0}" -gt 0 ]; then
    warn "Broadcom bnxt_en ports found: ${BNXT_COUNT} (expected 8 capture, or 10 including the 2x25G management pair) — check OCP adapter seating/BIOS enumeration"
else
    warn "No bnxt_en interfaces detected — capture adapters not visible (driver, seating, or naming; investigate before Phase 9)"
fi
# NUMA locality of capture ports (drives §8 socket split)
NODES=$(for i in $BNXT; do cat "/sys/class/net/$i/device/numa_node" 2>/dev/null; done | sort -u | tr '\n' ' ')
[ -n "${NODES// }" ] && echo "Capture-port NUMA node(s): ${NODES}" | tee -a "$RESULTS"
# media type check (discrepancy resolved 2026-09-03: BASE-T copper on this chassis)
for i in $BNXT; do
    PORTS=$(priv ethtool "$i" 2>/dev/null | grep -E 'Supported ports' || true)
    echo "$i: $PORTS" >> "$OUT/06b-media-types.txt"
done
[ -s "$OUT/06b-media-types.txt" ] && echo "Capture-NIC media: see 06b-media-types.txt. Settled 2026-09-03 for tag G8WFGH4 — BCM957412-N410TGI0S is 4x10GBASE-T copper (MEDIA=TP); the 2x25G SFP28 pair reports FIBRE and is the management bond. Re-verify only if adapters change." | tee -a "$RESULTS"

# ── 7. current management path (must be protected) ───────────────────────────
section 07-mgmt-path.txt "Current management path"
run who
run bash -c "ss -tnp 2>/dev/null | grep ':22 ' | head -5 || true"
run ip route get 1.1.1.1
run ls -l /etc/netplan/
runp bash -c 'cat /etc/netplan/*.yaml 2>/dev/null'
DEFIF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(x=1;x<=NF;x++) if($x=="dev") print $(x+1)}' | head -1)
DEFIP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(x=1;x<=NF;x++) if($x=="src") print $(x+1)}' | head -1)
if [ -n "${DEFIF:-}" ]; then
    ok "Management/default path: dev ${DEFIF}, src ${DEFIP:-?} — record this; it must survive every later phase"
    if echo "$BNXT" | grep -qx "$DEFIF"; then
        fail "Default route rides a Broadcom CAPTURE port (${DEFIF}) — management must move to the integrated NIC before capture config begins"
    fi
else
    warn "No default route found — box may be console-only right now; establish mgmt path before Phase 5"
fi
GW=$(ip route 2>/dev/null | awk '/^default/{print $3;exit}')
if [ -n "${GW:-}" ]; then
    if ping -c1 -W2 "$GW" >/dev/null 2>&1; then ok "Default gateway ${GW} responds to ping"; else warn "Default gateway ${GW} did not answer ping (may be filtered)"; fi
fi
if have resolvectl; then run resolvectl status; fi
if getent hosts archive.ubuntu.com >/dev/null 2>&1; then ok "DNS resolution works (archive.ubuntu.com)"; else warn "DNS resolution failed — fix before package phases"; fi

# ── 8. iDRAC visibility (read-only) ──────────────────────────────────────────
section 08-idrac.txt "iDRAC (read-only, from host)"
if have ipmitool; then
    runp ipmitool lan print 1
    runp ipmitool mc info
    IDRAC_IP=$(priv ipmitool lan print 1 2>/dev/null | awk -F': ' '/^IP Address +:/{print $2}')
    if [ -n "${IDRAC_IP:-}" ] && [ "$IDRAC_IP" != "0.0.0.0" ]; then
        ok "iDRAC reachable via IPMI, IP ${IDRAC_IP} — VERIFY console login out-of-band before any network change"
    else
        warn "iDRAC IP not readable/unset via IPMI — verify iDRAC recovery path manually before Phase 5"
    fi
else
    warn "ipmitool not installed — iDRAC state unverified from host; confirm OOB console access manually before Phase 5"
fi

# ── 9. health / errors ───────────────────────────────────────────────────────
section 09-health.txt "Health / errors"
runp bash -c 'dmesg --level=err,warn | tail -60'
run bash -c "journalctl -p err -b --no-pager 2>/dev/null | tail -40 || true"
ERRS=$(priv dmesg --level=err 2>/dev/null | grep -c . 2>/dev/null); ERRS=$(echo "${ERRS:-0}" | head -1)
case "$ERRS" in (''|*[!0-9]*) ERRS=0;; esac
[ "$ERRS" -eq 0 ] && ok "No kernel-level errors this boot" || warn "${ERRS} kernel error line(s) this boot — review 09-health.txt"
if have sensors; then run sensors; fi

# ── 10. tool availability for later phases ───────────────────────────────────
section 10-tools.txt "Tooling present vs needed later"
# Check BINARY names, not package names: 'lvm2' is a package and is never on
# PATH, so it always reported MISSING even on this host, which is already
# running LVM. The binary to look for is 'lvs'.
for t in ethtool nvme smartctl numactl ipmitool jq git curl tcpdump tshark iperf3 mtr lvs docker virsh tc; do
    if have "$t"; then echo "present: $t" >> "$SEC"; else echo "MISSING (install in its phase): $t" >> "$SEC"; fi
done

# ── summary / bundle ─────────────────────────────────────────────────────────
{
    echo
    echo "================ PRECHECK SUMMARY ================"
    echo "Host: $HN   Time: $(date -Is)"
    echo "PASS: $PASS   WARN: $WARN   FAIL: $FAIL"
    echo "Details: $RESULTS"
    if [ "$FAIL" -gt 0 ]; then
        echo "RESULT: FAIL — resolve FAIL items before proceeding to Phase 2/3."
    elif [ "$WARN" -gt 0 ]; then
        echo "RESULT: PROCEED WITH CAUTION — review WARN items; several are expected pre-install."
    else
        echo "RESULT: CLEAN — proceed to Phase 2 (BIOS/firmware assessment)."
    fi
    echo "=================================================="
} | tee -a "$RESULTS"

tar -czf "${OUT}.tar.gz" "$OUT" 2>/dev/null && \
    echo "Full report bundle: ${OUT}.tar.gz  — send this back for analysis."

exit 0
