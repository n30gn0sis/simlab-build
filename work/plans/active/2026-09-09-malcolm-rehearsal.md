# Malcolm Offline Deployment Rehearsal Implementation Plan

> **STATUS: NOT STARTED.** Requires staging VM 9770 and `bundle-20260908`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, on the staging VM before the media crosses the air gap, that `bundle-20260908`'s images deploy Malcolm with zero network access, and settle by experiment whether Malcolm works behind the lab's Nginx portal or must own port 443 itself.

**Architecture:** Simulate the air gap on staging VM 9770 with a reversible, auto-expiring egress block; `docker load` Malcolm from the bundle tarball; configure it via the installer's `--defaults` + `--export-malcolm-config-file` so the configuration becomes a replayable artifact. Then stand up **both** port arrangements — Malcolm owning `0.0.0.0:443` (A) versus Malcolm rebound to `127.0.0.1:8443` behind a host Nginx portal (B) — and decide from measured evidence which survives Keycloak's redirect flow and Dashboards' websockets.

**Tech Stack:** Docker CE 29.8.0 · Malcolm 26.08.0 (23 images, 12 in the `malcolm` profile) · Nginx · iptables · bats + shellcheck (existing gate)

**Spec:** `docs/plans/r770-network-lab-buildout.md` §7, §9, §4.5, §13; `PRD.md` §3.4, §7, §10; `.claude/commands/import-bundle.md`; `state/inventory/bundles.md`.

## Why this exists

The repo specifies a portal and specifies Malcolm, but **never specifies how they meet.** An exploration of every design document found no file addressing the double-proxy question: how host Nginx at `malcolm.lab` relates to Malcolm's own `nginx-proxy` container, what port Malcolm binds, whether its TLS is terminated or passed through, or how its auth interacts with the portal. `buildout:315` and `PRD.md:73` assert every web service is localhost-bound behind the portal; **Malcolm's stock compose is not that** — it publishes `0.0.0.0:443:443`. That is an unspecified integration, not a decision.

Two facts make resolving it now, on staging, materially cheaper than later:

- Malcolm 26.08.0 ships **Keycloak** and **PostgreSQL** as first-class services. Identity providers behind a second reverse proxy are the classic source of redirect loops, and Malcolm's installer exposes no setting for the 443 bind (`open_ports.py` covers Logstash, OpenSearch, Filebeat TCP, SFTP and Syslog — not the main port).
- On the R770 this is discovered *after* the media has crossed the gap, where fixing it costs a full bundle cycle.

There is also **no validation criterion for the portal anywhere** — neither buildout §13 nor PRD §10 has a line item for "portal reachable over TLS" or "Malcolm usable through the portal". Task 5 adds one.

## Global Constraints

