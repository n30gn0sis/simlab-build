#!/bin/sh
# ipsec-ss entrypoint — spec §5.2 E4 (iface wait), E6 (/gt ground truth).
set -eu
: "${WAIT_IFACES:=eth0 eth1}" "${WAIT_SECS:=60}" "${SA_SNAPSHOT_SECS:=5}"
: "${GT:=/gt}" "${CHARON:=/usr/lib/ipsec/charon}"
mkdir -p "$GT/keys" "$GT/sa"
for i in $WAIT_IFACES; do
    n=0
    until ip link show "$i" >/dev/null 2>&1; do
        n=$((n+1)); [ "$n" -ge "$WAIT_SECS" ] && { echo "iface $i missing after ${WAIT_SECS}s" >&2; exit 1; }
        sleep 1
    done
done
"$CHARON" >"$GT/charon.log" 2>&1 &
sleep 2
swanctl --load-all
# SPI history across rekeys — one snapshot per interval
( while :; do swanctl --list-sas > "$GT/sa/$(date -u +%Y%m%dT%H%M%SZ).txt" 2>&1 || true; sleep "$SA_SNAPSHOT_SECS"; done ) &
wait
