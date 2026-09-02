# PRD — Sim Lab: Air-Gapped Network Simulation & Packet-Capture Server (Dell R770)

**Version:** 1.0 · 2026-09-01
**Owner:** Stephen (lab operator)
**Status:** Approved for build — Phase 1 (discovery) not yet executed
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

1. **Capture & analysis** — Malcolm v26.07.1 (Docker Compose: Arkime, Zeek, OpenSearch + Dashboards, Logstash/Filebeat; Suricata present but disabled) ingesting up to 4 active physical 10GbE TAP/SPAN feeds plus a virtual mirror of lab traffic plus imported PCAPs.
2. **Simulation** — GNS3 server v3.0.6 (venv install) running QEMU appliances (VyOS, MikroTik CHR, OPNsense, FRR, OpenWrt; licensed Cisco/Fortinet/PA images if entitled) and Docker nodes over KVM/libvirt.
3. **WAN emulation** — `tc`/`netem` profile library (`wan-apply` / `wan-show` / `wan-clear`) with branch-wan, satellite, poor-broadband, and asymmetric profiles.
4. **Services** — Nginx portal (`portal.lab` → `malcolm.lab`, `gns3.lab`, `monitoring.lab`, docs), dnsmasq (`.lab`, no forwarders), chrony (lab time source), Prometheus/Grafana/Alertmanager monitoring, Restic backup, MkDocs analyst wiki, internal CA (easy-rsa).

All software arrives via a versioned offline bundle built on an internet-connected RHEL 8 staging host by `scripts/r770-offline-fetch.sh` (v3.3: resumable, proxy-aware, cross-bundle seeding), transferred on checksummed ext4 media.

## 4. Target Hardware (per inventory — every line requires discovery verification)

- Dell PowerEdge R770, 2U
- 2 × Intel Xeon 6 6515P — 32 physical cores / 64 threads total, 2 NUMA nodes expected
- 128 GB DDR5-6400 (8 × 16 GB — only 4 of 8 channels per socket populated; bandwidth caveat)
- ~8 TB raw NVMe behind Dell PERC "H975i" (model discrepancy — verify; RAID 1 intended → usable capacity **unknown**: ~4 TB or ~8 TB)
- 2 × Broadcom quad-port 10GbE OCP (8 capture ports; 57412=SFP+ vs 57416=BASE-T discrepancy — verify media)
- Integrated NIC (management), iDRAC (out-of-band recovery)

## 5. Goals

1. Reliable, drop-accounted packet capture on dedicated, unaddressed, promiscuous ports (offloads disabled on capture ports only; AF_PACKET first, escalate only on measured loss).
2. Concurrent heavy capture and large GNS3 topologies via a NUMA socket split: capture/analysis stack on the socket owning the capture NICs, labs on the other (≈12.5 infrastructure cores / 16 guaranteed lab cores; ~64 GB infra / ~48 GB lab RAM).
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

**Network zones (strict):** iDRAC OOB · management (integrated NIC, only physical host IP) · capture (8 ports, no IP ever, never bridged to labs) · lab fabric (virtual bridges) · lab NAT (firewalled, default-off). Lab traffic reaches Malcolm only via a dedicated virtual mirror feed.

**Storage:** LVM VG `vg_lab` on the RAID-1 VD; separate LVs for `/`, `/var`, `/var/lib/docker`, `/data/pcap` (XFS), `/data/index` (XFS), `/data/staging`, `/srv/vms`, `/srv/gns3`, `/srv/work`, `/srv/backup`; ~10% VG reserve; sizes scale with discovered usable capacity (4 TB worst case → 1.5 TB PCAP / 600 GB index).

**Security:** SSH key-only on mgmt IP; UFW default-deny with mgmt-subnet-only 22/443; every web service localhost-bound behind Nginx TLS+auth; Docker socket never on TCP; capture containers get only documented `NET_ADMIN`/`NET_RAW`; auditd; secrets never in git.

**Monitoring:** Prometheus + Grafana + Alertmanager; capture-drop accounting from three independent sources (ethtool, Arkime stats, Zeek capture_loss) with alerts; storage burn-rate with days-to-full; disk 70/80/90% alerts.

## 8. Offline Supply Chain Requirements

- Bundle built by `scripts/r770-offline-fetch.sh` on RHEL 8 + Docker CE (proxy-aware, resumable, seeds from previous bundle); ~45–65 GB scripted + manual Dell firmware and licensed GNS3 images (10–100+ GB).
- Pins (review each cycle): Malcolm 26.07.1, Ubuntu 24.04.4, gns3-server 3.0.6, CHR 7.21.5, OPNsense 26.7, FRR 10.6.1, Prometheus v3.14.0, Grafana 12.1.0 (held below 13), ET Open suricata-7.0.
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

## 11. Key Risks & Unknowns (resolve by discovery, in priority order)

1. Usable storage capacity (4 vs 8 TB) — halves or doubles every storage number.
2. PERC model/firmware/TRIM behavior ("H975i" unconfirmed).
3. NIC media type (SFP+ vs BASE-T) — cabling and TAP procurement.
4. NUMA locality of capture NICs and PERC — decides the socket split.
5. Retention vs real ingest rates — all retention figures are models until measured.
6. Single RAID-1 VD shared by capture I/O, indexing, and VM disks — disk-latency monitoring is the tripwire.
7. RAM (not CPU) is the binding constraint for lab size; 256 GB upgrade is the escape hatch.
8. Management NIC is a single access point until iDRAC is verified.
9. Backup escapes the chassis only when the Restic repo is copied off-box — owner needed.
10. Licensed appliance inventory still open — sizes the transfer media and lab capability.

## 12. Deliverables

1. The built, validated R770 (phases 1–16 complete).
2. `/opt/network-lab-config/` git repo on the box (inventory, netplan versions, scripts, systemd units, libvirt templates, monitoring rules, backup policy).
3. Final build document (system, hardware, networking, virtualization, GNS3, containers, capture, security, recovery).
4. Analyst wiki served via the portal (source in `docs/analyst-wiki/`).
5. Repeatable offline bundle pipeline (fetch script + runbook + manifest + logged cycles).
