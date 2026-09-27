# Sub-project 2 — Analyst stack (CA, Malcolm, portal, UFW) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four tested deploy scripts, plus a `site/` payload in the bundle, and prove them offline on VM 9771: portal, Malcolm and docs behind TLS and one login, with UFW on.

**Architecture:** The code is already written and reviewed as **drafts**. Each was built test-first by a drafting agent, and the controller re-ran it (shellcheck clean with no disable directives; 217 bats tests, 0 failures). Every tool assumption the drafts made was checked against the real tools on VM 9771 (easy-rsa 3.1.7, ufw 0.36.2, iproute2, ss, curl, the mkdocs-material image, tar, and the Malcolm 26.08 installer).
- **Tasks 1–5** integrate each draft into the repo **byte for byte** (sha256 below), register it, run the full suite and commit. The task review diffs repo against draft and reads the code.
- **Tasks 6–9** are the live proof run on 9771. **The controller runs them inline**: they need root once and the scoped token, and no credential ever goes into a subagent prompt.

**Tech Stack:** bash, bats, shellcheck, easy-rsa, nginx, ufw, docker/compose, Malcolm's installer, the Proxmox API (via `scripts/r770-staging-vm.sh`).

**Spec:** `docs/superpowers/specs/2026-09-26-analyst-stack-design.md`

## Global Constraints

- Scripts are shellcheck-clean with **no `# shellcheck disable` directives**. `r770-offline-fetch.sh` keeps only the repo's existing legacy exclusion set (`-e SC2015,SC2012,SC2010,SC1091`), with no new exclusions.
- **Copy drafts verbatim.** After copying, `sha256sum` of each repo file must equal the value below. If a draft needs a change, stop and report NEEDS_CONTEXT instead of editing it.
- **Review findings are fixed in the repo** (operator, 2026-09-26). After a task review, fix rounds edit the repo files directly, and each fix gets a scoped re-review. The repo then intentionally differs from the draft; the ledger records each such divergence. The sha256 table only proves the *initial* copy.
- **No secret in the repo, a log, argv or a subagent prompt:** the analyst password, the Proxmox root password and the token.
- **Owned facts are referenced, not restated** (`OWNERS.md`). `git add` BEFORE `./tests/run.sh`, and the suite must be green before each commit.
- **Chain gates with `&&`, never `;`** (session memory). Collect evidence **before** stopping a VM.
- **UFW on a remote box** is gated. The dead-man switch stays armed until `confirm` runs from a **new** SSH session.
- **9771 memory:** 12 GiB, and only if the host keeps ≥ 3 GiB free (spec §Decisions 2).
- Commits end with the attribution lines from the session's system reminder.

## Drafts (source of truth for Tasks 1–5)

Base dir `D=.superpowers/sdd/2026-09-26-analyst-stack/drafts` (gitignored, in this checkout).

| Draft file | → repo path | sha256 |
|---|---|---|
| `site/scripts/r770-offline-fetch.sh` | `scripts/r770-offline-fetch.sh` | `9bd3301f5b5382db301c7ec921cdfa6e701bacb4541b578969f23029b4c660bb` |
| `site/scripts/r770-bundle.sh` | `scripts/r770-bundle.sh` | `31ae49d8db6bad774c44741f75e1c647ae5d54e0c550dc8653177b9ebd3bf5b0` |
| `site/tests/offline-fetch.bats` | `tests/offline-fetch.bats` | `1a15c670774b55afcaf7832065c9c8fa062ab76be07fbcfb5ac9c17fc35c967a` |
| `site/tests/bundle-verify.bats` | `tests/bundle-verify.bats` | `672db2aeb94c68eae72d5d855c70ebbc0d0dfc5821f236b44ee50697681eb10a` |
| `site/tests/helpers/fixtures.bash` | `tests/helpers/fixtures.bash` | `967350e87e6dd72d7765cb0071d49925a02b34833ee8512495ccc91e0f946bb8` |
| `ca/scripts/r770-lab-ca.sh` | `scripts/r770-lab-ca.sh` | `63f658df94c3774b0502cfbeb2bfe11ed9bd06bb896a3fb48e38640c49840e8b` |
| `ca/tests/lab-ca.bats` | `tests/lab-ca.bats` | `9be5d382006a5f0d6e4866ac6cf23a9309e5cd5de68d162149211c98e9ceb825` |
| `malcolm/scripts/r770-malcolm-deploy.sh` | `scripts/r770-malcolm-deploy.sh` | `5caee8bb87832210abf4ffab7934cb2c232cb83849c4aa1f7b806219b498963f` |
| `malcolm/tests/malcolm-deploy.bats` | `tests/malcolm-deploy.bats` | `d479f4fd50b52059cc4316cf6701ecdfb82e7b655cce3f40cf92ac7a7c5e2e05` |
| `portal/scripts/r770-portal.sh` | `scripts/r770-portal.sh` | `a03e9d30f2079ebab82fb5942edd4a93e5b646bb10d6f1e6fe2265d7da75f190` |
| `portal/tests/portal.bats` | `tests/portal.bats` | `f67e89210ae754d6dad302b7f44608216b8783c8fa95a245eaf7cc68e0995aa3` |
| `ufw/scripts/r770-ufw.sh` | `scripts/r770-ufw.sh` | `0454ba8c07487391cbc59f47e5a08387d4c365bb3bd4b9eab601712c73e9ea3c` |
| `ufw/tests/ufw.bats` | `tests/ufw.bats` | `6a9b2354529a8be2a0cf845eda2af8e0ab65d4e883678380737b211b8cf3de23` |

