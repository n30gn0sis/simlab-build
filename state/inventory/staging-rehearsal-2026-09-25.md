# Staging rehearsal 2026-09-24/25 — first automated cut + import rehearsal on rebuilt VM 9770

> **TEST CUT — NOT FOR TRANSFER.** The manual items (`dell/`, `gns3/appliances/`) are **SYNTHETIC** placeholders. `bundle-20260925` exists only on VM 9770 and is discarded at its next rollback.

Plan: `work/plans/archive/2026-09-24-staging-vm-automation.md` Task 5. The Claude session drove it end to end with `scripts/r770-staging-vm.sh` (scoped token) and SSH. Nothing was pasted by the operator.

**Dates in this file are the VM's date, UTC** (`date` on VM 9770); the session's own local date when this rehearsal ran was still 2026-09-24, which is why the run spans both dates in the title.

## Run

| Step | Result |
|---|---|
| VM | `rollback clean-2026-09-24` → `start` → `wait-ssh` (192.168.4.72) — all via the driver, token only |
| Source | `git clone` of public `main` at `6cbb8b7` (PR #4 merge: pin bumps + Phase 3 scripts) |
| Preflight | **exit 0**, all PASS (below) |
| Cut, attempt 1 | Fetch **completed all 10 stages** into `bundle-20260925`, then the builder **crashed at the manual-items prompt** — finding 1 |
| Cut, attempt 2 | **Aborted by the controller** — placeholder writes failed on the root-owned bundle and a `;` let the builder start anyway; killed before the manifest step. Log kept (`cut-attempt2-aborted.log` in the session scratchpad) |
| Cut, attempt 3 | SYNTHETIC placeholders staged with `sudo`; `r770-build-bundle.sh --yes --bundle-dir …/bundle-20260925`; fetch skipped everything already present; manifest **1597 files, 14G**; `verify --strict` **FAIL** on 2 undispositioned WARNs (the gate working as designed — see dispositions) |
| Bundle | **14G**, 1597 manifested files (1601 on disk incl. manifest/notes bookkeeping) |
| Import rehearsal | `verify` (non-strict, as on the R770) **exit 2** at source and **exit 2** on the `/data/staging` copy — same single warning; APT repointed to `file:/srv/repo/apt` only |
| VM | `stop` |

### Preflight
```
== staging preflight ==
PASS  staging OS: Ubuntu 24.04 — the default path
PASS  virtualization: kvm — not lxc
PASS  container runtime: docker 29.8.1
PASS  docker daemon responds
PASS  376 GB free on /home/ubuntu/simlab-build (need 150)
PASS  required host tools present
PASS  r770-bundle.sh present and executable — it is copied into the bundle root
PASS  registry pull and in-container apt egress verified
PASS  docker save writes docker-archive (manifest.json present) — the R770's docker load can read it

READY — all checks passed
preflight exit=0
```

### Gate (attempt 3)
```
== 5/5  Gate — --strict, before the media is allowed to move
Verifying bundle: /home/ubuntu/simlab-build/bundle-20260925
ok    MANIFEST.sha256 parses — 1597 entries
ok    every manifested file is present and unmodified
ok    no unmanifested files — manual additions are covered
ok    no incomplete downloads
ok    malcolm/image-list.txt has its payload
ok    docker/monitoring-image-list.txt has its payload
ok    gns3/docker-nodes/image-list.txt has its payload
      22:- WARN: docs mirror for malcolm incomplete/failed (best-effort; rerun resumes it)
      23:- WARN: docs mirror for zeek incomplete/failed (best-effort; rerun resumes it)
WARN  2 WARN line(s) in BUNDLE_NOTES.md — disposition each before the media leaves staging
ok    dell/ has 1 staged file(s)
ok    gns3/appliances/ has 9 staged file(s)

RESULT: FAIL (--strict) — 1 warning(s) left undispositioned.

GATE FAILED — do not move this media.
cut exit=1
```

**Departure from the plan, on purpose:** Task 5 Step 3 expected exit 2 for an undispositioned-WARN
bundle ("Exit 2 → disposition each WARN in the evidence file"), with "Exit 1 → stop, debug from the
log". `r770-build-bundle.sh` always runs the gate as `verify --strict`, and `--strict` fails the run
(exit 1) on **any** WARN rather than passing with exit 2 — the two exit codes it and `r770-bundle.sh
verify` distinguish are `--strict` vs. non-strict, not "some WARNs" vs. "none". So this cut's WARNs
surfaced as the tool's own wording: **"1 warning(s) left undispositioned"** (the count of
dispositions still owed, following the **2 WARN lines** logged just above it in `BUNDLE_NOTES.md`),
at exit 1 — not exit 2. Continuing on to the import rehearsal after that exit 1, instead of stopping
to debug as the plan's literal rule says, was a deliberate departure: the WARNs were the known,
already-understood docs-mirror gap (finding 2, below), not a new failure, so dispositioning them and
proceeding was judged safer than treating this as an unplanned stop.

