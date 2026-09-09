#!/usr/bin/env bash
#
# r770-bundle.sh — manifest generation and integrity verification for the R770
# offline supply bundle.
#
#   r770-bundle.sh manifest <bundle-dir>            (re)write MANIFEST.sha256
#   r770-bundle.sh verify   <bundle-dir> [--strict] prove the bundle is importable
#
# Dependency-free by design: bash >= 4.4, coreutils, find. No network, no root,
# no jq. That makes it safe to run on the AIR-GAPPED R770 — copy this file into
# the bundle root BEFORE generating the manifest so the verifier travels with
# the media and is itself covered by the hashes.
#
# Why this exists: the hand-typed `find | xargs sha256sum` it replaces reports
# OK (exit 0) for an empty bundle, for files added after the manifest was
# written, and for leftover .part downloads. Each was reproduced against the
# real command on 2026-09-03; see
# docs/superpowers/plans/2026-09-03-bundle-integrity-gate.md.
set -euo pipefail

MANIFEST_NAME="MANIFEST.sha256"
NOTES_NAME="BUNDLE_NOTES.md"
TMPFILE=""

die() { echo "r770-bundle: $*" >&2; exit 1; }

cleanup() { [ -n "${TMPFILE:-}" ] && rm -f -- "$TMPFILE"; return 0; }
trap cleanup EXIT

# ── the single definition of what a manifest covers ──────────────────────────
# Everything excluded here is either derived (the manifest itself) or resume
# bookkeeping that must never cross the gap as payload.
bundle_files() {  # <dir> -> NUL-separated, sorted, ./-relative paths
    ( cd "$1" && find . -type f \
        ! -name "$MANIFEST_NAME" \
        ! -name '*.part' \
        ! -path './.stamps/*' \
        -print0 | sort -z )
}

part_files() {  # <dir> -> newline-separated relative paths of incomplete downloads
    ( cd "$1" && find . -type f -name '*.part' | sort )
}

manifest_paths() {  # <manifest> -> one path per line
    sed -e 's/^[0-9a-f]\{64\}  //' "$1"
}

# ── reporting ────────────────────────────────────────────────────────────────
FAILS=0
WARNS=0
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
warn() { echo "WARN  $*"; WARNS=$((WARNS + 1)); }
pass() { echo "ok    $*"; }

# ── manifest ─────────────────────────────────────────────────────────────────
cmd_manifest() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: r770-bundle.sh manifest <bundle-dir>"
    [ -d "$dir" ] || die "not a directory: $dir"

    local parts
    parts=$(part_files "$dir")
    if [ -n "$parts" ]; then
        printf '%s\n' "$parts" | sed 's/^/  /' >&2
        die "incomplete download(s) present — rerun r770-offline-fetch.sh before generating a manifest"
    fi

    local -a files=()
    mapfile -d '' -t files < <(bundle_files "$dir")
    [ "${#files[@]}" -gt 0 ] ||
        die "nothing to hash under $dir — refusing to write an empty manifest"

    # Hash into a temp file OUTSIDE the bundle. Writing it inside would make the
    # temp file part of its own input — the defect class this command replaces.
    TMPFILE=$(mktemp)
    ( cd "$dir" && printf '%s\0' "${files[@]}" | xargs -0 sha256sum ) > "$TMPFILE"
    chmod 644 "$TMPFILE"
    mv -- "$TMPFILE" "$dir/$MANIFEST_NAME"
    TMPFILE=""

    echo "wrote $dir/$MANIFEST_NAME — ${#files[@]} file(s), $(du -sh "$dir" | cut -f1) on disk"
}