The five `site` drafts were made from the repo files at `main` @ `0ade78f`. If any of those repo files changed on `main` since then, stop and report NEEDS_CONTEXT, so nothing is silently overwritten.

## Real-tool facts the drafts rely on (verified on 9771, 2026-09-26)

- easy-rsa 3.1.7-2: `--pki-dir=` plus `init-pki`, `build-ca nopass`, `--subject-alt-name="DNS:…" build-server-full lab nopass` all work.
- ufw 0.36.2: `ufw show added` prints each rule exactly as typed and works while inactive; `Status: inactive` when off.
- `ip -o route get` → `… dev <if> src …`; `ip -o -4 addr show dev <if>` → `inet <addr>/<len>`; `ss -H -ltn[p]` has the local address in field 4 and `users:(("name",…))` with `-p`.
- curl `-K -` with `user = "name:pw"` sends `Authorization: Basic …`.
- `squidfunk/mkdocs-material` builds offline (`--network none`) into `/docs/site`.
- Malcolm 26.08 zip: `install.py` and `installer/` at the top level, where the argparse package defines `--non-interactive`, `--configure`, `--skip-splash` and `--import-malcolm-config-file`.
- The Malcolm compose port line is `    - 0.0.0.0:443:443`, with **no `/tcp`**.
- `scripts/start` is `control.py`, which **tails logs unless `--quiet`**.
- dnsmasq from the R770 package set auto-starts and listens on the LAN. UFW verify WARNs on it (filtered by UFW) and FAILs only on docker-proxy.

---

### Task 1: `site/` in the bundle

**Files:** `scripts/r770-offline-fetch.sh`, `scripts/r770-bundle.sh`, `tests/offline-fetch.bats`, `tests/bundle-verify.bats`, `tests/helpers/fixtures.bash` (all replaced by the drafts).

**Interfaces:** Produces a fetch stage `site`, which runs just before `manifest` and copies `scripts/`, `config/` and `docs/analyst-wiki/` into `$B/site/` (excluding `*.env`, `.git`, `config/**/*.key|*.pem|htpasswd`). `verify` gains `check_site`: a missing `site/` or a missing required script WARNs, and `--strict` makes that a FAIL.

- [ ] **Step 1:** Check the bases have not moved: `git diff --quiet 0ade78f HEAD -- scripts/r770-offline-fetch.sh scripts/r770-bundle.sh tests/offline-fetch.bats tests/bundle-verify.bats tests/helpers/fixtures.bash` must exit 0. Otherwise report NEEDS_CONTEXT.
- [ ] **Step 2:** Copy the five drafts over their repo paths. Keep the executable bit on the two scripts.
- [ ] **Step 3:** `sha256sum` each and compare with the table.
- [ ] **Step 4:** Docs in the same commit:
  - `docs/plans/r770-install-runbook.md` Part 1.4: one line saying the deploy scripts travel in the bundle's `site/` and are run from `/data/staging/bundle-*/site/scripts/`;
  - `docs/CODEMAPS/scripts.md`: add `site` to the fetch stage list;
  - `state/inventory/bundles.md` per-cycle checklist: "`site/` present (verify checks it)".
