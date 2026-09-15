# Staging deployment test — runtime-by-capability preflight and sectioned fetch (2026-09-15)

Plan: the `/plan deployment test on 9770 VM` approved in chat on 2026-09-15, amended by the
operator: "make sure the vm is cleaned up and in an init state for the test" and, to the bundle
question, "wipe the bundle too". Format per `.claude/agents/validation-runner.md`: each item is
PASS / WARN / FAIL with the command's actual output. Nothing here touched the R770.

Host: staging VM 9770 `r770-staging` (192.168.4.28), Ubuntu 24.04, Docker CE 29.8.0, 11 GiB RAM.
Scripts under test: repo `main` at the commit that ships `r770-offline-fetch.sh` v3.6 and the
capability-judged preflight (sha256 prefixes below matched on both sides after `scp`).

## 0. Cleanup to init state — PASS

Removed before the test, all confirmed gone afterwards:

| Item | Before | After |
|---|---|---|
| Docker images (from the 2026-09-12 rehearsal loads) | 38, 27.75 GB | 0 (`docker system prune -a --volumes`: "Total reclaimed space: 27.75GB") |
| Rehearsal packages `nginx nginx-common easy-rsa python3-venv python3.12-venv python3-ruamel.yaml python3-ruamel.yaml.clib python3-dotenv` | installed | purged, `dpkg -l` shows none; `/etc/nginx`, `/var/www/html` gone |
| `~/.local/share/GNS3` | 1.4 MB | removed |
| `~/r770/` (bundle-20260908 15 GB, stale scripts, docs copy, three 2026-09-08 fetch logs) | present | removed; `~/r770/scripts/` recreated empty |
| iptables air-gap rules, `.lab` hosts lines, cron, tmux, containers, volumes | none found | none |
| Free disk on `/` | 336 GB | 376 GB |

