#!/usr/bin/env bash
#
# r770-offline-fetch.sh — build the air-gap supply bundle for the R770 lab server.
#
# v3.5 (2026-09-08): cadvisor REGISTRY fix (not just a tag bump).
#   The bundle-1 fetch failed at [4/10] with:
#     failed to resolve reference "gcr.io/cadvisor/cadvisor:v0.60.5": not found
#   gcr.io/cadvisor/cadvisor stopped publishing at v0.55.1. The PREVIOUS pin
#   (v0.57.0) 404s there too, so this was already broken before the 2026-09-04
#   bump -- the bundle would have failed here either way. cadvisor images now
#   live at ghcr.io/google/cadvisor (v0.57.0 and v0.60.5 both resolve).
#   Lesson recorded: a GitHub release existing does NOT mean an image was
#   published at that tag. Pin review must verify the image REFERENCE
#   (docker manifest inspect), not the version number. All 15 image
#   references were re-verified this way before the rerun; only this one
#   was broken.
#
# v3.4 (2026-09-04): pin bumps for bundle-1, after a full upstream review
#   (evidence: state/inventory/pin-review-2026-09-04.md, operator approved):
#     - MALCOLM_VER  26.07.1 -> 26.08.0  (23 images, release assets verified)
#     - alertmanager v0.33.0 -> v0.34.0
#     - cadvisor     v0.57.0 -> v0.60.5
#     - FRR_IMG      10.6.1  -> 10.7.1
#   grafana-oss stays HELD at 12.1.0 (13.2.1 is current) until dashboards are
#   reviewed. Policy of record: bump moved pins at cut time rather than ship
#   stale, since ad-hoc cadence means a bundle may sit for months.
#   Staging host also changed: RHEL 8 -> Ubuntu 24.04 Proxmox VM + Docker CE.
#   The script is unchanged by that — everything heavy already runs in
#   ubuntu:24.04 / python:3.12-slim containers.
#
# v3.3 (2026-08-31): cross-bundle seeding — a NEW bundle reuses a previous one:
#   - At startup the script finds the newest sibling bundle-*/ directory next to
#     the one being built (or SEED_FROM=/path/to/bundle to pick explicitly;
#     SEED_FROM=none disables). Every identical version-pinned file it already
#     holds — Ubuntu ISO, Malcolm/monitoring/gns3-node image tarballs, appliance
#     images, wheelhouse, .gns3a defs — is hardlinked into the new bundle
#     (copy fallback across filesystems) instead of re-downloaded, and each
#     reuse is logged as a "reused from bundle-..." line in BUNDLE_NOTES.md.
#   - Hardlinks cost no disk space and survive deleting the old bundle.
#   - Deliberately NOT seeded (refresh-per-cycle by design): apt/ (dist-upgrade
#     security debs must be current) and enrichment/ (rules/OUI staleness is the
#     point of a new bundle); the wget docs mirrors are rebuilt per bundle.
#   - Version pins are the safety: seeding matches exact relative path + filename,
#     so a bumped pin (new Malcolm, new CHR) is fetched fresh automatically.
#     VyOS/Alpine (resolved-to-latest) seed whatever version the old bundle holds,
#     consistent with the resume rule; FORCE=1 disables seeding entirely.
#
# v3.2 (2026-08-31): resumable — safe to rerun after a failure or cancel:
#   - Every direct download goes through fetch(): files download to <name>.part
#     and are renamed only on success, so an existing final file means COMPLETE
#     and is skipped on rerun; leftover .part files are resumed (curl -C -) when
#     the server supports ranges, with a clean-restart fallback when it doesn't.
#   - Heavy container steps (APT bundle, wheelhouse, docs mirrors) leave stamps
#     in $BUNDLE/.stamps/ and are skipped once complete. Image tarballs
#     (Malcolm, monitoring, gns3 nodes) skip when the tarball already exists —
#     ctr_save also writes .part-then-rename so a killed save can't leave a
#     truncated tarball that later masquerades as complete.
#   - Rerunning the same day resumes automatically (same bundle dir). To resume
#     a previous day's bundle:  BUNDLE_DIR=/path/bundle-YYYYMMDD ./r770-offline-fetch.sh
#   - FORCE=1 re-downloads/rebuilds everything, ignoring stamps and cached files.
#   - Verification still runs every pass (cached ISO etc. are re-checksummed);
#     BUNDLE_NOTES.md is regenerated fresh each run; the manifest is always
#     rebuilt at the end, so a resumed bundle gets a correct final manifest.
#
# v3.1 (2026-08-31): corporate proxy support:
#   - Set HTTP_PROXY / HTTPS_PROXY / NO_PROXY (either case) before running; the
#     script normalizes both cases, exports them for host curl/wget, and passes
#     them into every container run (apt + pip inside containers need them too).
#   - The DOCKER DAEMON needs its own proxy config to pull images — env vars do
#     NOT reach it. One-time setup (see also r770-staging-runbook.md §1.5):
#       sudo mkdir -p /etc/systemd/system/docker.service.d
#       sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
#       [Service]
#       Environment="HTTP_PROXY=http://proxy.example.com:3128"
#       Environment="HTTPS_PROXY=http://proxy.example.com:3128"
#       Environment="NO_PROXY=localhost,127.0.0.1"
#       EOF
#       sudo systemctl daemon-reload && sudo systemctl restart docker
#   - NEW [0/10] preflight: pulls ubuntu:24.04 and runs apt-get update inside it,
#     failing fast with guidance instead of hanging mid-bundle.
#   - Running under sudo? Use `sudo -E` so the proxy vars survive.
#
# v3 (2026-08-31): implements the decisions recorded in r770-dependency-manifest.md:
#   - Staging host confirmed: RHEL 8 + Docker Engine (podman path kept but unused)
#   - GeoIP/MaxMind DESCOPED (no account) — block removed; recover it from v2 if
#     geo enrichment is ever wanted
#   - NEW [6/10] GNS3 appliances: .gns3a definitions from the GNS3 registry
#     (free + licensed-appliance definitions), free images fetched directly
#     (VyOS rolling via GitHub API, MikroTik CHR 7.21.5, OPNsense 26.7,
#     Alpine virt via latest-releases.yaml), GNS3 docker-node images saved
#     (alpine, debian, netshoot, FRR)
#   - NEW [8/10] best-effort offline docs mirrors (malcolm.fyi, Zeek, GNS3 repo
#     docs, Wireshark user guide)
#   - Licensed-image manual checklist written to gns3/appliances/README.txt
#     (Cisco IOSv/IOSvL2/IOL/CSR/Cat8kv/ASAv, FortiGate, PA VM-Series, pfSense CE
#     — pfSense now requires a Netgate account, OPNsense is the scripted alternative)
#   - Pins re-verified 2026-08-31: Malcolm 26.07.1, Ubuntu 24.04.4,
#     gns3-server 3.0.6 all still current
#
# RUN THIS ON AN INTERNET-CONNECTED STAGING HOST — NEVER on the air-gapped server.
# Staging host: RHEL 8 + Docker Engine (or Ubuntu; rootful podman also works).
# Requirements:
#   - Docker Engine (chosen), or rootful podman 4.9+ (then run with sudo)
#   - ~150 GB free across container storage (/var/lib/docker) and the bundle
#     output directory. Check: df -h /var "$(pwd)"
#   - curl, gpg, sha256sum, unzip, wget (docs mirrors; skipped with a WARN if absent)
#
# Output: ./bundle-YYYYMMDD/  with MANIFEST.sha256 and BUNDLE_NOTES.md
#
# Manual steps it will REMIND you about (cannot be scripted):
#   - Dell firmware/perccli downloads (dell.com, per service tag)
#   - Licensed GNS3 vendor appliance images (see gns3/appliances/README.txt)
#
# Companion docs: r770-dependency-manifest.md (authoritative dependency list),
#                 r770-staging-runbook.md, r770-offline-supply.md,
#                 r770-network-lab-buildout.md

