# Import/install test 2026-09-26 — `bundle-20260926` really installed, offline, on VM 9771

> No transfer media (operator: skip the ext4 transfer). VM 9771 was made **R770-like**: its internet-installed Docker purged, state and apt source removed, and internet cut for host and containers with `r770-airgap-sim.sh`. Everything below came from the bundle alone. Before the test, 9771 was cold-snapshotted as **`bundle-20260926-cut`**, so the passing cut can be restored.

Scripts and raw logs are in `staging-install-test-2026-09-26/`: `install-test.sh` (full, corrected), `install-test-part2.sh`, `install-test-part3.sh`, `install-test-part{1,2,3}.log`, `install-apt-update.log`, `installed-highlights.txt`.

## Result: ALL PASS

| Runbook step | Result |
|---|---|
| Air gap | blocked; `archive.ubuntu.com`, `download.docker.com` and `pypi.org` unreachable (proved at each part) |
| Docker absent before the test | purged; `docker` not on PATH |
| 1.2–1.4 verify | **`--strict` PASS** in place **and** after the copy to `/data/staging` |
| 3 APT | `Packages` + `Packages.gz` + `Release` present; `apt-get update` **exit 0, no Err, no skipped index** — the #8 fix confirmed on a real install |
| 3 package set | `dist-upgrade` from the bundle; then **all 59 packages** of the fetch script's own `PKGS` list installed — **524 packages set up** (libvirt 10.0.0, qemu-system-x86 8.2.2, tshark 4.2.2, nginx, dnsmasq, chrony, the HWE kernel 7.0.0-34, …) |
| 4 Docker | `docker-ce` 29.8.1 installed **from `file:/srv/repo/apt`**, running (overlayfs, cgroup v2) |
| 5 images | image store empty → all tarballs loaded offline, **35 tags**; Malcolm `assert-tags`: all present; monitoring 8/8; gns3 nodes 4/4 |
| 5b smoke, `--network none` | Malcolm **`zeek version 8.2.2`**; `registry:2` answers `/v2/` locally; a GNS3 alpine node runs |
| 7.1 GNS3 | `gns3-server` **3.0.6** from the wheelhouse, no index |
| After | VM rebooted **after** the full install (HWE kernel included) and came back on 192.168.4.26 |

## Test defects found and fixed (not bundle defects)

The run took three parts, because the test itself was wrong three times. Each part stopped at the failure and lifted the air gap, as designed:

1. **`qemu-kvm` reported "not installed".** On noble it is a **virtual** package provided by `qemu-system-x86`, which *was* installed. The check now accepts an installed provider.
2. **Zeek smoke used a guessed path** (`/opt/zeek/bin`). Malcolm's image has it at `/usr/local/zeek/bin` on PATH, so the test now runs `zeek` through the image's PATH.
3. **`zeek: Operation not permitted`.** The binary carries file capabilities `cap_net_admin,cap_net_raw=eip` and only execs with those granted, as Malcolm's compose grants them. The smoke now adds `NET_RAW` and `NET_ADMIN`. **Worth knowing on the R770:** a Zeek container launched without those caps fails the same way.

Part 3 also needed `norm()` re-defined (it was cut out with step 5). The committed `install-test.sh` has all the fixes in one script.

## State left behind

9771 is **stopped**. Its current disk has the installed stack. Snapshot `bundle-20260926-cut` holds the pristine passing cut, and `clean-2026-09-25` the pre-cut clean state.
