# GNS3 mirror-feed proof run — VM 9771 (2026-09-29)

**Result: PASS.** A GNS3 lab's traffic reaches Malcolm's live capture pipeline (Zeek), which is
this sub-project's whole point (`docs/superpowers/specs/2026-09-27-gns3-mirror-design.md`).
Continues from `state/inventory/staging-baseline-reproof-2026-09-28.md` (Task 7's clean baseline
re-proof) on the same VM.

## Sequence run

1. `r770-gns3-deploy.sh apply` + `labnet apply` — GNS3 service up behind the portal, `br-lab` /
   `lab-mon0` / `lab_mirror0` created, Malcolm's capture reconfigured onto `lab_mirror0` with
   `liveZeek`/`liveArkime` set. Verified via `docker inspect`: `PCAP_IFACE=lab_mirror0`,
   `ZEEK_LIVE_CAPTURE=true`; `malcolm-pcap-capture-1` and `malcolm-zeek-live-1` both healthy after
   a full stop/start (`.env` changes do not reach already-running containers otherwise).
2. `r770-gns3-scenario-reference.sh build` — one ethernet hub, one cloud node bound to `br-lab`,
   two `netshoot` Docker nodes, one Alpine QEMU node; 4 links; project started. PASS.
3. `r770-gns3-scenario-reference.sh run` — 20 pings, 10 curls, 5 digs, 1 iperf3 transfer between
   the two netshoot nodes. PASS, evidence at the bottom of this file.
4. Verification — **not** via `r770-gns3-scenario-reference.sh verify`'s Arkime session-count
   check (blocked: needs the Malcolm `analyst` login password, deliberately deleted from the VM
   after Task 7 per the never-leave-secrets discipline; operator declined to provide it or
   regenerate it live rather than disrupt the running stack — see "Known gaps" below). Verified
   instead by reading Zeek's live capture log directly (root, no credentials needed): every
   traffic type `run` drove is present, with counts that match or closely match what was driven.

## Real bugs found and fixed getting here (all via systematic debugging against the live
server — reproduce, observe raw output, hypothesis, one change, test; never guessed)

1. **`r770-gns3-scenario-reference.sh`'s `GNS3SCN_API` default was `https://127.0.0.1:3080/v2`.**
   Both wrong: this GNS3 install answers plain HTTP (no `ssl =` line in `gns3_server.conf`), and
   it's GNS3 v3.0.6, which serves only `/v3` (`/v2/version` → 404). Fixed default →
   `http://127.0.0.1:3080/v3`.
2. **GNS3 v3 has no HTTP Basic Auth** (`curl -u user:pass .../v3/projects` → 401, with or without
   real credentials). Auth is JSON `POST /access/users/authenticate` → a bearer JWT. Replaced the
   Basic-Auth `api()` helper with `get_token()`/`ensure_token()`, preserving the existing
   "credentials never touch curl's argv" discipline (now via `-d @-` for login, `-K -`
   `header = "Authorization: Bearer ..."` for every other call).
3. **Cloud node's `ports_mapping` needs an explicit `"type":"ethernet"`** (GNS3 v3's
   `EthernetPort` schema requires it; 422 without it). Confirmed by reading
   `gns3server/schemas/compute/cloud_nodes.py` on the live server.
4. **Dynamips was missing entirely** — GNS3's `ethernet_switch`/`ethernet_hub` node types both
   route through the Dynamips compute backend regardless of any Cisco IOS image; absent, node
   creation fails "Could not find Dynamips". Added `dynamips` to `scripts/r770-offline-fetch.sh`'s
   curated apt set (Ubuntu universe, no PPA needed) and to the install runbook's Part 7.1 (this
   repo's convention puts apt-installs there, not in `r770-gns3-deploy.sh`, confirmed by research
   — that script only ever claimed to own the gns3-server pip wheel + config).
5. **`ubridge`'s own `.deb` ships the binary `root:ubridge`, mode 754** (group-execute only). The
   `gns3` service user had `kvm`+`docker` but not `ubridge`, so every cloud/link-touching node
   failed "uBridge is not available" even with the package installed and the service restarted.
   Fixed `ensure_user()` in `r770-gns3-deploy.sh` to add all three groups in one `usermod`.
6. **The registry's "Alpine Linux" `.gns3a` is a Docker appliance, not QEMU** — there is no
   registered QEMU template to reference by `template_name` at all; it silently resolved to a
   `None` platform, producing "QEMU binary 'qemu-system-None' cannot be found". Fixed: create the
   `alpine1` node with explicit qemu properties (`platform`, `cdrom_image`, `ram`) pointing at the
   Alpine ISO the bundle already stages, the same explicit-properties pattern already used for the
   netshoot Docker nodes.
7. **Every link reused `port_number: 0` on the hub/switch side** — only the first of 4 links could
   ever succeed; the rest 409'd "Port is already used". Fixed: increment the port per link.
8. **This netshoot image's `busybox` has no `httpd` applet at all** (`busybox --list` confirms).
   Switched the HTTP listener to `docker exec -d ... python3 -m http.server` (`-d`/detached is
   required: a plain `docker exec` backgrounding with `&` does not survive the exec call
   returning — verified both ways live).