- **This is a REHEARSAL on staging VM 9770 (192.168.4.28), not the R770.** The R770 is unreachable from this network (10.10.10.31 vs 192.168.4.0/22), has no Docker, and has received no bundle. Nothing here touches it.
- **Never break SSH to the VM.** Every egress block exempts `192.168.4.0/22` and loopback, and carries a timed auto-revert. Losing the VM means Proxmox console recovery.
- **Never modify Proxmox guests other than 9770.** LXC 101 runs this session; VMs 100 and 108 stay stopped.
- **Proves deployment and integration, NOT performance.** VM 9770 has **8 GiB / 6 cores**; the R770 budget is ~64 GB (`buildout:295-298`) and Malcolm's installer defaults OpenSearch to **16g**. Use `4g` and expect a functional-but-slow stack.
- **Bundle of record:** `~/r770/bundle-20260908` — 15 GB, 1616 files, `verify` PASS WITH WARNINGS (2 accepted docs-mirror WARNs).
- **Malcolm images are already in the VM's daemon** from the fetch. Task 2 must remove them first or the offline-load test proves nothing.
- **Evidence discipline** (`.claude/agents/validation-runner.md`): expected value vs observed value, never adjectives; capture the exact command *and* the exact output line; a check that cannot run is **SKIPPED with a reason**, never silently omitted.
- **No secrets in git** (CLAUDE.md rule 7). Malcolm generates auth material during configure. Never commit anything under `config/*.env`.
- **`docker` and `ssh` are behind an `ask` gate** in `.claude/settings.json:39-45` — expect approval prompts.
- Commit style: imperative, capitalized, no `feat:`/`fix:` prefix.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/r770-airgap-sim.sh` *(new)* | Reversible egress block with mandatory auto-revert: `block` / `unblock` / `status`. The safety-critical piece. |
| `scripts/r770-malcolm-deploy.sh` *(new)* | Offline deploy: `docker load` from the bundle, then assert every tag in `image-list.txt`. |
| `tests/airgap-sim.bats` *(new)* | Tests the *generated rules*, never applies them. |
| `tests/malcolm-deploy.bats` *(new)* | Tests tag-assertion against a stubbed `docker` CLI. |
| `config/malcolm/malcolm-config-rehearsal.json` *(new)* | Exported Malcolm config — the replayable artifact. |
| `config/malcolm/docker-compose.override.yml` *(new)* | Arrangement B: rebinds `nginx-proxy` to `127.0.0.1:8443`. |
| `config/nginx/malcolm.lab.conf` *(new)* | Portal vhost with the forwarded headers and websocket upgrade Keycloak and Dashboards need. |
| `state/inventory/malcolm-rehearsal-2026-09-09.md` *(new)* | Evidence table and the arrangement decision. |
| `docs/plans/r770-network-lab-buildout.md` *(modify §9, §13)* | Reconcile the design against measurement; add the missing portal criterion. |

Follow the house test pattern from `tests/bundle-verify.bats:1-11` (`load helpers/fixtures`, `$BATS_TEST_TMPDIR`, `$BATS_TEST_DIRNAME/../scripts/...`). Reuse `make_bundle` from `tests/helpers/fixtures.bash:6-24` — it already models the exact tarball names the import consumes.

---

### Task 1: Air-gap simulator with a mandatory auto-revert

The one piece that can lock us out. It gets tests and a dead-man timer before it touches a real interface.

**Files:** Create `scripts/r770-airgap-sim.sh`, `tests/airgap-sim.bats`

**Interfaces:**
- Produces: `block [--minutes N]` (default 30) — DROPs OUTPUT except `192.168.4.0/22`, loopback and Docker bridges, and schedules an unconditional `unblock`. `unblock` — removes rules, cancels timer. `status` — `BLOCKED`/`OPEN` plus seconds remaining.
- Honours `AIRGAP_DRY_RUN=1` (print rules, apply nothing) and `AIRGAP_LAN`.

- [ ] **Step 1: Write the failing tests**

Create `tests/airgap-sim.bats`:

```bash
#!/usr/bin/env bats
# Test the GENERATED RULES, not their application. Applying real firewall
# rules from a test suite is how a machine locks itself out.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-airgap-sim.sh"
    export AIRGAP_DRY_RUN=1
    export AIRGAP_LAN=192.168.4.0/22
}

@test "block always exempts the management LAN" {
    run "$SCRIPT" block
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"192.168.4.0/22"* ]]
    [[ "$output" == *"ACCEPT"* ]]
}

@test "block always exempts loopback" {
    run "$SCRIPT" block
    [[ "$output" == *"127.0.0.0/8"* ]]
}

@test "the LAN accept rule precedes the catch-all drop" {
    run "$SCRIPT" block
    lan=$(echo "$output" | grep -n '192.168.4.0/22' | head -1 | cut -d: -f1)
    drop=$(echo "$output" | grep -n 'DROP' | tail -1 | cut -d: -f1)
    [ "$lan" -lt "$drop" ]
}

@test "block refuses to run without scheduling an auto-revert" {
    run "$SCRIPT" block
    [[ "$output" == *"auto-revert"* ]]
}

