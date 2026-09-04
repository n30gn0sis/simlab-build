# Analyst Guide — R770 Network Lab

> **Build status: the lab is not yet live.** This guide documents the tools that are *confirmed and pinned* for the build (they are already in the offline software bundle). Anything not yet certain — final URLs, storage sizes, interface names — is collected in [Pending items](#pending-items) at the bottom rather than guessed at in the pages. When the build completes, that section shrinks to nothing and this banner comes down.

## What this lab is

A single air-gapped Dell PowerEdge R770 running Ubuntu Server 24.04 that does four jobs at once:

1. **Full-packet capture and analysis** — the [Malcolm stack](malcolm.md) (Arkime, Zeek, OpenSearch Dashboards) ingests traffic from physical TAP/SPAN feeds and from imported PCAPs, indexes it, and lets you search sessions, read protocol logs, and pull packets back out for Wireshark.
2. **Network simulation** — [GNS3](gns3.md) runs virtual routers, firewalls, switches, and endpoints so you can build realistic topologies without touching production gear.
3. **WAN emulation** — [impairment profiles](wan.md) add latency, jitter, loss, and rate limits to lab links so topologies behave like real branch/satellite/broadband circuits.
4. **A workbench** — [host CLI tools](cli-tools.md) for spot captures, traffic replay, and throughput testing, plus per-analyst [workspace directories](access.md) for case artifacts and exports.

Everything runs offline. There is no internet on this box — software, IDS rules, and documentation all arrive via a curated offline bundle. What that means for you day-to-day is covered in [Access & housekeeping](access.md#air-gap-rules).

## Which tool, when

| You want to… | Use | Page |
|---|---|---|
| Search captured traffic by IP, port, protocol, URI, JA3, etc. | Arkime | [Malcolm](malcolm.md#arkime) |
| Read protocol metadata (DNS queries, TLS certs, HTTP requests, file transfers) | Zeek logs via Dashboards | [Malcolm](malcolm.md#zeek) |
| Get a visual overview of a time window (top talkers, protocols, trends) | OpenSearch Dashboards | [Malcolm](malcolm.md#dashboards) |
| Analyze a PCAP you brought from elsewhere | Malcolm upload via staging | [Malcolm](malcolm.md#importing-pcap) |
| Deep-dive individual packets | Export from Arkime → Wireshark on your workstation | [Malcolm](malcolm.md#exporting-to-wireshark) |
| Build a network topology to test or reproduce something | GNS3 | [GNS3](gns3.md) |
| Make a lab link behave like a bad WAN circuit | `wan-apply` profiles | [WAN emulation](wan.md) |
| Capture and analyze traffic *from a lab topology* | Virtual mirror feed → Malcolm | [GNS3](gns3.md#analyzing-lab-traffic) |
| Quick spot-check that packets are flowing on an interface | `tcpdump` / `tshark` (pcapture group) | [CLI tools](cli-tools.md#spot-capture) |
| Replay a reference PCAP into a capture feed | `tcpreplay` | [CLI tools](cli-tools.md#tcpreplay) |
| Measure throughput or verify an impairment took effect | `iperf3`, `ping`, `mtr` | [CLI tools](cli-tools.md#throughput-and-path-testing) |
| Check lab health, storage burn-rate, capture drops | Grafana | [Access & housekeeping](access.md#monitoring) |
| Read tool documentation without internet | Offline docs mirrors | [Access & housekeeping](access.md#offline-documentation) |

## The one rule that protects your evidence

Raw captured PCAP is **automatically deleted oldest-first** when the capture volume hits its free-space floor. If packets matter to a case, move or export them to a curated location (`cases/`, `archived/`, or your workspace) — those are never auto-deleted. Details in [Access & housekeeping](access.md#storage-and-retention).

## Pending items

These are the things this guide deliberately does *not* state yet, because they depend on hardware discovery, build decisions, or measurement that hasn't happened:

- **Final service URLs and hostnames.** The design calls for friendly internal names served through a portal (working names: `portal.lab`, `malcolm.lab`, `gns3.lab`, `monitoring.lab`), but nothing is live and names/addresses are unconfirmed.
- **Retention windows.** Usable disk is now known — **7.68 TB on one RAID-1 volume**, with **3.25 TiB allocated to PCAP** — but PCAP retention still depends on measured feed rates, so the windows below remain estimates until the build measures real feeds. Plan on **days, not weeks**.
- **Capture feed inventory.** Which physical ports carry which TAP/SPAN feeds, and their names, are set during build.
- **Account provisioning.** How analysts get SSH keys, Malcolm logins, and GNS3 accounts — process TBD by the lab operator.
- **Licensed GNS3 appliances.** Free/open-source appliances (VyOS, MikroTik CHR, OPNsense, FRR, etc.) are bundled; which licensed images (Cisco, Fortinet, Palo Alto) get staged depends on entitlement inventory, still open.
- **Suricata.** Present inside Malcolm but **disabled** at initial build. If it is enabled later, IDS alerts appear as an additional data source; the CPU budget must be re-checked first.
- **GeoIP.** Descoped — no MaxMind account. Geo fields (country, ASN maps) will be **absent** in Arkime and Dashboards unless this decision is reversed.
- **Grafana dashboard inventory.** The planned panels (capture health, storage burn-rate, host health) firm up in the monitoring build phase.
- **Windows endpoint VMs.** Not in the bundle (descoped). Lab endpoints are Linux (Ubuntu cloud image, Alpine, CirrOS, Docker nodes).

## Site navigation (for the MkDocs build)

When the internal docs site is assembled, drop these pages in as:

```yaml
nav:
  - Analyst Guide: index.md
  - Access & Housekeeping: access.md
  - Analysis Stack (Malcolm): malcolm.md
  - Network Simulation (GNS3): gns3.md
  - WAN Emulation: wan.md
  - Host CLI Tools: cli-tools.md
```
