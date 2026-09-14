# Rehearsal Sites Up — Implementation Plan

> **STATUS: EXECUTED 2026-09-12; TORN DOWN 2026-09-12** — evidence (incl. teardown) in `state/inventory/rehearsal-sites-2026-09-12.md`. Archived 2026-09-14.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring up every portal site from the design — `portal.lab`, `malcolm.lab`, `gns3.lab`, `monitoring.lab`, `docs.lab` — on staging VM 9770, with a sample capture in Malcolm, and leave them running for interactive testing from the operator's browser.

**Architecture:** One host Nginx owns `0.0.0.0:443` and terminates TLS with a certificate from an internal easy-rsa CA (one cert, five SANs) so the operator imports one CA and gets clean locks everywhere. Each backend binds to `127.0.0.1` only: Malcolm's `nginx-proxy` on `:8443` (arrangement B, decided 2026-09-12), GNS3 on `:3080`, Grafana `:3000`, Prometheus `:9090`, Alertmanager `:9093`, and two static roots for the portal page and the MkDocs-built analyst wiki. Nothing is enabled at boot — the operator chose "start once, leave it".

**Tech Stack:** Ubuntu 24.04 · Docker CE 29.8.0 / Compose v5.5.1 · Malcolm, gns3-server, Prometheus, Alertmanager, Grafana, cAdvisor, Blackbox and mkdocs-material **at the releases pinned by `scripts/r770-offline-fetch.sh`** (`OWNERS.md`) — all already loaded in the VM's daemon / present in the bundle; nginx 1.24.0 and easy-rsa from the bundle's `apt/`

**Spec:** `docs/plans/r770-network-lab-buildout.md` §1 (portal diagram), §6 (GNS3), §9 (security: localhost-bound behind Nginx, internal CA, Malcolm rebind), §10 (monitoring stack); `PRD.md` §3.4; `docs/plans/r770-install-runbook.md` Parts 7, 10, 11; measured facts in `state/inventory/malcolm-rehearsal-2026-09-12.md`.

## Global Constraints

- **Staging VM 9770 only** (`ssh ubuntu@192.168.4.28`, key auth). Nothing here touches the R770 or any other Proxmox guest. LXC 101 runs this session.
- **Task 0 gate:** the VM must show ≥ 11 GiB in `free -g` before Task 2 starts, and VMs **100 and 108 must be stopped** on the Proxmox host for as long as the sites are up (operator-confirmed; this container has no key on Proxmox).
- **Egress stays OPEN.** The air-gap simulator caps at 240 min and interactive use is open-ended; offline behaviour was proven by the previous plan. Supply-chain discipline holds anyway: **no `docker pull`, no `apt-get install` from the internet, no `pip install` from PyPI** — every image, deb and wheel comes from `~/r770/bundle-20260908/`. The one exception is Task 3's traffic generation, whose whole point is to produce packets.
- **Every backend binds `127.0.0.1`**; only nginx listens on `0.0.0.0:443`. `ss -ltnp` is the check after every task.
- **No secrets in git** (CLAUDE.md rule 7). Passwords live in mode-0600 files in `/home/ubuntu` on the VM: `~/.malcolm-rehearsal-pw` (exists), `~/.monitoring.env` (Task 6), `~/.gns3-admin-pw` (Task 7). The plan never prints them; the operator reads them with `cat` over SSH.
- **Nothing enabled at boot.** No `systemctl enable`, no `--restart` policies added, no `qm set --onboot`. Task 8 records the one-command restart sequence.
- **Malcolm's rebind is already in place** (`docker-compose.yml` line `- 127.0.0.1:8443:443/tcp`) and `config/nginx/malcolm.lab.conf` exists; Task 2 reuses both. Never revert to raw `docker compose up` — Malcolm's `start` script does setup compose needs.
- **Nginx is 1.24.0** — no `http2 on;`, use `listen 443 ssl http2;`.
- **Evidence discipline** (`.claude/agents/validation-runner.md`): expected vs observed, exact command and exact output line, SKIPPED-with-reason for anything that cannot run. Evidence file: `state/inventory/rehearsal-sites-2026-09-12.md`.
- **The reference guard** (`tests/references.bats`) treats any `scripts/…` string under `state/` as a repo path — write "Malcolm's `start`", never "`scripts/start`", in the evidence file.
- Commit style: imperative, capitalised, no `feat:`/`fix:` prefix. Run `./tests/run.sh` before every commit (97 green at start).

## File Structure

| File | Responsibility |
|---|---|
| `config/nginx/snippets/lab-tls.conf` *(new)* | The one place the cert/key paths live; every vhost includes it. |
| `config/nginx/snippets/lab-auth.conf` *(new)* | `auth_basic` against the shared analyst htpasswd; included by vhosts that have no auth of their own. |
| `config/nginx/malcolm.lab.conf` *(modify)* | Swap the self-signed cert lines for the TLS snippet. Everything else stays. |
| `config/nginx/portal.lab.conf` *(new)* | Static landing page at `/srv/www/portal`. |
| `config/nginx/docs.lab.conf` *(new)* | Static MkDocs site at `/srv/www/docs`. |
| `config/nginx/monitoring.lab.conf` *(new)* | Grafana at `/`, Prometheus at `/prometheus/`, Alertmanager at `/alertmanager/`. |
| `config/nginx/gns3.lab.conf` *(new)* | GNS3 web UI + API with websocket upgrade. |
| `config/portal/index.html` *(new)* | The landing page: five links, the CA-import note, where the passwords live. |
| `config/docs/mkdocs.yml` *(new)* | MkDocs config for `docs/analyst-wiki/` (config cannot live inside the docs dir). |
| `config/monitoring/docker-compose.yml` *(new)* | Prometheus, Alertmanager, Grafana, cAdvisor, Blackbox — all on `127.0.0.1`. |
| `config/monitoring/prometheus.yml` *(new)* | Scrapes node_exporter, cAdvisor, itself, and Blackbox probes of the five vhosts. |
| `config/monitoring/alertmanager.yml` *(new)* | Minimal route to a null receiver — enough to be `ready`. |
| `config/monitoring/blackbox.yml` *(new)* | One HTTPS module that accepts 200/302/401 and trusts the lab CA. |
| `config/monitoring/grafana/provisioning/datasources/prometheus.yml` *(new)* | Grafana's Prometheus datasource, pre-wired. |
| `config/gns3/gns3_server.conf.template` *(new)* | `[Server]`/`[Controller]` with `__PASSWORD__`/`__JWT__` tokens filled on the VM, never in git. |
| `state/inventory/rehearsal-sites-2026-09-12.md` *(new)* | Evidence, per task. |
| `docs/plans/r770-install-runbook.md` *(modify Part 7)* | One line: Part 7 assumes `python3-venv` from Part 3 — say so. |
| `state/BUILD-STATE.md` *(modify Log)* | One log line at close-out. |

