---
description: Report build state, open unknowns, and the next actions
---

Report the current state of the sim lab build. Read-only — change nothing.

1. Read `state/BUILD-STATE.md` and summarize the 16 phases: which are VERIFIED / APPLIED / BLOCKED / READY / NOT STARTED, with blockers named.
2. From `state/inventory/`, list which of the top unknowns (PRD §11) are resolved vs still open — lead with usable storage capacity, PERC model, NIC media, NUMA locality.
3. From `state/inventory/bundles.md`, report the latest bundle: date, versions, outstanding manual items (Dell firmware, licensed appliances), and how stale rules/security debs are.
4. If the R770 is reachable and at least Phase 4 is applied, run a light health sample over SSH (uptime, `df -h` on the data LVs, failed systemd units, chrony status) — read-only only.
5. End with: the single next action, and anything waiting on the operator (confirmations, entitlement inventory, media policy).

$ARGUMENTS
