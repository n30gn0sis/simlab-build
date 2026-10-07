# S0 expected observations (W1 plaintext baseline, no IPsec)

| # | Observation | Check | Result |
|---|---|---|---|
| X4-inverse | Site addresses ARE visible on the outer side (nothing encrypts them); this proves the X4 check in S1 can detect leakage | `tshark -r outer-t01.pcapng -Y 'ip.addr==10.200.0.0/16'` returns **non-zero** | — |
| X8 | Zero kernel drops on every capture point | `capture-stats.txt` | — |

S0 delivery fails by design: the ISP has no routes to 10.200.0.0/16 and there is no IPsec. The leaked SYNs on the outer capture are exactly what X4-inverse needs; expect `FAILED:` lines in `traffic.out`.
