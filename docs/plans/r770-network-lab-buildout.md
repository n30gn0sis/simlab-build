# Dell PowerEdge R770 — Network Analysis Lab Server Buildout Plan

**Status:** Phase 1 (discovery) **VERIFIED 2026-09-03** — hardware facts below are measured, not assumed. Phases 2–16 not yet applied.
**Last revised:** 2026-09-03 (storage, network, socket split and risks rewritten from discovery)
**Target OS:** Ubuntu Server 24.04 LTS (minimal, no desktop)
**CPU:** 2 × Intel Xeon 6 Performance 6515P (dual-socket: 32 physical cores / 64 threads total)
**Document date:** 2026-08-24
**Scope:** Full-packet capture (Malcolm/Arkime/Zeek/OpenSearch), GNS3 simulated WAN, KVM/QEMU VMs, Docker services, internal portal, monitoring, backup.

---

## 0. Design Principles

1. Discover before configuring. Nothing in this document that names a device, interface, or capacity is final until Phase 1 discovery confirms it.
2. Management connectivity is sacred. iDRAC is the recovery path; the management path is the **802.3ad bond `lacp-trunk` with VLAN 10 on top (`lacp-trunk.10`, 10.10.10.31/24)** — not the integrated NIC, as discovery corrected on 2026-09-03. Neither is ever reconfigured without a validated alternate path.
3. Capture storage must never exhaust general storage. PCAP lives on its own logical volume with hard boundaries and automatic oldest-first deletion.
4. Malcolm is deployed as the integrated stack. Arkime, Zeek, Suricata, OpenSearch, Dashboards, Logstash, and Filebeat all run as Malcolm's Docker Compose services — they are **not** installed separately on the host. Host-level tshark/tcpdump/dumpcap exist only for validation and troubleshooting.
5. Simple first. Linux bridges before OVS, AF_PACKET before AF_XDP/PF_RING/DPDK, UFW before hand-rolled nftables. Escalate only on measured need.
6. Every change is reversible, validated, and recorded.
7. **Air-gapped operation:** the server runs fully offline. All software, images, and enrichment data arrive via a versioned bundle built on an internet-connected staging host — see `r770-offline-supply.md` and `r770-offline-fetch.sh`. APT points only at the local repo; snapd removed; chrony is the lab's own time source; dnsmasq has no upstream forwarders; TLS comes from an internal CA.

---

## 1. Proposed Logical Architecture

```text
                        ┌─────────────────────────────────────────────┐
  iDRAC network ────────┤ iDRAC (OOB: console, firmware, power)       │
  (isolated)            ├─────────────────────────────────────────────┤
                        │         Ubuntu Server 24.04 LTS             │
  Mgmt/analyst ─────────┤ lacp-trunk.10  (2×25G LACP + VLAN 10,       │
  10.10.10.0/24         │                 10.10.10.31, SSH, HTTPS)    │
  network               │                                             │
                        │  ┌─ Nginx reverse proxy (portal.lab) ─────┐ │
                        │  │   malcolm.lab · gns3.lab ·              │ │
                        │  │   monitoring.lab · docs                 │ │
                        │  └─────────────────────────────────────────┘ │
                        │  ┌─ Docker Engine ────────────────────────┐ │
                        │  │  Malcolm (Arkime, Zeek, OpenSearch,    │ │
                        │  │  Dashboards, Logstash, [Suricata off]) │ │
                        │  │  Prometheus · Grafana · Alertmanager   │ │
                        │  │  node_exporter · cAdvisor · MkDocs     │ │
                        │  └─────────────────────────────────────────┘ │
                        │  ┌─ KVM/QEMU + libvirt ───────────────────┐ │
                        │  │  GNS3 server + QEMU appliances         │ │
                        │  │  General lab VMs                       │ │
                        │  │  Linux bridges / (OVS if justified)    │ │
                        │  │  tc/netem WAN impairment               │ │
                        │  └─────────────────────────────────────────┘ │
                        ├─────────────────────────────────────────────┤
  Capture feeds ───────►│ OCP Slot 10, 4×10GBASE-T  (node 0, primary)│
  (TAP/SPAN, no IP,    ►│ OCP Slot 4,  4×10GBASE-T  (node 1, spare)  │
   RX-only, promisc)    │ copper RJ45 — TAPs must be copper          │
                        └─────────────────────────────────────────────┘
```

Network zones, strictly separated:

| Zone | Interface | Addressed? | Purpose |
|---|---|---|---|
| OOB management | iDRAC dedicated port | Yes (iDRAC only) | Console, firmware, power, recovery |
| Host management | `lacp-trunk.10` (bond + VLAN 10) | Yes, static 10.10.10.31/24 | SSH/SCP/SFTP, all browser services via Nginx, DNS/NTP |
| Capture | 8 × 10GBASE-T Broadcom ports (2 OCP quads) | **No IP ever** | Passive TAP/SPAN ingestion only |
| Lab fabric | Virtual (bridges/OVS) | Internal only | GNS3, VMs, containers, WAN emulation |
| Lab NAT | Virtual → mgmt bond | NAT | Controlled lab egress where explicitly allowed |

