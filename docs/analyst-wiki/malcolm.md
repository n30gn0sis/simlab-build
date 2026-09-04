# Analysis Stack — Malcolm

Malcolm (pinned at **v26.08.0**) is the lab's traffic-analysis platform. It is one integrated Docker Compose deployment that bundles every analysis tool you'll touch — you don't install or manage any of them, you just use their web interfaces through the portal.

**What's inside, in analyst terms:**

| Component | What it gives you |
|---|---|
| **Arkime** | Full-packet indexing: search sessions, view SPI (session profile information), export PCAP |
| **Zeek** | Rich protocol metadata: connection, DNS, HTTP, TLS, file-transfer logs and more |
| **OpenSearch Dashboards** | Visual exploration of everything Zeek and Arkime index |
| **OpenSearch** | The search engine underneath (you query it via Arkime/Dashboards, not directly) |
| **Suricata** | Signature IDS — present but **disabled at initial build**; no alerts until enabled |

**Where the traffic comes from:** physical TAP/SPAN feeds on dedicated capture ports, a virtual mirror of lab topologies (see [GNS3](gns3.md#analyzing-lab-traffic)), and PCAPs you import yourself.

**Known limitations up front:** no GeoIP (country/ASN fields absent — descoped), no Suricata alerts initially, and raw PCAP ages out automatically (see [retention](access.md#storage-and-retention)).

## Arkime

Arkime is where you go when the question is *"show me the traffic."* It indexes every session (flow) it captures, keeps the raw packets on disk until they age out, and lets you search, inspect, and export.

**Getting oriented (new analysts):** the main views are **Sessions** (the search results list — every row is one session, expandable to see details and packets), **SPIView** (aggregated field values for your current search — like a pivot table of every indexed field), **SPIGraph** (one field graphed over time), and **Connections** (a node-link graph of who talked to whom).

### Common searches

Arkime's query bar uses its own expression syntax. The everyday patterns:

```text
ip == 10.10.20.5                          # any session involving this IP
ip.src == 10.10.20.5 && port.dst == 445   # SMB from a host
protocols == dns                          # by protocol
http.uri == *login*                       # URI substring
host.http == portal.example.com           # HTTP host header
tls.ja3 == <hash>                         # TLS client fingerprint
bytes >= 10000000                         # big transfers
tags == <tag>                             # imported-PCAP batches are taggable
```

Combine with `&&`, `||`, parentheses. Set the **time range** first — it bounds every query and is the most common reason for "no results."

Typical workflow: broad query → narrow with SPIView (click a field value to add it to the query) → open the interesting session → read the packet view → export what matters.

### Exporting to Wireshark

Wireshark itself runs on your workstation, not on the server. To get packets there:

1. Run the search that isolates the sessions you care about.
2. Use Arkime's **Export PCAP** action (per-session, or for the whole result set).
3. Save the export into your workspace under `/srv/work/`, then pull it to your workstation over SFTP.
4. Open in Wireshark. Exports are standard PCAP and open cleanly.

If the sessions are case-relevant, also promote a copy to `/data/pcap/cases/` so the evidence outlives raw retention.

### Trusting a capture

Before you conclude "that traffic never happened," check drop counters: Arkime's own stats page shows per-interface capture drops, and the Grafana capture-health dashboard trends them. Zeek writes its estimate to `capture_loss` (visible in Dashboards) — it should sit at ≈0%. Non-zero loss during your window means absence of evidence is not evidence of absence.

## Zeek

Zeek doesn't show you packets — it reads them and writes structured logs about what happened at the protocol level. For most investigative questions ("what did this host resolve?", "what certs did it see?", "what files moved?") Zeek logs are faster than packet-diving.

The logs you'll use constantly, all searchable in Dashboards:

| Log | Answers |
|---|---|
| `conn` | Who connected to whom, when, how long, how many bytes — the backbone; every session has a `uid` that links logs together |
| `dns` | Every query and response — names, types, answers, failures |
| `http` | Method, host, URI, user-agent, status, MIME types |
| `ssl` / `x509` | TLS versions, SNI, JA3/JA4 fingerprints, certificate details |
| `files` | Files observed in transit — hashes, sizes, MIME types, which session carried them |
| `smb_*`, `rdp`, `ssh`, `ftp`, `ntp`, … | Per-protocol detail logs |
| `notice` | Things Zeek's policy scripts consider noteworthy |
| `weird` | Protocol anomalies — malformed, out-of-spec behavior; a good hunting ground |
| `capture_loss` | Zeek's own estimate of missed packets — your capture-quality gauge |

The `uid` field is the thread that ties it all together: find a suspicious DNS answer, take its `uid`/related `uid`s to `conn`, then pivot into Arkime with the same 5-tuple and time to get the actual packets.

## Dashboards

OpenSearch Dashboards is the visual layer over everything Malcolm indexes (Zeek logs, Arkime sessions, and Suricata alerts if ever enabled). Malcolm ships a large set of prebuilt dashboards — overview, per-protocol pages (DNS, HTTP, TLS, SMB…), file transfers, and connection maps.

Use it when the question is shaped like *"what does this time window look like?"* rather than *"show me this session"*: top talkers, protocol mix over time, spikes, rare user-agents, newly seen hostnames. Filter by clicking values or with the query bar (Lucene/DQL syntax, e.g. `source.ip:10.10.20.5 AND destination.port:445`), then pivot to Arkime when you need packets. Note the field-name difference: Dashboards uses ECS-style names (`source.ip`), Arkime uses its own (`ip.src`).

Geo map panels will be empty — GeoIP is descoped.

## Importing PCAP

Bringing your own capture into Malcolm gives it the full treatment — Zeek logs, Arkime indexing, dashboards — the same as live traffic:

1. SFTP your file(s) into `/data/staging/`.
2. Use Malcolm's upload/ingest interface and point it at the file. Assign a **tag** while ingesting — it's how you'll isolate your dataset from everything else (`tags == mytag` in Arkime, `tags:mytag` in Dashboards).
3. Wait for processing (large PCAPs take a while; progress is visible in the upload UI).
4. Analyze as usual, filtered to your tag.
5. Clean your originals out of `/data/staging/` when done — it's a working area, not storage.

Timestamps note: imported traffic appears at its *original* capture time — set the Dashboards/Arkime time range to when the PCAP was recorded, not to today.

## Suricata (disabled)

Suricata ships inside Malcolm and the ET Open ruleset is cached in the lab bundle, but the service is **off at initial build** (it adds a full per-packet processing pipeline, and the CPU budget must be re-checked before enabling). If it's enabled later, alerts become a new searchable data source in Dashboards. Until then: no signature-based alerting exists in this lab — detection is whatever you and Zeek's logs find.