- [ ] **Step 5:** `git add` the changed files, then `./tests/run.sh` must be green. Then `shellcheck -e SC2015,SC2012,SC2010,SC1091 scripts/r770-offline-fetch.sh && shellcheck scripts/r770-bundle.sh`.
- [ ] **Step 6:** Commit: `"Bundle: ship the deploy scripts, configs and analyst wiki as site/ (manifest-covered)"`.

### Task 2: `scripts/r770-lab-ca.sh`

**Interfaces:** CLI `r770-lab-ca.sh [plan|apply [--reissue-cert]|verify|export-ca]`, run as root. Env: `LABCA_DIR`, `LABCA_SSL_DIR`, `LABCA_EASYRSA`, `LABCA_NAMES`, `LABCA_MIN_DAYS`. It installs `/etc/nginx/ssl/{lab.crt,lab.key,ca.crt}` and never rebuilds an existing CA.

- [ ] **Step 1:** Copy `ca/scripts/r770-lab-ca.sh` (mode 0755) and `ca/tests/lab-ca.bats`. Check both sha256 values.
- [ ] **Step 2:** Register it:
  - `tests/lint.bats`: add `scripts/r770-lab-ca.sh` to the "new scripts are shellcheck-clean with no exclusions" line;
  - `tests/README.md`: add 1 to the suite count and add a row for `lab-ca.bats`;
  - `README.md` "What's here": a row for the script;
  - `scripts/r770-bundle.sh` `SITE_REQUIRED_SCRIPTS` already lists it (Task 1).
- [ ] **Step 3:** `git add`, then `./tests/run.sh` must be green.
- [ ] **Step 4:** Commit: `"Add r770-lab-ca.sh — internal CA and the five-name .lab certificate, never regenerates the CA"`.

### Task 3: Malcolm deploy verbs, and the R770 Malcolm config

**Interfaces:** `r770-malcolm-deploy.sh` gains these verbs, all run as root:
- `install <bundle-dir>`
- `configure <config-json>`
- `auth <bundle-dir> --password-file F [--user analyst] [--force]`
- `bind-loopback`
- `start`
- `health [--timeout S]`
- `verify --password-file F`

`load` and `assert-tags` are unchanged. Env: `MALCOLM_ROOT` (default /opt/malcolm), `MALCOLM_COMPOSE`, `MALCOLM_START` (default `./scripts/start --quiet`), `MALCOLM_POLL_SECS`, `MALCOLM_TMPDIR`, `VERIFY_TIMEOUT`, `VERIFY_CAPTURE_SECS`.

- [ ] **Step 1:** Check the base has not moved: `git diff --quiet 0ade78f HEAD -- scripts/r770-malcolm-deploy.sh tests/malcolm-deploy.bats`. Then copy both drafts and check their sha256.
- [ ] **Step 2:** Create `config/malcolm/malcolm-config.json` from the rehearsal config, changing only these fields. Suricata is off by decision of record; the paths are from buildout §3.2.

```bash
python3 - <<'PY'
import json
d = json.load(open("config/malcolm/malcolm-config-rehearsal.json"))
c = d["configuration"]
c.update({"autoSuricata": False, "liveSuricata": False, "suricataRuleUpdate": False,
          "pcapDir": "/data/pcap/raw", "indexDir": "/data/index", "pcapNodeName": "r770"})
json.dump(d, open("config/malcolm/malcolm-config.json", "w"), indent=2, sort_keys=False)
open("config/malcolm/malcolm-config.json", "a").write("\n")
PY
python3 -c 'import json;c=json.load(open("config/malcolm/malcolm-config.json"))["configuration"];print({k:c[k] for k in ("autoSuricata","liveSuricata","suricataRuleUpdate","pcapDir","indexDir","pcapNodeName")})'
```
Expected: exactly those six values. `git diff --no-index` against the rehearsal file shows only those six lines.
- [ ] **Step 3:** In `docs/plans/r770-install-runbook.md` Part 8, replace the hand commands in 8.1, 8.1a and 8.4 with the script verbs, in order: `install`, `configure …/site/config/malcolm/malcolm-config.json`, `auth --password-file`, `bind-loopback`, `start`, `health`, `verify`. Keep the explanatory prose. State that `start` must be `--quiet` and that the port line has no `/tcp`.
- [ ] **Step 4:** `tests/README.md` row for `malcolm-deploy.bats`: update it to cover the new verbs. Leave `tests/lint.bats` alone: the script is already in its list, or add it if not.
- [ ] **Step 5:** `git add`, then `./tests/run.sh` must be green. Commit: `"Malcolm deploy: install/configure/auth/bind-loopback/start/health/verify; R770 Malcolm config (Suricata off, data on /data)"`.

