#!/usr/bin/env bats
#
# The fetch downloads for hours and cannot run in a sandbox, so these tests
# cover only its SELECTION logic: which stages a given command line runs, in
# what order, and that --list/--dry-run touch no network. One real section
# (manual) is run for real -- it writes a README and nothing else.
#
# Every network tool is stubbed to log and fail, so an unexpected download
# attempt shows up as a line in $NET rather than as a hang.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-offline-fetch.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    NET="$BATS_TEST_TMPDIR/net.log"; : > "$NET"
    export BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
    export SEED_FROM=none
    export FETCH_NET_LOG="$NET"
    stub docker 'case "$1" in --version) echo "Docker version 29.8.0";; *) echo "docker $*" >> "$FETCH_NET_LOG"; exit 1;; esac'
    stub curl   'echo "curl $*" >> "$FETCH_NET_LOG"; exit 7'
    stub wget   'echo "wget $*" >> "$FETCH_NET_LOG"; exit 4'
    PATH="$BIN:$PATH"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

# load_fn <script> <fn> -- eval just that function's literal definition from
# the shipped script, so a test can call the real code without running the
# rest of the file (which would touch the network). Fails loudly if the
# function is not found, rather than silently defining nothing.
load_fn() {
    local out
    out="$(awk -v fn="$2" '''
        $0 ~ "^"fn"\\(\\) \\{" { p=1 }
        p { print }
        p && /^}/ { exit }
    ''' "$1")"
    [ -n "$out" ] || return 1
    eval "$out"
}

# load_seed_fns -- eval seed() (via load_fn) plus hand-written have()/note()
# stand-ins, since load_fn's awk extractor can't pull either out of the
# shipped script as-is: have() has extra alignment spaces before "{" (breaks
# the "fn() {" anchor), and note()'s one-line body has no "}"-starting line
# to stop on. Keep these two stand-ins in sync with the real definitions at
# scripts/r770-offline-fetch.sh's have() (~line 241) and note() (~line 158).
load_seed_fns() {
    load_fn "$SCRIPT" seed || { echo "seed not found in $SCRIPT"; return 1; }
    have() { [ "${FORCE:-0}" = "0" ] && [ -s "$1" ]; }
    note() { echo "- $*" >> "$NOTES"; echo ">> $*"; }
}

ALL="preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual manifest"

# selected <output> -- the stage names the dry run says it would execute, in order
selected() { echo "$1" | grep -oE '^\s*(would run|run) +[a-z0-9]+' | awk '{print $NF}' | tr '\n' ' ' | sed 's/ $//'; }

@test "--list names every stage in fixed order" {
    run "$SCRIPT" --list
    echo "$output"
    [ "$status" -eq 0 ]
    for s in $ALL; do [[ "$output" == *"$s"* ]]; done
    [ "$(echo "$output" | grep -oE '^\s*[a-z0-9]+' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" = "$ALL" ]
    [ ! -s "$NET" ]
}

@test "--list shows a stage as done when its completion marker exists" {
    mkdir -p "$BUNDLE_DIR/.stamps" "$BUNDLE_DIR/dell"
    touch "$BUNDLE_DIR/.stamps/01-apt.done"; echo x > "$BUNDLE_DIR/dell/README.txt"
    run "$SCRIPT" --list
    echo "$output"
    [[ "$(echo "$output" | grep -E '^\s*apt ')" == *done* ]]
    [[ "$(echo "$output" | grep -E '^\s*manual ')" == *done* ]]
    [[ "$(echo "$output" | grep -E '^\s*iso ')" != *done* ]]
}

@test "--dry-run with no selection would run every stage, in order, touching nothing" {
    run "$SCRIPT" --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(selected "$output")" = "$ALL" ]
    [ ! -s "$NET" ]
}

@test "--only runs the named stages in the fixed order, and never implies manifest" {
    run "$SCRIPT" --only enrichment,apt --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(selected "$output")" = "apt enrichment" ]
}

@test "--skip removes stages and keeps the rest in order" {
    run "$SCRIPT" --skip docs,manifest,preflight --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(selected "$output")" = "apt iso malcolm monitoring gns3 appliances enrichment manual" ]
}

@test "an unknown stage name is rejected by name, before anything runs" {
    run "$SCRIPT" --only nope --dry-run
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nope"* ]]
    [ ! -s "$NET" ]
}

@test "an unknown option is rejected rather than ignored" {
    run "$SCRIPT" --bogus
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--bogus"* ]]
}

@test "--only manual runs for real: writes the Dell README, touches no network, runs no manifest" {
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/dell/README.txt" ]
    [ ! -e "$BUNDLE_DIR/MANIFEST.sha256" ]
    [ ! -s "$NET" ]
}

@test "the Dell README no longer asks for perccli (removed 2026-09-23)" {
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    run grep -ci 'perccli' "$BUNDLE_DIR/dell/README.txt"
    [ "$output" = "0" ]
}

@test "a sectioned run appends to BUNDLE_NOTES.md instead of wiping the full run's notes" {
    mkdir -p "$BUNDLE_DIR"
    printf '# earlier full run\n- Malcolm images saved\n' > "$BUNDLE_DIR/BUNDLE_NOTES.md"
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'Malcolm images saved' "$BUNDLE_DIR/BUNDLE_NOTES.md"
    grep -qE 'rerun|section' "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

@test "resolve_latest_tag survives grep -m1 closing the pipe early under set -euo pipefail" {
    # Reproduces the VyOS-block defect that killed the fetch on 2026-09-08 and
    # again on 2026-09-15: grep -m1 exits right after its first match, closing
    # its read end while curl may still be writing; unguarded, curl's
    # resulting EPIPE (exit 23) kills the whole fetch under
    # set -euo pipefail. The stub curl writes a match line, then ~500k lines
    # of filler -- far past the pipe buffer -- so the race resolves the same
    # way every run.
    load_fn "$SCRIPT" resolve_latest_tag || { echo "resolve_latest_tag not found in $SCRIPT"; false; }
    stub curl 'printf "%s\n" "{\"tag_name\": \"2026.09.01-0034-rolling\"}"; seq 1 500000 | sed "s/^/padding /"'
    harness="$BATS_TEST_TMPDIR/harness.sh"
    {
        echo 'set -euo pipefail'
        declare -f resolve_latest_tag
        echo 'TAG=$(resolve_latest_tag http://fake)'
        echo 'echo "TAG=$TAG"'
    } > "$harness"
    run env PATH="$BIN:$PATH" bash "$harness"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TAG=2026.09.01-0034-rolling"* ]]
}

@test "the VyOS tag lookup goes through resolve_latest_tag, not a bare unguarded pipe" {
    run grep -c 'VYOS_TAG=\$(resolve_latest_tag' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── verify_iso_signature() — Ubuntu ISO GPG check ────────────────────────────

@test "verify_iso_signature fails loudly when gpg is not installed" {
    load_fn "$SCRIPT" verify_iso_signature
    UBUNTU_KEYRING="$BATS_TEST_TMPDIR/keyring.gpg"; echo x > "$UBUNTU_KEYRING"
    mkdir -p "$BUNDLE_DIR/isos"
    PATH="$BIN" run verify_iso_signature "$BUNDLE_DIR/isos"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"gpg not found"* ]]
}

@test "verify_iso_signature fails loudly when the keyring file is missing or empty" {
    load_fn "$SCRIPT" verify_iso_signature
    stub gpg 'exit 0'
    mkdir -p "$BUNDLE_DIR/isos"
    UBUNTU_KEYRING="$BATS_TEST_TMPDIR/does-not-exist.gpg"
    run verify_iso_signature "$BUNDLE_DIR/isos"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"UBUNTU_KEYRING"* ]]
    [[ "$output" == *"not found or empty"* ]]
}

@test "verify_iso_signature fails loudly when gpg --verify rejects the signature" {
    load_fn "$SCRIPT" verify_iso_signature
    stub gpg 'exit 1'
    UBUNTU_KEYRING="$BATS_TEST_TMPDIR/keyring.gpg"; echo x > "$UBUNTU_KEYRING"
    mkdir -p "$BUNDLE_DIR/isos"
    echo x > "$BUNDLE_DIR/isos/SHA256SUMS"; echo x > "$BUNDLE_DIR/isos/SHA256SUMS.gpg"
    run verify_iso_signature "$BUNDLE_DIR/isos"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED"* ]]
}

@test "verify_iso_signature succeeds and calls gpg with the expected local-keyring flags" {
    load_fn "$SCRIPT" verify_iso_signature
    export ARGLOG="$BATS_TEST_TMPDIR/gpg-args.log"
    stub gpg 'echo "$*" > "$ARGLOG"; exit 0'
    UBUNTU_KEYRING="$BATS_TEST_TMPDIR/keyring.gpg"; echo x > "$UBUNTU_KEYRING"
    mkdir -p "$BUNDLE_DIR/isos"
    echo x > "$BUNDLE_DIR/isos/SHA256SUMS"; echo x > "$BUNDLE_DIR/isos/SHA256SUMS.gpg"
    run verify_iso_signature "$BUNDLE_DIR/isos"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q -- "--no-default-keyring" "$ARGLOG"
    grep -q -- "--keyring $UBUNTU_KEYRING" "$ARGLOG"
    grep -q -- "--verify $BUNDLE_DIR/isos/SHA256SUMS.gpg $BUNDLE_DIR/isos/SHA256SUMS" "$ARGLOG"
}

@test "stage_iso calls verify_iso_signature before trusting SHA256SUMS" {
    run grep -c 'verify_iso_signature "\$B/isos"' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── seed() — cross-bundle reuse only when manifest-verified ──────────────────

@test "seed() reuses a cached file whose hash matches PREV_BUNDLE's MANIFEST.sha256" {
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/isos" "$B"
    echo "fake iso content" > "$PREV_BUNDLE/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    ( cd "$PREV_BUNDLE" && find . -type f | xargs sha256sum > MANIFEST.sha256 )
    run seed "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso" ]
    grep -q "manifest-verified" "$NOTES"
}

@test "seed() refuses to reuse a file when PREV_BUNDLE has no MANIFEST.sha256" {
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/isos" "$B"
    echo "fake iso content" > "$PREV_BUNDLE/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    run seed "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso" ]
    grep -q "no MANIFEST.sha256" "$NOTES"
}

@test "seed() refuses to reuse a file not listed in PREV_BUNDLE's MANIFEST.sha256" {
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/isos" "$B"
    echo "fake iso content" > "$PREV_BUNDLE/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "deadbeef  ./isos/some-other-file" > "$PREV_BUNDLE/MANIFEST.sha256"
    run seed "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso" ]
    grep -q "not listed in" "$NOTES"
}

@test "seed() refuses to reuse a file whose content no longer matches its manifest entry" {
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/isos" "$B"
    echo "fake iso content" > "$PREV_BUNDLE/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    ( cd "$PREV_BUNDLE" && find . -type f | xargs sha256sum > MANIFEST.sha256 )
    echo "corrupted after the manifest was written" >> "$PREV_BUNDLE/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    run seed "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$B/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso" ]
    grep -q "failed MANIFEST.sha256 verification" "$NOTES"
}

@test "seed() still exempts apt/ and enrichment/ from reuse regardless of manifest state" {
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/apt" "$B"
    echo "some deb" > "$PREV_BUNDLE/apt/pkg.deb"
    ( cd "$PREV_BUNDLE" && find . -type f | xargs sha256sum > MANIFEST.sha256 )
    run seed "$B/apt/pkg.deb"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$B/apt/pkg.deb" ]
}

@test "seed() still succeeds when a manifested file's path is a prefix of another (sidecar checksum case)" {
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/gns3/appliances" "$B"
    echo "iso bytes" > "$PREV_BUNDLE/gns3/appliances/alpine-virt-3.20.0-x86_64.iso"
    echo "sha bytes" > "$PREV_BUNDLE/gns3/appliances/alpine-virt-3.20.0-x86_64.iso.sha256"
    ( cd "$PREV_BUNDLE" && find . -type f | xargs sha256sum > MANIFEST.sha256 )
    run seed "$B/gns3/appliances/alpine-virt-3.20.0-x86_64.iso"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$B/gns3/appliances/alpine-virt-3.20.0-x86_64.iso" ]
}

@test "seed() refuses a file that is only a path-prefix of a DIFFERENT manifested file" {
    # Regression for a review finding: an unmanifested "isos/SHA256SUMS" must
    # not be accepted merely because its own manifested "isos/SHA256SUMS.gpg"
    # sidecar shares its name as a prefix. A naive substring match on the
    # manifest would find the .gpg line, verify ITS hash (which trivially
    # passes since that file is intact), and then wrongly seed SHA256SUMS
    # under a hash that was never actually checked against it.
    load_seed_fns
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/isos" "$B"
    echo "gpg signature bytes" > "$PREV_BUNDLE/isos/SHA256SUMS.gpg"
    echo "tampered checksums file" > "$PREV_BUNDLE/isos/SHA256SUMS"
    # Manifest only the .gpg sidecar -- SHA256SUMS itself was never manifested.
    ( cd "$PREV_BUNDLE" && sha256sum isos/SHA256SUMS.gpg > MANIFEST.sha256 )
    run seed "$B/isos/SHA256SUMS"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$B/isos/SHA256SUMS" ]
    grep -q "not listed in" "$NOTES"
}

# ── seed_glob() — reports a partial seed instead of hiding it ────────────────

@test "seed_glob() returns non-zero when one matched file fails verification, but still seeds the rest" {
    load_seed_fns
    load_fn "$SCRIPT" seed_glob
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/gns3/wheelhouse" "$B"
    echo "good wheel" > "$PREV_BUNDLE/gns3/wheelhouse/gns3-server-0.0.0-fixture.whl"
    echo "bad wheel"  > "$PREV_BUNDLE/gns3/wheelhouse/dep-1.0.whl"
    ( cd "$PREV_BUNDLE" && find . -type f | xargs sha256sum > MANIFEST.sha256 )
    echo "corrupted after the manifest was written" >> "$PREV_BUNDLE/gns3/wheelhouse/dep-1.0.whl"
    run seed_glob "gns3/wheelhouse/*"
    echo "$output"
    [ "$status" -ne 0 ]
    [ -s "$B/gns3/wheelhouse/gns3-server-0.0.0-fixture.whl" ]
    [ ! -e "$B/gns3/wheelhouse/dep-1.0.whl" ]
}

@test "seed_glob() returns 0 when every matched file verifies" {
    load_seed_fns
    load_fn "$SCRIPT" seed_glob
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    PREV_BUNDLE="$BATS_TEST_TMPDIR/prev"
    mkdir -p "$PREV_BUNDLE/gns3/wheelhouse" "$B"
    echo "good wheel" > "$PREV_BUNDLE/gns3/wheelhouse/gns3-server-0.0.0-fixture.whl"
    echo "also good"  > "$PREV_BUNDLE/gns3/wheelhouse/dep-1.0.whl"
    ( cd "$PREV_BUNDLE" && find . -type f | xargs sha256sum > MANIFEST.sha256 )
    run seed_glob "gns3/wheelhouse/*"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$B/gns3/wheelhouse/gns3-server-0.0.0-fixture.whl" ]
    [ -s "$B/gns3/wheelhouse/dep-1.0.whl" ]
}

@test "stage_gns3 only trusts a seeded wheelhouse as complete when seed_glob reports full success" {
    run grep -c 'if seed_glob "gns3/wheelhouse/\*" && ls' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "the bare VyOS and Alpine seed_glob calls are guarded against set -e on a partial seed" {
    run grep -cE 'seed_glob "gns3/appliances/(vyos|alpine-virt)[^"]*" \|\| true' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -eq 4 ]
}

# ── docs_mirror() — wget exit-code classification ────────────────────────────

# load_docs_mirror -- eval docs_mirror() (via load_fn) plus hand-written
# stamped()/stamp_done()/note() stand-ins, and set up a scratch bundle dir.
load_docs_mirror() {
    load_fn "$SCRIPT" docs_mirror || { echo "docs_mirror not found in $SCRIPT"; return 1; }
    stamped()    { [ -f "$B/.stamps/$1" ]; }
    stamp_done() { touch "$B/.stamps/$1"; }
    note()       { echo "- $*" >> "$B/NOTES"; echo ">> $*"; }
    B="$BATS_TEST_TMPDIR/b"; FORCE=0
    mkdir -p "$B/.stamps" "$B/docs"
}

# stub_docs_wget -- stub wget (exit code from $WGET_RC; when $WGET_PAGES=1,
# writes <the -P dir>/host/index.html; writes $WGET_LOG_LINES into the -o
# file) and timeout (drops the timeout arg, execs the rest so wget's exit
# code passes straight through).
stub_docs_wget() {
    stub wget '
        p=""; o=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -P) p="$2"; shift 2 ;;
                -o) o="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ "${WGET_PAGES:-0}" = "1" ]; then
            mkdir -p "$p/host"
            touch "$p/host/index.html"
        fi
        if [ -n "$o" ]; then
            printf "%s\n" "${WGET_LOG_LINES:-}" > "$o"
        fi
        exit "${WGET_RC:-0}"
    '
    stub timeout 'shift; "$@"'
}

@test "docs_mirror: wget exit 0 mirrors and stamps done" {
    load_docs_mirror
    stub_docs_wget
    export WGET_RC=0
    run docs_mirror malcolm "https://malcolm.fyi/docs/"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docs: malcolm mirrored"* ]]
    [ -f "$B/.stamps/08-docs-malcolm.done" ]
}

@test "docs_mirror: wget exit 8 with pages on disk classifies upstream 4xx as complete, no WARN" {
    load_docs_mirror
    stub_docs_wget
    export WGET_RC=8 WGET_PAGES=1
    export WGET_LOG_LINES=$'ERROR 404: Not Found.\nERROR 404: Not Found.'
    run docs_mirror malcolm "https://malcolm.fyi/docs/"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mirrored — 2 upstream link(s) returned HTTP 4xx"* ]]
    [[ "$output" != *"WARN"* ]]
    [ -f "$B/.stamps/08-docs-malcolm.done" ]
}

@test "docs_mirror: wget exit 8 with nothing mirrored warns and does not stamp" {
    load_docs_mirror
    stub_docs_wget
    export WGET_RC=8 WGET_PAGES=0
    run docs_mirror malcolm "https://malcolm.fyi/docs/"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"server refused (wget exit 8"* ]]
    [ ! -f "$B/.stamps/08-docs-malcolm.done" ]
}

@test "docs_mirror: wget exit 4 warns of a network error and does not stamp" {
    load_docs_mirror
    stub_docs_wget
    export WGET_RC=4
    run docs_mirror malcolm "https://malcolm.fyi/docs/"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"network error"* ]]
    [ ! -f "$B/.stamps/08-docs-malcolm.done" ]
}

@test "docs_mirror: wget exit 124 warns of a timeout and does not stamp" {
    load_docs_mirror
    stub_docs_wget
    export WGET_RC=124
    run docs_mirror malcolm "https://malcolm.fyi/docs/"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"timed out after 900 s"* ]]
    [ ! -f "$B/.stamps/08-docs-malcolm.done" ]
}

@test "docs_mirror: already stamped skips without calling wget" {
    load_docs_mirror
    touch "$B/.stamps/08-docs-malcolm.done"
    run docs_mirror malcolm "https://malcolm.fyi/docs/"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped — complete in a previous run"* ]]
    [ ! -s "$NET" ]
}

@test "zeek docs are fetched as the Read the Docs htmlzip, not mirrored from docs.zeek.org" {
    run grep -q 'app.readthedocs.org/projects/zeek-docs/downloads/htmlzip/current/' "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -c 'docs_mirror zeek' "$SCRIPT"
    [ "$output" -eq 0 ]
}

# ── APT repo metadata (2026-09-25) ────────────────────────────────────────────
# Without a Release file apt probes Packages.{xz,bz2,lzma} and prints an Err line
# for each on the R770. With a Release that lists only Packages.gz, apt skips the
# index entirely and the repo is silently EMPTY while 'apt update' exits 0.
# The Release must list the uncompressed Packages too.

@test "the APT stage writes Packages, Packages.gz and a Release that is not self-hashed" {
    grep -q 'dpkg-scanpackages --multiversion \. /dev/null > Packages$' "$SCRIPT"
    grep -q 'gzip -9 -kf Packages$' "$SCRIPT"
    grep -q 'apt-ftparchive release \. > /tmp/Release && mv /tmp/Release Release$' "$SCRIPT"
    grep -q 'apt-get -y install -qq dpkg-dev apt-utils' "$SCRIPT"
}

@test "a flat repo built that way is actually usable by apt (no Err, no skipped index, package visible)" {
    command -v apt-ftparchive >/dev/null && command -v dpkg-deb >/dev/null || skip "apt-utils/dpkg-deb not installed"
    X="$BATS_TEST_TMPDIR/aptrepo"; mkdir -p "$X/repo" "$X/pkg/DEBIAN" "$X/lists/partial" "$X/cache/archives/partial"
    printf 'Package: simlab-probe\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@t>\nDescription: probe\n' > "$X/pkg/DEBIAN/control"
    dpkg-deb -b "$X/pkg" "$X/repo/simlab-probe_1.0_all.deb" >/dev/null
    # same shape as the script: uncompressed Packages, gzip -k, Release written outside then moved in
    ( cd "$X/repo" && apt-ftparchive packages . > Packages 2>/dev/null && gzip -9 -kf Packages \
        && apt-ftparchive release . > "$X/Release.tmp" && mv "$X/Release.tmp" Release )
    grep -q ' Packages$' "$X/repo/Release"
    grep -q ' Packages.gz$' "$X/repo/Release"
    ! grep -q ' Release$' "$X/repo/Release"
    echo "deb [trusted=yes] file:$X/repo ./" > "$X/sources.list"
    O=(-o "Dir::Etc::sourcelist=$X/sources.list" -o Dir::Etc::sourceparts=- -o "Dir::State::Lists=$X/lists"
       -o "Dir::Cache=$X/cache" -o Acquire::Languages=none -o Debug::NoLocking=1 -o Dir::State::status=/dev/null)
    run apt-get "${O[@]}" update
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Err:"* ]]
    [[ "$output" != *"Skipping acquire"* ]]
    run apt-cache "${O[@]}" policy simlab-probe
    [[ "$output" == *"Candidate: 1.0"* ]]
}
