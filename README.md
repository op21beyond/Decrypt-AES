# AES Decryption Engine IP

**Version:** 0.1  
**Status:** Specification complete — RTL design in progress  
**Owner:** SSVD SoC Team  

---

> ⚠️ **[THROUGHPUT_TARGET]** Current throughput requirement: **200 Mbps**.  
> Search `THROUGHPUT_TARGET` across all files when updating this value.

---

## Overview

AES-128 CTR mode hardware decryption IP for SSVD SoC. Operates memory-to-memory using a descriptor-based circular command buffer. Supports CRC-32 integrity verification (IEEE 802.3 or Castagnoli, register-selectable).

## Repository Structure

```
Decrypt-AES/
├── prompt/
│   └── project-instructions.md     # Full project requirements and confirmed decisions
├── spec/
│   └── AES-Decrypt-IP-Specification.md   # IP implementation specification
├── doc/
│   └── (design notes, block diagrams, etc.)
├── design/
│   ├── rtl/                         # Verilog RTL source
│   └── tb/                          # Testbench, tasks, test data
├── host_software/
│   ├── pure/                        # Pure-software AES decrypt reference
│   └── driver/                      # IP register driver + test application
└── README.md                        # This file
```

## Quick Start

_To be filled in when RTL and host software are available._

## Key Parameters

| Parameter | Value | Note |
|---|---|---|
| Algorithm | AES-128 CTR | NIST SP 800-38A |
| Bus interface | AXI4 64-bit Manager + AXI4-Lite Subordinate | |
| Max descriptors | 1024 (register-configurable) | |
| Max read outstanding | 16 (register-configurable) | |
| CRC algorithms | CRC-32/IEEE 802.3, CRC-32C | Register-selectable |
| Throughput target | **200 Mbps** ⚠️ | `THROUGHPUT_TARGET` |

## Simulation

- Simulator: **NCVerilog**
- Waveform dump: **FSDB**

```
# Example (to be updated with actual command)
cd design/tb
ncverilog -f filelist.f +access+r +fsdb ...
```

## Changelog

### v0.1 — 2026-04-12
- Initial specification complete (`spec/AES-Decrypt-IP-Specification.md`)
- Project structure established
- Confirmed: AXI4 64-bit, 200 Mbps target, CRC-32 dual support, key via register
