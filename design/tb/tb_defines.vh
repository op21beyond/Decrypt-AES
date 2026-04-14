// =============================================================================
// File        : tb_defines.vh
// Project     : AES Decryption Engine IP
// Description : Shared testbench defines — register offsets, state/control
//               codes, memory map.  Included by tb_top.v (NCVerilog) and
//               tb_top_verilator.sv (Verilator) before the module declaration.
// =============================================================================

// ---------------------------------------------------------------------------
// Register offsets (mirrors aes_decrypt_defs.vh)
// ---------------------------------------------------------------------------
`define REG_CTRL          8'h00
`define REG_STATUS        8'h04
`define REG_IRQ_STATUS    8'h08
`define REG_IRQ_ENABLE    8'h0C
`define REG_CMD_BUF_ADDR  8'h10
`define REG_CMD_BUF_SIZE  8'h14
`define REG_CMD_HEAD_PTR  8'h18
`define REG_CMD_TAIL_PTR  8'h1C
`define REG_AES_KEY_0     8'h20
`define REG_AES_KEY_1     8'h24
`define REG_AES_KEY_2     8'h28
`define REG_AES_KEY_3     8'h2C
`define REG_CRC_CTRL      8'h30
`define REG_AXI_OUTSTAND  8'h34
`define REG_INTERVAL      8'h40

// ---------------------------------------------------------------------------
// FSM state codes (STATUS[1:0])
// ---------------------------------------------------------------------------
`define STATE_STOP        2'b00
`define STATE_ACTIVE      2'b01
`define STATE_PAUSE       2'b10

// ---------------------------------------------------------------------------
// CTRL command words
// ---------------------------------------------------------------------------
`define CTRL_START        32'h0000_0001
`define CTRL_RESUME       32'h0000_0002
`define CTRL_IMM_STOP     32'h0000_0004

// ---------------------------------------------------------------------------
// IRQ_STATUS bit masks
// ---------------------------------------------------------------------------
`define IRQ_DESC_DONE     32'h0000_0001
`define IRQ_BUS_ERROR     32'h0000_0002

// ---------------------------------------------------------------------------
// Descriptor state codes (written by IP into descriptor byte 1)
// ---------------------------------------------------------------------------
`define DSTATE_OK         8'h01
`define DSTATE_CRC_ERR    8'h02
`define DSTATE_RD_ERR     8'h03
`define DSTATE_WR_ERR     8'h04
`define DSTATE_IN_PROG    8'hFF

// ---------------------------------------------------------------------------
// Memory map (matches gen_mem.c / mem_init.hex)
// ---------------------------------------------------------------------------
`define MEM_BASE          32'h0000_1000
`define RING_BASE         32'h0000_1000

`define INBUF0            32'h0000_1100
`define INBUF1            32'h0000_1200
`define INBUF2            32'h0000_1300
`define INBUF3            32'h0000_1500

`define OUTBUF0           32'h0000_1600
`define OUTBUF1           32'h0000_1640
`define OUTBUF2           32'h0000_1700
`define OUTBUF3           32'h0000_1780
