# Rehearsal sites up — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/archive/2026-09-12-rehearsal-sites-up.md`. Format per `.claude/agents/validation-runner.md`:
check · expected · observed · verdict · command. Run over SSH from LXC 101 as `ubuntu`.

## Task 0 — VM grown to 12 GiB (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| VM memory | ≥ 11 GiB | `Mem: 11 0 11 0 0 11` (free -g; 12288 MiB configured) | PASS | `free -g` |
| Fresh boot after `qm set` | new boot time | `2026-09-12 22:43:39` | PASS | `uptime -s` |
| Docker | answers | `29.8.0` | PASS | `docker info` |
| VMs 100/108 | stopped (operator) | operator confirmed "done" after running the Task 0 Proxmox sequence | PASS (operator) | `qm list` |
| Note | — | nginx returned on `0.0.0.0:443` by itself: Ubuntu's package enables the unit at install. Not disabled — harmless, and it only serves what later tasks put behind it | info | `ss -ltnp` |

## Task 1 — Internal CA and one five-name certificate (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| easy-rsa from bundle | installs offline-style | `Setting up easy-rsa (3.1.7-2)` | PASS | `apt-get install ./easy-rsa_*.deb` (sourcelist=/dev/null) |
| Server cert chains to CA | OK | `pki/issued/lab.crt: OK` | PASS | `openssl verify -CAfile pki/ca.crt pki/issued/lab.crt` |
| SANs | five `.lab` names | `DNS:portal.lab, DNS:malcolm.lab, DNS:gns3.lab, DNS:monitoring.lab, DNS:docs.lab` | PASS | `openssl x509 -ext subjectAltName` |
| Installed into nginx | crt 0644, key 0600, ca 0644, htpasswd 0640 www-data; old pair gone | as expected (`ls -l`) | PASS | `install …; rm -f malcolm.lab.{crt,key}` |
| Snippets + Malcolm vhost | `nginx -t` ok, reload | `test is successful`; journal `Reloaded nginx.service` | PASS | `nginx -t; systemctl reload nginx` |
| Served chain (SNI malcolm.lab, CA trusted) | code 0, CN=lab | `Verify return code: 0 (ok)` · `subject=CN = lab` (first probe raced the reload and saw the old cert; second probe correct) | PASS | `openssl s_client -servername malcolm.lab -CAfile ca.crt` |
| CA handed over | file fetched | `ca.crt` copied to the session scratchpad; operator: `scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .` | PASS | `scp` |

## Task 4 — portal.lab (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| vhost enabled | `nginx -t` ok | `test is successful`, reloaded | PASS | `nginx -t; systemctl reload nginx` |
| Unauthenticated | 401 | `unauth 401` | PASS | `curl --cacert ca.crt --resolve portal.lab:443:127.0.0.1` |
| Authenticated | landing page | `<title>R770 Lab Portal` | PASS | same, `-u analyst:…` |

## Task 5 — docs.lab (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| MkDocs build with the bundled image | builds | `Documentation built in 0.27 seconds`; `site/` = `404.html access assets cli-tools gns3 index.html malcolm search sitemap.xml wan` | PASS | `docker run --rm -v $PWD:/docs squidfunk/mkdocs-material:latest build` |
| Unauthenticated | 401 | `unauth 401` | PASS | `curl … https://docs.lab/` |
| Authenticated | wiki | `<title>Analyst Guide — R770 Network Lab`; `/malcolm/` → `200` | PASS | same, `-u analyst:…` |

## Task 2 — Malcolm up behind the portal (2026-09-12 22:49–22:56)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Rebind intact | `127.0.0.1:8443:443/tcp` in compose | line 1453 present | PASS | `grep -n 8443:443 docker-compose.yml` |
| Start via Malcolm's own script | 27 services healthy | 27 up; `all 27 healthy` at ~+6 min (arkime, logstash, netbox last) | PASS | Malcolm's `start` under `nohup` |
| Through the portal, CA-verified | 200/302, `tls=0` | `/`→200 · `/arkime/`→302 · `/dashboards/`→302 · `/netbox/`→200 · `/readme/`→200, all `tls=0` | PASS | `curl --cacert ca.crt --resolve malcolm.lab:443:127.0.0.1 -u analyst:…` |
| Bindings | portal `0.0.0.0:443`, Malcolm `127.0.0.1:8443` | as expected | PASS | `ss -ltnp` |

