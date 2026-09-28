# Sub-project 4 — GNS3, virtual mirror feed, and one reference scenario

**Date:** 2026-09-27 · **Status:** design approved by operator, not yet implemented
**Part of:** "deploy and configure the analyst stack" (`docs/superpowers/specs/2026-09-24-bundle-to-r770-design.md` §"The larger goal") — sub-project 4: "Lab bridges/NAT, GNS3 behind `gns3.lab`, virtual mirror feed" (Phases 7 [partial], 8, 11). Done when: **a GNS3 lab's traffic appears in Malcolm.**

## Why now, and what "done" proves

No physical R770 is available, so this proves **offline deployability** and **the one integration that's never been attempted in any form**: GNS3-generated traffic reaching Malcolm's live capture. Sub-project 2 (`2026-09-26-analyst-stack-design.md`) already proved Malcolm + CA + portal + UFW offline on VM 9771 (snapshot `analyst-stack-3b05070`). This spec builds directly on that snapshot rather than re-deriving it.

## Decisions (operator, 2026-09-27)

1. **Mirror mechanism: hub-mode Linux bridge, not OVS.** Exactly what `docs/plans/r770-network-lab-buildout.md` §7.2 already specs (`br-lab`, `ageing_time 0`, multicast snooping off, veth pair `lab-mon0`/`lab-mirror0`) — "simple before clever," and the same OS-level mechanism the real R770 will use later, so nothing here needs to change when it moves to hardware.
2. **One reference scenario, kept RAM-light.** Two **netshoot** Docker nodes (ping/curl/dig/iperf3/tcpdump) plus one lightweight QEMU node (Alpine or CirrOS, boot-and-ping only) on a single GNS3 switch, uplinked to `br-lab` via a Cloud node. The QEMU node exists to satisfy the buildout §13 Phase 8 validation line ("one QEMU node + one Docker node boot and pass traffic") without the RAM cost of a router appliance (VyOS etc.) on a 12 GiB VM already running 27 Malcolm services.
3. **Tooling scope:** traffic-gen/analysis via netshoot's built-in CLI arsenal, plus this repo's own drop-accounting validation pattern (buildout §7.4). WAN impairment (`wan` skill / tc-netem) and additional/varied scenarios are explicitly **deferred** to a later pass.
4. **This pass also re-proves the full stack is still cleanly deployable offline** from current `main` (post PR #15/#16), as the baseline the GNS3 work builds on — a fresh bundle cut + air-gapped install-test, not a new design (it's the same proven playbook run again).

## Scope

**In:**
- A fresh bundle cut from current `main` + air-gapped install-test on staging, confirming the already-proven analyst stack still deploys clean (baseline re-proof; no new script).
- `scripts/r770-gns3-deploy.sh` (`plan`/`apply`/`verify`) — GNS3 server install/config/auth, behind the existing `gns3.lab` nginx vhost.
- `scripts/r770-gns3-deploy.sh labnet` (`plan`/`apply`/`verify`) — builds `br-lab`/`lab-mon0`/`lab-mirror0` and wires Malcolm's capture container to the new interface.
- One reference GNS3 topology + a traffic-driver script with known, logged traffic counts.
- Validation: Arkime session counts and Zeek logs vs. the known counts, `capture_loss.log` ≈ 0 — the same methodology already used for the tcpreplay-based Malcolm rehearsal, now against live GNS3 traffic.

**Out (this pass):**
- Lab NAT / internet egress for lab traffic (the other half of Phase 7) — not needed; the reference scenario is fully internal.
- WAN impairment tie-in, additional scenarios, licensed/heavier QEMU appliances (VyOS, Cisco, etc.).
- `.lab` DNS beyond what sub-project 2 already proved (hosts-file entries stand in until sub-project 5).
- Running any of this on the real R770 (no physical hardware available; staging only).

## Delivery path

Same mechanism as sub-project 2: the fetch already copies this repo's `scripts/`, `config/` and `docs/analyst-wiki/` into the bundle's `site/` directory, manifested and `--strict`-checked. New files here (the two new script verbs, the reference topology, the traffic driver) ride the same path — no new delivery mechanism needed.

## `scripts/r770-gns3-deploy.sh plan | apply | verify`

| Verb | Does |
|---|---|
| `plan` | Read-only: confirms the GNS3 package/wheelhouse is present in the bundle, the service user doesn't already exist in a bad state, and prints what `apply` would do. |
| `apply` | Installs `gns3-server` (pin per `scripts/r770-offline-fetch.sh`) from the bundle; creates the `gns3` service user (member of `kvm` and `docker` groups — documented as root-equivalent, per buildout §9); writes `/etc/gns3/gns3_server.conf` from `config/gns3/gns3_server.conf.template`, filling `__PASSWORD__`/`__JWT__` generated on the box (same never-in-git pattern as Malcolm `auth`); installs the existing `config/nginx/gns3.lab.conf` vhost (already in the repo — no new nginx work); enables and starts the systemd unit. |
| `verify` | Service up; API responds; `gns3.lab` reachable through the portal returning 401 without credentials and 200 with the configured auth; projects/images paths exist and are owned by the `gns3` user. |

Every verb is idempotent and reports "already done" instead of repeating work, matching the sibling scripts' convention.

## `scripts/r770-gns3-deploy.sh labnet plan | apply | verify`

| Verb | Does |
|---|---|
| `plan` | Read-only: shows current bridge/veth state (if any) and what would be created. |
| `apply` | Creates `br-lab` (hub mode: `ageing_time 0`, multicast snooping off), the veth pair `lab-mon0` (bridge side) / `lab-mirror0` (capture side), sets `lab-mirror0` promiscuous. Extends Malcolm's capture container to also listen on `lab-mirror0` (matches Malcolm's exact existing capture-interface config line, refuses unless exactly one match, backs the compose file up first — the same discipline as `bind-loopback` in `r770-malcolm-deploy.sh`). |
| `verify` | Both interfaces exist and are up; `lab-mirror0` is promiscuous; Malcolm's Zeek container lists `lab-mirror0` as a live capture interface. |

