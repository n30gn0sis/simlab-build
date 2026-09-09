---
description: Cut or refresh the offline supply bundle on this staging host
---

Build or resume an offline bundle per `docs/plans/r770-staging-runbook.md`. This runs LOCALLY on the staging host — never on the R770.

1. Preconditions: ≥150 GB free across `/var/lib/docker` and the output filesystem (`df -h`); docker working (`docker pull ubuntu:24.04` if in doubt); proxy configured in BOTH places if applicable (daemon drop-in + env vars — runbook §1.5).
2. Review the version pins at the top of `scripts/r770-offline-fetch.sh` against upstream (runbook pin table). Flag any that moved; only bump with the operator's OK, and note Grafana is deliberately held at 12.x.
3. Run it: `sudo -E ./scripts/r770-offline-fetch.sh` (it is resumable — rerun on failure; `BUNDLE_DIR=` to resume a previous day; it seeds from the newest sibling bundle automatically).
4. Afterwards, review `bundle-*/BUNDLE_NOTES.md`: treat any unresolved WARN line as a gate. Remind about the two manual categories — Dell firmware (`dell/README.txt`, needs service tag) and licensed GNS3 appliances (`gns3/appliances/README.txt`) — and that the manifest must be regenerated after manual files are added.
5. Verify per runbook Step 5 (Ubuntu ISO GPG, `./scripts/r770-bundle.sh verify bundle-YYYYMMDD --strict`). Exit **0** PASS · **2** PASS WITH WARNINGS (disposition each before the media moves) · **1** FAIL, do not import.
6. Record the cycle: date, versions, bundle size, WARN dispositions → `state/inventory/bundles.md`; commit.

$ARGUMENTS
