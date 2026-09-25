# Phase 2 / Phase 3 — PERC assessment and storage layout

**Date:** 2026-09-23 · **Status:** design approved by operator, not yet implemented
**Phases:** 2 (BIOS/firmware/iDRAC assessment; RAID VD verification) and 3 (storage LVM/filesystem layout) of `PRD.md` §9
**Supersedes:** the "needs perccli in Phase 2" wording in `docs/plans/r770-network-lab-buildout.md` §2/§3.2/§12 and `state/BUILD-STATE.md`

## Amendment 2026-09-24 — no iDRAC or PERC work (operator)

Supersedes decisions 3–4 and Phase 2 items 1, 4 and 5 below. Nothing on the R770 touches iDRAC or the PERC: no firmware, controller settings, virtual-media changes or out-of-band actions, and nothing queries either.

- **Item 1 (key custody): dropped.** Accepted risk; no phase is gated on it (Phase 10's gate removed).
- **Item 2 (NVMe x2): answered — BY DESIGN** from Dell's PERC13/PERC12 User's Guide ("at maximum x2 lane width"). No R770 action.
- **Item 3 (TRIM): unchanged** — OS-side read only (`lsblk -D`, sysfs), no controller access.
- **Item 4 (firmware delta): dropped.** Research kept for reference only; no updates are planned.
- **Item 5 (virtual-media noise): documented only.** No detach action.
- **Phase 5:** the iDRAC recovery-path gate is dropped (CLAUDE.md rule 2 amended); `netplan try` + saved rollback are the only protection.

Phase 2 VERIFIED therefore needs verdicts for items 2 and 3 only.

## Decisions (operator, 2026-09-23)

1. **Phase 2 is assess-only.** It produces a report; nothing on the R770 changes. Any firmware update or PERC setting change is a separate, later gated decision.
2. **perccli2 is removed** from the Phase 2 plan *and* from the supply lists (fetch-script reminder, bundle checklist, runbooks, dependency manifest). The precheck's optional `perccli2/perccli/storcli` probe stays.
3. **No iDRAC/Redfish queries.** Phase 2 works from evidence already captured (the 2026-09-03 iDRAC export), operator attestation, Dell documentation, and read-only OS checks over SSH. Consequence: Phase 5's iDRAC-reachability gate is untouched and stays open.
4. **Key custody gates Phase 10, not Phase 3.** Phase 3 creates empty LVs; the first case data lands in Phase 10.
5. **Phase 3 is applied by a tested script** (`scripts/r770-storage-apply.sh`), not hand-pasted commands or a generic declarative applier.

## Phase 2 — assessment

**Output:** `state/inventory/r770-phase2-assessment.md` — one verdict per item, each with its evidence.

| # | Item | Source | Runs where | Verdicts |
|---|---|---|---|---|
| 1 | PERC key custody | **Operator attestation**: LKM or SEKM, who holds the passphrase, where it is escrowed (a location, never the key). Supporting evidence: export shows `Security Key Assigned` / `Encryption mode: Enabled` | Operator answers; agent records | `RECORDED` · `UNKNOWN` |
| 2 | NVMe link x2 of x4 | Dell R770 documentation for the 16-bay E3.S backplane and PERC H975i Front, compared with the export's `x2 / x4` | Staging side (research) | `BY DESIGN` (cited source) · `SUSPECT` (becomes a later gated action: reseat or Dell ticket) · `UNRESOLVED` |
| 3 | TRIM / discard | `lsblk -D /dev/sda`; `/sys/block/sda/queue/discard_granularity`, `discard_max_bytes` | R770 over SSH, read-only | `ADVERTISED` (Phase 3 enables `fstrim.timer`) · `NOT ADVERTISED` (timer stays off) |
| 4 | Firmware delta | Installed versions from the 2026-09-03 export (BIOS 1.7.5, iDRAC 1.30.20.10, PERC 8.14.0.0.28-40, backplane 1.92, Broadcom NIC 233.1.181.0, PSU 1408) vs Dell's current releases for service tag `G8WFGH4` | Staging side (research) | Table of installed / latest / release-note criticality. Advisory only |
| 5 | iDRAC virtual-media noise (`sdb`/`sr0` errors) | `journalctl -k` / `dmesg` error counts, `lsblk` | R770 over SSH, read-only | Documented; detaching is a manual operator action in the iDRAC UI |

`/dev/sda` in items 3 and 5 is the device discovery confirmed as the RAID VD (`state/inventory/r770-discovery-findings.md`); re-confirm with `lsblk` in the same session before reading its queue attributes.

**Status rule:**
- **APPLIED** when the report exists with evidence for every item it has a verdict for.
- **VERIFIED** when items 2–5 each carry a verdict. Item 1 may still be `UNKNOWN`.
- Item 1 `UNKNOWN` is recorded as an open blocker in BUILD-STATE's unknowns table, and Phase 10's *Depends on* becomes `6,9,3 + key custody RECORDED`.

## perccli2 removal (same change as Phase 2 docs)

| File | Change |
|---|---|
| `scripts/r770-offline-fetch.sh` | Drop perccli2 from the header comment (l.36) and the Dell manual-download reminder (≈l.782) |
| `scripts/r770-build-bundle.sh` | Drop perccli2 from the `dell/` layout comment (l.154) |
| `scripts/r770-precheck.sh` | Keep the probe; reword the missing-tool `warn` so it no longer says "Install Dell's perccli in Phase 2" (Phase 2 no longer needs it) |
| `state/inventory/bundles.md` | Remove the perccli2 checklist item |
| `docs/plans/r770-staging-runbook.md`, `r770-install-runbook.md`, `r770-offline-supply.md`, `r770-dependency-manifest.md` §7, `docs/CODEMAPS/dependencies.md` | Remove perccli/perccli2 from the Dell download lists and install steps |
| `docs/plans/r770-network-lab-buildout.md` §2, §3.2, §12 | "TRIM needs perccli" → "OS-side discard check in Phase 2" |
| `state/BUILD-STATE.md` | Unknowns row for PERC/TRIM re-worded; add key-custody → Phase 10 gate |

Dated evidence records (`r770-precheck-report-2026-09-02.md`, `r770-discovery-findings.md`) are left as written — they are history, not plan.

## Phase 3 — `scripts/r770-storage-apply.sh`

### Layout (data table at the top of the script, mirrors buildout §3.2 — drift-tested)

| LV | Size | FS | Mount |
|---|---|---|---|
| `lv_docker` | 250G | ext4 | `/var/lib/docker` |
| `lv_pcap` | 3.25T | xfs | `/data/pcap` |
| `lv_index` | 1T | xfs | `/data/index` |
| `lv_staging` | 250G | xfs | `/data/staging` |
| `lv_vms` | 500G | xfs | `/srv/vms` |
| `lv_gns3` | 400G | xfs | `/srv/gns3` |
| `lv_work` | 200G | xfs | `/srv/work` |
| `lv_backup` | 250G | xfs | `/srv/backup` |
| `lv-var` (existing) | grow 6G → 50G | ext4 | `/var` |

VG: `ubuntu-vg0` (discovered). The script never names a block device; it acts only on LVs within that VG. `FSTAB` (default `/etc/fstab`) is overridable for tests.

### Modes

- **`--plan`** (default, read-only): reads `vgs`, `lvs`, `findmnt`, and the fstab. For each row prints current state, proposed action, and the exact commands; ends with VG free vs required.
- **`--apply --lv NAME`**: exactly one LV per invocation:
  1. `lvcreate -n NAME -L SIZE ubuntu-vg0`
  2. `mkfs.<fs>` on `/dev/ubuntu-vg0/NAME`
  3. `mkdir -p` the mount point
  4. `chattr +i` the mount point
  5. back up fstab to `$FSTAB.pre-NAME-<timestamp>`
  6. append `UUID=<uuid> <mount> <fs> noatime,nofail 0 2`
  7. `findmnt --verify`, then `mount <mount>`, then print the mounted source/fs/size as evidence
  If step 7 fails: `chattr -i` the mount point, restore the fstab backup, exit non-zero, leave the (empty) LV in place and print the `lvremove` command for the operator.
- **`--grow-var`**: `lvextend -r -L 50G ubuntu-vg0/lv-var` (online ext4 grow). The existing fstab line is not touched.

### Refusals (exit non-zero, nothing changed)

- Not root, or VG `ubuntu-vg0` absent.
- LV exists with a different size or filesystem. (Exists and matches → skip with `already applied`, exit 0.)
- Mount point exists and is non-empty, or is already a mount.
- fstab already has an entry for that mount point.
- VG free < required, or applying would leave the VG with < 5 % free (this floor is a hard floor; buildout's ~10 % reserve target is separate and is what the layout is sized against).
- `--grow-var` when `lv-var` is already ≥ 50G → skip with `already applied`.

### Mount policy

- `noatime` on every new LV. `nofail` on every new data LV so a bad data mount cannot stop boot (and SSH). `lv-var` keeps its existing entry — no `nofail`.
- Mount points are made immutable (`chattr +i`) before mounting, so a data LV that fails to mount at boot (nofail) leaves an immutable, empty directory on `/` or `/var` instead of a writable one that services can silently fill. Consuming units — Docker's data-root in Phase 6, Malcolm's data paths in Phase 10 — must also get `RequiresMountsFor=` so they fail to start rather than write into that directory; this is a gate for those phases.
- `fstrim.timer` enabled only if Phase 2 item 3 is `ADVERTISED`; otherwise left disabled and noted in the evidence file.
- Swapfile/swappiness stays in **Phase 4** (it is a sysctl; "measure before tuning").

### Execution order

1. Run `--plan` on the R770; save output.
2. `safety-reviewer` reviews the plan output.
3. Operator confirms (CLAUDE.md rule 3: what changes, data at risk, device, current vs proposed, rollback).
4. `--grow-var`.
5. `--apply --lv` for each LV, `lv_pcap` last.
6. `fstrim.timer` per Phase 2 verdict.
7. `--plan` again (every row `already applied`); `validation-runner` pass.
8. Reboot test at an operator-chosen time; confirm every mount returns.

**Evidence:** plan-before, each apply transcript, plan-after, validation output → `state/inventory/r770-phase3-storage-<date>.md`.

### Rollback

- **Per new LV:** `umount <mount>` → `chattr -i <mount>` → restore `$FSTAB.pre-NAME-*` → `lvremove ubuntu-vg0/NAME`. LVs are empty in Phase 3; no data at risk.
- **`lv-var` grow is not reversible online** (ext4 cannot shrink mounted; shrinking needs rescue media). It is the one irreversible step; cost is 44 GiB of VG reserve. Called out explicitly in the operator confirmation.

### Tests — `tests/storage-apply.bats`

PATH-shimmed `vgs`, `lvs`, `lvcreate`, `lvextend`, `mkfs.ext4`, `mkfs.xfs`, `blkid`, `mount`, `findmnt`; `FSTAB` pointed at a temp file. Cases:

- `--plan` makes no calls to mutating shims and leaves fstab byte-identical.
- Each refusal above produces non-zero exit and no mutation.
- `--apply --lv` touches exactly one LV; appends exactly one fstab line with `UUID=` and `noatime,nofail`.
- `findmnt --verify` failure restores the fstab backup.
- Re-run after success skips with `already applied`.
- `--grow-var` skip when already ≥ 50G.
- `tests/lint.bats` stays green; `./tests/run.sh` green before either phase advances.
