# R770 Precheck Report — `testbed` (2026-09-02)

> Verbatim output of `r770-precheck.sh` v2 (read-only Phase 1 discovery), run 2026-09-02 09:28 UTC on the Dell PowerEdge R770 (service tag G8WFGH4).
> Result: **14 PASS / 7 WARN / 0 FAIL — proceed with caution** (WARNs reviewed and dispositioned in `r770-discovery-findings.md`).
> Companion record: `r770-idrac-inventory-G8WFGH4.md` (iDRAC hardware inventory, closes the PERC/NIC-media items this run could not see).

## Check Results

```text
PASS  Ubuntu 24.04 LTS detected
PASS  Chassis reports PowerEdge R770
PASS  UEFI boot mode
Secure Boot: SecureBoot disabled
WARN  ipmitool not installed — iDRAC state unverified from host; confirm OOB console access manually before Phase 5
PASS  2 CPU sockets populated
PASS  32 physical cores visible
PASS  64 logical threads visible (SMT on)
PASS  2 NUMA nodes (standard dual-socket layout)
PASS  Intel VT-x (vmx) flag present
PASS  IOMMU/VT-d activity visible in dmesg
PASS  /dev/kvm present
PASS  ~128 GB RAM visible (125 GiB)
PASS  8 DIMMs populated (4/socket = half of 8 channels each; §8 bandwidth caveat applies)
WARN  No perccli/storcli found — PERC VD layout, cache policy, and usable capacity UNVERIFIED (top unknown in the plan). Install Dell's perccli in Phase 2.
Largest block device: 7.7 TB
PASS  RAID VD ≈ 7.7 TB — looks like ~8 TB usable: scale up lv_pcap/lv_index per plan §3.2
WARN  Broadcom bnxt_en ports found: 10 (expected 8) — check OCP adapter seating/BIOS enumeration
Capture-port NUMA node(s): 0 1
WARN  Confirm capture-NIC media type in NIC table above (inventory says BASE-T; 57412 is normally SFP+ / 57416 is BASE-T)
PASS  Management/default path: dev lacp-trunk.10, src 10.10.10.31 — record this; it must survive every later phase
WARN  Default gateway 10.10.10.1 did not answer ping (may be filtered)
WARN  DNS resolution failed — expected on the gapped box; local dnsmasq comes later
WARN  12 kernel error line(s) this boot — review 08-health.txt

================ PRECHECK SUMMARY ================
Host: testbed   Time: 2026-09-02T09:28:39+00:00
PASS: 14   WARN: 7   FAIL: 0
RESULT: PROCEED WITH CAUTION — review WARN items; several are expected pre-install.
==================================================

```

## 1. Identity / Os

```text
$ hostnamectl
 Static hostname: testbed
       Icon name: computer-server
         Chassis: server 🖳
      Machine ID: 2e6691a0cf3b4b819ae32976040ef5ab
         Boot ID: 0829f3c4980447bb951c7156952f5c23
Operating System: Ubuntu 24.04.4 LTS
          Kernel: Linux 6.8.0-136-generic
    Architecture: x86-64
 Hardware Vendor: Dell Inc.
  Hardware Model: PowerEdge R770
Firmware Version: 1.7.5
   Firmware Date: Fri 2026-01-16
  ...[+1 lines truncated — full output: 01-os.txt]

$ uname -a
Linux testbed 6.8.0-136-generic #136-Ubuntu SMP PREEMPT_DYNAMIC Wed Jul  1 21:53:05 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
os-release: Ubuntu 24.04.4 LTS

$ uptime
 09:27:48 up 12 days, 22:10,  1 user,  load average: 0.00, 0.00, 0.00

```

## 2. PLATFORM / FIRMWARE / BOOT / iDRAC

```text
Model:       PowerEdge R770
Service tag: G8WFGH4   (needed for Dell firmware downloads — runbook Step 0E)
BIOS:        1.7.5 (01/16/2026)
Boot mode:   UEFI
Secure Boot: SecureBoot disabled

```

## 3. Cpu / Numa / Virtualization

