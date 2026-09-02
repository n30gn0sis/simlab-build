# WAN Emulation

Real networks aren't LAN-fast. The lab's WAN emulation makes lab links behave like actual circuits — latency, jitter, packet loss, reordering, and rate limits — using Linux `tc`/`netem` under the hood, wrapped in profile scripts so nobody has to hand-craft `tc` syntax.

Use it to answer questions like: does this VPN survive satellite latency? How does the app behave at 2% loss? Why does the transfer crawl on the branch circuit? What does TCP retransmission actually look like in a capture?

## The scripts

Three commands, from the lab's script library (in the config repo; exact install path lands at build time — **TBD**):

```bash
wan-apply <profile> <interface>   # apply an impairment profile to a lab link endpoint
wan-show                          # list active impairments and their parameters
wan-clear <interface>             # remove impairment, restore clean behavior
```

Every impairment is visible in `wan-show` and fully removable with `wan-clear` — nothing persists across a deliberate clear, and impairments never touch the management interface or the capture ports (that's enforced by design, not etiquette).

## Built-in profiles

| Profile | Rate | Delay | Jitter | Loss | Feels like |
|---|---|---|---|---|---|
| `branch-wan` | 20 Mbps | 40 ms | 5 ms | 0.2% | A typical branch-office circuit |
| `satellite` | 25 Mbps | 600 ms RTT-equivalent | variable | — | Geostationary satellite |
| `poor-broadband` | 10 Mbps | 80 ms | — | 2% | Bad consumer DSL/cable |
| asymmetric variants | different up/down | | | | ADSL-style circuits |

Profiles are just parameter files — new ones (a specific customer circuit, a cellular link, a lossy microwave hop) are easy to add to the library; ask or submit one.

## Workflow: prove it, then trust it

Never assume the impairment took effect — measure it. The standard loop:

```bash
# 1. Baseline, before impairing
ping -c 20 <target>                 # note the RTT
iperf3 -c <target>                  # note the throughput

# 2. Apply
wan-apply branch-wan <lab-iface>
wan-show                            # confirm it's active

# 3. Verify the physics changed
ping -c 20 <target>                 # RTT should now be ~baseline + 40 ms
iperf3 -c <target>                  # throughput should cap near 20 Mbps

# 4. Run your actual test / capture

# 5. Clean up and confirm baseline returns
wan-clear <lab-iface>
ping -c 20 <target>
```

If step 3 shows no change, you probably impaired the wrong interface or the wrong direction — `netem` shapes traffic *leaving* an interface, so a "40 ms link" is often 40 ms applied at one endpoint (affecting one direction) or 20 ms at each end. Check `wan-show` and think about which direction your test traffic flows.

## Tips

- **Capture under impairment.** The combination of WAN emulation + the [virtual mirror into Malcolm](gns3.md#analyzing-lab-traffic) (or GNS3 link capture) is the lab's best teaching tool — you can *see* retransmissions, dup-ACKs, and window collapse in Arkime/Wireshark rather than reading about them.
- **Impair inside the topology, not the world.** Apply profiles to the specific GNS3 link endpoint or lab segment that represents the WAN, so the rest of your topology stays clean.
- **Loss and jitter are statistical.** Short tests can miss a 0.2% loss profile entirely; run enough packets (or long enough iperf3) for the statistics to show.
- **Clear when done.** A forgotten impairment on a shared segment is a classic "why is everything slow" mystery for the next analyst. `wan-show` is the first thing to check when a lab link behaves strangely.
