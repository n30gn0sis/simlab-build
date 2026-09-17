# Rehearsal sites up (redeploy, left running) — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/archive/2026-09-16-vm-deployment-test.md`. Format per `.claude/agents/validation-runner.md`:
check · expected · observed · verdict · command. Run over SSH from LXC 101 as `ubuntu`.

Unlike `state/inventory/rehearsal-sites-2026-09-12.md`, this deployment is from `bundle-20260915`
(the 2026-09-12 bundle no longer exists on the VM — wiped 2026-09-15) and is intentionally **left
running** at close-out — no Teardown section in this file.

## Task 1 — Readiness gate (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Proxmox VMs 100/108 stopped | stopped (operator) | operator confirmed "confirmed both are stopped" | PASS (operator) | operator statement |
| Scripts on VM match repo | sha256 pairs equal, all 6 | all 6 identical both sides (`6667ba67…` preflight, `de66af3a…` offline-fetch, `ed560973…` bundle, `a481bff2…` build-bundle, `59e1dbe4…` malcolm-deploy, `ce2238cb…` airgap-sim) | PASS | `scp …; sha256sum` both sides |
| VM memory | ≥ 11 GiB, no resize needed | `Mem: 11Gi total, 10Gi available` | PASS | `free -h` |
| Disk free | plenty of headroom | `51G used / 336G free / 387G total (14%)` | PASS | `df -h /` |
| `bundle-20260915` present | intact, ~14G, 13 top-level entries | `14G`, 13 entries | PASS | `du -sh; ls \| wc -l` |
| No stray listeners before setup | only ssh (22) and resolved (53) | `0.0.0.0:22`, `127.0.0.53%lo:53`, `127.0.0.54:53`, `[::]:22` | PASS | `ss -ltnp` |
| VM uptime | unchanged since last session (no reboot needed this time) | `2026-09-12 22:43:40` (no resize/reboot this run) | info | `uptime -s` |

## Task 2 — Internal CA and one five-name certificate (2026-09-16, full redo)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| nginx installed | 1.24.0, from bundle | `Setting up nginx (1.24.0-2ubuntu7.18)`; package-enabled by default (returned on `0.0.0.0:443` before any vhost existed — same harmless behavior noted 2026-09-12) | PASS | `apt-get install ./nginx*.deb` |
| easy-rsa from bundle | installs offline-style | `Setting up easy-rsa (3.1.7-2)` | PASS | `apt-get install ./easy-rsa_*.deb` |
| Server cert chains to CA | OK | `pki/issued/lab.crt: OK` | PASS | `openssl verify -CAfile pki/ca.crt pki/issued/lab.crt` |
| SANs | five `.lab` names | `DNS:portal.lab, DNS:malcolm.lab, DNS:gns3.lab, DNS:monitoring.lab, DNS:docs.lab` | PASS | `openssl x509 -ext subjectAltName` |
| Installed into nginx | crt/key/ca present | `lab.crt` 0644, `lab.key` 0600, `ca.crt` 0644 | PASS | `install …` |
| htpasswd installed | 0640 root:www-data, sourced from Malcolm's own `nginx/htpasswd` (Task 3) | as expected | PASS | `install -m 0640 -g www-data` |
| Snippets + Malcolm vhost | `nginx -t` ok, reload | `configuration file /etc/nginx/nginx.conf test is successful`; reloaded | PASS | `nginx -t; systemctl reload nginx` |
| Served chain (SNI malcolm.lab, CA trusted) | code 0, CN=lab | `Verify return code: 0 (ok)` · `subject=CN = lab` | PASS | `openssl s_client -servername malcolm.lab -CAfile ca.crt` |
| CA handed over | — | **operator note:** old 2026-09-12 CA is no longer trusted anywhere (new CA generated this run) — re-import `scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .` before trusting any `.lab` site | info | — |

