# End-to-end rehearsal on AWS: cut a bundle, install it offline

**Date:** 2026-10-20 · **Status:** design approved in conversation, awaiting operator review of this text
**Goal (session):** "a full end to end test with bundle generation and offline testing with an instance"
**Builds on:** the 2026-10-06 single-instance rehearsal (`sim-lab-basic` findings #11, this repo's #19)
and the installer rehearsed on VM 9770 (`state/inventory/staging-installer-2026-10-04.md`).
This spec changes no script in either repo. It is a test design: what is run, where, in
what order, what counts as a pass, and what is recorded.

## What this is and isn't

The 10-06 rehearsal built the bundle and installed it on the same host. That host already
had Docker, the staging images and both checkouts, so it could not show that the bundle is
self-sufficient; it had no `/dev/kvm`, so the QEMU appliances never booted; and the air gap
was a security-group change part way through, not the state of the box from first boot.

This rehearsal separates the two roles the way the real cycle does:

- a **staging** instance with internet cuts the bundle onto a transfer volume, the way the
  staging VM writes the ext4 transfer drive;
- an **offline target**, bare metal so KVM exists, that has never had a route to the
  internet, receives that volume and installs from the bundle alone.

Out of scope, each recorded as a difference from the R770 rather than tested:
physical capture ports (only `lab_mirror0` is exercised); PERC RAID (the storage is EBS
under LVM); iDRAC and SSH as the out-of-band channel (AWS Systems Manager stands in);
the licensed GNS3 appliances (none are staged — the one accepted gap). The stopped 10-06
instance (`i-08e07de7885a50844`) is not used or touched; its fate is a separate decision.

## Decisions taken in conversation

| Question | Decision |
|---|---|
| One host or two | Two: staging cuts, a separate never-online target installs |
| Target hardware | A `*.metal` instance, so `/dev/kvm` is real and every free appliance boots |
| Capture ports | Internal mirror only; external ports are SKIP with the reason "no tap on a cloud host" |
| Pass bar | Every check clean except the licensed images: `verify --strict` passes, every install step completes, validate has no FAIL, e2e covers every scenario a free image serves |
| On a real bug | Record it, finish the run, fix in PRs afterwards with one re-run of the affected stage; never patch the kit on the target |
| Bundle transfer | An EBS volume moved between the instances — the "USB stick" — not S3 |

## Topology

All in one AWS region and availability zone, all tagged `simlab-e2e`, all terminated at
the end.

| Piece | Spec | Network |
|---|---|---|
| **Staging** | Ubuntu 24.04, m6i.2xlarge class, 200 GB root (the preflight needs ≥ 150 GB free), Docker CE | Public subnet with internet egress; driven over SSM |
| **Transfer volume** | 256 GB EBS, ext4, label `R770XFER` | Attached to staging for the cut, then to the target, then back to staging for the evidence |
| **Target** | Ubuntu 24.04 on a `*.metal` instance, 100 GB root plus one ~1 TB data volume | Private subnet: no internet gateway, no NAT, no S3 endpoint. Egress only to the three SSM interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) |

The SSM endpoints are the test's management channel, in the place of the operator's SSH
session to the R770's management NIC. They are the only thing the target can reach.

