// =============================================================================
// File        : tb_top_verilator.sv
// Project     : AES Decryption Engine IP
// Description : Verilator testbench top wrapper.
//               Clock and reset are supplied from C++ (tb_dpi.cpp) via DPI-C.
//               Waveform dumping is handled by tb_dpi.cpp (VCD).
//               Includes the shared testbench body from tb_core.sv.
//
// Simulator   : Verilator 5.x  (requires --timing, C++20)
// =============================================================================

`define VERILATOR
`define TB_TOP_MODULE_NAME tb_top_verilator
`define TB_SKIP_WAVES
`define NOFSDB

`timescale 1ns/1ps
`include "../tb/tb_defines.vh"

module tb_top_verilator;

    // =========================================================================
    // Clock and reset — supplied from C++ via DPI-C (see tb_dpi.cpp)
    //
    // Verilator re-evaluates the DPI import each eval() cycle, so edges on
    // the returned value correctly trigger @(posedge clk) / @(posedge rst_n)
    // coroutines compiled by --timing.
    // =========================================================================
    wire clk;
    wire rst_n;

    import "DPI-C" function bit tb_dpi_get_clk();
    import "DPI-C" function bit tb_dpi_get_rst_n();

    assign clk   = tb_dpi_get_clk();
    assign rst_n = tb_dpi_get_rst_n();

    // =========================================================================
    // Shared testbench body (signals, DUT, fake_mem, tasks, test sequence)
    // =========================================================================
    `include "../tb/tb_core.sv"

endmodule
