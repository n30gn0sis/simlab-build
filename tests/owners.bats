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
    # '*.bats' '*.bash' are in the pathspec deliberately. Without them the guard
    # could not see test code at all, which made OWNERS.md's "fixtures are not
    # exempt from the pin check" claim false and unenforceable: tests/helpers/
    # fixtures.bash carried the live Malcolm, Prometheus and Ubuntu ISO pins in
    # plain sight while this test reported ok. Fixture values are synthetic now,
    # so there is nothing here for the guard to trip on -- which is the point.
    run bash -c "git grep -lE '26\.08\.0|v0\.34\.0|v0\.60\.5|10\.7\.1|v3\.14\.0|7\.21\.5|26\.7|24\.04\.4|3\.0\.6|suricata-7\.0|v0\.28\.0' -- '*.md' '*.sh' '*.bats' '*.bash' \
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
# Two tests, because there are two distinct failures: a copy appearing somewhere
# with no declared right to it, and a permitted copy *disagreeing* with the
# owner. The second is the one that actually happened.
#
# THE OWNER'S VALUE IS DERIVED, NEVER SPELLED OUT -- a test that hard-codes the
# value becomes copy N+1 of the fact it is guarding. The derivation is anchored
# on the phrase "free extents", NOT on the current digits. An earlier version
# derived it with '6\.8[0-9] Ti?B', which stops matching the moment the owner's
# value moves out of that window and yields an empty lookup; every
# comparison built on an empty lookup is vacuous, and a check that cannot fail
# reads as coverage while providing none. Both tests below therefore fail loudly
# on an empty or ambiguous lookup before comparing anything.
#
# docs/superpowers/specs/ is excluded from these two checks and only these: the
# approved restructure spec quotes both the wrong and the right value verbatim as
# the evidence for why this guard exists. Forbidding it would delete the
# evidence. Disclosed in OWNERS.md.

@test "the free-extent figure appears only in its owner and the named restatements" {
    cd "$BATS_TEST_DIRNAME/.."
    owner="$(grep -ohE '[0-9]+\.[0-9]+ [KMGTP]i?B (of )?free extents' state/BUILD-STATE.md \
                | sed -E 's/ (of )?free extents$//' | sort -u)"
    if [ -z "$owner" ]; then
        echo "OWNER LOOKUP FOUND NOTHING: state/BUILD-STATE.md states no"
        echo "'<n>.<n> <unit> [of] free extents' anywhere. Everything below would be"
        echo "vacuous, so this fails rather than reporting coverage it does not have."
        false
    fi
    if [ "$(printf '%s\n' "$owner" | wc -l)" -ne 1 ]; then
        echo "OWNER STATES MORE THAN ONE FORM, so there is no single value to compare"
        echo "against: $owner"
        false
    fi
    echo "owner (state/BUILD-STATE.md) states: [$owner]"

    # (a) A bare copy of the owner's current value, anywhere it is not permitted.
    #     Catches restatements that omit the phrase, e.g. an agent prompt reading
    #     "<figure> free in the existing VG" (which is what discovery-analyst.md
    #     used to say). No literal value appears in this file, by design.
    run bash -c "git grep -nF '$owner' -- '*.md' '*.sh' '*.bats' '*.bash' \
                 ':!state/' ':!work/plans/archive/' ':!OWNERS.md' \
                 ':!docs/superpowers/specs/' \
                 ':!PRD.md' ':!docs/plans/r770-network-lab-buildout.md'"
    copies="$output"

    # (b) Any free-extent figure at all, whatever its digits -- this is what
    #     catches a *stale* value left behind after the owner moved on.
    run bash -c "git grep -nE '[0-9]+\.[0-9]+ [KMGTP]i?B (of )?free extents' -- '*.md' '*.sh' '*.bats' '*.bash' \
                 ':!state/' ':!work/plans/archive/' ':!OWNERS.md' \
                 ':!docs/superpowers/specs/' \
                 ':!PRD.md' ':!docs/plans/r770-network-lab-buildout.md'"
    stale="$output"

    echo "$copies"
    echo "$stale"
    [ -z "$copies" ]
    [ -z "$stale" ]
}

@test "every restatement of the free-extent figure matches the owner exactly" {
    cd "$BATS_TEST_DIRNAME/.."
    owner="$(grep -ohE '[0-9]+\.[0-9]+ [KMGTP]i?B (of )?free extents' state/BUILD-STATE.md \
                | sed -E 's/ (of )?free extents$//' | sort -u)"
    if [ -z "$owner" ]; then
        echo "OWNER LOOKUP FOUND NOTHING: state/BUILD-STATE.md states no"
        echo "'<n>.<n> <unit> [of] free extents' anywhere. The comparison below would"
        echo "be vacuous, so this fails rather than reporting coverage it does not have."
        false
    fi
    if [ "$(printf '%s\n' "$owner" | wc -l)" -ne 1 ]; then
        echo "OWNER STATES MORE THAN ONE FORM: $owner"
        false
    fi
    echo "owner (state/BUILD-STATE.md) states: [$owner]"
    run bash -c "git grep -hoE '[0-9]+\.[0-9]+ [KMGTP]i?B (of )?free extents' -- state/BUILD-STATE.md PRD.md docs/plans/r770-network-lab-buildout.md \
                 | sed -E 's/ (of )?free extents\$//' | sort -u"
    echo "forms found across owner + permitted restatements:"
    echo "$output"
    [ "$output" = "$owner" ]
}
