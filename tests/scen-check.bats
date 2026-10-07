#!/usr/bin/env bats
# scen-check: tshark-driven PASS/FAIL/SKIP into <run-dir>/expected.md.
#
# tshark stub convention: the stub reads the display filter after -Y (empty string if
# there is no -Y), hashes it (printf %s "$filter" | sha256sum | cut -c1-12) and prints
# "$S/tshark.<hash>" if that file exists (nothing otherwise). seed_tshark '<filter>'
# writes stdin to the matching file. So the answer depends on the filter only, not on
# the -e fields: 'esp' feeds both X3 (line count) and X5 (unique SPIs); '' (no -Y) is
# the last-frame-time query of X6.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-check"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; RUN="$BATS_TEST_TMPDIR/run"
    S="$BATS_TEST_TMPDIR/stubdata"
    mkdir -p "$BIN" "$REAL" "$RUN/gt/gw-a/keys" "$S"
    for t in bash env python3 date mkdir cat grep sed awk printf dirname basename readlink cp ls sort wc rm mktemp comm tail head cut sha256sum; do
        p=$(type -P $t) && ln -sf "$p" "$REAL/$t"
    done
    export S SCEN_REPO="$BATS_TEST_DIRNAME/.."
    cat > "$BIN/tshark" <<'STUB'
#!/usr/bin/env bash
f=''
while [ $# -gt 0 ]; do case "$1" in -Y) f="$2"; shift ;; esac; shift; done
h=$(printf %s "$f" | sha256sum | cut -c1-12)
[ -f "$S/tshark.$h" ] && cat "$S/tshark.$h"
exit 0
STUB
    cat > "$BIN/mergecap" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$S/mergecap.calls"
[ "$1" = -w ] && : > "$2"
exit 0
STUB
    chmod +x "$BIN/tshark" "$BIN/mergecap"
    export PATH="$BIN:$REAL"
    cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$RUN/run.yaml"
    cp "$BATS_TEST_DIRNAME/../scenarios/S1/expected.md" "$RUN/expected.md"
    : > "$RUN/outer-t01.pcapng"; : > "$RUN/inner-i01.pcapng"
    echo "outer-t01: 0 packets dropped by kernel" > "$RUN/capture-stats.txt"
    echo "inner-i01: 0 packets dropped by kernel" >> "$RUN/capture-stats.txt"
    seed_all_pass
}

seed_tshark() {  # seed_tshark '<filter>' <<EOF ... EOF
    local h; h=$(printf %s "$1" | sha256sum | cut -c1-12)
    cat > "$S/tshark.$h"
}
seed_all_pass() {
    seed_tshark 'isakmp.exchangetype == 34' <<EOF
198.18.1.2
198.18.2.2
EOF
    seed_tshark 'esp' <<EOF
0x1
0x2
0x3
0x4
EOF
    seed_tshark '' <<EOF
0.0
100.0
299.0
EOF
    seed_tshark 'isakmp' <<EOF
1.0	34
2.0	35
100.0	36
270.0	37
EOF
    seed_tshark 'esp && ip' <<EOF
10.200.1.1	10.200.2.1	40000
EOF
    seed_tshark 'ip' <<EOF
10.200.1.1	10.200.2.1	40000
10.200.2.1	10.200.1.1	5201
EOF
    echo 'esp_sa-line' > "$RUN/gt/gw-a/keys/esp_sa"
}
cell() {  # cell <row> — last cell of the row in expected.md
    grep "^| $1 |" "$RUN/expected.md" | awk -F'|' '{gsub(/^ +| +$/,"",$(NF-1)); print $(NF-1)}'
}

@test "all-PASS S1 run writes PASS into X1-X8, X9 SKIP, exits 0" {
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    for x in X1 X2 X3 X4 X5 X6 X7 X8; do [ "$(cell $x)" = PASS ]; done
    [[ "$(cell X9)" == "SKIP (manual: Arkime tag query)" ]]
    [[ "$output" == *"RESULT: PASS"* ]]
    [[ "$output" == *"X1 PASS"*"X9 SKIP"* ]]
}

@test "non-table lines are untouched and the traffic line is appended under the table" {
    printf 'FAILED: a\nok\nFAILED: b\n' > "$RUN/traffic.out"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 0 ]
    grep -qx 'traffic: 2 FAILED steps in traffic.out' "$RUN/expected.md"
    grep -q '^\*\*Pass:\*\* X1-X9 all true' "$RUN/expected.md"
    [ "$(grep -c '^traffic:' "$RUN/expected.md")" -eq 1 ]
    run "$SCRIPT" "$RUN"       # idempotent: no second traffic line
    [ "$(grep -c '^traffic:' "$RUN/expected.md")" -eq 1 ]
}

