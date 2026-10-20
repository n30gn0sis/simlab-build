# AWS end-to-end rehearsal — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut a bundle on an internet-connected staging instance, move it on an EBS "transfer volume" to a bare-metal instance that has never had a route out, install the lab there from the bundle's own installer, and record the result.

**Architecture:** Two EC2 instances in one availability zone, driven only through AWS Systems Manager (SSM). Staging has egress and writes the bundle onto a 256 GB ext4 volume. The target sits in a private subnet whose only reachable hosts are the three SSM interface endpoints; the volume is moved to it, and `<media>/bundle-*/kit/scripts/r770-install.sh` does the rest. Evidence leaves the target on the same volume, back through staging, to S3.

**Tech Stack:** AWS EC2, EBS, VPC endpoints, SSM Run Command, S3 (via the AWS MCP `run_script` tool, `call_boto3`); Ubuntu 24.04; this repo's `scripts/r770-*.sh` and the kit's `scripts/r770-install.sh`. Nothing in either repo changes.

**Spec:** `docs/superpowers/specs/2026-10-20-aws-e2e-rehearsal-design.md` (merged, PR #21).

## Global Constraints

- The target never has a route to the internet. Its subnet's route table has only the `local` route; there is no NAT, no internet gateway association, and no S3 endpoint. Its security group allows egress only to the endpoint security group.
- Nothing is downloaded on the target. Every file arrives on the transfer volume. The one non-bundle item on it is `harness/amazon-ssm-agent.deb`, outside the manifest.
- The kit is never edited on the target, and no gate is bypassed. A refusal is a finding, copied verbatim.
- One `--from <step>` retry per installer step, after reading its transcript. A second failure stops that pipeline.
- Three actions get the operator's go-ahead first: launching the metal instance (Task 5), any retry beyond the one per step, extending the 6-hour cap.
- The metal instance is terminated at 6 hours up whatever the state, after evidence is on the media.
- Every AWS resource created here is tagged `Project=simlab-e2e` and `Run=e2e-YYYYMMDD`, and deleted in Task 9 (the S3 bucket is kept).
- Every `run_script` call finishes in under 45 s: long jobs run under `nohup`, and the tool only sends, polls, and reads logs.
- No credential is written to either repo or to the instances. Clones are public https.
- Pass bar (spec): `verify --strict` passed from the media; every installer step completed; `validate` has no FAIL; `e2e` ran every scenario a free image serves. The expected verdict is `NOT INSTALLED` for exactly one reason: the licensed appliances.

---

## Working files

All scratch state lives in the session scratchpad, never in a repo:

```
$SCRATCH/e2e/run.env          # discovered IDs, one KEY=value per line (Task 0 onward)
$SCRATCH/e2e/log/             # local copies of every log pulled from the instances
```

`$SCRATCH` is the session's scratchpad directory. `run.env` is the single source of every ID later tasks use; a task that needs an ID reads it from there, never from memory.

## The SSM driver

Every command on either instance goes through this helper, pasted at the top of each `run_script` call that needs it. It sends one shell script, waits up to `wait_s` seconds (keep ≤ 40), and returns stdout/stderr/status. Long jobs are started with `nohup … &` and polled by reading their log file in a later call.

```python
async def ssm(instance_id, script, region, wait_s=35, comment="e2e"):
    r = await call_boto3(service_name="ssm", operation_name="SendCommand", region_name=region, params={
        "InstanceIds": [instance_id], "DocumentName": "AWS-RunShellScript",
        "Parameters": {"commands": [script], "executionTimeout": ["3600"]}, "Comment": comment[:100]})
    cid = r["Command"]["CommandId"]
    for _ in range(wait_s // 5):
        await asyncio.sleep(5)
        try:
            inv = await call_boto3(service_name="ssm", operation_name="GetCommandInvocation", region_name=region,
                                   params={"CommandId": cid, "InstanceId": instance_id})
        except Exception:
            continue
        if inv["Status"] not in ("Pending", "InProgress", "Delayed"):
            return {"status": inv["Status"], "out": inv["StandardOutputContent"][-8000:], "err": inv["StandardErrorContent"][-4000:]}
    return {"status": "STILL_RUNNING", "command_id": cid}
```

Each `run_script` call is a fresh interpreter: paste `ssm`, the tag list `T` (Task 1 Step 2) and any `run.env` value a snippet names into every call that uses them. Upper-case names inside shell snippets (`BUCKET`, `RUN`, `BUNDLE_NAME`, `MEDIA_DEV`, `XFERVOLSERIAL`) are substituted from `run.env` before the script is sent; `XFERVOLSERIAL` is `XFER_VOL` with its hyphen removed.

Long job pattern (used in Tasks 3, 6):

```python
# start
await ssm(I, "nohup bash -c '<command>' > /mnt/xfer/log/<name>.log 2>&1 & echo started", R)
# poll, in later calls
await ssm(I, "tail -n 40 /mnt/xfer/log/<name>.log; pgrep -f '<command>' >/dev/null && echo RUNNING || echo DONE", R)
```

---

### Task 0: Preconditions and account discovery

**Files:**
- Create: `$SCRATCH/e2e/run.env`

**Interfaces:**
- Produces: `run.env` keys `REGION AZ VPC_ID PUBLIC_SUBNET ROLE_STAGING BUCKET METAL_TYPE METAL_VCPUS QUOTA_VCPUS AMI RUN=e2e-YYYYMMDD`

- [ ] **Step 1: Confirm the AWS tool answers.** Run `run_script` with `await call_boto3(service_name="sts", operation_name="GetCallerIdentity")`. Expected: account `775862930889`. If the tool reports it needs sign-in, stop and ask the operator to run `/mcp`; nothing else in this plan can run.

- [ ] **Step 2: Discover the 10-06 leftovers and the region.** They fix the region and VPC: the role `simlab-staging-ssm`, the bucket `simlab-staging-775862930889`, the stopped instance `i-08e07de7885a50844` (not reused, but its VPC and AZ are).

```python
inst = await call_boto3(service_name="ec2", operation_name="DescribeInstances", params={"InstanceIds": ["i-08e07de7885a50844"]})
i = inst["Reservations"][0]["Instances"][0]
result = {"vpc": i["VpcId"], "subnet": i["SubnetId"], "az": i["Placement"]["AvailabilityZone"], "state": i["State"]["Name"]}
```
Run it in every region the account has (DescribeRegions, gather) until one answers; that is `REGION`. Record `VPC_ID`, `AZ`, and the instance's subnet as `PUBLIC_SUBNET` (confirm with DescribeSubnets that `MapPublicIpOnLaunch` is true and its route table has an `igw-` route; if not, Task 1 creates a public subnet).

- [ ] **Step 3: Quota and metal availability.** In `REGION`:

```python
q = await call_boto3(service_name="service-quotas", operation_name="GetServiceQuota",
                     params={"ServiceCode": "ec2", "QuotaCode": "L-1216C47A"})   # Running On-Demand Standard instances (vCPUs)
off = await call_boto3(service_name="ec2", operation_name="DescribeInstanceTypeOfferings",
                       params={"LocationType": "availability-zone", "Filters": [
                           {"Name": "location", "Values": [AZ]},
                           {"Name": "instance-type", "Values": ["c5.metal", "m5.metal", "c6i.metal", "m6i.metal", "c5n.metal", "m5zn.metal"]}]})
types = await call_boto3(service_name="ec2", operation_name="DescribeInstanceTypes",
                         params={"InstanceTypes": [o["InstanceType"] for o in off["InstanceTypeOfferings"]]})
result = {"quota": q["Quota"]["Value"],
          "offered": [(t["InstanceType"], t["VCpuInfo"]["DefaultVCpus"], t["MemoryInfo"]["SizeInMiB"] // 1024) for t in types["InstanceTypes"]]}
```
Choose `METAL_TYPE`: the cheapest offered type whose vCPUs ≤ quota minus 8 (staging's m6i.2xlarge uses 8). Preference order when several fit: `m5zn.metal` (48 vCPU) < `c5.metal` (96) < `m5.metal` (96) < `c6i.metal`/`m6i.metal` (128). If none fits, request a quota increase to the chosen type's vCPUs + 8 (`RequestServiceQuotaIncrease`, same quota code), tell the operator, and stop: the plan resumes at Task 1 once it is granted.

- [ ] **Step 4: The Ubuntu AMI.**

```python
p = await call_boto3(service_name="ssm", operation_name="GetParameter",
                     params={"Name": "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"})
result = p["Parameter"]["Value"]
```
Record as `AMI`. Both instances use it.

- [ ] **Step 5: Write `run.env`** with every key above plus `RUN=e2e-<today, YYYYMMDD>`, `BUCKET=simlab-staging-775862930889`, `ROLE_STAGING=simlab-staging-ssm`. Confirm with `cat`.

---

### Task 1: Private subnet and SSM endpoints for the target

**Files:**
- Modify: `$SCRATCH/e2e/run.env` (adds `PRIVATE_SUBNET RT_PRIVATE SG_ENDPOINTS SG_TARGET VPCE_IDS`)

**Interfaces:**
- Consumes: `REGION AZ VPC_ID RUN`
- Produces: a subnet with no route out; three interface endpoints reachable from `SG_TARGET` only

- [ ] **Step 1: Pick a free CIDR.** `DescribeSubnets` on `VPC_ID`; choose the first `/24` inside the VPC CIDR not in use. Record it.

- [ ] **Step 2: Create the subnet and a route table with only the local route.**

```python
T = [{"Key": "Project", "Value": "simlab-e2e"}, {"Key": "Run", "Value": RUN}]
sn = await call_boto3(service_name="ec2", operation_name="CreateSubnet", params={
    "VpcId": VPC_ID, "CidrBlock": CIDR, "AvailabilityZone": AZ,
    "TagSpecifications": [{"ResourceType": "subnet", "Tags": T + [{"Key": "Name", "Value": "simlab-e2e-private"}]}]})
rt = await call_boto3(service_name="ec2", operation_name="CreateRouteTable", params={
    "VpcId": VPC_ID, "TagSpecifications": [{"ResourceType": "route-table", "Tags": T}]})
await call_boto3(service_name="ec2", operation_name="AssociateRouteTable", params={
    "RouteTableId": rt["RouteTable"]["RouteTableId"], "SubnetId": sn["Subnet"]["SubnetId"]})
```
A new route table carries only the VPC `local` route. Do not add any route.

- [ ] **Step 3: Verify the table has one route.** `DescribeRouteTables` on `RT_PRIVATE`: expected exactly one route, `GatewayId == "local"`. Record the output in `$SCRATCH/e2e/log/private-rt.json`; it is evidence.

- [ ] **Step 4: Security groups.** Two, both in `VPC_ID`:
  - `SG_ENDPOINTS` (`simlab-e2e-endpoints`): ingress TCP 443 from `SG_TARGET`; no other rule.
  - `SG_TARGET` (`simlab-e2e-target`): no ingress; **revoke the default all-egress rule**, then allow egress TCP 443 to `SG_ENDPOINTS` only.

```python
await call_boto3(service_name="ec2", operation_name="RevokeSecurityGroupEgress", params={
    "GroupId": SG_TARGET, "IpPermissions": [{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]})
await call_boto3(service_name="ec2", operation_name="AuthorizeSecurityGroupEgress", params={
    "GroupId": SG_TARGET, "IpPermissions": [{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                                            "UserIdGroupPairs": [{"GroupId": SG_ENDPOINTS}]}]})
```

- [ ] **Step 5: Verify the target SG.** `DescribeSecurityGroups` on `SG_TARGET`: `IpPermissions == []` and `IpPermissionsEgress` has exactly one entry, TCP 443 to `SG_ENDPOINTS`. Save to `$SCRATCH/e2e/log/sg-target.json`.

- [ ] **Step 6: Three interface endpoints** in `PRIVATE_SUBNET`, security group `SG_ENDPOINTS`, private DNS on:

```python
ids = []
for svc in ("ssm", "ssmmessages", "ec2messages"):
    e = await call_boto3(service_name="ec2", operation_name="CreateVpcEndpoint", params={
        "VpcId": VPC_ID, "VpcEndpointType": "Interface", "ServiceName": f"com.amazonaws.{REGION}.{svc}",
        "SubnetIds": [PRIVATE_SUBNET], "SecurityGroupIds": [SG_ENDPOINTS], "PrivateDnsEnabled": True,
        "TagSpecifications": [{"ResourceType": "vpc-endpoint", "Tags": T}]})
    ids.append(e["VpcEndpoint"]["VpcEndpointId"])
```
Poll `DescribeVpcEndpoints` until all three are `available` (a few minutes; one poll per call). Record `VPCE_IDS`.

- [ ] **Step 7: Note the VPC's DNS settings.** `DescribeVpcAttribute` for `enableDnsSupport` and `enableDnsHostnames` must both be true for private DNS to resolve; if either is false, set it with `ModifyVpcAttribute` and note it in the report (it is a VPC-wide change).

---

### Task 2: Staging instance and the transfer volume

**Files:**
- Modify: `$SCRATCH/e2e/run.env` (adds `SG_STAGING STAGING_ID XFER_VOL`)

**Interfaces:**
- Consumes: `REGION AZ VPC_ID PUBLIC_SUBNET AMI ROLE_STAGING RUN`
- Produces: a staging host that passes `r770-staging-preflight.sh`, with the volume at `/mnt/xfer`

- [ ] **Step 1: Staging security group** `simlab-e2e-staging`: no ingress, default all egress (it needs the internet). Record `SG_STAGING`.

- [ ] **Step 2: Launch.** `RunInstances`:

```python
UD = """#!/bin/bash
set -euxo pipefail
hostnamectl set-hostname simlab-staging
apt-get update
apt-get install -y ca-certificates curl git pigz
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
systemctl enable --now docker
touch /var/lib/cloud/instance/e2e-userdata-done
"""
r = await call_boto3(service_name="ec2", operation_name="RunInstances", params={
    "ImageId": AMI, "InstanceType": "m6i.2xlarge", "MinCount": 1, "MaxCount": 1,
    "SubnetId": PUBLIC_SUBNET, "SecurityGroupIds": [SG_STAGING],
    "IamInstanceProfile": {"Name": ROLE_STAGING},
    "BlockDeviceMappings": [{"DeviceName": "/dev/sda1", "Ebs": {"VolumeSize": 200, "VolumeType": "gp3", "DeleteOnTermination": True}}],
    "UserData": UD,
    "TagSpecifications": [{"ResourceType": "instance", "Tags": T + [{"Key": "Name", "Value": "simlab-e2e-staging"}]}]})
STAGING_ID = r["Instances"][0]["InstanceId"]
```
If `IamInstanceProfile` by name fails, look the profile up with `iam.ListInstanceProfilesForRole` on `ROLE_STAGING` and pass its `Arn`.

- [ ] **Step 3: Wait for SSM.** Poll `ssm.DescribeInstanceInformation` (filter `InstanceIds`) until `PingStatus == "Online"`, then `ssm(STAGING_ID, "ls /var/lib/cloud/instance/e2e-userdata-done && docker info --format '{{.ServerVersion}}'")`. Expected: the marker exists and a Docker version prints.

- [ ] **Step 4: Create, attach, format and mount the transfer volume.**

```python
v = await call_boto3(service_name="ec2", operation_name="CreateVolume", params={
    "AvailabilityZone": AZ, "Size": 256, "VolumeType": "gp3",
    "TagSpecifications": [{"ResourceType": "volume", "Tags": T + [{"Key": "Name", "Value": "simlab-e2e-xfer"}]}]})
XFER_VOL = v["VolumeId"]
# poll DescribeVolumes until State == "available", then:
await call_boto3(service_name="ec2", operation_name="AttachVolume", params={"VolumeId": XFER_VOL, "InstanceId": STAGING_ID, "Device": "/dev/sdf"})
```
Then on the host, discovering the device by its EBS serial rather than guessing `/dev/sdf`:

```bash
DEV=$(lsblk -dpno NAME,SERIAL | awk -v s="$(echo XFER_VOL | tr -d -)" '$2==s{print $1}')
test -n "$DEV"
mkfs.ext4 -F -L R770XFER "$DEV"
mkdir -p /mnt/xfer && mount "$DEV" /mnt/xfer && mkdir -p /mnt/xfer/log /mnt/xfer/harness
findmnt /mnt/xfer
```
(`XFER_VOL` is substituted into the script; EBS serials are the volume ID without the hyphen.) Expected: `findmnt` shows `/mnt/xfer` on `$DEV`, ext4.

- [ ] **Step 5: Clone both repos and run the preflight.**

```bash
cd /opt && git clone -q https://github.com/n30gn0sis/simlab-build.git && git clone -q https://github.com/n30gn0sis/sim-lab-basic.git
git -C /opt/simlab-build rev-parse HEAD; git -C /opt/sim-lab-basic rev-parse HEAD
cd /mnt/xfer && /opt/simlab-build/scripts/r770-staging-preflight.sh 2>&1 | tee /mnt/xfer/log/preflight.log; echo "preflight rc=${PIPESTATUS[0]}"
```
Expected: rc=0, or rc=2 with each WARN read and noted (they go in the report). Record both commit hashes in `run.env` as `BUILD_COMMIT` and `KIT_COMMIT_SRC`. rc=1 means fix the host (a missing tool, too little space) and rerun; never edit the script.

---

### Task 3: Cut the bundle onto the media

**Files:**
- Modify: `$SCRATCH/e2e/run.env` (adds `BUNDLE_NAME BUNDLE_SIZE BUNDLE_FILES KIT_COMMIT`)

**Interfaces:**
- Consumes: `STAGING_ID REGION`
- Produces: `/mnt/xfer/bundle-YYYYMMDD/` verified `--strict` from the media; `/mnt/xfer/harness/amazon-ssm-agent.deb`

- [ ] **Step 1: Start the cut, detached.** `--yes` answers the licensed-appliance pause (none staged — the accepted gap) and accepts preflight warnings; without it a non-TTY run dies by design. `SEED_FROM=none` makes "nothing reused" explicit.

```bash
cd /mnt/xfer && nohup env SITE_SRC_ROOT=/opt/simlab-build KIT_SRC_ROOT=/opt/sim-lab-basic SEED_FROM=none \
  /opt/simlab-build/scripts/r770-build-bundle.sh --yes > /mnt/xfer/log/build.log 2>&1 &
echo started
```

- [ ] **Step 2: Poll until done.** Every call: `tail -n 30 /mnt/xfer/log/build.log; pgrep -f r770-build-bundle.sh >/dev/null && echo RUNNING || echo DONE`. Between calls, wait with a `send_later` of 10–15 minutes rather than tight polling; the Malcolm images dominate and the whole cut is one to three hours. The log's last lines on success read `RESULT: PASS` from the strict gate and the builder's exit note; capture `grep -nE 'RESULT|WARN|ERROR|refus' /mnt/xfer/log/build.log`.

- [ ] **Step 3: Gate from the media, again, and record the bundle facts.**

```bash
cd /mnt/xfer && B=$(ls -d bundle-* | tail -1) && echo "BUNDLE_NAME=$B"
./$B/r770-bundle.sh verify /mnt/xfer/$B --strict 2>&1 | tee /mnt/xfer/log/verify-media.log; echo "verify rc=${PIPESTATUS[0]}"
du -sh /mnt/xfer/$B | cut -f1; find /mnt/xfer/$B -type f | wc -l; cat /mnt/xfer/$B/kit/KIT_COMMIT
```
Expected: rc=0 and `RESULT: PASS`; `KIT_COMMIT` equals `KIT_COMMIT_SRC` from Task 2. rc=2: read each WARN; a WARN about the licensed appliances only is the accepted gap, anything else is a finding to record before moving on. rc=1: stop; the target is not launched. Write the four values to `run.env`.

- [ ] **Step 4: The harness item.**

```bash
curl -fsSL -o /mnt/xfer/harness/amazon-ssm-agent.deb https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg-deb -I /mnt/xfer/harness/amazon-ssm-agent.deb | grep -E 'Package|Version'
```
Expected: `Package: amazon-ssm-agent` and a version. It sits outside `bundle-*/`, so the manifest is untouched: confirm with `./$B/r770-bundle.sh verify /mnt/xfer/$B --strict | tail -2` once more (still PASS).

- [ ] **Step 5: Staging evidence to S3.**

```bash
B=$(ls -d /mnt/xfer/bundle-* | tail -1)
aws s3 cp /mnt/xfer/log/ s3://BUCKET/out/RUN/staging/ --recursive
aws s3 cp $B/BUNDLE_NOTES.md s3://BUCKET/out/RUN/staging/BUNDLE_NOTES.md
```
If `aws` is absent on the AMI, install it from Ubuntu's `awscli` package (`apt-get install -y awscli`): staging has egress, this is allowed there. Expected: `aws s3 ls s3://BUCKET/out/RUN/staging/` lists `build.log preflight.log verify-media.log BUNDLE_NOTES.md`.

- [ ] **Step 6: Release the media and stop staging.**

```bash
sync && umount /mnt/xfer && echo unmounted
```
Then `DetachVolume` (`XFER_VOL`), poll until `available`, then `StopInstances` (`STAGING_ID`). Staging is stopped, not terminated: Task 8 starts it again.

---

### Task 4: Target IAM role

**Files:**
- Modify: `$SCRATCH/e2e/run.env` (adds `ROLE_TARGET`)

**Interfaces:**
- Produces: an instance profile with SSM core only — no S3, nothing else

- [ ] **Step 1: Create the role and profile.**

```python
trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
await call_boto3(service_name="iam", operation_name="CreateRole", params={"RoleName": "simlab-e2e-target-ssm", "AssumeRolePolicyDocument": trust, "Tags": T})
await call_boto3(service_name="iam", operation_name="AttachRolePolicy", params={"RoleName": "simlab-e2e-target-ssm", "PolicyArn": "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"})
await call_boto3(service_name="iam", operation_name="CreateInstanceProfile", params={"InstanceProfileName": "simlab-e2e-target-ssm"})
await call_boto3(service_name="iam", operation_name="AddRoleToInstanceProfile", params={"InstanceProfileName": "simlab-e2e-target-ssm", "RoleName": "simlab-e2e-target-ssm"})
```

- [ ] **Step 2: Verify.** `ListAttachedRolePolicies` on the role: exactly one policy, `AmazonSSMManagedInstanceCore`. Record `ROLE_TARGET=simlab-e2e-target-ssm`. IAM is eventually consistent: wait ~15 s before Task 5 uses it.

---

### Task 5: Launch and prepare the target (operator go-ahead first)

**Files:**
- Modify: `$SCRATCH/e2e/run.env` (adds `TARGET_ID DATA_VOL TARGET_UP_AT CAP_TRIGGER`)

**Interfaces:**
- Consumes: `METAL_TYPE AMI PRIVATE_SUBNET SG_TARGET ROLE_TARGET AZ RUN`
- Produces: a target with the nine LVs mounted, SSM online through the endpoints, and the first air-gap check recorded

- [ ] **Step 1: Ask the operator.** State `METAL_TYPE`, its hourly price class, the 6-hour cap, and that Task 3's gate passed. Proceed only on a yes.

- [ ] **Step 2: Launch** with the data volume in the block-device mapping and the storage layout in user-data. Sizes scale the R770 layout (`scripts/r770-storage-apply.sh`'s `LAYOUT`) to a 1 TB volume; `/var/lib/containerd` gets its own LV as on the 2026-10-04 rehearsal, so the kit's `storage` check PASSes.

```python
UD = r"""#!/bin/bash
set -euxo pipefail
hostnamectl set-hostname simlab-target
apt-get install -y lvm2 xfsprogs || true     # from the AMI's apt cache only; no network exists
# the data volume is the one disk that is not the root disk (its serial is unknown until the instance exists)
DEV=$(lsblk -dpno NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $1!~/nvme0n1|xvda|sda/{print $1}' | head -1)
test -n "$DEV"
pvcreate "$DEV"; vgcreate ubuntu-vg0 "$DEV"
while read -r n g fs mp; do
  [ -n "$n" ] || continue
  lvcreate --yes --wipesignatures y -n "$n" -L "${g}G" ubuntu-vg0
  mkfs."$fs" -q /dev/ubuntu-vg0/"$n"
  mkdir -p "$mp"
  echo "/dev/ubuntu-vg0/$n $mp $fs defaults,nofail 0 2" >> /etc/fstab
done <<'LAYOUT'
lv_docker     150 ext4 /var/lib/docker
lv_containerd  40 ext4 /var/lib/containerd
lv_pcap       300 xfs  /data/pcap
lv_index      150 xfs  /data/index
lv_staging     60 xfs  /data/staging
lv_vms        100 xfs  /srv/vms
lv_gns3       100 xfs  /srv/gns3
lv_work        40 xfs  /srv/work
lv_backup      40 xfs  /srv/backup
LAYOUT
systemctl daemon-reload; mount -a
touch /var/lib/cloud/instance/e2e-userdata-done
"""
```
Then:

```python
r = await call_boto3(service_name="ec2", operation_name="RunInstances", params={
    "ImageId": AMI, "InstanceType": METAL_TYPE, "MinCount": 1, "MaxCount": 1,
    "SubnetId": PRIVATE_SUBNET, "SecurityGroupIds": [SG_TARGET],
    "IamInstanceProfile": {"Name": ROLE_TARGET},
    "BlockDeviceMappings": [
        {"DeviceName": "/dev/sda1", "Ebs": {"VolumeSize": 100, "VolumeType": "gp3", "DeleteOnTermination": True}},
        {"DeviceName": "/dev/sdb",  "Ebs": {"VolumeSize": 1000, "VolumeType": "gp3", "DeleteOnTermination": True}}],
    "UserData": UD,
    "TagSpecifications": [{"ResourceType": "instance", "Tags": T + [{"Key": "Name", "Value": "simlab-e2e-target"}]},
                          {"ResourceType": "volume", "Tags": T}]})
TARGET_ID = r["Instances"][0]["InstanceId"]
```
Record `TARGET_UP_AT` (UTC now). A metal instance takes 5–15 minutes to come up. If `RunInstances` fails with `InsufficientInstanceCapacity`, try the next type in Task 0's preference order that fits the quota; if none launches, tell the operator and stop.

- [ ] **Step 3: Arm the cap and the check-ins.** `send_later` at +50 min ("check-in: target progress"), re-armed at each firing; and one at +6 h named `CAP_TRIGGER`: "terminate the target now per the spec's cap, after Task 7's evidence copy if it has not run". Record its trigger id.

- [ ] **Step 4: Wait for SSM through the endpoints.** Poll `DescribeInstanceInformation` until `Online` (the AMI's snap agent registers via the endpoints' private DNS). Then verify the prep:

```bash
ls /var/lib/cloud/instance/e2e-userdata-done
for m in /var/lib/docker /var/lib/containerd /data/pcap /data/index /data/staging /srv/vms /srv/gns3 /srv/work /srv/backup; do findmnt -n -o TARGET,SOURCE,FSTYPE "$m" || echo "MISSING $m"; done
ls /dev/kvm && egrep -c '(vmx|svm)' /proc/cpuinfo
```
Expected: the marker; nine lines each on `/dev/mapper/ubuntu--vg0-lv_*`; `/dev/kvm` present and a non-zero CPU count. A `MISSING` line is a prep failure: read `/var/log/cloud-init-output.log`, fix the user-data, terminate and relaunch (the cap clock restarts; cancel and re-arm `CAP_TRIGGER`).

- [ ] **Step 5: Air-gap check, before.** Save the script as `/root/airgap-check.sh` on the target by heredoc in the SSM command (the target cannot fetch it), then run it:

```bash
cat > /root/airgap-check.sh <<'EOF'
#!/bin/bash
# airgap-check.sh — each line must FAIL on an air-gapped host. Prints PASS when it did.
set -u
chk() { if timeout 15 "$@" >/dev/null 2>&1; then echo "FAIL  reached: $*"; else echo "PASS  blocked: $*"; fi; }
echo "== airgap check $(date -u -Is) on $(hostname)"
ip route show default | sed 's/^/route: /'; [ -z "$(ip route show default)" ] && echo "route: (no default route)"
chk curl -sS -m 10 https://deb.debian.org/
chk curl -sS -m 10 http://archive.ubuntu.com/ubuntu/
chk curl -sS -m 10 https://registry-1.docker.io/v2/
chk apt-get update -o Acquire::Retries=0
command -v docker >/dev/null && chk docker pull alpine:latest || echo "SKIP  docker pull: docker not installed yet"
EOF
chmod +x /root/airgap-check.sh && /root/airgap-check.sh | tee /root/airgap-before.log
```
Expected: every `chk` line `PASS  blocked`, and `docker pull` SKIP (Docker arrives from the bundle). Any `FAIL  reached` means the subnet or SG is wrong: fix Task 1, re-run this step, and do not attach the media until it is clean. Note: the default route may exist (to the VPC router) — the proof is that nothing beyond the endpoints answers, not the route's absence.

---

### Task 6: Attach the media, swap the SSM agent, install

**Files:**
- Modify: `$SCRATCH/e2e/run.env` (adds `MEDIA_DEV INDEX_PATTERN`)

**Interfaces:**
- Consumes: `XFER_VOL TARGET_ID BUNDLE_NAME`
- Produces: the installer's `run` summary under `/srv/bundles/<bundle>/kit/r770-evidence/`, with every step's transcript

- [ ] **Step 1: Attach and mount the media read-only.** `AttachVolume` (`XFER_VOL`, `TARGET_ID`, `/dev/sdf`), poll until `in-use`, then:

```bash
DEV=$(lsblk -dpno NAME,SERIAL | awk -v s="XFERVOLSERIAL" '$2==s{print $1}'); test -n "$DEV"; echo "MEDIA_DEV=$DEV"
mkdir -p /mnt/xfer && mount -o ro "$DEV" /mnt/xfer && findmnt /mnt/xfer && ls /mnt/xfer
```
Expected: `bundle-YYYYMMDD harness log lost+found`. Record `MEDIA_DEV`.

- [ ] **Step 2: Install the deb agent, confirm, remove the snap.**

```bash
dpkg -i /mnt/xfer/harness/amazon-ssm-agent.deb && systemctl enable --now amazon-ssm-agent && systemctl is-active amazon-ssm-agent
```
Then from a *new* SSM call (proving the deb agent answers): `snap remove amazon-ssm-agent; snap list 2>/dev/null | grep -c ssm || echo 0; systemctl is-active amazon-ssm-agent`. Expected: `0` and `active`. If the first call returns and the second never connects, the deb agent is not registering: `StartInstances` after a `StopInstances` restores the snap agent (it is on the root volume); investigate from `/var/log/amazon/ssm/` before retrying.

- [ ] **Step 3: `discover`.**

```bash
K=/mnt/xfer/BUNDLE_NAME/kit/scripts/r770-install.sh
$K discover 2>&1 | tee /root/discover.log; echo "rc=${PIPESTATUS[0]}"
ip -br addr; ip -br link
```
Expected: rc=0, template at `/etc/lab/install.conf.template`. Read the output for `MGMT_IF` (the one interface with an address: `ens5`, `enp…` or similar — take it from the output) and its CIDR.

- [ ] **Step 4: Write `install.conf`** from the discover output only. Every value is one the output showed; `MEDIA_DEV` is the device from Step 1.

```bash
cat > /etc/lab/install.conf <<EOF
BUNDLE=/mnt/xfer/BUNDLE_NAME
MEDIA=/mnt/xfer
DEVICE=MEDIA_DEV
CAPTURE_IFS=lab_mirror0
LAB_BRIDGE=br-lab
MGMT_IF=<the interface discover showed>
MGMT_CIDR=<its network, a.b.c.d/n, from ip -br addr>
VALIDATE_AREAS=
INDEX_PATTERN=
EOF
cat /etc/lab/install.conf
```

- [ ] **Step 5: `plan`.** `$K plan 2>&1 | tee /root/plan.log; echo "rc=${PIPESTATUS[0]}"`. Expected: rc=0 and every gated step's dry-run printed; a refusal names the `install.conf` key to fix (a wrong `MGMT_CIDR` form, a device that is not a block device). Pull `/root/plan.log` into `$SCRATCH/e2e/log/`.

- [ ] **Step 6: `run`, first pass, detached.**

```bash
nohup /mnt/xfer/BUNDLE_NAME/kit/scripts/r770-install.sh run --yes --non-interactive > /root/run1.log 2>&1 &
echo started
```
Poll with `tail -n 25 /root/run1.log; pgrep -f 'r770-install.sh run' >/dev/null && echo RUNNING || echo DONE`, with `send_later` waits of 10–15 minutes between (import's copy and the three `load` steps are the long ones; expect 1–2 hours). After import, the installer hands off to `/srv/bundles/BUNDLE_NAME/kit/scripts/r770-install.sh` and carries on there, so the media is free from that point. The pass ends at `dashboards`, which lists the index patterns and stops: `grep -nE 'index pattern|INDEX_PATTERN|NOT INSTALLED|INSTALLED|FAIL' /root/run1.log` and read the summary at the path `summary:` names.

- [ ] **Step 7: Fill `INDEX_PATTERN`, second pass from the local copy.** Take the pattern the log listed (the one Malcolm's own dashboards use; `r770-malcolm-deploy.sh inventory` lists them too), write it into `/etc/lab/install.conf`, record it, then:

```bash
nohup /srv/bundles/BUNDLE_NAME/kit/scripts/r770-install.sh run --yes --non-interactive --from dashboards > /root/run2.log 2>&1 &
echo started
```
Poll as above. `validate` and `e2e` run every scenario; e2e is the long one. Expected end: the summary's verdict line. Per the spec, `NOT INSTALLED — finished with warnings from: …` naming only the licensed appliances is the pass; any other named step is a finding.

- [ ] **Step 8: One retry rule.** A step that FAILs gets one `--from <step>` on the local copy's installer after its transcript (`r770-evidence/<step>*.log` under the summary's directory) has been read and the cause written down. A second failure stops that pipeline; carry on with `--from <next step>` only if the installer's own summary says the later steps can run. Anything more needs the operator.

---

### Task 7: After the install: air-gap check, evidence onto the media, terminate

**Interfaces:**
- Consumes: `TARGET_ID XFER_VOL MEDIA_DEV CAP_TRIGGER`
- Produces: `/mnt/xfer/evidence/` holding everything from the target; the target terminated

- [ ] **Step 1: Air-gap check, after.** `/root/airgap-check.sh | tee /root/airgap-after.log`. Expected: every line `PASS  blocked`, including `docker pull` now that Docker exists.

- [ ] **Step 2: Unmount the media**, as the installer's last line asks: `umount /mnt/xfer && echo unmounted`. If it is busy, `fuser -vm /mnt/xfer` names the holder; it is a finding (the installer should hold nothing after hand-off).

- [ ] **Step 3: Evidence onto the media.** Remount read-write for this alone:

```bash
mount MEDIA_DEV /mnt/xfer && mkdir -p /mnt/xfer/evidence
cp -a /srv/bundles/BUNDLE_NAME/kit/r770-evidence /mnt/xfer/evidence/ 2>/dev/null || true
cp -a /root/*.log /etc/lab/install.conf /etc/lab/install.conf.template /var/log/cloud-init-output.log /mnt/xfer/evidence/
find /mnt/xfer/evidence -type f | wc -l; sync; umount /mnt/xfer && echo unmounted
```
Expected: a non-zero file count and `unmounted`. Then `DetachVolume` (`XFER_VOL`), poll until `available`.

- [ ] **Step 4: Terminate the target** (`TerminateInstances`), cancel `CAP_TRIGGER` and the check-in with `delete_trigger`, and record the termination time in `run.env`. Both its volumes are `DeleteOnTermination`.

---

### Task 8: Evidence to S3 and the report

**Files:**
- Create: `$SCRATCH/e2e/report.md`

**Interfaces:**
- Consumes: `STAGING_ID XFER_VOL BUCKET RUN`
- Produces: `s3://BUCKET/out/RUN/target/…` and `s3://BUCKET/out/RUN/report.md`

- [ ] **Step 1: Start staging, reattach the media.** `StartInstances` (`STAGING_ID`), wait for SSM `Online`, `AttachVolume` (`/dev/sdf`), then on the host mount it by serial as in Task 2 Step 4 (read-only is fine).

- [ ] **Step 2: Upload.**

```bash
aws s3 cp /mnt/xfer/evidence/ s3://BUCKET/out/RUN/target/ --recursive
aws s3 ls s3://BUCKET/out/RUN/target/ --recursive | wc -l
```
Expected: the same file count as Task 7 Step 3. Pull the summary `.md`, `validate`'s and `e2e`'s logs, and both air-gap logs into `$SCRATCH/e2e/log/` (`ssm` returns up to 8000 chars per call; `sed -n` by line ranges for longer files).

- [ ] **Step 3: Write `report.md`** with exactly these sections, each filled from the logs, never from memory:
  1. **Commits and bundle** — `BUILD_COMMIT`, `KIT_COMMIT_SRC`, `BUNDLE_NAME`, `BUNDLE_SIZE`, `BUNDLE_FILES`, `KIT_COMMIT`.
  2. **Air gap** — both logs verbatim.
  3. **Installer** — every step's row from the summary; `validate`'s PASS/WARN/FAIL/SKIP tally (its `footer` line); e2e's per-scenario lines.
  4. **Differences from the R770** — one line each: EBS/LVM not PERC; no physical capture ports (`lab_mirror0` only); SSM not SSH/iDRAC; licensed appliances absent; the deb SSM agent on the media; the VPC default route to the endpoints only.
  5. **Findings** — each with the log file and line that shows it, and whether it is a kit, bundle, or harness matter.
  6. **Pass bar** — the four spec conditions, each marked met / not met with the evidence line.

Upload it: `aws s3 cp report.md s3://BUCKET/out/RUN/report.md` (copy the file onto staging by heredoc first).

- [ ] **Step 4: Unmount, detach, done with staging.** `umount /mnt/xfer`, `DetachVolume`.

---

### Task 9: Tear down

**Interfaces:**
- Consumes: every ID in `run.env`

- [ ] **Step 1: Terminate staging** (`TerminateInstances STAGING_ID`); poll until `terminated`.
- [ ] **Step 2: Delete the transfer volume** (`DeleteVolume XFER_VOL`) — only after Task 8 Step 2's count matched.
- [ ] **Step 3: Delete the endpoints** (`DeleteVpcEndpoints VPCE_IDS`), poll until gone; then `DeleteSecurityGroup` for `SG_TARGET`, `SG_ENDPOINTS`, `SG_STAGING` (target first: the endpoint SG's ingress references it); `DisassociateRouteTable`/`DeleteRouteTable RT_PRIVATE`; `DeleteSubnet PRIVATE_SUBNET`.
- [ ] **Step 4: Delete the target role**: `RemoveRoleFromInstanceProfile`, `DeleteInstanceProfile`, `DetachRolePolicy`, `DeleteRole` for `simlab-e2e-target-ssm`.
- [ ] **Step 5: Verify nothing tagged `Run=RUN` remains**: `DescribeInstances`, `DescribeVolumes`, `DescribeVpcEndpoints`, `DescribeSecurityGroups`, `DescribeSubnets` each filtered on `tag:Run`. Expected: empty, apart from instances in `terminated`. The bucket, the 10-06 instance and `simlab-staging-ssm` are untouched.

---

### Task 10: Record the run in this repo

**Files:**
- Create: `state/inventory/aws-e2e-YYYY-MM-DD.md` (the report's sections 1, 3, 4, 5, 6, in the shape of `state/inventory/staging-installer-2026-10-04.md`; the air-gap logs summarised to their PASS/FAIL counts, the S3 paths named)
- Modify: `state/BUILD-STATE.md` — one Log line, dated, "Staging · AWS end-to-end rehearsal …", pointing at the inventory file and `s3://BUCKET/out/RUN/`

- [ ] **Step 1: Write both files** on branch `ccr-8e9ba072-kueo5e` (restart it from `origin/main` first). No evidence tree, no log, is committed.
- [ ] **Step 2: Run the gate.** `./tests/run.sh`; expected: only the seven known sleeper failures in this container, none elsewhere.
- [ ] **Step 3: Commit, push, open a draft PR, subscribe to it.** Commit message: "Record the AWS end-to-end rehearsal of <date>".
- [ ] **Step 4: Findings into PRs.** For each finding in report section 5 that is a kit or bundle matter: a PR in the right repo with the fix and a test, proven by one re-run of the affected stage, as the 10-06 findings were (#11, #19). Harness findings go into this plan's next revision.
