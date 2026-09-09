# R770 Offline Dependency Prep — Staging Runbook (Ubuntu 24.04 VM)

**Companion to:** `r770-offline-supply.md` (the model/rationale) · `r770-offline-fetch.sh` v3.3 (the tool; resumable, seeds new bundles from previous ones) · `r770-dependency-manifest.md` (authoritative dependency list + decisions record) · `r770-network-lab-buildout.md`
**Date:** 2026-09-04 — **staging host changed from RHEL 8 to a dedicated Proxmox VM running Ubuntu 24.04 + Docker CE** (operator approved; rationale in dependency manifest §0). Pins reviewed and four bumped the same day (`state/inventory/pin-review-2026-09-04.md`).
**Staging host:** a dedicated **Proxmox VM** running Ubuntu 24.04 with internet access (direct or via corporate proxy), preparing bundles for the air-gapped Ubuntu 24.04 R770 `testbed` (tag `G8WFGH4`).
**Verified against (2026-09-04):** pins as reviewed in `state/inventory/pin-review-2026-09-04.md` — see the pin block in `scripts/r770-offline-fetch.sh` for current values; ET Open Suricata branch path confirmed HTTP 200, not retired.

Everything heavy still runs inside containers (`ubuntu:24.04`, `python:3.12-slim`) — that indirection is what made a RHEL host viable and it costs nothing on Ubuntu, so the script is unchanged. The host needs only a container runtime, curl, gpg, unzip, wget, and disk.

---

## Step 0 — Prerequisites (decisions as of 2026-08-31 — see manifest §0)

- [x] **A. MaxMind GeoLite2** — **DESCOPED.** No account; Malcolm runs without geo tagging. v2 of the fetch script has the working fetch block if this is ever reversed.
- [ ] **B. GNS3 vendor appliance inventory** — **still open.** Free set (VyOS, CHR, OPNsense, Alpine, docker nodes) is now scripted; the licensed list (Cisco IOSv/IOSvL2/IOL/CSR/ASAv, FortiGate, PA VM-Series — and pfSense CE, which now requires a Netgate account) needs inventorying against your entitlements. Usually the largest category (10–100+ GB) and sizes the media.
- [x] **C. Supply strategy** — curated bundle (decided). Revisit apt-mirror only if unplanned `apt install` on the gapped box becomes recurring.
- [x] **D. Transfer media** — 256 GB+ USB/NVMe, ext4 (decided). Site policy for media scanning/signing still to confirm (Step 6 must match it).
- [x] **E. Dell service tag** — **`G8WFGH4`** (express service code 35366715688), confirmed by Phase 1 discovery 2026-09-03. Firmware baselines to compare against in Step 4: BIOS **1.7.5** (2026-01-16) · iDRAC/LC **1.30.20.10** · PERC H975i Front **8.14.0.0.28-40** · backplane **1.92** · Broadcom NIC **233.1.181.0** (pkg) / 233.0.195.0 · PSU **1408** · CPLD **109.125.104**.
- [ ] **F. Proxy details** if the staging host egresses through one: proxy URL (+credentials if any), and confirm the allowlist covers the domains printed by the script's preflight failure message (registries, Ubuntu archives, download.docker.com, PyPI, GitHub, and the appliance mirrors).

## Step 1 — Prepare the Ubuntu 24.04 staging VM

**1.0 Provision the VM.** It must be a **QEMU/KVM virtual machine, not an LXC container.** Docker inside LXC needs `nesting=1` and `keyctl=1` and still fights overlayfs — not a fight worth having in the middle of a multi-hour 65 GB fetch. On the Proxmox host:

- Ubuntu Server 24.04 LTS, **≥300 GB disk** (150 GB working space + room for the bundle and the previous one), ≥4 vCPU, ≥8 GB RAM
- Take a **snapshot before fetch day** — that is the cheap rollback a bare-metal host never had

```bash
systemd-detect-virt        # expect "kvm" or "qemu"; "lxc" means wrong container type
df -h /var /               # /var/lib/docker lives here
```

**1.1 Disk space.** Budget ≥150 GB free: images stored uncompressed under `/var/lib/docker` (30–40 GB compressed expands to 60–80+ GB) plus the bundle output. Unlike RHEL's default partitioning there is no `/home`-vs-`/var` split to work around, but confirm the root filesystem was actually grown to the full virtual disk:

