# scenarios/

Reference-PCAP scenarios for the lab: IPsec/WAN traffic generated across impaired
links, captured, and ingested as labelled cases. The design is in
`docs/superpowers/specs/2026-10-07-ipsec-scenarios-design.md`; the build and test
steps are in `docs/superpowers/plans/2026-10-07-ipsec-scenarios-plan.md`. The
harness code lives in `scripts/scenarios/` (shared library: `scen-lib.sh`).

```
scenarios/
  profiles/   impairment profiles, one .conf per link type
  S*/         one folder per scenario
  README.md
```

## profiles/

One file per link type. Format is `KEY=value`, `#` comments, and only the keys
`RATE_DOWN RATE_UP DELAY JITTER LOSS NOTE`. Values are written in `tc` syntax
(`20mbit`, `40ms`, `0.2%`) so both consumers, the shell harness and the
container images, pass them straight through. An empty value means "do not
set it" (for example `congested-uplink` is rate only; queueing supplies the delay
and loss). `profile_load <name>` in `scen-lib.sh` exports them as `P_*` and
rejects unknown keys. Set `SCEN_PROFILES` to point at another directory.

## S*/

A scenario folder holds everything needed to replay one scenario: its definition,
the profile and events it uses, and the expected-results description that
`scen-check` compares against. Per-run PSKs (`secrets.conf`) and ground truth
(`gt/`: keys, SA dumps) are generated at run time and are gitignored; they never
enter Git.

`impairment[].direction` is a label, not a control: `wan-apply` shapes the **egress** of
the named host interface, and the egress of a bridge port flows *toward the node on
that port*. So `veth-t01a` (gw-a's port on `br-lab-t01`) impairs B→A; to impair A→B on
the same link name the ISP's port, `veth-t01b` (measured 2026-10-09: A→B bulk ran at
135 Mbit/s past a 20 Mbit profile on `veth-t01a`, only the ACKs were shaped).

Capture files are classic pcap named `<name>-<N>.pcap`, one per ring slot (`scen-run`
renames tcpdump's `<name>.pcapN` after stop; tcpdump cannot write pcapng, and the
all-digit `N` is a token Malcolm's tag rule drops). `scen-check` merges a ring with
`mergecap`; `scen-ingest` copies only these files.

A run's `sha256sums` covers the top-level files and everything under `gt/`. It stays
complete on the capture host; a copy brought into this repo as evidence has its `gt/`
lines removed first (`grep -v ' gt/'`), so no digest of a key or PSK file is ever
committed (decided 2026-10-09).

`run.yaml`'s `baseline: {node, target, rtt_ms}` is the H5 check `scen-clear` runs
at the end: `node` pings `target` (the far CE's outer address) from inside the
node, because the lab bridges carry no host address; `rtt_ms` is the S0 value to
compare against (`null` disables the check).

## Safety

Impairments and scenario traffic touch lab transit/inner bridges and veths only
(`guard_iface`). The management NIC, capture ports and mirror interfaces are
refused.