```text
$ lscpu
Architecture:                            x86_64
CPU op-mode(s):                          32-bit, 64-bit
Address sizes:                           52 bits physical, 57 bits virtual
Byte Order:                              Little Endian
CPU(s):                                  64
On-line CPU(s) list:                     0-63
Vendor ID:                               GenuineIntel
BIOS Vendor ID:                          Intel
Model name:                              Intel(R) Xeon(R) 6515P
BIOS Model name:                         Intel(R) Xeon(R) 6515P  CPU @ 2.3GHz
BIOS CPU family:                         179
CPU family:                              6
Model:                                   173
Thread(s) per core:                      2
Core(s) per socket:                      16
Socket(s):                               2
Stepping:                                1
CPU(s) scaling MHz:                      31%
CPU max MHz:                             3800.0000
CPU min MHz:                             800.0000
BogoMIPS:                                4600.00
Flags:                                   fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf tsc_known_freq pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid dca sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cat_l2 cdp_l3 intel_ppin cdp_l2 ssbd mba ibrs ibpb stibp ibrs_enhanced tpr_shadow flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid cqm rdt_a avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb intel_pt avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local split_lock_detect user_shstk avx_vnni avx512_bf16 wbnoinvd dtherm ida arat pln pts vnmi avx512vbmi umip pku ospke waitpkg avx512_vbmi2 gfni vaes vpclmulqdq avx512_vnni avx512_bitalg tme avx512_vpopcntdq la57 rdpid bus_lock_detect cldemote movdiri movdir64b enqcmd fsrm md_clear serialize tsxldtrk pconfig arch_lbr ibt amx_bf16 avx512_fp16 amx_tile amx_int8 flush_l1d arch_capabilities ibpb_exit_to_user
Virtualization:                          VT-x
L1d cache:                               1.5 MiB (32 instances)
L1i cache:                               2 MiB (32 instances)
L2 cache:                                64 MiB (32 instances)
L3 cache:                                144 MiB (2 instances)
NUMA node(s):                            2
NUMA node0 CPU(s):                       0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60,62
NUMA node1 CPU(s):                       1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55,57,59,61,63
  ...[+17 lines truncated — full output: 03-cpu.txt]

$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62
node 0 size: 64068 MB
node 0 free: 61900 MB
node 1 cpus: 1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 33 35 37 39 41 43 45 47 49 51 53 55 57 59 61 63
node 1 size: 64496 MB
node 1 free: 63156 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10

$ lscpu -e (condensed: node -> cpus, core -> sibling threads)
node0 cpus: 0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62
node1 cpus: 1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 33 35 37 39 41 43 45 47 49 51 53 55 57 59 61 63
core0   siblings: 0 40
core1   siblings: 1 33
core2   siblings: 2 34
core3   siblings: 3 35
core4   siblings: 4 36
core5   siblings: 5 37
core6   siblings: 6 38
core7   siblings: 7 39
core8   siblings: 8 32
core9   siblings: 9 41
core10  siblings: 10 42
core11  siblings: 11 43
core12  siblings: 12 44
core13  siblings: 13 45
core14  siblings: 14 46
core15  siblings: 15 47
core16  siblings: 16 48
core17  siblings: 17 49
core18  siblings: 18 50
core19  siblings: 19 51
core20  siblings: 20 52
core21  siblings: 21 53
core22  siblings: 22 54
core23  siblings: 23 55
core24  siblings: 24 56
core25  siblings: 25 57
core26  siblings: 26 58
core27  siblings: 27 59
core28  siblings: 28 60
core29  siblings: 29 61
core30  siblings: 30 62
core31  siblings: 31 63

$ dmesg | grep -iE "iommu|dmar" (first 8)
[    0.007240] ACPI: DMAR 0x0000000077294000 000678 (v01 DELL   PE_SC3   00000001 INTL 20230628)
[    0.007265] ACPI: Reserving DMAR table memory at [mem 0x77294000-0x77294677]
[    0.560534] DMAR: Host address width 52
[    0.560537] DMAR: DRHD base: 0x000000cbfe0000 flags: 0x0
[    0.560549] DMAR: dmar0: reg_base_addr cbfe0000 ver 7:0 cap f9ed008cee780c66 ecap 3fef9ea6f0efdf
[    0.560570] DMAR: DRHD base: 0x000000cc7e0000 flags: 0x0
[    0.560578] DMAR: dmar1: reg_base_addr cc7e0000 ver 7:0 cap f9ed008cee780c66 ecap 3fef9ea6f0efdf
[    0.560592] DMAR: DRHD base: 0x000000d37c0000 flags: 0x0

```

## 4. Memory

```text
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           125Gi       3.8Gi       122Gi        11Mi       505Mi       121Gi
Swap:             0B          0B          0B

$ dmidecode -t memory (populated DIMMs, condensed)
A1           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
A2           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
A3           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
A4           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
B1           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
B2           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
B3           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF
B4           16 GB      6400 MT/s      rank=   DDR5   MTC10F1084S1RC64BH1 3SFF

```

