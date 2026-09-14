<!-- Generated: 2026-09-14 | Files scanned: 85 | Token estimate: ~550 -->
# Tests — what each guard protects

`./tests/run.sh` = shellcheck on every script + `bats tests/*.bats`. Offline, read-only, synthetic
fixtures only (`tests/helpers/fixtures.bash`, versions are `0.0.0-fixture`). 97 tests; CI runs the same command.

| File | Tests | Guards |
|---|---|---|
| `bundle-verify.bats` | 21 | every `check_*` in the verifier: hash mismatch, uncovered file, bad parts, missing notes/manual/required, strict vs. lenient exit codes |
| `airgap-sim.bats` | 15 | generated iptables rules (stub `iptables`), unprivileged `status` must not report OPEN, sleeper PID lifecycle and cancel |
| `build-bundle.bats` | 13 | step order, preflight failure aborts before any download, unaccepted warnings stop unattended runs, manifest regenerated after the manual pause, strict gate, `--pack` output is valid bash and gitignored |
| `staging-preflight.bats` | 13 | distro paths, lxc refusal, runtime/daemon/rootful checks, free-space threshold, verifier presence |
| `bundle-manifest.bats` | 7 | manifest writer: full coverage, excludes itself and `.stamps`, refuses empty or half-downloaded bundles, reproducible, spaces in names, no temp file left behind |
| `malcolm-deploy.bats` | 7 | load then assert-tags; a missing tag fails loudly |
| `owners.bats` | 6 | **pin guard**: no version pin or size restated outside its owner (scans tracked md/sh/bats/bash, excluding state/, work/plans/archive/, OWNERS.md, the fetch script) |
| `lint.bats` | 4 | new scripts and hooks shellcheck-clean with no exclusions, legacy scripts clean bar accepted house-style codes, every script parses |
| `no-credentials.bats` | 4 | `.gitignore` keeps keys/tokens/pcaps out; no secret-looking strings tracked |
| `no-legacy-manifest.bats` | 4 | the defective manifest recipe cannot return |
| `references.bats` | 3 | every repo path named in `.claude/` or under `state/` exists; every script a slash command names is executable |

Rules the suite enforces on new content:
- Write "Malcolm's start script", not a `scripts/start` path, under `state/` (references guard).
- Never restate a pin or a bundle size in docs; point at the owner instead (pin guard).
- New tests that spawn detached processes must close fd 3 or bats hangs.
