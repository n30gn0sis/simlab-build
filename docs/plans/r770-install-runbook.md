# R770 Install Runbook — from bundle to running lab

The R770 side of the air gap. Its counterpart is `r770-staging-runbook.md`,
which builds the bundle; this document installs it.

**Nothing here reaches the internet.** No `apt install` from upstream, no
`pip install`, no `docker pull`, no `curl`, no `wget`. If a step appears to
need the network, the step is wrong — stop and fix the bundle, not the box.

**Owned facts are referenced, never restated.** Versions come from the pin
block in `scripts/r770-offline-fetch.sh`; bundle sizes and cycle history from
`state/inventory/bundles.md`; hardware and phase status from
`state/BUILD-STATE.md`. See `OWNERS.md` before quoting any figure here.

---

## Where this runbook stops today

Read this before planning a window. The install is **not** a single sitting.

| Part | Phase | Needs first |
|---|---|---|
| 1–3 Receive, verify, APT repo | 3 → import | Phase 3 storage mounted (bundle lands on `/data/staging`) |
| 4–5 Docker + images | 6 | Part 3 |
| 6 VM base images | 7 | Part 3 |
| 7 GNS3 | 8 | Parts 4–6 |
| 8 Malcolm | 10 | Parts 4–5 |
| 9–11 Enrichment, portal, docs | 13, 14 | Part 8 |

There is **no iDRAC gate** — the operator dropped it on 2026-09-24 (no iDRAC or
PERC work on the R770; see `PRD.md` §6). Phase 5 (management networking) is no
longer a precondition for these parts; its own risk is handled when it is built.

---

## Part 0 — Before the media leaves staging

Do not skip this because the bundle "looks fine". The gapped side can only
verify what the manifest asserts; trust is established on staging.

- [ ] Manual categories staged: `dell/` and `gns3/appliances/`
- [ ] **Manifest regenerated after those manual additions** —
      `./scripts/r770-bundle.sh manifest <bundle-dir>`. A manifest written
      before a file existed cannot see that file.
- [ ] Gate passed on staging: `./scripts/r770-bundle.sh verify <bundle-dir> --strict`
- [ ] Ubuntu ISO GPG signature verified on staging (staging runbook Step 5)
- [ ] Gate passed again **from the transfer media**, before it leaves
- [ ] Site AV/content scan per policy

---

## Part 1 — Receive and gate on the R770

### 1.1 Mount the media read-only first

Read-only until the gate passes. A bundle that fails verification must not be
writable by the box that just rejected it.

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT      # identify the device — never assume
sudo mkdir -p /mnt/bundle
sudo mount -o ro /dev/<device> /mnt/bundle      # discovered name, not a placeholder
```

### 1.2 Run the gate

The verifier travels inside the bundle root and is covered by the manifest, so
it is gated by the same hashes as the payload.

```bash
cd /mnt/bundle/bundle-YYYYMMDD
./r770-bundle.sh verify .
```

| Exit | Meaning | Action |
|---|---|---|
| **0** | PASS | proceed |
| **2** | PASS WITH WARNINGS | disposition every warning in writing before proceeding |
| **1** | FAIL | **do not import.** The media is suspect; re-cut on staging |

Record the exact exit code and the summary line. "It passed" is not evidence.

### 1.3 Confirm the rollback exists

```bash
ls -d /data/staging/bundle-*          # the previous bundle is the rollback
```

The previous bundle stays on the box until this one has validated end to end.
Never delete it during an import.

### 1.4 Copy to local storage

```bash
sudo mkdir -p /data/staging
sudo cp -a /mnt/bundle/bundle-YYYYMMDD /data/staging/
cd /data/staging/bundle-YYYYMMDD
./r770-bundle.sh verify .            # gate again after the copy
sudo umount /mnt/bundle
```

Verifying after the copy catches a truncated or bit-flipped transfer. It costs
minutes; discovering it during a Malcolm deploy costs a bundle cycle.

---

## Part 2 — Preconditions

Confirm, do not assume:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -E '/var/lib/docker|/data|/srv'
df -h /var/lib/docker /data/pcap /data/index /srv/gns3 /srv/vms
systemd-detect-virt ; uname -r ; lsb_release -d
```

Every logical volume in the storage layout must be mounted at its intended
path **before** anything is imported. `docker load` into an unmounted
`/var/lib/docker` writes onto the root filesystem and fills it.

---