```bash
lsblk; df -h /
# if the FS is smaller than the disk:  sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1
```

**1.2 Container runtime — Docker CE.** On Ubuntu this is a **first-party supported path** from Docker's own repository, with none of the RHEL caveats (third-party repo outside vendor support, conflict with the `container-tools` module):

```bash
sudo apt-get update
sudo apt-get -y install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world          # prove it before fetch day
```

(Rootful podman remains a supported fallback; the script auto-detects it and handles its differences, but then re-validate tarball interop per Step 3.)

**1.3 Host tools:**

```bash
sudo apt-get -y install curl gnupg unzip wget pigz jq
for t in curl gpg sha256sum tar unzip wget; do command -v $t; done
```

`pigz` is optional but worthwhile — the script auto-uses it to parallelize the ~30 GB compression step (stock single-threaded gzip is the wall-clock bottleneck). `wget` is required for the docs mirrors (skipped with a WARN if absent).

**1.4 Readiness check.** Before committing to a multi-hour run, confirm the box is the one you think it is:

```bash
systemd-detect-virt                       # kvm/qemu, NOT lxc
. /etc/os-release && echo "$PRETTY_NAME"  # Ubuntu 24.04.x
df -h --output=avail / | tail -1          # >= 150G
docker info >/dev/null && echo "docker OK"
curl -fsS -o /dev/null -w 'egress %{http_code}\n' https://api.github.com
```

**1.5 Proxy configuration (if the staging VM egresses through one).** A proxy must be configured in **two places** — this is the classic failure mode where the image pull works but `apt-get update` inside the container hangs, or vice versa:

1. **The Docker daemon** (for image pulls — env vars do NOT reach it):

   ```bash
   sudo mkdir -p /etc/systemd/system/docker.service.d
   sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
   [Service]
   Environment="HTTP_PROXY=http://proxy.example.com:3128"
   Environment="HTTPS_PROXY=http://proxy.example.com:3128"
   Environment="NO_PROXY=localhost,127.0.0.1"
   EOF
   sudo systemctl daemon-reload && sudo systemctl restart docker
   docker pull ubuntu:24.04        # verify before fetch day
   ```

2. **Your shell environment** (for host curl/wget AND for apt/pip inside containers — the v3.1 script forwards these into every container run):

   ```bash
   export HTTPS_PROXY=http://proxy.example.com:3128
   export HTTP_PROXY=http://proxy.example.com:3128
   export NO_PROXY=localhost,127.0.0.1
   ```

   Either case works — the script normalizes upper/lowercase to both. If the proxy needs auth, use `http://user:pass@proxy...` (the script redacts credentials in `BUNDLE_NOTES.md`).

The script's **[0/10] preflight** proves both paths (daemon pull + in-container apt egress) before committing to hours of downloads, and prints the full domain allowlist to hand your proxy team if it fails. For apt itself, add `Acquire::http::Proxy "http://proxy.example.com:3128";` to `/etc/apt/apt.conf.d/95proxy` so Step 1.2/1.3 work too.

## Step 2 — Run the fetch script

```bash
# proxy vars exported per Step 1.5 (skip if direct egress)
# optional overrides: MALCOLM_VER, UBUNTU_ISO_VER, GNS3_VER, ET_SURICATA_PATH,
#                     CHR_VER, OPNSENSE_VER, OPNSENSE_MIRROR, FRR_IMG
sudo -E ./r770-offline-fetch.sh       # -E preserves the proxy vars under sudo
```

(Plain `./r770-offline-fetch.sh` also works if your user is in the `docker` group.)

What to expect: a multi-GB download (Malcolm images dominate) — see `state/inventory/bundles.md` for measured cycle sizes; a few hours on a decent link. Output lands in `./bundle-YYYYMMDD/` (created wherever you run it — pick a filesystem with room, or run directly on the mounted ext4 transfer drive) with `BUNDLE_NOTES.md` regenerated each run as a log of what was fetched and skipped.

