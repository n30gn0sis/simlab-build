# Synthetic bundles: the real directory shape from r770-offline-fetch.sh, with
# byte-sized stand-ins for the 40+ GB of payload. Never a real bundle.
#
# Versions here are SYNTHETIC (0.0.0-fixture) and must stay that way. A fixture
# needs *a* version, not *the* version: the pins are owned by the pin block in
# scripts/r770-offline-fetch.sh (see OWNERS.md), and a fixture that spells one
# out is another copy nothing updates on the next bump. Nothing here depends on
# the value -- r770-bundle.sh pairs payloads by glob (malcolm-images-*.tar.gz),
# never by version, and no test asserts on one.

# make_bundle <dir> — a freshly fetched bundle, manual categories NOT yet staged
# (README.txt only), which is the true state at the end of a fetch run.
make_bundle() {
    local d=$1
    mkdir -p "$d"/{apt,malcolm,docker,images,enrichment,isos,dell} \
             "$d"/gns3/{appliances,definitions} "$d"/.stamps \
             "$d"/site/{scripts,config,docs/analyst-wiki}
    echo "fake deb"             > "$d/apt/example_1.0_amd64.deb"
    # site/ — this repo's reviewed scripts/config/docs-analyst-wiki, as
    # r770-offline-fetch.sh's stage_site() copies them. Includes a stand-in
    # for every script r770-bundle.sh's SITE_REQUIRED_SCRIPTS lists (all five
    # exist in the repo), so this "complete bundle" fixture satisfies
    # check_site() with a plain pass, not a WARN. The missing-script WARN path
    # is exercised separately in bundle-verify.bats by deleting one stand-in.
    printf '#!/usr/bin/env bash\necho hi\n' > "$d/site/scripts/hello.sh"
    chmod +x "$d/site/scripts/hello.sh"
    printf '#!/usr/bin/env bash\necho fixture-ca\n' > "$d/site/scripts/r770-lab-ca.sh"
    chmod +x "$d/site/scripts/r770-lab-ca.sh"
    printf '#!/usr/bin/env bash\necho fixture-bundle\n' > "$d/site/scripts/r770-bundle.sh"
    chmod +x "$d/site/scripts/r770-bundle.sh"
    printf '#!/usr/bin/env bash\necho fixture-malcolm-deploy\n' > "$d/site/scripts/r770-malcolm-deploy.sh"
    chmod +x "$d/site/scripts/r770-malcolm-deploy.sh"
    printf '#!/usr/bin/env bash\necho fixture-airgap-sim\n' > "$d/site/scripts/r770-airgap-sim.sh"
    chmod +x "$d/site/scripts/r770-airgap-sim.sh"
    printf '#!/usr/bin/env bash\necho fixture-portal\n' > "$d/site/scripts/r770-portal.sh"
    chmod +x "$d/site/scripts/r770-portal.sh"
    echo "server { }" > "$d/site/config/nginx.conf"
    echo "# wiki"      > "$d/site/docs/analyst-wiki/index.md"
    echo "fake malcolm images"  > "$d/malcolm/malcolm-images-0.0.0-fixture.tar.gz"
    echo "fake monitoring"      > "$d/docker/monitoring-images.tar.gz"
    # Every image tarball the fetch script writes has a companion image-list.txt
    # beside it, and import-bundle.md step 3b verifies loaded tags against it.
    # The fixture omitted them, which made it a shape no real bundle ever has.
    printf 'ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture\n' > "$d/malcolm/image-list.txt"
    printf 'docker.io/prom/prometheus:v0.0.0-fixture\n'       > "$d/docker/monitoring-image-list.txt"
    echo "fake iso"             > "$d/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "fake oui"             > "$d/enrichment/oui.txt"
    echo "MANUAL DOWNLOADS from dell.com/support" > "$d/dell/README.txt"
    echo "Stage licensed appliance images here"   > "$d/gns3/appliances/README.txt"
    touch "$d/.stamps/apt" "$d/.stamps/wheelhouse"
    cat > "$d/BUNDLE_NOTES.md" <<'NOTES'
# Bundle notes

- Ubuntu ISO 0.0.0-fixture fetched
- Malcolm 0.0.0-fixture images saved
NOTES
}

# stage_manual <dir> — the operator has completed runbook Step 4.
stage_manual() {
    local d=$1
    echo "fake bios dup"   > "$d/dell/BIOS_R770_1.7.5.EXE"
    echo "fake iosv qcow2" > "$d/gns3/appliances/vios-adventerprisek9.qcow2"
}
