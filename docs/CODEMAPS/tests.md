<!-- Generated: 2026-09-26 | Files scanned: 92 | Token estimate: ~550 -->
# Tests — what each guard protects

`./tests/run.sh` = `bats tests/*.bats`, shellcheck included (`lint.bats`). Offline, read-only, synthetic
fixtures only (`tests/helpers/fixtures.bash`, versions are `0.0.0-fixture`). Eighteen suites, 515 tests at
2026-09-26; CI runs the same command. Count with `grep -c '^@test' tests/*.bats` rather than trusting a number here.

| File | Tests | Guards |
|---|---|---|
| `bundle-verify.bats` | 29 | every `check_*` in the verifier: hash mismatch, uncovered file, bad parts, missing notes/manual/required, `check_site` WARNs, strict vs. lenient exit codes |
| `airgap-sim.bats` | 17 | generated iptables rules (stub `iptables`), unprivileged `status` must not report OPEN, sleeper PID lifecycle and cancel |
| `build-bundle.bats` | 20 | step order, preflight failure aborts before any download, unaccepted warnings stop unattended runs, manifest regenerated after the manual pause, strict gate, `--pack` output is valid bash and gitignored |
| `staging-preflight.bats` | 17 | distro paths, lxc refusal, runtime/daemon/rootful checks, free-space threshold, verifier presence. The script under test runs with a PATH of stubs plus a fixed list of real tools, so a real docker/podman/pigz on the runner cannot answer for the host under test |
| `staging-vm.bats` | 25 | `r770-staging-vm.sh` against stubbed curl/ssh: pinned node/VMID, rollback stops a running VM first, failed tasks fail, token file checks, the secret is never printed |
| `offline-fetch.bats` | 60 | the fetch's selection logic: `--list`, `--dry-run`, `--only` order and no implied manifest, `--skip`, rejections, one real network-free `--only manual` run, notes appended on sectioned runs, `resolve_latest_tag` survives `grep -m1` closing the pipe early; the `site` stage ships committed content only (canonical `SITE_SRC_ROOT` as git's `safe.directory`, or `SITE_ARCHIVE`), excludes secrets, refuses symlinks, submodules and an empty result. Network tools are stubbed to log and fail |
| `bundle-manifest.bats` | 7 | manifest writer: full coverage, excludes itself and `.stamps`, refuses empty or half-downloaded bundles, reproducible, spaces in names, no temp file left behind |
| `malcolm-deploy.bats` | 128 | load then assert-tags; every verb against stubbed installer, compose, docker, network and mount tools: idempotence, bind-loopback before start, Malcolm's tools as the PUID user, the data-dir chown allowlist (canonical, allowlisted, mounted per fstab, created if missing), PUID/PGID refusals, the password never in argv/output/files |
| `lab-ca.bats` | 36 | CA created once and never regenerated; partial or lost PKI refused by `plan` and `apply`; `--reissue-cert` revokes then rebuilds; `verify`/`export-ca` read-only; install paths and modes |
| `portal.bats` | 45 | `plan` read-only; `apply` refusals change nothing (missing CA files, missing or symlinked htpasswd, missing sources, mkdocs image); backup, install, `nginx -t` restore, reload only on change; `verify` 401/200 with the password on stdin; the repo's nginx config (catch-all, no `.lab` vhost on `:80`, headers from one snippet) |
| `ufw.bats` | 65 | discovery from `SSH_CONNECTION` and its refusals; `plan` read-only; `apply` step order, one sleeper, `--minutes` bounds, idempotence; `confirm` from a new session only; `revert`; `verify` FAIL/WARN split for listeners and DNAT; non-root refused |
| `storage-apply.bats` | 30 | `r770-storage-apply.sh` against stubbed LVM/mount tools: plan read-only, refusals change nothing, one LV per apply, fstab restored on failure, layout matches buildout §3.2 |
| `phase3-run.bats` | 9 | `r770-phase3-run.sh` order (grow-var, every LV, lv_pcap last), stops at the first failure, fstrim only with `--fstrim`, `check` only plans |
| `owners.bats` | 6 | **pin guard**: no version pin or size restated outside its owner (scans tracked md/sh/bats/bash, excluding state/, work/plans/archive/, OWNERS.md, the fetch script) |
| `lint.bats` | 4 | new scripts and hooks shellcheck-clean with no exclusions, legacy scripts clean bar accepted house-style codes, every script parses |
| `no-credentials.bats` | 5 | `.gitignore` keeps keys/tokens/pcaps out; no secret-looking strings tracked |
| `no-legacy-manifest.bats` | 4 | the defective manifest recipe cannot return |
| `references.bats` | 8 | every repo path named in `.claude/`, `BUILD-STATE.md` or under `state/` exists; every script a slash command names is executable; every `PRD.md §N` cited by `CLAUDE.md`, `OWNERS.md` or `.claude/` is a real heading, and an empty citation list fails rather than passes (self-tested on fixtures) |

Rules the suite enforces on new content:
- Write "Malcolm's start script", not a `scripts/start` path, under `state/` (references guard).
- Never restate a pin or a bundle size in docs; point at the owner instead (pin guard).
- New tests that spawn detached processes must close fd 3 or bats hangs.
- A guard that finds nothing to check must fail, not pass (see `owners.bats`, `references.bats`).
- TDD evidence for guards added test-first lives in `docs/testing/*.tdd.md`.
