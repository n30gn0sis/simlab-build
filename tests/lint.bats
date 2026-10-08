#!/usr/bin/env bats
#
# Lint gate. Scripts written for this gate must be shellcheck-clean at default
# severity with no exclusions. The two scripts that predate the gate get a
# documented exclusion list (see tests/README.md for why each is accepted).

LEGACY_EXCLUDE="SC2015,SC2012,SC2010,SC1091"

@test "new scripts are shellcheck-clean with no exclusions" {
    run shellcheck scripts/r770-bundle.sh scripts/r770-build-bundle.sh scripts/r770-storage-apply.sh scripts/r770-phase3-run.sh scripts/r770-staging-vm.sh scripts/r770-lab-ca.sh scripts/r770-malcolm-deploy.sh scripts/r770-portal.sh scripts/r770-airgap-sim.sh scripts/r770-ufw.sh scripts/r770-install.sh scripts/r770-install-adapters.sh tests/run.sh scripts/scenarios/scen-lib.sh scripts/scenarios/scen-prep scripts/scenarios/scen-run scripts/scenarios/scen-events.sh scripts/scenarios/scen-check scripts/scenarios/scen-ingest scripts/scenarios/scen-clear scripts/scenarios/scen-bridges.sh images/wan-emu/wan-emu.sh images/svc-targets/gen-dnsmasq.sh images/svc-targets/gen-fixed.sh images/svc-targets/entrypoint.sh scenarios/S1/gen-secrets.sh scenarios/S1/scen-wire.sh scenarios/S0/traffic/profile-basic.sh scenarios/S1/traffic/profile-basic.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "POSIX-sh entrypoints are shellcheck-clean as sh" {
    run shellcheck -s sh images/ipsec-ss/entrypoint.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "legacy scripts are clean apart from accepted house-style codes" {
    run shellcheck -e "$LEGACY_EXCLUDE" scripts/r770-offline-fetch.sh scripts/r770-precheck.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "hooks are shellcheck-clean with no exclusions" {
    run shellcheck .claude/hooks/session-start.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "every shell script parses" {
    for f in scripts/*.sh scripts/scenarios/* images/*/*.sh scenarios/S*/*.sh scenarios/S*/traffic/*.sh .claude/hooks/*.sh tests/run.sh; do
        run bash -n "$f"
        echo "$f: $output"
        [ "$status" -eq 0 ]
    done
}
