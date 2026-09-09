# Bundle Integrity Gate Implementation Plan

> **STATUS: EXECUTED 2026-09-04 — archived.** Tasks 1-4 shipped in `0938174` (2026-09-04).
> **Task 6 did not ship with them** — the fetch script kept its inline
> `find | xargs sha256sum` and never copied the verifier into the bundle. That gap was
> caught by external review on 2026-09-09 and fixed in `9f84a37`. **Tasks 5 and 7 never
> landed at all.** Task 7's absence is why every documented path still pointed at the
> defective manifest command until 2026-09-09. Task 5 is still unbuilt — tracked in
> `state/BUILD-STATE.md`.
> Kept as an outcome record. Do not execute.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the offline supply bundle's integrity mechanically provable — replacing the hand-typed `find | xargs sha256sum` and eyeballed `BUNDLE_NOTES.md` review with a tested script that refuses to let an incomplete, stale-manifest, or unverifiable bundle cross the air gap.

**Architecture:** Two new standalone shell scripts alongside the existing ones (this repo's established pattern — self-contained scripts, no lib directory). `scripts/r770-bundle.sh` owns the *single* definition of what a manifest covers and exposes two subcommands, `manifest` (write) and `verify` (read-only); it is dependency-free so it can be copied into the bundle and run on the air-gapped R770. `scripts/r770-pin-check.sh` is staging-only and network-dependent, reporting upstream drift against the pins parsed out of `r770-offline-fetch.sh` itself, so there is never a second pin table to drift. A `tests/` suite (bats + shellcheck) gives the repo its first executable gate.

**Tech Stack:** bash (≥4.4), GNU coreutils, `find`, `comm`, `sha256sum`, bats 1.10, shellcheck. No jq, no network, no root for anything in `r770-bundle.sh`.

**Spec:** `docs/plans/r770-offline-supply.md` §3 (transfer & verification procedure), `docs/plans/r770-staging-runbook.md` Steps 4–6 + pin table + success criteria, `docs/plans/r770-dependency-manifest.md` §0 (decisions) and §11 (manual checklist).

## Why this work exists (evidence, gathered 2026-09-03)

The manifest command in `scripts/r770-offline-fetch.sh:651` — reproduced verbatim in the runbook Step 4 and in the script's own closing instructions — was executed against fixture bundles. Three defects are confirmed, all of which let a bad bundle report `OK` with exit status 0:

1. **Empty input produces a manifest that verifies nothing.** With no files to hash, `xargs -0 sha256sum` runs `sha256sum` with no arguments, which reads stdin and emits `e3b0c44298fc...855  -` — the hash of empty input. `sha256sum -c` then reports `-: OK` and exits 0. A catastrophically empty bundle passes its own integrity check.
2. **Files added after the manifest are invisible.** `sha256sum -c` only proves that *listed* files exist and match; a file on disk that is absent from the manifest is never noticed. This is exactly the Dell firmware and licensed-GNS3-appliance case that runbook Step 4 warns about — the "regenerate the manifest" instruction is unenforced, so forgetting it means the R770-side check passes while unverified files ride along.
3. **Leftover `.part` files are invisible.** An interrupted download leaves a truncated `*.part`; it is excluded from the manifest by design, so nothing flags it and it crosses the gap silently.

Additionally: `shellcheck` reports SC2094 (read and write the same file in one pipeline) at that exact line, and the repo has no test suite or lint gate at all despite the fetch script being 40 KB of bash that runs as root via `sudo -E`.

## Global Constraints

- **Two machines, two roles.** `r770-pin-check.sh` and `r770-offline-fetch.sh` are staging-only and need internet. `r770-bundle.sh` must run on the air-gapped R770: no network, no root, no package installs, no `jq`.
- **bash floor is 4.4** (RHEL 8 staging host). `mapfile -d ''` is available; bash-5-only syntax is not.
- **No new staging-host dependencies.** Runbook §1.3 installs only `curl gnupg2 unzip wget pigz`. `jq` is in the *R770's* package list, not staging's — parse JSON with `grep`/`sed`.
- **Manifest exclusions are exactly:** `MANIFEST.sha256`, `*.part`, `./.stamps/*`. Defined once, in `bundle_files()`.
- **Pins as of 2026-09-04** (do not bump in this plan; four were bumped separately on 2026-09-04 — see `state/inventory/pin-review-2026-09-04.md`): Malcolm `26.08.0` · Ubuntu ISO `24.04.4` · gns3-server `3.0.6` · MikroTik CHR `7.21.5` · OPNsense `26.7` · FRR `quay.io/frrouting/frr:10.7.1` · prometheus `v3.14.0` · alertmanager `v0.34.0` · blackbox-exporter `v0.28.0` · cadvisor `v0.60.5` · grafana-oss `12.1.0` (**deliberately held** — 13.2.1 is current; review dashboards before jumping majors) · ET path `suricata-7.0`.
- **Never fabricate results.** Every task's "expected" output must be what the command actually printed. If it differs, the plan is wrong — fix the plan, do not fudge the report.
- **Do not restructure `r770-offline-fetch.sh`.** It cannot be exercised in the dev sandbox (no Docker, needs ~150 GB and hours). The only edit it receives in this plan is the two-line change in Task 6.
- **Commit style:** match existing history — imperative, capitalized subject, no `feat:`/`fix:` prefix (e.g. `Add SessionStart hook installing shellcheck for web sessions`). Append whatever session-attribution trailer your harness specifies.
- **No secrets in the repo.** Test fixtures are synthetic; never commit a real bundle, image tarball, or Dell download.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/r770-bundle.sh` *(new)* | The gate. `manifest` writes `MANIFEST.sha256`; `verify` proves a bundle is complete, unmodified, and importable. Sole definition of the exclusion rule. Travels with the bundle. |
| `scripts/r770-pin-check.sh` *(new)* | Advisory upstream pin-drift report. Reads pins from the fetch script; network fetches injectable for tests. Never fails a bundle. |
| `tests/run.sh` *(new)* | One entry point: shellcheck + bats. |
| `tests/helpers/fixtures.bash` *(new)* | `make_bundle`, `stage_manual` — synthetic bundles with realistic structure. |
| `tests/lint.bats` *(new)* | Lint gate, incl. the accepted legacy-exclusion list (one place). |
| `tests/bundle-manifest.bats` *(new)* | `manifest` subcommand behaviour. |
| `tests/bundle-verify.bats` *(new)* | `verify` subcommand behaviour, one test per confirmed defect. |
| `tests/pin-check.bats` *(new)* | Pin parsing + drift classification against canned responses. |
| `tests/fixtures/pin-check/` *(new)* | Canned upstream API bodies. |
| `tests/README.md` *(new)* | How to run the suite; why each legacy shellcheck code is excluded. |
| `scripts/r770-precheck.sh` *(modify: line 219)* | One quoting fix so the lint gate can be enabled. |
| `scripts/r770-offline-fetch.sh` *(modify: line 651 + closing echo)* | Delegate manifest generation to `r770-bundle.sh`. |
| `state/inventory/bundles.md` *(new)* | The bundle-cycle log referenced by `BUILD-STATE.md`, supply plan §3.5, runbook Step 6.5, and both slash commands — currently missing. |
| `docs/plans/r770-staging-runbook.md` *(modify: Steps 4, 5, 6)* | Replace hand-typed commands with the gate. |
| `.claude/commands/bundle.md`, `.claude/commands/import-bundle.md` *(modify)* | Point the workflows at the gate. |
| `.claude/settings.json` *(modify)* | Pre-approve the new scripts and `bats`. |

---

### Task 1: Test harness and lint gate

Nothing in this repo is currently executable-and-checked. This task makes `tests/run.sh` the one command that proves the repo is sound, and gets it to green against the code as it stands today.

**Files:**
- Create: `tests/run.sh`
- Create: `tests/lint.bats`
- Create: `tests/README.md`
- Modify: `.claude/settings.json`

> **Note added 2026-09-03:** the SC2086 finding this task originally fixed in `scripts/r770-precheck.sh:219` has **already been fixed** by the Phase 1 discovery-ingest work (the same commit that corrected the script's port-count and `lvm2` checks). Steps 4 and 5 below are therefore expected to pass rather than fail — confirm with `shellcheck -e "$LEGACY_EXCLUDE" scripts/r770-precheck.sh` and move on. If it *does* still report SC2086, apply the fix as written.

**Interfaces:**
- Consumes: nothing.
- Produces: `tests/run.sh` (runs shellcheck then bats over `tests/*.bats`, exits non-zero if either fails) — every later task ends by running it. `LEGACY_EXCLUDE` in `tests/lint.bats` is the single list of accepted legacy shellcheck codes; Task 6 removes `SC2094` from it.

- [ ] **Step 1: Confirm the tooling is present**

```bash
command -v shellcheck bats
```

Expected: two paths. If either is missing, install them (`apt-get install -y shellcheck bats` on the Ubuntu dev sandbox; on the RHEL 8 staging host `dnf -y install ShellCheck` and bats from EPEL). The repo's `.claude/hooks/session-start.sh` already installs shellcheck in web sessions.

- [ ] **Step 2: Write the failing lint test**

Create `tests/lint.bats`:

```bash
#!/usr/bin/env bats
#
# Lint gate. Scripts written for this gate must be shellcheck-clean at default
# severity with no exclusions. The two scripts that predate the gate get a
# documented exclusion list (see tests/README.md for why each is accepted).

# SC2094 is a real finding at r770-offline-fetch.sh:651 and is removed from
# this list in Task 6, when that line starts delegating to r770-bundle.sh.
LEGACY_EXCLUDE="SC2015,SC2012,SC2010,SC1091,SC2094"

@test "legacy scripts are clean apart from accepted house-style codes" {
    run shellcheck -e "$LEGACY_EXCLUDE" scripts/r770-offline-fetch.sh scripts/r770-precheck.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "hooks are shellcheck-clean with no exclusions" {
    run shellcheck .claude/hooks/session-start.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "every shell script parses" {
    for f in scripts/*.sh .claude/hooks/*.sh tests/run.sh; do
        run bash -n "$f"
        echo "$f: $output"
        [ "$status" -eq 0 ]
    done
}
```

- [ ] **Step 3: Write the runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
#
# The repo's one check. Run from anywhere:  ./tests/run.sh
#
# Everything here is read-only and offline: it lints the shell scripts and runs
# the bats suites against synthetic fixtures in $BATS_TEST_TMPDIR. It never
# touches a real bundle, never reaches the network, and never contacts the R770.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== bats =="
bats tests/*.bats
```

Then:

```bash
chmod +x tests/run.sh
```

- [ ] **Step 4: Run it to see the real failure**

```bash
./tests/run.sh
```

Expected (as of 2026-09-03): **PASS, 3 tests, 0 failures** — the SC2086 finding this step was written to surface has already been fixed. Skip to Step 7.

If you are running this against an older tree and it does FAIL, it will be with exactly one finding:

```
scripts/r770-precheck.sh:219:53: note: Double quote to prevent globbing and word splitting. [SC2086]
```

In that case apply Step 5. If you see *more* than that one finding, stop and reconcile — the exclusion list is wrong for the code in front of you.

- [ ] **Step 5: Fix the one real legacy finding**

`scripts/r770-precheck.sh:219` currently reads:

```bash
    ok "8 Broadcom (bnxt_en) ports detected: $(echo $BNXT | tr '\n' ' ')"
```

Quote the variable — the intent (collapse newlines to spaces) is unchanged, and interface names contain no globs or spaces:

```bash
    ok "8 Broadcom (bnxt_en) ports detected: $(echo "$BNXT" | tr '\n' ' ')"
```

- [ ] **Step 6: Run the suite to verify it passes**

```bash
./tests/run.sh
```

Expected: PASS — `3 tests, 0 failures`.

- [ ] **Step 7: Document the exclusions**

Create `tests/README.md`:

```markdown
# tests/

One command: `./tests/run.sh`. It lints every shell script and runs the bats
suites. Everything is offline and read-only — synthetic fixtures only, never a
real bundle, never the network, never the R770.

Requires: `shellcheck`, `bats` (>= 1.10). The repo's SessionStart hook installs
shellcheck in web sessions.

## Accepted legacy shellcheck exclusions

`scripts/r770-offline-fetch.sh` and `scripts/r770-precheck.sh` predate this
gate and cannot be exercised in a dev sandbox (the fetch script needs Docker,
~150 GB, and hours). Rewriting their style blind is a worse risk than the
findings, so these codes are excluded for those two files only. Scripts written
after the gate get no exclusions at all.

| Code | Why accepted |
|---|---|
| SC2015 | `cmd && note "ok" \|\| note "WARN"` is the fetch script's deliberate per-item reporting idiom; `note` cannot fail, so the classic A&&B\|\|C trap does not apply. |
| SC2012 | `ls` used to resolve a single version-glob (e.g. `vyos-*-generic-amd64.iso`) where filenames are upstream-controlled and alphanumeric. |
| SC2010 | `ls /sys/class/net \| grep -v` — a sysfs listing with fixed, safe names. |
| SC1091 | `. /etc/os-release` is not present at lint time. |
| SC2094 | **Not accepted — temporary.** A real finding at `r770-offline-fetch.sh:651`; removed from the list when that line delegates to `r770-bundle.sh`. |
```

- [ ] **Step 8: Pre-approve the test tooling**

In `.claude/settings.json`, add to `permissions.allow` (alongside the existing `Bash(shellcheck:*)`):

```json
      "Bash(bats:*)",
      "Bash(./tests/run.sh:*)",
      "Bash(./scripts/r770-bundle.sh:*)",
      "Bash(./scripts/r770-pin-check.sh:*)"
```

Verify the file is still valid JSON:

```bash
python3 -c 'import json,sys; json.load(open(".claude/settings.json")); print("valid json")'
```

Expected: `valid json`

- [ ] **Step 9: Commit**

```bash
git add tests/ .claude/settings.json
git commit -m "Add shell lint and test gate

First executable check in the repo: tests/run.sh lints every script with
shellcheck and runs the bats suites. Legacy scripts carry a documented
exclusion list (tests/README.md); scripts written after this gate get none."
```

---

### Task 2: `r770-bundle.sh manifest` — a manifest generator that cannot lie

Replaces the hand-typed `find | xargs sha256sum` with a command that refuses the two states in which that pipeline produces a worthless manifest.

**Files:**
- Create: `scripts/r770-bundle.sh`
- Create: `tests/helpers/fixtures.bash`
- Create: `tests/bundle-manifest.bats`

**Interfaces:**
- Consumes: `tests/run.sh` from Task 1.
- Produces:
  - `scripts/r770-bundle.sh manifest <bundle-dir>` — writes `<bundle-dir>/MANIFEST.sha256`, sorted, one `sha256sum`-format line per payload file. Exit 0 on success; exit 1 with a message on stderr if any `*.part` exists or there is nothing to hash.
  - `bundle_files <dir>` — NUL-separated, sorted, `./`-relative payload paths. **The only definition of the exclusion rule** (`MANIFEST.sha256`, `*.part`, `./.stamps/*`); Task 3 reuses it.
  - `part_files <dir>` — newline-separated relative paths of `*.part` files.
  - `manifest_paths <manifest>` — one path per line, parsed from `sha256sum` format.
  - Fixture helpers `make_bundle <dir>` and `stage_manual <dir>`.

- [ ] **Step 1: Write the fixture helper**

Create `tests/helpers/fixtures.bash`:

```bash
# Synthetic bundles: the real directory shape from r770-offline-fetch.sh, with
# byte-sized stand-ins for the 40+ GB of payload. Never a real bundle.

# make_bundle <dir> — a freshly fetched bundle, manual categories NOT yet staged
# (README.txt only), which is the true state at the end of a fetch run.
make_bundle() {
    local d=$1
    mkdir -p "$d"/{apt,malcolm,docker,images,enrichment,isos,dell} \
             "$d"/gns3/{appliances,definitions} "$d"/.stamps
    echo "fake deb"             > "$d/apt/example_1.0_amd64.deb"
    echo "fake malcolm images"  > "$d/malcolm/malcolm-images-26.08.0.tar.gz"
    echo "fake monitoring"      > "$d/docker/monitoring-images.tar.gz"
    echo "fake iso"             > "$d/isos/ubuntu-24.04.4-live-server-amd64.iso"
    echo "fake oui"             > "$d/enrichment/oui.txt"
    echo "MANUAL DOWNLOADS from dell.com/support" > "$d/dell/README.txt"
    echo "Stage licensed appliance images here"   > "$d/gns3/appliances/README.txt"
    touch "$d/.stamps/apt" "$d/.stamps/wheelhouse"
    cat > "$d/BUNDLE_NOTES.md" <<'NOTES'
# Bundle notes

- Ubuntu ISO 24.04.4 fetched
- Malcolm 26.08.0 images saved
NOTES
}

# stage_manual <dir> — the operator has completed runbook Step 4.
stage_manual() {
    local d=$1
    echo "fake bios dup"   > "$d/dell/BIOS_R770_1.2.3.EXE"
    echo "fake iosv qcow2" > "$d/gns3/appliances/vios-adventerprisek9.qcow2"
}
```

- [ ] **Step 2: Write the failing tests**

Create `tests/bundle-manifest.bats`:

```bash
#!/usr/bin/env bats

load helpers/fixtures

setup() {
    BUNDLE="$BATS_TEST_TMPDIR/bundle-20260903"
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-bundle.sh"
    make_bundle "$BUNDLE"
}

@test "manifest covers every payload file" {
    run "$SCRIPT" manifest "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'apt/example_1.0_amd64.deb'  "$BUNDLE/MANIFEST.sha256"
    grep -q 'BUNDLE_NOTES.md'            "$BUNDLE/MANIFEST.sha256"
    grep -q 'dell/README.txt'            "$BUNDLE/MANIFEST.sha256"
}

@test "manifest excludes itself, .stamps and .part files" {
    echo half > "$BUNDLE/apt/big.deb.part"
    run "$SCRIPT" manifest "$BUNDLE"
    [ "$status" -ne 0 ]                       # .part must be refused outright
    rm "$BUNDLE/apt/big.deb.part"
    run "$SCRIPT" manifest "$BUNDLE"
    [ "$status" -eq 0 ]
    ! grep -q 'MANIFEST.sha256' "$BUNDLE/MANIFEST.sha256"
    ! grep -q '.stamps'         "$BUNDLE/MANIFEST.sha256"
}

@test "refuses an empty bundle instead of writing a '-' entry" {
    empty="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$empty"
    run "$SCRIPT" manifest "$empty"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to write an empty manifest"* ]]
    [ ! -e "$empty/MANIFEST.sha256" ]
}

@test "refuses when an incomplete download is present" {
    echo half > "$BUNDLE/malcolm/malcolm-images-26.08.0.tar.gz.part"
    run "$SCRIPT" manifest "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"incomplete download"* ]]
}

@test "manifest is reproducible" {
    "$SCRIPT" manifest "$BUNDLE"
    cp "$BUNDLE/MANIFEST.sha256" "$BATS_TEST_TMPDIR/first"
    "$SCRIPT" manifest "$BUNDLE"
    diff "$BATS_TEST_TMPDIR/first" "$BUNDLE/MANIFEST.sha256"
}

@test "handles a filename with a space" {
    echo dup > "$BUNDLE/dell/Broadcom NIC firmware.EXE"
    run "$SCRIPT" manifest "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'Broadcom NIC firmware.EXE' "$BUNDLE/MANIFEST.sha256"
    run bash -c "cd '$BUNDLE' && sha256sum -c --quiet MANIFEST.sha256"
    [ "$status" -eq 0 ]
}

@test "leaves no temp file inside the bundle" {
    "$SCRIPT" manifest "$BUNDLE"
    run find "$BUNDLE" -name 'MANIFEST.sha256.*'
    [ -z "$output" ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bats tests/bundle-manifest.bats
```

Expected: all 7 fail — `scripts/r770-bundle.sh` does not exist yet (bats reports the command as not found / status 127).

- [ ] **Step 4: Write the implementation**

Create `scripts/r770-bundle.sh`:

```bash
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
# written, and for leftover .part downloads. See
# work/plans/archive/2026-09-03-bundle-integrity-gate.md.
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

usage() {
    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

case "${1:-}" in
    manifest)          shift; cmd_manifest "$@" ;;
    -h|--help|help|"") usage ;;
    *)                 die "unknown subcommand: $1 (try --help)" ;;
esac
```

Then:

```bash
chmod +x scripts/r770-bundle.sh
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bats tests/bundle-manifest.bats
```

Expected: `7 tests, 0 failures`.

- [ ] **Step 6: Prove the original defect is actually fixed**

```bash
mkdir -p /tmp/mt-empty && ./scripts/r770-bundle.sh manifest /tmp/mt-empty; echo "exit=$?"
```

Expected: `r770-bundle: nothing to hash under /tmp/mt-empty — refusing to write an empty manifest` on stderr and `exit=1`, with no `MANIFEST.sha256` created. Compare with the old pipeline, which wrote `e3b0c442...  -` and exited 0.

```bash
rmdir /tmp/mt-empty
```

- [ ] **Step 7: Run the full gate and commit**

```bash
./tests/run.sh
```

Expected: `10 tests, 0 failures`.

```bash
git add scripts/r770-bundle.sh tests/helpers/fixtures.bash tests/bundle-manifest.bats
git commit -m "Add r770-bundle.sh manifest generator

The hand-typed find|xargs sha256sum in the runbook writes a manifest
containing a single '-' entry when there is nothing to hash, which
sha256sum -c then reports as OK. It also happily manifests a bundle that
still holds truncated .part downloads. This refuses both, writes its temp
file outside the bundle so it cannot hash itself, and defines the
exclusion rule in exactly one place."
```

---

### Task 3: `r770-bundle.sh verify` — the three confirmed blind spots

Adds the read-only gate that catches what `sha256sum -c` alone cannot: a stale manifest, a truncated download, and a manifest generated from empty input.

**Files:**
- Modify: `scripts/r770-bundle.sh` (add `cmd_verify` and its checks; extend the dispatcher)
- Create: `tests/bundle-verify.bats`

**Interfaces:**
- Consumes: `bundle_files`, `part_files`, `manifest_paths`, `die`, `MANIFEST_NAME` from Task 2; `make_bundle`, `stage_manual` from `tests/helpers/fixtures.bash`.
- Produces:
  - `scripts/r770-bundle.sh verify <bundle-dir>` — prints one `ok`/`FAIL` line per check and a `RESULT:` summary. Exit 0 = PASS, exit 1 = FAIL (do not import).
  - `fail <msg>` / `pass <msg>` reporters and the `FAILS` counter, extended with `warn`/`WARNS` in Task 4.
  - `summary <strict>` — prints the `RESULT:` line and exits. Task 4 adds the exit-2 branch.

- [ ] **Step 1: Write the failing tests**

Create `tests/bundle-verify.bats`:

```bash
#!/usr/bin/env bats

load helpers/fixtures

setup() {
    BUNDLE="$BATS_TEST_TMPDIR/bundle-20260903"
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-bundle.sh"
    make_bundle "$BUNDLE"
    stage_manual "$BUNDLE"          # a bundle ready to travel
    "$SCRIPT" manifest "$BUNDLE"
}

@test "a complete, unmodified bundle passes" {
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "a modified file fails" {
    echo tampered > "$BUNDLE/apt/example_1.0_amd64.deb"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checksum verification failed"* ]]
}

@test "a deleted file fails" {
    rm "$BUNDLE/enrichment/oui.txt"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
}

@test "a manual file added after the manifest fails as a stale manifest" {
    echo "fake fortigate qcow2" > "$BUNDLE/gns3/appliances/fortios.qcow2"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not in MANIFEST.sha256"* ]]
    [[ "$output" == *"fortios.qcow2"* ]]
}

@test "a leftover .part fails" {
    echo half > "$BUNDLE/malcolm/malcolm-images-26.08.0.tar.gz.part"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"incomplete download"* ]]
}

@test "a manifest generated from empty input fails" {
    printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -\n' \
        > "$BUNDLE/MANIFEST.sha256"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"verifies nothing"* ]]
}

@test "a missing manifest fails" {
    rm "$BUNDLE/MANIFEST.sha256"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be trusted"* ]]
}

@test "a bundle whose .stamps changed still passes" {
    touch "$BUNDLE/.stamps/docs"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bats tests/bundle-verify.bats
```

Expected: all 8 fail — `verify` is not a known subcommand, so the script dies with `r770-bundle: unknown subcommand: verify (try --help)` and exit 1. (The `[ "$status" -eq 1 ]` assertions may incidentally pass; the `$output` assertions will not.)

- [ ] **Step 3: Add the reporters and checks**

In `scripts/r770-bundle.sh`, insert after the `manifest_paths` function:

```bash
# ── reporting ────────────────────────────────────────────────────────────────
FAILS=0
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok    $*"; }
```

Then insert after `cmd_manifest`:

```bash
# ── verify ───────────────────────────────────────────────────────────────────
check_manifest_sane() {  # <manifest>
    local m=$1 n
    if grep -q '^\\' "$m"; then
        fail "$MANIFEST_NAME holds escaped path(s) — a filename contains a backslash or newline; rename it and regenerate"
    fi
    if manifest_paths "$m" | grep -qx -- '-'; then
        fail "$MANIFEST_NAME contains a '-' entry: it was generated from empty input and verifies nothing"
        return
    fi
    n=$(wc -l < "$m")
    pass "$MANIFEST_NAME parses — $n entries"
}

check_hashes() {  # <dir>
    local out rc=0
    out=$( cd "$1" && sha256sum -c --quiet "$MANIFEST_NAME" 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "every manifested file is present and unmodified"
    else
        printf '%s\n' "$out" | sed 's/^/      /'
        fail "checksum verification failed — do not import this bundle"
    fi
}

# The blind spot in `sha256sum -c`: it proves listed files are intact but says
# nothing about files on disk that the manifest never listed. That is exactly
# the Dell / licensed-appliance case, where the manifest predates the manual
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

summary() {
    echo
    if [ "$FAILS" -gt 0 ]; then
        echo "RESULT: FAIL — $FAILS failure(s). Do not import this bundle."
        exit 1
    fi
    echo "RESULT: PASS — bundle is complete, unmodified and ready to transfer."
    exit 0
}

cmd_verify() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: r770-bundle.sh verify <bundle-dir>"
    [ -d "$dir" ] || die "not a directory: $dir"

    echo "Verifying bundle: $dir"
    local manifest="$dir/$MANIFEST_NAME"
    if [ ! -s "$manifest" ]; then
        fail "$MANIFEST_NAME is missing or empty — this bundle cannot be trusted"
        summary
    fi

    check_manifest_sane "$manifest"
    check_hashes   "$dir"
    check_coverage "$dir" "$manifest"
    check_parts    "$dir"
    summary
}
```

Extend the dispatcher — change:

```bash
    manifest)          shift; cmd_manifest "$@" ;;
```

to:

```bash
    manifest)          shift; cmd_manifest "$@" ;;
    verify)            shift; cmd_verify   "$@" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats tests/bundle-verify.bats
```

Expected: `8 tests, 0 failures`.

- [ ] **Step 5: Confirm the checks are independent, not accidentally coupled**

A test that passes for the wrong reason is worse than no test. Prove `check_coverage` is what catches the stale manifest, by confirming the hash check alone still reports OK on that same bundle:

```bash
B=$(mktemp -d)/bundle-test && mkdir -p "$B" && \
  cp -r tests/helpers "$B/../helpers-unused" 2>/dev/null; \
  mkdir -p "$B/apt" "$B/dell" && echo one > "$B/apt/a.deb" && \
  ./scripts/r770-bundle.sh manifest "$B" >/dev/null && \
  echo firmware > "$B/dell/bios.EXE" && \
  ( cd "$B" && sha256sum -c --quiet MANIFEST.sha256 ); echo "sha256sum -c exit=$?"; \
  ./scripts/r770-bundle.sh verify "$B"; echo "verify exit=$?"
```

Expected: `sha256sum -c exit=0` (the blind spot, unchanged) followed by verify printing the `dell/bios.EXE` line, `FAIL … not in MANIFEST.sha256`, and `verify exit=1`.

- [ ] **Step 6: Run the full gate and commit**

```bash
./tests/run.sh
```

Expected: `18 tests, 0 failures`.

```bash
git add scripts/r770-bundle.sh tests/bundle-verify.bats
git commit -m "Add r770-bundle.sh verify subcommand

sha256sum -c proves that listed files are intact and nothing more. It
reports OK for a bundle carrying files the manifest never listed - the
Dell and licensed-appliance case, where the manifest predates the manual
downloads - and for one carrying truncated .part downloads. verify checks
coverage in both directions, refuses a manifest generated from empty
input, and is dependency-free so it runs on the air-gapped R770."
```

---

### Task 4: `verify` — WARN triage and manual-category status

Runbook Step 5 says "treat unresolved WARN lines as a gate" and the success criteria demand zero of them, but nothing enforces it. This makes that a machine check with its own exit code, so a warning state is distinguishable from both pass and failure.

**Files:**
- Modify: `scripts/r770-bundle.sh` (add `warn`, the two WARN checks, `--strict`; extend `summary`)
- Modify: `tests/bundle-verify.bats` (append)

**Interfaces:**
- Consumes: everything from Task 3.
- Produces: `verify <dir> [--strict]` with a third exit code — **0 = PASS, 1 = FAIL, 2 = PASS WITH WARNINGS**. `--strict` promotes warnings to failure and is what `/bundle` Step 5 uses before the media leaves staging.

- [ ] **Step 1: Append the failing tests**

Add to the end of `tests/bundle-verify.bats`:

```bash
@test "unresolved WARN lines in the notes warn but do not fail" {
    echo "- WARN: oui.txt fetch failed — retry manually" >> "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"RESULT: PASS WITH WARNINGS"* ]]
    [[ "$output" == *"oui.txt fetch failed"* ]]
}

@test "--strict promotes warnings to failure" {
    echo "- WARN: docs mirror failed" >> "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE" --strict
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RESULT: FAIL (--strict)"* ]]
}

@test "unstaged manual categories warn" {
    rm "$BUNDLE/dell/BIOS_R770_1.2.3.EXE" \
       "$BUNDLE/gns3/appliances/vios-adventerprisek9.qcow2"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"dell/ holds only README.txt"* ]]
    [[ "$output" == *"gns3/appliances/ holds only README.txt"* ]]
}

@test "a missing BUNDLE_NOTES.md warns" {
    rm "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"BUNDLE_NOTES.md missing"* ]]
}

@test "a failure outranks a warning" {
    echo "- WARN: something" >> "$BUNDLE/BUNDLE_NOTES.md"
    "$SCRIPT" manifest "$BUNDLE"
    echo tampered > "$BUNDLE/apt/example_1.0_amd64.deb"
    run "$SCRIPT" verify "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RESULT: FAIL"* ]]
}

@test "an unknown option is rejected" {
    run "$SCRIPT" verify "$BUNDLE" --wat
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bats tests/bundle-verify.bats
```

Expected: the 8 Task 3 tests pass; the 6 new ones fail — the WARN cases exit 0 instead of 2, `--strict` and `--wat` are consumed as a second positional argument and rejected by `die "not a directory"`.

- [ ] **Step 3: Add the warning reporter**

In `scripts/r770-bundle.sh`, change the reporting block to:

```bash
# ── reporting ────────────────────────────────────────────────────────────────
FAILS=0
WARNS=0
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
warn() { echo "WARN  $*"; WARNS=$((WARNS + 1)); }
pass() { echo "ok    $*"; }
```

- [ ] **Step 4: Add the two WARN checks**

Insert after `check_parts`:

```bash
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
```

- [ ] **Step 5: Add `--strict` parsing and the exit-2 branch**

Replace `summary` and `cmd_verify` with:

```bash
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

    check_manifest_sane "$manifest"
    check_hashes   "$dir"
    check_coverage "$dir" "$manifest"
    check_parts    "$dir"
    check_notes    "$dir"
    check_manual   "$dir"
    summary "$strict"
}
```

Note the two `summary` call sites now take `$strict`; the early-exit one inside the missing-manifest branch does too.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bats tests/bundle-verify.bats
```

Expected: `14 tests, 0 failures`.

- [ ] **Step 7: Run the full gate and commit**

```bash
./tests/run.sh
```

Expected: `24 tests, 0 failures`.

```bash
git add scripts/r770-bundle.sh tests/bundle-verify.bats
git commit -m "Gate bundle WARN lines and unstaged manual downloads

Runbook Step 5 calls unresolved WARN lines in BUNDLE_NOTES.md a gate and
the success criteria demand zero of them, but nothing enforced it. verify
now reports them, plus the two categories no script can fetch (Dell
firmware, licensed GNS3 appliances), as exit 2 - distinguishable from
both pass and failure. --strict promotes them to failure for the check
before the media leaves staging."
```

---

### Task 5: `r770-pin-check.sh` — upstream drift, reported not guessed

The runbook's pin table has to be walked by hand across 11 upstreams on every refresh cycle. This reports the drift, reading the pinned values out of the fetch script so there is never a second table to go stale.

**Files:**
- Create: `scripts/r770-pin-check.sh`
- Create: `tests/pin-check.bats`
- Create: `tests/fixtures/pin-check/` (four canned response bodies)

**Interfaces:**
- Consumes: `scripts/r770-offline-fetch.sh` as the source of truth for pins.
- Produces: `scripts/r770-pin-check.sh [--fetch-script PATH]` — prints an aligned table and exits 0 when every checkable pin is current, 2 when any moved or could not be resolved. Never exits 1 except on usage error; it is advisory and must never fail a bundle. Honours `PINCHECK_FETCH` (a command receiving a URL on argv and printing the body on stdout) so tests need no network.

- [ ] **Step 1: Create the canned upstream responses**

```bash
mkdir -p tests/fixtures/pin-check
printf '{"tag_name": "v26.07.1", "name": "Malcolm v26.07.1"}\n' > tests/fixtures/pin-check/malcolm-current.json
printf '{"tag_name": "v26.09.0", "name": "Malcolm v26.09.0"}\n' > tests/fixtures/pin-check/malcolm-moved.json
printf '{"info": {"version": "3.0.6"}}\n'                        > tests/fixtures/pin-check/gns3-current.json
printf '{"info": {"version": "3.1.0"}}\n'                        > tests/fixtures/pin-check/gns3-moved.json
```

- [ ] **Step 2: Write the failing tests**

Create `tests/pin-check.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-pin-check.sh"
    FETCH="$BATS_TEST_DIRNAME/../scripts/r770-offline-fetch.sh"
    FIX="$BATS_TEST_DIRNAME/fixtures/pin-check"

    # A stub standing in for the network: maps a URL to a canned body.
    STUB="$BATS_TEST_TMPDIR/fetch"
    cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  *idaholab/Malcolm*)  cat "$FIX/\${MALCOLM_FIX:-malcolm-current.json}" ;;
  *gns3-server/json*)  cat "$FIX/\${GNS3_FIX:-gns3-current.json}" ;;
  *releases.ubuntu.com/noble*)
      echo '<a href="ubuntu-24.04.4-live-server-amd64.iso">' ;;
  *) exit 1 ;;
esac
STUBEOF
    chmod +x "$STUB"
    export PINCHECK_FETCH="$STUB"
}

@test "reads the pinned versions out of the fetch script" {
    run "$SCRIPT" --fetch-script "$FETCH"
    echo "$output"
    [[ "$output" == *"26.07.1"* ]]      # MALCOLM_VER
    [[ "$output" == *"3.0.6"*   ]]      # GNS3_VER
    [[ "$output" == *"24.04.4"* ]]      # UBUNTU_ISO_VER
}

@test "reports current when upstream matches the pin" {
    run "$SCRIPT" --fetch-script "$FETCH"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"MOVED"* ]]
}

@test "reports MOVED when an upstream release is newer" {
    MALCOLM_FIX=malcolm-moved.json run "$SCRIPT" --fetch-script "$FETCH"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"MOVED"*    ]]
    [[ "$output" == *"26.09.0"*  ]]
}

@test "grafana is reported as held, never as MOVED" {
    run "$SCRIPT" --fetch-script "$FETCH"
    echo "$output"
    [[ "$output" == *"grafana-oss"* ]]
    [[ "$output" == *"held"*        ]]
}

@test "unscriptable upstreams are listed as manual with their URL" {
    run "$SCRIPT" --fetch-script "$FETCH"
    echo "$output"
    [[ "$output" == *"MikroTik CHR"*            ]]
    [[ "$output" == *"mikrotik.com/download/chr"* ]]
    [[ "$output" == *"OPNsense"*                ]]
}

@test "an unresolvable upstream is unknown, not a crash" {
    GNS3_FIX=missing.json run "$SCRIPT" --fetch-script "$FETCH"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown"* ]]
}

@test "a missing fetch script is a usage error" {
    run "$SCRIPT" --fetch-script /nonexistent/path.sh
    echo "$output"
    [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bats tests/pin-check.bats
```

Expected: all 7 fail with status 127 — the script does not exist.

- [ ] **Step 4: Write the implementation**

Create `scripts/r770-pin-check.sh`:

```bash
#!/usr/bin/env bash
#
# r770-pin-check.sh — report upstream drift for the pins in r770-offline-fetch.sh.
#
# STAGING HOST ONLY: this reaches the internet. Never run it on the R770.
#
# Advisory by design. It never edits a pin and never fails a bundle; bumping a
# pin is the operator's call (see the decisions record in
# docs/plans/r770-dependency-manifest.md §0).
#
# Exit: 0 every checkable pin is current · 2 something moved or did not resolve
#       · 1 usage error.
#
# No jq — the RHEL 8 staging host installs only curl/gnupg2/unzip/wget/pigz
# (runbook §1.3), so JSON is parsed with grep/sed.
set -euo pipefail

FETCH_SCRIPT="$(dirname "$0")/r770-offline-fetch.sh"

while [ $# -gt 0 ]; do
    case $1 in
        --fetch-script) FETCH_SCRIPT=${2:-}; shift ;;
        -h|--help)
            echo "usage: r770-pin-check.sh [--fetch-script PATH]"; exit 0 ;;
        *)  echo "r770-pin-check: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

[ -r "$FETCH_SCRIPT" ] || { echo "r770-pin-check: cannot read $FETCH_SCRIPT" >&2; exit 1; }

# Network, injectable so the tests never leave the machine.
fetch_url() {
    if [ -n "${PINCHECK_FETCH:-}" ]; then
        "$PINCHECK_FETCH" "$1"
    else
        curl -fsSL --max-time 30 "$1"
    fi
}

# Read a pin's default out of the fetch script's pin block, e.g.
#   MALCOLM_VER="${MALCOLM_VER:-26.07.1}"   ->   26.07.1
pin_of() {
    sed -n "s/^$1=\"\${$1:-\([^}]*\)}\".*/\1/p" "$FETCH_SCRIPT" | head -1
}