Key rule: capture interfaces carry no IP address, run promiscuous, transmit nothing, and are never bridged to the lab fabric. Lab traffic that needs to be analyzed reaches Malcolm through a dedicated virtual mirror feed (see §7), not by mixing zones.

---

## 2. Hardware Discovery Checklist — **COMPLETE (Phase 1 VERIFIED 2026-09-03)**

Every item below was answered by `scripts/r770-precheck.sh` v2 (2026-09-02) plus the iDRAC hardware-inventory export for service tag `G8WFGH4`. Raw evidence: `state/inventory/r770-precheck-report-2026-09-02.md` and `state/inventory/r770-idrac-inventory-G8WFGH4.md`. Analysis and plan impacts: `state/inventory/r770-discovery-findings.md`. The verified hardware of record is tabulated in `state/BUILD-STATE.md`; the summary answers:

**Platform** — Service tag `G8WFGH4`; BIOS 1.7.5 (2026-01-16); iDRAC/LC 1.30.20.10 at `https://192.168.76.231:443`; UEFI boot, **Secure Boot disabled**; VT-x present, IOMMU/DMAR active, `/dev/kvm` present. **IPMI-over-LAN is disabled** — OOB automation is Redfish, never `ipmitool -H`. iDRAC sits on 192.168.76.0/24, a *different subnet* from management, and has **not yet been demonstrated reachable** from the operator's position — that remains the Phase 5 gate.

**CPU / memory / NUMA** — 2 × Xeon 6515P, 16c/32t each = 32c/64t, L3 144 MiB. **Two NUMA nodes, no sub-NUMA clustering**, but the CPU numbering is **interleaved**: node 0 is every even CPU (64,068 MB), node 1 every odd CPU (64,496 MB), distance 21. Any `cpuset`/`vcpupin`/IRQ range like `0-15` straddles both sockets — always use the explicit lists. 8 × 16 GB Micron DDR5-6400 single-rank RDIMMs in A1–A4 / B1–B4 = 4 of 8 channels per socket, confirming the bandwidth caveat in §8; 8 of 32 slots used, so the upgrade path is much wider than assumed.

**Storage** — **PERC H975i Front**, firmware 8.14.0.0.28-40, Write Back / No Read Ahead, energy pack OK, patrol read stopped. **One RAID-1 VD of 7.68 TB (6.99 TiB) usable** over 2 × KIOXIA E3.S NVMe 2.0 (100% endurance, Online). No direct-attached NVMe. **14 of 16 backplane bays are free.** Two findings the checklist did not anticipate: the controller reports **encryption Enabled with a Security Key Assigned** (custody unknown — §12), and the drives negotiated **x2 of a x4-capable link** (§12). TRIM passthrough is still unconfirmed and needs perccli in Phase 2.

**NICs** — Ten `bnxt_en` ports, not eight. Both OCP quads are Broadcom BCM57412 `BCM957412-N410TGI0S` = **4 × 10GBASE-T copper each** (`MEDIA=TP`), Slot 10 on **node 0** and Slot 4 on **node 1**. Management is *not* the integrated NIC: it is a **BCM57414 2 × 25G SFP28** in PCIe Slot 9 (**node 0**, Dell D0R73 transceivers), bonded 802.3ad as `lacp-trunk` with VLAN 10 as `lacp-trunk.10` at 10.10.10.31/24. Per-port: RX ring 511 of max 2047, combined channels 16 of max 74, offloads on as shipped. Predictable names are recorded in §4.1.

**The 57412 media question is settled:** 57412 silicon on a 4×10GBASE-T card. **Copper TAPs / RJ45 SPAN — do not order optics.**

---

## 3. Proposed Storage Architecture

### 3.1 Capacity model (**verified 2026-09-03 — no longer provisional**)

Discovery settles the highest-impact unknown. The PERC H975i Front presents **one RAID-1 virtual disk of 7,680,877,920,256 bytes ≈ 7.68 TB (6.99 TiB) usable**, over two KIOXIA E3.S NVMe drives. The 4 TB worst case does not apply.

The OS is already installed on that VD and LVM is already in use, so **Phase 3 does no repartitioning**: `/dev/sda3` is a PV in VG **`ubuntu-vg0`**, holding ≈147 GiB of existing LVs and leaving **≈6.84 TiB of free extents**. The lab volumes are `lvcreate` calls against that free space. (Evidence: `state/inventory/r770-discovery-findings.md` §2.3.)

| Existing LV | Mount | Size | Disposition |
|---|---|---|---|
| `lv-root` | `/` | 50 GiB | Keep. Every bulk consumer gets its own LV below, so 50 GiB is adequate; grow from reserve if it ever isn't. |
| `lv-home` | `/home` | 84.9 GiB | Keep as-is. |
| `lv-var` | `/var` | 6 GiB | **Grow to 50 GiB** — apt, journald and container metadata will not fit comfortably in 6 GiB. |
| `lv-varlog` | `/var/log` | 2 GiB | Keep (journald bounded). |
| `lv-varlogaudit` | `/var/log/audit` | 2 GiB | Keep. |
| `lv-tmp` | `/tmp` | 2 GiB | Keep. |

