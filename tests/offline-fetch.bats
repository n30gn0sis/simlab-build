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

ALL="preflight apt iso malcolm monitoring gns3 appliances enrichment docs manual site manifest"

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
    [ "$(selected "$output")" = "apt iso malcolm monitoring gns3 appliances enrichment manual site" ]
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

@test "a sectioned run appends to BUNDLE_NOTES.md instead of wiping the full run's notes" {
    mkdir -p "$BUNDLE_DIR"
    printf '# earlier full run\n- Malcolm images saved\n' > "$BUNDLE_DIR/BUNDLE_NOTES.md"
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'Malcolm images saved' "$BUNDLE_DIR/BUNDLE_NOTES.md"
    grep -qE 'rerun|section' "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

# ── site/ stage — copies this repo's scripts/config/docs-analyst-wiki into the bundle ──
#
# 2026-09-26 review fix: the old fixture was a plain directory, no git. Under
# `r770-build-bundle.sh --pack`, the unpacked scripts run flat out of a
# `mktemp -d`, so SITE_SRC_ROOT's default resolved to /tmp -- and the old
# stage_site() would happily ship whatever was lying around there (or "0
# files, exit 0" if nothing was), because missing trees were `continue`d
# past rather than refused. stage_site() now refuses outright unless
# SITE_SRC_ROOT is a real git work tree that looks like this repo, has all
# three trees, and yields at least one file; and it ships content read from
# HEAD, never the working tree or a dirty index, so these fixtures build a
# real (tiny) git repo rather than a bare directory.

gitc() { git -c user.name=test -c user.email=test@test.invalid "$@"; }

# setup_site_repo <dir> -- a real git repo standing in for a checkout: tracked
# scripts/config/docs-analyst-wiki content, including the marker file
# (scripts/r770-offline-fetch.sh) stage_site() uses to confirm SITE_SRC_ROOT
# really is a repo like this one. Also plants five TRACKED secret-looking
# files -- two of them outside config/, which the old denylist never looked
# at -- to prove the widened filter still excludes them even though they are
# committed (defence in depth, not merely ".gitignore already kept them
# out"). Everything is committed, so HEAD and the working tree start
# identical; individual tests dirty it further as needed.
#
# Deliberately does NOT plant a file literally named ".git" as a denylist
# case (2026-09-26 re-review, item 5): git refuses to track any path
# component named ".git" at all -- `git add -A` on one silently adds
# nothing, so an assertion that it isn't shipped passes whether or not
# site_excluded's ".git" pattern does anything. See the direct
# site_excluded() unit test below instead.
setup_site_repo() {
    local src="$1"
    mkdir -p "$src/scripts" "$src/config/nginx" "$src/docs/analyst-wiki"
    printf '#!/usr/bin/env bash\n' > "$src/scripts/r770-offline-fetch.sh"
    printf '#!/usr/bin/env bash\necho hi\n' > "$src/scripts/hello.sh"
    chmod +x "$src/scripts/hello.sh"
    echo "not executable" > "$src/scripts/README.txt"
    echo "server { }"   > "$src/config/nginx/site.conf"
    echo "# wiki page"  > "$src/docs/analyst-wiki/index.md"
    echo "SECRET=1"     > "$src/config/x.env"                    # *.env, inside config/
    echo "fake key"     > "$src/config/y.key"                    # *.key, inside config/
    echo "SECRET=2"     > "$src/scripts/outside.env"              # *.env, OUTSIDE config/
    echo "fake cert"    > "$src/docs/analyst-wiki/site.pem"       # *.pem, OUTSIDE config/
    echo "fake creds"   > "$src/scripts/htpasswd"                 # htpasswd, OUTSIDE config/
    echo "fake creds"   > "$src/docs/analyst-wiki/.htpasswd"      # .htpasswd, OUTSIDE config/
    git -C "$src" init -q
    gitc -C "$src" add -A
    gitc -C "$src" commit -q -m init
}

@test "--only site ships only TRACKED content, excludes secrets anywhere (not just config/), keeps +x, writes the note, touches no network" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/site/scripts/hello.sh" ]
    [ -x "$BUNDLE_DIR/site/scripts/hello.sh" ]
    [ ! -x "$BUNDLE_DIR/site/scripts/README.txt" ]
    [ -s "$BUNDLE_DIR/site/config/nginx/site.conf" ]
    [ -s "$BUNDLE_DIR/site/docs/analyst-wiki/index.md" ]
    [ ! -e "$BUNDLE_DIR/site/config/x.env" ]
    [ ! -e "$BUNDLE_DIR/site/config/y.key" ]
    [ ! -e "$BUNDLE_DIR/site/scripts/outside.env" ]
    [ ! -e "$BUNDLE_DIR/site/docs/analyst-wiki/site.pem" ]
    [ ! -e "$BUNDLE_DIR/site/scripts/htpasswd" ]
    [ ! -e "$BUNDLE_DIR/site/docs/analyst-wiki/.htpasswd" ]
    grep -qE 'site/: 5 files from [0-9a-f]{7,40} copied' "$BUNDLE_DIR/BUNDLE_NOTES.md"
    [ ! -e "$BUNDLE_DIR/MANIFEST.sha256" ]
    [ ! -s "$NET" ]
}

