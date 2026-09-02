# Dell PowerEdge R770 — Network Analysis Lab Server Buildout Plan

**Status:** READY (planning phase — no changes applied)
**Target OS:** Ubuntu Server 24.04 LTS (minimal, no desktop)
**CPU:** 2 × Intel Xeon 6 Performance 6515P (dual-socket: 32 physical cores / 64 threads total)
**Document date:** 2026-08-24
**Scope:** Full-packet capture (Malcolm/Arkime/Zeek/OpenSearch), GNS3 simulated WAN, KVM/QEMU VMs, Docker services, internal portal, monitoring, backup.

---

## 0. Design Principles

1. Discover before configuring. Nothing in this document that names a device, interface, or capacity is final until Phase 1 discovery confirms it.
2. Management connectivity is sacred. iDRAC is the recovery path; the integrated NIC is the management path; neither is ever reconfigured without a validated alternate path.
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
  Mgmt/analyst ─────────┤ Integrated NIC (static IP, SSH, HTTPS)      │
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
  Capture feeds ───────►│ Broadcom 57412 A ports 1–4 (active feeds)  │
  (TAP/SPAN, no IP,    ►│ Broadcom 57412 B ports 1–2 (future feeds)  │
   RX-only, promisc)   ►│ Broadcom 57412 B ports 3–4 (spare)         │
                        └─────────────────────────────────────────────┘
