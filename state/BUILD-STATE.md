# Build State — R770 Sim Lab

**Single source of build truth.** Updated by Claude Code after every phase action; statuses only advance with evidence (`state/inventory/`). Statuses: NOT STARTED · READY · BLOCKED · APPLIED · VERIFIED.

## Connection facts

| Item | Value |
|---|---|
| Host name | `testbed` (Ubuntu 24.04.4, kernel 6.8.0-136) |
| Service tag | `G8WFGH4` (express service code 35366715688) |
| Management address | **10.10.10.31/24** on `lacp-trunk.10` — VLAN 10 over an 802.3ad bond of `eno17295np0` + `eno17305np1` (2 × 25G SFP28, PCIe Slot 9) |
| Default gateway | 10.10.10.1 *(did not answer ping — may be filtered)* |
| Netplan of record | `/etc/netplan/00-h2-init.yaml` (mode 0600, single file) |
| R770 SSH target | *`CLAUDE.md` says `ssh r770`; the host calls itself `testbed` at 10.10.10.31 — confirm the alias the operator uses before remote work* |
| iDRAC | `https://192.168.76.231:443` · DNS `testbed-idrac` · MAC `28:00:af:df:bc:8c` · fw 1.30.20.10 · **IPMI-over-LAN disabled → use Redfish, not `ipmitool -H`** · **reachability from the operator's position NOT yet demonstrated** |
| Staging host | **VM 9770 `r770-staging`** on Proxmox `proxmox` (192.168.4.21) — Ubuntu 24.04.4, Docker CE 29.8.0, 6 cores / 8 GiB / 400 GiB, at **192.168.4.28**. Built + snapshotted `pre-fetch` 2026-09-04; evidence in `inventory/staging-vm-9770.md`. *(Not this session's container — LXC 101 is a 40 GiB container with no Docker.)* |
| Current bundle | **`bundle-20260908` BUILT on VM 9770** — 15 GB, 1617 files, `verify` PASS WITH WARNINGS (exit 2), Ubuntu ISO GPG-verified. **Not yet transferred to the R770** — blocked on Dell downloads + licensed appliances + media. See `inventory/bundles.md` |

## Phases

| # | Phase | Depends on | Status | Evidence |
|---|---|---|---|---|
| 1 | Hardware & OS discovery (read-only) | — | **VERIFIED** | `inventory/r770-precheck-report-2026-09-02.md`, `inventory/r770-idrac-inventory-G8WFGH4.md`, analysis in `inventory/r770-discovery-findings.md` |
| 2 | BIOS/firmware/iDRAC assessment; RAID VD verification | 1 | **READY** | — |
| 3 | Storage: LVM/filesystem layout | 1,2 | **READY** *(no repartitioning needed — ≈6.84 TiB free extents in existing VG `ubuntu-vg0`)* | — |
| 4 | Base OS: users, SSH hardening, UFW, packages, auditd | 3 | NOT STARTED | — |
| 5 | Management networking (Netplan, dnsmasq, chrony) | 4 | **BLOCKED** — iDRAC reachability unproven; mgmt is a bond + tagged VLAN | — |
| 6 | Docker Engine + Compose on lv_docker | 4 | NOT STARTED | — |
| 7 | KVM/libvirt + lab bridges + NAT zone | 5 | NOT STARTED | — |
| 8 | GNS3 server + service + proxy publication | 6,7 | NOT STARTED | — |
| 9 | Capture-port prep + drop-stat plumbing | 5 | NOT STARTED | — |
| 10 | Malcolm deployment + live capture + retention | 6,9,3 | NOT STARTED | — |
| 11 | Virtual mirror feed + imported-PCAP workflow | 10,7 | NOT STARTED | — |
| 12 | WAN impairment script library | 7 | NOT STARTED | — |
| 13 | Nginx portal + TLS + `.lab` names + docs site | 5,6 | NOT STARTED | — |
| 14 | Monitoring/alerting + capture validation suite | 10,13 | NOT STARTED | — |
| 15 | Backup jobs + restore test | 3,13 | NOT STARTED | — |
| 16 | Full validation pass + baseline + build document | all | NOT STARTED | — |

## Verified hardware of record

| Item | Value |
|---|---|
| Chassis | Dell PowerEdge R770, 2U, 17G monolithic · BIOS 1.7.5 (2026-01-16) · UEFI, **Secure Boot disabled** |
| CPU | 2 × Intel Xeon 6515P — 16c/32t each = **32 cores / 64 threads**, L3 144 MiB total, VT-x + IOMMU active, `/dev/kvm` present |
| NUMA | 2 nodes, **interleaved numbering**: node 0 = even CPUs (64,068 MB), node 1 = odd CPUs (64,496 MB), distance 21 |
| Memory | 128 GB = 8 × 16 GB Micron RDIMM DDR5-6400 single-rank (A1–A4, B1–B4) — **4 of 8 channels per socket**; 8/32 slots used, max 8 TB |
| Storage controller | **PERC H975i Front**, fw 8.14.0.0.28-40, Write Back / No Read Ahead, energy pack OK, **encryption Enabled with Security Key Assigned** |
| Virtual disk | `vd0` — **RAID1, 7,680,877,920,256 B ≈ 7.68 TB (6.99 TiB) usable**, 64 KB stripe, SSD, PCIE, redundancy OK |
| Physical disks | 2 × KIOXIA E3.S NVMe 2.0, ≈7.68 TB each, 100 % endurance, Online — **link negotiated x2 of x4 capable** |
| Backplane | 16 slots, **2 populated → 14 free bays**, fw 1.92 |
| Existing LVM | VG `ubuntu-vg0` on `/dev/sda3`; lv-root 50G, lv-home 84.9G, lv-var 6G, lv-varlog 2G, lv-varlogaudit 2G, lv-tmp 2G → **≈6.84 TiB free extents** |
| Capture NICs | 8 × **10GBASE-T copper (RJ45)** — 2 × Broadcom BCM57412 OCP quads (`BCM957412-N410TGI0S`). **OCP Slot 10 → NUMA node 0; OCP Slot 4 → NUMA node 1.** All 8 currently down, no carrier |
| Management NIC | Broadcom BCM57414 2 × 25G SFP28 (PCIe Slot 9, **node 0**), Dell D0R73 transceivers, bonded 802.3ad as `lacp-trunk` (50 Gbps) |
| PERC locality | `0000:ae:00.0` → **NUMA node 0** (same node as the mgmt bond and OCP Slot 10) |
| Power / cooling | 2 × 1100 W redundant PSUs (209 V), 6 fans, all OK, fully redundant |
| NIC tuning headroom | RX ring 511 of max **2047** (jumbo 2044/8191); channels combined 16 of max **74** |

## Top unknowns (PRD §11)

| Unknown | Status |
|---|---|
| Usable RAID capacity (~4 vs ~8 TB) | **RESOLVED — 7.68 TB usable (RAID1, single VD)** |
| Actual PERC model/firmware/TRIM | **RESOLVED for model + firmware** (H975i Front, 8.14.0.0.28-40); TRIM passthrough still needs perccli in Phase 2 |
| Capture NIC media (SFP+ vs BASE-T) | **RESOLVED — 10GBASE-T copper. Order copper TAPs / RJ45 SPAN, not optics** |
| NUMA locality of OCP adapters + PERC | **RESOLVED — PERC + Slot 10 + mgmt on node 0; Slot 4 on node 1 (quads split across sockets)** |
| iDRAC recovery path verified | **PARTIAL** — address known, on a different subnet (192.168.76.0/24); login not yet demonstrated. Phase 5 gate |
| Dell service tag for firmware downloads | **RESOLVED — G8WFGH4** (closes runbook Step 0E) |
| PERC encryption key custody (LKM vs SEKM, escrow) | **OPEN — NEW.** Blocking for evidence-grade data; Phase 2 |
| NVMe x2-of-x4 negotiated link width | **OPEN — NEW.** Phase 2 investigation |
| Licensed GNS3 appliance entitlements | OPEN (operator) |
| Site transfer-media scan policy | OPEN (operator) |

## Log

*(append one line per action: date · phase · what happened · evidence file)*

- 2026-09-03 · Phase 1 · Ingested `r770-precheck.sh` v2 output (2026-09-02, 14 PASS / 7 WARN / 0 FAIL) and the iDRAC hardware inventory for tag G8WFGH4; five of eight top unknowns resolved, three design assumptions corrected, three new risks recorded. Phase 1 → VERIFIED. · `inventory/r770-discovery-findings.md`
- 2026-09-04 · Bundle prep · Reviewed all 11 pins (4 bumped: Malcolm 26.08.0, alertmanager v0.34.0, cadvisor v0.60.5, FRR 10.7.1); built and verified staging VM 9770 on Proxmox with Docker CE, 8 G swap, thin-pool watchdog and a `pre-fetch` snapshot. All evidence gates passed incl. in-container apt egress and 376 G free. · `inventory/pin-review-2026-09-04.md`, `inventory/staging-vm-9770.md`
- 2026-09-08 · Bundle-1 · Cut `bundle-20260908` on staging VM 9770: 15 GB, 1617 files, all 10 steps complete. Two failures en route — an abandoned cadvisor registry (fixed to ghcr.io; the pin was already broken before the bump) and a non-reproducible exit-23 at [6/10]. Manifest regenerated with the tested tool; `verify` PASS WITH WARNINGS (2 docs-mirror WARNs, both accepted); Ubuntu ISO GPG signature good. · `inventory/bundles.md`
- 2026-09-09 · Bundle prep · Integrity-gate Task 5 (`r770-pin-check.sh`, upstream pin-drift reporting against the pins parsed out of `r770-offline-fetch.sh`) remains unbuilt. Tasks 1–4 shipped in `0938174` (2026-09-04); Task 6 shipped later, in `9f84a37` (2026-09-09); Task 5 and Task 7 (wire the gate into the docs) never shipped. · `work/plans/archive/2026-09-03-bundle-integrity-gate.md`
