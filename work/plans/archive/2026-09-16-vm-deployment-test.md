# VM Deployment Test — Rehearsal Sites Up, Left Running — Implementation Plan

> **STATUS: EXECUTED 2026-09-16; TORN DOWN 2026-09-17** (full wipe, including the bundle, per operator request) — evidence (incl. teardown) in `state/inventory/rehearsal-sites-2026-09-16.md`. Archived 2026-09-17.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring up every portal site from the design — `portal.lab`, `malcolm.lab`, `gns3.lab`, `monitoring.lab`, `docs.lab` — on staging VM 9770, with a sample capture in Malcolm, from `bundle-20260915` (not `bundle-20260908`, which no longer exists on the VM). Unlike the 2026-09-12 rehearsal, **leave everything running afterward for open-ended manual testing — no teardown task in this plan.**

**Relationship to prior work:** This repeats `work/plans/archive/2026-09-12-rehearsal-sites-up.md` almost exactly. All `config/` files that plan created still exist in the repo unchanged (proven working 2026-09-12) — this plan re-ships and re-runs them against the current VM state; it does not re-author them. Deviations from the archived plan are called out per task.

**Why `bundle-20260915`, not `bundle-20260908`:** the 2026-09-15 deployment test (`state/inventory/staging-sections-2026-09-15.md`) wiped the VM to init state — including deleting `bundle-20260908` from it — then cut a fresh bundle with the current (fixed) scripts. `bundle-20260915` is already on the VM, `verify` PASS WITH WARNINGS (same two accepted WARNs as `bundle-20260908`), and reflects the sectioned-fetch + capability-based-runtime + `resolve_latest_tag` EPIPE-guard work. `BUILD-STATE.md`'s "Current bundle" line still names `bundle-20260908` for the R770-transfer tracker — that line gets a note added, not overwritten, since `bundle-20260915` is explicitly not a transfer candidate (Task 9).

## Global Constraints