# Read a tag out of the MONITOR_IMAGES array, e.g. grafana/grafana-oss -> 12.1.0
monitor_tag_of() {
    sed -n '/^MONITOR_IMAGES=(/,/^)/p' "$FETCH_SCRIPT" |
        grep -o "\"[^\"]*$1:[^\"]*\"" | head -1 | sed 's/.*://; s/"$//'
}

# ── resolvers ────────────────────────────────────────────────────────────────
latest_gh() {  # <owner/repo> — newest release tag, leading v stripped
    fetch_url "https://api.github.com/repos/$1/releases/latest" |
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
        sed 's/.*"\([^"]*\)"$/\1/; s/^v//'
}

latest_pypi() {  # <package>
    fetch_url "https://pypi.org/pypi/$1/json" |
        grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
        sed 's/.*"\([^"]*\)"$/\1/'
}

latest_ubuntu_noble() {
    fetch_url "https://releases.ubuntu.com/noble/" |
        grep -o 'ubuntu-24\.04\.[0-9]\+-live-server-amd64\.iso' |
        sed 's/ubuntu-\(24\.04\.[0-9]*\).*/\1/' | sort -uV | tail -1
}

# ── the table ────────────────────────────────────────────────────────────────
DRIFT=0
row() {  # <name> <pinned> <upstream-or-empty> <status> <reference>
    printf '%-22s %-12s %-12s %-8s %s\n' "$1" "$2" "${3:--}" "$4" "$5"
    case $4 in MOVED|unknown) DRIFT=1 ;; esac
}

