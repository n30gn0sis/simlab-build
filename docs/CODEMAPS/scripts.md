<!-- Generated: 2026-09-16 | Files scanned: 92 | Token estimate: ~900 -->
# Scripts — entry points and call graph

All bash, all under `scripts/`. No script imports another; they invoke each other by path.

```
r770-build-bundle.sh ──▶ r770-staging-preflight.sh
        │            ──▶ r770-offline-fetch.sh ──▶ r770-bundle.sh manifest (stage 10/10)
        │            ──▶ r770-bundle.sh manifest ; verify --strict
        └── --pack  ──▶ self-extracting file that re-runs the WHOLE chain (never use it just to extract)
r770-airgap-sim.sh      standalone (staging VM rehearsal)
r770-malcolm-deploy.sh  standalone (R770 or rehearsal VM, offline)
r770-precheck.sh        standalone (R770, read-only)
```

## r770-offline-fetch.sh (804 lines) — staging only
`[--only s,s] [--skip s,s] [--list] [--dry-run]`; stages are `stage_<name>()` functions run by a driver in fixed order,
`--list`/`--dry-run` answer before any runtime is needed, `--only` never implies manifest, sectioned runs append to notes.
Runtime: `STAGING_CTR`, else docker, podman, nerdctl; `ctr_save` adds `--multi-image-archive` when `save --help` offers it.
Stages, resumable via stamp files: 0 preflight egress · 1 apt · 2 ubuntu iso · 3 malcolm ·
4 monitoring+portal images · 5 gns3 server+wheelhouse+base images · 6 gns3 appliances ·
7 enrichment · 8 docs mirrors · 9 manual reminders · 10 manifest.
Helpers: `note ctr_save have stamped stamp_done fetch seed seed_glob resolve_latest_tag`.
`resolve_latest_tag <api-url>` — named guard around `curl | grep -m1 '"tag_name"' | sed ...` (used for the VyOS
rolling release lookup): absorbs the EPIPE `grep -m1` causes by closing its read end before `curl` finishes writing,
which under `set -euo pipefail` would otherwise kill the whole fetch intermittently (bit this script twice, 2026-09-08
and 2026-09-15, before being fixed and named so it can't be silently re-added unguarded).
Bundle layout: `apt/ docker/ malcolm/ gns3/ isos/ images/ enrichment/ docs/ dell/` + MANIFEST.sha256 + BUNDLE_NOTES.md.
Owns every version pin and image reference (OWNERS.md).

## r770-bundle.sh (286 lines) — ships inside the bundle
`manifest <dir>` → `cmd_manifest` (sha256 of every file; excludes itself, the manifest and `.stamps/`).
`verify [--strict] <dir>` → `cmd_verify` runs, in order:
`check_manifest_sane check_hashes check_coverage check_parts check_required check_notes check_manual`
→ `summary`. Exit 0 pass · 2 pass-with-warnings · non-zero fail; `--strict` turns WARN into FAIL.
Support: `bundle_files part_files manifest_paths first_match fail warn pass die cleanup usage`.

## r770-build-bundle.sh (196 lines)
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

## r770-malcolm-deploy.sh (71 lines) — offline
`load <bundle>` → `cmd_load` docker-loads the malcolm archives then `cmd_assert_tags`;
`assert-tags <bundle>` alone re-checks. `image_list` reads `<bundle>/malcolm/image-list.txt`, the tag list the fetch wrote.

## r770-precheck.sh (318 lines) — R770, read-only
`section run runp` wrappers over lscpu/lspci/lsblk/nvme/ip/ethtool/dmidecode/ipmitool etc.;
`priv ok warn fail have`. Output is pasted into `state/inventory/` and parsed by discovery-analyst.

## Supporting
`.claude/hooks/session-start.sh` (48) shellcheck bootstrap for remote sessions ·
`tests/run.sh` (13) shellcheck + `bats tests/*.bats` · `tests/helpers/fixtures.bash` (43)
`make_bundle stage_manual` synthetic byte-sized bundles.
