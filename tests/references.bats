#!/usr/bin/env bats
# Every repo-relative path named in agent config or in the build tracker must
# exist. This is what makes the Stage 3 moves safe, and it catches phantom
# references like state/inventory/hardware-inventory.md, which is named in
# state/inventory/README.md but has never existed.
#
# A candidate immediately followed by `<...>` (e.g.
# state/inventory/phase-<n>-evidence.txt) is a documented naming template for
# a file that does not exist yet -- not a dangling reference -- and is
# skipped. A concrete path with no placeholder must still exist.

@test "every repo path named in .claude/ or BUILD-STATE.md exists" {
    cd "$BATS_TEST_DIRNAME/.."
    missing=""
    while read -r p; do
        case "$p" in
            *'<'*) continue ;;
        esac
        [ -e "$p" ] || missing="$missing $p"
    done < <(grep -rhoE '(state|docs|scripts|tests|work)/[A-Za-z0-9_./-]+(<[^>]*>?[A-Za-z0-9_./-]*)*' \
                 .claude/ state/BUILD-STATE.md 2>/dev/null \
             | sed 's/[.,)`]*$//' | sort -u)
    echo "missing:$missing"
    [ -z "$missing" ]
}

@test "every script referenced by a slash command exists and is executable" {
    cd "$BATS_TEST_DIRNAME/.."
    while read -r s; do
        [ -x "$s" ] || { echo "not executable: $s"; false; }
    done < <(grep -rhoE 'scripts/[a-z0-9-]+\.sh' .claude/ | sort -u)
}