**The retention reality that drives this design.** Full-packet capture at a sustained 1 Gbps writes ≈ **10.8 TB/day**; at 100 Mbps, ≈ 1.08 TB/day. Against the **3.25 TiB (3.57 TB)** allocated to PCAP below:

| Sustained ingest across all feeds | Write rate | PCAP retention in 3.25 TiB |
|---|---|---|
| 10 Mbps | 0.11 TB/day | ~33 days |
| 50 Mbps | 0.54 TB/day | ~6.6 days |
| 100 Mbps | 1.08 TB/day | ~3.3 days |
| 500 Mbps | 5.4 TB/day | ~16 hours |
| 1 Gbps | 10.8 TB/day | ~8 hours |
| 4 Gbps | 43.2 TB/day | ~2 hours |

> **Correction (2026-09-03):** the previous version of this table was wrong by a factor of ten. Its figures (~28 days at 50 Mbps, ~14 days at 100 Mbps) are what 15 TB of PCAP would buy, not the 1.5 TB the table was labelled with — the arithmetic never matched the 10.8 TB/day rate stated one line above it. The table above is recomputed and checked. **Retention here is days, not weeks, at anything above a trickle**, which makes the two mitigations below hard requirements rather than good practice.

Four 10GbE feeds cannot be retained at line rate on this chassis — nor is that the goal for a lab. Arkime must delete oldest PCAP automatically at a free-space floor, and OpenSearch must have index lifecycle (ISM) retention. Both are hard requirements, not options. The chassis has **14 free drive bays** (16-slot backplane, 2 populated), so dedicating direct-attached NVMe to PCAP is a real, costed escape hatch rather than a hypothetical one.

### 3.2 Layout — new LVs in the existing VG `ubuntu-vg0`

Created from the ≈6.84 TiB of free extents. Keep ~10% of the VG unallocated as emergency/expansion reserve. **The VG is not renamed** — `vg_lab` was a planning name; renaming the VG that carries a mounted root filesystem is risk with no benefit.

| LV | Mount | FS | Size | Contents |
|---|---|---|---|---|
| lv_docker | `/var/lib/docker` | ext4 | 250 GiB | images, container layers, volumes for portal/monitoring |
| lv_pcap | `/data/pcap` | **XFS** | **3.25 TiB** | Arkime raw PCAP (Malcolm bind-mount) + `raw/ cases/ temporary/ archived/` |
| lv_index | `/data/index` | XFS | **1 TiB** | OpenSearch data (Malcolm bind-mount), Zeek/Arkime metadata |
| lv_staging | `/data/staging` | XFS | 250 GiB | Imported-PCAP upload/staging area |
| lv_vms | `/srv/vms` | XFS | 500 GiB | libvirt images, snapshots (qcow2, sparse) |
| lv_gns3 | `/srv/gns3` | XFS | 400 GiB | GNS3 projects, appliance images, temp captures |
| lv_work | `/srv/work` | XFS | 200 GiB | Analyst workspaces, exports, reports, case artifacts |
| lv_backup | `/srv/backup` | XFS | 250 GiB | Restic repo, config exports, docs (secondary copy must leave the box) |
| *(grow `lv-var`)* | `/var` | ext4 | +44 GiB | 6 GiB → 50 GiB |
| **Total new allocation** | | | **≈6.10 TiB** | |
| *(reserve)* | — | — | **≈0.74 TiB free in VG (~10.6%)** | grow whichever LV proves undersized |

Rationale unchanged: XFS on the large streaming/parallel-write volumes (PCAP, OpenSearch, VM images) for allocation-group parallelism and large-file performance; ext4 where boring reliability is all that's needed. Separate LVs mean a runaway capture, index explosion, or fat VM disk fills **its own** filesystem, never `/`.

Mount options: `noatime` on all data LVs; use periodic `fstrim.timer` (weekly) rather than `discard` — **the PERC VD's TRIM passthrough is still unconfirmed** (needs perccli, Phase 2), so do not rely on it until it is. No swap beyond a small 8 GB swapfile with low swappiness; OpenSearch performs badly when swapped (Malcolm sets memlock).

> **Gate before any of this runs:** the PERC reports `Encryption mode: Enabled` with a `Security Key Assigned`. Establish whether that is LKM or SEKM and where the key is escrowed **before** case data lands on these volumes — losing the key loses the VD. See §12.

### 3.3 Retention and protection policy

- Arkime: `freeSpaceG` floor on `/data/pcap` (≥ 5%), oldest-first deletion — but **only** within `raw/`; `cases/` and `archived/` are operator-curated and never auto-deleted.
- OpenSearch ISM: sessions/Zeek indexes roll and delete at a target that keeps `/data/index` under 80%.
- Prometheus alerts at 70/80/90% on every data LV.
- Nothing in `cases/` or `/srv/work` is ever deleted automatically.

---

