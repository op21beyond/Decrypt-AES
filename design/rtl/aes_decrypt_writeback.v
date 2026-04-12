// =============================================================================
// File        : aes_decrypt_writeback.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Descriptor write-back module.
//               Issues a single-beat AXI4 write to update bytes 0-1 of a
//               descriptor's Header Word:
//                 Byte 0 (strobe=1): clear valid bit, preserve interrupt/last
//                 Byte 1 (strobe=1): write result state code
//               Uses byte-level AXI write strobe so only the two target bytes
//               are updated; bytes 2-3 are left untouched in memory.
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_writeback (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Write-back trigger
    // -------------------------------------------------------------------------
    input  wire        wb_start,        // pulse: issue the write-back
    input  wire [31:0] desc_base_addr,  // address of descriptor (32-bit word-aligned)
    input  wire [7:0]  ctrl_byte_orig,  // original control byte (to preserve interrupt/last)
    input  wire [7:0]  state_code,      // state byte to write (DSTATE_OK, DSTATE_CRC_ERR, etc.)
    output reg         wb_done,         // pulse: write-back AXI accepted

    // -------------------------------------------------------------------------
    // AXI4 write request port (to AXI manager, port 0 — writeback)
    // -------------------------------------------------------------------------
    output reg         wr_req_valid,
    input  wire        wr_req_ready,
    output reg  [31:0] wr_req_addr,
    output reg  [ 7:0] wr_req_len,     // always 0 (single beat)
    output wire [ 3:0] wr_req_cache,
    output wire [ 2:0] wr_req_prot,

    output reg         wr_wvalid,
    input  wire        wr_wready,
    output reg  [63:0] wr_wdata,
    output reg  [ 7:0] wr_wstrb,       // byte-strobe: only bytes 0-1 valid

    input  wire        wr_resp_valid,
    input  wire        wr_resp_err,

    // -------------------------------------------------------------------------
    // AxCACHE / AxPROT — use same attributes as descriptor reads
    // -------------------------------------------------------------------------
    input  wire [3:0]  arcache_desc,    // reuse descriptor cache setting for write-back
    input  wire [2:0]  arprot_desc,

    output reg         bus_err
);

    assign wr_req_cache = arcache_desc;
    assign wr_req_prot  = arprot_desc;

    localparam WB_IDLE  = 2'd0;
    localparam WB_AW    = 2'd1;   // issue AW
    localparam WB_W     = 2'd2;   // issue W
    localparam WB_WAIT  = 2'd3;   // wait for B

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= WB_IDLE;
            wr_req_valid <= 1'b0;
            wr_wvalid    <= 1'b0;
            wb_done      <= 1'b0;
            bus_err      <= 1'b0;
        end else begin
            wb_done  <= 1'b0;
            bus_err  <= 1'b0;

            case (state)
                WB_IDLE: begin
                    if (wb_start) begin
                        wr_req_addr  <= desc_base_addr;
                        wr_req_len   <= 8'd0;           // 1 beat
                        wr_req_valid <= 1'b1;
                        // Build data word:
                        //   Byte 0: ctrl with valid cleared  = ctrl_byte_orig & ~1
                        //   Byte 1: state_code
                        //   Bytes 2-3: unused but set to 0 (strobe will mask)
                        wr_wdata  <= {32'b0, 8'b0, 8'b0,
                                      state_code,
                                      (ctrl_byte_orig & 8'hFE)};
                        wr_wstrb  <= 8'h03;             // only bytes 0 and 1
                        state     <= WB_AW;
                    end
                end

                WB_AW: begin
                    if (wr_req_valid && wr_req_ready) begin
                        wr_req_valid <= 1'b0;
                        wr_wvalid    <= 1'b1;
                        state        <= WB_W;
                    end
                end

                WB_W: begin
                    if (wr_wvalid && wr_wready) begin
                        wr_wvalid <= 1'b0;
                        state     <= WB_WAIT;
                    end
                end

                WB_WAIT: begin
                    if (wr_resp_valid) begin
                        if (wr_resp_err)
                            bus_err <= 1'b1;
                        else
                            wb_done <= 1'b1;
                        state <= WB_IDLE;
                    end
                end

                default: state <= WB_IDLE;
            endcase
        end
    end

    `ifdef ENABLE_ASSERTIONS
    ASSERT_WB_SINGLE_BEAT : assert property (
        @(posedge clk) disable iff (!rst_n)
        wr_req_valid |-> (wr_req_len == 8'd0)
    ) else $error("[writeback] write-back burst length must be 0 (single beat)");

    ASSERT_WB_STROBE : assert property (
        @(posedge clk) disable iff (!rst_n)
        wr_wvalid |-> (wr_wstrb == 8'h03)
    ) else $error("[writeback] write strobe must be 0x03 (bytes 0-1 only)");
    `endif

endmodule
