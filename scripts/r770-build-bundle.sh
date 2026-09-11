#!/usr/bin/env bash
#
# r770-build-bundle.sh — one command, one verified bundle.
#
#   ./r770-build-bundle.sh              build here
#   ./r770-build-bundle.sh --pack       emit a self-extracting builder to stdout
#
# Chains the four steps that have to happen in this order, and refuses to
# continue when one of them fails:
#
#   1. preflight   is this host fit to build at all?
#   2. fetch       the long download
#   3. PAUSE       stage the manual categories -- dell/ and licensed appliances
#   4. manifest    regenerate, now that the manual files exist
#   5. verify      --strict, before the media is allowed to move
#
# STEP 3 BEFORE STEP 4 IS THE WHOLE POINT. The fetch writes a manifest covering
# what it downloaded. Dell firmware and licensed GNS3 appliances are added by
# hand afterwards, and a manifest written before those files existed cannot see
# them -- so the gate passes a bundle whose manual content is entirely
# unverified. Running these steps by hand is how that gets forgotten; this
# script exists so it cannot be.
#
#   0  bundle built and gated clean
#   1  failed -- do not move the media
#   2  built, with warnings to disposition first
#
# Test overrides: BUILD_PREFLIGHT, BUILD_FETCH, BUILD_MANIFEST_CMD,
# BUILD_VERIFY_CMD, BUILD_BUNDLE_DIR, BUILD_ASSUME_YES.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="${BUILD_PREFLIGHT:-$HERE/r770-staging-preflight.sh}"
FETCH="${BUILD_FETCH:-$HERE/r770-offline-fetch.sh}"
BUNDLE_TOOL="$HERE/r770-bundle.sh"
MANIFEST_CMD="${BUILD_MANIFEST_CMD:-$BUNDLE_TOOL}"
VERIFY_CMD="${BUILD_VERIFY_CMD:-$BUNDLE_TOOL}"

PACKED_NAME="r770-bundle-builder.sh"
CONTENTS="r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh"

ASSUME_YES="${BUILD_ASSUME_YES:-0}"
INTERACTIVE=1
BUNDLE_DIR="${BUILD_BUNDLE_DIR:-}"
DO_PACK=0