@test "an invalid --minutes value is rejected, not silently defaulted" {
    run "$SCRIPT" block --minutes abc
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"minutes"* ]]
}

@test "unblock is idempotent" {
    run "$SCRIPT" unblock
    [ "$status" -eq 0 ]
    run "$SCRIPT" unblock
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/airgap-sim.bats`
Expected: 6 failures, status 127 — script absent.

- [ ] **Step 3: Write the implementation**

Create `scripts/r770-airgap-sim.sh`:

```bash
#!/usr/bin/env bash
#
# r770-airgap-sim.sh — simulate the air gap on the staging VM so an offline
# deployment can be rehearsed while we still have internet to fix what breaks.
#
#   block [--minutes N]   drop internet egress, keep the LAN and loopback
#   unblock               restore egress, cancel the timer
#   status                BLOCKED / OPEN, plus time remaining
#
# SAFETY: block ALWAYS schedules an unconditional unblock (default 30 min).
# A firewall change you cannot undo from the far side of that firewall is the
# exact failure this exists to prevent -- the same discipline as `netplan try`
# in the R770 runbook.
#
# AIRGAP_DRY_RUN=1 prints the rules instead of applying them (used by tests).
set -euo pipefail

LAN="${AIRGAP_LAN:-192.168.4.0/22}"
DRY="${AIRGAP_DRY_RUN:-0}"
MARK="r770-airgap-sim"
TIMER="/run/${MARK}.deadline"

die() { echo "r770-airgap-sim: $*" >&2; exit 1; }

apply() { if [ "$DRY" = "1" ]; then echo "iptables $*"; else iptables "$@"; fi; }

cmd_block() {
    local minutes=30
    while [ $# -gt 0 ]; do
        case $1 in
            --minutes)
                minutes=${2:-}
                [[ "$minutes" =~ ^[0-9]+$ ]] || die "--minutes must be a whole number, got '${minutes:-}'"
                [ "$minutes" -ge 1 ] && [ "$minutes" -le 240 ] || die "--minutes must be 1-240"
                shift ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done

    # Order is load-bearing: every ACCEPT must precede the catch-all DROP.
    apply -I OUTPUT 1 -o lo -j ACCEPT
    apply -I OUTPUT 2 -d "127.0.0.0/8" -j ACCEPT
    apply -I OUTPUT 3 -d "$LAN" -j ACCEPT
    apply -I OUTPUT 4 -d 172.16.0.0/12 -j ACCEPT      # docker bridges
    apply -A OUTPUT -m comment --comment "$MARK" -j DROP

    echo "auto-revert scheduled in ${minutes} minute(s)"
    if [ "$DRY" != "1" ]; then
        date -d "+${minutes} minutes" +%s > "$TIMER"
        setsid bash -c "sleep $((minutes*60)); '$0' unblock" >/dev/null 2>&1 &
    fi
}

cmd_unblock() {
    if [ "$DRY" = "1" ]; then echo "iptables -F OUTPUT (dry run)"; return 0; fi
    while iptables -D OUTPUT -m comment --comment "$MARK" -j DROP 2>/dev/null; do :; done
    iptables -D OUTPUT -d 172.16.0.0/12 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -d "$LAN" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -d "127.0.0.0/8" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    rm -f "$TIMER"
    echo "egress restored"
}

cmd_status() {
    if iptables -C OUTPUT -m comment --comment "$MARK" -j DROP 2>/dev/null; then
        if [ -r "$TIMER" ]; then
            echo "BLOCKED ($(( $(cat "$TIMER") - $(date +%s) ))s until auto-revert)"
        else
            echo "BLOCKED (no timer found - run unblock)"
        fi
    else
        echo "OPEN"
    fi
}

case "${1:-}" in
    block)   shift; cmd_block "$@" ;;
    unblock) cmd_unblock ;;
    status)  cmd_status ;;
    *)       die "usage: r770-airgap-sim.sh block [--minutes N] | unblock | status" ;;
