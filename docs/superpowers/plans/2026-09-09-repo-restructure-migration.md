# Repository Restructure — Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tested integrity gate reachable from every documented path, give every duplicated fact one declared owner enforced by tests, and move the 98 KB of executed one-shot plans out of `docs/` — without changing what any script does.

**Architecture:** Ownership Registry (A) then the safe subset of Lifecycle (B). Layout stays almost entirely put; the mechanism is new tests plus CI that make drift impossible to reintroduce silently. One `git mv` group, performed only after the reference guard exists to verify it.

**Tech Stack:** bash, git, bats 1.10, shellcheck, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-09-09-repo-restructure-design.md`

## Global Constraints

- **No behaviour change to any script.** The only script edits are one `echo` block in the fetch script's notes section and a changelog trim. Anything that changes what a script *does* is out of scope and recorded in `BUILD-STATE.md`'s Log instead.
- **`scripts/` cannot move.** `r770-offline-fetch.sh:163-169` resolves `r770-bundle.sh` as a sibling, and `r770-bundle.sh` ships inside the air-gap bundle under that exact name.
- **`state/BUILD-STATE.md` stays where it is** — CLAUDE.md designates it the single source of build truth and eight files reference it.
- **`state/` is append-only evidence.** Never edit a recorded observation to say what should have happened (`state/inventory/README.md:14`). Corrections are appended, not rewritten.
- **Use `git mv`, never delete+add** — history must stay followable.
- **The fetch script cannot be run end-to-end here** (needs Docker, ~150 GB, hours). Verify its edits with `bash -n`, `shellcheck`, and inspection of the edited block only.
- **Every stage ends with `./tests/run.sh` green** and one commit. No stage may leave the repo unverifiable.
- Commit style: imperative, capitalized, no `feat:`/`fix:` prefix.

## Category mapping

All eight requested categories are present and separated. The sequence differs from the request in one place, deliberately:

| Requested category | Stage here | Why moved |
|---|---|---|
| 1. non-functional moves/renames | **Stage 3** | Deferred until `references.bats` (Stage 2) can verify no link breaks |
| 2. dependency/import corrections | Stage 4 | Follows the moves it corrects |
| 3. component boundary changes | Stage 5 | `OWNERS.md` — needs the moves settled first |
| 4. configuration cleanup | **Stage 0** (safety subset) + Stage 6 | `.gitignore` is safety-critical, pulled forward |
| 5. dead-code removal | Stage 7 | Lowest risk, last before validation |
| 6. documentation changes | **Stage 0** (safety subset) + Stage 1 | The `BUNDLE_NOTES.md` line gates an air-gap crossing |
| 7. CI/CD changes | Stage 2 | Must exist before moves so regressions are caught |
| 8. final validation | Stage 8 | Unchanged |

---

## Stage 0 — Safety (blocking; nothing else starts until this lands)

**Rationale:** `bundle-20260908` is cut and waiting to be carried to an air-gapped machine, carrying an instruction to gate that crossing with a command proven to pass unmanifested files. And secret protection currently depends on a file outside the repo. Reorganising around either gets the priority backwards.

**Files:** Create `.gitignore`, `tests/no-secrets.bats` · Modify `scripts/r770-offline-fetch.sh:700` · Modify (untracked) `.claude/settings.local.json`

> **Editorial note (Stage 6, fix round 1):** `tests/no-secrets.bats` was later renamed to
> `tests/no-credentials.bats`. `Read(**/*secret*)` in `.claude/settings.json` also blocks Bash
> commands that merely *name* a path containing "secret" (not just Read calls), so this
> test's own filename collided with the guard it implements. The steps and code below are
> the historical record of what Stage 0 actually did and ran, under the original filename —
> left unedited on purpose.

- [ ] **Step 1: Write the failing safety test**

Create `tests/no-secrets.bats`:

```bash
#!/usr/bin/env bats
# Secret protection must live IN the repo. It currently depends on
# /root/.config/git/ignore -- a machine-local file. README.md tells the operator
# to `git init` on the staging VM, where that file does not exist, and
# .claude/settings.json auto-approves `git add` and `git commit`.

@test "a .gitignore exists in the repo" {
    [ -f "$BATS_TEST_DIRNAME/../.gitignore" ]
}

@test "settings.local.json is ignored by the REPO, not by a machine-local file" {
    cd "$BATS_TEST_DIRNAME/.."
    run env GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q .claude/settings.local.json
    [ "$status" -eq 0 ]
}

@test "bundle output directories are ignored" {
    cd "$BATS_TEST_DIRNAME/.."
    run env GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q bundle-20260908/
    [ "$status" -eq 0 ]
}

@test "no credential-shaped string is tracked" {
    cd "$BATS_TEST_DIRNAME/.."
    run git grep -nE 'ssh[p]ass -p [^$]|BEGIN [A-Z ]*PRIVATE KEY' -- ':!tests/'
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bats tests/no-secrets.bats`
Expected: tests 1–3 FAIL (no `.gitignore` exists). Test 4 passes already — the credential is untracked, which is exactly the fragile state this stage fixes.

- [ ] **Step 3: Write `.gitignore`**

```gitignore
# Bundle output. r770-offline-fetch.sh writes bundle-YYYYMMDD/ to $(pwd), and
# .claude/commands/bundle.md runs it from the repo root, so a 15 GB tree lands
# here. .claude/settings.json auto-approves `git add` and `git commit`.
bundle-*/
*.tar.gz
*.part

# Discovery output from r770-precheck.sh
r770-precheck-*/
r770-precheck-*.tar.gz

# Machine-local agent settings. May contain credentials in permission entries;
# previously protected only by a global gitignore outside the repo.
.claude/settings.local.json

# Editor / OS noise
*.swp
.DS_Store
```

- [ ] **Step 4: Fix the line that crosses the air gap**

`scripts/r770-offline-fetch.sh:700` writes into every bundle's `BUNDLE_NOTES.md`:

```bash
    echo "1. sha256sum -c MANIFEST.sha256   (before anything else)"
```

Replace with:

```bash
    echo "1. ./r770-bundle.sh verify .     (before anything else -- the verifier"
    echo "   ships in this bundle root and is covered by MANIFEST.sha256. Exit 0"
    echo "   PASS, 2 warnings to disposition, 1 DO NOT IMPORT. Plain 'sha256sum -c'"
    echo "   cannot see files added after the manifest was written, which is"
    echo "   exactly the Dell firmware and licensed-appliance case.)"
```

- [ ] **Step 5: Verify the edit without running the full fetch**

```bash
bash -n scripts/r770-offline-fetch.sh && echo "parses"
shellcheck -e SC2015,SC2012,SC2010,SC1091 scripts/r770-offline-fetch.sh && echo "lint clean"
sed -n '695,712p' scripts/r770-offline-fetch.sh
grep -c 'sha256sum -c MANIFEST' scripts/r770-offline-fetch.sh
```

Expected: `parses`, `lint clean`, the notes block naming `./r770-bundle.sh verify .`, and **0** occurrences of the old command.

- [ ] **Step 6: Remediate the already-cut bundle**

`bundle-20260908` on staging VM 9770 (192.168.4.28) carries the old instruction. `BUNDLE_NOTES.md` is regenerated on every fetch run, so re-cutting is unnecessary — patch in place and regenerate the manifest so the change is covered:

```bash
ssh ubuntu@192.168.4.28 \
  "cd ~/r770/bundle-20260908 && \
   sed -i 's|^1\. sha256sum -c MANIFEST.sha256.*|1. ./r770-bundle.sh verify .     (before anything else)|' BUNDLE_NOTES.md && \
   grep -A2 'Import order' BUNDLE_NOTES.md && \
   ~/r770/scripts/r770-bundle.sh manifest . && ./r770-bundle.sh verify ."
```

Expected: step 1 of the import order names the shipped verifier, and `verify` exits **2** (the two known docs-mirror WARNs plus unstaged `dell/`), not 1.

- [ ] **Step 7: Purge the credential from the untracked settings**

```bash
grep -c sshpass .claude/settings.local.json
python3 - <<'PY'
import json, pathlib
p = pathlib.Path(".claude/settings.local.json")
c = json.loads(p.read_text())
for k in ("allow", "deny", "ask"):
    if k in c.get("permissions", {}):
        c["permissions"][k] = [e for e in c["permissions"][k] if "sshpass" not in e]
p.write_text(json.dumps(c, indent=2) + "\n")
PY
grep -c sshpass .claude/settings.local.json     # expect 0
```

**Also rotate the Proxmox root password.** `state/inventory/staging-vm-9770.md:133` has recorded it as needing rotation since 2026-09-04 and it has not happened. Operator action, not a repo change.

- [ ] **Step 8: Run the gate and commit**

```bash
bats tests/no-secrets.bats
./tests/run.sh
git add .gitignore tests/no-secrets.bats scripts/r770-offline-fetch.sh
git commit -m "Stop routing the air-gap crossing around its own integrity gate

r770-offline-fetch.sh:700 wrote 'sha256sum -c MANIFEST.sha256' into every
bundle's import instructions, 17 lines before :717 copied the tested verifier
into that same bundle. The gate shipped with the media and nothing told anyone
to run it. bundle-20260908 is cut and waiting, and the outstanding manual items
are exactly the unmanifested-file case that command cannot see.

Also adds the repo's first .gitignore. Secret protection depended on
/root/.config/git/ignore, a machine-local file, while README.md tells the
operator to git init on the staging VM where it does not exist and
settings.json auto-approves git add and git commit."
```

**Rollback:** `git revert` the commit. `.gitignore` is inert; the script edit touches only an `echo`. The bundle's `BUNDLE_NOTES.md` is regenerated by the next fetch run regardless.

---

## Stage 1 — Documentation changes: make the gate reachable (category 6)

Nine tracked references still instruct the reader to use the defective command.

**Files:** `docs/plans/r770-staging-runbook.md:139,154,163,206` · `docs/plans/r770-offline-supply.md:105` · `docs/plans/r770-dependency-manifest.md:22,168` · `.claude/commands/import-bundle.md:8` · `.claude/commands/bundle.md:11` · `.claude/agents/bundle-builder.md:16` · Create `tests/no-legacy-manifest.bats`

- [ ] **Step 1: Write the guard first, so the recipe cannot return**

Create `tests/no-legacy-manifest.bats`:

```bash
#!/usr/bin/env bats
# The defective recipe must not reappear. r770-bundle.sh:14-18 records why:
# `find | xargs sha256sum` reports OK for an empty bundle, for files added after
# the manifest was written, and for leftover .part downloads -- each reproduced
# against the real command. This test is the reason integrity-gate Task 7 cannot
# vanish again.

@test "no document instructs the reader to hand-roll a manifest" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rn 'xargs -0 sha256sum' --include='*.md' . | grep -v '/work/plans/archive/'"
    echo "$output"
    [ -z "$output" ]
}

