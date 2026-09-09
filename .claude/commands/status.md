---
description: Report build state, open unknowns, and the next actions
---

Report the current state of the sim lab build. Read-only — change nothing.

1. Read `state/BUILD-STATE.md` and summarize the 16 phases: which are VERIFIED / APPLIED / BLOCKED / READY / NOT STARTED, with blockers named.
2. Read PRD §11 ("Key Risks & Unknowns") for the live disposition — it already separates what discovery closed from what remains open, in priority order. Report the "Open" list as-is; do not re-derive or restate the "Closed by discovery" items as unknowns.
3. From `state/inventory/bundles.md`, report the latest bundle: date, versions, outstanding manual items (Dell firmware, licensed appliances), and how stale rules/security debs are.
4. If the R770 is reachable and at least Phase 4 is applied, run a light health sample over SSH (uptime, `df -h` on the data LVs, failed systemd units, chrony status) — read-only only.
5. End with: the single next action, and anything waiting on the operator (confirmations, entitlement inventory, media policy).

$ARGUMENTS
