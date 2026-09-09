# R770 Discovery Findings — plan impacts

**Date:** 2026-09-03 · **Host:** `testbed` · **Service tag:** `G8WFGH4`
**Evidence:** `r770-precheck-report-2026-09-02.md` (OS-side, `r770-precheck.sh` v2, 14 PASS / 7 WARN / 0 FAIL) · `r770-idrac-inventory-G8WFGH4.md` (iDRAC XML export, pulled 2026-09-03)

Every statement below is traceable to one of those two files. Where they disagree with the plan, **discovery wins and the plan has been updated** — the edits made from this analysis are listed in §6.

---

## 1. Top unknowns — disposition

| # | Unknown (PRD §11) | Status | Finding |
|---|---|---|---|
| 1 | Usable storage capacity (4 vs 8 TB) | **RESOLVED** | RAID1 across 2 × 7.68 TB KIOXIA E3.S NVMe → **one VD, 7,680,877,920,256 B ≈ 7.68 TB (6.99 TiB) usable**. The 8 TB branch of the plan applies, not the 4 TB worst case. |
| 2 | PERC model / firmware / TRIM | **RESOLVED (model+fw)** | **PERC H975i Front**, firmware `8.14.0.0.28-40`, energy pack OK, patrol read Stopped, write cache Write Back, read cache No Read Ahead. TRIM passthrough still unverified — needs perccli in Phase 2. |
| 3 | Capture NIC media (SFP+ vs BASE-T) | **RESOLVED** | **10GBASE-T copper (RJ45)**. Two OCP quads, `BCM957412-N410TGI0S`, BCM57412 silicon; `ethtool` reports `MEDIA=TP` on all 8. The catalog discrepancy is settled: 57412 chip on a 4×10GBASE-T card. **Copper TAPs / RJ45 SPAN — do not order optics.** |
| 4 | NUMA locality of OCP adapters + PERC | **RESOLVED** | PERC `0000:ae:00.0` → **node 0**. OCP Slot 10 (`0000:84/85`) → **node 0**. OCP Slot 4 (`0001:36/37`, PCI segment 1) → **node 1**. Mgmt NIC Slot 9 (`0000:5c`) → **node 0**. **The capture quads are split across sockets** — the case §12 risk 6a flagged. See §3. |
| 5 | iDRAC recovery path verified | **PARTIAL** | Address known: `https://192.168.76.231:443`, DNS `testbed-idrac`, MAC `28:00:af:df:bc:8c`, fw 1.30.20.10. **Not yet proven reachable from the operator's position**, and it is on a different subnet from management (192.168.76.0/24 vs 10.10.10.0/24). Still a Phase 5 gate. |
| 6 | Dell service tag | **RESOLVED** | `G8WFGH4` (express service code 35366715688). Closes runbook Step 0E. |
| 7 | Licensed GNS3 appliance entitlements | OPEN (operator) | Unchanged. |
| 8 | Site transfer-media scan policy | OPEN (operator) | Unchanged. |

## 2. Findings that contradict the written design

### 2.1 Management is an LACP bond + VLAN, not the integrated NIC

Buildout plan §4.1 said "Integrated NIC → static IP via Netplan… the only host IP on physical hardware." Reality:

```
lacp-trunk        bonding   up   50000     (802.3ad over eno17295np0 + eno17305np1)
lacp-trunk.10     802.1Q    up   50000     10.10.10.31/24
default via 10.10.10.1 dev lacp-trunk.10 proto static
```

The two slaves are the **BCM57414 2×25G SFP28** ports in PCIe Slot 9 (node 0), carrying Dell `D0R73` SFP28 transceivers — `MEDIA=FIBRE`, 25 Gbps each. The integrated NIC is not carrying management. Netplan lives in a single file, `/etc/netplan/00-h2-init.yaml`, mode `0600`.

**Impact:** Phase 5 is materially riskier than written — a bond and a tagged VLAN, not a single addressed port. Any change must preserve `lacp-trunk` membership, 802.3ad mode, and the VLAN-10 tag, and `netplan try` is mandatory. Recorded in the plan's §4.1 and §12.

### 2.2 Ten Broadcom ports, not eight

Precheck WARNed `Broadcom bnxt_en ports found: 10 (expected 8)`. The iDRAC inventory explains it: 8 × 10GBASE-T (OCP Slots 4 and 10) **plus** 2 × 25G SFP28 (Slot 9) = 10 `bnxt_en` interfaces. Eight are capture candidates; two are management. **This is not a fault** — the precheck script's expectation was wrong and has been fixed.

### 2.3 The OS is already installed and LVM is already laid out

Not a greenfield install. Ubuntu 24.04.4, kernel 6.8.0-136, up 12 days, UEFI boot, **Secure Boot disabled**, hostname `testbed`.

