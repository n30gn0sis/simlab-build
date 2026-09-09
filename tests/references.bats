#!/usr/bin/env bats
# Every repo-relative path named in agent config, in the build tracker, or in
# the evidence tree must exist. This is what makes the Stage 3 moves safe, and
# it catches phantom references like state/inventory/hardware-inventory.md,
# which is named in state/inventory/README.md but has never existed.
#
# A candidate immediately followed by `<...>` (e.g.
# state/inventory/phase-<n>-evidence.txt) is a documented naming template for
# a file that does not exist yet -- not a dangling reference -- and is
# skipped. A concrete path with no placeholder must still exist.
#
# work/plans/ is deliberately NOT covered: a plan names the scripts and tests
# it intends to create, and those forward references are correct until the
# plan is executed.

# Collect every repo-relative path named under the given roots and assert each
# one exists. Roots are passed as arguments; grep -r walks files and dirs alike.
assert_named_paths_exist() {
    missing=""
    while read -r p; do
        case "$p" in
            *'<'*) continue ;;
        esac
        [ -e "$p" ] || missing="$missing $p"
    done < <(grep -rhoE '(state|docs|scripts|tests|work)/[A-Za-z0-9_./-]+(<[^>]*>?[A-Za-z0-9_./-]*)*' \
                 "$@" 2>/dev/null | sed 's/[.,)`]*$//' | sort -u)
    echo "missing:$missing"
    [ -z "$missing" ]
}

@test "every repo path named in .claude/ or BUILD-STATE.md exists" {
    cd "$BATS_TEST_DIRNAME/.."
    assert_named_paths_exist .claude/ state/BUILD-STATE.md
}

# state/ is the evidence tree: every file under it records something that was
# discovered or decided, so every concrete path it names must exist NOW.
@test "every repo path named anywhere under state/ exists" {
    cd "$BATS_TEST_DIRNAME/.."
    assert_named_paths_exist state/
}

@test "every script referenced by a slash command exists and is executable" {
    cd "$BATS_TEST_DIRNAME/.."
    while read -r s; do
        [ -x "$s" ] || { echo "not executable: $s"; false; }
    done < <(grep -rhoE 'scripts/[a-z0-9-]+\.sh' .claude/ | sort -u)
}
