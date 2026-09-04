# Staging VM 9770 `r770-staging` — build record

**Built:** 2026-09-04 · **Hypervisor:** `proxmox` (192.168.4.21), PVE 9.2.11, kernel 7.0.14-15-pve
**Purpose:** builds the offline supply bundle for the air-gapped R770 `testbed` (tag G8WFGH4).
**Design + adversarial review:** 8-agent workflow, 3 designs × 4 risk lenses, 32 risks raised.

## Why this host

Decision of record (dependency manifest §0, operator-approved 2026-09-04): staging moved from
RHEL 8 to a **Proxmox VM running Ubuntu 24.04 + Docker CE**. It must be a **VM, not an LXC
container** — Docker in LXC needs `nesting=1`/`keyctl=1` and still fights overlayfs.

Note the hypervisor also runs LXC 101, which is where the Claude Code session that built this
lives. Resource decisions below were made with that in mind.

## As-built spec

| | |
|---|---|
| VMID / name | `9770` / `r770-staging` (VMID deliberately far from the 100–128 live block) |
| CPU | 6 cores, `--cpu host`, `numa 0`, cpuunits default |
| Memory | **8192 MiB, `--balloon 0`** — 12 GiB would leave ~1.5 GiB slack on a 29 GiB host, and a balloon floor is not a reservation |
| Disk | **400 GiB** on `local-lvm`, `discard=on,ssd=1,iothread=1,backup=0,mbps_wr=250,mbps_wr_max=400` |
| Guest swap | 8 GiB `/swap.img` — the cloud image ships none, and `balloon 0` gives no soft landing |
| Network | `vmbr0`, virtio, MAC `BC:24:11:97:70:01`, DHCP → **192.168.4.28/22**, gw 192.168.4.1 |
| Console | default VGA (noVNC) **plus** `serial0 socket` — two independent recovery paths |
| Auth | key-only, `ubuntu` user, host's `/root/.ssh/id_rsa.pub` injected. **No password anywhere** |
| onboot | `0` — never competes for RAM at host boot |

**`backup=0` is load-bearing.** `vzdump` targets `local`, which *is* the 54 GiB PVE root
filesystem. A backup of this VM would fill `/`, take pmxcfs read-only, and break `qm`/`pct` for
all six guests. Pre-flight confirmed **no vzdump job exists at all** (`jobs.cfg` absent,
`vzdump.cron` empty, `vzdump.conf` default, no timers), so the flag is future-proofing — but if
an "All"-mode job is ever added, `backup=0` alone is not enough and 9770 must go in its exclude list.

## Image provenance

- Pinned **`releases/noble/release-20260826/`** — deliberately *not* `noble/current/`, which is
  the daily tree and unreproducible; wrong for a pinned-supply-chain project.
- `ubuntu-24.04-server-cloudimg-amd64.img`, qcow2, 3.5 GiB virtual / 596 MiB on disk
- **GPG: Good signature** from `UEC Image Automatic Signing Key <cdimage@ubuntu.com>`,
  RSA-4096, fingerprint `D2EB 4462 6FDD C30B 513D 5BB7 1A5D 6C4C 7DB8 7C81`, signed 2026-08-26
- `sha256sum -c` against the signed list: **OK**
- Caveat recorded honestly: the key is `[unknown]` in the local web of trust, so this proves the
  image matches what that key signed — not independently that the key is Canonical's.

## Installed

Ubuntu 24.04.4 LTS, kernel 6.8.0-138 · Docker CE **29.8.0**, compose **v5.5.1**, overlayfs,
cgroup v2 · pigz 2.8, jq, rsync, wget, curl, gpg, unzip, qemu-guest-agent · `ubuntu` in the
`docker` group.

## Evidence gates (all passed)