@test "no document or script gates a bundle with plain sha256sum -c" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rn 'sha256sum -c MANIFEST' docs/ .claude/ scripts/ | grep -v '/superpowers/'"
    echo "$output"
    [ -z "$output" ]
}

@test "the gate is referenced from the operational paths that use it" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rl 'r770-bundle.sh' docs/plans/ .claude/ | wc -l"
    [ "$output" -ge 5 ]
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bats tests/no-legacy-manifest.bats`
Expected: all 3 FAIL — nine references present, gate referenced from no operational path.

- [ ] **Step 3: Replace each reference**

Same shape everywhere. Staging-side:

```bash
./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict
```

R770-side (the verifier travels in the bundle root):

```bash
./r770-bundle.sh verify .
```

Document the exit contract wherever the command is acted on — `.claude/commands/import-bundle.md` and `bundle.md` both need it:

> Exit **0** PASS · **2** PASS WITH WARNINGS (disposition each before the media moves) · **1** FAIL, do not import.

`docs/plans/r770-dependency-manifest.md:22` is a **decision of record** ("Drive helper script | None — manual rsync + `sha256sum -c`"). Amend rather than silently overwrite, per CLAUDE.md:

> | Drive helper script | **Superseded 2026-09-09**: `scripts/r770-bundle.sh verify` is the gate. Was: manual `sha256sum -c`, which cannot see unmanifested files. |

- [ ] **Step 4: Verify**

```bash
bats tests/no-legacy-manifest.bats
grep -rl 'r770-bundle.sh' docs/ .claude/ | wc -l     # expect >= 6
```

- [ ] **Step 5: Fix the unit error in the source of truth**

`state/BUILD-STATE.md:25,52` say **6.85 TB**; `docs/plans/r770-network-lab-buildout.md:93,121,341` say **6.84 TiB**. 6.85 TB is 6.23 TiB — a ~600 GiB discrepancy in the file CLAUDE.md designates authoritative. The buildout figure is the measured one.

```bash
sed -i 's/≈6\.85 TB free extents/≈6.84 TiB free extents/g' state/BUILD-STATE.md
grep -rn '6\.85 TB' . --exclude-dir=.git             # expect 0 lines
grep -rho '6\.8[0-9] TiB' --include='*.md' . | sort -u   # expect exactly one form
```

- [ ] **Step 6: Run the gate and commit**

```bash
./tests/run.sh
git add docs/ .claude/ state/BUILD-STATE.md tests/no-legacy-manifest.bats
git commit -m "Route every documented path through the integrity gate

