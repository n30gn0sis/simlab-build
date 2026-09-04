# PRD — Sim Lab: Air-Gapped Network Simulation & Packet-Capture Server (Dell R770)

**Version:** 1.1 · 2026-09-03
**Owner:** Stephen (lab operator)
**Status:** Approved for build — **Phase 1 (discovery) VERIFIED 2026-09-03**; §4 is now measured fact, §11 re-dispositioned
**Sources distilled:** project build-agent charter, `docs/plans/r770-network-lab-buildout.md`, `docs/plans/r770-offline-supply.md`, `docs/plans/r770-dependency-manifest.md`, `docs/plans/r770-staging-runbook.md`, `docs/analyst-wiki/`

---

## 1. Problem & Purpose

Analysts need a single, self-contained platform for realistic network work that cannot depend on internet access: full-packet capture and analysis of TAP/SPAN feeds and imported PCAPs, simulation of arbitrary network topologies, WAN impairment for protocol behavior studies, and a workbench for case artifacts — all on one air-gapped Dell PowerEdge R770.

Today this capability doesn't exist as a coherent system. The purpose of this project is to design, build, validate, and document that server, and to maintain the offline supply chain that keeps it fed with software, rules, and images.

## 2. Users

| User | Needs |
|---|---|
| **Network analysts** | Search captured traffic (Arkime), read protocol metadata (Zeek), visual exploration (Dashboards), import/export PCAP, build GNS3 topologies, apply WAN impairments, per-analyst workspaces |
| **Lab operator** (also the builder) | Repeatable build, monitoring/alerting, retention enforcement, backup/restore, bundle refresh cycles, account provisioning |
| **Claude Code (build agent)** | A directory of rules, plans, commands, and state that lets it execute the build safely from a staging host over SSH — see `CLAUDE.md` |

## 3. Product Overview

One air-gapped Ubuntu Server 24.04 LTS host that concurrently provides:

1. **Capture & analysis** — Malcolm v26.08.0 (Docker Compose: Arkime, Zeek, OpenSearch + Dashboards, Logstash/Filebeat; Suricata present but disabled) ingesting up to 4 active physical 10GbE TAP/SPAN feeds plus a virtual mirror of lab traffic plus imported PCAPs.
2. **Simulation** — GNS3 server v3.0.6 (venv install) running QEMU appliances (VyOS, MikroTik CHR, OPNsense, FRR, OpenWrt; licensed Cisco/Fortinet/PA images if entitled) and Docker nodes over KVM/libvirt.
3. **WAN emulation** — `tc`/`netem` profile library (`wan-apply` / `wan-show` / `wan-clear`) with branch-wan, satellite, poor-broadband, and asymmetric profiles.
4. **Services** — Nginx portal (`portal.lab` → `malcolm.lab`, `gns3.lab`, `monitoring.lab`, docs), dnsmasq (`.lab`, no forwarders), chrony (lab time source), Prometheus/Grafana/Alertmanager monitoring, Restic backup, MkDocs analyst wiki, internal CA (easy-rsa).

All software arrives via a versioned offline bundle built on an internet-connected Ubuntu 24.04 staging VM by `scripts/r770-offline-fetch.sh` (v3.3: resumable, proxy-aware, cross-bundle seeding), transferred on checksummed ext4 media.

## 4. Hardware of Record (**verified 2026-09-03** — evidence in `state/inventory/`)

Every line below is measured, not assumed. Sources: `r770-precheck-report-2026-09-02.md` (host, 14 PASS / 7 WARN / 0 FAIL) and `r770-idrac-inventory-G8WFGH4.md` (iDRAC export); analysis in `r770-discovery-findings.md`.

