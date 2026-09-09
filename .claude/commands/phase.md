---
description: Plan or execute a numbered build phase (1-16) with all safety gates
argument-hint: <phase number> [plan|execute]
---

Work build phase $ARGUMENTS of the R770 buildout.

1. Read `state/BUILD-STATE.md` and confirm every dependency phase is VERIFIED. If not, stop and say which.
2. Read the relevant sections of `docs/plans/r770-network-lab-buildout.md` and any discovery facts in `state/inventory/`. If the phase needs facts discovery hasn't produced (device names, capacities, NUMA map), stop — run `/discover` first. Never substitute placeholder names into executable commands.
3. Produce the phase in the CLAUDE.md phase format (Current State / Proposed Design / Reasoning / Changes / Commands / Risks / Validation / Rollback / Status).
4. Classify destructiveness. For anything touching storage, Netplan, firewall, SSH, RAID, or firmware: run the `safety-reviewer` subagent on the proposed commands, present its findings, and get explicit operator confirmation before executing. For Netplan changes, use `netplan try` and confirm iDRAC access is verified first.
5. Execute only with authorization, over SSH to the R770, one logical step at a time, capturing output.
6. Run the phase's validation commands (spawn `validation-runner` for anything non-trivial). Save evidence to `state/inventory/phase-<n>-evidence.txt`.
7. Update `state/BUILD-STATE.md` (APPLIED after execution, VERIFIED only with validation evidence) and commit. State the rollback path in the final report.
