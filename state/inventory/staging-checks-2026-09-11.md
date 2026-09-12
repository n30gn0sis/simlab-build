# Staging VM 9770 — checks run 2026-09-11

Run over SSH from LXC 101 as `ubuntu@192.168.4.28`, using the scripts at repo `e28282d`
(shipped via `r770-build-bundle.sh --pack`, extracted to `/tmp/tmp.acRGjba7Gc/` on the VM).
The VM's own `~/r770/scripts/` is older (no preflight, no build orchestrator) — still true after this.

## `r770-staging-preflight.sh` — exit 0, READY

```
PASS  staging OS: Ubuntu 24.04 — the default path
PASS  virtualization: kvm — not lxc
PASS  container runtime: docker 29.8.0
PASS  docker daemon responds
PASS  334 GB free on /home/ubuntu/r770 (need 150)
PASS  required host tools present
PASS  r770-bundle.sh present and executable — it is copied into the bundle root
PASS  registry pull and in-container apt egress verified

READY — all checks passed
```

## `r770-bundle.sh verify bundle-20260908` — exit 2, PASS WITH WARNINGS

```
ok    MANIFEST.sha256 parses — 1617 entries
ok    every manifested file is present and unmodified
ok    no unmanifested files — manual additions are covered
ok    no incomplete downloads
ok    malcolm/image-list.txt has its payload
ok    docker/monitoring-image-list.txt has its payload
ok    gns3/docker-nodes/image-list.txt has its payload
      22:- WARN: docs mirror for malcolm incomplete/failed (best-effort; rerun resumes it)
      23:- WARN: docs mirror for zeek incomplete/failed (best-effort; rerun resumes it)
WARN  2 WARN line(s) in BUNDLE_NOTES.md — disposition each before the media leaves staging
WARN  dell/ holds only README.txt — manual downloads not staged (see that README)
ok    gns3/appliances/ has 8 staged file(s)

RESULT: PASS WITH WARNINGS — 2 warning(s) to disposition.
```

`--strict` → exit 1, `FAIL (--strict) — 2 warning(s) left undispositioned.` Same two WARNs:
the docs-mirror pair (already dispositioned ACCEPTED in `bundles.md`, but the disposition lives
in the repo, not in `BUNDLE_NOTES.md`, so strict still counts them) and `dell/` empty.

Unchanged from 2026-09-08. Bundle is intact; still blocked on the same two manual items.

## Incident — unintended fetch start, stopped after ~2 min

Running the packed builder to *extract* the scripts also `exec`s the orchestrator (line 90 of
`r770-build-bundle.sh`), which passed preflight and started a fetch. Killed at ~2 min; the
`ubuntu:24.04` build container was stopped. It had written ~1 GB into
`~/r770/scripts-20260911/bundle-20260911/` (root-owned `apt/partial` inside). Left in place —
operator's call whether to delete or let a future run resume it. `bundle-20260908` untouched;
`/` 52 G used, 335 G free. Lesson: the packed file is a *builder*, not an installer — there is no
extract-only mode. If one is wanted it's a small change to the pack header.