- **Dell PowerEdge R770**, 2U, 17G · service tag **`G8WFGH4`** · BIOS 1.7.5 (2026-01-16) · UEFI, Secure Boot disabled · 2 × 1100 W redundant PSUs, 6 fans, all OK
- **2 × Intel Xeon 6515P** — 16c/32t each = **32 physical cores / 64 threads**, L3 144 MiB, VT-x + IOMMU active. **2 NUMA nodes with interleaved numbering**: node 0 = even CPUs, node 1 = odd CPUs (distance 21) — pinning by contiguous range is a trap
- **128 GB DDR5-6400** as 8 × 16 GB Micron single-rank RDIMMs (A1–A4, B1–B4) — 4 of 8 channels per socket, so per-socket bandwidth is ~half the platform's; **8 of 32 slots used, max 8 TB**, so the 256 GB upgrade is a straightforward purchase
- **Storage: PERC H975i Front** (fw 8.14.0.0.28-40, Write Back), one **RAID-1 VD of 7.68 TB (6.99 TiB) usable** over 2 × KIOXIA E3.S NVMe 2.0 at 100 % endurance. **Encryption is Enabled with a Security Key Assigned — custody unknown (see §11).** Drives negotiated **x2 of a x4-capable link**. **14 of 16 backplane bays free.** Ubuntu is already installed; VG `ubuntu-vg0` has ≈**6.84 TiB of free extents**, so the storage phase needs no repartitioning
- **Capture: 8 × 10GBASE-T copper (RJ45)** — 2 × Broadcom BCM57412 OCP quads (`BCM957412-N410TGI0S`). **OCP Slot 10 → NUMA node 0** (same node as the PERC; primary feeds), **OCP Slot 4 → NUMA node 1** (secondary). **Copper TAPs, not optics**
- **Management: an 802.3ad bond, not the integrated NIC** — 2 × 25G SFP28 (Broadcom BCM57414, PCIe Slot 9, node 0, Dell D0R73 transceivers) bonded as `lacp-trunk`, VLAN 10 as **`lacp-trunk.10` at 10.10.10.31/24**, gateway 10.10.10.1
- **iDRAC** (OOB recovery) — `https://192.168.76.231:443`, fw 1.30.20.10. **IPMI-over-LAN disabled → Redfish, not `ipmitool -H`.** On a different subnet from management, and **not yet demonstrated reachable** — the Phase 5 gate

## 5. Goals

1. Reliable, drop-accounted packet capture on dedicated, unaddressed, promiscuous ports (offloads disabled on capture ports only; AF_PACKET first, escalate only on measured loss).
2. Concurrent heavy capture and large GNS3 topologies via a NUMA socket split — **decided from discovery: node 0 is capture/analysis (it owns the PERC, the management bond and OCP Slot 10), node 1 is the lab socket** (≈12.5 infrastructure cores / 16 guaranteed lab cores; ~64 GB infra / ~48 GB lab RAM). Node numbering is interleaved (node 0 = even CPUs), so pinning must use explicit lists, never ranges.
3. Evidence protection: `raw/` PCAP auto-deletes oldest-first at a free-space floor; `cases/`, `archived/`, and `/srv/work/` never auto-delete; each workload on its own LVM volume so nothing starves anything else.
4. Full offline operation: local APT repo only, no snapd, no phone-home, local time and DNS authority, internal CA, all updates by bundle.
5. Repeatability and recoverability: config repo (`/opt/network-lab-config/`, git), idempotent scripts, documented rollback for every change, nightly Restic backups of configs/projects/curated artifacts.
6. A complete validation suite — the build is not done because services start; it is done when every capability is proven (see §10).

## 6. Non-Goals / Descoped (decisions of record, 2026-08-31)

- **GeoIP enrichment** — descoped (no MaxMind account); geo fields absent in Arkime/Dashboards. Reversible via fetch-script v2 block.
- **Suricata alerting** — shipped inside Malcolm but disabled at initial build; enabling requires a CPU-budget re-check.
- **Windows endpoint VMs / virtio-win** — descoped.
- **Open vSwitch** — not installed initially (package cached); Linux bridges + `tc-mirred` until a concrete need appears.
- **DPDK/PF_RING/AF_XDP** — only if measured AF_PACKET loss demands escalation.
- **Huge pages, CPU pinning beyond the socket split** — only on measured need.
- **Full APT mirror** — curated bundle chosen; unplanned `apt install` on the gapped box fails by design.
- **Line-rate retention of 4 × 10GbE** — explicitly not a goal; retention is bounded and enforced.

