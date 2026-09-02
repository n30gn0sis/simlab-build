# R770 Lab — Offline Dependency Manifest

**Version:** 1.0 (2026-08-31)
**Companion to:** `r770-offline-supply.md` (supply plan), `r770-offline-fetch.sh` (v3.3 fetch script — resumable; new bundles seed from previous ones), `r770-staging-runbook.md`, `r770-network-lab-buildout.md`

This is the definitive list of everything the air-gapped R770 build needs, what version it is pinned to, where it comes from, whether the fetch script gets it automatically or a human must, and where it lands in the bundle.

---

## 0. Decisions record (2026-08-31)

| Decision | Choice |
|---|---|
| Scope | Everything in the supply plan: OS/APT, Docker, Malcolm, monitoring stack, GNS3, VM images, enrichment/rules, Dell firmware checklist, docs mirrors |
| APT strategy | Curated bundle (exact package set + deps resolved in clean `ubuntu:24.04` container) — not a partial mirror |
| Staging host | RHEL 8 with **Docker Engine** (script also supports rootful podman, unused) |
| Transfer media | 256 GB+ USB/NVMe, **ext4** |
| GeoIP enrichment | **Descoped** — no MaxMind account; Malcolm runs without geo tagging. Reversible: v2 of the fetch script has the working GeoLite2 block if this changes |
| GNS3 images | Free/open-source set scripted; Cisco + commercial firewall images manual (checklist below) |
| Refresh cadence | Ad-hoc / one-time initial build; no fixed schedule. Accepted risk: host security updates, ET rules only refresh when a new bundle is cut |
| Drive helper script | None — manual rsync + `sha256sum -c MANIFEST.sha256` on the drive |

---

## 1. Ubuntu OS + APT packages — scripted §1

| Item | Pin | Source | Bundle path | Size |
|---|---|---|---|---|
| Ubuntu Server live ISO + SHA256SUMS(.gpg) | 24.04.4 | releases.ubuntu.com/noble | `isos/` | ~3.2 GB |
| Curated .deb set + all deps + `dist-upgrade` security debs | resolved at build time | archive/security.ubuntu.com | `apt/` (with `Packages.gz` repo metadata) | ~3–6 GB |
| Docker Engine debs (docker-ce, cli, containerd.io, buildx, compose) + repo GPG key | noble/stable current | download.docker.com | `apt/` | ~400 MB |

Curated package list (script is authoritative):

- **Virtualization:** qemu-kvm, qemu-system-x86, qemu-utils, libvirt-daemon-system, libvirt-clients, virtinst, ovmf, bridge-utils, cpu-checker, guestfs-tools
- **Switching (deferred but cached):** openvswitch-switch
- **Host services:** nginx, dnsmasq, chrony, auditd, ufw, lvm2, xfsprogs, easy-rsa, restic, prometheus-node-exporter
- **Storage/HW:** smartmontools, nvme-cli, ipmitool, edac-utils, lm-sensors
- **Network/capture/perf:** ethtool, numactl, sysstat, tcpdump, tshark, tcpreplay, iperf3, fio, stress-ng, mtr-tiny, traceroute, dnsutils, net-tools, nmap
- **Admin:** git, jq, tmux, htop, iotop, curl, wget, vim, lsof, strace, unzip, zip, python3-venv, python3-pip, dpkg-dev, rsync
- **Kernel tracking:** linux-generic-hwe-24.04

> Curated-bundle limitation (accepted): an unplanned `apt install foo` on the gapped box fails until a package is added here and a new bundle is cut.

## 2. Malcolm — scripted §3

