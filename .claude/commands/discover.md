---
description: Run or ingest Phase 1 read-only hardware discovery on the R770
---

Phase 1 discovery for the R770. Everything here is READ-ONLY.

1. Check `state/BUILD-STATE.md` and `state/inventory/` — if a precheck bundle already exists, skip to step 4 (re-run only if the user asks or hardware changed).
2. Copy `scripts/r770-precheck.sh` to the R770 over SSH and run it with sudo:
   `scp scripts/r770-precheck.sh r770:/tmp/ && ssh r770 'sudo bash /tmp/r770-precheck.sh'`
   (the SSH target is unconfirmed — see the "R770 SSH target" row of `state/BUILD-STATE.md`'s Connection facts table before running this; ask the operator if it's still open).
3. Retrieve the resulting `r770-precheck-<host>-<ts>.tar.gz` into `state/inventory/` and extract it.
4. Launch the `discovery-analyst` subagent on the extracted output. It must produce `state/inventory/r770-discovery-findings.md` answering, at minimum:
   - Usable RAID capacity (the #1 unknown: ~4 TB vs ~8 TB) and actual PERC model/firmware
   - Socket/core/thread/NUMA map; sub-NUMA clustering yes/no
   - NUMA locality of each Broadcom OCP adapter, the PERC, and the integrated NIC
   - Persistent interface names (media type was settled 2026-09-03 for tag G8WFGH4: 10GBASE-T copper — re-check only if adapters change)
   - Which interface carries the management SSH session; iDRAC reachability
   - All PASS/WARN/FAIL items with disposition
5. Update `state/BUILD-STATE.md`: Phase 1 → VERIFIED (with evidence path), and record which provisional numbers in `docs/plans/r770-network-lab-buildout.md` §3/§8 must now be recomputed.
6. Report: the resolved unknowns, remaining WARN/FAIL items, and whether Phase 2 (BIOS/firmware) or Phase 3 (storage) is ready.

$ARGUMENTS

> **Phase 1 is already VERIFIED for chassis `G8WFGH4` (2026-09-03).** Evidence and analysis live in `state/inventory/`. Re-run this only after a hardware change, or to refresh evidence — and when you do, reconcile against `state/inventory/r770-discovery-findings.md` rather than treating the results as new.
