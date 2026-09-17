# Rehearsal sites up (redeploy, left running) — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/active/2026-09-16-vm-deployment-test.md`. Format per `.claude/agents/validation-runner.md`:
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