## Task 3 — Malcolm up behind the portal, staying up (2026-09-16, full redo from bundle-20260915)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Install deps for Malcolm's installer | ruamel.yaml + dotenv from bundle | `Setting up python3-dotenv (1.0.1-1)`, `python3-ruamel.yaml.clib (0.2.8-1build1)`, `python3-ruamel.yaml (0.17.21-1)`; `imports ok 0.17.21` | PASS | `apt-get install ./python3-{ruamel.yaml,ruamel.yaml.clib,dotenv}_*.deb` |
| Extract installer | unzip from bundle | `install.py`, `docker-compose.yml`, installer dir present | PASS | `unzip bundle-20260915/malcolm/malcolm-*-docker_install.zip` |
| Images already present, no reload needed | 23/23 `ok` | 23 `ok` lines, `all images present` | PASS | `r770-malcolm-deploy.sh assert-tags ~/r770/bundle-20260915` |
| Configure via imported config (no re-derive) | non-interactive, no prompts | `--import-malcolm-config-file` (not `--defaults`, which conflicts with it) succeeded once python deps were present; heap unchanged: `OPENSEARCH_JAVA_OPTS ... -Xmx4g -Xms4g` | PASS | `install.py --non-interactive --configure --import-malcolm-config-file ~/malcolm-config-rehearsal.json` |
| `auth_setup` unattended | htpasswd + certs generated | `nginx/htpasswd` 68 bytes; `nginx/certs/{cert,key,dhparam}.pem` present | PASS | Malcolm's own `auth_setup --auth-noninteractive …` |
| One-line rebind, not an override file | `127.0.0.1:8443:443/tcp` | line 1453 changed from `0.0.0.0:443:443/tcp` | PASS | `sed -i '1453s#.*#    - 127.0.0.1:8443:443/tcp#'` |
| Start with Malcolm's own script | 27 services, all healthy within ~3 min | 27/27 `(healthy)`, ~3 min settle (8→6→4→3→2→2→2→1→1→1→0 still-starting across 11 polls) | PASS | Malcolm's own `start` script; `docker compose ps` |
| Port binding | `127.0.0.1:8443` only, nothing on `0.0.0.0:443` | `127.0.0.1:8443` only | PASS | `ss -ltnp` |
| Probe through the portal (CA, credentials) | matches 2026-09-12 result set | `/ 200`, `/arkime/ 302`, `/dashboards/ 302`, `/netbox/ 200`, `/readme/ 200` | PASS | `curl --resolve malcolm.lab:443:127.0.0.1 --cacert ca.crt -u analyst:$PW` |
| Memory after Malcolm alone | headroom for the remaining sites | `Mem: 11Gi total, 973Mi available` — **tighter than 2026-09-12** (VM was 12 GiB then, is 11 GiB now); flagged, watching closely as monitoring/GNS3 are added | WARN (info) | `free -h` |

## Task 4 — Sample capture in Malcolm (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Interface discovered, never guessed | one interface name | `eth0` | PASS | `ip -o route get 1.1.1.1` |
| Capture 60s of mixed traffic | a few hundred KB, hundreds of packets | `75728` bytes, `488` packets | PASS | `tcpdump -i eth0 -s 0 -w … "not port 22"` |
| Upload → processed | moves within ~2 min | moved immediately (first poll) | PASS | drop in `pcap/upload/`; poll `pcap/processed/` |
| Arkime indexed it | session count > 0 | `45` sessions within seconds, grew to `250` as enrichment continued | PASS | `arkime/api/sessions?date=24` |
| Zeek processed it | zeek log files produced | `zeek-logs/processed/sample-20260917.pcap-sample-*` holds `conn.log dns.log http.log ssl.log files.log` etc. (proven via disk, not logs — `zeek-1`/`pcap-monitor-1` containers log almost nothing to stdout by design) | PASS | `find ~/malcolm/malcolm/zeek-logs` |
| **Finding, not a failure:** no separate dated `malcolm_beats_zeek*` index appears (`malcolm_beats_initial` stays at 0 docs) — the 2026-09-12 evidence file's success shape doesn't hold on Malcolm 26.08.0's current architecture. Zeek-derived data is merged directly into `arkime_sessions3-260917` instead: protocol detection (`["udp","dns"]`, `["udp","dhcpv6"]`) and resolved DNS hostnames (`archive.ubuntu.com` — one of the exact hosts the capture queried) are both present on session records. | analyzable, zeek data present somewhere | 67 DNS sessions found via `expression=protocols==dns`, including `dns.host=archive.ubuntu.com` | PASS (different mechanism than 2026-09-12) | `arkime/api/sessions?...expression=protocols%3D%3Ddns` |

