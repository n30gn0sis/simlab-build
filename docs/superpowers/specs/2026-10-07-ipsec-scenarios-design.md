# R770 Lab — IPsec & Simulated WAN Scenario Specification

**Version:** v0.1.5 (DRAFT — design only, nothing applied; **filed in repo 2026-10-07**, see Change Log)
**Date:** 2026-09-24
**Status:** NOT STARTED — depends on buildout Phases 6, 7, 8, 10, 11, 12 (see §14); all six are NOT STARTED on the R770 per `state/BUILD-STATE.md`, so IP2 onward is gated on them. The plan that implements this spec is `docs/superpowers/plans/2026-10-07-ipsec-scenarios-plan.md`.
**Pins:** every version this spec needs (FRR image, GNS3 server, CHR, OPNsense) is owned by the pin block in `scripts/r770-offline-fetch.sh` — this document names the component and never the number (`OWNERS.md`).
**Companion specs:** `lab-fabric.md` v0.2 (bridge map, address plan, T-* templates, `lab-transit.sh`) · `r770-network-lab-buildout.md` §4.3, §4.4, §6, §7 · analyst wiki `wan.md`, `cli-tools.md` · `r770-offline-supply.md`
**Purpose:** Produce repeatable GNS3 scenarios that push traffic *through* simulated WAN underlays and *into* IPsec endpoints, and yield **reference PCAPs with ground truth** for Malcolm analysis and scenario testing.

---

## 0. Design Principles

1. **Layered, swappable scenarios.** Every run = *site template × WAN underlay × IPsec overlay × traffic lane × impairment profile × event script*. Change one layer without rebuilding the others.
2. **A PCAP without ground truth is not a reference PCAP.** Every run ships a manifest, SA/key dumps (where obtainable), event timestamps, gateway logs, and checksums alongside the captures.
3. **Two views, one clock.** Each run captures the *outer* (transit/WAN) and *inner* (protected LAN) sides simultaneously on the same host, so timestamps align exactly.
4. **Underlay before overlay.** Every WAN underlay is validated as plain routed transport before any IPsec rides on it.
5. **Containers first, appliances second.** strongSwan containers iterate fast and are the only source of decryption keys; appliance variants (VyOS, OPNsense, CHR) follow once the harness is proven.
6. **One profile library, three mechanisms.** Impairment profiles are defined once (`profiles/*.conf`) and applied by host `wan-apply`, the in-GNS3 `wan-emu` node, or (ad hoc only) GNS3 link filters — the manifest records which.
7. **Air-gap rules apply unchanged.** Every image, deb, and appliance arrives via the bundle; secrets and key material never enter Git.
8. **Free platforms only in v0.1.** VyOS, OPNsense, MikroTik CHR, strongSwan, FRR, plus custom containers. Cisco is out of scope for this revision.

---

## 1. Layer Model

```text
 ┌──────────────────────────────────────────────────────────────────────┐
 │ TRAFFIC LANES   A: generated (netshoot/iperf3/HTTP/DNS)              │
 │                 B: replay (tcpreplay/tcprewrite)                     │
 │                 C: external physical devices (Slot-4 port)           │
 ├──────────────────────────────────────────────────────────────────────┤
 │ SITES           protected LANs behind each gateway (T-LAN/T-DIST/…)  │  ← INNER capture (br-lab-iNN)
 ├──────────────────────────────────────────────────────────────────────┤
 │ IPsec OVERLAY   strongSwan / custom containers / VyOS / OPNsense /   │
 │                 CHR — policy-based, route-based, remote access       │
 ├──────────────────────────────────────────────────────────────────────┤
 │ WAN UNDERLAY    W1 single ISP · W2 multi-ISP BGP · W3 MPLS L3VPN ·   │  ← OUTER capture (br-lab-tNN → mirror0)
 │                 W4 CGNAT/mobile · W5 satellite · W6 dual transport · │
 │                 W7 congested/asymmetric                               │
 ├──────────────────────────────────────────────────────────────────────┤
 │ IMPAIRMENT      M1 host wan-apply · M2 wan-emu node · M3 link filter │
 │ EVENTS          timed flaps, brownouts, withdrawals, failovers       │
 └──────────────────────────────────────────────────────────────────────┘
```

**Key constraint (drives the whole design):** GNS3 node-to-node links are ubridge UDP tunnels, not Linux bridges. Traffic on a plain GNS3 link never touches a host bridge, so it is invisible to `mirror0`/Malcolm and cannot be shaped by host `wan-apply`. Any segment that must be **captured** or **host-impaired** is routed through GNS3 Cloud nodes attached to a host bridge (`br-lab-tNN` outer, `br-lab-iNN` inner) created by `lab-transit.sh`.

---

## 2. Open Items and Dependencies

