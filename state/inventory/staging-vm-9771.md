# Staging VM 9771 `r770-staging-2` — second staging VM (2026-09-25)

**Why:** on 2026-09-25 a second Claude session (`sim-lab-basic-08`) and this one were both changing `bundle-20260925` on VM 9770 at the same time. The VM's `sudo` journal shows the other session's `--only appliances`, a strongSwan GNS3 node, and `--only manifest` / `verify` runs interleaved with this session's builder. That produced a duplicated appliance stage, a colliding CHR download (`curl: (23)`), and a `BUNDLE_NOTES.md` that changed after the manifest was written. The operator chose a separate VM per session.

**Spec owner:** same as `state/inventory/staging-vm-9770.md` — 9771 is a **full clone of 9770's `clean-2026-09-24` snapshot**, so image provenance, installed software and evidence gates are the ones recorded there.

| | |
|---|---|
| Created | 2026-09-25 by the Claude session, root@pam used once (operator-approved), `POST …/qemu/9770/clone full=1 snapname=clean-2026-09-24 storage=local-lvm` → task OK |
| Config | name `r770-staging-2`, `cpu host` ×6, 8192 MiB `balloon 0`, 400G `local-lvm` with `backup=0,discard,ssd,iothread,mbps_wr=250,mbps_wr_max=400`, `serial0 socket`, `onboot 0` — as 9770's clean snapshot |
| MAC | **`BC:24:11:E7:AF:99`** (new, from the clone). **No DHCP reservation yet**, so the driver has no default host for 9771: pass `STAGING_VM_HOST` |
| Snapshot | **`clean-2026-09-25`**, taken cold **before first boot**, no vmstate |
| Access | Same token `claude-staging@pve!lxc101`, role `SimlabStaging`; ACL extended to **`/vms/9771`**. Token now sees exactly `[9770, 9771]`; VM 101 → HTTP 403 |
| Driver | `STAGING_VMID=9771 scripts/r770-staging-vm.sh …`. The driver accepts exactly 9770 or 9771; any other value (including empty) is refused before any API call |
| State | **Never started.** At creation the host was at 20.6 / 29.2 GiB (9770 running with 12 GiB, VM 101 with 15.6 GiB), so another 8 GiB would leave ~0.6 GiB. Start it only when 9770 is stopped or smaller, or give it less memory |

Ownership going forward: **9770 belongs to `sim-lab-basic-08`, 9771 to this session.** Two sessions must not build into the same VM at once.
