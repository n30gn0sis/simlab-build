# Sub-project 2 — Analyst stack: internal CA, Malcolm, portal, UFW

**Date:** 2026-09-26 · **Status:** design approved by operator, not yet implemented
**Part of:** "deploy and configure the analyst stack" (`docs/superpowers/specs/2026-09-24-bundle-to-r770-design.md` §"The larger goal")

## Decisions (operator, 2026-09-26)

1. **Script it, and prove it on VM 9771.** The hand procedure proven on staging on 2026-09-12 and 2026-09-16 (`state/inventory/rehearsal-sites-2026-09-16.md`) becomes reusable scripts. They're proven offline on 9771, starting from its install-test state (`state/inventory/staging-install-test-2026-09-26.md`), then run on the R770 later as operator-gated steps.
2. **Memory:** 9771 goes to **12 GiB** (root, once). It only starts when the host can hold it: 9770 stopped or small enough that at least 3 GiB stays free.
3. **Approach A:** small focused scripts, one per component, each with `plan | apply | verify` (plus component-specific verbs), idempotent, and bats-tested with stubbed tools.

## Scope

In: the internal CA; Malcolm (configure, auth, loopback rebind, start, health, verify); the portal (`portal.lab`, `malcolm.lab`, `docs.lab`); UFW for the portal and SSH.
Out: `gns3.lab` and `monitoring.lab` (their own sub-projects, though the certificate already carries their names); `.lab` DNS (sub-project 5, so clients use hosts-file entries until then); capture ports and live capture (sub-project 3); Malcolm sizing for the R770 (Phase 10, after measurement).

## Delivery path: `site/` in the bundle

The fetch copies this repo's `scripts/`, `config/` and `docs/analyst-wiki/` into a new bundle directory **`site/`**, so the manifest covers them and `verify --strict` checks them. The deploy always runs from `/data/staging/bundle-*/site/`, exactly the reviewed code. Tests: a bundle built by the fetch has `site/` manifested, and `verify` fails if a `site/` file is modified.

## `scripts/r770-lab-ca.sh plan | apply | verify | export-ca`

- An easy-rsa CA (from the bundle) in `/etc/r770-ca`, mode 0700, root-owned.
- One server certificate, `CN=lab`, SANs `portal.lab malcolm.lab docs.lab gns3.lab monitoring.lab`.
- Installed as `/etc/nginx/ssl/lab.crt` (0644), `lab.key` (0600) and `ca.crt` (0644), the paths `config/nginx/snippets/lab-tls.conf` expects.
- **Never regenerates an existing CA.** A new CA silently invalidates every client that trusted the old one (the 2026-09-16 lesson). A certificate reissue is only ever the explicit `--reissue-cert`.
- `verify`: the chain verifies, the five SANs are present, and it's at least 30 days from expiry.
- `export-ca` prints the CA certificate for analysts to import.

## `scripts/r770-malcolm-deploy.sh` (extended; `load` and `assert-tags` unchanged)

| Verb | Does |
|---|---|
| `install` | Unpack the bundle's Malcolm installer zip into `/opt/malcolm`. Its Python dependencies are already in the R770 package set |
| `configure` | `install.py --non-interactive --configure --import-malcolm-config-file config/malcolm/malcolm-config.json`, evolved from the rehearsal config. **Suricata off, GeoIP off** (decisions of record); PCAP bind-mounted at `/data/pcap/raw` and OpenSearch data at `/data/index` (buildout §3.2). On 9771 those are plain directories. The OpenSearch heap stays at the rehearsed 4 GiB |
| `auth` | Malcolm's own `auth_setup --auth-noninteractive`. The analyst password comes from a prompt or a file named by the operator. **It never appears in the repo, a log, or argv**, and ends up only in Malcolm's htpasswd |
| `bind-loopback` | Change Malcolm's nginx port mapping from `0.0.0.0:443:443` to `127.0.0.1:8443:443`. It matches that exact mapping (not a line number) and **refuses unless there's exactly one match**. The compose file is backed up first |
| `start` / `health` | Malcolm's own start script, then wait (up to about 10 min) until **every** service is healthy. On failure it lists the unhealthy ones. Afterwards nothing may listen beyond `127.0.0.1:8443` |
| `verify` | Write a small PCAP on the box (loopback capture while probing the portal; no internet needed) into Malcolm's upload dir. Arkime must show sessions and Zeek must write logs. The zeek container must be healthy, because Malcolm's zeek binary carries `cap_net_admin,cap_net_raw` and only runs when those are granted |