@test "X4 non-zero marks FAIL and exits 1" {
    seed_tshark 'ip.addr==10.200.0.0/16' <<EOF
frame1
frame2
EOF
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$(cell X4)" == "FAIL (2 outer frames"* ]]
    [ "$(cell X1)" = PASS ]
    [[ "$output" == *"RESULT: FAIL"* ]]
}

@test "X1 FAILs when a gateway never sent IKE_SA_INIT" {
    seed_tshark 'isakmp.exchangetype == 34' <<EOF
198.18.1.2
EOF
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X1)" == *"198.18.2.2"* ]]
}

@test "X2 FAILs on UDP 4500 traffic" {
    seed_tshark 'udp.port==4500' <<EOF
f
EOF
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X2)" == FAIL* ]]
}

@test "X5 FAILs with too few SPIs, X3 FAILs without ESP" {
    seed_tshark 'esp' <<EOF
0x1
0x1
0x2
EOF
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [ "$(cell X3)" = PASS ]
    [[ "$(cell X5)" == "FAIL (2 distinct SPIs"* ]]
    : > "$S/tshark.$(printf %s esp | sha256sum | cut -c1-12)"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X3)" == FAIL* ]]
}

@test "X6 FAILs on a non-rekey IKE exchange mid-run and when there is no tail traffic" {
    seed_tshark 'isakmp' <<EOF
1.0	34
100.0	37
270.0	37
EOF
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X6)" == FAIL* ]]
    seed_tshark 'isakmp' <<EOF
1.0	34
100.0	36
EOF
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X6)" == "FAIL (no DPD"* ]]
}

@test "missing gt keys marks X7 SKIP, not FAIL" {
    rm "$RUN/gt/gw-a/keys/esp_sa"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cell X7)" = "SKIP (no keys in gt/)" ]
}

@test "X7 FAILs when a decrypted tuple is absent from the inner capture" {
    seed_tshark 'esp && ip' <<EOF
10.9.9.9	10.200.2.1	40000
EOF
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X7)" == "FAIL (1 decrypted"* ]]
}

@test "UNKNOWN drop line marks X8 FAIL" {
    echo "inner-i01: UNKNOWN (tcpdump gave no stats)" >> "$RUN/capture-stats.txt"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X8)" == FAIL* ]]
}

@test "nonzero kernel drops mark X8 FAIL" {
    echo "outer-t01: 12 packets dropped by kernel" > "$RUN/capture-stats.txt"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X8)" == FAIL* ]]
}

@test "X9 stays SKIP even with SCEN_ARKIME_URL set, saying not implemented" {
    SCEN_ARKIME_URL=http://x run "$SCRIPT" "$RUN"
    [ "$status" -eq 0 ]
    [ "$(cell X9)" = "SKIP (not implemented in v0.1)" ]
}

@test "S0 run uses the inverse X4 and only X4-inverse/X8 rows" {
    sed 's/^scenario: S1/scenario: S0/' "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" > "$RUN/run.yaml"
    cp "$BATS_TEST_DIRNAME/../scenarios/S0/expected.md" "$RUN/expected.md"
    seed_tshark 'ip.addr==10.200.0.0/16' <<EOF
syn
EOF
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cell X4-inverse)" = PASS ]
    [ "$(cell X8)" = PASS ]
    [[ "$output" != *"X1 "* ]]
    # and it FAILs when nothing leaks
    : > "$S/tshark.$(printf %s 'ip.addr==10.200.0.0/16' | sha256sum | cut -c1-12)"
    cp "$BATS_TEST_DIRNAME/../scenarios/S0/expected.md" "$RUN/expected.md"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$(cell X4-inverse)" == FAIL* ]]
}

@test "ring files are merged with mergecap (both files passed)" {
    rm "$RUN/outer-t01.pcapng"
    : > "$RUN/outer-t01.pcapng0"; : > "$RUN/outer-t01.pcapng1"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -f "$S/mergecap.calls" ]
    grep -q "outer-t01.pcapng0 .*outer-t01.pcapng1" "$S/mergecap.calls"
}

@test "a single capture file is not merged" {
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 0 ]
    [ ! -e "$S/mergecap.calls" ]
}

@test "dies when expected.md is missing" {
    rm "$RUN/expected.md"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no expected.md"* ]]
}

@test "dies when run.yaml is missing" {
    rm "$RUN/run.yaml"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no run.yaml"* ]]
}

@test "dies when the outer capture has no files" {
    rm "$RUN/outer-t01.pcapng"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no outer-t01.pcapng"* ]]
}

@test "dies when expected.md lacks a row the scenario needs, leaving it unchanged" {
    grep -v '^| X6 |' "$RUN/expected.md" > "$RUN/e2" && cp "$RUN/e2" "$RUN/expected.md"
    cp "$RUN/expected.md" "$RUN/before"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'| X6 |'"* ]]
    [ "$(cat "$RUN/expected.md")" = "$(cat "$RUN/before")" ]
}
