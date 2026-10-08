#!/usr/bin/env bash
# gen-secrets.sh <scenario-dir> — write <scenario-dir>/swanctl/secrets.conf with a fresh
# 32-byte hex PSK (mode 0600, gitignored). If RUN_DIR is set, also keep the PSK as
# $RUN_DIR/gt/psk.txt (ground truth; gt/ never leaves the run directory).
set -euo pipefail
d="${1:?usage: gen-secrets.sh <scenario-dir>}"
[ -d "$d/swanctl" ] || { echo "ERROR: $d/swanctl not found" >&2; exit 1; }
psk=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
umask 077
cat > "$d/swanctl/secrets.conf" <<EOT
secrets {
  ike-s1 {
    id-a = gw-a.site-a.lab
    id-b = gw-b.site-b.lab
    secret = "$psk"
  }
}
EOT
chmod 600 "$d/swanctl/secrets.conf"
if [ -n "${RUN_DIR:-}" ]; then
    mkdir -p "$RUN_DIR/gt"
    echo "$psk" > "$RUN_DIR/gt/psk.txt"
    chmod 600 "$RUN_DIR/gt/psk.txt"
fi
echo "wrote $d/swanctl/secrets.conf"
