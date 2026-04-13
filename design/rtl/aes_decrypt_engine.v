// =============================================================================
// File        : aes_decrypt_engine.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES Decryption Engine — top-level module.
//               Instantiates and wires all sub-modules:
//                 - aes_decrypt_regfile   (AXI4-Lite Subordinate)
//                 - aes_decrypt_ctrl      (top-level FSM)
//                 - aes_decrypt_desc_fetch
//                 - aes_decrypt_input_ctrl
//                 - aes_decrypt_output_ctrl
//                 - aes_decrypt_writeback
//                 - aes_decrypt_axi_mgr   (AXI4 Manager)
//                 - aes128_key_sched
//                 - aes128_ctr_top
//                 - crc32_engine
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_engine (
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // AXI4-Lite Subordinate (register interface)
    // =========================================================================
    input  wire [7:0]  s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [7:0]  s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    // =========================================================================
    // AXI4 Manager (memory bus)
    // =========================================================================
    output wire [31:0] m_awaddr,
    output wire [ 7:0] m_awlen,
    output wire [ 2:0] m_awsize,
    output wire [ 1:0] m_awburst,
    output wire [ 3:0] m_awcache,
    output wire [ 2:0] m_awprot,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [63:0] m_wdata,
    output wire [ 7:0] m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [ 1:0] m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire [ 7:0] m_arlen,
    output wire [ 2:0] m_arsize,
    output wire [ 1:0] m_arburst,
    output wire [ 3:0] m_arcache,
    output wire [ 2:0] m_arprot,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [63:0] m_rdata,
    input  wire [ 1:0] m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    // =========================================================================
    // Interrupt
    // =========================================================================
    output wire        irq
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // --- Register file outputs ---
    wire        ctrl_start, ctrl_resume, ctrl_immediate_stop;
    wire [1:0]  status_state;
    wire        hw_set_bus_error, hw_set_irq_done, hw_set_irq_buserr;
    wire [127:0] aes_key;
    wire        crc_alg_sel;
    wire [4:0]  max_rd_outstanding, max_wr_outstanding;
    wire [3:0]  arcache_desc, arcache_in, awcache_out;
    wire [2:0]  arprot_desc, arprot_in, awprot_out;
    wire [31:0] cmd_buf_addr;
    wire [9:0]  cmd_buf_size, cmd_tail_ptr, cmd_head_ptr;
    wire [15:0] interval_cycles;

    // --- AXI key schedule ---
    wire [1407:0] rk_out;

    // --- Descriptor fetch ---
    wire        fetch_start, fetch_done, fetch_invalid, fetch_bus_err;
    wire [9:0]  fetch_head_ptr;
    wire [7:0]  desc_ctrl_byte;
    wire [31:0] desc_in_addr, desc_out_addr;
    wire [23:0] desc_in_data_size, desc_out_data_size;
    wire [7:0]  desc_in_pad_size, desc_out_pad_size;

    // --- AXI manager: read port 0 (descriptor) ---
    wire        rd0_req_valid, rd0_req_ready;
    wire [31:0] rd0_req_addr;
    wire [7:0]  rd0_req_len;
    wire [3:0]  rd0_req_cache;
    wire [2:0]  rd0_req_prot;
    wire        rd0_resp_valid;
    wire [63:0] rd0_resp_data;
    wire        rd0_resp_last, rd0_resp_err;

    // --- AXI manager: read port 1 (input buffer) ---
    wire        rd1_req_valid, rd1_req_ready;
    wire [31:0] rd1_req_addr;
    wire [7:0]  rd1_req_len;
    wire [3:0]  rd1_req_cache;
    wire [2:0]  rd1_req_prot;
    wire        rd1_resp_valid;
    wire [63:0] rd1_resp_data;
    wire        rd1_resp_last, rd1_resp_err;

    // --- AXI manager: write port 0 (writeback) ---
    wire        wr0_req_valid, wr0_req_ready;
    wire [31:0] wr0_req_addr;
    wire [7:0]  wr0_req_len;
    wire [3:0]  wr0_req_cache;
    wire [2:0]  wr0_req_prot;
    wire [63:0] wr0_wdata;
    wire [7:0]  wr0_wstrb;
    wire        wr0_wvalid, wr0_wready;
    wire        wr0_resp_valid, wr0_resp_err;

    // --- AXI manager: write port 1 (output buffer) ---
    wire        wr1_req_valid, wr1_req_ready;
    wire [31:0] wr1_req_addr;
    wire [7:0]  wr1_req_len;
    wire [3:0]  wr1_req_cache;
    wire [2:0]  wr1_req_prot;
    wire [63:0] wr1_wdata;
    wire [7:0]  wr1_wstrb;
    wire        wr1_wvalid, wr1_wready, wr1_wlast;
    wire        wr1_resp_valid, wr1_resp_err;

    wire        bus_error_out;

    // --- SRAM memory interfaces ---
    wire        cipher_mem_wen;
    wire [4:0]  cipher_mem_wa;
    wire [63:0] cipher_mem_wd;
    wire [4:0]  cipher_mem_ra;
    wire [63:0] cipher_mem_q;

    wire        out_mem_wen;
    wire [4:0]  out_mem_wa;
    wire [71:0] out_mem_wd;
    wire [4:0]  out_mem_ra;
    wire [71:0] out_mem_q;

    // --- Input controller ---
    wire        input_job_start, input_job_done, input_bus_err;
    wire [95:0] aes_nonce;
    wire [31:0] aes_initial_ctr;
    wire        aes_hdr_valid;
    wire [31:0] crc_expected;
    wire        crc_valid;
    wire        cipher_valid;
    wire [63:0] cipher_data;
    wire [7:0]  cipher_bvalid;
    wire        cipher_stall;

    // --- 64→128 beat assembler ---
    wire        aes_in_stall;    // back-pressure out of aes128_ctr_top (currently 0)
    // Stall input_ctrl when output FIFO is almost full or AES itself stalls.
    // The AES pipeline is 10 cycles; out_fifo depth is 32 beats (16 blocks),
    // so almost_full fires early enough to drain the pipeline safely.
    assign cipher_stall = plain_stall | aes_in_stall;

    // Assembled 128-bit block: two consecutive 64-bit beats from input_ctrl.
    // Beat 0 (even) → assem_lo_r; Beat 1 (odd) + assem_lo_r → 128-bit block.
    reg  [63:0]  assem_lo_r;
    reg          assem_beat_cnt;  // 0=waiting for beat-0, 1=waiting for beat-1

    wire         assem_out_valid = cipher_valid && assem_beat_cnt;
    wire [127:0] assem_out_data  = {cipher_data, assem_lo_r};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assem_lo_r     <= 64'b0;
            assem_beat_cnt <= 1'b0;
        end else if (input_job_start) begin
            // Re-align beat counter at job boundaries
            assem_beat_cnt <= 1'b0;
        end else if (cipher_valid) begin
            if (!assem_beat_cnt) begin
                assem_lo_r     <= cipher_data;   // latch even beat
                assem_beat_cnt <= 1'b1;
            end else begin
                assem_beat_cnt <= 1'b0;          // odd beat consumed; block presented this cycle
            end
        end
    end

    // --- AES CTR ---
    wire        aes_job_start;
    wire [95:0] aes_nonce_reg;
    wire [31:0] aes_ctr_reg;
    wire        aes_out_valid;
    wire [127:0] aes_out_plain;

    // --- CRC engine ---
    wire        crc_init;
    wire [31:0] crc_computed;

    // --- Output controller ---
    wire        output_job_start, output_job_done, output_bus_err;
    wire        plain_stall;

    // --- Write-back ---
    wire        wb_start, wb_done, wb_bus_err;
    wire [31:0] wb_addr;
    wire [7:0]  wb_ctrl_orig, wb_state_code;

    // =========================================================================
    // Sub-module instantiations
    // =========================================================================

    // --- Register file ---
    aes_decrypt_regfile u_regfile (
        .clk               (clk),
        .rst_n             (rst_n),
        .s_awaddr          (s_awaddr),   .s_awvalid (s_awvalid), .s_awready (s_awready),
        .s_wdata           (s_wdata),    .s_wstrb   (s_wstrb),   .s_wvalid  (s_wvalid),
        .s_wready          (s_wready),
        .s_bresp           (s_bresp),    .s_bvalid  (s_bvalid),  .s_bready  (s_bready),
        .s_araddr          (s_araddr),   .s_arvalid (s_arvalid), .s_arready (s_arready),
        .s_rdata           (s_rdata),    .s_rresp   (s_rresp),   .s_rvalid  (s_rvalid),
        .s_rready          (s_rready),
        .ctrl_start        (ctrl_start),
        .ctrl_resume       (ctrl_resume),
        .ctrl_immediate_stop(ctrl_immediate_stop),
        .status_state      (status_state),
        .hw_set_bus_error  (hw_set_bus_error),
        .hw_set_irq_done   (hw_set_irq_done),
        .hw_set_irq_buserr (hw_set_irq_buserr),
        .aes_key           (aes_key),
        .crc_alg_sel       (crc_alg_sel),
        .max_rd_outstanding(max_rd_outstanding),
        .max_wr_outstanding(max_wr_outstanding),
        .arcache_desc      (arcache_desc),  .arcache_in (arcache_in),
        .awcache_out       (awcache_out),
        .arprot_desc       (arprot_desc),   .arprot_in  (arprot_in),
        .awprot_out        (awprot_out),
        .cmd_buf_addr      (cmd_buf_addr),
        .cmd_buf_size      (cmd_buf_size),
        .cmd_head_ptr      (cmd_head_ptr),
        .cmd_tail_ptr      (cmd_tail_ptr),
        .interval_cycles   (interval_cycles),
        .irq               (irq)
    );

    // --- AES key schedule (combinational) ---
    aes128_key_sched u_key_sched (
        .key_in  (aes_key),
        .rk_out  (rk_out)
    );

    // --- AXI Manager ---
    aes_decrypt_axi_mgr u_axi_mgr (
        .clk               (clk),       .rst_n            (rst_n),
        .m_awaddr          (m_awaddr),  .m_awlen          (m_awlen),
        .m_awsize          (m_awsize),  .m_awburst        (m_awburst),
        .m_awcache         (m_awcache), .m_awprot         (m_awprot),
        .m_awvalid         (m_awvalid), .m_awready        (m_awready),
        .m_wdata           (m_wdata),   .m_wstrb          (m_wstrb),
        .m_wlast           (m_wlast),   .m_wvalid         (m_wvalid),
        .m_wready          (m_wready),
        .m_bresp           (m_bresp),   .m_bvalid         (m_bvalid),
        .m_bready          (m_bready),
        .m_araddr          (m_araddr),  .m_arlen          (m_arlen),
        .m_arsize          (m_arsize),  .m_arburst        (m_arburst),
        .m_arcache         (m_arcache), .m_arprot         (m_arprot),
        .m_arvalid         (m_arvalid), .m_arready        (m_arready),
        .m_rdata           (m_rdata),   .m_rresp          (m_rresp),
        .m_rlast           (m_rlast),   .m_rvalid         (m_rvalid),
        .m_rready          (m_rready),
        .rd0_req_valid     (rd0_req_valid),  .rd0_req_ready(rd0_req_ready),
        .rd0_req_addr      (rd0_req_addr),   .rd0_req_len  (rd0_req_len),
        .rd0_req_cache     (rd0_req_cache),  .rd0_req_prot (rd0_req_prot),
        .rd0_resp_valid    (rd0_resp_valid), .rd0_resp_data(rd0_resp_data),
        .rd0_resp_last     (rd0_resp_last),  .rd0_resp_err (rd0_resp_err),
        .rd1_req_valid     (rd1_req_valid),  .rd1_req_ready(rd1_req_ready),
        .rd1_req_addr      (rd1_req_addr),   .rd1_req_len  (rd1_req_len),
        .rd1_req_cache     (rd1_req_cache),  .rd1_req_prot (rd1_req_prot),
        .rd1_resp_valid    (rd1_resp_valid), .rd1_resp_data(rd1_resp_data),
        .rd1_resp_last     (rd1_resp_last),  .rd1_resp_err (rd1_resp_err),
        .wr0_req_valid     (wr0_req_valid),  .wr0_req_ready(wr0_req_ready),
        .wr0_req_addr      (wr0_req_addr),   .wr0_req_len  (wr0_req_len),
        .wr0_req_cache     (wr0_req_cache),  .wr0_req_prot (wr0_req_prot),
        .wr0_wdata         (wr0_wdata),      .wr0_wstrb    (wr0_wstrb),
        .wr0_wvalid        (wr0_wvalid),     .wr0_wready   (wr0_wready),
        .wr0_resp_valid    (wr0_resp_valid), .wr0_resp_err (wr0_resp_err),
        .wr1_req_valid     (wr1_req_valid),  .wr1_req_ready(wr1_req_ready),
        .wr1_req_addr      (wr1_req_addr),   .wr1_req_len  (wr1_req_len),
        .wr1_req_cache     (wr1_req_cache),  .wr1_req_prot (wr1_req_prot),
        .wr1_wdata         (wr1_wdata),      .wr1_wstrb    (wr1_wstrb),
        .wr1_wvalid        (wr1_wvalid),     .wr1_wlast    (wr1_wlast),
        .wr1_wready        (wr1_wready),
        .wr1_resp_valid    (wr1_resp_valid), .wr1_resp_err (wr1_resp_err),
        .max_rd_outstanding(max_rd_outstanding),
        .max_wr_outstanding(max_wr_outstanding),
        .bus_error_out     (bus_error_out)
    );

    // --- Descriptor fetch ---
    aes_decrypt_desc_fetch u_desc_fetch (
        .clk               (clk),        .rst_n           (rst_n),
        .fetch_start       (fetch_start),.fetch_done      (fetch_done),
        .fetch_invalid     (fetch_invalid),.fetch_bus_err (fetch_bus_err),
        .cmd_buf_addr      (cmd_buf_addr),.cmd_buf_size   (cmd_buf_size),
        .cmd_tail_ptr      (cmd_tail_ptr),.cmd_head_ptr   (fetch_head_ptr),
        .rd_req_valid      (rd0_req_valid),.rd_req_ready  (rd0_req_ready),
        .rd_req_addr       (rd0_req_addr), .rd_req_len    (rd0_req_len),
        .rd_req_cache      (rd0_req_cache),.rd_req_prot   (rd0_req_prot),
        .rd_resp_valid     (rd0_resp_valid),.rd_resp_data  (rd0_resp_data),
        .rd_resp_last      (rd0_resp_last), .rd_resp_err  (rd0_resp_err),
        .arcache_desc      (arcache_desc),  .arprot_desc  (arprot_desc),
        .desc_ctrl_byte    (desc_ctrl_byte),
        .desc_in_addr      (desc_in_addr),  .desc_out_addr(desc_out_addr),
        .desc_in_data_size (desc_in_data_size),.desc_in_pad_size(desc_in_pad_size),
        .desc_out_data_size(desc_out_data_size),.desc_out_pad_size(desc_out_pad_size)
    );

    // --- Input controller ---
    aes_decrypt_input_ctrl u_input_ctrl (
        .clk               (clk),        .rst_n            (rst_n),
        .job_start         (input_job_start),
        .in_addr           (desc_in_addr),
        .in_data_size      (desc_in_data_size),
        .in_pad_size       (desc_in_pad_size),
        .job_done          (input_job_done),
        .rd_req_valid      (rd1_req_valid), .rd_req_ready  (rd1_req_ready),
        .rd_req_addr       (rd1_req_addr),  .rd_req_len    (rd1_req_len),
        .rd_req_cache      (rd1_req_cache), .rd_req_prot   (rd1_req_prot),
        .rd_resp_valid     (rd1_resp_valid),.rd_resp_data  (rd1_resp_data),
        .rd_resp_last      (rd1_resp_last), .rd_resp_err   (rd1_resp_err),
        .arcache_in        (arcache_in),    .arprot_in     (arprot_in),
        .aes_nonce         (aes_nonce),     .aes_initial_ctr(aes_initial_ctr),
        .aes_hdr_valid     (aes_hdr_valid),
        .cipher_valid      (cipher_valid),  .cipher_data   (cipher_data),
        .cipher_bvalid     (cipher_bvalid), .cipher_stall  (cipher_stall),
        .crc_expected      (crc_expected),  .crc_valid     (crc_valid),
        .bus_err           (input_bus_err),
        // SRAM memory interface
        .cipher_mem_wen    (cipher_mem_wen),
        .cipher_mem_wa     (cipher_mem_wa),
        .cipher_mem_wd     (cipher_mem_wd),
        .cipher_mem_ra     (cipher_mem_ra),
        .cipher_mem_q      (cipher_mem_q)
    );

    // --- AES-128 CTR ---
    aes128_ctr_top u_aes_ctr (
        .clk               (clk),           .rst_n        (rst_n),
        .job_start         (aes_job_start),
        .nonce             (aes_nonce_reg),
        .initial_ctr       (aes_ctr_reg),
        .rk_in             (rk_out),
        .in_valid          (assem_out_valid),   // 128-bit block ready every 2 input beats
        .in_cipher         (assem_out_data),
        .in_stall          (aes_in_stall),
        .out_valid         (aes_out_valid),
        .out_plain         (aes_out_plain)
    );

    // --- CRC engine ---
    // crc_init is a one-cycle pulse from ctrl FSM that resets the accumulator
    // between jobs.  It is driven as a synchronous init rather than by gating
    // rst_n, which avoids a combinational path on the asynchronous reset net
    // and is cleaner for synthesis/STA.
    crc32_engine u_crc (
        .clk        (clk),
        .rst_n      (rst_n),
        .init       (crc_init),
        .alg_sel    (crc_alg_sel),
        .valid      (cipher_valid && !cipher_stall),
        .wr_data    (cipher_data),
        .byte_valid (cipher_bvalid),
        .crc_out    (crc_computed)
    );

    // --- Output controller ---
    aes_decrypt_output_ctrl u_output_ctrl (
        .clk               (clk),        .rst_n          (rst_n),
        .job_start         (output_job_start),
        .out_addr          (desc_out_addr),
        .out_data_size     (desc_out_data_size),
        .out_pad_size      (desc_out_pad_size),
        .job_done          (output_job_done),
        .plain_valid       (aes_out_valid),
        .plain_data        (aes_out_plain),
        .plain_stall       (plain_stall),
        .wr_req_valid      (wr1_req_valid),  .wr_req_ready (wr1_req_ready),
        .wr_req_addr       (wr1_req_addr),   .wr_req_len   (wr1_req_len),
        .wr_req_cache      (wr1_req_cache),  .wr_req_prot  (wr1_req_prot),
        .wr_wvalid         (wr1_wvalid),     .wr_wready    (wr1_wready),
        .wr_wlast          (wr1_wlast),
        .wr_wdata          (wr1_wdata),      .wr_wstrb     (wr1_wstrb),
        .wr_resp_valid     (wr1_resp_valid), .wr_resp_err  (wr1_resp_err),
        .awcache_out       (awcache_out),    .awprot_out   (awprot_out),
        .bus_err           (output_bus_err),
        // SRAM memory interface
        .out_mem_wen       (out_mem_wen),
        .out_mem_wa        (out_mem_wa),
        .out_mem_wd        (out_mem_wd),
        .out_mem_ra        (out_mem_ra),
        .out_mem_q         (out_mem_q)
    );

    // --- Descriptor write-back ---
    aes_decrypt_writeback u_writeback (
        .clk               (clk),          .rst_n          (rst_n),
        .wb_start          (wb_start),     .wb_done        (wb_done),
        .desc_base_addr    (wb_addr),
        .ctrl_byte_orig    (wb_ctrl_orig), .state_code     (wb_state_code),
        .wr_req_valid      (wr0_req_valid),.wr_req_ready   (wr0_req_ready),
        .wr_req_addr       (wr0_req_addr), .wr_req_len     (wr0_req_len),
        .wr_req_cache      (wr0_req_cache),.wr_req_prot    (wr0_req_prot),
        .wr_wvalid         (wr0_wvalid),   .wr_wready      (wr0_wready),
        .wr_wdata          (wr0_wdata),    .wr_wstrb       (wr0_wstrb),
        .wr_resp_valid     (wr0_resp_valid),.wr_resp_err   (wr0_resp_err),
        .arcache_desc      (arcache_desc), .arprot_desc    (arprot_desc),
        .bus_err           (wb_bus_err)
    );

    // --- Memory top (all compiled SRAMs — MBIST boundary) ---
    aes_decrypt_mem_top u_mem_top (
        .clk             (clk),
        // Cipher FIFO SRAM (32 × 64-bit)
        .cipher_mem_wen  (cipher_mem_wen),
        .cipher_mem_wa   (cipher_mem_wa),
        .cipher_mem_wd   (cipher_mem_wd),
        .cipher_mem_ra   (cipher_mem_ra),
        .cipher_mem_q    (cipher_mem_q),
        // Output FIFO SRAM (32 × 72-bit)
        .out_mem_wen     (out_mem_wen),
        .out_mem_wa      (out_mem_wa),
        .out_mem_wd      (out_mem_wd),
        .out_mem_ra      (out_mem_ra),
        .out_mem_q       (out_mem_q)
    );

    // --- Top-level control FSM ---
    aes_decrypt_ctrl u_ctrl (
        .clk               (clk),        .rst_n             (rst_n),
        .ctrl_start        (ctrl_start), .ctrl_resume       (ctrl_resume),
        .ctrl_immediate_stop(ctrl_immediate_stop),
        .status_state      (status_state),
        .hw_set_bus_error  (hw_set_bus_error),
        .hw_set_irq_done   (hw_set_irq_done),
        .hw_set_irq_buserr (hw_set_irq_buserr),
        .cmd_buf_addr      (cmd_buf_addr),
        .cmd_buf_size      (cmd_buf_size),
        .cmd_tail_ptr      (cmd_tail_ptr),
        .cmd_head_ptr_out  (cmd_head_ptr),
        .interval_cycles   (interval_cycles),
        .aes_key           (aes_key),
        .crc_alg_sel       (crc_alg_sel),
        .fetch_start       (fetch_start),    .fetch_done      (fetch_done),
        .fetch_invalid     (fetch_invalid),  .fetch_bus_err   (fetch_bus_err),
        .fetch_head_ptr    (fetch_head_ptr),
        .desc_ctrl_byte    (desc_ctrl_byte), .desc_in_addr    (desc_in_addr),
        .desc_out_addr     (desc_out_addr),
        .desc_in_data_size (desc_in_data_size),.desc_in_pad_size(desc_in_pad_size),
        .desc_out_data_size(desc_out_data_size),.desc_out_pad_size(desc_out_pad_size),
        .input_job_start   (input_job_start), .input_job_done (input_job_done),
        .input_bus_err     (input_bus_err),
        .aes_nonce         (aes_nonce),       .aes_initial_ctr(aes_initial_ctr),
        .aes_hdr_valid     (aes_hdr_valid),
        .crc_expected      (crc_expected),    .crc_valid      (crc_valid),
        .aes_job_start     (aes_job_start),
        .aes_nonce_reg     (aes_nonce_reg),   .aes_ctr_reg    (aes_ctr_reg),
        .aes_rk_in         (rk_out),
        .crc_init          (crc_init),        .crc_computed   (crc_computed),
        .output_job_start  (output_job_start),.output_job_done(output_job_done),
        .output_bus_err    (output_bus_err),
        .wb_start          (wb_start),        .wb_addr        (wb_addr),
        .wb_ctrl_orig      (wb_ctrl_orig),     .wb_state_code  (wb_state_code),
        .wb_done           (wb_done),          .wb_bus_err     (wb_bus_err)
    );

endmodule
