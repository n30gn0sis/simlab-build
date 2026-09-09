# OWNERS

One owner per fact. Every other place in the repo that needs the fact links
to its owner instead of restating the value. Restating instead of linking is
exactly how the cadvisor pin went stale, how a Malcolm release six days newer
than the manifest got recorded as "still current," and how a bundle-size
retention estimate drifted 10x from measured reality — three incidents this
registry exists to stop from happening a fourth time.

Enforced by `tests/owners.bats`. If a check there fails, it is naming a file
that restated a fact instead of referencing its owner — fix the file, don't
weaken the check.

**A registry that overclaims is worse than none**, because it tells the reader
not to look. Where a second statement of a fact is legitimate, the row below
**names it**. Where a row says "sole", there is genuinely nowhere else.

| Fact | Owner | Permitted restatements | Enforced |
|---|---|---|---|
| Version pins — every value set in the `# ── pins: review each refresh cycle ──` block of `scripts/r770-offline-fetch.sh` (enumerated below) | `scripts/r770-offline-fetch.sh` pin block | none (sole) | yes — `tests/owners.bats` |
| The verify command | `scripts/r770-bundle.sh` | none (sole); every operational route must *reference* it by name | yes — `tests/no-legacy-manifest.bats` asserts the reference exists in each route |
| Hardware of record, phase status, unknowns | `state/BUILD-STATE.md` | `PRD.md` §7 and §11 · `docs/plans/r770-network-lab-buildout.md` §2, §3, §12 — see "Hardware of record" below | partly — the free-extent figure only |
| Free-extent capacity in VG `ubuntu-vg0` | `state/BUILD-STATE.md` (hardware of record) | `PRD.md` · `docs/plans/r770-network-lab-buildout.md` §3 | yes — two checks in `tests/owners.bats` |
| Bundle sizes, file counts and cycle history | `state/inventory/bundles.md` | none (sole) | partly — the retention-estimate sizes only |
| Decisions of record (staging host, OS, transfer media, cadence, pin policy) | `docs/plans/r770-dependency-manifest.md` §0 | `CLAUDE.md` "Decisions of record" · `PRD.md` §6 — see "Decisions of record" below | partly — the RHEL/Ubuntu staging-host fact only |
| Success criteria | `PRD.md` §10 | none (sole) | no |

## Hardware of record — why two restatements are permitted

`state/BUILD-STATE.md` is the measured inventory and the only place a *new*
hardware fact may be recorded. Two documents legitimately state hardware
alongside it, and pretending otherwise would be a false claim:

- **`PRD.md`** is a requirements document. Requirements are written *against* a
  chassis, and §7 (architecture) and §11 (risks) are unreadable without naming
  the properties that drive them. §4 no longer restates the inventory — it is a
  pointer to the owner, which is what the restructure spec required.
- **`docs/plans/r770-network-lab-buildout.md`** is the authoritative technical
  design. Its §3 derives the LV layout arithmetically from the free-extent
  figure; a design that cannot show its own arithmetic is not a design.

What is *not* permitted anywhere: hardware values inside agent prompts under
`.claude/`. An agent prompt that carries a number ships a stale copy of it to
every future session. `.claude/agents/discovery-analyst.md` was one such copy
and now points at the owner.

### The free-extent figure is the one that already drifted

Drift incident #3 was this figure recorded in TB in `state/BUILD-STATE.md` where
the measured figure is in TiB — a ~600 GiB error in the file `CLAUDE.md` calls
the single source of truth. It was live in five files with **no test at all**,
which is how it drifted. Two checks now cover it:

1. It may appear only in the owner and the two permitted restatements above.
   Anywhere else fails.
2. Every occurrence must be **byte-identical to the owner's form**. The owner's
   value is read out of `state/BUILD-STATE.md` at test time and never spelled
   out in the test — a test that hard-codes the value becomes copy N+1 of the
   fact it is guarding.

Check 2 is the one that would have caught the original incident.

## Decisions of record — why `CLAUDE.md` restates them

`docs/plans/r770-dependency-manifest.md` §0 is the owner: a decision is changed
there, with its date and the operator's approval. But:

- **`CLAUDE.md`** is agent instruction and is **deliberately self-contained** —
  it is loaded automatically at session start and an agent must not have to open
  a plan document to learn that OVS is deferred or that grafana is held below
  13.x. Its "Decisions of record" paragraph restates every decision on purpose.
