#!/usr/bin/env bats
# The defective recipe must not reappear. r770-bundle.sh:14-18 records why:
# `find | xargs sha256sum` reports OK for an empty bundle, for files added after
# the manifest was written, and for leftover .part downloads -- each reproduced
# against the real command. This test is the reason integrity-gate Task 7 cannot
# vanish again.

@test "no document instructs the reader to hand-roll a manifest" {
    cd "$BATS_TEST_DIRNAME/.."
    # git grep, not grep -r: this repo keeps ephemeral, git-ignored planning
    # scratch (.superpowers/sdd/) inside the working tree, and that scratch
    # quotes this very pattern for illustration. grep -r over "." would trip
    # on it every time regardless of tracked-file state -- a false failure,
    # not a real one. git grep only ever sees tracked content, which is what
    # this guard is actually checking.
    run bash -c "git grep -n 'xargs -0 sha256sum' -- '*.md' \
                 | grep -vE '(^|/)(superpowers|work)/'"
    echo "$output"
    [ -z "$output" ]
}

@test "no document or script gates a bundle with plain sha256sum -c" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rn 'sha256sum -c MANIFEST' docs/ .claude/ scripts/ | grep -v '/superpowers/'"
    echo "$output"
    [ -z "$output" ]
}

# The two tests below replace a single count assertion:
#
#     run bash -c "grep -rl 'r770-bundle.sh' docs/plans/ .claude/ | wc -l"
#     [ "$output" -ge 5 ]
#
# Seven files matched, so it carried two files of slack and named no path.
# Proved by injection: stripping every r770-bundle.sh reference from
# .claude/commands/import-bundle.md -- the R770 side of the air-gap crossing,
# the live defect this branch exists to close -- still reported ok. A count is
# not a reachability guard. Each route is now asserted by name, and a failure
# names the file that lost the reference.

@test "the gate is referenced by name from every documented operational route" {
    cd "$BATS_TEST_DIRNAME/.."
    # One entry per route an operator or agent can actually take to the gap:
    #   import-bundle.md   R770-side import -- the crossing itself
    #   bundle.md          staging-side cut via /bundle
    #   bundle-builder.md  the agent that does supply-chain work
    #   staging-runbook    the human runbook for cutting and shipping media
    #   offline-supply     the transfer procedure
    #   dependency-manifest the transfer/import section of the manifest
    # `verify` is required, not just the filename: a route that only names the
    # script's `manifest` subcommand does not gate anything.
    missing=""
    for f in .claude/commands/import-bundle.md \
             .claude/commands/bundle.md \
             .claude/agents/bundle-builder.md \
             docs/plans/r770-staging-runbook.md \
             docs/plans/r770-offline-supply.md \
             docs/plans/r770-dependency-manifest.md; do
        grep -qE 'r770-bundle\.sh verify' "$f" || missing="$missing $f"
    done
    echo "no 'r770-bundle.sh verify' reference in:$missing"
    [ -z "$missing" ]
}

@test "the gate is runnable by the agent that is told to run it" {
    cd "$BATS_TEST_DIRNAME/.."
    # Reachable in prose but denied by the permission layer is still unreachable.
    run grep -F 'scripts/r770-bundle.sh' .claude/settings.json
    echo "no Bash allow-rule naming scripts/r770-bundle.sh in .claude/settings.json"
    [ "$status" -eq 0 ]
}