## 4. Proposed Network Architecture

### 4.1 Physical (**verified 2026-09-03**)

Ten Broadcom `bnxt_en` ports, not eight — the two OCP quads plus the 2 × 25G adapter that actually carries management.

| Role | Hardware | Interfaces | NUMA | State as found |
|---|---|---|---|---|
| **Management** | Broadcom BCM57414 2 × 25G SFP28, PCIe Slot 9, Dell D0R73 transceivers | `eno17295np0` + `eno17305np1` bonded 802.3ad as **`lacp-trunk`** (50 Gbps), VLAN 10 as **`lacp-trunk.10`** → **10.10.10.31/24**, default via 10.10.10.1 | **node 0** | up |
| **Capture (primary)** | Broadcom BCM57412 4 × 10GBASE-T OCP, **Slot 10** | `eno17395np0` `eno17405np1` `eno17415np0` `eno17425np1` | **node 0** | down, no carrier |
| **Capture (secondary)** | Broadcom BCM57412 4 × 10GBASE-T OCP, **Slot 4** | `eno16795np0` `eno16805np1` `eno16815np0` `eno16825np1` | **node 1** | down, no carrier |
| **OOB** | iDRAC | `https://192.168.76.231:443`, DNS `testbed-idrac` | — | IPMI-over-LAN **disabled**; SOL enabled |

Three corrections to what this section previously said:

1. **Management is not the integrated NIC.** It is a bond with a tagged VLAN on top. Phase 5 must preserve `lacp-trunk` membership, 802.3ad mode, and the VLAN-10 tag; `netplan try` is mandatory, and the netplan of record is the single file `/etc/netplan/00-h2-init.yaml` (mode 0600). This is the highest-consequence change in the build.
2. **Capture media is 10GBASE-T copper (RJ45)**, part `BCM957412-N410TGI0S`, `ethtool` `MEDIA=TP`. Procure **copper TAPs / RJ45 SPAN** — not optics. The 57412-vs-57416 catalog discrepancy is closed: 57412 silicon on a BASE-T card.
3. **The capture quads straddle both sockets.** Slot 10 is node-local to the PERC and the management bond; Slot 4 is not. Prefer Slot 10's four ports for the highest-rate feeds so packets never cross UPI before they are written. See §8.

The eight capture ports are defined in Netplan with **no addresses**, brought up by a `capture-prep` systemd service that sets promisc and disables offloads. Nothing else touches them. iDRAC is verified reachable *before* any host networking change is applied — and note it sits on **192.168.76.0/24, a different subnet from management**, so that reachability is not implied by having an SSH session.

### 4.2 Capture-port preparation (per active feed, applied by script/systemd — interface names now known, see §4.1)

```bash
# capture-prep <iface> — run per capture port at boot
ip link set <iface> up promisc on mtu 9216      # accommodate VLAN/jumbo on monitored links
ethtool -K <iface> gro off lro off tso off gso off rx-gzip off \
        rxvlan off txvlan off ntuple off 2>/dev/null || true
ethtool -K <iface> rx off tx off sg off 2>/dev/null || true   # checksum offloads
ethtool -G <iface> rx 2047                                     # max ring size (discovered: 511 of 2047)
ethtool -A <iface> rx off tx off                               # no pause frames
```

Offloads are disabled **only** on capture ports — GRO/LRO coalesce packets and destroy wire-faithfulness; the management bond keeps all offloads. Ring sizes and queue counts come from `ethtool -g/-l` discovery, not guesses: **RX ring 511 of a 2047 maximum** (jumbo 2044/8191), **combined channels 16 of a 74 maximum**. As found, the ports have `gro on`, `rx-gro-hw on`, `tso on`, `gso on` and VLAN offloads on — every one of those must go off on a capture port.

### 4.3 Virtual / lab fabric

Start with Linux bridges (libvirt-managed):

| Bridge | Purpose | Host IP | Egress |
|---|---|---|---|
| `br-lab-mgmt` | VM/appliance management | Yes (RFC1918 /24) | none |
| `br-lab-nat` | Lab internet access when explicitly needed | Yes | NAT via the mgmt bond (`lacp-trunk.10`), firewalled |
| `br-lab-tXX` | GNS3/lab transit segments, created per topology | No | none |
| `br-mirror` | Virtual mirror feed → Malcolm capture (see §7) | No | none |

**OVS decision:** not installed at initial build. Adopt OVS later *only if* a concrete need appears — port mirroring of many lab segments at once, 802.1Q trunk manipulation inside the fabric, or OpenFlow experiments. Linux bridges + `tc-mirred` cover the initial mirror-to-Malcolm requirement. This decision is recorded and reversible.

### 4.4 WAN emulation

`tc`/`netem` on GNS3 link endpoints or dedicated impairment namespaces. Reusable profile scripts in the config repo (`wan-apply <profile> <iface>`, `wan-show`, `wan-clear`), with profiles for branch WAN (20 Mbps/40 ms/5 ms jitter/0.2% loss), satellite (25 Mbps/600 ms), poor broadband (10 Mbps/80 ms/2% loss), and asymmetric variants (HTB for rate + netem for delay; IFB for ingress where needed). Every profile has apply/show/clear. Impairments never touch the management bond/VLAN (`lacp-trunk`, `lacp-trunk.10`) or capture ports.