| ID | Item | Blocks | Resolution path |
|---|---|---|---|
| O1 | `lab-fabric.md` v0.2 not filed in project/repo (it is not in this repo as of 2026-10-07); its address-collision check is still open | Final addressing (§3) | File it; reconcile §3 provisional blocks against it. **Collision check against the known real blocks done 2026-10-07:** 198.18.0.0/15, 100.64.0.0/10, 10.200.0.0/16, 10.201.0.0/16 overlap none of 10.10.10.0/24 (R770 mgmt), 192.168.76.0/24 (iDRAC), 192.168.4.0/22 (staging LAN). Remaining: reconcile against `lab-fabric.md`'s own 10.100.0.0/16 and `br-lab-mgmt`/`br-lab-nat` once filed |
| O2 | "Custom containers" not yet defined (own IKE implementations? strongSwan wrappers such as brobrobro spoof clients? non-IPsec helpers?) | §5.3 scope | Operator to define; each custom node is classified E (endpoint contract §5.2) or H (helper, §5.4) |
| O3 | Is strongSwan's `save-keys` plugin compiled into the noble packages? | Key ground truth (§8.4) | On staging: check the loaded plugin list; if absent, source-build strongSwan with `--enable-save-keys` and package via `checkinstall`/`fpm` (same path as `ubridge`) |
| O4 | gns3-server (bundled pin) Docker-node behavior: privileges actually granted, container naming, persistent/extra volumes, interface attach timing, link-suspend API | §5.2, §8, §9 | Verify on staging with `docker inspect` of a running GNS3 node and the v3 API docs in the bundle |
| O5 | Containerized MPLS (FRR LDP + BGP VPNv4) feasibility | W3 container variant | Staging test: host `mpls_router`/`mpls_iptunnel` modules + per-netns `net.mpls.*` sysctls; fallback is CHR for P/PE roles |
| O6 | Malcolm decode coverage for IKE (Suricata is shipped but off) and MPLS encapsulation | Expected-observation wording | Test with a known PCAP during IP3; record what each component (Arkime, Zeek, Suricata-if-enabled) shows |
| O7 | Which Slot-4 port (and its kernel name) serves lane C | §7.3 | Pick from discovery inventory; Slot-4 is already reserved for physical lab links |
| O8 | Docker + `br_netfilter` may drop bridged lab traffic (see §12, R1) | Any bridged segment after Phase 6 | Verify after Docker install; apply scoped `DOCKER-USER` accept rule if needed |
| O9 | CHR `installed-sa` key visibility on the bundled CHR pin (the draft said an older release; the fetch script's pin is newer — probe the pinned one) | Appliance key ground truth | Verify on staging; if visible, capture into ground truth like save-keys output |
| O10 | Bundle delta (images/debs listed in §5.5) | IP1 | Add to next bundle cut; pin and record per pin policy |

---

## 3. Addressing and Naming (PROVISIONAL until O1 closes)

| Space | Block | Use |
|---|---|---|
| Simulated "public" internet | **198.18.0.0/15** (RFC 2544 benchmarking) | ISP cores, CE uplinks, public-facing gateway addresses — looks public in PCAPs, collides with nothing real |
| CGNAT | **100.64.0.0/10** (RFC 6598) | W4 subscriber side |
| Site protected LANs | 10.200.0.0/16 *(provisional)* | 10.200.<site>.0/24 per site |
| Provider infrastructure | 10.201.0.0/16 *(provisional)* | Provider loopbacks, P–P and P–PE links, tunnel interface addressing |
| Provider ASNs | 64512–65534 (or 4200000000+) | Private ASNs only |
| Host bridges | per `lab-fabric.md` (10.100.0.0/16 for bridges that carry host IPs) | Transit/inner bridges carry **no** host IP |

**Access-link convention (W1/W2/W4):** site *n* uplink = 198.18.*n*.0/30 (ISP side `.1`, CE side `.2`).

**Bridge naming:**

| Bridge | Role | Captured | Mirrored to `mirror0` |
|---|---|---|---|
| `br-lab-tNN` | Outer / WAN segment (existing fabric convention) | Yes (harness) | Yes (live Malcolm) |
| `br-lab-iNN` | Inner / protected LAN segment (**new name — reconcile with `lab-fabric.md`**) | Yes (harness) | **No** — ingested by upload with an `-inner` tag, so live Malcolm sessions are not doubled |
| `br-lab-ext` | Lane C physical ingress (Slot-4 port member, no host IP) | Yes | Optional |

**Run ID scheme:** `<scenario>-<underlay>-<variant>-<UTC yyyymmddThhmmZ>` — e.g. `S1-W1-ss-20261001T1400Z` (`ss` = strongSwan variant, `vy` = VyOS, `op` = OPNsense, `mt` = CHR, `mx` = mixed).

---

## 4. WAN Underlay Catalog

Each underlay is a GNS3 project fragment that exposes two or more **CE attachment points**. Provider cores use FRR containers (the bundled `quay.io/frrouting/frr` image — pin in `scripts/r770-offline-fetch.sh`) unless the role needs vendor behavior. Every underlay passes its **plain-transport validation** before overlay use.

### W1 — Single-ISP internet *(worked example in §10)*
- **Shape:** CE-A ─ ISP1 ─ CE-B. ISP1 = FRR container, static routes only.
- **Capture:** both access links on `br-lab-t01` / `br-lab-t02`.
- **Impairment:** M1 on access links.
- **Used by:** S0, S1, S6 (with W4).

### W2 — Multi-ISP internet core
- **Shape:** 2–3 provider ASes (FRR), eBGP between them plus a small exchange segment; each site homes to one ISP; default route toward the sites.
- **Behavior exercised:** asymmetric paths, route withdrawal mid-run, BGP convergence under the overlay.
- **Capture:** access links (outer); optional one inter-AS link for path-asymmetry references.
- **Impairment:** M2 `wan-emu` on inter-AS links, M1 on access links.
- **Note:** check `rp_filter` inside router containers; asymmetric paths can be dropped by strict reverse-path filtering.

### W3 — MPLS L3VPN provider
- **Shape:** CE ─ PE ─ P ─ P ─ PE ─ CE; LDP in the core, BGP VPNv4 between PEs, per-customer VRF.
- **Platform:** CHR for P/PE (mature MPLS) or FRR containers if O5 passes.
- **Behavior exercised:** IPsec over a provider VPN (the common "encrypt over carrier transport" pattern); MPLS-labeled ESP inside the core.
- **Capture:** CE–PE access links (unlabeled ESP) **and** one P–P core link (labeled ESP) — the core capture is a distinctive reference set; decode support per O6.
- **MTU:** label stack (4–8 bytes) + ESP overhead — see S7 MTU cases.

### W4 — CGNAT / mobile access
- **Shape:** subscriber CE on 100.64.0.0/10 ─ CGN router (CHR or OPNsense; NAT44) ─ W2 core ─ gateway.
- **Behavior exercised:** NAT-T (UDP 4500 encapsulation, NAT keepalives), NAT mapping timeouts vs. keepalive interval.
- **Impairment:** `lte-good` / `lte-poor` profiles (§6.2) on the subscriber access link.
- **Used by:** S3, S6.

### W5 — Satellite / high-latency
- **Shape:** W1 or W2 with one access link carrying `satellite` (GEO) or `leo` profile.
- **Behavior exercised:** DPD timer interaction, rekey under long RTT, TCP inside the tunnel. LEO handover spikes are modeled as **events** (§8.5), not static netem.
- **Used by:** S7.

### W6 — Dual transport
- **Shape:** each site has an MPLS path (W3) and an internet path (W2 or W4). Route-based tunnels over both; BGP (or static + tracking) prefers MPLS, fails over to internet.
- **Behavior exercised:** SD-WAN-like failover built from primitives; tunnel-per-transport; asymmetric return paths during failover.
- **Used by:** S5 (optional), S9.

### W7 — Congested / asymmetric uplink
- **Shape:** W1 access link with HTB contention and background flows; asymmetric up/down rates; policing vs. shaping variants.
- **Behavior exercised:** ESP overhead against a rate cap, queueing delay, loss under contention.
- **Used by:** S7.

**Plain-transport validation (every underlay):**
```bash
# From a site host (netshoot) to the far CE's public address and far-site LAN
ping -c 20 <far-CE-public>            # reachability, baseline RTT recorded
traceroute -n <far-CE-public>         # expected provider hops present
ping -M do -s 1472 -c 5 <far-CE-public>   # 1500-byte path MTU (adjust per underlay; W3 core may differ)
iperf3 -c <far-host> -t 20            # baseline throughput recorded to the underlay's README
# W2/W3/W6: routing-protocol state from each provider node (vtysh -c 'show bgp summary', etc.)
```

---

## 5. IPsec Endpoints

### 5.1 Families

| Family | Platforms | Strength | Ground truth available |
|---|---|---|---|
| Containers | strongSwan (`swanctl`), custom (O2) | Fast, scriptable, key export | SA dumps + **ESP/IKE keys** (save-keys, O3) |
| Appliances | VyOS, OPNsense, CHR (bundled pins) | Realistic vendor behavior (proposals, DPD, rekey patterns) | SA dumps via CLI; CHR possibly keys (O9); inner capture is the plaintext truth |

### 5.2 Endpoint container contract (applies to strongSwan and any custom IPsec endpoint)

| # | Requirement |
|---|---|
| E1 | Built on staging from `ubuntu:24.04` (matches wheelhouse rule), pinned package versions, SBOM via the bundle pipeline |
| E2 | Configuration is mounted, never baked: `/etc/swanctl/conf.d/` from the scenario folder; secrets generated per run (§5.6) |
| E3 | Minimum privilege: runs with `NET_ADMIN` + `net.ipv4.ip_forward=1` (via `--sysctl`) outside GNS3. GNS3 may grant more (O4) — the contract states the floor so the same image also runs under Compose |
| E4 | Entrypoint waits for the expected interfaces (`WAIT_IFACES="eth0 eth1"`, timeout) before starting `charon` — GNS3 may attach interfaces after container start |
| E5 | Healthcheck: `swanctl --list-sas` returns an INSTALLED CHILD_SA for the scenario's child name |
| E6 | Ground-truth outputs written to a single directory (`/gt`): save-keys files, periodic SA dumps, charon log — collected by the harness (§8.4) |
| E7 | No kernel-module loading from inside the container — the host preloads (§9.1) |

**Dockerfile sketch (`images/ipsec-ss/Dockerfile`):**
```dockerfile
FROM ubuntu:24.04
# Staging-only build; pin versions at bundle cut and record them in the pin review
RUN apt-get update && apt-get install -y --no-install-recommends \
      strongswan-charon strongswan-swanctl libstrongswan-extra-plugins \
      iproute2 iputils-ping tcpdump ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# If O3 shows save-keys is not in the noble build, replace the strongSwan packages
# above with the locally built .debs (--enable-save-keys) from the staging build step.
COPY strongswan.d/save-keys.conf /etc/strongswan.d/charon/save-keys.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
HEALTHCHECK --interval=10s CMD swanctl --list-sas --noblock >/dev/null 2>&1 || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**`strongswan.d/save-keys.conf` (option names to be verified against the built version, O3):**
```text
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

**`entrypoint.sh` sketch:**
```sh
#!/bin/sh
set -eu
: "${WAIT_IFACES:=eth0 eth1}" "${WAIT_SECS:=60}"
mkdir -p /gt/keys /gt/sa
for i in $WAIT_IFACES; do
  n=0; until ip link show "$i" >/dev/null 2>&1; do
    n=$((n+1)); [ "$n" -ge "$WAIT_SECS" ] && { echo "iface $i missing" >&2; exit 1; }; sleep 1
  done
done
/usr/lib/ipsec/charon >/gt/charon.log 2>&1 &
sleep 2
swanctl --load-all
# periodic SA snapshots for ground truth (SPI history across rekeys)
( while :; do swanctl --list-sas > "/gt/sa/$(date -u +%Y%m%dT%H%M%SZ).txt"; sleep 5; done ) &
wait
```

### 5.3 Custom containers (pending O2)
Each custom node is classified before it enters a scenario:
- **Class E (endpoint):** terminates or originates IKE/ESP → must satisfy E1–E7; if it cannot export keys, its runs rely on inner capture as plaintext truth.
- **Class H (helper):** traffic generators, service targets, `wan-emu`, NAT boxes → §5.4 base, no IPsec requirements.

### 5.4 Helper images
| Image | Base | Role |
|---|---|---|
| `wan-emu` | `ubuntu:24.04` + iproute2 | Two-interface L2 bump-in-the-wire (`br0` over `eth0`/`eth1` inside its netns); applies the **same** `profiles/*.conf` as host `wan-apply`: egress on `eth1` shapes A→B, egress on `eth0` shapes B→A (asymmetry without IFB). `NET_ADMIN` only |
| netshoot | already bundled | Traffic lane A client/server (iperf3, curl, dig, tcpdump) |
| `svc-targets` | `ubuntu:24.04` or Alpine | nginx + dnsmasq with fixed content, so HTTP/DNS flows are identical run to run |
| FRR | `quay.io/frrouting/frr` (bundled, pin in the fetch script) | Provider routing, site routers behind gateways |

### 5.5 Bundle delta (O10)
`ipsec-ss` image (and source-built strongSwan debs if O3 requires) · `wan-emu` · `svc-targets` · custom container images (O2) · confirm `tcpreplay` deb (already in the dependency manifest; provides `tcprewrite`) · confirm VyOS / OPNsense / CHR appliance files present (the current bundle named in `state/BUILD-STATE.md` carries all eight appliance files).

### 5.6 Secrets and PKI
- **PSKs:** generated per run into a gitignored `secrets.conf` from a run-local value; recorded in the run's ground truth (lab-only), never committed.
- **Certificates (S6, cert-auth variants of S1–S5):** a **dedicated IPsec lab CA**, created with strongSwan's `pki` tool — **not** the `portal.lab` easy-rsa CA, so expiry/revocation scenarios cannot disturb portal trust. Short-lived leaf certs; custody of the IPsec CA key recorded in `inventory/` alongside the portal CA entry (location only).

---

## 6. Impairment

### 6.1 Mechanisms

| ID | Mechanism | Where | Rate limiting | Reproducible for reference runs | Notes |
|---|---|---|---|---|---|
| M1 | Host `wan-apply` (buildout Phase 12) | `br-lab-tNN` ports | Yes (HTB) | Yes | Only on bridge-attached segments; guard list protects mgmt bond and capture ports |
| M2 | `wan-emu` node | Any internal GNS3 link | Yes (HTB inside node) | Yes | Costs no host bridge; profile + node name go in the manifest |
| M3 | GNS3 link filters (ubridge) | Any GNS3 link | **No** (delay, jitter, loss, corrupt, BPF only) | Weak | Ad hoc exploration only — not used for reference runs |

Direction rule (from `wan.md`): netem shapes **egress**. A "40 ms link" is 40 ms on one side (one direction) or 20 ms on each; the manifest records per-direction values.

### 6.2 Profile library additions (starting values — tune against measurements)

| Profile | Down / Up | Delay | Jitter | Loss | Intended underlay |
|---|---|---|---|---|---|
| `branch-wan` *(existing)* | 20 Mbps | 40 ms | 5 ms | 0.2% | W1/W2 |
| `satellite` *(existing)* | 25 Mbps | 600 ms RTT-equiv. | variable | — | W5 |
| `poor-broadband` *(existing)* | 10 Mbps | 80 ms | — | 2% | W1/W4 |
| `asym-adsl` *(existing)* | asymmetric | | | | W7 |
| `lte-good` *(new)* | 30 / 10 Mbps | 45 ms | 10 ms | 0.3% | W4 |
| `lte-poor` *(new)* | 5 / 1 Mbps | 90 ms | 30 ms | 2% | W4 |
| `leo` *(new)* | 100 / 15 Mbps | 30 ms | 10 ms | 0.5% | W5 (+ handover events) |
| `mpls-metro` *(new)* | 100 Mbps | 5 ms | 1 ms | 0% | W3 access |
| `congested-uplink` *(new)* | 50 Mbps shared (HTB, background flows) | queue-driven | queue-driven | queue-driven | W7 |

---

## 7. Traffic Lanes

### 7.1 Lane A — generated
netshoot clients and `svc-targets` behind each gateway. Each scenario ships a **traffic script** with a fixed seed and duration, e.g.:
```bash
# traffic/profile-basic.sh  (runs in the site-A netshoot node)
iperf3 -c 10.200.2.10 -t 60 -P 2          # bulk TCP
iperf3 -c 10.200.2.10 -u -b 5M -t 30      # UDP at fixed rate
for i in $(seq 1 50); do curl -s http://10.200.2.20/fixed.bin >/dev/null; done
for i in $(seq 1 50); do dig @10.200.2.20 host$i.site-b.lab +short >/dev/null; done
```

### 7.2 Lane B — replay
Two distinct uses; never confuse them:

| Use | Injected where | Result |
|---|---|---|
| **B1 — encrypt replayed traffic** | Host veth on the **inner** bridge (`br-lab-iNN`), via GNS3 Cloud node | Gateways encrypt it; outer capture shows ESP carrying replayed flows |
| **B2 — analysis-only replay** | A capture feed / `mirror0` | Malcolm sees the PCAP as-is; no IPsec involvement |

- B1 requires `tcprewrite` first: rewrite source/destination IPs into the scenario's protected subnets and fix MACs, or the packets will not match the CHILD_SA traffic selectors and will be forwarded in clear or dropped.
- Replaying **captured ESP** through live endpoints never works (no matching SAs; anti-replay). Captured ESP is B2 only.

### 7.3 Lane C — external physical devices
- One Slot-4 (node-1) port (O7) → `br-lab-ext` (no host IP) → GNS3 Cloud node → a gateway or the W-underlay edge.
- External laptop/firewall acts as a site-to-site peer or road-warrior client (S6, S1-C variant).
- Netplan change (buildout Phase 5 style): bridge with the port as member, no addresses, `optional: true` (avoids the known `systemd-networkd-wait-online` boot delay), applied with `netplan try`. Port is **not** in the capture-port list and **is** added to the `wan-apply` guard list unless it is deliberately impaired.
- **Optional wire view:** cable a second Slot-4 port through a copper TAP into a Slot-10 capture port (10GBASE-T, Cat6a). This yields real-NIC captures alongside the virtual ones for fidelity comparison.
- `br-lab-ext` is an untrusted-device ingress: no forwarding to management, no host IP, and the R1 rule (§12) scoped so it does not open a path to other bridges beyond what the scenario wires.

---

## 8. Reference-PCAP Harness

### 8.1 Run directory (under `/data/pcap/cases/` — operator-designated, never auto-deleted)
```text
/data/pcap/cases/<scenario>/<run-id>/
├── run.yaml               # manifest (8.2) — completed with actuals at run end
├── outer-t01-0.pcap       # per capture point: one classic-pcap file per ring slot,
├── outer-t02-0.pcap       #   <name>-<N>.pcap (renamed from tcpdump's <name>.pcapN
├── inner-i01-0.pcap       #   after stop; tcpdump cannot write pcapng)
├── inner-i02-0.pcap
├── gt/                    # ground truth — LAB-ONLY, excluded from Git and from Malcolm upload
│   ├── keys/<node>/       # save-keys output (esp_sa, ikev2_decryption_table)
│   ├── sa/<node>/         # timestamped swanctl / appliance SA dumps
│   └── logs/<node>/       # charon / appliance logs
├── events.log             # executed event timeline (UTC, ms)
├── capture-stats.txt      # per-capture kernel drop counts
├── expected.md            # copy of the scenario's expected observations, with PASS/FAIL marked
└── sha256sums
```
Because `cases/` is exempt from automatic retention, the harness enforces a **per-run size cap** (`tcpdump -C`/`-W` or dumpcap ring limits) and refuses to start if `/data/pcap` free space is under the Phase-10 floor.

### 8.2 Manifest schema (`run.yaml`)
```yaml
run_id: S1-W1-ss-20261001T1400Z
scenario: S1
underlay: W1
variant: ss                      # ss | vy | op | mt | mx
spec_version: ipsec-scenarios v0.1
gns3_project: s1-w1-ss.gns3project
nodes:
  - {name: gw-a, image: ipsec-ss@sha256:<digest>, role: endpoint}
  - {name: gw-b, image: ipsec-ss@sha256:<digest>, role: endpoint}
  - {name: isp1, image: quay.io/frrouting/frr:0.0.0-fixture, role: provider}   # fixture tag — the real tag is the bundled pin
ipsec:
  ike_version: 2
  auth: psk
  ike_proposal: aes256gcm16-prfsha384-ecp384
  esp_proposal: aes256gcm16-ecp384
  ike_rekey_s: 600
  child_rekey_s: 120
  dpd_delay_s: 10
  mode: policy                   # policy | route
capture_points:
  - {name: outer-t01, bridge: br-lab-t01, view: outer}
  - {name: outer-t02, bridge: br-lab-t02, view: outer}
  - {name: inner-i01, bridge: br-lab-i01, view: inner}
  - {name: inner-i02, bridge: br-lab-i02, view: inner}
impairment:
  - {mechanism: M1, profile: branch-wan, iface: <t01-port>, direction: A->B}
traffic:
  lane: A
  script: traffic/profile-basic.sh
  seed: 1001
events: events/s1-baseline.yaml
times_utc: {start: null, end: null}   # filled by harness
results: {pass: null, notes: ""}      # filled after expected.md review
```

### 8.3 Harness command contracts (to implement in `scripts/scenarios/`, bats + shellcheck gated)

| Command | Does | Must not |
|---|---|---|
| `scen-prep <scenario-dir>` | Verifies prerequisites (modules §9.1, bridges exist, `wan-show` clean, free space), creates the run dir | Create bridges on the mgmt bond or capture ports |
| `scen-run <run.yaml>` | Starts captures on every capture point → applies impairment → starts traffic → executes events → stops captures → collects ground truth → writes drop stats, `events.log`, `sha256sums` | Leave captures or qdiscs running on failure (trap-based cleanup) |
| `scen-ingest <run-dir>` | Copies PCAPs into Malcolm's upload directory (discovered the way `scripts/r770-malcolm-deploy.sh` `upload_dir()` does — the `upload:` service's bind mount) with filename tags `<run-id>-outer` / `<run-id>-inner`; never uploads `gt/` | Upload key material |
| `scen-clear` | `wan-clear` on all scenario ifaces, kill harness captures, verify baseline RTT returns | Touch interfaces outside the scenario's manifest |