# <name>|<pinned>|<upstream>|<reference>, classified into current/MOVED/unknown.
check() {
    local name=$1 pinned=$2 upstream=$3 ref=$4
    if [ -z "$pinned" ]; then
        row "$name" "?" "$upstream" "unknown" "$ref"
    elif [ -z "$upstream" ]; then
        row "$name" "$pinned" "" "unknown" "$ref"
    elif [ "$pinned" = "$upstream" ]; then
        row "$name" "$pinned" "$upstream" "current" "$ref"
    else
        row "$name" "$pinned" "$upstream" "MOVED" "$ref"
    fi
}

printf '%-22s %-12s %-12s %-8s %s\n' PIN PINNED UPSTREAM STATUS REFERENCE
printf '%-22s %-12s %-12s %-8s %s\n' ---------------------- ------------ ------------ -------- ---------

check "Malcolm"      "$(pin_of MALCOLM_VER)"    "$(latest_gh idaholab/Malcolm || true)" \
      "https://github.com/idaholab/Malcolm/releases"
check "gns3-server"  "$(pin_of GNS3_VER)"       "$(latest_pypi gns3-server || true)" \
      "https://pypi.org/project/gns3-server/"
check "Ubuntu ISO"   "$(pin_of UBUNTU_ISO_VER)" "$(latest_ubuntu_noble || true)" \
      "https://releases.ubuntu.com/noble/"
