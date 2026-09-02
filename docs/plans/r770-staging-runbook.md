# R770 Offline Dependency Prep — Staging Runbook (RHEL 8)

**Companion to:** `r770-offline-supply.md` (the model/rationale) · `r770-offline-fetch.sh` v3.3 (the tool; resumable, seeds new bundles from previous ones) · `r770-dependency-manifest.md` (authoritative dependency list + decisions record) · `r770-network-lab-buildout.md`
**Date:** 2026-08-31 (updated for v3.1: Docker-on-RHEL8 chosen, proxy support, GNS3 appliance fetching, GeoIP descoped)
**Staging host:** RHEL 8 box with internet access (direct or via corporate proxy), preparing bundles for the air-gapped Ubuntu 24.04 R770.
**Verified against:** Malcolm v26.07.1 (current), Ubuntu 24.04.4 (current point release), gns3-server 3.0.6, CHR 7.21.5, OPNsense 26.7, FRR 10.6.1, CirrOS 0.6.3, ET Open suricata-7.0 path.

Everything heavy runs inside containers (`ubuntu:24.04`, `python:3.12-slim`), so a RHEL host builds Ubuntu artifacts correctly — the host only needs a container runtime, curl, gpg, unzip, wget, and disk.

---

## Step 0 — Prerequisites (decisions as of 2026-08-31 — see manifest §0)

- [x] **A. MaxMind GeoLite2** — **DESCOPED.** No account; Malcolm runs without geo tagging. v2 of the fetch script has the working fetch block if this is ever reversed.
- [ ] **B. GNS3 vendor appliance inventory** — **still open.** Free set (VyOS, CHR, OPNsense, Alpine, docker nodes) is now scripted; the licensed list (Cisco IOSv/IOSvL2/IOL/CSR/ASAv, FortiGate, PA VM-Series — and pfSense CE, which now requires a Netgate account) needs inventorying against your entitlements. Usually the largest category (10–100+ GB) and sizes the media.
- [x] **C. Supply strategy** — curated bundle (decided). Revisit apt-mirror only if unplanned `apt install` on the gapped box becomes recurring.
- [x] **D. Transfer media** — 256 GB+ USB/NVMe, ext4 (decided). Site policy for media scanning/signing still to confirm (Step 6 must match it).
- [ ] **E. Dell service tag** of the R770 at hand, for the firmware downloads in Step 4.
- [ ] **F. Proxy details** if the staging host egresses through one: proxy URL (+credentials if any), and confirm the allowlist covers the domains printed by the script's preflight failure message (registries, Ubuntu archives, download.docker.com, PyPI, GitHub, and the appliance mirrors).

## Step 1 — Prepare the RHEL 8 staging host

**1.1 Disk space.** Budget ≥150 GB free total: images stored uncompressed under container storage (30–40 GB compressed expands to 60–80+ GB) plus the bundle output.

```bash
df -h /var "$(pwd)"      # docker's storage lives in /var/lib/docker
```

On RHEL's default partitioning, `/` (holding `/var`) is small and the space is in `/home`. If `/var` is tight, either move docker's `data-root` (`/etc/docker/daemon.json`) to a filesystem with room, or free space first.

**1.2 Container runtime — Docker CE (decided 2026-08-31).** Third-party repo, outside Red Hat support, but runs the script identically to the original:

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
```

Note: docker-ce conflicts with the `container-tools` module packages — don't install both. (Rootful podman remains a supported fallback; the script auto-detects it and handles its differences, but then re-validate tarball interop per Step 3.)

**1.3 Host tools:**

```bash
sudo dnf -y install curl gnupg2 unzip wget pigz
for t in curl gpg sha256sum tar unzip wget; do command -v $t; done
```

`pigz` is optional but worthwhile — the script auto-uses it to parallelize the ~30 GB compression step (stock single-threaded gzip is the wall-clock bottleneck). `wget` is required for the docs mirrors (skipped with a WARN if absent).

**1.5 Proxy configuration (if the staging host egresses through one).** A proxy must be configured in **two places** — this is the classic failure mode where the image pull works but `apt-get update` inside the container hangs, or vice versa:

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

The script's **[0/10] preflight** proves both paths (daemon pull + in-container apt egress) before committing to hours of downloads, and prints the full domain allowlist to hand your proxy team if it fails. Also configure dnf's proxy for Step 1.2/1.3 itself: `proxy=http://proxy.example.com:3128` in `/etc/dnf/dnf.conf`.

