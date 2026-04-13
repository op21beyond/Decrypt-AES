// =============================================================================
// File        : sram_2p.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Behavioral model — parameterized simple dual-port SRAM.
//               Write port : synchronous (rising-edge CLK).
//               Read port  : asynchronous (combinational Q = MEM[RA]).
//
//               This file is a functional placeholder for a foundry-compiled
//               SRAM macro.  Replace this module with the vendor-provided
//               SRAM hard macro before tape-out.  Ensure the replacement macro
//               matches the port interface and timing convention below.
//
//               If the replacement SRAM provides only a synchronous (registered)
//               read output, the sync_fifo controller must be updated to add a
//               1-cycle output pipeline register and the empty/almost_empty
//               signals must be re-timed accordingly.
//
// Parameters  :
//   DATA_W  — data width in bits  (default 64)
//   DEPTH   — number of words     (default 32, must be power of 2)
//
// Interface:
//   CLK  — write clock (rising-edge triggered)
//   WEN  — write enable (active-high)
//   WA   — write address [$clog2(DEPTH)-1 : 0]
//   WD   — write data    [DATA_W-1 : 0]
//   RA   — read address  [$clog2(DEPTH)-1 : 0]  (asynchronous)
//   Q    — read data     [DATA_W-1 : 0]          (combinational)
// =============================================================================

// synthesis translate_off
`timescale 1ns/1ps
// synthesis translate_on

module sram_2p #(
    parameter DATA_W = 64,
    parameter DEPTH  = 32
)(
    input  wire                     CLK,
    input  wire                     WEN,
    input  wire [$clog2(DEPTH)-1:0] WA,
    input  wire [DATA_W-1:0]        WD,
    input  wire [$clog2(DEPTH)-1:0] RA,
    output wire [DATA_W-1:0]        Q
);

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // Synchronous write
    always @(posedge CLK) begin
        if (WEN)
            mem[WA] <= WD;
    end

    // Asynchronous (combinational) read
    assign Q = mem[RA];

endmodule