set -euo pipefail

# ── pins: review each refresh cycle ──────────────────────────────────────────
MALCOLM_VER="${MALCOLM_VER:-26.08.0}"          # check https://github.com/idaholab/Malcolm/releases
UBUNTU_ISO_VER="${UBUNTU_ISO_VER:-24.04.4}"    # check https://releases.ubuntu.com/noble/
GNS3_VER="${GNS3_VER:-3.0.6}"                  # check https://pypi.org/project/gns3-server/
ET_SURICATA_PATH="${ET_SURICATA_PATH:-suricata-7.0}"  # noble ships Suricata 7.0.x; ET returns 410 on retired paths
CHR_VER="${CHR_VER:-7.21.5}"                   # check https://mikrotik.com/download/chr
OPNSENSE_VER="${OPNSENSE_VER:-26.7}"           # check https://opnsense.org/download/
OPNSENSE_MIRROR="${OPNSENSE_MIRROR:-https://mirrors.dotsrc.org/opnsense/releases/mirror}"
FRR_IMG="${FRR_IMG:-quay.io/frrouting/frr:10.7.1}"    # check https://quay.io/repository/frrouting/frr?tab=tags

MONITOR_IMAGES=(
    "docker.io/prom/prometheus:v3.14.0"
    "docker.io/prom/alertmanager:v0.34.0"
    "docker.io/prom/blackbox-exporter:v0.28.0"
    "docker.io/grafana/grafana-oss:12.1.0"     # 13.x is current stable; held at 12.x — review dashboards before jumping majors
    "ghcr.io/google/cadvisor:v0.60.5"   # gcr.io/cadvisor/cadvisor is ABANDONED at v0.55.1 — see below
    "docker.io/library/nginx:stable"
    "docker.io/library/registry:2"
    "docker.io/squidfunk/mkdocs-material:latest"  # pin a tag once you standardize
)

# GNS3 docker-node images (used as container nodes inside topologies)
GNS3_NODE_IMAGES=(
    "docker.io/library/alpine:latest"
    "docker.io/library/debian:stable-slim"
    "docker.io/nicolaka/netshoot:latest"
    "$FRR_IMG"
)

# .gns3a appliance definitions to grab from the GNS3 registry (free even when
# the images are licensed). Missing names WARN, never fail.
GNS3A_DEFS=(
    vyos mikrotik-chr opnsense frr alpine-linux tinycore-linux openwrt
    cisco-iosv cisco-iosvl2 cisco-asav fortigate pan-vm-fw
)

UBUNTU_BUILD_IMG="docker.io/library/ubuntu:24.04"
PYTHON_BUILD_IMG="docker.io/library/python:3.12-slim"

# The manifest is generated by its own tested script, which is also copied INTO
# the bundle so the air-gapped R770 can run `./r770-bundle.sh verify .` without a
# separate transfer. Checked here, at startup, rather than at [10/10] -- the
# alternative is discovering it after hours of downloading.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_TOOL="$SCRIPT_DIR/r770-bundle.sh"
[ -x "$BUNDLE_TOOL" ] || {
    echo "FATAL: $BUNDLE_TOOL not found or not executable — it ships alongside this script" >&2
    exit 1
}
# ─────────────────────────────────────────────────────────────────────────────

