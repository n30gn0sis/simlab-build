# Repository Restructure — Design Specification

**Date:** 2026-09-09 · **Status:** approved · **Analysis:** 4-dimension review at `b133628`, 17 ranked findings

## Problem

The repo holds five kinds of artifact with genuinely different lifecycles, authors and audiences, filed as if they were one kind. That is not itself harmful. The consequence is: **no fact has a declared owner**, so a correction in one file leaves the other copies wrong, and nothing in the repo can notice.

Three drift incidents have already cost real work:

| Drift | Cost |
|---|---|
| cadvisor pin verified as a GitHub *release*, not an image reference | fetch failed at `[4/10]` after 12 GB |
| Malcolm's actual release published six days before the manifest recorded 26.07.1 as "still current" (current pin: `scripts/r770-offline-fetch.sh`, see `OWNERS.md`) | a stale bundle pin |
| `6.85 TB` in `state/BUILD-STATE.md` vs `6.84 TiB` in the buildout plan | ~600 GiB error in the file CLAUDE.md calls the single source of truth |

And one defect is live: **the tested integrity gate is unreachable from every documented path.** `scripts/r770-offline-fetch.sh:700` writes `sha256sum -c MANIFEST.sha256` into every bundle's import instructions — 17 lines before `:717` copies the correct verifier into that same bundle. `grep -rn 'r770-bundle' docs/ .claude/` returns nothing operational. `bundle-20260908` is cut and waiting to cross the air gap carrying an instruction to gate the crossing with the command proven to pass unmanifested files — precisely the Dell-firmware and licensed-appliance case still outstanding.

Secret protection is equally accidental: no `.gitignore`; `.claude/settings.local.json` (containing a credential) is ignored only by `/root/.config/git/ignore`, a machine-local file. `README.md` instructs the operator to `git init` on the staging VM where that does not exist, `.claude/settings.json` auto-approves `git add`/`git commit`, and the fetch writes a 15 GB `bundle-*/` into the repo root.

## Non-goals

- **No behaviour change to the three scripts**, except where a change closes a path by which corrupt or unauthentic content reaches the air-gapped machine. Those are enumerated and deferred to their own plan.
- **No re-litigation of decisions of record** (dependency manifest §0).
- **Not a rewrite of the design.** The buildout plan's content is sound; its *addressing* is the problem.

## Target architecture: Ownership Registry (A), then the safe subset of Lifecycle (B)

**Rationale.** Zero problems in this repo were caused by a file being in the wrong directory. The one that comes closest — 98 KB (23%) of executed one-shot plans filed beside durable design — is a single `git mv`. Layout-first alternatives move most files, break §-citations from six documents, and fix no bug. Architecture C is disqualified by constraint: it cannot preserve `state/BUILD-STATE.md` as one source of truth, and `scripts/` cannot move because `r770-offline-fetch.sh:163-169` resolves `r770-bundle.sh` as a sibling.

**A is the only option that installs a mechanism.** The reason integrity-gate Task 7 vanished without trace is that nothing in the repo could notice it had. A 20-line `tests/no-legacy-manifest.bats` would have caught it. `settings.json` already pre-approves `bats` and `./tests/run.sh`; the infrastructure exists and is simply not connected to anything.

### Structure

```
simlab-build/
├── .gitignore                    NEW — in-repo, not machine-local
├── README.md                     canonical repo map (adds r770-bundle.sh, tests/)
├── CLAUDE.md                     rules; map → README; phase protocol gains a test step
├── OWNERS.md                     NEW — one declared owner per fact
├── PRD.md                        §4/§8/§10 reduced to references
├── docs/
│   ├── plans/                    SAME 4 FILES, SAME NAMES — every §-citation still resolves
│   ├── analyst-wiki/ + mkdocs.yml
│   └── superpowers/specs/        this document
├── work/plans/{active,archive}/  THE ONE MOVE
├── scripts/                      unchanged location (sibling + air-gap-name constraints)
├── state/                        UNCHANGED LAYOUT — BUILD-STATE.md stays put
├── tests/                        + no-legacy-manifest · references · owners · no-credentials
└── .github/workflows/tests.yml   NEW
```

### The ownership registry

`OWNERS.md` declares exactly one owner per fact; every other mention becomes a reference:

| Fact | Owner |
|---|---|
| Version pins | `scripts/r770-offline-fetch.sh` pin block |
| The verify command | `scripts/r770-bundle.sh` |
| Hardware of record, phase status, unknowns | `state/BUILD-STATE.md` |
| Bundle sizes and cycle history | `state/inventory/bundles.md` |
| Decisions of record | `docs/plans/r770-dependency-manifest.md` §0 |
| Success criteria | `PRD.md` §10 |

`tests/owners.bats` enforces it: no file outside an owner may restate a pin, a size, or a version.

### Deferred deliberately

- **Splitting the 489-line buildout plan into nine files.** Highest-risk item on the list, fixes no bug, and six documents cite it by section number. Defer until those citations are file links. The two deletions that matter (§11, §15 — 110 lines) can happen now without touching a single §-number below them.
- **Fetch-script correctness changes** (signature check downgraded to WARN; seeding trusting "non-empty"). These change behaviour and need the test coverage this work creates. Recorded in `BUILD-STATE.md`'s Log so they cannot vanish the way Task 7 did.

## Sequencing

| Gate | Content | Must precede |
|---|---|---|
| **0 — Safety** | `.gitignore`; the `BUNDLE_NOTES.md` line; the credential | everything |
| **1 — Reachability** | the 9 remaining verify references; lint guard; unit error; RHEL/`dnf`; repo map + test step | any move |
| **2 — Ownership** | `OWNERS.md`, the four test gates, CI | any move |
| **3 — Structure** | the `git mv`s from B's safe subset | after 2 |

Gate 0 first is not negotiable: no restructure fixes a bundle already cut and waiting, and reorganising files around a live defect gets the priority backwards.

## Success criteria (mechanical, all from repo root)

```bash
# Gate 0
test -f .gitignore && GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q .claude/settings.local.json
GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q bundle-20260908/
git grep -nE 'sshpass -p|BEGIN [A-Z ]*PRIVATE KEY' $(git rev-parse HEAD)   # → 0 matches

# Gate 1
grep -rn 'sha256sum -c MANIFEST' docs/ .claude/ scripts/                   # → 0 lines
grep -rl 'r770-bundle.sh' docs/ .claude/ | wc -l                           # → ≥ 6
grep -rn '6\.85 TB' .                                                      # → 0 lines

# Gate 2
grep -rn 'RHEL' README.md .claude/                                         # → 0 lines
./tests/run.sh                                                             # → exit 0
```

## Risks

| Risk | Mitigation |
|---|---|
| A `git mv` breaks a cross-reference silently | `tests/references.bats` written **before** any move; every path named in `.claude/` or `BUILD-STATE.md` must exist |
| Editing the fetch script cannot be end-to-end tested (needs Docker, 150 GB, hours) | Confine edits to the notes-writing block; verify with `bash -n`, shellcheck, and a fixture exercise of that block |
| `state/` is append-only evidence; restructuring must not rewrite it | `state/` layout unchanged in Gate 0–2; Gate 3 moves only `inventory/` subdirectories, never edits content |
| The unit correction changes a storage number | It is a *unit* fix (TB→TiB), not a re-measurement; the measured value in the buildout plan is authoritative and unchanged |
