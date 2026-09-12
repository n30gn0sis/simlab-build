# Malcolm offline-deployment rehearsal — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/active/2026-09-09-malcolm-rehearsal.md`. Format per `.claude/agents/validation-runner.md`:
check · expected · observed · verdict · command. Run over SSH from LXC 101 as `ubuntu`.

## Task 0 — scripts shipped, auto-revert proven (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Scripts on VM match repo | sha256 pairs equal | `b06343c3…` / `59e1dbe4…` both sides (airgap-sim at pre-fix rev; re-shipped after the fix below) | PASS | `scp …; sha256sum` both sides |
| `block --minutes 1` applies | egress to internet fails, SSH intact | `curl https://archive.ubuntu.com/` → `(28) Connection timed out`, `000`; all SSH calls answered | PASS | `sudo r770-airgap-sim.sh block --minutes 1; curl --max-time 5 …` |
| Auto-revert fires unaided | OPEN within 60 s, no DROP rules, timer gone | after 70 s: `status` → `OPEN` (root), `curl` → `200`, `iptables -S OUTPUT`/`DOCKER-USER` DROP count `0`/`0`, no airgap timer in `systemctl list-timers` | PASS | `sleep 70; sudo r770-airgap-sim.sh status; curl …; sudo iptables -S …` |
| `status` while blocked | BLOCKED | **`OPEN`** when run unprivileged (root-only `iptables -C` exit 4 swallowed as "absent") | **FAIL → fixed** | `r770-airgap-sim.sh status` (no sudo) |
| `status` after fix, unprivileged | refuses, non-zero | `r770-airgap-sim: cannot query iptables (exit 4) - status needs root`, rc=1 | PASS | same, script re-shipped |
| `status` after fix, root | OPEN | `OPEN` | PASS | `sudo r770-airgap-sim.sh status` |

**Finding:** `status` reported OPEN during a live block when run without root — the exact false pass the
simulator's header warns about. Fixed in `scripts/r770-airgap-sim.sh` (`rule_present`: only iptables exit
0/1 are answers; anything else aborts naming root) with two bats tests. Suite 92 → 94, green. Plan updated
so every `status` call uses `sudo`.

## Task 2 step 5 — the real offline load (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Malcolm images purged first | 23 → 0 | `before: 23` · `rmi ok` · `after: 0`; `/` 52 G → 30 G used | PASS | `docker rmi $(docker image ls … \| grep '^ghcr.io/idaholab/malcolm/')` |
| Egress blocked for the load | BLOCKED, pull fails | `BLOCKED (3600s until auto-revert)`; `docker pull hello-world` → `pull blocked (correct)` (30 s timeout) | PASS | `sudo r770-airgap-sim.sh block --minutes 60; timeout 30 docker pull hello-world` |
| Offline load asserts every tag | 23 × `ok`, `all images present`, rc 0 | 23 `Loaded image:` lines, 23 `ok` lines (api … zeek, all `:26.08.0`), `all images present`, `rc=0`, **real 8m41.580s** | PASS | `~/r770/scripts/r770-malcolm-deploy.sh load ~/r770/bundle-20260908` |
| Daemon state after | 23 Malcolm images, still BLOCKED | `images now: 23`; `BLOCKED (3016s until auto-revert)` | PASS | `docker image ls …; sudo r770-airgap-sim.sh status` |

**Headline:** `bundle-20260908/malcolm/malcolm-images-26.08.0.tar.gz` populates an air-gapped Docker
daemon completely — the R770 import path is proven at the image layer. Load time 8m41s on 6 vCPU /
virtio disk; expect similar or better on the R770's NVMe.

## Task 3 step 1 — BLOCKER found and fixed: installer dependencies missing from the bundle (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Installer dry-run, air-gapped | a plan of what it would write | `The ruamel.yaml module is required … The python-dotenv module is required … (ERROR) Missing one or more required libraries`, rc 1 (also: `This installer must be run as root`) | **FAIL** | `sudo python3 ./install.py --defaults --dry-run` |
| Bundle carries them | debs in `apt/` | **none** — not in `apt/`, not in the fetch script `PKGS`, not in manifest or runbook | **FAIL** | `ls bundle-20260908/apt \| grep -iE 'ruamel\|dotenv'` |
| Fix: fetch script + manifest | packages added | `python3-ruamel.yaml python3-dotenv` added to `PKGS` (`r770-offline-fetch.sh:284`), manifest §1 line added; suite 94/94 | PASS | repo edits |
| Re-run APT step only | new debs land, nothing else re-fetched | stamp `01-apt.done` cleared; `apt/` 877 → **894** debs (3 target + 14 fresher security debs); every other step skipped on stamp/file | PASS | `BUNDLE_DIR=… r770-offline-fetch.sh` (egress OPEN for this step only) |
| Manifest + gate | regenerated, PASS WITH WARNINGS | `1634 file(s), 15G`; `RESULT: PASS WITH WARNINGS — 2 warning(s)` (same accepted docs-mirror WARNs + dell/), rc 2 | PASS | `r770-bundle.sh manifest …; verify …` |
| Install from bundle, air-gapped | both packages install with no network | `BLOCKED (5400s …)`; `Setting up python3-dotenv (1.0.1-1)`, `python3-ruamel.yaml.clib (0.2.8-1build1)`, `python3-ruamel.yaml (0.17.21-1)`; `apt rc=0`; `imports ok 0.17.21` | PASS | `apt-get install ./python3-*.deb` with sourcelist=/dev/null |

**Why this matters:** bundle-20260908 as cut on 09-08 would have failed Malcolm's installer on the R770
after the media crossed the gap — a full bundle cycle to fix. Caught and repaired on staging; the
bundle is now correct in place (still named `bundle-20260908`; `bundles.md` row to be amended at close-out).
Also: `install.py` refuses to run unprivileged — the runbook's Part 8 must say `sudo`.
