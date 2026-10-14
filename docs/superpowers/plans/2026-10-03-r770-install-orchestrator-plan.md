# R770 Install Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `scripts/r770-install.sh`, a resumable bash orchestrator that drives the existing sub-project 0 (Phase 3 storage piece) and sub-project 2 (lab-CA, Malcolm, portal, UFW) scripts through a formalized `check`/`plan`/`apply`/`verify` contract, with gating on destructive steps and resumability off `state/BUILD-STATE.md`, proven on a staging VM rehearsal.

**Architecture:** A step-table-driven loop (`scripts/r770-install.sh`) calls per-script adapter functions (`scripts/r770-install-adapters.sh`) that translate each existing script's real CLI (discovered below — none of them natively speak `check`/`plan`/`apply`/`verify`) into the four-verb contract. The storage step's skip/resume decision reads `state/BUILD-STATE.md`'s Phase 3 row directly; the lab-CA/Malcolm/portal/UFW steps rely on those scripts' own proven idempotency (lab-CA never regenerates an existing CA; UFW's `plan` shows SKIP rows when nothing changed) rather than BUILD-STATE, because BUILD-STATE tracks whole phases (10, 13) at a coarser grain than these four individual steps — see Global Constraints for why this doesn't contradict the spec.

**Tech Stack:** bash, bats (test), shellcheck (lint) — matching every other script in `scripts/`. No new language, no new dependency.

**Spec:** `docs/superpowers/specs/2026-10-03-r770-install-orchestrator-design.md` (committed `ec9d8f6`, operator-approved)

## Global Constraints

- Bash only, no YAML/JSON config — the step table is a hardcoded bash array (spec decision 1).
- Every existing or future phase script is driven through exactly four verbs: `check`, `plan`, `apply`, `verify` (spec contract table). **Clarification on `check`'s exit codes** (the committed spec's wording is terse enough to misread): `check` exits 0 when the orchestrator should proceed to `plan`/`apply` — covering both "nothing to do, already satisfied" and "not yet done but ready" — and exits 2 only when a real, live-discovered dependency is unmet (e.g. Docker isn't installed when the storage step's `check` runs). Exit 1 is a hard error. The *orchestrator's own* top-level exit code (below) is a separate, outer layer — not the same numbers reused for the same meaning.
- Resumability source of truth: `state/BUILD-STATE.md`'s Phases table, for any step that maps 1:1 to one BUILD-STATE phase row. The storage step (Phase 3) is the only step in this plan's scope that does. The lab-CA/Malcolm/portal/UFW steps map to phases 10 and 13 at a many-to-one grain BUILD-STATE can't resolve per-step, so their skip/resume decision instead comes from calling each underlying script's own `plan`/`health`/`verify` output, which the 2026-09-26 staging proof already showed is safe to re-run. The orchestrator still writes BUILD-STATE Phase 10/13 rows once every step mapping to that phase has verified, as the human-readable record — it just isn't the *input* to those four steps' skip decision. Document this distinction inline in `r770-install.sh`'s header comment so a future reader doesn't "fix" it into a BUILD-STATE-only lookup that can't actually resolve per-step status.
- Gated steps (CLAUDE.md rule 3): storage (RAID-adjacent LV creation, data loss risk on a bad `--grow-var`) and UFW (firewall policy) are gated. Lab-CA, Malcolm, and portal are not — they're not in CLAUDE.md's gated list (RAID, partitions, bootloader, firmware, SSH config, Netplan, default route, firewall policy).
- **UFW's dead-man switch is never automated away.** `r770-ufw.sh apply` arms a timed auto-disable that only `confirm`, run from a *separate, new* SSH session, cancels — this is how the script proves the firewall change didn't cut off access. The orchestrator's UFW adapter must never call `confirm` itself in the same invocation; it halts with exit 4 (see below) and an explicit instruction to open a new session and run `confirm` by hand.
- Standalone: no step may assume a Claude Code session is present. No tool calls, no SSH-from-Claude — only local script invocations the operator (or a future cron) runs directly.
- Never touch Netplan, Phase 4 (users/SSH hardening) internals, or anything against the real R770 in this plan's scope — matches the spec's explicit exclusions.
- Match this repo's existing bats convention exactly (seen in `tests/phase3-run.bats`): isolate `PATH` to a per-test `bin/` of stubs plus a small allowlist of real coreutils symlinked into `real/`, inject every external path (script locations, BUILD-STATE file) via environment variables the script reads with a default, so tests never touch the real filesystem outside `$BATS_TEST_TMPDIR`.

## Review Focus

- **A phase row is missing or unparsable in `state/BUILD-STATE.md`** (renumbered table, a row deleted) — `phase_status()` must fail loudly (hard error, not "treat as NOT STARTED"), because silently defaulting to NOT STARTED on a parse failure could re-trigger a gated, destructive step against a system that's actually already past it. Task 1's tests cover this.
- **A step maps to more than one BUILD-STATE phase and they disagree** (e.g. a future multi-phase step where Phase 10 shows VERIFIED but Phase 13 shows NOT STARTED) — must not be treated as "done" on a partial match. Task 1's tests cover this for the general function even though no step in *this* plan's table currently needs it, since the next sub-project to plug in might.
- **Re-running after a gate stop assumes the earlier `plan` is still current** — between an operator reading a `plan` and re-invoking with `--confirm`, real system state can change (another process, a manual fix). `apply` must re-run `check`/`plan` itself rather than trusting a cached result from the earlier invocation. Task 8's tests cover this (a stub that changes its answer between calls).
- **UFW's apply exit path gets treated like every other gated step's** — i.e. someone "fixes" the orchestrator later to auto-confirm because it looks like dead code. Task 7's and Task 8's tests assert the halt-with-instructions behavior explicitly, by name, so removing it breaks a named test, not just a comment.
- **Malcolm's multi-verb apply sequence (`load`→`assert-tags`→`install`→`configure`→`auth`→`bind-loopback`→`start`→`health`) partially succeeds** — e.g. `install` exits 0 but `auth` fails. The adapter must halt the whole orchestrator run at that point (CLAUDE.md rule 5: one change at a time), not continue to `portal`/`ufw` with Malcolm half-configured. Task 6's tests cover this.

