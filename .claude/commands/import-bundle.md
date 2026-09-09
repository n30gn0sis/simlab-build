---
description: Verify and import a transferred bundle on the R770 (gated)
argument-hint: <path to bundle on the R770>
---

Import a bundle on the R770 over SSH, following supply plan §3 and the import order in the bundle's `BUNDLE_NOTES.md`. Bundle path: $ARGUMENTS

1. **Verify before anything else**: `./r770-bundle.sh verify .` inside the bundle on the R770 (the verifier travels in the bundle root). Exit **0** PASS · **2** PASS WITH WARNINGS (disposition each before the media moves) · **1** FAIL, do not import. Confirm site AV/content scan was done per policy (ask if unknown).
2. Confirm the previous bundle still exists on the box — it is the rollback. Never delete it during import.
3. Import in order, each step gated and verified:
   a. `apt/` → local repo directory; point APT sources at it (this edits `/etc/apt/sources.list.d/` — show current vs proposed and get confirmation); `apt update` must succeed against the local repo only.
   b. `docker load` the Malcolm, monitoring, and gns3-node tarballs; verify loaded tags against the bundle's image-list files.
   c. Wheelhouse, `.gns3a` definitions, appliance images, VM base images, enrichment data, docs mirrors into their target paths per the buildout plan.
4. Validate: `apt install --dry-run` of a bundle package, `docker image ls` shows expected tags, gns3-server importable from the venv (if that phase is built).
5. Log the cycle in `state/inventory/bundles.md` (date, versions, hashes, who carried the media) and update `state/BUILD-STATE.md`.