GNS3 project start/stop stays operator-driven (GUI/API) in v0.1; the harness only manages the host side and in-container ground-truth collection.

### 8.4 Ground-truth collection
- **Containers:** copy `/gt` from each endpoint node — via GNS3 persistent/extra volumes in the project directory or `docker cp` (whichever O4 confirms); resolve node → container via the GNS3 API or container labels.
- **VyOS:** `show vpn ike sa` and `show vpn ipsec sa` snapshots at start, after each event, and at end (SSH over `br-lab-mgmt`).
- **OPNsense:** `swanctl --list-sas` snapshots (strongSwan-based).
- **CHR:** `/ip ipsec active-peers print` and `/ip ipsec installed-sa print detail` snapshots (keys if O9 confirms).
- **Decryption check:** point tshark at a dedicated Wireshark profile populated from `gt/keys` (`tshark -C <profile> …`) to confirm outer ESP decrypts to the flows seen on the inner capture.

### 8.5 Event scripts
```yaml
# events/s9-mpls-failover.yaml — times relative to traffic start
- {t: 0,   action: note,      text: "traffic start"}
- {t: 60,  action: link-down, target: br-lab-t03:<port>}      # MPLS access link
- {t: 150, action: link-up,   target: br-lab-t03:<port>}
- {t: 200, action: wan-apply, profile: lte-poor, iface: <t05-port>}
- {t: 260, action: wan-clear, iface: <t05-port>}
```
Actions for v0.1: `note`, `link-down`/`link-up` (host bridge ports via `ip link`), `wan-apply`/`wan-clear`, `exec` (a named command inside a node, e.g. `vtysh` route withdrawal), and `gns3-link-suspend`/`resume` once O4 confirms the API. Every executed event is written to `events.log` with a UTC millisecond timestamp.

