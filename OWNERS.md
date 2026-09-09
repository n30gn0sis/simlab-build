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

| Fact | Owner |
|---|---|
| Version pins — every value set in the `# ── pins: review each refresh cycle ──` block of `scripts/r770-offline-fetch.sh` (enumerated below) | `scripts/r770-offline-fetch.sh` pin block |
| The verify command | `scripts/r770-bundle.sh` |
| Hardware of record, phase status, unknowns | `state/BUILD-STATE.md` |
| Bundle sizes and cycle history | `state/inventory/bundles.md` |
| Decisions of record (staging host, OS, transfer media, cadence, pin policy) | `docs/plans/r770-dependency-manifest.md` §0 |
| Success criteria | `PRD.md` §10 |

### Pin block enumeration and enforcement status

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
