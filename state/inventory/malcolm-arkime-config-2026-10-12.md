# Arkime `trackESP=true` via `r770-malcolm-deploy.sh arkime-config` — staging VM 9771, 2026-10-12

Follow-up to `staging-ipsec-rehearsal-2026-10-09.md` ("Arkime drops ESP unless
`trackESP=true`"): the deploy script now owns the setting. This file is the
evidence that the verb works against a real Malcolm 26.08 tree and that a
recreated container renders it.

## Mechanism (read from the running `malcolm-arkime-1`, image `ghcr.io/idaholab/malcolm/arkime:26.08.0`)

`/usr/local/bin/docker_entrypoint.sh`:

```
# if config.ini does not exist but config.orig.ini does, use it as a basis and modify based on env. vars
if [[ ! -f "${ARKIME_CONFIG_FILE}" ]] && [[ -r "${ARKIME_DIR}"/etc/config.orig.ini ]]; then
    cp "${ARKIME_DIR}"/etc/config.orig.ini "${ARKIME_CONFIG_FILE}"
    sed -i ... (elasticsearch, passwordSecret, freeSpaceG, rotateIndex, ... — no trackESP)
```

`config.ini` is therefore written once per container into its writable layer;
nothing in the env list renders `trackESP`. `docker-compose.yml` (26.08 render)
mounts no `config.ini`/`config.orig.ini` (`arkime/etc/` holds `wise.ini` only),
and Malcolm's `/opt/malcolm/malcolm/scripts/control.py` runs compose with an explicit `-f args.composeFile`
(lines 429–430, 650–651, 811, 891), so a `docker-compose.override.yml` would be
ignored. Hence: a host copy of the image's `config.orig.ini` with the setting,
bind-mounted read-only over the image's at the path the entrypoint copies from.

## Run

```
$ sudo bash /tmp/r770-malcolm-deploy.sh arkime-config
config.orig.ini taken from ghcr.io/idaholab/malcolm/arkime:26.08.0
backup: /opt/malcolm/malcolm/docker-compose.yml.bak-20261012T153907
mounted ./arkime/etc/config.orig.ini over /opt/arkime/etc/config.orig.ini in: arkime arkime-live (rollback: cp -p /opt/malcolm/malcolm/docker-compose.yml.bak-20261012T153907 /opt/malcolm/malcolm/docker-compose.yml)
PASS    Arkime trackESP=true via /opt/malcolm/malcolm/arkime/etc/config.orig.ini
NOTE    Malcolm has containers: config.ini is rendered when a container is created — stop and start Malcolm for trackESP to take effect, then check with: health
rc=0
```

(The first run also printed four `awk: warning: escape sequence` lines from a
regex passed through `-v`; the matching was changed to whole-line comparison
and the second run, below, was clean.)

```
$ ls -la /opt/malcolm/malcolm/arkime/etc/
-rw-r--r-- 1 ubuntu ubuntu 857688 Oct 12 15:39 config.orig.ini
-rw-r--r-- 1 ubuntu ubuntu    748 Oct  9 06:45 wise.ini
$ grep -n '^trackESP' /opt/malcolm/malcolm/arkime/etc/config.orig.ini
10:trackESP=true
$ cat /opt/malcolm/.r770-deploy/arkime-config.image
ghcr.io/idaholab/malcolm/arkime:26.08.0
$ grep -n -B1 -A6 config.orig.ini /opt/malcolm/malcolm/docker-compose.yml
373:      source: ./arkime/etc/config.orig.ini      (arkime, first entry under volumes:)
374:      target: /opt/arkime/etc/config.orig.ini
375-      read_only: true
453:      source: ./arkime/etc/config.orig.ini      (arkime-live)
454:      target: /opt/arkime/etc/config.orig.ini
455-      read_only: true

$ sudo bash /tmp/r770-malcolm-deploy.sh arkime-config      # second run
already configured: trackESP=true in /opt/malcolm/malcolm/arkime/etc/config.orig.ini (from ghcr.io/idaholab/malcolm/arkime:26.08.0), mounted in every arkime service
rc=0
```

## Restart and proof

Malcolm's own `restart --quiet` as the PUID user (runbook 8.1), rc 0. Then:

```
$ sudo bash /tmp/r770-malcolm-deploy.sh health --timeout 600
PASS    all 27 services running and healthy
PASS    127.0.0.1:8443 is listening
info    443 wildcard held by a non-docker process: ... nginx ...   (the portal, as designed)
PASS    no docker-proxy on 0.0.0.0:443 or [::]:443, none off loopback
PASS    arkime config.ini has trackESP=true
health rc=0

$ docker inspect malcolm-arkime-1 --format '{{.Created}}'
2026-10-12T15:40:28.245907632Z
$ docker exec malcolm-arkime-1 sh -c 'grep -n -x trackESP=true /opt/arkime/etc/config.ini; grep -c ^trackESP= /opt/arkime/etc/config.ini; ls -la --time-style=+%FT%T /opt/arkime/etc/config.ini'
10:trackESP=true
1
-rw------- 1 arkime arkime 857934 2026-10-12T15:40:31 /opt/arkime/etc/config.ini
$ docker inspect malcolm-arkime-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ro={{not .RW}}{{println}}{{end}}' | grep orig
/opt/malcolm/malcolm/arkime/etc/config.orig.ini -> /opt/arkime/etc/config.orig.ini ro=true
```

The container was created at 15:40:28 and its `config.ini` written at 15:40:31
from the mounted file: `trackESP=true` at line 10, exactly one `trackESP=` line,
with the entrypoint's own rendering still applied (file size 857 934 vs the
857 688-byte source — the env substitutions). ESP indexing with this setting was
already shown on 2026-10-09 (X9/H4: `(17, 500)` ISAKMP and `(50)` ESP sessions).

## Not done

- No ESP upload was repeated after the restart; the setting's effect was proven
  on 2026-10-09 with the same `config.ini` line set by hand.
- VM 9771 residue: `docker-compose.yml.bak-20261012T153907` kept beside the
  compose file (the rollback). Malcolm left running.