@test "site_excluded() unit: .git anywhere, secret extensions anywhere, and an ordinary script pass through" {
    load_fn "$SCRIPT" site_excluded || { echo "site_excluded not found in $SCRIPT"; false; }
    run site_excluded "a/.git/x"
    [ "$status" -eq 0 ]
    run site_excluded ".git"
    [ "$status" -eq 0 ]
    run site_excluded "x.p12"
    [ "$status" -eq 0 ]
    run site_excluded "sub/.htpasswd"
    [ "$status" -eq 0 ]
    run site_excluded "config/creds.pfx"
    [ "$status" -eq 0 ]
    run site_excluded "scripts/ok.sh"
    [ "$status" -eq 1 ]
}

@test "a real commit hash appears in the note" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    export SITE_SRC_ROOT="$SRC"
    local want; want="$(git -C "$SRC" rev-parse --short HEAD)"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qF "from $want copied" "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

@test "an untracked file under config/ is NOT shipped" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    echo "oops" > "$SRC/config/untracked.txt"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$BUNDLE_DIR/site/config/untracked.txt" ]
}

@test "a tracked file with an uncommitted edit ships the COMMITTED content, not the working-tree edit" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    echo "TAMPERED" > "$SRC/scripts/hello.sh"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    run cat "$BUNDLE_DIR/site/scripts/hello.sh"
    [[ "$output" != *"TAMPERED"* ]]
    [[ "$output" == *"echo hi"* ]]
}

@test "a dirty tree still ships committed content and leaves a WARN in the notes" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    echo "TAMPERED" > "$SRC/scripts/hello.sh"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'WARN: site/ built from a dirty tree; uncommitted edits NOT shipped' "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

@test "a clean tree leaves no dirty-tree WARN in the notes" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    ! grep -q 'dirty tree' "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

@test "a SITE_SRC_ROOT that doesn't look like this repo refuses, before touching git" {
    SRC="$BATS_TEST_TMPDIR/not-a-repo"
    mkdir -p "$SRC"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"r770-offline-fetch.sh"* ]]
    [ ! -d "$BUNDLE_DIR/site" ]
    [ ! -s "$NET" ]
}

@test "a SITE_SRC_ROOT that looks like this repo but is not a git work tree refuses" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    mkdir -p "$SRC/scripts" "$SRC/config" "$SRC/docs/analyst-wiki"
    touch "$SRC/scripts/r770-offline-fetch.sh"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"git work tree"* ]]
    [ ! -d "$BUNDLE_DIR/site" ]
}

@test "a missing tree (docs/analyst-wiki removed) refuses" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    rm -rf "$SRC/docs"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/analyst-wiki"* ]]
}

@test "0 tracked files under the three trees refuses, even though the identity marker exists" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    mkdir -p "$SRC/scripts" "$SRC/config" "$SRC/docs/analyst-wiki"
    touch "$SRC/scripts/r770-offline-fetch.sh"    # present, but UNTRACKED below
    git -C "$SRC" init -q
    gitc -C "$SRC" commit -q -m init --allow-empty
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0 files"* ]]
}

