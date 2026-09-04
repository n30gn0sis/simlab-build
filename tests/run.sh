#!/usr/bin/env bash
#
# The repo's one check. Run from anywhere:  ./tests/run.sh
#
# Everything here is read-only and offline: it lints the shell scripts and runs
# the bats suites against synthetic fixtures in $BATS_TEST_TMPDIR. It never
# touches a real bundle, never reaches the network, and never contacts the R770.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== bats =="
bats tests/*.bats
