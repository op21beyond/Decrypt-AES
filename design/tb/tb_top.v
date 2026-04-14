// =============================================================================
// File        : tb_top.v
// Project     : AES Decryption Engine IP
// Description : NCVerilog (Xcelium) testbench top wrapper.
//               Supplies clock/reset natively and includes the shared
//               testbench body from tb_core.sv.
//
// Simulator   : NCVerilog (Xcelium)
// Dump format : FSDB (Novas/Verdi) — falls back to VCD if `NOFSDB is defined
//
// For Verilator use tb_top_verilator.sv instead.
// =============================================================================

`timescale 1ns/1ps

`ifndef TB_TOP_MODULE_NAME
`define TB_TOP_MODULE_NAME tb_top
`endif

`include "tb_defines.vh"

module `TB_TOP_MODULE_NAME;

    // =========================================================================
    // Clock and reset — native generator (NCVerilog / Xcelium)
    // =========================================================================
    reg clk, rst_n;
    localparam CLK_HALF = 5;   // 10 ns period = 100 MHz

    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
    end

    // =========================================================================
    // Shared testbench body (signals, DUT, fake_mem, tasks, test sequence)
    // =========================================================================
    `include "tb_core.sv"

endmodule
