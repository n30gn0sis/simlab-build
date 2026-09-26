#!/usr/bin/env bash
# Continuation (part 2) of the import/install test of bundle-20260926 on VM 9771, made R770-like.
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

step "3b. re-check the R770 package set (virtual-package aware); install already ran in part 1"
# The R770 package set is the fetch script's own PKGS list — read it, don't restate it.
mapfile -t PKGS < <(awk '/^PKGS=\(/{p=1;next} p&&/^\)/{exit} p' "$R/scripts/r770-offline-fetch.sh" | sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$')
echo "   R770 package set: ${#PKGS[@]} packages"
[ "${#PKGS[@]}" -gt 40 ] || bad "could not read PKGS from the fetch script"
# A virtual package (e.g. qemu-kvm on noble, provided by qemu-system-x86) never
# shows as installed itself; it counts when an installed package provides it.
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
provided() { apt-cache showpkg "$1" 2>/dev/null | sed -n '/^Reverse Provides:/,$p' | awk 'NR>1{print $1}' | while read -r q; do installed "$q" && { echo "$q"; break; }; done; }
missing=""; for p in "${PKGS[@]}"; do installed "$p" || [ -n "$(provided "$p")" ] || missing="$missing $p"; done
[ -z "$missing" ] || bad "not installed:$missing"
ok "all ${#PKGS[@]} R770 packages installed from the bundle ($(grep -c '^Setting up' /tmp/pkgs-install.log) set up)"

step "4. Docker Engine from the bundle"
sudo -E apt-get -y -q install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/tmp/docker-install.log 2>&1 || { tail -8 /tmp/docker-install.log; bad "docker install from bundle"; }
sudo systemctl enable --now docker >/dev/null 2>&1; sleep 3
sudo docker info --format 'server {{.ServerVersion}}, storage {{.Driver}}, cgroup {{.CgroupVersion}}' || bad "docker info"
apt-cache policy docker-ce | grep -q 'file:/srv/repo/apt' || bad "docker-ce did not come from the local repo"
ok "Docker installed from the bundle and running"

step "5. runbook Part 5: load every image tarball, assert every tag"
[ -z "$(sudo docker image ls -q)" ] || bad "image store not empty before load"
for t in "$S"/malcolm/malcolm-images-*.tar.gz "$S/docker/monitoring-images.tar.gz" "$S/gns3/docker-nodes/gns3-node-images.tar.gz"; do
    [ -s "$t" ] || bad "missing tarball $t"
    sudo docker load -i "$t" | tail -1 || bad "docker load $t"
done
norm() { sed -E 's#^docker\.io/library/##; s#^docker\.io/##'; }
sudo docker image ls --format '{{.Repository}}:{{.Tag}}' | norm | sort > /tmp/loaded.txt
echo "   loaded tags: $(wc -l < /tmp/loaded.txt)"
sudo "$R/scripts/r770-malcolm-deploy.sh" assert-tags "$S" | tail -1; [ "${PIPESTATUS[0]}" -eq 0 ] || bad "malcolm assert-tags"
for l in "$S/docker/monitoring-image-list.txt" "$S/gns3/docker-nodes/image-list.txt"; do
    miss=$(comm -23 <(grep -vE '^\s*(#|$)' "$l" | norm | sort) /tmp/loaded.txt)
    [ -z "$miss" ] || { echo "$miss"; bad "missing from $(basename "$l")"; }
    echo "   $(basename "$l"): all $(grep -cvE '^\s*(#|$)' "$l") present"
done
ok "every image in every list loaded offline"

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
