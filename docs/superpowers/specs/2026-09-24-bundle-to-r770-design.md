# Sub-project 0 — Bundle to the R770 (with storage first)

**Date:** 2026-09-24 · **Status:** design approved by operator, not yet executed
**Part of:** "deploy and configure the analyst stack" (operator refocus, 2026-09-24)

## The larger goal and where this fits

The operator wants the analyst stack deployed on the R770: Malcolm, the TLS portal and docs,
GNS3, and networking (lab bridges/NAT, capture ports, `.lab` DNS/time). It is split into
sub-projects. Each gets its own design, plan and execution:

| # | Sub-project | Phases | Done when |
|---|---|---|---|
| **0** | **Bundle to the R770 — this spec** | 2, 3, bundle import | LVs mounted and surviving a reboot; verified bundle on `/data/staging`; `apt` resolves only from it |
| 1 | Docker from the bundle; load images | 6 | Docker on `lv_docker`; image tags verified |
| 2 | Malcolm + internal CA + portal/`docs.lab` (+ the UFW rules the portal needs) | 10, 13 | Analysts log in; an uploaded PCAP is indexed |
| 3 | Capture ports → Malcolm live capture | 9 | Live traffic in Arkime, drops counted |
| 4 | Lab bridges/NAT, GNS3 behind `gns3.lab`, virtual mirror feed | 7, 8, 11 | A GNS3 lab's traffic appears in Malcolm |
| 5 | dnsmasq `.lab` + chrony, designed to avoid touching Netplan if possible | 5 | `.lab` resolves without hosts-file entries |

Until sub-project 5, analysts reach `.lab` names through a hosts-file entry, as the
2026-09-16 rehearsal did. Phase 4 (users/SSH hardening) is out of scope.

## Constraints

- **This session reaches neither the staging VM nor the R770** (192.168.4.28: no route; no SSH
  key or alias for the R770). Every command on either box is run by the operator from their own
  session and its output pasted back or saved to a log. This session does pin research, repo
  work, reviews and evidence write-ups.
- No iDRAC or PERC work (decision of record, 2026-09-24).
- Manual bundle categories (`dell/`, licensed `gns3/appliances/`) are assumed staged by the
  operator (operator, 2026-09-24).
- CLAUDE.md rules 1, 3, 4 hold: discovered names only, gated destructive steps with explicit
  confirmation, no result claimed without pasted evidence.

## Part 1 — Staging side

1. **Pin review (this session).** Check every value in the pin block of
   `scripts/r770-offline-fetch.sh` against upstream. Write
   `state/inventory/pin-review-2026-09-24.md` (pin · current · latest · moved?). The operator
   approves each bump. grafana-oss stays below 13.x (standing exception). Commit the bumps with
   `./tests/run.sh` green.
2. **Cut (operator, on VM 9770, from this branch):**
   ```bash
   cd ~/simlab-build && git pull && ./scripts/r770-staging-preflight.sh
   tmux new -s cut 'sudo -E ./scripts/r770-build-bundle.sh 2>&1 | tee ~/cut-$(date +%F).log'
   ```
   At the manual-items pause the operator stages `dell/` and `gns3/appliances/`. The builder
   regenerates the manifest and runs `verify --strict`.
3. **Disposition.** The operator pastes the verify summary and the `BUNDLE_NOTES.md` WARN lines.
   Exit 1 means stop. Exit 2 means every WARN is dispositioned in writing before the media
   moves. Record in `state/inventory/bundles.md` and `state/BUILD-STATE.md`.
4. **Media.** Copy the bundle to the ≥256 GB ext4 drive. Also put `scripts/r770-storage-apply.sh`
   on the drive; its sha256 is recorded in the evidence. Run `verify` once from the drive, then
   carry it across under the site scan policy (install runbook Part 0).

## Part 2 — R770 side (operator-run)

