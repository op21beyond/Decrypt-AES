# AES Decryption Engine IP -- Architecture Description

**Project:** AES Decryption Engine IP
**Company:** SSVD
**Document type:** Hardware Architecture Description
**Date:** 2026-04-13

---

## 1. Overview

The AES Decryption Engine IP is a memory-to-memory, descriptor-based hardware accelerator
that performs AES-128 CTR mode decryption with CRC-32 integrity verification.
It is designed for integration into the SSVD SoC as an AXI4 Manager IP.

Key characteristics:
- AES-128 CTR mode (encrypt keystream, XOR with ciphertext)
- Descriptor ring buffer -- host software queues decryption jobs via 32-byte descriptors
- AXI4 Manager (64-bit data bus) for memory access; AXI4-Lite Subordinate for register access
- CRC-32/IEEE 802.3 and CRC-32C selectable at runtime
- Throughput target: **200 Mbps** *(see spec for definition)*
- Max outstanding read transactions: 16 (configurable)
- Descriptor ring buffer: max 1024 entries (configurable)

---

## 2. Block Diagram

```
  +-----------------------------------------------------------+
  |              aes_decrypt_engine (DUT top)                 |
  |                                                           |
  |  AXI4-Lite --> aes_decrypt_regfile                        |
  |  Subordinate               | registers                    |
  |                            v                              |
  |            aes_decrypt_ctrl (top FSM)                     |
  |             |           |             |                   |
  |        +----+       +---+        +----+                   |
  |        v            v            v                        |
  |  aes_decrypt_  aes_decrypt_  aes_decrypt_                 |
  |  desc_fetch    input_ctrl    output_ctrl                  |
  |      |              |              |                      |
  |      |    +---------+      +-------+                      |
  |      |    | u_cipher_fifo  | u_out_fifo                   |
  |      |    | (sync_fifo)    | (sync_fifo)                  |
  |      |    |     |          |     |                        |
  |      |    | +---+----------+--+  |  <-- aes128_ctr_top    |
  |      |    | | aes_decrypt_    |  |          |             |
  |      |    | | mem_top         |  |   aes128_enc_pipe      |
  |      |    | |  sram_32x64     |  |   aes128_key_sched     |
  |      |    | |  sram_32x72     |  |                        |
  |      |    | +-----------------+  |   crc32_engine         |
  |      |    |                      | aes_decrypt_writeback  |
  |      |    +--------------------> |       |                |
  |      +--------------------------> |       |                |
  |                            aes_decrypt_axi_mgr            |
  |                                       |                   |
  +---------------------------------------+-------------------+
                                          |
                                     AXI4 Manager
                                   (64-bit, to SoC NoC)
```

---

## 3. Module Hierarchy

```
aes_decrypt_engine                         -- DUT top
+-- aes_decrypt_regfile                    -- AXI4-Lite register file
+-- aes_decrypt_ctrl                       -- Top-level FSM
+-- aes_decrypt_desc_fetch                 -- Descriptor ring buffer fetch
+-- aes_decrypt_input_ctrl                 -- Input buffer read controller
|   +-- sync_fifo (u_cipher_fifo)          -- Ciphertext beat FIFO [32x64b SRAM]
+-- aes_decrypt_output_ctrl                -- Output buffer write controller
|   +-- sync_fifo (u_out_fifo)             -- Output beat FIFO [32x72b SRAM]
+-- aes_decrypt_writeback                  -- Descriptor status write-back
+-- aes_decrypt_axi_mgr                    -- AXI4 Manager (2R + 2W ports)
+-- aes_decrypt_mem_top                    -- All compiled SRAMs (MBIST boundary)
|   +-- sram_2p_32x64 (u_sram_cipher_fifo)
|   +-- sram_2p_32x72 (u_sram_out_fifo)
+-- aes128_key_sched                       -- AES-128 key expansion (combinational)
+-- aes128_ctr_top                         -- AES-128 CTR mode engine
|   +-- aes128_enc_pipe                    -- 10-round AES pipeline (10-cycle latency)
+-- crc32_engine                           -- CRC-32/IEEE 802.3 and CRC-32C
```

---

## 4. Data Flow

### 4.1 Job Pipeline (per descriptor)

1. **Descriptor fetch** -- `aes_decrypt_desc_fetch` issues a 4-beat AXI4 burst read to load
   the 32-byte descriptor from the ring buffer. Decodes fields: input address, output address,
   sizes, AES nonce/IV, CRC.

2. **Writeback (in-progress)** -- `aes_decrypt_writeback` writes `DSTATE_IN_PROGRESS` to
   the descriptor before processing begins.