**Cutting a new bundle next to an old one? It seeds itself (v3.3).** At startup the script finds the newest sibling `bundle-*/` directory beside the one being built and hardlinks every identical version-pinned file it already holds — Ubuntu ISO, Malcolm/monitoring/gns3-node image tarballs, appliance images and definitions, the wheelhouse — instead of re-downloading (~35+ GB saved when pins haven't moved). Each reuse is logged as a `reused from bundle-...` line in `BUNDLE_NOTES.md`, hardlinks cost no disk space, and a bumped pin is fetched fresh automatically since matching is by exact filename. Deliberately **not** seeded: `apt/` (dist-upgrade security debs must be current) and `enrichment/` (fresh rules/OUI are the point of a new cycle); the wget docs mirrors also rebuild per bundle. `SEED_FROM=/path/to/bundle` picks the source explicitly; `SEED_FROM=none` disables.

**Interrupted or failed run? Just rerun it — v3.2 is resumable.** Completed downloads are skipped (a final file only exists once complete; in-flight transfers live as `.part` files and are resumed), and the heavy container steps (APT bundle, wheelhouse, image tarballs, docs mirrors) skip once done via stamps in `bundle-*/.stamps/`. Same-day reruns resume automatically (same dated directory); to resume across days use `BUNDLE_DIR=$(pwd)/bundle-YYYYMMDD sudo -E ./r770-offline-fetch.sh`; `FORCE=1` re-fetches everything. Verification still runs every pass, so cached files are re-checksummed rather than blindly trusted.

If container storage filled up mid-pull, reclaim it between attempts with `sudo docker system prune -a` — the saved tarballs in the bundle directory are independent of container storage, so pruning never loses bundle progress.

## Step 3 — Podman→Docker interop validation (only if staging with podman)

Not applicable on the chosen Docker path — tarballs are natively docker-format. If podman is ever used instead: the bundle's image tarballs come from `podman save -m` (docker-archive format); before the media crosses the gap, `docker load -i bundle-YYYYMMDD/docker/monitoring-images.tar.gz` on any Docker box and confirm every tag in `docker/monitoring-image-list.txt` appears. Record the check in `BUNDLE_NOTES.md`.

## Step 4 — Manual additions (cannot be scripted)

- [ ] **Dell** (`bundle/dell/`): from dell.com/support with service tag **`G8WFGH4`** — **perccli2** (the PERC H975i is an NVMe RAID part), BIOS + iDRAC + Broadcom NIC firmware DUPs, optionally a DSU offline repo. Keep Dell's published checksums alongside each file. Only download DUPs *newer* than the baselines in Step 0E; a firmware package is not worth the risk if it matches what is installed.
- [ ] **Note for OOB work:** this chassis has **IPMI-over-LAN disabled** (SOL enabled). Anything scripted against iDRAC must use **Redfish**, not `ipmitool -H`.
- [ ] **Licensed GNS3 appliances** (`bundle/gns3/appliances/`): the images from Step 0B per the README the script writes there. Free appliances, `.gns3a` definitions (including for the licensed appliances), and docker-node images are already fetched by the script into `gns3/`.
- [ ] **GNS3 v3 note:** gns3-server 3.x bundles its web UI and enforces authentication (admin user created on first run); appliance images are still plain files under the server's `images_path`, so pre-staging on disk remains the right offline approach.

After adding manual files, **regenerate the manifest** (the script's manifest predates them):

```bash
./scripts/r770-bundle.sh manifest bundle-YYYYMMDD
```

(The script excludes resume bookkeeping — `.stamps/` and any leftover `.part` partials — from the manifest, and refuses to run while a `.part` file is present: that means an incomplete download — rerun the fetch script before packing.)

## Step 5 — Verify on staging (trust is established here)

The gapped side can only verify what the manifest asserts, so signature checks happen now:

```bash
cd bundle-YYYYMMDD
# Ubuntu ISO: GPG-verify the checksum file, then the ISO against it
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 0x843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --verify isos/SHA256SUMS.gpg isos/SHA256SUMS
( cd isos && grep live-server SHA256SUMS | sha256sum -c - )
../scripts/r770-bundle.sh verify . --strict   # full-bundle integrity gate, not a hand-rolled sha256sum -c
```

Exit **0** PASS · **2** PASS WITH WARNINGS (disposition each before the media moves) · **1** FAIL, do not import.

(Behind the proxy, gpg's keyserver fetch may need `--keyserver-options http-proxy=$HTTPS_PROXY`.) The script already sha256-verifies OPNsense and Alpine against their published checksum files at fetch time.

Also confirm in `BUNDLE_NOTES.md`: no unresolved `WARN` lines (ET rules 410, VyOS tag resolution, appliance fetches, oui.txt failures, docs mirrors), versions recorded.

## Step 6 — Pack, transfer, import

1. Copy the bundle to the ext4 drive; `./scripts/r770-bundle.sh verify <path-on-media>/bundle-YYYYMMDD --strict` **from the media** before it leaves staging.
2. AV/content scan per site policy (Step 0D).
3. On the R770: manifest check first, then import in the order in `BUNDLE_NOTES.md` (local apt repo → `docker load` of Malcolm/monitoring/gns3-node tarballs → wheelhouse/definitions/appliances/images/enrichment/docs into place), per supply plan §3.
4. **Keep the previous bundle** until this one validates — that's the rollback.
5. Log the cycle in the config repo (`inventory/bundles.md`): date, versions, hashes, who carried it.

---

## Refresh cadence and pin review

**Decided cadence: ad-hoc** (initial build; no fixed schedule). **Pin policy (2026-09-04): bump moved pins at cut time** rather than shipping stale — nothing is deployed to migrate, and an ad-hoc bundle may sit for months. Grafana is the standing exception. Accepted, documented risk: host security updates, ET rules, and OUI data only refresh when a new bundle is cut. When cutting a refresh bundle, review the pin block at the top of `scripts/r770-offline-fetch.sh` — it is the sole owner of current pin values (see `OWNERS.md`) — against each pin's upstream source:

| Pin | Where to check |
|---|---|
| `MALCOLM_VER` | github.com/idaholab/Malcolm/releases |
| `UBUNTU_ISO_VER` | releases.ubuntu.com/noble |
| `GNS3_VER` | pypi.org/project/gns3-server |
| `CHR_VER` | mikrotik.com/download/chr |
| `OPNSENSE_VER` | opnsense.org/download |
| `FRR_IMG` | quay.io/repository/frrouting/frr?tab=tags |
| `ET_SURICATA_PATH` | rules.emergingthreats.net (matches noble's Suricata 7.0.x; ET returns 410 when a branch retires — script checks) |
| Monitoring tags (prometheus, alertmanager, blackbox, cadvisor, grafana-oss) | upstream GitHub releases (grafana-oss is held below 13.x — see the pin block for the standing-exception note) |

VyOS rolling and Alpine are resolved to latest automatically at build time (GitHub API / `latest-releases.yaml`).

## Known risks

| Risk | Mitigation |
|---|---|
| Proxy configured in one place but not the other (daemon vs. containers) | Script [0/10] preflight fails fast with guidance; runbook §1.5 configures both |
| Proxy blocks a needed domain mid-run | Preflight error prints the full allowlist to hand the proxy team; WARN lines catch per-item failures |
| ~~SELinux denials writing to bind mounts~~ | **No longer applicable** — Ubuntu uses AppArmor, not SELinux. Removing this failure mode was part of the reason for the host change. The script's `:Z` labels are harmless no-ops here |
| `/var` fills mid-pull | Step 1.1 check (and confirm the root FS was grown to the full virtual disk); prune between runs with `docker system prune -a`. On a VM the cheapest fix is to grow the disk |
| Rules/OUI silently stale (ad-hoc cadence) | WARN lines in `BUNDLE_NOTES.md`; treat unresolved WARNs as a gate in Step 5; staleness is an accepted, documented risk |
| Vendor appliance images exceed media | Step 0B inventory sizes the media before fetch day — **still open, and the one genuinely unbounded item in this cycle** |
| Docker inside an LXC container | Step 1.0 — use a VM. `systemd-detect-virt` must not say `lxc` |
| Grafana 12→13 major jump breaks dashboards | Held at 12.1.0; upgrade deliberately in its own cycle |

## Success criteria

- [ ] Preflight [0/10] passes (daemon pull + in-container egress, through the proxy if present)
- [ ] Bundle builds end-to-end on the Ubuntu 24.04 staging VM with zero unresolved WARNs in `BUNDLE_NOTES.md`
- [ ] Manual items (Dell, licensed appliances) present and covered by the regenerated manifest
- [ ] Media verifies (`r770-bundle.sh verify`) after copy, and again on the R770 before any import
- [ ] Previous bundle retained until the new one validates on the R770
