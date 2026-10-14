# IPsec & Simulated-WAN Scenarios — Deploy and Test Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the IPsec scenario spec into shippable, tested pieces — three lab container images, the reference-PCAP harness (`scen-prep`/`scen-run`/`scen-check`/`scen-ingest`/`scen-clear`), the S0/W1/S1 scenario definitions — prove them end-to-end on the staging VM under Docker Compose, then deploy and run them on the R770 once buildout Phases 6–12 exist, producing the first reference-PCAP set (S1 over W1, X1–X9 pass).

**Architecture:** Three parts. **Part A (repo + staging, runnable today):** everything is bash + bats like the rest of `scripts/`, with one deliberate exception — `run.yaml` manifests are parsed by `python3` + PyYAML (both already on the R770's base image; `python3-yaml` is added to the curated APT list). Images are built on staging by a new `labimages` stage of the fetch script and travel in the bundle like the other GNS3 node images. **Part B (staging rehearsal):** the whole S1 run is proven on VM 9771 with Docker Compose and four host bridges standing in for GNS3 Cloud nodes — the harness never knows the difference, and 9771 already has Malcolm for the ingest round trip. **Part C (R770, gated):** host prep, harness validation H1–H6, S1 reference set, then the W2–W7 / S2–S9 rollout, each as a `/phase`-style block that only advances with evidence under `state/inventory/`.

**Tech Stack:** bash, bats, shellcheck · Docker (staging) / GNS3 Docker nodes (R770) · strongSwan `swanctl`, FRR, netshoot · `tcpdump`, `tshark`, `tcpreplay` · `tc`/`netem`/HTB · Malcolm upload ingest.

**Spec:** `docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md` (v0.1.1, filed 2026-10-07 — section numbers below (§) refer to it).

## Global Constraints

- **Air gap:** every image, deb and appliance reaches the R770 only via the bundle (`scripts/r770-offline-fetch.sh`); nothing in Part C pulls, pips or curls (CLAUDE.md run context, spec §0.7).
- **No pins restated** anywhere in this plan's deliverables — reference the pin block in `scripts/r770-offline-fetch.sh`; fixtures use `0.0.0-fixture` tags (`OWNERS.md`). `tests/owners.bats` enforces this on tracked files, so **stage new files before `./tests/run.sh`**.
- **Secrets never enter Git or Malcolm:** `scenarios/**/secrets.conf`, `/data/pcap/cases/**/gt/` and any `*.key`/PSK material are gitignored and refused by `scen-ingest` (spec §5.6, §8.3, R5).
- **Capture-port and management guards:** the harness and `scen-bridges.sh` only ever touch interfaces named `br-lab-t[0-9][0-9]`, `br-lab-i[0-9][0-9]`, `br-lab-ext`, their veth members, or an interface the run manifest names; they refuse `lacp-trunk*`, `eno*`, `ens*`, `bond*`, `br-mirror` and anything in the Phase 9 capture-port list (CLAUDE.md rule 8, spec §6.1 M1 guard list).
- **`/data/pcap/cases/` is exempt from auto-retention**, so every run is size-capped (`tcpdump -C <MB> -W <n>`) and `scen-prep` refuses to start under the Phase-10 free-space floor (spec §8.1, R6).
- **Outer bridges are mirrored to `mirror0`; inner bridges never are** — inner traffic reaches Malcolm only by `scen-ingest` upload with the `-inner` tag (spec §3, R4).
- **GNS3 project start/stop stays operator-driven** in v0.1; the harness manages the host side and in-container ground truth only (spec §8.3).
- **Endpoint container contract E1–E7** (spec §5.2) is binding on `ipsec-ss` and any future custom endpoint image: `ubuntu:24.04` base, mounted config, `NET_ADMIN` + `ip_forward` sysctl floor, interface wait, `swanctl --list-sas` healthcheck, `/gt` output dir, no in-container module loading.
- **Bash-only is relaxed for one thing:** YAML data files (`run.yaml`, `events/*.yaml`) are read through `python3 -c 'import yaml'`. No other new language or dependency. Reason: the manifest schema (spec §8.2) is nested and a hand-rolled bash YAML reader is exactly the kind of fragile cleverness this repo avoids.
- **Match the repo's bats convention** (`tests/phase3-run.bats`): per-test `bin/` of stubs + `real/` allowlist of coreutils, every external path injected via env var with a default, nothing outside `$BATS_TEST_TMPDIR` touched. Run new suites as `nobody` once before a PR (root masks failures).
- **Phase 12's `wan-apply`/`wan-show`/`wan-clear` do not exist yet.** The harness calls them by name on `PATH`; staging and bats use stubs. The **profile file format** is defined by this plan (Task 1) so Phase 12 and `wan-emu` read the same files — Phase 12 must adopt it, recorded in buildout §4.4 by Task 13.

## Decisions this plan makes (operator: read these first — they are not in the spec)

| # | Decision | Why | Where recorded |
|---|---|---|---|
| D1 | Harness lives in **this repo** at `scripts/scenarios/` and ships to the R770 via the bundle's `site/` stage (added to `SITE_REQUIRED_SCRIPTS` in `scripts/r770-bundle.sh`), not in the `/opt/network-lab-config` config repo | The config repo does not exist yet; this repo's test gate is the only one that runs today | Task 5, README row (Task 13) |
| D2 | Impairment **profiles** live at `scenarios/profiles/*.conf` in this repo, one key=value file per profile, read by both `wan-emu` and (future) `wan-apply`. Phase 12 installs them to the config repo's `wan/profiles/` | Spec §0.6 "one profile library, three mechanisms" — the library has to be born somewhere before Phase 12 | Task 1; buildout §4.4 (Task 13) |
| D3 | `run.yaml` parsed with python3 + PyYAML; `python3-yaml` added to the curated APT list | See Global Constraints | Task 5 |
| D4 | A minimal `scripts/scenarios/scen-bridges.sh` creates/destroys `br-lab-tNN`/`br-lab-iNN` bridges **until `lab-transit.sh` exists** (Phase 7 deliverable, from the unfiled `lab-fabric.md`); when it lands, `scen-bridges.sh` becomes a thin wrapper or is deleted — never two bridge creators | Needed for the staging rehearsal and bats; nothing else can create them today | Task 10 |
| D5 | Staging rehearsal uses **Docker Compose + host bridges** instead of GNS3 | 9771 has Docker and Malcolm, no GNS3 server; the harness only sees bridges either way; proves H1–H6 and X1–X9 months before Phase 8 | Part B |
| D6 | Image tags are `lab/<name>:<bundle-date>` (e.g. `lab/ipsec-ss:20261015`) and the manifest records the `@sha256` digest the harness reads back from `docker image inspect` | Spec §8.2 wants digests; bundle date is the only version these images have | Task 5, Task 7c |
| D7 | `scen-check` (new, not in the spec's §8.3 table) automates the `expected.md` X-checks with `tshark`, writing PASS/FAIL into the run's `expected.md` | "Test these scenarios out" must be repeatable, not a human reading tshark output | Task 12 |

## Review Focus

Spec-implied inputs no task's happy path exercises, most likely to bite first; each has its test pinned to the owning task:

1. **A run manifest names an interface outside the guard list** (`iface: lacp-trunk.10`, `bridge: br-mirror`, or a capture port) — `scen-prep` must refuse before creating anything, naming the interface and the rule. → Task 6 test "refuses a manifest whose iface is the management VLAN".
2. **`scen-run` is killed mid-run (SIGINT/SIGTERM) or a capture dies early** — no `tcpdump` left running, no qdisc left applied, `events.log` ends with an `aborted` line, run dir kept (not deleted — partial evidence is evidence). → Task 7a test "trap cleanup on SIGTERM leaves no capture and clears every iface it impaired" (spec H6).
3. **Ground-truth directory already exists in the run dir or a node has no `/gt`** (appliance variant, or a crashed container) — collection records `gt/<node>/MISSING` and continues; it never aborts the run after the captures are already good. → Task 7c test "a node without /gt yields a MISSING marker, exit 0".
4. **`scen-ingest` is pointed at a run dir containing `gt/` and at a Malcolm upload dir that is a symlink** — it copies only `*.pcap`/`*.pcapng` at the top level, resolves the upload dir and refuses if it is outside `/data` (R5, and Malcolm's uploader chroot). → Task 8 tests "never copies gt/" and "refuses an upload dir outside /data".
5. **Free space on `/data/pcap` is below the floor, or the per-run cap × capture points exceeds free space** — `scen-prep` refuses with the arithmetic shown. → Task 6 test "refuses when cap×points exceeds free space".

---

## File Structure

```
scenarios/                              # scenario content (data), shipped in site/
├── README.md                           # 20 lines: layout + pointer to spec/plan
├── profiles/                           # D2 — one file per impairment profile
│   ├── branch-wan.conf  satellite.conf  poor-broadband.conf  asym-adsl.conf
│   └── lte-good.conf  lte-poor.conf  leo.conf  mpls-metro.conf  congested-uplink.conf
├── S0/  run.yaml  expected.md  events/s0-baseline.yaml  traffic/profile-basic.sh
└── S1/  run.yaml  expected.md  events/s1-baseline.yaml  traffic/profile-basic.sh
         swanctl/gw-a.conf  swanctl/gw-b.conf  gen-secrets.sh  staging-compose.yaml
images/                                 # built on staging by the labimages stage
├── ipsec-ss/   Dockerfile  entrypoint.sh  strongswan.d/save-keys.conf
├── wan-emu/    Dockerfile  wan-emu.sh
└── svc-targets/ Dockerfile  entrypoint.sh  nginx.conf  dnsmasq.conf
scripts/scenarios/
├── scen-lib.sh        # shared: manifest_get, profile_load, guard_iface, log, die
├── scen-prep          # prerequisites + run dir
├── scen-run           # captures → impairment → traffic → events → stop → collect
├── scen-events.sh     # event engine (sourced by scen-run)
├── scen-check         # X-checks via tshark → expected.md PASS/FAIL
├── scen-ingest        # copy PCAPs to Malcolm upload dir, tagged
├── scen-clear         # wan-clear + kill captures + baseline RTT check
└── scen-bridges.sh    # D4 — create/destroy lab bridges (until lab-transit.sh)
tests/
├── scen-lib.bats  scen-prep.bats  scen-run.bats  scen-events.bats  scen-check.bats
├── scen-ingest.bats  scen-clear.bats  scen-bridges.bats  wan-emu.bats  ipsec-ss.bats
└── scenarios-content.bats   # every scenarios/*/run.yaml validates; every profile loads
```

Modified: `scripts/r770-offline-fetch.sh` (new `labimages` stage, `python3-yaml`), `scripts/r770-bundle.sh` (`SITE_REQUIRED_SCRIPTS`), `.gitignore`, `README.md`, `docs/plans/r770-network-lab-buildout.md` §4.3/§4.4, `docs/plans/r770-dependency-manifest.md` §1/§3, `docs/analyst-wiki/wan.md`, new `docs/analyst-wiki/scenarios.md`, `state/BUILD-STATE.md`.

---

# Part A — Repo and staging-side build (executable now)

### Task 1: Profile library + `scen-lib.sh` core

**Files:**
- Create: `scenarios/profiles/*.conf` (9 files), `scenarios/README.md`, `scripts/scenarios/scen-lib.sh`
- Modify: `.gitignore`
- Test: `tests/scen-lib.bats`

**Interfaces:**
- Produces: `profile_load <name>` → exports `P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE` (strings as written, e.g. `20mbit`, `40ms`, `0.2%`; empty when absent); exit 1 if the file is missing or has an unknown key. `guard_iface <iface>` → exit 0 if allowed, exit 1 with reason on stderr. `die <msg>` (exit 1), `log <msg>` (UTC ms timestamp to stdout and `$SCEN_LOG` if set). `SCEN_PROFILES` env var (default: `<repo>/scenarios/profiles`).

- [ ] **Step 1: Write the profile files** — format is `KEY=value`, `#` comments, keys limited to `RATE_DOWN RATE_UP DELAY JITTER LOSS NOTE`. Values are `tc` syntax so both consumers pass them straight through.

```
# scenarios/profiles/branch-wan.conf — typical branch-office circuit (spec §6.2)
RATE_DOWN=20mbit
RATE_UP=20mbit
DELAY=40ms
JITTER=5ms
LOSS=0.2%
NOTE="W1/W2 access link"
```
```
# scenarios/profiles/lte-good.conf
RATE_DOWN=30mbit
RATE_UP=10mbit
DELAY=45ms
JITTER=10ms
LOSS=0.3%
NOTE="W4 subscriber access, good cell"
```
```
# scenarios/profiles/lte-poor.conf
RATE_DOWN=5mbit
RATE_UP=1mbit
DELAY=90ms
JITTER=30ms
LOSS=2%
NOTE="W4 subscriber access, poor cell"
```
```
# scenarios/profiles/leo.conf — static part only; handover spikes are events (spec §4 W5)
RATE_DOWN=100mbit
RATE_UP=15mbit
DELAY=30ms
JITTER=10ms
LOSS=0.5%
NOTE="W5 LEO; add link-down/up events for handovers"
```
```
# scenarios/profiles/mpls-metro.conf
RATE_DOWN=100mbit
RATE_UP=100mbit
DELAY=5ms
JITTER=1ms
LOSS=0%
NOTE="W3 CE-PE access"
```
```
# scenarios/profiles/congested-uplink.conf — rate only; queueing supplies delay/loss (spec W7)
RATE_DOWN=50mbit
RATE_UP=50mbit
DELAY=
JITTER=
LOSS=
NOTE="W7 shared HTB; run background iperf3 flows for contention"
```
```
# scenarios/profiles/satellite.conf — 600 ms RTT-equivalent: 300 ms each direction
RATE_DOWN=25mbit
RATE_UP=25mbit
DELAY=300ms
JITTER=20ms
LOSS=
NOTE="W5 GEO"
```
```
# scenarios/profiles/poor-broadband.conf
RATE_DOWN=10mbit
RATE_UP=10mbit
DELAY=80ms
JITTER=
LOSS=2%
NOTE="W1/W4 bad consumer line"
```
```
# scenarios/profiles/asym-adsl.conf
RATE_DOWN=8mbit
RATE_UP=1mbit
DELAY=25ms
JITTER=3ms
LOSS=0.1%
NOTE="W7 ADSL-style asymmetry"
```

- [ ] **Step 2: Write the failing tests**

```bash
# tests/scen-lib.bats
setup() {
    LIB="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-lib.sh"
    export SCEN_PROFILES="$BATS_TEST_DIRNAME/../scenarios/profiles"
    export T="$BATS_TEST_TMPDIR"
}
lib() { bash -c "source '$LIB'; $*"; }

@test "profile_load exports every field of branch-wan" {
    run lib 'profile_load branch-wan && echo "$P_RATE_DOWN $P_DELAY $P_JITTER $P_LOSS"'
    [ "$status" -eq 0 ]
    [ "$output" = "20mbit 40ms 5ms 0.2%" ]
}
@test "profile_load leaves absent fields empty" {
    run lib 'profile_load congested-uplink && echo "[$P_DELAY][$P_RATE_DOWN]"'
    [ "$output" = "[][50mbit]" ]
}
@test "profile_load fails on a missing profile" {
    run lib 'profile_load no-such-profile'
    [ "$status" -eq 1 ]; [[ "$output" == *"no such profile"* ]]
}
@test "profile_load rejects an unknown key" {
    mkdir -p "$T/p"; printf 'RATE_DOWN=1mbit\nBOGUS=1\n' > "$T/p/x.conf"
    SCEN_PROFILES="$T/p" run lib 'profile_load x'
    [ "$status" -eq 1 ]; [[ "$output" == *"unknown key BOGUS"* ]]
}
@test "guard_iface allows lab bridges and veths, refuses mgmt/capture/mirror" {
    for ok in br-lab-t01 br-lab-i12 br-lab-ext veth-t01a; do
        run lib "guard_iface $ok"; [ "$status" -eq 0 ]
    done
    for bad in lacp-trunk lacp-trunk.10 eno17295np0 ens5f0 bond0 br-mirror mirror0 br-lab-mgmt br-lab-nat lo; do
        run lib "guard_iface $bad"; [ "$status" -eq 1 ]; [[ "$output" == *"refused"* ]]
    done
}
@test "guard_iface also refuses anything in SCEN_CAPTURE_PORTS" {
    SCEN_CAPTURE_PORTS="enp10s0f0 enp10s0f1" run lib 'guard_iface enp10s0f1'
    [ "$status" -eq 1 ]
}
@test "log writes a UTC millisecond timestamp and appends to SCEN_LOG" {
    SCEN_LOG="$T/events.log" run lib 'log "traffic start"'
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\ traffic\ start$ ]]
    grep -q "traffic start" "$T/events.log"
}
```

- [ ] **Step 3: Run tests to verify they fail** — `bats tests/scen-lib.bats` → every test fails (`No such file` for the lib).

- [ ] **Step 4: Write `scripts/scenarios/scen-lib.sh`**

```bash
#!/usr/bin/env bash
# scen-lib.sh — shared functions for the reference-PCAP harness (spec §8).
# Sourced by scen-prep, scen-run, scen-check, scen-ingest, scen-clear. No side
# effects at source time. Every path is an env var with a default so bats can
# redirect it.
set -euo pipefail

SCEN_REPO="${SCEN_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCEN_PROFILES="${SCEN_PROFILES:-$SCEN_REPO/scenarios/profiles}"
SCEN_CASES="${SCEN_CASES:-/data/pcap/cases}"
SCEN_CAPTURE_PORTS="${SCEN_CAPTURE_PORTS:-}"      # Phase 9 list, space-separated
SCEN_LOG="${SCEN_LOG:-}"

log() {  # UTC with milliseconds, to stdout and (if set) $SCEN_LOG — spec §8.5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    printf '%s %s\n' "$ts" "$*"
    [ -n "$SCEN_LOG" ] && printf '%s %s\n' "$ts" "$*" >> "$SCEN_LOG" || true
}
die() { echo "ERROR: $*" >&2; exit 1; }

# profile_load <name> — exports P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE
profile_load() {
    local f="$SCEN_PROFILES/$1.conf" k v
    [ -f "$f" ] || die "no such profile: $1 ($f)"
    P_RATE_DOWN= P_RATE_UP= P_DELAY= P_JITTER= P_LOSS= P_NOTE=
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        case "$k" in
            RATE_DOWN|RATE_UP|DELAY|JITTER|LOSS|NOTE) printf -v "P_$k" '%s' "$v" ;;
            *) die "profile $1: unknown key $k" ;;
        esac
    done < "$f"
    export P_RATE_DOWN P_RATE_UP P_DELAY P_JITTER P_LOSS P_NOTE
}

# guard_iface <iface> — CLAUDE.md rule 8 / spec §6.1: lab segments only.
guard_iface() {
    local i="$1" p
    for p in $SCEN_CAPTURE_PORTS; do
        [ "$i" = "$p" ] && { echo "refused: $i is a capture port" >&2; return 1; }
    done
    case "$i" in
        br-lab-t[0-9][0-9]|br-lab-i[0-9][0-9]|br-lab-ext|veth-*) return 0 ;;
        *) echo "refused: $i is not a lab transit/inner bridge or veth (mgmt, capture, mirror and host bridges are off limits)" >&2; return 1 ;;
    esac
}
```

- [ ] **Step 5: Run tests** — `bats tests/scen-lib.bats` → 7/7 pass. `shellcheck scripts/scenarios/scen-lib.sh` clean.

- [ ] **Step 6: `.gitignore` + `scenarios/README.md`**

Append to `.gitignore`:
```
# IPsec scenario harness: per-run PSKs and ground truth (keys, SA dumps) never enter Git
scenarios/**/secrets.conf
scenarios/**/gt/
cases/
```
`scenarios/README.md`: the tree above (File Structure), one paragraph each for `profiles/` (format, D2), `S*/` (what a scenario folder holds), and the pointers to the spec and this plan. No version numbers.

- [ ] **Step 7: Commit**
```bash
git add scenarios/ scripts/scenarios/scen-lib.sh tests/scen-lib.bats .gitignore
./tests/run.sh && git commit -m "scenarios: profile library, scen-lib (profile_load, guard_iface, log)"
```

---

### Task 2: `wan-emu` image

**Files:**
- Create: `images/wan-emu/Dockerfile`, `images/wan-emu/wan-emu.sh`
- Test: `tests/wan-emu.bats`

**Interfaces:**
- Produces: container entrypoint `wan-emu.sh apply <profile> | show | clear | --dry-run apply <profile>`; profile files mounted at `/profiles` (`SCEN_PROFILES=/profiles` inside the image). Bridges `eth0`+`eth1` into `br0`; egress on `eth1` gets the DOWN-direction shaping (A→B), egress on `eth0` the UP-direction (B→A) — spec §5.4.

- [ ] **Step 1: Write the failing tests** (`wan-emu.sh` is plain bash; `--dry-run` prints the `ip`/`tc` lines instead of running them, which is what the tests assert on)

```bash
# tests/wan-emu.bats
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../images/wan-emu/wan-emu.sh"
    export SCEN_PROFILES="$BATS_TEST_DIRNAME/../scenarios/profiles"
    export SCEN_REPO="$BATS_TEST_DIRNAME/.."
}
@test "dry-run apply builds br0 and shapes both directions from branch-wan" {
    run "$SCRIPT" --dry-run apply branch-wan
    [ "$status" -eq 0 ]
    [[ "$output" == *"ip link add br0 type bridge"* ]]
    [[ "$output" == *"tc qdisc add dev eth1 root handle 1: htb default 10"* ]]
    [[ "$output" == *"tc class add dev eth1 parent 1: classid 1:10 htb rate 20mbit"* ]]
    [[ "$output" == *"tc qdisc add dev eth1 parent 1:10 handle 10: netem delay 40ms 5ms loss 0.2%"* ]]
    [[ "$output" == *"tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit"* ]]
}
@test "dry-run apply with an asymmetric profile puts RATE_DOWN on eth1 and RATE_UP on eth0" {
    run "$SCRIPT" --dry-run apply lte-poor
    [[ "$output" == *"dev eth1 parent 1: classid 1:10 htb rate 5mbit"* ]]
    [[ "$output" == *"dev eth0 parent 1: classid 1:10 htb rate 1mbit"* ]]
}
@test "dry-run apply omits netem when the profile has no delay/jitter/loss" {
    run "$SCRIPT" --dry-run apply congested-uplink
    [[ "$output" != *"netem"* ]]
    [[ "$output" == *"htb rate 50mbit"* ]]
}
@test "dry-run clear deletes root qdiscs on both legs only" {
    run "$SCRIPT" --dry-run clear
    [ "$output" = $'tc qdisc del dev eth1 root\ntc qdisc del dev eth0 root' ]
}
@test "apply with an unknown profile fails" {
    run "$SCRIPT" --dry-run apply nope
    [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests → fail** (`No such file`).

- [ ] **Step 3: Write `images/wan-emu/wan-emu.sh`**

```bash
#!/usr/bin/env bash
# wan-emu — L2 bump-in-the-wire impairment node (spec §5.4, mechanism M2).
# eth0 <-> br0 <-> eth1. Shaping is egress: eth1 egress = A->B (RATE_DOWN),
# eth0 egress = B->A (RATE_UP). Reads the same profiles/*.conf as wan-apply.
set -euo pipefail
. "${SCEN_LIB:-${SCEN_REPO:-/opt/scen}/scripts/scenarios/scen-lib.sh}"

DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
run() { if [ "$DRY" = 1 ]; then echo "$*"; else "$@"; fi; }

netem_args() {  # from P_* → "delay 40ms 5ms loss 0.2%" or empty
    local a=""
    [ -n "$P_DELAY" ] && a="delay $P_DELAY${P_JITTER:+ $P_JITTER}"
    [ -n "$P_LOSS" ] && [ "$P_LOSS" != "0%" ] && a="$a${a:+ }loss $P_LOSS"
    echo "$a"
}
shape() {  # shape <dev> <rate>
    run tc qdisc add dev "$1" root handle 1: htb default 10
    run tc class add dev "$1" parent 1: classid 1:10 htb rate "$2"
    local n; n=$(netem_args)
    # shellcheck disable=SC2086
    [ -n "$n" ] && run tc qdisc add dev "$1" parent 1:10 handle 10: netem $n
    return 0
}
bridge_up() {
    run ip link add br0 type bridge
    run ip link set eth0 master br0; run ip link set eth1 master br0
    run ip link set br0 up
}
case "${1:-}" in
    apply) profile_load "$2"; bridge_up
           shape eth1 "${P_RATE_DOWN:-1000mbit}"; shape eth0 "${P_RATE_UP:-1000mbit}" ;;
    clear) run tc qdisc del dev eth1 root; run tc qdisc del dev eth0 root ;;
    show)  tc qdisc show dev eth1; tc qdisc show dev eth0 ;;
    *) die "usage: wan-emu.sh [--dry-run] apply <profile> | show | clear" ;;