---

## 9. Host Preparation (additions to buildout Phases 7/11/12)

### 9.1 Kernel modules for containerized IPsec (and MPLS if O5 passes)
`/etc/modules-load.d/ipsec-lab.conf`:
```text
# XFRM / ESP for containerized IPsec endpoints
xfrm_user
xfrm_interface
esp4
esp6
# optional — only if W3 uses FRR MPLS (O5)
# mpls_router
# mpls_iptunnel
```
Validation: `lsmod | grep -E 'xfrm_user|xfrm_interface|esp4'`. Rollback: remove the file, `modprobe -r` the modules when no endpoint containers are running.

### 9.2 Bridges
Created per scenario by `lab-transit.sh` (no host IPs). Outer bridges get `mirror-on.sh` (buildout Phase 11); inner bridges do not.

### 9.3 Docker FORWARD interaction (R1)
After Phase 6, test bridged forwarding on a `br-lab-*` segment. If frames are dropped, add a scoped rule:
```bash
sudo iptables -I DOCKER-USER -i br-lab-+ -o br-lab-+ -j ACCEPT
```
Record it (persisted with the rest of the host firewall config), with rollback `sudo iptables -D DOCKER-USER -i br-lab-+ -o br-lab-+ -j ACCEPT`.

---

## 10. Scenario Catalog