## Part 3 — APT: point the box at the local repo  *(GATED)*

**This edits `/etc/apt/sources.list.d/` and changes where the machine gets
software. Show current vs proposed and get explicit confirmation first.**

### 3.1 Place the repo

```bash
sudo mkdir -p /srv/repo
sudo cp -a /data/staging/bundle-YYYYMMDD/apt /srv/repo/
ls /srv/repo/apt/Packages.gz          # the flat-repo index must be present
```

### 3.2 Save the existing configuration — the rollback

```bash
sudo tar czf /root/apt-sources-$(date +%F).tar.gz \
    /etc/apt/sources.list /etc/apt/sources.list.d/
```

### 3.3 Replace the sources

```bash
sudo mv /etc/apt/sources.list.d /etc/apt/sources.list.d.upstream
sudo mkdir -p /etc/apt/sources.list.d
sudo sh -c ': > /etc/apt/sources.list'
echo 'deb [trusted=yes] file:/srv/repo/apt ./' | \
    sudo tee /etc/apt/sources.list.d/r770-local.list
echo 'Acquire::Languages "none";' | \
    sudo tee /etc/apt/apt.conf.d/99r770-no-translations
sudo apt update
```

The flat repo has no `Translation-*` files, so without this `apt update` prints
harmless `Translation-en` fetch errors on every run; this silences them.

`apt update` must succeed and must contact **only** `file:/srv/repo/apt`. Any
line mentioning an upstream host means a source survived — stop and fix it.

### 3.4 Disable the phone-home paths

```bash
sudo systemctl disable --now unattended-upgrades 2>/dev/null || true
sudo apt-get purge -y snapd
sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
```

Updates now arrive by bundle. That is deliberate, and it is the accepted cost
of the air gap.

**Rollback for Part 3:** restore the tarball from 3.2, delete
`/etc/apt/apt.conf.d/99r770-no-translations`, `apt update`.

---

## Part 4 — Docker Engine  *(Phase 6)*