## 7. Architecture Requirements (summary — authoritative detail in `docs/plans/r770-network-lab-buildout.md`)

**Network zones (strict):** iDRAC OOB (192.168.76.0/24) · management (**`lacp-trunk.10` — an 802.3ad bond of 2 × 25G with VLAN 10, 10.10.10.31/24 — the only physical host IP**) · capture (8 × 10GBASE-T ports, no IP ever, never bridged to labs) · lab fabric (virtual bridges) · lab NAT (firewalled, default-off). Lab traffic reaches Malcolm only via a dedicated virtual mirror feed.

**Storage:** new LVs in the **existing VG `ubuntu-vg0`** on the RAID-1 VD (no repartitioning — ≈6.84 TiB of free extents): `/var/lib/docker` 250 GiB, `/data/pcap` **3.25 TiB** (XFS), `/data/index` **1 TiB** (XFS), `/data/staging` 250 GiB, `/srv/vms` 500 GiB, `/srv/gns3` 400 GiB, `/srv/work` 200 GiB, `/srv/backup` 250 GiB, plus growing `/var` from 6 → 50 GiB; ~10 % VG reserve retained.

**Security:** SSH key-only on mgmt IP; UFW default-deny with mgmt-subnet-only 22/443; every web service localhost-bound behind Nginx TLS+auth; Docker socket never on TCP; capture containers get only documented `NET_ADMIN`/`NET_RAW`; auditd; secrets never in git.

**Monitoring:** Prometheus + Grafana + Alertmanager; capture-drop accounting from three independent sources (ethtool, Arkime stats, Zeek capture_loss) with alerts; storage burn-rate with days-to-full; disk 70/80/90% alerts.

## 8. Offline Supply Chain Requirements

- Bundle built by `scripts/r770-offline-fetch.sh` on a **dedicated Proxmox VM running Ubuntu 24.04 + Docker CE** (changed from RHEL 8, operator approved 2026-09-04 — see dependency manifest §0); proxy-aware, resumable, seeds from previous bundle; ~45–65 GB scripted + manual Dell firmware and licensed GNS3 images (10–100+ GB).
- Pins (reviewed 2026-09-04, evidence in `state/inventory/pin-review-2026-09-04.md`): Malcolm **26.08.0**, Ubuntu 24.04.4, gns3-server 3.0.6, CHR 7.21.5, OPNsense 26.7, FRR **10.7.1**, Prometheus v3.14.0, alertmanager **v0.34.0**, cadvisor **v0.60.5**, Grafana 12.1.0 (held below 13), ET Open suricata-7.0. Policy: bump moved pins at cut time; grafana is the standing exception.
- Trust established on staging (GPG/sha256 verification), asserted across the gap by `MANIFEST.sha256`, re-verified on the R770 before import; previous bundle retained as rollback; each cycle logged in `inventory/bundles.md`.
- Cadence: ad-hoc (accepted, documented risk: security updates and rules staleness between bundles).
- Open manual items: Dell service-tag downloads; licensed GNS3 appliance entitlement inventory; site media-scan policy confirmation.

## 9. Operating Model & Safety (binding on the build agent)

Work proceeds in 16 dependency-ordered phases (discovery → BIOS/firmware → storage → base OS → mgmt networking → Docker → KVM → GNS3 → capture-prep → Malcolm → mirror/import → WAN scripts → portal/DNS/docs → monitoring → backup → full validation). For every phase: inspect → report → state assumptions → classify destructiveness → produce exact commands → execute only when authorized → validate → record → provide rollback.

Hard rules: never guess device/interface names; never touch RAID, partitions, bootloader, firmware, SSH, Netplan, default route, or firewall without an explicit gate; `netplan try` for remote network changes; iDRAC verified before any networking phase; never mark VERIFIED without evidence; never fabricate command output. Full text in `CLAUDE.md`.

## 10. Success Criteria (validation suite, all must pass)