---

## Current CLI surface of the scripts this plan wraps (discovered 2026-10-03)

None of these natively speak `check`/`plan`/`apply`/`verify` — every adapter does real translation work, not a rename:

| Script | Real verbs/flags today | Exit codes |
|---|---|---|
| `r770-phase3-run.sh` (storage, sub-project 0's Phase 3 piece) | `check` (read-only: identity, discard, fstab, storage plan) \| `apply [--fstrim]` | 1 on any failure; no 2 |
| `r770-storage-apply.sh` | `--plan` \| `--apply` \| `--grow-var` \| `--lv NAME` | 1 on any failure; no 2 |
| `r770-lab-ca.sh` | `plan` \| `apply` \| `verify` \| `export-ca` | 1 on any failure; no 2 |
| `r770-malcolm-deploy.sh` | `load` \| `assert-tags` \| `install` \| `configure` \| `auth` \| `bind-loopback` \| `start` \| `health` \| `verify` | 1 on any failure; no 2 |
| `r770-portal.sh` | `plan` \| `apply` \| `verify` (with `--host`/`--cacert`/`--user`/`--password-file`) | 1 on any failure; no 2 |
| `r770-ufw.sh` | `plan` \| `apply [--minutes N]` \| `confirm` \| `verify` \| `revert` | 1 on any failure; no 2 |

## File Structure

- **Create:** `scripts/r770-install.sh` — the orchestrator: BUILD-STATE parsing, step table, `run_step`/`main`, CLI (`--only`, `--list`, `--confirm`).
- **Create:** `scripts/r770-install-adapters.sh` — one `storage_*`/`labca_*`/`malcolm_*`/`portal_*`/`ufw_*` function group per existing script, sourced by `r770-install.sh`.
- **Create:** `tests/install.bats` — orchestrator sequencing logic (Task 1, 2, 8, 9), using fake adapter functions.
- **Create:** `tests/install-adapters.bats` — each adapter's verb translation (Tasks 3–7), stubbing the real scripts.
- **Modify:** `README.md` — one new row in the script table (Task 11).
- **Create (evidence, Task 12):** `state/inventory/staging-install-orchestrator-rehearsal-2026-10-03.md` — the rehearsal's commands and output.
- **Modify:** `state/BUILD-STATE.md` — log line recording the orchestrator exists and was rehearsed (Task 13). No phase Status cell changes — nothing has run against the real R770.

---

### Task 1: BUILD-STATE phase-status parser

**Files:**
- Create: `scripts/r770-install.sh` (this task adds only the parser + its own small CLI stub so it's runnable)
- Test: `tests/install.bats`

**Interfaces:**
- Produces: `phase_status <phase_num> <build_state_file>` → prints one of `NOT STARTED`/`READY`/`BLOCKED`/`APPLIED`/`VERIFIED` to stdout and exits 0, or exits 1 with a message on stderr if the phase row is missing or the Status cell doesn't contain a recognized keyword.

- [ ] **Step 1: Write the failing tests**

```bash
# tests/install.bats
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-install.sh"
    T="$BATS_TEST_TMPDIR"
    export BS="$T/BUILD-STATE.md"
}

make_build_state() {
    cat > "$BS" <<'EOF'
# Build State

## Phases

| # | Phase | Depends on | Destructive? | Status | Evidence |
|---|---|---|---|---|---|
| 1 | Hardware discovery | — | No | **VERIFIED** | `inventory/x.md` |
| 3 | Storage layout | 1,2 | **Lower than planned** | **READY** *(note)* | — |
| 10 | Malcolm deployment | 6,9,3 | No | NOT STARTED | — |
EOF
}

@test "phase_status reads a plain VERIFIED status" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 1 '$BS'"
    [ "$status" -eq 0 ]
    [ "$output" = "VERIFIED" ]
}

@test "phase_status strips markdown bold and trailing notes" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 3 '$BS'"
    [ "$status" -eq 0 ]
    [ "$output" = "READY" ]
}

@test "phase_status reads a plain NOT STARTED status" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 10 '$BS'"
    [ "$status" -eq 0 ]
    [ "$output" = "NOT STARTED" ]
}

@test "phase_status fails loudly when the phase row is missing" {
    make_build_state
    run bash -c "source '$SCRIPT' --source-only; phase_status 99 '$BS'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no row for phase 99"* ]]
}

@test "phase_status fails loudly when the Status cell has no recognized keyword" {
    cat > "$BS" <<'EOF'
| # | Phase | Depends on | Destructive? | Status | Evidence |
|---|---|---|---|---|---|
| 5 | Networking | 4 | High | *(garbled)* | — |
EOF
    run bash -c "source '$SCRIPT' --source-only; phase_status 5 '$BS'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unrecognized status"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install.bats`
Expected: FAIL — `scripts/r770-install.sh` doesn't exist yet.

- [ ] **Step 3: Write the minimal implementation**

```bash
#!/usr/bin/env bash
# scripts/r770-install.sh — resumable orchestrator for the R770 install sub-projects.
#
# Drives sub-project 0's Phase 3 piece and sub-project 2 (lab-CA, Malcolm,
# portal, UFW) through a check/plan/apply/verify contract. See
# docs/superpowers/specs/2026-10-03-r770-install-orchestrator-design.md.
#
# Resumability note: the storage step's skip decision reads
# state/BUILD-STATE.md's Phase 3 row directly (one step, one phase). The
# lab-CA/Malcolm/portal/UFW steps map to phases 10 and 13 at a coarser grain
# than BUILD-STATE can resolve per-step, so their skip decision instead comes
# from each script's own idempotent plan/health/verify output. BUILD-STATE
# Phase 10/13 rows are still written once every step mapping to that phase
# verifies — that's the record, not the input.
set -euo pipefail

die()  { printf 'REFUSE  %s\n' "$*" >&2; exit 1; }

# phase_status <phase_num> <build_state_file>
# Prints the Status cell for a Phases-table row, stripped of markdown bold
# and any trailing parenthetical note. Exits 1 if the row is missing or the
# cell has no recognized keyword — never silently defaults.
phase_status() {
    local phase=$1 file=$2
    local line
    line=$(awk -F'|' -v n="$phase" '
        { gsub(/^ +| +$/, "", $2) }
        $2 == n { print; found=1 }
        END { if (!found) exit 1 }
    ' "$file") || die "phase_status: no row for phase $phase in $file"

    local raw status
    raw=$(printf '%s' "$line" | awk -F'|' '{print $6}')
    raw=${raw//\*/}
    raw=$(printf '%s' "$raw" | sed -E 's/\([^)]*\)//g')
    # shellcheck disable=SC2001
    raw=$(printf '%s' "$raw" | sed -E 's/^ +| +$//g')

    case "$raw" in
        "NOT STARTED"|READY|BLOCKED|APPLIED|VERIFIED*) status=$raw ;;
        *) die "phase_status: unrecognized status '$raw' for phase $phase" ;;
    esac
    # VERIFIED rows sometimes carry trailing " — <note>" after the keyword;
    # normalize to just the keyword set this function promises.
    case "$status" in
        VERIFIED*) status=VERIFIED ;;
    esac
    printf '%s\n' "$status"
}

if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi

die "scripts/r770-install.sh: no further CLI yet — later tasks add --list/--only/--confirm"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install.bats`
Expected: PASS (all 5 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install: add BUILD-STATE phase-status parser"
```

---

### Task 2: Step table and skip logic

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `phase_status` from Task 1.
- Produces:
  - `STEP_IDS` — ordered bash array: `(storage labca malcolm portal ufw)`.
  - `step_gated <id>` → exits 0 (gated) or 1 (not gated).
  - `step_build_state_phase <id>` → prints a phase number for steps that map 1:1 to BUILD-STATE (only `storage` → `3`), or prints nothing and exits 1 for steps that don't.
  - `step_registered <id>` → exits 0 if an adapter function group (`<id>_check` etc.) exists as a callable function, 1 otherwise. Lets later tasks' adapters "plug in" by merely defining functions — no table edit needed.

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install.bats

@test "STEP_IDS lists storage before the sub-project 2 steps, in dependency order" {
    run bash -c "source '$SCRIPT' --source-only; echo \"\${STEP_IDS[@]}\""
    [ "$status" -eq 0 ]
    [ "$output" = "storage labca malcolm portal ufw" ]
}

@test "step_gated is true for storage and ufw, false for labca/malcolm/portal" {
    run bash -c "source '$SCRIPT' --source-only; step_gated storage"
    [ "$status" -eq 0 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated ufw"
    [ "$status" -eq 0 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated labca"
    [ "$status" -eq 1 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated malcolm"
    [ "$status" -eq 1 ]
    run bash -c "source '$SCRIPT' --source-only; step_gated portal"
    [ "$status" -eq 1 ]
}

@test "step_build_state_phase resolves storage to phase 3 and fails for labca" {
    run bash -c "source '$SCRIPT' --source-only; step_build_state_phase storage"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
    run bash -c "source '$SCRIPT' --source-only; step_build_state_phase labca"
    [ "$status" -eq 1 ]
}

@test "step_registered is false before any adapter is defined" {
    run bash -c "source '$SCRIPT' --source-only; step_registered storage"
    [ "$status" -eq 1 ]
}

@test "step_registered is true once the four verb functions exist" {
    run bash -c "source '$SCRIPT' --source-only
        storage_check() { :; }; storage_plan() { :; }
        storage_apply() { :; }; storage_verify() { :; }
        step_registered storage"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install.bats`
Expected: FAIL — `STEP_IDS`/`step_gated`/`step_build_state_phase`/`step_registered` undefined.

- [ ] **Step 3: Write the minimal implementation**

Insert into `scripts/r770-install.sh`, after `phase_status`, before the `--source-only` guard:

```bash
STEP_IDS=(storage labca malcolm portal ufw)

step_gated() {
    case "$1" in
        storage|ufw) return 0 ;;
        labca|malcolm|portal) return 1 ;;
        *) die "step_gated: unknown step '$1'" ;;
    esac
}

step_build_state_phase() {
    case "$1" in
        storage) printf '3\n'; return 0 ;;
        labca|malcolm|portal|ufw) return 1 ;;
        *) die "step_build_state_phase: unknown step '$1'" ;;
    esac
}

step_registered() {
    local id=$1
    declare -F "${id}_check" >/dev/null \
        && declare -F "${id}_plan" >/dev/null \
        && declare -F "${id}_apply" >/dev/null \
        && declare -F "${id}_verify" >/dev/null
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install.bats`
Expected: PASS (all tests so far)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install: add step table, gating and registration lookup"
```

---

### Task 3: Storage adapter (wraps `r770-phase3-run.sh`)

**Files:**
- Create: `scripts/r770-install-adapters.sh`
- Test: `tests/install-adapters.bats`

**Interfaces:**
- Consumes: `$PHASE3_RUN` env var — path to `r770-phase3-run.sh` (defaults to `"$(dirname "${BASH_SOURCE[0]}")/r770-phase3-run.sh"`), overridable in tests.
- Produces: `storage_check`, `storage_plan`, `storage_apply`, `storage_verify` — each exits 0/1/2 per the Global Constraints' `check` clarification; `apply`/`verify` exit 0 or 1 only (no "unmet dependency" case post-check).

- [ ] **Step 1: Write the failing tests**

```bash
# tests/install-adapters.bats
setup() {
    ADAPTERS="$BATS_TEST_DIRNAME/../scripts/r770-install-adapters.sh"
    T="$BATS_TEST_TMPDIR"
    export PHASE3_RUN="$T/phase3-run.sh"
}

stub_phase3_run() {
    cat > "$PHASE3_RUN" <<EOF
#!/usr/bin/env bash
echo "phase3-run \$*" >> "$T/calls"
case "\$1" in
    check) exit "\${CHECK_EXIT:-0}" ;;
    apply) exit "\${APPLY_EXIT:-0}" ;;
esac
EOF
    chmod +x "$PHASE3_RUN"
}

@test "storage_check exits 0 when phase3-run check succeeds" {
    stub_phase3_run
    CHECK_EXIT=0 run bash -c "source '$ADAPTERS'; storage_check"
    [ "$status" -eq 0 ]
}

@test "storage_check exits 2 when phase3-run check fails (unmet dependency)" {
    stub_phase3_run
    CHECK_EXIT=1 run bash -c "source '$ADAPTERS'; storage_check"
    [ "$status" -eq 2 ]
}

@test "storage_plan runs phase3-run check (it already shows the plan)" {
    stub_phase3_run
    run bash -c "source '$ADAPTERS'; storage_plan"
    [ "$status" -eq 0 ]
    grep -q "phase3-run check" "$T/calls"
}

@test "storage_apply runs phase3-run apply and propagates failure" {
    stub_phase3_run
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; storage_apply"
    [ "$status" -eq 1 ]
    grep -q "phase3-run apply" "$T/calls"
}

@test "storage_verify re-runs check as the post-apply proof" {
    stub_phase3_run
    CHECK_EXIT=0 run bash -c "source '$ADAPTERS'; storage_verify"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install-adapters.bats`
Expected: FAIL — `scripts/r770-install-adapters.sh` doesn't exist.

- [ ] **Step 3: Write the minimal implementation**

```bash
#!/usr/bin/env bash
# scripts/r770-install-adapters.sh — translates each phase script's real CLI
# (none of which natively speak check/plan/apply/verify) into that contract.
# Sourced by scripts/r770-install.sh; never run standalone.

PHASE3_RUN=${PHASE3_RUN:-"$(dirname "${BASH_SOURCE[0]}")/r770-phase3-run.sh"}

storage_check() {
    "$PHASE3_RUN" check && return 0
    return 2   # phase3-run's own checks found an unmet dependency
}

storage_plan() {
    # phase3-run's check already prints the storage plan (lsblk, fstab,
    # discard verdicts) — there's no separate dry-run verb to call.
    "$PHASE3_RUN" check
}

storage_apply() {
    "$PHASE3_RUN" apply "$@"
}

storage_verify() {
    # No distinct verify verb; re-running check is the same read-only proof
    # the sub-project 0 spec's Part 2.2 step 4 runs by hand after apply.
    "$PHASE3_RUN" check
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install-adapters.bats`
Expected: PASS (all 5 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install-adapters.sh tests/install-adapters.bats
git commit -m "r770-install: add storage adapter wrapping r770-phase3-run.sh"
```

---

### Task 4: Lab-CA adapter (wraps `r770-lab-ca.sh`)

**Files:**
- Modify: `scripts/r770-install-adapters.sh`
- Test: `tests/install-adapters.bats`

**Interfaces:**
- Consumes: `$LAB_CA` env var, defaults to `.../r770-lab-ca.sh`.
- Produces: `labca_check`, `labca_plan`, `labca_apply`, `labca_verify`.

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install-adapters.bats

stub_lab_ca() {
    cat > "$LAB_CA" <<EOF
#!/usr/bin/env bash
echo "lab-ca \$*" >> "$T/calls"
case "\$1" in
    plan)   [ -n "\${PLAN_OUTPUT:-}" ] && echo "\$PLAN_OUTPUT"; exit "\${PLAN_EXIT:-0}" ;;
    apply)  exit "\${APPLY_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
esac
EOF
    chmod +x "$LAB_CA"
}

@test "labca_check exits 0 (apply is idempotent; check never blocks)" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    run bash -c "source '$ADAPTERS'; labca_check"
    [ "$status" -eq 0 ]
}

