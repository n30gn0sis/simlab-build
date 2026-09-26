# Staging kit rehearsal 2026-09-26 — the R770 kit, air-gapped, end to end on VM 9770

> **TEST CUT — NOT FOR TRANSFER.** `bundle-20260925` still carries the SYNTHETIC `gns3/appliances/` placeholders; it exists only on VM 9770.

**What ran:** the R770 kit (`sim-lab-basic`, branch `rehearsal-fixes` → its PR #5) against `bundle-20260925`, on VM 9770 (12 GiB, set by the operator in the Proxmox UI) with the air gap **blocked** by `scripts/r770-airgap-sim.sh` (auto-revert armed). The Claude session drove it over SSH. Dates are the VM's, in UTC. The kit's raw transcripts, validation reports and scenario run records (92 files) are **not committed**: `*.tar.gz` is ignored here, and as plain files they name R770 and kit paths that `tests/references.bats` would flag. They remain on VM 9770 under the kit checkout's `r770-evidence/` (lost at its next rollback) and as a tarball in the rehearsing session's scratch space. The numbers below are copied from them.

## Bundle extension (before the gap)

| Change | How | Result |
|---|---|---|
| strongSwan image (`STRONGSWAN_IMG`, this branch) | `r770-offline-fetch.sh --only appliances`, `BUNDLE_DIR=…/bundle-20260925` | GNS3 node images 5/5; the previous tarball was kept aside on the VM |
| `ubridge` | first try: a curated-APT-list entry, which failed with `Unable to locate package` and was reverted (the repo lock and the appended notes block were repaired by hand). Then GNS3's PPA inside the APT stage (`82eadd1`), `FORCE=1 --only apt` | `ubridge` in `apt/` |
| Manifest | regenerated | **1599 files, 15G**; `verify` exit 2 (the CHR download WARN only, accepted for a test cut); `--strict` exit 1 |

## Base-OS stand-ins (not the kit's job)

- **Phase 3 volumes:** the kit's `preflight` refuses unmounted Phase 3 directories. Each was given a loop-mounted ext4 file in `/etc/fstab`.
- **Base-OS packages:** installed by hand from `/srv/repo/apt`, emulating the base-OS phase: `python3-venv`, `python3-pip-whl`, `python3-ruamel.yaml`, `python3-dotenv`, `easy-rsa`, `nginx`, `ubridge`.

## Results

| Pipeline / step | Result |
|---|---|
| GNS3 `full` | DEPLOYED; `labnet` all PASS (`br_netfilter` SKIP) |
| Malcolm `full` (`--capture-ifs lab_mirror0`) | DEPLOYED; **27/27 healthy**, including `pcap-capture`, `zeek-live` and `arkime-live` on `lab_mirror0` |
| Docs `full` | DEPLOYED WITH WARNINGS (7 pages) |
| Portal `ca cert htpasswd nginx` | all PASS |
| Scenarios | all five `up` / `traffic` / `down` PASS — see below |
| `r770-validate.sh` | network 9 PASS / 1 SKIP · capture `zeek capture_loss` **PASS 0.0** · gns3, portal, airgap and storage READY (each SKIP carries its reason) |

### Scenario pack on the mirror

Each run was captured with `tcpdump -ni lab_mirror0` during a 20 s window, with 0 kernel drops after the rate cap:

| Scenario | Mirror | Malcolm |
|---|---|---|
| client-server | HTTP 10.205.0.10 ↔ .20 (416 packets) | Zeek `conn`/`http`/`files`; Arkime **129 sessions** from 10.205.0.10 |
| ipsec-esp | ESP 10.201.0.1 ↔ .2 only, no cleartext from the client ranges | — |
| ospf | OSPF on 10.203.23.0/24, ICMP and iperf 10.203.1/24 → 10.203.3/24 | Zeek `ospf.log` |
| bgp | tcp/179 (after the timers fix), ICMP, iperf | Zeek `conn` 10.204.0.1 ↔ .2:179 |
| ipsec-ike | udp/500 IKE_SA_INIT, udp/4500 IKE_AUTH, ESP both ways, no cleartext | Zeek `spicy_ipsec_ike_udp` (500), `spicy_ipsec_udp` (4500) |

## Findings

All were fixed in the kit test-first and re-proved on the VM (kit PR #5), except the two marked as build-repo findings.

1. The Malcolm installer zip's `install.py` is at the zip root. It must run from `/opt/malcolm`, and it refuses once the stack is extracted; the installer inside the extracted stack reconfigures.
2. The installer keeps live Arkime as netsniff (`pcapNetSniff`), not `liveArkime`.
3. Malcolm's `auth_setup`/`start`/`stop` refuse root. They must run as the `PUID`/`PGID` owner in `config/process.env`, and that user must own the stack and the configured `/data/index`, `/data/pcap/raw` (the first start failed with permission denied on `/data/index`).
4. `pcap-capture` does `export $IFACE`, so the capture end was renamed `lab-mirror0` → **`lab_mirror0`**.
5. GNS3 v3: `/v3/access/users/login` is OAuth2 form-encoded and answers JSON with 422. The JSON login is `/v3/access/users/authenticate`.
6. **Build repo:** no bundle carried `ubridge`, so every GNS3 project failed to open with 409 "uBridge is not available". Fixed upstream by fetching `ubridge` from GNS3's PPA (this branch).
7. `ubridge` installs as `root:ubridge 0754` with file capabilities. The GNS3 service user needs the `ubridge` group.
8. **Build repo (recorded 2026-09-25):** the strongSwan image does not start charon. The scenario starts `/usr/libexec/ipsec/charon`.
9. FRR: `vtysh -f` exits 0 while skipping a daemon still starting, so one router lost `router ospf` and OSPF never converged. The kit now waits for `show watchfrr` to report every daemon Up.
10. BGP at FRR's 60 s keepalive leaves no tcp/179 in a traffic window. The scenario now sets `timers 5 15`.
11. Uncapped iperf3 flooded `br-lab`: tcpdump dropped 16 %, control plane included. Every client is now capped at 50 Mbit/s.
12. IKE negotiated at `up`, and a rekey or reauth stays on 4500, so no udp/500 appeared in the window. The traffic step now tears the SA down so the trap renegotiates.
13. Malcolm's default `captureStats: false` meant `capture_loss.log` was never written. It now follows live capture. Rotated logs are `logs/<date>/capture_loss.*.log.gz`, one row per worker.

## Still open

- The air gap was left blocked, with auto-revert armed; VM close-out is to follow.
- Resync the kit's `staging/` from this branch once it merges.
- The dashboards for these scenarios and an automated end-to-end `expect.txt` check are the kit's next sub-projects.
