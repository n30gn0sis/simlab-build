# Phase 2 / Phase 3 — PERC assessment and storage apply — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove perccli2 from the build, ship a tested `scripts/r770-storage-apply.sh`, then run Phase 2 (read-only assessment) and Phase 3 (gated LV creation) on the R770.

**Architecture:** Tasks 1–4 are repo work on the staging side and must leave `./tests/run.sh` green. Tasks 5–6 are operational. They run against the R770 over SSH, save evidence under `state/inventory/`, and Task 6 stops for operator confirmation before any write.

**Tech Stack:** bash, bats (≥ 1.10), shellcheck, LVM2, util-linux (`findmnt`, `mount`, `blkid`), xfsprogs, e2fsprogs.

**Spec:** `docs/superpowers/specs/2026-09-23-phase2-3-storage-design.md`

## Global Constraints

- Phase 2 is **assess-only**: nothing on the R770 changes in Task 5.
- **No iDRAC/Redfish queries** anywhere in this plan.
- **perccli2 is removed** from the plan and every supply list. The precheck's optional `perccli2 perccli storcli2 storcli` probe stays.
- Key custody gates **Phase 10**, not Phase 3.
- VG is `ubuntu-vg0`. The script never names a block device.
- Layout owner: `docs/plans/r770-network-lab-buildout.md` §3.2. The script's `LAYOUT` is a permitted, drift-tested copy.
- New fstab lines: `UUID=<uuid> <mount> <fs> noatime,nofail 0 2`. `lv-var`'s existing line is not touched.
- Reserve floor: an action may not leave VG free below **5 %** of VG size.
- New scripts must be shellcheck-clean with **no exclusions** (`tests/lint.bats`).
- `./tests/run.sh` must be green before either phase advances (CLAUDE.md).
- Dated evidence records (`state/inventory/r770-precheck-report-2026-09-02.md`, `state/inventory/r770-discovery-findings.md`) are not edited.
- Commit messages end with the attribution lines from the session's system reminder.

## File map

| File | Task | Responsibility |
|---|---|---|
| `scripts/r770-offline-fetch.sh` | 1 | Dell README + header comment lose perccli2 |
| `scripts/r770-build-bundle.sh` | 1 | Manual-items text loses perccli2 |
| `scripts/r770-precheck.sh` | 1 | Missing-tool warn re-worded; probe kept |
| `tests/offline-fetch.bats` | 1 | Regression guard: Dell README never names perccli |
| `state/inventory/bundles.md`, 4 plan docs, `docs/CODEMAPS/dependencies.md`, buildout §2/§3.2/§12 | 1 | Supply-list and TRIM wording |
| `scripts/r770-storage-apply.sh` | 2, 3 | Phase 3 plan/apply/grow-var |
| `tests/storage-apply.bats` | 2, 3 | Shimmed LVM tests + layout drift test |
| `tests/lint.bats`, `tests/README.md`, `README.md`, `OWNERS.md` | 2 | Register the new script and its permitted layout copy |
| `state/BUILD-STATE.md` | 4, 5, 6 | Unknowns, Phase 10 gate, phase statuses, log |
| `state/inventory/r770-phase2-assessment.md` | 5 | Phase 2 report |
| `state/inventory/r770-phase3-storage-<date>.md` | 6 | Phase 3 evidence |

---

### Task 1: Remove perccli2 from the supply lists

**Files:**
- Modify: `scripts/r770-offline-fetch.sh:36` and the `stage_manual()` Dell heredoc (≈l.781–791)
- Modify: `scripts/r770-build-bundle.sh:154`
- Modify: `scripts/r770-precheck.sh:181`
- Modify: `state/inventory/bundles.md` (≈l.135–141)
- Modify: `docs/plans/r770-staging-runbook.md:245`, `docs/plans/r770-install-runbook.md:406-409`, `docs/plans/r770-offline-supply.md:82`, `docs/plans/r770-dependency-manifest.md:133`, `docs/CODEMAPS/dependencies.md:18`
- Modify: `docs/plans/r770-network-lab-buildout.md` §2 (l.79), §3.2 (l.139), §12 (item 1 unchanged; TRIM mentions only)
- Test: `tests/offline-fetch.bats`

**Interfaces:** none (text only). Later tasks rely on the buildout §3.2 table being unchanged apart from the mount-options paragraph.

- [ ] **Step 1: Write the failing test.** In `tests/offline-fetch.bats`, directly after the existing `@test "--only manual runs for real: writes the Dell README, ..."` block, add:

```bash
@test "the Dell README no longer asks for perccli (removed 2026-09-23)" {
    run "$SCRIPT" --only manual
    echo "$output"
    [ "$status" -eq 0 ]
    run grep -ci 'perccli' "$BUNDLE_DIR/dell/README.txt"
    [ "$output" = "0" ]
}
```

`setup()` already exports `BUNDLE_DIR` and stubs the network tools, so this invocation matches the neighbouring test.

- [ ] **Step 2: Run it and confirm it fails**

Run: `bats tests/offline-fetch.bats -f "no longer asks for perccli"`
Expected: FAIL. `grep -ci` prints a count > 0.

- [ ] **Step 3: Edit the fetch script.** Line 36:

```
#   - Dell firmware/perccli downloads (dell.com, per service tag)
```
becomes
```
#   - Dell firmware downloads (dell.com, per service tag)
```

In the `stage_manual()` heredoc, delete from `REQUIRED regardless of version:` up to and including the line `      * NVMe link width: both drives negotiated x2 of a x4-capable link`, plus the blank line after it. The heredoc then reads `(express service code 35366715688)`, a blank line, and then `ONLY IF DELL LISTS SOMETHING NEWER — installed baselines, from Phase 1`. Leave the rest of the heredoc as it is.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bats tests/offline-fetch.bats`
Expected: all PASS.

- [ ] **Step 5: Edit the remaining files**

`scripts/r770-build-bundle.sh:154`:
```
  dell/                    firmware DUPs for the service tag, and perccli2.
```
→
```
  dell/                    firmware DUPs for the service tag.
```

`scripts/r770-precheck.sh:181`: keep the probe. Replace the warn text with:
```bash
    warn "No perccli/storcli found — PERC details come from the iDRAC inventory export (Phase 1) and OS-side checks (Phase 2); the CLI is not part of the build."
```

`state/inventory/bundles.md`: delete the line `**Required regardless of version — this one is not optional:**`, the blank line after it, the `- [ ] **\`perccli2\`** …` item, and its three numbered sub-items. Keep `- [ ] Optionally: Dell System Update (DSU) offline repository for the R770`.