@test "labca_plan surfaces the real plan output" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    PLAN_OUTPUT="nothing to do — CA already issued" run bash -c "source '$ADAPTERS'; labca_plan"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
}

@test "labca_apply propagates failure" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; labca_apply"
    [ "$status" -eq 1 ]
}

@test "labca_verify calls the real verify verb" {
    export LAB_CA="$T/lab-ca.sh"; stub_lab_ca
    VERIFY_EXIT=0 run bash -c "source '$ADAPTERS'; labca_verify"
    [ "$status" -eq 0 ]
    grep -q "lab-ca verify" "$T/calls"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install-adapters.bats`
Expected: FAIL — `labca_*` undefined.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/r770-install-adapters.sh`:

```bash
LAB_CA=${LAB_CA:-"$(dirname "${BASH_SOURCE[0]}")/r770-lab-ca.sh"}

labca_check() {
    # r770-lab-ca.sh never regenerates an existing CA, so apply is always
    # safe to invoke — check has nothing to block on.
    return 0
}

labca_plan() {
    "$LAB_CA" plan
}

labca_apply() {
    "$LAB_CA" apply "$@"
}

labca_verify() {
    "$LAB_CA" verify
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install-adapters.bats`
Expected: PASS (9 tests total)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install-adapters.sh tests/install-adapters.bats
git commit -m "r770-install: add lab-CA adapter wrapping r770-lab-ca.sh"
```

---

### Task 5: Portal adapter (wraps `r770-portal.sh`)

**Files:**
- Modify: `scripts/r770-install-adapters.sh`
- Test: `tests/install-adapters.bats`

**Interfaces:**
- Consumes: `$PORTAL` env var, defaults to `.../r770-portal.sh`.
- Produces: `portal_check`, `portal_plan`, `portal_apply`, `portal_verify`.

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install-adapters.bats

stub_portal() {
    cat > "$PORTAL" <<EOF
#!/usr/bin/env bash
echo "portal \$*" >> "$T/calls"
case "\$1" in
    plan)   exit "\${PLAN_EXIT:-0}" ;;
    apply)  exit "\${APPLY_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
esac
EOF
    chmod +x "$PORTAL"
}

@test "portal_check exits 0 (apply re-applies config idempotently)" {
    export PORTAL="$T/portal.sh"; stub_portal
    run bash -c "source '$ADAPTERS'; portal_check"
    [ "$status" -eq 0 ]
}

@test "portal_plan, apply and verify call the matching real verb" {
    export PORTAL="$T/portal.sh"; stub_portal
    run bash -c "source '$ADAPTERS'; portal_plan"
    [ "$status" -eq 0 ]
    run bash -c "source '$ADAPTERS'; portal_apply"
    [ "$status" -eq 0 ]
    run bash -c "source '$ADAPTERS'; portal_verify"
    [ "$status" -eq 0 ]
    grep -q "portal plan" "$T/calls"
    grep -q "portal apply" "$T/calls"
    grep -q "portal verify" "$T/calls"
}

@test "portal_apply propagates failure" {
    export PORTAL="$T/portal.sh"; stub_portal
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; portal_apply"
    [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install-adapters.bats`
Expected: FAIL — `portal_*` undefined.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/r770-install-adapters.sh`:

```bash
PORTAL=${PORTAL:-"$(dirname "${BASH_SOURCE[0]}")/r770-portal.sh"}

portal_check() {
    return 0
}

portal_plan() {
    "$PORTAL" plan "$@"
}

portal_apply() {
    "$PORTAL" apply "$@"
}

portal_verify() {
    "$PORTAL" verify "$@"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install-adapters.bats`
Expected: PASS (12 tests total)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install-adapters.sh tests/install-adapters.bats
git commit -m "r770-install: add portal adapter wrapping r770-portal.sh"
```

---

### Task 6: Malcolm adapter (wraps `r770-malcolm-deploy.sh`'s multi-verb sequence)

**Files:**
- Modify: `scripts/r770-install-adapters.sh`
- Test: `tests/install-adapters.bats`

**Interfaces:**
- Consumes: `$MALCOLM_DEPLOY` env var, defaults to `.../r770-malcolm-deploy.sh`.
- Produces: `malcolm_check`, `malcolm_plan`, `malcolm_apply`, `malcolm_verify`. `malcolm_apply` runs `load → assert-tags → install → configure → auth → bind-loopback → start → health` in order and **halts at the first non-zero exit**, printing which sub-verb failed.

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install-adapters.bats

stub_malcolm() {
    cat > "$MALCOLM_DEPLOY" <<EOF
#!/usr/bin/env bash
echo "malcolm \$1" >> "$T/calls"
if [ -n "\${FAIL_AT:-}" ] && [ "\$1" = "\$FAIL_AT" ]; then exit 1; fi
case "\$1" in
    health) exit "\${HEALTH_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
esac
exit 0
EOF
    chmod +x "$MALCOLM_DEPLOY"
}

@test "malcolm_check runs health as a read-only proxy for current state" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    run bash -c "source '$ADAPTERS'; malcolm_check"
    [ "$status" -eq 0 ]
    grep -q "malcolm health" "$T/calls"
}

