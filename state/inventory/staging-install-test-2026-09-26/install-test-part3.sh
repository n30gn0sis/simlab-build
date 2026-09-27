#!/usr/bin/env bash
# Continuation (part 3: smoke + GNS3; images already loaded in part 2) of the import/install test of bundle-20260926 on VM 9771, made R770-like.
# Follows docs/plans/r770-install-runbook.md Parts 1, 3, 4-5 and 7.1 with REAL installs,
# under a simulated air gap. Stops at the first failed check. Run as ubuntu (uses sudo).
set -uo pipefail
BD="$(cat ~/bundle-dir)"; N="$(basename "$BD")"; R="$HOME/simlab-build"; S="/data/staging/$N"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; sudo "$R/scripts/r770-airgap-sim.sh" unblock >/dev/null 2>&1; exit 1; }
step() { printf '\n== %s  (%s)\n' "$*" "$(date -u +%H:%M:%S)"; }

step "0b. air gap: block internet for host and containers (auto-revert 240 min), prove it"
sudo "$R/scripts/r770-airgap-sim.sh" block --minutes 240 || bad "airgap block"
sudo "$R/scripts/r770-airgap-sim.sh" status
for u in https://archive.ubuntu.com https://download.docker.com https://pypi.org; do
    curl -s -m 8 -o /dev/null "$u" && bad "internet reachable: $u"
done
ok "no internet (archive.ubuntu.com, download.docker.com, pypi.org unreachable)"

norm() { sed -E 's#^docker\.io/library/##; s#^docker\.io/##'; }   # defined in part 2's step 5, which part 3 skips
step "5b. smoke: run loaded images with no network"
z=$(grep -m1 '/zeek:' "$S/malcolm/image-list.txt")
# Use the image's own PATH (zeek lives in /usr/local/zeek/bin in Malcolm's image).
# The binary carries file capabilities (cap_net_admin,cap_net_raw=eip), so it only
# execs with those granted — as Malcolm's own compose does for the zeek service.
zv=$(sudo docker run --rm --network none --cap-add NET_RAW --cap-add NET_ADMIN --entrypoint sh "$z" -c 'zeek --version' 2>&1 | tail -1)
echo "   $zv"; printf '%s' "$zv" | grep -qi '^zeek version' || bad "zeek container"
sudo docker run -d --name reg-smoke -p 127.0.0.1:5000:5000 registry:2 >/dev/null || bad "registry run"
sleep 3; curl -sf -o /dev/null http://127.0.0.1:5000/v2/ || { sudo docker rm -f reg-smoke >/dev/null; bad "registry /v2/"; }
sudo docker rm -f reg-smoke >/dev/null
node=$(grep -vE '^\s*(#|$)' "$S/gns3/docker-nodes/image-list.txt" | grep -m1 -i alpine | norm)
sudo docker run --rm --network none "$node" sh -c 'echo node-ok' | grep -q node-ok || bad "gns3 node image $node"
ok "zeek, registry:2 and a GNS3 node image run offline"

step "7.1 GNS3 server from the wheelhouse, no index"
sudo rm -rf /opt/gns3 && sudo python3 -m venv /opt/gns3 || bad "venv"
sudo /opt/gns3/bin/pip install -q --no-index --find-links "$S/gns3/wheelhouse" gns3-server 2>&1 | tail -3; [ "${PIPESTATUS[0]}" -eq 0 ] || bad "pip wheelhouse"
echo "   gns3server $(/opt/gns3/bin/gns3server --version 2>&1 | tail -1)"
ok "gns3-server installed offline"

step "air gap: unblock"
sudo "$R/scripts/r770-airgap-sim.sh" unblock && sudo "$R/scripts/r770-airgap-sim.sh" status
printf '\nINSTALL TEST: ALL PASS\n'