1. **Read-only block.** Pasted back. Nothing changes.
   - identity: `hostname`, product serial `G8WFGH4`
   - Phase 2 TRIM read. Find the disk holding `ubuntu-vg0` from its PV; don't assume it. Then
     `lsblk -D` and `/sys/block/<vd>/queue/discard_{granularity,max_bytes,max_hw_bytes}`
   - `tail -c1 /etc/fstab | od -c` (the script refuses an fstab without a trailing newline)
   - mount the drive read-only (install runbook 1.1), check the storage script's sha256, then
     `sudo bash <drive>/r770-storage-apply.sh --plan`

   This session then writes `state/inventory/r770-phase2-assessment.md`:
   - item 2: BY DESIGN, citing Dell's PERC13/PERC12 guide
   - item 3: the TRIM verdict
   - items 1, 4, 5: DROPPED or DOCUMENTED per the 2026-09-24 amendment

   `safety-reviewer` reviews the plan output. The operator gets the CLAUDE.md rule-3 summary:
   - changes: `lv-var` 6G→50G, 8 new LVs, 8 fstab lines, immutable mount points
   - data at risk: none, all new LVs from free extents
   - current vs proposed: the `--plan` output
   - rollback: per LV, `umount` → `chattr -i` → restore fstab backup → `lvremove`
   - `--grow-var` is the one step that can't be undone online

   **Nothing is written until the operator confirms.**
2. **Apply block.** Run as `ssh -t <r770>` → `tmux new -s phase3` → one script piped
   `| tee /root/phase3-$(date +%F).log`. It stops at the first non-zero exit:
   1. `--grow-var`
   2. `--apply --lv` for lv_docker, lv_index, lv_staging, lv_vms, lv_gns3, lv_work, lv_backup,
      then lv_pcap last
   3. `systemctl enable --now fstrim.timer` only if TRIM is ADVERTISED; otherwise note it
      left off
   4. `--plan` (every row SKIP), `findmnt --verify`, `df -h` on every new mount

   The operator pastes the log.
3. **Reboot test**, at an operator-chosen time, **before** the bundle copy. Re-run the step 4
   checks afterwards. Every mount must return.
4. **Bundle onto disk.** Install runbook Parts 1.2–1.4, with one change: the bundle lands in
   `/data/staging/bundle-<date>/`, not `/srv/bundles/`. That keeps the bundle (size: `state/inventory/bundles.md`) off the 50G root.
   `./r770-bundle.sh verify .` from the disk copy: exit 0, or 2 with dispositions; 1 = stop.
5. **APT local repo (GATED).** Install runbook Part 3 as written:
   - copy `apt/` to `/srv/repo/apt`
   - tar the current sources as the rollback
   - move `sources.list.d` aside
   - add `deb [trusted=yes] file:/srv/repo/apt ./`
   - disable `unattended-upgrades`, purge `snapd`, `chmod -x` the motd scripts

   Current vs proposed is shown and confirmed first. Validate:
   - `apt update` contacts only `file:/srv/repo/apt`
   - `apt-get install --dry-run docker-ce` resolves entirely from it

   Rollback: restore the sources tarball, then `apt update`.
6. **Record.**
   - `bundles.md`: transfer cycle, who carried the media, verify exit codes
   - `BUILD-STATE`: Phase 2 VERIFIED; Phase 3 APPLIED, then VERIFIED after the reboot; bundle
     row; log entry

## Doc updates carried by this sub-project

- `docs/plans/r770-install-runbook.md`:
  - bundle location `/srv/bundles` → `/data/staging` (Parts 1.3–1.4, 3.1)
  - the "Where this runbook stops today" table no longer says Phase 5 blocks Parts 6+. The
    iDRAC gate was dropped 2026-09-24, so they wait on their own phases only.
- The earlier plan's Task 6 tmux wording
  (`work/plans/active/2026-09-23-phase2-3-storage.md`) is superseded by Part 2.2 here. Mark it
  so, then archive that plan once Phase 3 is VERIFIED.

## Out of scope

Docker install and `docker load` (sub-project 1); everything after. Phase 4 hardening. Any
iDRAC/PERC action.