esac
```

- [ ] **Step 4: Run tests → 5/5 pass**; shellcheck clean.

- [ ] **Step 5: Dockerfile**

```dockerfile
# images/wan-emu/Dockerfile — built on staging only (labimages stage)
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iputils-ping \
 && rm -rf /var/lib/apt/lists/*
# the harness lib + profiles are copied in at build time from the repo checkout
COPY scripts/scenarios/scen-lib.sh /opt/scen/scripts/scenarios/scen-lib.sh
COPY scenarios/profiles/ /profiles/
COPY images/wan-emu/wan-emu.sh /usr/local/bin/wan-emu.sh
ENV SCEN_PROFILES=/profiles SCEN_REPO=/opt/scen
ENTRYPOINT ["/usr/local/bin/wan-emu.sh"]
CMD ["show"]
```
Build context is the repo root (the `labimages` stage, Task 5, runs `build -f images/wan-emu/Dockerfile .`).

- [ ] **Step 6: Commit** — `git add images/wan-emu tests/wan-emu.bats && ./tests/run.sh && git commit -m "images: wan-emu bump-in-the-wire impairment node"`

---

### Task 3: `ipsec-ss` image (strongSwan endpoint, contract E1–E7)

**Files:**
- Create: `images/ipsec-ss/Dockerfile`, `images/ipsec-ss/entrypoint.sh`, `images/ipsec-ss/strongswan.d/save-keys.conf`
- Test: `tests/ipsec-ss.bats`

**Interfaces:**
- Produces: container with `/etc/swanctl/conf.d/` mounted from `scenarios/<S>/swanctl/<node>.conf` + `secrets.conf`; env `WAIT_IFACES` (default `eth0 eth1`), `WAIT_SECS` (default 60), `SA_SNAPSHOT_SECS` (default 5); writes `/gt/keys/`, `/gt/sa/<UTC>.txt`, `/gt/charon.log`. Healthcheck: `swanctl --list-sas` output contains `INSTALLED`.

- [ ] **Step 1: Write the failing tests** (entrypoint exercised with stubbed `ip`, `swanctl`, and a stub charon at `$CHARON`)

```bash
# tests/ipsec-ss.bats
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../images/ipsec-ss/entrypoint.sh"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"
    mkdir -p "$BIN" "$REAL" "$S"; export S
    for t in bash sh sleep date mkdir cat printf; do p=$(command -v $t) && ln -sf "$p" "$REAL/$t"; done
    export GT="$BATS_TEST_TMPDIR/gt" CHARON="$BIN/charon" WAIT_SECS=2 SA_SNAPSHOT_SECS=1
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    stub ip      '[ -f "$S/ifaces" ] && grep -qx "$3" "$S/ifaces"'       # ip link show <if>
    stub swanctl 'echo "swanctl $*" >> "$S/calls"; echo "s1-net: INSTALLED"'
    stub charon  'echo charon >> "$S/calls"; sleep 30'
    PATH="$BIN:$REAL"
}
@test "waits for every iface, then starts charon, loads config and snapshots SAs into /gt" {
    printf 'eth0\neth1\n' > "$S/ifaces"
    run timeout 3 "$SCRIPT"
    grep -q charon "$S/calls"; grep -q -- "--load-all" "$S/calls"
    [ -d "$GT/keys" ]; ls "$GT"/sa/*.txt | grep -q 'Z.txt$'
    grep -q INSTALLED "$GT"/sa/*.txt
}
@test "exits 1 naming the missing iface after WAIT_SECS" {
    printf 'eth0\n' > "$S/ifaces"
    run "$SCRIPT"
    [ "$status" -eq 1 ]; [[ "$output" == *"iface eth1 missing"* ]]
    ! grep -q charon "$S/calls" 2>/dev/null
}
@test "WAIT_IFACES overrides the interface list" {
    printf 'eth0\n' > "$S/ifaces"
    WAIT_IFACES=eth0 run timeout 3 "$SCRIPT"
    grep -q charon "$S/calls"
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Write `images/ipsec-ss/entrypoint.sh`**

```sh
#!/bin/sh
# ipsec-ss entrypoint — spec §5.2 E4 (iface wait), E6 (/gt ground truth).
set -eu
: "${WAIT_IFACES:=eth0 eth1}" "${WAIT_SECS:=60}" "${SA_SNAPSHOT_SECS:=5}"
: "${GT:=/gt}" "${CHARON:=/usr/lib/ipsec/charon}"
mkdir -p "$GT/keys" "$GT/sa"
for i in $WAIT_IFACES; do
    n=0
    until ip link show "$i" >/dev/null 2>&1; do
        n=$((n+1)); [ "$n" -ge "$WAIT_SECS" ] && { echo "iface $i missing after ${WAIT_SECS}s" >&2; exit 1; }
        sleep 1
    done
done
"$CHARON" >"$GT/charon.log" 2>&1 &
sleep 2
swanctl --load-all
# SPI history across rekeys — one snapshot per interval
( while :; do swanctl --list-sas > "$GT/sa/$(date -u +%Y%m%dT%H%M%SZ).txt" 2>&1 || true; sleep "$SA_SNAPSHOT_SECS"; done ) &
wait
```

- [ ] **Step 4: Run → 3/3 pass.** `shellcheck -s sh images/ipsec-ss/entrypoint.sh` clean.

- [ ] **Step 5: `save-keys.conf` and Dockerfile**

```text
# images/ipsec-ss/strongswan.d/save-keys.conf — option names verified by probe O3 (Task 14)
charon {
  plugins {
    save-keys {
      load = yes
      esp = yes
      ike = yes
      wireshark_keys = /gt/keys
    }
  }
}
```
```dockerfile
# images/ipsec-ss/Dockerfile — strongSwan endpoint, contract E1–E7 (spec §5.2). Staging build only.
FROM ubuntu:24.04
# Pinned at bundle cut: record the installed strongswan version in the pin review, not here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      strongswan-charon strongswan-swanctl libstrongswan-extra-plugins libcharon-extra-plugins \
      iproute2 iputils-ping tcpdump ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# If probe O3 shows save-keys is absent from the noble packages, the labimages
# stage copies locally built .debs into images/ipsec-ss/debs/ and this line
# installs them instead (see Task 14 for the conditional).
COPY images/ipsec-ss/strongswan.d/save-keys.conf /etc/strongswan.d/charon/save-keys.conf
COPY images/ipsec-ss/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /gt /etc/swanctl/conf.d
HEALTHCHECK --interval=10s --timeout=3s CMD swanctl --list-sas 2>/dev/null | grep -q INSTALLED || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 6: Commit** — `git add images/ipsec-ss tests/ipsec-ss.bats && ./tests/run.sh && git commit -m "images: ipsec-ss strongSwan endpoint with /gt ground truth"`

---

### Task 4: `svc-targets` image

**Files:**
- Create: `images/svc-targets/Dockerfile`, `entrypoint.sh`, `nginx.conf`, `dnsmasq.conf`
- Test: `tests/svc-targets.bats`

**Interfaces:**
- Produces: HTTP on :80 serving `/fixed.bin` (exactly 1 MiB, deterministic content, sha256 constant), DNS on :53 answering `host<N>.site-b.lab` → `10.200.2.<N mod 250 + 1>` for N in 1..50 and `svc.site-b.lab` → its own address; `gen-fixed.sh` is the deterministic generator.

- [ ] **Step 1: Failing test**
```bash
# tests/svc-targets.bats
@test "gen-fixed.sh produces a 1 MiB file with the same sha256 every time" {
    G="$BATS_TEST_DIRNAME/../images/svc-targets/gen-fixed.sh"
    "$G" "$BATS_TEST_TMPDIR/a"; "$G" "$BATS_TEST_TMPDIR/b"
    [ "$(stat -c %s "$BATS_TEST_TMPDIR/a")" -eq 1048576 ]
    [ "$(sha256sum < "$BATS_TEST_TMPDIR/a")" = "$(sha256sum < "$BATS_TEST_TMPDIR/b")" ]
}
```
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement**
```bash
#!/usr/bin/env bash
# gen-fixed.sh <out> — deterministic 1 MiB: repeat a counter so runs are byte-identical
set -euo pipefail
seq -f 'fixed-%07g' 1 65536 | head -c 1048576 > "$1"
```
`nginx.conf`: `server { listen 80; root /srv/www; location / { autoindex off; } }`. `dnsmasq.conf`:
```
no-resolv
no-hosts
address=/svc.site-b.lab/10.200.2.20
synth-domain=site-b.lab,10.200.2.1,10.200.2.250,host
log-queries
```
`entrypoint.sh`: `gen-fixed.sh /srv/www/fixed.bin; dnsmasq -k -C /etc/dnsmasq.conf & exec nginx -g 'daemon off;'`.
Dockerfile: `FROM ubuntu:24.04`, install `nginx-light dnsmasq`, copy the four files, `EXPOSE 80 53/udp`, `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`.
- [ ] **Step 4: Run → pass. Commit** — `git add images/svc-targets tests/svc-targets.bats && ./tests/run.sh && git commit -m "images: svc-targets fixed HTTP/DNS endpoints"`

---

### Task 5: Bundle delta — `labimages` fetch stage, `python3-yaml`, `site/` ships the harness

**Files:**
- Modify: `scripts/r770-offline-fetch.sh` (STAGES, `stage_labimages`, usage text, curated apt list, `stage_marker`), `scripts/r770-bundle.sh:203` (`SITE_REQUIRED_SCRIPTS`), `docs/plans/r770-dependency-manifest.md` §1 (python3-yaml) and §3 (new row: `gns3/docker-nodes/lab-images.tar.gz`)
- Test: `tests/offline-fetch.bats` (add cases), `tests/bundle-verify.bats` (site list)

**Interfaces:**
- Produces: stage `labimages` (after `gns3`, before `appliances`) that builds `lab/ipsec-ss:$DATE`, `lab/wan-emu:$DATE`, `lab/svc-targets:$DATE` from the repo checkout with the detected runtime and `ctr_save`s them to `$B/gns3/docker-nodes/lab-images.tar.gz`, writing the tags to `$B/gns3/docker-nodes/lab-images.list`; `--dry-run` prints the build/save commands. `site/scripts/scenarios/` and `site/scenarios/` are in the bundle.

- [ ] **Step 1: Failing tests** — follow the existing `offline-fetch.bats` patterns for `--list`/`--dry-run` (read the file first; reuse its runtime stub):
```bash
@test "--list names the labimages stage between gns3 and appliances" {
    run fetch --list
    [[ "$output" =~ gns3[[:space:]].*labimages[[:space:]].*appliances ]]
}
@test "--dry-run --only labimages prints a build for each lab image and one save" {
    run fetch --dry-run --only labimages
    [ "$status" -eq 0 ]
    [[ "$output" == *"build -f images/ipsec-ss/Dockerfile"* ]]
    [[ "$output" == *"build -f images/wan-emu/Dockerfile"* ]]
    [[ "$output" == *"build -f images/svc-targets/Dockerfile"* ]]
    [[ "$output" == *"gns3/docker-nodes/lab-images.tar.gz"* ]]
}
@test "curated apt list includes python3-yaml" {
    grep -qE '^\s+.*\bpython3-yaml\b' "$FETCH"
}
```
and in `tests/bundle-verify.bats`: `SITE_REQUIRED_SCRIPTS` contains `scripts/scenarios/scen-run` (assert via `grep -q 'scripts/scenarios/scen-run' scripts/r770-bundle.sh`), plus a verify fixture test that a site tree lacking `scenarios/profiles/branch-wan.conf` fails `--strict`.

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — `STAGES=(preflight apt iso malcolm monitoring gns3 labimages appliances enrichment docs manual site manifest)`; add to usage text; `stage_labimages()`:
```bash
stage_labimages() {   # 6e. lab container images built from this checkout (spec §5.5)
    local tag="${BUNDLE_DATE}" img out="$B/gns3/docker-nodes/lab-images.tar.gz" tags=()
    for img in ipsec-ss wan-emu svc-targets; do
        [ -f "$REPO/images/$img/Dockerfile" ] || { note "WARN: images/$img/Dockerfile missing — skipped"; continue; }
        if [ "$DRY_RUN" = 1 ]; then echo "$CTR build -f images/$img/Dockerfile -t lab/$img:$tag $REPO"
        else $CTR build -f "$REPO/images/$img/Dockerfile" -t "lab/$img:$tag" "$REPO" || { note "WARN: build of lab/$img failed"; continue; }
        fi
        tags+=("lab/$img:$tag")
    done
    [ "${#tags[@]}" -gt 0 ] || return 0
    if [ "$DRY_RUN" = 1 ]; then echo "ctr_save $out ${tags[*]}"; else
        ctr_save "$out" "${tags[@]}"; printf '%s\n' "${tags[@]}" > "${out%.tar.gz}.list"
        note "lab images saved: ${tags[*]}"
    fi
}
```
(`$REPO`, `$CTR`, `$BUNDLE_DATE`, `$DRY_RUN` — use the names the script already uses for the checkout root, runtime command, bundle date and dry-run flag; read the file and match them.) Add `python3-yaml` on the `python3-ruamel.yaml python3-dotenv` line with a comment `# scen-* harness parses run.yaml`. Add `scripts/scenarios/scen-lib.sh scripts/scenarios/scen-prep scripts/scenarios/scen-run scripts/scenarios/scen-events.sh scripts/scenarios/scen-check scripts/scenarios/scen-ingest scripts/scenarios/scen-clear scripts/scenarios/scen-bridges.sh` to `SITE_REQUIRED_SCRIPTS` and make the `site` stage copy `scenarios/` (minus gitignored files) to `site/scenarios/`; `verify` checks `scenarios/profiles/branch-wan.conf` exists in `site/`.
- [ ] **Step 4: Run → pass. Update the dependency manifest** — §1 bullet "admin / tooling": add `python3-yaml`; §3 (GNS3) new row: `| Lab scenario images (ipsec-ss, wan-emu, svc-targets) | built from images/*/Dockerfile at cut, tagged lab/<name>:<bundle-date> | this repo | gns3/docker-nodes/lab-images.tar.gz + .list | ~300 MB |`. No version numbers.
- [ ] **Step 5: Commit** — `git add -A scripts/r770-offline-fetch.sh scripts/r770-bundle.sh tests/offline-fetch.bats tests/bundle-verify.bats docs/plans/r770-dependency-manifest.md && ./tests/run.sh && git commit -m "bundle: labimages stage builds the scenario images; site/ ships the scen-* harness; python3-yaml"`

---

### Task 6: `scen-prep`

**Files:**
- Create: `scripts/scenarios/scen-prep`; extend `scripts/scenarios/scen-lib.sh` with `manifest_get`, `manifest_list`, `run_dir_for`
- Test: `tests/scen-prep.bats`, extend `tests/scen-lib.bats`

**Interfaces:**
- Consumes: `profile_load`, `guard_iface`, `die`, `log` (Task 1).
- Produces: `manifest_get <run.yaml> <dotted.path>` → scalar on stdout (`run_id`, `ipsec.mode`, …; exit 1 if absent); `manifest_list <run.yaml> <path> <field>` → one value per line over a list (`capture_points bridge`, `impairment iface`, `nodes name`). `run_dir_for <run.yaml>` → `$SCEN_CASES/<scenario>/<run_id>`. `scen-prep <scenario-dir>` reads `<scenario-dir>/run.yaml`, checks: modules `xfrm_user xfrm_interface esp4` loaded (`$SCEN_MODULES_FILE`, default `/proc/modules`), every `capture_points[].bridge` exists (`$SCEN_SYSNET`, default `/sys/class/net`) and passes `guard_iface`, every `impairment[].iface` passes `guard_iface`, `wan-show` prints nothing, free space on `$SCEN_CASES` ≥ `SCEN_FREE_FLOOR_GB` (default 200) **and** ≥ `cap_mb × ring × points`; creates the run dir and copies `run.yaml` into it. Exit 0 and prints the run dir; exit 1 with the failing check named.

- [ ] **Step 1: Failing tests (lib)** — add to `tests/scen-lib.bats`, using a fixture `run.yaml` written in `setup` (the spec §8.2 example with `image: quay.io/frrouting/frr:0.0.0-fixture`, `lab/ipsec-ss:0.0.0-fixture`):
```bash
@test "manifest_get reads scalars by dotted path" {
    run lib "manifest_get '$T/run.yaml' run_id";          [ "$output" = "S1-W1-ss-20261001T1400Z" ]
    run lib "manifest_get '$T/run.yaml' ipsec.child_rekey_s"; [ "$output" = "120" ]
    run lib "manifest_get '$T/run.yaml' nope.nope"; [ "$status" -eq 1 ]
}
@test "manifest_list returns one field per list item" {
    run lib "manifest_list '$T/run.yaml' capture_points bridge"
    [ "$output" = $'br-lab-t01\nbr-lab-t02\nbr-lab-i01\nbr-lab-i02' ]
}
```
- [ ] **Step 2: Failing tests (scen-prep)**
```bash
# tests/scen-prep.bats — stubs: wan-show (prints $S/wanshow), df (prints $S/free_kb), lsmod unused (modules via file)
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios/scen-prep"
    BIN="$BATS_TEST_TMPDIR/bin"; REAL="$BATS_TEST_TMPDIR/real"; S="$BATS_TEST_TMPDIR/s"; mkdir -p "$BIN" "$REAL" "$S"
    for t in bash python3 date mkdir cp cat grep sed awk printf dirname basename readlink; do p=$(command -v $t) && ln -sf "$p" "$REAL/$t"; done
    export SCEN_REPO="$BATS_TEST_DIRNAME/.." SCEN_CASES="$BATS_TEST_TMPDIR/cases" SCEN_SYSNET="$BATS_TEST_TMPDIR/sysnet"
    export SCEN_MODULES_FILE="$BATS_TEST_TMPDIR/modules" SCEN_FREE_FLOOR_GB=1 S
    mkdir -p "$SCEN_SYSNET"/br-lab-t01 "$SCEN_SYSNET"/br-lab-t02 "$SCEN_SYSNET"/br-lab-i01 "$SCEN_SYSNET"/br-lab-i02
    printf 'xfrm_user 1\nxfrm_interface 1\nesp4 1\n' > "$SCEN_MODULES_FILE"
    stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
    stub wan-show 'cat "$S/wanshow" 2>/dev/null'
    stub df 'echo "Filesystem 1K-blocks Used Available Use% Mounted"; echo "x 1 1 $(cat "$S/free_kb") 1% /data/pcap"'
    echo $((500*1024*1024)) > "$S/free_kb"
    mkdir -p "$BATS_TEST_TMPDIR/S1"; cp "$BATS_TEST_DIRNAME/fixtures/run-s1.yaml" "$BATS_TEST_TMPDIR/S1/run.yaml"
    export PATH="$BIN:$REAL"
}
@test "creates the run dir and copies the manifest when every check passes" {
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 0 ]
    [ -f "$SCEN_CASES/S1/S1-W1-ss-20261001T1400Z/run.yaml" ]
}
@test "refuses when a module is missing" {
    printf 'xfrm_user 1\n' > "$SCEN_MODULES_FILE"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"esp4"* ]]
}
@test "refuses when a capture bridge does not exist" {
    rmdir "$SCEN_SYSNET/br-lab-i02"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"br-lab-i02"* ]]
}
@test "refuses a manifest whose iface is the management VLAN" {
    sed -i 's/iface: veth-t01a/iface: lacp-trunk.10/' "$BATS_TEST_TMPDIR/S1/run.yaml"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"refused: lacp-trunk.10"* ]]
    [ ! -d "$SCEN_CASES" ]
}
@test "refuses when wan-show is not clean" {
    echo "veth-t01a: netem delay 40ms" > "$S/wanshow"
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"wan-show not clean"* ]]
}
@test "refuses when cap×points exceeds free space, showing the arithmetic" {
    echo $((3*1024*1024)) > "$S/free_kb"      # 3 GB free; manifest: cap 1024 MB × ring 2 × 4 points = 8 GB
    run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"8192 MB needed"* ]]
}
@test "refuses below the free-space floor even if the run would fit" {
    SCEN_FREE_FLOOR_GB=200 run "$SCRIPT" "$BATS_TEST_TMPDIR/S1"; [ "$status" -eq 1 ]; [[ "$output" == *"floor"* ]]
}
```
Fixture `tests/fixtures/run-s1.yaml`: the §8.2 manifest with `capture: {cap_mb: 1024, ring: 2}` added, `impairment[0].iface: veth-t01a`, fixture image tags.

- [ ] **Step 3: Run → fail.**
- [ ] **Step 4: Implement** — lib additions:
```bash
manifest_get() {  # manifest_get <run.yaml> <a.b.c>
    python3 -I - "$1" "$2" <<'PY' || return 1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    if not isinstance(d, dict) or k not in d: sys.exit(1)
    d = d[k]
print('' if d is None else d)
PY
}
manifest_list() {  # manifest_list <run.yaml> <list-key> <field>
    python3 -I - "$1" "$2" "$3" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])).get(sys.argv[2]) or []
