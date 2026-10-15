# Staging 2026-10-04 — the offline installer from the bundle alone, under the air gap

The acceptance rehearsal for sim-lab-basic's offline installer
(`<bundle>/kit/scripts/r770-install.sh`, sim-lab-basic PR #10, merged) and this
branch's `kit` fetch stage. The question was whether an R770 with Ubuntu
installed, plus the bundle media and nothing else, can reach a proven lab
through the installer alone. It can. Every step completed, and e2e judged all
8 scenarios in Malcolm. The verdict is "NOT INSTALLED — finished with
warnings", for one staging-only reason, set out below.

## 1. Host

- **VM:** 9770, rolled back to `clean-2026-09-24`, 12 GiB (raised by the operator after the rollback).
- **Stand-ins for things the kit doesn't own:**
  - Phase 3: eight sparse ext4 loop volumes in `/etc/fstab`, as on 2026-09-29.
  - New: a 40G loop volume at `/var/lib/containerd`. This applies one of the remedies the kit's new `storage` check prints. On this VM the check then PASSes ("on its own mount").
- **Unlike 2026-09-29, the base-OS packages were not stood in.** The kit's `apt` stage now installs them itself; see Findings.
- **Staging's cached images were pruned first,** so every image came from the bundle.

## 2. The cut (online)

- **First cut:** `KIT_SRC_ROOT=<sim-lab-basic offline-installer> SITE_SRC_ROOT=<this branch> SEED_FROM=none r770-build-bundle.sh --yes`. Strict gate PASS: 14G, `kit/: 122 files from 3adfe74`, and "kit/ carries the R770 installer".
- **Kit-stage re-cuts** (`--only kit`) after the two kit fixes below. Each re-ran the manifest and the strict gate, and each PASSed.
- **The final bundle, `bundle-20261004`, carries kit `7c98218`.** It was cut under a new name because import's `copy` is stamped by bundle name, so a re-cut under the same name would not be copied again. That is pre-existing behaviour, noted in the code review.

## 3. The install (air gap BLOCKED with `scripts/r770-airgap-sim.sh`, 240 min; egress confirmed refused)

**Media:** a loop-device ext4 image holding the bundle, mounted read-only at `/mnt/media`. The kit checkout was deleted from the VM before the install.

**Only the bundle's commands were run:**
1. `r770-bundle.sh verify`: PASS, and the kit was present.
2. `r770-install.sh discover`: printed the host and wrote the template with nothing chosen.
3. `wizard`: menu answers fed from the same discovery commands. It derived `MGMT_CIDR=192.168.4.0/22`. `VALIDATE_AREAS=network capture gns3 storage portal airgap` was then added: the areas a VM can prove.
4. `plan`, then `run --yes`.

| Run | From | Result |
|---|---|---|
| 1 (kit `1792c0d`) | the media | import PASS (preflight's first-install warnings recorded as a note), hand-off to `/srv/bundles/bundle-20261003/kit`. gns3, malcolm and docs WARN (below), portal PASS, **dashboards FAIL**: three index patterns, and the step refuses to choose. Finding 2. |
| 2 (kit `7c98218`) | the media, new bundle | import PASS, hand-off, gns3/malcolm/docs WARN, portal, dashboards, **validate (41 checks, 6 skipped) and e2e (32 checks: all 8 scenarios judged in Malcolm)** PASS. Verdict: **NOT INSTALLED — finished with warnings from: gns3 malcolm docs**, exit 2. |
| 3 | the local copy, `--from malcolm` | Interrupted mid-malcolm by signalling the whole process group, as Ctrl-C does: exit 1, a `malcolm` FAIL row and `--from malcolm` in the summary. |
| 4 | the local copy, `--from malcolm` | Re-entry. malcolm, docs, portal, dashboards, validate and e2e (32 checks) all completed; the same warnings (malcolm, docs). |

After run 4 the media unmounted cleanly, so nothing held it. The air gap was lifted and confirmed OPEN.

**The warnings, disposition by disposition:**
- **8 × "definition without image"**, for cisco-asav, cisco-iosv, cisco-iosvl2, fortigate, frr, openwrt, pan-vm-fw and tinycore-linux. These are licensed appliances that a test cut cannot carry. Each pipeline's shared `files` step reports them again (gns3, malcolm and docs). On the R770 the operator stages these images at cut time. They are why this staging run is not INSTALLED.
- **"something listens on 0.0.0.0:443"** (malcolm, runs 2 and 4 only). This is the portal's own nginx from run 1 (`ss` showed `nginx`), which the warning text itself anticipates. It is an artefact of a second pass, not a Malcolm defect.

## 4. Findings (each fixed test-first in sim-lab-basic before the next run)

1. **Nothing installed the kit's required base packages** (`python3-venv`, `python3-pip-whl`, `python3-ruamel.yaml`, `python3-dotenv`, `easy-rsa`, `nginx`, `ubridge`). Every step only checked for them, so a fresh R770 dies at gns3's `venv`. The 2026-09-29 test hid this by standing them in by hand. **Fixed:** import's `apt` stage installs whichever are missing, from `file:/srv/repo/apt` only, under its existing gate.
2. **The installer had no way to pass `--index-pattern` to `dashboards`.** **Fixed:** an optional `INDEX_PATTERN` key. It exists only once Malcolm is up; left empty, the step's own refusal still lists the choices. This run used `arkime_sessions3-*`.
3. **`plan` on a fresh host is red by construction**, not a fix-before-run. Steps that depend on packages the `apt` stage *would* install (gns3 `venv`, malcolm `unpack`, the four portal steps) see them missing under `--dry-run`. Open: `plan` should say "installed by apt" instead.
4. **A whole-group Ctrl-C records "see log", not "interrupted",** because the child exits first. The row still names `--from <step>`. Open, minor.
5. **The builder's preflight hung on container egress** after the stand-in volumes were mounted under a running docker. A VM reboot cleared it. This was a staging artefact of mounting under a live daemon, not a kit or build-repo defect.
