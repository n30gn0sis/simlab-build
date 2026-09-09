# Bundle cycle log

One entry per supply-bundle cycle. Evidence, not intent — record what the
commands actually printed. Referenced by `state/BUILD-STATE.md`, the supply
plan §3.5, the staging runbook Step 6.5, and `/bundle` / `/import-bundle`.

Cadence is **ad-hoc** (dependency manifest §0). The accepted risk: host security
updates, ET rules and OUI data are only as fresh as the last bundle.

## Cycles

| Date | Bundle | Size | Key versions | `verify` result | WARN dispositions | Courier | Imported on R770 |
|---|---|---|---|---|---|---|---|
| 2026-09-08 | `bundle-20260908` | **15 GB**, 1617 files | Malcolm 26.08.0 · Ubuntu 24.04.4 · gns3-server 3.0.6 · FRR 10.7.1 · alertmanager v0.34.0 · cadvisor v0.60.5 (ghcr.io) | **PASS WITH WARNINGS (exit 2)** | 2 docs-mirror WARNs, accepted — see below | not yet transferred | no |

### bundle-20260908 — build result

Built on VM 9770, three attempts (two failures, zero re-downloads — the script's resumability held).

| Component | Size |
|---|---|
| `malcolm/` | 6.8 G (23 images, tarball + compose + install zip) |
| `isos/` | 3.2 G (Ubuntu 24.04.4 + SHA256SUMS + .gpg) |
| `gns3/` | 1.6 G (wheelhouse, 12 `.gns3a` definitions, 8 free appliance files) |
| `apt/` | 1.5 G (877 debs + `Packages.gz` + Docker repo key) |
| `images/` | 617 M (noble cloud image, CirrOS) |
| `docker/` | 510 M (8 monitoring/portal images) |
| `docs/` | 53 M · `enrichment/` 12 M · `dell/` README only |
| **Total** | **15 G** |

**Verification (2026-09-08):**
- `r770-bundle.sh verify` → **PASS WITH WARNINGS, exit 2**. Manifest parses (1617 entries), every
  manifested file present and unmodified, no unmanifested files, no `.part` leftovers.
- Ubuntu ISO: **Good signature** from `Ubuntu CD Image Automatic Signing Key (2012) <cdimage@ubuntu.com>`,
  fingerprint `8439 38DF 228D 22F7 B374 2BC0 D94A A3F0 EFE2 1092`; `ubuntu-24.04.4-live-server-amd64.iso: OK`.

**WARN dispositions — both ACCEPTED:**

| WARN | Disposition |
|---|---|
| `docs mirror for malcolm incomplete/failed` | **Accepted.** Docs mirrors are best-effort by design (dependency manifest §8: "each is `\|\| warn` — a failed mirror never fails the bundle"). 53 M of docs did land (Wireshark guide, gns3-server source tree). Retryable: a rerun resumes them. |
| `docs mirror for zeek incomplete/failed` | **Accepted**, same reasoning. |

Neither touches software, images, or enrichment data — only offline reading material.

**Remediated 2026-09-09** after review on PR #1: `r770-bundle.sh` is now copied into the
bundle root and covered by its own manifest (1616 → 1617 files), so the documented
`./r770-bundle.sh verify .` actually runs on the R770. It did not before — the bundle carried no
verifier. Future bundles get it automatically; the fetch script now does the copy.

**Still blocking transfer** (both are `verify` warnings by design, not defects):
`dell/` holds only README.txt, and the licensed GNS3 appliance set is not inventoried.

**Two failures on the way, both recorded for the next cycle:**
1. `[4/10]` — `gcr.io/cadvisor/cadvisor:v0.60.5` not found. That registry is abandoned at v0.55.1;
   the *previous* pin 404s there too, so this was broken before the bump. Fixed to
   `ghcr.io/google/cadvisor`. Root cause was method: a GitHub release existing is not an image
   existing. See `pin-review-2026-09-04.md`.
2. `[6/10]` — exit 23 after the `.gns3a` definitions. **Transient and not reproducible**: an xtrace
   rerun went straight through the same code, resolved VyOS `2026.09.01-0034-rolling`, and
   downloaded it. Deliberately not "fixed". If it recurs, the VyOS block is where to look — its
   `\|\| note "WARN: …"` fallback should have downgraded a download failure to a warning, and did not.

**Staging host is built and ready:** VM 9770 `r770-staging` at **192.168.4.28** (Ubuntu 24.04.4, Docker CE 29.8.0, 400 GiB, 376 G free, snapshot `pre-fetch` taken). Build record and fetch-day watch list: `staging-vm-9770.md`.

## Per-cycle checklist

- [x] Pins reviewed 2026-09-04 — 4 bumped with operator approval, grafana held (`pin-review-2026-09-04.md`)
- [x] Staging host is a **VM, not LXC** — VM 9770, `systemd-detect-virt`=`kvm`, 376 G free, `docker info` OK (2026-09-04)
- [ ] Bundle built: `sudo -E ./scripts/r770-offline-fetch.sh`
- [ ] Manual categories staged: Dell (`dell/`) and licensed GNS3 appliances (`gns3/appliances/`)
- [ ] Manifest regenerated **after** the manual additions: `./scripts/r770-bundle.sh manifest bundle-YYYYMMDD`
- [ ] Gate passed on staging: `./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict`
- [ ] Ubuntu ISO GPG signature verified on staging (runbook Step 5)
- [ ] Gate passed again **from the transfer media**, before it leaves staging
- [ ] Site AV/content scan per policy
- [ ] Gate passed on the R770 before any import: `./r770-bundle.sh verify .`
- [ ] Previous bundle retained until this one validates
- [ ] Row above completed with real numbers

---

# bundle-1 — preparation (2026-09-04)

## Pin decisions

Reviewed 2026-09-04; four bumped with operator approval. Full evidence:
`pin-review-2026-09-04.md`. Malcolm **26.08.0**, alertmanager **v0.34.0**,
cadvisor **v0.60.5**, FRR **10.7.1**; grafana-oss held at 12.1.0.

## Manual category A — Dell, for service tag `G8WFGH4`

From dell.com/support by service tag. Keep Dell's published checksum beside each
file, and put everything in `bundle-YYYYMMDD/dell/`.

**Only download a DUP that is newer than what is installed.** Installed
baselines from Phase 1 discovery (`r770-idrac-inventory-G8WFGH4.md`):

| Component | Installed now | Needed? |
|---|---|---|
| BIOS | **1.7.5** (2026-01-16) | only if Dell lists newer |
| iDRAC / Lifecycle Controller | **1.30.20.10** | only if newer |
| PERC H975i Front | **8.14.0.0.28-40** | only if newer |
| Backplane | **1.92** | only if newer |
| Broadcom NIC (both BCM57412 OCP quads + BCM57414) | family **233.1.181.0**, pkg 233.0.195.0 | only if newer |
| PSU (LiteOn 1100 W ×2) | **1408** | only if newer |
| CPLD / FPGA | **109.125.104** | only if newer |

**Required regardless of version — this one is not optional:**

- [ ] **`perccli2`** — the management CLI for the PERC. Note it is **perccli2**, not perccli: the H975i is an **NVMe** RAID controller. Three Phase 2 questions are blocked on it:
  1. **PERC encryption key custody** — the controller reports `Security Key Assigned` with encryption enabled, and nobody has established LKM vs SEKM or where the key is escrowed. Losing it loses the virtual disk and every byte of evidence on it.
  2. **TRIM passthrough** on the VD — determines whether `fstrim.timer` is meaningful or theatre.
  3. **NVMe link width** — both drives negotiated x2 of a x4-capable link, halving per-drive bandwidth. Backplane bifurcation by design, or a fault?
- [ ] Optionally: Dell System Update (DSU) offline repository for the R770

> **Out-of-band note:** IPMI-over-LAN is **disabled** on this chassis (SOL is enabled). Firmware is applied via iDRAC, but any *scripted* OOB work must use **Redfish** — `ipmitool -H` will not connect.

## Manual category B — licensed GNS3 appliances

**This is the schedule-critical item and the only unbounded one: it sizes the
transfer media.** Fill in what you actually hold entitlements for, then confirm
the total fits alongside the ~45–65 GB of scripted content on a 256 GB drive.

| Appliance | Entitled? | Source | Approx size | Staged? |
|---|---|---|---|---|
| Cisco IOSv | ? | CCO / CML (VIRL) | ~1 GB | ☐ |
| Cisco IOSvL2 | ? | CCO / CML | ~1 GB | ☐ |
| Cisco IOL | ? | CCO / CML | ~100 MB | ☐ |
| Cisco CSR1000v / Cat8000v | ? | CCO | ~1.5 GB | ☐ |
| Cisco ASAv | ? | CCO | ~1 GB | ☐ |
| Fortinet FortiGate-VM | ? | support.fortinet.com | ~100 MB | ☐ |
| Palo Alto VM-Series | ? | support.paloaltonetworks.com | ~2 GB | ☐ |
| pfSense CE | ? | Netgate account required | ~700 MB | ☐ |
| **Total** | | | **?** | |

Already scripted, so **do not** download by hand: VyOS rolling, MikroTik CHR
7.21.5, OPNsense 26.7, Alpine virt, the GNS3 docker-node images, and **all 12
`.gns3a` definitions** — including the definitions for the licensed appliances
above, which are free even when the images are not.

## Still to confirm before the media moves

- [ ] **Site AV/content scan policy** (runbook Step 0D) — the transfer procedure has to match it, and it is still unconfirmed
