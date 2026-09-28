# Baseline re-proof — VM 9771, 2026-09-28

Task 7 of `work/plans/active/2026-09-27-gns3-mirror.md`: re-prove the already-proven analyst
stack (Malcolm + CA + portal + UFW, sub-project 2) still deploys and runs clean from a fresh
bundle cut off current `main` (post PR #15/#16), under a genuinely enforced air gap, as the
baseline the GNS3/mirror work (Tasks 1–6, already merged into this branch) builds on.

## Bundle

- Cut from branch `claude/gns3-malcolm-mirror` (started at commit `2a01d11`, later amended in
  place to include the `r770-airgap-sim.sh` fix below — final commit `1462298`).
- `bundle-20260928` on VM 9771: 15 GB, 1641 files. Seeded from `bundle-20260926` (the GNS3
  server's own upstream docs tarball reused, manifest-verified) — only `site/` (this repo's
  `scripts/`, `config/`, and `docs/analyst-wiki/`), `apt/`, and `enrichment/` fetched fresh, per
  the fetch script's own seeding design. `site/` carries 42 files, confirmed from commit `1462298` (includes
  `r770-gns3-deploy.sh`, `r770-gns3-scenario-reference.sh`, the fixed `r770-airgap-sim.sh`).
- `./r770-bundle.sh verify . --strict` → **PASS** (exit 0), on both the build location
  (`~/simlab-build/bundle-20260928`) and the deployed copy (`/data/staging/bundle-20260928`),
  re-verified after regenerating the manifest for the `r770-airgap-sim.sh` fix.

## Found and fixed: `r770-airgap-sim.sh` did not actually block egress with UFW active

Not part of this plan's Tasks 1–8 — an independent, previously-undetected bug hit live while
arming the air gap for this proof run.

**Symptom:** `r770-airgap-sim.sh block` reported `BLOCKED`, but `curl` to a real internet host
(`archive.ubuntu.com`, resolved to `91.189.92.24`) succeeded with HTTP 200, and the DROP rule's
`iptables -L -v` packet/byte counters read 0 even after that request.

**Root cause:** `cmd_block` appended the catch-all DROP with `-A OUTPUT` (end of chain). UFW —
active on this VM since sub-project 2 (2026-09-26) — installs its own `OUTPUT` chain-jump rules
ahead of anything appended there; its `ufw-track-output` chain unconditionally `ACCEPT`s every
`NEW` outbound tcp/udp connection. iptables traversal stops at that `ACCEPT` and never reaches a
rule appended after it. The script predates UFW being active on this VM and was never
re-verified against it.

**Fix:** insert the DROP at the fixed position `-I OUTPUT 5` (immediately after the script's own
four `ACCEPT` inserts at positions 1–4) instead of appending — deterministically correct
regardless of what else, UFW included, was already in `OUTPUT` before the script runs. TDD:
wrote a failing regression test first (`tests/airgap-sim.bats`, confirmed RED against the old
`-A OUTPUT` code), fixed, confirmed GREEN. `18/18` `airgap-sim.bats`, `548/548` full suite,
shellcheck clean. Commit `1462298`.

**Verified live after the fix**, before proceeding with anything else in this proof run:

```
$ sudo bash r770-airgap-sim.sh unblock && sudo bash r770-airgap-sim.sh block --minutes 120
egress restored
auto-revert scheduled in 120 minute(s)

$ sudo bash r770-airgap-sim.sh status
BLOCKED (7200s until auto-revert)

$ curl -sS -m 5 -o /dev/null -w "http_code=%{http_code}\n" https://archive.ubuntu.com
curl: (28) Connection timed out after 5002 milliseconds
http_code=000

$ sudo iptables -L OUTPUT -n -v --line-numbers | sed -n '1,7p'
Chain OUTPUT (policy ACCEPT 4 packets, 160 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1        4   696 ACCEPT     0    --  *      lo      0.0.0.0/0            0.0.0.0/0
2        0     0 ACCEPT     0    --  *      *       0.0.0.0/0            127.0.0.0/8
3        8   894 ACCEPT     0    --  *      *       0.0.0.0/0            192.168.4.0/22
4        0     0 ACCEPT     0    --  *      *       0.0.0.0/0            172.16.0.0/12
5        8   480 DROP       0    --  *      *       0.0.0.0/0            0.0.0.0/0            /* r770-airgap-sim */
```

Egress genuinely fails (real timeout, not a fast reject) and the DROP rule shows real packet/
byte counts. The re-cut bundle (with the fix in `site/`) was re-verified `--strict` PASS and
re-synced to `/data/staging/bundle-20260928` before proceeding.

**Implication for prior rehearsals:** every earlier `r770-airgap-sim.sh` rehearsal on this repo
predates UFW being active on the staging VM (UFW landed with sub-project 2, 2026-09-26), so
this bug could not have affected them — those "offline" proofs stand. This proof run is the
first one where the bug could have produced a false pass, and it was caught before any
conclusion was drawn from it.

## Redeploy/health sequence (under the now-genuinely-enforced air gap)

All run from `/data/staging/bundle-20260928/site/scripts/` (the real deployment path, not the
git checkout), starting from VM 9771 snapshot `analyst-stack-3b05070` (Malcolm/CA/portal/UFW
already installed, containers stopped from the VM restart).

| Step | Result |
|---|---|
| `r770-lab-ca.sh apply` | CA and cert already present — kept; certs already installed — skipped |
| `r770-lab-ca.sh verify` | **PASS**, 10/10 checks (chain, all 5 SANs, expiry, key mode, pubkey match, installed CA matches) |
| `r770-malcolm-deploy.sh install` | already installed (sha256-matched) |
| `r770-malcolm-deploy.sh configure` | already configured from this config (sha256-matched) |
| `r770-malcolm-deploy.sh bind-loopback` | already bound: nginx-proxy publishes 127.0.0.1:8443 only |
| `r770-malcolm-deploy.sh start` | **PASS** — start script returned 0 |
| `r770-malcolm-deploy.sh health --timeout 600` | **PASS** — all 27 services running and healthy; 127.0.0.1:8443 listening; no docker-proxy on the :443 wildcard |
| `r770-malcolm-deploy.sh verify --password-file ...` | **PASS** — loopback capture (28804 bytes) uploaded and indexed: Arkime 4 sessions on port 8443, Zeek new logs written, zeek container healthy. Password file transferred via `scp` + `install -m 600`, deleted from the VM immediately after (`sudo test -f /root/analyst-pw` confirmed absent) |
| `r770-portal.sh apply` | idempotent (nginx configs/htpasswd already installed); docs rebuilt (0.24s); `nginx -t` PASS; no reload needed |
| `r770-portal.sh verify` | **PASS** on all reachability checks: portal.lab/malcolm.lab/docs.lab each return 401 without credentials; only nginx listens on :443. (200-with-credentials check skipped — no credential file supplied this call; Malcolm's own `verify` above already round-tripped the same analyst login) |
| `r770-ufw.sh verify` | **PASS** — active, default-deny incoming, exactly the 22/443 rules from the management subnet, no extra allow rules, no pending auto-revert, no docker-proxy/unidentified listeners, every Docker DNAT rule loopback-restricted. 5 expected WARNs (dnsmasq :53, nginx :80, node-exporter :9100 — all UFW-filtered, consistent with prior rehearsals) |

## Disposition

Baseline re-proof: **PASS**. The already-proven analyst stack deploys and runs clean from the
current branch's freshly cut bundle, under a real (now bug-fixed) air gap. Snapshot taken
(`baseline-2026-09-28`) before proceeding to Task 8's GNS3/virtual-mirror integration proof.
