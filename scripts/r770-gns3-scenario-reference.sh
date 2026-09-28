#!/usr/bin/env bash
#
# r770-gns3-scenario-reference.sh -- the one reference GNS3 topology proving
# the virtual mirror feed: an Ethernet switch connecting two `netshoot`
# Docker nodes and one `alpine-linux` QEMU node, with a Cloud node bound to
# the host's br-lab bridge itself (GNS3SCN_BRIDGE_IFACE, default br-lab).
#
#   build   create the project/nodes/links if absent, start it (no-op if the
#           project already exists)
#   run     drive a known, logged sequence of traffic between the two
#           netshoot nodes -- see Task 5
#   verify  compare Malcolm's Arkime/Zeek data against run's evidence -- see
#           Task 6
#
# Design: docs/superpowers/specs/2026-09-27-gns3-mirror-design.md
#   ("Reference scenario")
#
# Test overrides: GNS3SCN_API (default https://127.0.0.1:3080/v2),
# GNS3SCN_CREDFILE (path to a 2-line file: user, then password -- never
# argv), GNS3SCN_PROJECT_NAME (default reference-scenario), GNS3SCN_BRIDGE_IFACE
# (default br-lab), GNS3SCN_STATE_DIR (default /var/lib/r770-gns3-scenario).
# `run` additions: GNS3SCN_PING_COUNT (default 20), GNS3SCN_CURL_COUNT
# (default 10), GNS3SCN_DIG_COUNT (default 5), GNS3SCN_SERVER_IP (default
# 192.168.100.2) and GNS3SCN_CLIENT_IP (default 192.168.100.3) -- fixed
# addresses `run` assigns to the two netshoot nodes via `ip addr replace`
# at run time, since the switch segment has no DHCP.
set -uo pipefail

GNS3SCN_API="${GNS3SCN_API:-https://127.0.0.1:3080/v2}"
GNS3SCN_CREDFILE="${GNS3SCN_CREDFILE:-/etc/r770-gns3-scenario/credentials}"
GNS3SCN_PROJECT_NAME="${GNS3SCN_PROJECT_NAME:-reference-scenario}"
GNS3SCN_BRIDGE_IFACE="${GNS3SCN_BRIDGE_IFACE:-br-lab}"
GNS3SCN_STATE_DIR="${GNS3SCN_STATE_DIR:-/var/lib/r770-gns3-scenario}"
GNS3SCN_PING_COUNT="${GNS3SCN_PING_COUNT:-20}"
GNS3SCN_CURL_COUNT="${GNS3SCN_CURL_COUNT:-10}"
GNS3SCN_DIG_COUNT="${GNS3SCN_DIG_COUNT:-5}"
GNS3SCN_SERVER_IP="${GNS3SCN_SERVER_IP:-192.168.100.2}"
GNS3SCN_CLIENT_IP="${GNS3SCN_CLIENT_IP:-192.168.100.3}"

die() { echo "r770-gns3-scenario-reference: $*" >&2; exit 1; }

check_creds() { [ -f "$GNS3SCN_CREDFILE" ] || die "no credentials file at $GNS3SCN_CREDFILE"; }

# api METHOD PATH [DATA] -- credentials never touch argv, env, or a log: read
# into local shell variables (never exported) and handed to curl only via a
# -K - config heredoc, which the shell writes to curl's stdin directly. Do
# NOT refactor this to `-u "$(creds)"` or any other form that puts the
# user:pass string into a command's own argv (visible via ps/proc) -- that
# was Task 4's one real review finding, fixed here.
api() {
    local method="$1" path="$2" data="${3:-}" u p
    check_creds
    { read -r u; read -r p; } < "$GNS3SCN_CREDFILE"
    if [ -n "$data" ]; then
        curl -sf -k -K - -X "$method" -H 'Content-Type: application/json' -d "$data" "$GNS3SCN_API$path" <<CURLCFG
user = "$u:$p"
CURLCFG
    else
        curl -sf -k -K - -X "$method" "$GNS3SCN_API$path" <<CURLCFG
user = "$u:$p"
CURLCFG
    fi
}

json_get() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

cmd_build() {
    check_creds
    mkdir -p "$GNS3SCN_STATE_DIR" || die "could not create $GNS3SCN_STATE_DIR"

    if [ -f "$GNS3SCN_STATE_DIR/project_id" ]; then
        echo "KEEP    project $GNS3SCN_PROJECT_NAME already exists"
        return 0
    fi

    local proj_id switch_id cloud_id client_id server_id alpine_id
    proj_id=$(api POST /projects "{\"name\":\"$GNS3SCN_PROJECT_NAME\"}" | json_get "['project_id']") ||
        die "project create failed"
    echo "$proj_id" > "$GNS3SCN_STATE_DIR/project_id"

    switch_id=$(api POST "/projects/$proj_id/nodes" '{"name":"switch1","node_type":"ethernet_switch","compute_id":"local"}' | json_get "['node_id']") ||
        die "switch node create failed"
    cloud_id=$(api POST "/projects/$proj_id/nodes" "{\"name\":\"cloud1\",\"node_type\":\"cloud\",\"compute_id\":\"local\",\"properties\":{\"ports_mapping\":[{\"interface\":\"$GNS3SCN_BRIDGE_IFACE\",\"name\":\"$GNS3SCN_BRIDGE_IFACE\",\"port_number\":0}]}}" | json_get "['node_id']") ||
        die "cloud node create failed"
    client_id=$(api POST "/projects/$proj_id/nodes" '{"name":"netshoot-client","node_type":"docker","compute_id":"local","properties":{"image":"nicolaka/netshoot:latest","start_command":"sleep infinity"}}' | json_get "['node_id']") ||
        die "netshoot-client create failed"
    server_id=$(api POST "/projects/$proj_id/nodes" '{"name":"netshoot-server","node_type":"docker","compute_id":"local","properties":{"image":"nicolaka/netshoot:latest","start_command":"sleep infinity"}}' | json_get "['node_id']") ||
        die "netshoot-server create failed"
    alpine_id=$(api POST "/projects/$proj_id/nodes" '{"name":"alpine1","node_type":"qemu","compute_id":"local","properties":{"template_name":"Alpine Linux"}}' | json_get "['node_id']") ||
        die "alpine node create failed"

    local peer
    for peer in "$cloud_id" "$client_id" "$server_id" "$alpine_id"; do
        api POST "/projects/$proj_id/links" "{\"nodes\":[{\"node_id\":\"$switch_id\",\"adapter_number\":0,\"port_number\":0},{\"node_id\":\"$peer\",\"adapter_number\":0,\"port_number\":0}]}" >/dev/null ||
            die "link to $peer failed"
    done

    api POST "/projects/$proj_id/nodes/start" >/dev/null || die "project start failed"
    echo "PASS    project $GNS3SCN_PROJECT_NAME built and started ($proj_id)"
}

