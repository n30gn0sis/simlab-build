---
description: WAN impairment work - build, apply, verify, or clear tc/netem profiles
argument-hint: [apply <profile> <iface> | show | clear <iface> | new-profile <spec>]
---

WAN emulation task: $ARGUMENTS

Ground rules (from buildout plan §4.4 and `docs/analyst-wiki/wan.md`):

- Impairments apply ONLY to lab bridge/GNS3 link endpoints — never the management NIC, never capture ports. Refuse and explain if asked otherwise.
- Every profile must have apply, show, and clear paths; nothing may persist that `wan-clear` can't remove.
- Prove it, then trust it: baseline (ping/iperf3) → apply → `wan-show` → measure the physics changed (RTT ≈ baseline + delay, throughput ≈ cap) → after clearing, verify baseline returns. Remember netem shapes egress — think about direction.

Built-in profiles: branch-wan (20 Mbps/40 ms/5 ms jitter/0.2% loss), satellite (25 Mbps/600 ms RTT-equivalent), poor-broadband (10 Mbps/80 ms/2% loss), asymmetric variants (HTB rate + netem delay; IFB for ingress).

When writing new profile scripts, put them in the box's config-repo checkout at `/opt/network-lab-config`, under its own `scripts` directory (a `wan` subfolder there) — not this repo's `scripts`: readable, commented, idempotent, safe to rerun. Measurement evidence for any applied/cleared impairment goes in the report.
