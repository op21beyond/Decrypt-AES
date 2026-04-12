// =============================================================================
// File        : aes_decrypt_defs.vh
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Global defines, parameters, and register address map.
//               Include this file in every RTL module.
// -----------------------------------------------------------------------------
// SSVD Confidential — For internal use only
// =============================================================================

`ifndef AES_DECRYPT_DEFS_VH
`define AES_DECRYPT_DEFS_VH

// ---------------------------------------------------------------------------
// Feature gates — `define to enable optional assertions / coverage
// ---------------------------------------------------------------------------
//`define ENABLE_ASSERTIONS    // Uncomment to enable SVA assertions
//`define ENABLE_COVERAGE      // Uncomment to enable cover groups

// ---------------------------------------------------------------------------
// Top-level parameters
// ---------------------------------------------------------------------------
`define AXI_DW          64          // AXI data bus width (bits)
`define AXI_AW          32          // AXI address width (bits)
`define AXI_SW          8           // AXI strobe width  (= AXI_DW/8)

`define REG_AW          8           // Subordinate register address width

`define DESC_BYTES      32          // Descriptor size in bytes
`define DESC_BEATS      4           // Descriptor size in AXI beats (32/8)

`define MAX_DESC        1024        // Maximum descriptors in ring buffer
`define DESC_PTR_W      10          // Pointer width for max-1024 ring (log2(1024))

`define AES_KEY_W       128         // AES key width in bits
`define AES_BLK_W       128         // AES block width in bits
`define AES_HDR_BYTES   16          // AES header size in input buffer

`define CRC_W           32          // CRC result width

// THROUGHPUT_TARGET : 200 Mbps  (search this tag to update consistently)
`define THROUGHPUT_TARGET_MBPS 200

// ---------------------------------------------------------------------------
// Register Offsets (byte addresses, AXI4-Lite 32-bit registers)
// ---------------------------------------------------------------------------
`define REG_CTRL            8'h00
`define REG_STATUS          8'h04
`define REG_IRQ_STATUS      8'h08
`define REG_IRQ_ENABLE      8'h0C
`define REG_CMD_BUF_ADDR    8'h10
`define REG_CMD_BUF_SIZE    8'h14
`define REG_CMD_HEAD_PTR    8'h18
`define REG_CMD_TAIL_PTR    8'h1C
`define REG_AES_KEY_0       8'h20
`define REG_AES_KEY_1       8'h24
`define REG_AES_KEY_2       8'h28
`define REG_AES_KEY_3       8'h2C
`define REG_CRC_CTRL        8'h30
`define REG_AXI_OUTSTAND    8'h34
`define REG_AXI_CACHE_CTRL  8'h38
`define REG_AXI_PROT_CTRL   8'h3C
`define REG_INTERVAL        8'h40

// ---------------------------------------------------------------------------
// CTRL register bit positions (self-clearing pulse bits)
// ---------------------------------------------------------------------------
`define CTRL_START          0
`define CTRL_RESUME         1
`define CTRL_IMMEDIATE_STOP 2

// ---------------------------------------------------------------------------
// STATUS register bit positions
// ---------------------------------------------------------------------------
`define STATUS_STATE_W      2
`define STATUS_STATE_LSB    0
`define STATUS_BUS_ERROR    2

// STATUS.STATE encodings
`define STATE_STOP          2'b00
`define STATE_ACTIVE        2'b01
`define STATE_PAUSE         2'b10

// ---------------------------------------------------------------------------
// IRQ_STATUS / IRQ_ENABLE bit positions
// ---------------------------------------------------------------------------
`define IRQ_DESCRIPTOR_DONE 0
`define IRQ_BUS_ERROR       1

// ---------------------------------------------------------------------------
// AXI_OUTSTAND register field positions
// ---------------------------------------------------------------------------
`define OUTSTAND_RD_LSB     0
`define OUTSTAND_RD_W       5       // bits [4:0]
`define OUTSTAND_WR_LSB     5
`define OUTSTAND_WR_W       5       // bits [9:5]

// ---------------------------------------------------------------------------
// AXI_CACHE_CTRL register field positions
// ---------------------------------------------------------------------------
`define CACHE_ARCACHE_DESC_LSB  0   // [3:0]  : descriptor read AxCACHE
`define CACHE_ARCACHE_IN_LSB    4   // [7:4]  : input buf read AxCACHE
`define CACHE_AWCACHE_OUT_LSB   8   // [11:8] : output buf write AxCACHE

// ---------------------------------------------------------------------------
// AXI_PROT_CTRL register field positions
// ---------------------------------------------------------------------------
`define PROT_ARPROT_DESC_LSB    0   // [2:0]  : descriptor read AxPROT
`define PROT_ARPROT_IN_LSB      3   // [5:3]  : input buf read AxPROT
`define PROT_AWPROT_OUT_LSB     6   // [8:6]  : output buf write AxPROT

// ---------------------------------------------------------------------------
// Descriptor byte offsets (within the 32-byte descriptor)
// ---------------------------------------------------------------------------
`define DESC_OFF_HDR_WORD   5'h00   // [3:0]   Header Word (4 bytes)
`define DESC_OFF_IN_ADDR    5'h04   // [7:4]   Input buffer address
`define DESC_OFF_OUT_ADDR   5'h08   // [11:8]  Output buffer address
`define DESC_OFF_IN_SIZE    5'h0C   // [15:12] IN_DATA_SIZE[23:0] + IN_PAD_SIZE[7:0]
`define DESC_OFF_OUT_SIZE   5'h10   // [19:16] OUT_DATA_SIZE[23:0] + OUT_PAD_SIZE[7:0]

// Descriptor Header Word (32-bit) field positions
`define HDR_VALID           0
`define HDR_INTERRUPT       1
`define HDR_LAST            2
// Byte 1 = state byte [15:8]
`define HDR_STATE_LSB       8
`define HDR_STATE_W         8

// Descriptor state byte values (written by IP)
`define DSTATE_IDLE         8'h00
`define DSTATE_OK           8'h01
`define DSTATE_CRC_ERR      8'h02
`define DSTATE_RD_ERR       8'h03
`define DSTATE_WR_ERR       8'h04
`define DSTATE_IN_PROGRESS  8'hFF

// ---------------------------------------------------------------------------
// AXI burst type / size constants
// ---------------------------------------------------------------------------
`define AXI_BURST_INCR      2'b01
`define AXI_SIZE_8B         3'b011  // 8-byte transfers (matches AXI_DW=64)

// ---------------------------------------------------------------------------
// Internal AXI read request IDs (for arbitration tagging)
// ---------------------------------------------------------------------------
`define RDID_DESC           2'd0    // Descriptor fetch
`define RDID_INPUT          2'd1    // Input buffer read

// Internal AXI write request IDs
`define WRID_OUTPUT         2'd0    // Output buffer write
`define WRID_WRITEBACK      2'd1    // Descriptor writeback

// ---------------------------------------------------------------------------
// CRC algorithm select
// ---------------------------------------------------------------------------
`define CRC_ALG_IEEE8023    1'b0    // CRC-32/IEEE 802.3 (poly 0x04C11DB7)
`define CRC_ALG_C           1'b1    // CRC-32C / Castagnoli (poly 0x1EDC6F41)

`endif // AES_DECRYPT_DEFS_VH