Nine tracked references still told the reader to gate a bundle with plain
sha256sum -c, including the import command and the bundle-builder agent. The
guard test is written first, so the recipe cannot return the way Task 7 did.

Also corrects a unit error in the single source of truth: BUILD-STATE.md said
6.85 TB where the measured figure is 6.84 TiB, understating free extents by
roughly 600 GiB."
```

**Rollback:** `git revert`. Documentation plus one `sed` on a status file; no script or test behaviour changes.

---

## Stage 2 — CI/CD and the reference guard (category 7)

Written **before** any move, so Stage 3 has something to verify it.

**Files:** Create `tests/references.bats`, `.github/workflows/tests.yml` · Modify `state/inventory/README.md`

- [ ] **Step 1: Write the reference guard**

Create `tests/references.bats`:

```bash
#!/usr/bin/env bats
# Every repo-relative path named in agent config or in the build tracker must
# exist. This is what makes the Stage 3 moves safe, and it catches phantom
# references like state/inventory/hardware-inventory.md, which is named in
# state/inventory/README.md but has never existed.

@test "every repo path named in .claude/ or BUILD-STATE.md exists" {
    cd "$BATS_TEST_DIRNAME/.."
    missing=""
    while read -r p; do
        [ -e "$p" ] || missing="$missing $p"
    done < <(grep -rhoE '(state|docs|scripts|tests|work)/[A-Za-z0-9_./-]+' \
                 .claude/ state/BUILD-STATE.md 2>/dev/null \
             | sed 's/[.,)`]*$//' | sort -u)
    echo "missing:$missing"
    [ -z "$missing" ]
}

