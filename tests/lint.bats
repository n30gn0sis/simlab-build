#!/usr/bin/env bats
#
# Lint gate. Scripts written for this gate must be shellcheck-clean at default
# severity with no exclusions. The two scripts that predate the gate get a
# documented exclusion list (see tests/README.md for why each is accepted).

# SC2094 is a real finding at r770-offline-fetch.sh:651 and comes off this list
# when that line starts delegating to r770-bundle.sh (integrity-gate Task 6).
LEGACY_EXCLUDE="SC2015,SC2012,SC2010,SC1091,SC2094"

@test "new scripts are shellcheck-clean with no exclusions" {
    run shellcheck scripts/r770-bundle.sh tests/run.sh
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
    for f in scripts/*.sh .claude/hooks/*.sh tests/run.sh; do
        run bash -n "$f"
        echo "$f: $output"
        [ "$status" -eq 0 ]
    done
}