- **Host:** boots, SSH, chrony synced, `.lab` DNS resolves, apt (local repo) healthy.
- **CPU/RAM:** 32 cores/64 threads and 128 GB visible, `kvm-ok`, EDAC clean.
- **Storage:** all LVs mounted at expected sizes, PERC VD optimal, SMART clean, fio baseline on scratch file.
- **Network:** mgmt reachable; each capture port link-up, promisc, offloads off, no IP.
- **Virtualization:** CirrOS/Ubuntu test VM create → boot → network → destroy cleanly.
- **GNS3:** service up, authenticated API via portal, remote client connects, one QEMU node + one Docker node pass traffic.
- **WAN:** apply 40 ms profile → ping shows ~+40 ms → clear → baseline returns; iperf3 confirms shaping.
- **Capture:** tcpreplay of a reference PCAP → Arkime session count matches, Zeek logs present, capture_loss ≈ 0, exports open in Wireshark.
- **Monitoring:** all Prometheus targets up; a test alert fires.
- **Backup:** one file and one GNS3 project restored from Restic.

## 11. Key Risks & Unknowns — **re-dispositioned after Phase 1 (2026-09-03)**

**Closed by discovery:** usable capacity (**7.68 TB**, not 4) · PERC model and firmware (**H975i Front, 8.14.0.0.28-40**) · NIC media (**10GBASE-T copper**) · NUMA locality (**PERC, mgmt bond and OCP Slot 10 on node 0; OCP Slot 4 on node 1** — socket split now decided in buildout §8) · Dell service tag (**G8WFGH4**).

**Open, in priority order:**

1. **PERC encryption key custody — NEW.** Encryption is on with a Security Key assigned and nobody has established LKM vs SEKM, who holds the passphrase, or where it is escrowed. Losing it loses the VD and every byte of evidence on it. Blocking for case data; resolve in Phase 2.
2. **iDRAC unproven as a recovery path.** Address known, different subnet from management, no login demonstrated. Phase 5 must not touch Netplan until it is — an SSH session proves nothing about the recovery path.
3. **Management is a bond + tagged VLAN**, not a single addressed port, which raises Phase 5 from medium to high consequence. A mistake in bond mode, slave membership, or the VLAN tag drops the only in-band path.
4. **Retention is days, not weeks — and the prior model was 10× optimistic.** The buildout plan's retention table was computed for 15 TB while labelled 1.5 TB; corrected, 3.25 TiB of PCAP holds ~3.3 days at 100 Mbps and ~8 hours at 1 Gbps. All figures remain models until feed rates are measured in Phase 10. The 14 free drive bays are the escape hatch.
5. **NVMe link width x2 of x4 — NEW.** Half the per-drive bandwidth. Backplane bifurcation by design, or a fault? Determine in Phase 2 *before* any performance tuning.
6. **One RAID-1 VD shared** by capture I/O, indexing and VM disks — now known to be running at half link width. Disk-latency monitoring is the tripwire; dedicated PCAP NVMe in the free bays is the fix if proven.
7. **RAM is the binding constraint** for lab size, not CPU. Outlook improved: 8 of 32 DIMM slots populated, so 256 GB is a simple upgrade that also fixes the half-channel bandwidth caveat.
8. **Backup escapes the chassis only** when the Restic repo is copied off-box — owner still needed.
9. **Licensed appliance inventory** still open — sizes the transfer media and lab capability.
10. **Housekeeping from discovery** (non-blocking): iDRAC virtual media causes persistent `sdb`/`sr0` I/O errors that pollute health baselines — detach it; `pam_lastlog.so` is missing on 24.04 and logs a PAM error per login; `systemd-networkd-wait-online` stalls boot waiting on eight legitimately-down capture ports; gateway 10.10.10.1 did not answer ping (possibly filtered — confirm, don't assume).

## 12. Deliverables

1. The built, validated R770 (phases 1–16 complete).
2. `/opt/network-lab-config/` git repo on the box (inventory, netplan versions, scripts, systemd units, libvirt templates, monitoring rules, backup policy).
3. Final build document (system, hardware, networking, virtualization, GNS3, containers, capture, security, recovery).
4. Analyst wiki served via the portal (source in `docs/analyst-wiki/`).
5. Repeatable offline bundle pipeline (fetch script + runbook + manifest + logged cycles).