@test "malcolm_apply runs every sub-verb in order on a clean run" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 0 ]
    for v in load assert-tags install configure auth bind-loopback start health; do
        grep -q "malcolm $v" "$T/calls"
    done
}

@test "malcolm_apply halts at the first sub-verb that fails and runs nothing after it" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    FAIL_AT=auth run bash -c "source '$ADAPTERS'; malcolm_apply"
    [ "$status" -eq 1 ]
    [[ "$output" == *"auth"* ]]
    grep -q "malcolm configure" "$T/calls"
    ! grep -q "malcolm bind-loopback" "$T/calls"
    ! grep -q "malcolm start" "$T/calls"
}

@test "malcolm_verify calls the real verify verb" {
    export MALCOLM_DEPLOY="$T/malcolm.sh"; stub_malcolm
    VERIFY_EXIT=0 run bash -c "source '$ADAPTERS'; malcolm_verify"
    [ "$status" -eq 0 ]
    grep -q "malcolm verify" "$T/calls"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install-adapters.bats`
Expected: FAIL — `malcolm_*` undefined.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/r770-install-adapters.sh`:

```bash
MALCOLM_DEPLOY=${MALCOLM_DEPLOY:-"$(dirname "${BASH_SOURCE[0]}")/r770-malcolm-deploy.sh"}

malcolm_check() {
    "$MALCOLM_DEPLOY" health
}

malcolm_plan() {
    # No native dry-run verb; health is the closest read-only view of
    # current state. Known limitation, not a true diff — see the design
    # spec's "contract mismatch" risk.
    "$MALCOLM_DEPLOY" health
}

malcolm_apply() {
    local verb
    for verb in load assert-tags install configure auth bind-loopback start health; do
        if ! "$MALCOLM_DEPLOY" "$verb"; then
            printf 'malcolm_apply: halted — %s failed\n' "$verb" >&2
            return 1
        fi
    done
}

malcolm_verify() {
    "$MALCOLM_DEPLOY" verify
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install-adapters.bats`
Expected: PASS (16 tests total)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install-adapters.sh tests/install-adapters.bats
git commit -m "r770-install: add Malcolm adapter sequencing the real deploy verbs"
```

---

### Task 7: UFW adapter (wraps `r770-ufw.sh`, preserves the dead-man switch)

**Files:**
- Modify: `scripts/r770-install-adapters.sh`
- Test: `tests/install-adapters.bats`

**Interfaces:**
- Consumes: `$UFW_SCRIPT` env var, defaults to `.../r770-ufw.sh`.
- Produces: `ufw_check`, `ufw_plan`, `ufw_apply`, `ufw_verify`. `ufw_apply` exits **4** (not 0 or 1) after successfully arming the dead-man switch — a distinct signal the orchestrator must treat as "needs a manual `confirm` from a new session," never as plain success or plain failure.

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install-adapters.bats

stub_ufw() {
    cat > "$UFW_SCRIPT" <<EOF
#!/usr/bin/env bash
echo "ufw \$*" >> "$T/calls"
case "\$1" in
    plan)   exit "\${PLAN_EXIT:-0}" ;;
    apply)  exit "\${APPLY_EXIT:-0}" ;;
    verify) exit "\${VERIFY_EXIT:-0}" ;;
    confirm) exit "\${CONFIRM_EXIT:-0}" ;;
esac
EOF
    chmod +x "$UFW_SCRIPT"
}

@test "ufw_check exits 0 (plan shows SKIP rows when nothing changed)" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    run bash -c "source '$ADAPTERS'; ufw_check"
    [ "$status" -eq 0 ]
}

@test "ufw_apply exits 4 on a successful arm, never calling confirm itself" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    APPLY_EXIT=0 run bash -c "source '$ADAPTERS'; ufw_apply"
    [ "$status" -eq 4 ]
    [[ "$output" == *"new"*"session"* ]] || [[ "$output" == *"confirm"* ]]
    ! grep -q "ufw confirm" "$T/calls"
}

@test "ufw_apply exits 1, not 4, when the real apply itself failed" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    APPLY_EXIT=1 run bash -c "source '$ADAPTERS'; ufw_apply"
    [ "$status" -eq 1 ]
}

@test "ufw_verify calls the real verify verb" {
    export UFW_SCRIPT="$T/ufw.sh"; stub_ufw
    VERIFY_EXIT=0 run bash -c "source '$ADAPTERS'; ufw_verify"
    [ "$status" -eq 0 ]
    grep -q "ufw verify" "$T/calls"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install-adapters.bats`
Expected: FAIL — `ufw_*` undefined.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/r770-install-adapters.sh`:

```bash
UFW_SCRIPT=${UFW_SCRIPT:-"$(dirname "${BASH_SOURCE[0]}")/r770-ufw.sh"}

ufw_check() {
    "$UFW_SCRIPT" plan
}

ufw_plan() {
    "$UFW_SCRIPT" plan
}

ufw_apply() {
    local rc
    "$UFW_SCRIPT" apply "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'ufw_apply: armed — open a NEW ssh session and run "r770-ufw.sh confirm" to keep it, or it auto-disables\n' >&2
        return 4
    fi
    return "$rc"
}

ufw_verify() {
    "$UFW_SCRIPT" verify
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install-adapters.bats`
Expected: PASS (20 tests total)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install-adapters.sh tests/install-adapters.bats
git commit -m "r770-install: add UFW adapter that halts for a new-session confirm, never auto-confirms"
```

---

### Task 8: Orchestrator `run_step` and `main` loop

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `STEP_IDS`, `step_gated`, `step_build_state_phase`, `step_registered` (Task 2); `<id>_check/plan/apply/verify` (Tasks 3–7, or fakes in tests).
- Produces: `run_step <id> [--confirm]` → one of exit `0` (done — skipped or completed), `1` (apply/verify failed for real), `2` (gated, awaiting confirmation), `3` (not registered yet), `4` (armed, needs a manual out-of-band confirm — only `ufw` returns this today, surfaced verbatim from the adapter). `main "$@"` loops `STEP_IDS` in order, stopping at the first non-zero `run_step` result.

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install.bats

fake_adapter() {
    # fake_adapter <id> <check_exit> <apply_exit> <verify_exit>
    local id=$1
    eval "${id}_check() { echo \"${id}_check\" >> \"$T/calls\"; return $2; }"
    eval "${id}_plan()  { echo \"${id}_plan\"  >> \"$T/calls\"; return 0; }"
    eval "${id}_apply() { echo \"${id}_apply\" >> \"$T/calls\"; return $3; }"
    eval "${id}_verify(){ echo \"${id}_verify\" >> \"$T/calls\"; return $4; }"
}

@test "run_step skips a step whose mapped BUILD-STATE phase is already VERIFIED" {
    make_build_state   # phase 1 is VERIFIED in the fixture; alias storage to it for this test
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { [ \"\$1\" = storage ] && echo 1 || return 1; }
        $(declare -f fake_adapter); fake_adapter storage 0 0 0
        run_step storage '$BS'"
    [ "$status" -eq 0 ]
    [ ! -f "$T/calls" ]   # never even called check — BUILD-STATE already says VERIFIED
}

@test "run_step halts with exit 3 on the first unregistered step" {
    run bash -c "source '$SCRIPT' --source-only; run_step labca '$BS'"
    [ "$status" -eq 3 ]
    [[ "$output" == *"not yet implemented"* ]]
}

@test "run_step halts with exit 2 at a gated step with no --confirm, printing the plan" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter); fake_adapter storage 0 0 0
        run_step storage '$BS'"
    [ "$status" -eq 2 ]
    grep -q storage_plan "$T/calls"
    ! grep -q storage_apply "$T/calls"
}

@test "run_step proceeds through apply+verify at a gated step when --confirm is given" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter); fake_adapter storage 0 0 0
        run_step storage '$BS' --confirm"
    [ "$status" -eq 0 ]
    grep -q storage_check "$T/calls"
    grep -q storage_apply "$T/calls"
    grep -q storage_verify "$T/calls"
}