`docs/plans/r770-staging-runbook.md:245`: delete `**perccli2** (the PERC H975i is an NVMe RAID part), ` so the line reads `… service tag **\`G8WFGH4\`** — BIOS + iDRAC + Broadcom NIC firmware DUPs, …`.

`docs/plans/r770-install-runbook.md`: delete the paragraph that starts `` `perccli2` — note the `2` `` (4 lines) and the blank line before it.

`docs/plans/r770-offline-supply.md:82`: `perccli/perccli2 for the PERC, BIOS + iDRAC firmware packages,` → `BIOS + iDRAC firmware packages,`.

`docs/plans/r770-dependency-manifest.md:133`: delete `**perccli2** (the PERC **H975i Front** is an NVMe RAID controller — confirmed by discovery, so this is the right tool, not perccli), ` so it reads `… published checksums: BIOS DUP, iDRAC firmware, …`.

`docs/CODEMAPS/dependencies.md:18`: `dell.com firmware + perccli (per service tag)` → `dell.com firmware (per service tag)`.

`docs/plans/r770-network-lab-buildout.md`:
- l.79: `TRIM passthrough is still unconfirmed and needs perccli in Phase 2.` → `TRIM/discard is checked OS-side in Phase 2 (lsblk -D, sysfs).`
- l.139: `— **the PERC VD's TRIM passthrough is still unconfirmed** (needs perccli, Phase 2), so do not rely on it until it is.` → `— enabled only if Phase 2's OS-side check shows the VD advertises discard (\`lsblk -D\`, \`/sys/block/<dev>/queue/discard_max_bytes\`); otherwise left off.`
- Then run `grep -n -i perccli docs/plans/r770-network-lab-buildout.md` and give any remaining hit the same "OS-side check" treatment.

- [ ] **Step 6: Confirm only the intended mentions remain**

Run: `git grep -n -i perccli -- ':!state/inventory/r770-precheck-report-2026-09-02.md' ':!state/inventory/r770-discovery-findings.md' ':!work/plans/archive/' ':!docs/superpowers/' ':!work/plans/active/'`
Expected: hits only in `scripts/r770-precheck.sh` (the probe loop and the new warn) and in `state/BUILD-STATE.md` l.64, which Task 4 fixes.

- [ ] **Step 7: Run the full suite**

Run: `./tests/run.sh`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add scripts/ tests/offline-fetch.bats state/inventory/bundles.md docs/plans/ docs/CODEMAPS/dependencies.md
git commit -m "Remove perccli2 from the build — Phase 2 answers its questions without it"
```

---

### Task 2: `r770-storage-apply.sh` — plan mode, refusals, layout drift guard

**Files:**
- Create: `scripts/r770-storage-apply.sh` (mode 0755)
- Create: `tests/storage-apply.bats`
- Modify: `tests/lint.bats` (new-scripts test), `tests/README.md` (suite table), `README.md` ("What's here" table), `OWNERS.md` (new row)

**Interfaces:**
- Produces: CLI `r770-storage-apply.sh [--plan | --apply --lv NAME | --grow-var]`. Exit 0 = done or nothing to do; exit 1 = refused or failed. Output lines start with `SKIP`, `CREATE`, `GROW`, `REFUSE`, `APPLY`, `DONE` or `FAIL`.
- Produces: env overrides `STORAGE_FSTAB` (default `/etc/fstab`) and `STORAGE_ROOT` (prefix for mount-point directory operations only, default empty).
- Produces: shell functions that Task 3 extends: `layout_row`, `vg_field`, `lv_size`, `lv_fs`, `fstab_has`, `dir_nonempty`, `is_mounted`, `room_reason`, `classify`, `print_cmds`.

- [ ] **Step 1: Write the test file with shims and the plan/refusal/drift tests**

Create `tests/storage-apply.bats`:

```bash
#!/usr/bin/env bats
#
# r770-storage-apply.sh writes filesystems on the R770, so what matters most
# here is the refusals: every one of them must exit non-zero and change nothing.
#
# LVM, blkid, findmnt, mount and systemctl are all stubs backed by a state
# directory ($S). The script sees ONLY the stubs plus a fixed list of real
# tools, so a real LVM on the test host can never answer for the fake VG.
#
#   $S/vg_size, $S/vg_free    GiB, as vgs --units g --nosuffix prints them
#   $S/lv/<name>              "<size_GiB> <fs>"   (fs empty until mkfs)
#   $S/mounted                one mount point per line
#   $S/verify_rc              exit code for `findmnt --verify` (default 0)
#   $S/calls                  every mutating call, one per line

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-storage-apply.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"
    export S="$BATS_TEST_TMPDIR/state"
    export STORAGE_ROOT="$BATS_TEST_TMPDIR/root"
    export STORAGE_FSTAB="$BATS_TEST_TMPDIR/fstab"
    export FAKE_UID=0
    mkdir -p "$BIN" "$REAL" "$S/lv" "$STORAGE_ROOT"
    for t in bash env awk sed grep tr cat cp mkdir ls date head tail rm cmp; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    TEST_PATH="$BIN:$REAL"

    # A VG shaped like discovery found it (GiB; owner: state/BUILD-STATE.md), lv-var 6G.
    echo 7153 > "$S/vg_size"; echo 7004 > "$S/vg_free"
    echo "6 ext4" > "$S/lv/lv-var"
    printf '%s\n' \
        '/dev/disk/by-id/dm-uuid-LVM-root / ext4 defaults 0 1' \
        '/dev/disk/by-id/dm-uuid-LVM-var /var ext4 defaults 0 1' > "$STORAGE_FSTAB"
    cp "$STORAGE_FSTAB" "$BATS_TEST_TMPDIR/fstab.orig"

    stub id        'echo "$FAKE_UID"'
    stub vgs       'case "$*" in *vg_size*) echo "  $(cat "$S/vg_size").00";; *vg_free*) echo "  $(cat "$S/vg_free").00";; *) [ -f "$S/vg_size" ];; esac'
    stub lvs       'for a; do t=$a; done; f="$S/lv/${t#*/}"; [ -f "$f" ] || exit 5; read -r sz _ < "$f"; echo "  ${sz}.00"'
    stub blkid     'k=$2; for a; do d=$a; done; n=${d##*/}; f="$S/lv/$n"; [ -f "$f" ] || exit 2; read -r _ fs < "$f"; [ -n "$fs" ] || exit 2; if [ "$k" = UUID ]; then echo "uuid-$n"; else echo "$fs"; fi'
    stub lvcreate  'echo "lvcreate $*" >> "$S/calls"; while [ $# -gt 0 ]; do case $1 in -n) n=$2; shift;; -L) l=${2%G}; shift;; esac; shift; done; echo "$l" > "$S/lv/$n"'
    stub mkfs.xfs  'echo "mkfs.xfs $*" >> "$S/calls"; n=${1##*/}; read -r sz _ < "$S/lv/$n"; echo "$sz xfs" > "$S/lv/$n"'
    stub mkfs.ext4 'echo "mkfs.ext4 $*" >> "$S/calls"; n=${1##*/}; read -r sz _ < "$S/lv/$n"; echo "$sz ext4" > "$S/lv/$n"'
    stub lvextend  'echo "lvextend $*" >> "$S/calls"; echo "50 ext4" > "$S/lv/lv-var"'
    stub systemctl 'echo "systemctl $*" >> "$S/calls"'
    stub mount     'echo "mount $*" >> "$S/calls"; for a; do t=$a; done; echo "$t" >> "$S/mounted"'
    stub findmnt   'if [ "$1" = --verify ]; then echo "findmnt $*" >> "$S/calls"; exit "$(cat "$S/verify_rc" 2>/dev/null || echo 0)"; fi; for a; do t=$a; done; grep -qxF "$t" "$S/mounted" 2>/dev/null || exit 1; echo "$t"'
}

