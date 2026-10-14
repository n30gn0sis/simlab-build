#!/usr/bin/env bash
# traffic/profile-basic.sh — Lane A generated traffic, run in the site-A netshoot node.
# ~240 s of load, then a 40 s idle tail (DPD window). Spec §7.1.
# SEED (env, default 1001) only picks the order of the four load phases; durations,
# rates and request counts are fixed, so two runs with one seed are comparable.
# Failures do not stop the run: the capture is the evidence. Each step logs "FAILED: ..." to
# stderr (traffic.out) and the timeline continues; scen-check judges the result. No set -e.
set -u
SEED="${SEED:-1001}"
SRV=10.200.2.10; SVC=10.200.2.20
T0=$(date +%s)

step() { "$@" || echo "FAILED: $*" >&2; }
# Each request phase has a 60 s budget: when nothing answers (S0 by design, or a broken
# tunnel) every request runs to its own timeout, and 50 x 10 s would be 500 s against a
# 240 s timeline. bulk/udp are bounded by iperf3's -t and --connect-timeout.
P0=0
phase() { P0=$(date +%s); }
budget() { [ $(( $(date +%s) - P0 )) -lt 60 ] || { echo "BUDGET: phase cut at 60 s" >&2; return 1; }; }
bulk() { step iperf3 --connect-timeout 5000 -c "$SRV" -t 60 -P 2; }
# -l 1200: iperf3's default 1448-byte datagram does not fit the tunnel MTU (1446 on the
# staging VM); the first one draws an ICMP frag-needed and iperf3 sends nothing more.
udp()  { step iperf3 --connect-timeout 5000 -c "$SRV" -u -b 5M -l 1200 -t 30; }
http() { phase; for _ in $(seq 1 50); do budget || break; step curl -s --max-time 10 -o /dev/null "http://$SVC/fixed.bin"; done; }
dns()  { phase; for i in $(seq 1 50); do budget || break; step dig +time=2 +tries=1 "@$SVC" "host$i.site-b.lab" +short >/dev/null; done; }

# A 1/s ping for the whole 240 s load keeps ESP flowing both ways even through the
# one-way UDP phase; otherwise the far gateway sees no inbound traffic and sends DPD
# mid-run, which X6 allows only in the idle tail (2026-10-09 rehearsal, DPD at 11-31 s).
( while [ $(( $(date +%s) - T0 )) -lt 240 ]; do ping -c 1 -W 1 "$SRV" >/dev/null 2>&1; sleep 1; done ) &
KEEPALIVE=$!
case $((SEED % 4)) in
    0) order="bulk udp http dns" ;;
    1) order="udp http dns bulk" ;;
    2) order="http dns bulk udp" ;;
    *) order="dns bulk udp http" ;;
esac
for p in $order; do "$p"; done
# Pad the load phase to 240 s so the run spans at least one CHILD_SA rekey (the
# keepalive above carries the pad), then the 40 s idle tail.
wait "$KEEPALIVE"
sleep 40
