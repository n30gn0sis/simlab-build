# Staging rehearsal of the IPsec scenario track (IP1b) — VM 9771, 2026-10-09 (UTC)

Plan: `docs/superpowers/plans/2026-10-07-ipsec-scenarios-plan.md` Part B (Tasks 14–16). Spec: `docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md` (now v0.1.4). Probes: `ipsec-probes-2026-10-08.md`. Per-run files (run.yaml, expected.md, capture-stats.txt, events.log, sha256sums without the `gt/` lines, traffic.out — never `gt/`, never PCAPs): `staging-ipsec-rehearsal-2026-10-09/`.

Driven from the Claude session over SSH (`ubuntu@192.168.4.26`), VM started 04:54 UTC after the operator stopped 9770. Nothing touched the R770. The repo on the VM was fast-forwarded by git bundle at each fix (final: `e0d4d14` + the last doc/script commit). Docker Compose stand-in for GNS3, lab bridges from `scen-bridges.sh`, Phase-12 `wan-apply`/`wan-show`/`wan-clear` as 15-line stand-ins in `/usr/local/bin` (removed at teardown; Phase 12 owns the real ones).

## Result

| Item | Result |
|---|---|
| Build (`r770-offline-fetch.sh --only labimages`) | PASS — `localhost/lab/{ipsec-ss,wan-emu,svc-targets}:20261009`, `lab-images.tar.gz` 56 MB + `.list`, no WARN; rebuilt twice after image fixes with `FORCE=1` |
| R1 (Docker `FORWARD DROP` + `br_netfilter`) | `-P FORWARD DROP` present, **`br_netfilter` not loaded** before or after `compose up` → bridged frames never reach iptables; no `DOCKER-USER` rule needed on this VM. Re-check on the R770 (IP2) |
| S0 (`S0-W1-none-20261009T0524Z`) | `scen-check`: **X4-inverse PASS, X8 PASS, RESULT: PASS**; 102 FAILED traffic steps by design (no site routes past the ISP) |
| H1 (veth vs bridge) | **PASS** — 258 = 258 frames on `veth-t01a` and `br-lab-t01` in the common window |
| H2 (inner/outer consistency) | **PASS** — 360 SYNs on both, identical `ip.id`s, outer 12–26 µs after inner |
| S0 baseline RTT | gw-a → 198.18.2.2: 0.104 ms avg (10 pings, unimpaired) → `rtt_ms: 0.1` in the S1 run copies |
| S1 run 1 (`…T0537Z`) | X1/X3/X4/X5 PASS; X2/X6/X7/X8 FAIL — all four root-caused and fixed (below) |
| S1 run 2 (`…T0615Z`) | X1–X5, X7, X8 PASS; X6 FAIL (rekey DELETEs counted as DPD) — fixed |
| S1 run 3 (`…T0625Z`) | X1–X5, X7, X8 PASS; X6 FAIL (DPD during the one-way UDP phase) — fixed |
| **S1 run 4 (`…T0633Z`)** | **X1–X8 PASS, RESULT: PASS**, 0 drops on all four points, 0 FAILED traffic steps, timeline 280 s exact (`traffic done` 1 s after `end`) |
| H3 (= X8) | **PASS** on run 4 (0 kernel drops with `-B 65536`) |
| H4 / X9 (ingest) | **PASS** after one Arkime setting — see "Malcolm" below |
| H5 (`scen-clear`) | **PASS** — `RTT OK (0.033 ms vs baseline 0.1, from gw-a)`, `all clear`, exit 0 |
| H6 (SIGTERM at t≈30 s) | **FAIL then PASS** — first attempt: cleanup only ran 240 s later (bash held the trap behind the engine's `sleep 240`); fixed; second attempt: `aborted rc=143` 30 ms after the kill, `pgrep tcpdump` empty, `wan-show` empty |

## Defects found and fixed in the repo (all with bats cases, suite green at each commit)

| # | Where | What the VM showed | Fix / commit |
|---|---|---|---|
| 1 | `images/ipsec-ss` | No noble package ships `save-keys` (O3) | Builder stage compiles the plugin from `apt-get source strongswan` (same `5.9.13-2ubuntu4.24.04.5`), version guard — `32b28d2` |
| 2 | `images/ipsec-ss/strongswan.d/save-keys.conf` | Plugin present but never loaded: `strongswan.d/charon/*.conf` is included *inside* `charon { plugins { } }`, the wrapped block resolved to `charon.plugins.charon.plugins.*` | Bare plugin block — `32b28d2` |
| 3 | `scenarios/S1/staging-compose.yaml` | Only the s1 gateways had `container_name`; `isp1`/hosts would be `s1-<svc>-1`, unreachable by the harness | `container_name` on every service — `19fd921` |
| 4 | `scen-clear` | H5 pinged `baseline.target` from the host, which has no address on the (IP-less) lab bridges → always `RTT UNKNOWN` | `baseline.node` pings from inside the node via `$SCEN_EXEC`, iputils and busybox parsed — `8241021` |
| 5 | traffic scripts + `scen-run` | S0: 50 curl × 10 s + 50 dig × 2 s with nothing answering → 651 s traffic vs 280 s plan; `scen-run` waited unbounded | 60 s budget per request phase; `SCEN_TRAFFIC_GRACE` (60 s) abandons a traffic job that outlives the last event (rc 124, exit 3) — `531ff94` |
| 6 | `images/ipsec-ss` | `plugin 'gcm'/'openssl'/'aesni': failed to load — no plugin file` | `libstrongswan-standard-plugins` — `35f5531` |
| 7 | `scenarios/S1/swanctl/*.conf` + spec §11.2 | `loading connection 's1' failed: invalid value for: auth` — `auth = psk  id = x` on one line is one value | One key per line (spec v0.1.3) — `35f5531` |
| 8 | `scen-check` X7 | tshark 4.2.2 rejects save-keys' `"AES-GCM [RFC4106]"` + `"ANY 128 bit authentication"`; with plain `NULL` it assumed a 0-byte ICV and never found the next header (decrypted bytes were a valid inner IPv4 packet) | Records rewritten to `"AES-GCM with <n> octet ICV [RFC4106]"` + `"NULL"` → inner 5-tuples decrypt — `775ae81` |
| 9 | swanctl confs | X2: 46 frames on UDP 4500 with no NAT — strongSwan's MOBIKE floats the IKE_SA after IKE_AUTH | `mobike = no` on both gateways — `775ae81` |
| 10 | traffic scripts | X6: load ended at ~100 s, the pad to 240 s was silent, DPD every 10 s | keepalive ping through the pad — `775ae81`; then (run 3) through the **whole** load, because the one-way UDP phase left gw-a with no inbound ESP — `7ba402b` |
| 11 | `scen-run` | X8: 167–536 kernel drops per point at ~135 Mbit/s into four 1 GB rings with tcpdump's 2 MiB buffer | `-B ${SCEN_CAP_BUFFER_KB:-65536}` → 0 drops — `775ae81` |
| 12 | manifests + `scenarios/README.md` | `veth-t01a` impairment labelled `A->B`, but egress of gw-a's bridge port flows toward gw-a: the A→B bulk ran at 135 Mbit/s past a "20 Mbit" profile, only ACKs were shaped | Label `B->A`, rule documented (name `veth-t01b` for A→B) — `775ae81` |
| 13 | `scen-check` X6 | Run 2's only strays: the INFORMATIONAL DELETE pair after each CHILD_SA rekey — opaque like a DPD from outside | INFORMATIONALs within 5 s of a CREATE_CHILD_SA exempt — `e3fe61e` |
| 14 | `staging-compose.yaml` | Named `/gt` volumes carried run 1's `charon.log` and keys into run 2's ground truth | Anonymous `/gt`, recreate with `-V` (and isp1 too — its ARP cache held the old gateway MAC and the first three IKE_SA_INITs went to a dead address for 24 s) — `e3fe61e` |
| 15 | `scen-events.sh` | H6: SIGTERM cleanup held until the engine's `sleep` to the next event returned (240 s) | Sleep as a job + `wait` (interruptible), cleanup kills it; regression test with a 600 s gap — `e0d4d14` |
| 16 | traffic scripts | UDP phase empty in every run: iperf3's 1448-byte datagram draws an ICMP frag-needed (tunnel MTU 1446) and iperf3 stops (`0/1`, receiver `0/0`); TCP phases fine (MSS adapts) | `-l 1200` → 5.00 Mbit/s, 0/2605 lost — last commit |
| 17 | `staging-compose.yaml` | IPv6 router solicitations/MLD from every container on every capture point and as icmpv6 sessions in Arkime | `net.ipv6.conf.all.disable_ipv6=1` on all services — last commit |

## Malcolm (H4 / X9) — two findings for Phase 10 and the spec

**Tag rule (confirmed in `pcap_utils.py` of the running pcap-monitor):** `tags_from_filename` splits the file name on `[,-/_.]+` and drops tokens that are all digits or pcap-ish (`p?cap|dmp|log|…`). `AUTO_TAG=true` on this deployment. So `scen-ingest`'s name `S1-W1-ss-20261009T0633Z-outer,outer-t01.pcapng0` yields the tags `S1 W1 ss 20261009T0633Z outer t01 pcapng0` — a hyphenated run-id can never be one tag. The per-run query is `tags == <stamp> && tags == outer` (the stamp is unique per run); spec X9 and `scen-ingest`'s header now say so. The comma separator is harmless but not what does the work.

**Arkime drops ESP unless `trackESP=true`:** the first upload of an outer capture registered no file and no session — `capture-offline` by hand: `packets: 0 … pstats: 0/0/0/0/73/0/0` (all packets "unknown"). With `-o trackESP=true`: 2996/3000 processed, sessions `(17, 500)` ISAKMP and `(50)` ESP. The option exists in this Arkime build but no Malcolm env knob renders it; `config.ini` is created from `config.orig.ini` in the container's writable layer at first start. For the rehearsal it was set with `sed` in the running container (the processor re-reads `config.ini` per upload). **Phase 10's deploy script must own this** (a `configure`-time edit that survives container recreation, or a bind-mounted `config.ini` that still gets the entrypoint's env rendering) — recorded in BUILD-STATE.

Validated after both: run 4 slices (40 000 frames each) uploaded as `S1-W1-ss-20261009T0633Z-outer,outer-t01-slice.pcap` / `…-inner,inner-i01-slice.pcap`:

```
tags == 20261009T0633Z && tags == outer : 8 sessions  [((58,0),6), ((17,500),1), ((50,0),1)]
tags == 20261009T0633Z && tags == inner : 37 sessions [((6,80),28), ((58,0),5), ((1,0),2), ((6,5201),1), ((17,5201),1)]
```

Outer = ISAKMP + ESP only (the 58/0 rows are the IPv6 router solicitations, now disabled); inner = HTTP, iperf3 TCP/UDP, ICMP. `ls /data/pcap/raw/upload` never showed anything from `gt/`. Arkime API auth: basic auth as `analyst` with the password from the 2026-10-04 reinstall (`/root/rehearsal-pw.txt` on the VM — `/root/analyst-pw` is the stale 09-26 one and gets `401 password mismatch`).

## Other observations (not fixed — decide before IP3)

- **Capture file format/name:** tcpdump writes classic pcap (`magic`: `application/vnd.tcpdump.pcap`) even to `-w x.pcapng`, and `-C/-W` names ring files `x.pcapng0`, `x.pcapng1`. Readers are fine with it; the name is misleading and `pcapng0` becomes a Malcolm tag. Options: capture with `dumpcap` (real pcapng, `-b filesize:/files:` rings named `x_00001_<ts>.pcapng`, `-B` in MiB, different drop-stat format) or keep tcpdump and rename after stop. Spec §-level decision; the harness, tests (`scen-ingest.bats` has 30 `.pcapng` references) and docs change together. **Decided 2026-10-09 (operator): rename after stop** — `scen-run` now writes `<name>.pcap` and renames tcpdump's `<name>.pcapN` to `<name>-<N>.pcap` once the tcpdumps have exited (also in the TERM cleanup path); `scen-check`/`scen-ingest` read only those names. Spec v0.1.5. The seven run directories on the VM keep their original `.pcapngN` names.
- **`sha256sums` lists `gt/` files** (SA snapshots, keys, `psk.txt`). Hashes of 256-bit random secrets are not reversible, but the copies in this evidence directory have the `gt/` lines removed anyway. **Decided 2026-10-09 (operator): keep the sums as they are and keep stripping** — the run directory's `sha256sums` stays complete (it is the run's integrity record, and `gt/` never leaves the lab), and any copy brought into this repo has its `gt/` lines removed; rule recorded in `scenarios/README.md`.
- **fstrim:** `fstrim.timer` fired at 05:40 and `/sbin/fstrim` sat in D state for 20 min on the 387 GB virtual disk (IO pressure 97 %), which made `compose up` take minutes per container and let the gateways' 60 s interface wait expire. The R770 build should check what `fstrim.timer` does to the capture disks (Phase 3/9).
- **Rehearsal procedure that works** (compose header updated): `scen-prep` → `gen-secrets.sh` (`RUN_DIR=<run-dir>`) → `compose --profile s1 up -d -V` → `scen-wire.sh` ×9 within 60 s → `scen-run` → `scen-check` → `scen-clear`; `compose down -v` between runs. The traffic node needs `host-b`'s `iperf3 -s` (compose does this).
- **Malcolm's memory on this VM:** 27 containers leave ~1 GiB; only slices were ingested. The full 4.4 GB run-4 set stays on the VM under `/data/pcap/cases/S1/S1-W1-ss-20261009T0633Z/` for a later full ingest.
- **IKE timing:** run 4's IKE_SA_INIT, IKE_AUTH and first CHILD_SA all land at t = 0.0–0.1 s after `traffic start` — the trap fires on host-a's first packet with the captures already up, as the spec's run procedure intends. CHILD_SA rekeys at 108 s and 216 s (`rekey_time 120s` minus jitter), DPD only in the 40 s tail.

## Residue on the VM (left for inspection)

Run directories under `/data/pcap/cases/{S0,S1}/` (seven; two are the H6 aborts). Malcolm is **running** (started for H4; it was stopped when the VM was found) with `trackESP=true` set only in the live `malcolm-arkime-1` container and the test sessions tagged `h6btest`/`esptest`/`20261009T0633Z` in its index. Scenario containers, bridges, veths and the `wan-*` stand-ins are gone; `xfrm_user xfrm_interface esp4 esp6 mpls_router mpls_iptunnel` remain loaded until reboot. Named volumes `s1_gt-gw-a`/`s1_gt-gw-b` from runs 1–3 and images `o3img`, `localhost/lab/ipsec-ss:o3test`, containers `o3build`/`o3build2` remain (the drydock hook refuses `docker rm`/`volume rm` from this session). `~/runs/`, `~/evidence/`, `~/staging-compose.rehearsal.yaml`, `/data/staging/labimages-rehearsal/bundle-20261009/` (the `labimages` output), `/tmp/*.pcap` slices.
