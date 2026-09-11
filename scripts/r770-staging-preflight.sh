#!/usr/bin/env bash
#
# r770-staging-preflight.sh — decide whether THIS host may build a bundle.
#
# Runs before scripts/r770-offline-fetch.sh. Its whole value is failing early:
# the fetch downloads for hours, and every condition checked here is one that
# would otherwise surface somewhere in the middle of that.
#
# TWO SUPPORTED STAGING HOSTS
#
#   Ubuntu 24.04 + Docker CE   the default (dependency manifest §0)
#   RHEL 8 + rootful podman    supported alternative
#
# The fetch itself was always portable: every Ubuntu-specific command --
# apt-get, dpkg-scanpackages -- runs inside a clean ubuntu:24.04 container, so
# resolving Ubuntu packages never required an Ubuntu host. Both of its bind
# mounts already carry :Z, which relabels for SELinux and is ignored where
# SELinux is absent. What was missing was a check that a RHEL host is actually
# fit to run it, which is this script.
#
# WHY RHEL MUST USE PODMAN, NOT DOCKER CE
#
# Docker CE on RHEL 8 comes from a third-party repository outside Red Hat
# support and conflicts with the container-tools module that provides podman.
# Installing it to run this fetch trades a working supported container stack
# for an unsupported one. That conflict is why the default moved to Ubuntu on
# 2026-09-04; on RHEL the answer is podman, which ships in container-tools.
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
            pass "staging OS: RHEL ${OS_VER} — supported alternative path, podman required"
        else
            warn "staging OS: RHEL-family ${OS_VER}; only 8 is exercised"
        fi ;;
    "")
        warn "cannot read ${OS_RELEASE} — staging OS unidentified" ;;
    *)
        warn "unsupported distro '${OS_ID}' — only Ubuntu 24.04 and RHEL 8 are exercised" ;;
esac

# ── 2. A VM, never a container ───────────────────────────────────────────────
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
if [ "$VIRT" = "lxc" ]; then
    fail "running inside lxc — Docker there needs nesting=1/keyctl=1 and still fights overlayfs; use a VM"
else
    pass "virtualization: ${VIRT} — not lxc"
fi

# ── 3. Container runtime ─────────────────────────────────────────────────────
CTR=""
if command -v docker >/dev/null 2>&1 && ! docker --version 2>/dev/null | grep -qi podman; then
    CTR="docker"
elif command -v podman >/dev/null 2>&1; then
    CTR="podman"
fi

IS_RHEL=0
case "$OS_ID" in rhel|rocky|almalinux|centos) IS_RHEL=1 ;; esac

if [ -z "$CTR" ]; then
    fail "no container runtime — install Docker CE (Ubuntu) or the container-tools module (RHEL)"
elif [ "$CTR" = "docker" ] && [ "$IS_RHEL" = "1" ]; then
    fail "Docker CE on RHEL conflicts with the container-tools module that provides podman — use rootful podman instead"
else
    CTR_VER=$("$CTR" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    pass "container runtime: ${CTR} ${CTR_VER:-unknown}"

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
            fail "rootless podman — rerun with sudo; rootful gives docker-identical ownership and uses /var/lib/containers"
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

# ── 8. Egress, through the runtime that will actually do the pulling ─────────
if [ "$SKIP_EGRESS" = "1" ]; then
    echo "SKIP  registry egress check (PREFLIGHT_SKIP_EGRESS=1)"
elif [ -n "$CTR" ]; then
    if timeout 300 "$CTR" run --rm "$UBUNTU_BUILD_IMG" \
            bash -ec "apt-get update -qq" >/dev/null 2>&1; then
        pass "registry pull and in-container apt egress verified"
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
