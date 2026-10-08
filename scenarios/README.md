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

## Safety

Impairments and scenario traffic touch lab transit/inner bridges and veths only
(`guard_iface`). The management NIC, capture ports and mirror interfaces are
refused.