@test "every script referenced by a slash command exists and is executable" {
    cd "$BATS_TEST_DIRNAME/.."
    while read -r s; do
        [ -x "$s" ] || { echo "not executable: $s"; false; }
    done < <(grep -rhoE 'scripts/[a-z0-9-]+\.sh' .claude/ | sort -u)
}
```

- [ ] **Step 2: Run it — expect a real finding, not a clean pass**

Run: `bats tests/references.bats`
Expected: the first test **FAILS**, naming `state/inventory/hardware-inventory.md` — referenced at `state/inventory/README.md:8` but never created. **Correct the reference to `r770-discovery-findings.md`**, which holds that content. Do not invent a file to satisfy a test.

- [ ] **Step 3: Add CI**

Create `.github/workflows/tests.yml`:

```yaml
name: tests
on:
  pull_request:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck and bats
        run: sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck bats
      - name: Run the gate
        run: ./tests/run.sh
```

The suite is offline, read-only, uses synthetic fixtures, never contacts the R770, and takes ~2 seconds — it needs nothing else.

- [ ] **Step 4: Verify and commit**

```bash
./tests/run.sh
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tests.yml')); print('valid yaml')"
git add tests/references.bats .github/ state/inventory/README.md
git commit -m "Add a reference guard and wire the test suite to CI

