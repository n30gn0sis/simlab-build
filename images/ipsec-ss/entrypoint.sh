#!/bin/sh
# ipsec-ss entrypoint — spec §5.2 E4 (iface wait), E6 (/gt ground truth).
set -eu
: "${WAIT_IFACES:=eth0 eth1}" "${WAIT_SECS:=60}" "${SA_SNAPSHOT_SECS:=5}" "${START_WAIT_SECS:=30}"
: "${GT:=/gt}" "${CHARON:=/usr/lib/ipsec/charon}"
mkdir -p "$GT/keys" "$GT/sa"
for i in $WAIT_IFACES; do
    n=0
    until ip link show "$i" >/dev/null 2>&1; do
        n=$((n+1)); [ "$n" -ge "$WAIT_SECS" ] && { echo "iface $i missing after ${WAIT_SECS}s" >&2; exit 1; }
        sleep 1
    done
done
charon_pid=""; loop_pid=""
# PID 1: stop charon and the snapshot loop cleanly on container stop
trap 'kill $charon_pid $loop_pid 2>/dev/null || :; wait; exit 0' TERM INT
# charon's own log goes to /gt/charon.log via strongswan.d/logging.conf; this
# redirect keeps crash output. Debug levels are tuned in the probe.
"$CHARON" >>"$GT/charon.log" 2>&1 &
charon_pid=$!
n=0
until swanctl --stats >/dev/null 2>&1; do
    n=$((n+1))
    if [ "$n" -ge "$START_WAIT_SECS" ]; then
        echo "charon/vici not ready after ${START_WAIT_SECS}s" >&2
        kill "$charon_pid" 2>/dev/null || :
        exit 1
    fi
    sleep 1
done
swanctl --load-all
# SPI history across rekeys — one snapshot per interval
( while :; do swanctl --list-sas > "$GT/sa/$(date -u +%Y%m%dT%H%M%SZ).txt" 2>&1 || true; sleep "$SA_SNAPSHOT_SECS"; done ) &
loop_pid=$!
# the container lives and dies with charon
rc=0; wait "$charon_pid" || rc=$?
kill "$loop_pid" 2>/dev/null || :
exit "$rc"
