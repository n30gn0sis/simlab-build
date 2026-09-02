# state/inventory/

Evidence lives here — discovery output, phase validation results, bundle cycle logs.

Expected contents as the build progresses:

- `r770-precheck-<host>-<ts>/` + `.tar.gz` — raw Phase 1 discovery bundles from `scripts/r770-precheck.sh`
- `hardware-inventory.md` — the analyzed, evidence-quoted inventory (written by the discovery-analyst agent)
- `phase-<n>-evidence.txt` — captured command output proving each phase
- `validation-<date>.md` — validation-suite runs
- `capture-check-<date>.md` — drop-accounting reports
- `bundles.md` — one entry per supply-bundle cycle: date, versions, hashes, WARN dispositions, courier

Nothing in here is ever edited to say what *should* have happened — it records what *did*.