| ID | Scenario | Underlay | Endpoints (variants) | Lanes | Key reference behaviors |
|---|---|---|---|---|---|
| S0 | Plaintext baseline | W1 | none (routed CEs) | A | Baseline RTT/throughput/PCAP shape for every comparison |
| S1 | Site-to-site, policy-based, IKEv2 PSK | W1 | ss·ss, vy·vy, op·op, mt·mt; S1-C external peer | A, C | IKE_SA_INIT/IKE_AUTH on 500, ESP (proto 50), CHILD_SA rekey, DPD on idle |
| S2 | Route-based (XFRM interfaces/VTI) + BGP over tunnel | W2 | ss+FRR, vy | A | Tunnel-interface routing, BGP over ESP, route withdrawal on tunnel loss |
| S3 | NAT traversal | W4 | ss client behind CGN ↔ ss/vy gateway | A, B1 | NAT detection, switch to UDP 4500, ESP-in-UDP, NAT keepalives, mapping expiry |
| S4 | Multi-vendor interop + failure injection | W2 | pairwise vy/op/mt/ss (mx) | A | See failure catalog below |
| S5 | Hub-and-spoke, DPD failover to secondary hub | W2 (or W6) | 2 hubs + 3 spokes | A, B1 | DPD-driven failover, rekey collisions under load, multiple concurrent SAs |
| S6 | Remote access, IKEv2 certs / EAP | W4 + W1 | ss road-warriors, external laptop; gw ss/op | A, C | Virtual IPs, cert validation, expired/revoked cert failures |
| S7 | Impairment stress | W5, W7 | S2 overlay | A, B1 | DPD false positives, rekey under loss/latency, MTU black holes, ESP vs rate caps |
| S8 | IPsec over MPLS L3VPN | W3 | CE gateways ss or vy | A | Unlabeled ESP at CE–PE, labeled ESP in the core, VRF isolation |
| S9 | Dual-transport failover | W6 | route-based ss+FRR, vy | A + events | Tunnel-per-transport, BGP preference, failover/failback timing |