@test "run_step re-checks before apply even with --confirm, rather than trusting an earlier plan" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        calls=0
        storage_check() { calls=\$((calls+1)); echo \"storage_check \$calls\" >> '$T/calls'; return 0; }
        storage_plan() { :; }; storage_apply() { :; return 0; }; storage_verify() { :; return 0; }
        run_step storage '$BS'
        run_step storage '$BS' --confirm"
    [ "$status" -eq 0 ]
    [ "$(grep -c storage_check "$T/calls")" -eq 2 ]
}

@test "run_step surfaces a non-gated step's apply failure as exit 1 with real output" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter); fake_adapter labca 0 1 0
        run_step labca '$BS'"
    [ "$status" -eq 1 ]
}

@test "run_step passes through exit 4 from an adapter (ufw-style armed state) unchanged" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        ufw_check() { return 0; }; ufw_plan() { :; }
        ufw_apply() { echo 'armed — needs a new-session confirm' >&2; return 4; }
        ufw_verify() { :; }
        run_step ufw '$BS' --confirm"
    [ "$status" -eq 4 ]
}

@test "main stops the whole run at the first halting step and does not run later ones" {
    run bash -c "
        source '$SCRIPT' --source-only
        step_build_state_phase() { return 1; }
        $(declare -f fake_adapter)
        fake_adapter storage 0 0 0
        main --only storage,labca --confirm"
    [ "$status" -eq 3 ]   # labca has no real adapter defined in this test
    grep -q storage_apply "$T/calls"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install.bats`
Expected: FAIL — `run_step`/`main` undefined.

- [ ] **Step 3: Write the minimal implementation**

Insert into `scripts/r770-install.sh`, after Task 2's block, before the `--source-only` guard:

```bash
# run_step <id> <build_state_file> [--confirm]
run_step() {
    local id=$1 bsfile=$2 confirm=${3:-}

    if ! step_registered "$id"; then
        printf 'run_step: %s — not yet implemented, stopping here\n' "$id" >&2
        return 3
    fi

    local phase
    if phase=$(step_build_state_phase "$id" 2>/dev/null); then
        local st
        st=$(phase_status "$phase" "$bsfile")
        if [ "$st" = APPLIED ] || [ "$st" = VERIFIED ]; then
            return 0
        fi
    fi

    "${id}_check"
    local check_rc=$?
    if [ "$check_rc" -eq 2 ]; then
        printf 'run_step: %s — unmet dependency, stopping here\n' "$id" >&2
        return 2
    elif [ "$check_rc" -ne 0 ]; then
        return 1
    fi

    if step_gated "$id"; then
        if [ "$confirm" != "--confirm" ]; then
            "${id}_plan"
            printf 'run_step: %s is gated — review the plan above, then re-run with --confirm\n' "$id" >&2
            return 2
        fi
    fi

    "${id}_apply" || return $?
    "${id}_verify"
}

# main [--only id1,id2,...] [--confirm]
main() {
    local only="" confirm=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --only) only=$2; shift 2 ;;
            --confirm) confirm=--confirm; shift ;;
            *) die "main: unknown argument '$1'" ;;
        esac
    done

    local ids=("${STEP_IDS[@]}")
    if [ -n "$only" ]; then
        IFS=',' read -r -a ids <<< "$only"
    fi

    local id rc
    for id in "${ids[@]}"; do
        run_step "$id" "${INSTALL_BUILD_STATE:-state/BUILD-STATE.md}" "$confirm"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi
    done
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install.bats`
Expected: PASS (all tests so far)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install: add run_step/main orchestration loop with gating and resume"
```