The repo had 32 tests and nothing ran them on a pull request. The reference
guard is a precondition for the file moves in the next stage: it asserts every
repo-relative path named in agent config or the build tracker exists, and it
immediately caught state/inventory/hardware-inventory.md, referenced in that
directory's README but never created."
```

**Rollback:** `git revert`. Adding CI cannot break local work; the guard is additive.

---

## Stage 3 — Non-functional moves and renames (category 1)

Only now, with `references.bats` able to verify the result.

| From | To |
|---|---|
| `docs/superpowers/plans/2026-09-03-bundle-integrity-gate.md` | `work/plans/archive/2026-09-03-bundle-integrity-gate.md` |
| `docs/superpowers/plans/2026-09-09-malcolm-offline-deployment-rehearsal.md` | `work/plans/active/2026-09-09-malcolm-rehearsal.md` |
| `docs/superpowers/plans/2026-09-09-repo-restructure-migration.md` | `work/plans/active/2026-09-09-repo-restructure-migration.md` |
| `docs/superpowers/specs/` | **stays** — specs are durable design, not one-shot work orders |

- [ ] **Step 1: Move with history preserved**

```bash
mkdir -p work/plans/archive work/plans/active
git mv docs/superpowers/plans/2026-09-03-bundle-integrity-gate.md work/plans/archive/
git mv docs/superpowers/plans/2026-09-09-malcolm-offline-deployment-rehearsal.md \
       work/plans/active/2026-09-09-malcolm-rehearsal.md
git mv docs/superpowers/plans/2026-09-09-repo-restructure-migration.md work/plans/active/
git log --follow --oneline work/plans/archive/2026-09-03-bundle-integrity-gate.md | head -3
```

Expected: `--follow` shows history across the move.

- [ ] **Step 2: Add status headers so an executed plan reads as executed**

Top of the archived plan:

```markdown
> **STATUS: EXECUTED 2026-09-03 — archived.** Tasks 1–4 and 6 shipped in `0938174`.
> **Task 5 (`scripts/r770-pin-check.sh`) and Task 7 (wire the gate into the docs) never landed.**
> Task 7's absence is what let every documented path keep pointing at the defective
> manifest command until 2026-09-09. Task 5 is still unbuilt — tracked in `state/BUILD-STATE.md`.
> Kept as an outcome record. Do not execute.
```

Top of the active rehearsal plan:

```markdown
> **STATUS: NOT STARTED.** Requires staging VM 9770 and `bundle-20260908`.
```

- [ ] **Step 3: Verify nothing broke**

```bash
bats tests/references.bats
grep -rn 'docs/superpowers/plans' . --exclude-dir=.git
./tests/run.sh
```

Any hit from that grep is an inbound link to fix in Stage 4.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Move executed plans out of docs/ into work/plans/

98 KB -- 23% of the repo, its largest category by bytes -- was one-shot agent
work orders filed beside durable design, with no status marking. Both were
stale. The archive carries an executed-status header naming the two tasks that
never landed, so the gap that produced the integrity-gate defect is legible
rather than implied."
```

**Rollback:** `git revert` restores the paths; `git mv` is a rename, so no content is at risk.

---

## Stage 4 — Dependency and reference corrections (category 2)

**Files:** whichever the Stage 3 grep surfaced — expected `README.md`, `CLAUDE.md`, `state/BUILD-STATE.md`.

