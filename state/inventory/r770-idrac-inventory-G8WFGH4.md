# iDRAC Hardware Inventory — PowerEdge R770 `G8WFGH4`

> Rendered from the iDRAC export `G8WFGH4HardwareInventory.xml` (pulled 2026-09-03). This is the authoritative hardware-of-record for the sim-lab R770; analysis and plan impacts live in `r770-discovery-findings.md`. Companion record: `r770-precheck-report-2026-09-02.md` (OS-side view).

## System

| Field | Value |
|---|---|
| Model | PowerEdge R770 |
| Service tag | G8WFGH4 |
| Express service code | 35366715688 |
| System ID / generation | 17G Monolithic |
| BIOS | 1.7.5 |
| BIOS release date | 01/16/2026 |
| Lifecycle Controller | 1.30.20.10 |
| FPGA/CPLD | 109.125.104 |
| Board part number | 0GXH30 |
| Board serial | VNWSV0062500T5 |
| Chassis height | 2 U |
| Host name (last seen) | MINWINPC |
| Total memory | 128 GB |
| Max memory | 8388608 MB |
| DIMM slots populated/max | 8 / 32 |
| CPU sockets populated/max | 2 / 2 |
| PCIe slots populated/max | 7 / 8 |
| Memory operation mode | OptimizerMode |
| Power state | On |
| Power cap | 32767 Watts |
| Overall rollup status | OK |

## iDRAC

| Field | Value |
|---|---|
| Product | This system component provides a complete set of remote management functions for PowerEdge servers |
| Firmware | 1.30.20.10 |
| DNS name | testbed-idrac |
| URL | https://192.168.76.231:443 |
| MAC | 28:00:af:df:bc:8c |
| IPMI version | 2.0 |
| IPMI-over-LAN | Disabled |
| Serial-over-LAN | Enabled |

Note: IPMI-over-LAN disabled → use Redfish/web UI for OOB automation, not ipmitool.

## Processors

| Socket | Model | Cores | Threads | Base/Max clock | L3 | Turbo | VT-x | HT | Status |
|---|---|---|---|---|---|---|---|---|---|
| CPU0 | Intel(R) Xeon(R) 6515P | 16 | 32 | 2300 MHz / 4300 MHz | 73728 KB | Yes | Yes | Yes | OK |
| CPU1 | Intel(R) Xeon(R) 6515P | 16 | 32 | 2300 MHz / 4300 MHz | 73728 KB | Yes | Yes | Yes | OK |

## Memory

| Slot | Size | Speed (rated/operating) | Type | Rank | Manufacturer | Part number | Serial | Status |
|---|---|---|---|---|---|---|---|---|
| A1 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D24D96 | OK |
| A2 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D278EE | OK |
| A3 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D24DB9 | OK |
| A4 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D277E0 | OK |
| B1 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D278CF | OK |
| B2 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D24D9C | OK |
| B3 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D278D7 | OK |
| B4 | 16384 MB | 6400 MHz / 6400 MT/s | RDIMM | Single Rank | Micron Technology | MTC10F1084S1RC64BH1 3SFF | 54D24D47 | OK |

## Storage

### RAID controller

| Field | Value |
|---|---|
| Model | PERC H975i Front |
| Location | RAID Controller in SL 3 |
| Firmware | 8.14.0.0.28-40 |
| Cache size | — |
| Security status | Security Key Assigned |
| Encryption mode | Enabled |
| Patrol read | Stopped |
| Rollup status | OK |
| Energy pack | OK (Ready) |

⚠️ **Encryption is Enabled with a Security Key Assigned** — determine LKM vs SEKM and record key custody/escrow in the recovery runbook before evidence-grade data lands on the VD.

### Virtual disk

