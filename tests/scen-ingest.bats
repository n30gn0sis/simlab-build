#!/usr/bin/env bats
# scen-ingest: tagged copy of a run's PCAPs into Malcolm's upload dir; gt/ never leaves.
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-ingest"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; RUN="$BATS_TEST_TMPDIR/run"
    export SCEN_DATA_ROOT="$BATS_TEST_TMPDIR/data"
    UP="$SCEN_DATA_ROOT/pcap/raw/upload"; ID=S1-W1-ss-20261001T1400Z
    mkdir -p "$BIN" "$REAL" "$RUN" "$UP"
    for t in bash env python3 date mkdir cat grep sed awk printf dirname basename readlink cp ls find sort wc rm ln chmod install stat; do
        p=$(type -P $t) && ln -sf "$p" "$REAL/$t"
    done
    export SCEN_REPO="$BATS_TEST_DIRNAME/.." SCEN_UPLOAD_DIR="$UP"
    cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$RUN/run.yaml"
    export PATH="$BIN:$REAL"
}

@test "copies outer and inner pcaps with run-id,view tags, ring suffix included" {
    echo a > "$RUN/outer-t01-0.pcap"; echo b > "$RUN/outer-t01-1.pcap"
    echo c > "$RUN/inner-i01-0.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -f "$UP/$ID-outer,outer-t01-0.pcap" ]
    [ -f "$UP/$ID-outer,outer-t01-1.pcap" ]
    [ -f "$UP/$ID-inner,inner-i01-0.pcap" ]
    [ "$(cat "$UP/$ID-inner,inner-i01-0.pcap")" = c ]
    [[ "$output" == *"$ID-outer,outer-t01-0.pcap"* ]]
    [ "$(find "$UP" -type f | wc -l)" -eq 3 ]
}

@test "never copies gt/ or anything below it, even pcap-named files" {
    echo c > "$RUN/inner-i01-0.pcap"
    mkdir -p "$RUN/gt/gw-a/keys"
    echo k > "$RUN/gt/gw-a/keys/esp_sa"
    echo k > "$RUN/gt/gw-a/outer-t01-0.pcap"
    echo k > "$RUN/gt/inner-i01-0.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(find "$UP" -type f | wc -l)" -eq 1 ]
    [ -f "$UP/$ID-inner,inner-i01-0.pcap" ]
    [ "$(cat "$UP/$ID-inner,inner-i01-0.pcap")" = c ]
    [[ "$output" != *esp_sa* ]]
}

@test "refuses an upload dir outside the data root" {
    echo c > "$RUN/inner-i01-0.pcap"
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    SCEN_UPLOAD_DIR="$BATS_TEST_TMPDIR/elsewhere" run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside $SCEN_DATA_ROOT"* ]]
    [ -z "$(ls "$BATS_TEST_TMPDIR/elsewhere")" ]
}

@test "refuses a symlinked upload dir that resolves outside the data root" {
    echo c > "$RUN/inner-i01-0.pcap"
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$SCEN_DATA_ROOT/link"
    SCEN_UPLOAD_DIR="$SCEN_DATA_ROOT/link" run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside"* ]]
    [ -z "$(ls "$BATS_TEST_TMPDIR/elsewhere")" ]
}

@test "refuses a dir without run.yaml" {
    rm "$RUN/run.yaml"; echo c > "$RUN/inner-i01-0.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"run.yaml"* ]]
    [ -z "$(ls "$UP")" ]
}

@test "refuses to overwrite an existing destination" {
    echo new > "$RUN/inner-i01-0.pcap"
    echo old > "$UP/$ID-inner,inner-i01-0.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exists"* ]]
    [ "$(cat "$UP/$ID-inner,inner-i01-0.pcap")" = old ]
}

@test "nothing to ingest when no capture files exist" {
    mkdir -p "$RUN/gt/gw-a"; echo k > "$RUN/gt/gw-a/x.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outer-t01: no capture files"* ]]
    [[ "$output" == *"nothing to ingest"* ]]
    [ -z "$(ls "$UP")" ]
}

@test "without SCEN_UPLOAD_DIR the upload dir comes from the deploy script's upload-dir verb" {
    echo c > "$RUN/inner-i01-0.pcap"
    printf '#!/usr/bin/env bash\n[ "$1" = upload-dir ] && echo "%s"\n' "$UP" > "$BIN/deploy"; chmod +x "$BIN/deploy"
    unset SCEN_UPLOAD_DIR
    SCEN_MALCOLM_DEPLOY="$BIN/deploy" run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -f "$UP/$ID-inner,inner-i01-0.pcap" ]
}

@test "copied files are mode 0644 even when the source is 0600" {
    echo c > "$RUN/inner-i01-0.pcap"; chmod 600 "$RUN/inner-i01-0.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$UP/$ID-inner,inner-i01-0.pcap")" = 644 ]
}

@test "a capture point name containing / is refused and nothing is copied" {
    echo c > "$RUN/inner-i01-0.pcap"
    sed -i 's|name: outer-t01,|name: ../gt/x,|' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad capture point name '../gt/x'"* ]]
    [ -z "$(ls "$UP")" ]
}

@test "a capture point name containing a comma is refused" {
    echo c > "$RUN/inner-i01-0.pcap"
    sed -i 's|name: outer-t01,|name: "a,b",|' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad capture point name 'a,b'"* ]]
    [ -z "$(ls "$UP")" ]
}

@test "only final <name>-<N>.pcap files are copied: tcpdump's interim <name>.pcapN and other files are not" {
    echo c > "$RUN/inner-i01-0.pcap"
    echo x > "$RUN/outer-t01.pcap0"; echo y > "$RUN/outer-t01.pcap"; echo z > "$RUN/outer-t01-0.pcapng"
    run "$SCRIPT" "$RUN"
    [ "$status" -eq 0 ]
    [[ "$output" == *"outer-t01: no capture files"* ]]
    [ "$(find "$UP" -type f | wc -l)" -eq 1 ]
}

@test "a symlinked capture file is skipped and logged, the regular file beside it is copied" {
    echo secret > "$BATS_TEST_TMPDIR/target"
    ln -s "$BATS_TEST_TMPDIR/target" "$RUN/outer-t01-0.pcap"
    echo c > "$RUN/inner-i01-0.pcap"
    run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"outer-t01-0.pcap: symlink, skipped"* ]]
    [ -f "$UP/$ID-inner,inner-i01-0.pcap" ]
    [ "$(find "$UP" -type f | wc -l)" -eq 1 ]
}

@test "a sibling dir sharing the data root's prefix is outside it" {
    echo c > "$RUN/inner-i01-0.pcap"
    mkdir -p "$BATS_TEST_TMPDIR/database"
    SCEN_UPLOAD_DIR="$BATS_TEST_TMPDIR/database" run "$SCRIPT" "$RUN"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside"* ]]
    [ -z "$(ls "$BATS_TEST_TMPDIR/database")" ]
}
