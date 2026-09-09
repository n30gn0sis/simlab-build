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
                 | grep -vE '/(superpowers|work)/'"
    echo "$output"
    [ -z "$output" ]
}

@test "no document or script gates a bundle with plain sha256sum -c" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rn 'sha256sum -c MANIFEST' docs/ .claude/ scripts/ | grep -v '/superpowers/'"
    echo "$output"
    [ -z "$output" ]
}

@test "the gate is referenced from the operational paths that use it" {
    cd "$BATS_TEST_DIRNAME/.."
    run bash -c "grep -rl 'r770-bundle.sh' docs/plans/ .claude/ | wc -l"
    [ "$output" -ge 5 ]
}
