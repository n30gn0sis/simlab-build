#!/usr/bin/env bash
#
# r770-staging-preflight.sh — decide whether THIS host may build a bundle.
#
# Runs before scripts/r770-offline-fetch.sh. Its whole value is failing early:
# the fetch downloads for hours, and every condition checked here is one that
# would otherwise surface somewhere in the middle of that.
#
# ANY CONTAINER RUNTIME, JUDGED BY WHAT IT CAN DO (decision 2026-09-14)
#
# The fetch is portable: every Ubuntu-specific command -- apt-get,
# dpkg-scanpackages -- runs inside a clean ubuntu:24.04 container, and its bind
# mounts carry :Z, which relabels for SELinux and is ignored elsewhere. So the
# host distro is informational. What matters is the runtime, and what matters
# about the runtime is capability, not name:
#
#   - it is found: STAGING_CTR=<command> if set, else docker, podman, nerdctl
#   - its daemon/engine answers `info`
#   - it can pull the build image and give a container egress
#   - its `save` writes a docker archive (manifest.json in the tar) -- the one
#     format `docker load` on the R770 reads. This is probed for real in the
#     egress stage, so a runtime nobody here has heard of is judged the same way.
#
# Still refused: no runtime, an engine that does not answer, an LXC host, and
# podman below 3.0 (no --multi-image-archive, so multi-image tarballs cannot
# be written in that format). Rootless podman and Docker CE on RHEL used to be
# refusals and are now warnings with the reason: they work, they are just not
# the recommended setup, and the operator dispositions warnings before fetch day.
# Ubuntu 24.04 + Docker CE remains the recommended default (manifest §0).
#
#   0  ready
#   1  not ready -- at least one refusal
#   2  ready with warnings -- disposition each before fetch day
#
# Test overrides: PREFLIGHT_OS_RELEASE, PREFLIGHT_BUNDLE_DIR, PREFLIGHT_MIN_GB,
# PREFLIGHT_SKIP_EGRESS.
set -uo pipefail

MIN_GB="${PREFLIGHT_MIN_GB:-150}"
OS_RELEASE="${PREFLIGHT_OS_RELEASE:-/etc/os-release}"
BUNDLE_DIR="${PREFLIGHT_BUNDLE_DIR:-$(pwd)}"
SKIP_EGRESS="${PREFLIGHT_SKIP_EGRESS:-0}"
UBUNTU_BUILD_IMG="docker.io/library/ubuntu:24.04"

FAILED=0
WARNED=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNED=$((WARNED + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }

echo "== staging preflight =="

# ── 1. Which staging OS is this? ─────────────────────────────────────────────
OS_ID=""; OS_VER=""
if [ -r "$OS_RELEASE" ]; then
    OS_ID=$(   awk -F= '$1=="ID"        {gsub(/"/,"",$2); print $2}' "$OS_RELEASE" | head -1)
    OS_VER=$(  awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}' "$OS_RELEASE" | head -1)
fi
OS_MAJOR="${OS_VER%%.*}"

case "$OS_ID" in
    ubuntu)
        if [ "$OS_VER" = "24.04" ]; then
            pass "staging OS: Ubuntu ${OS_VER} — the default path"
        else
            warn "staging OS: Ubuntu ${OS_VER}, not 24.04 — the bundle targets 24.04"
        fi ;;
    rhel|rocky|almalinux|centos)
        if [ "$OS_MAJOR" = "8" ]; then
            pass "staging OS: RHEL ${OS_VER} — exercised alternative; rootful podman recommended"
        else
            warn "staging OS: RHEL-family ${OS_VER}; only 8 is exercised"
        fi ;;
    "")
        warn "cannot read ${OS_RELEASE} — staging OS unidentified" ;;
    *)
        warn "distro '${OS_ID}' not exercised here — only Ubuntu 24.04 and RHEL 8 have been; the runtime checks below decide" ;;
esac

# ── 2. A VM, never a container ───────────────────────────────────────────────
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
if [ "$VIRT" = "lxc" ]; then
    fail "running inside lxc — Docker there needs nesting=1/keyctl=1 and still fights overlayfs; use a VM"
else
    pass "virtualization: ${VIRT} — not lxc"
fi

# ── 3. Container runtime — found by override or by name, judged by capability ─
CTR=""
if [ -n "${STAGING_CTR:-}" ]; then
    if command -v "$STAGING_CTR" >/dev/null 2>&1; then
        CTR="$STAGING_CTR"
    else
        fail "STAGING_CTR=${STAGING_CTR} is not on PATH"
    fi
elif command -v docker >/dev/null 2>&1 && ! docker --version 2>/dev/null | grep -qi podman; then
    CTR="docker"
elif command -v podman >/dev/null 2>&1; then
    CTR="podman"
elif command -v nerdctl >/dev/null 2>&1; then
    CTR="nerdctl"
fi

IS_RHEL=0
case "$OS_ID" in rhel|rocky|almalinux|centos) IS_RHEL=1 ;; esac

if [ -z "$CTR" ]; then
    [ -n "${STAGING_CTR:-}" ] || fail "no container runtime — none of docker, podman, nerdctl on PATH (or set STAGING_CTR=<command>)"
