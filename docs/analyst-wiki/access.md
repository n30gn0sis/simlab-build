# Access & Housekeeping

How you reach the lab, where your files live, what gets deleted automatically, and the rules an air-gapped box imposes.

> Items marked **(TBD)** depend on build decisions not yet final — see [Pending items](index.md#pending-items).

## Getting in

All analyst access happens over the **management network**. The capture side of the box is invisible to you by design — capture ports have no IP addresses and cannot be reached.

| Access | Mechanism | Notes |
|---|---|---|
| Web services | HTTPS through the Nginx portal | One entry point fans out to Malcolm, GNS3, Grafana, and the docs site. Final URLs **(TBD)** — working names are `portal.lab`, `malcolm.lab`, `gns3.lab`, `monitoring.lab` |
| Shell | SSH, **key-only** (no passwords, no root login) | Management IP only. Key enrollment process **(TBD)** |
| PCAP drop-off | SFTP to the staging area | Scoped account; see [Importing PCAP](malcolm.md#importing-pcap) |
| GNS3 desktop client | Connects to the GNS3 server API through the portal | Same credentials as the GNS3 web UI |

**TLS certificates:** the lab has no public CA. Services present certificates from the lab's **internal CA** — you will need to trust the internal CA certificate on your workstation once (browser + OS store), or you'll see warnings on every service. Get the CA cert from the lab operator.

**Logins:** GNS3 v3 enforces its own authentication, Malcolm has its own account system, and Grafana has its own admin/viewer accounts. These are separate credential sets **(TBD** until provisioning is defined**)**.

## Storage and retention

The disk layout separates evidence, scratch, and infrastructure so that nothing can starve anything else. What you need to know as an analyst:

| Path | What it's for | Deletion policy |
|---|---|---|
| `/data/pcap/raw/` | Live capture written by Arkime | **Auto-deleted oldest-first** when the volume hits its free-space floor. Never store anything here yourself |
| `/data/pcap/cases/` | PCAPs promoted to a case | **Never auto-deleted.** Operator-curated |
| `/data/pcap/archived/` | Long-term keeps | **Never auto-deleted** |
| `/data/pcap/temporary/` | Short-lived scratch captures | Treat as expendable |
| `/data/staging/` | SFTP upload area for imported PCAPs | Working area — clean up after Malcolm ingests your file |
| `/srv/work/` | Per-analyst workspaces: exports, reports, case artifacts | **Never auto-deleted** |

The practical rule: **`raw/` is a conveyor belt, not a shelf.** How long the belt is depends on total ingest rate — at a sustained 100 Mbps across all feeds the math gives roughly two weeks in a 1.5 TB allocation; at 1 Gbps, under two days. Real numbers come after the build measures real feeds **(TBD)** — until then assume raw retention is short and promote anything that matters.

Zeek/Arkime *metadata* (the searchable index) has its own longer retention, managed by index lifecycle policies — so you will often still be able to *find* a session in Arkime after its packets have rolled off. You get the session record and protocol logs, but not the payload.

**Backups:** configs, GNS3 projects, curated case artifacts, and workspace selections are backed up nightly. Raw PCAP and search indexes are **not** backed up, by policy. If it only exists in `raw/`, it isn't protected.

## Monitoring

Grafana (via the portal) is the lab's health view. The dashboards worth an analyst's attention:

- **Capture health** — per-feed packet rates and drop counters. If drops are non-zero during your capture window, your PCAP has holes; check before drawing conclusions from absence of traffic.
- **Storage burn-rate** — days-to-full projection for the PCAP and index volumes. This tells you how long `raw/` retention effectively is right now.
- **Host health** — CPU, RAM, disk latency. Useful before launching a heavy GNS3 topology.

Alerting (disk thresholds, sustained capture drops, service down) goes to the portal. Exact dashboard inventory firms up during the monitoring build phase **(TBD)**.

## Air-gap rules

This server has **no internet access, ever**. Consequences:

- **You cannot install software on it.** `apt install`, `pip install`, and `docker pull` all fail by design. If a tool you need is missing, request it — it gets added to the next offline bundle. There is no workaround, and attempting one is a policy violation.
- **IDS rules and enrichment data are only as fresh as the last bundle.** The Suricata ET Open ruleset, OUI vendor list, and similar data update only when a new bundle is cut.
- **No geo lookups.** GeoIP was descoped; country/ASN fields are absent in Arkime and Dashboards.
- **Bringing data in:** PCAPs and files come in via SFTP to `/data/staging/` over the management network, or via approved removable media per site policy.
- **Taking data out:** exports leave via SFTP from `/srv/work/`, subject to site data-handling policy. Nothing on this box syncs anywhere automatically.
- **Time:** the lab keeps its own clock (chrony serves the lab). Timestamps are consistent *within* the lab; verify offset against your evidence source before correlating with external logs.

## Offline documentation

Because you can't google from the lab network, the docs site mirrors upstream documentation locally: Malcolm docs, Zeek docs, Arkime docs, GNS3 docs, and the Wireshark user guide. Reach them through the portal's docs link. Mirrors are best-effort snapshots from bundle-build time — good for reference, not guaranteed current.