| Field | Value |
|---|---|
| Name | vd0 |
| RAID level | RAID1 |
| Size | 7680877920256 bytes (≈7.68 TB) |
| Stripe size | 64KB |
| Read cache | No Read Ahead |
| Write cache | Write Back |
| Disk cache | Default |
| Bus protocol | PCIE |
| Media | Solid State Drive |
| Remaining redundancy | 1 |
| Status | OK |

### Physical drives

| Bay | Manufacturer | Protocol | Form factor | Size | Link (neg/cap) | Endurance left | State | Serial |
|---|---|---|---|---|---|---|---|---|
| 0 | KIOXIA Corporation | NVMe 2.0 | E3.S | ≈7.68 TB | x2 / x4 | 100 % | Online | 2G60A02N04J3 |
| 1 | KIOXIA Corporation | NVMe 2.0 | E3.S | ≈7.68 TB | x2 / x4 | 100 % | Online | 2G60A03504J3 |

Backplane: Backplane 1 on Connector 0 of RAID Controller in SL 3 — **16 slots** (2 populated → 14 free for expansion), firmware 1.92.

## Network adapters

| Port (FQDD) | Product | Permanent MAC | Part number | Slot type | Link | FW family |
|---|---|---|---|---|---|---|
| NIC.Slot.10-1-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f4:45:70 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.10-2-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f4:45:71 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.10-3-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f4:45:82 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.10-4-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f4:45:83 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.4-1-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f3:e2:d0 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.4-2-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f3:e2:d1 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.4-3-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f3:e2:e2 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.4-4-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | 6c:83:75:f3:e2:e3 | BCM957412-N410TGI0S | OCP NIC 3.0 Small Form Factor | Unknown | 233.1.181.0 |
| NIC.Slot.9-1-1 | Broadcom BCM57414 2x25G PCIe Ethernet NIC | 40:5b:7f:7e:53:e0 | — | PCI Express Gen 5 | 25 Gbps | 233.1.181.0 |
| NIC.Slot.9-2-1 | Broadcom BCM57414 2x25G PCIe Ethernet NIC | 40:5b:7f:7e:53:e1 | — | PCI Express Gen 5 | 25 Gbps | 233.1.181.0 |

Media resolution: `BCM957412-N410TGI0S` = **4×10GBASE-T (RJ45 copper)** quads in OCP Slot 4 (NUMA node 1) and Slot 10 (NUMA node 0); the BCM57414 2×25G in PCIe Slot 9 (Gen5, node 0) carries the LACP management bond.

### Transceivers

| Location | Type | Vendor | Part | Serial |
|---|---|---|---|---|
| Network Transceiver in NIC in Slot 9 Port 1 | SFP/SFP+/SFP28 | Dell | D0R73 | VN0LXV0057A2HF5 |
| Network Transceiver in NIC in Slot 9 Port 2 | SFP/SFP+/SFP28 | Dell | D0R73 | VN0LXV0057A2HOD |

## Power & cooling

| Component | Model/desc | Status | Detail |
|---|---|---|---|
| PSU.Slot.1 | PWR SPLY,1100W,RDNT,LITEON | OK | 1100 Watts out, input 209 Volts, Fully Redundant, fw 1408 |
| PSU.Slot.2 | PWR SPLY,1100W,RDNT,LITEON | OK | 1100 Watts out, input 209 Volts, Fully Redundant, fw 1408 |
| CoolingController.1.Fan1 | Fan1 | OK | Gold, redundancy: Fully Redundant |
| CoolingController.1.Fan2 | Fan2 | OK | Gold, redundancy: Fully Redundant |
| CoolingController.1.Fan3 | Fan3 | OK | Gold, redundancy: Fully Redundant |
| CoolingController.1.Fan4 | Fan4 | OK | Gold, redundancy: Fully Redundant |
| CoolingController.1.Fan5 | Fan5 | OK | Gold, redundancy: Fully Redundant |
| CoolingController.1.Fan6 | Fan6 | OK | Gold, redundancy: Fully Redundant |

## PCI devices (as enumerated by iDRAC)