3. **Input read** -- `aes_decrypt_input_ctrl` reads the input buffer in order:
   - AES Header (16 bytes): nonce[95:0] + initial counter[31:0]
   - Ciphertext payload (IN_DATA_SIZE bytes): written into cipher FIFO
   - Padding (IN_PAD_SIZE bytes): discarded
   - CRC-32 (4 bytes): latched for comparison

4. **AES decryption** -- `aes128_ctr_top` generates keystream by encrypting counter blocks
   through the 10-round pipeline (`aes128_enc_pipe`). Ciphertext beats from the cipher FIFO
   are aligned into 128-bit blocks and XORed with the keystream.

5. **CRC computation (parallel with AES)** -- `crc32_engine` accumulates CRC over
   the same ciphertext beats simultaneously. CRC check (computed vs. expected from input
   buffer) happens after the last ciphertext beat is consumed, while output writing may
   still be in progress. A CRC failure sets `DSTATE_CRC_ERR` in the final writeback;
   the plaintext is already in the output buffer and the host must check descriptor status
   before using the data.

6. **Output write** -- `aes_decrypt_output_ctrl` receives 128-bit plaintext blocks, splits
   them into 64-bit AXI beats with byte strobes, and writes them to the output buffer.
   Appends OUT_PAD_SIZE zero bytes. WLAST is asserted on the final beat of each burst.

7. **Writeback (final)** -- `aes_decrypt_writeback` writes the result code
   (`DSTATE_OK`, `DSTATE_CRC_ERR`, `DSTATE_RD_ERR`, `DSTATE_WR_ERR`) to the descriptor.

8. **Interrupt / next** -- Based on the INTERRUPT and LAST flags in the descriptor,
   the FSM either pauses, stops, or proceeds to the next descriptor.

### 4.2 AXI Manager Port Assignment

| Port | Direction | Used by |
|------|-----------|---------|
| Read port 0 (RD0) | Read | `aes_decrypt_desc_fetch` -- descriptor fetch |
| Read port 1 (RD1) | Read | `aes_decrypt_input_ctrl` -- input buffer read |
| Write port 0 (WR0) | Write | `aes_decrypt_writeback` -- descriptor status update |
| Write port 1 (WR1) | Write | `aes_decrypt_output_ctrl` -- plaintext write |

Priority: RD0 > RD1 (fixed priority); WR0 > WR1 (fixed priority).

---

## 5. Register Interface

The `aes_decrypt_regfile` module implements an AXI4-Lite Subordinate register file.
Key registers:

| Register | Offset | Description |
|----------|--------|-------------|
| CTRL | 0x00 | Start / Resume / Immediate Stop (self-clearing) |
| STATUS | 0x04 | State (STOP/ACTIVE/PAUSE), BUS_ERROR (W1C) |
| IRQ_STATUS | 0x08 | DESCRIPTOR_DONE, BUS_ERROR (W1C) |
| IRQ_ENABLE | 0x0C | Interrupt enable bits |
| CMD_BUF_ADDR | 0x10 | Descriptor ring buffer base address |
| CMD_BUF_SIZE | 0x14 | Ring buffer size (number of slots, max 1024) |
| CMD_HEAD_PTR | 0x18 | Read-only head pointer (updated by HW) |
| CMD_TAIL_PTR | 0x1C | Write pointer (updated by SW) |
| AES_KEY_0..3 | 0x20-0x2C | AES-128 key (write-only, 4 x 32-bit) |
| CRC_CTRL | 0x30 | CRC algorithm select (0=IEEE 802.3, 1=CRC-32C) |
| AXI_OUTSTAND | 0x34 | Max outstanding read/write transactions |
| AXI_CACHE_CTRL | 0x38 | AxCACHE per access type |
| AXI_PROT_CTRL | 0x3C | AxPROT per access type |
| INTERVAL | 0x40 | Polling interval (cycles) for invalid descriptors |

---

## 6. Memory Architecture

### 6.1 Compiled SRAM Summary

All compiled SRAM instances are aggregated in `aes_decrypt_mem_top` to provide a single
MBIST insertion boundary.

| Instance (in mem_top) | Type | Size | Purpose |
|-----------------------|------|------|---------|
| `u_sram_cipher_fifo` | `sram_2p_32x64` | 32 x 64-bit | Cipher beat FIFO storage |
| `u_sram_out_fifo` | `sram_2p_32x72` | 32 x 72-bit | Output beat FIFO storage |

See [compiled_memory_list.txt](compiled_memory_list.txt) for the full SRAM list and
interface specification.

### 6.2 Flip-Flop Arrays (not SRAM)

The following reg arrays are implemented as flip-flops and are excluded from SRAM mapping:

| Location | Array | Depth x Width | Reason |
|----------|-------|---------------|--------|
| `aes128_enc_pipe` | `stage[0:9]` | 10 x 128b | AES pipeline stages |
| `aes128_enc_pipe` | `valid_pipe[0:9]` | 10 x 1b | Pipeline valid chain |
| `aes128_ctr_top` | `cipher_delay[0:9]` | 10 x 128b | Ciphertext alignment SR |
| `aes128_ctr_top` | `cipher_valid_delay[0:9]` | 10 x 1b | Valid alignment SR |
| `aes_decrypt_axi_mgr` | `rd_id_fifo[15:0]` | 16b flat | AXI ID routing bits |
| `aes_decrypt_axi_mgr` | `wr_id_fifo[15:0]` | 16b flat | AXI ID routing bits |

---

## 7. Clock and Reset

- **Clock domain:** Single synchronous domain `clk`. All modules share one clock.
- **Reset:** `rst_n` -- asynchronous active-low reset. All state machines and registers
  reset to defined safe states. The CRC engine resets via `crc_init` (implemented as
  `rst_n` gating in `aes_decrypt_engine`).
- **Timing target:** 200 MHz (5 ns period). See `design/syn/constraints.sdc`.

---

## 8. File List

| File | Description |
|------|-------------|
| `design/rtl/aes_decrypt_engine.v` | DUT top -- wires all sub-modules |
| `design/rtl/aes_decrypt_regfile.v` | AXI4-Lite register file |
| `design/rtl/aes_decrypt_ctrl.v` | Top-level FSM |
| `design/rtl/aes_decrypt_desc_fetch.v` | Descriptor ring buffer fetch |
| `design/rtl/aes_decrypt_input_ctrl.v` | Input buffer read controller |
| `design/rtl/aes_decrypt_output_ctrl.v` | Output buffer write controller |
| `design/rtl/aes_decrypt_writeback.v` | Descriptor status write-back |
| `design/rtl/aes_decrypt_axi_mgr.v` | AXI4 Manager (2R + 2W ports) |
| `design/rtl/aes_decrypt_mem_top.v` | All compiled SRAMs (MBIST boundary) |
| `design/rtl/crypto/aes128_key_sched.v` | AES-128 key schedule (combinational) |
| `design/rtl/crypto/aes128_ctr_top.v` | AES-128 CTR mode engine |
| `design/rtl/crypto/aes128_enc_pipe.v` | 10-round AES encryption pipeline |
| `design/rtl/util/sync_fifo.v` | Synchronous FIFO (external SRAM interface) |
| `design/rtl/util/crc32_engine.v` | CRC-32 engine (IEEE 802.3 + CRC-32C) |
| `design/rtl/util/sram_2p_32x64.v` | SRAM behavioral model 32x64b |
| `design/rtl/util/sram_2p_32x72.v` | SRAM behavioral model 32x72b |
| `design/rtl/inc/aes_decrypt_defs.vh` | Global parameters and defines |
| `design/syn/run_dc.tcl` | Synopsys DC synthesis script (template -- PDK paths TBD) |
| `design/syn/constraints.sdc` | Timing constraints (SDC, template -- cell values TBD) |
| `doc/compiled_memory_list.txt` | Compiled SRAM candidate list |
| `spec/AES-Decrypt-IP-Specification.md` | IP specification document |

---

## 9. Known Issues / Design Notes

1. **`sync_fifo.v` double-driver fix (resolved):** The original `sync_fifo` had `wr_ptr`
   driven by two separate `always` blocks. This has been corrected -- `wr_ptr` is now
   managed in a single always block with proper async reset.

2. **SRAM read latency:** The `sram_2p_32x*` behavioral models use asynchronous combinational
   read to match the show-ahead FIFO behavior. If the foundry SRAM macro provides only
   synchronous (registered) read, the `sync_fifo` controller must be updated to add a
   1-cycle output pipeline register and the empty/almost_empty signals must be re-timed
   accordingly.

3. **AES key schedule timing:** `aes128_key_sched` is purely combinational. For tight
   timing, consider registering the round key outputs in `aes_decrypt_engine` or applying
   a multicycle path constraint in the SDC (see commented section in constraints.sdc).

4. **Synthesis script is a template:** `run_dc.tcl` and `constraints.sdc` contain
   placeholder values (`TARGET_LIBRARY`, `set_driving_cell`, `set_load`) that must be
   replaced with actual PDK / library values before running synthesis.

5. **Testbench (`tb_top.v`) not yet updated:** The testbench was written before the
   SRAM port refactor of `sync_fifo`. It must be updated to connect the new
   `cipher_mem_*` and `out_mem_*` ports (or instantiate the `sram_2p_*` behavioral
   models) before simulation can run.