**S4 failure-injection catalog (one run per case, each with its expected IKEv2 notify/behavior):**

| Case | Injection | Expected |
|---|---|---|
| F1 | IKE proposal mismatch | `NO_PROPOSAL_CHOSEN` in IKE_SA_INIT response |
| F2 | PSK mismatch | `AUTHENTICATION_FAILED` |
| F3 | Traffic-selector mismatch | `TS_UNACCEPTABLE`; IKE SA up, no CHILD_SA |
| F4 | Identity mismatch | `AUTHENTICATION_FAILED` (or vendor-specific) |
| F5 | Lifetime mismatch | Asymmetric rekey initiator; record which side rekeys |
| F6 | Expired cert (S6 variant) | Authentication failure; no SA |
| F7 | Inner MTU too large, DF set (S7 variant) | Black-holed large packets; ICMP behavior recorded |

---

## 11. Worked Templates

### 11.1 W1 — Single-ISP internet

```text
 [site-A host]──[gw-A]──(Cloud: br-lab-t01)──[isp1]──(Cloud: br-lab-t02)──[gw-B]──[site-B host]
      │                                                                          │
 (Cloud: br-lab-i01)                                                    (Cloud: br-lab-i02)
```

| Link | Subnet | Addresses |
|---|---|---|
| gw-A uplink | 198.18.1.0/30 | isp1 198.18.1.1, gw-A 198.18.1.2 |
| gw-B uplink | 198.18.2.0/30 | isp1 198.18.2.1, gw-B 198.18.2.2 |
| Site A LAN | 10.200.1.0/24 | gw-A .1, host .10 |
| Site B LAN | 10.200.2.0/24 | gw-B .1, host .10, svc-targets .20 |