die()  { echo "r770-build-bundle: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# ── pack: emit a single file carrying all four scripts ──────────────────────
# The payload rides in a quoted heredoc so the emitted file is inert to a
# syntax check and cannot be mistaken for code. Note it is base64: a packed
# builder must never be committed, because base64 hides the version pins from
# the ownership guard that keeps them living in exactly one place. .gitignore
# carries the name for that reason.
cmd_pack() {
    local tmp
    tmp="$(mktemp -d)" || die "mktemp failed"
    # shellcheck disable=SC2086
    if ! tar czf "$tmp/payload.tgz" -C "$HERE" $CONTENTS; then
        rm -rf "$tmp"
        die "could not pack: $CONTENTS"
    fi

    cat <<HEADER
#!/usr/bin/env bash
#
# R770 self-extracting bundle builder — generated $(date -Is)
#
# Carries, and runs:
#   r770-build-bundle.sh        the orchestrator
#   r770-staging-preflight.sh   host fitness gate
#   r770-offline-fetch.sh       the fetch (owner of every version pin)
#   r770-bundle.sh              manifest + integrity gate
#
# Copy to a staging host and run it. On RHEL 8 use rootful podman:
#   sudo -E bash ${PACKED_NAME}
#
# Regenerate this file whenever a pin moves — it is a snapshot, not a source.
# Never commit it: the payload is base64, which hides the pins from the guard
# that keeps them in one place.
set -euo pipefail
D="\$(mktemp -d)"; trap 'rm -rf "\$D"' EXIT
base64 -d <<'R770_PAYLOAD' | tar xz -C "\$D"
HEADER
    base64 "$tmp/payload.tgz"
    cat <<'FOOTER'
R770_PAYLOAD
chmod +x "$D"/*.sh
exec "$D/r770-build-bundle.sh" "$@"
FOOTER
    rm -rf "$tmp"
}

# ── arguments ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --pack)            DO_PACK=1 ;;
        --bundle-dir)      BUNDLE_DIR="${2:-}"; [ -n "$BUNDLE_DIR" ] || die "--bundle-dir needs a path"; shift ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --non-interactive) INTERACTIVE=0 ;;
        -h|--help)         sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)                 die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

if [ "$DO_PACK" = "1" ]; then
    cmd_pack
    exit 0
fi

# ── 1. preflight ─────────────────────────────────────────────────────────────
step "1/5  Preflight — is this host fit to build?"
"$PREFLIGHT"
rc=$?
case "$rc" in
    0) ;;
    2)
        echo
        echo "Preflight returned warnings."
        if [ "$ASSUME_YES" = "1" ]; then
            echo "Accepted via --yes; they still belong in the cycle log."
        elif [ "$INTERACTIVE" = "0" ]; then
            die "warnings need a decision and this run is non-interactive — rerun with --yes once you have dispositioned them"
        else
            read -r -p "Continue anyway? [y/N] " a
            case "$a" in [yY]*) ;; *) die "stopped at preflight" ;; esac
        fi ;;
    *) die "preflight refused this host — nothing was downloaded" ;;
esac

# ── 2. fetch ─────────────────────────────────────────────────────────────────
step "2/5  Fetch — this is the long one, and it is resumable"
if [ -n "$BUNDLE_DIR" ]; then
    BUNDLE_DIR="$BUNDLE_DIR" "$FETCH" || die "fetch failed — rerun to resume; completed items are skipped"
else
    "$FETCH" || die "fetch failed — rerun to resume; completed items are skipped"
    BUNDLE_DIR="$(pwd)/bundle-$(date +%Y%m%d)"
fi

# ── 3. the manual categories ─────────────────────────────────────────────────
step "3/5  Manual items — nothing below can be scripted"
cat <<'MANUAL'

  dell/                    firmware DUPs for the service tag, and perccli2.
                           Only a DUP NEWER than what is installed; Phase 1
                           holds the baselines. Keep Dell's published checksum
                           beside each file.

  gns3/appliances/         licensed appliance images you hold entitlements for.
                           The .gns3a definitions are already staged and are
                           free even where the images are not.

Both are added by hand, AFTER the fetch wrote its manifest. That manifest
cannot see them. Step 4 regenerates it so it can.

MANUAL
if [ "$ASSUME_YES" != "1" ] && [ "$INTERACTIVE" = "1" ]; then
    read -r -p "Staged everything you intend to ship? [y/N] " a
    case "$a" in [yY]*) ;; *) die "stopped before the manifest — stage the manual items, then rerun" ;; esac
fi

# ── 4. manifest, now that the manual files exist ────────────────────────────
step "4/5  Manifest — regenerated so it covers the manual additions"
"$MANIFEST_CMD" manifest "$BUNDLE_DIR" || die "manifest generation failed"

# ── 5. the gate ──────────────────────────────────────────────────────────────
step "5/5  Gate — --strict, before the media is allowed to move"
"$VERIFY_CMD" verify "$BUNDLE_DIR" --strict
vrc=$?

echo
case "$vrc" in
    0)
        echo "BUNDLE READY — gated clean at ${BUNDLE_DIR}"
        echo "Next: verify the Ubuntu ISO GPG signature, copy to ext4 media, gate again"
        echo "FROM the media, then follow docs/plans/r770-install-runbook.md on the R770."
        exit 0 ;;
    2)
        echo "BUNDLE BUILT WITH WARNINGS at ${BUNDLE_DIR}"
        echo "Disposition every warning in writing, in state/inventory/bundles.md,"
        echo "before the media moves."
        exit 2 ;;
    *)
        echo "GATE FAILED — do not move this media."
        exit 1 ;;
esac