## Task 5 — portal.lab (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| vhost enabled | `nginx -t` ok | `configuration file /etc/nginx/nginx.conf test is successful`, reloaded | PASS | `nginx -t; systemctl reload nginx` |
| Unauthenticated | 401 | `unauth 401` | PASS | `curl --cacert ca.crt --resolve portal.lab:443:127.0.0.1` |
| Authenticated | landing page | first probe raced the reload and returned Malcolm's title (same class of race the 2026-09-12 cert probe hit); a clean retest returned `<title>R770 Lab Portal</title>`, `subject: CN=lab`, `HTTP/2 200` | PASS | same, `-u analyst:…`, verbose retest |

## Task 6 — docs.lab (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| MkDocs build with the bundled image | builds | `Documentation built in 0.25 seconds`; `site/` = `404.html access assets cli-tools gns3 index.html malcolm search sitemap.xml` (one deprecation notice about a future mkdocs-material major version — informational, no error) | PASS | `docker run --rm -v $PWD:/docs squidfunk/mkdocs-material:latest build` |
| Served | title + a real page | `<title>Analyst Guide — R770 Network Lab`; `malcolm page 200` | PASS | `curl --cacert ca.crt -u analyst:…` |

## Task 7 — monitoring.lab (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| node_exporter from bundle | base package only (not `-collectors`, which pulls deps not in this curated set) | first attempt with `-collectors` failed (`moreutils`, `python3-prometheus-client` unmet deps, not this bundle's problem to fix); base package alone: `Setting up prometheus-node-exporter (1.7.0-1ubuntu0.3)`, `2514` `node_` metrics | PASS (after correcting my own mistake) | `apt-get install ./prometheus-node-exporter_*.deb` |
| `.env` from `bundle-20260915`'s image list | 5 image refs, each matching a tag already in `docker image ls` | `prom/prometheus:v3.14.0`, `prom/alertmanager:v0.34.0`, `grafana/grafana-oss:12.1.0`, `ghcr.io/google/cadvisor:v0.60.5`, `prom/blackbox-exporter:v0.28.0` — all matched pre-loaded tags | PASS | `docker compose config --images` |
| Stack up, `--pull never` | five services `Up` | all five `Up`/`Up (healthy)` within 15s | PASS | `docker compose up -d --pull never` |
| Reachable | Grafana title, Prometheus/Alertmanager ready | `<title>Grafana`; `Prometheus Server is Ready. 200`; `OK 200` | PASS | `curl --cacert ca.crt -u analyst:…` |
| Targets | prometheus/node/cadvisor up; portal-vhosts probed | all up, incl. `portal.lab malcolm.lab monitoring.lab docs.lab` | PASS | `prometheus/api/v1/targets` |
| **Finding:** `gns3.lab` probe already reports `up` even though GNS3 doesn't exist yet (Task 8 not done) — nginx has no `gns3.lab` vhost, so the unmatched SNI falls back to whichever vhost nginx treats as default, which answers `401` (a status Blackbox's `lab_https` module accepts as "answers over TLS"). Not a monitoring-stack defect; it means this probe can't distinguish a real `gns3.lab` from an unrelated fallback vhost until the real vhost is enabled in Task 8 — worth re-checking there. | `down` until Task 8 (per 2026-09-12 baseline expectation) | `up` (false positive via fallback vhost) | WARN (info) | `prometheus/api/v1/targets` |
| Ports | all five on `127.0.0.1` only | `127.0.0.1:{3000,8080,9090,9093,9115}` | PASS | `ss -ltnp` |
| Memory after monitoring | headroom remains for GNS3 | `Mem: 11Gi total, 2.5Gi available` — improved since Task 3 (cache reclaim), still watching | PASS (info) | `free -h` |

