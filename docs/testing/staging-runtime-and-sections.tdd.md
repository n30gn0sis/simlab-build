# TDD evidence: runtime-agnostic staging, sectioned bundle fetch

**Source plan:** the `/plan` of 2026-09-14 approved in chat ("yes"): staging
scripts accept any container runtime; the bundle fetch runs a section at a time.

## User journeys

1. As the operator, I want the preflight to judge my staging host by what its
   container runtime can do, so a host with podman, nerdctl, or a runtime the
   scripts have never seen is not refused by name.
2. As the operator, I want to run one section of the bundle fetch at a time,
   see which sections look complete, and rerun a failed one without walking
   through the others.

## Task report

| Task | RED | GREEN | Commits |
|---|---|---|---|
| Preflight by capability | `bats tests/staging-preflight.bats` → 6 of 17 fail (refusals still exit 1, nerdctl and `STAGING_CTR` unknown, no save-format probe) | 17/17; shellcheck clean | `git log --grep 'runtime-agnostic'` |
| Fetch sections + runtime | `bats tests/offline-fetch.bats` → 9 of 9 fail (no argument parser) | 9/9; `bash -n` and shellcheck (accepted legacy codes) clean; full suite 114 | `git log --grep 'sectioned'` |
| Builder passthrough | `bats tests/build-bundle.bats` → test 14 fails (`--only` unknown) | 14/14; full suite 114 | `git log --grep 'passthrough'` |
| Docs | n/a | full suite 115 (pin, owners, references guards green) | `git log --grep 'runtime-by-capability'` |

Commits are on `main` in RED→GREEN pairs; hashes are deliberately not copied
here (see the LOW finding in the previous review), use the grep above.

## Test specification

| # | What is guaranteed | Test | Type |
|---|---|---|---|
| 1 | A host with only nerdctl passes; `STAGING_CTR=<cmd>` selects a runtime by any name | `staging-preflight.bats`: nerdctl / STAGING_CTR tests | unit (stubs) |
| 2 | Rootless podman and Docker CE on RHEL exit 2 with the reason, not 1 | `staging-preflight.bats`: two "warns … but does not refuse" tests | unit |
| 3 | A runtime whose `save` yields no `manifest.json` is refused; one that does passes and says docker-archive | `staging-preflight.bats`: save-format probe tests (egress on, `timeout` and `docker` stubbed) | unit |
| 4 | Still refused: no runtime, unresponsive engine, podman below 3.0, LXC | pre-existing tests, unchanged | unit |
| 5 | `--list` names all eleven stages in fixed order and marks completion markers; touches no network | `offline-fetch.bats` 1–2 | unit |
| 6 | `--dry-run` shows the selection in fixed order; `--only` never adds manifest; `--skip` removes | `offline-fetch.bats` 3–5 | unit |
| 7 | Unknown stage or option is rejected before anything runs | `offline-fetch.bats` 6–7 | unit |
| 8 | `--only manual` runs for real: writes `dell/README.txt`, no manifest, no network call | `offline-fetch.bats` 8 | integration (real script, stubbed network) |
| 9 | A sectioned run appends to `BUNDLE_NOTES.md`; the earlier notes survive | `offline-fetch.bats` 9 | integration |
| 10 | The builder hands `--only`/`--skip` to the fetch verbatim and still runs manifest and gate | `build-bundle.bats` 14 | unit (stubs) |

## Coverage and known gaps

No line-coverage tool applies to bats. The fetch's stage bodies (the downloads
themselves) are untested here as before: they need a runtime, egress and hours.
What changed in them is mechanical wrapping into functions, checked by `bash -n`
and shellcheck, plus `$CTR` quoting.

**Not yet done, and required before the next real bundle:** one sectioned run
on staging VM 9770 against the existing bundle, e.g.
`--only enrichment` (small, fresh-per-cycle), then `--list`, recorded under
`state/inventory/`. The `--pack` carry-file must be regenerated since the
scripts changed.

The save-format probe checks one image; it narrows the risk of an unreadable
bundle, it does not replace the runbook's Step 3 load test for non-Docker
runtimes.
