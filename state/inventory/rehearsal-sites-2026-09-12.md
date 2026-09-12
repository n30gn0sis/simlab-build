# Rehearsal sites up — evidence (staging VM 9770, 192.168.4.28)

Plan: `work/plans/active/2026-09-12-rehearsal-sites-up.md`. Format per `.claude/agents/validation-runner.md`:
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
