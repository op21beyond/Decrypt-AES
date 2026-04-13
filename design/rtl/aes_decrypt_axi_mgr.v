// =============================================================================
// File        : aes_decrypt_axi_mgr.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AXI4 Manager interface with two read requestors and two write
//               requestors.  Tracks outstanding transactions and enforces the
//               configurable limits (max_rd_out, max_wr_out ≤ 16).
//
//               Read requestors (priority: writeback > desc > input):
//                 RD port 0 (RDID_DESC)  : descriptor fetch
//                 RD port 1 (RDID_INPUT) : input buffer
//
//               Write requestors:
//                 WR port 0 (WRID_WRITEBACK) : descriptor write-back (always < 1 burst)
//                 WR port 1 (WRID_OUTPUT)    : output buffer stream
//
//               Bus error detection: any non-OKAY RRESP/BRESP causes
//               bus_error_out to pulse for one cycle.
//
//               AXI fixed parameters (per spec):
//                 AxBURST = INCR, AxSIZE = 8B, AxLOCK = 0,
//                 AxID = 0, AxREGION = 0
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_axi_mgr (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // AXI4 Manager interface
    // -------------------------------------------------------------------------
    // Write address
    output reg  [31:0] m_awaddr,
    output reg  [ 7:0] m_awlen,
    output reg  [ 2:0] m_awsize,
    output reg  [ 1:0] m_awburst,
    output reg  [ 3:0] m_awcache,
    output reg  [ 2:0] m_awprot,
    output reg         m_awvalid,
    input  wire        m_awready,
    // Write data
    output reg  [63:0] m_wdata,
    output reg  [ 7:0] m_wstrb,
    output reg         m_wlast,
    output reg         m_wvalid,
    input  wire        m_wready,
    // Write response
    input  wire [ 1:0] m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    // Read address
    output reg  [31:0] m_araddr,
    output reg  [ 7:0] m_arlen,
    output reg  [ 2:0] m_arsize,
    output reg  [ 1:0] m_arburst,
    output reg  [ 3:0] m_arcache,
    output reg  [ 2:0] m_arprot,
    output reg         m_arvalid,
    input  wire        m_arready,
    // Read data
    input  wire [63:0] m_rdata,
    input  wire [ 1:0] m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    // -------------------------------------------------------------------------
    // Read request port 0 — descriptor fetch (higher priority)
    // -------------------------------------------------------------------------
    input  wire        rd0_req_valid,
    output wire        rd0_req_ready,
    input  wire [31:0] rd0_req_addr,
    input  wire [ 7:0] rd0_req_len,
    input  wire [ 3:0] rd0_req_cache,
    input  wire [ 2:0] rd0_req_prot,
    // Response back to requester 0
    output wire        rd0_resp_valid,
    output wire [63:0] rd0_resp_data,
    output wire        rd0_resp_last,
    output wire        rd0_resp_err,

    // -------------------------------------------------------------------------
    // Read request port 1 — input buffer (lower priority)
    // -------------------------------------------------------------------------
    input  wire        rd1_req_valid,
    output wire        rd1_req_ready,
    input  wire [31:0] rd1_req_addr,
    input  wire [ 7:0] rd1_req_len,
    input  wire [ 3:0] rd1_req_cache,
    input  wire [ 2:0] rd1_req_prot,
    // Response back to requester 1
    output wire        rd1_resp_valid,
    output wire [63:0] rd1_resp_data,
    output wire        rd1_resp_last,
    output wire        rd1_resp_err,

    // -------------------------------------------------------------------------
    // Write request port 0 — descriptor write-back (higher priority)
    // -------------------------------------------------------------------------
    input  wire        wr0_req_valid,
    output wire        wr0_req_ready,
    input  wire [31:0] wr0_req_addr,
    input  wire [ 7:0] wr0_req_len,
    input  wire [ 3:0] wr0_req_cache,
    input  wire [ 2:0] wr0_req_prot,
    input  wire [63:0] wr0_wdata,
    input  wire [ 7:0] wr0_wstrb,
    input  wire        wr0_wvalid,
    output wire        wr0_wready,
    output wire        wr0_resp_valid,
    output wire        wr0_resp_err,

    // -------------------------------------------------------------------------
    // Write request port 1 — output buffer stream (lower priority)
    // -------------------------------------------------------------------------
    input  wire        wr1_req_valid,
    output wire        wr1_req_ready,
    input  wire [31:0] wr1_req_addr,
    input  wire [ 7:0] wr1_req_len,
    input  wire [ 3:0] wr1_req_cache,
    input  wire [ 2:0] wr1_req_prot,
    input  wire [63:0] wr1_wdata,
    input  wire [ 7:0] wr1_wstrb,
    input  wire        wr1_wvalid,
    input  wire        wr1_wlast,       // last beat of output burst (from output_ctrl)
    output wire        wr1_wready,
    output wire        wr1_resp_valid,
    output wire        wr1_resp_err,

    // -------------------------------------------------------------------------
    // Limits and error
    // -------------------------------------------------------------------------
    input  wire [4:0]  max_rd_outstanding,
    input  wire [4:0]  max_wr_outstanding,
    output wire        bus_error_out       // pulses 1 cycle on any RRESP/BRESP error
);

    // -------------------------------------------------------------------------
    // Outstanding transaction counters (simple saturating counters)
    // -------------------------------------------------------------------------
    reg [4:0] rd_outstanding;  // count of in-flight read address transactions
    reg [4:0] wr_outstanding;  // count of in-flight write address transactions

    wire rd_can_issue = (rd_outstanding < max_rd_outstanding);
    wire wr_can_issue = (wr_outstanding < max_wr_outstanding);

    // Track which read requestor owns each in-flight transaction (round-robin
    // between desc(0) and input(1); FIFO of IDs to route responses)
    // Use a 16-entry shift register for response routing.
    reg [15:0] rd_id_fifo;   // bit i=0 → desc, bit i=1 → input
    reg [4:0]  rd_id_head;   // index of oldest in-flight transaction
    reg [4:0]  rd_id_tail;

    // Similarly for write responses
    reg [15:0] wr_id_fifo;
    reg [4:0]  wr_id_head;
    reg [4:0]  wr_id_tail;

    // -------------------------------------------------------------------------
    // Read address channel arbitration (fixed priority: port0 > port1)
    // -------------------------------------------------------------------------
    wire rd0_win = rd0_req_valid && rd_can_issue;
    wire rd1_win = rd1_req_valid && rd_can_issue && !rd0_req_valid;

    assign rd0_req_ready = rd0_win && m_arready;
    assign rd1_req_ready = rd1_win && m_arready && !rd0_req_valid;

    always @(*) begin
        m_arvalid = 1'b0;
        m_araddr  = 32'b0;
        m_arlen   = 8'b0;
        m_arcache = 4'b0;
        m_arprot  = 3'b0;
        m_arsize  = `AXI_SIZE_8B;
        m_arburst = `AXI_BURST_INCR;

        if (rd0_win) begin
            m_arvalid = 1'b1;
            m_araddr  = rd0_req_addr;
            m_arlen   = rd0_req_len;
            m_arcache = rd0_req_cache;
            m_arprot  = rd0_req_prot;
        end else if (rd1_win) begin
            m_arvalid = 1'b1;
            m_araddr  = rd1_req_addr;
            m_arlen   = rd1_req_len;
            m_arcache = rd1_req_cache;
            m_arprot  = rd1_req_prot;
        end
    end

    // Track outstanding reads and requestor ID FIFO
    wire ar_accepted = m_arvalid && m_arready;
    wire r_last_beat = m_rvalid && m_rlast;  // one transaction completing

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_outstanding <= 5'd0;
            rd_id_fifo     <= 16'b0;
            rd_id_tail     <= 5'd0;
            rd_id_head     <= 5'd0;
        end else begin
            if (ar_accepted && !r_last_beat)
                rd_outstanding <= rd_outstanding + 5'd1;
            else if (!ar_accepted && r_last_beat && rd_outstanding > 0)
                rd_outstanding <= rd_outstanding - 5'd1;

            if (ar_accepted) begin
                // Record which port won (0=desc, 1=input)
                rd_id_fifo[rd_id_tail[3:0]] <= rd1_win ? 1'b1 : 1'b0;
                rd_id_tail <= rd_id_tail + 5'd1;
            end
            if (r_last_beat && rd_id_head != rd_id_tail) begin
                rd_id_head <= rd_id_head + 5'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read data routing — return data to the requestor that owns this burst
    // -------------------------------------------------------------------------
    assign m_rready = 1'b1; // always accept read data

    wire current_rd_id = rd_id_fifo[rd_id_head[3:0]];

    assign rd0_resp_valid = m_rvalid && (current_rd_id == 1'b0);
    assign rd0_resp_data  = m_rdata;
    assign rd0_resp_last  = m_rlast;
    assign rd0_resp_err   = (m_rresp != 2'b00);

    assign rd1_resp_valid = m_rvalid && (current_rd_id == 1'b1);
    assign rd1_resp_data  = m_rdata;
    assign rd1_resp_last  = m_rlast;
    assign rd1_resp_err   = (m_rresp != 2'b00);

    // -------------------------------------------------------------------------
    // Write address channel arbitration (fixed priority: port0 > port1)
    // -------------------------------------------------------------------------
    wire wr0_win = wr0_req_valid && wr_can_issue;
    wire wr1_win = wr1_req_valid && wr_can_issue && !wr0_req_valid;

    // Track which write port is currently streaming data (for W channel mux)
    reg wr_active_id;   // 0 = port0, 1 = port1
    reg wr_data_phase;  // write address accepted; now sending data

    assign wr0_req_ready = wr0_win && m_awready && !wr_data_phase;
    assign wr1_req_ready = wr1_win && m_awready && !wr_data_phase && !wr0_req_valid;

    always @(*) begin
        m_awvalid = 1'b0;
        m_awaddr  = 32'b0;
        m_awlen   = 8'b0;
        m_awcache = 4'b0;
        m_awprot  = 3'b0;
        m_awsize  = `AXI_SIZE_8B;
        m_awburst = `AXI_BURST_INCR;

        if (!wr_data_phase) begin
            if (wr0_win) begin
                m_awvalid = 1'b1;
                m_awaddr  = wr0_req_addr;
                m_awlen   = wr0_req_len;
                m_awcache = wr0_req_cache;
                m_awprot  = wr0_req_prot;
            end else if (wr1_win) begin
                m_awvalid = 1'b1;
                m_awaddr  = wr1_req_addr;
                m_awlen   = wr1_req_len;
                m_awcache = wr1_req_cache;
                m_awprot  = wr1_req_prot;
            end
        end
    end

    wire aw_accepted = m_awvalid && m_awready;
    wire b_accepted  = m_bvalid;               // bready always 1 (below)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_outstanding <= 5'd0;
            wr_active_id   <= 1'b0;
            wr_data_phase  <= 1'b0;
            wr_id_fifo     <= 16'b0;
            wr_id_tail     <= 5'd0;
            wr_id_head     <= 5'd0;
        end else begin
            if (aw_accepted && !b_accepted)
                wr_outstanding <= wr_outstanding + 5'd1;
            else if (!aw_accepted && b_accepted && wr_outstanding > 0)
                wr_outstanding <= wr_outstanding - 5'd1;

            if (aw_accepted) begin
                wr_active_id  <= wr1_win ? 1'b1 : 1'b0;
                wr_data_phase <= 1'b1;
                wr_id_fifo[wr_id_tail[3:0]] <= wr1_win ? 1'b1 : 1'b0;
                wr_id_tail <= wr_id_tail + 5'd1;
            end

            // Data phase ends when wlast is accepted
            if (wr_data_phase && m_wvalid && m_wready && m_wlast)
                wr_data_phase <= 1'b0;

            if (b_accepted && wr_id_head != wr_id_tail)
                wr_id_head <= wr_id_head + 5'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Write data channel mux
    // -------------------------------------------------------------------------
    assign wr0_wready = wr_data_phase && (wr_active_id == 1'b0) && m_wready;
    assign wr1_wready = wr_data_phase && (wr_active_id == 1'b1) && m_wready;

    always @(*) begin
        m_wvalid = 1'b0;
        m_wdata  = 64'b0;
        m_wstrb  = 8'b0;
        m_wlast  = 1'b0;

        if (wr_data_phase) begin
            if (wr_active_id == 1'b0) begin
                m_wvalid = wr0_wvalid;
                m_wdata  = wr0_wdata;
                m_wstrb  = wr0_wstrb;
                m_wlast  = wr0_wvalid; // writeback is always single-beat
            end else begin
                m_wvalid = wr1_wvalid;
                m_wdata  = wr1_wdata;
                m_wstrb  = wr1_wstrb;
                m_wlast  = wr1_wlast;   // driven by aes_decrypt_output_ctrl
            end
        end
    end

    // -------------------------------------------------------------------------
    // Write response routing
    // -------------------------------------------------------------------------
    assign m_bready = 1'b1; // always accept write responses

    wire current_wr_id = wr_id_fifo[wr_id_head[3:0]];

    assign wr0_resp_valid = m_bvalid && (current_wr_id == 1'b0);
    assign wr0_resp_err   = (m_bresp != 2'b00);

    assign wr1_resp_valid = m_bvalid && (current_wr_id == 1'b1);
    assign wr1_resp_err   = (m_bresp != 2'b00);

    // -------------------------------------------------------------------------
    // Bus error detection (single-cycle pulse)
    // -------------------------------------------------------------------------
    assign bus_error_out = (m_rvalid && (m_rresp != 2'b00)) ||
                           (m_bvalid && (m_bresp != 2'b00));

    // -------------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    ASSERT_RD_OUTSTANDING_LIMIT : assert property (
        @(posedge clk) disable iff (!rst_n)
        rd_outstanding <= max_rd_outstanding
    ) else $error("[axi_mgr] Read outstanding limit exceeded");

    ASSERT_WR_OUTSTANDING_LIMIT : assert property (
        @(posedge clk) disable iff (!rst_n)
        wr_outstanding <= max_wr_outstanding
    ) else $error("[axi_mgr] Write outstanding limit exceeded");

    ASSERT_AXSIZE_RD : assert property (
        @(posedge clk) disable iff (!rst_n)
        m_arvalid |-> (m_arsize == `AXI_SIZE_8B && m_arburst == `AXI_BURST_INCR)
    ) else $error("[axi_mgr] AR: unexpected AxSIZE or AxBURST");

    ASSERT_AXSIZE_WR : assert property (
        @(posedge clk) disable iff (!rst_n)
        m_awvalid |-> (m_awsize == `AXI_SIZE_8B && m_awburst == `AXI_BURST_INCR)
    ) else $error("[axi_mgr] AW: unexpected AxSIZE or AxBURST");
    `endif

endmodule
