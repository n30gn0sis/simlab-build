#!/usr/bin/env bats
#
# r770-gns3-scenario-reference.sh talks only to the GNS3 v2 REST API (curl) and
# the GNS3-managed Docker containers (docker exec). curl and docker are stubs
# backed by a state dir ($S); a fixed real-tool allowlist (jq/python3, sed,
# mkdir, etc.) is the only other thing on PATH.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-gns3-scenario-reference.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export GNS3SCN_API="https://127.0.0.1:3080/v2"
    export GNS3SCN_CREDFILE="$BATS_TEST_TMPDIR/creds"
    export GNS3SCN_PROJECT_NAME="reference-scenario"
    export GNS3SCN_BRIDGE_IFACE="br-lab"
    export GNS3SCN_STATE_DIR="$BATS_TEST_TMPDIR/scenario-state"
    mkdir -p "$BIN" "$REAL" "$S" "$GNS3SCN_STATE_DIR"
    printf 'admin\nPASSWORD\n' > "$GNS3SCN_CREDFILE"

    for t in bash env cat sed awk grep tr cp mv mkdir chmod rm date stat cmp find dirname basename python3; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    # curl stub: routes by URL suffix + method, all logged, all answerable from
    # fixed JSON fixtures the tests can override per-case via $S files.
    cat > "$BIN/curl" <<'CURL'
#!/usr/bin/env bash
args=("$@")
printf '%s\n' "${args[*]}" >> "$S/curl_calls"
method="GET"
for i in "${!args[@]}"; do [ "${args[$i]}" = "-X" ] && method="${args[$((i+1))]}"; done
url="${args[-1]}"
case "$method $url" in
    "GET "*"/version") echo '{"version":"test"}' ;;
    "POST "*"/projects")
        echo '{"project_id":"proj-1","name":"reference-scenario","status":"opened"}' ;;
    "POST "*"/templates")
        echo '{"template_id":"tmpl-1"}' ;;
    "GET "*"/templates")
        cat "$S/templates_response" 2>/dev/null || echo '[{"template_id":"tmpl-alpine","name":"Alpine Linux"}]' ;;
    "POST "*"/nodes")
        n=$(( $(cat "$S/node_counter" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/node_counter"
        echo "{\"node_id\":\"node-$n\",\"status\":\"stopped\"}" ;;
    "POST "*"/links")
        echo '{"link_id":"link-1"}' ;;
    "POST "*"/start")
        echo '{"status":"started"}' ;;
    *) echo "stub-curl: unhandled $method $url" >&2; exit 1 ;;
esac
CURL
    chmod +x "$BIN/curl"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
run_scn() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

@test "build refuses without a credentials file" {
    rm -f "$GNS3SCN_CREDFILE"
    run run_scn build
    [ "$status" -eq 1 ]
    [[ "$output" == *"credentials"* ]]
}

@test "build creates a project, an ethernet switch, a cloud node, 2 netshoot nodes, 1 alpine node, links them, and starts the project" {
    run run_scn build
    echo "$output"; cat "$S/curl_calls"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'POST.*/projects$' "$S/curl_calls")" -eq 1 ]
    # 5 node objects: switch1, cloud1 (bound to GNS3SCN_BRIDGE_IFACE), netshoot-client,
    # netshoot-server, alpine1 -- the Interfaces section's "4 nodes ... plus a Cloud
    # node" is 5 distinct GNS3 node-API objects, all created via POST .../nodes.
    [ "$(grep -c 'POST.*/nodes$' "$S/curl_calls")" -eq 5 ]
    [ "$(grep -c 'POST.*/links$' "$S/curl_calls")" -eq 4 ]
    [ "$(grep -c 'POST.*/start$' "$S/curl_calls")" -ge 1 ]
    [ "$(cat "$GNS3SCN_STATE_DIR/project_id")" = "proj-1" ]
}

@test "a second build is a no-op (project already exists)" {
    run_scn build
    : > "$S/curl_calls"
    run run_scn build
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]
    [ "$(grep -c 'POST.*/projects$' "$S/curl_calls")" -eq 0 ]
}

# ── run ──────────────────────────────────────────────────────────────────────
#
# docker is a stub: `docker exec <container> <cmd...>` just logs the call and
# returns 0, modeling every command inside the netshoot nodes succeeding.
# GNS3's node-list API maps node_id -> the real Docker container name/id,
# which docker ps (also stubbed) resolves.

setup_run_stubs() {
    echo "proj-1" > "$GNS3SCN_STATE_DIR/project_id"
    cat > "$S/nodes_response" <<'JSON'
[
  {"node_id":"node-3","name":"netshoot-client","node_type":"docker","status":"started","properties":{"container_id":"c-client"}},
  {"node_id":"node-4","name":"netshoot-server","node_type":"docker","status":"started","properties":{"container_id":"c-server"}}
]
JSON
    # Extend the curl stub with a GET .../nodes route.
    sed -i "s#\*) echo \"stub-curl: unhandled#\"GET \"*\"/nodes\") cat \"\$S/nodes_response\" ;;\n    *) echo \"stub-curl: unhandled#" "$BIN/curl"
    stub docker '
        printf "%s\n" "$*" >> "'"$S"'/docker_calls"
        exit "$(cat "'"$S"'/docker_exec_rc" 2>/dev/null || echo 0)"'
}

@test "run refuses if the project has not been built" {
    rm -f "$GNS3SCN_STATE_DIR/project_id"
    run run_scn run
    [ "$status" -eq 1 ]
    [[ "$output" == *"not built"* ]]
}

@test "run refuses if the netshoot nodes are not started" {
    setup_run_stubs
    sed -i 's/"started"/"stopped"/' "$S/nodes_response"
    run run_scn run
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not started"* ]]
    [ ! -f "$GNS3SCN_STATE_DIR/evidence.json" ]
}

@test "run drives the expected traffic counts and writes the evidence file" {
    setup_run_stubs
    GNS3SCN_PING_COUNT=5 GNS3SCN_CURL_COUNT=3 GNS3SCN_DIG_COUNT=2 run run_scn run
    echo "$output"; cat "$S/docker_calls"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'exec c-client ping' "$S/docker_calls")" -eq 1 ]
    [ "$(grep -c 'exec c-client curl' "$S/docker_calls")" -eq 3 ]
    [ "$(grep -c 'exec c-client dig' "$S/docker_calls")" -eq 2 ]
    [ "$(grep -c 'exec c-client iperf3 -c' "$S/docker_calls")" -eq 1 ]
    [ "$(grep -c 'exec c-server iperf3 -s' "$S/docker_calls")" -eq 1 ]
    run python3 -c "import json; d=json.load(open('$GNS3SCN_STATE_DIR/evidence.json')); print(d['pings'], d['curls'], d['digs'], d['iperf_transfers'])"
    [ "$output" = "5 3 2 1" ]
}

@test "run refuses (and writes no evidence) if a driven command fails" {
    setup_run_stubs
    echo 7 > "$S/docker_exec_rc"
    run run_scn run
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed"* ]]
    [ ! -f "$GNS3SCN_STATE_DIR/evidence.json" ]
}