@test "a fetch with SITE_ARCHIVE and SITE_COMMIT (no work tree) builds site/ and notes the commit" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    local commit; commit="$(git -C "$SRC" rev-parse HEAD)"
    ARCHIVE="$BATS_TEST_TMPDIR/site.tar"
    git -C "$SRC" archive --format=tar HEAD -- scripts config docs/analyst-wiki > "$ARCHIVE"
    unset SITE_SRC_ROOT
    export SITE_ARCHIVE="$ARCHIVE" SITE_COMMIT="$commit"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/site/scripts/hello.sh" ]
    [ -x "$BUNDLE_DIR/site/scripts/hello.sh" ]
    [ ! -x "$BUNDLE_DIR/site/scripts/README.txt" ]
    [ ! -e "$BUNDLE_DIR/site/config/x.env" ]
    [ ! -e "$BUNDLE_DIR/site/scripts/htpasswd" ]
    grep -qF "from $commit copied" "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

@test "the startup site-source check fails fast, before any stage output, with neither a work tree nor SITE_ARCHIVE/SITE_COMMIT" {
    SRC="$BATS_TEST_TMPDIR/not-a-repo"
    mkdir -p "$SRC"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"r770-offline-fetch.sh"* ]]
    [[ "$output" != *"[0/11]"* ]]
    [[ "$output" != *"Staging container runtime"* ]]
    [ ! -s "$NET" ]
}

@test "a staged-but-uncommitted NEW file is not shipped, and leaves a dirty WARN instead of a FATAL" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    echo "brand new" > "$SRC/scripts/new-file.sh"
    git -C "$SRC" add scripts/new-file.sh    # staged, NOT committed -- HEAD does not have it yet
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$BUNDLE_DIR/site/scripts/new-file.sh" ]
    grep -q 'WARN: site/ built from a dirty tree; uncommitted edits NOT shipped' "$BUNDLE_DIR/BUNDLE_NOTES.md"
}

@test "a git rm --cached path still in HEAD IS shipped" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    git -C "$SRC" rm --cached -q scripts/hello.sh    # index no longer has it; HEAD and the working tree still do
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/site/scripts/hello.sh" ]
}

@test "a tracked symlink refuses, naming the path" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    ln -s /etc/passwd "$SRC/scripts/evil-link"
    git -C "$SRC" add scripts/evil-link
    gitc -C "$SRC" commit -q -m "add symlink"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/evil-link"* ]]
    [[ "$output" == *"symlink"* ]]
    [ ! -e "$BUNDLE_DIR/site" ]
}

@test "a tracked submodule (gitlink) refuses, naming the path" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    git -C "$SRC" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,config/fake-submodule
    gitc -C "$SRC" commit -q -m "add fake submodule"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"config/fake-submodule"* ]]
    [[ "$output" == *"submodule"* ]]
    [ ! -e "$BUNDLE_DIR/site" ]
}

@test "a refusal mid-build leaves no site.tmp and no partial site/, and a previous good site/ is untouched" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/site/scripts/hello.sh" ]
    local before; before="$(sha256sum "$BUNDLE_DIR/site/scripts/hello.sh" | cut -d' ' -f1)"

    ln -s /etc/passwd "$SRC/scripts/evil-link"
    git -C "$SRC" add scripts/evil-link
    gitc -C "$SRC" commit -q -m "add symlink -- should refuse without touching the prior good site/"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [ ! -d "$BUNDLE_DIR/site.tmp" ]
    [ -s "$BUNDLE_DIR/site/scripts/hello.sh" ]
    [ "$(sha256sum "$BUNDLE_DIR/site/scripts/hello.sh" | cut -d' ' -f1)" = "$before" ]
}

@test "the site stage always refreshes: a file removed at HEAD is not re-shipped from a prior copy" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    export SITE_SRC_ROOT="$SRC"
    run "$SCRIPT" --only site
    [ "$status" -eq 0 ]
    [ -s "$BUNDLE_DIR/site/scripts/hello.sh" ]
    gitc -C "$SRC" rm -q scripts/hello.sh
    gitc -C "$SRC" commit -q -m "remove hello.sh"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$BUNDLE_DIR/site/scripts/hello.sh" ]
}

# git_logging_stub -- a git on PATH that records every safe.directory value it
# is handed (one per line, in $BATS_TEST_TMPDIR/safe-dirs), then runs the real
# git unchanged.
git_logging_stub() {
    local real; real="$(command -v git)"
    stub git 'prev=""; for a; do case "$prev $a" in "-c safe.directory="*) printf "%s\n" "${a#safe.directory=}" >> "'"$BATS_TEST_TMPDIR"'/safe-dirs" ;; esac; prev=$a; done
exec "'"$real"'" "$@"'
}