```
sda (7T) ├─sda1 1G vfat /boot/efi ├─sda2 2G ext4 /boot └─sda3 7T LVM2 → VG ubuntu-vg0
  lv-root 50G /   lv-home 84.9G /home   lv-var 6G /var
  lv-varlog 2G /var/log   lv-varlogaudit 2G /var/log/audit   lv-tmp 2G /tmp
```

≈147 GB allocated of ≈6.99 TiB → **≈6.85 TB of free extents in `ubuntu-vg0`**.

**Impact — this is a significant de-risk.** Phase 3 no longer needs repartitioning, a RAID rebuild, or a reinstall: the lab volumes are `lvcreate` calls against free extents in the existing VG. The plan's VG name `vg_lab` is wrong; the VG is **`ubuntu-vg0`** and the plan has been changed to use it rather than rename it (renaming a mounted root VG is gratuitous risk). `lv-var` at 6 GB is undersized against the plan's 50 GB and should be grown online.

## 3. The socket-split decision this forces

The capture quads land on **different NUMA nodes** (Slot 10 → node 0, Slot 4 → node 1), which §12 risk 6a said would require revisiting the split. With the PERC on node 0 and the management bond on node 0:

**Recommendation: make node 0 the capture/analysis socket and use OCP Slot 10's four ports as the primary capture feeds.** Capture NIC → CPU → OpenSearch/Arkime → PERC then stays entirely node-local; PCAP writes never cross UPI. OCP Slot 4's four ports (node 1) stay as spare/secondary feeds — usable, but a packet arriving there crosses UPI before it is written, so they are the wrong choice for the highest-rate feed.

**Watch the CPU numbering — it is interleaved, not blocked:**

```
node 0 cpus: 0 2 4 6 8 ... 62   (all even)
node 1 cpus: 1 3 5 7 9 ... 63   (all odd)
node distances: 0→1 = 21
```

Every `cpuset-cpus`, `vcpupin`, and IRQ-affinity value must use these explicit lists. A range like `0-15` straddles **both** sockets and would silently defeat the entire split.

Per-node memory: node 0 = 64,068 MB, node 1 = 64,496 MB.

## 4. New risks discovery surfaced (in none of the prior documents)

| Risk | Evidence | Why it matters |
|---|---|---|
| **PERC encryption is enabled with a Security Key assigned** | iDRAC: `Security status: Security Key Assigned`, `Encryption mode: Enabled` | Key custody is unknown. If the key is lost or the controller is replaced without it, **the VD is unrecoverable** — including evidence-grade PCAP. Determine LKM vs SEKM and record custody/escrow before any case data lands. Phase 2 gate. |
| **NVMe drives negotiated x2 of x4 capable link width** | iDRAC physical disks: `Link (neg/cap): x2 / x4` | Half the available PCIe width per drive, so roughly half the per-drive bandwidth. May be backplane bifurcation by design on a 16-slot backplane, or a seating issue. Sustained capture write throughput is the workload that would notice. Investigate in Phase 2 before tuning anything. |
| **IPMI-over-LAN is disabled** | iDRAC: `IPMI-over-LAN: Disabled`, `Serial-over-LAN: Enabled` | `ipmitool` will not work out-of-band. OOB automation must use **Redfish** or the web UI. The package stays in the bundle (in-band KCS still works) but no runbook step may assume `ipmitool -H`. |
| **iDRAC is on a different subnet from management** | iDRAC `192.168.76.231` vs mgmt `10.10.10.31/24` | The recovery path is not reachable from the management subnet without a route. Confirm the operator's access path **before** Phase 5 touches Netplan — that is the whole point of the gate. |
| **Persistent `sdb` / `sr0` I/O errors** | `08-health.txt`: `sd 5:0:0:0: [sdb] access beyond end of device`, `FAT-fs (sdb1): FAT read failed`, repeated `Power-on or device reset occurred` | Traced to iDRAC **virtual media** on the Renesas uPD720201 USB 3.0 controller — not the RAID VD, not the NVMe. Harmless but it pollutes `dmesg` and inflates the precheck's kernel-error count. Detach virtual media; re-baseline health in Phase 2. |
| **`pam_lastlog.so` missing** | `journalctl -p err`: `PAM unable to dlopen(pam_lastlog.so)` | Ubuntu 24.04 dropped `pam_lastlog`; a stale line remains in the PAM stack. Cosmetic, logs an error on every login. Clean up in Phase 4. |
| **`systemd-networkd-wait-online` timeout** | `journalctl`: `Timeout occurred while waiting for network connectivity` | Expected — it waits on all ten links and eight capture ports are legitimately down with no carrier. Bound it to `lacp-trunk.10` in Phase 5 so boots stop stalling. |

## 5. Baselines captured for later phases