On the VM, the repo is not checked out. Each task ships its files with `scp` into `/home/ubuntu/r770/config/…` (create dirs with `ssh … mkdir -p` first) and copies from there into place with `sudo`.

---

### Task 0: Operator gate — grow the VM, confirm the host budget

**Files:** none. Remote: Proxmox host `192.168.4.21` (operator), VM 9770.

**Interfaces:** Produces a VM with ≥ 11 GiB visible and the guarantee that VMs 100/108 are stopped. Every later task assumes both.

- [x] **Step 1: Operator runs on the Proxmox host** (this container cannot):

```bash
qm list                                   # 100 and 108 must show 'stopped'
qm shutdown 9770 && sleep 20 && qm status 9770      # expect: status: stopped
qm set 9770 --memory 12288 --balloon 0
qm start 9770
free -g                                   # host: 'available' must stay >= 2 GiB with 9770 up
```

- [x] **Step 2: Verify from this side**

```bash
sleep 45
ssh ubuntu@192.168.4.28 'free -g | sed -n 2p; uptime -s; docker info --format "{{.ServerVersion}}"'
```

Expected: `Mem: 11` (or 12) in the total column, a fresh boot time, Docker `29.8.0` answering. If `Mem` still reads `7`, the `qm set` did not take — stop and report.

- [x] **Step 3: Record**

Create `state/inventory/rehearsal-sites-2026-09-12.md`:

```markdown
# Rehearsal sites up — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/active/2026-09-12-rehearsal-sites-up.md`. Format per `.claude/agents/validation-runner.md`:
check · expected · observed · verdict · command. Run over SSH from LXC 101 as `ubuntu`.

## Task 0 — VM grown to 12 GiB (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| VM memory | ≥ 11 GiB | `<paste free -g line>` | | `free -g` |
| VMs 100/108 | stopped (operator) | `<operator's qm list line>` | | `qm list` |
```

Fill the observed cells from real output, then:

```bash
git add state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Start the rehearsal-sites evidence file with the 12 GiB VM gate"
```

---

### Task 1: Internal CA and one five-name certificate

**Files:**
- Create: `config/nginx/snippets/lab-tls.conf`, `config/nginx/snippets/lab-auth.conf`
- Modify: `config/nginx/malcolm.lab.conf` (the two `ssl_certificate*` lines)

**Interfaces:** Produces `/etc/nginx/ssl/lab.crt` + `lab.key` (SANs: `portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab`), `/etc/nginx/ssl/ca.crt` (public — the operator imports it), `/etc/nginx/lab.htpasswd` (user `analyst`, same password as Malcolm), and the two snippets every later vhost includes with `include snippets/lab-tls.conf;` / `include snippets/lab-auth.conf;`.

- [x] **Step 1: Install easy-rsa from the bundle and build the CA on the VM**

```bash
ssh ubuntu@192.168.4.28 'cd ~/r770/bundle-20260908/apt && sudo apt-get -y -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/dev/null install ./easy-rsa_*.deb 2>&1 | grep -E "^(Setting up|E:)"
rm -rf ~/lab-ca && make-cadir ~/lab-ca && cd ~/lab-ca
EASYRSA_BATCH=1 EASYRSA_REQ_CN="R770 Lab CA (staging rehearsal)" ./easyrsa init-pki >/dev/null
EASYRSA_BATCH=1 EASYRSA_REQ_CN="R770 Lab CA (staging rehearsal)" ./easyrsa build-ca nopass 2>&1 | tail -1
EASYRSA_BATCH=1 ./easyrsa --subject-alt-name="DNS:portal.lab,DNS:malcolm.lab,DNS:gns3.lab,DNS:monitoring.lab,DNS:docs.lab" build-server-full lab nopass 2>&1 | tail -1
openssl verify -CAfile pki/ca.crt pki/issued/lab.crt
openssl x509 -in pki/issued/lab.crt -noout -ext subjectAltName | tail -1'
```

Expected: `pki/issued/lab.crt: OK` and a SAN line naming all five `.lab` names. If `--subject-alt-name` is rejected (older easy-rsa), use `EASYRSA_EXTRA_EXTS="subjectAltName = DNS:portal.lab,DNS:malcolm.lab,DNS:gns3.lab,DNS:monitoring.lab,DNS:docs.lab"` in the environment of the same `build-server-full` command instead.

- [x] **Step 2: Install the cert, CA and shared htpasswd into nginx**

```bash
ssh ubuntu@192.168.4.28 'sudo install -m 0644 ~/lab-ca/pki/issued/lab.crt /etc/nginx/ssl/lab.crt
sudo install -m 0600 ~/lab-ca/pki/private/lab.key /etc/nginx/ssl/lab.key
sudo install -m 0644 ~/lab-ca/pki/ca.crt /etc/nginx/ssl/ca.crt
sudo install -m 0640 -g www-data ~/malcolm/malcolm/nginx/htpasswd /etc/nginx/lab.htpasswd
sudo rm -f /etc/nginx/ssl/malcolm.lab.crt /etc/nginx/ssl/malcolm.lab.key
ls -l /etc/nginx/ssl/ /etc/nginx/lab.htpasswd'
```

Expected: three files under `ssl/` (the old self-signed pair gone), htpasswd readable by `www-data`.

- [x] **Step 3: Write the two snippets in the repo**

`config/nginx/snippets/lab-tls.conf`:

```nginx
# Included by every .lab vhost. One certificate, five SANs, issued by the
# internal easy-rsa CA (buildout section 9). Rehearsal CA lives in
# ~/lab-ca on VM 9770; the R770 issues its own on the gapped side.
ssl_certificate     /etc/nginx/ssl/lab.crt;
ssl_certificate_key /etc/nginx/ssl/lab.key;
ssl_protocols       TLSv1.2 TLSv1.3;
```

`config/nginx/snippets/lab-auth.conf`:

```nginx
# Included by vhosts with no authentication of their own (portal, docs,
# Prometheus, Alertmanager). Malcolm, Grafana and GNS3 carry their own
# logins and must NOT include this: GNS3 sends 'Authorization: Bearer',
# which auth_basic would reject.
auth_basic           "R770 Lab";
auth_basic_user_file /etc/nginx/lab.htpasswd;
```

- [x] **Step 4: Point the Malcolm vhost at the snippet**

In `config/nginx/malcolm.lab.conf` replace exactly these two lines:

```nginx
    ssl_certificate     /etc/nginx/ssl/malcolm.lab.crt;
    ssl_certificate_key /etc/nginx/ssl/malcolm.lab.key;
