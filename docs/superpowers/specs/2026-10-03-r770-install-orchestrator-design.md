# Fully deployable offline installer — orchestrator framework

**Date:** 2026-10-03 · **Status:** design drafted, awaiting operator review
**Goal (session):** "a fully deployable offline installer" for the R770 build
**Builds on:** `docs/superpowers/specs/2026-09-24-bundle-to-r770-design.md` — the operator-approved
deployment decomposition (sub-projects 0–5). This spec does not replace that decomposition or
its numbering; it designs the framework that runs it as one resumable, gated sequence instead
of operator-run commands pasted back by hand.

## What this is and isn't

"A fully deployable offline installer" turned out to already have most of its *scope* decided
on 2026-09-24: sub-projects 0–5 below cover phases 2, 3, 6, 9, 10, 13, 7, 8, 11 and 5 — the
analyst-stack deployment, in dependency order, each with its own design. **Phase 4 (users/SSH
hardening) is out of scope** by that same decision, and **sub-project 5 is deliberately scoped
to avoid touching Netplan** (dnsmasq `.lab` + chrony only) rather than reworking management
networking. Nothing here reopens either of those calls.

What's missing is *mechanism*, not scope: today each sub-project is a sequence of commands an
operator runs by hand over their own SSH session and pastes back, per
`docs/plans/r770-install-runbook.md` and the sub-project 0 spec's Part 2. This spec adds a
single resumable script that drives that same sequence, stopping cleanly at every point the
operator's manual process already stops at, so install day doesn't depend on a human re-typing
runbook steps correctly in order.

## Sub-projects this orchestrator drives (from the 2026-09-24 decomposition)

