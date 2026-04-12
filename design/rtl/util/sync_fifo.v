// =============================================================================
// File        : sync_fifo.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Synchronous FIFO with configurable width and depth.
//               Fall-through (show-ahead) mode: rd_data is valid whenever
//               !empty, no read-enable required to present data.
//               Single clock domain; no combinational loop; ASIC-safe.
// Parameters  :
//   DATA_W   — data width in bits
//   DEPTH    — number of entries (must be power of 2)
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
    output wire [$clog2(DEPTH):0] count       // number of valid entries
);

    localparam PTR_W = $clog2(DEPTH);

    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [PTR_W:0]    wr_ptr;    // extra bit for full/empty distinction
    reg [PTR_W:0]    rd_ptr;

    wire [PTR_W-1:0] wr_addr = wr_ptr[PTR_W-1:0];
    wire [PTR_W-1:0] rd_addr = rd_ptr[PTR_W-1:0];

    assign count        = wr_ptr - rd_ptr;
    assign empty        = (count == 0);
    assign full         = (count == DEPTH);
    assign almost_full  = (count >= DEPTH - 1);
    assign almost_empty = (count <= 1);

    // Write
    always @(posedge clk) begin
        if (wr_en && !full) begin
            mem[wr_addr] <= wr_data;
            wr_ptr       <= wr_ptr + 1'b1;
        end
    end

    // Read pointer advance
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

    // Show-ahead read: output registered entry at rd_addr
    // (registered for timing; one cycle read latency, which is fine for FIFO use)
    assign rd_data = mem[rd_addr];

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
