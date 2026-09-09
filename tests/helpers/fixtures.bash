# Synthetic bundles: the real directory shape from r770-offline-fetch.sh, with
# byte-sized stand-ins for the 40+ GB of payload. Never a real bundle.

# make_bundle <dir> — a freshly fetched bundle, manual categories NOT yet staged
# (README.txt only), which is the true state at the end of a fetch run.
make_bundle() {
    local d=$1
    mkdir -p "$d"/{apt,malcolm,docker,images,enrichment,isos,dell} \
             "$d"/gns3/{appliances,definitions} "$d"/.stamps
    echo "fake deb"             > "$d/apt/example_1.0_amd64.deb"
    echo "fake malcolm images"  > "$d/malcolm/malcolm-images-26.08.0.tar.gz"
    echo "fake monitoring"      > "$d/docker/monitoring-images.tar.gz"
    # Every image tarball the fetch script writes has a companion image-list.txt
    # beside it, and import-bundle.md step 3b verifies loaded tags against it.
    # The fixture omitted them, which made it a shape no real bundle ever has.
    printf 'ghcr.io/idaholab/malcolm/arkime:26.08.0\n' > "$d/malcolm/image-list.txt"
    printf 'docker.io/prom/prometheus:v3.14.0\n'       > "$d/docker/monitoring-image-list.txt"
    echo "fake iso"             > "$d/isos/ubuntu-24.04.4-live-server-amd64.iso"
    echo "fake oui"             > "$d/enrichment/oui.txt"
    echo "MANUAL DOWNLOADS from dell.com/support" > "$d/dell/README.txt"
    echo "Stage licensed appliance images here"   > "$d/gns3/appliances/README.txt"
    touch "$d/.stamps/apt" "$d/.stamps/wheelhouse"
    cat > "$d/BUNDLE_NOTES.md" <<'NOTES'
# Bundle notes

- Ubuntu ISO 24.04.4 fetched
- Malcolm 26.08.0 images saved
NOTES
}

# stage_manual <dir> — the operator has completed runbook Step 4.
stage_manual() {
    local d=$1
    echo "fake bios dup"   > "$d/dell/BIOS_R770_1.7.5.EXE"
    echo "fake iosv qcow2" > "$d/gns3/appliances/vios-adventerprisek9.qcow2"
}
