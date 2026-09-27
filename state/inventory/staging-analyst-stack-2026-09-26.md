# Analyst stack proof run 2026-09-26: Malcolm, CA, portal and UFW deployed offline on VM 9771

> This is sub-project 2 (`docs/superpowers/specs/2026-09-26-analyst-stack-design.md`), deployed **only from the bundle's `site/scripts/`** (`/data/staging/bundle-20260926/site/scripts/`) on VM 9771, with internet cut for the host and its containers (`r770-airgap-sim.sh block --minutes 240`).
>
> **Code under test:** branch `claude/analyst-stack-design` at `05d7772`. It reached the VM by `git push` over SSH to a temporary branch, so the air gap stayed up, and `site/` was rebuilt with `--only site,manifest` each time. Both the bundle and the staged copy passed **`--strict`** after every rebuild.
>
> Raw logs are in `staging-analyst-stack-2026-09-26/`. A grep for the analyst password, tokens, private keys and password hashes over the whole folder is clean.

## VM preparation (Task 6)

- **Hosts.** VM 9770 was stopped with the scoped token. **root@pam was used once** (operator, 2026-09-26), only to read host memory and set memory. Host memory with 9770 stopped: 5.2 / 29.2 GiB used, 24.0 GiB free. That leaves ≥ 12 GiB after 9771 starts, above the 3 GiB floor.
- **Snapshot.** Before the change, snapshot `installed-2026-09-26` was taken with the token (task OK). It holds the state after the 2026-09-26 install test.
- **Memory.** Set to `12288` with `balloon: 0` (root), and read back. The VM shows 11 GiB in `free -g`.

## Result: ALL PASS, after three real defects were fixed in the repo

| Step | Result | Log |
|---|---|---|
| `--only site,manifest`, then `verify --strict` (bundle and `/data/staging` copy) | PASS; all six deploy scripts are in `site/scripts/` | `site-*.log`, `staged-verify.log` |
| Air gap | `archive.ubuntu.com`, `download.docker.com`, `pypi.org` and `github.com` are unreachable | chain launch |
| Analyst password | Generated on the VM (`openssl rand`) into `/root/analyst-pw`, root 600, never printed. The session copy is outside the repo | — |
| `r770-lab-ca.sh apply` + `verify` | 10/10 PASS: chain, the 5 SANs, validity, key mode, key↔cert match, installed CA = PKI CA | — |
| Malcolm `install` → `configure` → `auth` → `bind-loopback` → `start` → `health --timeout 900` | **PASS**: all **27 services running and healthy**; `127.0.0.1:8443` listening; no docker-proxy off loopback | `malcolm-chain.run3.log`, `malcolm-ps.txt` |
| Storage | Compose binds `/data/index` and `/data/pcap/raw` (with `upload/`), all owned by Malcolm's PUID user (uid 1000) | run 3 |
| `r770-portal.sh plan` / `apply` / `verify` (on the box) | **PASS**: docs built offline; nginx backup at 0600; `nginx -t` passed and nginx reloaded; portal/malcolm/docs.lab each return **401 without credentials and 200 with them**; only nginx on :443 | `portal.log` |
| `r770-malcolm-deploy.sh verify` | **PASS**: 28 804-byte loopback capture uploaded to `/data/pcap/raw/upload/`; Arkime indexed **4 sessions** on port 8443 since the capture started; Zeek wrote new logs; zeek container running healthy | `malcolm-verify.log` |
| `r770-ufw.sh plan` → `apply --minutes 10` → `confirm` (NEW, non-multiplexed ssh connection) → `verify` | **PASS**: discovered `eth0` / `192.168.4.0/22` / port 22; allow rules read back before the deny; switch armed, then cancelled by `confirm`; `verify` RESULT PASS (every Docker DNAT restricted to 127.0.0.1) | `ufw-*.log` |
| From outside (the session's LXC, 192.168.4.59): `r770-portal.sh verify --host 192.168.4.26 --cacert <exported CA>` | **PASS**: 401 then 200 for all three names | `outside-portal.log` |
| Malcolm through the portal | `/` **200**, `/arkime/` **302**, `/dashboards/` **302** | `outside-net.log` |
| Bare-IP TLS | handshake rejected (`curl` rc 35; `00-default-reject.conf`) | `outside-net.log` |
| Ports from outside | 22 **open**, 443 **open**; 8443, 9200, 5601, 80 and 31337 **closed** | `outside-net.log` |

## Listeners after the deploy (`ss -H -ltnp`)

| Address | Process | Exposure |
|---|---|---|
| `0.0.0.0:22`, `[::]:22` | sshd | allowed from the management subnet on `eth0` |
| `0.0.0.0:443`, `[::]:443` | nginx | allowed from the management subnet; IPv6 handshakes are rejected |
| `0.0.0.0:80`, `[::]:80` | nginx | **filtered by UFW**, see finding 4 |
| `127.0.0.1:8443` | docker-proxy (Malcolm's nginx) | loopback only |
| `*:9100` | prometheus-node-exporter | filtered by UFW (WARN in `verify`) |
| `192.168.4.26:53`, `127.0.0.1:53`, `[::1]:53`, link-local :53 | dnsmasq | filtered by UFW (WARN) |
| `127.0.0.53`/`127.0.0.54:53` | systemd-resolved | loopback only |

## Real defects found (the stubbed suite could not see them), fixed in the repo

Each fix went through a repo change, a commit and the test suite, then was pushed to the VM and re-run. Nothing was hand-edited on the VM.

1. **Malcolm refuses root** (run 1: `Exception: auth_setup should not be run as root`).
   - Every `scripts/*` verb except `install.py` goes through `control.py`, which refuses uid/euid 0 or a `root` login name.
   - Fix `f3d7c5e`: `auth_setup` and `start` run through `runuser` as the PUID user from `config/process.env`, with HOME/USER/LOGNAME set. The Malcolm tree and its data dirs are chowned to that user first.
   - **For the R770:** the user must exist, be in `docker`, and be named by `processUserId`/`processGroupId` in `config/malcolm/malcolm-config.json`.
2. **`pcapDir`/`indexDir` were ignored.**
   - The first configure rendered `./pcap` and `./opensearch`. Malcolm's installer honours the storage keys only when `useDefaultStorageLocations` is false (26.08 `installer/core/dependencies.py`). Unset storage dirs fall back to the in-tree defaults (`installer/actions/shared.py`, `get_or_default`).
   - Fix `0391baf`: `useDefaultStorageLocations: false`.
3. **`configure` could only run once** (run 2: `/opt/malcolm/malcolm already exists, please specify a different installation path`).
   - The top-level installer always extracts the tarball. The tree's own `malcolm/scripts/install.py` reconfigures in place (a dry run confirmed it).
   - Fix `05d7772`: `configure` uses the in-tree installer once the tree exists.
4. **Open, for the final review:** UFW allows only 22 and 443, so the `.lab` vhosts' `:80 → https` redirects can never be reached. Either allow 80 from the management subnet or drop the redirects.

The review of fixes 1–2 raised hardening items for the recursive chown (canonicalise and allowlist the paths, create missing data dirs first) and for where PUID comes from. They are being fixed in the repo (fix round 5). Run 3 used paths inside that allowlist.

## After the run

- Air gap lifted (`egress restored`, status `OPEN`) **after** the logs were collected.
- VM 9771 stopped and snapshotted `analyst-stack-2026-09-26` with the token, left at 12 GiB. **Start it only when the host has room** (≥ 3 GiB free after its 12 GiB).
