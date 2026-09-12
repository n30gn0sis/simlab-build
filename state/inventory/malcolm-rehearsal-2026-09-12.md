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