### Task 4: `scripts/r770-portal.sh`

**Interfaces:** `r770-portal.sh [plan|apply|verify [--host IP] [--cacert F] [--user U] [--password-file F]]`. It needs `/etc/nginx/ssl/*` (Task 2) and Malcolm's `nginx/htpasswd` (Task 3 `auth`). Env: `PORTAL_SITE`, `PORTAL_NGINX_DIR`, `PORTAL_WWW`, `PORTAL_MALCOLM_HTPASSWD`, `PORTAL_SITES`, `PORTAL_MKDOCS_IMAGE`.

- [ ] **Step 1:** Copy the drafts and check their sha256.
- [ ] **Step 2:** Register it (lint no-exclusions line, `tests/README.md` count and row, `README.md` row, and add `scripts/r770-portal.sh` to `SITE_REQUIRED_SCRIPTS` in `scripts/r770-bundle.sh`). Also `docs/plans/r770-install-runbook.md` Part 10: the portal steps become `r770-portal.sh apply` then `verify`.
- [ ] **Step 3:** `git add`, then `./tests/run.sh` green. Commit: `"Add r770-portal.sh — portal/malcolm/docs vhosts, one login, nginx -t before any reload"`.

### Task 5: `scripts/r770-ufw.sh`

**Interfaces:** `r770-ufw.sh [plan|apply [--minutes N]|confirm|verify|revert]`. Env: `UFW_RUN_DIR`, `UFW_BACKUP_DIR`, `UFW_ETC_DIR`, `UFW_SSH_CONNECTION`, `UFW_DRY_RUN`.

- [ ] **Step 1:** Copy the drafts and check their sha256.
- [ ] **Step 2:** Register it (lint line, `tests/README.md` count and row, `README.md` row, `SITE_REQUIRED_SCRIPTS`). Also a new short section in `docs/plans/r770-install-runbook.md`, "UFW (gated)":
  - run `plan`, then `apply`;
  - open a NEW ssh session and run `confirm` within the window, or UFW turns itself off;
  - then `verify`;
  - rollback is `revert`.
- [ ] **Step 3:** The draft's own tests found three bare `! kill -0` assertions in `tests/airgap-sim.bats` that bats cannot fail (a `!` command is only an assertion when it is the last line). Fix them in place with `run kill -0 …; [ "$status" -ne 0 ]`, and prove each fails if its sleeper is left alive (temporarily comment out the kill, see red, restore).
- [ ] **Step 4:** `git add`, then `./tests/run.sh` green. Commit: `"Add r770-ufw.sh — discovered mgmt-only policy with a dead-man auto-revert; fix vacuous airgap-sim assertions"`.

---

### Task 6: Prepare VM 9771 (controller; root once)

- [ ] **Step 1: Host check.** (Operator 2026-09-26: stop 9770 with the token first; root@pam once, for this check and Step 3 only.) Using a root ticket, read-only, get the host's used and total memory and every running guest. Proceed only if host free memory minus 12 GiB is at least 3 GiB, with 9771 stopped. Otherwise stop and tell the operator which guest to stop.
- [ ] **Step 2: Snapshot (token).** `r770-staging-vm.sh` has no snapshot verb, so `POST /nodes/proxmox/qemu/9771/snapshot` with `snapname=installed-2026-09-26`, `vmstate=0`, using the token config-on-stdin form. Poll the task to OK.
- [ ] **Step 3: Memory (root).** `PUT /nodes/proxmox/qemu/9771/config` with `memory=12288`. Read the config back and confirm `memory: 12288`, `balloon: 0`.
- [ ] **Step 4:** `STAGING_VMID=9771 ./scripts/r770-staging-vm.sh start && … wait-ssh 300`. Then `free -g` on the VM shows about 11–12.

### Task 7: Put `site/` into the bundle on 9771