## 5. STORAGE (top unknown: usable RAID capacity, PERC model)

```text
$ lsblk -e7 -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
NAME                            MODEL SERIAL                            SIZE TYPE FSTYPE      MOUNTPOINTS
sda                             RAID  00ee8552e0f325cd690087ce8680e04e    7T disk
├─sda1                                                                    1G part vfat        /boot/efi
├─sda2                                                                    2G part ext4        /boot
└─sda3                                                                    7T part LVM2_member
  ├─ubuntu--vg0-lv--tmp                                                   2G lvm  ext4        /tmp
  ├─ubuntu--vg0-lv--var                                                   6G lvm  ext4        /var
  ├─ubuntu--vg0-lv--varlog                                                2G lvm  ext4        /var/log
  ├─ubuntu--vg0-lv--varlogaudit                                           2G lvm  ext4        /var/log/audit
  ├─ubuntu--vg0-lv--root                                                 50G lvm  ext4        /
  └─ubuntu--vg0-lv--home                                               84.9G lvm  ext4        /home

$ findmnt --real
TARGET               SOURCE                                  FSTYPE OPTIONS
/                    /dev/mapper/ubuntu--vg0-lv--root        ext4   rw,relatime
├─/tmp               /dev/mapper/ubuntu--vg0-lv--tmp         ext4   rw,relatime
├─/home              /dev/mapper/ubuntu--vg0-lv--home        ext4   rw,relatime
├─/var               /dev/mapper/ubuntu--vg0-lv--var         ext4   rw,relatime
│ └─/var/log         /dev/mapper/ubuntu--vg0-lv--varlog      ext4   rw,relatime
│   └─/var/log/audit /dev/mapper/ubuntu--vg0-lv--varlogaudit ext4   rw,relatime
└─/boot              /dev/sda2                               ext4   rw,relatime
  └─/boot/efi        /dev/sda1                               vfat   rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro

$ df -h
Filesystem                               Size  Used Avail Use% Mounted on
tmpfs                                     13G  2.7M   13G   1% /run
efivarfs                                 304K  175K  125K  59% /sys/firmware/efi/efivars
/dev/mapper/ubuntu--vg0-lv--root          49G  2.3G   45G   5% /
tmpfs                                     63G     0   63G   0% /dev/shm
tmpfs                                    5.0M     0  5.0M   0% /run/lock
/dev/mapper/ubuntu--vg0-lv--tmp          2.0G   92K  1.8G   1% /tmp
/dev/mapper/ubuntu--vg0-lv--home          84G  376K   79G   1% /home
/dev/mapper/ubuntu--vg0-lv--var          5.9G  239M  5.3G   5% /var
/dev/sda2                                2.0G  105M  1.7G   6% /boot
/dev/mapper/ubuntu--vg0-lv--varlog       2.0G   86M  1.8G   5% /var/log
/dev/sda1                                1.1G  6.2M  1.1G   1% /boot/efi
/dev/mapper/ubuntu--vg0-lv--varlogaudit  2.0G   24K  1.8G   1% /var/log/audit
tmpfs                                     13G   12K   13G   1% /run/user/1001

$ bash -c lspci -nn | grep -i -E 'raid|storage|nvme|sas' || echo none-matched
0000:36:00.0 USB controller [0c03]: Renesas Technology Corp. uPD720201 USB 3.0 Host Controller [1912:0014] (rev 03)
0000:ac:00.0 PCI bridge [0604]: Broadcom / LSI Fusion-MPT Switch SAS50xx/SAS51xx [1000:00b8]
0000:ad:00.0 PCI bridge [0604]: Broadcom / LSI Fusion-MPT Switch SAS50xx/SAS51xx [1000:00b8]
0000:ad:01.0 PCI bridge [0604]: Broadcom / LSI Fusion-MPT Switch SAS50xx/SAS51xx [1000:00b8]
0000:ad:02.0 PCI bridge [0604]: Broadcom / LSI Fusion-MPT Switch SAS50xx/SAS51xx [1000:00b8]
0000:ad:03.0 PCI bridge [0604]: Broadcom / LSI Fusion-MPT Switch SAS50xx/SAS51xx [1000:00b8]
0000:ae:00.0 RAID bus controller [0104]: Broadcom / LSI Fusion-MPT 24G SAS/PCIe SAS50xx/SAS51xx [1000:00b3]
0000:af:00.0 RAID bus controller [0104]: Broadcom / LSI Fusion-MPT 24G SAS/PCIe SAS50xx/SAS51xx [1000:00b5]
  ...[+2 lines truncated — full output: 05-storage.txt]
nvme-cli not installed (NVMe behind PERC may not show here anyway)
smartmontools not installed — SMART health deferred to Phase 2
(no perccli/storcli — VD topology must come from lsblk sizes + Dell tools later)

```

