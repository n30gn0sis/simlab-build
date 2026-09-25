# Staging VM 9770 — rebuild, scoped access, and automated cut + import rehearsals

**Date:** 2026-09-24 · **Status:** design approved by operator, not yet implemented
**Serves:** sub-project 0 (`docs/superpowers/specs/2026-09-24-bundle-to-r770-design.md`). This
session runs the bundle cut and the staging-side evidence itself, and rehearses the R770 import
steps, instead of the operator pasting output.

## Facts that shaped this (read-only query, 2026-09-24)

- This session (LXC on the Proxmox host, 192.168.4.59) reaches the Proxmox API at
  `192.168.4.21:8006`. It holds no VM credentials.
- **VM 9770 no longer exists.** No VM, no snapshots. The host `proxmox` is online, and the
  other guests are 100, 101, 104, 106, 108 and 128.
- The as-built spec, image provenance and evidence gates are recorded in
  `state/inventory/staging-vm-9770.md`. That file is the owner of the VM's specification; this
  design references it and does not restate it.

## Decisions (operator, 2026-09-24)

1. Routine access is a **scoped API token**, limited to `/vms/9770`.
2. Every run starts by **rolling back a snapshot**.
3. Run scope is **cut + import rehearsal** (install runbook Parts 1–3). The storage scripts stay
   bats-only, because the cloud image has no `ubuntu-vg0`.
4. The operator supplied **root@pam credentials for one-time use**: the rebuild and creating
   the token. They are not stored. The operator should change that password afterwards.
5. The driver is a **small tested bash script** (approach A), not ad-hoc commands and not a
   Python client.

## Part 1 — One-time rebuild and access (root, used once)

1. **Rebuild 9770 exactly per `state/inventory/staging-vm-9770.md`.** Same VMID, name, CPU,
   memory/balloon, disk size, storage, disk flags (including the load-bearing `backup=0`),
   network, MAC (so DHCP returns the recorded address), console and `onboot`.
   - **Image:** the pinned cloud-image release named there. Download its `SHA256SUMS` and
     `SHA256SUMS.gpg`, verify them on this side (GPG, then `sha256sum -c`) before import.
   - **Cloud-init:** user `ubuntu`, and **this session's new SSH public key** (generated for
     this purpose; private half stays in this session's `~/.ssh`). No password is set.
2. **Provision** as the record's "Installed" section lists: Docker CE from Docker's apt repo,
   the helper packages, `ubuntu` in the `docker` group, the 8 GiB swap file. Re-run every
   evidence gate in the record: `systemd-detect-virt` = kvm, root grown to the full disk, disk
   floor, `docker run hello-world`.
3. **Snapshot `clean-2026-09-24`**: VM shut down cleanly, no bundle, no loaded images beyond
   `hello-world` (which is removed first).
4. **Scoped access.** User `claude-staging@pve`, role `SimlabStaging` =
   `VM.Audit, VM.PowerMgmt, VM.Snapshot, VM.Snapshot.Rollback`, ACL on `/vms/9770` only. Token
   `claude-staging@pve!lxc101` with privilege separation (the token itself also gets the
   role on `/vms/9770`). Secret stored at `/root/.config/simlab/pve-token` (mode 0600,
   `user@realm!tokenid=secret` form), never in the repo.
5. **Record.** `state/inventory/staging-vm-9770.md` gains a "Rebuilt 2026-09-24" section: the
   image verify output, the new SSH host-key fingerprint, the gate results, the snapshot name,
   the token's user/role/ACL (never the secret). `state/BUILD-STATE.md` staging-host row and
   log are updated.

## Part 2 — The driver: `scripts/r770-staging-vm.sh`

Runs **in this session**, never on the VM or the R770.

| Command | Does |
|---|---|
| `status` | VM power state and uptime; snapshot list |
| `rollback <snap>` | Stop the VM if running, roll back, wait for the task |
| `start` / `stop` | Power, waiting for the task (stop = ACPI shutdown, then `stop` after a timeout) |
| `wait-ssh [secs]` | Wait until `ssh ubuntu@<vm>` answers (default 300 s) |

- **Fixed target.** Node `proxmox` and VMID `9770` are constants; there is no flag to change
  them. The token can only touch 9770 anyway, so that's two guards against the wrong guest.
- **API.** `curl` with `Authorization: PVEAPIToken=<token>` against
  `https://192.168.4.21:8006/api2/json`. Proxmox's self-signed certificate is accepted with
  `--cacert` pinned to the host's CA, fetched once in Part 1 and stored beside the token, not
  with `-k`. Every task-returning call polls `/nodes/proxmox/tasks/<upid>/status` until it
  stops, and fails unless `exitstatus` is `OK`.
- **Config overrides for tests:** `STAGING_PVE_URL`, `STAGING_PVE_TOKEN_FILE`,
  `STAGING_PVE_CA`, `STAGING_VM_HOST`.
- **Tests** (`tests/staging-vm.bats`), with `curl` and `ssh` stubbed:
  - every URL targets `/nodes/proxmox/qemu/9770`;
  - rollback stops a running VM first;
  - a task that ends in anything but `OK` fails the command;
  - a missing or world-readable token file is refused;
  - the token never appears in output.
- Registered in `tests/lint.bats` (no exclusions), `tests/README.md` and `README.md`.
- `tests/no-credentials.bats` must keep passing. If it doesn't already reject PVE token
  patterns (`PVEAPIToken=` followed by a UUID-shaped secret), extend it so it does.

## Part 3 — A rehearsal run (this session)

1. `rollback clean-2026-09-24 && start && wait-ssh`.
2. **Cut.** On the VM: `git clone` the repo's `main` (public HTTPS; no credentials needed),
   then `r770-staging-preflight.sh` and `r770-build-bundle.sh` under
   `tmux … | tee ~/cut-<date>.log`.
   - At the manual-items pause, place **synthetic** stand-ins named `SYNTHETIC-*` in `dell/`
     and `gns3/appliances/`.
   - The bundle is a **test cut, never a transfer candidate.**
3. **Import rehearsal** on the same VM, as if it were the R770: install runbook Parts 1.2–1.4
   and 3 against the new bundle.
   - The VM has no `/data/staging` LV, so a directory stands in for it.
   - APT is repointed at the local repo, then `apt update` and
     `apt-get install --dry-run docker-ce`.
4. **Evidence back.** `scp` the logs into this session. Write
   `state/inventory/staging-rehearsal-<date>.md`:
   - preflight, cut and verify exit codes;
   - the WARN list with dispositions;
   - size and file count (recorded in `bundles.md`, their owner);
   - the import verify exit codes;
   - APT before/after and the dry-run output.

   `bundles.md` logs the cycle as **test cut — not for transfer**.
5. `stop`. Leftovers don't matter; the next run rolls back first.

## Risks

- **Host memory.** 8 GiB for 9770 on a 29 GiB host with other guests running. Keep
  `onboot 0` and stop the VM after every run.
- **Root credential exposure.** The password is in the chat transcript. It is used once and
  never stored; the operator changes it afterwards. The token is scoped so that losing it
  exposes only 9770.
- **A synthetic manual item mistaken for real.** `SYNTHETIC-` prefix, and the evidence file
  and `bundles.md` both say "not for transfer".

## Out of scope

The real transfer cut for the R770 (still sub-project 0 Task 4, with real manual items). The
storage scripts on real LVM. Any change to other guests.