container_for() {  # container_for NODE_NAME -- prints "STATUS\nCONTAINER_ID"
    api GET "/projects/$(cat "$GNS3SCN_STATE_DIR/project_id")/nodes" |
        python3 -c "
import json, sys
nodes = json.load(sys.stdin)
n = next((n for n in nodes if n['name'] == '$1'), None)
if n is None:
    sys.exit(1)
print(n['status'])
print(n['properties']['container_id'])
"
}

cmd_run() {
    [ -f "$GNS3SCN_STATE_DIR/project_id" ] || die "project not built -- run 'build' first"

    local client_info server_info client_status client_id server_status server_id
    client_info=$(container_for netshoot-client) || die "could not find netshoot-client via the GNS3 API"
    server_info=$(container_for netshoot-server) || die "could not find netshoot-server via the GNS3 API"
    client_status=$(sed -n 1p <<< "$client_info"); client_id=$(sed -n 2p <<< "$client_info")
    server_status=$(sed -n 1p <<< "$server_info"); server_id=$(sed -n 2p <<< "$server_info")
    if [ "$client_status" != started ] || [ "$server_status" != started ]; then
        die "netshoot nodes are not started (client=$client_status server=$server_status) -- run 'build' or start the project first"
    fi

    # The switch segment has no DHCP -- assign fixed addresses before driving
    # any traffic. `ip addr replace` (not `add`) so a second `run` is a no-op
    # here rather than an "address already exists" failure. Interface name
    # (eth0) and the assumption that these addresses are reachable across the
    # GNS3-managed link are unverified against a real GNS3 project -- part of
    # Task 8's empirical confirmation (see Task 8's checklist).
    docker exec "$client_id" ip addr replace "$GNS3SCN_CLIENT_IP/24" dev eth0 || die "could not assign $GNS3SCN_CLIENT_IP to the client"
    docker exec "$server_id" ip addr replace "$GNS3SCN_SERVER_IP/24" dev eth0 || die "could not assign $GNS3SCN_SERVER_IP to the server"
    # netshoot is Alpine-based, so busybox httpd should be present; without
    # -f it daemonizes itself, so this returns once the listener is up.
    # Also unverified against the real image -- Task 8 confirms or corrects.
    docker exec "$server_id" busybox httpd -p 80 -h /tmp || die "could not start the HTTP listener on the server"

    docker exec "$server_id" iperf3 -s -D || die "iperf3 -s on the server failed"
    docker exec "$client_id" ping -c "$GNS3SCN_PING_COUNT" "$GNS3SCN_SERVER_IP" || die "ping from the client failed"
    local i
    for ((i = 0; i < GNS3SCN_CURL_COUNT; i++)); do
        docker exec "$client_id" curl -s "http://$GNS3SCN_SERVER_IP/" -o /dev/null || die "curl #$((i+1)) from the client failed"
    done
    for ((i = 0; i < GNS3SCN_DIG_COUNT; i++)); do
        docker exec "$client_id" dig "@$GNS3SCN_SERVER_IP" example.lab || die "dig #$((i+1)) from the client failed"
    done
    docker exec "$client_id" iperf3 -c "$GNS3SCN_SERVER_IP" -t 2 || die "iperf3 -c from the client failed"

    python3 -c "
import json, datetime
json.dump({
    'pings': $GNS3SCN_PING_COUNT,
    'curls': $GNS3SCN_CURL_COUNT,
    'digs': $GNS3SCN_DIG_COUNT,
    'iperf_transfers': 1,
    'started_at': datetime.datetime.utcnow().isoformat() + 'Z',
}, open('$GNS3SCN_STATE_DIR/evidence.json.tmp', 'w'), indent=2)
" || die "could not write evidence file"
    mv -f "$GNS3SCN_STATE_DIR/evidence.json.tmp" "$GNS3SCN_STATE_DIR/evidence.json"
    echo "PASS    drove $GNS3SCN_PING_COUNT pings, $GNS3SCN_CURL_COUNT curls, $GNS3SCN_DIG_COUNT digs, 1 iperf3 transfer -- evidence: $GNS3SCN_STATE_DIR/evidence.json"
}

VERB="${1:-build}"
[ $# -eq 0 ] || shift
case "$VERB" in
    build) cmd_build "$@" ;;
    run)   cmd_run "$@" ;;
    *)     die "unknown verb: $VERB (expected build or run; verify lands in Task 6)" ;;
esac
