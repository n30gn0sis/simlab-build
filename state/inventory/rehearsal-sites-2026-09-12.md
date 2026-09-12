# Rehearsal sites up — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/active/2026-09-12-rehearsal-sites-up.md`. Format per `.claude/agents/validation-runner.md`:
check · expected · observed · verdict · command. Run over SSH from LXC 101 as `ubuntu`.

## Task 0 — VM grown to 12 GiB (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| VM memory | ≥ 11 GiB | `Mem: 11 0 11 0 0 11` (free -g; 12288 MiB configured) | PASS | `free -g` |
| Fresh boot after `qm set` | new boot time | `2026-09-12 22:43:39` | PASS | `uptime -s` |
| Docker | answers | `29.8.0` | PASS | `docker info` |
| VMs 100/108 | stopped (operator) | operator confirmed "done" after running the Task 0 Proxmox sequence | PASS (operator) | `qm list` |
| Note | — | nginx returned on `0.0.0.0:443` by itself: Ubuntu's package enables the unit at install. Not disabled — harmless, and it only serves what later tasks put behind it | info | `ss -ltnp` |