```

with:

```nginx
    include snippets/lab-tls.conf;
```

- [x] **Step 5: Ship, reload, verify the chain end to end**

```bash
ssh ubuntu@192.168.4.28 'mkdir -p ~/r770/config/nginx/snippets'
scp -q config/nginx/snippets/lab-tls.conf config/nginx/snippets/lab-auth.conf ubuntu@192.168.4.28:/home/ubuntu/r770/config/nginx/snippets/
scp -q config/nginx/malcolm.lab.conf ubuntu@192.168.4.28:/home/ubuntu/r770/config/nginx/
ssh ubuntu@192.168.4.28 'sudo mkdir -p /etc/nginx/snippets && sudo cp ~/r770/config/nginx/snippets/lab-*.conf /etc/nginx/snippets/ && sudo cp ~/r770/config/nginx/malcolm.lab.conf /etc/nginx/sites-available/ && sudo nginx -t 2>&1 | tail -1 && sudo systemctl start nginx && sudo systemctl reload nginx
echo | openssl s_client -connect 127.0.0.1:443 -servername malcolm.lab -CAfile /etc/nginx/ssl/ca.crt 2>/dev/null | grep -E "Verify return code|subject="'
```

Expected: `test is successful`; `Verify return code: 0 (ok)`; `subject=CN = lab`.

- [x] **Step 6: Hand the CA to the operator, record, commit**

```bash
scp -q ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt /tmp/claude-0/-root-claude-simlab-build/d164567b-1424-488e-b894-82f2a004a479/scratchpad/r770-lab-ca.crt
```

Tell the operator: `scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .` then import it as a trusted CA in the browser/OS. Append a "Task 1" table to the evidence file with the `openssl verify`, SAN, and `Verify return code` lines. Then:

```bash
./tests/run.sh | tail -2
git add config/nginx/ state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Issue the rehearsal portal certificate from an internal CA

One easy-rsa CA on the staging VM, one server certificate carrying all five
.lab names, and two nginx snippets so every vhost shares the cert lines and
the analyst htpasswd instead of repeating them. Malcolm's vhost now includes
the snippet; its self-signed pair is gone."
```

---

### Task 2: Malcolm up behind the portal, staying up

**Files:** none in the repo (evidence only).

**Interfaces:** Consumes Task 1's cert. Produces Malcolm running (27 services) on `127.0.0.1:8443`, reachable at `https://malcolm.lab/` through the portal, with the `analyst` password at `~/.malcolm-rehearsal-pw` on the VM.

- [x] **Step 1: Confirm the rebind survived and start with Malcolm's own script**

```bash
ssh ubuntu@192.168.4.28 'cd ~/malcolm/malcolm && grep -n "8443:443" docker-compose.yml && (nohup ./scripts/start </dev/null > ~/malcolm-start-sites-$(date +%Y%m%d).log 2>&1 &) && sleep 240 && docker compose ps --format "{{.Service}} {{.Status}}" | grep -viE "\(healthy\)" || echo "all healthy"; docker compose ps -q | wc -l; ss -ltnp | grep -E ":(443|8443) " | awk "{print \$4}" | sort'
```

Expected: the `8443:443` line at ~1453; after 4 min at most `arkime`/`logstash` still `health: starting`; `27`; `0.0.0.0:443` and `127.0.0.1:8443`.

- [x] **Step 2: Wait for full health, probe through the portal**

```bash
ssh ubuntu@192.168.4.28 'sleep 120; cd ~/malcolm/malcolm; docker compose ps --format "{{.Service}} {{.Status}}" | grep -viE "\(healthy\)" || echo "all 27 healthy"; PW=$(cat ~/.malcolm-rehearsal-pw); R="--resolve malcolm.lab:443:127.0.0.1 --cacert /etc/nginx/ssl/ca.crt"; for p in / /arkime/ /dashboards/ /netbox/ /readme/; do curl -s $R -u "analyst:$PW" "https://malcolm.lab$p" -o /dev/null -w "$p %{http_code}\n"; done; free -h | sed -n 2p'
```

Expected: `all 27 healthy`; `/ 200`, `/arkime/ 302`, `/dashboards/ 302`, `/netbox/ 200`, `/readme/ 200` — **with the CA, no `-k`**; memory used ≈ 7.5 Gi of 11–12.

- [x] **Step 3: Record and commit**

Append a "Task 2" table (health count, five status codes, `free` line, the `ss` binding lines). Commit:

```bash
git add state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Bring Malcolm back up behind the portal for interactive testing"
```

---

### Task 3: A sample capture in Malcolm

**Files:** none in the repo (evidence only).

**Interfaces:** Consumes Task 2's running stack. Produces `~/sample-YYYYMMDD.pcap` on the VM, ingested, with sessions visible in Arkime and Zeek logs in Dashboards.

- [x] **Step 1: Discover the interface — never guess it**

```bash
ssh ubuntu@192.168.4.28 'ip -o route get 1.1.1.1 | sed -E "s/.* dev ([^ ]+).*/\1/"'
```

Expected: one interface name (the DHCP one, MAC `bc:24:11:97:70:01`). Use it as `IFACE` below.

- [x] **Step 2: Capture 60 seconds of mixed traffic the VM generates itself**

```bash
ssh ubuntu@192.168.4.28 'IFACE=$(ip -o route get 1.1.1.1 | sed -E "s/.* dev ([^ ]+).*/\1/"); OUT=~/sample-$(date +%Y%m%d).pcap
sudo timeout 60 tcpdump -i "$IFACE" -s 0 -w "$OUT" "not port 22" 2>/dev/null &
sleep 2
for h in archive.ubuntu.com security.ubuntu.com deb.debian.org example.com ghcr.io; do curl -s --max-time 8 -o /dev/null "https://$h/"; curl -s --max-time 8 -o /dev/null "http://$h/"; dig +short "$h" >/dev/null; done
ping -c 5 -i 0.5 192.168.4.1 >/dev/null 2>&1; ping -c 5 -i 0.5 1.1.1.1 >/dev/null 2>&1
ssh -o BatchMode=yes -o ConnectTimeout=3 192.168.4.1 true 2>/dev/null; curl -s --max-time 5 -o /dev/null http://192.168.4.21:8006/ 2>/dev/null
wait; ls -l "$OUT"; sudo chown ubuntu "$OUT"; tcpdump -nr "$OUT" 2>/dev/null | wc -l'
```