`isp1` (FRR): interfaces on both /30s, no routes to 10.200.0.0/16 (the ISP must never know the private sites — this is what makes plaintext leakage detectable). Gateways: default route to their ISP address.

**Validation:** §4 plain-transport checks between 198.18.1.2 and 198.18.2.2; site LANs must **not** reach each other until the overlay is up (expected: failure — that is the negative test).

### 11.2 S1 — Site-to-site policy-based IKEv2 PSK over W1 (strongSwan variant `ss`)

**`gw-A` — `/etc/swanctl/conf.d/s1.conf`:**
```text
connections {
  s1 {
    version = 2
    local_addrs  = 198.18.1.2
    remote_addrs = 198.18.2.2
    proposals = aes256gcm16-prfsha384-ecp384
    rekey_time = 600s
    dpd_delay = 10s
    local {
      auth = psk
      id = gw-a.site-a.lab
    }
    remote {
      auth = psk
      id = gw-b.site-b.lab
    }
    children {
      s1-net {
        local_ts  = 10.200.1.0/24
        remote_ts = 10.200.2.0/24
        esp_proposals = aes256gcm16-ecp384
        rekey_time = 120s
        dpd_action = restart
        start_action = trap
      }
    }
  }
}
```
`gw-B` mirrors this with addresses, IDs, and traffic selectors swapped (and `start_action = trap`, as on gw-A: both gateways trap, and gw-A remains the initiator because the traffic originates at site A — initiator/responder is deterministic in the PCAP, and IKE only starts once host-A's first packet arrives, after the captures are up).

**`secrets.conf` (generated per run, gitignored):**
```text
secrets {
  ike-s1 {
    id-a = gw-a.site-a.lab
    id-b = gw-b.site-b.lab
    secret = "<generated per run>"
  }
}
```

**Run procedure:**
1. Start GNS3 project `s1-w1-ss`; confirm W1 validation passed on this project revision.
2. `scen-prep scenarios/S1` → `scen-run <run-dir>/run.yaml` (captures start **before** any IKE, so IKE_SA_INIT is in the file: both gateways use `trap` and host-A's first packet triggers the negotiation).
3. Lane A traffic for 240 s (spans ≥ 1 CHILD_SA rekey); idle 40 s at the end (≥ 1 DPD exchange).
4. `scen-clear`; `scen-ingest <run-dir>`.

**Expected observations (`expected.md`):**

| # | Observation | Check |
|---|---|---|
| X1 | IKE_SA_INIT request/response on UDP 500 between 198.18.1.2 ↔ 198.18.2.2 | `tshark -r outer-t01-0.pcap -Y 'isakmp'` |
| X2 | No NAT detected → IKE stays on UDP 500 (no 4500) | `tshark … -Y 'udp.port==4500'` returns 0 |
| X3 | Data carried as ESP (IP proto 50), no UDP encapsulation | `tshark … -Y 'esp'` non-zero |
| X4 | **No site addresses on the outer side without decryption** | `tshark -r outer-t01-0.pcap -Y 'ip.addr==10.200.0.0/16'` returns 0 |
| X5 | ≥ 1 CHILD_SA rekey (CREATE_CHILD_SA) within the 120 s window minus strongSwan's randomization; new SPI pair appears | SA snapshots in `gt/sa/` + new ESP SPIs in outer capture |
| X6 | DPD INFORMATIONAL exchanges appear only during the idle tail | isakmp packets in the final 40 s |
| X7 | With `gt/keys`, decrypted outer flows match the inner capture's 5-tuples | tshark with key profile vs `inner-i01-0.pcap` |
| X8 | Zero kernel drops on every capture point | `capture-stats.txt` |
| X9 | Malcolm shows the run under `tags == <run stamp> && tags == outer` / `inner` (Malcolm splits the file name on `[,-/_.]+`, so the run-id is several tags; the stamp is the per-run key); outer sessions are IKE/ESP only — needs Arkime `trackESP=true` | Arkime tag query |

**Pass:** X1–X9 all true. Variant runs (`vy`, `op`, `mt`) drop X7 unless the platform yields keys, and substitute the platform's SA dumps for X5 evidence.

**Teardown/rollback:** stop the GNS3 project; `scen-clear`; `wan-show` must be empty; bridges removed or retained per `lab-transit.sh`; run directory stays in `cases/` (operator-designated retention).

---

## 12. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | Docker loads `br_netfilter` and sets FORWARD policy DROP → bridged `br-lab-*` traffic silently dropped | Scenarios fail after Phase 6 | §9.3 test + scoped `DOCKER-USER` accept |
| R2 | Endpoint containers negotiate but pass no traffic | False negatives | Host module preload (§9.1); check `ip xfrm state` inside the node |
| R3 | Capturing on a bridge misses forwarded frames on some configurations | Empty/partial reference PCAPs | Harness validation H1 (§13) before the first reference run; fall back to capturing on the bridge member port |
| R4 | Inner and outer bridges both mirrored to `mirror0` | Doubled/confusing live Malcolm sessions | Inner bridges are upload-only (§3) |
| R5 | Key material leaks into Git or Malcolm | Policy violation even for lab keys | `gt/` excluded in `.gitignore` and in `scen-ingest` |
| R6 | `cases/` fills `/data/pcap` (exempt from auto-retention) | Capture stack starvation | Per-run size caps + free-space gate in `scen-prep` |
| R7 | Lane C port misconfiguration | Unexpected external reachability | No host IP, not a capture port, `netplan try`, guard list |
| R8 | MTU/overhead surprises (ESP + MPLS + UDP encapsulation) | Unintended black holes contaminating reference runs | Record path MTU per underlay; MTU cases only in S7 on purpose |
| R9 | Node-1 resource exhaustion with large VM-based topologies | Timing distortion in references | FRR containers for cores; VMs only where vendor behavior matters; record host load in `run.yaml` |

---

## 13. Harness Validation (before any reference run)

| # | Test | Pass |
|---|---|---|
| H1 | Ping across W1 while capturing on `br-lab-t01` and its member port | Both show the ICMP flow; counts match |
| H2 | Simultaneous outer+inner capture of one ping stream | Same packets, same host clock, ordering consistent |
| H3 | Drop accounting | `capture-stats.txt` shows 0 kernel drops at lane-A rates |
| H4 | `scen-ingest` round trip | Tags searchable in Arkime; `gt/` absent from Malcolm |
| H5 | `scen-clear` | `wan-show` empty; baseline RTT within 1 ms of S0 |
| H6 | Trap cleanup | Kill `scen-run` mid-run → no captures or qdiscs left behind |

---

## 14. Build Order (dependency-ordered)

| Phase | Work | Entry | Exit | Status |
|---|---|---|---|---|
| IP0 | Close O1, O2; file this spec + `lab-fabric.md` in repo | — | Addressing final; custom containers classified | NOT STARTED |
| IP1 | Staging: build `ipsec-ss`, `wan-emu`, `svc-targets`, custom images; resolve O3, O4, O5, O9; bundle delta | IP0 | Images pinned in bundle; open items dispositioned | NOT STARTED |
| IP2 | Host prep §9 | Buildout 6, 7, 8, 11, 12 | Modules loaded; R1 tested; bridges via `lab-transit.sh` | NOT STARTED |
| IP3 | Harness implementation + H1–H6 on S0/W1 | IP2, buildout 10 | H1–H6 pass; O6 dispositioned | NOT STARTED |
| IP4 | W1 validation → S1 `ss` → first reference set | IP3 | S1 X1–X9 pass | NOT STARTED |
| IP5 | W2, W4 underlays → S2, S3 | IP4 | Underlay validations + scenario pass | NOT STARTED |
| IP6 | Appliance variants of S1–S3 → S4 interop and F1–F7 | IP5 | Interop matrix recorded | NOT STARTED |
| IP7 | W3, W6 → S8, S9; S5 | IP6, O5 | Failover timing references recorded | NOT STARTED |
| IP8 | Lane B (B1, B2), Lane C (netplan change) → S6, S1-C | IP4; buildout 5 for lane C | External peer + replay runs pass | NOT STARTED |
| IP9 | W5, W7 → S7; curate reference-library index | IP5 | `cases/INDEX.md`: run → behaviors shown | NOT STARTED |

---

## Change Log

| Version | Date | Change |
|---|---|---|
| v0.1 | 2026-09-24 | Initial draft: layer model, W1–W7 underlays, impairment mechanisms and profile additions, endpoint container contract, traffic lanes A/B/C, reference-PCAP harness, S0–S9 catalog, worked W1/S1 templates, open items O1–O10 |
| v0.1.1 | 2026-10-07 | Filed in repo. Version numbers replaced by references to the fetch script's pin block (`OWNERS.md`); the CHR release named in O9 was behind the pin. O1 collision check against the known real blocks recorded. `scen-ingest` target corrected to Malcolm's upload directory as `r770-malcolm-deploy.sh` discovers it. §0 status now points at the implementing plan |
| v0.1.2 | 2026-10-07 | §11.2: both S1 gateways use `start_action = trap` (gw-A stays the initiator because traffic originates at site A); run-procedure step 2 runs `scen-run <run-dir>/run.yaml` |
| v0.1.3 | 2026-10-09 | §11.2 swanctl example: `local`/`remote` blocks one key per line (swanctl.conf has no inline `key = v  key = v`; the one-line form made charon discard the connection on the staging VM — `state/inventory/staging-ipsec-rehearsal-2026-10-09.md`) |
| v0.1.5 | 2026-10-09 | Capture files are `<name>-<N>.pcap` (classic pcap; tcpdump writes no pcapng and names ring files `<name>.pcapN` — `scen-run` renames them after stop, in cleanup too). Decided over switching to dumpcap: the readers never cared about the container, only the name was misleading and `pcapng0` became a Malcolm tag |
| v0.1.4 | 2026-10-09 | X9: Malcolm tag rule as measured (file name split on `[,-/_.]+`; query by run stamp + view) and Arkime needs `trackESP=true` or ESP packets are dropped as unknown (Phase 10 configuration item) — `state/inventory/staging-ipsec-rehearsal-2026-10-09.md` |
