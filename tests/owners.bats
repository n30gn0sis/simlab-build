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
# "path:line:full-text" -- a `grep -v <name-or-pattern>` on that output matches
# the whole line, so it silently swallows any real violation whose line also
# happens to *mention* the excluded name (e.g. a correct fix that reads "see
# OWNERS.md", or a reference to a path under state/ or work/). A pathspec
# restricts which files git grep even looks at, so it cannot be fooled by
# content. Only test 1 uses `git grep -l` (paths only, one per line) where a
# trailing `grep -v <name>` is content-safe by construction; even there we
# use pathspecs for consistency.
#
# EXCLUDED TREES -- both are disclosed in OWNERS.md, "Excluded trees":
#
#   ':!state/'               append-only evidence. A report records what a
#                            command printed on a date; rewriting it to point
#                            at an owner would falsify the evidence. The owners
#                            of two facts (BUILD-STATE.md, inventory/bundles.md)
#                            also live here.
#   ':!work/plans/archive/'  frozen history. An executed plan records the pins
#                            and counts that were current when it ran.
#
# `work/plans/active/` is NOT excluded and must not be: it is live operational
# content. The previous wholesale ':!work/' let a live plan hard-code the
# Malcolm pin in an operator command (`unzip ... malcolm-<pin>-docker_install.zip`)
# that breaks at the air gap on the next bump, and state a bundle file count
# one lower than its owner. Excluding live plans from the pin guard is exactly
# what let that drift happen.

@test "version pins live only in the fetch script" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -lE '26\.08\.0|v0\.34\.0|v0\.60\.5|10\.7\.1|v3\.14\.0|7\.21\.5|26\.7|24\.04\.4|3\.0\.6|suricata-7\.0|v0\.28\.0' -- '*.md' '*.sh' \
                 ':!state/' ':!work/plans/archive/' ':!OWNERS.md' ':!scripts/r770-offline-fetch.sh'"
    echo "$output"
    [ -z "$output" ]
}

@test "bundle sizes live only in the cycle log" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -nE '45–65 GB|40–55 GB' -- '*.md' \
                 ':!state/' ':!work/plans/archive/' ':!OWNERS.md'"
    echo "$output"
    [ -z "$output" ]
}

@test "no document claims the staging host is RHEL" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -n 'RHEL' -- README.md .claude/ scripts/ ':!OWNERS.md'"
    echo "$output"
    [ -z "$output" ]
}

# --- Free-extent capacity figure -------------------------------------------
#
# Drift incident #3: state/BUILD-STATE.md recorded this figure in TB where the
# measured figure is in TiB -- a ~600 GiB error in the file CLAUDE.md calls the
# single source of truth. It was live in five files with no test at all, which
# is how it drifted in the first place.
#
# Owner: state/BUILD-STATE.md (hardware of record).
# Permitted restatements, named in OWNERS.md: PRD.md (a requirements document
# states the hardware its requirements are written against) and
# docs/plans/r770-network-lab-buildout.md (the authoritative design, whose §3
# derives the LV layout from this number).
#
# Two tests, because there are two distinct failures: a *sixth* copy appearing
# somewhere with no declared right to it, and a permitted copy *disagreeing*
# with the owner. The second is the one that actually happened.
#
# docs/superpowers/specs/ is excluded here and only here: the approved
# restructure spec quotes both the wrong and the right value verbatim as the
# evidence for why this guard exists. Forbidding it would delete the evidence.
# Disclosed in OWNERS.md.

@test "the free-extent figure appears only in its owner and the named restatements" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "git grep -nE '6\.8[0-9] Ti?B' -- '*.md' '*.sh' \
                 ':!state/' ':!work/plans/archive/' ':!OWNERS.md' \
                 ':!docs/superpowers/specs/' \
                 ':!PRD.md' ':!docs/plans/r770-network-lab-buildout.md'"
    echo "$output"
    [ -z "$output" ]
}

@test "every restatement of the free-extent figure matches the owner exactly" {
    cd "$BATS_TEST_DIRNAME/.."
    # Derived from the owner, never hard-coded: a test that spells the value out
    # becomes copy N+1 of the fact it is guarding.
    owner="$(grep -ohE '6\.8[0-9] Ti?B' state/BUILD-STATE.md | sort -u)"
    echo "owner (state/BUILD-STATE.md) states: [$owner]"
    [ -n "$owner" ]
    [ "$(printf '%s\n' "$owner" | wc -l)" -eq 1 ]
    run bash -c "git grep -hoE '6\.8[0-9] Ti?B' -- state/BUILD-STATE.md PRD.md docs/plans/r770-network-lab-buildout.md | sort -u"
    echo "forms found across owner + permitted restatements:"
    echo "$output"
    [ "$output" = "$owner" ]
}
