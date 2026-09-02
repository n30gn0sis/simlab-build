# Network Simulation — GNS3

GNS3 (server pinned at **v3.0.6**) is the lab's topology builder: drag routers, firewalls, switches, and endpoints onto a canvas, wire them up, and run them as real software — QEMU virtual machines and Docker containers under the hood. Use it to reproduce a customer network, build a test bed for a protocol question, stage traffic for capture practice, or rehearse a change.

## Connecting

Two ways in, same server, same projects:

- **Web UI** — GNS3 v3 ships a built-in web interface, reached through the portal. Good for most topology work.
- **Desktop GNS3 GUI** — install the GNS3 client on your workstation and point it at the lab server as a *remote server* through the portal address. Familiar if you've used GNS3 standalone; nothing runs on your workstation except the GUI.

Authentication is enforced by the server (accounts **TBD** until provisioning is defined). Projects live server-side under `/srv/gns3/projects` — they persist between sessions and are included in nightly backups, so your topology survives both logout and disaster.

## What you can build with

### Routers & network appliances (QEMU)

Bundled free/open-source appliances, ready to use:

| Appliance | Role |
|---|---|
| **VyOS** | General-purpose router — OSPF/BGP, VPN, firewall; the workhorse |
| **MikroTik CHR** (RouterOS 7.21) | RouterOS environments |
| **OPNsense** (26.7) | Firewall/router with a full web UI (the no-license pfSense alternative) |
| **FRR** | Pure routing stack — lightweight BGP/OSPF/IS-IS nodes |
| **OpenWrt** | CPE/edge-device behavior |

Appliance *definitions* also exist for licensed images — Cisco IOSv/IOSvL2/ASAv, FortiGate, Palo Alto VM-Series — but the images themselves are entitlement-gated. Which ones are actually staged is **TBD**; check the appliance list in the UI or ask the operator before planning a Cisco-dependent lab.

### Endpoints

- **Docker nodes** (light, boot in seconds, cheap on RAM — prefer these): Alpine, Debian, **netshoot** (a container packed with network troubleshooting tools — ping/curl/dig/iperf/tcpdump in one node), and FRR as a container.
- **Linux VMs** (when you need a full OS): Ubuntu cloud image, Alpine, TinyCore, and CirrOS (minimal, for connectivity tests).
- **Built-ins:** GNS3's internal ethernet switches and hubs cost nothing to run — use them for basic L2 plumbing instead of booting a whole appliance.

No Windows endpoints — descoped from the bundle.

### Resource etiquette

This is a shared box. Router/firewall appliances cost real RAM (commonly 2–4 GB *each*) and lab capacity is bounded — a couple dozen heavyweight appliances will exhaust the lab's memory budget before anything else. Habits that keep everyone happy:

- Prefer Docker nodes and built-in switches over VMs wherever the job allows.
- Stop topologies when you're done for the day; projects keep their state.
- Check the Grafana host dashboard before launching something huge.

## Analyzing lab traffic

The lab's best trick: traffic inside your GNS3 topology can be fed into Malcolm and analyzed exactly like real captured traffic — Zeek logs, Arkime search, dashboards, the lot.

Mechanically, lab bridge segments are mirrored into a dedicated virtual feed that Malcolm captures alongside the physical TAPs (the capture ports themselves are never bridged into the lab — evidence and experiments stay separated). The workflow:

1. Build and start your topology; get traffic flowing.
2. Ask the operator to mirror the relevant lab segment (or use the documented mirror script once the build lands — exact procedure **TBD**).
3. Analyze in Malcolm. Filter by your lab's IP ranges or the mirror feed's interface/tag to isolate your traffic from the physical feeds.

For a quick look that doesn't need the full Malcolm treatment, GNS3 also has built-in per-link capture (right-click a link → capture) which writes a PCAP you can pull back to Wireshark — handy for a single link, no mirror needed.

Combine with [WAN emulation](wan.md) to watch how protocols behave under latency and loss — captured and analyzed like any other traffic.