check "prometheus"   "$(monitor_tag_of prom/prometheus)"   "v$(latest_gh prometheus/prometheus || true)" \
      "https://github.com/prometheus/prometheus/releases"
check "alertmanager" "$(monitor_tag_of prom/alertmanager)" "v$(latest_gh prometheus/alertmanager || true)" \
      "https://github.com/prometheus/alertmanager/releases"
check "blackbox-exporter" "$(monitor_tag_of prom/blackbox-exporter)" \
      "v$(latest_gh prometheus/blackbox_exporter || true)" \
      "https://github.com/prometheus/blackbox_exporter/releases"
check "cadvisor"     "$(monitor_tag_of cadvisor/cadvisor)" "v$(latest_gh google/cadvisor || true)" \
      "https://github.com/google/cadvisor/releases"

# Deliberately held — a moved upstream here is expected, not a finding.
row "grafana-oss" "$(monitor_tag_of grafana/grafana-oss)" "13.x exists" "held" \
    "review dashboards before jumping majors (manifest §3)"

# No stable machine-readable index; the reference is the whole answer.
row "MikroTik CHR" "$(pin_of CHR_VER)"      "" "manual" "https://mikrotik.com/download/chr"
row "OPNsense"     "$(pin_of OPNSENSE_VER)" "" "manual" "https://opnsense.org/download/"
row "FRR image"    "$(pin_of FRR_IMG)"      "" "manual" "https://quay.io/repository/frrouting/frr?tab=tags"
row "ET Suricata"  "$(pin_of ET_SURICATA_PATH)" "" "manual" \
    "liveness-checked by the fetch script at build time (410 on retired branches)"