## Reference scenario

Not a phase-gating script — a GNS3 project definition plus a small traffic-driver:

- **Topology:** one GNS3 Ethernet switch connecting two `netshoot` Docker nodes (client/server) and one QEMU node (Alpine or CirrOS); the switch's uplink goes to a Cloud node bound to `br-lab`.
- **Traffic driver** (`scripts/r770-gns3-scenario-reference.sh run`): resolves the netshoot nodes' container IDs via the GNS3 API's node list, then runs a fixed, logged sequence — N pings, M `curl` requests against a simple HTTP listener on the peer, K `dig` queries, one short `iperf3` transfer — and writes the expected counts to an evidence file.
- **QEMU node's role:** boot and answer a ping on the shared switch — satisfies buildout §13's Phase 8 line without adding a router appliance.

## Validation

Compares Arkime session counts and Zeek log entries against the traffic driver's expected-counts file, and checks `capture_loss.log` ≈ 0 — reusing buildout §7.4/§13's existing methodology (previously validated only via tcpreplay of a reference PCAP; this proves the same check against live topology traffic).

## Proof run on VM 9771

1. Start from snapshot `analyst-stack-3b05070`. Host memory check first (as sub-project 2 does).
2. **Baseline re-proof:** recut the bundle from current `main`, air-gapped install-test, confirm clean (step 4 of the Decisions above) — new snapshot if this changes anything, otherwise proceed from `analyst-stack-3b05070` directly.
3. Air gap on (`scripts/r770-airgap-sim.sh`).
4. `r770-gns3-deploy.sh apply`, then `labnet apply`.
5. Import and start the reference GNS3 project; run the traffic driver.
6. Validate: Arkime/Zeek counts match expected, `capture_loss.log` ≈ 0; `gns3.lab` reachable through the portal (401 without creds, 200 with).
7. Air gap off. Evidence under `state/inventory/`. New snapshot. Stop VM.

## R770 afterwards

Same scripts run later as operator-gated steps once sub-projects 0–3 are done on the real hardware. The only difference: `lab-mirror0` sits alongside the physical TAP/SPAN feeds instead of being the only feed, and the reference scenario becomes optional (real lab traffic is the point on hardware).

## Risks

- **RAM pressure on 9771** (12 GiB) running Malcolm's 27 services + portal + GNS3 + 3 scenario nodes concurrently. Mitigated by keeping the scenario light (2 Docker + 1 lightweight QEMU) and stopping/removing scenario nodes after the proof run.
- **GNS3 API / container-ID resolution** for the traffic driver. Mitigated by using GNS3's documented node-list endpoint (returns Docker container names); fallback is `docker ps` filtered by the GNS3 project label.
- **Hub-mode bridge disables normal MAC learning** — a known, accepted trade-off already reflected in the buildout plan (§7.2), fine at this traffic scale.
- **Extra Malcolm capture interface.** Staging currently has no physical feeds, so adding `lab-mirror0` is purely additive — no existing passing config should regress.
