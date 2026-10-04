#!/usr/bin/env bash
#
# r770-build-bundle.sh — one command, one verified bundle.
#
#   ./r770-build-bundle.sh              build here
#   ./r770-build-bundle.sh --pack       emit a self-extracting builder to stdout
#   ./r770-build-bundle.sh --only s,s   / --skip s,s   run a selection of fetch
#                                       stages (see the fetch's --list); the
#                                       pause, manifest and strict gate still
#                                       run, so a partial bundle fails the gate
#                                       by design -- use the fetch script
#                                       directly for section-by-section work
#
# Chains the four steps that have to happen in this order, and refuses to
# continue when one of them fails:
#
#   1. preflight   is this host fit to build at all?
#   2. fetch       the long download
#   3. PAUSE       stage the manual category -- licensed GNS3 appliances
#   4. manifest    regenerate, now that the manual files exist
#   5. verify      --strict, before the media is allowed to move
#
# STEP 3 BEFORE STEP 4 IS THE WHOLE POINT. The fetch writes a manifest covering
# what it downloaded. Licensed GNS3 appliances are added by hand afterwards,
# and a manifest written before those files existed cannot see them -- so the gate passes a bundle whose manual content is entirely
# unverified. Running these steps by hand is how that gets forgotten; this
# script exists so it cannot be.
#
#   0  bundle built and gated clean
#   1  failed -- do not move the media
#   2  built, with warnings to disposition first
#
# Test overrides: BUILD_PREFLIGHT, BUILD_FETCH, BUILD_MANIFEST_CMD,
# BUILD_VERIFY_CMD, BUILD_BUNDLE_DIR, BUILD_ASSUME_YES, BUILD_PACK_ROOT.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="${BUILD_PREFLIGHT:-$HERE/r770-staging-preflight.sh}"
FETCH="${BUILD_FETCH:-$HERE/r770-offline-fetch.sh}"
BUNDLE_TOOL="$HERE/r770-bundle.sh"
MANIFEST_CMD="${BUILD_MANIFEST_CMD:-$BUNDLE_TOOL}"
VERIFY_CMD="${BUILD_VERIFY_CMD:-$BUNDLE_TOOL}"

PACKED_NAME="r770-bundle-builder.sh"
CONTENTS="r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh"
SITE_TREES=(scripts config docs/analyst-wiki)

ASSUME_YES="${BUILD_ASSUME_YES:-0}"
INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0
BUNDLE_DIR="${BUILD_BUNDLE_DIR:-}"
DO_PACK=0
FETCH_ARGS=()     # --only/--skip, handed to the fetch verbatim

