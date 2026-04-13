// =============================================================================
// File        : sram_2p_32x64.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : 32-word x 64-bit instance wrapper for sram_2p.
//               Replace with foundry-compiled SRAM macro before tape-out.
// =============================================================================

// synthesis translate_off
`timescale 1ns/1ps
// synthesis translate_on

module sram_2p_32x64 (
    input  wire        CLK,
    input  wire        WEN,
    input  wire [4:0]  WA,
    input  wire [63:0] WD,
    input  wire [4:0]  RA,
    output wire [63:0] Q
);
    sram_2p #(.DATA_W(64), .DEPTH(32)) u_mem (
        .CLK (CLK), .WEN (WEN),
        .WA  (WA),  .WD  (WD),
        .RA  (RA),  .Q   (Q)
    );
endmodule