| Item | Pin | Source | Bundle path | Size |
|---|---|---|---|---|
| `malcolm-26.07.1-docker_install.zip` | 26.07.1 (current as of 2026-08-31) | github.com/idaholab/Malcolm releases | `malcolm/` | ~0.5 MB |
| All container images from the release compose file | tags as referenced by v26.07.1 compose | ghcr.io/idaholab/malcolm/* | `malcolm/malcolm-images-26.07.1.tar.gz` | ~20–30 GB |
| Release compose file + image list | v26.07.1 | raw.githubusercontent.com | `malcolm/` | — |

Restore: `docker load -i malcolm-images-26.07.1.tar.gz`, then run Malcolm's install/configure scripts (find images locally, never pull). The full Malcolm ISO is **not** bundled (Ubuntu stays the host OS); grab a copy manually only if you want the recovery/reference option.

## 3. Monitoring / portal container images — scripted §4

| Image | Pin |
|---|---|
| prom/prometheus | v3.14.0 |
| prom/alertmanager | v0.33.0 |
| prom/blackbox-exporter | v0.28.0 |
| grafana/grafana-oss | 12.1.0 (13.x is current; held — review dashboards before jumping majors) |
| gcr.io/cadvisor/cadvisor | v0.57.0 |
| nginx | stable |
| registry | 2 |
| squidfunk/mkdocs-material | latest (pin once standardized) |

Bundle path `docker/monitoring-images.tar.gz`, ~3 GB.

## 4. GNS3 — scripted §5 + §6, licensed parts manual

### 4.1 Server (scripted)

| Item | Pin | Method | Bundle path |
|---|---|---|---|
| gns3-server + deps wheelhouse | 3.0.6 | `pip download` in `python:3.12-slim` container | `gns3/wheelhouse/` (~100 MB) |

Offline install: `python3 -m venv /opt/gns3 && /opt/gns3/bin/pip install --no-index --find-links <wheelhouse> gns3-server`. GNS3 v3 bundles the web UI and enforces auth (admin user created on first run); images live as files under `images_path`, so pre-staging appliances on disk works.

### 4.2 Appliance definitions (`.gns3a`) — scripted

Fetched from the GNS3 registry (raw.githubusercontent.com/GNS3/gns3-registry) into `gns3/definitions/`: definitions for both the free images below **and** the licensed ones (definitions are free even when images are not) — vyos, mikrotik-chr, opnsense, frr, alpine-linux, tinycore-linux, openwrt, cisco-iosv, cisco-iosvl2, cisco-asav, fortigate, pan-vm-fw (all 12 names verified against the registry 2026-08-31; fetch is tolerant — a renamed one warns, not fails).

### 4.3 Free/open-source images — scripted

| Image | Pin | Source | Size |
|---|---|---|---|
| VyOS rolling ISO (+ .minisig) | latest nightly at build time (e.g. 2026.08.28-0255-rolling) | github.com/vyos/vyos-nightly-build releases (via GitHub API) | ~600 MB |
| MikroTik CHR raw image | 7.21.5 | download.mikrotik.com/routeros/7.21.5/chr-7.21.5.img.zip | ~50 MB |
| OPNsense dvd ISO (+ sha256 + sig) | 26.7 | mirrors.dotsrc.org/opnsense/releases/mirror | ~2.2 GB |
| Alpine virt ISO | latest-stable at build time (parsed from `latest-releases.yaml`) | dl-cdn.alpinelinux.org | ~60 MB |
| GNS3 docker-node images (alpine, debian:stable-slim, nicolaka/netshoot, quay.io/frrouting/frr:10.6.1) | as listed | Docker Hub / quay.io | ~1.5 GB saved |

### 4.4 Licensed / account-gated images — **MANUAL** (`gns3/appliances/README.txt` in bundle)

| Image | Where | Notes |
|---|---|---|
| Cisco IOSv, IOSvL2, IOL | CCO / CML (VIRL) entitlement | qcow2/bin per your license |
| Cisco CSR1000v / Cat8000v, ASAv | CCO downloads | |
| Fortinet FortiGate-VM | support.fortinet.com account | KVM qcow2, eval license |
| Palo Alto VM-Series | support.paloaltonetworks.com account | KVM qcow2, auth codes |
| pfSense CE | pfsense.org — **now requires free Netgate account** | OPNsense is the scripted no-account alternative |

Stage into `gns3/appliances/`. **This is usually the largest and most schedule-critical manual category — often 10–100+ GB.** Inventorying exactly which of these you hold licenses for is still an open item.

## 5. VM base images — scripted §5

| Item | Pin | Source | Bundle path |
|---|---|---|---|
| Ubuntu noble cloud image | current at build | cloud-images.ubuntu.com | `images/` (~600 MB) |
| CirrOS (validation-suite test VM) | 0.6.3 | download.cirros-cloud.net | `images/` (~20 MB) |

Windows endpoint ISOs + virtio-win: **descoped** (not selected).

## 6. Enrichment & rules — scripted §7 (GeoIP descoped)

| Item | Used by | Handling |
|---|---|---|
| IEEE OUI list (`oui.txt`) | Arkime | scripted |
| Public suffix list | Arkime | scripted |
| IANA ipv4-address-space | Arkime | scripted |
| ET Open Suricata ruleset (`suricata-7.0` branch) | Suricata (disabled by default; cached anyway) | scripted, liveness-checked (ET returns 410 on retired branches) |
| MaxMind GeoLite2 City/ASN/Country | Malcolm/Arkime geo tagging | **DESCOPED** — no account. Geo fields will be absent in Arkime/dashboards. v2 script block is the recovery path |

Staleness note: with ad-hoc cadence, rules/OUI are only as fresh as the last bundle — accepted.

## 7. Dell firmware & tools — **MANUAL** (`dell/README.txt` in bundle)

From dell.com/support by service tag, with Dell's published checksums: perccli/perccli2 (PERC H975i), BIOS DUP, iDRAC firmware, Broadcom NIC firmware DUPs, optionally DSU offline repo. ~2–5 GB. Applied via iDRAC OOB (Phase 2 of the buildout).

## 8. Docs mirrors — scripted §8 (best-effort)

wget mirrors into `docs/` for 2 a.m. troubleshooting: malcolm.fyi docs, docs.zeek.org, arkime.com docs, docs.gns3.com (JS-heavy; repo docs tree fetched as fallback), Wireshark user guide. Each is `|| warn` — a failed mirror never fails the bundle. ~1–2 GB. mkdocs-material image (§3) lets the internal docs site build offline.

## 9. Trust anchors & keys

Ubuntu SHA256SUMS + GPG sig (scripted, verified on staging), Docker repo key (scripted, into `apt/`), Malcolm release checksums (scripted), VyOS minisig (scripted), OPNsense sha256 + sig (scripted). Internal CA material is generated **on the gapped side** with easy-rsa — never transferred in.

---

## 10. Drive budget (256 GB ext4)

| Category | Est. |
|---|---|
| Ubuntu ISO + APT + Docker debs | 7–10 GB |
| Malcolm images + install pkg | 25–35 GB |
| Monitoring/portal images | 3 GB |
| GNS3 wheelhouse + free appliances + docker nodes | 5–7 GB |
| VM base images | 1 GB |
| Enrichment/rules | <0.5 GB |
| Docs mirrors | 1–2 GB |
| Dell (manual) | 2–5 GB |
| **Scripted+Dell subtotal** | **~45–65 GB** |
| Licensed GNS3 appliances (manual) | 10–100+ GB |

Current + previous bundle fit comfortably unless the licensed-appliance set is very large; ext4 preserves permissions and >4 GB files.

## 11. Outstanding manual checklist (before the transfer)

1. Dell downloads by service tag → `dell/` (§7).
2. Inventory + download licensed GNS3 images per your entitlements → `gns3/appliances/` (§4.4).
3. Verify Ubuntu ISO GPG signature and Malcolm `.sha` files on staging per site policy (script verifies SHA256; GPG per policy).
4. Site AV/content scan of the drive per policy, then `sha256sum -c MANIFEST.sha256` on the R770 before anything is installed.