die()  { echo "r770-build-bundle: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# ── pack: emit a single file carrying all four scripts, PLUS a git archive of
# this repo's reviewed site/ content (scripts/, config/, docs/analyst-wiki/)
# at the exact commit it was packed from ───────────────────────────────────
# The payload rides in a quoted heredoc so the emitted file is inert to a
# syntax check and cannot be mistaken for code. Note it is base64: a packed
# builder must never be committed, because base64 hides the version pins from
# the ownership guard that keeps them living in exactly one place. .gitignore
# carries the name for that reason.
#
# 2026-09-26 review: a packed builder unpacks flat into a mktemp -d with NO
# git checkout at all, so r770-offline-fetch.sh's "site" stage had nothing to
# read the reviewed scripts/config/docs-analyst-wiki from -- it would refuse
# at stage 10 of 11, after the whole long download, or (before that refusal
# existed) silently ship whatever happened to be lying around in /tmp. A pack
# is a release artifact, so it must be traceable to one exact, clean commit:
# `--pack` now embeds `git archive --format=tar HEAD -- scripts config
# docs/analyst-wiki` plus the full commit hash, and refuses outright if any
# of those three trees is dirty. BUILD_PACK_ROOT (test-only) points the git
# operations at a directory other than $HERE's own checkout, so tests never
# depend on this repo's ambient working-tree state.
cmd_pack() {
    local tmp root commit
    root="$(git -c safe.directory="${BUILD_PACK_ROOT:-$HERE}" -C "${BUILD_PACK_ROOT:-$HERE}" rev-parse --show-toplevel 2>/dev/null)" ||
        die "--pack must run from a git checkout of this repo (git rev-parse --show-toplevel failed under ${BUILD_PACK_ROOT:-$HERE})"
    if [ -n "$(git -c safe.directory="$root" -C "$root" status --porcelain -- "${SITE_TREES[@]}" 2>/dev/null)" ]; then
        die "--pack refuses a dirty tree -- scripts/, config/ or docs/analyst-wiki/ has uncommitted changes; commit or stash them first. A pack is a release artifact: it must be traceable to one exact commit."
    fi
    commit="$(git -c safe.directory="$root" -C "$root" rev-parse HEAD)" || die "git rev-parse HEAD failed under $root"

    tmp="$(mktemp -d)" || die "mktemp failed"
    if ! git -c safe.directory="$root" -C "$root" archive --format=tar HEAD -- "${SITE_TREES[@]}" > "$tmp/site.tar"; then
        rm -rf "$tmp"
        die "could not archive ${SITE_TREES[*]} at HEAD ($commit) for site/"
    fi
    printf '%s' "$commit" > "$tmp/site-commit.txt"

    # The kit (sim-lab-basic, the R770 installer) rides along when KIT_SRC_ROOT
    # names a checkout at pack time: same rules as site/ -- one exact, clean
    # commit. Without it the pack carries no kit, and the packed builder's
    # fetch then needs KIT_SRC_ROOT (or --skip kit) like any other run.
    local kit_files="" kit_commit=""
    if [ -n "${KIT_SRC_ROOT:-}" ]; then
        if [ -n "$(git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" status --porcelain -- scripts config scenarios docs 2>/dev/null)" ]; then
            rm -rf "$tmp"; die "--pack refuses a dirty kit tree at KIT_SRC_ROOT ($KIT_SRC_ROOT) -- commit or stash it first"
        fi
        kit_commit="$(git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" rev-parse HEAD)" || { rm -rf "$tmp"; die "KIT_SRC_ROOT ($KIT_SRC_ROOT) is not a git checkout"; }
        git -c safe.directory="$KIT_SRC_ROOT" -C "$KIT_SRC_ROOT" archive --format=tar HEAD -- scripts config scenarios docs > "$tmp/kit.tar" ||
            { rm -rf "$tmp"; die "could not archive the kit at $kit_commit"; }
        kit_files="kit.tar"
    else
        echo "r770-build-bundle: note: --pack without KIT_SRC_ROOT carries no kit; the packed builder's fetch will need KIT_SRC_ROOT (or --skip kit)" >&2
    fi

    # shellcheck disable=SC2086
    if ! tar czf "$tmp/payload.tgz" -C "$HERE" $CONTENTS -C "$tmp" site.tar site-commit.txt $kit_files; then    # CONTENTS, kit_files: intentional word-splitting
        rm -rf "$tmp"
        die "could not pack: $CONTENTS site.tar site-commit.txt $kit_files"
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
# Also carries this repo's reviewed scripts/, config/ and docs/analyst-wiki/
# as a git archive of commit ${commit} (site.tar + site-commit.txt below), so
# the fetch's "site" stage ships that exact, reviewed content even though
# this unpacked builder has no checkout of its own to read it from.
# Also carries sim-lab-basic (the R770 installer) as kit.tar when KIT_SRC_ROOT
# was set at pack time.
#
# Copy to a staging host and run it. On RHEL 8 use rootful podman:
#   sudo -E bash ${PACKED_NAME}
#
# Regenerate this file whenever a pin moves, or the reviewed scripts/config/
# docs-analyst-wiki content changes — it is a snapshot, not a source. Never
# commit it: the payload is base64, which hides the pins from the guard that
# keeps them in one place.
set -euo pipefail
D="\$(mktemp -d)"; trap 'rm -rf "\$D"' EXIT
base64 -d <<'R770_PAYLOAD' | tar xz -C "\$D"
HEADER
    base64 "$tmp/payload.tgz"
    cat <<FOOTER
R770_PAYLOAD
chmod +x "\$D"/*.sh
export SITE_ARCHIVE="\$D/site.tar"
export SITE_COMMIT="$commit"
FOOTER
    if [ -n "$kit_commit" ]; then
        # shellcheck disable=SC2016  # $D stays literal: it is the packed script's own variable
        printf 'export KIT_ARCHIVE="$D/kit.tar"\nexport KIT_COMMIT="%s"\n' "$kit_commit"
    fi
    cat <<'FOOTER2'
exec "$D/r770-build-bundle.sh" "$@"
FOOTER2
    rm -rf "$tmp"
}

# ── arguments ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --pack)            DO_PACK=1 ;;
        --bundle-dir)      BUNDLE_DIR="${2:-}"; [ -n "$BUNDLE_DIR" ] || die "--bundle-dir needs a path"; shift ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --non-interactive) INTERACTIVE=0 ;;
        --only|--skip)     [ -n "${2:-}" ] || die "$1 needs a stage list"; FETCH_ARGS+=("$1" "$2"); shift ;;
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
            read -r -p "Continue anyway? [y/N] " a || a=""
            case "$a" in [yY]*) ;; *) die "stopped at preflight" ;; esac
        fi ;;
    *) die "preflight refused this host — nothing was downloaded" ;;
esac

# ── 2. fetch ─────────────────────────────────────────────────────────────────
step "2/5  Fetch — this is the long one, and it is resumable"
if [ -n "$BUNDLE_DIR" ]; then
    BUNDLE_DIR="$BUNDLE_DIR" "$FETCH" "${FETCH_ARGS[@]}" || die "fetch failed — rerun to resume; completed items are skipped"
else
    "$FETCH" "${FETCH_ARGS[@]}" || die "fetch failed — rerun to resume; completed items are skipped"
    BUNDLE_DIR="$(pwd)/bundle-$(date +%Y%m%d)"
fi

# ── 3. the manual categories ─────────────────────────────────────────────────
step "3/5  Manual items — nothing below can be scripted"
cat <<'MANUAL'

  gns3/appliances/         licensed appliance images you hold entitlements for.
                           The .gns3a definitions are already staged and are
                           free even where the images are not.

They are added by hand, AFTER the fetch wrote its manifest. That manifest
cannot see them. Step 4 regenerates it so it can. (Dell firmware is not a
bundle item: it is handled on the R770 directly.)

MANUAL
if [ "$ASSUME_YES" = "1" ]; then
    :
elif [ "$INTERACTIVE" = "0" ]; then
    die "stopped before the manifest — stage the manual items, then rerun with --yes (or from a terminal to be asked)"
else
    read -r -p "Staged everything you intend to ship? [y/N] " a || a=""
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