| FQDD | Description | Slot/bus |
|---|---|---|
| HostBridge.Embedded.1-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 1 (seg 0) |
| HostBridge.Embedded.2-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 2 (seg 0) |
| HostBridge.Embedded.3-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 3 (seg 0) |
| HostBridge.Embedded.4-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 4 (seg 0) |
| HostBridge.Embedded.5-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 5 (seg 0) |
| HostBridge.Embedded.6-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 6 (seg 0) |
| HostBridge.Embedded.7-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 5 fn 7 (seg 0) |
| HostBridge.Embedded.8-1 | Xeon IMC0 Mesh to Mem Registers | bus 254 dev 6 fn 1 (seg 0) |
| ISABridge.Embedded.1-1 | Granite Rapids Chipset LPC Controller | bus 0 dev 31 fn 0 (seg 0) |
| NIC.Slot.10-1-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 133 dev 0 fn 0 (seg 0) |
| NIC.Slot.10-2-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 133 dev 0 fn 1 (seg 0) |
| NIC.Slot.10-3-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 132 dev 0 fn 0 (seg 0) |
| NIC.Slot.10-4-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 132 dev 0 fn 1 (seg 0) |
| NIC.Slot.4-1-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 54 dev 0 fn 0 (seg 1) |
| NIC.Slot.4-2-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 54 dev 0 fn 1 (seg 1) |
| NIC.Slot.4-3-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 55 dev 0 fn 0 (seg 1) |
| NIC.Slot.4-4-1 | Broadcom BCM57412 4x10GbT OCP Ethernet NIC | bus 55 dev 0 fn 1 (seg 1) |
| NIC.Slot.9-1-1 | BCM57414 NetXtreme-E 10Gb/25Gb RDMA Ethernet Controller | bus 92 dev 0 fn 0 (seg 0) |
| NIC.Slot.9-2-1 | BCM57414 NetXtreme-E 10Gb/25Gb RDMA Ethernet Controller | bus 92 dev 0 fn 1 (seg 0) |
| P2PBridge.SL.3-1 | Fusion-MPT Switch SAS50xx/SAS51xx | bus 172 dev 0 fn 0 (seg 0) |
| P2PBridge.SL.3-2 | Fusion-MPT Switch SAS50xx/SAS51xx | bus 173 dev 0 fn 0 (seg 0) |
| P2PBridge.SL.3-3 | Fusion-MPT Switch SAS50xx/SAS51xx | bus 173 dev 1 fn 0 (seg 0) |
| P2PBridge.SL.3-4 | Fusion-MPT Switch SAS50xx/SAS51xx | bus 173 dev 2 fn 0 (seg 0) |
| P2PBridge.SL.3-5 | Fusion-MPT Switch SAS50xx/SAS51xx | bus 173 dev 3 fn 0 (seg 0) |
| RAID.SL.3-1 | PERC H975i Front | bus 174 dev 0 fn 0 (seg 0) |
| RAID.SL.3-2 | PERC H975i Front - Virtual | bus 175 dev 0 fn 0 (seg 0) |
| RAID.SL.3-3 | PERC H975i Front - Virtual | bus 176 dev 0 fn 0 (seg 0) |
| RAID.SL.3-4 | PERC H975i Front - Virtual | bus 177 dev 0 fn 0 (seg 0) |
| SMBus.Embedded.1-1 | Granite Rapids SMBus Controller | bus 0 dev 31 fn 4 (seg 0) |
| SerialBus.Embedded.1-1 | Granite Rapids SPI Controller | bus 0 dev 31 fn 5 (seg 0) |
| USBXHCI.Embedded.1-1 | uPD720201 USB 3.0 Host Controller | bus 54 dev 0 fn 0 (seg 0) |
| Video.Embedded.1-1 | Integrated Matrox G200eW3 Graphics Controller | bus 53 dev 0 fn 0 (seg 0) |