# ── verify ───────────────────────────────────────────────────────────────────
check_manifest_sane() {  # <manifest>
    local m=$1 n backslash=$'\\'
    # Detect paths GNU sha256sum escaped (leading backslash). Matched as a
    # FIXED string against the first character of each line, because the
    # regex spellings are both bad: a doubled backslash draws SC1003, and a
    # bracketed one is a syntax error under ugrep, which some hosts install
    # as grep — and a check that errors out fails silently, which is worse
    # than no check at all.
    if cut -c1 "$m" | grep -qF "$backslash"; then
        fail "$MANIFEST_NAME holds escaped path(s) — a filename contains a backslash or newline; rename it and regenerate"
    fi
    if manifest_paths "$m" | grep -qx -- '-'; then
        fail "$MANIFEST_NAME contains a '-' entry: it was generated from empty input and verifies nothing"
        # Stop here. To sha256sum, '-' means stdin, so checking this manifest
        # blocks forever waiting on a terminal — the same defect wearing a
        # different hat, and it only shows up when stdin is open (i.e. for a
        # human running this by hand, not under a test harness).
        return 1
    fi
    n=$(wc -l < "$m")
    pass "$MANIFEST_NAME parses — $n entries"
}

check_hashes() {  # <dir>
    local out rc=0
    out=$( cd "$1" && sha256sum -c --quiet "$MANIFEST_NAME" 2>&1 < /dev/null ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "every manifested file is present and unmodified"
    else
        printf '%s\n' "$out" | sed 's/^/      /'
        fail "checksum verification failed — do not import this bundle"
    fi
}

# The blind spot in `sha256sum -c`: it proves listed files are intact but says
# nothing about files on disk the manifest never listed. That is exactly the
# Dell / licensed-appliance case, where the manifest predates the manual
# downloads.
check_coverage() {  # <dir> <manifest>
    local extra
    extra=$( comm -23 \
        <(bundle_files "$1" | tr '\0' '\n' | sort) \
        <(manifest_paths "$2" | sort) )
    if [ -n "$extra" ]; then
        printf '%s\n' "$extra" | sed 's/^/      /'
        fail "the file(s) above are on disk but not in $MANIFEST_NAME — regenerate it: r770-bundle.sh manifest $1"
    else
        pass "no unmanifested files — manual additions are covered"
    fi
}

check_parts() {  # <dir>
    local parts
    parts=$(part_files "$1")
    if [ -n "$parts" ]; then
        printf '%s\n' "$parts" | sed 's/^/      /'
        fail "incomplete download(s) in the bundle — rerun r770-offline-fetch.sh, then regenerate the manifest"
    else
        pass "no incomplete downloads"
    fi
}

# BUNDLE_NOTES.md is where the fetch script records per-item failures. Runbook
# Step 5 makes unresolved WARN lines a gate; this is that gate. They are
# advisory by default because some are legitimately dispositioned ("ET branch
# retired, accepted") — --strict is what refuses to let them slide.
check_notes() {  # <dir>
    local notes="$1/$NOTES_NAME" n
    if [ ! -f "$notes" ]; then
        warn "$NOTES_NAME missing — the version record and import order travel in it"
        return
    fi
    n=$(grep -c 'WARN' "$notes" || true)
    if [ "$n" -gt 0 ]; then
        grep -n 'WARN' "$notes" | sed 's/^/      /'
        warn "$n WARN line(s) in $NOTES_NAME — disposition each before the media leaves staging"
    else
        pass "$NOTES_NAME has no WARN lines"
    fi
}

# The two categories no script can fetch: Dell firmware (needs the service tag)
# and licensed GNS3 appliances (need vendor accounts). A bundle with only the
# README in each is a valid state — it just is not finished.
check_manual() {  # <dir>
    local dir=$1 d n
    for d in dell gns3/appliances; do
        if [ ! -d "$dir/$d" ]; then
            warn "$d/ is missing — the manual-download category is not staged"
            continue
        fi
        n=$(find "$dir/$d" -type f ! -name 'README.txt' | wc -l)
        if [ "$n" -eq 0 ]; then
            warn "$d/ holds only README.txt — manual downloads not staged (see that README)"
        else
            pass "$d/ has $n staged file(s)"
        fi
    done
}

# A list file without its payload -- or a payload with no list file -- means the
# bundle cannot be imported. import-bundle.md step 3b docker-loads the payload and
# then verifies the loaded tags against the list; either half alone is useless.
#
# This is the difference between CONSISTENCY and COMPLETENESS. The rest of verify
# proves the manifest matches the disk. It cannot notice that something which
# should be there isn't, and the manifest regeneration the workflow mandates after
# manual additions would otherwise launder a lost payload into "PASS - bundle is
# complete, unmodified and ready to transfer". Reported by review on PR #1 and
# reproduced before this check existed.
first_match() {  # <dir> <glob relative to dir> -> prints the first non-empty match
    local d=$1 g=$2 f
    for f in "$d"/$g; do [ -s "$f" ] && { printf '%s' "$f"; return 0; }; done
    return 1
}

check_required() {  # <dir>
    local dir=$1 pair list payload have_list have_payload
    for pair in \
        "malcolm/image-list.txt|malcolm/malcolm-images-*.tar.gz" \
        "docker/monitoring-image-list.txt|docker/monitoring-images.tar.gz" \
        "gns3/docker-nodes/image-list.txt|gns3/docker-nodes/gns3-node-images.tar.gz"
    do
        list="${pair%%|*}"
        payload="${pair#*|}"
        have_list=0;   [ -s "$dir/$list" ] && have_list=1
        have_payload=0; first_match "$dir" "$payload" >/dev/null 2>&1 && have_payload=1

        if [ "$have_list" -eq 1 ] && [ "$have_payload" -eq 1 ]; then
            pass "$list has its payload"
        elif [ "$have_list" -eq 0 ] && [ "$have_payload" -eq 0 ]; then
            :   # category never fetched -- a legitimate bundle shape, not an error
        elif [ "$have_payload" -eq 0 ]; then
            fail "$list is present but $payload is missing — this bundle cannot import that category"
        else
            fail "$payload is present but $list is missing — import cannot verify the loaded tags"
        fi
    done
}

summary() {  # <strict>
    echo
    if [ "$FAILS" -gt 0 ]; then
        echo "RESULT: FAIL — $FAILS failure(s), $WARNS warning(s). Do not import this bundle."
        exit 1
    fi
    if [ "$WARNS" -gt 0 ]; then
        if [ "$1" -eq 1 ]; then
            echo "RESULT: FAIL (--strict) — $WARNS warning(s) left undispositioned."
            exit 1
        fi
        echo "RESULT: PASS WITH WARNINGS — $WARNS warning(s) to disposition."
        exit 2
    fi
    echo "RESULT: PASS — bundle is complete, unmodified and ready to transfer."
    exit 0
}

cmd_verify() {
    local dir="" strict=0
    while [ $# -gt 0 ]; do
        case $1 in
            --strict) strict=1 ;;
            -*)       die "unknown option: $1" ;;
            *)        [ -z "$dir" ] || die "unexpected argument: $1"; dir=$1 ;;
        esac
        shift
    done
    [ -n "$dir" ] || die "usage: r770-bundle.sh verify <bundle-dir> [--strict]"
    [ -d "$dir" ] || die "not a directory: $dir"

    echo "Verifying bundle: $dir"
    local manifest="$dir/$MANIFEST_NAME"
    if [ ! -s "$manifest" ]; then
        fail "$MANIFEST_NAME is missing or empty — this bundle cannot be trusted"
        summary "$strict"
    fi

    if ! check_manifest_sane "$manifest"; then
        summary "$strict"
    fi
    check_hashes   "$dir"
    check_coverage "$dir" "$manifest"
    check_parts    "$dir"
    check_required "$dir"
    check_notes    "$dir"
    check_manual   "$dir"
    summary "$strict"
}

usage() {
    sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

case "${1:-}" in
    manifest)          shift; cmd_manifest "$@" ;;
    verify)            shift; cmd_verify   "$@" ;;
    -h|--help|help|"") usage ;;
    *)                 die "unknown subcommand: $1 (try --help)" ;;
esac