## 6. NICs (top unknowns: media type SFP+/BASE-T, NUMA locality)

```text
$ bash -c lspci -nn | grep -i ethernet || echo none-matched
0000:5c:00.0 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57414 NetXtreme-E 10Gb/25Gb RDMA Ethernet Controller [14e4:16d7] (rev 01)
0000:5c:00.1 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57414 NetXtreme-E 10Gb/25Gb RDMA Ethernet Controller [14e4:16d7] (rev 01)
0000:84:00.0 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0000:84:00.1 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0000:85:00.0 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0000:85:00.1 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0001:36:00.0 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0001:36:00.1 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0001:37:00.0 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)
0001:37:00.1 Ethernet controller [0200]: Broadcom Inc. and subsidiaries BCM57412 NetXtreme-E 10Gb RDMA Ethernet Controller [14e4:16d6] (rev 01)

$ NIC summary (physical interfaces)
IFACE          DRIVER     PCI-ADDR       NUMA LINK   SPEED     MEDIA              FIRMWARE
bonding_masters ?          ?              ?    ?      ?         ?                  ?
eno16795np0    bnxt_en    0001:36:00.0   1    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno16805np1    bnxt_en    0001:36:00.1   1    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno16815np0    bnxt_en    0001:37:00.0   1    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno16825np1    bnxt_en    0001:37:00.1   1    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno17295np0    bnxt_en    0000:5c:00.0   0    up     25000     FIBRE              233.0.195.0/pkg 233.1.181.0
eno17305np1    bnxt_en    0000:5c:00.1   0    up     25000     FIBRE              233.0.195.0/pkg 233.1.181.0
eno17395np0    bnxt_en    0000:85:00.0   0    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno17405np1    bnxt_en    0000:85:00.1   0    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno17415np0    bnxt_en    0000:84:00.0   0    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
eno17425np1    bnxt_en    0000:84:00.1   0    down   -1        TP                 233.0.195.0/pkg 233.1.181.0
lacp-trunk     bonding    ?              ?    up     50000     ?                  2
lacp-trunk.10  802.1Q     ?              ?    up     50000     ?                  N/A

$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
eno17295np0      UP             82:f4:71:f1:b9:8e <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
eno17305np1      UP             82:f4:71:f1:b9:8e <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
eno17415np0      DOWN           6c:83:75:f4:45:82 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno17425np1      DOWN           6c:83:75:f4:45:83 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno17395np0      DOWN           6c:83:75:f4:45:70 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno17405np1      DOWN           6c:83:75:f4:45:71 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno16795np0      DOWN           6c:83:75:f3:e2:d0 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno16805np1      DOWN           6c:83:75:f3:e2:d1 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno16815np0      DOWN           6c:83:75:f3:e2:e2 <NO-CARRIER,BROADCAST,MULTICAST,UP>
eno16825np1      DOWN           6c:83:75:f3:e2:e3 <NO-CARRIER,BROADCAST,MULTICAST,UP>
lacp-trunk       UP             82:f4:71:f1:b9:8e <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP>
lacp-trunk.10@lacp-trunk UP             82:f4:71:f1:b9:8e <BROADCAST,MULTICAST,UP,LOWER_UP>

$ ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
eno17295np0      UP
eno17305np1      UP
eno17415np0      DOWN
eno17425np1      DOWN
eno17395np0      DOWN
eno17405np1      DOWN
eno16795np0      DOWN
eno16805np1      DOWN
eno16815np0      DOWN
eno16825np1      DOWN
lacp-trunk       UP             fe80::80f4:71ff:fef1:b98e/64
lacp-trunk.10@lacp-trunk UP             10.10.10.31/24 fe80::80f4:71ff:fef1:b98e/64
Capture-port NUMA node(s): 0 1
PERC NUMA node: 0 (dev 0000:ae:00.0)

$ (sudo) ethtool -l eno16795np0
Channel parameters for eno16795np0:
Pre-set maximums:
RX:             37
TX:             37
Other:          n/a
Combined:       74
Current hardware settings:
RX:             0
TX:             0
Other:          n/a
Combined:       16

$ (sudo) ethtool -g eno16795np0
Ring parameters for eno16795np0:
Pre-set maximums:
RX:                     2047
RX Mini:                n/a
RX Jumbo:               8191
TX:                     2047
TX push buff len:       n/a
Current hardware settings:
RX:                     511
RX Mini:                n/a
RX Jumbo:               2044
TX:                     511
RX Buf Len:             n/a
CQE Size:               n/a
  ...[+4 lines truncated — full output: 06-nics.txt]

$ (sudo) bash -c ethtool -k eno16795np0 | grep -E 'gro|large-receive|tcp-segmentation|generic-segmentation|rx-checksum|tx-checksum|vlan-offload'
rx-checksumming: on
tx-checksumming: on
        tx-checksum-ipv4: on
        tx-checksum-ip-generic: off [fixed]
        tx-checksum-ipv6: on
        tx-checksum-fcoe-crc: off [fixed]
        tx-checksum-sctp: off [fixed]
tcp-segmentation-offload: on
        tx-tcp-segmentation: on
generic-segmentation-offload: on
large-receive-offload: off
rx-vlan-offload: on
tx-vlan-offload: on
rx-gro-hw: on
  ...[+2 lines truncated — full output: 06-nics.txt]

```