---

### Task 9: CLI entrypoint (`--list`, usage, real invocation)

**Files:**
- Modify: `scripts/r770-install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Produces: running `r770-install.sh --list` prints `STEP_IDS` with gated/registered status; running with no args or `--only`/`--confirm` invokes `main`; running with an unknown flag exits 1 with a usage message. Matches this repo's existing `--list`/`--only` convention (`r770-offline-fetch.sh`).

- [ ] **Step 1: Write the failing tests**

```bash
# append to tests/install.bats

@test "--list prints every step with its gated and registered status" {
    run bash "$SCRIPT" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"storage"*"gated"* ]]
    [[ "$output" == *"labca"*"not gated"* ]]
}

@test "an unknown flag exits 1 with a usage message" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/install.bats`
Expected: FAIL — `--list` not implemented; no top-level dispatch yet.

- [ ] **Step 3: Write the minimal implementation**

Add near the top of `scripts/r770-install.sh`, right after `set -euo pipefail`:

```bash
adapters="$(dirname "${BASH_SOURCE[0]}")/r770-install-adapters.sh"
# shellcheck disable=SC1090
[ -r "$adapters" ] && source "$adapters"
```

Replace the `--source-only` guard block at the end of `scripts/r770-install.sh` with:

```bash
usage() {
    die "usage: r770-install.sh [--list | --only id1,id2,... ] [--confirm]"
}