## Task 8 — gns3.lab (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| venv + server from wheelhouse | version pinned in the fetch script; 12 definitions | `3.0.6`; `12` | PASS | `python3 -m venv; pip install --no-index --find-links wheelhouse gns3-server` |
| **Real defect found and fixed**: GNS3 3.0.6 writes its JWT secret key and controller SQLite DB directly under `/etc/gns3/` (not `~/.config/GNS3/…` as the older version the 2026-09-12 baseline used). That directory was only ever `chown`'d for the conf file itself, never the directory — server crashed on startup: `Permission denied: '/etc/gns3/gns3_jwt_secret_key'`, then `unable to open database file … gns3_controller.db`, then an unhandled `AttributeError: 'State' object has no attribute '_db_engine'`. Fixed: `chown -R ubuntu:ubuntu /etc/gns3` before starting. | starts cleanly | after the ownership fix, clean startup: `Starting server on 127.0.0.1:3080`, images auto-discovered, no errors | FAIL → fixed | `tmux new -d -s gns3 …`; `tail server.log` |
| Listening | `127.0.0.1:3080` | `127.0.0.1:3080` | PASS | `ss -ltnp` |
| API version | pinned version | `{"controller_host":"127.0.0.1","version":"3.0.6","local":false}` | PASS | `curl .../v3/version` |
| Web UI title (follows a 308 redirect from `/`) | a title from the bundled UI | `<title>GNS3 Web UI` | PASS | `curl -L …` |
| Login | token issued | `login: token issued` | PASS | `POST /v3/access/users/login` |
| **Finding, not blocking:** server log shows the local compute created and WebSocket-connected (`Create compute local`, `Connected to compute 'local'`), but `GET /v3/computes` returns `[]` for the logged-in admin token — likely an API-permission-scope change in 3.0.6 vs the version the 2026-09-12 baseline used. Node execution is out of scope for this plan regardless (dynamips/ubridge/vpcs not in the bundle), so not chased further; worth a look if a future plan needs the compute API. | `computes: 1` (2026-09-12 baseline) | `computes: 0` via REST; compute visibly live in the server log | WARN (info) | `GET /v3/computes` vs `server.log` |

## Task 9 — Whole portal, measured, left running (2026-09-16)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| All five sites, one pass, with the CA | five `200`/`302`/`308` with `tls=0` | `portal.lab 200`, `malcolm.lab 200`, `gns3.lab 308`, `monitoring.lab 302`, `docs.lab 200` — all `tls=0` | PASS | `curl --resolve … --cacert ca.crt -u analyst:…` |
| Only nginx on `0.0.0.0` | only `443` | `0.0.0.0:443` — nothing else in that list | PASS | `ss -ltnp` |
| `probe_success` for all five, real `gns3.lab` this time | all `1` | `docs.lab 1`, `malcolm.lab 1`, `gns3.lab 1`, `portal.lab 1`, `monitoring.lab 1` — the Task 7 false-positive is now a real pass since the actual vhost exists | PASS | `prometheus/api/v1/query?query=probe_success` |
| Memory at rest, all five sites + capture up | comfortable headroom | `Mem: 11Gi total, 2.4Gi available` — tighter than the 12 GiB / ~7.5Gi-used 2026-09-12 baseline (this VM is 11 GiB now), but stable across every task, no OOM/restart observed | PASS (info) | `free -h` |

## How to use it (operator)

1. Hosts line on your machine: `192.168.4.28 portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab`
2. Trust the CA — **a new one, generated 2026-09-16; the 2026-09-12 CA is no longer valid anywhere**: `scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .` → import as a trusted root.
3. Start at https://portal.lab/ (login `analyst`).
4. Passwords, on the VM only: `cat ~/.malcolm-rehearsal-pw` (analyst), `cat ~/.monitoring.env` (Grafana admin), `cat ~/.gns3-admin-pw` (GNS3 admin).
5. GNS3 node execution (dynamips/ubridge/vpcs) is out of scope — server + web UI only, same as 2026-09-12.

## This deployment is intentionally left running

**No teardown was executed as part of this plan.** Unlike the 2026-09-12 rehearsal, this stack stays
up for open-ended manual testing until the operator says otherwise. No auto-revert timer, no
scheduled teardown. If VM 9770 is needed for something else (a fresh bundle cut, another rehearsal),
that is a conscious decision the operator makes, not something this plan does automatically.

