#!/usr/bin/env bash
# gen-dnsmasq.sh <out> — write the full dnsmasq config: static lines plus
# host1..host50 -> 10.200.2.2..10.200.2.51 (host<N> = 10.200.2.<N+1>).
set -euo pipefail
{
    echo 'no-resolv'
    echo 'no-hosts'
    echo 'log-queries'
    echo 'address=/svc.site-b.lab/10.200.2.20'
    for n in $(seq 1 50); do
        echo "address=/host${n}.site-b.lab/10.200.2.$((n + 1))"
    done
} > "$1"
