#!/bin/bash
#
# SessionStart hook — Sim Lab R770 build repo.
#
# Installs the tooling this repo's own workflow assumes but that a fresh
# Claude Code on the web container does not ship: shellcheck, the linter for
# scripts/*.sh (already pre-approved in .claude/settings.json permissions).
#
# This repo has no build system, no package manifest, and no test suite —
# it is plans, agent configuration, and two standalone shell scripts. The
# scripts are the only executable code, so linting them is the whole job.
#
# Runs only in remote/web sessions; a local machine keeps whatever the
# operator already has installed. Idempotent and non-interactive: safe to
# re-run, never prompts, and never fails the session if a package index is
# unreachable.

set -uo pipefail

# Local sessions: leave the operator's toolchain alone.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

# Already provisioned (container state is cached between sessions) — nothing to do.
if command -v shellcheck >/dev/null 2>&1; then
    echo "session-start: shellcheck $(shellcheck --version | awk '/^version:/{print $2}') already present"
    exit 0
fi

echo "session-start: installing shellcheck..."

export DEBIAN_FRONTEND=noninteractive

# The base image carries a third-party PPA that the egress proxy blocks; its
# failure is expected and must not abort the run, so the update is advisory.
apt-get update -qq >/dev/null 2>&1 || \
    echo "session-start: apt-get update reported errors (continuing — usually a blocked third-party PPA)"

if apt-get install -y -qq shellcheck >/dev/null 2>&1 && command -v shellcheck >/dev/null 2>&1; then
    echo "session-start: shellcheck $(shellcheck --version | awk '/^version:/{print $2}') installed"
else
    # Not fatal. The scripts still get `bash -n`, and a human can install it
    # later; a broken linter must never cost the operator a session.
    echo "session-start: WARNING shellcheck install failed — lint scripts/*.sh with 'bash -n' only" >&2
fi

exit 0
