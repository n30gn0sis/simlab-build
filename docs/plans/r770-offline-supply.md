# R770 Lab — Air-Gap / Offline Supply Plan

**Companion to:** `r770-network-lab-buildout.md`
**Date:** 2026-08-24
**Model:** everything the build needs is downloaded and verified on an internet-connected **staging host**, packed into a versioned **bundle**, moved across the gap on approved media, and served locally on the R770. Nothing on the R770 ever needs internet.

```text
Internet ──► Staging host (Ubuntu 24.04 VM + Docker)
                 │  r770-offline-fetch.sh  → bundle-YYYYMMDD/  + MANIFEST.sha256
                 ▼
          Approved transfer media (USB/NVMe, checksummed, scanned)
                 ▼
          R770 (air-gapped)
            ├── local APT repo  (nginx: http://portal.lab/apt  or file:/)
            ├── docker load / local registry
            ├── pip wheelhouse (GNS3)
            └── images/ISOs/enrichment data in place
```

---

## 1. What must be cached, by component

### 1.1 Ubuntu OS + all APT packages

| Item | Source | Size (approx) |
|---|---|---|
| Ubuntu Server 24.04.x LTS ISO (+ SHA256SUMS + GPG sig) | releases.ubuntu.com | ~3 GB |
| Curated .deb bundle: every package from every build phase **plus dependencies** | archive.ubuntu.com / security.ubuntu.com | 3–6 GB |
| Docker Engine debs (docker-ce, docker-ce-cli, containerd.io, buildx, compose plugin) + Docker's GPG key | download.docker.com | ~400 MB |

The curated package list (full list lives in the fetch script): qemu-kvm/libvirt/virtinst stack, ovmf, bridge-utils, openvswitch-switch (cached even though deferred — costs nothing), nginx, dnsmasq, chrony, auditd, ufw, lvm2, xfsprogs, smartmontools, nvme-cli, ipmitool, ethtool, numactl, sysstat, tcpdump, tshark, tcpreplay, iperf3, fio, stress-ng, restic, easy-rsa, git, jq, tmux, htop, iotop, mtr-tiny, dnsutils, nmap, lsof, strace, lm-sensors, edac-utils, python3-venv/pip, dpkg-dev, cpu-checker, guestfs-tools, prometheus-node-exporter (deb is simpler than a container for host metrics).

**Two supply strategies — pick one:**

* **Curated bundle (recommended, what the script does):** resolve and download the exact package set inside a clean `ubuntu:24.04` container, then build a signed local repo with `dpkg-scanpackages`. Small, auditable, fast to refresh. Limitation: it covers what you listed; an unplanned `apt install foo` on the gapped box fails until the next bundle.
* **Partial mirror (`apt-mirror`/`aptly` of noble main+security, amd64 only):** everything installable forever, but **hundreds of GB** and slower refreshes. Worth it only if the lab will grow unpredictably.

Kernel/security updates arrive the same way: each refresh cycle, the container runs `dist-upgrade --download-only` against the pinned package set so the bundle carries current security debs (including HWE kernels — add `linux-generic-hwe-24.04` to the list to track them).

### 1.2 Malcolm (the big one)

Malcolm's releases are already offline-friendly ([releases page](https://github.com/idaholab/Malcolm/releases); current: [v26.08.0](https://github.com/idaholab/Malcolm/releases/tag/v26.08.0), pinned 2026-09-04):

| Artifact | Use |
|---|---|
| `malcolm-<ver>-docker_install.zip` (~0.5 MB) | Config/install scripts — our path, since the R770 runs Ubuntu |
| Container images (~20–30 GB unpacked) | On staging: run Malcolm's `docker compose pull` against its compose file, then `docker save` all `ghcr.io/idaholab/malcolm/*` images to a tarball |
| `malcolm-<ver>.iso.*` (3× ~1.9 GB chunks) | Alternative appliance route — full Malcolm ISO with images embedded. **Not** our route (we keep Ubuntu as the host OS), but worth storing one copy as a recovery/reference option |

On the R770: `docker load -i malcolm-images-<ver>.tar`, then run Malcolm's install/configure scripts, which find the images locally and never pull.

### 1.3 Other container images

Pull + `docker save` on staging: `prom/prometheus`, `grafana/grafana-oss`, `prom/alertmanager`, `prom/blackbox-exporter`, `gcr.io/cadvisor/cadvisor`, `nginx:stable`, `registry:2` (optional local registry), `squidfunk/mkdocs-material` (docs builds). ~2–3 GB total. Pin tags — never `latest` — so the gapped box is reproducible.

### 1.4 GNS3

