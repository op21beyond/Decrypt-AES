// =============================================================================
// File        : aes_decrypt_mem_top.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Top-level memory module for the AES Decryption Engine.
//               Aggregates ALL compiled SRAM instances in one location to
//               simplify future Memory BIST (MBIST) insertion.
//
//               Instantiated memories:
//                 u_sram_cipher_fifo — 32 × 64-bit (sram_2p_32x64)
//                   Stores ciphertext beats for the input FIFO
//                   (aes_decrypt_input_ctrl / u_cipher_fifo)
//
//                 u_sram_out_fifo    — 32 × 72-bit (sram_2p_32x72)
//                   Stores {WSTRB[7:0], WDATA[63:0]} beats for the output FIFO
//                   (aes_decrypt_output_ctrl / u_out_fifo)
//
//               MBIST notes:
//                 - To add MBIST, insert a BIST controller in this module and
//                   mux the functional signals with BIST signals using a
//                   standard bist_en gating structure.
//                 - All SRAM CLK, WEN, WA, WD, RA ports are accessible here,
//                   providing a single boundary for scan/BIST wrappers.
//
//               SRAM interface (write-synchronous / read-asynchronous):
//                 CLK  — rising-edge write clock
//                 WEN  — write enable (active-high)
//                 WA   — write address
//                 WD   — write data
//                 RA   — read address (asynchronous)
//                 Q    — read data    (combinational)
// =============================================================================

module aes_decrypt_mem_top (
    input  wire        clk,

    // =========================================================================
    // Cipher FIFO SRAM interface (32 × 64-bit)
    // Connected to: aes_decrypt_input_ctrl / u_cipher_fifo
    // =========================================================================
    input  wire        cipher_mem_wen,
    input  wire [4:0]  cipher_mem_wa,
    input  wire [63:0] cipher_mem_wd,
    input  wire [4:0]  cipher_mem_ra,
    output wire [63:0] cipher_mem_q,

    // =========================================================================
    // Output FIFO SRAM interface (32 × 72-bit)
    // Connected to: aes_decrypt_output_ctrl / u_out_fifo
    // =========================================================================
    input  wire        out_mem_wen,
    input  wire [4:0]  out_mem_wa,
    input  wire [71:0] out_mem_wd,
    input  wire [4:0]  out_mem_ra,
    output wire [71:0] out_mem_q
);

    // =========================================================================
    // SRAM instance: cipher FIFO storage
    // Capacity  : 32 words × 64 bits = 256 bytes
    // Consumer  : aes_decrypt_input_ctrl (ciphertext beat buffer)
    // =========================================================================
    sram_2p_32x64 u_sram_cipher_fifo (
        .CLK  (clk),
        .WEN  (cipher_mem_wen),
        .WA   (cipher_mem_wa),
        .WD   (cipher_mem_wd),
        .RA   (cipher_mem_ra),
        .Q    (cipher_mem_q)
    );

    // =========================================================================
    // SRAM instance: output FIFO storage
    // Capacity  : 32 words × 72 bits = 288 bytes
    // Consumer  : aes_decrypt_output_ctrl ({WSTRB, WDATA} beat buffer)
    // =========================================================================
    sram_2p_32x72 u_sram_out_fifo (
        .CLK  (clk),
        .WEN  (out_mem_wen),
        .WA   (out_mem_wa),
        .WD   (out_mem_wd),
        .RA   (out_mem_ra),
        .Q    (out_mem_q)
    );

endmodule
