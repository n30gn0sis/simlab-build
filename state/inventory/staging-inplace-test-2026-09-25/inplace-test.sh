#!/usr/bin/env bash
# In-place bundle test on staging VM 9770, under a simulated air gap.
# Follows docs/plans/r770-install-runbook.md Parts 1-5 and 7.1 against the
# bundle where it sits. Stops at the first failed check. Run as ubuntu via sudo.
set -uo pipefail
BD="$(cat ~/bundle-dir)"; N="$(basename "$BD")"; R="$HOME/simlab-build"
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; sudo "$R/scripts/r770-airgap-sim.sh" unblock >/dev/null 2>&1; exit 1; }
step() { printf '\n== %s\n' "$*"; }

step "0. air gap: block internet (auto-revert 120 min), prove it"
sudo "$R/scripts/r770-airgap-sim.sh" block --minutes 120 || bad "airgap block"
sudo "$R/scripts/r770-airgap-sim.sh" status
if curl -s -m 8 -o /dev/null https://registry-1.docker.io/v2/; then bad "internet still reachable from host"; fi
ok "host has no internet (curl to registry-1.docker.io fails)"

step "1. verify the bundle in place, then the staged copy (runbook 1.2-1.4)"
( cd "$BD" && ./r770-bundle.sh verify . ) | tail -4; rc=${PIPESTATUS[0]}
echo "verify-in-place exit=$rc"; [ "$rc" -le 2 ] || bad "verify in place"
sudo mkdir -p /data/staging && sudo cp -a "$BD" /data/staging/ || bad "copy to /data/staging"
( cd "/data/staging/$N" && ./r770-bundle.sh verify . ) | tail -3; rc=${PIPESTATUS[0]}
echo "verify-copy exit=$rc"; [ "$rc" -le 2 ] || bad "verify copy"
ok "bundle verifies at source and after copy"
S="/data/staging/$N"

step "3. APT from the bundle only (runbook Part 3)"
sudo mkdir -p /srv/repo && sudo cp -a "$S/apt" /srv/repo/ && [ -s /srv/repo/apt/Packages.gz ] || bad "repo placement"
sudo tar czf /root/apt-sources-inplace.tar.gz /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
sudo mv /etc/apt/sources.list.d /etc/apt/sources.list.d.upstream && sudo mkdir -p /etc/apt/sources.list.d
sudo sh -c ': > /etc/apt/sources.list'
echo 'deb [trusted=yes] file:/srv/repo/apt ./' | sudo tee /etc/apt/sources.list.d/r770-local.list >/dev/null
echo 'Acquire::Languages "none";' | sudo tee /etc/apt/apt.conf.d/99r770-no-translations >/dev/null
sudo apt-get update 2>&1 | tee ~/inplace-apt-update.log | tail -3; rc=${PIPESTATUS[0]}
echo "apt-get update exit=$rc"; [ "$rc" -eq 0 ] || bad "apt-get update failed"
# A flat repo with no Release file makes apt probe Packages.{xz,bz2,lzma} before Packages.gz;
# those three misses are expected. Any other Err/E: line is a real failure.
grep -E '^(Err|E:)|File not found' ~/inplace-apt-update.log | grep -vE '^Err:[0-9]+ file:/srv/repo/apt \./ Packages$|File not found - /srv/repo/apt/\./Packages\.(xz|bz2|lzma) ' && bad "apt update reported unexpected errors"
grep -vE 'file:/srv/repo/apt|^Reading|^Building|^All packages|^$' ~/inplace-apt-update.log | grep -qE '^(Get|Hit|Ign):' && bad "apt touched a non-local source"
ok "apt update clean, local repo only"
for p in libvirt-daemon-system qemu-kvm tshark bridge-utils chrony dnsmasq nginx python3-venv; do
    sudo apt-get install --dry-run -y "$p" >/tmp/dr 2>&1 || { tail -3 /tmp/dr; bad "dry-run $p"; }
    printf '   %-24s %s Inst\n' "$p" "$(grep -c '^Inst ' /tmp/dr)"
done
ok "R770 package set resolves from the bundle alone"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-venv python3-pip-whl >/tmp/venv-inst 2>&1 || { tail -5 /tmp/venv-inst; bad "real install of python3-venv from bundle"; }
ok "python3-venv really installed from the bundle (needed for 7.1)"

step "5. container images: wipe everything the fetch pulled, then load from the bundle only (runbook Part 5)"
sudo docker system prune -a -f >/dev/null && [ -z "$(sudo docker image ls -q)" ] || bad "could not empty docker image store"
ok "docker image store empty before load"
for t in "$S"/malcolm/malcolm-images-*.tar.gz "$S/docker/monitoring-images.tar.gz" "$S/gns3/docker-nodes/gns3-node-images.tar.gz"; do
    [ -s "$t" ] || bad "missing tarball $t"
    sudo docker load -i "$t" | tail -1 || bad "docker load $t"
done
sudo docker image ls --format '{{.Repository}}:{{.Tag}}' | sort > /tmp/loaded.txt
echo "   loaded tags: $(wc -l < /tmp/loaded.txt)"
sudo "$R/scripts/r770-malcolm-deploy.sh" assert-tags "$S" | tail -2; [ "${PIPESTATUS[0]}" -eq 0 ] || bad "malcolm assert-tags"
for l in "$S/docker/monitoring-image-list.txt" "$S/gns3/docker-nodes/image-list.txt"; do
    miss=$(comm -23 <(grep -vE '^\s*(#|$)' "$l" | sort) /tmp/loaded.txt)
    [ -z "$miss" ] || { echo "$miss"; bad "tags missing from $(basename "$l")"; }
    echo "   $(basename "$l"): all $(grep -cvE '^\s*(#|$)' "$l") present"
done
ok "every image in every list is loaded, with no network"

step "7.1 GNS3 server from the wheelhouse, no index"
sudo rm -rf /opt/gns3 && sudo python3 -m venv /opt/gns3 || bad "venv"
sudo /opt/gns3/bin/pip install -q --no-index --find-links "$S/gns3/wheelhouse" gns3-server 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || bad "pip install gns3-server from wheelhouse"
echo "   $(/opt/gns3/bin/gns3server --version 2>&1 | tail -1)"
ok "gns3-server installs offline from the wheelhouse"

step "air gap: unblock"
sudo "$R/scripts/r770-airgap-sim.sh" unblock && sudo "$R/scripts/r770-airgap-sim.sh" status
printf '\nIN-PLACE TEST: ALL PASS\n'
