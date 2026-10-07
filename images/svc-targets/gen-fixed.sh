#!/usr/bin/env bash
# gen-fixed.sh <out> — deterministic 1 MiB: repeat a counter so runs are byte-identical
set -euo pipefail
tmp="$1.part"
# 14 bytes per line; 80000 lines (1.12 MB) comfortably exceeds 1 MiB. Write the
# whole sequence first, then cut, so head never closes a pipe on seq (pipefail).
seq -f 'fixed-%07g' 1 80000 > "$tmp"
head -c 1048576 "$tmp" > "$1"
rm -f "$tmp"
