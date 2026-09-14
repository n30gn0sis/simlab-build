# Account Provisioning — Design Specification

**Date:** 2026-09-14 · **Status:** proposed (awaiting operator approval) · **Implements at:** Phases 4, 8, 10, 13, 14 · **Owner of the resulting facts:** `state/BUILD-STATE.md` once applied

## Problem

The lab today has no per-person accounts. Every human-facing login is a shared
administrator: the `analyst` basic-auth password gates the portal, docs,
Prometheus and Alertmanager *and* is Malcolm's only account (the rehearsal
copied Malcolm's htpasswd into nginx); GNS3 has only its superadmin; Grafana
has only `admin`. There is no read-only tier anywhere, no SSH key enrollment
process, no SFTP drop-off account, and the analyst wiki marks all of this
**TBD**. `PRD.md` §2 promises per-analyst workspaces and names account
provisioning as the operator's job, and the buildout plan §9 requires
key-only SSH with `AllowGroups`, a scoped PCAP-import account, and restricted
`docker`/`libvirt` membership — none of which can be built without deciding
who the accounts are.

This spec decides that. It is a design, not an executed change: nothing here
is applied until the phases named above run through their normal gates.

## What was verified upstream (2026-09-14, at the pinned releases)

Every claim below about a product's account model was read from that
product's source or docs at the release pinned in `scripts/r770-offline-fetch.sh`
(see `OWNERS.md`). Anything not verified is marked **rehearse** and goes on the
staging checklist in §8.

| Product | Verified fact | Consequence for this design |
|---|---|---|
| GNS3 v3 | First start creates one superadmin from `default_admin_username`/`default_admin_password` and two built-in groups, `Administrators` and `Users`. Seven built-in roles: `Administrator` (all 48 privileges), `User`, `Auditor` (read-only), `Template manager`, `User manager`, `ACL manager`, `No Access`. **No default ACL entries exist**, and creating a project does not grant its creator anything. A non-superadmin with no matching ACE gets `403` on everything. Users are created via `POST /v3/access/users` (`username`, `password`, `full_name`, `is_active`) and cannot be made superadmin through the API. | Non-admin users need ACEs bound to the `Users` group; operators get an ACE on the `Administrators` group. Disable = `is_active: false`. |
| Malcolm | `NGINX_AUTH_MODE=basic` (installer default, measured in the 2026-09-12 rehearsal). `auth_setup` manages exactly one admin (`nginx/htpasswd`, bcrypt; `MALCOLM_USERNAME`/`MALCOLM_PASSWORD` in `config/auth.env`) and cannot add others; additional users are created by the admin in the **Malcolm User Management** page at `/auth` (htadmin, which also owns `htadmin/metadata`), and users change their own password there. **Role-based access control exists only in the `keycloak`/`keycloak_remote` modes**, so in basic mode every Malcolm login is equivalent to the admin. Malcolm's own SFTP (`upload` container, port 8022) is bound to `127.0.0.1`, has exactly one user (`MALCOLM_USERNAME`) and is chrooted — unusable as a multi-user drop-off. | Per-person Malcolm logins are possible but all-powerful; a read-only Malcolm tier requires switching to embedded Keycloak (deferred, §7). PCAP drop-off is a host SFTP account, not Malcolm's. |
| Grafana | Auth proxy (`[auth.proxy]` / `GF_AUTH_PROXY_*`) trusts a username header from a reverse proxy, auto-signs-up unknown users, and `users.auto_assign_org_role` sets their org role. Whitelisting is by source IP only. | Grafana can ride the portal's basic auth: one password, Viewer by default, operators promoted once. |
| nginx (host) | `auth_basic` reads a bcrypt htpasswd — the same format Malcolm writes. | The portal can read a copy of Malcolm's htpasswd, so Malcolm's self-service password page serves the portal too. |

## Design principles applied