## 7. MANAGEMENT PATH (must survive every later phase)

```text
$ ip route get 1.1.1.1
1.1.1.1 via 10.10.10.1 dev lacp-trunk.10 src 10.10.10.31 uid 0
    cache

$ ip route
default via 10.10.10.1 dev lacp-trunk.10 proto static
10.10.10.0/24 dev lacp-trunk.10 proto kernel scope link src 10.10.10.31

$ bash -c ls -l /etc/netplan/
total 4
-rw------- 1 root root 1142 Aug 13 12:14 00-h2-init.yaml

$ (sudo) bash -c for f in /etc/netplan/*.yaml; do echo "--- $f"; cat "$f"; done 2>/dev/null
--- /etc/netplan/00-h2-init.yaml

network:
  version: 2
  ethernets:
    eno17295np0:
      dhcp4: false
      dhcp6: false
    eno17305np1:
      dhcp4: false
      dhcp6: false
    eno17415np0:
      dhcp4: false
      dhcp6: false
    eno17425np1:
      dhcp4: false
      dhcp6: false
    eno17395np0:
      dhcp4: false
      dhcp6: false
    eno17405np1:
      dhcp4: false
      dhcp6: false
    eno16795np0:
      dhcp4: false
      dhcp6: false
    eno16805np1:
      dhcp4: false
      dhcp6: false
    eno16815np0:
      dhcp4: false
      dhcp6: false
    eno16825np1:
      dhcp4: false
      dhcp6: false
  bonds:
    lacp-trunk:
      interfaces:
        - eno17295np0
        - eno17305np1
  ...[+22 lines truncated — full output: 07-mgmt-path.txt]

$ resolvectl status
Global
         Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
  resolv.conf mode: uplink

Link 2 (eno17295np0)
    Current Scopes: none
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported

Link 3 (eno17305np1)
    Current Scopes: none
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported

Link 4 (eno17415np0)
    Current Scopes: none
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported

Link 5 (eno17425np1)
    Current Scopes: none
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported

  ...[+33 lines truncated — full output: 07-mgmt-path.txt]

```

## 8. Health / Errors