Two account facts gate the whole plan and are checked first: the on-demand vCPU quota
(a metal instance is 72–96 vCPUs; a new account's quota is often lower) and which metal
types the zone offers. Neither is assumed.

## Staging: cutting the bundle

Runs as root on the staging instance. Every long job runs detached under `nohup` with its
log on the transfer volume, because the driving tool's calls time out at 60 s.

1. **Checkouts.** Fresh public https clones of `simlab-build` and `sim-lab-basic` at their
   current `main`; both commits recorded. No credential goes on the box. This repo's `main`
   is canonical for the cut: it owns the pins and carries the full monitoring set.
2. **Preflight.** `scripts/r770-staging-preflight.sh`, output kept. A refusal stops the run;
   the host is fixed, never the script.
3. **Cut onto the media.** With the volume mounted at `/mnt/xfer` and the cut run from
   there, so `bundle-YYYYMMDD/` lands directly on the media:
   ```
   SITE_SRC_ROOT=<simlab-build> KIT_SRC_ROOT=<sim-lab-basic> BUILD_ASSUME_YES=1 \
       <simlab-build>/scripts/r770-build-bundle.sh
   ```
   Every fetch stage runs, including `labimages`, the GNS3 appliance images (#19) and `kit`
   (#18). `BUILD_ASSUME_YES=1` answers the licensed-appliance pause: none are staged, and
   that is the one accepted gap. The builder's manifest and `--strict` gate run as usual.
4. **Gate from the media.** `r770-bundle.sh verify --strict` again, from `/mnt/xfer`, as
   staging-runbook Step 6 requires. 0 lets the media move; 2 means each WARN is decided
   first; 1 stops the run. Recorded with it: bundle size, file count, and `kit/KIT_COMMIT`,
   which must equal the kit's `main`.
5. **Harness item.** `amazon-ssm-agent`'s deb is fetched on staging and placed at
   `/mnt/xfer/harness/`, beside the bundle and outside the manifest. The kit's `phone-home`
   step purges `snapd`, and the stock Ubuntu image's SSM agent is a snap; without the deb
   the management channel dies at that step (the 10-06 finding).
6. **Evidence out, then stop.** `BUNDLE_NOTES.md`, the preflight, build and verify logs go
   to `s3://simlab-staging-775862930889/out/e2e-YYYYMMDD/staging/`. Then `sync`, unmount,
   detach. Staging is **stopped**, not terminated: it comes back at the end to receive the
   media. The target is launched only now, after the gate has passed.

## Target: preparation, then install from the bundle alone

### Preparation (stands in for Phases 1–3)

Done from the stock image with nothing downloaded. In order:

1. From user-data: hostname; a volume group on the data volume with logical volumes at
   the eight mount points `r770-import-bundle.sh` requires (`/var/lib/docker`,
   `/data/pcap`, `/data/index`, `/data/staging`, `/srv/vms`, `/srv/gns3`, `/srv/work`,
   `/srv/backup`), sized down proportionally; an `fstab` line for each.
2. Attach the media, mount it read-only at `/mnt/xfer`, install the deb agent from
   `harness/`, confirm SSM still answers, then remove the snap.
3. **Air-gap check, before.** `curl` to the internet, `apt-get update` against upstream,
   and `docker pull` must each fail. Output recorded.

### Install

Driven only through `<media>/bundle-YYYYMMDD/kit/scripts/r770-install.sh`, the installer
the bundle carries.

1. `discover` — the template and the host facts, saved.
2. `install.conf`, written from the discover output: SSM is non-interactive and `wizard`
   reads a TTY. Every value is a discovered one — `DEVICE` the media's device,
   `MEDIA=/mnt/xfer`, `CAPTURE_IFS=lab_mirror0`, `LAB_BRIDGE=br-lab`, `MGMT_IF` and
   `MGMT_CIDR` from `ip -br addr`, `INDEX_PATTERN` empty.
3. `plan` — every gated change under `--dry-run`, saved whole as the review record.
4. `run --yes --non-interactive` — import → gns3 → malcolm → docs → portal → dashboards.
   Each gate's current/proposed/rollback text is in its transcript. At `dashboards` the
   installer lists the index patterns and stops, by design.
5. `INDEX_PATTERN` filled from that list; `run --yes --non-interactive --from dashboards`
   — dashboards → validate → e2e.

### After

The air-gap check is repeated. The media is unmounted, as the installer's last line asks.
Then the whole `r770-evidence/` tree, the installer's summary and every log are copied
onto the transfer volume (remounted read-write for that alone), which is detached. The
target has no path to S3; evidence leaves on the media, as it would from the R770.

## Pass bar and expected verdict

The run passes when all of these hold:

- `verify --strict` passed on staging, from the media;
- every installer step completed (no FAIL row in the summary);
- `validate` reports no FAIL; its SKIPs each carry a reason;
- `e2e` ran every scenario a free image serves, and judged each in Malcolm.

The installer's own verdict is expected to be `NOT INSTALLED`, for exactly one reason:
the licensed appliances the cut could not carry. That is the accepted gap. Any other WARN
or FAIL is a finding.

## Failure handling

- A kit or bundle refusal is a finding; its text goes in the report verbatim. No gate is
  bypassed and nothing in the kit is edited on the target.
- A failed step gets one `--from <step>` retry, after its transcript has been read. A
  second failure stops that pipeline; the run continues wherever the installer allows.
- A failed cut means the target is never launched.
- Each finding becomes a PR afterwards, proven by one re-run of the affected stage.

## Cost control

The metal instance is the only expensive part (about $4–5/h; staging is about $0.40/h).
Whole-run estimate $25–35. Its lifetime is bounded three ways:

- it launches only after the media passes the gate;
- a self check-in every ~50 minutes reports where the run is;
- a hard cap: at 6 hours up it is terminated whatever the state, after the evidence has
  been copied to the media. The operator can extend the cap during the run.

Three actions get the operator's explicit go-ahead first: launching the metal instance,
any `--from` retry beyond the one per step, and extending the cap. Everything else in the
plan runs unasked.

## The report

Written beside the evidence in S3 (`out/e2e-YYYYMMDD/report.md`), with a one-line entry in
this repo's `state/BUILD-STATE.md` log pointing at it, the way the 10-04 rehearsal was
recorded. Evidence trees stay out of git, per the kit's rules. The report carries:

- both commits, the bundle name, size and file count, `KIT_COMMIT`;
- the two air-gap checks, before and after;
- every installer step's verdict, validate's PASS/WARN/FAIL/SKIP tally, e2e's result per
  scenario;
- the differences from the R770, one line each;
- the findings, each with the transcript line that shows it.

## Not in this spec

How the AWS pieces are created (subnets, endpoints, user-data, volume moves) is
implementation detail for the plan, as is the exact instance type, which the quota check
decides. No change to either repo's scripts is proposed here; if the run finds one is
needed, that is a finding and its own PR.