esac
```

Then `chmod +x scripts/r770-airgap-sim.sh`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/airgap-sim.bats`
Expected: `6 tests, 0 failures`.

- [ ] **Step 5: Prove the auto-revert actually fires**

An untested safety mechanism is worth nothing — this repo has already shipped two checks that were silently dead. On the VM:

```bash
sudo ./scripts/r770-airgap-sim.sh block --minutes 1
./scripts/r770-airgap-sim.sh status
curl -sS -o /dev/null --max-time 8 https://ghcr.io && echo "UNEXPECTED: egress open" || echo "egress blocked (expected)"
sleep 75
./scripts/r770-airgap-sim.sh status
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://ghcr.io
```

Expected: `BLOCKED (~60s)` → egress fails → `OPEN` → `200`. **If status does not return to OPEN unaided, stop and fix the timer.** SSH must stay alive throughout; if it drops, recover via Proxmox noVNC and flush the rules.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-airgap-sim.sh tests/airgap-sim.bats
git commit -m "Add a reversible air-gap simulator for the staging VM

Lets the offline deployment be rehearsed while we still have internet to fix
what breaks. block always exempts the management LAN and loopback and always
schedules an unconditional auto-revert, because a firewall change you cannot
undo from the far side of that firewall is the failure this exists to
prevent. Tests assert the generated rules rather than applying them."
```

---

### Task 2: Offline deploy — prove the images load with no network

**Files:** Create `scripts/r770-malcolm-deploy.sh`, `tests/malcolm-deploy.bats`

**Interfaces:**
- Consumes: Task 1's simulator; `~/r770/bundle-20260908/malcolm/`.
- Produces: `load <bundle-dir>` — `docker load` then assert tags. `assert-tags <bundle-dir>` — the check alone. Both exit non-zero naming every missing tag.

- [ ] **Step 1: Write the failing tests**

Create `tests/malcolm-deploy.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-malcolm-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE/malcolm"
    cat > "$BUNDLE/malcolm/image-list.txt" <<'EOF'
ghcr.io/idaholab/malcolm/arkime:26.08.0
ghcr.io/idaholab/malcolm/zeek:26.08.0
EOF
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# Stub the docker CLI so the suite never touches a real daemon.
stub_docker_reporting() {
    { echo '#!/usr/bin/env bash'
      echo 'if [ "$1" = "image" ] && [ "$2" = "ls" ]; then'
      for t in "$@"; do echo "  echo '$t'"; done
      echo 'fi'
      echo 'exit 0'
    } > "$BATS_TEST_TMPDIR/bin/docker"
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

@test "assert-tags passes when every listed tag is present" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:26.08.0 ghcr.io/idaholab/malcolm/zeek:26.08.0
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "assert-tags FAILS when a tag is missing, and names it" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:26.08.0
    run "$SCRIPT" assert-tags "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zeek:26.08.0"* ]]
}

@test "assert-tags fails loudly when image-list.txt is missing" {
    rm "$BUNDLE/malcolm/image-list.txt"
    run "$SCRIPT" assert-tags "$BUNDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"image-list.txt"* ]]
}

@test "a bundle directory that does not exist is rejected" {
    run "$SCRIPT" assert-tags /nonexistent
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/malcolm-deploy.bats`
Expected: 4 failures, status 127.

- [ ] **Step 3: Write the implementation**

Create `scripts/r770-malcolm-deploy.sh`:

```bash
#!/usr/bin/env bash
#
# r770-malcolm-deploy.sh — load Malcolm's images from a bundle and prove the
# load was COMPLETE. Runs with no network, which is the condition it must
# satisfy on the real air-gapped R770.
#
#   load <bundle-dir>          docker load the tarball, then assert every tag
#   assert-tags <bundle-dir>   the tag check alone
#
# `docker load` reports success even when the resulting tag set is incomplete,
# which is why import-bundle.md step 3b requires verifying loaded tags against
# the bundle's own image-list files.
set -euo pipefail

die() { echo "r770-malcolm-deploy: $*" >&2; exit 1; }

image_list() {
    local f="$1/malcolm/image-list.txt"
    [ -s "$f" ] || die "missing or empty $f — is this a bundle directory?"
    grep -vE '^[[:space:]]*(#|$)' "$f"
}

cmd_assert_tags() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: assert-tags <bundle-dir>"
    [ -d "$dir" ] || die "not a directory: $dir"

    local present missing=0
    present=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

    while IFS= read -r want; do
        if printf '%s\n' "$present" | grep -qxF "$want"; then
            echo "ok      $want"
        else
            echo "MISSING $want"
            missing=$((missing + 1))
        fi
    done < <(image_list "$dir")

    [ "$missing" -eq 0 ] ||
        die "$missing image(s) missing after load — the tarball is incomplete or the load failed"
    echo "all images present"
}