echo
if [ "$DRIFT" -eq 1 ]; then
    echo "Pins moved or did not resolve. Bumping any of them is the operator's call —"
    echo "record the change in docs/plans/r770-dependency-manifest.md §0 and the runbook pin table."
    exit 2
fi
echo "Every checkable pin is current. Rows marked 'manual' still need a human."
exit 0
```

Then:

```bash
chmod +x scripts/r770-pin-check.sh
```

Note the `row` calls for `manual` and `held` deliberately bypass `check` — they must never be classified as drift.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bats tests/pin-check.bats
```

Expected: `7 tests, 0 failures`. If `reports current when upstream matches the pin` fails on the prometheus rows, the stub returned nothing for those URLs (it exits 1) — they are then `unknown`, which is drift. Extend the stub's `case` to cover the four `prometheus/*`, `google/cadvisor` URLs with the pinned values so the happy-path test is genuinely clean.

- [ ] **Step 6: Sanity-check against the real network (staging only, optional here)**

```bash
./scripts/r770-pin-check.sh
```

Expected on an internet-connected host: the full table, with `Malcolm 26.07.1` reported `current` or `MOVED` depending on what upstream has done since 2026-08-31. Record whatever it actually prints in the commit message — **do not** bump any pin in this task; that is a separate, operator-approved decision.

