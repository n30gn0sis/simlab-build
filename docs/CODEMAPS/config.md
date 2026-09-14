<!-- Generated: 2026-09-14 | Files scanned: 85 | Token estimate: ~550 -->
# Config — what ships to the R770 and which phase consumes it

Nothing under `config/` runs on staging. Files are copied into the bundle or onto the R770 by the
install runbook. Proven working on the staging VM in the 2026-09-12 rehearsal (evidence in `state/inventory/`).

```
browser ──443──▶ nginx (R770)  portal.lab ─▶ config/portal/index.html
                               docs.lab ───▶ mkdocs site built from docs/analyst-wiki + config/docs/mkdocs.yml
                               gns3.lab ───▶ gns3server :3080 (config/gns3/gns3_server.conf.template)
                               monitoring.lab ─▶ grafana / prometheus / alertmanager (config/monitoring/)
                               malcolm.lab ▶ 127.0.0.1:8443 (Malcolm rebound off 443, arrangement B)
```

| Path | Phase | Notes |
|---|---|---|
| `config/nginx/portal.lab.conf` + 4 site confs | 13 | one `server` each; TLS + auth via snippets |
| `config/nginx/snippets/lab-tls.conf` | 13 | internal CA cert, one cert with five SANs |
| `config/nginx/snippets/lab-auth.conf` | 13 | basic auth, included by portal, docs and monitoring only (GNS3 and Malcolm bring their own login) |
| `config/portal/index.html` | 13 | static landing page linking the five names |
| `config/docs/mkdocs.yml` | 13 | builds `docs/analyst-wiki/` into docs.lab |
| `config/gns3/gns3_server.conf.template` | 8 | `__PASSWORD__` / `__JWT__` tokens filled at install; config dir must be owned by the service user |
| `config/monitoring/docker-compose.yml` | 14 | image tags come from a generated `.env` fed by the bundle's image list, never hard-coded |
| `config/monitoring/prometheus.yml` | 14 | route-prefix `/prometheus/`; jobs: prometheus, node, cadvisor, portal-vhosts (via blackbox) |
| `config/monitoring/blackbox.yml` | 14 | probes the five `.lab` names via host-gateway |
| `config/monitoring/alertmanager.yml` | 14 | `null` receiver: alerts are visible, nothing is notified |
| `config/monitoring/grafana/provisioning/datasources/prometheus.yml` | 14 | single datasource |
| `config/malcolm/malcolm-config-rehearsal.json` | 10 | installer answers export; zero credential keys |

Malcolm itself has no config here: its installer is driven non-interactively (runbook Part 8),
auth via its own `auth_setup`, and started with its own start script (a compose override is ignored).

Secrets never live in `config/`: the CA key, htpasswd, GNS3 password and JWT are generated on the box.