@test "a scripts/..-style or symlinked SITE_SRC_ROOT is normalised: git gets the canonical path as safe.directory" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    local canon; canon="$(cd "$SRC" && pwd -P)"
    ln -s "$SRC" "$BATS_TEST_TMPDIR/site-link"
    git_logging_stub
    for root in "$SRC/scripts/.." "$BATS_TEST_TMPDIR/site-link"; do
        rm -f "$BATS_TEST_TMPDIR/safe-dirs"
        export SITE_SRC_ROOT="$root"
        run "$SCRIPT" --only site
        echo "[$root] $output"
        [ "$status" -eq 0 ]
        [ -s "$BATS_TEST_TMPDIR/safe-dirs" ]
        # every git call names the canonical path, and only it
        [ "$(sort -u "$BATS_TEST_TMPDIR/safe-dirs")" = "$canon" ]
    done
}

@test "a SITE_SRC_ROOT that cannot be entered refuses before touching git" {
    git_logging_stub
    export SITE_SRC_ROOT="$BATS_TEST_TMPDIR/does-not-exist"
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SITE_SRC_ROOT ($BATS_TEST_TMPDIR/does-not-exist) is not a directory that can be entered"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/safe-dirs" ]
    [ ! -d "$BUNDLE_DIR/site" ]
}

@test "a symlink inside SITE_ARCHIVE refuses, naming the path" {
    SRC="$BATS_TEST_TMPDIR/site-src"
    setup_site_repo "$SRC"
    local stage="$BATS_TEST_TMPDIR/archive-src"
    mkdir -p "$stage"
    git -C "$SRC" archive --format=tar HEAD -- scripts config docs/analyst-wiki | tar xf - -C "$stage"
    ln -s /etc/passwd "$stage/scripts/evil-link"
    ARCHIVE="$BATS_TEST_TMPDIR/site.tar"
    tar cf "$ARCHIVE" -C "$stage" scripts config docs
    unset SITE_SRC_ROOT
    export SITE_ARCHIVE="$ARCHIVE" SITE_COMMIT=0123456789abcdef
    run "$SCRIPT" --only site
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts/evil-link is a symlink in SITE_ARCHIVE"* ]]
    [ ! -e "$BUNDLE_DIR/site" ]
}

@test "--list shows the new site stage as always refreshed" {
    run "$SCRIPT" --list
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | grep -E '^\s*site ')" == *"runs every time"* ]]
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

# ── GNS3 docker-node archive — reused only when it holds exactly the pinned list ──
# A cached gns3-node-images.tar.gz (seeded from a previous bundle, or left by a
# same-day resume) was reused whenever it existed, so a newly pinned node image
# (strongSwan) never reached the bundle while the notes claimed it had.

load_node_fns() {
    load_fn "$SCRIPT" node_list_matches || { echo "node_list_matches not found in $SCRIPT"; return 1; }
    B="$BUNDLE_DIR"; mkdir -p "$B/gns3/docker-nodes"
    GNS3_NODE_IMAGES=("docker.io/library/alpine:latest" "quay.io/frrouting/frr:0.0.0-fixture" "docker.io/strongx509/strongswan:0.0.0-fixture")
}

@test "node_list_matches: the archive's image-list.txt equal to GNS3_NODE_IMAGES, in order, matches" {
    load_node_fns
    printf '%s\n' "${GNS3_NODE_IMAGES[@]}" > "$B/gns3/docker-nodes/image-list.txt"
    run node_list_matches
    [ "$status" -eq 0 ]
}

@test "node_list_matches: a list missing a newly pinned image does not match" {
    load_node_fns
    printf '%s\n' "${GNS3_NODE_IMAGES[@]:0:2}" > "$B/gns3/docker-nodes/image-list.txt"
    run node_list_matches
    [ "$status" -ne 0 ]
}

@test "node_list_matches: no image-list.txt does not match" {
    load_node_fns
    run node_list_matches
    [ "$status" -ne 0 ]
}