```text
$ (sudo) bash -c dmesg --level=err,warn | tail -30
[654179.182685] kauditd_printk_skb: 94 callbacks suppressed
[794317.687785] kauditd_printk_skb: 94 callbacks suppressed
[868171.435834] kauditd_printk_skb: 94 callbacks suppressed
[929193.681921] kauditd_printk_skb: 94 callbacks suppressed
[1022346.419653] kauditd_printk_skb: 94 callbacks suppressed
[1107446.103992] kauditd_printk_skb: 94 callbacks suppressed
[1108344.459599] kauditd_printk_skb: 94 callbacks suppressed
[1108467.859941] workqueue: console_callback hogged CPU for >10000us 4 times, consider switching to WQ_UNBOUND
[1110586.891788] kauditd_printk_skb: 94 callbacks suppressed
[1112391.891833] workqueue: drm_fb_helper_damage_work hogged CPU for >10000us 256 times, consider switching to WQ_UNBOUND
[1112406.444477] sr 4:0:0:0: Power-on or device reset occurred
[1112406.771716] sd 4:0:0:1: Power-on or device reset occurred
[1112432.236618] sr 4:0:0:0: Power-on or device reset occurred
[1112432.562491] sd 4:0:0:1: Power-on or device reset occurred
[1113382.380333] sr 4:0:0:0: Power-on or device reset occurred
[1113382.709954] sd 4:0:0:1: Power-on or device reset occurred
[1114566.252249] sr 4:0:0:0: Power-on or device reset occurred
[1114566.582214] sd 4:0:0:1: Power-on or device reset occurred
[1114827.554746] workqueue: drm_fb_helper_damage_work hogged CPU for >10000us 512 times, consider switching to WQ_UNBOUND
[1115905.324497] sd 5:0:0:0: Power-on or device reset occurred
[1115905.324783] sr 4:0:0:0: Power-on or device reset occurred
[1115905.328130] sd 5:0:0:0: [sdb] No Caching mode page found
[1115905.328133] sd 5:0:0:0: [sdb] Assuming drive cache: write through
[1115946.764037] sd 5:0:0:0: [sdb] tag#0 access beyond end of device
[1115946.764065] I/O error, dev sdb, sector 34 op 0x0:(READ) flags 0x84700 phys_seg 240 prio class 2
[1115946.764114] sd 5:0:0:0: [sdb] tag#0 access beyond end of device
[1115946.764125] I/O error, dev sdb, sector 274 op 0x0:(READ) flags 0x80700 phys_seg 239 prio class 2
[1115946.764753] sd 5:0:0:0: [sdb] tag#0 access beyond end of device
[1115946.764767] I/O error, dev sdb, sector 34 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2
[1115946.764785] FAT-fs (sdb1): FAT read failed (blocknr 33)

$ bash -c journalctl -p err -b --no-pager 2>/dev/null | tail -15 || true
Sep 02 06:42:52 testbed systemd-networkd-wait-online[32926]: Timeout occurred while waiting for network connectivity.
Sep 02 06:51:42 testbed login[2198]: PAM unable to dlopen(pam_lastlog.so): /usr/lib/security/pam_lastlog.so: cannot open shared object file: No such file or directory
Sep 02 06:51:42 testbed login[2198]: PAM adding faulty module: pam_lastlog.so
Sep 02 06:53:18 testbed adduser[33317]: Only root may add a user or group to the system.
Sep 02 07:09:06 testbed login[33414]: PAM unable to dlopen(pam_lastlog.so): /usr/lib/security/pam_lastlog.so: cannot open shared object file: No such file or directory
Sep 02 07:09:06 testbed login[33414]: PAM adding faulty module: pam_lastlog.so
Sep 02 07:45:42 testbed login[33594]: PAM unable to dlopen(pam_lastlog.so): /usr/lib/security/pam_lastlog.so: cannot open shared object file: No such file or directory
Sep 02 07:45:42 testbed login[33594]: PAM adding faulty module: pam_lastlog.so
Sep 02 09:16:28 testbed kernel: sd 5:0:0:0: [sdb] tag#0 access beyond end of device
Sep 02 09:16:28 testbed kernel: I/O error, dev sdb, sector 34 op 0x0:(READ) flags 0x84700 phys_seg 240 prio class 2
Sep 02 09:16:28 testbed kernel: sd 5:0:0:0: [sdb] tag#0 access beyond end of device
Sep 02 09:16:28 testbed kernel: I/O error, dev sdb, sector 274 op 0x0:(READ) flags 0x80700 phys_seg 239 prio class 2
Sep 02 09:16:28 testbed kernel: sd 5:0:0:0: [sdb] tag#0 access beyond end of device
Sep 02 09:16:28 testbed kernel: I/O error, dev sdb, sector 34 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2
Sep 02 09:16:28 testbed kernel: FAT-fs (sdb1): FAT read failed (blocknr 33)

```

## 9. TOOLS PRESENT vs NEEDED LATER

```text
present: ethtool
MISSING (install in its phase): nvme
MISSING (install in its phase): smartctl
present: numactl
MISSING (install in its phase): ipmitool
present: mokutil
present: jq
present: git
present: curl
present: tcpdump
MISSING (install in its phase): tshark
MISSING (install in its phase): iperf3
present: mtr
MISSING (install in its phase): lvm2
MISSING (install in its phase): docker
MISSING (install in its phase): virsh
present: tc
MISSING (install in its phase): sensors

```

---
*Full per-section logs remain on the server in the `r770-precheck-testbed-20260902-092839/` output directory (root-owned).*