stub() {  # stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

apply_script() { PATH="$TEST_PATH" "$SCRIPT" "$@"; }

no_mutations() { [ ! -s "$S/calls" ] || { cat "$S/calls"; false; }; }

fstab_unchanged() { cmp "$STORAGE_FSTAB" "$BATS_TEST_TMPDIR/fstab.orig"; }

# ── plan mode ────────────────────────────────────────────────────────────────

@test "plan on the discovered VG proposes the grow and all eight LVs, changes nothing" {
    run apply_script --plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GROW    lv-var"* ]]
    [ "$(grep -c '^CREATE  ' <<< "$output")" -eq 8 ]
    [[ "$output" == *"lvcreate --yes --wipesignatures y -n lv_pcap -L 3328G ubuntu-vg0"* ]]
    no_mutations
    fstab_unchanged
}

@test "no arguments means --plan" {
    run apply_script
    [ "$status" -eq 0 ]
    [[ "$output" == *"== storage plan"* ]]
    no_mutations
}

@test "plan refuses when the layout would breach the 5% reserve floor" {
    echo 6500 > "$S/vg_free"
    run apply_script --plan
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reserve floor"* ]]
    no_mutations
}

# ── refusals common to every mode ────────────────────────────────────────────

@test "refuses to run as a non-root user" {
    FAKE_UID=1000 run apply_script --plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"must run as root"* ]]
    no_mutations
}

@test "refuses when the VG is absent" {
    rm "$S/vg_size"
    run apply_script --plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"VG ubuntu-vg0 not found"* ]]
}

@test "refuses an unknown argument" {
    run apply_script --frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument"* ]]
}

# ── layout drift guard ───────────────────────────────────────────────────────
# buildout §3.2 owns the layout (OWNERS.md). The script carries a copy because
# it runs on an air-gapped host with no repo; this test keeps the copy honest.