- **One username per person, everywhere.** The Linux username is the identity; every service account for that person carries the same name.
- **Two password stores, not four.** Malcolm's htpasswd is the master for portal + docs + Prometheus + Alertmanager + Grafana + Malcolm (via a synced copy); GNS3 is the second. No directory server: GNS3 v3 speaks neither LDAP nor OIDC, and nginx's stock Ubuntu build has no LDAP module, so unification below two stores is not available without Keycloak (§7).
- **Keys for shells, passwords for browsers.** SSH is key-only (buildout §9). Web logins are the only passwords.
- **The host shell is the trusted tier.** Everything on `127.0.0.1` (Grafana 3000, Prometheus 9090, Alertmanager 9093, GNS3 3080, Malcolm 8443, the Docker socket) is reachable by any local process. Analysts therefore get **no shell by default**; a shell is an explicit, per-person grant with its own gate (§4.3).
- **Declarative roster in git, reconciled by one script.** Public keys are not secrets. The roster is the known-good configuration the decision rules demand; the script makes reality match it and reports drift.
- **Break-glass accounts are named, local, and locked down** — password in a root-only file, listed by location in the build document, never used day-to-day.

## 1. Accounts of record

### 1.1 Human tiers

| Tier | Linux group | SSH | sudo | Web (portal, docs, Prometheus, Alertmanager) | Grafana | Malcolm | GNS3 | Storage |
|---|---|---|---|---|---|---|---|---|
| **operator** | `lab-operators` (+ `sudo`, `docker`, `libvirt`, `kvm`) | key-only shell | full (`sudo` group; no `NOPASSWD`) | yes | `Admin` (promoted once by `admin`, §5.3) | admin-equivalent (basic mode) | `Administrators` group → role `Administrator` on `/` | home `/srv/work/<user>`; everything else by sudo |
| **analyst** | `lab-analysts` | key-only, **SFTP only** (`internal-sftp`, chrooted to `/data/staging`) | none | yes | `Viewer` (auto sign-up) | admin-equivalent (basic mode — see §7) | `Users` group → role `User` on the resource families in §4.2 | `/data/staging/<user>/` (own drop-off and export area), `/data/staging/ingest/` (shared, feeds Malcolm) |
| **analyst-shell** | `lab-analysts` + `lab-shell` | key-only shell | none | as analyst | as analyst | as analyst | as analyst | home `/srv/work/<user>`, plus the analyst SFTP dirs; group `lab-shell` is empty until the gate in §4.3 is met |

`docker` group membership is root-equivalent and is documented as such
(buildout §9); it is granted to `lab-operators` and the two service accounts
below and to nobody else. `libvirt` membership is restricted to operators.

### 1.2 Service accounts (non-human, no login)

| Account | Kind | Groups | Owns / runs | Why |
|---|---|---|---|---|
| `gns3` | system user, `/usr/sbin/nologin`, home `/etc/gns3` | `kvm`, `docker` | `gns3server` systemd unit; `/etc/gns3` (controller DB + JWT key are written beside the config — measured 2026-09-12), `/srv/gns3/*` | buildout §6; Docker nodes need the socket |
| `malcolm` | system user, nologin, home `/opt/malcolm` | `docker` | Malcolm's `control.py` start/stop via a systemd unit; `/opt/malcolm`; `PUID`/`PGID` in Malcolm's `process.env` set to this uid/gid (the rehearsal ran as uid 1000 = `ubuntu`, which the R770 must not repeat) | Malcolm docs require a non-root docker-group user; keeps Malcolm's files out of a human's home |
| `www-data` | package user (nginx) | — | reads `/etc/nginx/lab.htpasswd` (0640, group `www-data`) | stock |
| `prometheus` | package user (`prometheus-node-exporter`) | — | node_exporter, textfile collectors | stock |
| `dnsmasq`, `_chrony` | package users | — | `.lab` DNS, lab time | stock |
| root (systemd timers) | — | — | restic backup, retention enforcement, htpasswd sync (§5.1) | need to read everything |

Containers (Grafana, Prometheus, Alertmanager, cAdvisor, blackbox) keep their
image-internal uids; they need no host accounts.

### 1.3 Break-glass accounts