- **Staging VM 9770 only** (`ssh ubuntu@192.168.4.28`, key auth — confirmed working 2026-09-16). Nothing here touches the R770 or any other Proxmox guest.
- **Operator gate, unresolved as of plan approval:** VMs 100 and 108 must be stopped on the Proxmox host for as long as the sites are up (same standing requirement as 2026-09-12). This container has no Proxmox key to check itself — **confirm with the operator before Task 1.**
- No VM resize needed this time — 9770 is already at ~11 GiB with 10 GiB available at rest, meeting the ≥11 GiB bar without a `qm set`.
- **Egress stays OPEN** during setup (supply-chain discipline holds regardless: no `docker pull`, no `apt-get install` from the internet, no `pip install` from PyPy — everything comes from `~/r770/bundle-20260915/`, except Task 4's traffic generation).
- **No secrets in git** (CLAUDE.md rule 7). New passwords land in mode-0600 files on the VM (`~/.malcolm-rehearsal-pw`, `~/.monitoring.env`, `~/.gns3-admin-pw`) — the plan never prints them.
- **Nothing enabled at boot**, same as before, except the package-enabled exceptions (nginx, node_exporter) noted in the 2026-09-12 evidence.
- **Malcolm's rebind is a one-line `docker-compose.yml` edit, never an override file** — the override-file approach was tried and abandoned 2026-09-09 (`docker-compose.override.yml` did not load under `./scripts/start`). Never revert to raw `docker compose up`.
- Evidence discipline (`.claude/agents/validation-runner.md`): expected vs observed, exact command and output, SKIPPED-with-reason for anything that cannot run. New evidence file: `state/inventory/rehearsal-sites-2026-09-16.md` (a fresh date — the 2026-09-12 file already ends in a completed teardown).
- Commit style: imperative, capitalized, no `feat:`/`fix:` prefix. Run `./tests/run.sh` before every commit.

## Files

No new `config/` files. Only these repo files change:
| File | Action |
|---|---|
| `state/inventory/rehearsal-sites-2026-09-16.md` | CREATE — evidence |
| `state/BUILD-STATE.md` | MODIFY — Log entry + a note on the Current-bundle line |

Everything else ships as-is from the existing `config/nginx/`, `config/portal/`, `config/docs/`, `config/monitoring/`, `config/gns3/`, `config/malcolm/malcolm-config-rehearsal.json`.

---

### Task 1: Readiness gate

- [ ] Confirm with the operator that Proxmox VMs 100 and 108 are stopped.
- [ ] Ship the four staging scripts fresh; sha256-compare both sides (mirrors the 2026-09-15 sync).
- [ ] Record VM memory/disk baseline and the operator's VM-100/108 confirmation in the new evidence file.

### Task 2: Internal CA + one five-name certificate (full redo — purged 2026-09-15)

- [ ] Install easy-rsa from `bundle-20260915/apt`; rebuild the CA and one server cert with the same 5 SANs (`portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab`), same commands as archived Task 1 Step 1, path updated to `bundle-20260915`.
- [ ] Install cert/key/CA/htpasswd into nginx paths (archived Task 1 Step 2).
- [ ] Re-ship the existing (unchanged) `config/nginx/snippets/lab-tls.conf`, `lab-auth.conf`, `malcolm.lab.conf`.
- [ ] Verify the served chain (`openssl s_client -servername malcolm.lab`), hand the new CA to the operator (old one is no longer trusted anywhere — this is a new CA, not a resurrection of the old one).
- [ ] Evidence + commit.

### Task 3: Malcolm — extract, configure (reuse exported config), auth, rebind, start

- [ ] `mkdir ~/malcolm && cd ~/malcolm && unzip ~/r770/bundle-20260915/malcolm/malcolm-*-docker_install.zip && cp ~/r770/bundle-20260915/malcolm/docker-compose.yml .`
- [ ] Verify all 23 Malcolm image tags already present: `~/r770/scripts/r770-malcolm-deploy.sh assert-tags ~/r770/bundle-20260915` (images are already loaded from the 2026-09-15 fetch — this should report `all images present` with no `docker load` needed; if any are missing, fall back to `r770-malcolm-deploy.sh load`).
- [ ] Configure via `--import-malcolm-config-file`, reusing the committed `config/malcolm/malcolm-config-rehearsal.json` unchanged (skip the interactive dry-run/configure cycle — that config is already proven to fit an 8–12 GiB VM).
- [ ] `auth_setup` unattended (runbook §8.1a command shape), new random admin password → `~/.malcolm-rehearsal-pw`.
- [ ] One-line edit to `docker-compose.yml`: `nginx-proxy` ports `127.0.0.1:8443:443` (never an override file).
- [ ] Start with Malcolm's own `./scripts/start`; wait for health; confirm 27 services, portal-fronted probes matching the 2026-09-12 result set (`/ 200`, `/arkime/ 302`, `/dashboards/ 302`, `/netbox/ 200`, `/readme/ 200`).
- [ ] Evidence + commit.

### Task 4: Sample capture in Malcolm

- [ ] Discover the interface (never guess it), capture ~60s of self-generated mixed traffic, same recipe as archived Task 3.
- [ ] Drop into Malcolm's `pcap/upload/`, confirm it moves to `processed/`.
- [ ] Confirm Arkime session count > 0 and at least one zeek index with non-zero docs.
- [ ] Evidence + commit.

### Task 5: `portal.lab`

- [ ] Re-ship the existing `config/portal/index.html` and `config/nginx/portal.lab.conf` unchanged; enable the vhost; verify `unauth 401` / authenticated `<title>R770 Lab Portal`.
- [ ] Evidence + commit.

### Task 6: `docs.lab`

- [ ] Re-ship `config/docs/mkdocs.yml`, `config/nginx/docs.lab.conf`; rebuild the site with the bundled `squidfunk/mkdocs-material` image (already loaded); verify.
- [ ] Evidence + commit.

### Task 7: `monitoring.lab`

- [ ] node_exporter from `bundle-20260915/apt` (host metrics).
- [ ] Re-ship `config/monitoring/*` and `config/nginx/monitoring.lab.conf` unchanged; `.env` image refs generated from **`bundle-20260915/docker/monitoring-image-list.txt`** (not 20260908's) — same generation command as archived Task 6 Step 5, path updated.
- [ ] `docker compose up -d --pull never`; verify Grafana/Prometheus/Alertmanager reachable, targets up, `gns3.lab` probe down until Task 8 (expected).
- [ ] Evidence + commit.

### Task 8: `gns3.lab`

- [ ] Rebuild the Python venv from `bundle-20260915/gns3/wheelhouse` (purged 2026-09-15); install `gns3-server`; stage the 12 `.gns3a` definitions.
- [ ] Re-ship the existing `config/gns3/gns3_server.conf.template` and `config/nginx/gns3.lab.conf` unchanged; fill secrets on the VM (new password + JWT); start under tmux; enable the vhost.
- [ ] Verify `/v3/version`, login issues a token, `computes: 1`. Node execution stays out of scope (dynamips/ubridge/vpcs not in the bundle), same as before.
- [ ] Evidence + commit.

### Task 9: Close-out — measured, left running (no teardown)

- [ ] One pass over all five sites with the CA: expect five `200`/`302` with `tls=0`; `ss -ltnp` shows only nginx on `0.0.0.0:443`; `probe_success` 1 for all five vhosts; memory well under the VM total.
- [ ] Write the "How to use it (operator)" and "If the VM reboots" sections into the new evidence file (same shape as 2026-09-12's, updated for `bundle-20260915`).
- [ ] Add an explicit line: **this deployment is intentionally left running for manual testing — no auto-teardown, no timer — until the operator says otherwise.**
- [ ] `state/BUILD-STATE.md`: add a Log entry for 2026-09-16, and append (do not overwrite) a note on the "Current bundle" line that `bundle-20260908` no longer exists on VM 9770 and `bundle-20260915` (not a transfer candidate) is what's actually deployed there now.
- [ ] `./tests/run.sh` green, final commit.
- [ ] **No Teardown section.** That is the entire point of this plan.

---

## Verification

The plan succeeds when all hold:
1. `./tests/run.sh` — 0 failures.
2. All five sites load with a clean lock from the operator's browser (CA trusted, hosts line in place); Arkime shows sessions from the sample capture; Grafana's Prometheus datasource tests OK; GNS3 web UI logs in as `admin`.
3. `ss -ltnp` on the VM shows only nginx on `0.0.0.0:443`.
4. `probe_success` is 1 for all five vhosts in Prometheus.
5. The stack is left running — no teardown executed as part of this plan.
6. No file in the repo contains a password (`no-credentials.bats`).
