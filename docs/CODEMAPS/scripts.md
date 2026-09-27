<!-- Generated: 2026-09-26 | Files scanned: 92 | Token estimate: ~900 -->
# Scripts — entry points and call graph

All bash, all under `scripts/`. No script imports another; they invoke each other by path.

```
r770-build-bundle.sh ──▶ r770-staging-preflight.sh
        │            ──▶ r770-offline-fetch.sh ──▶ r770-bundle.sh manifest (stage 11/11)
        │            ──▶ r770-bundle.sh manifest ; verify --strict
        └── --pack  ──▶ self-extracting file that re-runs the WHOLE chain (never use it just to extract)
r770-staging-vm.sh      standalone (Proxmox API, from the session's LXC; staging VM power/snapshots)
r770-airgap-sim.sh      standalone (staging VM rehearsal)
r770-precheck.sh        standalone (R770, read-only)
r770-phase3-run.sh ──▶ r770-storage-apply.sh   (R770, Phase 3 storage)
R770 or rehearsal VM, offline, run from the bundle's site/scripts/ -- no script calls another;
the order is the runbook's (Parts 8, 10.0-10.2), each refusing until its predecessor's output exists:
r770-malcolm-deploy.sh  load → install → configure → auth → bind-loopback → start → health → verify
r770-lab-ca.sh          plan → apply → verify; export-ca        (/etc/nginx/ssl/{lab.crt,lab.key,ca.crt})
r770-portal.sh          plan → apply → verify   needs lab-ca's three files + malcolm-deploy auth's htpasswd
r770-ufw.sh             plan → apply → confirm → verify; revert  (GATED; 22 + 443 on the mgmt interface only)
```