```

Network zones, strictly separated:

| Zone | Interface | Addressed? | Purpose |
|---|---|---|---|
| OOB management | iDRAC dedicated port | Yes (iDRAC only) | Console, firmware, power, recovery |
| Host management | Integrated NIC | Yes, static | SSH/SCP/SFTP, all browser services via Nginx, DNS/NTP |
| Capture | 8 × 10GbE Broadcom ports | **No IP ever** | Passive TAP/SPAN ingestion only |
| Lab fabric | Virtual (bridges/OVS) | Internal only | GNS3, VMs, containers, WAN emulation |
| Lab NAT | Virtual → mgmt NIC | NAT | Controlled lab egress where explicitly allowed |

Key rule: capture interfaces carry no IP address, run promiscuous, transmit nothing, and are never bridged to the lab fabric. Lab traffic that needs to be analyzed reaches Malcolm through a dedicated virtual mirror feed (see §7), not by mixing zones.

---

## 2. Hardware Discovery Checklist (must be verified before any change)

**Platform**

- [ ] Service tag, BIOS version, iDRAC version and licensing (Express vs Enterprise)
- [ ] BIOS: VT-x, VT-d/IOMMU, SR-IOV, Hyper-Threading, power profile, C-states, boot mode, Secure Boot state
- [ ] Confirm iDRAC is on its dedicated port and reachable independently

**CPU / memory / NUMA**

- [ ] Both sockets populated: 2 × 6515P → 32 cores / 64 threads visible; sibling-thread map (`lscpu -e`)
- [ ] NUMA layout: expect **two NUMA nodes minimum** (sub-NUMA clustering could present four — verify and record the actual node map)
- [ ] All 8 DIMMs present at 6400 MT/s; **DIMM placement per socket** — 8 DIMMs across 2 sockets is 4 per socket, i.e. only half of Xeon 6's 8 memory channels per socket populated. Verify slots follow Dell's population rules and record the resulting per-socket bandwidth expectation; no memory errors logged
- [ ] **PCIe device NUMA locality:** which socket owns each Broadcom OCP adapter, the PERC, and the integrated NIC (`/sys/class/net/*/device/numa_node`, `lspci -tv`). This decides the capture-vs-lab socket split in §8

**Storage — do NOT assume topology**

- [ ] PERC controller model as actually reported (inventory says "H975i" — confirm exact model; current Dell PERC 12 NVMe part is H965i-class, so verify the real controller name, firmware, and cache/battery state)
- [ ] Number of physical NVMe drives, size each, health
- [ ] Virtual disk layout: is "8 TB raw, RAID 1" 2×8TB→8TB usable, 2×4TB→4TB usable, or multiple VDs? **Usable capacity is unknown until checked.**
- [ ] Whether any drives are direct-attached NVMe (not behind PERC)
- [ ] Write-cache policy on the VD

**NICs**

- [ ] Both Broadcom 57412 OCP adapters detected; PCIe slot/NUMA locality; driver (`bnxt_en`) and firmware versions
- [ ] Integrated NIC model and which physical port carries the current SSH session
- [ ] Per-port: link, queues (`ethtool -l`), ring sizes (`ethtool -g`), offload states (`ethtool -k`)
- [ ] Persistent interface naming — record predictable names before writing any Netplan

**Note on the 57412:** the 57412 is a 10GbE **SFP+** part in Dell's usual catalog; the inventory says BASE-T/RJ-45 (that is typically the 57416). Discovery must confirm which media type is actually installed, because it changes TAP/SPAN cabling and any future upgrade path. Functionally the plan is identical either way.

---

## 3. Proposed Storage Architecture

### 3.1 Capacity model (provisional — recompute after discovery)

Working assumption: RAID 1 over the ~8 TB raw pool → **~4 TB usable** (worst case). If discovery shows 2×8TB → 8 TB usable, scale the PCAP and index volumes up and keep everything else the same.

**The retention reality that drives this design:** full-packet capture at a sustained 1 Gbps writes ≈ 10.8 TB/day; at a sustained 100 Mbps ≈ 1.1 TB/day. With 1.5 TB allocated to PCAP (worst-case pool), retention is roughly:

| Sustained ingest across all feeds | PCAP retention in 1.5 TB |
|---|---|
| 50 Mbps | ~28 days |
| 100 Mbps | ~14 days |
| 500 Mbps | ~2.8 days |
| 1 Gbps | ~1.4 days |
| 4 Gbps | ~8 hours |

Four 10GbE feeds cannot be retained at line rate on this chassis — nor is that the goal for a lab. Arkime must be configured to delete oldest PCAP automatically at a free-space floor, and OpenSearch must have index lifecycle (ILM/ISM) retention. Both are hard requirements, not options.

### 3.2 Layout — LVM on the PERC virtual disk

One VG (`vg_lab`) on the RAID-1 VD. Leave ~10% of the VG unallocated as an emergency/expansion reserve.

| LV | Mount | FS | Size (of ~4 TB) | Contents |
|---|---|---|---|---|
| lv_root | `/` | ext4 | 100 GB | OS, host services |
| lv_var | `/var` | ext4 | 50 GB | logs, apt, journald (bounded) |
| lv_docker | `/var/lib/docker` | ext4 | 250 GB | images, container layers, volumes for portal/monitoring |
| lv_pcap | `/data/pcap` | **XFS** | 1.5 TB | Arkime raw PCAP (Malcolm bind-mount) + `raw/ cases/ temporary/ archived/` |
| lv_index | `/data/index` | XFS | 600 GB | OpenSearch data (Malcolm bind-mount), Zeek/Arkime metadata |
| lv_staging | `/data/staging` | XFS | 150 GB | Imported-PCAP upload/staging area |
| lv_vms | `/srv/vms` | XFS | 400 GB | libvirt images, snapshots (qcow2, sparse) |
| lv_gns3 | `/srv/gns3` | XFS | 250 GB | GNS3 projects, appliance images, temp captures |
| lv_work | `/srv/work` | XFS | 100 GB | Analyst workspaces, exports, reports, case artifacts |
| lv_backup | `/srv/backup` | XFS | 200 GB | Restic repo, config exports, docs (secondary copy must leave the box) |
| **Total allocated** | | | **~3.6 TB** | |
| *(reserve)* | — | — | ~400 GB free in VG | grow whichever LV proves undersized |

If discovery shows 8 TB usable instead of 4 TB, first grow lv_pcap (→ ~4.5 TB) and lv_index (→ ~1.2 TB), then lv_vms/lv_gns3; keep the ~10% VG reserve.

Rationale: XFS on the large streaming/parallel-write volumes (PCAP, OpenSearch, VM images) for allocation-group parallelism and large-file performance; ext4 where boring reliability is all that's needed. Separate LVs mean a runaway capture, index explosion, or fat VM disk fills **its own** filesystem, never `/`.

Mount options: `noatime` on all data LVs; use periodic `fstrim.timer` (weekly) rather than `discard` — confirm the PERC VD actually passes TRIM through before relying on it (discovery item). No swap beyond a small 8 GB swapfile with low swappiness; OpenSearch performs badly when swapped (Malcolm sets memlock).

### 3.3 Retention and protection policy

- Arkime: `freeSpaceG` floor on `/data/pcap` (≥ 5%), oldest-first deletion — but **only** within `raw/`; `cases/` and `archived/` are operator-curated and never auto-deleted.
- OpenSearch ISM: sessions/Zeek indexes roll and delete at a target that keeps `/data/index` under 80%.
- Prometheus alerts at 70/80/90% on every data LV.
- Nothing in `cases/` or `/srv/work` is ever deleted automatically.

---

## 4. Proposed Network Architecture

### 4.1 Physical

- **Integrated NIC** → static IP via Netplan, management VLAN/subnet, default route, DNS pointing at the local resolver, NTP via chrony. This is the only host IP on physical hardware.
- **iDRAC dedicated port** → OOB network only. Verified reachable *before* any host networking change is ever applied.
- **8 × Broadcom 10GbE ports** → defined in Netplan with **no addresses**, brought up by a `capture-prep` systemd service that sets promisc, disables offloads, and pins them RX-only in practice (no protocols bound). Nothing else touches them.

### 4.2 Capture-port preparation (per active feed, applied by script/systemd — names are placeholders until discovery)

```bash
# capture-prep <iface> — run per capture port at boot
ip link set <iface> up promisc on mtu 9216      # accommodate VLAN/jumbo on monitored links
ethtool -K <iface> gro off lro off tso off gso off rx-gzip off \
        rxvlan off txvlan off ntuple off 2>/dev/null || true
ethtool -K <iface> rx off tx off sg off 2>/dev/null || true   # checksum offloads
ethtool -G <iface> rx <max-from-discovery>                     # max ring size
ethtool -A <iface> rx off tx off                               # no pause frames
```

Offloads are disabled **only** on capture ports — GRO/LRO coalesce packets and destroy wire-faithfulness; the management NIC keeps all offloads. Ring sizes and queue counts come from `ethtool -g/-l` discovery, not guesses.

### 4.3 Virtual / lab fabric

Start with Linux bridges (libvirt-managed):

| Bridge | Purpose | Host IP | Egress |
|---|---|---|---|
| `br-lab-mgmt` | VM/appliance management | Yes (RFC1918 /24) | none |
| `br-lab-nat` | Lab internet access when explicitly needed | Yes | NAT via mgmt NIC, firewalled |
| `br-lab-tXX` | GNS3/lab transit segments, created per topology | No | none |
| `br-mirror` | Virtual mirror feed → Malcolm capture (see §7) | No | none |

**OVS decision:** not installed at initial build. Adopt OVS later *only if* a concrete need appears — port mirroring of many lab segments at once, 802.1Q trunk manipulation inside the fabric, or OpenFlow experiments. Linux bridges + `tc-mirred` cover the initial mirror-to-Malcolm requirement. This decision is recorded and reversible.

### 4.4 WAN emulation

`tc`/`netem` on GNS3 link endpoints or dedicated impairment namespaces. Reusable profile scripts in the config repo (`wan-apply <profile> <iface>`, `wan-show`, `wan-clear`), with profiles for branch WAN (20 Mbps/40 ms/5 ms jitter/0.2% loss), satellite (25 Mbps/600 ms), poor broadband (10 Mbps/80 ms/2% loss), and asymmetric variants (HTB for rate + netem for delay; IFB for ingress where needed). Every profile has apply/show/clear. Impairments never touch the management NIC or capture ports.

### 4.5 Internal DNS / names

dnsmasq (simplest fit: DNS + optional DHCP for lab bridges in one small service) serving `.lab` on the management interface and lab bridges: `portal.lab`, `malcolm.lab`, `gns3.lab`, `monitoring.lab`, `idrac.lab` (A record pointing into the OOB net only if mgmt can route there — otherwise document as OOB-only). Chrony serves NTP to the lab from the host, syncing upstream from the mgmt network.

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
- Node types: QEMU appliances (routers/firewalls/endpoints), Docker nodes for lightweight endpoints, built-in switches/clouds. Cloud nodes may attach lab bridges — never the management NIC, never capture ports.

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

### Socket split (assign after discovery confirms which socket owns the capture NICs)

- **Capture/analysis socket** — the socket the Broadcom OCP adapters attach to: Malcolm stack (Arkime, Zeek, OpenSearch, Logstash), capture IRQ affinity, host network services. Capture packets then never cross the UPI link to be processed.
- **Lab socket** — the other socket: GNS3, QEMU/KVM VMs, lab containers, WAN-emulation work.

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

## 11. Build Phases (dependency order)

| # | Phase | Depends on | Destructive? |
|---|---|---|---|
| 1 | Hardware & OS discovery (read-only) | — | No |
| 2 | BIOS/firmware/iDRAC assessment; RAID VD verification | 1 | Only if changes chosen (each gated) |
| 3 | Storage: LVM/filesystem layout on the RAID VD | 1,2 | **Yes** if reinstall/re-partition needed — full confirmation gate |
| 4 | Base OS: hostname, time, DNS client, users, SSH hardening, UFW, baseline packages, auditd/rsyslog | 3 | Low (SSH/firewall steps gated) |
| 5 | Management networking finalized in Netplan (`netplan try`), dnsmasq + chrony serving `.lab` | 4 | Medium — mgmt-connectivity protocol applies |
| 6 | Docker Engine + Compose; `/var/lib/docker` on lv_docker | 4 | No |
| 7 | KVM/libvirt + lab bridges + NAT zone; test VM lifecycle | 5 | Low |
| 8 | GNS3 server + service + proxy publication | 6,7 | No |
| 9 | Capture-port prep (offloads/promisc/systemd) + drop-stat plumbing | 5 | No (capture ports only) |
| 10 | Malcolm deployment, bind mounts, live capture on feeds 1–4, retention config | 6,9,3 | No |
| 11 | Virtual mirror feed + imported-PCAP workflow | 10,7 | No |
| 12 | WAN impairment script library | 7 | No |
| 13 | Nginx portal + TLS + internal DNS names + MkDocs docs site | 5,6 | No |
| 14 | Monitoring/alerting stack + capture validation suite | 10,13 | No |
| 15 | Backup jobs + restore test | 3,13 | No |
| 16 | Full validation pass (§13) + performance baseline + build document | all | No |

---

## 12. Risks and Unknowns (must be resolved by discovery)

1. **Usable storage capacity unknown.** RAID 1 over "~8 TB raw" may mean 4 TB usable — which halves every §3 number. Highest-impact unknown; resolve first.
2. **PERC model discrepancy** ("H975i" vs Dell's H965i-class NVMe RAID parts) — confirm controller, firmware, cache policy, and TRIM passthrough behavior.
3. **NIC media discrepancy** — 57412 is SFP+ in Dell's catalog; BASE-T suggests 57416. Affects TAP/SPAN cabling only, but must be confirmed before ordering taps.
4. **Retention vs ingest rate** — until real feed rates are measured, all retention figures are model numbers. Measure in Phase 10, then set Arkime/ISM floors from data.
5. **Single box, single RAID-1 VD** — capture I/O, OpenSearch indexing, and VM disks share one spindle-set. NVMe mitigates this, but sustained multi-feed capture + heavy lab use may contend; the monitoring stack's disk-latency panels are the tripwire. Mitigation if proven: dedicate a future direct-attached NVMe to PCAP.
6. **Memory ceiling before CPU ceiling — now more so.** With 32 cores, 128 GB splits ~64 GB infrastructure / ~48 GB labs, and RAM is decisively the binding constraint: big GNS3 topologies (router appliances at 2–4 GB each) hit the lab socket's ~64 GB node long before its 16 cores saturate. Watch Grafana; plenty of DIMM slots remain (4 of 8 channels per socket populated), so growth to 256 GB is a straightforward upgrade that also fixes the bandwidth caveat below.

6a. **Half-populated memory channels + NUMA locality** — 4 DIMMs/socket halves per-socket memory bandwidth, and any workload placed on the wrong socket pays UPI-crossing penalties on top. Discovery must map NIC/PERC socket ownership before the §8 split is finalized; if both OCP slots land on the same socket as the PERC, that socket carries all I/O and the plan stands — if they split across sockets, revisit which socket is "capture."

7. **Management NIC is a single point of access** — iDRAC must be verified as the working recovery path before Phase 5 touches Netplan.
8. **Malcolm resource appetite** — OpenSearch and Zeek sizing in §8 is a starting model; Malcolm's own tuning (worker counts, heap) must be set from measured feed rates, not defaults.
9. **Backup escape** — until the Restic repo is copied off-box, a chassis loss loses everything. Operational owner needed.
10. **Suricata off by default** — enabling it later adds a full extra per-packet processing pipeline; re-run the CPU budget before switching it on.

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

---

## 15. Phase 1 — Read-Only Discovery Commands

Run these on the fresh Ubuntu install and return the output. Nothing here modifies state. (The packaged form of this section is `scripts/r770-precheck.sh`.)

```bash
# ── Identity / OS ─────────────────────────────────────────────
hostnamectl
uname -a
cat /etc/os-release

# ── CPU / NUMA / virtualization ───────────────────────────────
lscpu
lscpu -e
grep -c -E 'vmx' /proc/cpuinfo
sudo dmidecode -t processor | head -40
numactl --hardware 2>/dev/null || echo "numactl not installed"
sudo dmesg | grep -i -E 'iommu|dmar' | head -20

# ── Memory ────────────────────────────────────────────────────
free -h
lsmem
sudo dmidecode -t memory | grep -E 'Size|Speed|Rank|Locator|Part Number' | head -60

# ── Platform / firmware ───────────────────────────────────────
sudo dmidecode -t system
sudo dmidecode -t bios
ls /sys/firmware/efi >/dev/null 2>&1 && echo "UEFI boot" || echo "BIOS boot"
mokutil --sb-state 2>/dev/null || echo "mokutil not installed"

# ── Storage ───────────────────────────────────────────────────
lsblk -e7 -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
sudo nvme list 2>/dev/null || echo "nvme-cli not installed"
findmnt --real
sudo fdisk -l 2>/dev/null | head -60
df -h
lspci -nn | grep -i -E 'raid|storage|nvme|sas'
# PERC (if perccli/perccli2 present; otherwise note for Phase 2):
sudo perccli2 /call show 2>/dev/null || sudo perccli /call show 2>/dev/null || echo "perccli not installed"
sudo smartctl --scan 2>/dev/null || echo "smartmontools not installed"

# ── PCIe / NICs ───────────────────────────────────────────────
lspci -nn | grep -i ethernet
lspci -tv | head -60
ip -br link
ip -br addr
ip route
ip -d link | head -80
# For EACH interface name shown by `ip -br link` (repeat, substituting real names):
#   ethtool <iface>            # link, speed, media
#   ethtool -i <iface>         # driver, firmware
#   ethtool -l <iface>         # queue counts
#   ethtool -g <iface>         # ring sizes
#   ethtool -k <iface> | grep -E 'gro|lro|tso|gso|checksum|vlan'
ls /sys/class/net/*/device/numa_node 2>/dev/null | while read f; do echo "$f: $(cat $f)"; done

# ── Current management path (protect before anything changes) ──
who am i
ss -tnp | grep ':22 ' | head -5
ip route get 1.1.1.1
ls -l /etc/netplan/
sudo cat /etc/netplan/*.yaml

# ── iDRAC visibility from host (optional, read-only) ──────────
sudo ipmitool lan print 1 2>/dev/null | grep -E 'IP Address|MAC' || echo "ipmitool not installed/available"

# ── Health / errors ───────────────────────────────────────────
sudo dmesg --level=err,warn | tail -40
journalctl -p err -b --no-pager | tail -30
```

**Next step after output is returned:** finalize actual usable storage capacity and interface map, then produce Phase 3 (storage) and Phase 4 (base OS) as exact, gated command sets in the phase output format.

---

*Nothing in this plan has been applied. All capacities, interface names, and device paths above are provisional until Phase 1 discovery output is analyzed. Status: READY — awaiting discovery output.*