Every verb checks its preconditions and reports "already done" instead of repeating work.

## `scripts/r770-portal.sh plan | apply | verify`

- Install `config/nginx/conf.d/*` (the one `$connection_upgrade` map), `config/nginx/snippets/*`, the `00-default-reject.conf` catch-all and only the `portal`, `malcolm` and `docs` vhosts. No `.lab` vhost listens on `:80`: the firewall admits 22 and 443 only.
- Copy `config/portal/index.html` to `/srv/www/portal`.
- Build `docs.lab` offline with the bundled `squidfunk/mkdocs-material` image from `config/docs/mkdocs.yml` and `docs/analyst-wiki/`, into `/srv/www/docs`.
- `/etc/nginx/lab.htpasswd` comes from Malcolm's `nginx/htpasswd`, so there's one analyst login. This needs Malcolm `auth` first.
- Back up `/etc/nginx` and run `nginx -t` **before** any reload. If the test fails, restore the backup: nginx never reloads onto a broken config.
- `verify`: each name returns **401** without credentials and **200** with them, over TLS verified against the CA. Only nginx listens on `0.0.0.0:443`.

## `scripts/r770-ufw.sh plan | apply | confirm | verify | revert`

- **Discover, never guess:** the management interface and subnet come from the live SSH session (`$SSH_CONNECTION` → `ip route get`). If they can't be determined, it refuses.
- **Policy:** deny incoming by default, allow outgoing. Allow **22/tcp** and **443/tcp** only on the management interface, from the management subnet. Nothing else.
- **Before applying:** save `/etc/ufw` and `iptables-save` as the rollback, and print current vs proposed (the CLAUDE.md rule-3 gate).
- **Dead-man switch:** `apply` enables UFW and schedules an automatic `ufw disable` after 10 minutes (the detached-sleeper pattern from `scripts/r770-airgap-sim.sh`). **`confirm`, run from a new SSH session, cancels it.** A lockout undoes itself.
- `revert` restores the saved state.
- `verify` (as built):
  - UFW is active, default incoming is deny, the SSH and 443 rules are present and there are no other allow rules; a still-pending auto-revert WARNs;
  - a `docker-proxy` non-loopback listener, a Docker DNAT rule not restricted to `127.0.0.1`, or a non-loopback listener with no identifiable process FAILs — these are the ports Docker publishes past UFW;
  - any other non-loopback host listener WARNs (UFW's INPUT chain filters it).
  - Reachability from outside (SSH and 443 open; 8443 and an unused high port refused) cannot be seen from the box itself; the proof run checks it from a second host.

## Proof run on VM 9771

1. Host memory check (refuse if it doesn't fit). Snapshot `installed-2026-09-26` of the install-test state. Raise 9771 to 12 GiB (root, once). Start.
2. Air gap on (`scripts/r770-airgap-sim.sh`, auto-revert).
3. `r770-lab-ca.sh apply`, then Malcolm `install`, `configure`, `auth`, `bind-loopback`, `start`, `health`, then `r770-portal.sh apply`, then `r770-ufw.sh apply`, then `confirm` from a new SSH session.
4. From the Claude session, as an analyst would:
   - every name via `--resolve <name>:443:192.168.4.26` with the exported CA, giving 401, then 200 with credentials;
   - Malcolm `verify` (PCAP indexed);
   - `r770-ufw.sh verify`.
5. Air gap off. Evidence under `state/inventory/`, snapshot `analyst-stack-2026-09-26`, stop.

## R770 afterwards

The same scripts run from the bundle's `site/` as operator-gated steps once sub-projects 0 (storage and bundle import) and 1 (Docker) are done on the R770. UFW there waits for explicit operator confirmation, and the management interface discovered there is expected to be `lacp-trunk.10`.

## Risks

- **UFW lockout.** Mitigations: the dead-man switch, discovered (not guessed) management addressing, and `confirm` only from a new session.
- **Malcolm memory.** 12 GiB was enough on 2026-09-12. `health` fails loudly rather than hanging.
- **CA regeneration invalidating trust.** Prevented by construction: it never regenerates.