@test "the script's LAYOUT matches buildout §3.2 exactly" {
    design="$(awk -F'|' '$2 ~ /^ *lv_/ {
                  name=$2; mp=$3; fs=tolower($4); sz=$5
                  gsub(/[ `*]/, "", name); gsub(/[ `*]/, "", mp); gsub(/[ *]/, "", fs); gsub(/\*/, "", sz)
                  split(sz, p, " "); g = (p[2] == "TiB") ? p[1] * 1024 : p[1]
                  printf "%s %d %s %s\n", name, g, fs, mp }' \
                  "$BATS_TEST_DIRNAME/../docs/plans/r770-network-lab-buildout.md" | sort)"
    script="$(sed -n '/^LAYOUT="/,/^"$/p' "$SCRIPT" | awk 'NF == 4 {print $1, $2, $3, $4}' | sort)"
    echo "design:"; echo "$design"; echo "script:"; echo "$script"
    [ "$(wc -l <<< "$design")" -eq 8 ]
    [ "$design" = "$script" ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `bats tests/storage-apply.bats`
Expected: every test FAILs because the script doesn't exist yet. The drift test fails with an empty `script:` block.

- [ ] **Step 3: Write the script (plan mode plus shared functions)**

Create `scripts/r770-storage-apply.sh` and `chmod 0755` it:

```bash
#!/usr/bin/env bash
#
# r770-storage-apply.sh — Phase 3: create the lab LVs in VG ubuntu-vg0.
#
# Runs ON the R770, as root. It never names a block device: it acts only on
# LVs inside the VG discovery confirmed (state/BUILD-STATE.md).
#
# Design: docs/superpowers/specs/2026-09-23-phase2-3-storage-design.md
# Layout owner: docs/plans/r770-network-lab-buildout.md §3.2. LAYOUT below is a
# permitted copy, because this script runs where the repo does not; the test
# suite fails if the two disagree. Change the design first, then this table.
#
#   --plan              default. Read-only: state, proposed action, exact commands
#   --apply --lv NAME   create, format, fstab and mount ONE LV
#   --grow-var          grow lv-var to 50 GiB online. NOT reversible online.
#
#   0  done, or nothing to do
#   1  refused (nothing changed) or failed (fstab restored; see output)
#
# Test overrides: STORAGE_FSTAB, STORAGE_ROOT (prefix for mount-point dirs).
set -uo pipefail

VG=ubuntu-vg0
FSTAB="${STORAGE_FSTAB:-/etc/fstab}"
ROOT="${STORAGE_ROOT:-}"
VAR_LV=lv-var
VAR_TARGET_G=50
MIN_FREE_PCT=5

# name        GiB  fs   mount point
LAYOUT="
lv_docker     250  ext4 /var/lib/docker
lv_pcap      3328  xfs  /data/pcap
lv_index     1024  xfs  /data/index
lv_staging    250  xfs  /data/staging
lv_vms        500  xfs  /srv/vms
lv_gns3       400  xfs  /srv/gns3
lv_work       200  xfs  /srv/work
lv_backup     250  xfs  /srv/backup
"

die() { printf 'REFUSE  %s\n' "$*"; exit 1; }

layout_row() { awk -v n="$1" '$1 == n' <<< "$LAYOUT"; }

vg_field() {  # vg_field size|free -> GiB
    vgs --noheadings --nosuffix --units g -o "vg_$1" "$VG" 2>/dev/null | tr -d ' '
}

lv_size() {  # lv_size NAME -> GiB, empty if the LV does not exist
    lvs --noheadings --nosuffix --units g -o lv_size "$VG/$1" 2>/dev/null | tr -d ' '
}

lv_fs() { blkid -s TYPE -o value "/dev/$VG/$1" 2>/dev/null; }

fstab_has() { awk -v m="$1" '$1 !~ /^#/ && $2 == m {f = 1} END {exit !f}' "$FSTAB"; }

dir_nonempty() { [ -d "$ROOT$1" ] && [ -n "$(ls -A "$ROOT$1")" ]; }

is_mounted() { findmnt -n "$1" >/dev/null 2>&1; }

ge() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a >= b)}'; }

sub() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a - b}'; }

room_reason() {  # room_reason FREE NEED VGSIZE -> empty when there is room
    awk -v f="$1" -v n="$2" -v s="$3" -v p="$MIN_FREE_PCT" 'BEGIN {
        if (f < n)                printf "VG free %.2fG < %.2fG needed", f, n
        else if (f - n < s*p/100) printf "would leave %.2fG free, under the %d%% reserve floor (%.2fG)", f - n, p, s*p/100
    }'
}

# classify NAME SIZE FS MP FREE VGSIZE -> SKIP | CREATE | REFUSE: <reason>
classify() {
    local name=$1 size=$2 fs=$3 mp=$4 free=$5 vgsize=$6 cur curfs reason
    cur=$(lv_size "$name")
    if [ -n "$cur" ]; then
        curfs=$(lv_fs "$name")
        if ! awk -v a="$cur" -v b="$size" 'BEGIN {exit !(a == b)}' || [ "$curfs" != "$fs" ]; then
            echo "REFUSE: $VG/$name exists as ${cur}G ${curfs:-unformatted}; layout wants ${size}G $fs"
        elif is_mounted "$mp" && fstab_has "$mp"; then
            echo "SKIP"
        else
            echo "REFUSE: $VG/$name exists but is not both mounted at $mp and in fstab — partially applied; inspect, then remove with: umount $mp; lvremove $VG/$name"
        fi
        return
    fi
    if is_mounted "$mp";   then echo "REFUSE: $mp is already a mount point"; return; fi
    if dir_nonempty "$mp"; then echo "REFUSE: $mp exists and is not empty"; return; fi
    if fstab_has "$mp";    then echo "REFUSE: $FSTAB already has an entry for $mp"; return; fi
    reason=$(room_reason "$free" "$size" "$vgsize")
    if [ -n "$reason" ]; then echo "REFUSE: $reason"; return; fi
    echo "CREATE"
}

print_cmds() {  # print_cmds NAME SIZE FS MP
    printf '        %s\n' \
        "lvcreate --yes --wipesignatures y -n $1 -L ${2}G $VG" \
        "mkfs.$3 /dev/$VG/$1" \
        "mkdir -p $4" \
        "cp -p $FSTAB $FSTAB.pre-$1-<timestamp>" \
        "echo 'UUID=<uuid of /dev/$VG/$1> $4 $3 noatime,nofail 0 2' >> $FSTAB" \
        "systemctl daemon-reload" \
        "findmnt --verify --tab-file $FSTAB" \
        "mount --fstab $FSTAB $4"
}

plan() {
    local free vgsize refused=0 cur delta reason name size fs mp verdict
    free=$(vg_field free); vgsize=$(vg_field size)
    echo "== storage plan: VG $VG size ${vgsize}G, free ${free}G =="

    # lv-var first: it is the first thing applied.
    cur=$(lv_size "$VAR_LV")
    if [ -z "$cur" ]; then
        echo "REFUSE  $VAR_LV not found in $VG"; refused=1
    elif ge "$cur" "$VAR_TARGET_G"; then
        echo "SKIP    $VAR_LV — already ${cur}G"
    else
        delta=$(sub "$VAR_TARGET_G" "$cur")
        reason=$(room_reason "$free" "$delta" "$vgsize")
        if [ -n "$reason" ]; then
            echo "REFUSE  $VAR_LV — $reason"; refused=1
        else
            echo "GROW    $VAR_LV ${cur}G -> ${VAR_TARGET_G}G  (online; NOT reversible online)"
            printf '        %s\n' "lvextend --resizefs -L ${VAR_TARGET_G}G $VG/$VAR_LV"
            free=$(sub "$free" "$delta")
        fi
    fi

    while read -r name size fs mp; do
        [ -n "$name" ] || continue
        verdict=$(classify "$name" "$size" "$fs" "$mp" "$free" "$vgsize")
        case "$verdict" in
            SKIP)   echo "SKIP    $name — already applied" ;;
            CREATE) echo "CREATE  $name ${size}G $fs $mp"
                    print_cmds "$name" "$size" "$fs" "$mp"
                    free=$(sub "$free" "$size") ;;
            *)      echo "REFUSE  $name — ${verdict#REFUSE: }"; refused=1 ;;
        esac
    done <<< "$LAYOUT"

    echo "== VG free after this plan: ${free}G of ${vgsize}G =="
    return "$refused"
}

MODE=plan; LV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plan)     MODE=plan ;;
        --apply)    MODE=apply ;;
        --lv)       LV="${2:-}"; shift ;;
        --grow-var) MODE=grow ;;
        *)          die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "must run as root (LVM and $FSTAB)"
vgs "$VG" >/dev/null 2>&1 || die "VG $VG not found — discovery says it exists; stop and re-run discovery"

case "$MODE" in
    plan)  plan; exit $? ;;
    *)     die "mode $MODE not implemented yet" ;;
esac
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bats tests/storage-apply.bats`
Expected: all 7 PASS.

- [ ] **Step 5: Register the script**

`tests/lint.bats`, first test:
```bash
    run shellcheck scripts/r770-bundle.sh scripts/r770-storage-apply.sh tests/run.sh
```

`README.md` "What's here" table: add this row after the `scripts/r770-precheck.sh` row:
```
| `scripts/r770-storage-apply.sh` | Phase 3 — creates the lab LVs in `ubuntu-vg0`, one at a time (`--plan` default, `--apply --lv NAME`, `--grow-var`); run on the R770 as root |
```

`tests/README.md` suite table: add
```
| `storage-apply.bats` | `r770-storage-apply.sh` against stubbed LVM/mount tools: plan is read-only, every refusal changes nothing, apply touches exactly one LV and restores fstab on failure, and the script's layout matches buildout §3.2 |
```

`OWNERS.md` table: add after the free-extent row:
```
| LV layout (names, sizes, filesystems, mount points) | `docs/plans/r770-network-lab-buildout.md` §3.2 | `scripts/r770-storage-apply.sh` `LAYOUT` — it runs on the air-gapped host where the repo does not | yes — `tests/storage-apply.bats` compares the two |
```

- [ ] **Step 6: Run the full suite**

Run: `./tests/run.sh`
Expected: all green, including lint on the new script. Fix any shellcheck finding in the script. Don't add exclusions.

- [ ] **Step 7: Commit**

```bash
git add scripts/r770-storage-apply.sh tests/storage-apply.bats tests/lint.bats tests/README.md README.md OWNERS.md
git commit -m "Add r770-storage-apply.sh plan mode — read-only Phase 3 plan with refusals and a layout drift guard"
```

---

### Task 3: `r770-storage-apply.sh` — `--apply --lv` and `--grow-var`

**Files:**
- Modify: `scripts/r770-storage-apply.sh` (add `fail_after_lv`, `apply_lv`, `grow_var`; replace the `case "$MODE"` block)
- Test: `tests/storage-apply.bats` (append)

**Interfaces:**
- Consumes: `layout_row`, `vg_field`, `lv_size`, `classify`, `room_reason`, `ge`, `sub`, `is_mounted`, `die` from Task 2.
- Produces: `apply_lv NAME`, `grow_var`. Output lines start `APPLY`, `DONE`, `FAIL`, `GROW` or `SKIP`.

- [ ] **Step 1: Append the failing tests** to `tests/storage-apply.bats`:

```bash
# ── --apply --lv ─────────────────────────────────────────────────────────────

@test "--apply needs --lv" {
    run apply_script --apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"--apply needs --lv NAME"* ]]
    no_mutations
}

@test "--apply refuses a name that is not in the layout" {
    run apply_script --apply --lv lv_bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"no LV named 'lv_bogus'"* ]]
    no_mutations
}

@test "--apply creates exactly one LV, one fstab line, and mounts it" {
    run apply_script --apply --lv lv_work
    echo "$output"; cat "$S/calls"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^lvcreate ' "$S/calls")" -eq 1 ]
    grep -qxF 'lvcreate --yes --wipesignatures y -n lv_work -L 200G ubuntu-vg0' "$S/calls"
    grep -qxF 'mkfs.xfs /dev/ubuntu-vg0/lv_work' "$S/calls"
    grep -qxF 'mount --fstab '"$STORAGE_FSTAB"' /srv/work' "$S/calls"
    [ "$(diff "$BATS_TEST_TMPDIR/fstab.orig" "$STORAGE_FSTAB" | grep -c '^>')" -eq 1 ]
    tail -1 "$STORAGE_FSTAB" | grep -qxF 'UUID=uuid-lv_work /srv/work xfs noatime,nofail 0 2'
    [ -d "$STORAGE_ROOT/srv/work" ]
    ls "$STORAGE_FSTAB".pre-lv_work-* >/dev/null
    [[ "$output" == *"DONE    lv_work"* ]]
}

@test "lv_docker gets ext4" {
    run apply_script --apply --lv lv_docker
    [ "$status" -eq 0 ]
    grep -qxF 'mkfs.ext4 /dev/ubuntu-vg0/lv_docker' "$S/calls"
    tail -1 "$STORAGE_FSTAB" | grep -qxF 'UUID=uuid-lv_docker /var/lib/docker ext4 noatime,nofail 0 2'
}

@test "a re-run after success is a no-op" {
    apply_script --apply --lv lv_work
    : > "$S/calls"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP    lv_work — already applied"* ]]
    no_mutations
}

@test "a failed fstab verify restores fstab and names the lvremove" {
    echo 1 > "$S/verify_rc"
    run apply_script --apply --lv lv_work
    echo "$output"
    [ "$status" -eq 1 ]
    fstab_unchanged
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"lvremove ubuntu-vg0/lv_work"* ]]
    ! grep -q '^mount ' "$S/calls"
}

@test "refuses an existing LV of a different size" {
    echo "100 xfs" > "$S/lv/lv_work"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 1 ]
    [[ "$output" == *"exists as 100.00G xfs"* ]]
    no_mutations
}

@test "refuses a matching LV that is not mounted (partial apply)" {
    echo "200 xfs" > "$S/lv/lv_work"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 1 ]
    [[ "$output" == *"partially applied"* ]]
    no_mutations
}

@test "refuses a non-empty mount point" {
    mkdir -p "$STORAGE_ROOT/srv/work"; touch "$STORAGE_ROOT/srv/work/keep"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 1 ]
    [[ "$output" == *"/srv/work exists and is not empty"* ]]
    no_mutations
}

@test "refuses a mount point that is already mounted" {
    echo /srv/work > "$S/mounted"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 1 ]
    [[ "$output" == *"already a mount point"* ]]
    no_mutations
}

@test "refuses when fstab already has the mount point" {
    echo 'UUID=other /srv/work xfs defaults 0 2' >> "$STORAGE_FSTAB"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 1 ]
    [[ "$output" == *"already has an entry for /srv/work"* ]]
    no_mutations
}

@test "refuses when VG free is below the LV size" {
    echo 100 > "$S/vg_free"
    run apply_script --apply --lv lv_work
    [ "$status" -eq 1 ]
    [[ "$output" == *"VG free 100.00G < 200.00G needed"* ]]
    no_mutations
}

# ── --grow-var ───────────────────────────────────────────────────────────────

@test "--grow-var extends lv-var to 50G online, and only that" {
    run apply_script --grow-var
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$S/calls")" = "lvextend --resizefs -L 50G ubuntu-vg0/lv-var" ]
    fstab_unchanged
}

@test "--grow-var is a no-op once lv-var is 50G" {
    echo "50 ext4" > "$S/lv/lv-var"
    run apply_script --grow-var
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP    lv-var"* ]]
    no_mutations
}

@test "--grow-var respects the reserve floor" {
    echo 380 > "$S/vg_free"
    run apply_script --grow-var
    [ "$status" -eq 1 ]
    [[ "$output" == *"reserve floor"* ]]
    no_mutations
}
```

(Reserve-floor arithmetic: 5 % of 7153 is 357.65. Growing by 44 from 380 leaves 336, which is below that floor.)

- [ ] **Step 2: Run them and confirm they fail**

Run: `bats tests/storage-apply.bats`
Expected: the 7 Task 2 tests PASS. All 15 new ones FAIL: the Task 2 script dies with `mode apply not implemented yet` / `mode grow not implemented yet`, which fails every status or message assertion.

- [ ] **Step 3: Implement.** In `scripts/r770-storage-apply.sh`, insert the following directly after the `plan()` function and before `MODE=plan; LV=""`:

```bash
fail_after_lv() {  # fail_after_lv NAME MESSAGE
    printf 'FAIL    %s\n        the empty LV was left in place; to remove it: lvremove %s/%s\n' "$2" "$VG" "$1"
    exit 1
}

apply_lv() {
    local row name size fs mp verdict uuid backup
    row=$(layout_row "$1")
    [ -n "$row" ] || die "no LV named '$1' in the layout (names: $(awk 'NF {printf "%s ", $1}' <<< "$LAYOUT"))"
    read -r name size fs mp <<< "$row"
    verdict=$(classify "$name" "$size" "$fs" "$mp" "$(vg_field free)" "$(vg_field size)")
    case "$verdict" in
        SKIP)    echo "SKIP    $name — already applied"; return 0 ;;
        REFUSE*) die "$name — ${verdict#REFUSE: }" ;;
    esac

    echo "APPLY   $name ${size}G $fs $mp"
    lvcreate --yes --wipesignatures y -n "$name" -L "${size}G" "$VG" \
        || die "lvcreate failed — nothing else changed"
    "mkfs.$fs" "/dev/$VG/$name" || fail_after_lv "$name" "mkfs.$fs failed"
    mkdir -p "$ROOT$mp"         || fail_after_lv "$name" "mkdir $mp failed"
    uuid=$(blkid -s UUID -o value "/dev/$VG/$name")
    [ -n "$uuid" ]              || fail_after_lv "$name" "no filesystem UUID on /dev/$VG/$name"

    backup="$FSTAB.pre-$name-$(date +%Y%m%dT%H%M%S)"
    cp -p "$FSTAB" "$backup"    || fail_after_lv "$name" "could not back up $FSTAB"
    printf 'UUID=%s %s %s noatime,nofail 0 2\n' "$uuid" "$mp" "$fs" >> "$FSTAB"
    systemctl daemon-reload
    if ! findmnt --verify --tab-file "$FSTAB" || ! mount --fstab "$FSTAB" "$mp"; then
        cp -p "$backup" "$FSTAB"
        systemctl daemon-reload
        fail_after_lv "$name" "fstab verify or mount failed — $FSTAB restored from $backup"
    fi
    is_mounted "$mp" || fail_after_lv "$name" "mount reported success but $mp is not mounted"
    echo "DONE    $name mounted at $mp (fstab backup: $backup)"
    findmnt -n -o SOURCE,FSTYPE,SIZE,OPTIONS "$mp" || true   # evidence only
}

grow_var() {
    local cur free vgsize delta reason
    cur=$(lv_size "$VAR_LV")
    [ -n "$cur" ] || die "$VAR_LV not found in $VG"
    if ge "$cur" "$VAR_TARGET_G"; then echo "SKIP    $VAR_LV — already ${cur}G"; return 0; fi
    free=$(vg_field free); vgsize=$(vg_field size)
    delta=$(sub "$VAR_TARGET_G" "$cur")
    reason=$(room_reason "$free" "$delta" "$vgsize")
    [ -z "$reason" ] || die "$VAR_LV — $reason"
    echo "GROW    $VAR_LV ${cur}G -> ${VAR_TARGET_G}G  (online; NOT reversible online)"
    lvextend --resizefs -L "${VAR_TARGET_G}G" "$VG/$VAR_LV" || die "lvextend failed"
    findmnt -n -o SOURCE,FSTYPE,SIZE /var || true   # evidence only
}
```

Replace the final `case "$MODE"` block with:

```bash
case "$MODE" in
    plan)  plan; exit $? ;;
    apply) [ -n "$LV" ] || die "--apply needs --lv NAME"; apply_lv "$LV" ;;
    grow)  grow_var ;;
esac
```

The trailing `findmnt` lines are only there for evidence, and `|| true` keeps their exit status out of the script's own exit status.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bats tests/storage-apply.bats`
Expected: all 22 PASS.

- [ ] **Step 5: Run the full suite**

Run: `./tests/run.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-storage-apply.sh tests/storage-apply.bats
git commit -m "r770-storage-apply.sh: --apply one LV at a time with fstab rollback, and --grow-var"
```

---

### Task 4: Re-gate key custody onto Phase 10 in the build tracker

**Files:**
- Modify: `state/BUILD-STATE.md` (Phase 10 row, unknowns table, log)
- Modify: `docs/plans/r770-network-lab-buildout.md` §3.2 gate blockquote (l.141)

**Interfaces:** Task 5 writes the verdicts that these rows point to.

- [ ] **Step 1: Edit BUILD-STATE.md**

Phase 10 row, *Depends on* column: `6,9,3` → `6,9,3 + PERC key custody RECORDED (Phase 2)`.

Unknowns row `Actual PERC model/firmware/TRIM`: status becomes
`**RESOLVED for model + firmware** (H975i Front, 8.14.0.0.28-40); TRIM/discard answered OS-side in Phase 2 (\`lsblk -D\`, sysfs) — perccli removed from the build 2026-09-23`

Unknowns row `PERC encryption key custody (LKM vs SEKM, escrow)`: status becomes
`**OPEN** — operator attestation in Phase 2 (\`inventory/r770-phase2-assessment.md\`). **Gates Phase 10** (first case data), not Phase 3`

Add a log entry at the top of `## Log`:
```
- 2026-09-23 · Planning · Phase 2/3 designed (`docs/superpowers/specs/2026-09-23-phase2-3-storage-design.md`). Phase 2 is assess-only with no iDRAC queries: key custody by operator attestation, NVMe x2 from Dell documentation, TRIM from OS-side checks, firmware delta from the 2026-09-03 export. perccli2 removed from the build and the supply lists. Key custody now gates Phase 10 instead of Phase 3. Phase 3 applies through the new `scripts/r770-storage-apply.sh` (plan by default, one LV per apply, layout drift-tested against buildout §3.2). · `work/plans/active/2026-09-23-phase2-3-storage.md`
```

Leave `inventory/r770-phase2-assessment.md` out of any path the references test checks until Task 5 creates it. `tests/references.bats` fails if a concrete `state/…` path named in BUILD-STATE doesn't exist. The unknowns-row text above uses `inventory/…` without the `state/` prefix, so the checker's `(state|docs|scripts|tests|work)/` pattern doesn't pick it up. Keep it that way.

- [ ] **Step 2: Edit the buildout gate note (l.141)**

```
> **Gate before any of this runs:** the PERC reports `Encryption mode: Enabled` with a `Security Key Assigned`. Establish whether that is LKM or SEKM and where the key is escrowed **before** case data lands on these volumes — losing the key loses the VD. See §12.
```
→
```
> **Gate before case data lands (Phase 10, not Phase 3):** the PERC reports `Encryption mode: Enabled` with a `Security Key Assigned`. The operator attests LKM vs SEKM and where the key is escrowed in Phase 2; Phase 10 does not start until that is recorded. Creating these empty LVs is not gated on it — losing the key loses the VD either way, and empty LVs cost minutes to recreate. See §12.
```

- [ ] **Step 3: Run the full suite**

Run: `./tests/run.sh`
Expected: all green. `references.bats` and `owners.bats` are the ones to watch, because the free-extent figure lives in these files. Don't change it.

- [ ] **Step 4: Commit**

```bash
git add state/BUILD-STATE.md docs/plans/r770-network-lab-buildout.md
git commit -m "Gate PERC key custody on Phase 10, not Phase 3; record the Phase 2/3 design"
```

---

### Task 5: Execute Phase 2 — assessment (read-only; nothing on the R770 changes)

> **Amended 2026-09-24 (operator): no iDRAC or PERC work.** Skip Step 5 (firmware delta) and Step 6 (key custody) — both dropped. Step 4 (NVMe x2) is answered BY DESIGN from Dell's PERC13/PERC12 guide. Step 3 records the virtual-media noise only; there is no detach action. The operator runs the R770 commands themselves and pastes the output (no SSH from this session). The report keeps rows 1, 4 and 5 marked DROPPED / DOCUMENTED with this reason. Phase 2 is VERIFIED when items 2 and 3 have verdicts. See the spec's 2026-09-24 amendment.

**Files:**
- Create: `state/inventory/r770-phase2-assessment.md`
- Modify: `state/BUILD-STATE.md` (Phase 2 status, unknowns, log)

**Interfaces:** Produces the item 3 verdict (`ADVERTISED` / `NOT ADVERTISED`), which Task 6 Step 7 reads, and the item 1 verdict, which gates Phase 10.

- [ ] **Step 1: Confirm the SSH target.** BUILD-STATE says the host calls itself `testbed` at 10.10.10.31 and that the operator's alias still needs confirming. Ask the operator for the alias. Then run `ssh <alias> 'hostname; cat /sys/class/dmi/id/product_serial 2>/dev/null || sudo cat /sys/class/dmi/id/product_serial'`
Expected: `testbed` and `G8WFGH4`. On any mismatch, stop.

- [ ] **Step 2: Item 3 (TRIM), read-only.** Re-confirm the VD device first. Don't assume `/dev/sda`:

```bash
ssh <alias> 'lsblk -d -o NAME,MODEL,SIZE,TYPE; pvs --noheadings -o pv_name,vg_name 2>/dev/null || sudo pvs --noheadings -o pv_name,vg_name'
```
Expected: the `ubuntu-vg0` PV sits on a partition of the PERC VD device, which discovery recorded as `/dev/sda3`. Call that disk `<vd>`. Then:
```bash
ssh <alias> 'lsblk -D /dev/<vd>; for f in discard_granularity discard_max_bytes discard_max_hw_bytes; do printf "%s=" $f; cat /sys/block/<vd>/queue/$f; done'
```
Verdict: `ADVERTISED` if `discard_max_bytes` > 0 and `DISC-MAX` isn't `0B`; otherwise `NOT ADVERTISED`. Save the raw output.

- [ ] **Step 3: Item 5 (virtual-media noise), read-only**

```bash
ssh <alias> 'lsblk -o NAME,TRAN,MODEL,SIZE,TYPE; sudo journalctl -k -b --no-pager | grep -cE "sdb|sr0"; sudo journalctl -k -b --no-pager | grep -E "sdb|sr0" | tail -20'
```
Record the count, and which device(s) are iDRAC virtual media (TRAN `usb`, model `Virtual …`). Verdict: documented, plus a manual operator action to detach it in the iDRAC UI (Configuration → Virtual Media).

- [ ] **Step 4: Item 2 (NVMe x2), staging-side research.** Search Dell documentation for the R770 16-bay E3.S NVMe backplane and the PERC H975i Front lane allocation per drive. Useful queries: "PowerEdge R770 E3.S backplane x2", "PERC H975i Front NVMe lanes per drive", "R770 technical guide storage". Cite the URL and quote the sentence. Verdict: `BY DESIGN` (with the source), `SUSPECT` (no source, or a source that says x4), or `UNRESOLVED`.

- [ ] **Step 5: Item 4 (firmware delta), staging-side research.** For service tag `G8WFGH4`, look up Dell's current releases for BIOS, iDRAC/LC, PERC H975i Front, the backplane, Broadcom BCM57412/57414 and the PSU. Compare each against `state/inventory/r770-idrac-inventory-G8WFGH4.md`. Record installed / latest / release date / Dell criticality (Urgent / Recommended / Optional) / URL. If you can't reach a Dell page, say so for that row. Don't guess a version.

- [ ] **Step 6: Item 1 (key custody), operator attestation.** Ask the operator, with AskUserQuestion or in plain text:
  1. LKM (Local Key Management) or SEKM?
  2. Who holds the passphrase or key ID (a role, not a name)?
  3. Where is it escrowed (a location description only; **never the key or passphrase**)?
  Verdict: `RECORDED` if all three are answered, otherwise `UNKNOWN`.

- [ ] **Step 7: Write the report** at `state/inventory/r770-phase2-assessment.md`:

```markdown
# Phase 2 assessment — R770 `G8WFGH4` — <date>

Assess-only (spec: docs/superpowers/specs/2026-09-23-phase2-3-storage-design.md). Nothing on the R770 was changed. No iDRAC queries.

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | PERC key custody | <RECORDED/UNKNOWN> | operator attestation <date>: mode <LKM/SEKM>, holder <role>, escrow <location description> |
| 2 | NVMe link x2 of x4 | <BY DESIGN/SUSPECT/UNRESOLVED> | <source URL + quote> |
| 3 | TRIM / discard | <ADVERTISED/NOT ADVERTISED> | raw output below |
| 4 | Firmware delta | advisory | table below |
| 5 | iDRAC virtual-media noise | documented; operator action: detach in iDRAC UI | raw output below |

## Raw output
<paste each command and its full output, with the command line>

## Firmware delta
| Component | Installed | Latest | Released | Dell criticality | Source |
|---|---|---|---|---|---|
```

Fill in every `<…>` with the real values. None may remain in the committed file.

- [ ] **Step 8: Update BUILD-STATE.md.** Phase 2 status: `APPLIED`, evidence `inventory/r770-phase2-assessment.md`. Move it to `VERIFIED` only if items 2–5 all have a verdict. Update the three PERC unknowns rows with their verdicts. Add a log entry with the date and a summary of the verdicts. If item 2 is `SUSPECT`, add a new unknowns row: `NVMe x2 — gated follow-up (reseat / Dell ticket)`.

- [ ] **Step 9: Run the suite and commit**

```bash
./tests/run.sh
git add state/inventory/r770-phase2-assessment.md state/BUILD-STATE.md
git commit -m "Phase 2 assessment: key custody, NVMe link width, TRIM, firmware delta"
```

---

### Task 6: Execute Phase 3 — storage (GATED; writes filesystems)

> **Superseded 2026-09-24** by `work/plans/active/2026-09-24-bundle-to-r770.md` Tasks 5–6 (operator-run via `scripts/r770-phase3-run.sh`, with a working tmux + tee procedure). Do not execute this task.

**Files:**
- Create: `state/inventory/r770-phase3-storage-<date>.md`
- Modify: `state/BUILD-STATE.md`

**Interfaces:** Consumes the Task 3 script and the Task 5 item 3 verdict.

- [ ] **Step 1: Deliver the script.** The R770 has no internet and no repo checkout. Copy the one reviewed script over the existing SSH session and record its hash on both sides:

```bash
sha256sum scripts/r770-storage-apply.sh
scp scripts/r770-storage-apply.sh <alias>:/tmp/r770-storage-apply.sh
ssh <alias> 'sha256sum /tmp/r770-storage-apply.sh'
```
Expected: identical hashes.

- [ ] **Step 2: Plan (read-only)**

```bash
ssh <alias> 'sudo bash /tmp/r770-storage-apply.sh --plan'
```
Expected: exit 0, `GROW lv-var`, 8 × `CREATE`, VG free after the plan ≈ 758G of ≈ 7153G. Save the full output as "plan-before".

- [ ] **Step 3: Safety review.** Dispatch the `safety-reviewer` agent with the plan-before output, the script, and the rollback section of the spec. Resolve every finding before going on.

- [ ] **Step 4: Operator gate (CLAUDE.md rule 3).** Show the operator, all at once:
  - **What changes:** `lv-var` 6G → 50G; 8 new LVs; 8 new fstab lines.
  - **Data that could be lost:** none; all targets are new, empty LVs from free extents.
  - **Device:** VG `ubuntu-vg0` on the PERC VD.
  - **Current vs proposed:** the plan-before output.
  - **Rollback:** the spec's per-LV rollback, and the statement that the `lv-var` grow is not reversible online.

  Get explicit confirmation. Don't go on without it.

- [ ] **Step 5: Grow /var.** Run inside `tmux new -s phase3` on the R770 so an SSH drop cannot interrupt a run between the fstab append and its verify:

```bash
ssh <alias> 'tmux new -d -s phase3 "sudo bash /tmp/r770-storage-apply.sh --grow-var; df -h /var"' && ssh <alias> 'tmux attach -t phase3'
```
Expected: `GROW` then `/var` ≈ 50G. Save the output.

- [ ] **Step 6: Apply each LV, one at a time, `lv_pcap` last.** Also run inside `tmux new -s phase3` on the R770 (or re-attach to the Step 5 session) so an SSH drop cannot interrupt a run between the fstab append and its verify. For each of `lv_docker lv_index lv_staging lv_vms lv_gns3 lv_work lv_backup lv_pcap`:

```bash
ssh <alias> 'tmux new -d -s phase3 "sudo bash /tmp/r770-storage-apply.sh --apply --lv <name>"' && ssh <alias> 'tmux attach -t phase3'
```
Expected: `DONE <name> mounted at <mp>`. Save each transcript. On any `FAIL` or `REFUSE`, stop, save the output, and follow the systematic-debugging skill. Don't retry blindly.

- [ ] **Step 7: TRIM timer, according to the Task 5 item 3 verdict.** If `ADVERTISED`:
```bash
ssh <alias> 'sudo systemctl enable --now fstrim.timer && systemctl status fstrim.timer --no-pager'
```
If `NOT ADVERTISED`: don't enable it, and write "fstrim.timer left disabled — VD does not advertise discard" in the evidence file.

- [ ] **Step 8: Verify**

```bash
ssh <alias> 'sudo bash /tmp/r770-storage-apply.sh --plan; sudo findmnt --verify; df -h /var /var/lib/docker /data/* /srv/*; sudo vgs ubuntu-vg0'
```
Expected: every row `SKIP`, `findmnt --verify` clean, sizes as laid out. Then dispatch `validation-runner` for the storage area.

- [ ] **Step 9: Reboot test at a time the operator chooses.** Confirm with the operator first. After the reboot, re-run Step 8's command. Every mount must come back.

- [ ] **Step 10: Record and commit.** Write `state/inventory/r770-phase3-storage-<date>.md` containing plan-before, the grow and each apply transcript, the TRIM decision, the Step 8 output, the validation-runner result and the reboot result. In BUILD-STATE, set Phase 3 to `APPLIED` after Step 8 and `VERIFIED` after Step 9, and add a log entry. Move this plan with `git mv work/plans/active/2026-09-23-phase2-3-storage.md work/plans/archive/`. Then change every `work/plans/active/2026-09-23-phase2-3-storage.md` in `state/BUILD-STATE.md` to the archive path, because `tests/references.bats` fails on a dangling path under `state/`.

```bash
./tests/run.sh
git add state/ work/plans/
git commit -m "Phase 3 storage applied and verified on the R770"
```