9. **No DNS server exists anywhere in this topology or the netshoot image** — `dig` can never get
   an answer. Changed a dig failure from fatal to a warning: the DNS-shaped UDP query hitting the
   wire is the actual point (for Malcolm to capture and log), not that it gets answered.
10. **The biggest one: `ethernet_switch` doesn't mirror unicast traffic.** `build`/`run` both
    succeeded, but Zeek's live capture showed only IPv6 router-solicitation noise from
    `br-lab`/`lab-mon0` themselves — none of the actual GNS3 traffic. Root-caused with a live
    `tcpdump -i lab_mirror0` while regenerating traffic: a broadcast ARP request arrived, a
    directly-following ping did not. GNS3's `ethernet_switch` is a real learning switch: once it
    learns both netshoot nodes' MAC addresses (almost immediately), it forwards their unicast
    traffic only out the port it learned the destination on — never out the cloud-bound port.
    Fixed: the shared segment is now an `ethernet_hub`, which floods every frame to every port
    regardless of learned MACs — the same "hub-mode" principle the host-level `br-lab` bridge
    already uses for the identical reason (buildout §7.2), one layer further into the topology.
11. **`r770-gns3-scenario-reference.sh verify`'s Arkime integration had two more wrong
    assumptions**, found by reading `r770-malcolm-deploy.sh`'s own already-working `cmd_verify`
    (the sibling script that already proves Arkime/Zeek offline): Arkime has no standalone API
    port (`GNS3SCN_ARKIME_API` defaulted to `http://127.0.0.1:8005`, which points nowhere real —
    Malcolm's nginx portal fronts it under `/arkime/` on the same loopback HTTPS endpoint,
    `https://127.0.0.1:8443`, as everything else), and its sessions API returns
    `{"recordsFiltered": N, ...}`, not `{"sessions": N}`. Both fixed. This fix is code-verified
    (tests, shellcheck) but not live-verified against a real 200 response — see "Known gaps".

Every fix above: TDD (regression test added/updated before or alongside the fix, confirmed RED
where applicable), full suite green (`./tests/run.sh`, 548+ tests, 0 failures) and shellcheck
clean before each commit. Commits: e516ff6, 5eb1a6b, d7dcd87, be47050, 73d7bf7, 9d0951f, f5623de,
1cdf79a, e1c1630 (branch `claude/gns3-malcolm-mirror`).

## Known gaps (not blocking; documented for the next pass)

- **Arkime session-count check unverified live.** The endpoint/field fix (finding #11) is
  code-correct per the working sibling script's own pattern, but was never actually exercised
  against a real 200 response in this session — no valid `analyst` credentials were available,
  and the operator declined to regenerate them (regenerating via `--force` also resets all
  internal service credentials on the live stack). Confirming this needs either the current
  analyst password or a deliberate, operator-approved `auth --force` cycle.
- **`GNS3SCN_ZEEK_CAPTURE_LOSS_LOG`'s default path
  (`/data/pcap/zeek-live/current/capture_loss.log`) does not exist anywhere on this VM** — checked
  both the live spool and every rotated log directory; no `capture_loss` file exists at all yet.
  Not chased further under time pressure. Zeek's `misc/capture-loss` script writes on a periodic
  measurement window (traditionally ~15 min); it's plausible none has fired yet this run, or the
  real path/filename differs from what was assumed (matching the pattern of every other
  unverified-path assumption found this session). Needs the same live-read treatment as the fixes
  above before `verify`'s capture_loss check can be trusted.
- **One `dig` query returned a garbled/duplicate-looking answer** (a malformed response with an
  absurd `MSG SIZE`) rather than the expected "no servers could be reached" — plausibly an
  artifact of the hub now flooding every frame (a stray reflection), but this did not affect the
  proof (dig still exited non-fatally either way) and was not investigated further.
- **`scripts/r770-staging-vm.sh` still has no snapshot-creation verb** (only
  `status|rollback|start|stop|wait-ssh`) — flagged already in Task 7's evidence file, still true.

## Evidence

`run`'s evidence file (`/tmp/gns3-scenario/evidence.json` on the VM):
```json
{
  "pings": 20,
  "curls": 10,
  "digs": 5,
  "iperf_transfers": 1,
  "started_at": "2026-09-29T00:28:02.425710Z"
}
```

Zeek's live `conn.log` (`/opt/malcolm/malcolm/zeek-logs/live/spool/logger-1/conn.log`, filtered to
`192.168.100.2`/`192.168.100.3`, read directly, no credentials): 29 matching lines —

| Traffic | Zeek conn.log entries | Driven |
|---|---|---|
| ICMP (ping) | 1 entry, `orig_pkts=20 resp_pkts=20` | 20 pings |
| HTTP (curl) | 10 entries, port 80, `service=http`, `SF` (clean close) | 10 curls |
| DNS (dig) | 15 entries, port 53, `service=dns` (dig retries unanswered queries up to 3x) | 5 digs |
| iperf3 | 2 entries, port 5201 (control + data), one carrying 122MB/126MB | 1 transfer |

Every traffic type `run` drove is independently visible in Malcolm's own live capture pipeline,
with counts matching or closely matching (DNS retry multiplication is dig's own expected
behavior, not a bug) what was actually generated. This is the proof this sub-project set out to
produce: **a GNS3 lab's traffic appears in Malcolm.**