## r770-offline-fetch.sh (1063 lines) — staging only
`[--only s,s] [--skip s,s] [--list] [--dry-run]`; stages are `stage_<name>()` functions run by a driver in fixed order,
`--list`/`--dry-run` answer before any runtime is needed, `--only` never implies manifest, sectioned runs append to notes.
Runtime: `STAGING_CTR`, else docker, podman, nerdctl; `ctr_save` adds `--multi-image-archive` when `save --help` offers it.
Stages, resumable via stamp files: 0 preflight egress · 1 apt · 2 ubuntu iso · 3 malcolm ·
4 monitoring+portal images · 5 gns3 server+wheelhouse+base images · 6 gns3 appliances ·
7 enrichment · 8 docs mirrors · 9 manual reminders · 10 site · 11 manifest.
Helpers: `note ctr_save have stamped stamp_done fetch seed seed_glob resolve_latest_tag`.
`resolve_latest_tag <api-url>` — named guard around `curl | grep -m1 '"tag_name"' | sed ...` (used for the VyOS
rolling release lookup): absorbs the EPIPE `grep -m1` causes by closing its read end before `curl` finishes writing,
which under `set -euo pipefail` would otherwise kill the whole fetch intermittently (bit this script twice, 2026-09-08
and 2026-09-15, before being fixed and named so it can't be silently re-added unguarded).
Bundle layout: `apt/ docker/ malcolm/ gns3/ isos/ images/ enrichment/ keys/ docs/ dell/ site/` + MANIFEST.sha256 +
BUNDLE_NOTES.md. `dell/` holds only a README (Dell firmware is not a bundle item). `site/` (stage 10) is this repo's
committed `scripts/ config/ docs/analyst-wiki/` — from a git work tree (`SITE_SRC_ROOT`, canonicalised) or from
`SITE_ARCHIVE`+`SITE_COMMIT` — with secret-looking files excluded and symlinks/submodules refused.
Owns every version pin and image reference (OWNERS.md).

## r770-bundle.sh (323 lines) — ships inside the bundle
`manifest <dir>` → `cmd_manifest` (sha256 of every file; excludes itself, the manifest and `.stamps/`).
`verify [--strict] <dir>` → `cmd_verify` runs, in order:
`check_manifest_sane check_hashes check_coverage check_parts check_required check_notes check_manual check_site`
→ `summary` (`check_site` WARNs on a missing `site/` or a missing deploy script, never FAILs). Exit 0 pass · 2 pass-with-warnings · non-zero fail; `--strict` turns WARN into FAIL.
Support: `bundle_files part_files manifest_paths first_match fail warn pass die cleanup usage`.

## r770-build-bundle.sh (232 lines)
`step` 1/5 preflight → 2/5 fetch → 3/5 manual-items pause (non-interactive or no TTY: stops unless `--yes`) →
4/5 manifest regen → 5/5 strict gate. Flags: `--bundle-dir --non-interactive --pack --only --skip` (the last two pass through to the fetch; the gate still runs). `cmd_pack` builds the carry-file.

## r770-staging-preflight.sh (219 lines)
`pass/warn/fail` checks: distro (informational) · not lxc · runtime found (`STAGING_CTR`, docker, podman, nerdctl),
engine answers `info`, podman 3.0+ (refusal) and rootful (warning), Docker CE on RHEL (warning) · SELinux label mode ·
free space on the bundle dir · host tools (pigz optional) · verifier present and executable · registry pull +
in-container apt egress · **save-format probe**: `save` output must contain `manifest.json` (docker-archive).

## r770-airgap-sim.sh (185 lines)
`block [--minutes N] | unblock | status`. `cmd_block` → `apply` iptables rules: allow lo, loopback net,
LAN (`AIRGAP_LAN`), docker bridge range; DROP the rest in OUTPUT and in DOCKER-USER
(`ensure_docker_chain`). Optional auto-revert sleeper: PID in `$AIRGAP_RUN_DIR`, `cancel_sleeper` on unblock.
`cmd_status` uses `rule_present` (only iptables exit 0/1 count as answers; anything else dies).

## r770-malcolm-deploy.sh (902 lines) — offline, root
`load <bundle>` → `cmd_load` docker-loads the malcolm archives then `cmd_assert_tags`;
`assert-tags <bundle>` alone re-checks (`image_list` reads `<bundle>/malcolm/image-list.txt`).
`install <bundle>` unzips the one `malcolm-*-docker_install.zip` (stamped; never over an existing tree) ·
`configure <json>` Malcolm's `install.py --non-interactive --configure` importing the JSON (top-level installer once,
then the tree's own), keeps a copy of the JSON beside its sha256 stamp ·
`auth <bundle> --password-file F [--user N] [--force]` Malcolm's `auth_setup`, fed hashes only ·
`bind-loopback` nginx-proxy `0.0.0.0:443` → `127.0.0.1:8443` · `start` Malcolm's start script (refused before bind) ·
`health [--timeout S]` every service healthy, only `127.0.0.1:8443` published ·
`verify --password-file F [--user N]` loopback PCAP → upload dir → Arkime sessions + Zeek logs.
`auth`/`start` run Malcolm's tools as the PUID user (`runuser`) after `own_for_malcolm` chowns the tree and the
allowlisted, canonical, mounted data-dir bind sources (`bind_sources config_storage_dirs check_data_dir check_mounted`).

## r770-lab-ca.sh (307 lines) — R770, root
`plan` (default, read-only) · `apply [--reissue-cert]` easy-rsa CA created only if absent (a partial PKI refuses),
five-SAN `lab` cert issued if absent (reissue = revoke then rebuild), installed to `/etc/nginx/ssl/` · `verify` chain,
SANs, expiry, key mode · `export-ca` prints the CA certificate.

## r770-portal.sh (503 lines) — R770, root
`plan` (default, read-only) · `apply` preflight (lab-ca files, Malcolm htpasswd — not a symlink, sources, mkdocs
image) → portal page + docs build (`docker run --network none`) → nginx backup → `conf.d/`, `snippets/`,
`00-default-reject.conf` and the portal/malcolm/docs vhosts → `nginx -t` (restore on failure) → reload only on change
· `verify [--host] [--cacert] [--user --password-file]` 401/200 per name, only nginx on `:443`.

## r770-ufw.sh (651 lines) — R770, root, GATED
Discovery from `SSH_CONNECTION` (interface, subnet, SSH port). `plan` read-only · `apply [--minutes N]` backup →
allow rules → auto-revert sleeper → default deny → enable · `confirm` from a new session cancels the sleeper ·
`verify` rules, default policy, listeners (docker-proxy/DNAT/unidentified FAIL, other host listeners WARN) ·
`revert` restores the backup.

## r770-precheck.sh (318 lines) — R770, read-only
`section run runp` wrappers over lscpu/lspci/lsblk/nvme/ip/ethtool/dmidecode/ipmitool etc.;
`priv ok warn fail have`. Output is pasted into `state/inventory/` and parsed by discovery-analyst.

## Supporting
`.claude/hooks/session-start.sh` (48) shellcheck bootstrap for remote sessions ·
`tests/run.sh` (13) `bats tests/*.bats` (shellcheck runs inside `lint.bats`) · `tests/helpers/fixtures.bash` (66)
`make_bundle stage_manual` synthetic byte-sized bundles.
