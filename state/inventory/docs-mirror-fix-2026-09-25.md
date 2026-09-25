# Docs-mirror fix — root cause and live verification (2026-09-25)

**Symptom:** `WARN: docs mirror for malcolm|zeek incomplete/failed` on every cut (`bundle-20260908`, `bundle-20260915`, `bundle-20260925`), so `verify --strict` refused every cut.

## Root cause (reproduced from the session with the exact wget command, logged, exit codes captured)

| Mirror | wget exit | What actually happened |
|---|---|---|
| malcolm | **8** | Mirror **complete** (250 files, 26 MB, 24 s). Exit 8 = some URL returned an HTTP error. Every 404 is a defect **on malcolm.fyi itself** (malformed links like `docs/(https://github.com/idaholab/Malcolm)`, missing `images/hedgehog/…` and `images/screenshots/…` PNGs, `docs/version`). No rerun can fix them. |
| zeek | **8** | **Nothing** fetched. `docs.zeek.org` answers the first request with `HTTP/2 429`, `server: cloudflare`, `cf-mitigated: challenge` — the same for the Wget, curl and browser-like User-Agents. A Cloudflare JS challenge no non-browser client can pass. |

The script ran `wget -q … && note mirrored || note "WARN …incomplete/failed"`, so any non-zero exit was reported identically and `-q` hid the reason.

## Fix (`scripts/r770-offline-fetch.sh`, commit `3536f6b`)

- `docs_mirror()` classifies the exit code:
  - `0` → mirrored.
  - `8` **with pages on disk** → mirrored, with a note of the upstream 4xx count; not warned, and stamped complete.
  - `8` with nothing on disk, `4` (network) and `124` (900 s timeout) → a specific WARN each.
  - The exit code is captured as `&& rc=0 || rc=$?` so the script's `set -euo pipefail` doesn't abort the run.
- Zeek: fetch Read the Docs' offline **htmlzip** from `app.readthedocs.org/projects/zeek-docs/downloads/htmlzip/current/` (no challenge; HTTP 200 to plain clients) via the resumable `fetch()`. Egress allowlist updated: `docs.zeek.org` → `app.readthedocs.org`.
- 7 new bats tests (each exit-code branch, the stamped skip, and the source check). Suite 206/206.

## Live verification on staging VM 9770 (driven from the session)

`rollback clean-2026-09-24` → `start` → clone `claude/docs-mirror-fix` @ `3536f6b` → `BUNDLE_DIR=~/docs-verify/bundle-docs ./scripts/r770-offline-fetch.sh --only docs`:

```
==== [8/10] Docs mirrors ====
>> docs: malcolm mirrored — 10 upstream link(s) returned HTTP 4xx (defects on the source site; not retryable)
>> docs: zeek offline htmlzip (Read the Docs build) fetched
>> docs: wireshark mirrored
>> docs: gns3-server v3.0.6 source tarball (includes docs/) fetched
fetch exit=0
```

On disk: malcolm 26M · zeek-docs-htmlzip-current.zip 11M (112 files, `zeek-docs-current/index.html`) · wireshark 12M · gns3-server-docs.tar.gz 15M. **No WARN lines in `BUNDLE_NOTES.md`.** VM stopped afterwards.

**Side finding:** after the rollback, DHCP gave the VM **192.168.4.78** (it was .72 the previous day). The address isn't stable across rollbacks. A DHCP reservation for `BC:24:11:97:70:01` is needed before `r770-staging-vm.sh`'s default host can be relied on.
