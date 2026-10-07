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
bulk() { step iperf3 --connect-timeout 5000 -c "$SRV" -t 60 -P 2; }
udp()  { step iperf3 --connect-timeout 5000 -c "$SRV" -u -b 5M -t 30; }
http() { for _ in $(seq 1 50); do step curl -s --max-time 10 -o /dev/null "http://$SVC/fixed.bin"; done; }
dns()  { for i in $(seq 1 50); do step dig +time=2 +tries=1 "@$SVC" "host$i.site-b.lab" +short >/dev/null; done; }

case $((SEED % 4)) in
    0) order="bulk udp http dns" ;;
    1) order="udp http dns bulk" ;;
    2) order="http dns bulk udp" ;;
    *) order="dns bulk udp http" ;;
esac
for p in $order; do "$p"; done
# Pad the load phase to 240 s so the run spans at least one CHILD_SA rekey.
while [ $(( $(date +%s) - T0 )) -lt 240 ]; do sleep 1; done
sleep 40
