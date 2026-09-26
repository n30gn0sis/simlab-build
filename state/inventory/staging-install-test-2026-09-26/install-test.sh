#!/usr/bin/env bash
# Import/install test of bundle-20260926 on VM 9771, made R770-like.
# Follows docs/plans/r770-install-runbook.md Parts 1, 3, 4-5 and 7.1 with REAL installs,
# under a simulated air gap. Stops at the first failed check. Run as ubuntu (uses sudo).
set -uo pipefail
BD="$(cat ~/bundle-dir)"; N="$(basename "$BD")"; R="$HOME/simlab-build"; S="/data/staging/$N"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; sudo "$R/scripts/r770-airgap-sim.sh" unblock >/dev/null 2>&1; exit 1; }
step() { printf '\n== %s  (%s)\n' "$*" "$(date -u +%H:%M:%S)"; }

step "0. make it R770-like: remove the internet-installed Docker and its apt source"
sudo systemctl stop docker.socket docker containerd >/dev/null 2>&1
sudo -E apt-get purge -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras >/tmp/purge.log 2>&1 || { tail -5 /tmp/purge.log; bad "purge docker"; }
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
command -v docker >/dev/null && bad "docker still on PATH"
ok "no Docker on the box (purged, state and apt source removed)"

step "0b. air gap: block internet for host and containers (auto-revert 240 min), prove it"
sudo "$R/scripts/r770-airgap-sim.sh" block --minutes 240 || bad "airgap block"
sudo "$R/scripts/r770-airgap-sim.sh" status
for u in https://archive.ubuntu.com https://download.docker.com https://pypi.org; do
    curl -s -m 8 -o /dev/null "$u" && bad "internet reachable: $u"
done
ok "no internet (archive.ubuntu.com, download.docker.com, pypi.org unreachable)"

step "1. runbook 1.2-1.4: verify in place, copy to /data/staging, verify the copy --strict"
( cd "$BD" && ./r770-bundle.sh verify . --strict ) | tail -2; [ "${PIPESTATUS[0]}" -eq 0 ] || bad "verify --strict in place"
sudo mkdir -p /data/staging && sudo cp -a "$BD" /data/staging/ || bad "copy"
( cd "$S" && ./r770-bundle.sh verify . --strict ) | tail -2; [ "${PIPESTATUS[0]}" -eq 0 ] || bad "verify --strict on the copy"
ok "bundle passes --strict in place and after the copy"

step "3. runbook Part 3: APT from the bundle only"
sudo mkdir -p /srv/repo && sudo cp -a "$S/apt" /srv/repo/ || bad "repo placement"
for f in Packages Packages.gz Release; do [ -s "/srv/repo/apt/$f" ] || bad "repo missing $f"; done
sudo tar czf /root/apt-sources-install-test.tar.gz /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
sudo mv /etc/apt/sources.list.d /etc/apt/sources.list.d.upstream && sudo mkdir -p /etc/apt/sources.list.d
sudo sh -c ': > /etc/apt/sources.list'
echo 'deb [trusted=yes] file:/srv/repo/apt ./' | sudo tee /etc/apt/sources.list.d/r770-local.list >/dev/null
echo 'Acquire::Languages "none";' | sudo tee /etc/apt/apt.conf.d/99r770-no-translations >/dev/null
sudo rm -rf /var/lib/apt/lists/*
sudo apt-get update 2>&1 | tee ~/install-apt-update.log | tail -4; [ "${PIPESTATUS[0]}" -eq 0 ] || bad "apt-get update"
grep -qE '^(Err|E:|W: Skipping)' ~/install-apt-update.log && bad "apt update printed Err/E:/Skipping"
ok "apt update: exit 0, no Err, no skipped index (Release file works)"

# The R770 package set is the fetch script's own PKGS list — read it, don't restate it.
mapfile -t PKGS < <(awk '/^PKGS=\(/{p=1;next} p&&/^\)/{exit} p' "$R/scripts/r770-offline-fetch.sh" | sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$')
echo "   R770 package set: ${#PKGS[@]} packages"
[ "${#PKGS[@]}" -gt 40 ] || bad "could not read PKGS from the fetch script"
sudo -E apt-get -y -q dist-upgrade >/tmp/dist-upgrade.log 2>&1 || { tail -8 /tmp/dist-upgrade.log; bad "dist-upgrade from the bundle"; }
ok "dist-upgrade from the bundle ($(grep -c '^Setting up' /tmp/dist-upgrade.log) packages set up)"
sudo -E apt-get -y -q install "${PKGS[@]}" >/tmp/pkgs-install.log 2>&1 || { tail -12 /tmp/pkgs-install.log; bad "install of the R770 package set"; }
missing=""; for p in "${PKGS[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing="$missing $p"; done
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
sudo docker run --rm --network none --entrypoint /opt/zeek/bin/zeek "$z" --version 2>&1 | tail -1 | grep -qi zeek || bad "zeek container"
echo "   $(sudo docker run --rm --network none --entrypoint /opt/zeek/bin/zeek "$z" --version 2>&1 | tail -1)"
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