@test "stage 6f seeds the node image list, reuses the archive only when it matches, and drops a stale one" {
    run grep -c 'seed "$B/gns3/docker-nodes/image-list.txt"' "$SCRIPT"
    [ "$output" -ge 1 ]
    run grep -cE 'if have "\$B/gns3/docker-nodes/gns3-node-images.tar.gz" && node_list_matches; then' "$SCRIPT"
    [ "$output" -eq 1 ]
    run grep -c 'rm -f "$B/gns3/docker-nodes/gns3-node-images.tar.gz" "$B/gns3/docker-nodes/image-list.txt"' "$SCRIPT"
    [ "$output" -eq 1 ]
    run grep -cE 'appliances\) +\[ -s "\$B/gns3/docker-nodes/gns3-node-images.tar.gz" \] && node_list_matches' "$SCRIPT"
    [ "$output" -eq 1 ]
}

# ── free QEMU images chosen by their own .gns3a ──────────────────────────────
# The 2026-10-06 EC2 rehearsal: frr, tinycore-linux and openwrt definitions
# were bundled with no image, so they appeared in GNS3 and failed at boot.

# a registry-shaped definition: versions newest first, images keyed by filename
write_gns3a() {  # write_gns3a <file> <filename> <md5> <url> [compression]
    local comp=""
    [ -n "${5:-}" ] && comp=", \"compression\": \"$5\""
    cat > "$1" <<JSON
{"name": "fixture", "status": "stable",
 "images": [
  {"filename": "old-1.0.qcow2", "version": "1.0", "md5sum": "00000000000000000000000000000000", "direct_download_url": "https://example.invalid/old-1.0.qcow2"},
  {"filename": "$2", "version": "2.0", "md5sum": "$3", "direct_download_url": "$4"$comp}
 ],
 "versions": [
  {"name": "2.0", "images": {"hda_disk_image": "$2"}},
  {"name": "1.0", "images": {"hda_disk_image": "old-1.0.qcow2"}}
 ]}
JSON
}

load_gns3a_fns() {
    load_fn "$SCRIPT" gns3a_newest_image || { echo "gns3a_newest_image not found in $SCRIPT"; return 1; }
    load_fn "$SCRIPT" fetch_gns3a_image || { echo "fetch_gns3a_image not found in $SCRIPT"; return 1; }
    GNS3A_PY=(python3)       # the shipped default runs python3 inside PYTHON_BUILD_IMG
    B="$BUNDLE_DIR"; FORCE=0; NOTES="$BATS_TEST_TMPDIR/notes.log"; : > "$NOTES"
    mkdir -p "$B/gns3/definitions" "$B/gns3/appliances"
    have() { [ "${FORCE:-0}" = "0" ] && [ -s "$1" ]; }
    note() { echo "- $*" >> "$NOTES"; echo ">> $*"; }
    seed() { :; }
    # fetch <out> <url>: serve the url's basename from $SRV, log the url
    export SRV="$BATS_TEST_TMPDIR/srv"; mkdir -p "$SRV"
    fetch() { echo "fetch $2" >> "$FETCH_NET_LOG"; cp "$SRV/$(basename "$2")" "$1"; }
}

@test "gns3a_newest_image: picks the newest version's disk image and prints filename, md5, url, compression" {
    load_gns3a_fns
    write_gns3a "$B/gns3/definitions/x.gns3a" new-2.0.qcow2 0123456789abcdef0123456789abcdef https://example.invalid/new-2.0.qcow2
    run gns3a_newest_image "$B/gns3/definitions/x.gns3a"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "new-2.0.qcow2 0123456789abcdef0123456789abcdef https://example.invalid/new-2.0.qcow2 none" ]
}

