#!/usr/bin/env bats
# Secret protection must live IN the repo. It currently depends on
# /root/.config/git/ignore -- a machine-local file. README.md tells the operator
# to `git init` on the staging VM, where that file does not exist, and
# .claude/settings.json auto-approves `git add` and `git commit`.

@test "a .gitignore exists in the repo" {
    [ -f "$BATS_TEST_DIRNAME/../.gitignore" ]
}

@test "settings.local.json is ignored by the REPO, not by a machine-local file" {
    cd "$BATS_TEST_DIRNAME/.."
    # GIT_CONFIG_GLOBAL=/dev/null alone is not enough: it disables ~/.gitconfig but
    # not git's separate default-excludes fallback ($HOME/.config/git/ignore), which
    # on some machines already carries an entry for this exact path. Pin
    # core.excludesFile to /dev/null too so only the repo's own .gitignore can match --
    # otherwise this test passes even with no .gitignore at all, and can never catch
    # someone deleting the line that actually protects this file.
    run env GIT_CONFIG_GLOBAL=/dev/null git -c core.excludesFile=/dev/null check-ignore -q .claude/settings.local.json
    [ "$status" -eq 0 ]
}

@test "bundle output directories are ignored" {
    cd "$BATS_TEST_DIRNAME/.."
    run env GIT_CONFIG_GLOBAL=/dev/null git check-ignore -q bundle-20260908/
    [ "$status" -eq 0 ]
}

@test "no credential-shaped string is tracked" {
    cd "$BATS_TEST_DIRNAME/.."
    run git grep -nE 'sshpass -p [^$]|BEGIN [A-Z ]*PRIVATE KEY' -- ':!tests/'
    [ "$status" -ne 0 ]
}
