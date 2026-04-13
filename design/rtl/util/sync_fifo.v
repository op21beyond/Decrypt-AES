// =============================================================================
// File        : sync_fifo.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Synchronous FIFO with configurable width and depth.
//               Fall-through (show-ahead) mode: rd_data is valid whenever
//               !empty, no read-enable required to present data.
//               Single clock domain; no combinational loop; ASIC-safe.
//
//               Memory interface is EXTERNAL: the internal reg mem[] has been
//               removed and replaced with a dual-port SRAM interface.
//               Connect mem_* ports to the foundry SRAM macro via
//               aes_decrypt_mem_top.  For simulation, connect to the
//               sram_2p_NxM behavioral model.
//
//               SRAM interface (write-synchronous / read-asynchronous):
//                 mem_wen  — write enable (active-high, registered by SRAM on CLK)
//                 mem_wa   — write address
//                 mem_wd   — write data
//                 mem_ra   — read address  (asynchronous)
//                 mem_q    — read data     (combinational output from SRAM)
//
// Parameters  :
//   DATA_W   — data width in bits
//   DEPTH    — number of entries (must be power of 2, max 32)
// =============================================================================

module sync_fifo #(
    parameter DATA_W = 64,
    parameter DEPTH  = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    // Write port
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,
    output wire              almost_full,    // DEPTH-2 or more entries used

    // Read port
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty,
    output wire              almost_empty,   // 1 or fewer entries remaining

    // Status
    output wire [$clog2(DEPTH):0] count,     // number of valid entries

    // -------------------------------------------------------------------------
    // External SRAM memory interface
    // Connect to sram_2p_NxM (or foundry SRAM macro) via aes_decrypt_mem_top.
    // -------------------------------------------------------------------------
    output wire                         mem_wen,   // write enable  (active-high)
    output wire [$clog2(DEPTH)-1:0]     mem_wa,    // write address
    output wire [DATA_W-1:0]            mem_wd,    // write data
    output wire [$clog2(DEPTH)-1:0]     mem_ra,    // read address (async)
    input  wire [DATA_W-1:0]            mem_q      // read data    (async)
);

    localparam PTR_W = $clog2(DEPTH);

    reg [PTR_W:0] wr_ptr;    // extra bit for full/empty distinction
    reg [PTR_W:0] rd_ptr;

    wire [PTR_W-1:0] wr_addr = wr_ptr[PTR_W-1:0];
    wire [PTR_W-1:0] rd_addr = rd_ptr[PTR_W-1:0];

    assign count        = wr_ptr - rd_ptr;
    assign empty        = (count == 0);
    assign full         = (count == DEPTH);
    assign almost_full  = (count >= DEPTH - 1);
    assign almost_empty = (count <= 1);

    // -------------------------------------------------------------------------
    // Pointer management (single always block — no double-driver)
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= {(PTR_W+1){1'b0}};
            wr_ptr <= {(PTR_W+1){1'b0}};
        end else begin
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
            if (wr_en && !full)
                wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // External SRAM interface
    // -------------------------------------------------------------------------
    assign mem_wen = wr_en && !full;
    assign mem_wa  = wr_addr;
    assign mem_wd  = wr_data;
    assign mem_ra  = rd_addr;
    assign rd_data = mem_q;

    // -----------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    // Overflow / underflow checks
    ASSERT_NO_OVERFLOW : assert property (
        @(posedge clk) disable iff (!rst_n)
        !(wr_en && full)
    ) else $error("[sync_fifo] OVERFLOW: wr_en asserted while full");

    ASSERT_NO_UNDERFLOW : assert property (
        @(posedge clk) disable iff (!rst_n)
        !(rd_en && empty)
    ) else $error("[sync_fifo] UNDERFLOW: rd_en asserted while empty");
    `endif

endmodule