| # | Sub-project | Phases | Scripts today | Still needed |
|---|---|---|---|---|
| 0 | Bundle to the R770 (storage first) | 2, 3, bundle import | `r770-storage-apply.sh` (Phase 3 apply/plan); Phase 2 is a manual read-only block in the sub-project 0 spec, Part 2.1 | nothing new — Phase 2 stays a documented manual pre-step (operator attestation for key custody can't be scripted anyway) run once before the orchestrator starts at sub-project 0's Phase 3 piece |
| 1 | Docker from the bundle; load images | 6 | — | Docker install + `docker load` script |
| 2 | Malcolm + internal CA + portal/`docs.lab` (+ UFW) | 10, 13 | `r770-lab-ca.sh`, `r770-malcolm-deploy.sh`, `r770-portal.sh`, `r770-ufw.sh` — **proven on staging VM 9771**, `state/inventory/staging-analyst-stack-2026-09-26.md` | verb-name adapters only, if any don't already match the contract below |
| 3 | Capture ports → Malcolm live capture | 9 | — | capture-port prep script |
| 4 | Lab bridges/NAT, GNS3, virtual mirror feed | 7, 8, 11 | — | bridges/GNS3/mirror script(s) |
| 5 | dnsmasq `.lab` + chrony (avoids Netplan) | 5 | — | dnsmasq/chrony script |

Only sub-project 2 has working, proven scripts today. The rest still need their own
design/plan/execution — each is its own follow-on effort, same as before; this spec only
commits their future scripts to the contract below so they slot into the orchestrator without
rework.

## Decisions

1. **Bash**, matching every script in `scripts/` and this repo's shellcheck+bats convention.
   Rejected: a declarative YAML/JSON-driven engine (speculative generality for a fixed ~6
   sub-project list — YAGNI); a Python orchestrator (new language for no ergonomic gain at this
   scale).
2. **Formalize the contract scripts already converged on independently** rather than inventing
   a new one: `r770-storage-apply.sh` (`--plan`/`--apply`), `r770-ufw.sh`
   (`plan`/`apply`/`confirm`/`verify`/`revert`), `r770-portal.sh` and `r770-malcolm-deploy.sh`
   (verb-shaped) already separate "show what would happen" from "do it" from "prove it worked."
3. **Resumability comes from `state/BUILD-STATE.md`**, not a separate state file — the
   orchestrator reads the Phases table's Status column to decide what to skip, and writes the
   same evidence-file + BUILD-STATE-row + log-line pattern every sub-project already produces by
   hand today (CLAUDE.md phase protocol). No second source of truth.
4. **Two-tier automation**: sub-projects/steps already flagged destructive in CLAUDE.md rule 3 or
   the sub-project 0 spec (e.g. the Phase 3 apply block, the APT local-repo switch) stop after
   `plan` and wait for an explicit re-invocation with `--confirm`; everything else runs
   `plan`→`apply`→`verify` straight through.
5. **Standalone**: ships inside the bundle (next to `site/scripts/`, which the analyst stack
   already deploys from offline) so the operator runs it on the R770 over a plain SSH/console
   session with no Claude Code session required on install day.
6. **Proven on a staging VM rehearsal before ever touching the real R770** — the same pattern as
   sub-project 2's proof on VM 9771.

## Contract every sub-project's script must implement

| Verb | Does | Mutates? | Required output |
|---|---|---|---|
| `check` | Read-only discovery/status (is this already satisfied, what does the system look like) | No | Exit 0 (satisfied/ready), 1 (error), 2 (not ready — unmet dependency) |
| `plan` | Compute and print the exact change: current vs. proposed, affected device/file, data-loss risk, rollback | No | Human-readable plan matching CLAUDE.md's phase-protocol Changes/Risks/Rollback shape |
| `apply` | Execute the plan | Yes (gated steps additionally require `--confirm`) | Evidence file under `state/inventory/`; non-zero exit halts the orchestrator |
| `verify` | Prove the change worked | No | Exit 0 only with real command output as evidence (CLAUDE.md rule 4 — never fabricate) |

Scripts that already exist get a thin verb-name adapter if their flags don't already match this
table exactly — not a rewrite.

## Orchestrator behavior (`r770-install.sh`, new)

- Hardcoded sub-project table: number, name, script path(s), gated?, deps — matching
  `state/BUILD-STATE.md`'s own Phases table and the 2026-09-24 decomposition, which stay the
  single human-readable sources of truth.
- For each sub-project in dependency order (0 → 1 → 2 → 3 → 4 → 5):
  - If `state/BUILD-STATE.md` already shows its phases APPLIED/VERIFIED → skip.
  - If no script is registered yet (true for 1, 3, 4, 5 until their own design/plan/execution
    ships) → stop with a clear "not yet implemented" message, not a crash. This makes the
    orchestrator runnable and testable today, against sub-projects 0's Phase 3 piece and 2,
    before the rest exist. Sub-project 0's Phase 2 piece is never in the orchestrator's table at
    all — it stays a documented manual pre-step, run once before the orchestrator starts.
  - Else run `check` → `plan`. If gated and no `--confirm` for this step was given, print the
    plan/risk/rollback and stop cleanly (re-running after operator review and confirmation
    resumes right here). If not gated, or confirmed, continue to `apply` → `verify`, then update
    `state/BUILD-STATE.md` and append the log line, matching the existing manual convention
    exactly.
- A failed `apply`/`verify` halts the whole run with the real failure output (CLAUDE.md rule 5 —
  one change at a time, reproduce → observe → logs).

## Testing

- `tests/run.sh` bats coverage for the orchestrator's own logic in isolation: skip-already-done,
  stop-at-unregistered-step, stop-at-gate, resume-after-confirm, halt-on-failure — using fake
  stub scripts, no real system calls.
- Staging VM rehearsal: run `r770-install.sh` against a fresh VM standing in for the R770,
  through sub-project 2 (the one with real, proven scripts today), confirming gate-stop/resume
  behavior and BUILD-STATE/evidence output match what manual execution already produced on VM
  9771.

## What this spec does not decide

The internals of sub-projects 0 (Phase 2 piece)/1/3/4/5 — their actual commands, risk tables,
and rollback procedures — stay owned by their own design work (sub-project 0's is already
written; 1/3/4/5 are not). This spec only commits those future scripts to the four-verb contract
above.

## Risks

- **Contract mismatch discovered late**: if a future sub-project's flow doesn't fit the
  four-verb contract cleanly, the orchestrator needs a documented escape hatch rather than a
  silent special case. Flagged for whichever sub-project hits it, not pre-solved here.
- **CLAUDE.md's gates are unchanged by this work** — the orchestrator automates sequencing and
  bookkeeping, never the operator-confirmation requirement itself. No `apply` on a gated step
  proceeds without the same explicit confirmation the manual process already requires.
- **Phase 4 and full Netplan rework remain out of scope**, per the 2026-09-24 decision this spec
  inherits. "Fully deployable" here means sub-projects 0–5, not every phase in `PRD.md` §9.

## Next steps

On operator approval of this spec: invoke `writing-plans` for the orchestrator's implementation
plan (`r770-install.sh`, the verb adapters for sub-project 2's existing scripts, and the bats
suite), execute it, prove it on a staging VM rehearsal against sub-project 2, then return to
`2026-09-24-bundle-to-r770-design.md` to design/execute sub-projects 0, 1, 3, 4, 5 so they plug
into the now-proven contract.
