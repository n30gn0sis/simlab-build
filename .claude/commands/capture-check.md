---
description: Capture drop accounting across all three independent sources
argument-hint: [interface or feed name]
---

Check capture integrity on the R770 (target: $ARGUMENTS, or all active feeds). The capture is not trusted until this passes — buildout plan §7.4.

Collect, over SSH, from all three independent sources:

1. **NIC level** — `ethtool -S <iface>` deltas over a sampling window: `rx_dropped`, ring/fifo overruns, per-queue drops. Also confirm the port's required state: promisc on, no IP, GRO/LRO/TSO/GSO/checksum offloads OFF (`ethtool -k`), ring at discovered max, pause frames off.
2. **Arkime** — its capture stats / drop counters (API or stats page via the portal).
3. **Zeek** — `capture_loss` log values for the window (must sit ≈ 0%; alert threshold 0.5%).

Then reconcile: the three must agree. For a quantitative check, tcpreplay a reference PCAP with a known packet count into a designated test feed and compare against Arkime's indexed count.

Report per feed: pps/throughput during the window, drops from each source, verdict (CLEAN / DEGRADED / UNTRUSTWORTHY), and — only if sustained loss is proven — the escalation options in order (AF_PACKET block/fanout tuning → AF_XDP → PF_RING/DPDK as last resort) with their costs. Save the report under `state/inventory/`, named `capture-check-<date>.md`.