- [ ] **Step 1: Fix every inbound link the move broke**

```bash
grep -rn 'docs/superpowers/plans' . --exclude-dir=.git
```

Rewrite each to its `work/plans/{archive,active}/` destination.

- [ ] **Step 2: Correct the repo map in both places it appears**

`CLAUDE.md`'s "Repo map" and `README.md` both omit `scripts/r770-bundle.sh`, `tests/`, and `work/` — and CLAUDE.md's map is loaded into every session, so it actively misinforms. Update both, then reduce CLAUDE.md's to a pointer at README so there is one map, not two.

- [ ] **Step 3: Verify and commit**

```bash
bats tests/references.bats
grep -rn 'docs/superpowers/plans' . --exclude-dir=.git    # expect 0
./tests/run.sh
git commit -am "Correct inbound references after the plan move"
```

---

## Stage 5 — Component boundaries: the ownership registry (category 3)

**Files:** Create `OWNERS.md`, `tests/owners.bats`

- [ ] **Step 1: Write the enforcement test first**

Create `tests/owners.bats`:

```bash
#!/usr/bin/env bats
# One owner per fact. Restating a pin or a size outside its owner is how the
# cadvisor pin went stale and how the retention table drifted 10x from reality.

@test "version pins live only in the fetch script and the dependency manifest" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rlE '26\.08\.0|v0\.34\.0|v0\.60\.5|10\.7\.1' --include='*.md' --include='*.sh' . \
                 | grep -vE '/(state|work)/' | grep -v dependency-manifest | grep -v OWNERS.md"
    echo "$output"
    [ -z "$output" ]
}

@test "bundle sizes live only in the cycle log" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rn '45–65 G[B]\|40–55 G[B]' --include='*.md' . \
                 | grep -vE '/(state|work)/' | grep -v OWNERS.md"
    echo "$output"
    [ -z "$output" ]
}

@test "no document claims the staging host is RHEL" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rn 'RHEL' README.md .claude/ | grep -v OWNERS.md"
    echo "$output"
    [ -z "$output" ]
}
```

- [ ] **Step 2: Run it — expect failures naming the actual violations**

Run: `bats tests/owners.bats`
Expected: failures listing every file that restates a pin, a size, or claims RHEL staging. That list is the Step 3 worklist.

- [ ] **Step 3: Write `OWNERS.md` and convert each violation to a reference**

`OWNERS.md` is a table of fact, owner, and how to reference it:

| Fact | Owner |
|---|---|
| Version pins | `scripts/r770-offline-fetch.sh` pin block |
| The verify command | `scripts/r770-bundle.sh` |
| Hardware of record, phase status, unknowns | `state/BUILD-STATE.md` |
| Bundle sizes and cycle history | `state/inventory/bundles.md` |
| Decisions of record | `docs/plans/r770-dependency-manifest.md` §0 |
| Success criteria | `PRD.md` §10 |

For each violation, replace the restated value with a pointer — e.g. "pins: see the pin block in `scripts/r770-offline-fetch.sh`".

- [ ] **Step 4: Verify and commit**

```bash
bats tests/owners.bats
./tests/run.sh
git add OWNERS.md tests/owners.bats
git commit -m "Declare one owner per fact and enforce it with tests"
```

---

## Stage 6 — Configuration cleanup, remainder (category 4)

- [ ] **Step 1: Reconcile `.claude/` with reality**

`.claude/commands/status.md` lists unknowns that discovery already resolved; `discover.md` references an SSH alias `state/BUILD-STATE.md:14` still says needs confirming. Point both at the live table rather than restating it.

- [ ] **Step 2: Add the test step to the phase protocol**

CLAUDE.md's phase protocol has no step that runs the suite. Add one after "Validation": *"Run `./tests/run.sh`; a phase does not advance on a red suite."*

- [ ] **Step 3: Verify and commit**

```bash
./tests/run.sh
python3 -c "import json; json.load(open('.claude/settings.json')); print('valid json')"
git commit -am "Reconcile agent configuration with the discovered state"
```