Expected: a `.pcap` of at least a few hundred KB and a packet count in the hundreds or more (DNS, TLS, HTTP, ICMP, some LAN TCP).

- [x] **Step 3: Hand it to Malcolm the documented way — drop it in the upload directory**

```bash
ssh ubuntu@192.168.4.28 'OUT=$(ls -t ~/sample-*.pcap | head -1); sudo cp "$OUT" ~/malcolm/malcolm/pcap/upload/ && sudo chown 1000:1000 ~/malcolm/malcolm/pcap/upload/$(basename "$OUT") && sleep 150 && ls -l ~/malcolm/malcolm/pcap/upload/ ~/malcolm/malcolm/pcap/processed/ 2>/dev/null | head; docker compose -f ~/malcolm/malcolm/docker-compose.yml logs --since 4m pcap-monitor 2>/dev/null | grep -iE "sample-|processed|error" | tail -5'
```

Expected: the file moves from `upload/` to `processed/` (Malcolm's `pcap-monitor` picks it up) within ~2 min.

- [x] **Step 4: Prove it landed — Arkime sessions and Zeek logs, through the portal**

```bash
ssh ubuntu@192.168.4.28 'PW=$(cat ~/.malcolm-rehearsal-pw); R="--resolve malcolm.lab:443:127.0.0.1 --cacert /etc/nginx/ssl/ca.crt"
echo "arkime sessions (last 24h):"; curl -s $R -u "analyst:$PW" "https://malcolm.lab/arkime/api/sessions?date=24&length=1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"recordsFiltered\", d.get(\"recordsTotal\")))"
echo "indices with docs:"; curl -s $R -u "analyst:$PW" "https://malcolm.lab/mapi/indices" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(i.get(\"index\"), i.get(\"docs.count\")) for i in d.get(\"indices\", d if isinstance(d,list) else []) if str(i.get(\"docs.count\",\"0\")) not in (\"0\",\"None\")]" 2>/dev/null | head -8'
```

Expected: an Arkime session count `> 0`; at least one `arkime_sessions3-*` and one `malcolm_beats_zeek*`/`zeek` index with a non-zero doc count. If the count is 0 after 5 min, `docker compose logs --since 10m arkime zeek filebeat | tail -40` and record the reason — do not retry blindly.

- [x] **Step 5: Record and commit**

Append a "Task 3" table (interface, packet count, upload→processed move, session count, index list). Commit:

```bash
git add state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Load a sample capture into the rehearsal Malcolm and prove it indexed"
```

---

### Task 4: `portal.lab` — the landing page

**Files:**
- Create: `config/portal/index.html`, `config/nginx/portal.lab.conf`

**Interfaces:** Consumes Task 1's snippets. Produces `https://portal.lab/` (basic auth, `analyst`) linking the five sites.

- [x] **Step 1: Write the page**

`config/portal/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>R770 Lab Portal</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem; color: #222; }
  h1 { font-size: 1.6rem; } li { margin: .4rem 0; } code { background: #f2f2f2; padding: 0 .3rem; }
  .note { border-left: 4px solid #999; padding: .5rem 1rem; background: #fafafa; margin-top: 2rem; }
</style>
</head>
<body>
<h1>R770 Lab Portal <small>(staging rehearsal)</small></h1>
<ul>
  <li><a href="https://malcolm.lab/">malcolm.lab</a> — capture &amp; analysis: <a href="https://malcolm.lab/arkime/">Arkime</a> · <a href="https://malcolm.lab/dashboards/">Dashboards</a> · <a href="https://malcolm.lab/netbox/">NetBox</a> · <a href="https://malcolm.lab/upload/">PCAP upload</a></li>
  <li><a href="https://gns3.lab/">gns3.lab</a> — GNS3 server (web UI; login <code>admin</code>)</li>
  <li><a href="https://monitoring.lab/">monitoring.lab</a> — Grafana (login <code>admin</code>) · <a href="https://monitoring.lab/prometheus/">Prometheus</a> · <a href="https://monitoring.lab/alertmanager/">Alertmanager</a></li>
  <li><a href="https://docs.lab/">docs.lab</a> — Analyst Guide</li>
</ul>
<div class="note">
  <p><strong>First visit:</strong> import the lab CA (<code>scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .</code>) so every site shows a clean lock,
  and add one hosts line on your machine: <code>192.168.4.28 portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab</code>.</p>
  <p><strong>Passwords</strong> are on the VM, never in this page or in git: <code>~/.malcolm-rehearsal-pw</code> (analyst — Malcolm, this portal, docs, Prometheus, Alertmanager),
  <code>~/.monitoring.env</code> (Grafana admin), <code>~/.gns3-admin-pw</code> (GNS3 admin).</p>
</div>
</body>
</html>
```

- [x] **Step 2: Write the vhost**

`config/nginx/portal.lab.conf`:

```nginx
# portal.lab -- static landing page. Basic auth via the shared analyst htpasswd.
server {
    listen 443 ssl http2;
    server_name portal.lab;
    include snippets/lab-tls.conf;
    include snippets/lab-auth.conf;

    root /srv/www/portal;
    index index.html;
}
```

- [x] **Step 3: Ship, enable, verify**

```bash
ssh ubuntu@192.168.4.28 'mkdir -p ~/r770/config/portal'
scp -q config/portal/index.html ubuntu@192.168.4.28:/home/ubuntu/r770/config/portal/
scp -q config/nginx/portal.lab.conf ubuntu@192.168.4.28:/home/ubuntu/r770/config/nginx/
ssh ubuntu@192.168.4.28 'sudo mkdir -p /srv/www/portal && sudo cp ~/r770/config/portal/index.html /srv/www/portal/ && sudo cp ~/r770/config/nginx/portal.lab.conf /etc/nginx/sites-available/ && sudo ln -sf /etc/nginx/sites-available/portal.lab.conf /etc/nginx/sites-enabled/ && sudo nginx -t 2>&1 | tail -1 && sudo systemctl reload nginx
PW=$(cat ~/.malcolm-rehearsal-pw); R="--resolve portal.lab:443:127.0.0.1 --cacert /etc/nginx/ssl/ca.crt"
curl -s $R https://portal.lab/ -o /dev/null -w "unauth %{http_code}\n"
curl -s $R -u "analyst:$PW" https://portal.lab/ | grep -oE "<title>[^<]*"'
```

Expected: `test is successful`; `unauth 401`; `<title>R770 Lab Portal`.

- [x] **Step 4: Record and commit**

Append a "Task 4" table. Commit:

```bash
./tests/run.sh | tail -2
git add config/portal/ config/nginx/portal.lab.conf state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Add the portal.lab landing page"
```

---

### Task 5: `docs.lab` — the analyst wiki, built with the bundled MkDocs image

**Files:**
- Create: `config/docs/mkdocs.yml`, `config/nginx/docs.lab.conf`

**Interfaces:** Consumes `docs/analyst-wiki/*.md` (six pages, exist) and the loaded `squidfunk/mkdocs-material:latest` image. Produces `https://docs.lab/` (basic auth).

- [x] **Step 1: Write the MkDocs config**

`config/docs/mkdocs.yml` (lives outside the docs dir because MkDocs refuses a config inside `docs_dir`):

```yaml
# Built on the VM with the bundled squidfunk/mkdocs-material image:
#   docker run --rm -v ~/r770/wiki:/docs squidfunk/mkdocs-material:latest build
# where ~/r770/wiki/mkdocs.yml is this file and ~/r770/wiki/docs/ is docs/analyst-wiki/.
site_name: Analyst Guide — R770 Network Lab
site_url: https://docs.lab/
docs_dir: docs
site_dir: site
use_directory_urls: true
theme:
  name: material
  font: false            # no Google Fonts -- the R770 has no internet, and neither should this page
  features: [navigation.sections, search.highlight]
plugins: [search]
markdown_extensions: [admonition, tables, toc]
nav:
  - Home: index.md
  - Access & workspaces: access.md
  - Malcolm: malcolm.md
  - GNS3: gns3.md
  - WAN impairment: wan.md
  - CLI tools: cli-tools.md
```

- [x] **Step 2: Write the vhost**

`config/nginx/docs.lab.conf`:

```nginx
# docs.lab -- static MkDocs build of docs/analyst-wiki. Basic auth (shared htpasswd).
server {
    listen 443 ssl http2;
    server_name docs.lab;
    include snippets/lab-tls.conf;
    include snippets/lab-auth.conf;

    root /srv/www/docs;
    index index.html;
    location / { try_files $uri $uri/ /index.html; }
}
```

- [x] **Step 3: Ship the sources, build with the bundled image, install, verify**

```bash
ssh ubuntu@192.168.4.28 'rm -rf ~/r770/wiki && mkdir -p ~/r770/wiki/docs ~/r770/config/docs'
scp -q docs/analyst-wiki/*.md ubuntu@192.168.4.28:/home/ubuntu/r770/wiki/docs/
scp -q config/docs/mkdocs.yml ubuntu@192.168.4.28:/home/ubuntu/r770/wiki/mkdocs.yml
scp -q config/nginx/docs.lab.conf ubuntu@192.168.4.28:/home/ubuntu/r770/config/nginx/
ssh ubuntu@192.168.4.28 'cd ~/r770/wiki && docker run --rm -v "$PWD":/docs squidfunk/mkdocs-material:latest build 2>&1 | tail -3; ls site/ | head; sudo mkdir -p /srv/www/docs && sudo rsync -a --delete site/ /srv/www/docs/ && sudo cp ~/r770/config/nginx/docs.lab.conf /etc/nginx/sites-available/ && sudo ln -sf /etc/nginx/sites-available/docs.lab.conf /etc/nginx/sites-enabled/ && sudo nginx -t 2>&1 | tail -1 && sudo systemctl reload nginx
PW=$(cat ~/.malcolm-rehearsal-pw); R="--resolve docs.lab:443:127.0.0.1 --cacert /etc/nginx/ssl/ca.crt"
curl -s $R -u "analyst:$PW" https://docs.lab/ | grep -oE "<title>[^<]*"; curl -s $R -u "analyst:$PW" https://docs.lab/malcolm/ -o /dev/null -w "malcolm page %{http_code}\n"'
```

Expected: `INFO - Documentation built in …`; `site/` holds `index.html` and a dir per page; `test is successful`; `<title>Analyst Guide…` (MkDocs prefixes the page title); `malcolm page 200`. If the build reaches for the internet (it must not with `font: false`), it will still succeed — egress is open — but note it in the evidence.

- [x] **Step 4: Record and commit**

```bash
./tests/run.sh | tail -2
git add config/docs/ config/nginx/docs.lab.conf state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Build and serve the analyst wiki at docs.lab from the bundled MkDocs image"
```

---

### Task 6: `monitoring.lab` — Prometheus, Alertmanager, Grafana, cAdvisor, Blackbox

**Files:**
- Create: `config/monitoring/docker-compose.yml`, `config/monitoring/prometheus.yml`, `config/monitoring/alertmanager.yml`, `config/monitoring/blackbox.yml`, `config/monitoring/grafana/provisioning/datasources/prometheus.yml`, `config/nginx/monitoring.lab.conf`

**Interfaces:** Consumes the five loaded images and Task 1's CA. Produces Grafana at `https://monitoring.lab/` (own login, `admin` / password in `~/.monitoring.env`), Prometheus at `/prometheus/`, Alertmanager at `/alertmanager/` (both behind the shared basic auth), with `node_exporter` installed from the bundle on the host.

- [x] **Step 1: node_exporter from the bundle (host metrics)**

```bash
ssh ubuntu@192.168.4.28 'cd ~/r770/bundle-20260908/apt && sudo apt-get -y -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/dev/null install ./prometheus-node-exporter_*.deb 2>&1 | grep -E "^(Setting up|E:)"; sudo systemctl start prometheus-node-exporter; sleep 1; curl -s http://127.0.0.1:9100/metrics | grep -c "^node_"'
```

Expected: `Setting up prometheus-node-exporter…`; a count in the hundreds. (The Ubuntu package binds `:9100` on all interfaces; there is no UFW on the VM. Acceptable for the rehearsal; the R770 build restricts it in Phase 14.)

- [x] **Step 2: Write the compose file**

`config/monitoring/docker-compose.yml`:

```yaml
# Monitoring stack for the portal (buildout section 10). Every port binds to
# 127.0.0.1; nginx at monitoring.lab is the only way in. Image TAGS are not
# written here: OWNERS.md keeps every pin in the fetch script, so the tags
# come from the bundle's own docker/monitoring-image-list.txt via a .env
# generated on the host (Task 6 step 5) -- never pull. Grafana's admin
# password comes from an env file that lives only on the host
# (~/.monitoring.env), never in git.
name: monitoring
services:
  prometheus:
    image: ${PROMETHEUS_IMAGE}
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.external-url=https://monitoring.lab/prometheus/
      - --web.route-prefix=/prometheus/
      - --storage.tsdb.retention.time=7d
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom-data:/prometheus
    extra_hosts: ["host.docker.internal:host-gateway"]
    ports: ["127.0.0.1:9090:9090"]
  alertmanager:
    image: ${ALERTMANAGER_IMAGE}
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --web.external-url=https://monitoring.lab/alertmanager/
      - --web.route-prefix=/alertmanager/
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    ports: ["127.0.0.1:9093:9093"]
  grafana:
    image: ${GRAFANA_IMAGE}
    env_file: /home/ubuntu/.monitoring.env          # GF_SECURITY_ADMIN_PASSWORD=...
    environment:
      GF_SERVER_ROOT_URL: https://monitoring.lab/
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana-data:/var/lib/grafana
    ports: ["127.0.0.1:3000:3000"]
  cadvisor:
    image: ${CADVISOR_IMAGE}
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports: ["127.0.0.1:8080:8080"]
  blackbox:
    image: ${BLACKBOX_IMAGE}
    volumes:
      - ./blackbox.yml:/etc/blackbox_exporter/config.yml:ro
      - /etc/nginx/ssl/ca.crt:/etc/blackbox_exporter/ca.crt:ro
    # The .lab names must resolve to the host's nginx from inside the container.
    extra_hosts:
      - "portal.lab:host-gateway"
      - "malcolm.lab:host-gateway"
      - "gns3.lab:host-gateway"
      - "monitoring.lab:host-gateway"
      - "docs.lab:host-gateway"
    ports: ["127.0.0.1:9115:9115"]
volumes:
  prom-data: {}
  grafana-data: {}
```

- [x] **Step 3: Write the Prometheus, Alertmanager and Blackbox configs**

`config/monitoring/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
alerting:
  alertmanagers:
    - static_configs: [{ targets: ["alertmanager:9093"] }]
      path_prefix: /alertmanager/
scrape_configs:
  - job_name: prometheus
    metrics_path: /prometheus/metrics
    static_configs: [{ targets: ["localhost:9090"] }]
  - job_name: node
    static_configs: [{ targets: ["host.docker.internal:9100"] }]
  - job_name: cadvisor
    static_configs: [{ targets: ["cadvisor:8080"] }]
  - job_name: portal-vhosts
    metrics_path: /probe
    params: { module: [lab_https] }
    static_configs:
      - targets:
          - https://portal.lab/
          - https://malcolm.lab/
          - https://gns3.lab/
          - https://monitoring.lab/
          - https://docs.lab/
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

`config/monitoring/alertmanager.yml`:

```yaml
# Minimal: enough to be 'ready'. Delivery is a Phase 14 decision on the R770.
route:
  receiver: "null"
receivers:
  - name: "null"
```

`config/monitoring/blackbox.yml`:

```yaml
modules:
  lab_https:
    prober: http
    timeout: 10s
    http:
      # 401 counts as 'answers over TLS' -- the probe carries no credentials.
      valid_status_codes: [200, 302, 401]
      tls_config:
        ca_file: /etc/blackbox_exporter/ca.crt
```

`config/monitoring/grafana/provisioning/datasources/prometheus.yml`:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090/prometheus/
    isDefault: true
```

- [x] **Step 4: Write the vhost**

`config/nginx/monitoring.lab.conf`:

```nginx
# monitoring.lab -- Grafana at /, Prometheus at /prometheus/, Alertmanager at
# /alertmanager/. Grafana has its own login; the other two get the shared
# basic auth. Prometheus and Alertmanager run with --web.route-prefix, so the
# path is passed through unchanged (proxy_pass without a URI part).
server {
    listen 443 ssl http2;
    server_name monitoring.lab;
    include snippets/lab-tls.conf;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;                       # Grafana Live uses websockets
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /prometheus/ {
        include snippets/lab-auth.conf;
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
    }
    location /alertmanager/ {
        include snippets/lab-auth.conf;
        proxy_pass http://127.0.0.1:9093;
        proxy_set_header Host $host;
    }
}
```

- [x] **Step 5: Create the Grafana secret on the VM, ship, start, verify**

```bash
ssh ubuntu@192.168.4.28 'umask 077; [ -s ~/.monitoring.env ] || echo "GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 18)" > ~/.monitoring.env; mkdir -p ~/r770/config/monitoring/grafana/provisioning/datasources'
scp -q config/monitoring/docker-compose.yml config/monitoring/prometheus.yml config/monitoring/alertmanager.yml config/monitoring/blackbox.yml ubuntu@192.168.4.28:/home/ubuntu/r770/config/monitoring/
scp -q config/monitoring/grafana/provisioning/datasources/prometheus.yml ubuntu@192.168.4.28:/home/ubuntu/r770/config/monitoring/grafana/provisioning/datasources/
scp -q config/nginx/monitoring.lab.conf ubuntu@192.168.4.28:/home/ubuntu/r770/config/nginx/
ssh ubuntu@192.168.4.28 'cd ~/r770/config/monitoring && L=~/r770/bundle-20260908/docker/monitoring-image-list.txt && { echo "PROMETHEUS_IMAGE=$(grep "/prom/prometheus:" $L | sed "s#^docker.io/##")"; echo "ALERTMANAGER_IMAGE=$(grep "/prom/alertmanager:" $L | sed "s#^docker.io/##")"; echo "GRAFANA_IMAGE=$(grep "/grafana/grafana-oss:" $L | sed "s#^docker.io/##")"; echo "CADVISOR_IMAGE=$(grep "/cadvisor:" $L)"; echo "BLACKBOX_IMAGE=$(grep "/blackbox-exporter:" $L | sed "s#^docker.io/##")"; } > .env && cat .env && docker compose config --images && docker compose up -d --pull never 2>&1 | grep -E "Started|Error|error" ; sleep 20; docker compose ps --format "{{.Service}} {{.Status}}"; sudo cp ~/r770/config/nginx/monitoring.lab.conf /etc/nginx/sites-available/ && sudo ln -sf /etc/nginx/sites-available/monitoring.lab.conf /etc/nginx/sites-enabled/ && sudo nginx -t 2>&1 | tail -1 && sudo systemctl reload nginx
PW=$(cat ~/.malcolm-rehearsal-pw); R="--resolve monitoring.lab:443:127.0.0.1 --cacert /etc/nginx/ssl/ca.crt"
curl -s $R https://monitoring.lab/login | grep -oE "<title>[^<]*"
curl -s $R -u "analyst:$PW" https://monitoring.lab/prometheus/-/ready -w " %{http_code}\n"
curl -s $R -u "analyst:$PW" https://monitoring.lab/alertmanager/-/ready -w " %{http_code}\n"
sleep 30; curl -s $R -u "analyst:$PW" "https://monitoring.lab/prometheus/api/v1/targets" | python3 -c "import sys,json; [print(t[\"labels\"][\"job\"], t[\"labels\"].get(\"instance\"), t[\"health\"]) for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]]"
ss -ltnp | grep -E ":(3000|9090|9093|8080|9115) " | awk "{print \$4}" | sort'
```

Expected: `.env` shows five image refs, each matching a tag already in `docker image ls`; five services `Up`; `<title>Grafana`; `Prometheus Server is Ready. 200`; `OK 200`; targets `prometheus`, `node`, `cadvisor` **up** and five `portal-vhosts` probes (`gns3.lab` will be **down** until Task 7 — expected); all five ports on `127.0.0.1` only. `--pull never` proves no image came from the internet.

- [x] **Step 6: Record and commit**

```bash
./tests/run.sh | tail -2
git add config/monitoring/ config/nginx/monitoring.lab.conf state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Stand up the monitoring stack behind monitoring.lab from bundled images"
```

---

### Task 7: `gns3.lab` — GNS3 server from the wheelhouse

**Files:**
- Create: `config/gns3/gns3_server.conf.template`, `config/nginx/gns3.lab.conf`
- Modify: `docs/plans/r770-install-runbook.md` (Part 7, one line)

**Interfaces:** Consumes the wheelhouse and `python3-venv` from the bundle. Produces `https://gns3.lab/` (GNS3's own JWT login, `admin` / `~/.gns3-admin-pw`), API at `/v3/version` reporting the pinned release. **Scope:** the server and web UI are up; running nodes (dynamips/ubridge/vpcs are not in the bundle) is out of scope and recorded as such.

- [x] **Step 1: venv + server from the wheelhouse (`--no-index` is load-bearing)**

```bash
ssh ubuntu@192.168.4.28 'cd ~/r770/bundle-20260908/apt && sudo apt-get -y -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/dev/null install ./python3-venv_*.deb ./python3.12-venv_*.deb ./python3-pip-whl_*.deb ./python3-setuptools-whl_*.deb 2>&1 | grep -E "^(Setting up|E:)" | head -3
sudo rm -rf /opt/gns3 && sudo python3 -m venv /opt/gns3 && sudo /opt/gns3/bin/pip install -q --no-index --find-links ~/r770/bundle-20260908/gns3/wheelhouse gns3-server && /opt/gns3/bin/gns3server --version
sudo mkdir -p /srv/gns3/{projects,images,appliances} /etc/gns3 /var/log/gns3 && sudo cp ~/r770/bundle-20260908/gns3/definitions/*.gns3a /srv/gns3/appliances/ && ls /srv/gns3/appliances | wc -l'
```

Expected: the gns3-server version pinned in the fetch script; `12` definitions. (`python3-venv` is already on this VM from the research step; the command is idempotent.)

- [x] **Step 2: Write the config template (secrets are substituted on the VM)**

`config/gns3/gns3_server.conf.template`:

```ini
; GNS3 server (release pinned by the fetch script) -- sections map to gns3server's ServerConfig (configparser).
; __PASSWORD__ and __JWT__ are filled on the host from files that never enter git.
[Server]
host = 127.0.0.1
port = 3080
projects_path = /srv/gns3/projects
images_path = /srv/gns3/images
appliances_path = /srv/gns3/appliances
report_errors = false

[Controller]
default_admin_username = admin
default_admin_password = __PASSWORD__
jwt_secret_key = __JWT__
```

- [x] **Step 3: Write the vhost**

`config/nginx/gns3.lab.conf`:

```nginx
# gns3.lab -- GNS3 web UI + API on 127.0.0.1:3080. GNS3 authenticates with
# its own JWT (Authorization: Bearer), so NO basic auth here. Websockets carry
# console and notification streams; long read timeout on purpose.
server {
    listen 443 ssl http2;
    server_name gns3.lab;
    include snippets/lab-tls.conf;

    client_max_body_size 0;        # appliance image uploads
    proxy_read_timeout 1d;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

- [x] **Step 4: Fill the config on the VM, start under tmux, enable the vhost, verify**

```bash
ssh ubuntu@192.168.4.28 'mkdir -p ~/r770/config/gns3'
scp -q config/gns3/gns3_server.conf.template ubuntu@192.168.4.28:/home/ubuntu/r770/config/gns3/
scp -q config/nginx/gns3.lab.conf ubuntu@192.168.4.28:/home/ubuntu/r770/config/nginx/
ssh ubuntu@192.168.4.28 'umask 077; [ -s ~/.gns3-admin-pw ] || openssl rand -base64 15 > ~/.gns3-admin-pw; [ -s ~/.gns3-jwt ] || openssl rand -hex 32 > ~/.gns3-jwt
sed -e "s|__PASSWORD__|$(cat ~/.gns3-admin-pw)|" -e "s|__JWT__|$(cat ~/.gns3-jwt)|" ~/r770/config/gns3/gns3_server.conf.template | sudo tee /etc/gns3/gns3_server.conf >/dev/null && sudo chmod 0600 /etc/gns3/gns3_server.conf && sudo chown ubuntu /etc/gns3/gns3_server.conf
sudo chown -R ubuntu:ubuntu /srv/gns3 /var/log/gns3
tmux kill-session -t gns3 2>/dev/null; tmux new -d -s gns3 "/opt/gns3/bin/gns3server --config /etc/gns3/gns3_server.conf --logfile /var/log/gns3/server.log"
sleep 8; tail -5 /var/log/gns3/server.log; ss -ltnp | grep ":3080 " | awk "{print \$4}"
sudo cp ~/r770/config/nginx/gns3.lab.conf /etc/nginx/sites-available/ && sudo ln -sf /etc/nginx/sites-available/gns3.lab.conf /etc/nginx/sites-enabled/ && sudo nginx -t 2>&1 | tail -1 && sudo systemctl reload nginx
R="--resolve gns3.lab:443:127.0.0.1 --cacert /etc/nginx/ssl/ca.crt"
curl -s $R https://gns3.lab/v3/version
echo; curl -s $R https://gns3.lab/ | grep -oE "<title>[^<]*"
TOKEN=$(curl -s $R -X POST https://gns3.lab/v3/access/users/login -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "username=admin" --data-urlencode "password=$(cat ~/.gns3-admin-pw)" | python3 -c "import sys,json; print(json.load(sys.stdin).get(\"access_token\",\"\"))")
[ -n "$TOKEN" ] && echo "login: token issued" || echo "login: FAILED"
curl -s $R -H "Authorization: Bearer $TOKEN" https://gns3.lab/v3/computes | python3 -c "import sys,json; print(\"computes:\", len(json.load(sys.stdin)))"'
```

Expected: log shows the server listening on `127.0.0.1:3080` with the config path loaded; `127.0.0.1:3080`; `{"controller_host": …, "version": "<the pinned gns3-server version>"}`; a `<title>` from the bundled web UI; `login: token issued`; `computes: 1` (the local compute). If the login returns no token, check the log for the admin-user creation line — the default password is applied only when the controller DB is first created (`rm -rf ~/.config/GNS3/3.0/` for a clean retry is safe here; nothing is in it yet).

- [x] **Step 5: Runbook Part 7 assumption, evidence, commit**

In `docs/plans/r770-install-runbook.md`, after the line `No \`pip install\` from the internet. The wheelhouse is the index.` add:

```markdown
`python3 -m venv` needs `python3-venv` (+ `python3.12-venv`, `python3-pip-whl`) from the
curated set installed in Part 3 — without them the venv is created with no `pip` and the
next line fails with "No such file or directory" (seen on staging 2026-09-12).
```

Append a "Task 7" table (version, listening address, `/v3/version` body, login result, computes count, and one SKIPPED row: "node start — dynamips/ubridge/vpcs not in bundle; out of scope"). Commit:

```bash
./tests/run.sh | tail -2
git add config/gns3/ config/nginx/gns3.lab.conf docs/plans/r770-install-runbook.md state/inventory/rehearsal-sites-2026-09-12.md
git commit -m "Run GNS3 server from the wheelhouse behind gns3.lab"
```

---

### Task 8: Close-out — the whole portal measured, and how to bring it back

**Files:**
- Modify: `state/inventory/rehearsal-sites-2026-09-12.md`, `state/BUILD-STATE.md` (Log), this plan's status line

- [x] **Step 1: One pass over every site with the CA, plus the memory picture**

```bash
ssh ubuntu@192.168.4.28 'PW=$(cat ~/.malcolm-rehearsal-pw); C="--cacert /etc/nginx/ssl/ca.crt"
for h in portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab; do printf "%-16s " "$h"; curl -s $C --resolve "$h:443:127.0.0.1" -u "analyst:$PW" "https://$h/" -o /dev/null -w "%{http_code} tls=%{ssl_verify_result}\n"; done
echo "--- only nginx on 0.0.0.0:"; ss -ltnp | grep -E "0.0.0.0:(443|8443|3080|3000|9090|9093|8080|9115) " | awk "{print \$4}"
echo "--- blackbox view:"; curl -s $C --resolve monitoring.lab:443:127.0.0.1 -u "analyst:$PW" "https://monitoring.lab/prometheus/api/v1/query?query=probe_success" | python3 -c "import sys,json; [print(r[\"metric\"][\"instance\"], r[\"value\"][1]) for r in json.load(sys.stdin)[\"data\"][\"result\"]]"
echo "--- memory:"; free -h | sed -n 2p; docker stats --no-stream --format "{{.Name}} {{.MemUsage}}" | sort -k2 -h -r | head -6'
```

Expected: five `200` (or `302` for malcolm.lab) with `tls=0`; only `0.0.0.0:443`; five `probe_success 1`; memory used well under 11 GiB.

- [x] **Step 2: Write the operator section into the evidence file**

Append:

```markdown
## How to use it (operator)

1. Hosts line on your machine: `192.168.4.28 portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab`
2. Trust the CA once: `scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .` → import as a trusted root.
3. Start at https://portal.lab/ (login `analyst`).
4. Passwords, on the VM only: `cat ~/.malcolm-rehearsal-pw` (analyst), `cat ~/.monitoring.env` (Grafana admin), `cat ~/.gns3-admin-pw` (GNS3 admin).

## If the VM reboots (nothing is enabled at boot, by decision)

    sudo systemctl start nginx prometheus-node-exporter
    cd ~/malcolm/malcolm && ./scripts/start            # Malcolm's own start script
    cd ~/r770/config/monitoring && docker compose up -d --pull never
    tmux new -d -s gns3 "/opt/gns3/bin/gns3server --config /etc/gns3/gns3_server.conf --logfile /var/log/gns3/server.log"

VMs 100 and 108 must stay stopped on Proxmox while this runs.
```

(Write the Malcolm line exactly as shown inside an indented code block — the reference guard scans prose, and the accompanying comment says whose script it is.)

- [x] **Step 3: Build state, plan status, final commit**

Add to `state/BUILD-STATE.md` under `## Log`:

```markdown
- 2026-09-12 · Staging · All five portal sites up on VM 9770 for interactive testing (portal, Malcolm w/ sample capture, GNS3 web UI, Prometheus/Grafana/Alertmanager, MkDocs wiki) behind one nginx with an internal-CA certificate; every backend on 127.0.0.1. VM grown to 12 GiB. Nothing enabled at boot. Phases 8/13/14 remain NOT STARTED — this is staging. · `inventory/rehearsal-sites-2026-09-12.md`
```

Change this plan's first line to `> **STATUS: EXECUTED 2026-09-12** — sites running; evidence in \`state/inventory/rehearsal-sites-2026-09-12.md\`.`

```bash
./tests/run.sh | tail -2                                   # expect 97+ tests, 0 failures
git add state/ work/plans/active/2026-09-12-rehearsal-sites-up.md
git commit -m "Record the rehearsal portal as running, with the operator's access notes"
```

---

## Verification

The plan succeeds when all hold:

1. `./tests/run.sh` — **0 failures** (97 tests at start; this plan adds none).
2. From the operator's browser with the CA trusted and the hosts line in place: all five sites load with a clean lock; Arkime shows sessions from the sample capture; Grafana's Prometheus datasource tests OK; GNS3 web UI logs in as `admin`.
3. On the VM: `ss -ltnp` shows **only** nginx on `0.0.0.0:443`; every other listener is `127.0.0.1`.
4. `probe_success` is `1` for all five vhosts in Prometheus.
5. Memory used stays ≥ 2 GiB below the VM total at rest.
6. No file in the repo contains a password: `./tests/run.sh` includes `no-credentials.bats`.