### 4.5 Internal DNS / names

dnsmasq (simplest fit: DNS + optional DHCP for lab bridges in one small service) serving `.lab` on the management interface and lab bridges: `portal.lab`, `malcolm.lab`, `gns3.lab`, `monitoring.lab`, `idrac.lab` (**discovery: iDRAC is 192.168.76.231, a different subnet from mgmt 10.10.10.0/24 — publish this A record only if a route genuinely exists, otherwise document it as OOB-only and do not create a name that resolves to something unreachable**). Chrony serves NTP to the lab from the host, syncing upstream from the mgmt network.

---

## 5. Proposed Virtualization Architecture

- KVM/QEMU + libvirt (distro packages only). `virt-install`/`virsh` administration; optional Cockpit+cockpit-machines later, bound to localhost behind Nginx if adopted.
- VM disks: qcow2 on `/srv/vms` pool, virtio-blk/virtio-scsi + virtio-net everywhere, host-passthrough CPU model for GNS3 appliance performance.
- Nested VMX enabled (`kvm_intel nested=1`) — several router/firewall appliances want it.
- Snapshots allowed for lab VMs; not for anything holding case data.
- **No PCI passthrough / SR-IOV of capture NICs to VMs.** Capture belongs to the host/Malcolm; labs get virtual mirror feeds.
- Huge pages: **not enabled initially.** Revisit only if a steady-state set of large VMs exists and measurement shows TLB pressure; then use static 2 MB pages sized to that measured footprint, allocated on the lab socket's NUMA node, and document the RAM removed from the general pool.
- NUMA-aware placement from day one: lab VMs get `<numatune>` memory binding and vCPU placement on the lab socket (§8), so guest memory stays node-local. VMs larger than one node's free memory are flagged, not silently split.
- CPU pinning beyond the socket split: none at first. If capture drops appear under combined load, tighten to per-queue IRQ affinity and explicit Arkime/Zeek worker pinning using actual `lscpu -e` topology.

---

## 6. GNS3 Architecture

