#!/usr/bin/env bash
# svc-targets: fixed HTTP payload on :80, DNS for host<N>.site-b.lab / svc.site-b.lab on :53.
set -euo pipefail
mkdir -p /srv/www
/usr/local/bin/gen-fixed.sh /srv/www/fixed.bin
/usr/local/bin/gen-dnsmasq.sh /etc/dnsmasq.conf
dnsmasq -k -C /etc/dnsmasq.conf &
exec nginx -g 'daemon off;'