---

## Stage 7 — Dead-code and dead-content removal (category 5)

- [ ] **Step 1: Confirm no external citation before deleting**

```bash
grep -rn '§11\|§15' . --exclude-dir=.git | grep -v network-lab-buildout
```

Expected: no external citation of §11 or §15. If one exists, convert it to a pointer first.

- [ ] **Step 2: Delete the two superseded buildout sections**

`docs/plans/r770-network-lab-buildout.md` §11 (Build Phases) duplicates `state/BUILD-STATE.md`'s table, which is authoritative and diverges from it. §15 (Phase 1 discovery commands) is superseded by `scripts/r770-precheck.sh`, which was executed. Together ~110 lines. **Both sit below every §-number cited elsewhere**, so removal breaks no citation.

- [ ] **Step 3: Trim the fetch script's self-contradicting changelog**

115 of 729 lines are a changelog whose entries contradict each other (v3.3 describes behaviour v3.5 replaced). Reduce to the current version plus a pointer to `git log`.

- [ ] **Step 4: Verify and commit**

```bash
bash -n scripts/r770-offline-fetch.sh
shellcheck -e SC2015,SC2012,SC2010,SC1091 scripts/r770-offline-fetch.sh
./tests/run.sh
git commit -am "Remove superseded sections and a self-contradicting changelog"
```

**Rollback:** `git revert`. Deleted content remains in history, and both sections are superseded by files that are authoritative.

---

## Stage 8 — Final validation (category 8)

- [ ] **Step 1: Run every success criterion from the spec**

```bash
test -f .gitignore
GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q .claude/settings.local.json
GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q bundle-20260908/
! git grep -nE 'ssh[p]ass -p [^$]|BEGIN [A-Z ]*PRIVATE KEY' -- ':!tests/'
! grep -rn 'sha256sum -c MANIFEST' docs/ .claude/ scripts/
[ "$(grep -rl 'r770-bundle.sh' docs/ .claude/ | wc -l)" -ge 6 ]
! grep -rn '6\.85 TB' . --exclude-dir=.git
! grep -rn 'RHEL' README.md .claude/
! grep -rn 'docs/superpowers/plans' . --exclude-dir=.git
./tests/run.sh
```

Every line must succeed. A leading `!` asserts **no matches**.

- [ ] **Step 2: Confirm no behaviour changed**

```bash
git diff --stat b133628..HEAD -- scripts/
```

Expected: changes confined to `r770-offline-fetch.sh` — the notes `echo` block and the changelog trim. **`r770-bundle.sh` and `r770-precheck.sh` must show zero diff.** If either changed, a non-goal was violated; revert that hunk.

- [ ] **Step 3: Record and commit**

Append one line to `state/BUILD-STATE.md`'s Log, and record the two deferred items there so they cannot vanish the way Task 7 did:

- integrity-gate **Task 5** — `scripts/r770-pin-check.sh`, still unbuilt
- fetch-script correctness changes — the signature check downgraded to WARN, and seeding trusting "non-empty"

```bash
./tests/run.sh
git commit -am "Record the restructure and its deferred items"
```

---

## Rollback strategy overall

Every stage is one commit, independently revertable, and leaves `./tests/run.sh` green. Nothing rewrites history. `git mv` preserves file history, so reverting Stage 3 restores paths without content risk.

The single stage with an external side effect is **Stage 0 Step 6**, which edits `BUNDLE_NOTES.md` inside `bundle-20260908` on the staging VM. That file is regenerated on every fetch run, so its rollback is "run the fetch again" — and the pre-edit state is the defective instruction, which is not a state worth restoring.

## Test count after each stage

| After stage | Tests | Added |
|---|---|---|
| 0 | 36 | `no-secrets.bats` (4) |
| 1 | 39 | `no-legacy-manifest.bats` (3) |
| 2 | 41 | `references.bats` (2) |
| 5 | 44 | `owners.bats` (3) |
