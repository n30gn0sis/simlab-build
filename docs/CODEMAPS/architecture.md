<!-- Generated: 2026-09-14 | Files scanned: 85 | Token estimate: ~650 -->
# Architecture — R770 Sim Lab Build

Two machines, two roles. Nothing crosses between them except the bundle on ext4 media.

```
internet ──▶ STAGING  (Ubuntu VM + Docker CE, or RHEL 8 + rootful podman)
              scripts/r770-staging-preflight.sh   may THIS host build a bundle?
              scripts/r770-offline-fetch.sh       10 stages → bundle-YYYYMMDD/
              scripts/r770-bundle.sh              MANIFEST.sha256 write + verify
              scripts/r770-build-bundle.sh        one command wrapping the three above
                      │  transfer media (ext4), verifier travels inside the bundle
                      ▼
             R770     (Ubuntu 24.04, no internet, reached over ssh)
              scripts/r770-precheck.sh            Phase 1 discovery, read-only
              <bundle>/r770-bundle.sh verify --strict   gate before anything installs
              scripts/r770-malcolm-deploy.sh      load images, prove every tag landed
              docs/plans/r770-install-runbook.md  Phases 2–16, operator-driven
```

Rehearsal loop (staging VM only): `r770-airgap-sim.sh block` → deploy from the bundle → `unblock`.
Egress is dropped in both OUTPUT and DOCKER-USER so containers are cut off too.

## Sources of truth
- `PRD.md` requirements · `docs/plans/r770-network-lab-buildout.md` design
- `OWNERS.md` one owner per fact; version pins live only in `scripts/r770-offline-fetch.sh`
- `state/BUILD-STATE.md` phase status · `state/inventory/` evidence (append-only)
- `work/plans/` one-shot plans: `active/` in flight, `archive/` executed (frozen)

## Phase chain (state/BUILD-STATE.md)
1 discover → 2 firmware/RAID → 3 storage → 4 base OS → 5 mgmt network → 6 docker →
7 kvm/bridges → 8 gns3 → 9 capture ports → 10 malcolm → 11 mirror feed →
12 wan impairment → 13 portal/tls/docs → 14 monitoring → 15 backup → 16 validation

## Guardrails
- `CLAUDE.md` rules 1–8; `.claude/settings.json` denies disk-destroying tools outright
- `./tests/run.sh` is the one gate; CI runs it on every push to main and every PR
- `.claude/hooks/session-start.sh` installs shellcheck in remote sessions only
- Agents (`.claude/agents/`): safety-reviewer before anything destructive, bundle-builder,
  discovery-analyst, validation-runner, capture-engineer

See also: scripts.md · config.md · tests.md · dependencies.md