cmd_list() {
    local id gated reg
    for id in "${STEP_IDS[@]}"; do
        step_gated "$id" && gated=gated || gated="not gated"
        step_registered "$id" && reg=registered || reg="not yet implemented"
        printf '%-10s %-10s %s\n' "$id" "$gated" "$reg"
    done
}

if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    --list) cmd_list ;;
    --only|--confirm|"") main "$@" ;;
    *) usage ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/install.bats`
Expected: PASS (full suite)

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-install.sh tests/install.bats
git commit -m "r770-install: add --list/usage CLI dispatch and source the adapters"
```

---

### Task 10: Lint and full suite

**Files:** none (verification task)

- [ ] **Step 1: Run the repo's one check**

Run: `./tests/run.sh`
Expected: shellcheck clean on `r770-install.sh` and `r770-install-adapters.sh`; every bats file, including the two new ones, PASS.

- [ ] **Step 2: Fix any shellcheck findings**

Address them inline (quoting, `local` declarations) — no `# shellcheck disable` beyond the ones already placed intentionally in Tasks 1 and 9.

- [ ] **Step 3: Re-run and confirm green**

Run: `./tests/run.sh`
Expected: exit 0.

- [ ] **Step 4: Commit (only if Step 2 changed anything)**

```bash
git add scripts/r770-install.sh scripts/r770-install-adapters.sh
git commit -m "r770-install: fix shellcheck findings"
```

