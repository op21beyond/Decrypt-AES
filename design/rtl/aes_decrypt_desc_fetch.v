// =============================================================================
// File        : aes_decrypt_desc_fetch.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Descriptor fetch and decode module.
//               - Issues a 4-beat AXI4 burst read to fetch one 32-byte
//                 descriptor from the command ring buffer.
//               - Validates the 'valid' bit; if 0, signals a retry after
//                 the configured interval.
//               - Decodes all descriptor fields and presents them to the
//                 job controller.
//               - Manages the ring buffer head pointer.
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_desc_fetch (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Control from top-level FSM
    // -------------------------------------------------------------------------
    input  wire        fetch_start,     // pulse: begin fetching current HEAD descriptor
    output reg         fetch_done,      // pulse: descriptor decoded and presented
    output reg         fetch_invalid,   // pulse: descriptor was valid=0 (retry needed)

    // -------------------------------------------------------------------------
    // Ring buffer configuration
    // -------------------------------------------------------------------------
    input  wire [31:0] cmd_buf_addr,
    input  wire [9:0]  cmd_buf_size,
    input  wire [9:0]  cmd_tail_ptr,
    output reg  [9:0]  cmd_head_ptr,    // advanced here after successful fetch

    // -------------------------------------------------------------------------
    // AXI4 read request to AXI manager (port 0 — descriptor)
    // -------------------------------------------------------------------------
    output reg         rd_req_valid,
    input  wire        rd_req_ready,
    output reg  [31:0] rd_req_addr,
    output reg  [ 7:0] rd_req_len,
    output wire [ 3:0] rd_req_cache,
    output wire [ 2:0] rd_req_prot,

    // AXI4 read data back from manager
    input  wire        rd_resp_valid,
    input  wire [63:0] rd_resp_data,
    input  wire        rd_resp_last,
    input  wire        rd_resp_err,

    // -------------------------------------------------------------------------
    // AxCACHE / AxPROT for descriptor accesses
    // -------------------------------------------------------------------------
    input  wire [3:0]  arcache_desc,
    input  wire [2:0]  arprot_desc,

    // -------------------------------------------------------------------------
    // Decoded descriptor fields (valid when fetch_done=1)
    // -------------------------------------------------------------------------
    output reg  [7:0]  desc_ctrl_byte,  // Header Word byte 0: valid/interrupt/last
    output reg  [31:0] desc_in_addr,
    output reg  [31:0] desc_out_addr,
    output reg  [23:0] desc_in_data_size,
    output reg  [ 7:0] desc_in_pad_size,
    output reg  [23:0] desc_out_data_size,
    output reg  [ 7:0] desc_out_pad_size,

    // Bus error during fetch
    output reg         fetch_bus_err
);

    assign rd_req_cache = arcache_desc;
    assign rd_req_prot  = arprot_desc;

    // -------------------------------------------------------------------------
    // Descriptor fetch FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE    = 2'd0;
    localparam S_ISSUE   = 2'd1;  // issue AXI read request
    localparam S_COLLECT = 2'd2;  // collect 4 beats into desc_buf
    localparam S_DECODE  = 2'd3;  // decode and output

    reg [1:0] state;
    reg [1:0] beat_cnt;     // 0..3 for 4-beat burst
    reg [255:0] desc_buf;   // 32 bytes = 4 × 64-bit beats

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            beat_cnt       <= 2'd0;
            rd_req_valid   <= 1'b0;
            fetch_done     <= 1'b0;
            fetch_invalid  <= 1'b0;
            fetch_bus_err  <= 1'b0;
            cmd_head_ptr   <= 10'd0;
            desc_buf       <= 256'b0;
        end else begin
            // Default pulse signals
            fetch_done    <= 1'b0;
            fetch_invalid <= 1'b0;
            fetch_bus_err <= 1'b0;

            case (state)
                S_IDLE: begin
                    rd_req_valid <= 1'b0;
                    if (fetch_start) begin
                        // Address of descriptor = base + head_ptr * 32
                        rd_req_addr  <= cmd_buf_addr + {cmd_head_ptr, 5'b00000};
                        rd_req_len   <= 8'd3;   // 4 beats (len = beats - 1)
                        rd_req_valid <= 1'b1;
                        state        <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    if (rd_req_valid && rd_req_ready) begin
                        rd_req_valid <= 1'b0;
                        beat_cnt     <= 2'd0;
                        state        <= S_COLLECT;
                    end
                end

                S_COLLECT: begin
                    if (rd_resp_valid) begin
                        if (rd_resp_err) begin
                            fetch_bus_err <= 1'b1;
                            state         <= S_IDLE;
                        end else begin
                            // Pack beats into desc_buf: beat 0 → bits [63:0], etc.
                            desc_buf[beat_cnt*64 +: 64] <= rd_resp_data;
                            beat_cnt <= beat_cnt + 2'd1;
                            if (rd_resp_last)
                                state <= S_DECODE;
                        end
                    end
                end

                S_DECODE: begin
                    // Descriptor layout (little-endian, beat order):
                    // Beat 0 [63:0]  : [31:0]=Header Word, [63:32]=IN_ADDR
                    // Beat 1 [127:64]: [95:64]=OUT_ADDR, [127:96]=IN_SIZE_PAD
                    // Beat 2 [191:128]: [159:128]=OUT_SIZE_PAD, [191:160]=reserved
                    // Beat 3 [255:192]: reserved

                    // Header Word byte 0 = desc_buf[7:0]
                    desc_ctrl_byte     <= desc_buf[7:0];
                    // IN_ADDR = desc_buf[63:32]
                    desc_in_addr       <= desc_buf[63:32];
                    // OUT_ADDR = desc_buf[95:64]
                    desc_out_addr      <= desc_buf[95:64];
                    // IN_DATA_SIZE[23:0] = desc_buf[119:96], IN_PAD_SIZE = desc_buf[127:120]
                    desc_in_data_size  <= desc_buf[119:96];
                    desc_in_pad_size   <= desc_buf[127:120];
                    // OUT_DATA_SIZE[23:0] = desc_buf[151:128], OUT_PAD_SIZE = desc_buf[159:152]
                    desc_out_data_size <= desc_buf[151:128];
                    desc_out_pad_size  <= desc_buf[159:152];

                    // Check valid bit
                    if (desc_buf[`HDR_VALID]) begin
                        // Advance head pointer (wrap)
                        cmd_head_ptr <= (cmd_head_ptr == cmd_buf_size - 10'd1) ?
                                         10'd0 : cmd_head_ptr + 10'd1;
                        fetch_done   <= 1'b1;
                    end else begin
                        fetch_invalid <= 1'b1;  // caller will wait interval and retry
                    end

                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    // Head pointer must stay within ring buffer bounds
    ASSERT_HEAD_IN_BOUNDS : assert property (
        @(posedge clk) disable iff (!rst_n)
        cmd_head_ptr < cmd_buf_size
    ) else $error("[desc_fetch] cmd_head_ptr out of bounds");

    // fetch_start must not arrive while a fetch is in progress
    ASSERT_NO_CONCURRENT_FETCH : assert property (
        @(posedge clk) disable iff (!rst_n)
        (state != S_IDLE) |-> !fetch_start
    ) else $error("[desc_fetch] fetch_start during active fetch");
    `endif

    `ifdef ENABLE_COVERAGE
    covergroup cg_desc_fetch @(posedge clk);
        cp_valid_desc   : coverpoint fetch_done;
        cp_invalid_desc : coverpoint fetch_invalid;
        cp_bus_err      : coverpoint fetch_bus_err;
        cp_interrupt    : coverpoint (desc_ctrl_byte[`HDR_INTERRUPT]) iff (fetch_done);
        cp_last         : coverpoint (desc_ctrl_byte[`HDR_LAST])      iff (fetch_done);
    endgroup
    cg_desc_fetch cg_inst = new();
    `endif

endmodule