@test "gns3a_newest_image: reports gzip compression, and a definition with no downloadable newest image fails" {
    load_gns3a_fns
    write_gns3a "$B/gns3/definitions/g.gns3a" new.img 0123456789abcdef0123456789abcdef https://example.invalid/new.img.gz gzip
    run gns3a_newest_image "$B/gns3/definitions/g.gns3a"
    [ "$status" -eq 0 ]
    [[ "$output" == *" gzip" ]]
    write_gns3a "$B/gns3/definitions/n.gns3a" new.img 0123456789abcdef0123456789abcdef ""
    run gns3a_newest_image "$B/gns3/definitions/n.gns3a"
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "fetch_gns3a_image: keeps an image whose md5 matches its definition, upgrading http to https" {
    load_gns3a_fns
    printf 'qcow2-bytes' > "$SRV/new-2.0.qcow2"
    md5=$(md5sum < "$SRV/new-2.0.qcow2" | cut -d' ' -f1)
    write_gns3a "$B/gns3/definitions/x.gns3a" new-2.0.qcow2 "$md5" http://downloads.example.invalid/new-2.0.qcow2
    run fetch_gns3a_image x
    echo "$output"
    [ "$status" -eq 0 ]
    [ -s "$B/gns3/appliances/new-2.0.qcow2" ]
    grep -qx 'fetch https://downloads.example.invalid/new-2.0.qcow2' "$NET"
    grep -q "x: new-2.0.qcow2 .*md5 matches its definition" "$NOTES"
    [ -z "$(ls "$B/gns3/appliances" | grep -vx 'new-2.0.qcow2')" ]
}

@test "fetch_gns3a_image: an md5 mismatch removes the image and WARNs" {
    load_gns3a_fns
    printf 'tampered' > "$SRV/new-2.0.qcow2"
    write_gns3a "$B/gns3/definitions/x.gns3a" new-2.0.qcow2 0123456789abcdef0123456789abcdef https://example.invalid/new-2.0.qcow2
    run fetch_gns3a_image x
    echo "$output"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$B/gns3/appliances")" ]
    grep -q "WARN: x: new-2.0.qcow2 md5 does not match its definition" "$NOTES"
}

@test "fetch_gns3a_image: a gzip image is unpacked (OpenWrt's trailing-signature exit 2 tolerated), verified, and no .gz is left" {
    load_gns3a_fns
    printf 'raw-disk-image' > "$BATS_TEST_TMPDIR/new.img"
    md5=$(md5sum < "$BATS_TEST_TMPDIR/new.img" | cut -d' ' -f1)
    gzip -c "$BATS_TEST_TMPDIR/new.img" > "$SRV/new.img.gz"
    printf 'SIGNATURE-BLOCK' >> "$SRV/new.img.gz"      # what OpenWrt appends; gzip -d then exits 2
    write_gns3a "$B/gns3/definitions/w.gns3a" new.img "$md5" https://example.invalid/new.img.gz gzip
    run fetch_gns3a_image w
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$B/gns3/appliances/new.img")" = "raw-disk-image" ]
    [ -z "$(ls "$B/gns3/appliances" | grep -vx 'new.img')" ]
}

@test "fetch_gns3a_image: an image already present with the right md5 is not fetched again" {
    load_gns3a_fns
    printf 'qcow2-bytes' > "$B/gns3/appliances/new-2.0.qcow2"
    md5=$(md5sum < "$B/gns3/appliances/new-2.0.qcow2" | cut -d' ' -f1)
    write_gns3a "$B/gns3/definitions/x.gns3a" new-2.0.qcow2 "$md5" https://example.invalid/new-2.0.qcow2
    run fetch_gns3a_image x
    [ "$status" -eq 0 ]
    [ ! -s "$NET" ]
}

@test "fetch_gns3a_image: a definition that was not staged WARNs and fetches nothing" {
    load_gns3a_fns
    run fetch_gns3a_image missing
    [ "$status" -ne 0 ]
    grep -q "WARN: missing.gns3a not staged" "$NOTES"
    [ ! -s "$NET" ]
}

@test "stage_appliances fetches the image for every free definition named in GNS3A_FREE_IMAGES, each one also in GNS3A_DEFS" {
    run grep -cE '^ *fetch_gns3a_image "\$a"' "$SCRIPT"
    [ "$output" -eq 1 ]
    eval "$(sed -n '/^GNS3A_DEFS=(/,/^)/p' "$SCRIPT")"
    eval "$(grep -E '^GNS3A_FREE_IMAGES=\([^)]*\)$' "$SCRIPT")"
    [ "${#GNS3A_FREE_IMAGES[@]}" -ge 3 ]
    for f in frr tinycore-linux openwrt; do [[ " ${GNS3A_FREE_IMAGES[*]} " == *" $f "* ]]; done
    for f in "${GNS3A_FREE_IMAGES[@]}"; do [[ " ${GNS3A_DEFS[*]} " == *" $f "* ]]; done
}
