#!/usr/bin/env bats
# One owner per fact. Restating a pin or a size outside its owner is how the
# cadvisor pin went stale and how the retention table drifted 10x from reality.
#
# Uses `git grep`, not a filesystem `grep -r .`: it scans tracked repo content
# only, so untracked/gitignored scratch (e.g. SDD task-brief working files)
# can't produce a false violation that a fresh clone would never see.
#
# All exclusions are git PATHSPECS passed to `git grep` itself (':!path'),
# never a post-hoc `grep -v` on the output. `git grep -n` emits
# "path:line:full-text" — a `grep -v <name-or-pattern>` on that output matches
# the whole line, so it silently swallows any real violation whose line also
# happens to *mention* the excluded name (e.g. a correct fix that reads "see
# OWNERS.md", or a reference to a path under state/ or work/). A pathspec
# restricts which files git grep even looks at, so it cannot be fooled by
# content. Only test 1 uses `git grep -l` (paths only, one per line) where a
# trailing `grep -v <name>` is content-safe by construction; even there we
# use pathspecs for consistency.

@test "version pins live only in the fetch script" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -lE '26\.08\.0|v0\.34\.0|v0\.60\.5|10\.7\.1|v3\.14\.0|7\.21\.5|26\.7|24\.04\.4|3\.0\.6|suricata-7\.0|v0\.28\.0' -- '*.md' '*.sh' \
                 ':!state/' ':!work/' ':!OWNERS.md' ':!scripts/r770-offline-fetch.sh'"
    echo "$output"
    [ -z "$output" ]
}

@test "bundle sizes live only in the cycle log" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -nE '45–65 GB|40–55 GB' -- '*.md' \
                 ':!state/' ':!work/' ':!OWNERS.md'"
    echo "$output"
    [ -z "$output" ]
}

@test "no document claims the staging host is RHEL" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -n 'RHEL' -- README.md .claude/ scripts/ ':!OWNERS.md'"
    echo "$output"
    [ -z "$output" ]
}
