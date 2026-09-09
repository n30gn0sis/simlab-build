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
| Version pins (Malcolm, FRR, alertmanager, cadvisor, and the rest of the pin block) | `scripts/r770-offline-fetch.sh` pin block |
| The verify command | `scripts/r770-bundle.sh` |
| Hardware of record, phase status, unknowns | `state/BUILD-STATE.md` |
| Bundle sizes and cycle history | `state/inventory/bundles.md` |
| Decisions of record (staging host, OS, transfer media, cadence, pin policy) | `docs/plans/r770-dependency-manifest.md` §0 |
| Success criteria | `PRD.md` §10 |

## How to reference instead of restate

Don't copy the value. Point at the owner: "pins: see the pin block in
`scripts/r770-offline-fetch.sh`" rather than naming a version number;
"current staging host: see `docs/plans/r770-dependency-manifest.md` §0"
rather than naming an OS. A reference can't go stale the way a second copy
of the same fact can.