for item in d: print(item.get(sys.argv[3], ''))
PY
}
run_dir_for() { echo "$SCEN_CASES/$(manifest_get "$1" scenario)/$(manifest_get "$1" run_id)"; }
```
`scen-prep`: source the lib, `M="$1/run.yaml"`, then in order: modules (loop `grep -q "^$m " "$SCEN_MODULES_FILE"`), bridges exist + `guard_iface`, impairment ifaces `guard_iface`, `[ -z "$(wan-show)" ] || die "wan-show not clean: …"`, free space (`df -Pk "$SCEN_CASES"` → `awk 'NR==2{print $4}'`; compute `need_mb=$((cap*ring*points))`, floor), then `mkdir -p "$dir" && cp "$M" "$dir/run.yaml" && echo "$dir"`. When `$SCEN_CASES` does not exist yet, `df` the nearest existing parent.
- [ ] **Step 5: Run → all pass; shellcheck clean. Commit** — `git add scripts/scenarios tests/scen-prep.bats tests/scen-lib.bats tests/fixtures/run-s1.yaml && ./tests/run.sh && git commit -m "scen-prep: prerequisite gate and run directory"`

---

### Task 7a: `scen-run` core — captures, trap cleanup, drop stats

**Files:**
- Create: `scripts/scenarios/scen-run`
- Test: `tests/scen-run.bats`

**Interfaces:**
- Consumes: lib (Task 1, 6).
- Produces: `scen-run <run-dir>/run.yaml` → for each capture point starts `tcpdump -i <bridge> -w <dir>/<name>.pcapng -C <cap_mb> -W <ring> -Z root -s 0 -n` (PID recorded in `<dir>/.pids`), applies each `impairment[]` via `wan-apply <profile> <iface>` (M1) or logs `M2 node <name>` (operator applies inside the node), runs `traffic.script` through `SCEN_EXEC` (default `docker exec <traffic.node>`; the manifest gains `traffic.node`), runs events (Task 7b), stops captures with SIGINT and waits, writes `capture-stats.txt` from each tcpdump's stderr (`N packets dropped by kernel`), then Task 7c's collection. `trap` on EXIT/INT/TERM: kill captures, `wan-clear` every iface it applied, `log aborted` if not finished. Exit 0 on success.

- [ ] **Step 1: Failing tests** (stubs: `tcpdump` writes `"$S/tcpdump.$name"` with args and sleeps until killed, printing `0 packets dropped by kernel` on SIGINT; `wan-apply`/`wan-clear` log to `$S/calls`; `docker` logs; `date` real)
```bash
@test "starts one tcpdump per capture point with cap and ring, then stops them" {
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 0 ]
    for n in outer-t01 outer-t02 inner-i01 inner-i02; do grep -q -- "-w $RUN/$n.pcapng -C 1024 -W 2" "$S/tcpdump.$n"; done
    ! pgrep -f "tcpdump -i br-lab" 
}
@test "applies impairment after captures start and clears it before captures stop" {
    run "$SCRIPT" "$RUN/run.yaml"
    [ "$(grep -n 'wan-apply branch-wan veth-t01a' "$S/calls" | cut -d: -f1)" -lt "$(grep -n 'wan-clear veth-t01a' "$S/calls" | cut -d: -f1)" ]
    grep -q "^tcpdump-start" "$S/order"; [ "$(grep -n tcpdump-start "$S/order" | head -1 | cut -d: -f1)" -lt "$(grep -n wan-apply "$S/order" | cut -d: -f1)" ]
}
@test "writes capture-stats.txt with one line per capture point" {
    run "$SCRIPT" "$RUN/run.yaml"
    [ "$(grep -c 'dropped by kernel' "$RUN/capture-stats.txt")" -eq 4 ]
}
@test "trap cleanup on SIGTERM leaves no capture and clears every iface it impaired" {
    stub docker 'sleep 60'          # traffic hangs
    "$SCRIPT" "$RUN/run.yaml" & pid=$!; sleep 2; kill -TERM $pid; wait $pid || true
    ! pgrep -f "tcpdump -i br-lab"; grep -q 'wan-clear veth-t01a' "$S/calls"
    tail -1 "$RUN/events.log" | grep -q aborted
    [ -d "$RUN" ]
}
@test "refuses to start when a capture point fails guard_iface" {
    sed -i 's/bridge: br-lab-t02/bridge: br-mirror/' "$RUN/run.yaml"
    run "$SCRIPT" "$RUN/run.yaml"; [ "$status" -eq 1 ]; [ ! -f "$S/tcpdump.outer-t01" ]
}
```
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** the skeleton with `start_captures`, `apply_impairments`, `run_traffic`, `stop_captures`, `cleanup()` trap:
```bash
cleanup() {
    local rc=$?
    for p in $(cat "$D/.pids" 2>/dev/null); do kill -INT "$p" 2>/dev/null || true; done
    for i in $APPLIED; do wan-clear "$i" || true; done
    [ "${FINISHED:-0}" = 1 ] || log "aborted rc=$rc"
    exit $rc
}
trap cleanup EXIT INT TERM
```
`guard_iface` every bridge and iface **before** anything starts. `SCEN_LOG="$D/events.log"`.
- [ ] **Step 4: Run → pass; shellcheck clean. Commit** — `"scen-run: captures, impairment, traffic, trap cleanup, drop stats"`

---

### Task 7b: Event engine `scen-events.sh`

**Files:**
- Create: `scripts/scenarios/scen-events.sh` (sourced by `scen-run`)
- Test: `tests/scen-events.bats`

**Interfaces:**
- Produces: `events_run <events.yaml> <t0_epoch>` — reads the list `[{t, action, …}]`, sleeps until `t0+t` for each in order, executes: `note` (log text), `link-down`/`link-up` (`target: <bridge>:<port>` → `guard_iface port` then `ip link set <port> down|up`), `wan-apply`/`wan-clear` (`profile`, `iface` → guard then call; records iface in `APPLIED`), `exec` (`node`, `cmd` → `$SCEN_EXEC <node> sh -c "<cmd>"`), `gns3-link-suspend`/`resume` (log `unsupported until O4` and continue). Every event logs `event t=<t> <action> <args>` through `log`. Unknown action → `die` before the run starts (validated up front).

- [ ] **Step 1: Failing tests** — fixture events file with `t: 0 note`, `t: 1 link-down br-lab-t01:veth-t01a`, `t: 1 link-up …`, `t: 2 wan-apply lte-poor veth-t01a`, `t: 2 exec gw-a 'swanctl --list-sas'`; stubs `ip`, `wan-apply`, `docker` logging to `$S/calls`:
```bash
@test "executes events in order at their offsets and logs each with a timestamp" { … grep -c '^20.*event t=' "$T/events.log" → 5; order of calls in $S/calls matches }
@test "link-down on a management port is refused before any event runs" { target lacp-trunk.10 → exit 1; $S/calls absent }
@test "unknown action is refused up front" { action: reboot → exit 1, "unknown action reboot" }
@test "gns3-link-suspend is logged as unsupported and does not abort" { … }
```
- [ ] **Step 2–4:** fail → implement (`python3 -I` dumps the list as `t|action|k=v|k=v` lines; bash loop with `sleep $((t0+t-now))` guarded ≥0) → pass → `git commit -m "scen-events: timed event engine (note, link-down/up, wan-apply/clear, exec)"`.

---

### Task 7c: Ground-truth collection, manifest completion, `sha256sums`

**Files:**
- Modify: `scripts/scenarios/scen-run` (add `collect_gt`, `finish_manifest`)
- Test: extend `tests/scen-run.bats`

**Interfaces:**
- Produces: for each `nodes[]` with `role: endpoint`: `$SCEN_CP <name> /gt <dir>/gt/<name>/` (default `docker cp <name>:/gt`); on failure writes `<dir>/gt/<name>/MISSING` with the error, continues. Records each node's image digest (`docker image inspect --format '{{index .RepoDigests 0}}'`) into `run.yaml` `nodes[].digest`. Fills `times_utc.start/end` (python3 in-place edit of the copied manifest), appends host load (`uptime` 1-min) to `results.notes`, writes `sha256sums` over every top-level file and `gt/**` (R9, §8.1).

- [ ] **Step 1: Failing tests**
```bash
@test "collects /gt from every endpoint node" { stub docker 'case "$1" in cp) mkdir -p "${@: -1}"; touch "${@: -1}/keys";; esac'; … [ -e "$RUN/gt/gw-a/keys" ]; [ -e "$RUN/gt/gw-b/keys" ]; [ ! -d "$RUN/gt/isp1" ] }
@test "a node without /gt yields a MISSING marker, exit 0" { docker cp exits 1 for gw-b → [ -f "$RUN/gt/gw-b/MISSING" ]; status 0 }
@test "fills times_utc and writes sha256sums covering pcaps and gt" { manifest_get times_utc.start non-empty; grep -q outer-t01.pcapng "$RUN/sha256sums"; grep -q gt/gw-a "$RUN/sha256sums" }
```
- [ ] **Step 2–4:** fail → implement → pass → `git commit -m "scen-run: ground-truth collection, manifest actuals, sha256sums"`.

---

### Task 8: `scen-ingest`

**Files:**
- Create: `scripts/scenarios/scen-ingest`
- Test: `tests/scen-ingest.bats`

**Interfaces:**
- Produces: `scen-ingest <run-dir>` → for each top-level `*.pcap|*.pcapng`: copies to `<upload-dir>/<run_id>-<view>,<file>` where view is `outer`/`inner` from the manifest's `capture_points[].view` (Malcolm's uploader turns the comma-separated prefix into a tag — confirm the exact rule in the bundled Malcolm docs mirror during H4 and adjust the separator here if needed). Upload dir from `$SCEN_UPLOAD_DIR` if set, else `scripts/r770-malcolm-deploy.sh`'s `upload_dir()` (source it with `--source-only` if that exists; otherwise call a new `r770-malcolm-deploy.sh upload-dir` verb added in this task — read the script and pick the smaller change). Refuses: a run dir without `run.yaml`; an upload dir that resolves (`readlink -f`) outside `/data`; never descends into `gt/`. Exit 0 prints the copied names.

- [ ] **Step 1: Failing tests**
```bash
@test "copies outer and inner pcaps with run-id,view tags" { … [ -f "$UP/S1-W1-ss-20261001T1400Z-outer,outer-t01.pcapng" ]; [ -f "$UP/S1-W1-ss-20261001T1400Z-inner,inner-i01.pcapng" ] }
@test "never copies gt/" { mkdir -p "$RUN/gt/gw-a/keys"; echo k > "$RUN/gt/gw-a/keys/esp_sa"; run …; [ -z "$(find "$UP" -name 'esp_sa' -o -name '*gt*')" ] }
@test "refuses an upload dir outside /data" { SCEN_UPLOAD_DIR="$BATS_TEST_TMPDIR/elsewhere" → exit 1, "outside /data" }   # tests set SCEN_DATA_ROOT="$BATS_TEST_TMPDIR/data" to make the good case pass
@test "refuses a dir without run.yaml" { … }
```
- [ ] **Step 2–4:** fail → implement → pass → `git commit -m "scen-ingest: tagged upload to Malcolm, gt/ never leaves the run dir"`.

---

### Task 9: `scen-clear`

**Files:** Create `scripts/scenarios/scen-clear`; Test `tests/scen-clear.bats`.

**Interfaces:** `scen-clear <run.yaml>` → `wan-clear` every `impairment[].iface` (guarded), kill any `tcpdump` whose `-w` path is under the run dir (`pkill -INT -f "tcpdump .* -w $dir/"`), then if `baseline.target` and `baseline.rtt_ms` are set in the manifest: `ping -c 10 <target>`, compare mean RTT within `±1 ms` of `baseline.rtt_ms` (H5), print `RTT OK`/`RTT DRIFT`. Exit 1 if `wan-show` is still non-empty afterwards.

- [ ] Tests: "clears every manifest iface and only those", "kills only captures under the run dir", "exits 1 when wan-show is still non-empty", "reports RTT DRIFT when ping mean is >1 ms from baseline" (stub `ping` output). Implement, pass, `git commit -m "scen-clear: impairment + capture cleanup with baseline RTT check"`.

---

### Task 10: `scen-bridges.sh` (D4)

**Files:** Create `scripts/scenarios/scen-bridges.sh`; Test `tests/scen-bridges.bats`.

**Interfaces:** `scen-bridges.sh create|destroy <bridge>...` — each name must pass `guard_iface` **and** match `br-lab-(t|i)[0-9]{2}|br-lab-ext`; `create`: `ip link add <b> type bridge && ip link set <b> up`, `sysctl -w net.ipv6.conf.<b>.disable_ipv6=1`, never assigns an address; `destroy`: `ip link del <b>` only if it has no member ports (`ls /sys/class/net/<b>/brif` empty) unless `--force`. `--dry-run` prints. Header comment: *"Temporary until lab-transit.sh (Phase 7) — fold in, don't fork."*

- [ ] Tests: dry-run create prints the three commands and no `ip addr`; refuses `br-lab-mgmt`, `br-mirror`, `br-lab-t1` (two digits required); destroy refuses a bridge with members without `--force`. Implement, pass, `git commit -m "scen-bridges: lab bridge create/destroy, guarded, until lab-transit.sh"`.

---

### Task 11: Scenario content — S0, W1, S1

**Files:**
- Create: `scenarios/S0/{run.yaml,expected.md,events/s0-baseline.yaml,traffic/profile-basic.sh}`, `scenarios/S1/{run.yaml,expected.md,events/s1-baseline.yaml,traffic/profile-basic.sh,swanctl/gw-a.conf,swanctl/gw-b.conf,gen-secrets.sh,secrets.conf.example,staging-compose.yaml}`
- Test: `tests/scenarios-content.bats`

**Interfaces:**
- Produces: manifests that `scen-prep` accepts; `gen-secrets.sh <scenario-dir>` writes `swanctl/secrets.conf` (gitignored) with a 32-byte random PSK and copies it to `$RUN_DIR/gt/psk.txt` when `RUN_DIR` is set; `staging-compose.yaml` wires `gw-a`, `gw-b`, `isp1`, `host-a`, `host-b`, `svc-b` to the four bridges via `macvlan`-free plain veths created by compose `network_mode: none` + a `scen-wire.sh` helper (see Step 3) — used by Part B only.

- [ ] **Step 1: Failing tests**
```bash
@test "every scenarios/*/run.yaml has the required keys and passes manifest_get" {
    for m in "$ROOT"/scenarios/S*/run.yaml; do
        for k in run_id scenario underlay variant spec_version capture.cap_mb capture.ring traffic.script traffic.node events; do
            run lib "manifest_get '$m' $k"; [ "$status" -eq 0 ] || { echo "$m lacks $k"; false; }
        done
    done
}
@test "every profile referenced by a manifest exists" { for each impairment profile → profile_load ok }
@test "S1 swanctl confs are mirror images: gw-a starts, gw-b traps" {
    grep -q 'start_action = start' scenarios/S1/swanctl/gw-a.conf; grep -q 'start_action = trap' scenarios/S1/swanctl/gw-b.conf
    grep -q 'local_ts  = 10.200.1.0/24' scenarios/S1/swanctl/gw-a.conf; grep -q 'local_ts  = 10.200.2.0/24' scenarios/S1/swanctl/gw-b.conf
}
@test "gen-secrets.sh writes a gitignored secrets.conf and never a tracked one" {
    cp -r scenarios/S1 "$T/S1"; "$ROOT/scenarios/S1/gen-secrets.sh" "$T/S1"
    grep -qE 'secret = "[0-9a-f]{64}"' "$T/S1/swanctl/secrets.conf"
    git -C "$ROOT" check-ignore -q scenarios/S1/swanctl/secrets.conf
}
@test "no scenario file carries a version pin or a real secret" { ! grep -rE 'secret = "[0-9a-f]{64}"' scenarios/ }
```
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Write the content** — `S1/run.yaml` is spec §8.2 verbatim plus:
```yaml
capture: {cap_mb: 1024, ring: 4}
traffic: {lane: A, script: traffic/profile-basic.sh, seed: 1001, node: host-a}
baseline: {target: 198.18.2.2, rtt_ms: null}     # filled from the S0 run
nodes:
  - {name: gw-a,  image: lab/ipsec-ss:0.0.0-fixture, role: endpoint}     # tags are rewritten to the bundle date by scen-prep? No: operator sets them at run time — see scenarios/README.md
  - {name: gw-b,  image: lab/ipsec-ss:0.0.0-fixture, role: endpoint}
  - {name: isp1,  image: quay.io/frrouting/frr:0.0.0-fixture, role: provider}
  - {name: host-a, image: docker.io/nicolaka/netshoot:latest, role: helper}
  - {name: host-b, image: docker.io/nicolaka/netshoot:latest, role: helper}
  - {name: svc-b,  image: lab/svc-targets:0.0.0-fixture, role: helper}
