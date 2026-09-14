# TDD evidence: PRD section-anchor guard

**Source plan:** none. Journey derived during this run, as the follow-up to the
2026-09-14 restructure of `PRD.md` whose plan verified section anchors by hand.

## User journey

As the lab operator, I want every `PRD.md §N` citation in `CLAUDE.md`,
`OWNERS.md` and the agent prompts to point at a heading that exists, so that a
future PRD restructure cannot silently leave a rule pointing at the wrong section.

## Task report

| Stage | Command | Outcome |
|---|---|---|
| RED | `bats tests/references.bats` | 3 of 6 fail: `assert_prd_sections_exist: command not found` (127); the fixture test fails on its `§9` output assertion, not vacuously |
| GREEN | `bats tests/references.bats` | 6 of 6 pass |
| Mutation | scratch copy with `## 10.` renumbered to `## 13.`, then the real-repo test alone | fails with `cited under CLAUDE.md OWNERS.md .claude/ but no such heading in PRD.md: §10` |
| Gate | `./tests/run.sh` | 100 tests, green |

Checkpoint commits on `main`: `9d82707` (test, RED) → `e5bca3b` (fix, GREEN) → this commit (docs).

## Test specification

| # | What is guaranteed | Test | Type | Result |
|---|---|---|---|---|
| 1 | A cited section with no heading fails the check and is named; existing sections are not named | `references.bats: the PRD-anchor check fails when a cited section has no heading, and names it` | unit (fixture) | PASS |
| 2 | When every cited section exists the check passes, including `PRD.md §1` without backticks | `references.bats: the PRD-anchor check passes when every cited section exists` | unit (fixture) | PASS |
| 3 | Every `PRD.md §N` in `CLAUDE.md`, `OWNERS.md`, `.claude/` is a `## N.` heading today | `references.bats: every PRD.md section cited by CLAUDE.md, OWNERS.md or .claude/ exists as a heading` | repo guard | PASS |

## Coverage and known gaps

No line-coverage tool applies to bats; the helper is 12 lines and both of its
branches (missing, present) are exercised by the fixtures. Intentional gaps:

- `docs/` and `work/plans/archive/` are not scanned. Archived plans cite sections
  of older PRD versions (for example §3.4) as frozen history, and design docs are
  not binding rules.
- Sub-section citations (`§3.4`) are matched on their leading integer only.
- A citation split across lines ("PRD.md" on one line, "§10" on the next) is not
  seen. None exists today.