## Task 3 — Sample capture in Malcolm (2026-09-12)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Interface discovered | one name | `eth0` (the DHCP NIC) | PASS | `ip -o route get 1.1.1.1` |
| 60 s self-generated capture | hundreds of packets | `sample-20260912.pcap`: 113,659 bytes, **701 packets** (DNS, TLS, HTTP, ICMP, LAN) | PASS | `tcpdump -i eth0 -s 0 -w … 'not port 22'` + curl/dig/ping loop |
| Malcolm picks it up | `upload/` → `processed/` | `processed/sample-20260912.pcap` within 150 s | PASS | `cp … pcap/upload/; chown 1000:1000` |
| Arkime indexed it | sessions > 0 | **350** sessions; index `arkime_sessions3-260912` = 350 docs | PASS | `/arkime/api/sessions?date=24&length=1`; `/mapi/indices` |
| Zeek analysed it | Zeek logs | `zeek-logs/current/`: `conn`, `dns`, `files`, `http`, `json_streaming_packet_filter` logs for `sample.pcap`; `ZEEK_AUTO_ANALYZE_PCAP_FILES=true` | PASS | `ls zeek-logs/current/` |
| Zeek logs indexed | a `malcolm_beats_zeek*` index with docs | **PENDING at 23:05** — only `malcolm_beats_initial` (0 docs); Filebeat/Logstash show 41 zeek lines in 30 min; Logstash at 2.2 GiB on a tight VM. Not a capture-path failure — the logs exist; the pipeline is slow. Re-check from Dashboards when using the site | PENDING | `/mapi/indices` |

## Task 6 — monitoring.lab (2026-09-12 22:57)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| node_exporter from bundle | metrics | `Setting up prometheus-node-exporter (1.7.0-1ubuntu0.3)`; 2,504 `node_*` metrics | PASS | `apt-get install ./prometheus-node-exporter_*.deb` |
| Image tags from the bundle's list | five refs, no pull | `.env` holds five refs from `docker/monitoring-image-list.txt`; `compose up -d --pull never` → 5 `Started` | PASS | `docker compose up -d --pull never` |
| Services | 5 up | alertmanager, blackbox, cadvisor (healthy), grafana, prometheus `Up` | PASS | `docker compose ps` |
| Through the portal | Grafana / ready / ready | `<title>Grafana` · `Prometheus Server is Ready. 200` · `OK 200` (first probe raced the nginx reload and hit the default vhost; re-probe correct) | PASS | `curl --cacert … --resolve monitoring.lab:443:127.0.0.1` |
| Targets | all up | `prometheus`, `node`, `cadvisor` up; `portal-vhosts` ×5 up | PASS | `/prometheus/api/v1/targets` |
| Bindings | five on 127.0.0.1 | `127.0.0.1:{3000,8080,9090,9093,9115}` | PASS | `ss -ltnp` |
| Note | — | cAdvisor uses **1.3 GiB** with default housekeeping on a 27-container host; trim with `--docker_only`/`--housekeeping_interval` on the R770 (Phase 14) | info | `docker stats` |

## Task 7 — gns3.lab (2026-09-12 22:59–23:00)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| venv from wheelhouse | pinned release | `gns3server 3.0.6`; 12 appliance definitions copied | PASS | `pip install --no-index --find-links …/gns3/wheelhouse gns3-server` |
| First start | server up | **FAIL**: `Could not create JWT secret key file '/etc/gns3/gns3_jwt_secret_key': Permission denied` then `unable to open database file` (`/etc/gns3/gns3_controller.db`) — GNS3 v3 uses the config file's directory as its state dir; `/etc/gns3` was root-owned, server runs as `ubuntu` | FAIL → fixed | `/var/log/gns3/server.log` |
| Fix | dir owned by service user | `chown -R ubuntu:ubuntu /etc/gns3`; restart → `Application startup complete`; `gns3_controller.db`, `gns3_jwt_secret_key` created there. Template annotated | PASS | `sudo chown -R ubuntu:ubuntu /etc/gns3` |
| Bind | `127.0.0.1:3080` | `127.0.0.1:3080` | PASS | `ss -ltnp` |
| API through portal | pinned version | `{"controller_host":"127.0.0.1","version":"3.0.6","local":false}` | PASS | `curl https://gns3.lab/v3/version` |
| Web UI | title | `/` → 308 → `/static/web-ui/bundled`; `<title>GNS3 Web UI` | PASS | `curl -L` |
| Login | token | `login: token issued` (`/v3/access/users/login`, admin) | PASS | `curl -X POST …` |
| Local compute | connected | log: `Connected to compute 'local' WebSocket`; `/v3/computes` listed 0 at +3 s (registration follows the WebSocket connect) | PASS (log) | `grep compute server.log` |
| Node start | — | **SKIPPED** — dynamips/ubridge/vpcs are not in the bundle; out of scope for "sites up" | SKIPPED | — |
| Note | — | the `[Controller] jwt_secret_key` template key was not honoured (`No JWT secret key configured, generating one`); GNS3 keeps the key in `gns3_jwt_secret_key` beside the config. Harmless; the template line stays as documentation of intent | info | server.log |

