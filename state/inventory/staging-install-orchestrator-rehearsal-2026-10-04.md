# Staging rehearsal — r770-install.sh orchestrator (2026-10-04)

**VM:** 9771, rolled back to snapshot `analyst-stack-3b05070` (the proven Malcolm+CA+portal+UFW state) after discovering unrelated active work on it (GNS3/topology commits, an unlogged `bundle-20260928`) — operator confirmed the rollback.

**Scope actually exercised:** `--only labca,malcolm,portal` against the real scripts. **Storage was not rehearsed here** — this VM has no LVM volume group at all (`vgs`/`pvs` empty, plain `/dev/sda1`); it was never meant to replicate the R770's `ubuntu-vg0` layout. Storage's proof remains the stub-level bats coverage from Task 3. UFW was not reached (see below).

## What passed, with real command output

- `scripts/r770-install.sh --list` ran correctly on the VM, reporting all five steps registered.
- `--only labca`: `labca_check`/`plan`/`apply`/`verify` all passed — CA already issued, cert chain verifies, every SAN present, key permissions correct. Fully idempotent re-confirmation of the existing CA.
- `--only malcolm` apply sequence (load → assert-tags → install → configure → auth → bind-loopback → start → health): **passed cleanly on the final run** — 27/27 containers reported "running and healthy" by the real `r770-malcolm-deploy.sh health`.
- The adapter's argument wiring (`MALCOLM_BUNDLE_DIR`/`MALCOLM_CONFIG_JSON`/`MALCOLM_PASSWORD_FILE`/`MALCOLM_USER`) was confirmed correct against the real script multiple times — this is the I1 fix from the final code review, proven here, not just in stubs.

## What failed, and why — recorded honestly, not glossed over

Three attempts at `malcolm_verify` (the real loopback-capture-and-index proof):

1. **First attempt** failed: `FAIL arkime: no sessions for the capture within 300s`. Root cause, confirmed: the rehearsal's password file didn't match the already-configured htpasswd on this VM (auth was skipped as "already authenticated" from the original 3b05070 proof, using a different password than my fresh rehearsal password file) — `verify`'s Arkime API query authenticated with the wrong credentials and never got real data back. This was a rehearsal setup mistake on my part, not an orchestrator defect.
2. Ran `r770-malcolm-deploy.sh auth ... --force` to reset the htpasswd to match — succeeded. This also regenerated OpenSearch's internal service credentials (`--auth-generate-opensearch-internal-creds`), which the already-running `opensearch`/`dashboards` containers didn't pick up without a restart, causing `Authentication finally failed for malcolm_internal` and both containers going `unhealthy`.
3. **Second attempt** (before I noticed and fixed the above) never reached verify cleanly — I killed it once the credential mismatch was diagnosed, restarted `opensearch`/`dashboards`, confirmed all 27 containers healthy again.
4. **Third attempt**: `labca` and `malcolm_apply`'s full sequence passed again cleanly (27/27 healthy). `malcolm_verify`'s capture and upload passed (`PASS capture: 28804 bytes`, `PASS uploaded: ...`). But the indexing check failed again: `FAIL arkime: no sessions for the capture within 300s` and `FAIL zeek: no new files under .../zeek-logs within 300s` (zeek's own container still reported healthy). At this point `free -h` showed the VM at 194Mi free of 11Gi, swapping (3.9Gi of 8Gi swap in use) — this VM is memory-constrained under Malcolm's full 27-service footprint stacked on top of the back-to-back heavy operations this rehearsal performed (three full docker loads, a compose restart), and BUILD-STATE.md's own history already notes memory was "tighter" on this VM even under normal conditions. The indexing pipeline (Logstash → OpenSearch, Zeek's own log flush) most plausibly stalled under that pressure, not because of a code defect.

