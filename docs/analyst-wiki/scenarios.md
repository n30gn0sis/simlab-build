# Reference PCAPs and Scenarios

A **reference PCAP with ground truth** is a capture of traffic whose cause is known in advance: we built the topology, chose the impairment, ran the traffic, and recorded what we did and when. When you open one you are not guessing what a retransmission burst or a rekey means. The run tells you, and a checklist says what the capture should show.

This is how the lab produces teaching and comparison captures for IPsec and simulated-WAN behavior, such as IKE negotiation, ESP, rekeying, dead-peer detection, NAT traversal, and failover.

## Where runs live

Each run gets its own directory on the capture volume:

```
/data/pcap/cases/<scenario>/<run-id>/
```

Inside you will find the captures, the run description, an `expected.md` listing the observations the run should show (each marked PASS, FAIL or SKIP by the automated checks), and a `gt/` folder.

## Finding a run in Arkime

Runs are uploaded to [Malcolm](malcolm.md) with tags, so a run appears as two views of the same traffic:

| Tag | What it is |
|---|---|
| `<run-id>-outer` | The traffic as the network saw it: IKE, ESP, NAT-T encapsulation. The payload is encrypted. |
| `<run-id>-inner` | The protected traffic inside the tunnel, as the sites saw it |

In Arkime, search on the tag (for example `tags == <run-id>-outer`) and compare the two views side by side. See [Malcolm](malcolm.md#arkime) for searching.

## What `gt/` is, and why it is not in Malcolm

`gt/` is the ground truth: the session keys exported by the endpoints, security-association dumps, and the event log. It is what lets Wireshark decrypt the outer capture and lets the checks prove what happened. It is deliberately **never** uploaded to Malcolm. Key material does not belong in an analysis stack that many people can search, and the ingest step is built to copy only the tagged PCAPs. To decrypt in Wireshark, work from the run directory on the lab host.

## Scenario catalog

| ID | Scenario | Key behaviors the reference shows |
|---|---|---|
| S0 | Plaintext baseline | Baseline RTT, throughput and PCAP shape for every other comparison |
| S1 | Site-to-site, policy-based, IKEv2 with pre-shared key | IKE negotiation on UDP 500, ESP, child-SA rekey, dead-peer detection on an idle tunnel |
| S2 | Route-based tunnel with BGP over it | Routing over the tunnel interface, BGP carried in ESP, route withdrawal when the tunnel drops |
| S3 | NAT traversal | NAT detection, switch to UDP 4500, ESP-in-UDP, NAT keepalives, mapping expiry |
| S4 | Multi-vendor interop and failure injection | Proposal, key, selector, identity and lifetime mismatches, each with its expected notify or behavior |
| S5 | Hub-and-spoke with failover to a secondary hub | Dead-peer-driven failover, rekey collisions under load, many concurrent SAs |
| S6 | Remote access with certificates or EAP | Virtual IPs, certificate validation, expired and revoked certificate failures |
| S7 | Impairment stress | False dead-peer detection, rekey under loss and latency, MTU black holes, ESP under rate caps |
| S8 | IPsec over an MPLS L3VPN | Unlabeled ESP at the customer edge, labeled ESP in the core, VRF isolation |
| S9 | Dual-transport failover | One tunnel per transport, BGP preference, failover and failback timing |

Not every scenario is built yet; the build tracker records which ones exist. Underlay circuits come from the [WAN profiles](wan.md).

## How to run one

On the lab host, four commands in order (run directory from `scen-prep`):

```bash
scen-prep  <scenario-dir>           # gate: prerequisites checked, run directory created
scen-run   <run-dir>/run.yaml       # captures, impairment, traffic, events, ground truth
scen-check <run-dir>                # tshark checks fill in expected.md
scen-ingest <run-dir>               # tagged upload of the PCAPs to Malcolm (never gt/)
```

`scen-clear <run-dir>/run.yaml` removes any leftover impairment and captures if a run is interrupted. Impairments and scenario traffic only ever touch lab bridges, never the management NIC or the capture ports.

Design and details: the scenario spec in `docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md` and `scenarios/README.md`.
