# Bundle cycle log

One entry per supply-bundle cycle. Evidence, not intent — record what the
commands actually printed. Referenced by `state/BUILD-STATE.md`, the supply
plan §3.5, the staging runbook Step 6.5, and `/bundle` / `/import-bundle`.

Cadence is **ad-hoc** (dependency manifest §0). The accepted risk: host security
updates, ET rules and OUI data are only as fresh as the last bundle.

## Cycles

| Date | Bundle | Size | Key versions | `verify` result | WARN dispositions | Courier | Imported on R770 |
|---|---|---|---|---|---|---|---|
| *in progress* | bundle-1 | — | Malcolm 26.08.0 · Ubuntu 24.04.4 · gns3-server 3.0.6 | not yet cut | — | — | no |

## Per-cycle checklist

- [ ] Pins reviewed — any `MOVED` row bumped with the operator's OK (recorded in dependency manifest §0) or explicitly deferred
- [ ] Staging host is a **VM, not LXC** (`systemd-detect-virt` ≠ `lxc`), ≥150 GB free, `docker info` works
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