## Step 2 — Run the fetch script

```bash
# proxy vars exported per Step 1.5 (skip if direct egress)
# optional overrides: MALCOLM_VER, UBUNTU_ISO_VER, GNS3_VER, ET_SURICATA_PATH,
#                     CHR_VER, OPNSENSE_VER, OPNSENSE_MIRROR, FRR_IMG
sudo -E ./r770-offline-fetch.sh       # -E preserves the proxy vars under sudo
```

(Plain `./r770-offline-fetch.sh` also works if your user is in the `docker` group.)

What to expect: ~45–65 GB downloaded (Malcolm images dominate); a few hours on a decent link. Output lands in `./bundle-YYYYMMDD/` (created wherever you run it — pick a filesystem with room, or run directly on the mounted ext4 transfer drive) with `BUNDLE_NOTES.md` regenerated each run as a log of what was fetched and skipped.

**Cutting a new bundle next to an old one? It seeds itself (v3.3).** At startup the script finds the newest sibling `bundle-*/` directory beside the one being built and hardlinks every identical version-pinned file it already holds — Ubuntu ISO, Malcolm/monitoring/gns3-node image tarballs, appliance images and definitions, the wheelhouse — instead of re-downloading (~35+ GB saved when pins haven't moved). Each reuse is logged as a `reused from bundle-...` line in `BUNDLE_NOTES.md`, hardlinks cost no disk space, and a bumped pin is fetched fresh automatically since matching is by exact filename. Deliberately **not** seeded: `apt/` (dist-upgrade security debs must be current) and `enrichment/` (fresh rules/OUI are the point of a new cycle); the wget docs mirrors also rebuild per bundle. `SEED_FROM=/path/to/bundle` picks the source explicitly; `SEED_FROM=none` disables.

**Interrupted or failed run? Just rerun it — v3.2 is resumable.** Completed downloads are skipped (a final file only exists once complete; in-flight transfers live as `.part` files and are resumed), and the heavy container steps (APT bundle, wheelhouse, image tarballs, docs mirrors) skip once done via stamps in `bundle-*/.stamps/`. Same-day reruns resume automatically (same dated directory); to resume across days use `BUNDLE_DIR=$(pwd)/bundle-YYYYMMDD sudo -E ./r770-offline-fetch.sh`; `FORCE=1` re-fetches everything. Verification still runs every pass, so cached files are re-checksummed rather than blindly trusted.

If container storage filled up mid-pull, reclaim it between attempts with `sudo docker system prune -a` — the saved tarballs in the bundle directory are independent of container storage, so pruning never loses bundle progress.

## Step 3 — Podman→Docker interop validation (only if staging with podman)

Not applicable on the chosen Docker path — tarballs are natively docker-format. If podman is ever used instead: the bundle's image tarballs come from `podman save -m` (docker-archive format); before the media crosses the gap, `docker load -i bundle-YYYYMMDD/docker/monitoring-images.tar.gz` on any Docker box and confirm every tag in `docker/monitoring-image-list.txt` appears. Record the check in `BUNDLE_NOTES.md`.

## Step 4 — Manual additions (cannot be scripted)

- [ ] **Dell** (`bundle/dell/`): from dell.com/support with the service tag — perccli/perccli2, BIOS + iDRAC + Broadcom NIC firmware DUPs, optionally a DSU offline repo. Keep Dell's published checksums alongside each file.
- [ ] **Licensed GNS3 appliances** (`bundle/gns3/appliances/`): the images from Step 0B per the README the script writes there. Free appliances, `.gns3a` definitions (including for the licensed appliances), and docker-node images are already fetched by the script into `gns3/`.
- [ ] **GNS3 v3 note:** gns3-server 3.x bundles its web UI and enforces authentication (admin user created on first run); appliance images are still plain files under the server's `images_path`, so pre-staging on disk remains the right offline approach.

After adding manual files, **regenerate the manifest** (the script's manifest predates them):

```bash
cd bundle-YYYYMMDD && find . -type f ! -name MANIFEST.sha256 ! -name '*.part' ! -path './.stamps/*' -print0 | xargs -0 sha256sum > MANIFEST.sha256
```

(The exclusions keep resume bookkeeping — `.stamps/` and any leftover `.part` partials — out of the manifest; a `.part` file present at this stage means an incomplete download: rerun the script before packing.)

## Step 5 — Verify on staging (trust is established here)

The gapped side can only verify what the manifest asserts, so signature checks happen now:

```bash
cd bundle-YYYYMMDD
# Ubuntu ISO: GPG-verify the checksum file, then the ISO against it
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 0x843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --verify isos/SHA256SUMS.gpg isos/SHA256SUMS
( cd isos && grep live-server SHA256SUMS | sha256sum -c - )
sha256sum -c MANIFEST.sha256          # full-bundle self-check
```

(Behind the proxy, gpg's keyserver fetch may need `--keyserver-options http-proxy=$HTTPS_PROXY`.) The script already sha256-verifies OPNsense and Alpine against their published checksum files at fetch time.

Also confirm in `BUNDLE_NOTES.md`: no unresolved `WARN` lines (ET rules 410, VyOS tag resolution, appliance fetches, oui.txt failures, docs mirrors), versions recorded.

## Step 6 — Pack, transfer, import

1. Copy the bundle to the ext4 drive; `sha256sum -c MANIFEST.sha256` **from the media** before it leaves staging.
2. AV/content scan per site policy (Step 0D).
3. On the R770: manifest check first, then import in the order in `BUNDLE_NOTES.md` (local apt repo → `docker load` of Malcolm/monitoring/gns3-node tarballs → wheelhouse/definitions/appliances/images/enrichment/docs into place), per supply plan §3.
4. **Keep the previous bundle** until this one validates — that's the rollback.
5. Log the cycle in the config repo (`inventory/bundles.md`): date, versions, hashes, who carried it.

---

## Refresh cadence and pin review

**Decided cadence: ad-hoc** (initial build; no fixed schedule). Accepted, documented risk: host security updates, ET rules, and OUI data only refresh when a new bundle is cut. When cutting a refresh bundle, review the pins at the top of the script:

| Pin | Current (2026-08-31) | Where to check |
|---|---|---|
| `MALCOLM_VER` | 26.07.1 | github.com/idaholab/Malcolm/releases |
| `UBUNTU_ISO_VER` | 24.04.4 | releases.ubuntu.com/noble |
| `GNS3_VER` | 3.0.6 | pypi.org/project/gns3-server |
| `CHR_VER` | 7.21.5 | mikrotik.com/download/chr |
| `OPNSENSE_VER` | 26.7 | opnsense.org/download |
| `FRR_IMG` | quay.io/frrouting/frr:10.6.1 | quay.io/repository/frrouting/frr?tab=tags |
| `ET_SURICATA_PATH` | suricata-7.0 (matches noble's Suricata 7.0.x; ET returns 410 when a branch retires — script checks) | rules.emergingthreats.net |
| Monitoring tags | prometheus v3.14.0 · alertmanager v0.33.0 · blackbox v0.28.0 · cadvisor v0.57.0 · grafana-oss 12.1.0 (13.x exists — review before jumping majors) | upstream GitHub releases |

VyOS rolling and Alpine are resolved to latest automatically at build time (GitHub API / `latest-releases.yaml`).

## Known risks

| Risk | Mitigation |
|---|---|
| Proxy configured in one place but not the other (daemon vs. containers) | Script [0/10] preflight fails fast with guidance; runbook §1.5 configures both |
| Proxy blocks a needed domain mid-run | Preflight error prints the full allowlist to hand the proxy team; WARN lines catch per-item failures |
| SELinux denials writing to bind mounts | Script uses `:Z` labels; point output at a dedicated bundle tree only (relabeling is recursive) |
| `/var` fills mid-pull on default RHEL partitioning | Step 1.1 check; relocate docker `data-root` or prune between runs |
| Rules/OUI silently stale (ad-hoc cadence) | WARN lines in `BUNDLE_NOTES.md`; treat unresolved WARNs as a gate in Step 5; staleness is an accepted, documented risk |
| Vendor appliance images exceed media | Step 0B inventory sizes the media before fetch day |
| Grafana 12→13 major jump breaks dashboards | Held at 12.1.0; upgrade deliberately in its own cycle |

## Success criteria

- [ ] Preflight [0/10] passes (daemon pull + in-container egress, through the proxy if present)
- [ ] Bundle builds end-to-end on the RHEL 8 host with zero unresolved WARNs in `BUNDLE_NOTES.md`
- [ ] Manual items (Dell, licensed appliances) present and covered by the regenerated manifest
- [ ] Media verifies (`sha256sum -c`) after copy, and again on the R770 before any import
- [ ] Previous bundle retained until the new one validates on the R770