- [ ] **Step 7: Run the full gate and commit**

```bash
./tests/run.sh
```

Expected: `31 tests, 0 failures`.

```bash
git add scripts/r770-pin-check.sh tests/pin-check.bats tests/fixtures/
git commit -m "Add r770-pin-check.sh upstream drift report

Walking the runbook's pin table by hand across 11 upstreams every refresh
cycle is the kind of check that quietly stops happening. This reads the
pinned values out of r770-offline-fetch.sh itself, so there is no second
table to drift, and classifies each as current, MOVED, held or manual.
Advisory only - it never edits a pin. jq-free, since the staging host does
not have it."
```

---

### Task 6: Make the fetch script use the gate

Until now the gate exists but the pipeline still writes its own manifest with the defective pipeline. This closes that, and makes the verifier travel with the bundle so the R770 has it without any extra transfer step.

**Files:**
- Modify: `scripts/r770-offline-fetch.sh` (three edits: a resolved script dir + preflight guard near the pins, the manifest call at ~line 651, the closing instructions)
- Modify: `tests/lint.bats` (drop `SC2094` from `LEGACY_EXCLUDE`)

**Interfaces:**
- Consumes: `scripts/r770-bundle.sh manifest` from Task 2.
- Produces: every bundle built from now on carries `r770-bundle.sh` in its root, covered by its own manifest, so `r770-bundle.sh verify .` works on the R770 with nothing else transferred.

> **Risk, stated plainly:** `r770-offline-fetch.sh` cannot be executed in a dev sandbox — it needs Docker, ~150 GB, and hours. These edits are verified by `bash -n`, `shellcheck`, and reading, not by a full run. They are confined to the final `[10/10]` step and to a startup guard; the script is resumable, so if the manifest step fails on the staging host, rerunning redoes only that step. Say so in the handoff.