| Item | Method |
|---|---|
| gns3-server + deps | `pip download` into a wheelhouse inside a `python:3.12` container (matches noble's Python) → install offline with `pip install --no-index --find-links` |
| GNS3 appliance images (router/firewall qcow2, IOS, endpoint images) | **You supply these** — licensed vendor images cannot be scripted; stage them into `bundle/gns3/appliances/`. This is usually the largest and most manual category |
| `.gns3a` appliance definition files | Grab from gns3.com registry on staging for the appliances you use |

### 1.5 VM base images

Ubuntu noble cloud image (`noble-server-cloudimg-amd64.img`), CirrOS (tiny test VM for the validation suite), any Windows/other lab ISOs you're licensed for, virtio-win drivers if Windows guests are planned. ~1–5 GB + lab ISOs.

### 1.6 Enrichment & rule data (the recurring, easy-to-forget category)

| Data | Used by | Offline handling |
|---|---|---|
| MaxMind GeoLite2 (City/ASN/Country mmdb) | Arkime/Malcolm geo tagging | Requires a free MaxMind account + license key on staging; download, transfer, configure Malcolm to use local copies. Refresh each cycle |
| IEEE OUI list (`oui.txt`), public suffix list, IANA ipv4-address-space | Arkime | Fetch on staging; Malcolm/Arkime accept local files |
| ET Open Suricata ruleset | Suricata (disabled by default, cache anyway) | `emerging.rules.tar.gz` per cycle; load via suricata-update offline source |
| Zeek packages (if any beyond Malcolm's bundle) | Zeek | Vendor into the config repo |

Without a refresh cadence these silently go stale — geo lookups and rules are only as current as the last bundle.

### 1.7 Dell / firmware (manual downloads from dell.com — cannot be scripted reliably)

perccli/perccli2 for the PERC, BIOS + iDRAC firmware packages, Broadcom NIC firmware DUPs, optionally Dell System Update (DSU) offline repo for the R770. Store in `bundle/dell/` with the Dell-published checksums. Firmware is applied via iDRAC OOB — one of the few things that doesn't even need the host.

### 1.8 Trust anchors, keys, docs

Ubuntu archive GPG keys, Docker repo key, Malcolm release signatures/checksums, your internal CA material (generated offline with easy-rsa — never transferred in), offline copies of documentation you'll want at 2 a.m.: Malcolm/Arkime/Zeek/GNS3 docs (each repo's `docs/` tree or a `wget --mirror` of the doc sites), man-page packages. Cache `mkdocs-material` wheels so the internal docs site builds offline.

---

## 2. What changes on the R770 for air-gap

1. **APT sources replaced** — `/etc/apt/sources.list.d/` points only at the local repo (`deb [signed-by=...] http://portal.lab/apt noble main` or a `file:/srv/repo` line). Upstream lists removed, `unattended-upgrades` disabled or pointed at the local repo (updates then arrive by bundle, deliberately).
2. **Remove/neutralize phone-home components** — `snapd` removed (nothing in this build needs it), MOTD news off, Ubuntu Pro/ESM apt hooks disabled, Grafana analytics/update-check off, OpenSearch/Dashboards telemetry off, Docker configured with no registry mirrors (or only the local `registry:2`).
3. **Time** — chrony becomes the lab's stratum source: prefer a GPS/PPS or radio reference if available; otherwise free-running local clock with `local stratum 10`, and all VMs/containers/appliances sync to the host. Arkime/Zeek correlation depends on this — document the drift expectation.
4. **DNS** — dnsmasq is authoritative for `.lab` with **no upstream forwarders** (`no-resolv`), returning NXDOMAIN for the internet instead of timing out — many tools behave much better with fast NXDOMAIN than with hangs.
5. **TLS** — internal CA (easy-rsa, generated on the gapped box or a gapped admin machine), portal/malcolm/gns3 certs issued from it, CA cert distributed to analyst browsers. No ACME/Let's Encrypt.
6. **The firewall stance gets simpler** — no egress to worry about; UFW default-deny both directions on the mgmt zone except the documented service ports.

---

## 3. Transfer & verification procedure (every cycle)

1. On staging: run `r770-offline-fetch.sh` → `bundle-YYYYMMDD/` with `MANIFEST.sha256` covering every file.
2. Verify upstream signatures **on staging** (Ubuntu ISO GPG, Malcolm `.sha`, Docker repo signatures) — the gapped side can only verify what the manifest asserts, so trust is established here. Record versions in `BUNDLE_NOTES.md`.
3. Copy to approved media; on the R770 run `./r770-bundle.sh verify .` before anything is installed (the verifier ships inside the bundle root); then AV/content scan per site policy.
4. Import: sync debs into the local repo + `apt update`; `docker load` image tars; copy wheelhouse/images/enrichment data into place; keep the previous bundle until the new one is validated (instant rollback).
5. Log the cycle in the config repo (`inventory/bundles.md`): date, versions, hashes, who carried it.

**Cadence:** quarterly is a sensible floor; monthly if Suricata/GeoIP freshness matters to your analysis. Security updates for the host ride the same schedule — that's the real cost of the air gap, and it should be written down as an accepted risk.

---

## 4. Bundle sizing summary

| Category | Size |
|---|---|
| Ubuntu ISO + curated APT bundle + Docker debs | ~6–9 GB |
| Malcolm images + install pkg (+ optional ISO copy) | ~25–35 GB |
| Monitoring/portal images | ~3 GB |
| GNS3 wheelhouse + cloud/test images | ~2 GB |
| Enrichment/rules/GeoIP | ~1 GB |
| Dell firmware/tools | ~2–5 GB |
| Docs mirrors | ~1–2 GB |
| **Total (before your licensed appliance images)** | **~40–55 GB** |
| GNS3 vendor appliances | often 10–100+ GB — plan the media around this |

A 256 GB+ USB-NVMe drive holds current + previous bundle comfortably.

---

## 5. Open items for you

1. Get a MaxMind account/license key (free tier) for GeoLite2, or decide to run without geo enrichment. *(Decision 2026-08-31: descoped — see dependency manifest.)*
2. Inventory which GNS3 vendor appliances (and licenses) you need staged.
3. Decide curated bundle vs. full partial mirror (§1.1) — the fetch script implements the curated path. *(Decision: curated.)*
4. Confirm site policy for transfer media scanning/signing so step 3 of the procedure matches it.
5. Decide whether a GPS/PPS time source is available; otherwise accept documented free-running drift.

Sources: [Malcolm releases](https://github.com/idaholab/Malcolm/releases) · [Malcolm v26.08.0](https://github.com/idaholab/Malcolm/releases/tag/v26.08.0) · [Malcolm ISO docs](https://malcolm.fyi/docs/malcolm-iso.html) · [Malcolm quick start](https://malcolm.fyi/docs/quickstart.html)
