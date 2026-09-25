<!-- Generated: 2026-09-16 | Files scanned: 92 | Token estimate: ~500 -->
# Dependencies — everything that crosses the air gap

Only `scripts/r770-offline-fetch.sh` talks to the internet, and only on staging. Exact versions and
image references are owned there (see `OWNERS.md`); the review trail is `state/inventory/pin-review-*.md`
and `docs/plans/r770-dependency-manifest.md`.

| Stage | Pulls from | Lands in |
|---|---|---|
| 1 apt | archive.ubuntu.com via a build container (curated deb set, incl. the Malcolm installer's python deps and python3-venv for GNS3) | `apt/` |
| 2 iso | releases.ubuntu.com | `isos/` |
| 3 malcolm | github.com (release tarball), ghcr.io / docker hub image set | `malcolm/` |
| 4 monitoring + portal | docker hub, ghcr.io: prometheus, alertmanager, blackbox-exporter, grafana-oss, cadvisor, nginx, registry, mkdocs-material, plus alpine/debian/netshoot utility images | `docker/` + `docker/monitoring-image-list.txt` |
| 5 gns3 | pypi.org wheelhouse, cloud-images.ubuntu.com, cirros, alpine | `gns3/`, `images/` |
| 6 gns3 appliances | github.com GNS3 registry; mikrotik.com, opnsense.org | `gns3/appliances/` (licensed vendor images are manual) |
| 7 enrichment | iana.org, ieee.org OUI, publicsuffix.org, emergingthreats.net, wireshark.org manuf | `enrichment/` |
| 8 docs mirrors | app.readthedocs.org (Zeek htmlzip), docs.docker.com, malcolm.fyi (wget; WARN if absent) | `docs/` |
| 9 manual | licensed GNS3 appliances only; `dell/` holds a README (Dell firmware not a bundle item since 2026-09-25) | `gns3/appliances/`, `dell/` |

## Staging host requirements
Ubuntu VM with Docker CE (default) or RHEL 8 with rootful podman; ~150 GB free; curl gpg sha256sum unzip wget; pigz optional.
`scripts/r770-staging-preflight.sh` accepts any runtime that passes its capability probes (`info`, egress, `save`
writes docker-archive) — not by name; rootless podman and Docker CE on RHEL warn rather than refuse. It still
refuses `lxc`, an unreachable runtime, or a `save` that isn't docker-archive.

## Tooling this repo itself needs
bash, shellcheck, bats (tests) · git · Claude Code plugins: superpowers, ecc (not required by any script).

## Known traps (recorded in the fetch script header and runbooks)
- A GitHub release tag does not prove an image exists at that tag: verify the image reference, not the version.
- cadvisor moved registries; pins that resolve on one host may 404 on another.
- The `--pack` carry-file re-runs the entire fetch on extraction.