---

### Task 11: README script table entry

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add one row to the script table**

In the `| Path | What |` table, after the `r770-ufw.sh` row, add:

```markdown
| `scripts/r770-install.sh` | Resumable orchestrator for sub-project 0's Phase 3 piece and sub-project 2 (lab-CA, Malcolm, portal, UFW) — `check`/`plan`/`apply`/`verify` per step, gated on storage and UFW, resumable off `state/BUILD-STATE.md`; ships inside the bundle, run standalone on the R770 (`--list`, `--only`, `--confirm`) |
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README script table entry for r770-install.sh"
```

---

### Task 12: Staging VM rehearsal

**Files:**
- Create: `state/inventory/staging-install-orchestrator-rehearsal-2026-10-03.md`

This is an operator-run task against a real staging VM, not code. Sub-project 1 (Docker) has no script yet, so the rehearsal VM is prepared with Docker and loaded images the same way the already-proven `state/inventory/staging-install-test-2026-09-26.md` procedure did — **outside** the orchestrator, exactly like Phase 2's manual pre-step. The rehearsal itself exercises `r770-install.sh --only storage,labca,malcolm,portal,ufw --confirm`, not a full no-flags run, because sub-projects 1/3/4/5 genuinely don't exist yet — a no-flags run would correctly stop at the first one it hits, which this rehearsal isn't testing.

- [ ] **Step 1: Clone a fresh staging VM** (standing in for the R770) from the latest clean snapshot, per `scripts/r770-staging-vm.sh`.

- [ ] **Step 2: Prepare it exactly as `staging-install-test-2026-09-26.md` did**: bundle copy, APT local repo, Docker install, image load, so the VM is at the point sub-project 1 would leave it.

- [ ] **Step 3: Copy `scripts/r770-install.sh` and `scripts/r770-install-adapters.sh`, plus the four wrapped scripts, onto the VM** (same relative layout as `scripts/` in this repo, so the adapters' default paths resolve without overrides).

- [ ] **Step 4: Run the gated storage step first, without `--confirm`**, and paste the plan output:
  ```bash
  ./r770-install.sh --only storage
  ```
  Expected: exit 2, a plan printed, nothing changed on disk.

- [ ] **Step 5: Re-run with `--confirm`** and paste the output:
  ```bash
  ./r770-install.sh --only storage --confirm
  ```
  Expected: exit 0, LVs created exactly as `staging-analyst-stack-2026-09-26.md`'s storage evidence already showed happens when `r770-storage-apply.sh` runs for real.

- [ ] **Step 6: Run the sub-project 2 steps**, including the gated UFW step:
  ```bash
  ./r770-install.sh --only labca,malcolm,portal,ufw --confirm
  ```
  Expected: exit 4 at the UFW step (armed, not auto-confirmed) — paste the message. From a **separate** new SSH session, run `r770-ufw.sh confirm` by hand and paste that output too.

- [ ] **Step 7: Confirm the analyst stack works**, re-using the same checks `staging-analyst-stack-2026-09-26.md` already proved (portal/malcolm/docs.lab 401→200, Arkime/Zeek indexed, UFW verify from outside). Paste the results.

- [ ] **Step 8: Write up `state/inventory/staging-install-orchestrator-rehearsal-2026-10-03.md`** with every command and its real output from Steps 1–7 — no step marked done without the pasted evidence (CLAUDE.md rule 4).

- [ ] **Step 9: Commit**

```bash
git add state/inventory/staging-install-orchestrator-rehearsal-2026-10-03.md
git commit -m "Staging rehearsal: r770-install.sh proven through storage and sub-project 2 on VM <id>"
```

---

### Task 13: BUILD-STATE log entry

**Files:**
- Modify: `state/BUILD-STATE.md`

- [ ] **Step 1: Append one Log line**, dated to the rehearsal's real date, pointing at Task 12's evidence file. Do **not** change any Phase Status cell — nothing has run against the real R770 yet, only the staging VM.

- [ ] **Step 2: Commit**

```bash
git add state/BUILD-STATE.md
git commit -m "BUILD-STATE: log the install orchestrator's staging rehearsal"
```

---

## Next steps after this plan

Sub-projects 1 (Docker), 3 (capture ports), 4 (bridges/GNS3/mirror), and 5 (dnsmasq/chrony) each still need their own design → plan → execution, same as before. Once each ships a script implementing the four-verb contract, it's added to `STEP_IDS` in the right dependency position — no change to `run_step`/`main` should be needed, which is the test this plan's contract-first approach is actually standing on.
