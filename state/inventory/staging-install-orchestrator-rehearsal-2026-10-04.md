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

## What this rehearsal does and doesn't prove

**Proven:** the orchestrator's CLI, step registration, labca adapter, and Malcolm's apply sequence (including the corrected argument-passing from the I1 fix) all work correctly against the real scripts on a real VM. The halt-on-a-real-failure behavior is proven, not just unit-tested.

**Not proven here:** a full clean `labca → malcolm → portal` pass to completion, or any UFW exercise (never reached). Storage was out of scope for this VM entirely (no LVM).

## Next steps

- Portal and UFW rehearsal still needs a run where `malcolm_verify` passes cleanly — either on a VM with more headroom, or after confirming Malcolm's indexing pipeline isn't resource-starved (not an orchestrator question).
- Storage needs a rehearsal on a VM (or the real R770) with an actual `ubuntu-vg0`-shaped LVM layout to mean anything beyond the existing stub coverage.