| Gate | Result |
|---|---|
| Guest is a real VM | `systemd-detect-virt` = **kvm** |
| Root grew to full disk | sda 400G → sda1 399G → **`/` 387G, 376G avail** (growpart automatic) |
| Runbook §1.4 disk floor ≥150 G | **376 G** |
| `docker run hello-world` | "installation appears to be working correctly" |
| The two build images the script uses | `ubuntu:24.04` ✓ · `python:3.12-slim` ✓ |
| In-container apt egress (script's [0/10] preflight) | **ok** |
| pigz present (else line 187 silently drops to single-threaded gzip) | `/usr/bin/pigz` 2.8, 6 cores |
| swap / fstrim.timer / docker | 8 G active · enabled · active |

## Thin-pool position

`pve/data` is 815.36 GiB, **6.10 % used** after the build. Allocating 400 GiB changed pool free
by **zero bytes** — verified byte-identical before and after `qm disk resize`, which is thin
provisioning behaving correctly.

**Over-provisioning, stated accurately.** LVM warns:
`Sum of all thin volume sizes (1.07 TiB) exceeds the size of thin pool`. Nominal commitment is
298 (six existing guests) + 400 (this VM) + 400 (its snapshot) = **1098 GiB against 815 = 135 %**.
The design review put this at 85 % because it omitted the snapshot volume — that was wrong.

It is still not a hazard, because nominal ≠ reachable:

```
snapshot pins what existed when taken     ~15 GiB
this VM writes its entire 400 GiB          400 GiB
all six existing guests fill completely    298 GiB
                                          --------
worst case actually reachable              713 GiB of 815 = 87%
```

87 % is above the watchdog's 80 % data threshold, so the guard stops VM 9770 before the pool can
exhaust. That is the safety net working as designed, not a margin being relied on.

## Thin-pool watchdog (host)

`/usr/local/sbin/thinpool-guard.sh` + `thinpool-guard.timer`, every 5 min, logging to
`/var/log/thinpool-guard.log`. Stops VM 9770 at **data ≥80 %** or **metadata ≥70 %** — metadata
threshold is lower on purpose, since tmeta exhausts first under snapshot + Docker churn and
fails the same way. Debian ships `thin_pool_autoextend_threshold` disabled, so nothing else alarms.

Two bugs were caught by dry-running it before arming, which is why the dry run exists:
1. `tr -d ' %'` deleted the field *separator* as well as the percent sign, merging
   `5.92 0.42` into `5.920.42`. Now strips only `%`, per-field, via awk.
2. The breach branch was then proven reachable by running a copy with thresholds lowered to 1 %
   and `qm stop` stubbed to an echo — it fired. An untested safety mechanism is worth little.

Current: `data=6.1% meta=0.42%`.

## Snapshot

`pre-fetch`, taken **cold** (VM shut down) and deliberately **without `--vmstate`** — no 8 GiB
RAM-state volume in the pool, and rollback returns a state that is trivially reasoned about
rather than resuming a mid-flight kernel.

Rollback: `qm stop 9770 && qm rollback 9770 pre-fetch && qm start 9770`

## Watch list for fetch day

- **Do not start VM 100 or 108 during a run.** Committed memory would exceed 29 GiB and the OOM
  killer takes the 8 GiB QEMU process. Run `qm list` immediately before starting a fetch.
- **If space runs short, grow the disk — never `docker system prune`.** `ctr_save`
  (fetch script line ~178) pipes `docker save` into gzip with no resume; ENOSPC discards the whole
  30–40 GB save, and pruning then forces re-pulling all 23 Malcolm images. Downloads resume via
  `curl -C -`; that pipe does not. Grow instead: `qm disk resize 9770 scsi0 +100G`, then
  `growpart /dev/sda 1 && resize2fs /dev/sda1`. Free on a thin pool.
- **The bundle must never transit the host filesystem.** 45–65 GB into 54 GiB of PVE root is the
  same node-killing outcome as a vzdump. Pass the ext4 transfer media through to the guest.
- **Run the fetch under `tmux`** so a dropped SSH session doesn't take hours of downloading with it.
- **Re-check `command -v pigz`** after any rollback or rebuild.

## Still open

1. **How the 45–65 GB bundle leaves the VM** — media passthrough (`--scsi1 /dev/disk/by-id/…` or
   `--usb0 host=…`) not yet designed, and the media is not attached.
2. **Licensed GNS3 appliance inventory** (runbook Step 0B) — still the only unbounded item; it
   sizes both this disk and the 256 GB transfer media.
3. **Site AV/media-scan policy** (Step 0D).
4. **Rotate the Proxmox root password** — it was shared in a chat transcript and is in shell
   history on both boxes.
