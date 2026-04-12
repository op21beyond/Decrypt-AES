# AES Decryption Engine IP — Implementation Specification

**Document Number:** SSVD-IP-AESDEC-SPEC-001  
**Version:** 0.1 (Draft)  
**Author:** SoC Team  
**Company:** SSVD  
**Date:** 2026-04-12  
**Status:** Draft — For Review

---

> ⚠️ **THROUGHPUT REQUIREMENT MARKER**  
> Target throughput is currently set to **200 Mbps**.  
> Search for `THROUGHPUT_TARGET` across all project files to update this value consistently if it changes.

---

## Table of Contents

1. [Introduction](#1-introduction)  
2. [Terminology](#2-terminology)  
3. [System Overview](#3-system-overview)  
4. [Interface Signals](#4-interface-signals)  
5. [Register Map](#5-register-map)  
6. [Descriptor Layout](#6-descriptor-layout)  
7. [Operational State Machine](#7-operational-state-machine)  
8. [AES Processing](#8-aes-processing)  
9. [CRC Processing](#9-crc-processing)  
10. [Interrupt Handling](#10-interrupt-handling)  
11. [Performance Requirements](#11-performance-requirements)  
12. [Bus Interface Specification](#12-bus-interface-specification)  
13. [Electrical and Physical Constraints](#13-electrical-and-physical-constraints)  
14. [Revision History](#14-revision-history)

---

## 1. Introduction

### 1.1 Purpose

This document specifies the implementation requirements for the **AES Decryption Engine IP** developed by Company for integration into the SSVD SoC. The IP decrypts AES-128 CTR-mode encrypted data streams stored in memory and writes the plaintext result back to memory without CPU involvement in the data path.

### 1.2 Scope

This specification covers:
- Functional behavior and state machine
- AXI4 bus interface requirements (both Manager and Subordinate)
- Register map and programming model
- Descriptor format and command buffer protocol
- AES-128 CTR decryption processing
- CRC-32 integrity checking
- Interrupt protocol
- Performance requirements

### 1.3 Intended Audience

- RTL design engineers implementing the IP
- Verification engineers developing the testbench
- Host software engineers writing the driver and test code
- SoC integration engineers

### 1.4 References

| Reference | Description |
|---|---|
| AMBA AXI4 Protocol Specification | ARM IHI0022E |
| FIPS PUB 197 | Advanced Encryption Standard (AES) |
| NIST SP 800-38A | Recommendation for Block Cipher Modes of Operation — CTR |
| ISO 3309 / ITU-T V.42 | CRC-32/IEEE 802.3 polynomial |
| RFC 3720 Appendix B.4 | CRC-32C (Castagnoli) polynomial |

---

## 2. Terminology

| Term | Definition |
|---|---|
| **Manager** | Bus initiator that issues read/write transactions (equivalent to AXI "M a s t e r") |
| **Subordinate** | Bus target that responds to transactions (equivalent to AXI "S l a v e") |
| **DUT** | Device Under Test |
| **SSVD** | The company requesting this IP |
| **SoC Team** | The team at SSVD responsible for SoC development |
| **Company** | The IP development organization |
| **Descriptor** | A data structure in memory that describes one decryption job |
| **Command Buffer** | A circular buffer in memory holding an ordered list of Descriptors |
| **AES Header** | Per-job data prepended to the encrypted payload containing IV and initial counter |
| **IV** | Initialization Vector — the 96-bit nonce portion of the AES-128 CTR counter block |
| **CTR** | AES Counter Mode of operation |
| **CRC** | Cyclic Redundancy Check — used for data integrity verification |

---

## 3. System Overview

### 3.1 Functional Description

The AES Decryption Engine IP is a **memory-to-memory** hardware accelerator. The host CPU software sets up a circular buffer of Descriptors in system memory, each Descriptor pointing to an input buffer (AES-encrypted data) and an output buffer (plaintext destination). The IP autonomously reads Descriptors, fetches encrypted data, performs AES-128 CTR decryption, verifies data integrity using CRC-32, and writes plaintext to the output buffer.

The IP operates without CPU involvement during the data path. The CPU communicates with the IP exclusively through:
1. Memory-mapped **control/status registers** (Subordinate AXI4-Lite interface)
2. Descriptor fields written back by the IP to system memory

### 3.2 Top-Level Block Diagram

```
                        System Memory
                    ┌─────────────────┐
                    │  Command Buffer │
                    │  (Descriptors)  │
                    ├─────────────────┤
                    │  Input Buffers  │
                    │ (Encrypted Data)│
                    ├─────────────────┤
                    │  Output Buffers │
                    │  (Plaintext)    │
                    └────────┬────────┘
                             │ AXI4 (64-bit)
                    ┌────────▼────────────────────────────────┐
                    │          AES Decryption Engine IP        │
                    │                                          │
  APB/AXI4-Lite ───►  Subordinate     ┌──────────────────┐   │
  (Register I/F)   │  Register        │  Descriptor      │   │
                   │  Interface       │  Fetch & Decode  │   │
  IRQ ◄────────────│                  └────────┬─────────┘   │
                   │  AXI4 Manager    ┌────────▼─────────┐   │
                   │  (Memory I/F) ◄──►  Input Buffer    │   │
                   │                  └────────┬─────────┘   │
                   │                  ┌────────▼─────────┐   │
                   │                  │  AES-128 CTR     │   │
                   │                  │  Decrypt Core    │   │
                   │                  └────────┬─────────┘   │
                   │                  ┌────────▼─────────┐   │
                   │                  │  CRC-32 Check    │   │
                   │                  └────────┬─────────┘   │
                   │                  ┌────────▼─────────┐   │
                   │                  │  Output Buffer   │   │
                   │                  │  & Write-back    │   │
                   │                  └──────────────────┘   │
                   └──────────────────────────────────────────┘
```

### 3.3 Key Features

- AES-128 CTR mode decryption
- Memory-to-memory descriptor-based DMA
- Circular command buffer with up to 1024 descriptors (configurable)
- CRC-32 data integrity checking (IEEE 802.3 or Castagnoli, register-selectable)
- AXI4 64-bit Manager interface with configurable outstanding read and write transactions (up to 16 each)
- AXI4-Lite Subordinate register interface
- Single interrupt output with per-descriptor enable
- Configurable AxCACHE and AxPROT per transaction type

---

## 4. Interface Signals

### 4.1 Clock and Reset

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | System clock. All signals are synchronous to rising edge. |
| `rst_n` | Input | 1 | Active-low asynchronous reset. |

### 4.2 AXI4 Manager Interface (Memory Bus)

Data width: 64 bits. Address width: 32 bits.  
Non-essential signals not listed below are not implemented. Tie-off values for required-but-unused fields are defined in [Section 12](#12-bus-interface-specification).

#### Write Address Channel (AW)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_awvalid` | Output | 1 | Write address valid |
| `m_axi_awready` | Input | 1 | Write address ready |
| `m_axi_awaddr` | Output | 32 | Write address |
| `m_axi_awlen` | Output | 8 | Burst length (AXI4: number of transfers minus 1) |
| `m_axi_awsize` | Output | 3 | Transfer size (fixed: `3'b011` = 8 bytes) |
| `m_axi_awburst` | Output | 2 | Burst type (fixed: `2'b01` = INCR) |
| `m_axi_awcache` | Output | 4 | Cache attributes — per output buffer write, set from register `AXI_CACHE_CTRL` |
| `m_axi_awprot` | Output | 3 | Protection attributes — per output buffer write, set from register `AXI_PROT_CTRL` |

#### Write Data Channel (W)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_wvalid` | Output | 1 | Write data valid |
| `m_axi_wready` | Input | 1 | Write data ready |
| `m_axi_wdata` | Output | 64 | Write data |
| `m_axi_wstrb` | Output | 8 | Write byte enables |
| `m_axi_wlast` | Output | 1 | Last transfer in burst |

#### Write Response Channel (B)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_bvalid` | Input | 1 | Write response valid |
| `m_axi_bready` | Output | 1 | Write response ready |
| `m_axi_bresp` | Input | 2 | Write response (OKAY / SLVERR / DECERR) |

#### Read Address Channel (AR)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_arvalid` | Output | 1 | Read address valid |
| `m_axi_arready` | Input | 1 | Read address ready |
| `m_axi_araddr` | Output | 32 | Read address |
| `m_axi_arlen` | Output | 8 | Burst length |
| `m_axi_arsize` | Output | 3 | Transfer size (fixed: `3'b011` = 8 bytes) |
| `m_axi_arburst` | Output | 2 | Burst type (fixed: `2'b01` = INCR) |
| `m_axi_arcache` | Output | 4 | Cache attributes — per transaction type, set from register `AXI_CACHE_CTRL` |
| `m_axi_arprot` | Output | 3 | Protection attributes — per transaction type, set from register `AXI_PROT_CTRL` |

#### Read Data Channel (R)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axi_rvalid` | Input | 1 | Read data valid |
| `m_axi_rready` | Output | 1 | Read data ready |
| `m_axi_rdata` | Input | 64 | Read data |
| `m_axi_rresp` | Input | 2 | Read response |
| `m_axi_rlast` | Input | 1 | Last transfer in burst |

### 4.3 AXI4-Lite Subordinate Interface (Register Bus)

Data width: 32 bits. Address width: 8 bits (256-byte register space).  
The Subordinate interface does not report bus errors: `BRESP` and `RRESP` are always `2'b00` (OKAY). Writes to read-only registers and reads from write-only registers are silently ignored or return `0x00000000` respectively.

| Signal | Direction | Width | Description |
|---|---|---|---|
| `s_axil_awvalid` | Input | 1 | Write address valid |
| `s_axil_awready` | Output | 1 | Write address ready |
| `s_axil_awaddr` | Input | 8 | Write address |
| `s_axil_wvalid` | Input | 1 | Write data valid |
| `s_axil_wready` | Output | 1 | Write data ready |
| `s_axil_wdata` | Input | 32 | Write data |
| `s_axil_wstrb` | Input | 4 | Write byte enables |
| `s_axil_bvalid` | Output | 1 | Write response valid |
| `s_axil_bready` | Input | 1 | Write response ready |
| `s_axil_bresp` | Output | 2 | Write response |
| `s_axil_arvalid` | Input | 1 | Read address valid |
| `s_axil_arready` | Output | 1 | Read address ready |
| `s_axil_araddr` | Input | 8 | Read address |
| `s_axil_rvalid` | Output | 1 | Read data valid |
| `s_axil_rready` | Input | 1 | Read data ready |
| `s_axil_rdata` | Output | 32 | Read data |
| `s_axil_rresp` | Output | 2 | Read response |

### 4.4 Interrupt

| Signal | Direction | Width | Description |
|---|---|---|---|
| `irq` | Output | 1 | Active-high level interrupt request. Remains asserted until all pending bits in `IRQ_STATUS` that have a corresponding enable bit set in `IRQ_ENABLE` are cleared by the host (W1C). |

---

## 5. Register Map

Base address: as assigned by SoC integration. All registers are 32-bit wide, accessed via AXI4-Lite Subordinate interface. All reserved bits read as 0 and must be written as 0.

### 5.1 Register Summary

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| `0x00` | `CTRL` | W | `0x0000_0000` | Control register |
| `0x04` | `STATUS` | Mixed | `0x0000_0001` | Status register ([1:0] RO, [2] W1C) |
| `0x08` | `IRQ_STATUS` | R/W1C | `0x0000_0000` | Interrupt status / clear |
| `0x0C` | `IRQ_ENABLE` | R/W | `0x0000_0000` | Interrupt enable mask |
| `0x10` | `CMD_BUF_ADDR` | R/W | `0x0000_0000` | Command buffer base address |
| `0x14` | `CMD_BUF_SIZE` | R/W | `0x0000_0000` | Command buffer depth (max descriptors) |
| `0x18` | `CMD_HEAD_PTR` | RO | `0x0000_0000` | Current descriptor head pointer (next to fetch) |
| `0x1C` | `CMD_TAIL_PTR` | R/W | `0x0000_0000` | Tail pointer written by host to advance ring |
| `0x20` | `AES_KEY_0` | WO | `0x0000_0000` | AES-128 key bits [31:0] |
| `0x24` | `AES_KEY_1` | WO | `0x0000_0000` | AES-128 key bits [63:32] |
| `0x28` | `AES_KEY_2` | WO | `0x0000_0000` | AES-128 key bits [95:64] |
| `0x2C` | `AES_KEY_3` | WO | `0x0000_0000` | AES-128 key bits [127:96] |
| `0x30` | `CRC_CTRL` | R/W | `0x0000_0000` | CRC algorithm selection |
| `0x34` | `AXI_OUTSTAND` | R/W | `0x0010_0010` | Max outstanding read and write transactions |
| `0x38` | `AXI_CACHE_CTRL` | R/W | `0x0000_0000` | AxCACHE per transaction type |
| `0x3C` | `AXI_PROT_CTRL` | R/W | `0x0000_0000` | AxPROT per transaction type |
| `0x40` | `INTERVAL` | R/W | `0x0000_0010` | Poll interval (cycles) when descriptor valid=0 |

### 5.2 CTRL — Control Register (Offset 0x00)

Write-only bits. All bits self-clear after one clock cycle (pulse-type).

| Bits | Field | Description |
|---|---|---|
| [0] | `START` | Write 1 to start operation from STOP state. Transitions to ACTIVE if currently STOP. Ignored if not in STOP state. |
| [1] | `RESUME` | Write 1 to resume from PAUSE state. Transitions PAUSE → ACTIVE. Clears the pause condition. |
| [2] | `IMMEDIATE_STOP` | Write 1 to force transition to STOP state immediately from ACTIVE or PAUSE. In-flight AXI transactions are allowed to complete; current descriptor processing is abandoned. |
| [31:3] | — | Reserved. Write 0. |

### 5.3 STATUS — Status Register (Offset 0x04)

Bits [1:0] are read-only. Bit [2] is Write-1-to-Clear (W1C).

| Bits | Field | Access | Description |
|---|---|---|---|
| [1:0] | `STATE` | RO | Current engine state: `2'b00` = STOP, `2'b01` = ACTIVE, `2'b10` = PAUSE |
| [2] | `BUS_ERROR` | W1C | Set by IP when an AXI Manager transaction returns a non-OKAY response. Cleared by host writing `1` to this bit. Remains set across state transitions until explicitly cleared. |
| [31:3] | — | RO | Reserved. Reads as 0. |

### 5.4 IRQ_STATUS — Interrupt Status Register (Offset 0x08)

Write 1 to clear (W1C). Each bit is set by hardware and cleared by host. The `irq` output is de-asserted when all set bits in `IRQ_STATUS` have their corresponding enable bit in `IRQ_ENABLE` cleared, or when all such bits are cleared.

| Bits | Field | Description |
|---|---|---|
| [0] | `DESCRIPTOR_DONE` | Set when a descriptor with `interrupt=1` completes processing. Cleared by writing 1 to this bit. |
| [1] | `BUS_ERROR` | Set when an AXI Manager transaction returns a non-OKAY response. Cleared by writing 1 to this bit. |
| [31:2] | — | Reserved |

### 5.5 IRQ_ENABLE — Interrupt Enable Register (Offset 0x0C)

Controls which `IRQ_STATUS` events drive the `irq` output. Setting a bit to 0 masks the interrupt but does not prevent the corresponding `IRQ_STATUS` bit from being set.

| Bits | Field | Description |
|---|---|---|
| [0] | `DESCRIPTOR_DONE_EN` | 1 = assert `irq` when `IRQ_STATUS.DESCRIPTOR_DONE` is set. |
| [1] | `BUS_ERROR_EN` | 1 = assert `irq` when `IRQ_STATUS.BUS_ERROR` is set. |
| [31:2] | — | Reserved |

### 5.6 CMD_BUF_ADDR — Command Buffer Base Address (Offset 0x10)

| Bits | Field | Description |
|---|---|---|
| [31:0] | `BASE_ADDR` | Physical base address of the descriptor ring buffer in system memory. Must be 32-bit word-aligned (4-byte aligned). Writes are ignored while engine is ACTIVE. |

### 5.7 CMD_BUF_SIZE — Command Buffer Depth (Offset 0x14)

| Bits | Field | Description |
|---|---|---|
| [9:0] | `DEPTH` | Number of descriptor slots in the ring buffer. Valid range: 1–1024. A value of 0 is treated as 1. Writes are ignored while engine is ACTIVE. |
| [31:10] | — | Reserved |

### 5.8 CMD_HEAD_PTR / CMD_TAIL_PTR (Offsets 0x18, 0x1C)

These implement the producer-consumer ring buffer protocol.

- `CMD_TAIL_PTR`: Written by host SW after placing new descriptors in memory to advance the tail (produce). Wraps at `CMD_BUF_SIZE.DEPTH`.
- `CMD_HEAD_PTR`: Updated by IP after consuming a descriptor (incrementing toward tail). Read-only. Wraps at `CMD_BUF_SIZE.DEPTH`.

The ring buffer is considered empty when `HEAD_PTR == TAIL_PTR`.

| Bits | Field | Description |
|---|---|---|
| [9:0] | `PTR` | Current pointer value (0 to DEPTH-1) |
| [31:10] | — | Reserved |

### 5.9 AES_KEY_[3:0] — AES Key Registers (Offsets 0x20–0x2C)

Write-only. Reads return 0x00000000 (key data is never readable).

The 128-bit AES key is stored in four 32-bit registers. Byte order follows little-endian convention: `AES_KEY_0` holds the least-significant 32 bits of the key.

| Register | Key bits |
|---|---|
| `AES_KEY_0` | [31:0] |
| `AES_KEY_1` | [63:32] |
| `AES_KEY_2` | [95:64] |
| `AES_KEY_3` | [127:96] |

The IP uses the key as written for all subsequent operations until the registers are overwritten. The host must write the key while the engine is in STOP or PAUSE state to avoid key tearing during an in-flight operation.

### 5.10 CRC_CTRL — CRC Control Register (Offset 0x30)

| Bits | Field | Description |
|---|---|---|
| [0] | `ALG_SEL` | CRC algorithm selection: `0` = CRC-32/IEEE 802.3 (polynomial 0x04C11DB7), `1` = CRC-32C / Castagnoli (polynomial 0x1EDC6F41) |
| [31:1] | — | Reserved |

Writes are accepted at any time; the selected algorithm applies to descriptors processed after the write.

### 5.11 AXI_OUTSTAND — AXI Outstanding Transactions (Offset 0x34)

| Bits | Field | Description |
|---|---|---|
| [4:0] | `MAX_RD_OUTSTANDING` | Maximum number of in-flight AXI read address transactions (ARVALID/ARREADY accepted, RLAST not yet received). Valid range: 1–16. A value of 0 is treated as 1. Values 17–31 are clamped to 16. Reset: `5'h10` (=16). |
| [9:5] | `MAX_WR_OUTSTANDING` | Maximum number of in-flight AXI write address transactions (AWVALID/AWREADY accepted, BVALID not yet received). Valid range: 1–16. A value of 0 is treated as 1. Values 17–31 are clamped to 16. Reset: `5'h10` (=16). |
| [31:10] | — | Reserved |

### 5.12 AXI_CACHE_CTRL — AXI Cache Attributes (Offset 0x38)

| Bits | Field | Description |
|---|---|---|
| [3:0] | `ARCACHE_DESC` | AxCACHE for descriptor reads |
| [7:4] | `ARCACHE_IN` | AxCACHE for input buffer reads |
| [11:8] | `AWCACHE_OUT` | AxCACHE for output buffer writes |
| [31:12] | — | Reserved |

Reset value: `0x0000_0000` (Non-cacheable, non-bufferable).

### 5.13 AXI_PROT_CTRL — AXI Protection Attributes (Offset 0x3C)

| Bits | Field | Description |
|---|---|---|
| [2:0] | `ARPROT_DESC` | AxPROT for descriptor reads |
| [5:3] | `ARPROT_IN` | AxPROT for input buffer reads |
| [8:6] | `AWPROT_OUT` | AxPROT for output buffer writes |
| [31:9] | — | Reserved |

Reset value: `0x0000_0000`.

### 5.14 INTERVAL — Poll Interval Register (Offset 0x40)

| Bits | Field | Description |
|---|---|---|
| [15:0] | `CYCLES` | Number of clock cycles to wait before re-reading a descriptor whose `valid` field was found to be 0. Minimum effective value: 1. |
| [31:16] | — | Reserved |

---

## 6. Descriptor Layout

### 6.1 Overview

A Descriptor is a data structure written by the host CPU into the command buffer (a circular ring in system memory). Each Descriptor represents one decryption job and carries only job control metadata and buffer pointers/sizes. Per-job AES parameters (IV, initial counter) and all payload data reside in the **input buffer**, not in the Descriptor itself.

The IP reads a Descriptor to locate the input and output buffers, then reads the input buffer to obtain the AES Header, ciphertext, and CRC value.

Descriptors are **32-bit word-aligned** (4-byte aligned) in memory. Since each Descriptor is 32 bytes, all Descriptor start addresses are naturally aligned to 32-byte boundaries when `CMD_BUF_ADDR` is 32-bit aligned. All multi-byte fields are **little-endian**. All fields are **byte-aligned** (no sub-byte fields outside the control byte).

### 6.2 Descriptor Memory Map

The total Descriptor size is **32 bytes**. Layout:

```
Byte Offset  Size     Field
──────────────────────────────────────────────────────
0x00         4 B      Header Word (control flags, status)
0x04         4 B      Input Buffer Address [31:0]
0x08         4 B      Output Buffer Address [31:0]
0x0C         4 B      Input Data Size [23:0] + Input Padding Size [7:0]
0x10         4 B      Output Data Size [23:0] + Output Padding Size [7:0]
0x14        12 B      Reserved (write 0)
──────────────────────────────────────────────────────
Total:       32 B
```

### 6.3 Header Word (Offset 0x00, 4 bytes)

The Header Word is split into four bytes to allow independent byte-level updates via AXI Write Strobe. This is essential because the IP must clear the `valid` bit and write the `state` field without disturbing each other or the control flags set by the host.

| Byte | Bits | Field | R/W | Description |
|---|---|---|---|---|
| Byte 0 | [7:0] | Control byte | Host W | See below |
| Byte 1 | [15:8] | State byte | IP W | IP-writeback: job result code |
| Byte 2 | [23:16] | Reserved | — | Write 0 |
| Byte 3 | [31:24] | Reserved | — | Write 0 |

**Control byte (Byte 0) field breakdown:**

| Bits | Field | Description |
|---|---|---|
| [0] | `valid` | 1 = this descriptor is ready to be processed. Host sets to 1. IP clears to 0 after processing completes. Updated by IP via byte-strobe write to Byte 0. |
| [1] | `interrupt` | 1 = assert interrupt after this descriptor completes. IP enters PAUSE state after asserting IRQ. 0 = no interrupt; continue to next descriptor immediately. |
| [2] | `last` | 1 = this is the final descriptor. Engine transitions to STOP after all descriptor processing completes. If `interrupt=1` is also set on this descriptor, the engine first enters PAUSE and waits for `CTRL.RESUME` from the host; STOP occurs only after that resume. If `interrupt=0`, the engine transitions directly to STOP. 0 = continue to next descriptor. |
| [7:3] | — | Reserved. Write 0. |

**State byte (Byte 1) — written by IP:**

| Value | Meaning |
|---|---|
| `0x00` | Not processed (initial / reset state) |
| `0x01` | Processing completed successfully |
| `0x02` | CRC error detected |
| `0x03` | AXI read error on input buffer |
| `0x04` | AXI write error on output buffer |
| `0xFF` | In progress (written by IP at start of processing, replaced with result code on completion) |

### 6.4 Input Buffer Address (Offset 0x04, 4 bytes)

| Bits | Field | Description |
|---|---|---|
| [31:0] | `IN_ADDR` | 32-bit byte address of the input buffer in system memory. Byte-aligned; no AXI alignment constraint is imposed. |

See [Section 6.6](#66-input-buffer-content) for the full layout of the input buffer.

### 6.5 Output Buffer Address (Offset 0x08, 4 bytes)

| Bits | Field | Description |
|---|---|---|
| [31:0] | `OUT_ADDR` | 32-bit byte address of the output buffer in system memory. Byte-aligned; no AXI alignment constraint is imposed. |

The output buffer receives, in order:
1. Decrypted plaintext, `OUT_DATA_SIZE` bytes
2. Padding bytes (if `OUT_PAD_SIZE > 0`), written as `0x00`

### 6.6 Input Buffer Content

The input buffer pointed to by `IN_ADDR` contains the following fields in order:

```
Input Buffer (at IN_ADDR)
──────────────────────────────────────────────────────────────────
+0x00       16 B   AES Header
               Bytes [11:0]  — Nonce / IV (96 bits)
               Bytes [15:12] — Initial Counter Value (32 bits, big-endian
                                within the AES counter block)
+0x10       N B    Encrypted Payload (ciphertext)
               N = IN_DATA_SIZE bytes. Must be a multiple of 16 bytes.
+(0x10+N)   M B    Input Padding
               M = IN_PAD_SIZE bytes (0–255). Read from memory for burst
               alignment; not fed to the AES core or CRC computation.
+(0x10+N+M) 4 B    CRC-32 Value (little-endian)
               Expected CRC-32 over the Encrypted Payload (N bytes)
               only. AES Header and padding bytes are excluded.
──────────────────────────────────────────────────────────────────
Total:  (16 + N + M + 4) bytes
```

The IP reads the AES Header first to extract the Nonce and Initial Counter (the header bytes are **not** included in CRC computation), then reads the Encrypted Payload while computing CRC-32 in parallel, then reads and discards the Input Padding, then reads the CRC-32 Value for comparison.

### 6.7 Input Data Size and Padding (Descriptor Offset 0x0C, 4 bytes)

| Bits | Field | Description |
|---|---|---|
| [23:0] | `IN_DATA_SIZE` | Number of valid encrypted bytes in the input buffer payload (0 to 16,777,215). Byte-aligned. Must be a multiple of 16. |
| [31:24] | `IN_PAD_SIZE` | Number of padding bytes appended after the encrypted payload in the input buffer (0 to 255). |

### 6.8 Output Data Size and Padding (Descriptor Offset 0x10, 4 bytes)

| Bits | Field | Description |
|---|---|---|
| [23:0] | `OUT_DATA_SIZE` | Number of valid plaintext bytes to write to the output buffer (0 to 16,777,215). |
| [31:24] | `OUT_PAD_SIZE` | Number of `0x00` padding bytes to write after the plaintext in the output buffer (0 to 255). |

---

## 7. Operational State Machine

### 7.1 State Definitions

| State | Encoding | Description |
|---|---|---|
| **STOP** | `2'b00` | Engine is idle. No AXI Manager transactions are issued. Host may freely update registers. |
| **ACTIVE** | `2'b01` | Engine is processing descriptors from the command buffer. |
| **PAUSE** | `2'b10` | Engine has suspended after completing a descriptor with `interrupt=1`. Awaiting RESUME from host. |

### 7.2 State Transition Diagram

```
                   ┌───────────────────────────────────┐
                   │              STOP                 │
                   │  STATUS.STATE = 2'b00             │
                   └───┬───────────────────────────────┘
                       │ CTRL.START=1 or CTRL.RESUME=1
                       ▼
                   ┌───────────────────────────────────┐
              ┌───►│             ACTIVE                │◄────────────────┐
              │    │  STATUS.STATE = 2'b01             │                 │
              │    └───┬──────────────────┬────────────┘                 │
              │        │                  │                              │
              │  (descriptor with    (descriptor with                   │
              │   interrupt=0,        interrupt=1                       │
              │   last=0 completes)   completes)                        │
              │        │                  ▼                              │
              │        │      ┌───────────────────────┐    CTRL.RESUME=1 │
              │        │      │         PAUSE          ├─────────────────┘
              │        │      │  STATUS.STATE = 2'b10  │
              │        │      └───────────┬───────────┘
              │        │                  │
              │        │   CTRL.IMMEDIATE_STOP=1 (from ACTIVE or PAUSE)
              │        │   or Bus error (all outstanding transactions drained)
              │        │                  │
              │        │                  ▼
              │        │      ┌───────────────────────┐
              └────────┴─────►│         STOP           │
    (descriptor with last=1   └───────────────────────┘
     completes; if interrupt=1
     was also set, STOP is reached
     only after PAUSE→CTRL.RESUME)
```

### 7.3 Detailed State Transition Rules

#### STOP → ACTIVE
- Condition: Engine in STOP **and** host writes `1` to `CTRL.START` (or `CTRL.RESUME`, treated equivalently from STOP).
- Action: Set `STATUS.STATE = ACTIVE`. Begin fetching the descriptor at `CMD_HEAD_PTR`.

#### ACTIVE: Descriptor Processing Loop

1. **Fetch descriptor:** Read the 32-byte descriptor at address `CMD_BUF_ADDR + CMD_HEAD_PTR × 32` using a single AXI4 burst read (4 beats of 8 bytes).
2. **Check `valid` bit:**
   - If `valid=0`: Wait `INTERVAL.CYCLES` clock cycles, then re-read the descriptor header. Do not advance `CMD_HEAD_PTR`.
   - If `valid=1`: Proceed.
3. **Begin processing:** Write `state = 0xFF` (in-progress) to the descriptor's State byte (byte-strobe write to Byte 1 of Header Word). Begin reading the input buffer starting with the AES Header (prefetch may start as soon as `IN_ADDR` and `IN_DATA_SIZE` are decoded from the descriptor).
4. **Decrypt and check CRC:** Read AES Header (IV + initial counter), then read encrypted payload while computing CRC-32, perform AES-128 CTR decryption, write plaintext to output buffer, read and discard padding, read CRC-32 value and compare against computed result.
5. **Write back result:** Write `state = result_code` and clear `valid=0` to the descriptor Header Word via a single 4-byte write with byte strobes targeting Bytes 0 and 1.
6. **Advance head pointer:** `CMD_HEAD_PTR = (CMD_HEAD_PTR + 1) mod CMD_BUF_SIZE.DEPTH`.
7. **Check `interrupt` bit:**
   - If `interrupt=1`: Assert `irq` (if `IRQ_ENABLE.DESCRIPTOR_DONE_EN=1`), set `IRQ_STATUS.DESCRIPTOR_DONE=1`, transition to **PAUSE**.
   - If `interrupt=0`: Continue.
8. **Check `last` bit:**
   - If `last=1` and `interrupt=0`: Transition immediately to **STOP**.
   - If `last=1` and `interrupt=1`: The engine already entered PAUSE in step 7. Upon receiving `CTRL.RESUME`, transition to **STOP** (do not fetch the next descriptor).
   - If `last=0`: Go to step 1 for the next descriptor.

#### ACTIVE / PAUSE → STOP (Immediate Stop)
- Condition: Host writes `1` to `CTRL.IMMEDIATE_STOP`.
- Action: Immediately stop issuing new AXI Manager transactions. Allow any outstanding AXI transactions to complete (drain the response channels). Transition to STOP. The current descriptor is left in an indeterminate state; the host is responsible for re-initializing the ring buffer.

#### ACTIVE → STOP (Bus Error)
- Condition: An AXI Manager transaction returns a non-OKAY response (`RRESP ≠ OKAY` or `BRESP ≠ OKAY`).
- Action:
  1. Write the bus error code (`0x03` for read error, `0x04` for write error) to the `state` byte of the descriptor currently being processed, and clear its `valid` bit.
  2. Set `STATUS.BUS_ERROR = 1`.
  3. Set `IRQ_STATUS.BUS_ERROR = 1`. If `IRQ_ENABLE.BUS_ERROR_EN = 1`, assert `irq`.
  4. Stop issuing new AXI Manager transactions immediately. Do not start processing any subsequent descriptors.
  5. Allow all remaining outstanding AXI transactions (already issued) to complete (drain response channels).
  6. Transition to **STOP** state.
- Note: Descriptors that completed successfully before the bus error are not affected. The host must inspect `STATUS.BUS_ERROR` and the descriptor `state` fields to determine which descriptor failed.

#### PAUSE → ACTIVE
- Condition: Engine in PAUSE **and** host writes `1` to `CTRL.RESUME`.
- Action: Clear `CTRL.RESUME`. Transition to ACTIVE. Resume descriptor processing loop at step 1 (fetch next descriptor at current `CMD_HEAD_PTR`).

### 7.4 Register Access Rules by State

| Register | STOP | ACTIVE | PAUSE |
|---|---|---|---|
| `CTRL` | Writable | Writable (only `IMMEDIATE_STOP` has effect) | Writable (`RESUME` and `IMMEDIATE_STOP` have effect) |
| `STATUS` | R/W1C (`BUS_ERROR` bit) | R/W1C (`BUS_ERROR` bit) | R/W1C (`BUS_ERROR` bit) |
| `IRQ_STATUS` | R/W1C | R/W1C | R/W1C |
| `IRQ_ENABLE` | R/W | R/W | R/W |
| `CMD_BUF_ADDR` | R/W | Read-only (writes ignored) | R/W |
| `CMD_BUF_SIZE` | R/W | Read-only (writes ignored) | R/W |
| `CMD_HEAD_PTR` | RO | RO | RO |
| `CMD_TAIL_PTR` | R/W | R/W | R/W |
| `AES_KEY_[3:0]` | WO | Write accepted; key takes effect on next descriptor | WO |
| `CRC_CTRL` | R/W | R/W (takes effect on next descriptor) | R/W |
| `AXI_OUTSTAND` | R/W | Read-only (writes ignored) | R/W |
| `AXI_CACHE_CTRL` | R/W | Read-only (writes ignored) | R/W |
| `AXI_PROT_CTRL` | R/W | Read-only (writes ignored) | R/W |
| `INTERVAL` | R/W | R/W | R/W |

---

## 8. AES Processing

### 8.1 Algorithm

The IP implements **AES-128 in Counter (CTR) mode** as defined in NIST SP 800-38A.

- Key size: 128 bits
- Block size: 128 bits
- Mode: CTR with standard counter incrementing (32-bit counter, big-endian, wraps modulo 2^32)

### 8.2 Key Schedule

The AES key is loaded from registers `AES_KEY_0` through `AES_KEY_3`. The key schedule is computed once per descriptor fetch and held for the duration of that job.

### 8.3 Counter Block Construction

For each 128-bit plaintext block at position `i` (0-indexed):

```
Counter_Block_i = { Nonce[95:0], (InitialCounter + i) mod 2^32 }
```

where `Nonce` and `InitialCounter` come from the AES Header at the beginning of the input buffer (see Section 6.6).

### 8.4 Decryption Operation

For each 16-byte ciphertext block `C_i`:

```
P_i = C_i XOR AES_Encrypt(Key, Counter_Block_i)
```

Note: In CTR mode, the AES **Encrypt** function is used for both encryption and decryption.

### 8.5 Data Flow

```
System Memory                   IP Internal Pipeline
─────────────────────────────────────────────────────────────
Input Buffer        ──AXI read──►  Input FIFO (ciphertext)
                                        │
                              ┌─────────┴──────────┐
                              ▼                    ▼
                         CRC-32 computation   AES-128 CTR Decrypt
                         (over ciphertext,    (ciphertext → plaintext)
                          parallel with AES)       │
                              │                    ▼
                              │              Output FIFO  ──AXI write──► Output Buffer
                              ▼
                         compare vs
                         CRC field in
                         input buffer
```

CRC is computed over the **ciphertext** (before decryption) in parallel with AES decryption, enabling early error detection without adding pipeline latency.

### 8.6 Padding

Input padding bytes (`IN_PAD_SIZE`) are read from memory (to maintain AXI burst alignment) but are not fed to the AES core or CRC computation. Output padding bytes (`OUT_PAD_SIZE`) are written as `0x00` to the output buffer after the plaintext.

---

## 9. CRC Processing

### 9.1 Supported Algorithms

| `CRC_CTRL.ALG_SEL` | Algorithm | Polynomial | Initial Value | Input Reflection | Output Reflection | Final XOR |
|---|---|---|---|---|---|---|
| `0` | CRC-32/IEEE 802.3 | 0x04C11DB7 | 0xFFFFFFFF | Yes | Yes | 0xFFFFFFFF |
| `1` | CRC-32C (Castagnoli) | 0x1EDC6F41 | 0xFFFFFFFF | Yes | Yes | 0xFFFFFFFF |

### 9.2 CRC Coverage

CRC is computed over the **Encrypted Payload** (`IN_DATA_SIZE` bytes) only. The AES Header, Input Padding bytes (`IN_PAD_SIZE`), and the CRC-32 value field itself are all excluded from CRC computation. Computing CRC over the ciphertext (before decryption) enables early error detection and allows CRC computation and AES decryption to proceed in parallel.

The CRC-32 value for comparison is read from the input buffer at offset `0x10 + IN_DATA_SIZE + IN_PAD_SIZE` (see Section 6.6).

### 9.3 Error Handling

If the computed CRC does not match the CRC-32 value read from the input buffer:

1. The decryption job is considered complete (the IP does not retry).
2. The descriptor `state` byte is set to `0x02` (CRC error).
3. The `valid` bit is cleared.
4. If the descriptor's `interrupt` bit is set, interrupt and PAUSE behavior proceeds normally.
5. If the descriptor's `last` bit is set, the engine transitions to STOP normally.
6. Host SW must treat the output buffer content as invalid.

---

## 10. Interrupt Handling

### 10.1 Interrupt Signal Behavior

The `irq` output is an **active-high level signal**. It is asserted as long as at least one bit in `IRQ_STATUS` is set and its corresponding enable bit in `IRQ_ENABLE` is 1. It is de-asserted only when all such pending enabled bits are cleared by the host.

### 10.2 Interrupt Sources

| Source | `IRQ_STATUS` bit | `IRQ_ENABLE` bit | Engine state after event |
|---|---|---|---|
| Descriptor with `interrupt=1` completed | `DESCRIPTOR_DONE` [0] | `DESCRIPTOR_DONE_EN` [0] | PAUSE |
| AXI Manager bus error | `BUS_ERROR` [1] | `BUS_ERROR_EN` [1] | STOP |

`IRQ_STATUS` bits are set unconditionally by hardware regardless of the `IRQ_ENABLE` setting. The enable bits only gate the `irq` output.

### 10.3 Interrupt Clearing — DESCRIPTOR_DONE

The host interrupt service routine for a descriptor-done interrupt must:

1. Read `IRQ_STATUS` to confirm `DESCRIPTOR_DONE = 1`.
2. Inspect the completed descriptor's `state` byte in memory.
3. Write `1` to `IRQ_STATUS.DESCRIPTOR_DONE` to clear the status bit.
4. Write `1` to `CTRL.RESUME` to transition PAUSE → ACTIVE.

If `CTRL.RESUME` is written before `IRQ_STATUS.DESCRIPTOR_DONE` is cleared, the engine transitions to ACTIVE but `irq` remains asserted until the status bit is cleared.

### 10.4 Interrupt Clearing — BUS_ERROR

The host interrupt service routine for a bus error interrupt must:

1. Read `IRQ_STATUS` to confirm `BUS_ERROR = 1`.
2. Read `STATUS` to confirm `STATE = STOP`.
3. Inspect the failing descriptor's `state` byte in memory.
4. Write `1` to `STATUS.BUS_ERROR` to clear the status flag.
5. Write `1` to `IRQ_STATUS.BUS_ERROR` to clear the interrupt status bit and de-assert `irq`.
6. After correcting the root cause, write `1` to `CTRL.START` to resume.

### 10.5 Interrupt Timing Diagram (DESCRIPTOR_DONE)

```
                        Descriptor N completes
                               │
clk        ─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐│┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐
             └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘

irq        ─────────────────────┐               ┌──────────────
           (de-asserted)        └───────────────┘ (cleared by W1C)
                                 (asserted at
                                  next rising edge
                                  after descriptor N write-back)

STATUS     ══════════════════[ ACTIVE ]══[ PAUSE ]══[ ACTIVE ]═
                                          │
                                          SW writes CTRL.RESUME=1
```

---

## 11. Performance Requirements

> ⚠️ **[THROUGHPUT_TARGET — Review and update if target changes]**  
> **Target: 200 Mbps sustained throughput** (data payload only, excluding protocol overhead).

### 11.1 Throughput Definition

Throughput is measured as the number of valid plaintext bytes written to the output buffer per second, sustained over a sequence of back-to-back descriptors with no software-induced delays (i.e., all descriptors have `interrupt=0` and the ring buffer is continuously populated by the host).

### 11.2 Design Requirements to Achieve Throughput Target

The following architectural constraints must be observed:

1. **AES core must not starve:** The input FIFO between the AXI Manager read path and the AES core must be large enough to absorb AXI read latency. Specifically, the IP shall begin prefetching input data into the internal input FIFO as soon as the `IN_ADDR` and `IN_DATA_SIZE` fields are decoded from the descriptor, without waiting for the full descriptor to be consumed.

2. **No unnecessary bus congestion:** The IP shall not issue more read transactions than needed to fill the internal input FIFO. The number of outstanding read transactions is bounded by `AXI_OUTSTAND.MAX_RD_OUTSTANDING`. When the internal input FIFO has no available space, the IP shall not issue further read requests.

3. **Descriptor overhead minimized:** The fixed-size portion of a descriptor shall be fetched in a single AXI burst to minimize read latency before processing begins.

4. **Back-pressure handled correctly:** If the output FIFO is full (output AXI write path is backpressured), the AES core shall stall gracefully without corrupting state.

### 11.3 Clock Frequency Assumption

> ⚠️ **[THROUGHPUT_TARGET]** Throughput target of 200 Mbps assumes a minimum operating frequency of **200 MHz** with the AES core producing one 128-bit output block per 10 clock cycles (AES pipeline latency TBD by implementation; latency must not reduce sustained throughput below target).

At 200 MHz with 64-bit AXI bus: peak AXI bandwidth = 200 MHz × 8 B = 1600 MB/s = 12.8 Gbps. The 200 Mbps throughput requirement represents a light load on the bus.

---

## 12. Bus Interface Specification

### 12.1 AXI4 Manager — General Rules

- All transactions use **INCR burst type** (`AxBURST = 2'b01`).
- All transactions use **8-byte transfer size** (`AxSIZE = 3'b011`).
- Maximum burst length: 256 beats (`AxLEN = 8'hFF`), i.e., 2 KB per burst.
- `AxLOCK` is tied to `1'b0` (normal access, no exclusive).
- `AxID` is tied to `{ID_WIDTH{1'b0}}` (all transactions use ID 0; in-order responses assumed).
- `AxREGION` is tied to `4'b0000`.

### 12.2 Transaction Type Mapping

| Transaction | Channel | AxCACHE source | AxPROT source |
|---|---|---|---|
| Descriptor read | AR | `AXI_CACHE_CTRL[3:0]` | `AXI_PROT_CTRL[2:0]` |
| Input buffer read | AR | `AXI_CACHE_CTRL[7:4]` | `AXI_PROT_CTRL[5:3]` |
| Output buffer write | AW | `AXI_CACHE_CTRL[11:8]` | `AXI_PROT_CTRL[8:6]` |
| Descriptor write-back | AW | `AXI_CACHE_CTRL[3:0]` | `AXI_PROT_CTRL[2:0]` |

### 12.3 Outstanding Read Transaction Limit

The IP maintains a counter of in-flight read address channel transactions (ARVALID/ARREADY accepted, RLAST not yet received). When the counter reaches `AXI_OUTSTAND.MAX_RD_OUTSTANDING`, the IP de-asserts `m_axi_arvalid` until a read response completes.

### 12.4 Outstanding Write Transaction Limit

The IP maintains a counter of in-flight write address channel transactions (AWVALID/AWREADY accepted, BVALID not yet received). When the counter reaches `AXI_OUTSTAND.MAX_WR_OUTSTANDING`, the IP de-asserts `m_axi_awvalid` until a write response is received.

### 12.5 Write Response Handling

The IP asserts `m_axi_bready = 1` continuously. If `BRESP` is not `OKAY (2'b00)`, the IP treats it as a bus error and applies the bus error handling sequence defined in Section 7.3 (ACTIVE → STOP via Bus Error). The current descriptor's `state` byte is set to `0x04` (AXI write error).

### 12.6 Read Response Error Handling

If `RRESP` is not `OKAY (2'b00)`, the IP treats it as a bus error and applies the bus error handling sequence defined in Section 7.3. The current descriptor's `state` byte is set to `0x03` (AXI read error). The output buffer may contain partial data and must be treated as invalid by host SW.

### 12.7 Bus Error Recovery Sequence (Host Software)

After a bus error, the host should:
1. Read `STATUS` to confirm `BUS_ERROR = 1` and `STATE = STOP`.
2. Inspect descriptor `state` bytes to identify the failing descriptor.
3. Write `1` to `STATUS.BUS_ERROR` to clear the flag.
4. Write `1` to `IRQ_STATUS.BUS_ERROR` to clear the interrupt status (if set).
5. Correct the root cause (e.g., fix buffer addresses, re-initialize ring buffer).
6. Write `1` to `CTRL.START` to resume operation.

---

## 13. Electrical and Physical Constraints

### 13.1 Synthesis Requirements

- All RTL must be synthesizable using standard ASIC synthesis flows (e.g., Synopsys Design Compiler, Cadence Genus).
- No use of `initial` blocks except in testbench files.
- No combinational loops.
- All flip-flops shall have synchronous or asynchronous reset as required by the synthesis library.

### 13.2 Timing Constraints

- **Dividers and wide multipliers are prohibited.** Any arithmetic required must be expressible as shift, add, and XOR operations to avoid long timing paths.
- The AES round function shall be implemented as a pipelined structure. Minimum pipeline depth is determined by the target frequency; a fully unrolled single-cycle implementation is not required and is not recommended.
- All paths must meet timing at the target frequency in the worst-case process/voltage/temperature corner.

### 13.3 Reset Behavior

After `rst_n` is de-asserted (reset released):
- `STATUS.STATE = STOP`
- `IRQ_STATUS = 0x0`
- `CMD_HEAD_PTR = 0x0`
- `irq = 0`
- All other registers reset to the values specified in the register map (Section 5).

---

## 14. Revision History

| Version | Date | Author | Description |
|---|---|---|---|
| 0.1 | 2026-04-12 | SoC Team | Initial draft |

---

*End of Document*  
*SSVD Confidential — For internal use only*
