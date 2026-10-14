# S1 expected observations (site-to-site policy IKEv2 PSK over W1, strongSwan)

| # | Observation | Check | Result |
|---|---|---|---|
| X1 | IKE_SA_INIT request/response on UDP 500 between 198.18.1.2 <-> 198.18.2.2 | `tshark -r outer-t01.pcapng -Y 'isakmp'` | PASS |
| X2 | No NAT detected: IKE stays on UDP 500 (no 4500) | `tshark ... -Y 'udp.port==4500'` returns 0 | FAIL (46 frames on UDP 4500) |
| X3 | Data carried as ESP (IP proto 50), no UDP encapsulation | `tshark ... -Y 'esp'` non-zero | PASS |
| X4 | **No site addresses on the outer side without decryption** | `tshark -r outer-t01.pcapng -Y 'ip.addr==10.200.0.0/16'` returns 0 | PASS |
| X5 | At least 1 CHILD_SA rekey (CREATE_CHILD_SA) within the 120 s window minus strongSwan's randomization; new SPI pair appears | SA snapshots in `gt/sa/` + new ESP SPIs in outer capture | PASS |
| X6 | DPD INFORMATIONAL exchanges appear only during the idle tail | isakmp packets in the final 40 s | FAIL (20 non-CREATE_CHILD_SA isakmp frames mid-run) |
| X7 | With `gt/keys`, decrypted outer flows match the inner capture's 5-tuples | tshark with key profile vs `inner-i01.pcapng` | FAIL (2 decrypted tuples not in inner capture) |
| X8 | Zero kernel drops on every capture point | `capture-stats.txt` | FAIL (4 capture point(s) with drops or unknown drops) |
| X9 | Malcolm shows the run under `<run-id>-outer` / `-inner` tags; outer sessions are IKE/ESP only | Arkime tag query | SKIP (manual: Arkime tag query) |
traffic: 0 FAILED steps in traffic.out

**Pass:** X1-X9 all true. Variant runs (`vy`, `op`, `mt`) drop X7 unless the platform yields keys, and substitute the platform's SA dumps for X5 evidence.