- [ ] **Step 1:** On 9771, with internet still open, check out the branch that holds Tasks 1–5 in `~/simlab-build`: `git fetch` and `git checkout <branch> && git pull`.
- [ ] **Step 2:** `sudo -E BUNDLE_DIR=$(cat ~/bundle-dir) ./scripts/r770-offline-fetch.sh --only site,manifest`, then `./scripts/r770-bundle.sh verify $(cat ~/bundle-dir) --strict`. Expected: **PASS**, with `site/` present and every required script found.
- [ ] **Step 3:** Refresh the staged copy the deploy runs from: `sudo rsync -a --delete $(cat ~/bundle-dir)/ /data/staging/$(basename $(cat ~/bundle-dir))/`, then `verify --strict` there must PASS too.

### Task 8: Deploy offline (controller; everything from `/data/staging/bundle-*/site/scripts/`)

Set `S=/data/staging/<bundle>` and `X=$S/site/scripts`.

- [ ] **Step 1:** Air gap: `sudo $X/r770-airgap-sim.sh block --minutes 240`, and prove it with curl failures (as in the install test).
- [ ] **Step 2: Analyst password, on the VM only.** `sudo install -m 600 /dev/null /root/analyst-pw && sudo sh -c 'openssl rand -base64 18 > /root/analyst-pw'`. Never print it. Copy it to the session for the outside checks: `ssh … 'sudo cat /root/analyst-pw' > /root/.config/simlab/vm9771-analyst-pw && chmod 600 …`. It is a test credential, outside the repo.
- [ ] **Step 3:** `sudo $X/r770-lab-ca.sh apply && sudo $X/r770-lab-ca.sh verify`.
- [ ] **Step 4:** Create the data directories (they are not LVs on 9771): `sudo mkdir -p /data/pcap/raw /data/index`. Then, **under tmux with a tee'd log**:

```bash
sudo $X/r770-malcolm-deploy.sh install "$S" && \
sudo $X/r770-malcolm-deploy.sh configure "$S/site/config/malcolm/malcolm-config.json" && \
sudo $X/r770-malcolm-deploy.sh auth "$S" --password-file /root/analyst-pw && \
sudo $X/r770-malcolm-deploy.sh bind-loopback && \
sudo $X/r770-malcolm-deploy.sh start && \
sudo $X/r770-malcolm-deploy.sh health --timeout 900
```
If any step fails, stop there and debug with superpowers:systematic-debugging. Any fix goes back through a repo change and review, never a hand edit on the VM.
- [ ] **Step 5:** `sudo $X/r770-portal.sh apply && sudo $X/r770-portal.sh verify --user analyst --password-file /root/analyst-pw`.
- [ ] **Step 6:** `sudo $X/r770-malcolm-deploy.sh verify --password-file /root/analyst-pw` (PCAP indexed by Arkime, Zeek logs present, zeek container healthy).
- [ ] **Step 7: UFW.** Every call is `sudo --preserve-env=SSH_CONNECTION $X/r770-ufw.sh …`. Run `plan`, then `apply --minutes 10`, then **from a NEW ssh session** (`ssh -o ControlMaster=no -o ControlPath=none …`) run `confirm`, then `verify`. (Amended 2026-09-26 after the Task 5 review: sudo strips SSH_CONNECTION, and a multiplexed session is not a new connection.)

### Task 9: Verify from outside, record, snapshot (controller)

- [ ] **Step 1:** From this session:
  - export the CA: `ssh … 'sudo $X/r770-lab-ca.sh export-ca' > /root/.config/simlab/vm9771-lab-ca.crt`;
  - then `./scripts/r770-portal.sh verify --host 192.168.4.26 --cacert /root/.config/simlab/vm9771-lab-ca.crt --user analyst --password-file /root/.config/simlab/vm9771-analyst-pw`. Expect 401 then 200 for all three names;
  - Malcolm pages through the portal, as in the 2026-09-16 set: `/` 200, `/arkime/` 302, `/dashboards/` 302;
  - from outside: `nc -z -w3 192.168.4.26 8443` and an unused high port must **fail**, and 22 and 443 must succeed.
- [ ] **Step 2:** Lift the air gap. Collect every log first (`&&`-chained scp), then run a credential grep over the evidence. Write `state/inventory/staging-analyst-stack-2026-09-26.md`, covering each step's result, the listener table, the health summary and the PCAP result, plus the raw logs in a folder beside it. Update BUILD-STATE: a log entry, and the sub-project 2 status "proven on 9771; R770 pending sub-projects 0–1". `git add`, suite green, commit.
- [ ] **Step 3:** Stop 9771, then snapshot it as `analyst-stack-2026-09-26` with the token. Leave 9771 at 12 GiB and **stopped**, and record that it must only start when the host has room.
