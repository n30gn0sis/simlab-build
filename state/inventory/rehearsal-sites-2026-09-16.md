# Rehearsal sites up (redeploy, left running) — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/active/2026-09-16-vm-deployment-test.md`. Format per `.claude/agents/validation-runner.md`:
check · expected · observed · verdict · command. Run over SSH from LXC 101 as `ubuntu`.

Unlike `state/inventory/rehearsal-sites-2026-09-12.md`, this deployment is from `bundle-20260915`
(the 2026-09-12 bundle no longer exists on the VM — wiped 2026-09-15) and is intentionally **left
running** at close-out — no Teardown section in this file.

## Task 1 — Readiness gate (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Proxmox VMs 100/108 stopped | stopped (operator) | operator confirmed "confirmed both are stopped" | PASS (operator) | operator statement |
| Scripts on VM match repo | sha256 pairs equal, all 6 | all 6 identical both sides (`6667ba67…` preflight, `de66af3a…` offline-fetch, `ed560973…` bundle, `a481bff2…` build-bundle, `59e1dbe4…` malcolm-deploy, `ce2238cb…` airgap-sim) | PASS | `scp …; sha256sum` both sides |
| VM memory | ≥ 11 GiB, no resize needed | `Mem: 11Gi total, 10Gi available` | PASS | `free -h` |
| Disk free | plenty of headroom | `51G used / 336G free / 387G total (14%)` | PASS | `df -h /` |
| `bundle-20260915` present | intact, ~14G, 13 top-level entries | `14G`, 13 entries | PASS | `du -sh; ls \| wc -l` |
| No stray listeners before setup | only ssh (22) and resolved (53) | `0.0.0.0:22`, `127.0.0.53%lo:53`, `127.0.0.54:53`, `[::]:22` | PASS | `ss -ltnp` |
| VM uptime | unchanged since last session (no reboot needed this time) | `2026-09-12 22:43:40` (no resize/reboot this run) | info | `uptime -s` |
