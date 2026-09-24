# Pin review — 2026-09-24 (pre-cut, ahead of Phase 3 storage + bundle import)

Run on the internet-connected side per `/bundle` step 2, ahead of the next bundle cut. Method:
GitHub releases API (Malcolm, prometheus/alertmanager/blackbox_exporter, google/cadvisor,
grafana/grafana), PyPI JSON (gns3-server), `releases.ubuntu.com/noble` index, quay.io tag API
(FRR), HTTP liveness on the pinned ET rules path, `opnsense.org/download` + the dotsrc mirror
listing, and MikroTik's own update-check endpoint
(`upgrade.mikrotik.com/routeros/NEWESTa7.stable`). Per the 2026-09-08 methodology correction on
file, every image pin (not just the version number) was also confirmed to actually resolve as a
container image — via unauthenticated registry-API manifest HEAD checks against ghcr.io and
Docker Hub (token + `GET /v2/<repo>/manifests/<tag>`), since that is what the fetch script's
`pull`/`save` actually needs, not a proxy for it. Pinned values read from
`scripts/r770-offline-fetch.sh` (read-only during research).

| Pin | Was | Upstream | Status | Action |
|---|---|---|---|---|
| alertmanager | v0.34.0 | **v0.34.1** (published 2026-09-17) | MOVED | **BUMPED** — operator approved 2026-09-24 |
| cadvisor | v0.60.5 | **v0.60.6** (published 2026-09-18) | MOVED | **BUMPED** — operator approved 2026-09-24 |
| MikroTik CHR | 7.21.5 | **7.24.4** (confirmed via MikroTik's stable-channel version endpoint; image resolves) | MOVED | **BUMPED** — operator approved 2026-09-24 |
| grafana-oss | 12.1.0 | Latest 12.x GitHub release v12.4.11 (2026-09-15); latest `grafana-oss` Docker Hub image tag actually published is **12.4.3** (12.4.4–12.4.11 have no Docker Hub image yet); latest overall is v13.2.2 | held | **HELD** — policy: below 13.x, review dashboards before any major jump |
| Malcolm | 26.08.0 | 26.08.0 (published 2026-08-25; unchanged since 2026-09-04) | current | none |
| Ubuntu ISO | 24.04.4 | 24.04.4 (no 24.04.5 listed) | current | none |
| gns3-server | 3.0.6 | 3.0.6 (3.1.0a1–a5 are pre-release alphas, not stable) | current | none |
| prometheus | v3.14.0 | v3.14.0 (published 2026-08-18) | current | none |
| blackbox-exporter | v0.28.0 | v0.28.0 (published 2025-12-06) | current | none |
| FRR image | 10.7.1 | 10.7.1 (highest semver `X.Y.Z` tag in the last 50) | current | none |
| OPNsense | 26.7 | 26.7 per opnsense.org | current | none — **re-check the mirror on cut day** (dotsrc did not respond during this check) |
| ET Suricata path | `suricata-7.0` | HTTP 200 (still alive; `suricata-8.0` also live but noble ships 7.0.x) | current/alive | none |
| nginx:stable | floating | — | n/a | n/a |
| registry:2 | floating | — | n/a | n/a |
| mkdocs-material:latest | floating | — | n/a | n/a |

## Notes for the record

- **CHR is a multi-minor jump (7.21.5 → 7.24.4), not the routine monthly cadence.** This pin only
  affects the MikroTik CHR raw image used as a GNS3 lab appliance (`gns3/appliances/`) — it has no
  effect on the R770 host, Malcolm, or any monitoring/portal component. No RouterOS 7.22–7.24
  changelog review was in scope for this pass; skim those release notes for breaking config/CLI
  changes before relying on new CHR features in lab topologies.
- **alertmanager and cadvisor each moved by one patch/point release** (v0.34.0→v0.34.1,
  v0.60.5→v0.60.6) — low risk, both confirmed to actually resolve as images at the new tag before
  being approved.
- **grafana-oss stays HELD below 13.x** per the standing exception (dependency manifest §3). Note
  carried forward from research: if grafana is ever un-held, use the Docker Hub tag list as the
  ceiling, not the GitHub releases API — GitHub's release feed runs ahead of what Docker Hub
  actually publishes as a `grafana-oss` image (same class of mistake as the 2026-09-08 cadvisor
  `gcr.io` incident).
- **OPNsense mirror (`mirrors.dotsrc.org`) did not respond during this check** (empty body, no
  headers). The pinned version (26.7) is confirmed current on opnsense.org itself, so this doesn't
  block the bump review, but re-check the mirror's reachability on cut day, since that mirror (not
  opnsense.org) is what the fetch script actually downloads from.
- Malcolm did not move (still 26.08.0, same as 2026-09-04) — no new
  `malcolm-<ver>-docker_install.zip` check or release-notes diff was needed.
- ET rules path: only HTTP liveness of the pinned branch was checked, no rules-content/CVE-coverage
  review — per task scope.
