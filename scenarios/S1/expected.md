# S1 expected observations (site-to-site policy IKEv2 PSK over W1, strongSwan)

| # | Observation | Check | Result |
|---|---|---|---|
| X1 | IKE_SA_INIT request/response on UDP 500 between 198.18.1.2 <-> 198.18.2.2 | `tshark -r outer-t01-0.pcap -Y 'isakmp'` | — |
| X2 | No NAT detected: IKE stays on UDP 500 (no 4500) | `tshark ... -Y 'udp.port==4500'` returns 0 | — |
| X3 | Data carried as ESP (IP proto 50), no UDP encapsulation | `tshark ... -Y 'esp'` non-zero | — |
| X4 | **No site addresses on the outer side without decryption** | `tshark -r outer-t01-0.pcap -Y 'ip.addr==10.200.0.0/16'` returns 0 | — |
| X5 | At least 1 CHILD_SA rekey (CREATE_CHILD_SA) within the 120 s window minus strongSwan's randomization; new SPI pair appears | SA snapshots in `gt/sa/` + new ESP SPIs in outer capture | — |
| X6 | DPD INFORMATIONAL exchanges appear only during the idle tail | isakmp packets in the final 40 s | — |
| X7 | With `gt/keys`, decrypted outer flows match the inner capture's 5-tuples | tshark with key profile vs `inner-i01-0.pcap` | — |
| X8 | Zero kernel drops on every capture point | `capture-stats.txt` | — |
| X9 | Malcolm shows the run under `tags == <run stamp> && tags == outer` / `inner` (Malcolm splits the file name on `[,-/_.]+`, so the run-id is several tags; the stamp is the per-run key); outer sessions are IKE/ESP only — needs Arkime `trackESP=true` | Arkime tag query | — |

**Pass:** X1-X9 all true. Variant runs (`vy`, `op`, `mt`) drop X7 unless the platform yields keys, and substitute the platform's SA dumps for X5 evidence.