else
    CTR_VER=$("$CTR" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    pass "container runtime: ${CTR} ${CTR_VER:-unknown}$([ -n "${STAGING_CTR:-}" ] && echo ' (STAGING_CTR override)')"

    if [ "$CTR" = "docker" ] && [ "$IS_RHEL" = "1" ]; then
        warn "Docker CE on RHEL comes from a repo outside Red Hat support and conflicts with the container-tools module — it works for the fetch, but rootful podman is the supported setup there"
    fi

    if [ "$CTR" = "podman" ]; then
        # podman save --multi-image-archive is how the image tarballs are written
        # in docker-archive format. Without it the bundle's tarballs are unusable
        # on the R770, which only has Docker.
        if [ -z "$CTR_VER" ]; then
            warn "cannot determine podman version — --multi-image-archive needs 3.0+"
        elif [ "${CTR_VER%%.*}" -lt 3 ]; then
            fail "podman ${CTR_VER} is too old — --multi-image-archive needs 3.0+ (RHEL 8.10 ships 4.9)"
        else
            pass "podman ${CTR_VER} supports --multi-image-archive"
        fi

        if [ "$(id -u)" -ne 0 ]; then
            warn "rootless podman — works, but image storage lands under \$HOME and bundle files are owned by you; rerun with sudo for docker-identical ownership and /var/lib/containers"
        else
            pass "podman is rootful"
        fi
    fi

    if "$CTR" info >/dev/null 2>&1; then
        pass "${CTR} daemon responds"
    else
        fail "${CTR} client present but the daemon does not respond"
    fi
fi

# ── 4. SELinux ───────────────────────────────────────────────────────────────
if command -v getenforce >/dev/null 2>&1; then
    SEL=$(getenforce 2>/dev/null || echo Unknown)
    if [ "$SEL" = "Enforcing" ]; then
        pass "SELinux Enforcing — the fetch's bind mounts already carry :Z"
    else
        pass "SELinux ${SEL}"
    fi
fi

# ── 5. Room for the bundle ───────────────────────────────────────────────────
AVAIL_K=$(df -Pk "$BUNDLE_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "${AVAIL_K:-}" ] && [ "$AVAIL_K" -gt 0 ] 2>/dev/null; then
    AVAIL_GB=$((AVAIL_K / 1024 / 1024))
    if [ "$AVAIL_GB" -lt "$MIN_GB" ]; then
        fail "only ${AVAIL_GB} GB free on ${BUNDLE_DIR} — need at least ${MIN_GB} GB"
    else
        pass "${AVAIL_GB} GB free on ${BUNDLE_DIR} (need ${MIN_GB})"
    fi
else
    warn "cannot determine free space on ${BUNDLE_DIR}"
fi

# ── 6. Host tools used outside containers ────────────────────────────────────
MISSING=""
for t in curl sha256sum tar awk; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
    fail "missing required host tools:${MISSING}"
else
    pass "required host tools present"
fi

command -v pigz >/dev/null 2>&1 \
    || warn "pigz absent — the compress step falls back to gzip and runs single-threaded (RHEL: EPEL)"

# ── 7. The verifier must travel with the bundle ──────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "${HERE}/r770-bundle.sh" ]; then
    pass "r770-bundle.sh present and executable — it is copied into the bundle root"
else
    fail "r770-bundle.sh missing or not executable — the bundle would ship with no verifier"
fi

# ── 8. Egress and save format, through the runtime that will do the work ─────
if [ "$SKIP_EGRESS" = "1" ]; then
    echo "SKIP  registry egress + save-format probe (PREFLIGHT_SKIP_EGRESS=1)"
elif [ -n "$CTR" ]; then
    if timeout 300 "$CTR" run --rm "$UBUNTU_BUILD_IMG" \
            bash -ec "apt-get update -qq" >/dev/null 2>&1; then
        pass "registry pull and in-container apt egress verified"
        # The bundle's image tarballs are read by `docker load` on the R770,
        # which understands docker-archive: a tar with manifest.json at its
        # root. Probe the format the runtime actually writes instead of
        # trusting its name -- this is what makes an unknown runtime safe.
        if timeout 300 "$CTR" save "$UBUNTU_BUILD_IMG" 2>/dev/null | tar -tf - 2>/dev/null \
                | grep -qE '^(\./)?manifest\.json$'; then
            pass "${CTR} save writes docker-archive (manifest.json present) — the R770's docker load can read it"
        else
            fail "${CTR} save output has no manifest.json — not docker-archive; the R770's docker load could not read the bundle's image tarballs"
        fi
    else
        fail "cannot pull ${UBUNTU_BUILD_IMG} or reach archive.ubuntu.com from inside it — see the fetch script's proxy notes"
    fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
    echo "NOT READY — ${FAILED} refusal(s), ${WARNED} warning(s)"
    exit 1
elif [ "$WARNED" -gt 0 ]; then
    echo "READY WITH WARNINGS — ${WARNED} warning(s); disposition each before fetch day"
    exit 2
fi
echo "READY — all checks passed"
exit 0
