#!/usr/bin/env bats
# One owner per fact. Restating a pin or a size outside its owner is how the
# cadvisor pin went stale and how the retention table drifted 10x from reality.
#
# Uses `git grep`, not a filesystem `grep -r .`: it scans tracked repo content
# only, so untracked/gitignored scratch (e.g. SDD task-brief working files)
# can't produce a false violation that a fresh clone would never see.

@test "version pins live only in the fetch script and the dependency manifest" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -lE '26\.08\.0|v0\.34\.0|v0\.60\.5|10\.7\.1' -- '*.md' '*.sh' \
                 | grep -vE '(^|/)(state|work)/' | grep -v dependency-manifest | grep -v r770-offline-fetch.sh | grep -v OWNERS.md"
    echo "$output"
    [ -z "$output" ]
}

@test "bundle sizes live only in the cycle log" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -nE '45–65 GB|40–55 GB' -- '*.md' \
                 | grep -vE '(^|/)(state|work)/' | grep -v OWNERS.md"
    echo "$output"
    [ -z "$output" ]
}

@test "no document claims the staging host is RHEL" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -n 'RHEL' -- README.md .claude/ | grep -v OWNERS.md"
    echo "$output"
    [ -z "$output" ]
}
