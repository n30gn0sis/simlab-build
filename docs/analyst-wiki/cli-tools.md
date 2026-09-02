# Host CLI Tools

The server carries a curated set of command-line tools for spot checks, validation, and testing over SSH. Ground rules first, because they're different from a normal Linux box:

- **Malcolm is the capture platform; the CLI is the screwdriver.** Host-level capture tools exist for spot-validation and troubleshooting, not for running your own parallel capture pipeline. If it matters, it goes through Malcolm.
- **Capture rights come from the `pcapture` group,** not root/sudo. `dumpcap` carries capabilities so group members can capture without elevation. If capture commands give permission errors, you're not in the group yet — ask the operator.
- **You can't install anything.** The tool set is fixed per offline bundle ([why](access.md#air-gap-rules)). Missing something? Request it for the next bundle.
- **Aim tests at the lab, not the management network.** Scans and traffic generators belong on lab segments.

## Spot capture

`tcpdump`, `tshark`, and `dumpcap` for quick looks — is traffic flowing, is the VLAN tag there, is the capture port actually seeing packets:

```bash
# Live peek at an interface (no file written)
tcpdump -i <iface> -nn -c 100

# ...filtered — BPF syntax
tcpdump -i <iface> -nn 'host 10.10.20.5 and port 443'

# Write a short capture to your workspace (dumpcap = most efficient writer)
dumpcap -i <iface> -a duration:60 -w /srv/work/<you>/spotcheck.pcapng

# Ring buffer so a long spot-check can't fill the disk
dumpcap -i <iface> -b filesize:100000 -b files:10 -w /srv/work/<you>/ring.pcapng

# Quick protocol readout with display filters (Wireshark syntax)
tshark -i <iface> -Y 'dns' -c 50
```

Write captures to **your workspace** (`/srv/work/`) — never into `/data/pcap/raw/` (that's Arkime's) and not onto `/` (spot captures grow fast; use `-c`, `-a duration:` or a ring buffer, always).

### PCAP file utilities

The tshark suite includes the standard file tools — most useful on exports and imports:

```bash
capinfos file.pcap                              # summary: duration, packet count, rates, timestamps
editcap -A '2026-08-30 12:00' -B '2026-08-30 13:00' in.pcap out.pcap   # slice by time
editcap -c 100000 big.pcap chunk.pcap           # split into chunks
mergecap -w merged.pcap a.pcap b.pcap           # merge captures
tshark -r file.pcap -Y 'http.request' -T fields -e ip.src -e http.host  # scripted field extraction
```

## tcpreplay

Replays a PCAP onto an interface, packet-for-packet. Two lab uses:

- **Capture validation** — replay a reference PCAP with a known packet count into a feed, then confirm Malcolm indexed all of it (this is the lab's standard capture-integrity test).
- **Reproducing traffic in a topology** — inject recorded traffic into a lab segment so appliances/sensors see it.

```bash
tcpreplay -i <lab-iface> --stats 5 sample.pcap          # replay at original timing
tcpreplay -i <lab-iface> --mbps 50 sample.pcap          # replay at a set rate
tcpreplay -i <lab-iface> --loop 10 sample.pcap          # repeat
```

Replay **only into lab segments or designated test feeds** — replayed packets are real packets, and anything listening will treat them as such.

## Throughput and path testing

```bash
iperf3 -s                                   # server end (one lab node)
iperf3 -c <server> -t 30                    # TCP throughput, 30 s
iperf3 -c <server> -u -b 100M               # UDP at a target rate (also reports loss/jitter)
iperf3 -c <server> -R                       # reverse direction — test both ways on asymmetric links
ping -c 20 <host>                           # RTT/loss basics
mtr -rw <host>                              # path + per-hop loss/latency in one report
traceroute <host>                           # path only
```

These are the measurement half of the [WAN-emulation workflow](wan.md#workflow-prove-it-then-trust-it): baseline → impair → measure → clear → confirm.

## Name and network lookups

```bash
dig @<lab-dns> <name>            # DNS lookups (dnsutils) — remember: no internet resolution
nmap -sn 10.10.20.0/24           # which lab hosts are up
nmap -sT -p 1-1024 <lab-host>    # what's listening (lab segments only)
ss -tlnp                         # sockets listening on the host itself
ip -br addr ; ip route           # interface and routing state
```

`nmap` is for **lab networks only** — never the management subnet, per lab policy.

## Everything else in the box

Also installed and occasionally useful to analysts: `jq` (slice JSON — including Zeek logs exported as JSON), `git` (the lab's config/script repo), `tmux` (keep long replays/captures alive across SSH disconnects), `htop`/`iotop`/`sysstat` (is the box busy?), `ethtool` (link state and NIC drop counters: `ethtool -S <iface> | grep -i drop`), `fio`/`stress-ng` (performance/stress testing — operator territory), `mtr`, `lsof`, `strace`.

If a favorite tool is missing from this page, run `which <tool>` — the curated package list is broader than this summary — and if it's truly absent, request it for the next bundle.
