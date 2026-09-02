# Build State — R770 Sim Lab

**Single source of build truth.** Updated by Claude Code after every phase action; statuses only advance with evidence (`state/inventory/`). Statuses: NOT STARTED · READY · BLOCKED · APPLIED · VERIFIED.

## Connection facts

| Item | Value |
|---|---|
| R770 SSH target | *TBD — record `user@host` or ssh-config alias here before any remote work* |
| iDRAC address | *TBD — must be recorded and verified before Phase 5* |
| Staging host | RHEL 8 + Docker CE (this machine) |
| Current bundle | *none imported yet — see `inventory/bundles.md`* |

## Phases

| # | Phase | Depends on | Status | Evidence |
|---|---|---|---|---|
| 1 | Hardware & OS discovery (read-only) | — | NOT STARTED | — |
| 2 | BIOS/firmware/iDRAC assessment; RAID VD verification | 1 | NOT STARTED | — |
| 3 | Storage: LVM/filesystem layout | 1,2 | NOT STARTED | — |
| 4 | Base OS: users, SSH hardening, UFW, packages, auditd | 3 | NOT STARTED | — |
| 5 | Management networking (Netplan, dnsmasq, chrony) | 4 | NOT STARTED | — |
| 6 | Docker Engine + Compose on lv_docker | 4 | NOT STARTED | — |
| 7 | KVM/libvirt + lab bridges + NAT zone | 5 | NOT STARTED | — |
| 8 | GNS3 server + service + proxy publication | 6,7 | NOT STARTED | — |
| 9 | Capture-port prep + drop-stat plumbing | 5 | NOT STARTED | — |
| 10 | Malcolm deployment + live capture + retention | 6,9,3 | NOT STARTED | — |
| 11 | Virtual mirror feed + imported-PCAP workflow | 10,7 | NOT STARTED | — |
| 12 | WAN impairment script library | 7 | NOT STARTED | — |
| 13 | Nginx portal + TLS + `.lab` names + docs site | 5,6 | NOT STARTED | — |
| 14 | Monitoring/alerting + capture validation suite | 10,13 | NOT STARTED | — |
| 15 | Backup jobs + restore test | 3,13 | NOT STARTED | — |
| 16 | Full validation pass + baseline + build document | all | NOT STARTED | — |

## Top unknowns (PRD §11)

| Unknown | Status |
|---|---|
| Usable RAID capacity (~4 vs ~8 TB) | OPEN |
| Actual PERC model/firmware/TRIM | OPEN |
| Capture NIC media (SFP+ vs BASE-T) | OPEN |
| NUMA locality of OCP adapters + PERC | OPEN |
| iDRAC recovery path verified | OPEN |
| Licensed GNS3 appliance entitlements | OPEN (operator) |
| Dell service tag for firmware downloads | OPEN (operator) |
| Site transfer-media scan policy | OPEN (operator) |

## Log

*(append one line per action: date · phase · what happened · evidence file)*