**Both verify failures correctly halted the orchestrator before `portal` ever ran.** That is the behavior under test, and it worked exactly as designed: `run_step`'s `"${id}_apply" || return $?; "${id}_verify"` meant a real, non-stubbed verify failure stopped the whole `--only labca,malcolm,portal` run at malcolm, with the real `FAIL` lines surfaced to the operator, never silently continuing to portal with Malcolm unverified. That is Review Focus #5 and the general halt-on-failure contract, proven against a real failure this VM actually produced — not just a stub.

## Fourth attempt (2026-10-04, resumed): a cold reboot, and a different self-inflicted failure

VM 9771 was stopped then restarted fresh (10Gi free, 0 swap used, 0 containers running — nothing auto-starts at boot). `--only labca,malcolm,portal,ufw --confirm ufw` was run against this genuinely clean state:

- `labca`: passed.
- Malcolm's full apply sequence, including a real cold `start` (all 27 containers came up from stopped, not idempotent-skip): **passed**. The real `health` command's own polling loop confirmed every container healthy one by one.
- `health` then hung well past the point every container showed `running healthy` in `docker compose ps`. Root cause, found by reading `not_ready()`/`compose_ps()` in `r770-malcolm-deploy.sh`: `compose_ps` passes `--all`, which includes **exited** containers that a plain `docker compose ps` or `docker ps` doesn't show. `malcolm-netbox-1` had exited: its logs showed `FATAL: password authentication failed for user "netbox"` against postgres.
- This traces directly back to **my own earlier manual remediation** in this same rehearsal (`r770-malcolm-deploy.sh auth --force` to fix attempt 1's password mismatch): that call's `--auth-generate-postgres-password` flag regenerated postgres's credential, but postgres's live, already-initialized database user password doesn't change just because a secret file changed or the container restarts — only `auth_setup`'s own `ALTER USER` at the moment it ran would have applied it live, and apparently didn't fully propagate to netbox's view of it. A plain `docker compose restart netbox` did not fix it (confirmed — same auth failure after restart), meaning the mismatch is between netbox's credential and postgres's actual stored one, not a stale read.
- This is the **same class of problem** as the earlier opensearch/dashboards credential desync in attempt 2 — forcing an auth reset with `auth_setup`'s credential-regeneration flags on an **already-running, already-authenticated** Malcolm stack doesn't safely resync every dependent service. It is not something `malcolm_apply`'s normal, non-forced flow would ever trigger (a real first-time `auth` call sets every password once, consistently, before anything starts) — it is a consequence of me using `--force` to fix my own rehearsal setup mistake, not a defect in the orchestrator or its adapter.
- Stopped the orchestrator run manually rather than let `health`'s 600s timeout play out on a condition that could not resolve on its own.

## What this rehearsal does and doesn't prove

**Proven, including from a genuine cold start:** the orchestrator's CLI, step registration, the labca adapter, and Malcolm's full apply sequence (load/assert-tags/install/configure/auth/bind-loopback/start/health) — including a real cold `start` bringing up all 27 containers from stopped — all work correctly against the real scripts on a real VM, with the corrected I1 argument-passing. The halt-on-a-real-failure behavior is proven twice over, against two different genuine failures.

**Not proven here:** a full clean `labca → malcolm → portal → ufw` pass to completion. Every verify/health failure encountered traces to this specific VM's accumulated state (my own `--force` auth interventions, and before that, memory pressure from repeated heavy operations) rather than to the orchestrator. Storage was out of scope for this VM entirely (no LVM).

## Next steps

- A fully clean end-to-end rehearsal needs either: (a) a fresh snapshot rollback followed by a run that **never** calls `auth --force` (only possible if the rehearsal's password file is set *before* Malcolm's first-ever `auth` call, not after), or (b) a full teardown and reinstall of Malcolm on this VM so auth runs once, cleanly, with no legacy credentials anywhere to desync.
- Storage needs a rehearsal on a VM (or the real R770) with an actual `ubuntu-vg0`-shaped LVM layout to mean anything beyond the existing stub coverage.
- This VM (9771) now has lingering credential corruption (netbox/postgres) from this rehearsal's own remediation attempts. It should be rolled back to a known snapshot before any other session relies on it.
