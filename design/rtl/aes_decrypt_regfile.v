// =============================================================================
// File        : aes_decrypt_regfile.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AXI4-Lite Subordinate register file.
//               Implements all control/status registers defined in the spec.
//               - BRESP/RRESP are always OKAY (no error responses on this interface).
//               - Write-only registers (AES_KEY) read back 0x00000000.
//               - W1C bits handled atomically (set by HW, cleared by SW write-1).
//               - Writes to read-only fields are silently ignored.
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_regfile (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // AXI4-Lite Subordinate interface
    // -------------------------------------------------------------------------
    input  wire [7:0]  s_awaddr,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,

    input  wire [7:0]  s_araddr,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    // -------------------------------------------------------------------------
    // Register outputs to IP logic
    // -------------------------------------------------------------------------
    output wire        ctrl_start,          // pulse
    output wire        ctrl_resume,         // pulse
    output wire        ctrl_immediate_stop, // pulse

    input  wire [1:0]  status_state,        // from ctrl FSM
    input  wire        hw_set_bus_error,    // from AXI manager: set BUS_ERROR flag
    input  wire        hw_set_irq_done,     // from job ctrl: descriptor done interrupt
    input  wire        hw_set_irq_buserr,   // from AXI manager: set IRQ BUS_ERROR

    output wire [127:0] aes_key,
    output wire        crc_alg_sel,

    output wire [4:0]  max_rd_outstanding,
    output wire [4:0]  max_wr_outstanding,

    output wire [3:0]  arcache_desc,
    output wire [3:0]  arcache_in,
    output wire [3:0]  awcache_out,
    output wire [2:0]  arprot_desc,
    output wire [2:0]  arprot_in,
    output wire [2:0]  awprot_out,

    output wire [31:0] cmd_buf_addr,
    output wire [9:0]  cmd_buf_size,        // number of descriptor slots
    input  wire [9:0]  cmd_head_ptr,        // updated by desc fetch FSM
    output wire [9:0]  cmd_tail_ptr,

    output wire [15:0] interval_cycles,

    output wire        irq                  // interrupt output
);

    // -------------------------------------------------------------------------
    // Register storage
    // -------------------------------------------------------------------------
    reg        r_status_bus_error;   // STATUS[2], W1C
    reg        r_irq_done;           // IRQ_STATUS[0], W1C
    reg        r_irq_buserr;         // IRQ_STATUS[1], W1C
    reg        r_irq_done_en;
    reg        r_irq_buserr_en;

    reg [31:0] r_cmd_buf_addr;
    reg [9:0]  r_cmd_buf_size;
    reg [9:0]  r_cmd_tail_ptr;

    reg [127:0] r_aes_key;           // write-only

    reg        r_crc_alg_sel;
    reg [4:0]  r_max_rd_out;
    reg [4:0]  r_max_wr_out;
    reg [11:0] r_axi_cache_ctrl;     // [3:0]=DESC, [7:4]=IN, [11:8]=OUT
    reg [8:0]  r_axi_prot_ctrl;      // [2:0]=DESC, [5:3]=IN, [8:6]=OUT
    reg [15:0] r_interval;

    // Self-clearing control bits
    reg        r_ctrl_start;
    reg        r_ctrl_resume;
    reg        r_ctrl_imm_stop;

    // -------------------------------------------------------------------------
    // AXI4-Lite write logic (address + data latched together for simplicity)
    // -------------------------------------------------------------------------
    reg [7:0]  wr_addr_lat;
    reg        wr_addr_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_awready     <= 1'b1;
            s_wready      <= 1'b1;
            s_bvalid      <= 1'b0;
            s_bresp       <= 2'b00;
            wr_addr_lat   <= 8'h00;
            wr_addr_valid <= 1'b0;
        end else begin
            // Accept write address
            if (s_awvalid && s_awready) begin
                wr_addr_lat   <= s_awaddr;
                wr_addr_valid <= 1'b1;
                s_awready     <= 1'b0;
            end

            // Accept write data and perform register write
            if (s_wvalid && s_wready && wr_addr_valid) begin
                s_wready      <= 1'b0;
                wr_addr_valid <= 1'b0;
                s_bvalid      <= 1'b1;
                s_bresp       <= 2'b00; // Always OKAY

                case (wr_addr_lat)
                    `REG_CTRL: begin
                        // All bits self-clear; only pulse on write
                        r_ctrl_start    <= s_wdata[`CTRL_START]          & s_wstrb[0];
                        r_ctrl_resume   <= s_wdata[`CTRL_RESUME]         & s_wstrb[0];
                        r_ctrl_imm_stop <= s_wdata[`CTRL_IMMEDIATE_STOP] & s_wstrb[0];
                    end
                    `REG_STATUS: begin
                        // Byte 0: RO (STATE); Byte 1+: reserved
                        // Bit [2] = BUS_ERROR W1C
                        if (s_wdata[`STATUS_BUS_ERROR] && s_wstrb[0])
                            r_status_bus_error <= 1'b0;
                    end
                    `REG_IRQ_STATUS: begin
                        if (s_wdata[`IRQ_DESCRIPTOR_DONE] && s_wstrb[0])
                            r_irq_done   <= 1'b0;
                        if (s_wdata[`IRQ_BUS_ERROR] && s_wstrb[0])
                            r_irq_buserr <= 1'b0;
                    end
                    `REG_IRQ_ENABLE: begin
                        if (s_wstrb[0]) begin
                            r_irq_done_en   <= s_wdata[`IRQ_DESCRIPTOR_DONE];
                            r_irq_buserr_en <= s_wdata[`IRQ_BUS_ERROR];
                        end
                    end
                    `REG_CMD_BUF_ADDR: begin
                        // Writable only in STOP/PAUSE; ignore if ACTIVE (handled by caller,
                        // but also gate here for safety)
                        if (status_state != `STATE_ACTIVE) begin
                            if (s_wstrb[0]) r_cmd_buf_addr[7:0]   <= s_wdata[7:0];
                            if (s_wstrb[1]) r_cmd_buf_addr[15:8]  <= s_wdata[15:8];
                            if (s_wstrb[2]) r_cmd_buf_addr[23:16] <= s_wdata[23:16];
                            if (s_wstrb[3]) r_cmd_buf_addr[31:24] <= s_wdata[31:24];
                        end
                    end
                    `REG_CMD_BUF_SIZE: begin
                        if (status_state != `STATE_ACTIVE)
                            if (s_wstrb[0]) r_cmd_buf_size <= s_wdata[9:0];
                    end
                    `REG_CMD_TAIL_PTR: begin
                        if (s_wstrb[0]) r_cmd_tail_ptr[7:0] <= s_wdata[7:0];
                        if (s_wstrb[1]) r_cmd_tail_ptr[9:8] <= s_wdata[9:8];
                    end
                    `REG_AES_KEY_0: begin
                        if (s_wstrb[0]) r_aes_key[7:0]   <= s_wdata[7:0];
                        if (s_wstrb[1]) r_aes_key[15:8]  <= s_wdata[15:8];
                        if (s_wstrb[2]) r_aes_key[23:16] <= s_wdata[23:16];
                        if (s_wstrb[3]) r_aes_key[31:24] <= s_wdata[31:24];
                    end
                    `REG_AES_KEY_1: begin
                        if (s_wstrb[0]) r_aes_key[39:32] <= s_wdata[7:0];
                        if (s_wstrb[1]) r_aes_key[47:40] <= s_wdata[15:8];
                        if (s_wstrb[2]) r_aes_key[55:48] <= s_wdata[23:16];
                        if (s_wstrb[3]) r_aes_key[63:56] <= s_wdata[31:24];
                    end
                    `REG_AES_KEY_2: begin
                        if (s_wstrb[0]) r_aes_key[71:64] <= s_wdata[7:0];
                        if (s_wstrb[1]) r_aes_key[79:72] <= s_wdata[15:8];
                        if (s_wstrb[2]) r_aes_key[87:80] <= s_wdata[23:16];
                        if (s_wstrb[3]) r_aes_key[95:88] <= s_wdata[31:24];
                    end
                    `REG_AES_KEY_3: begin
                        if (s_wstrb[0]) r_aes_key[103:96]  <= s_wdata[7:0];
                        if (s_wstrb[1]) r_aes_key[111:104] <= s_wdata[15:8];
                        if (s_wstrb[2]) r_aes_key[119:112] <= s_wdata[23:16];
                        if (s_wstrb[3]) r_aes_key[127:120] <= s_wdata[31:24];
                    end
                    `REG_CRC_CTRL: begin
                        if (s_wstrb[0]) r_crc_alg_sel <= s_wdata[0];
                    end
                    `REG_AXI_OUTSTAND: begin
                        if (status_state != `STATE_ACTIVE) begin
                            if (s_wstrb[0]) r_max_rd_out <= s_wdata[4:0];
                            if (s_wstrb[1]) r_max_wr_out <= s_wdata[9:5];
                        end
                    end
                    `REG_AXI_CACHE_CTRL: begin
                        if (status_state != `STATE_ACTIVE) begin
                            if (s_wstrb[0]) r_axi_cache_ctrl[7:0]  <= s_wdata[7:0];
                            if (s_wstrb[1]) r_axi_cache_ctrl[11:8] <= s_wdata[11:8];
                        end
                    end
                    `REG_AXI_PROT_CTRL: begin
                        if (status_state != `STATE_ACTIVE) begin
                            if (s_wstrb[0]) r_axi_prot_ctrl[7:0] <= s_wdata[7:0];
                            if (s_wstrb[1]) r_axi_prot_ctrl[8]   <= s_wdata[8];
                        end
                    end
                    `REG_INTERVAL: begin
                        if (s_wstrb[0]) r_interval[7:0]  <= s_wdata[7:0];
                        if (s_wstrb[1]) r_interval[15:8] <= s_wdata[15:8];
                    end
                    default: ; // ignore writes to unknown addresses
                endcase
            end else if (!wr_addr_valid) begin
                // Re-open for next transaction once response is accepted
                if (s_bvalid && s_bready) begin
                    s_bvalid  <= 1'b0;
                    s_awready <= 1'b1;
                    s_wready  <= 1'b1;
                end
            end

            // Self-clear control bits the cycle after assertion
            r_ctrl_start    <= 1'b0;
            r_ctrl_resume   <= 1'b0;
            r_ctrl_imm_stop <= 1'b0;
        end
    end

    // Hardware set of status/IRQ bits (can coincide with SW clear; HW wins)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_status_bus_error <= 1'b0;
            r_irq_done         <= 1'b0;
            r_irq_buserr       <= 1'b0;
        end else begin
            if (hw_set_bus_error)  r_status_bus_error <= 1'b1;
            if (hw_set_irq_done)   r_irq_done         <= 1'b1;
            if (hw_set_irq_buserr) r_irq_buserr       <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite read logic
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_arready <= 1'b1;
            s_rvalid  <= 1'b0;
            s_rdata   <= 32'h0;
            s_rresp   <= 2'b00;
        end else begin
            if (s_arvalid && s_arready) begin
                s_arready <= 1'b0;
                s_rvalid  <= 1'b1;
                s_rresp   <= 2'b00; // Always OKAY

                case (s_araddr)
                    `REG_CTRL:
                        s_rdata <= 32'h0; // write-only in spirit; reads 0
                    `REG_STATUS:
                        s_rdata <= {29'b0, r_status_bus_error, status_state};
                    `REG_IRQ_STATUS:
                        s_rdata <= {30'b0, r_irq_buserr, r_irq_done};
                    `REG_IRQ_ENABLE:
                        s_rdata <= {30'b0, r_irq_buserr_en, r_irq_done_en};
                    `REG_CMD_BUF_ADDR:
                        s_rdata <= r_cmd_buf_addr;
                    `REG_CMD_BUF_SIZE:
                        s_rdata <= {22'b0, r_cmd_buf_size};
                    `REG_CMD_HEAD_PTR:
                        s_rdata <= {22'b0, cmd_head_ptr};
                    `REG_CMD_TAIL_PTR:
                        s_rdata <= {22'b0, r_cmd_tail_ptr};
                    `REG_AES_KEY_0: s_rdata <= 32'h0; // write-only
                    `REG_AES_KEY_1: s_rdata <= 32'h0;
                    `REG_AES_KEY_2: s_rdata <= 32'h0;
                    `REG_AES_KEY_3: s_rdata <= 32'h0;
                    `REG_CRC_CTRL:
                        s_rdata <= {31'b0, r_crc_alg_sel};
                    `REG_AXI_OUTSTAND:
                        s_rdata <= {22'b0, r_max_wr_out, r_max_rd_out};
                    `REG_AXI_CACHE_CTRL:
                        s_rdata <= {20'b0, r_axi_cache_ctrl};
                    `REG_AXI_PROT_CTRL:
                        s_rdata <= {23'b0, r_axi_prot_ctrl};
                    `REG_INTERVAL:
                        s_rdata <= {16'b0, r_interval};
                    default:
                        s_rdata <= 32'h0;
                endcase
            end else if (s_rvalid && s_rready) begin
                s_rvalid  <= 1'b0;
                s_arready <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Reset values
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_irq_done_en   <= 1'b0;
            r_irq_buserr_en <= 1'b0;
            r_cmd_buf_addr  <= 32'h0;
            r_cmd_buf_size  <= 10'd1;
            r_cmd_tail_ptr  <= 10'd0;
            r_aes_key       <= 128'h0;
            r_crc_alg_sel   <= 1'b0;
            r_max_rd_out    <= 5'd16;
            r_max_wr_out    <= 5'd16;
            r_axi_cache_ctrl<= 12'h0;
            r_axi_prot_ctrl <= 9'h0;
            r_interval      <= 16'd16;
            r_ctrl_start    <= 1'b0;
            r_ctrl_resume   <= 1'b0;
            r_ctrl_imm_stop <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Output assignments
    // -------------------------------------------------------------------------
    assign ctrl_start          = r_ctrl_start;
    assign ctrl_resume         = r_ctrl_resume;
    assign ctrl_immediate_stop = r_ctrl_imm_stop;

    assign aes_key             = r_aes_key;
    assign crc_alg_sel         = r_crc_alg_sel;

    // Clamp outstanding values: 0→1, >16→16
    assign max_rd_outstanding  = (r_max_rd_out == 5'd0)  ? 5'd1  :
                                 (r_max_rd_out > 5'd16)  ? 5'd16 : r_max_rd_out;
    assign max_wr_outstanding  = (r_max_wr_out == 5'd0)  ? 5'd1  :
                                 (r_max_wr_out > 5'd16)  ? 5'd16 : r_max_wr_out;

    assign arcache_desc        = r_axi_cache_ctrl[3:0];
    assign arcache_in          = r_axi_cache_ctrl[7:4];
    assign awcache_out         = r_axi_cache_ctrl[11:8];
    assign arprot_desc         = r_axi_prot_ctrl[2:0];
    assign arprot_in           = r_axi_prot_ctrl[5:3];
    assign awprot_out          = r_axi_prot_ctrl[8:6];

    assign cmd_buf_addr        = r_cmd_buf_addr;
    assign cmd_buf_size        = (r_cmd_buf_size == 10'd0) ? 10'd1 : r_cmd_buf_size;
    assign cmd_tail_ptr        = r_cmd_tail_ptr;
    assign interval_cycles     = (r_interval == 16'd0) ? 16'd1 : r_interval;

    // IRQ: level signal, active-high, de-asserts when all enabled pending bits cleared
    assign irq = (r_irq_done   && r_irq_done_en)
               | (r_irq_buserr && r_irq_buserr_en);

    // -------------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    ASSERT_BRESP_OKAY : assert property (
        @(posedge clk) disable iff (!rst_n)
        s_bvalid |-> (s_bresp == 2'b00)
    ) else $error("[regfile] BRESP must always be OKAY");

    ASSERT_RRESP_OKAY : assert property (
        @(posedge clk) disable iff (!rst_n)
        s_rvalid |-> (s_rresp == 2'b00)
    ) else $error("[regfile] RRESP must always be OKAY");
    `endif

endmodule