Kept, as staging tooling: docker, curl, gpg, sha256sum, unzip, wget, pigz, jq, rsync, `~/.gnupg`,
`~/.ssh`. RAM is still 12 GiB from the rehearsal (operator's Proxmox call to shrink).

## 1. Script sync — PASS

`scp` of the four staging scripts (never the `--pack` file, which runs the whole fetch on
extraction). sha256 prefixes identical local/remote:

```
6667ba671bfea537 r770-staging-preflight.sh
82befe2f06c42866 r770-offline-fetch.sh      (# v3.6)
ed56097343e8d31c r770-bundle.sh
a481bff297ef89f1 r770-build-bundle.sh
```

## 2. Preflight on Docker, egress and save-format probe live — PASS (exit 0, 62 s)

```
PASS  staging OS: Ubuntu 24.04 — the default path
PASS  virtualization: kvm — not lxc
PASS  container runtime: docker 29.8.0
PASS  docker daemon responds
PASS  375 GB free on /home/ubuntu/r770 (need 150)
PASS  required host tools present
PASS  r770-bundle.sh present and executable — it is copied into the bundle root
PASS  registry pull and in-container apt egress verified
PASS  docker save writes docker-archive (manifest.json present) — the R770's docker load can read it
READY — all checks passed
```

Override probes (`PREFLIGHT_SKIP_EGRESS=1`):

- `STAGING_CTR=docker` → `PASS  container runtime: docker 29.8.0 (STAGING_CTR override)`, exit 0. PASS
- `STAGING_CTR=nope` → `FAIL  STAGING_CTR=nope is not on PATH`, `NOT READY — 1 refusal(s)`, exit 1. PASS (refused by name)

## 3. Second runtime probe — PASS, then removed

To exercise the capability path once for real, `podman` 4.9.3 was installed from Ubuntu's repo
and probed rootless via `STAGING_CTR=podman`:

```
PASS  container runtime: podman 4.9.3 (STAGING_CTR override)
PASS  podman 4.9.3 supports --multi-image-archive
WARN  rootless podman — works, but image storage lands under $HOME and bundle files are owned by you; rerun with sudo for docker-identical ownership and /var/lib/containers
PASS  podman daemon responds
PASS  podman save writes docker-archive (manifest.json present) — the R770's docker load can read it
READY WITH WARNINGS — 1 warning(s); disposition each before fetch day     rc=2
```

`podman save --help` lists `--multi-image-archive` (1 match), which is what `ctr_save` keys on.
Podman was then purged with its config and storage; `command -v podman` → nothing. **The
operator's standing instruction is that this VM's runtime is Docker on Ubuntu, not podman**; the
probe was a one-off and the fetch below ran on Docker.

## 4. Sectioned fetch: full bundle cut, one section at a time

Empty bundle dir `~/r770/bundle-20260915`, `SEED_FROM=none` (nothing to seed from after the wipe).

`--list` on the empty dir: all eleven stages, `preflight  runs every time`, every other stage
`-`. `--only preflight,apt --dry-run`: `would run preflight`, `would run apt`, nothing else,
no network touched. PASS

Chain 1 started 2026-09-15T13:57:28Z under `nohup`, log `~/r770/fetch-sections.log`:

```
--only preflight,apt  →  --only iso,malcolm  →  --only monitoring,gns3
→  --only appliances,enrichment,docs  →  --only manual  →  --list
```

First three sections (`preflight,apt`; `iso,malcolm`; `monitoring,gns3`) all PASSED clean:
894 debs; Ubuntu 24.04.4 ISO fetched and SHA256-verified; Malcolm 26.08.0 images pulled;
monitoring/portal images pulled; GNS3 wheelhouse + VM base images (noble cloud image, CirrOS).

**Chain 1 FAILED, exit 23**, in section 4 (`appliances,enrichment,docs`), right after the 12
GNS3 `.gns3a` definitions downloaded. This is a real, deterministic defect, not the "transient"
one logged for `bundle-20260908` on 2026-09-08 at the identical point:

```
VYOS_TAG=$(curl -fsSL https://api.github.com/repos/vyos/vyos-nightly-build/releases/latest \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
```

`grep -m1` exits the instant it matches, closing its read end while curl may still be writing.
Under the script's `set -euo pipefail`, curl's resulting `EPIPE` (`curl: (23) Failure writing
output to destination`) kills the whole fetch at this un-guarded assignment — before the
`fetch()` call two lines later, whose `|| note "WARN: …"` was assumed (in the 2026-09-08 note)
to be the safety net. It never reached that far. The Alpine block two sections later has the
identical `curl | grep -m1` shape and has always carried `|| true`; VyOS never did.

**Fixed test-first** (repo commits, `main`, local): `resolve_latest_tag()` added to
`scripts/r770-offline-fetch.sh`, guarded the same way as Alpine, named so the guard can't be
silently dropped again. RED: two new tests in `tests/offline-fetch.bats` failed (function
missing). GREEN: 11/11 offline-fetch tests, shellcheck clean, full suite 117 green. Fixed
script re-synced to the VM (sha256 `de66af3a…` matched both sides).

Chain 2 resumed 2026-09-15T17:57:13Z from section 4, log `~/r770/fetch-sections2.log`:

```
--only appliances,enrichment,docs  →  --only manual  →  --only manifest  →  --list
```

The 12 definitions correctly skipped as already-present (`have()`/`seed()` resume semantics).
VyOS resolved to `2026.09.15-0029-rolling` and its ISO (611 MB) + minisig fetched — **past the
point that killed chain 1**. Two further network events, both survived correctly by the
script's *existing*, already-correct guards (not part of this fix):

- MikroTik CHR: a mid-download connection reset, then (after `curl --retry 3` exhausted) a
  guarded failure → `WARN: CHR 7.21.5 download failed`. Chain continued.
- Docs mirrors for `malcolm` and `zeek`: incomplete (best-effort, `wget --mirror` under a
  900s cap) → the same two accepted WARNs `bundle-20260908` already carries.

Sections `appliances,enrichment,docs`, `manual`, `manifest` all completed. **Chain 2 exit 0.**

## 5. Manifest and gate — PASS WITH WARNINGS (exit 2), same disposition as bundle-20260908

```
$ ./scripts/r770-bundle.sh verify bundle-20260915
ok    MANIFEST.sha256 parses — 1594 entries
ok    every manifested file is present and unmodified
ok    no unmanifested files — manual additions are covered
ok    no incomplete downloads
ok    malcolm/image-list.txt has its payload
ok    docker/monitoring-image-list.txt has its payload
ok    gns3/docker-nodes/image-list.txt has its payload
WARN  3 WARN line(s) in BUNDLE_NOTES.md — disposition each before the media leaves staging
WARN  dell/ holds only README.txt — manual downloads not staged (see that README)
ok    gns3/appliances/ has 7 staged file(s)
RESULT: PASS WITH WARNINGS — 2 warning(s) to disposition.   rc=2
```

`--strict` correctly turns the same two WARNs into a FAIL (rc=1), as designed — this bundle is
not meant to leave staging yet.

**WARN dispositions:**

| WARN | Disposition |
|---|---|
| CHR 7.21.5 download failed | **Accepted, retryable.** Network blip, not a script defect (confirmed above); a rerun of `--only appliances` alone would retry just this file since MikroTik's `.img.zip` never landed. Not done as part of this test — this bundle is for deployment-testing the scripts, not for transfer. |
| docs mirror malcolm / zeek incomplete | **Accepted**, same reasoning as `bundle-20260908` — best-effort by design. |
| `dell/` holds only README | **Expected** — manual category, unchanged from `bundle-20260908`. |

Component sizes: 14 G total — `malcolm/` 6.8G · `isos/` 3.2G · `apt/` 1.5G · `gns3/` 1.5G ·
`images/` 617M · `docker/` 510M · `docs/` 53M · `enrichment/` 13M · `dell/` 8K (README only).

## Findings

1. **Real defect found and fixed**: the VyOS `curl|grep -m1` pipe-close crash, previously
   misdiagnosed as transient. See commits on `main` (test-first, RED then GREEN).
2. **Everything else in the runtime-by-capability preflight and sectioned-fetch work from
   2026-09-14 held up under a real, full bundle cut**: `--list`, `--dry-run`, `--only`, `--skip`,
   resumability across two separate chains, `BUNDLE_NOTES.md` section-rerun headers (visible at
   lines 7/14/22/27/43/48 of the notes file, one per `--only` invocation across both chains),
   and the final `--only manifest` producing a bundle that verifies identically to the
   hand-built `bundle-20260908`.
3. **Not exercised in this test**: `STAGING_CTR` pointed at a real non-Docker runtime for a
   full cut (only probed via the preflight in isolation, §3 above) — the actual fetch ran on
   Docker throughout, per the operator's standing instruction that this VM's runtime is Docker.
4. **`bundle-20260915` is a test artifact**, not a transfer candidate — cut to validate the
   scripts, not to replace `bundle-20260908` in the phase tracker. Left on the VM; not imported
   anywhere.