- GNS3 **server only** (no GUI on host), installed in a Python venv or from the GNS3 PPA (the one sanctioned exception to the no-PPA rule, as it is the upstream project's supported channel — decision recorded; alternative is pip install into a dedicated venv).
- Dedicated `gns3` service user, member of `kvm` and `docker` groups (docker membership documented as root-equivalent — see §9), systemd unit, auto-start.
- Paths: projects `/srv/gns3/projects`, images `/srv/gns3/images`, symlinked/configured in `gns3_server.conf`.
- Bound to localhost; exposed **only** through Nginx at `gns3.lab` with authentication enabled in GNS3 (v3 has built-in auth) plus reverse-proxy TLS. The GNS3 Web UI serves topology control; the desktop GNS3 GUI on analyst workstations connects to the same API through the proxy.
- Node types: QEMU appliances (routers/firewalls/endpoints), Docker nodes for lightweight endpoints, built-in switches/clouds. Cloud nodes may attach lab bridges — never the management bond or its VLAN, never capture ports.

---

## 7. Packet Capture & Analysis Architecture

### 7.1 Stack shape

**Malcolm (Docker Compose) is the platform.** It ships and orchestrates: Arkime (capture + session search + PCAP export), Zeek (protocol metadata), OpenSearch + Dashboards (index/visualization), Logstash/Filebeat (pipelines), Suricata (present, **disabled** initially), Wise/Cont3xt (optional, off initially). Malcolm runs in live-capture mode against the physical capture ports (its capture containers get `NET_ADMIN`/`NET_RAW` and host network on those interfaces — the documented Malcolm pattern), and also accepts imported PCAP via its upload interface from `/data/staging`.

Bind mounts pin the heavy data where the storage design wants it: PCAP → `/data/pcap/raw`, OpenSearch → `/data/index`.

### 7.2 Feeds

| Feed | Source | Mechanism |
|---|---|---|
| Physical 1–4 | TAPs / SPAN ports | Adapter A ports 1–4, AF_PACKET (tpacket v3) |
| Physical 5–6 | future | Adapter B ports 1–2, same pattern |
| Virtual mirror | GNS3/VM lab segments | `tc mirred` (or OVS mirror later) from lab bridges → `br-mirror` → a veth/dummy interface Malcolm captures like any other feed |
| Imported PCAP | analysts via SFTP to `/data/staging` | Malcolm upload/ingest |

### 7.3 Capture mechanism policy

AF_PACKET first. It is the zero-extra-complexity path and on this hardware comfortably handles the hundreds-of-Mbps-per-feed range a lab actually produces. Measure drops (per §7.4) under realistic load; **only** if sustained loss appears, escalate in order: larger blocks/fanout tuning → AF_XDP → PF_RING/DPDK (last resort; DPDK removes the NIC from the kernel and complicates everything else on the box).

### 7.4 Drop accounting (the capture is not trusted until this exists)

- `ethtool -S <iface>` deltas: `rx_dropped`, ring overruns, per-queue drops
- Arkime capture stats (its own drop counters, surfaced in Dashboards)
- Zeek `capture_loss.log` (must stay ≈ 0%)
- All three exported to Prometheus with alert thresholds; a validation script compares a known replayed traffic count (tcpreplay of a reference PCAP) against captured session counts.

### 7.5 Host-level tools

tcpdump/tshark/dumpcap installed for spot-validation only, runnable via a `pcapture` group (`setcap`d dumpcap) rather than root. Wireshark stays on analyst workstations, fed by Arkime/tshark exports from `/srv/work`.

---

## 8. CPU / RAM Allocation Strategy

2 × 6515P = **32 physical cores / 64 threads**, 128 GB RAM (≈ 64 GB per socket). Threads are not cores: budget in physical-core equivalents and treat SMT as headroom, not capacity. With two sockets, **NUMA is the organizing principle**: cross-socket (UPI) memory traffic is the enemy of both capture throughput and VM latency.

### Socket split — **decided 2026-09-03 from discovery**

Discovery found the two capture quads on *different* sockets, which §12 said would force this decision:

| Device | PCI | NUMA node |
|---|---|---|
| PERC H975i (all PCAP and index writes) | `0000:ae:00.0` | **0** |
| Management bond NIC (BCM57414 2×25G, Slot 9) | `0000:5c:00.x` | **0** |
| Capture OCP **Slot 10** | `0000:84/85:00.x` | **0** |
| Capture OCP **Slot 4** | `0001:36/37:00.x` | **1** |

**Node 0 is the capture/analysis socket. Node 1 is the lab socket.**

- **Capture/analysis (node 0)** — Malcolm stack (Arkime, Zeek, OpenSearch, Logstash), capture IRQ affinity, host network services. Use **Slot 10's four ports as the primary feeds**: a packet then arrives, is processed, and is written to the PERC without ever crossing UPI.
- **Lab (node 1)** — GNS3, QEMU/KVM VMs, lab containers, WAN emulation.
- **Slot 4's four ports remain usable** as secondary/spare feeds, but traffic arriving there crosses the UPI link before it reaches the analysis stack and the PERC. Give them the lower-rate feeds, and expect them to be the first suspect if drops appear asymmetrically across ports.

> **The CPU numbering is interleaved, and this is the trap.** `node 0 cpus: 0 2 4 6 … 62` (even) and `node 1 cpus: 1 3 5 7 … 63` (odd). A `cpuset-cpus=0-15`, a `vcpupin` range, or an IRQ affinity mask written as a contiguous range spans **both** sockets and silently defeats the entire split — the symptom is unexplained cross-socket memory traffic, not an error. Every pinning value must use the explicit even/odd lists, and `numactl --hardware` is the source of truth. Per-node memory: node 0 = 64,068 MB, node 1 = 64,496 MB.

### Steady-state budget (initial model — adjust to measurements)

| Consumer | Socket | Physical cores (≈) | RAM |
|---|---|---|---|
| Host, kernel, capture IRQs, SSH, Nginx, dnsmasq, chrony | capture | 2 | 8 GB |
| OpenSearch (JVM heap 24 GB, ≤ 31 GB always) | capture | 4 | 32 GB (heap + off-heap) |
| Zeek workers (start: 1 worker/active feed + manager/logger) | capture | 3 | 8 GB |
| Arkime capture + viewer | capture | 2 | 8 GB |
| Logstash/Dashboards/other Malcolm services | capture | 1 | 6 GB |
| Monitoring + portal containers | either | 0.5 | 2 GB |
| **Infrastructure subtotal** | | **~12.5 of 16** | **~64 GB** |
| GNS3 + VMs + lab containers | lab | **16 guaranteed** (+ capture-socket slack when feeds are quiet) | 48 GB allocatable |
| Page cache / headroom | both | ~3.5 | ~16 GB |

The second socket changes the character of the box: labs get a **full 16 physical cores / 32 threads guaranteed** even under heavy ingest, instead of scraps. Heavy capture and a large GNS3 topology can now genuinely run at the same time.

Enforcement: start soft — Docker `cpuset-cpus`/`mem_limit` on the Malcolm services (capture-socket cores), libvirt `<numatune>`/`vcpupin` placing lab VMs on the lab socket with node-local memory, lab vCPU total capped around 32 oversubscribed. Avoid vCPU overcommit >2:1 for latency-sensitive router appliances; idle endpoints can overcommit harder. RAM discipline matters per-node: infrastructure's ~64 GB must fit the capture socket's node, labs' 48 GB the lab socket's node — a VM spilling across nodes quietly halves its memory bandwidth. Tighten to hard IRQ + per-queue pinning only if drop measurements demand it.

One caveat from the memory config: 4 DIMMs per socket populates only half of each socket's 8 memory channels, so per-socket memory bandwidth is roughly half of what the platform can do. For this workload mix that is acceptable, but it is the first suspect if OpenSearch indexing or multi-VM performance underwhelms — and the fix (8 more DIMMs) is a purchase, not a config change.

---

## 9. Security Architecture

- **SSH:** key-only, no root login, `AllowGroups` restricted, listening on management IP only. SFTP chroot or scoped account for PCAP import into `/data/staging`.
- **Firewall:** UFW. Default deny inbound; allow from management subnet only: 22 (SSH), 443 (Nginx). Everything else — GNS3 API, OpenSearch, Dashboards, Grafana, Prometheus, cockpit if ever installed — binds to localhost/docker-internal and is reached exclusively through Nginx with TLS + auth. Enable sequence: identify current SSH source → insert allow rules → verify → enable (never lock yourself out).
- **Docker:** socket never exposed over TCP; no `--privileged` except where Malcolm's capture containers require documented `NET_ADMIN`/`NET_RAW`; membership in the `docker` group treated as root-equivalent and limited to admins + the gns3 service account (documented).
- **libvirt:** local socket only, `libvirt` group membership restricted.
- **Zones:** capture ports unaddressed (nothing to attack); lab NAT egress firewalled and default-off per bridge; lab fabric cannot reach the management plane (nft/UFW forward rules).
- **Patching:** `unattended-upgrades` for security updates; Malcolm and GNS3 updated deliberately (pinned versions, changelog review) since they anchor investigations.
- **Audit:** auditd with a modest ruleset (auth, sudo, netplan/UFW/libvirt config paths); rsyslog local with rotation; auth + audit summaries into the monitoring stack.
- **Secrets:** none in the config repo — Malcolm auth, Grafana admin, GNS3 credentials in `/etc/…` mode-0600 files or Docker secrets, listed (by location, not value) in the build doc.

---

## 10. Monitoring, Logging, Backup

- **Prometheus** (30-day retention on `/var/lib/docker` volume) scraping: node_exporter (host), cAdvisor (containers), blackbox_exporter (HTTP checks on portal/malcolm/gns3/monitoring vhosts + DNS + SSH banner), SMART/PERC textfile collectors (smartmontools + perccli cron → node_exporter textfile), libvirt exporter (VM counts/CPU), and capture-drop metrics from §7.4.
- **Grafana** dashboards: capture health (per-feed pps/drops), storage capacity/burn-rate (with days-to-full projection for `/data/pcap` and `/data/index`), host CPU per-core, RAM, disk latency, NIC errors, VM/container inventory, temperatures (via ipmi/redfish exporter from iDRAC if licensed).
- **Alertmanager:** disk >70/80/90%, any capture drops sustained >0.1%, Zeek capture_loss >0.5%, OpenSearch red/yellow, RAID VD degraded, SMART failure, chrony unsynced, service down. Delivery initially to the portal + email if an internal relay exists (offline-friendly).
- **Logging:** journald capped (1 GB), rsyslog to `/var/log` with logrotate; Malcolm keeps its own component logs inside its volumes.
- **Backup — Restic** to `/srv/backup` repo, nightly: `/etc`, Netplan, UFW rules, the config repo, libvirt XML dumps, GNS3 projects, Malcolm config (not indexes), docs, and *curated* case artifacts (`/data/pcap/cases`, `/srv/work` selections). Raw PCAP and OpenSearch indexes are **not** backed up (reproducible/expendable by policy). A local-only backup is half a backup: schedule a periodic copy of the Restic repo to external/remote storage — flagged as an open operational requirement.

---

## 12. Risks and Unknowns — **re-dispositioned after Phase 1 (2026-09-03)**

Resolved by discovery, kept for the record: ~~usable storage capacity~~ (**7.68 TB usable, RAID 1, one VD**), ~~PERC model~~ (**H975i Front, fw 8.14.0.0.28-40**), ~~NIC media~~ (**10GBASE-T copper**), ~~NUMA locality~~ (**PERC + mgmt + OCP Slot 10 on node 0; OCP Slot 4 on node 1** — §8 split decided). Evidence: `state/inventory/r770-discovery-findings.md`.

**Open, in priority order:**

1. **PERC encryption key custody — NEW, and the most consequential.** The controller reports `Encryption mode: Enabled` with a `Security Key Assigned`. Nobody has yet established whether that is Local Key Management or SEKM, who holds the passphrase, or where it is escrowed. **If the key is lost or the controller is replaced without it, the virtual disk — and every byte of case evidence on it — is unrecoverable.** Resolve in Phase 2, before any case data lands. Record custody in the recovery runbook, never the key itself in git.
2. **iDRAC is not yet a proven recovery path.** The address is known (`192.168.76.231`), but it sits on a different subnet from management (10.10.10.0/24) and no login has been demonstrated. Phase 5 must not touch Netplan until someone has actually logged into iDRAC and confirmed console access — an SSH session is not evidence that the recovery path works.
3. **Management is a bond with a tagged VLAN**, raising the stakes on Phase 5 well above the "single static IP" this plan originally assumed. `lacp-trunk` (802.3ad, 2 × 25G) carrying `lacp-trunk.10`; a mistake in bond mode, slave membership, or the VLAN tag drops the only in-band path. `netplan try` is mandatory, the existing `/etc/netplan/00-h2-init.yaml` is saved and diffed first, and risk 2 is the precondition.
4. **Retention is days, not weeks — and the previous estimate was ten times too optimistic.** The old §3.1 table was computed for 15 TB of PCAP while being labelled 1.5 TB. Corrected: 3.25 TiB of PCAP holds ~3.3 days at a sustained 100 Mbps and ~8 hours at 1 Gbps. Real feed rates are still unmeasured; measure in Phase 10 and set the Arkime free-space floor and OpenSearch ISM policy from data, not from this model. The 14 free drive bays are the escape hatch if the numbers land badly.
5. **NVMe link width negotiated x2 of x4 — NEW.** Both drives report `x2 / x4`, i.e. half the available PCIe width and roughly half the per-drive bandwidth. This may be backplane bifurcation by design on a 16-slot backplane, or a seating/config issue. Sustained capture writes are exactly the workload that would notice. Investigate in Phase 2, *before* any performance tuning — measuring against a halved link and then "optimizing" is wasted work.
6. **Single box, single RAID-1 VD.** Capture I/O, OpenSearch indexing, and VM disks share one mirror pair, and that pair is now known to be running at x2 link width (risk 5). NVMe mitigates contention, but the monitoring stack's disk-latency panels remain the tripwire. Mitigation if proven: populate free bays with direct-attached NVMe dedicated to PCAP.
7. **Memory ceiling before CPU ceiling.** 128 GB splits ~64 GB per node; RAM is the binding constraint on lab size long before 32 cores saturate. Discovery improves the outlook: **8 of 32 DIMM slots are populated** (max 8 TB), so growth to 256 GB is straightforward and also fixes the half-channel bandwidth caveat (4 of 8 channels per socket, confirmed).
8. **Malcolm resource appetite** — OpenSearch and Zeek sizing in §8 is a starting model; set worker counts and heap from measured feed rates, not defaults.
9. **Backup escape** — until the Restic repo is copied off-box, a chassis loss loses everything. Operational owner still needed.
10. **Suricata off by default** — enabling it adds a full extra per-packet pipeline; re-run the CPU budget before switching it on.

**Housekeeping surfaced by discovery** (none are blockers, all are Phase 2/4/5 cleanup):

- Persistent `sdb`/`sr0` I/O errors (`access beyond end of device`, `FAT-fs read failed`) trace to **iDRAC virtual media** on the Renesas USB 3.0 controller — not the RAID VD. Detach it and re-baseline health, or the noise will keep inflating every kernel-error count.
- `pam_lastlog.so` is missing (Ubuntu 24.04 dropped it) and logs a PAM error on every login — stale line in the PAM stack, clean up in Phase 4.
- `systemd-networkd-wait-online` times out at boot because it waits on all ten links while eight capture ports are legitimately down. Bind it to `lacp-trunk.10` in Phase 5.
- The default gateway 10.10.10.1 did not answer ping; may simply be filtered. Confirm rather than assume when Phase 5 validates routing.

---

## 13. Validation Suite (summary — full scripts land in the config repo)

Host: boot, SSH, chrony synced, DNS resolves `.lab` + upstream, apt healthy. CPU: `kvm-ok`, flags, 32 threads visible. Memory: 128 GB visible, EDAC clean. Storage: all LVs mounted with expected sizes, PERC VD optimal, SMART clean, fio baseline on a scratch file (never a raw device). Network: mgmt reachable, gateway, MTU, each capture port link/promisc/offloads-off verified. Virtualization: create → boot → network-test → destroy a cirros/ubuntu-cloud test VM. GNS3: service up, API auth, remote client connects, one QEMU node + one Docker node boot and pass traffic. WAN: apply 40 ms profile → ping shows +40 ms → clear → baseline returns; iperf3 confirms shaping. Capture: tcpreplay a reference PCAP into a feed → session count matches in Arkime, Zeek logs present, capture_loss ≈ 0, PCAP exports open cleanly in Wireshark. Monitoring: every target up in Prometheus, test alert fires. Backup: restore one file and one GNS3 project from Restic.

---

## 14. Configuration Repository

`/opt/network-lab-config/` (git):

```text
├── README.md
├── inventory/          # discovery outputs, build document
├── netplan/            # versioned copies + rollback configs
├── scripts/
│   ├── capture/        # capture-prep, drop-check, tcpreplay validation
│   ├── wan/            # wan-apply / wan-show / wan-clear + profiles/
│   ├── networking/     # bridge/NAT/mirror setup
│   └── validation/     # full suite from §13
├── systemd/            # capture-prep@.service, gns3.service, timers
├── libvirt/            # domain/network XML templates
├── gns3/               # gns3_server.conf template
├── containers/         # malcolm config deltas, monitoring compose, portal compose
├── monitoring/         # prometheus rules, grafana dashboards (json)
└── backups/            # restic policy, exclude lists (no secrets, ever)
```
