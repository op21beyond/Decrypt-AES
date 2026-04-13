// =============================================================================
// File        : fake_mem.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Fake AXI4 Subordinate memory for simulation.
//               Responds to the DUT's AXI4 Manager (memory bus) interface.
//               - 64-bit data bus, INCR bursts only
//               - Configurable read/write error injection via backdoor tasks
//               - Single-cycle read data latency after AR acceptance
//               - Reads and writes handled in separate always blocks
//               - Memory initialised via $readmemh from HEX_FILE
//               - Backdoor read/write tasks for testbench verification
//
// Parameters:
//   MEM_BASE  : byte base address mapped to index 0
//   MEM_WORDS : number of 64-bit words (total = MEM_WORDS × 8 bytes)
//   HEX_FILE  : path to hex file loaded by $readmemh
//
// Error injection:
//   Call set_read_error(addr)  before a burst to make that burst return SLVERR.
//   Call set_write_error(addr) before a burst to make that burst return SLVERR.
//   Call clear_read_error() / clear_write_error() to cancel injection.
//   The injected address is matched against the burst start address (ARADDR/AWADDR).
// =============================================================================

`timescale 1ns/1ps

module fake_mem #(
    parameter [31:0] MEM_BASE  = 32'h0000_1000,
    parameter        MEM_WORDS = 256,
    parameter        HEX_FILE  = "mem_init.hex"
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4 Subordinate — Read Address
    input  wire [31:0] s_araddr,
    input  wire [ 7:0] s_arlen,
    input  wire        s_arvalid,
    output reg         s_arready,

    // AXI4 Subordinate — Read Data
    output reg  [63:0] s_rdata,
    output reg  [ 1:0] s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,

    // AXI4 Subordinate — Write Address
    input  wire [31:0] s_awaddr,
    input  wire [ 7:0] s_awlen,
    input  wire        s_awvalid,
    output reg         s_awready,

    // AXI4 Subordinate — Write Data
    input  wire [63:0] s_wdata,
    input  wire [ 7:0] s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output reg         s_wready,

    // AXI4 Subordinate — Write Response
    output reg  [ 1:0] s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready
);

    // -------------------------------------------------------------------------
    // Memory array (64-bit words, loaded from HEX_FILE)
    // -------------------------------------------------------------------------
    reg [63:0] mem_w [0:MEM_WORDS-1];

    integer k;
    initial begin
        for (k = 0; k < MEM_WORDS; k = k + 1)
            mem_w[k] = 64'h0;
        $readmemh(HEX_FILE, mem_w);
    end

    // Convert byte address → word index (relative to MEM_BASE)
    function [31:0] widx;
        input [31:0] ba;
        widx = (ba - MEM_BASE) >> 3;
    endfunction

    // -------------------------------------------------------------------------
    // Error injection registers (controlled via backdoor tasks)
    // -------------------------------------------------------------------------
    reg        err_r_en;    // enable read-error injection
    reg [31:0] err_r_addr;  // burst start address that triggers SLVERR on reads
    reg        err_w_en;    // enable write-error injection
    reg [31:0] err_w_addr;  // burst start address that triggers SLVERR on writes

    initial begin
        err_r_en   = 1'b0;
        err_r_addr = 32'h0;
        err_w_en   = 1'b0;
        err_w_addr = 32'h0;
    end

    // Active-burst copies latched at AR/AW acceptance to avoid race with task
    reg        cur_rd_inject;
    reg        cur_wr_inject;

    // -------------------------------------------------------------------------
    // Read channel (AR + R)
    // One burst at a time; ARREADY deasserts while a burst is in progress.
    // -------------------------------------------------------------------------
    reg        rd_active;
    reg [31:0] rd_addr;     // current burst word address (byte)
    reg [ 7:0] rd_beats;    // remaining beats

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_arready    <= 1'b1;
            s_rvalid     <= 1'b0;
            s_rdata      <= 64'h0;
            s_rresp      <= 2'b00;
            s_rlast      <= 1'b0;
            rd_active    <= 1'b0;
            rd_addr      <= 32'h0;
            rd_beats     <= 8'h0;
            cur_rd_inject<= 1'b0;
        end else begin
            // Accept new AR when not busy
            if (!rd_active && s_arvalid && s_arready) begin
                rd_addr      <= s_araddr;
                rd_beats     <= s_arlen;   // beats-1
                rd_active    <= 1'b1;
                s_arready    <= 1'b0;
                // Latch error-inject decision at AR acceptance time
                cur_rd_inject<= err_r_en && (s_araddr == err_r_addr);
            end

            // Issue R beats
            if (rd_active) begin
                if (!s_rvalid || s_rready) begin
                    s_rvalid <= 1'b1;
                    // Return memory data even on error (DUT should ignore it)
                    s_rdata  <= mem_w[widx(rd_addr)];
                    s_rresp  <= cur_rd_inject ? 2'b10 : 2'b00; // SLVERR or OKAY
                    s_rlast  <= (rd_beats == 8'h0);

                    if (rd_beats == 8'h0) begin
                        rd_active <= 1'b0;
                        s_arready <= 1'b1;
                    end else begin
                        rd_addr  <= rd_addr + 32'h8;
                        rd_beats <= rd_beats - 8'h1;
                    end
                end
            end else begin
                if (s_rvalid && s_rready) begin
                    s_rvalid <= 1'b0;
                    s_rlast  <= 1'b0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Write channel (AW + W + B)
    // One burst at a time; AWREADY deasserts while a burst is in progress.
    // -------------------------------------------------------------------------
    localparam WR_AW    = 2'd0;
    localparam WR_DATA  = 2'd1;
    localparam WR_BRESP = 2'd2;

    reg [1:0]  wr_state;
    reg [31:0] wr_addr;
    reg [ 7:0] wr_beats;
    integer    b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_awready    <= 1'b1;
            s_wready     <= 1'b0;
            s_bvalid     <= 1'b0;
            s_bresp      <= 2'b00;
            wr_state     <= WR_AW;
            wr_addr      <= 32'h0;
            wr_beats     <= 8'h0;
            cur_wr_inject<= 1'b0;
        end else begin
            case (wr_state)
                WR_AW: begin
                    s_wready <= 1'b0;
                    if (s_awvalid && s_awready) begin
                        wr_addr      <= s_awaddr;
                        wr_beats     <= s_awlen;
                        s_awready    <= 1'b0;
                        s_wready     <= 1'b1;
                        // Latch error-inject decision at AW acceptance time
                        cur_wr_inject<= err_w_en && (s_awaddr == err_w_addr);
                        wr_state     <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (s_wvalid && s_wready) begin
                        // Apply byte strobes (only when NOT injecting error)
                        if (!cur_wr_inject) begin
                            for (b = 0; b < 8; b = b + 1) begin
                                if (s_wstrb[b])
                                    mem_w[widx(wr_addr)][(b*8)+:8] <= s_wdata[(b*8)+:8];
                            end
                        end
                        if (s_wlast) begin
                            s_wready <= 1'b0;
                            s_bvalid <= 1'b1;
                            s_bresp  <= cur_wr_inject ? 2'b10 : 2'b00; // SLVERR or OKAY
                            wr_state <= WR_BRESP;
                        end else begin
                            wr_addr  <= wr_addr + 32'h8;
                            wr_beats <= wr_beats - 8'h1;
                        end
                    end
                end

                WR_BRESP: begin
                    if (s_bvalid && s_bready) begin
                        s_bvalid  <= 1'b0;
                        s_awready <= 1'b1;
                        wr_state  <= WR_AW;
                    end
                end

                default: wr_state <= WR_AW;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Backdoor tasks — used by testbench to verify and manipulate memory
    // -------------------------------------------------------------------------
    task backdoor_read64;
        input  [31:0] byte_addr;
        output [63:0] data;
        begin
            data = mem_w[widx(byte_addr)];
        end
    endtask

    task backdoor_read8;
        input  [31:0] byte_addr;
        output [ 7:0] data;
        reg    [31:0] wi;
        reg    [ 2:0] bi;
        begin
            wi   = widx(byte_addr);
            bi   = byte_addr[2:0];
            data = mem_w[wi][(bi*8)+:8];
        end
    endtask

    task backdoor_write8;
        input  [31:0] byte_addr;
        input  [ 7:0] data;
        reg    [31:0] wi;
        reg    [ 2:0] bi;
        begin
            wi = widx(byte_addr);
            bi = byte_addr[2:0];
            mem_w[wi][(bi*8)+:8] = data;
        end
    endtask

    // Error injection control tasks
    task set_read_error;
        input [31:0] addr;
        begin
            err_r_addr = addr;
            err_r_en   = 1'b1;
        end
    endtask

    task clear_read_error;
        begin
            err_r_en = 1'b0;
        end
    endtask

    task set_write_error;
        input [31:0] addr;
        begin
            err_w_addr = addr;
            err_w_en   = 1'b1;
        end
    endtask

    task clear_write_error;
        begin
            err_w_en = 1'b0;
        end
    endtask

endmodule