```
(The committed manifest carries fixture tags; the run copy is edited by the operator — or by `scen-prep --images <list-file>` reading `gns3/docker-nodes/lab-images.list` — add that flag to `scen-prep` here with a test: it rewrites `lab/<name>:0.0.0-fixture` to the listed tag.) `S0/run.yaml`: same with no `ipsec:` block, no endpoint nodes, `variant: none`. `swanctl/gw-a.conf` and `gw-b.conf`: spec §11.2 verbatim (gw-b with addresses/IDs/TS swapped, `start_action = trap`), both `include /etc/swanctl/conf.d/secrets.conf`-free — `secrets.conf` sits beside them and swanctl loads the whole dir. `traffic/profile-basic.sh`: spec §7.1 with `set -eu`, `SEED` env honoured by `iperf3 --... ` ordering only (document it), 240 s total then `sleep 40` idle tail. `events/s1-baseline.yaml`: `[{t: 0, action: note, text: "traffic start"}, {t: 240, action: note, text: "idle tail for DPD"}, {t: 280, action: note, text: "end"}]`. `expected.md`: spec §11.2 X1–X9 table with a `Result` column of `—`. `gen-secrets.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
d="${1:?scenario dir}"; psk=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cat > "$d/swanctl/secrets.conf" <<EOF
secrets { ike-s1 { id-a = gw-a.site-a.lab  id-b = gw-b.site-b.lab  secret = "$psk" } }
EOF
chmod 600 "$d/swanctl/secrets.conf"
[ -n "${RUN_DIR:-}" ] && { mkdir -p "$RUN_DIR/gt"; echo "$psk" > "$RUN_DIR/gt/psk.txt"; chmod 600 "$RUN_DIR/gt/psk.txt"; }
echo "wrote $d/swanctl/secrets.conf"
```
`staging-compose.yaml` + `scen-wire.sh`: compose starts each container with `network_mode: none`, `cap_add: [NET_ADMIN]`, `sysctls: {net.ipv4.ip_forward: 1}`, volumes `./swanctl/gw-a.conf:/etc/swanctl/conf.d/s1.conf:ro`, `./swanctl/secrets.conf:/etc/swanctl/conf.d/secrets.conf:ro`, `gt-gw-a:/gt`; `scen-wire.sh <container> <bridge> <ifname> <cidr> [gw]` creates a veth pair, puts one end in the container netns (`ip link set … netns $(docker inspect -f '{{.State.Pid}}' c)`), the other into the bridge (`veth-t01a` etc. — the `veth-*` names are what `guard_iface` and the manifest's `impairment.iface` use), assigns the address and default route inside. Topology and addresses are spec §11.1 verbatim. Document the wiring order in the compose file header.
- [ ] **Step 4: Run → pass. Commit** — `git add scenarios tests/scenarios-content.bats scripts/scenarios/scen-prep && ./tests/run.sh && git commit -m "scenarios: S0 baseline and S1 site-to-site over W1 (manifests, swanctl, traffic, events, staging compose)"`

---

### Task 12: `scen-check` — automated X-checks (D7)

**Files:** Create `scripts/scenarios/scen-check`; Test `tests/scen-check.bats`.

**Interfaces:** `scen-check <run-dir>` → runs the S1 checks against the run's files using `tshark -r` and writes `PASS`/`FAIL`/`SKIP` into the `Result` column of `<run-dir>/expected.md`, prints a summary, exit 0 iff no FAIL. Checks (each a function, selected by the manifest's `scenario`; S0 uses X4-inverse and X8 only):

| X | Command | Pass |
|---|---|---|
| X1 | `tshark -r outer-t01.pcapng -Y 'isakmp.exchangetype == 34' -T fields -e ip.src \| sort -u` | contains both gateway addresses from the manifest |
| X2 | `tshark -r outer-t01.pcapng -Y 'udp.port==4500' \| wc -l` | 0 (S1), >0 (S3) |
| X3 | `tshark -r outer-t01.pcapng -Y 'esp' \| wc -l` | >0 |
| X4 | `tshark -r outer-t01.pcapng -Y 'ip.addr==10.200.0.0/16' \| wc -l` | 0 (S0 inverse: >0) |
| X5 | `tshark -r outer-t01.pcapng -Y 'esp' -T fields -e esp.spi \| sort -u \| wc -l` | ≥ 4 (two SPIs per direction after ≥1 rekey) |
| X6 | isakmp frames with `frame.time_relative` ≥ traffic end − 40 s | >0 and none between t=30 and t=230 except CREATE_CHILD_SA (`exchangetype == 36`) |
| X7 | if `gt/gw-a/keys/esp_sa` exists: `tshark -r outer-t01.pcapng -o esp.enable_encryption_decode:TRUE -o "uat:esp_sa:$(…)"` decrypted 5-tuples ⊆ `inner-i01.pcapng` 5-tuples | SKIP when no keys |
| X8 | `grep -v ' 0 packets dropped' capture-stats.txt` | empty |
| X9 | manual (Arkime UI) — `SKIP` with note unless `SCEN_ARKIME_URL` and a token are set | — |

- [ ] Tests with a `tshark` stub that answers from `$S/tshark.<filter-hash>` files: "all PASS writes PASS into every Result cell and exits 0", "X4 non-zero marks FAIL and exits 1", "missing keys marks X7 SKIP not FAIL", "S0 run uses the inverse X4". Implement, pass, `git commit -m "scen-check: tshark-driven expected.md PASS/FAIL"`.

---

### Task 13: Documentation reflection

**Files:**
- Modify: `README.md` (rows), `docs/plans/r770-network-lab-buildout.md` §4.3 + §4.4, `docs/analyst-wiki/wan.md`, `state/BUILD-STATE.md`
- Create: `docs/analyst-wiki/scenarios.md`
- Test: `./tests/run.sh` (references.bats, owners.bats, lint)

- [ ] **Step 1: README "What's here"** — add rows after `scripts/r770-install-adapters.sh`:
```
| `scripts/scenarios/` | Reference-PCAP harness for the IPsec/WAN scenarios — `scen-prep` (gate + run dir), `scen-run` (captures → impairment → traffic → events → ground truth), `scen-check` (tshark X-checks → `expected.md`), `scen-ingest` (tagged Malcolm upload, never `gt/`), `scen-clear`, `scen-bridges.sh` (lab bridges until `lab-transit.sh`); ships in `site/`. Spec: `docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md` |
| `scenarios/` | Scenario content: `profiles/` (the one impairment-profile library, read by `wan-emu` and `wan-apply`), `S0/`, `S1/` … (manifest, swanctl config, traffic script, events, expected observations, staging compose) |
| `images/` | Lab container images built on staging by the fetch script's `labimages` stage: `ipsec-ss` (strongSwan endpoint, exports keys), `wan-emu` (in-topology impairment node), `svc-targets` (fixed HTTP/DNS) |
```
- [ ] **Step 2: Buildout §4.3** — add rows `| br-lab-iNN | Inner / protected-LAN segment of an IPsec scenario (upload-only to Malcolm, never mirrored) | No | none |` and `| br-lab-ext | Lane-C physical ingress: one Slot-4 port as member, untrusted | No | none |` with a sentence pointing at the spec §3. **§4.4** — append: *"Profile files are the library at `scenarios/profiles/*.conf` (format: `RATE_DOWN RATE_UP DELAY JITTER LOSS NOTE`, `tc` syntax); Phase 12's `wan-apply` reads them and installs a copy to the config repo; the in-topology `wan-emu` node reads the same files. New profiles (`lte-good`, `lte-poor`, `leo`, `mpls-metro`, `congested-uplink`) are defined there — see the IPsec scenario spec §6.2."*
- [ ] **Step 3: `docs/analyst-wiki/wan.md`** — add the five new profiles to the "Built-in profiles" table (values from Task 1) and a line linking `scenarios.md`. **Create `docs/analyst-wiki/scenarios.md`**: what a reference PCAP with ground truth is, where runs live (`/data/pcap/cases/<scenario>/<run-id>/`), how to find one in Arkime (tags `<run-id>-outer`/`-inner`), what `gt/` is and why it is not in Malcolm, the S-catalog table from spec §10 (IDs + one-line behaviors, no addresses), and "how to run one" = the four harness commands. No version numbers.
- [ ] **Step 4: `state/BUILD-STATE.md`** — add a section after "Phases":
```
## IPsec / simulated-WAN scenario track (sub-project; spec `docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md`, plan `docs/superpowers/plans/2026-10-07-ipsec-scenarios-plan.md`)

| # | Work | Depends on | Status | Evidence |
|---|---|---|---|---|
| IP0 | Spec filed; O1 collision check; O2 custom containers classified | — | **APPLIED** (spec filed 2026-10-07; O2 still open — operator) | spec §2 |
| IP1 | Images + harness built and unit-tested; probes O3/O4/O5/O9; bundle delta | IP0 | NOT STARTED | — |
| IP1b | Staging rehearsal: S0 + S1 under Compose, H1–H6, X1–X9 | IP1 | NOT STARTED | — |
| IP2 | R770 host prep (modules, R1 test, bridges) | Buildout 6, 7, 8, 11, 12 | BLOCKED (buildout) | — |
| IP3 | Harness validation H1–H6 on the R770 | IP2, buildout 10 | BLOCKED | — |
| IP4 | W1 → S1 `ss` → first reference set | IP3 | BLOCKED | — |
| IP5–IP9 | W2/W4 → S2/S3 · appliances → S4 · W3/W6 → S8/S9/S5 · lanes B/C → S6 · W5/W7 → S7 · `cases/INDEX.md` | IP4 | BLOCKED | — |
```
and a Log line: `- 2026-10-07 · Scenarios · IPsec/WAN scenario spec filed (v0.1.1, pins → owner refs, O1 collision check against known blocks clean) and the deploy-and-test plan written; nothing applied. · docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md`
- [ ] **Step 5: Run the whole suite staged** — `git add -A && ./tests/run.sh` → green (references.bats will fail on any path named in BUILD-STATE that does not exist yet — only name files that exist). Commit: `git commit -m "docs: README/buildout/wiki/BUILD-STATE reflect the IPsec scenario track"`.

---

# Part B — Staging rehearsal on VM 9771 (Compose, no GNS3)

Staging-side; operator-visible SSH and docker commands, run from the Claude session through `scripts/r770-staging-vm.sh` + SSH as in previous rehearsals. 9771 must be started (≥ 3 GiB host headroom rule in BUILD-STATE) and **nothing else may be working on it** (the 2026-09-25 lesson).

### Task 14: Probes O3, O4, O5, O9 → `state/inventory/ipsec-probes-<date>.md`

- [ ] **O3 — save-keys in noble packages:**
```bash
docker run --rm ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq strongswan-charon strongswan-swanctl libstrongswan-extra-plugins libcharon-extra-plugins >/dev/null && ls /usr/lib/ipsec/plugins/ | grep -i save; dpkg -l strongswan-charon | tail -1; /usr/lib/ipsec/charon --version 2>&1 | head -1'
```
Pass: `libstrongswan-save-keys.so` listed. **If absent:** build from the strongSwan source tarball (fetched to the bundle's `manual/` with its signature) in `ubuntu:24.04` with `./configure --enable-save-keys --enable-swanctl --enable-vici …` (copy the distro's `debian/rules` configure flags), package with `checkinstall`, drop the `.deb`s into `images/ipsec-ss/debs/` and switch the Dockerfile's install line — record the exact flags in the probe file and the pin review. Verify option names in `save-keys.conf` against `strongswan.conf(5)` of the installed version.
- [ ] **O4 — GNS3 Docker-node behavior:** deferred to Part C (needs the GNS3 server on the R770); record "deferred, Part C IP3" — the Compose rehearsal does not exercise it. What *is* recorded now: that `docker cp` of `/gt` works with the compose volume layout (Task 7c path).
- [ ] **O5 — containerized MPLS (optional for IP7):** `modprobe mpls_router mpls_iptunnel && docker run --rm --cap-add NET_ADMIN --sysctl net.mpls.platform_labels=1000 <frr image from gns3-node-images.tar.gz> vtysh -c 'show version' -c 'show mpls table'`. Pass: no sysctl error, `show mpls table` answers. Record either way; W3 falls back to CHR for P/PE if it fails.
- [ ] **O9 — CHR key visibility:** requires a QEMU boot of the CHR image; record "deferred to IP6 on the R770" unless the staging VM has nested virt to spare.
- [ ] Write `state/inventory/ipsec-probes-<date>.md` with the commands and verbatim output, disposition per probe. Commit.

### Task 15: Build images and run S0 then S1 end to end

- [ ] **Step 1: Build** — on 9771 with the repo checkout: `scripts/r770-offline-fetch.sh --only labimages` (needs the `gns3` stage's image tarball present for FRR/netshoot, or load them from the existing bundle on 9771: `docker load -i bundle-*/gns3/docker-nodes/gns3-node-images.tar.gz`). Confirm `docker images | grep '^lab/'` shows three.
- [ ] **Step 2: Bridges** — `sudo scripts/scenarios/scen-bridges.sh create br-lab-t01 br-lab-t02 br-lab-i01 br-lab-i02`. Check R1 right here (Docker's `FORWARD DROP` + `br_netfilter`): `sudo iptables -S FORWARD | head -3; lsmod | grep br_netfilter`. If `br_netfilter` is loaded and FORWARD policy is DROP, apply the scoped rule from spec §9.3 and record it: `sudo iptables -I DOCKER-USER -i br-lab-+ -o br-lab-+ -j ACCEPT`.
- [ ] **Step 3: Stub `wan-apply`/`wan-show`/`wan-clear`** for the rehearsal — Phase 12 does not exist: write `/usr/local/bin/wan-apply` as a 15-line bash wrapper over `profile_load` + the same `tc` lines `wan-emu.sh` emits (`shape <iface> <rate>`), `wan-show` = `tc qdisc show | grep -E 'netem|htb'`, `wan-clear` = `tc qdisc del dev $1 root`. Note in the evidence that this is the rehearsal stand-in and that Phase 12 owns the real one.
- [ ] **Step 4: S0** — `cd scenarios/S0 && docker compose -f ../S1/staging-compose.yaml up -d isp1 host-a host-b svc-b gw-a gw-b` with `gw-*` running plain routing (no swanctl config mounted: use the compose `profiles:` feature — `s0` profile mounts nothing). Wire with `scen-wire.sh` per the compose header. Plain-transport validation (spec §4): `docker exec host-a ping -c 20 198.18.2.2`, `traceroute -n 198.18.2.2`, `ping -M do -s 1472 -c 5 198.18.2.2`, `iperf3 -c 10.200.2.10 -t 20` (S0 has site-to-site routing on purpose — it's the plaintext baseline). Record RTT into `S1/run.yaml`'s `baseline.rtt_ms`. Then `sudo scen-prep scenarios/S0 && sudo scen-run <dir>/run.yaml && sudo scen-check <dir>` → X4-inverse and X8 PASS. **H1:** during the run also `tcpdump -i veth-t01a -c 20 icmp` and compare counts with the bridge capture. **H2:** inner and outer files both contain the same ICMP ids with monotonically consistent timestamps (`tshark -T fields -e frame.time_epoch -e icmp.seq`).
- [ ] **Step 5: S1** — `scenarios/S1/gen-secrets.sh scenarios/S1`; `docker compose … --profile s1 up -d` (gw-a/gw-b with swanctl mounts; gw-b first, gw-a last so IKE_SA_INIT lands after captures start — or start both with `trap` and let traffic trigger). `sudo scen-prep --images <lab-images.list> scenarios/S1 && sudo scen-run <dir>/run.yaml` (280 s). Then `sudo scen-check <dir>` → X1–X8. **H3** = X8. **H6:** repeat `scen-run` and `kill -TERM` it at t≈30 s: `pgrep tcpdump` empty, `wan-show` empty, `events.log` ends `aborted`. **H5:** `sudo scen-clear <dir>/run.yaml` → `RTT OK`.
- [ ] **Step 6: Ingest (H4, X9)** — `sudo scen-ingest <dir>` (Malcolm is deployed on 9771); wait for Malcolm's upload processing; in Arkime search `tags == S1-W1-ss-*-outer` → sessions are IKE/ESP only; `tags == *-inner` → the iperf3/HTTP/DNS flows; confirm no file from `gt/` reached the upload dir (`ls <upload-dir>`). Record the tag-rule finding (D7/Task 8) — adjust `scen-ingest` if Malcolm parsed the filename differently.
- [ ] **Step 7: Teardown** — `docker compose down -v`, `scen-bridges.sh destroy …`, remove the stand-in `wan-*` wrappers and the `DOCKER-USER` rule if added, `wan-show` empty. Keep the run dirs on 9771 for inspection; copy `run.yaml`, `expected.md`, `capture-stats.txt`, `events.log`, `sha256sums` (never `gt/`, never PCAPs) into `state/inventory/staging-ipsec-rehearsal-<date>/`.

### Task 16: Evidence and tracker

- [ ] Write `state/inventory/staging-ipsec-rehearsal-<date>.md`: commands, verbatim results of H1–H6 and X1–X9, defects found and their commits, the R1 finding, the Malcolm tag-rule finding, O3 disposition. Update BUILD-STATE IP1 → APPLIED/VERIFIED, IP1b → VERIFIED with the evidence path; log line. Any image/harness fix found here goes back through Part A's tests first (red → green → commit) — no untested hotfix on the VM. `git add -A && ./tests/run.sh && git commit`.

---

# Part C — R770 deployment and scenario rollout (gated)

**Entry condition for all of Part C:** buildout Phases 6 (Docker), 7 (bridges/libvirt), 8 (GNS3), 10 (Malcolm), 11 (mirror feed), 12 (`wan-apply`) show APPLIED or VERIFIED in `state/BUILD-STATE.md`, and the bundle on the R770 contains `gns3/docker-nodes/lab-images.tar.gz` and `site/scripts/scenarios/`. Every block below is executed with `/phase`-style output and the `safety-reviewer` agent for anything touching modules, iptables or Netplan; `validation-runner` after each.

### IP2 — Host preparation (spec §9)

```
## Phase: IP2 host prep
### Current State   — lsmod | grep -E 'xfrm_user|xfrm_interface|esp4|br_netfilter'; iptables -S FORWARD; ls /sys/class/net | grep br-lab; wan-show
### Proposed Design — /etc/modules-load.d/ipsec-lab.conf (xfrm_user xfrm_interface esp4 esp6; mpls_* only if O5 passed); scoped DOCKER-USER accept for br-lab-+ ↔ br-lab-+ only if the R1 test drops frames; bridges via lab-transit.sh (or scen-bridges.sh if Phase 7 did not ship it — then file the fold-in task)
### Changes         — one file, one optional iptables rule (persisted with the Phase-4 firewall config), bridges
### Commands        — sudo install -m 644 site/scenarios/host/ipsec-lab.conf /etc/modules-load.d/ · sudo systemctl restart systemd-modules-load · R1 test: two netshoot containers on br-lab-t01 ping each other with/without the rule · sudo lab-transit.sh create t01 t02 i01 i02 · mirror-on.sh br-lab-t01 br-lab-t02 (outer only!)
### Risks           — none to management; iptables rule is scoped to br-lab-+ on both sides (never -i any); modules are additive
### Validation      — lsmod shows the four modules; ping across br-lab-t01 between two containers succeeds; `wan-show` empty; `ip -br addr show br-lab-i01` has no address; mirror0 sees br-lab-t01 frames and not br-lab-i01 frames (tcpdump -i mirror0 -c 5 while pinging on each)
### Rollback        — rm the modules file; iptables -D the rule; lab-transit.sh destroy; mirror-off.sh
### Status          — APPLIED → VERIFIED with state/inventory/ip2-host-prep-<date>.md
```
Add `scenarios/host/ipsec-lab.conf` (spec §9.1 verbatim) to the repo in this step (it travels in `site/`).

### IP3 — Harness validation H1–H6 on the R770 (spec §13) + O4/O6

- Load images: `docker load -i <bundle>/gns3/docker-nodes/lab-images.tar.gz`; register the three as GNS3 Docker templates (web UI or API) with `start_command` empty, `console_type: none`, two adapters for `gw-*`/`wan-emu`, one for `svc-targets`; persistent volume `/gt` per the GNS3 v3 docs in the bundle's docs mirror. **O4 is closed here:** `docker inspect` a running `gw-a` node → record CapAdd, sysctls, mounts, the container name pattern, and whether `/gt` persists under the project directory; try the link-suspend API from the bundled v3 API docs and record the endpoint or "absent".
- Build the W1 project (`s0-w1`) in GNS3 with four Cloud nodes on `br-lab-t01/t02/i01/i02` per spec §11.1. Plain-transport validation as in Task 15 Step 4, from the GNS3 netshoot nodes.
- Run S0 with the harness exactly as Task 15 Step 4 (the `scen-*` commands are identical; only the GNS3 project start/stop is manual). H1–H6 per Task 15; H4 via the R770's Malcolm. **O6:** after ingest, record what Arkime shows for IKE (protocol field, any parsed exchange types), what Zeek logged (`conn.log` proto 50 entries, no ike analyzer unless present) and whether the Suricata-off decision leaves an IKE gap — goes into `expected.md` wording for S2+.
- Exit: `state/inventory/ip3-harness-validation-<date>.md` with H1–H6 PASS, O4 and O6 dispositions; BUILD-STATE IP3 → VERIFIED.

### IP4 — W1 → S1 `ss` → first reference set (spec §11.2)

- Project `s1-w1-ss`: W1 plus `gw-a`/`gw-b` as `ipsec-ss` nodes with `scenarios/S1/swanctl/*` mounted (GNS3 extra-volume or baked via a per-run derived image — whichever O4 found works; the run manifest's `gns3_project` names it). `gen-secrets.sh` with `RUN_DIR` set so `gt/psk.txt` is recorded.
- Procedure: spec §11.2 steps 1–4 using `scen-prep --images … → scen-run → scen-check → scen-clear → scen-ingest`. Captures start before `gw-a`'s node is started (start the project with `gw-a` stopped; start it after `scen-run` prints `captures up`).
- Pass: `expected.md` X1–X9 PASS (X7 requires O3 PASS; otherwise X7 = SKIP and the run is a reference set *without decryption keys*, say so in `results.notes`). Copy the run's `expected.md`, `run.yaml`, `capture-stats.txt`, `events.log`, `sha256sums` to `state/inventory/ip4-s1-reference-<date>/`; BUILD-STATE IP4 → VERIFIED. Create `/data/pcap/cases/INDEX.md` with its first row.

### IP5–IP9 — Rollout table

Each row is one `/phase`-style block; the per-scenario `expected.md` (written into `scenarios/<S>/expected.md` as a Part-A-style task before the run, with `scen-check` functions added test-first) is the validation. Underlay validation (spec §4 block) precedes every overlay run and its output goes into `scenarios/<W>/README.md` + the evidence file.

| Step | Build | Validate | Exit evidence |
|---|---|---|---|
| IP5a | W2 (2–3 FRR ASes, eBGP, default toward sites) GNS3 fragment; `wan-emu` nodes on inter-AS links | plain transport + `vtysh -c 'show bgp summary'` Established on all; `rp_filter` noted | `ip5-w2-<date>.md` |
| IP5b | S2 route-based: `ipsec-ss` + XFRM interface (`xfrm_interface` module, `if_id`) + FRR in the gateway image? — **no**: keep `ipsec-ss` single-purpose; add a `site-rtr` FRR node behind each gateway and run BGP over the tunnel between them | X-checks: BGP session inside ESP (inner capture shows TCP/179; outer shows only ESP), route withdrawal on tunnel loss event | `ip5-s2-<date>.md` |
| IP5c | W4 CGNAT (CHR NAT44 or OPNsense) + S3 | NAT_DETECTION_*_IP notify present, switch to UDP 4500, keepalives at the configured interval, mapping expiry when keepalive > NAT timeout (two runs) | `ip5-s3-<date>.md` |
| IP6 | Appliance variants `vy`/`op`/`mt` of S1–S3; S4 F1–F7 one run each | per-F expected notify (spec §10 table) via `tshark -Y 'isakmp.notify.msgtype == <n>'`; SA dumps collected per §8.4 (VyOS/OPNsense/CHR commands); O9 closed | `ip6-interop-matrix-<date>.md` |
| IP7 | W3 (CHR P/PE or FRR if O5), W6 dual transport; S8, S9, S5 | S8: unlabeled ESP at CE–PE, labeled ESP in core capture (O6 decode noted); S9: failover/failback timing from `events.log` vs first ESP on the backup path; S5: DPD failover to hub 2 | `ip7-*-<date>.md` |
| IP8 | Lane B1 (`tcprewrite` into 10.200.x then replay on `br-lab-iNN` veth) and B2 (replay to a capture feed); Lane C `br-lab-ext` Netplan change (`optional: true`, port from O7, `netplan try`, guard-listed) → S6, S1-C | B1: replayed flows appear as ESP outer / plaintext inner; B2: Malcolm sees them untouched; C: external peer forms SA; **Netplan step is gated (CLAUDE.md rule 2/3, safety-reviewer)** | `ip8-*-<date>.md` |
| IP9 | W5 (satellite/leo + handover events), W7 (congested-uplink + background iperf3) → S7; curate `cases/INDEX.md` | DPD false positives counted, rekey under loss, F7 MTU black hole with/without DF, ESP throughput vs cap | `ip9-s7-<date>.md`, `cases/INDEX.md` |

BUILD-STATE's scenario-track table advances one row per completed step, with the evidence path; `scenarios/README.md` gains a "status" line pointing at BUILD-STATE rather than restating it.

---

## Self-review (done while writing)

- **Spec coverage:** §0 principles → Global Constraints; §1 layer model → Part C rollout; §2 open items → O1 (filed spec), O2 (operator, IP0 row), O3/O5 (Task 14), O4/O6 (IP3), O7 (IP8), O8/R1 (Task 15 Step 2, IP2), O9 (Task 14/IP6), O10 (Task 5); §3 addressing → Task 11 content, buildout §4.3 (Task 13); §4 underlays → IP3 (W1), IP5/IP7/IP9 (W2–W7); §5 endpoints/helpers/bundle/secrets → Tasks 2–5, 11; §6 impairment → Tasks 1, 2, Part B stand-in, Phase 12 handoff; §7 lanes → Task 11 (A), IP8 (B, C); §8 harness → Tasks 6–9, 12; §9 host prep → IP2; §10/§11 catalog + templates → Task 11, IP4–IP9; §12 risks → R1 (IP2), R2 (IP2 validation), R3 (H1), R4 (IP2 mirror-on outer only), R5 (Task 8), R6 (Task 6), R7 (IP8), R8 (IP5–IP9 MTU rows), R9 (Task 7c host load); §13 H1–H6 → Task 15, IP3; §14 build order → BUILD-STATE track table.
- **Gap found and fixed:** the spec had no automated pass/fail for X-checks — D7/Task 12. The spec's `traffic:` block lacked which node runs the script — `traffic.node` added (Task 11, Task 7a). Spec §8.3 named a Malcolm `pcapimport` path that does not exist in this build — corrected in the filed spec and Task 8.
- **Type consistency:** `profile_load`/`P_*`, `guard_iface`, `manifest_get`/`manifest_list`, `run_dir_for`, `log`/`SCEN_LOG`, `APPLIED`, `SCEN_CASES`/`SCEN_PROFILES`/`SCEN_SYSNET`/`SCEN_MODULES_FILE`/`SCEN_UPLOAD_DIR`/`SCEN_EXEC`/`SCEN_CP` are used with the same names in every task. Veth naming `veth-t01a` is consistent between `guard_iface`, the manifest fixture, `scen-wire.sh` and the staging steps.
- **Placeholders:** none of the forbidden phrases; the `*-<date>.md` evidence names are the repo's documented naming-template form (skipped by `references.bats`).

---

## Execution notes

- Part A is ~13 commits of bash + bats; nothing in it touches a real host. Part B needs VM 9771 started and idle, plus operator awareness that this session owns it for the duration. Part C waits on buildout 6–12 and is operator-gated at IP2 (modules/iptables) and IP8 (Netplan).
- Run the new bats suites once as `nobody` before opening the PR.
