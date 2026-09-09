# tests/

One command: `./tests/run.sh`. It lints every shell script and runs the bats
suites. Everything is offline and read-only — synthetic fixtures only, never a
real bundle, never the network, never the R770.

Requires `shellcheck` and `bats` (>= 1.10). The repo's SessionStart hook
installs shellcheck in web sessions; on the staging VM,
`sudo apt-get -y install shellcheck bats`.

## What is covered

| Suite | Covers |
|---|---|
| `bundle-manifest.bats` | `r770-bundle.sh manifest` — coverage, exclusions, the empty-bundle and `.part` refusals, reproducibility, spaces in filenames |
| `bundle-verify.bats` | `r770-bundle.sh verify` — one test per confirmed defect, plus WARN triage, `--strict`, and exit-code precedence |
| `lint.bats` | shellcheck over every script, and `bash -n` over all of them |

## Accepted legacy shellcheck exclusions

`scripts/r770-offline-fetch.sh` and `scripts/r770-precheck.sh` predate this
gate and cannot be exercised in a dev sandbox (the fetch script needs Docker,
~150 GB, and hours). Rewriting their style blind is a worse risk than the
findings, so these codes are excluded **for those two files only**. Scripts
written after the gate get no exclusions at all.

| Code | Why accepted |
|---|---|
| SC2015 | `cmd && note "ok" \|\| note "WARN"` is the fetch script's deliberate per-item reporting idiom; `note` cannot fail, so the classic A&&B\|\|C trap does not apply. |
| SC2012 | `ls` used to resolve a single version-glob (e.g. `vyos-*-generic-amd64.iso`) where filenames are upstream-controlled and alphanumeric. |
| SC2010 | `ls /sys/class/net \| grep -v` — a sysfs listing with fixed, safe names. |
| SC1091 | `. /etc/os-release` is not present at lint time. |
| SC2094 | **Not accepted — temporary.** A real finding at `r770-offline-fetch.sh:651`; comes off the list when that line delegates to `r770-bundle.sh` (integrity-gate Task 6). |

## Gotchas worth knowing before editing these scripts or their tests

- **A comment beginning `# shellcheck ` is parsed as a directive**, not prose.
  Starting a sentence with the word "shellcheck" produces SC1072/SC1073 syntax
  errors that look nothing like the real cause.
- **`grep` is not always GNU grep.** This repo's dev container ships `ugrep` as
  `grep`, where `'^[\]'` is a syntax error rather than a backslash match. A
  regex that errors out makes the surrounding `if` silently false — a check
  that never fires. Prefer `grep -F` with an ANSI-C-quoted needle (`$'\\'`)
  when matching literal metacharacters.
- **The `Read(**/*secret*)` deny rule in `.claude/settings.json` is
  project-tree-scoped, not filesystem-wide.** Inside the repo it blocks Bash
  commands naming such a path, `Write`, and `Read` — even for files that do
  not exist. A matching path *outside* the project tree is not blocked for
  the `Read` tool. Do not assume it protects anything beyond this repository.
  Proven by direct test during Stage 6.