## Task 8 — Whole portal, measured (2026-09-12 23:03)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Five sites, CA-verified | 200/302/308, `tls=0` | `portal.lab 200` · `malcolm.lab 200` · `gns3.lab 308` · `monitoring.lab 302` · `docs.lab 200`, all `tls=0` | PASS | `curl --cacert ca.crt --resolve <host>:443:127.0.0.1 -u analyst:…` |
| Public listeners | only `0.0.0.0:443` | `0.0.0.0:443` only | PASS | `ss -ltnp` |
| Blackbox | 5 × `probe_success 1` | all five `1` | PASS | `/prometheus/api/v1/query?query=probe_success` |
| Memory (12 GiB VM) | ≥ 2 GiB free | used 9.2 Gi, **available 2.5 Gi**; opensearch 4.9 GiB, logstash 2.2 GiB, cadvisor 1.3 GiB, suricata 353 MiB, dashboards 203 MiB, grafana 180 MiB, prometheus 176 MiB | PASS | `free -h; docker stats` |
| Repo suite | green | 97 tests, 0 failures | PASS | `./tests/run.sh` |

## How to use it (operator)

1. Hosts line on your machine: `192.168.4.28 portal.lab malcolm.lab gns3.lab monitoring.lab docs.lab`
2. Trust the CA once: `scp ubuntu@192.168.4.28:/etc/nginx/ssl/ca.crt .` → import as a trusted root.
3. Start at https://portal.lab/ (login `analyst`).
4. Passwords, on the VM only: `cat ~/.malcolm-rehearsal-pw` (analyst), `cat ~/.monitoring.env` (Grafana admin), `cat ~/.gns3-admin-pw` (GNS3 admin).

## If the VM reboots (nothing is enabled at boot, by decision — nginx and node_exporter are the package-enabled exceptions)

    sudo systemctl start nginx prometheus-node-exporter
    cd ~/malcolm/malcolm/scripts && ./start             # Malcolm's own start script
    cd ~/r770/config/monitoring && docker compose up -d --pull never
    tmux new -d -s gns3 "/opt/gns3/bin/gns3server --config /etc/gns3/gns3_server.conf --logfile /var/log/gns3/server.log"

VMs 100 and 108 must stay stopped on Proxmox while this runs.

## Teardown (2026-09-12, operator-confirmed scope: remove the test, keep the bundle)

| Check | Expected | Observed | Verdict | Command |
|---|---|---|---|---|
| Malcolm | wiped, dir removed | Malcolm's `wipe` → 0 containers; `~/malcolm`, `~/.malcolm-rehearsal-pw`, exported config, `~/GNS3` removed | PASS | `wipe; rm -rf` |
| Monitoring | down, volumes gone | `compose down -v` → 8 removed; `~/.monitoring.env` removed | PASS | `docker compose down -v` |
| GNS3 | stopped, removed | `gns3server` outlived its tmux session (still on `:3080`) → `pkill`; `/opt/gns3 /etc/gns3 /srv/gns3 /var/log/gns3`, pw + jwt files removed | PASS | `pkill -f gns3server; rm -rf` |
| nginx | sites/CA gone, service stopped | five vhosts, snippets, `ssl/`, `lab.htpasswd`, `/srv/www` removed; default site relinked; `nginx -t` ok; stopped (package left installed) | PASS | `rm; nginx -t; systemctl stop nginx` |
| node_exporter | purged | `node_exporter purged` | PASS | `apt-get purge` |
| Test files | gone | `~/lab-ca`, `~/r770/config`, `~/r770/wiki`, sample PCAP, start logs, `scripts-20260911/` (partial `bundle-20260911`), packed builder, apt-refresh log removed | PASS | `rm -rf` |
| Docker leftovers | 0 volumes, 0 containers | 16 anonymous dangling volumes pruned → `volumes: 0 containers: 0`; **38 images kept** (23 Malcolm + monitoring, from the bundle) | PASS | `docker volume prune -f` |
| Listeners | none of the test ports | `no test listeners` | PASS | `ss -ltnp` |
| Bundle | intact | `bundle-20260908`: 13 entries, `verify` → `PASS WITH WARNINGS — 2 warning(s)` (the accepted pair) | PASS | `r770-bundle.sh verify` |
| VM at rest | — | disk 51 G used / 336 G free; mem 665 Mi used / 11 Gi available; VM still 12 GiB (Proxmox) | info | `df; free` |

**Kept on purpose:** `bundle-20260908` (amended, the only correct copy), `~/r770/scripts/` (current), the loaded images,
and the bundle-installed `easy-rsa`, `python3-venv`, `python3-ruamel.yaml`, `python3-dotenv`, `nginx` packages.
**Operator follow-ups:** remove the imported `R770 Lab CA (staging rehearsal)` from the browser trust store — the CA
no longer exists; drop the `.lab` hosts line; optionally `qm set 9770 --memory 8192` to return host RAM.
