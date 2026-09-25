# In-place bundle test 2026-09-25 — `bundle-20260925` on VM 9770, under a simulated air gap

> The bundle was **not transferred**. It was tested where it was built (operator request). **No manual items staged**: `dell/` holds only its README. This is not yet a transfer candidate.

Driven entirely from the Claude session: `r770-staging-vm.sh` (scoped token) + SSH. Raw logs are in `staging-inplace-test-2026-09-25/`, including the test script itself.

## The cut

| | |
|---|---|
| Source | public `main` @ `97f83df` (includes the docs-mirror fix, PR #6) |
| VM | `rollback clean-2026-09-24` → `start`; DHCP gave **192.168.4.78** (found by MAC sweep) |
| Preflight | **exit 0**, all PASS (`preflight.log`) |
| Fetch | `r770-offline-fetch.sh` (full), **exit 0**, 1596 files, 15G (size/count owner: `bundles.md`) |
| `BUNDLE_NOTES.md` | **zero WARN lines** — the first cut with none (`BUNDLE_NOTES.md.txt`); docs: malcolm mirrored (10 upstream 4xx noted), zeek htmlzip, wireshark, gns3-server docs |
| `verify --strict` | **FAIL on exactly one item:** `dell/ holds only README.txt — manual downloads not staged` (`gate-strict.log`). Every integrity check passes. |

## In-place offline test (install runbook Parts 1–5 and 7.1, bundle in place)

`r770-airgap-sim.sh block` cut the VM's internet (host and container traffic), with an automatic unblock scheduled. A failing curl proved the block each time (`registry-1.docker.io`, `pypi.org`). LAN SSH stayed up.

| Step | Result |
|---|---|
| verify in place / after copy to `/data/staging` | exit **2** / exit **2** — the same single `dell/` warning |
| APT (Part 3): sources swapped to `deb [trusted=yes] file:/srv/repo/apt ./` | `apt-get update` **exit 0**, local repo only |
| Dry-runs from the bundle alone | libvirt-daemon-system 188 · qemu-kvm 169 · tshark 18 · python3-venv 4 · dnsmasq 3 · chrony 2 · nginx 2 · bridge-utils 1 Inst — **0 errors** |
| Real install from the bundle | `python3-venv python3-pip-whl` **installed** |
| Docker (Part 5) | Image store **emptied first** (the fetch had pulled everything). The Malcolm, monitoring and gns3-node tarballs were then loaded offline: **35 tags**. `r770-malcolm-deploy.sh assert-tags`: **all images present**. Monitoring **8/8**, gns3 nodes **4/4** present |
| GNS3 (7.1) | `pip install --no-index --find-links …/gns3/wheelhouse gns3-server` → **3.0.6**, offline |
| Air gap | unblocked; status OPEN |

## Findings

1. **Install runbook Part 5's tag check reported docker.io images as missing (fixed on this branch).** `docker image ls` drops the default registry: `docker.io/prom/prometheus:TAG` lists as `prom/prometheus:TAG`, and `docker.io/library/nginx:TAG` as `nginx:TAG`. The raw `comm` would report 7 of the 8 monitoring images "missing" and tell the R770 operator to **stop** a good import. The fix normalises both sides; verified here, 8/8 and 4/4.
2. **"Err:" lines during a clean `apt update`.** The flat repo has no `Release` file, so apt probes `Packages.{xz,bz2,lzma}` (one `Err` each) before it succeeds with `Packages.gz`, exit 0. Harmless, but it will alarm an operator. A `Release` file generated at cut time (`apt-ftparchive release`) would stop the probing. **Not fixed yet — follow-up.**
3. **The test's own first APT check was too strict** (it matched any `Err` line and ignored the exit code). Corrected in `inplace-test.sh` before the passing run. Recorded for honesty; it isn't a bundle defect.
4. **The VM's DHCP address moves on rollback** (.72 → .78). It needs a DHCP reservation for `BC:24:11:97:70:01` (operator).

## State left behind

VM 9770 is **stopped, not rolled back**. `bundle-20260925` stays on its disk (`/home/ubuntu/simlab-build/bundle-20260925`), ready for the real Dell files, a manifest regeneration and `--strict`. Any `rollback` discards it.
