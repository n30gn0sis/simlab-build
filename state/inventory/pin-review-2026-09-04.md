# Pin review — 2026-09-04 (pre-bundle-1)

Run on the internet-connected side per `/bundle` step 2, before cutting the first bundle. Method: GitHub releases API, PyPI JSON, `releases.ubuntu.com/noble` index, quay.io tag API, and an HTTP liveness check for the ET rules path. Pinned values read from `scripts/r770-offline-fetch.sh`.

| Pin | Was | Upstream | Status | Action |
|---|---|---|---|---|
| Malcolm | 26.07.1 | **26.08.0** (published 2026-08-25) | MOVED | **BUMPED** — operator approved 2026-09-04 |
| alertmanager | v0.33.0 | **v0.34.0** | MOVED | **BUMPED** |
| cadvisor | v0.57.0 | **v0.60.5** | MOVED | **BUMPED** |
| FRR image | 10.6.1 | **10.7.1** | MOVED | **BUMPED** |
| grafana-oss | 12.1.0 | 13.2.1 | held | **HELD** — deliberate, per manifest §3; review dashboards before any major jump |
| Ubuntu ISO | 24.04.4 | 24.04.4 | current | none |
| gns3-server | 3.0.6 | 3.0.6 | current | none |
| prometheus | v3.14.0 | v3.14.0 | current | none |
| blackbox-exporter | v0.28.0 | v0.28.0 | current | none |
| OPNsense | 26.7 | 26.7 | current | none |
| MikroTik CHR | 7.21.5 | *(no machine-readable index)* | manual | check mikrotik.com/download/chr by hand |
| ET Suricata path | `suricata-7.0` | HTTP 200 | alive | none — branch not retired |
| VyOS rolling · Alpine | resolved at build time | — | n/a | script resolves to latest automatically |

## Malcolm 26.08.0 — verified before committing to the bump

Not bumped blind. Confirmed against the release:

- `malcolm-26.08.0-docker_install.zip` — HTTP 200
- `docker-compose.yml` at tag `v26.08.0` — HTTP 200
- **23 images**, every one tagged `26.08.0` under `ghcr.io/idaholab/malcolm/*`, matching the path the fetch script greps for: api, arkime, dashboards, dashboards-helper, file-upload, filebeat-oss, filescan, freq, htadmin, keycloak, logstash-oss, netbox, nginx-proxy, opensearch, pcap-capture, pcap-monitor, postgresql, strelka-{backend,frontend,manager}, suricata, valkey, zeek

## Note for the record

Malcolm 26.08.0 was published **2026-08-25**, six days *before* the dependency manifest recorded "Pins re-verified 2026-08-31: Malcolm 26.07.1 … still current." The record does not say whether it was missed or consciously not adopted. Flagged as a fact, not a fault — but it is the reason the next cycle should run this check from a script rather than by eye (`r770-pin-check.sh`, planned in `work/plans/archive/2026-09-03-bundle-integrity-gate.md` Task 5).

## Rationale for bumping rather than holding

Nothing is deployed yet, so a version bump costs only documentation churn — there is no migration. The refresh cadence is ad-hoc, so bundle-1 may sit for months; importing a core analysis stack that is already one release behind on day one is the worse trade. Grafana remains the one deliberate exception, held below 13.x until someone reviews the dashboards.

---

## Correction, 2026-09-08 — this review had a methodology gap

The bundle-1 fetch failed at `[4/10]`:

```
failed to resolve reference "gcr.io/cadvisor/cadvisor:v0.60.5": not found
```

**Root cause:** this review verified that a *GitHub release* `v0.60.5` existed. It never verified
that a *container image* was published at that tag. Those are different facts.

**What was actually true:** `gcr.io/cadvisor/cadvisor` stopped publishing at **v0.55.1**. The
*previous* pin, `v0.57.0`, also 404s there — so this pin was **already broken before the bump**,
and bundle-1 would have failed at the same point either way. cadvisor images moved to
`ghcr.io/google/cadvisor`, where both v0.57.0 and v0.60.5 resolve.

**Fixed:** `gcr.io/cadvisor/cadvisor:v0.60.5` → `ghcr.io/google/cadvisor:v0.60.5` (fetch script
v3.5, dependency manifest §3).

**Method change for every future pin review.** Version numbers are not artifacts. Each image pin
must be confirmed with `docker manifest inspect <full reference>` before a fetch, because that is
what the fetch actually does. All 15 image references were re-verified this way on 2026-09-08 —
only the cadvisor one was broken:

| Result | References |
|---|---|
| OK (14) | prometheus v3.14.0 · alertmanager v0.34.0 · blackbox-exporter v0.28.0 · grafana-oss 12.1.0 · **ghcr.io/google/cadvisor v0.60.5** · nginx:stable · registry:2 · mkdocs-material:latest · alpine:latest · debian:stable-slim · netshoot:latest · frr 10.7.1 · ubuntu:24.04 · python:3.12-slim |
| MISSING (1) | ~~gcr.io/cadvisor/cadvisor:v0.60.5~~ |

This is the same class of error as trusting a fingerprint printed in a generated document: check
the thing you will actually use, not a proxy for it.

---

## Correction, 2026-09-09 — path reference moved

The plan cited above for `r770-pin-check.sh` (Task 5) moved in the 2026-09-09 repo restructure and
now lives at `work/plans/archive/2026-09-03-bundle-integrity-gate.md`. The citation above is left
as originally written — this record is append-only — but readers following it now should use the
new path.