## If the VM reboots (nothing is enabled at boot, by decision — nginx and node_exporter are the package-enabled exceptions)

    sudo systemctl start nginx prometheus-node-exporter
    cd ~/malcolm/malcolm/scripts && ./start             # Malcolm's own start script
    cd ~/r770/config/monitoring && docker compose up -d --pull never
    tmux new -d -s gns3 "/opt/gns3/bin/gns3server --config /etc/gns3/gns3_server.conf --logfile /var/log/gns3/server.log"

VMs 100 and 108 must stay stopped on Proxmox while this runs (same standing requirement as 2026-09-12).

## Teardown (2026-09-17, operator-confirmed scope: full wipe, including the bundle)

Unlike the 2026-09-12 teardown (which kept `bundle-20260908`), the operator chose a full wipe to init
state this time — no bundle survives on the VM. Any future rehearsal needs a fresh bundle cut first.

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Malcolm | wiped, 0 containers | Malcolm's own `wipe` → `docker compose ps -q \| wc -l` = `0` | PASS | Malcolm's own `wipe` script |
| Monitoring | down, volumes gone | `alertmanager`/`prometheus` removed, `monitoring_grafana-data`/`monitoring_prom-data` volumes removed, network removed | PASS | `docker compose down -v` |
| GNS3 | stopped, removed | `gns3server` outlived its tmux session (same finding as 2026-09-12) → `pkill`; `/opt/gns3 /etc/gns3 /srv/gns3 /var/log/gns3 ~/GNS3`, admin pw + JWT removed | PASS | `pkill gns3server; rm -rf` |
| nginx | sites/CA/htpasswd gone, package purged | all site confs, snippets, `ssl/`, `lab.htpasswd`, `/srv/www` removed; `nginx`/`nginx-common` purged | PASS | `rm -f …; apt-get purge nginx nginx-common` |
| Rehearsal packages | purged | `easy-rsa`, `python3-venv`, `python3.12-venv`, `python3-ruamel.yaml(.clib)`, `python3-dotenv`, `python3-pip-whl`, `python3-setuptools-whl`, `prometheus-node-exporter` all purged; `dpkg-query` finds none | PASS | `apt-get purge …` |
| Test files, incl. the bundle | gone | `~/r770` (bundle-20260915 14G, config, wiki incl. root-owned MkDocs build output, fetch logs), `~/malcolm`, `~/lab-ca`, `~/malcolm-config-rehearsal.json`, start log, sample pcap, both password files removed; `~/r770/scripts/` recreated empty (matches the 2026-09-15 convention) | PASS | `rm -rf …` (root-owned MkDocs output needed `sudo rm -rf`) |
| Docker leftovers | 0 images/containers/volumes | `docker system prune -a --volumes` → `Images 0, Containers 0, Local Volumes 0, Build Cache 0` (ran long — 37 images / ~30GB — moved to background, confirmed via polling) | PASS | `docker system prune -a --volumes -f`; `docker system df` |
| Listeners | only ssh + resolved | `0.0.0.0:22`, `127.0.0.53%lo:53`, `127.0.0.54:53`, `[::]:22` | PASS | `ss -ltnp` |
| No stray iptables/hosts/cron/tmux | none | no DROP rules, no `.lab` hosts lines, no crontab, no tmux server running | PASS | `iptables -S OUTPUT; grep .lab /etc/hosts; crontab -l; tmux ls` |
| VM at rest | — | disk `11G used / 376G free / 387G total (3%)`; mem `624Mi used / 10Gi available`; VM still 11 GiB (unchanged, no resize this run) | info | `df; free` |

**Kept on purpose:** `~/r770/scripts/` (empty, ready for the next fetch), base staging tooling (docker, curl,
gpg, sha256sum, unzip, wget, pigz, jq, rsync, `~/.gnupg`, `~/.ssh`) — matches the 2026-09-15 init-state baseline.
**Nothing else survives** — this was a full wipe, not a "keep the bundle" teardown like 2026-09-12.
**Operator follow-up:** remove the 2026-09-16 lab CA from any browser trust store where it was imported —
the CA no longer exists on the VM; drop the `.lab` hosts line; a future rehearsal needs `scripts/r770-offline-fetch.sh` run again from scratch.