- [ ] **Step 1: Tighten the lint gate first, so it fails**

In `tests/lint.bats`, change:

```bash
LEGACY_EXCLUDE="SC2015,SC2012,SC2010,SC1091,SC2094"
```

to:

```bash
LEGACY_EXCLUDE="SC2015,SC2012,SC2010,SC1091"
```

and delete the two-line comment above it that explains the temporary `SC2094`.

- [ ] **Step 2: Run the gate to verify it fails**

```bash
./tests/run.sh
```

Expected: FAIL, one test, with exactly:

```
scripts/r770-offline-fetch.sh:651:37: note: Make sure not to read and write the same file in the same pipeline. [SC2094]
scripts/r770-offline-fetch.sh:651:123: note: Make sure not to read and write the same file in the same pipeline. [SC2094]
```

- [ ] **Step 3: Add the resolved script dir and a startup guard**

In `scripts/r770-offline-fetch.sh`, immediately after the pin block's closing rule (the `# ────` line following `PYTHON_BUILD_IMG=`), add:

```bash
# The manifest is generated by its own tested script, which also travels inside
# the bundle so the air-gapped R770 can verify without a separate transfer.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_TOOL="$SCRIPT_DIR/r770-bundle.sh"
[ -x "$BUNDLE_TOOL" ] || {
    echo "FATAL: $BUNDLE_TOOL not found or not executable — it ships alongside this script" >&2
    exit 1
}
```

Checking this at startup rather than at `[10/10]` matters: the alternative is discovering it after hours of downloading.

- [ ] **Step 4: Replace the manifest command**

At `scripts/r770-offline-fetch.sh:651`, replace:

```bash
( cd "$B" && find . -type f ! -name MANIFEST.sha256 ! -name '*.part' ! -path './.stamps/*' -print0 | xargs -0 sha256sum > MANIFEST.sha256 )
```

with:

```bash
cp "$BUNDLE_TOOL" "$B/"          # the verifier travels with the media
"$BUNDLE_TOOL" manifest "$B"
```

- [ ] **Step 5: Replace the closing instructions**

Further down, replace these two lines:

```bash
echo "regenerate the manifest after adding manual files:"
echo "  cd $B && find . -type f ! -name MANIFEST.sha256 ! -name '*.part' ! -path './.stamps/*' -print0 | xargs -0 sha256sum > MANIFEST.sha256"
```

with:

```bash
echo "regenerate the manifest after adding manual files:"
echo "  ./scripts/r770-bundle.sh manifest $B"
echo "then gate it before the media leaves staging:"
echo "  ./scripts/r770-bundle.sh verify $B --strict"
```

- [ ] **Step 6: Verify by static analysis (a full run is not possible here)**

```bash
bash -n scripts/r770-offline-fetch.sh && echo "parses"
shellcheck -e SC2015,SC2012,SC2010,SC1091 scripts/r770-offline-fetch.sh && echo "shellcheck clean"
grep -n 'BUNDLE_TOOL\|find . -type f ! -name MANIFEST' scripts/r770-offline-fetch.sh
```

Expected: `parses`, `shellcheck clean`, and the grep showing the four `BUNDLE_TOOL` references with **no** remaining `find . -type f ! -name MANIFEST` line.

- [ ] **Step 7: Prove the new call site works, standalone**

The fetch script cannot run here, but its new manifest step can be exercised directly against a fixture:

```bash
B=$(mktemp -d)/bundle-20260903 && mkdir -p "$B/apt" && echo deb > "$B/apt/x.deb" && \
  BUNDLE_TOOL=./scripts/r770-bundle.sh && \
  cp "$BUNDLE_TOOL" "$B/" && "$BUNDLE_TOOL" manifest "$B" && \
  ./scripts/r770-bundle.sh verify "$B"; echo "verify exit=$?"
```

Expected: the manifest is written covering both `./apt/x.deb` and `./r770-bundle.sh`, then verify prints warnings for the missing `dell/` and `gns3/appliances/` directories and `BUNDLE_NOTES.md`, and `verify exit=2`. The point of the check is that the copied-in verifier is itself manifested — confirm with:

```bash
grep r770-bundle.sh "$B/MANIFEST.sha256"
```

Expected: one line ending `./r770-bundle.sh`.

- [ ] **Step 8: Run the full gate and commit**

```bash
./tests/run.sh
```

Expected: `31 tests, 0 failures`.

```bash
git add scripts/r770-offline-fetch.sh tests/lint.bats
git commit -m "Generate the bundle manifest with r770-bundle.sh

Replaces the inline find|xargs sha256sum - which shellcheck flagged
(SC2094) and which reports OK for an empty bundle - with the tested
generator, and copies the verifier into the bundle root so the air-gapped
R770 can check the media without a separate transfer. The missing-tool
check runs at startup rather than at step 10/10, so it cannot surface
after hours of downloading. Verified by bash -n, shellcheck and a fixture
exercise of the new call site; a full fetch run needs Docker and ~150 GB
and was not possible here."
```

---

### Task 7: Wire the gate into the documented workflow

The scripts are useless if the runbook still tells an operator to type the old command. This is also where `state/inventory/bundles.md` — referenced by `BUILD-STATE.md`, supply plan §3.5, runbook Step 6.5, and both slash commands, and missing from the repo — finally exists.

**Files:**
- Create: `state/inventory/bundles.md`
- Modify: `docs/plans/r770-staging-runbook.md` (Steps 4, 5, 6; success criteria)
- Modify: `.claude/commands/bundle.md`
- Modify: `.claude/commands/import-bundle.md`

**Interfaces:**
- Consumes: `r770-bundle.sh manifest|verify` and `r770-pin-check.sh` from Tasks 2–5.
- Produces: no code. The documented procedure and both slash commands now call the gate, and every bundle cycle has one place to be recorded.

- [ ] **Step 1: Create the cycle log**

Create `state/inventory/bundles.md`:

```markdown
# Bundle cycle log

One entry per supply-bundle cycle. Evidence, not intent — record what the
commands actually printed. Referenced by `state/BUILD-STATE.md`, the supply
plan §3.5, the staging runbook Step 6.5, and `/bundle` / `/import-bundle`.

Cadence is **ad-hoc** (decisions record, dependency manifest §0). The accepted
risk: host security updates, ET rules and OUI data are only as fresh as the
last bundle.

## Cycles

| Date | Bundle | Size | Key versions | `verify` result | WARN dispositions | Courier | Imported on R770 |
|---|---|---|---|---|---|---|---|
| *(no bundle cut yet)* | | | | | | | |

## Per-cycle checklist

Copy this into the entry's notes as it is worked through:

- [ ] Pins reviewed: `./scripts/r770-pin-check.sh` — any `MOVED` row either bumped with the operator's OK (and recorded in dependency manifest §0) or explicitly deferred
- [ ] Bundle built: `sudo -E ./scripts/r770-offline-fetch.sh`
- [ ] Manual categories staged: Dell (`dell/`, needs the service tag) and licensed GNS3 appliances (`gns3/appliances/`)
- [ ] Manifest regenerated after the manual additions: `./scripts/r770-bundle.sh manifest bundle-YYYYMMDD`
- [ ] Gate passed on staging: `./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict`
- [ ] Ubuntu ISO GPG signature verified on staging (runbook Step 5)
- [ ] Gate passed again from the transfer media, before it leaves staging
- [ ] Site AV/content scan per policy
- [ ] Gate passed on the R770 before any import: `./r770-bundle.sh verify .`
- [ ] Previous bundle retained until this one validates
```

- [ ] **Step 2: Update runbook Step 4**

In `docs/plans/r770-staging-runbook.md`, replace the manifest-regeneration block at the end of Step 4 — the paragraph beginning "After adding manual files, **regenerate the manifest**" together with its fenced `cd bundle-YYYYMMDD && find …` command and the parenthetical about exclusions — with:

````markdown
After adding manual files, **regenerate the manifest** (the script's manifest predates them):

```bash
./scripts/r770-bundle.sh manifest bundle-YYYYMMDD
```

It refuses to write a manifest while any `.part` file is present (an incomplete
download) or when there is nothing to hash, and it keeps `.stamps/` resume
bookkeeping out. Forgetting this step used to be invisible: `sha256sum -c`
verifies only the files the manifest lists, so unmanifested manual downloads
crossed the gap unchecked. Step 5 now catches that.
````

- [ ] **Step 3: Update runbook Step 5**

Replace the body of Step 5 — from "The gapped side can only verify what the manifest asserts" through the paragraph ending "versions recorded." — with:

````markdown
The gapped side can only verify what the manifest asserts, so signature checks happen now:

```bash
cd bundle-YYYYMMDD
# Ubuntu ISO: GPG-verify the checksum file, then the ISO against it
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 0x843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --verify isos/SHA256SUMS.gpg isos/SHA256SUMS
( cd isos && grep live-server SHA256SUMS | sha256sum -c - )
cd ..

# The full-bundle gate: hashes, manifest coverage in both directions,
# incomplete downloads, BUNDLE_NOTES.md WARN lines, manual categories.
./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict
```

(Behind the proxy, gpg's keyserver fetch may need `--keyserver-options http-proxy=$HTTPS_PROXY`.) The script already sha256-verifies OPNsense and Alpine against their published checksum files at fetch time.

`verify` exits **0** (pass), **2** (pass with warnings — WARN lines to
disposition, manual categories not staged), or **1** (fail — do not transfer).
`--strict` makes warnings fail, which is the right stance before media leaves
staging. Each warning names what to do about it, and the WARN check replaces
reading `BUNDLE_NOTES.md` by eye for unresolved lines.
````

- [ ] **Step 4: Update runbook Step 6 and the success criteria**

In Step 6, replace item 1:

```markdown
1. Copy the bundle to the ext4 drive; `sha256sum -c MANIFEST.sha256` **from the media** before it leaves staging.
```

with:

```markdown
1. Copy the bundle to the ext4 drive; run `./scripts/r770-bundle.sh verify /path/to/media/bundle-YYYYMMDD --strict` **from the media** before it leaves staging — a copy that dropped or truncated a file fails here, not on the gapped side.
```

and item 3's opening:

```markdown
3. On the R770: manifest check first, then import in the order in `BUNDLE_NOTES.md`
```

with:

```markdown
3. On the R770: `./r770-bundle.sh verify .` from inside the bundle first (the verifier travels in the bundle root), then import in the order in `BUNDLE_NOTES.md`
```

In the pin-review section, after the pin table, add:

```markdown
`./scripts/r770-pin-check.sh` reports this table's drift automatically — it
reads the pinned values out of the fetch script, so the table above and the
script can never disagree. Rows marked `manual` (CHR, OPNsense, FRR, ET) still
need a human; `grafana-oss` reports `held` by design.
```

In **Success criteria**, replace the last three items with:

```markdown
- [ ] `./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict` exits 0 on staging
- [ ] Manual items (Dell, licensed appliances) present, and the manifest regenerated after adding them (`verify` fails if not)
- [ ] The same `verify --strict` exits 0 from the transfer media, and again on the R770 before any import
- [ ] Previous bundle retained until the new one validates on the R770
- [ ] Cycle recorded in `state/inventory/bundles.md`
```

- [ ] **Step 5: Update `/bundle`**

In `.claude/commands/bundle.md`, replace steps 2, 4, 5 and 6 with:

```markdown
2. Review the version pins: `./scripts/r770-pin-check.sh` (it reads them out of the fetch script). Flag every `MOVED` row; only bump with the operator's OK, and note Grafana is deliberately held at 12.x. Record a bump in `docs/plans/r770-dependency-manifest.md` §0 and the runbook pin table.
```

```markdown
4. Afterwards, remind about the two manual categories — Dell firmware (`dell/README.txt`, needs the service tag) and licensed GNS3 appliances (`gns3/appliances/README.txt`) — then regenerate the manifest so it covers them: `./scripts/r770-bundle.sh manifest bundle-YYYYMMDD`.
5. Gate it: `./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict`. Exit 1 = stop and fix. Exit 2 = disposition each warning (unresolved `BUNDLE_NOTES.md` WARN lines, unstaged manual categories) before the media moves. Also do the Ubuntu ISO GPG check per runbook Step 5 — that is the one thing `verify` cannot do for you.
6. Record the cycle in `state/inventory/bundles.md` (date, versions, bundle size, `verify` result, WARN dispositions, courier) and commit.
```

- [ ] **Step 6: Update `/import-bundle`**

In `.claude/commands/import-bundle.md`, replace step 1 with:

```markdown
1. **Verify before anything else**: from inside the bundle on the R770, `./r770-bundle.sh verify .` (the verifier travels in the bundle root). Exit 1 = stop, report, do not import. Exit 2 = report each warning and get the operator's call before proceeding. Confirm the site AV/content scan was done per policy (ask if unknown).
```

- [ ] **Step 7: Verify the wiring is consistent**

Nothing in the repo should still tell anyone to type the old command, and every reference to the cycle log should now resolve:

```bash
grep -rn "find . -type f ! -name MANIFEST" --include='*.md' --include='*.sh' . ; echo "old-command hits: $?"
grep -rln "bundles.md" --include='*.md' . 
ls -l state/inventory/bundles.md
./tests/run.sh
```

Expected: the first grep prints nothing and reports `old-command hits: 1` (grep's no-match status); the second lists `state/BUILD-STATE.md`, `state/inventory/README.md`, `docs/plans/r770-offline-supply.md`, `docs/plans/r770-staging-runbook.md`, `.claude/commands/bundle.md`, `.claude/commands/import-bundle.md` and the new file itself; `bundles.md` exists; `31 tests, 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add state/inventory/bundles.md docs/plans/r770-staging-runbook.md .claude/commands/
git commit -m "Point the bundle workflow at the integrity gate

The runbook and both slash commands still told operators to type the
find|xargs pipeline by hand. They now call r770-bundle.sh, and the R770
side runs the verifier that travels inside the bundle. Adds
state/inventory/bundles.md - the cycle log that BUILD-STATE.md, the supply
plan, the runbook and both commands all referenced but which never
existed - with a per-cycle checklist."
```

---

## What this plan deliberately does not do

- **No pin bumps.** `r770-pin-check.sh` reports drift; changing a pin is an operator decision recorded in `docs/plans/r770-dependency-manifest.md` §0 (decisions of record).
- **No restructuring of `r770-offline-fetch.sh`.** It gets three small edits and nothing else. Its SC2015/SC2012 style findings stay excluded and documented rather than rewritten blind, because the script cannot be exercised outside a real staging run.
- **No GPG verification inside `verify`.** Signature checking needs a keyring and (first time) the network. It stays a documented staging step; `verify` is the offline, dependency-free part that can also run on the R770.
- **Nothing touches the R770.** Every task here runs on the dev/staging side. `r770-bundle.sh` is *designed* to run on the R770 but is only executed there as part of a real import, under `/import-bundle`.
- **No change to what the bundle contains.** Sizes, pins, and the curated-vs-mirror decision are all untouched.

## Follow-on work this surfaces (not in scope)

- The runbook's Step 3 podman→docker interop check has no automated equivalent; it is moot on the chosen Docker path.
- `verify` could learn a `--json` mode if the validation suite (Phase 14) wants to consume its result.
- Nothing yet checks that the bundle's `apt/` repo metadata (`Packages.gz`) is consistent with the `.deb` files beside it — a real class of import failure, but it needs `dpkg-scanpackages` and belongs with the Phase 6 import work.