cmd_load() {
    local dir=${1:-}
    [ -n "$dir" ] || die "usage: load <bundle-dir>"
    local tar
    tar=$(find "$dir/malcolm" -maxdepth 1 -name 'malcolm-images-*.tar.gz' | head -1)
    [ -n "$tar" ] || die "no malcolm-images-*.tar.gz under $dir/malcolm"
    echo "loading $tar ..."
    docker load -i "$tar"
    cmd_assert_tags "$dir"
}

case "${1:-}" in
    load)        shift; cmd_load "$@" ;;
    assert-tags) shift; cmd_assert_tags "$@" ;;
    *)           die "usage: r770-malcolm-deploy.sh load|assert-tags <bundle-dir>" ;;
esac
```

Then `chmod +x scripts/r770-malcolm-deploy.sh`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/malcolm-deploy.bats`
Expected: `4 tests, 0 failures`.

- [ ] **Step 5: The real offline load — remove the images first, or this proves nothing**

```bash
docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -c '^ghcr.io/idaholab/malcolm/'   # expect 23
docker rmi $(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^ghcr.io/idaholab/malcolm/')
docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -c '^ghcr.io/idaholab/malcolm/'   # expect 0

sudo ./scripts/r770-airgap-sim.sh block --minutes 60
./scripts/r770-airgap-sim.sh status
docker pull ghcr.io/idaholab/malcolm/arkime:26.08.0 && echo "UNEXPECTED: pull worked" || echo "pull blocked (correct)"

time ./scripts/r770-malcolm-deploy.sh load ~/r770/bundle-20260908
```

Expected: the pull fails; `load` prints `ok` for all 23 tags then `all images present`. **This is the headline result** — proof the bundle can populate an air-gapped daemon.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-malcolm-deploy.sh tests/malcolm-deploy.bats
git commit -m "Add an offline Malcolm image loader with tag assertion

docker load reports success even when the resulting tag set is incomplete,
so the load is verified against the bundle's own image-list.txt and every
missing tag is named. Tests stub the docker CLI so the suite never touches a
real daemon."
```

---

### Task 3: Arrangement A — Malcolm owns 443 (baseline)

**Files:** Create `config/malcolm/malcolm-config-rehearsal.json`, `state/inventory/malcolm-rehearsal-2026-09-09.md`

**Interfaces:** Consumes Task 2's loaded images. Produces a Malcolm install at `~/malcolm` and an exported config Task 4 re-imports **unchanged**, so the two arrangements differ only in the port binding.

- [ ] **Step 1: Unpack and dry-run the installer**

Still air-gapped:

```bash
mkdir -p ~/malcolm && cd ~/malcolm
unzip -q ~/r770/bundle-20260908/malcolm/malcolm-26.08.0-docker_install.zip
cp ~/r770/bundle-20260908/malcolm/docker-compose.yml .
find . -maxdepth 2 -name 'install.py'
python3 ./install.py --defaults --dry-run 2>&1 | tail -20
```

Expected: a summary of what it *would* write, nothing changed.

- [ ] **Step 2: Configure with a heap this VM can satisfy**

The installer defaults OpenSearch to `16g`; the VM has 8 GiB.

```bash
python3 ./install.py --defaults --configure \
  --export-malcolm-config-file ~/malcolm-config-rehearsal.json 2>&1 | tail -30
