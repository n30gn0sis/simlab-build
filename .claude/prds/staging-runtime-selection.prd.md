# Staging Runtime Selection (Docker default, Podman as a documented option)

## Problem
The staging pipeline (`r770-staging-preflight.sh` → `r770-offline-fetch.sh` → bundle build) already
*accepts* podman on capability, but there is no documented, discoverable way for an operator to
deliberately choose it — someone would have to already know to set `STAGING_CTR=podman` themselves.
Two known-good hosts today (a RHEL 8 box with only Docker installed, and the Ubuntu staging VM 9770,
also Docker-only) must keep defaulting to Docker unchanged. An upcoming RHEL-only host that will need
to stage everything makes podman-as-a-real-option more than academic.

## Evidence
- `state/BUILD-STATE.md`, 2026-09-15 entry: on VM 9770, "a second runtime (podman, rootless) probed
  once for real then removed per operator instruction that this VM runs Docker" — podman has been
  exercised at the preflight-probe level, never carried through an actual bundle cut.
- Operator confirms two current hosts are Docker-only (RHEL 8 box, and staging VM 9770) and must stay
  that way by default.
- Assumption — needs validation via confirmed host spec: an upcoming RHEL-only host that will need to
  stage everything. No date, ticket, or confirmed Docker-availability status for that host yet.

## Users
- **Primary**: the staging VM operator (currently running Docker-only VM 9770), who needs a documented
  way to opt into podman ahead of the upcoming RHEL-only host, without disturbing their default workflow.
- **Secondary**: an operator running the offline fetch directly on a RHEL 8 box that has only Docker
  installed (no podman) — must see no behavior change; Docker stays default there too.
- **Not for**: the R770 itself (no internet, unaffected by this); support for any container runtime
  other than Docker or podman (nerdctl remains best-effort, as today).

## Hypothesis
We believe **documenting and hardening an explicit runtime-selection option (Docker default, podman
opt-in) for the staging pipeline** will let an operator choose podman deliberately **for an upcoming
podman-relevant host** for **staging VM operators and RHEL-box operators**.
We'll know we're right when an operator can select podman via a documented option, the test suite
proves the default stays Docker on both Ubuntu and RHEL unless overridden, and podman selection is
exercised in the existing (stubbed) test environment — real end-to-end proof on physical/VM hardware
is tracked as a separate, deferred milestone (see below), not required for this one.

## Success Metrics
| Metric | Target | How measured |
|---|---|---|
| Runtime-selection option is documented | Present in staging runbook/README, not just code | doc review / `references.bats`-style existence check |
| Default runtime unchanged | 100% of no-override runs pick Docker on both Ubuntu and RHEL | `staging-preflight.bats` / `offline-fetch.bats` reproducers |
| Podman selectable without code changes | Yes | stub-environment reproducer forces podman via the documented option and preflight/fetch honor it |

## Scope
**MVP** — a documented, explicit way to select podman for the staging pipeline (this may mean
formally documenting and testing the existing `STAGING_CTR` override rather than inventing a new flag
— left to `/plan` to decide), with Docker remaining the unconditional default on both Ubuntu and RHEL,
covered by the existing stub-based test suite.

**Out of scope**
- Making podman the default on any host — Docker stays default everywhere, deferred to operator choice only.
- Real end-to-end proof of a completed, verified bundle cut via podman on live hardware (VM 9770 or a
  separate RHEL 8 box) — explicitly deferred per operator instruction ("skip the podman proof for now").
  Tracked as Milestone 2 below, unscheduled.
- Support for container runtimes other than Docker and podman.
- Any change to the R770 side of the pipeline.

## Delivery Milestones
<!-- Business outcomes, not engineering tasks. /plan turns each into a plan. -->
<!-- Status: pending | in-progress | complete -->

| # | Milestone | Outcome | Status | Plan |
|---|---|---|---|---|
| 1 | Documented runtime selection | An operator can find and use a documented way to request podman instead of docker for the staging pipeline; default stays docker on Ubuntu and RHEL; covered by the stub-based test suite | pending | — |
| 2 | Real end-to-end podman proof | A full bundle cut is run and `verify`-clean through podman on real hardware (VM 9770 and/or a separate RHEL 8 box) | pending (deferred, unscheduled) | — |

## Open Questions
- [ ] Will the upcoming RHEL-only host have Docker CE available as a fallback, or is it podman-only?
- [ ] Is a separate real RHEL 8 box available now for Milestone 2, or does that depend on the upcoming host arriving first?
- [ ] Should selection be the existing `STAGING_CTR` env var (documented/hardened) or a new CLI flag on `r770-build-bundle.sh` — left for `/plan` unless the operator has a preference.
- [ ] What date or trigger should re-open Milestone 2 (the deferred podman proof)?

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Podman path is documented as "supported" before it's proven on real hardware, and the upcoming RHEL-only host arrives before Milestone 2 lands | Medium | High — bundle build could fail on first real use | Word documentation carefully ("selectable," not "validated"); keep Milestone 2 visible and not silently dropped |
| A new/duplicate selection mechanism is added alongside `STAGING_CTR`, causing operator confusion | Low | Medium | Prefer documenting/hardening the existing knob over inventing a second one; decide explicitly in `/plan` |

---
*Status: DRAFT — requirements only. Implementation planning pending via /plan.*
