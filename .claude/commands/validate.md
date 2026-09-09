---
description: Run the validation suite (whole or one area) against the R770
argument-hint: [host|cpu|memory|storage|network|virt|gns3|wan|capture|monitoring|backup]
---

Run the validation suite from PRD §10 / buildout plan §13 against the R770 over SSH. Area filter: $ARGUMENTS (empty = everything that's been built so far per `state/BUILD-STATE.md` — never test phases not yet applied).

Rules:

- All checks are read-only or self-cleaning (a test VM is destroyed after; a WAN impairment is cleared and baseline re-verified; tcpreplay only into designated test feeds).
- Never run fio against a raw device or a filesystem with data — scratch files only.
- Capture validation is quantitative: replayed reference-PCAP packet count vs Arkime session/packet count, Zeek `capture_loss` ≈ 0, `ethtool -S` drop deltas ≈ 0. "It seems to work" is not a result.

Use the `validation-runner` subagent to execute and collect evidence. Produce a PASS/WARN/FAIL table with the exact evidence line for each check, save it under `state/inventory/`, named `validation-<date>.md`, update `state/BUILD-STATE.md`, and commit. Phases only move to VERIFIED off this evidence.
