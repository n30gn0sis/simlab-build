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
set -uo pipefail

GNS3SCN_API="${GNS3SCN_API:-https://127.0.0.1:3080/v2}"
GNS3SCN_CREDFILE="${GNS3SCN_CREDFILE:-/etc/r770-gns3-scenario/credentials}"
GNS3SCN_PROJECT_NAME="${GNS3SCN_PROJECT_NAME:-reference-scenario}"
GNS3SCN_BRIDGE_IFACE="${GNS3SCN_BRIDGE_IFACE:-br-lab}"
GNS3SCN_STATE_DIR="${GNS3SCN_STATE_DIR:-/var/lib/r770-gns3-scenario}"

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

VERB="${1:-build}"
[ $# -eq 0 ] || shift
case "$VERB" in
    build) cmd_build "$@" ;;
    *)     die "unknown verb: $VERB (expected build; run/verify land in Tasks 5-6)" ;;
esac