The `docker-ce` debs ship in the bundle's `apt/`. Install from the local repo.

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
docker info --format '{{.ServerVersion}} / {{.DockerRootDir}}'
```

`DockerRootDir` must read `/var/lib/docker` on its own logical volume.

Configure no registry mirrors — there is no registry to reach. Confirm:

```bash
docker info --format '{{.RegistryConfig.Mirrors}}'     # expect []
```

---

## Part 5 — Load the container images

Three independent list/payload pairs. Each is loaded, then its tags are
asserted against the list that travelled with it.

```bash
cd /data/staging/bundle-YYYYMMDD
docker load -i malcolm/malcolm-images-*.tar.gz
docker load -i docker/monitoring-images.tar.gz
docker load -i gns3/docker-nodes/gns3-node-images.tar.gz
```

### Assert the tags — `docker load` lies by omission

`docker load` reports success even when the resulting tag set is incomplete.
Verify against the bundle's own lists:

```bash
./scripts/r770-malcolm-deploy.sh assert-tags /data/staging/bundle-YYYYMMDD
```

For the other two pairs, compare directly:

```bash
# docker image ls drops the default registry: docker.io/prom/prometheus:TAG is
# listed as prom/prometheus:TAG, docker.io/library/nginx:TAG as nginx:TAG.
# Normalise both sides, or every docker.io image looks missing.
norm() { sed -E 's#^docker\.io/library/##; s#^docker\.io/##'; }
docker image ls --format '{{.Repository}}:{{.Tag}}' | norm | sort > /tmp/loaded.txt
comm -23 <(grep -vE '^\s*(#|$)' docker/monitoring-image-list.txt | norm | sort) /tmp/loaded.txt   # expect empty
comm -23 <(grep -vE '^\s*(#|$)' gns3/docker-nodes/image-list.txt | norm | sort) /tmp/loaded.txt  # expect empty
```

Any line printed by `comm` is an image that did not load. Stop.

---

## Part 6 — VM base images  *(Phase 7)*

```bash
sudo mkdir -p /srv/vms/base
sudo cp -a /data/staging/bundle-YYYYMMDD/images/* /srv/vms/base/
qemu-img info /srv/vms/base/<image>          # confirm format and virtual size
```

Boot one throwaway guest — create → boot → network-test → destroy — before
trusting the pool.

---

## Part 7 — GNS3  *(Phase 8 — needs Phases 6 and 7)*

### 7.1 Server from the wheelhouse

No `pip install` from the internet. The wheelhouse is the index.

`python3 -m venv` needs `python3-venv` (+ `python3.12-venv`, `python3-pip-whl`) from the
curated set installed in Part 3 — without them the venv is created with no `pip` and the
next line fails with "No such file or directory" (seen on staging 2026-09-12). GNS3 3.x also
writes its controller database and JWT key **beside its config file**, so the directory
holding `gns3_server.conf` must be owned by the user the server runs as.

```bash
python3 -m venv /opt/gns3
/opt/gns3/bin/pip install --no-index \
    --find-links /data/staging/bundle-YYYYMMDD/gns3/wheelhouse gns3-server
/opt/gns3/bin/gns3server --version
```

`--no-index` is load-bearing: without it pip reaches for PyPI and hangs.

### 7.2 Appliance definitions and images

```bash
sudo mkdir -p /srv/gns3/{projects,images,appliances}
sudo cp -a /data/staging/bundle-YYYYMMDD/gns3/definitions/*.gns3a /srv/gns3/appliances/
sudo cp -a /data/staging/bundle-YYYYMMDD/gns3/appliances/*        /srv/gns3/images/
```

Definitions are free even where the images are licensed. A definition whose
image was never staged will appear in the GUI and fail at boot — inventory
them against what you actually hold.

---

## Part 8 — Malcolm  *(Phase 10 — needs Phases 3, 6, 9)*

### 8.1 Unpack and configure

```bash
sudo mkdir -p /opt/malcolm
sudo unzip /data/staging/bundle-YYYYMMDD/malcolm/*.zip -d /opt/malcolm
cd /opt/malcolm
# Malcolm's own installer, shipped inside its zip -- not a script from this repo.
# Needs root, needs python3-ruamel.yaml + python3-dotenv (in apt/ since
# 2026-09-12), and needs --non-interactive or it opens a TUI menu and waits.
sudo python3 /opt/malcolm/scripts/install.py --non-interactive --defaults --configure \
    --skip-splash --export-malcolm-config-file /opt/malcolm/malcolm-config.json
```

The installer extracts Malcolm to `/opt/malcolm/malcolm` and sizes the JVM
heaps to the host by itself (staging: OpenSearch 4g on an 8 GiB VM); check
`config/opensearch.env` before trusting the default on 128 GB.

### 8.1a Generate the auth material — not optional

`--configure` writes the `.env` files and nothing else. `htpasswd`, the TLS
certs, the OpenSearch keystore and `arkime/etc/wise.ini` all come from
`auth_setup`, and compose refuses to start without them (bind sources missing).
Unattended form, hashes generated on the box:

```bash
cd /opt/malcolm/malcolm
H_SSL=$(openssl passwd -1 "$ADMIN_PW")
H_HT=$(docker run --rm --entrypoint sh ghcr.io/idaholab/malcolm/nginx-proxy:<tag> \
         -c "htpasswd -bnBC 10 '' '$ADMIN_PW'" | tr -d ':\n')
./scripts/auth_setup --auth-noninteractive --auth-method basic \
    --auth-admin-username analyst \
    --auth-admin-password-openssl "$H_SSL" --auth-admin-password-htpasswd "$H_HT" \
    --auth-generate-webcerts --auth-generate-fwcerts \
    --auth-generate-netbox-passwords --auth-generate-valkey-password \
    --auth-generate-postgres-password --auth-generate-opensearch-internal-creds \
    --auth-generate-keycloak-db-password
```

Exporting the configuration makes it a replayable artifact rather than a
sequence of answers nobody wrote down.

### 8.2 Pin the heavy data to the right volumes

Bind PCAP to `/data/pcap/raw` and OpenSearch to `/data/index`. Left at
defaults, both land on the Docker volume and fill `/var/lib/docker`.

### 8.3 Size OpenSearch to this host, not to the installer's default

The installer's default heap is sized for a much smaller box than the R770 and
a much larger one than a rehearsal VM. Set it from the steady-state budget in
the buildout plan §8, and record the value you chose.

### 8.4 Bring it up

Take Malcolm off `0.0.0.0:443` first so the portal can own it (buildout §9;
re-apply after every installer run — the installer regenerates the file, and a
`docker-compose.override.yml` is ignored because `control.py` passes `-f`):

```bash
cd /opt/malcolm/malcolm
sed -i 's|^    - 0.0.0.0:443:443/tcp$|    - 127.0.0.1:8443:443/tcp|' docker-compose.yml
./scripts/start        # NOT raw 'docker compose up': control.py creates the
                       # keystore and touches files compose needs first
docker compose ps      # 27 services; arkime and logstash are the last to go healthy
ss -ltnp | grep -E ':(443|8443) '    # expect 127.0.0.1:8443 and nothing on 0.0.0.0:443
```

**Integration decided by measurement (2026-09-12, staging).** Malcolm sits
behind the portal: `config/nginx/malcolm.lab.conf` proxies `malcolm.lab` to
`127.0.0.1:8443`; every site answered identically to direct access, every
redirect stayed relative, and the stack came up healthy with all egress
dropped. Evidence: `state/inventory/malcolm-rehearsal-2026-09-12.md`.

### 8.5 Never commit what this step generates

Malcolm writes auth material during configure. Nothing under `config/*.env`
goes into git, ever.

---

## Part 9 — Enrichment data

```bash
sudo mkdir -p /opt/enrichment
sudo tar xzf /data/staging/bundle-YYYYMMDD/enrichment/emerging.rules.tar.gz \
    -C /opt/enrichment
```

Suricata is disabled initially, so these rules are staged, not active. GeoIP is
descoped — there is no geo enrichment in this build.

These feeds are only as fresh as the last bundle. That staleness is an accepted
risk of the air gap and belongs in the cycle log, not in a surprise.

---

## Part 10 — Portal and monitoring  *(Phases 13, 14)*

Nginx, Prometheus, Grafana, alertmanager, cAdvisor and the docs site all come
from the monitoring images loaded in Part 5. Internal CA only — issue portal,
Malcolm and GNS3 certificates from it and distribute the CA certificate to
analyst browsers. No ACME, no Let's Encrypt: both need the internet.

Publish a `.lab` name only where a route genuinely exists. Discovery found
iDRAC on a different subnet from management; a name that resolves to something
unreachable is worse than no name.

---

## Part 11 — Docs mirror  *(Phase 13)*

```bash
sudo mkdir -p /srv/docs
sudo tar xzf /data/staging/bundle-YYYYMMDD/docs/*.tar.gz -C /srv/docs
```

Docs mirrors are best-effort by design — a failed mirror warns, it never fails
a bundle. Expect gaps, and expect them to be reading material only.

---

## Part 12 — Dell firmware  *(Phase 2 — out-of-band, not from this box)*

Firmware is applied through iDRAC, not over SSH. Apply only a DUP that is
**newer than what is installed** — the Phase 1 inventory holds the baselines.

**IPMI-over-LAN is disabled on this chassis** (Serial-over-LAN is enabled), so
any scripted out-of-band work must use Redfish. `ipmitool -H` will not connect.

---

## Part 13 — Validate

```bash
apt install --dry-run <a package from the bundle>   # resolves from the local repo
docker image ls                                      # expected tags present
/opt/gns3/bin/gns3server --version                   # importable from the venv
./tests/run.sh                                       # the repo's own suite, green
```

Then the phase-level checks in buildout §13 for whatever was actually built.

**A phase does not advance on a red suite, and no phase is VERIFIED without
command output saved under `state/inventory/`.** An assertion is not evidence.

---

## Part 14 — Record the cycle

- [ ] Append the cycle row in `state/inventory/bundles.md` — date, versions,
      `verify` exit code, WARN dispositions, who carried the media, and
      whether it imported
- [ ] Update phase rows in `state/BUILD-STATE.md` with evidence paths
- [ ] Save command output under `state/inventory/`
- [ ] Keep the previous bundle until this one has validated end to end
- [ ] Commit

---

## If it goes wrong

| Symptom | First move |
|---|---|
| `verify` exits 1 | Do not import. Re-cut on staging; the media is suspect |
| `apt update` reaches upstream | A source survived Part 3.3. Restore 3.2, redo |
| `docker load` succeeds, tags missing | The tarball is incomplete. Re-cut; do not patch by hand |
| `pip` hangs | `--no-index` was omitted; it is reaching for PyPI |
| Root filesystem fills | A volume was not mounted before import. Stop, unwind, mount, redo |
| SSH lost during a network step | No out-of-band recovery path — the iDRAC gate was dropped 2026-09-24 (PRD.md §6); Phase 5 relies on `netplan try` and a saved rollback |

One change at a time: reproduce, observe, read logs, form one hypothesis, make
one controlled change, test, then keep or revert it.