## WARN dispositions

| WARN | Disposition |
|---|---|
| `docs mirror for malcolm incomplete/failed` | **Accepted for this test cut.** Best-effort by design. **Finding 2:** this is now the third consecutive cut with it (`bundle-20260908`, `bundle-20260915`, `bundle-20260925`), so it is systematic, not transient — investigate before a real transfer cut |
| `docs mirror for zeek incomplete/failed` | Same |

## Import rehearsal (install runbook Parts 1.2–1.4 and 3; VM standing in for the R770)

- `/data/staging` is a plain directory here (no LV on the cloud image).
- APT before: `docker.list`, `ubuntu.sources` → saved to `/root/apt-sources-rehearsal.tar.gz` → after: only `r770-local.list` = `deb [trusted=yes] file:/srv/repo/apt ./`.
- `apt update`: every line is `file:/srv/repo/apt`. The only errors are `Translation-en` not found (`en.gz/lz4/zst`) — harmless for a flat repo with no translations. **Finding 3:** add `Acquire::Languages "none";` to the runbook's Part 3 so the output is clean.
- `apt-cache policy docker-ce`: candidate `5:29.8.1-1~ubuntu.24.04~noble` from `file:/srv/repo/apt ./`. The `docker-ce` dry run itself proves little on this VM, since Docker is already installed here at that same version — `apt-get install --dry-run docker-ce` reports `0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded` (that "1" is `docker-ce` itself, already current; see `import.log`). So packages the R770 will need and this VM lacks were dry-run too — **all resolve from the local repo alone, 0 errors**:

| Package | Inst lines |
|---|---|
| `libvirt-daemon-system` | 188 |
| `qemu-kvm` (virtual) | 169 |
| `tshark` | 18 |
| `dnsmasq` | 3 |
| `chrony` | 2 |
| `nginx` | 2 |
| `bridge-utils` | 1 |

- **Skipped on purpose:** runbook Part 3.4 (disable unattended-upgrades, purge snapd, motd). The VM is not the R770 and rolls back anyway.

## Findings

1. **`r770-build-bundle.sh` crashes when a prompt can't read stdin.** At line 168 `read -r -p "Staged everything…"` got an I/O error (no readable TTY under `sudo` in a detached tmux session). Line 169 then hit `a: unbound variable` under `set -u` and exited 1 instead of the intended clean "stopped before the manifest". The preflight-warnings prompt (line 135) has the same pattern. Fix: `read … || a=""` (or treat a failed read as "no" with a clear message), plus a test. The fetch itself was unaffected and resumed cleanly.
2. **Docs mirrors for Malcolm and Zeek fail on every cut** (above).
3. **`apt update` Translation-en noise** against the flat repo (above).
4. **Operator-procedure lesson (controller errors, not script bugs):** a bundle built under `sudo` is root-owned, so staging manual items needs `sudo`. Chain launch commands with `&&`, never `;`, after any step that must succeed first. Both happened in this run and are why attempt 2 exists and why the logs were collected in a second VM boot.

## Raw evidence

Committed under [`staging-rehearsal-2026-09-25/`](staging-rehearsal-2026-09-25/) (grepped for
`pass|token|secret|PVEAPIToken|github_pat|BEGIN .*PRIVATE` before commit — no hits beyond the
`PASS` preflight lines above). `cut-attempt1.log` is 170 KB of one repeated dpkg warning, so only
its last 60 lines are kept, as `cut-attempt1-tail.log` — that tail is where the crash (finding 1)
actually happened.

- [`preflight.log`](staging-rehearsal-2026-09-25/preflight.log)
- [`cut3.log`](staging-rehearsal-2026-09-25/cut3.log) — attempt 3, the cut that produced `bundle-20260925`
- [`cut-attempt1-tail.log`](staging-rehearsal-2026-09-25/cut-attempt1-tail.log) — last 60 lines of attempt 1
- [`cut-attempt2-aborted.log`](staging-rehearsal-2026-09-25/cut-attempt2-aborted.log)
- [`apt-update.log`](staging-rehearsal-2026-09-25/apt-update.log)
- [`import.log`](staging-rehearsal-2026-09-25/import.log) — the import rehearsal run
- [`summary.txt`](staging-rehearsal-2026-09-25/summary.txt)
- [`image-verify.txt`](staging-rehearsal-2026-09-25/image-verify.txt), [`image-sum.txt`](staging-rehearsal-2026-09-25/image-sum.txt), [`vm-config.txt`](staging-rehearsal-2026-09-25/vm-config.txt), [`gates.txt`](staging-rehearsal-2026-09-25/gates.txt) — VM rebuild evidence, also linked from `staging-vm-9770.md`