- **`PRD.md` §6** records the non-goals as product scope. `CLAUDE.md` itself
  instructs that a change be recorded in *both* `PRD.md` §6 and manifest §0.

Only one of these facts is mechanically enforced (no document may call the
staging host RHEL — the specific drift that occurred). The rest rely on the
`CLAUDE.md` instruction to update all three places together. That is a known
gap, recorded here rather than hidden by a row that claims sole ownership.

## Excluded trees

`tests/owners.bats` passes two git pathspecs to every content check. Both are
deliberate; neither was disclosed before, and one of them was far too wide.

| Excluded | Why |
|---|---|
| `state/` | **Append-only evidence.** A report records what a command printed on a date; rewriting it to point at an owner would falsify the evidence. The owners of two facts (`state/BUILD-STATE.md`, `state/inventory/bundles.md`) also live here, so they must be exempt from their own checks. |
| `work/plans/archive/` | **Frozen history.** An executed plan records the pins and counts that were current when it ran. |

`work/plans/active/` is **not** excluded, and must not be. The exclusion used to
be a wholesale `':!work/'`, which hid live operational content: a live plan
stated a bundle file count one lower than its owner, and hard-coded the Malcolm
pin into an operator command —

```
unzip -q ~/r770/bundle-20260908/malcolm/malcolm-<pin>-docker_install.zip
```

— which breaks at the air gap on the next pin bump, where there is no way to
look the version up. That command now uses a glob. Excluding live plans from
the pin guard is precisely what let the drift happen.

One further exclusion applies to the free-extent checks **only**:
`docs/superpowers/specs/`. The approved restructure spec quotes both the wrong
and the right value verbatim, as the evidence for why the guard exists.
Forbidding it there would delete the evidence.

## Fixture and example data

Test fixtures, worked examples and stub inputs must use a **synthetic** value,
never the live pin — `ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture`, not the
release of the day. A fixture needs *a* tag, not *the* tag, and a fixture that
spells out the pin is another copy of it that nothing will update on the next
bump. Keep the surrounding shape real (registry paths, filename patterns) so the
example still teaches; make only the owned value obviously fake. Fixtures are
therefore **not** exempt from the pin check — they simply have nothing to
restate.

## Pin block enumeration and enforcement status

"And the rest of the pin block" (the previous wording here) was vague enough that two version
pins slipped past enforcement for two review rounds before being caught. This enumerates every
value the block sets, and states plainly which ones `tests/owners.bats` actually checks.

**Mechanically enforced** — `tests/owners.bats` fails the suite if any of these values is
restated outside the fetch script:

- `MALCOLM_VER`, `UBUNTU_ISO_VER`, `GNS3_VER`, `ET_SURICATA_PATH`, `CHR_VER`, `OPNSENSE_VER`,
  `FRR_IMG`
- `MONITOR_IMAGES` tags: prometheus, alertmanager, blackbox-exporter, cadvisor

**Named exceptions — not mechanically enforced, and here is why:**

- `MONITOR_IMAGES`: grafana-oss (currently `12.1.0`, held below 13.x — policy in
  `docs/plans/r770-dependency-manifest.md` §0). Still owned by the fetch script's pin block like
  every other pin; simply not yet added to the test's regex. Not a false-fire risk — a plain
  gap, tracked here so it isn't a silent one.
- `MONITOR_IMAGES`: nginx (`stable`), registry (`2`), mkdocs-material (`latest`). These are
  deliberately floating tags, not version pins — the fetch script's own comment on the
  mkdocs-material line says "pin a tag once you standardize." There is no fixed current value to
  restate elsewhere, so "one owner per fact" doesn't apply to them the way it does to a pinned
  version. `registry`'s tag, `2`, is also a concrete illustration of a value that would be unsafe
  to search for regardless: as a bare literal it would match constantly throughout the repo and
  turn the check into noise — an over-matching test is its own defect, same as an
  under-matching one.
- `OPNSENSE_MIRROR` (a mirror base URL, not a version) is part of the same reviewed block but
  isn't a pin at all, so it's excluded from this enumeration on those grounds rather than as a
  test-safety exception.

## How to reference instead of restate

Don't copy the value. Point at the owner: "pins: see the pin block in
`scripts/r770-offline-fetch.sh`" rather than naming a version number;
"current staging host: see `docs/plans/r770-dependency-manifest.md` §0"
rather than naming an OS. A reference can't go stale the way a second copy
of the same fact can.