TS="$(date +%Y%m%d)"
B="${BUNDLE_DIR:-$(pwd)/bundle-${TS}}"
mkdir -p "$B"/{apt,docker,malcolm,gns3/{wheelhouse,appliances,definitions,docker-nodes},isos,images,enrichment,dell,keys,docs} "$B/.stamps"
if [ -n "$(ls -A "$B/.stamps" 2>/dev/null)" ]; then
    echo "NOTE: resuming previous run in $B — completed items will be skipped (FORCE=1 to redo everything)"
fi
NOTES="$B/BUNDLE_NOTES.md"
echo "# R770 offline bundle ${TS}" > "$NOTES"
note() { echo "- $*" >> "$NOTES"; echo ">> $*"; }

# ── container runtime detection (docker or podman) ───────────────────────────
CTR=""
if command -v docker >/dev/null 2>&1 && ! docker --version 2>/dev/null | grep -qi podman; then
    CTR="docker"
elif command -v podman >/dev/null 2>&1; then
    CTR="podman"
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: with podman, run this script with sudo (rootful podman gives"
        echo "       docker-identical ownership/semantics and uses /var/lib/containers)."
        exit 1
    fi
else
    echo "ERROR: need docker or podman on the staging host."
    echo "  RHEL 8 Docker: https://docs.docker.com/engine/install/  (chosen staging setup)"
    exit 1
fi
note "Staging container runtime: $CTR ($($CTR --version 2>/dev/null | head -1))"

# multi-image save: podman needs --multi-image-archive for docker-archive format.
# Writes .part then renames, so a killed save never leaves a truncated tarball
# that a later resume would mistake for complete.
ctr_save() {  # ctr_save <output.tar.gz> <image...>
    local out="$1"; shift
    if [ "$CTR" = "podman" ]; then
        $CTR save --multi-image-archive "$@" | $GZ > "${out}.part"
    else
        $CTR save "$@" | $GZ > "${out}.part"
    fi
    mv "${out}.part" "$out"
}
GZ="$(command -v pigz || command -v gzip)"   # pigz parallelizes the ~30 GB compress step

# ── resume helpers ───────────────────────────────────────────────────────────
FORCE="${FORCE:-0}"    # FORCE=1 ignores cached files/stamps and re-fetches everything
have()       { [ "$FORCE" = "0" ] && [ -s "$1" ]; }          # final file present ⇒ complete
stamped()    { [ "$FORCE" = "0" ] && [ -f "$B/.stamps/$1" ]; }
stamp_done() { touch "$B/.stamps/$1"; }

fetch() {  # fetch <output> <url> [extra curl args...] — seed from prev bundle, skip if complete, resume .part
    local out="$1" url="$2"; shift 2
    seed "$out"
    if have "$out"; then echo "   [skip] $(basename "$out") already present"; return 0; fi
    if ! curl -fL --retry 3 -C - "$@" -o "${out}.part" "$url"; then
        rm -f "${out}.part"     # server may not support ranges — one clean restart
        curl -fL --retry 3 "$@" -o "${out}.part" "$url" || { rm -f "${out}.part"; return 1; }
    fi
    mv "${out}.part" "$out"
}

# ── cross-bundle seeding: reuse completed files from a previous bundle dir ───
# A new (empty) bundle scans for the newest sibling bundle-*/ next to it and
# hardlinks identical version-pinned files in instead of re-downloading them.
# apt/ and enrichment/ are exempt — those must be fresh each cycle.
PREV_BUNDLE=""
if [ "$FORCE" = "0" ] && [ "${SEED_FROM:-auto}" != "none" ]; then
    if [ -n "${SEED_FROM:-}" ] && [ "$SEED_FROM" != "auto" ]; then
        PREV_BUNDLE="${SEED_FROM%/}"
        if [ ! -d "$PREV_BUNDLE" ]; then
            echo "ERROR: SEED_FROM=$PREV_BUNDLE is not a directory"; exit 1
        fi
    else
        PREV_BUNDLE="$(find "$(dirname "$B")" -maxdepth 1 -type d -name 'bundle-*' \
            ! -path "$B" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    fi
fi
if [ -n "$PREV_BUNDLE" ]; then
    note "Seeding enabled: version-pinned files reused from $(basename "$PREV_BUNDLE") — each reuse logged below (apt/ + enrichment/ always fetched fresh; SEED_FROM=none disables)"
fi

seed() {  # seed <abs path under $B> — link/copy the file from PREV_BUNDLE if it has it
    local out="$1" rel src
    if [ -z "$PREV_BUNDLE" ] || have "$out"; then return 0; fi
    rel="${out#"$B"/}"
    case "$rel" in apt/*|enrichment/*) return 0 ;; esac   # refresh-per-cycle content
    src="$PREV_BUNDLE/$rel"
    if [ -s "$src" ]; then
        mkdir -p "$(dirname "$out")"
        if ln "$src" "$out" 2>/dev/null || cp -p "$src" "$out"; then
            note "reused from $(basename "$PREV_BUNDLE"): $rel ($(du -h "$out" | cut -f1))"
        fi
    fi
    return 0
}

seed_glob() {  # seed_glob <glob relative to bundle root> — seed every match
    local f
    if [ -z "$PREV_BUNDLE" ]; then return 0; fi
    # shellcheck disable=SC2231
    for f in "$PREV_BUNDLE"/$1; do
        if [ -e "$f" ]; then seed "$B/${f#"$PREV_BUNDLE"/}"; fi
    done
    return 0
}

# ── proxy handling ───────────────────────────────────────────────────────────
# Normalize either case into both, export for host curl/wget, and build the
# env-injection list for container runs (apt/pip inside containers need these).
HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1}}"
PROXY_ENV=()
if [ -n "${HTTP_PROXY}${HTTPS_PROXY}" ]; then
    export HTTP_PROXY HTTPS_PROXY NO_PROXY
    export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" no_proxy="$NO_PROXY"
    for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
        if [ -n "${!v}" ]; then PROXY_ENV+=(-e "$v=${!v}"); fi
    done
    # redact any user:pass@ before logging
    note "Proxy in use: $(echo "${HTTPS_PROXY:-$HTTP_PROXY}" | sed -E 's#//[^/@]*@#//***:***@#')"
    note "Reminder: the docker daemon needs its own proxy config (systemd drop-in) to pull images — env vars do not reach it"
else
    note "No proxy configured (direct egress assumed)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 0. Preflight — prove the daemon can pull AND containers have egress,
#    before committing to hours of downloads. Tests the exact path step 1 uses.
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [0/10] Preflight: registry pull + container egress ===="
if ! timeout 300 $CTR run --rm "${PROXY_ENV[@]}" "$UBUNTU_BUILD_IMG" \
        bash -ec "apt-get update -qq" >/dev/null 2>&1; then
    cat <<'PREFLIGHT_EOF'
ERROR: preflight failed. One of two proxy problems, in order of likelihood:

  1. The docker daemon cannot pull ubuntu:24.04 (daemon has no proxy config).
     Env vars do NOT reach the daemon. Fix with a systemd drop-in:
       sudo mkdir -p /etc/systemd/system/docker.service.d
       sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
       [Service]
       Environment="HTTP_PROXY=http://proxy.example.com:3128"
       Environment="HTTPS_PROXY=http://proxy.example.com:3128"
       Environment="NO_PROXY=localhost,127.0.0.1"
       EOF
       sudo systemctl daemon-reload && sudo systemctl restart docker
     Verify:  docker pull ubuntu:24.04

  2. The pull worked but apt-get update inside the container cannot reach
     archive.ubuntu.com — the proxy env vars were not set before running this
     script. Export HTTPS_PROXY/HTTP_PROXY (and rerun with sudo -E if using
     sudo), then rerun; this script forwards them into every container.

  Also confirm the proxy allowlists: archive.ubuntu.com, security.ubuntu.com,
  download.docker.com, registry-1.docker.io, auth.docker.io,
  production.cloudflare.docker.com, ghcr.io, gcr.io, quay.io, pypi.org,
  files.pythonhosted.org, github.com, objects.githubusercontent.com,
  raw.githubusercontent.com, releases.ubuntu.com, cloud-images.ubuntu.com,
  download.cirros-cloud.net, download.mikrotik.com, mirrors.dotsrc.org,
  dl-cdn.alpinelinux.org, standards-oui.ieee.org, publicsuffix.org,
  www.iana.org, rules.emergingthreats.net, malcolm.fyi, docs.zeek.org,
  www.wireshark.org
PREFLIGHT_EOF
    exit 1
fi
note "Preflight OK: daemon pull + in-container apt egress verified"

# ═════════════════════════════════════════════════════════════════════════════
# 1. Curated APT bundle — resolved in a clean ubuntu:24.04 container
#    (:Z relabels the mount for SELinux hosts; ignored where SELinux is absent)
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [1/10] APT package bundle ===="
PKGS=(
    # virtualization
    qemu-kvm qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients
    virtinst ovmf bridge-utils cpu-checker guestfs-tools
    # optional-but-cached switching
    openvswitch-switch
    # host services
    nginx dnsmasq chrony auditd ufw lvm2 xfsprogs easy-rsa restic
    prometheus-node-exporter
    # storage / hw
    smartmontools nvme-cli ipmitool edac-utils lm-sensors
    # networking / capture / perf
    ethtool numactl sysstat tcpdump tshark tcpreplay iperf3 fio stress-ng
    mtr-tiny traceroute dnsutils net-tools nmap
    # admin / tooling
    git jq tmux htop iotop curl wget vim lsof strace unzip zip
    python3-venv python3-pip dpkg-dev rsync
    # kernel/security update tracking
    linux-generic-hwe-24.04
)
if stamped 01-apt.done; then
    note "APT bundle: skipped — complete in a previous run ($(ls "$B/apt"/*.deb 2>/dev/null | wc -l) debs cached; FORCE=1 to rebuild)"
else
$CTR run --rm "${PROXY_ENV[@]}" -v "$B/apt:/out:Z" "$UBUNTU_BUILD_IMG" bash -ec "
    apt-get update -qq
    apt-get -y --download-only -o Dir::Cache::archives=/out dist-upgrade -qq
    apt-get -y --download-only -o Dir::Cache::archives=/out install ${PKGS[*]} -qq
    # docker engine debs from docker's own repo
    apt-get -y install -qq curl gnupg ca-certificates >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get -y --download-only -o Dir::Cache::archives=/out install \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
    cp /etc/apt/keyrings/docker.asc /out/docker-repo-key.asc
    # build local repo metadata
    apt-get -y install -qq dpkg-dev >/dev/null
    cd /out && rm -f lock && rm -rf partial
    dpkg-scanpackages --multiversion . /dev/null | gzip -9 > Packages.gz
"
note "APT bundle: $(ls "$B/apt"/*.deb 2>/dev/null | wc -l) debs incl. docker-ce + dist-upgrade security debs; Packages.gz generated (serve as a trivial repo)"
stamp_done 01-apt.done
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. Ubuntu ISO + checksums
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [2/10] Ubuntu Server ISO ===="
ISO="ubuntu-${UBUNTU_ISO_VER}-live-server-amd64.iso"
fetch "$B/isos/$ISO"            "https://releases.ubuntu.com/noble/$ISO"
fetch "$B/isos/SHA256SUMS"      "https://releases.ubuntu.com/noble/SHA256SUMS"
fetch "$B/isos/SHA256SUMS.gpg"  "https://releases.ubuntu.com/noble/SHA256SUMS.gpg"
( cd "$B/isos" && grep "$ISO" SHA256SUMS | sha256sum -c - )
note "Ubuntu ISO $UBUNTU_ISO_VER verified against SHA256SUMS (verify the GPG sig per site policy)"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Malcolm — install package + all container images
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [3/10] Malcolm ${MALCOLM_VER} ===="
fetch "$B/malcolm/malcolm-${MALCOLM_VER}-docker_install.zip" \
    "https://github.com/idaholab/Malcolm/releases/download/v${MALCOLM_VER}/malcolm-${MALCOLM_VER}-docker_install.zip"

# pull every image referenced by the release's docker-compose file, then save
fetch "$B/malcolm/docker-compose.yml" \
    "https://raw.githubusercontent.com/idaholab/Malcolm/v${MALCOLM_VER}/docker-compose.yml"
MALCOLM_IMAGES=$(grep -E '^\s*image:' "$B/malcolm/docker-compose.yml" | awk '{print $2}' | sort -u)
echo "$MALCOLM_IMAGES" > "$B/malcolm/image-list.txt"

MTAR="$B/malcolm/malcolm-images-${MALCOLM_VER}.tar.gz"
seed "$MTAR"
if have "$MTAR"; then
    note "Malcolm ${MALCOLM_VER}: images tarball already present ($(du -h "$MTAR" | cut -f1)) — pulls/save skipped"
else
    for img in $MALCOLM_IMAGES; do $CTR pull "$img"; done
    # shellcheck disable=SC2086
    ctr_save "$MTAR" $MALCOLM_IMAGES
    note "Malcolm ${MALCOLM_VER}: install zip + $(echo "$MALCOLM_IMAGES" | wc -l) images saved ($(du -h "$MTAR" | cut -f1)). Restore with: docker load -i malcolm-images-${MALCOLM_VER}.tar.gz"
fi
note "GeoIP DESCOPED by decision 2026-08-31: no MaxMind account — Malcolm runs without geo tagging (v2 of this script has the fetch block if reversed)"

# ═════════════════════════════════════════════════════════════════════════════
# 4. Monitoring / portal images
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [4/10] Monitoring & portal images ===="
seed "$B/docker/monitoring-images.tar.gz"
if have "$B/docker/monitoring-images.tar.gz"; then
    note "Monitoring/portal images: tarball already present — pulls/save skipped"
else
    for img in "${MONITOR_IMAGES[@]}"; do $CTR pull "$img"; done
    ctr_save "$B/docker/monitoring-images.tar.gz" "${MONITOR_IMAGES[@]}"
    note "Monitoring/portal images: ${#MONITOR_IMAGES[@]} saved"
fi
printf '%s\n' "${MONITOR_IMAGES[@]}" > "$B/docker/monitoring-image-list.txt"

# ═════════════════════════════════════════════════════════════════════════════
# 5. GNS3 wheelhouse + VM base images
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [5/10] GNS3 server + VM base images ===="
# seed the wheelhouse from a previous bundle; if the pinned gns3-server dist
# came over, the set is complete (pip downloaded it with its deps) — stamp it
if ! stamped 05-wheelhouse.done; then
    seed_glob "gns3/wheelhouse/*"
    if ls "$B/gns3/wheelhouse"/gns3?server-"${GNS3_VER}"* >/dev/null 2>&1; then
        stamp_done 05-wheelhouse.done
        note "GNS3 wheelhouse: seeded complete from previous bundle (gns3-server==${GNS3_VER} present)"
    fi
fi
if stamped 05-wheelhouse.done; then
    note "GNS3 wheelhouse: skipped — complete in a previous run"
else
    $CTR run --rm "${PROXY_ENV[@]}" -v "$B/gns3/wheelhouse:/wh:Z" "$PYTHON_BUILD_IMG" bash -ec "
        pip download --no-cache-dir -d /wh gns3-server==${GNS3_VER} pip setuptools wheel
    "
    stamp_done 05-wheelhouse.done
fi
note "GNS3 wheelhouse (gns3-server==${GNS3_VER}): install offline with  python3 -m venv /opt/gns3 && /opt/gns3/bin/pip install --no-index --find-links /path/wheelhouse gns3-server"
note "GNS3 v3 note: server bundles the web UI and enforces auth (admin user on first run); images still live as files under images_path — pre-staging appliances on disk remains valid"

fetch "$B/images/noble-server-cloudimg-amd64.img" \
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
fetch "$B/images/cirros-0.6.3-x86_64-disk.img" \
    "https://download.cirros-cloud.net/0.6.3/cirros-0.6.3-x86_64-disk.img"
note "VM base images: noble cloud image + cirros (validation-suite test VM)"

# ═════════════════════════════════════════════════════════════════════════════
# 6. GNS3 appliances — definitions + free images + docker-node images
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [6/10] GNS3 appliances ===="
# 6a. .gns3a definitions from the GNS3 registry (tolerant: missing names WARN)
for a in "${GNS3A_DEFS[@]}"; do
    seed "$B/gns3/definitions/${a}.gns3a"
    if have "$B/gns3/definitions/${a}.gns3a"; then
        echo "   [skip] ${a}.gns3a already present"; continue
    fi
    if curl -fsSL -o "$B/gns3/definitions/${a}.gns3a" \
        "https://raw.githubusercontent.com/GNS3/gns3-registry/master/appliances/${a}.gns3a"; then
        echo "   definition: ${a}.gns3a"
    else
        rm -f "$B/gns3/definitions/${a}.gns3a"
        note "WARN: registry has no appliances/${a}.gns3a — browse https://github.com/GNS3/gns3-registry/tree/master/appliances for the actual name"
    fi
done
note "GNS3 definitions: $(ls "$B/gns3/definitions"/*.gns3a 2>/dev/null | wc -l) .gns3a files (definitions are free even for licensed appliances)"

# 6b. VyOS rolling — reuse an already-downloaded nightly (any tag) before
# resolving the latest via the GitHub API, so a resume doesn't chase a newer
# nightly than the one it already holds. Seed from the previous bundle first.
seed_glob "gns3/appliances/vyos-*-generic-amd64.iso"
seed_glob "gns3/appliances/vyos-*-generic-amd64.iso.minisig"
VYOS_EXISTING=$(ls "$B/gns3/appliances"/vyos-*-generic-amd64.iso 2>/dev/null | head -1 || true)
if [ -n "$VYOS_EXISTING" ] && [ "$FORCE" = "0" ]; then
    VYOS_TAG=$(basename "$VYOS_EXISTING" | sed -E 's/^vyos-(.*)-generic-amd64\.iso$/\1/')
    note "VyOS rolling ${VYOS_TAG}: already present — skipped"
else
    VYOS_TAG=$(curl -fsSL https://api.github.com/repos/vyos/vyos-nightly-build/releases/latest \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [ -n "$VYOS_TAG" ]; then
        VYOS_ISO="vyos-${VYOS_TAG}-generic-amd64.iso"
        fetch "$B/gns3/appliances/$VYOS_ISO" \
            "https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_TAG}/${VYOS_ISO}" \
            && fetch "$B/gns3/appliances/${VYOS_ISO}.minisig" \
                "https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_TAG}/${VYOS_ISO}.minisig" \
            && note "VyOS rolling ${VYOS_TAG} ISO + minisig fetched" \
            || note "WARN: VyOS ${VYOS_TAG} download failed — fetch manually from github.com/vyos/vyos-nightly-build/releases"
    else
        note "WARN: could not resolve latest VyOS nightly tag (GitHub API) — fetch manually"
    fi
fi

# 6c. MikroTik CHR (free tier: 1 Mbps unlicensed — fine for lab control-plane work)
fetch "$B/gns3/appliances/chr-${CHR_VER}.img.zip" \
    "https://download.mikrotik.com/routeros/${CHR_VER}/chr-${CHR_VER}.img.zip" \
    && note "MikroTik CHR ${CHR_VER} raw image fetched (unzip on the R770; GNS3/QEMU boots the raw .img directly)" \
    || note "WARN: CHR ${CHR_VER} download failed — check https://mikrotik.com/download/chr"

# 6d. OPNsense (the no-account open firewall; pfSense CE now requires a Netgate account)
for f in "OPNsense-${OPNSENSE_VER}-dvd-amd64.iso.bz2" \
         "OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256" \
         "OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256.sig"; do
    fetch "$B/gns3/appliances/$f" "${OPNSENSE_MIRROR}/$f" \
        || note "WARN: OPNsense fetch failed for $f — try another mirror from https://opnsense.org/download/"
done
if [ -f "$B/gns3/appliances/OPNsense-${OPNSENSE_VER}-dvd-amd64.iso.bz2" ] && \
   [ -f "$B/gns3/appliances/OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256" ]; then
    ( cd "$B/gns3/appliances" && \
      grep "OPNsense-${OPNSENSE_VER}-dvd-amd64.iso.bz2" "OPNsense-${OPNSENSE_VER}-checksums-amd64.sha256" \
        | sha256sum -c - ) \
        && note "OPNsense ${OPNSENSE_VER} dvd ISO verified against its sha256 list" \
        || note "WARN: OPNsense checksum verification FAILED — do not transfer this file"
fi

# 6e. Alpine virt ISO — reuse an already-downloaded copy (any version) before
# parsing latest-releases.yaml, so a resume doesn't chase a newer point release.
ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
seed_glob "gns3/appliances/alpine-virt-*-x86_64.iso"
seed_glob "gns3/appliances/alpine-virt-*-x86_64.iso.sha256"
ALPINE_EXISTING=$(ls "$B/gns3/appliances"/alpine-virt-*-x86_64.iso 2>/dev/null | head -1 || true)
if [ -n "$ALPINE_EXISTING" ] && [ "$FORCE" = "0" ]; then
    ALPINE_ISO=$(basename "$ALPINE_EXISTING")
    ( cd "$B/gns3/appliances" && sha256sum -c "${ALPINE_ISO}.sha256" ) \
        && note "Alpine virt ISO ${ALPINE_ISO}: already present (re-verified) — skipped" \
        || note "WARN: cached ${ALPINE_ISO} failed re-verification — delete it and rerun"
else
    ALPINE_ISO=$(curl -fsSL "${ALPINE_BASE}/latest-releases.yaml" \
        | grep -m1 -o 'alpine-virt-[0-9][^" ]*-x86_64\.iso' || true)
    if [ -n "$ALPINE_ISO" ]; then
        fetch "$B/gns3/appliances/$ALPINE_ISO" "${ALPINE_BASE}/${ALPINE_ISO}" \
            && fetch "$B/gns3/appliances/${ALPINE_ISO}.sha256" "${ALPINE_BASE}/${ALPINE_ISO}.sha256" \
            && ( cd "$B/gns3/appliances" && sha256sum -c "${ALPINE_ISO}.sha256" ) \
            && note "Alpine virt ISO ${ALPINE_ISO} fetched + verified" \
            || note "WARN: Alpine fetch/verify failed — see ${ALPINE_BASE}"
    else
        note "WARN: could not parse Alpine latest-releases.yaml — fetch the virt ISO manually from ${ALPINE_BASE}"
    fi
fi

# 6f. GNS3 docker-node images (containers used as nodes inside topologies)
seed "$B/gns3/docker-nodes/gns3-node-images.tar.gz"
if have "$B/gns3/docker-nodes/gns3-node-images.tar.gz"; then
    note "GNS3 docker-node images: tarball already present — pulls/save skipped"
else
    NODE_PULLED=()
    for img in "${GNS3_NODE_IMAGES[@]}"; do
        if $CTR pull "$img"; then NODE_PULLED+=("$img"); else note "WARN: pull failed for $img — check the tag (FRR tags: quay.io/repository/frrouting/frr?tab=tags)"; fi
    done
    if [ "${#NODE_PULLED[@]}" -gt 0 ]; then
        ctr_save "$B/gns3/docker-nodes/gns3-node-images.tar.gz" "${NODE_PULLED[@]}"
        printf '%s\n' "${NODE_PULLED[@]}" > "$B/gns3/docker-nodes/image-list.txt"
        note "GNS3 docker-node images: ${#NODE_PULLED[@]} saved (alpine/debian/netshoot/FRR)"
    fi
fi

# 6g. Licensed images — manual checklist
cat > "$B/gns3/appliances/README.txt" <<'EOF'
LICENSED / ACCOUNT-GATED GNS3 IMAGES — MANUAL DOWNLOADS, STAGE INTO THIS DIRECTORY
(decisions 2026-08-31; definitions for these are already in ../definitions/)

  Cisco (CCO / CML-VIRL entitlement):
    - IOSv (vios-adventerprisek9-*.qcow2)   - IOSvL2 (vios_l2-*.qcow2)
    - IOL/IOU images (bin) if entitled       - CSR1000v / Cat8000v qcow2
    - ASAv qcow2
  Fortinet (support.fortinet.com account): FortiGate-VM KVM qcow2 (+ eval license)
  Palo Alto (support.paloaltonetworks.com): VM-Series KVM qcow2 (+ auth codes)
  pfSense CE (pfsense.org): now requires a free Netgate account — OPNsense in this
    directory is the scripted, no-account alternative.

This is usually the LARGEST manual category (10-100+ GB). Record what you staged,
with versions and sha256 sums, in BUNDLE_NOTES.md before building the manifest —
or rerun the manifest step ([10/10] in the fetch script) after adding files here.
EOF
note "Licensed GNS3 images: MANUAL — see gns3/appliances/README.txt"

# ═════════════════════════════════════════════════════════════════════════════
# 7. Enrichment / rules data  (GeoIP descoped — see section 3 note)
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [7/10] Enrichment data ===="
fetch "$B/enrichment/oui.txt"            "https://standards-oui.ieee.org/oui/oui.txt" || note "WARN: oui.txt fetch failed — retry manually"
fetch "$B/enrichment/public_suffix_list.dat" "https://publicsuffix.org/list/public_suffix_list.dat" || true
fetch "$B/enrichment/ipv4-address-space.csv" "https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.csv" || true

# ET Open rules — path retires with HTTP 410 when a Suricata branch ages out
ET_URL="https://rules.emergingthreats.net/open/${ET_SURICATA_PATH}/emerging.rules.tar.gz"
if have "$B/enrichment/emerging.rules.tar.gz"; then
    note "ET Open rules: already present — skipped"
elif ET_CODE=$(curl -sIL -o /dev/null -w '%{http_code}' "$ET_URL" || echo 000); [ "$ET_CODE" = "200" ]; then
    fetch "$B/enrichment/emerging.rules.tar.gz" "$ET_URL" \
        && note "ET Open rules (${ET_SURICATA_PATH}) fetched" \
        || note "WARN: ET Open rules download failed (optional; Suricata disabled by default)"
else
    note "WARN: ET Open ${ET_SURICATA_PATH} path returned HTTP ${ET_CODE} — branch may be retired; set ET_SURICATA_PATH (e.g. suricata-8.0) to match the target's Suricata version and rerun"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 8. Offline docs mirrors — best effort, never fails the bundle
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [8/10] Docs mirrors ===="
if command -v wget >/dev/null 2>&1; then
    docs_mirror() {  # docs_mirror <name> <url> — stamped complete; partial mirrors re-run
        local name="$1" url="$2"
        if stamped "08-docs-${name}.done"; then
            note "docs: $name skipped — complete in a previous run"; return 0
        fi
        # wget --mirror is itself incremental (timestamping), so a re-run of a
        # partial mirror only fetches what's missing/newer.
        timeout 900 wget -q --mirror --no-parent --convert-links --page-requisites \
            --adjust-extension -P "$B/docs/$name" "$url" \
            && { note "docs: $name mirrored"; stamp_done "08-docs-${name}.done"; } \
            || note "WARN: docs mirror for $name incomplete/failed (best-effort; rerun resumes it)"
    }
    docs_mirror malcolm   "https://malcolm.fyi/docs/"
    docs_mirror zeek      "https://docs.zeek.org/en/current/"
    docs_mirror wireshark "https://www.wireshark.org/docs/wsug_html_chunked/"
    # docs.gns3.com is JS-heavy and mirrors poorly — take the repo docs instead
    fetch "$B/docs/gns3-server-docs.tar.gz" \
        "https://github.com/GNS3/gns3-server/archive/refs/tags/v${GNS3_VER}.tar.gz" \
        && note "docs: gns3-server v${GNS3_VER} source tarball (includes docs/) fetched" \
        || note "WARN: gns3-server source tarball fetch failed"
else
    note "WARN: wget not installed on staging host — docs mirrors SKIPPED (dnf -y install wget, then rerun)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 9. Manual-download placeholders
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [9/10] Manual items ===="
cat > "$B/dell/README.txt" <<'EOF'
MANUAL DOWNLOADS from dell.com/support — service tag G8WFGH4
(express service code 35366715688)

REQUIRED regardless of version:
  - perccli2  (note: perccli2, NOT perccli — the PERC H975i Front is an
    NVMe RAID controller). Three Phase 2 questions are blocked on it:
      * PERC encryption key custody: the controller reports encryption
        Enabled with a Security Key Assigned, and the key mode (LKM vs
        SEKM) and escrow location are unknown. Lose the key and the
        virtual disk is unrecoverable.
      * TRIM passthrough on the VD (decides whether fstrim.timer is real)
      * NVMe link width: both drives negotiated x2 of a x4-capable link

ONLY IF DELL LISTS SOMETHING NEWER — installed baselines, from Phase 1
discovery on 2026-09-02/03:
  BIOS ................ 1.7.5 (2026-01-16)
  iDRAC / LC .......... 1.30.20.10
  PERC H975i Front .... 8.14.0.0.28-40
  Backplane ........... 1.92
  Broadcom NICs ....... family 233.1.181.0 (pkg 233.0.195.0)
  PSU (2x LiteOn 1100W) 1408
  CPLD / FPGA ......... 109.125.104

Optionally: Dell System Update (DSU) offline repository.

Keep Dell's published checksums alongside each file.
Firmware is applied via iDRAC out-of-band — schedule in Phase 2. NOTE:
IPMI-over-LAN is DISABLED on this chassis (Serial-over-LAN is enabled), so
scripted OOB work must use Redfish; "ipmitool -H" will not connect.

After adding files here, REGENERATE THE MANIFEST — it was written before
these existed, and sha256sum -c cannot see files it never listed:
    ./scripts/r770-bundle.sh manifest <bundle-dir>
    ./scripts/r770-bundle.sh verify   <bundle-dir> --strict
EOF
note "Dell firmware/tools: MANUAL — see dell/README.txt"

# ═════════════════════════════════════════════════════════════════════════════
# 10. Manifest
# ═════════════════════════════════════════════════════════════════════════════
echo "==== [10/10] Manifest ===="
{
    echo; echo "## Versions"
    echo "- Malcolm: ${MALCOLM_VER}"
    echo "- Ubuntu ISO: ${UBUNTU_ISO_VER}"
    echo "- gns3-server: ${GNS3_VER}"
    echo "- MikroTik CHR: ${CHR_VER}"
    echo "- OPNsense: ${OPNSENSE_VER}"
    echo "- VyOS rolling: ${VYOS_TAG:-unresolved}"
    echo "- FRR image: ${FRR_IMG}"
    echo "- Built: $(date -Is) on $(hostname) with ${CTR}"
    echo; echo "## Import order on the R770"
    echo "1. ./r770-bundle.sh verify .     (before anything else -- the verifier"
    echo "   ships in this bundle root and is covered by MANIFEST.sha256. Exit 0"
    echo "   PASS, 2 warnings to disposition, 1 DO NOT IMPORT. Plain 'sha256sum -c'"
    echo "   cannot see files added after the manifest was written, which is"
    echo "   exactly the Dell firmware and licensed-appliance case.)"
    echo "2. Site AV/content scan per policy"
    echo "3. apt/ -> local repo dir; point sources.list at it; apt update"
    echo "4. docker load -i malcolm/malcolm-images-*.tar.gz && docker load -i docker/monitoring-images.tar.gz && docker load -i gns3/docker-nodes/gns3-node-images.tar.gz"
    echo "5. gns3 wheelhouse, definitions/, appliances/, images/, enrichment/, docs/ into place per buildout doc"
    echo "6. Keep previous bundle until this one validates"
    if [ "$CTR" = "podman" ]; then
        echo; echo "## Podman-built bundle note"
        echo "Image tarballs were produced by 'podman save --multi-image-archive' (docker-archive"
        echo "format). Before the transfer, test 'docker load' of monitoring-images.tar.gz on any"
        echo "Docker host and confirm tags with 'docker image ls'. After load on the R770, verify"
        echo "tags match malcolm/image-list.txt and docker/monitoring-image-list.txt (docker.io/"
        echo "prefixes are part of the saved names)."
    fi
} >> "$NOTES"

cp "$BUNDLE_TOOL" "$B/"          # the verifier travels with the media
"$BUNDLE_TOOL" manifest "$B"

echo
echo "Bundle complete: $B"
du -sh "$B"
echo "If this run was interrupted, just rerun it — completed items are skipped"
echo "(same-day runs resume automatically; otherwise BUNDLE_DIR=$B; FORCE=1 redoes all)."
echo "Review $NOTES, complete the MANUAL items (dell/, gns3/appliances/), then"
echo "regenerate the manifest after adding manual files:"
echo "  ./scripts/r770-bundle.sh manifest $B"
echo "then gate it before the media leaves staging:"
echo "  ./scripts/r770-bundle.sh verify $B --strict"
echo "Then transfer per the supply plan (ext4 drive; verify MANIFEST.sha256 on the R770)."