grep -iE 'OPENSEARCH_JAVA_OPTS|MALCOLM_PROFILE' config/*.env
```

If the export carries `16g`, edit to `4g` and re-run with `--import-malcolm-config-file`. **Record the exact key changed** — Task 4 reuses this file untouched.

- [ ] **Step 3: Start the profile and let it settle**

```bash
docker compose --profile malcolm up -d
sleep 180
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
docker compose ps --format '{{.Service}} {{.Status}}' | grep -iE 'unhealthy|restarting|exited' || echo "no failing services"
free -h; docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' | head -15
```

Expected: 12 services running. **On 8 GiB some may OOM or flap.** Record which, with `docker compose logs <svc> | tail -30` each. That list is a resource finding for §8, not a rehearsal failure.

- [ ] **Step 4: Probe through Malcolm's own proxy**

```bash
curl -skI https://127.0.0.1:443/ | head -3
for p in / /arkime/ /dashboards/ /netbox/ /auth/; do
  curl -sk "https://127.0.0.1:443$p" -o /dev/null -w "$p %{http_code} -> %{redirect_url}\n"
done
```

Expected: 200/302, not 502/504. **Record every redirect target verbatim** — where Keycloak sends the browser is the single fact that decides whether arrangement B can work. An absolute redirect to `127.0.0.1` will not survive a reverse proxy.

- [ ] **Step 5: Record the baseline and commit**

Write findings into `state/inventory/malcolm-rehearsal-2026-09-09.md` under "Arrangement A" using the validation-runner format (check · expected · observed · verdict · evidence line).

```bash
grep -icE 'password|secret|token|apikey' ~/malcolm-config-rehearsal.json
cp ~/malcolm-config-rehearsal.json config/malcolm/
git add config/malcolm/ state/inventory/malcolm-rehearsal-2026-09-09.md
git commit -m "Record Malcolm arrangement A baseline (Malcolm owns 443)"
```

**If that grep returns non-zero, do not commit the file** — note the offending keys by name only and commit a redacted version (CLAUDE.md rule 7).

---

### Task 4: Arrangement B — Malcolm behind the portal

**Files:** Create `config/malcolm/docker-compose.override.yml`, `config/nginx/malcolm.lab.conf`

**Interfaces:** Consumes Task 3's config file, re-imported unchanged. Produces Malcolm on `127.0.0.1:8443` with host Nginx terminating TLS on 443 for `malcolm.lab`.

- [ ] **Step 1: Write the compose override**

Create `config/malcolm/docker-compose.override.yml`:

```yaml
# Arrangement B: take Malcolm's nginx-proxy off 0.0.0.0:443 so the host portal
# can own 443, per buildout section 9 ("every web service localhost-bound
# behind Nginx TLS+auth"). Malcolm's installer has no setting for this bind --
# open_ports.py covers Logstash, OpenSearch, Filebeat TCP, SFTP and Syslog, but
# not the main 443 -- so an override file is the only mechanism.
services:
  nginx-proxy:
    ports:
      - "127.0.0.1:8443:443"
      - "127.0.0.1:9200:9200"
```

- [ ] **Step 2: Restart onto the new binding**

The repo is not checked out on the VM — Task 2 only shipped `scripts/`. Sync `config/` the same
way, through the Proxmox host (the VM is key-only from there):

```bash
# from the repo on the staging side:
tar czf - config/ | ssh root@192.168.4.21 'cat > /tmp/r770-config.tgz'
ssh root@192.168.4.21 'scp -q /tmp/r770-config.tgz ubuntu@192.168.4.28:/tmp/ && \
  ssh ubuntu@192.168.4.28 "cd ~/r770 && tar xzf /tmp/r770-config.tgz && ls config/malcolm config/nginx"'
```

```bash
cd ~/malcolm
cp ~/r770/config/malcolm/docker-compose.override.yml .
docker compose config | grep -A4 'nginx-proxy:' | grep -A3 ports
docker compose --profile malcolm down && docker compose --profile malcolm up -d
sleep 120
ss -ltnp | grep -E ':443|:8443'
```

Expected: `8443` on `127.0.0.1`, **nothing on `0.0.0.0:443`**. If 443 is still bound, the override was not merged — the `docker compose config` output above shows whether it was.

- [ ] **Step 3: Write the portal vhost**

Create `config/nginx/malcolm.lab.conf`:

```nginx
# Portal vhost: malcolm.lab -> Malcolm's own nginx-proxy on 127.0.0.1:8443.
# Rehearsal uses a self-signed cert; the real deployment issues one from the
# internal easy-rsa CA (buildout section 9, generated on the gapped side).
server {
    listen 443 ssl;
    http2 on;
    server_name malcolm.lab;

    ssl_certificate     /etc/nginx/ssl/malcolm.lab.crt;
    ssl_certificate_key /etc/nginx/ssl/malcolm.lab.key;

    client_max_body_size 0;      # PCAP uploads are large
    proxy_read_timeout 300s;

    location / {
        proxy_pass https://127.0.0.1:8443;
        proxy_ssl_verify off;                 # Malcolm's internal cert is self-signed

        # Keycloak builds absolute redirects from these. Get them wrong and the
        # login loop sends the browser to 127.0.0.1.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;

        # Arkime and OpenSearch Dashboards are SPAs using websockets.
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

- [ ] **Step 4: Install Nginx from the bundle and enable the vhost**

Installing from `apt/` rather than the internet is the more faithful rehearsal — and it exercises the local-repo half of `import-bundle.md` step 3a:

```bash
sudo apt-get -y -o Dir::Etc::sourcelist=/dev/null \
  -o Dir::Etc::sourceparts=/dev/null install \
  ~/r770/bundle-20260908/apt/nginx*.deb || sudo apt-get -y install nginx
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -keyout /etc/nginx/ssl/malcolm.lab.key -out /etc/nginx/ssl/malcolm.lab.crt \
  -subj "/CN=malcolm.lab" -addext "subjectAltName=DNS:malcolm.lab"
sudo cp ~/r770/config/nginx/malcolm.lab.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/malcolm.lab.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Expected: `nginx -t` reports syntax ok. If the local-repo install fails for dependencies, note it — that is itself a finding about the curated APT set.

- [ ] **Step 5: The comparison that decides the arrangement**

```bash
for p in / /arkime/ /dashboards/ /netbox/ /auth/; do
  curl -sk "https://malcolm.lab$p" -o /dev/null --resolve malcolm.lab:443:127.0.0.1 \
       -w "$p %{http_code} -> %{redirect_url}\n"
done
curl -skI https://malcolm.lab/dashboards/ --resolve malcolm.lab:443:127.0.0.1 | grep -iE 'upgrade|connection|location'
sudo tail -30 /var/log/nginx/error.log
```

Expected: statuses matching arrangement A, and **every `redirect_url` naming `malcolm.lab`, never `127.0.0.1` or `:8443`**. A redirect to `127.0.0.1` means Keycloak is ignoring the forwarded headers — the specific failure this task exists to detect.

- [ ] **Step 6: Commit**

```bash
git add config/malcolm/docker-compose.override.yml config/nginx/malcolm.lab.conf
git commit -m "Add arrangement B: Malcolm behind the portal on 127.0.0.1:8443

Malcolm's compose binds nginx-proxy to 0.0.0.0:443, which collides with the
portal owning 443. The installer exposes no setting for that bind, so an
override file is the mechanism. The vhost carries the forwarded headers
Keycloak builds redirects from and the websocket upgrade Dashboards needs."
```

---

### Task 5: Decide from evidence, and close the documentation gaps it exposed

**Files:** Modify `state/inventory/malcolm-rehearsal-2026-09-09.md`, `docs/plans/r770-network-lab-buildout.md` (§9, §13), `state/BUILD-STATE.md`

- [ ] **Step 1: Write the comparison table**

One row per probe path, one column per arrangement: HTTP status, redirect target, and whether Dashboards rendered in a browser. State which arrangement works and quote the output proving it. **If neither works cleanly, say so** — a rehearsal that discovers Malcolm cannot sit behind a second proxy is a success, because learning it on the R770 costs a bundle cycle.

- [ ] **Step 2: Reconcile §9 against measurement**

`buildout:315` asserts every web service is localhost-bound behind the portal. If B works, record that Malcolm needs a compose override to comply and reference the file. If it does not, amend §9 to record Malcolm as a **documented exception with the measured reason**. CLAUDE.md's rule: when docs and reality disagree, reality wins and the docs get updated.

- [ ] **Step 3: Add the missing portal validation criterion**

Neither buildout §13 nor `PRD.md` §10 has any portal line item — the nearest is `PRD.md:98` (GNS3 API via portal). Add to §13:

```markdown
- **Portal:** each `.lab` vhost resolves and answers over TLS with the internal CA trusted;
  `malcolm.lab` serves Arkime and Dashboards through the proxy with no redirect escaping the
  vhost name; websocket upgrade confirmed on `/dashboards/`.
```

- [ ] **Step 4: Record resource findings for Phase 10**

Note the measured memory footprint and any service that would not stay up on 8 GiB. §8 currently models this stack at ~64 GB with no measurement behind it.

- [ ] **Step 5: Restore the VM and commit**

```bash
./scripts/r770-airgap-sim.sh unblock && ./scripts/r770-airgap-sim.sh status   # expect OPEN
cd ~/malcolm && docker compose --profile malcolm down
./tests/run.sh                                                                # expect 36 tests, 0 failures
git add state/ docs/plans/r770-network-lab-buildout.md
git commit -m "Record the Malcolm portal-integration decision from measurement"
```

---

## Verification

The rehearsal succeeds when all hold:

1. `./tests/run.sh` — **36 tests, 0 failures** (26 existing + 6 airgap + 4 deploy).
2. **Auto-revert proven**: `block --minutes 1` returns to `OPEN` unaided, SSH intact throughout.
3. **Offline load proven**: with egress blocked, `docker pull` fails and `load` reports all 23 tags present.
4. **Malcolm serves**: the malcolm profile is up, with any service that would not stay up on 8 GiB named in the evidence file.
5. **Arrangement decided**: both arrangements probed on the same paths, redirect targets recorded verbatim, decision justified by that output.
6. **Docs reconciled**: §9 matches measurement; §13 has a portal criterion.
7. **VM restored**: egress OPEN, Malcolm down, thin pool below the watchdog thresholds.

## What this deliberately does NOT prove

- **Capture fidelity, retention, drop accounting** — need the R770's real NICs and the 7.68 TB volume. `/capture-check`'s quantitative standard cannot be met here.
- **Performance** — 8 GiB against a ~64 GB design budget. A flapping service is a resource finding, not a bundle defect.
- **The real import** — `/import-bundle` on the R770 still needs the Dell downloads, the licensed-appliance inventory, and the media.
- **The internal CA** — rehearsal uses self-signed; easy-rsa issuance is Phase 13.
- **The vhost-vs-path question.** The design is ambiguous about whether `portal.lab` fans out by path or whether the four `.lab` names are separate vhosts (`buildout:34-37` and `PRD.md:31` read as fan-out; `buildout:206` and `buildout:327` read as separate vhosts). This plan assumes **separate vhosts** and tests `malcolm.lab` only. Worth settling before Phase 13 — note that `http://portal.lab/apt` is a fifth, path-based, plain-HTTP surface, and that serving APT from Nginx couples the local repo to Phase 13 while the Docker import it supports is Phase 6/10.