| Account | Where | Password file (root:root 0600, under `/etc/lab/secrets/`) | Used for |
|---|---|---|---|
| install-time OS account (currently the one SSH uses; name confirmed at Phase 4 discovery) | host | none — password **locked** (`passwd -l`), key-only, stays in `sudo` | recovery if every operator key is lost; also iDRAC console login |
| `admin` | GNS3 superadmin (from `config/gns3/gns3_server.conf.template`) | `gns3-admin.pw` | the provisioning script's API credential; manual recovery |
| `malcolm-admin` | Malcolm admin (`auth_setup --auth-admin-username malcolm-admin`, replacing the runbook's `analyst`) | `malcolm-admin.pw` | the provisioning script's credential for htadmin-equivalent edits; Malcolm's internal SFTP/Arkime/NetBox admin identity |
| `admin` | Grafana | `grafana-admin.env` (`GF_SECURITY_ADMIN_PASSWORD=…`; the compose `env_file` moves here from `/home/ubuntu/.monitoring.env`) | promoting operators; recovery if auth proxy breaks |

No account named `analyst` survives. Every secret file is listed here by
location and nowhere by value (buildout §9 "Secrets").

## 2. Roster: the declarative source

`config/users/roster.tsv` (tracked in git) — one line per human:

```
# username	tier	full_name	state
jdoe	operator	Jane Doe	active
asmith	analyst	Aki Smith	active
```

and `config/users/keys/<username>.pub` holding that person's SSH public key(s),
one per line. Public keys are not secrets; `tests/no-credentials.bats` already
rejects private-key material and stays the guard. `tier` is one of
`operator | analyst | analyst-shell`; `state` is `active | disabled`.
Removing a line means *remove the account* (after `disabled` has been applied
at least once — the script refuses to jump straight from a live account to
deletion).

## 3. The provisioning script

`scripts/r770-lab-user.sh` — runs **on the R770 as root**, ships in the
bundle like the other R770-side scripts, is shellcheck-clean, and is
idempotent: every subcommand converges the box to the roster and prints what
it changed.

| Subcommand | Effect |
|---|---|
| `apply` | reconcile every store (§5) to `roster.tsv` + `keys/`; the normal operation |
| `add <user> --tier T --name "…"` | append to the roster and apply; generates one random initial web password, prints it once to the terminal (never logged), and writes nothing else to disk |
| `disable <user>` / `enable <user>` | Linux: `usermod -L` + expire; key file emptied but retained; Malcolm htpasswd: line commented out; GNS3: `is_active=false`; Grafana: `is_disabled` via API. Reversible |
| `remove <user>` | only from `disabled`; deletes the Linux user (home preserved under `/srv/work/_removed/<user>`), htpasswd line, GNS3 user; Grafana user deleted |
| `reset-password <user>` | new random web password into Malcolm's htpasswd and GNS3 (both), printed once |
| `list` / `audit` | `list` shows the roster with per-store status; `audit` exits non-zero on any drift between roster and reality (a Linux user with a shell that the roster says is SFTP-only, an htpasswd entry with no roster line, a GNS3 user outside its group, a Grafana Admin not in `lab-operators`) — wired into `/validate` |

Stores it touches, and the mechanism:

- **Linux**: `useradd`/`usermod`, groups per §1.1, `AuthorizedKeysFile /etc/ssh/authorized_keys/%u` (root-owned directory, so an SFTP-chrooted user cannot enrol their own keys; operators control every key).
- **Malcolm htpasswd**: `htpasswd -B` against `/opt/malcolm/malcolm/nginx/htpasswd` (bcrypt, cost 10, the same call `auth_setup` uses). **Rehearse**: confirm the User Management page lists script-created users and that a later `auth_setup` re-run leaves their lines alone (its code manages only the admin line).
- **GNS3**: `POST /v3/access/users/login` as `admin`, then create/update users and group membership on `/v3/access/users` and `/v3/access/groups/{id}/members/{uid}`; ACEs from §4.2 created once and re-asserted on every `apply`.
- **Grafana**: nothing on `add` (auth proxy auto-signs-up on first visit); `disable`/`remove`/`audit` via `/api/admin/users` as `admin`.

The script never edits `sshd_config`, UFW, or Netplan — those stay in Phase 4's
gated steps. It has a `--dry-run` that prints every change and is what
`safety-reviewer` sees before the first real run.

## 4. Per-service design

### 4.1 SSH and SFTP (Phase 4, gated — touches `sshd_config`)

```
# /etc/ssh/sshd_config.d/10-lab.conf   (proposed; applied only after the Phase 4 gate)
ListenAddress <mgmt-ip>            # from state/BUILD-STATE.md at apply time, never a placeholder
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthorizedKeysFile /etc/ssh/authorized_keys/%u
AllowGroups lab-operators lab-shell lab-analysts <install-account's primary group>

Match Group lab-analysts
    ForceCommand internal-sftp
    ChrootDirectory /data/staging
    AllowTcpForwarding no
    X11Forwarding no
```

sshd `Match Group` cannot negate, so "SFTP-only unless granted a shell" is
expressed by membership: a person who is granted a shell is moved **out of**
`lab-analysts` into `lab-shell` by the script (they keep the same
`/data/staging/<user>` directory through its group ownership). Operators are
never in `lab-analysts`.

Chroot layout (`ChrootDirectory` demands the root be `root:root 0755`):

```
/data/staging/                 root:root        0755   the chroot
/data/staging/<user>/          <user>:lab-analysts 0750  own uploads, own exports
/data/staging/ingest/          malcolm:lab-analysts 2775  shared drop → Malcolm
```

`ingest/` is bind-mounted as Malcolm's `./pcap/upload` (compose bind, set in
Phase 10 alongside the `/data/pcap/raw` and `/data/index` binds the runbook
already pins). Malcolm's upload watcher moves files out of that directory
within about a minute of the upload completing and tags them from the
filename (`AUTO_TAG`), so the analyst's workflow is `sftp> put case42_dns.pcap
ingest/` and nothing else. **Rehearse**: that Malcolm ingests a file placed by
a non-Malcolm uid in the bind-mounted upload dir (docs describe the watcher for
web and SFTP uploads; direct placement must be shown working), and that the
setgid bit gives `malcolm` the group write it needs to move the file.

The wiki's "SFTP to `/data/staging/`, then use Malcolm's upload interface"
becomes "put it in `ingest/`"; the wiki edit rides Phase 11.

### 4.2 GNS3 (Phase 8)

On first start, after the superadmin exists, the script creates once:

| ACE | Group | Role | Path | propagate |
|---|---|---|---|---|
| operators | `Administrators` | `Administrator` | `/` | yes |
| analysts | `Users` | `User` | `/projects`, `/templates`, `/images`, `/computes`, `/appliances`, `/symbols` | yes |

The `User` role carries `Project.*`, `Snapshot.*`, `Node.*` (incl. console and
power), `Link.*` (incl. capture), `Drawing.*`, `Appliance.Allocate/Audit` and
read-only `Template/Symbol/Image/Compute.Audit` — i.e. build and run
topologies, capture on links, install appliances from the staged definitions,
but not add images or templates, not manage users, roles or computes. Exact
path spellings are taken from `GET /v3/access/acl/endpoints` at rehearsal;
the six above are the resource families the role's privileges name.

**Projects are shared by default**: every analyst sees every project. That is
the right default for a lab and the simple one. Isolation, when a case needs
it, is one user-level ACE on `/projects/<id>` with role `No Access` for the
`Users` group plus role `User` for the named user — user ACEs override group
ACEs and deeper paths override shallower ones (verified in the RBAC
repository). `r770-lab-user.sh project-lock <project> <user>` wraps it.

Operators are ordinary GNS3 users in `Administrators`; only the config-file
`admin` is a superadmin, and it is used only by the script.

### 4.3 Host shells for analysts — the gate

`lab-shell` starts empty. Granting the first analyst shell requires, first,
moving Grafana off TCP: `GF_SERVER_PROTOCOL=socket` with the socket
bind-mounted to `/run/lab/grafana.sock`, `GF_SERVER_SOCKET_GID` = `www-data`,
mode `0660`, and the vhost's `proxy_pass` pointed at it. Until then any local
process could set `X-WEBAUTH-USER` against `127.0.0.1:3000` and become any
Grafana user. Prometheus and Alertmanager (no auth of their own) get the same
treatment or stay operator-visible only. This is a documented pre-condition,
not a Phase-4 task; it is why analysts default to SFTP-only.

### 4.4 Malcolm (Phase 10)

- `auth_setup … --auth-admin-username malcolm-admin` (runbook §8.1a changes
  from `analyst`); password to `/etc/lab/secrets/malcolm-admin.pw`.
- Per-person users in Malcolm's htpasswd via the script; each person changes
  their own password on the **Malcolm User Management → User Self Service**
  page, which is also the portal's password (§5.1).
- In basic mode every login is admin-equivalent inside Malcolm: Arkime
  settings, Dashboards objects, NetBox, the upload page, extracted files. The
  wiki says so plainly. The read-only tier is the Keycloak upgrade in §7.
- Malcolm's own SFTP on 8022 stays loopback-bound and unused; UFW never opens it.

### 4.5 Grafana (Phase 14)

Additions to `config/monitoring/docker-compose.yml`'s `grafana.environment`
and the `monitoring.lab` vhost:

```
GF_AUTH_PROXY_ENABLED=true
GF_AUTH_PROXY_HEADER_NAME=X-WEBAUTH-USER
GF_AUTH_PROXY_HEADER_PROPERTY=username
GF_AUTH_PROXY_AUTO_SIGN_UP=true
GF_AUTH_PROXY_ENABLE_LOGIN_TOKEN=true
GF_USERS_AUTO_ASSIGN_ORG_ROLE=Viewer
GF_USERS_ALLOW_SIGN_UP=false
```

```
location / {
    include snippets/lab-auth.conf;              # was: Grafana's own login
    proxy_set_header X-WEBAUTH-USER $remote_user;
    proxy_set_header Authorization "";           # strip the basic-auth header before Grafana sees it
    …
}
```

Every roster user is a Grafana `Viewer` on first visit. The operator promotes
each `lab-operators` member to `Admin` once (Administration → Users, as
`admin`); `audit` flags an Admin who is not an operator. `admin` keeps
password login for recovery. `GF_AUTH_PROXY_WHITELIST` is set to the compose
network's gateway address once measured (`docker network inspect`), not
guessed — and it does not protect against local processes, which is §4.3's job.

### 4.6 Portal, docs, Prometheus, Alertmanager (Phase 13)

Unchanged mechanism (`snippets/lab-auth.conf`); the file behind it is now the
synced copy (§5.1), so it contains every roster user plus `malcolm-admin`, and
there is no shared password.

## 5. Keeping the stores in step

### 5.1 htpasswd sync (Phase 13)

A systemd **path unit** watches `/opt/malcolm/malcolm/nginx/htpasswd`
(`PathModified=`) and its service copies it to `/etc/nginx/lab.htpasswd`
(`install -m 0640 -g www-data`). Effect: a password changed on Malcolm's
self-service page is the portal's and Grafana's password within a second.
nginx re-reads the file per request; no reload. The copy is one-way; the
script and Malcolm are the only writers of the master.

### 5.2 GNS3 password

Independent (second store). Initial password from the script; users change it
in the GNS3 web UI (`PUT /v3/access/users/me`). `reset-password` re-syncs both
stores to one new value.

### 5.3 What `audit` compares

Roster ↔ `/etc/passwd` + groups ↔ `/etc/ssh/authorized_keys/` ↔ Malcolm
htpasswd ↔ `/etc/nginx/lab.htpasswd` (byte-equal to master) ↔ GNS3 users and
group membership ↔ Grafana users and org roles. Any entry in a store with no
roster line is drift. Runs inside `/validate` and as a daily timer whose
non-zero exit becomes a Prometheus textfile metric and an alert (buildout §10).

## 6. Auditing and backup

- auditd watch rules (buildout §9) extended to `/etc/ssh/authorized_keys/`,
  `/etc/ssh/sshd_config.d/`, `/etc/nginx/lab.htpasswd`,
  `/opt/malcolm/malcolm/nginx/htpasswd`, `/etc/gns3/`, `/etc/lab/secrets/`,
  and `sudo` use.
- restic (Phase 15) includes `/etc/ssh/authorized_keys/`, `/etc/lab/secrets/`,
  Malcolm's `nginx/htpasswd` + `htadmin/metadata`, `/etc/gns3/` (controller DB
  holds GNS3 users and ACEs), and the Grafana data volume. The roster itself
  is in git.

## 7. Deferred: Malcolm read-only tier via embedded Keycloak

Malcolm's RBAC (`ROLE_BASED_ACCESS` with `ROLE_READ_ACCESS`,
`ROLE_ARKIME_READ_ACCESS`, `ROLE_DASHBOARDS_READ_ACCESS`, `ROLE_UPLOAD`, …)
needs `NGINX_AUTH_MODE=keycloak`. The Keycloak container is already in the
stack (measured up and idle in the rehearsal). Switching means: Malcolm logins
move to Keycloak's realm (users and roles managed there, script gains a
Keycloak backend), the htpasswd sync in §5.1 loses its master (portal auth
would need Keycloak too, via `oauth2-proxy` or nginx `auth_request`), and the
redirects that were measured relative in basic mode must be re-measured. It
buys a genuine read-only analyst tier and single sign-on across portal,
Grafana and Malcolm. Trigger to revisit: the first user who must not be able
to delete Malcolm data (trainees, external reviewers). Until then, basic mode
with per-person logins is the simpler system and is what this spec builds.

## 8. Rehearsal checklist (staging VM 9770, before any R770 phase uses this)

1. `r770-lab-user.sh apply` from a two-line roster on a fresh VM: Linux users,
   groups, key files, chroot dirs exactly as §1.1/§4.1.
2. SFTP as an analyst: can `put` into own dir and `ingest/`, cannot `cd /`,
   cannot open a shell, cannot write `authorized_keys`.
3. Malcolm: script-created user can log in, appears in the User Management
   page, changes own password there → `/etc/nginx/lab.htpasswd` updates (path
   unit) → portal and Grafana accept the new password, Grafana auto-creates
   the user as Viewer.
4. Malcolm ingests a PCAP dropped into `ingest/` by the analyst's uid; tags
   from filename appear in Arkime.
5. GNS3: analyst logs in, sees templates, creates and runs a project, cannot
   list users or upload images; `project-lock` hides a project from a second
   analyst; `is_active=false` refuses login.
6. Operator: shell, sudo, Grafana Admin after promotion, GNS3 `Administrators`
   ACE lets them manage users through the web UI.
7. `disable` → every store refuses the user; `enable` restores; `audit` exits 0
   before and non-zero after a deliberate manual edit to any store.
8. `auth_setup` re-run leaves script-created htpasswd lines intact.

Evidence goes to `state/inventory/` as usual; `state/BUILD-STATE.md` Phase 4
row points here until then.

## 9. Changes this spec implies (applied in their phases, not now)

| Where | Change |
|---|---|
| `scripts/r770-lab-user.sh` *(new)* + `tests/lab-user.bats` | the script and its offline tests (dry-run against fixture roster/passwd/htpasswd) |
| `config/users/roster.tsv`, `config/users/keys/` *(new)* | the roster |
| `docs/plans/r770-install-runbook.md` §8.1a | `--auth-admin-username malcolm-admin`; add the `pcap/upload` → `/data/staging/ingest` bind next to §8.2 |
| `config/monitoring/docker-compose.yml` | `env_file: /etc/lab/secrets/grafana-admin.env`; the `GF_AUTH_PROXY_*`/`GF_USERS_*` lines of §4.5 |
| `config/nginx/monitoring.lab.conf`, `snippets/lab-auth.conf` | Grafana location gets `lab-auth` + the two headers; the snippet comment no longer says Grafana has its own login |
| `config/gns3/gns3_server.conf.template` | unchanged (`admin` stays the superadmin) |
| `docs/analyst-wiki/access.md`, `gns3.md`, `malcolm.md`, `index.md` | replace the four **TBD** markers with the tiers, the key-enrollment process ("send your public key to the operator"), the `ingest/` workflow, and the plain statement that a Malcolm login is admin-equivalent |
| `docs/plans/r770-network-lab-buildout.md` §9 | one sentence pointing here for the account model |
| `state/BUILD-STATE.md` | Phase 4/8/10/13/14 evidence rows once applied |