- **Firmware:** BIOS `1.7.5` (2026-01-16) · iDRAC/LC `1.30.20.10` · CPLD `109.125.104` · PERC `8.14.0.0.28-40` · backplane `1.92` · NIC family `233.1.181.0` (pkg) / `233.0.195.0` · PSU `1408`. Phase 2 compares against Dell's current DUPs for tag G8WFGH4.
- **NIC rings/queues** (`eno16795np0`, representative): RX ring 511 of max **2047**, RX Jumbo 2044 of 8191, TX 511 of 2047; channels combined 16 of max **74** (RX/TX pre-set max 37 each). The plan's `ethtool -G <iface> rx <max>` now has a real number: **2047**.
- **Offload state as found:** `gro on`, `rx-gro-hw on`, `lro off`, `tso on`, `gso on`, `rx/tx-vlan-offload on`, checksums on. Capture-prep must turn these off **on capture ports only**.
- **CPU:** 2 × Xeon 6515P, 16c/32t each = 32c/64t, base 2.3 GHz / max 3.8 GHz as reported by `lscpu` (iDRAC advertises 4.3 GHz turbo), L3 144 MiB total. `vmx` present, IOMMU/DMAR active, `/dev/kvm` present.
- **Memory:** 128 GB as 8 × 16 GB Micron RDIMM DDR5-6400, single rank, slots A1–A4 / B1–B4 — **4 of 8 channels per socket**. 32 slots total, max 8 TB, OptimizerMode. The half-channel bandwidth caveat in plan §8 is confirmed, and the upgrade path is far wider than the plan assumed.
- **Chassis:** 2 × 1100 W redundant PSUs (209 V in), 6 fans, all OK, fully redundant. **Backplane has 16 slots with 2 populated — 14 free bays**, which is the concrete escape hatch for plan §12 risk 5 (dedicating future NVMe to PCAP).
- **Tools already present on the host:** `ethtool numactl mokutil jq git curl tcpdump mtr tc`. Missing and deferred to their phases: `nvme smartctl ipmitool tshark iperf3 docker virsh sensors`.

## 6. Documents changed from these findings

| Document | Change |
|---|---|
| `state/BUILD-STATE.md` | Connection facts filled in; Phase 1 → VERIFIED with evidence; Phase 2 → READY; unknowns table re-dispositioned; log entry. |
| `PRD.md` | §4 target hardware replaced with verified values; §11 risks re-ranked, resolved ones struck, new ones added; status line. |
| `docs/plans/r770-network-lab-buildout.md` | §3.1 capacity model recomputed for 7.68 TB; §3.2 layout rebuilt against `ubuntu-vg0` free extents; §4.1 physical network corrected to the bond/VLAN reality; §4.2 ring size resolved to 2047; §8 socket split decided; §12 risks updated. |
| `docs/plans/r770-staging-runbook.md` | Step 0E closed with the service tag; Step 4 Dell list annotated with current firmware baselines to compare against. |
| `docs/plans/r770-dependency-manifest.md` | §7 Dell section: service tag recorded, perccli confirmed as the H975i tool, Redfish noted over IPMI-over-LAN. |
| `scripts/r770-precheck.sh` | Two bugs fixed: the hard-coded 8-port expectation (10 is correct here) and the `lvm2` presence check (wrong binary name). Media-type WARN text updated now that the question is settled. |

## 7. Still open after this pass

1. **iDRAC reachability from the operator's position** — the Phase 5 gate. Address is known; a login has not been demonstrated.
2. **PERC encryption key custody** (LKM vs SEKM, who holds it, where it is escrowed) — Phase 2, blocking for evidence-grade data.
3. **NVMe x2/x4 link width** — Phase 2 investigation.
4. **TRIM passthrough on the VD** — needs perccli, Phase 2.
5. **SSH alias/target of record** — the precheck ran on the host; `CLAUDE.md` refers to `ssh r770` while the host calls itself `testbed` at `10.10.10.31`. Confirm the alias the operator actually uses.
6. **Licensed GNS3 appliance entitlements** and **site media-scan policy** — operator items, unchanged.

---

## Correction, 2026-09-09 — unit slip in the free-extent figure

§2.3 above records "≈6.85 TB of free extents in `ubuntu-vg0`". The digits are right and the unit is
wrong: the figure is ≈6.85 **TiB**, and the value the design carries forward
(`docs/plans/r770-network-lab-buildout.md` :93, :121, :341) is **≈6.84 TiB**. Read as written, 6.85 TB
is only 6.23 TiB — understating the free extents by ~600 GiB, on the side that would undersize the
lab volumes. This is a unit slip, not a re-measurement: nothing was re-read from the host, and
≈6.99 TiB total less the ≈147 GiB of existing LVs is ≈6.84 TiB, which is the arithmetic the original
line already did. The line above is left as originally written — this record is append-only — but the
figure to use is **≈6.84 TiB**.
