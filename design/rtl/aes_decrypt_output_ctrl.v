// =============================================================================
// File        : aes_decrypt_output_ctrl.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Output buffer write controller.
//               Accepts 128-bit plaintext blocks from the AES CTR core,
//               splits them into 64-bit AXI beats, and writes them to the
//               output buffer.  Appends OUT_PAD_SIZE zero bytes after
//               the valid plaintext.
//               Reports write bus errors to the top-level controller.
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_output_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Job parameters
    // -------------------------------------------------------------------------
    input  wire        job_start,
    input  wire [31:0] out_addr,
    input  wire [23:0] out_data_size,   // valid plaintext bytes to write
    input  wire [ 7:0] out_pad_size,    // zero-padding bytes after plaintext
    output reg         job_done,        // pulse: all writes issued and accepted

    // -------------------------------------------------------------------------
    // Plaintext input from AES core (128-bit blocks)
    // -------------------------------------------------------------------------
    input  wire        plain_valid,
    input  wire [127:0] plain_data,
    output wire        plain_stall,     // request AES core to stall

    // -------------------------------------------------------------------------
    // AXI4 write request port (to AXI manager, port 1 — output buffer)
    // -------------------------------------------------------------------------
    output reg         wr_req_valid,
    input  wire        wr_req_ready,
    output reg  [31:0] wr_req_addr,
    output reg  [ 7:0] wr_req_len,
    output wire [ 3:0] wr_req_cache,
    output wire [ 2:0] wr_req_prot,

    output wire        wr_wvalid,
    input  wire        wr_wready,
    output wire [63:0] wr_wdata,
    output wire [ 7:0] wr_wstrb,
    output wire        wr_wlast,        // last beat of current write burst

    input  wire        wr_resp_valid,
    input  wire        wr_resp_err,

    // -------------------------------------------------------------------------
    // AxCACHE / AxPROT for output buffer writes
    // -------------------------------------------------------------------------
    input  wire [3:0]  awcache_out,
    input  wire [2:0]  awprot_out,

    // Bus error output
    output reg         bus_err,

    // -------------------------------------------------------------------------
    // Output FIFO external SRAM interface (pass-through to aes_decrypt_mem_top)
    // -------------------------------------------------------------------------
    output wire        out_mem_wen,
    output wire [4:0]  out_mem_wa,
    output wire [71:0] out_mem_wd,
    output wire [4:0]  out_mem_ra,
    input  wire [71:0] out_mem_q
);

    assign wr_req_cache = awcache_out;
    assign wr_req_prot  = awprot_out;

    // -------------------------------------------------------------------------
    // Internal output FIFO: holds 64-bit beats + strobe ready for AXI
    // -------------------------------------------------------------------------
    // Pack {strobe[7:0], data[63:0]} = 72 bits per entry
    wire        out_fifo_wr_en;
    wire [71:0] out_fifo_wr_data;
    wire        out_fifo_full;
    wire        out_fifo_almost_full;
    wire        out_fifo_rd_en;
    wire [71:0] out_fifo_rd_data;
    wire        out_fifo_empty;

    sync_fifo #(.DATA_W(72), .DEPTH(32)) u_out_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (out_fifo_wr_en),
        .wr_data     (out_fifo_wr_data),
        .full        (out_fifo_full),
        .almost_full (out_fifo_almost_full),
        .rd_en       (out_fifo_rd_en),
        .rd_data     (out_fifo_rd_data),
        .empty       (out_fifo_empty),
        .almost_empty(),
        .count       (),
        // External SRAM interface — routed to aes_decrypt_mem_top
        .mem_wen     (out_mem_wen),
        .mem_wa      (out_mem_wa),
        .mem_wd      (out_mem_wd),
        .mem_ra      (out_mem_ra),
        .mem_q       (out_mem_q)
    );

    // Back-pressure to AES core: stall when output FIFO is almost full
    assign plain_stall = out_fifo_almost_full;

    // -------------------------------------------------------------------------
    // Plaintext → FIFO packer
    // Split 128-bit block into two 64-bit beats; apply byte-valid mask for
    // last partial block.
    // -------------------------------------------------------------------------
    reg [23:0] bytes_pushed;    // total valid plaintext bytes pushed to FIFO
    reg        push_high;       // 0=low half pending, 1=high half pending

    // Compute strobe for each 8-byte push
    function automatic [7:0] strobe_for_bytes;
        input [23:0] offset;    // byte offset of this push within plaintext
        input [23:0] total;     // total valid plaintext bytes
        integer k;
        begin
            strobe_for_bytes = 8'b0;
            for (k = 0; k < 8; k = k + 1) begin
                if ((offset + k) < total)
                    strobe_for_bytes[k] = 1'b1;
            end
        end
    endfunction

    // We push one 64-bit beat per cycle from each incoming 128-bit block.
    // First beat = plain_data[63:0], second = plain_data[127:64].
    reg [127:0] plain_hold;
    reg         plain_hold_valid;   // second beat waiting

    assign out_fifo_wr_en = (plain_valid && !push_high && !out_fifo_full)
                          || (plain_hold_valid && push_high && !out_fifo_full);

    assign out_fifo_wr_data = push_high
        ? {strobe_for_bytes(bytes_pushed + 24'd8, out_data_size), plain_hold[127:64]}
        : {strobe_for_bytes(bytes_pushed,          out_data_size), plain_data[63:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bytes_pushed     <= 24'd0;
            push_high        <= 1'b0;
            plain_hold       <= 128'b0;
            plain_hold_valid <= 1'b0;
        end else if (job_start) begin
            bytes_pushed     <= 24'd0;
            push_high        <= 1'b0;
            plain_hold_valid <= 1'b0;
        end else begin
            if (plain_valid && !push_high && !out_fifo_full) begin
                plain_hold       <= plain_data;
                plain_hold_valid <= 1'b1;
                push_high        <= 1'b1;
                bytes_pushed     <= bytes_pushed + 24'd8;
            end
            if (plain_hold_valid && push_high && !out_fifo_full) begin
                plain_hold_valid <= 1'b0;
                push_high        <= 1'b0;
                bytes_pushed     <= bytes_pushed + 24'd8;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI write sequencer: drains the FIFO into AXI write bursts
    // -------------------------------------------------------------------------
    localparam WS_IDLE    = 3'd0;
    localparam WS_AW_REQ  = 3'd1;  // issue write address
    localparam WS_DATA    = 3'd2;  // send data beats
    localparam WS_PAD     = 3'd3;  // send zero-padding beats
    localparam WS_WAIT_B  = 3'd4;  // wait for all write responses
    localparam WS_DONE    = 3'd5;

    reg [2:0]  ws;
    reg [31:0] cur_wr_addr;
    reg [23:0] data_bytes_rem;    // plaintext bytes left to write
    reg [7:0]  pad_bytes_rem;     // pad bytes left to write
    reg [7:0]  burst_beats_rem;   // beats remaining in current burst
    reg [7:0]  beats_in_burst;    // beats in the current burst
    reg [3:0]  wr_resp_pending;   // number of write responses still expected

    // How many beats remain to write (data + pad together)
    wire [23:0] total_bytes_rem   = data_bytes_rem + {16'b0, pad_bytes_rem};
    wire [23:0] total_beats_rem   = (total_bytes_rem + 24'd7) >> 3;

    function automatic [7:0] wr_burst_len;
        input [23:0] beats;
        wr_burst_len = (beats > 256) ? 8'd255 : beats[7:0] - 8'd1;
    endfunction

    // FIFO read enable: only during WS_DATA when AXI W channel is ready
    assign out_fifo_rd_en = (ws == WS_DATA) && wr_wvalid && wr_wready && !out_fifo_empty;

    // W channel outputs
    assign wr_wvalid = ((ws == WS_DATA) && !out_fifo_empty)
                     || (ws == WS_PAD);
    assign wr_wdata  = (ws == WS_PAD) ? 64'h0 : out_fifo_rd_data[63:0];
    assign wr_wstrb  = (ws == WS_PAD) ? pad_strobe(pad_bytes_rem)
                                      : out_fifo_rd_data[71:64];
    // wlast: asserted on the final beat of each AXI write burst
    assign wr_wlast  = wr_wvalid && (burst_beats_rem == 8'd1);

    function automatic [7:0] pad_strobe;
        input [7:0] remaining;
        integer k;
        begin
            pad_strobe = 8'b0;
            for (k = 0; k < 8; k = k + 1)
                if (k < remaining) pad_strobe[k] = 1'b1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ws               <= WS_IDLE;
            wr_req_valid     <= 1'b0;
            job_done         <= 1'b0;
            bus_err          <= 1'b0;
            wr_resp_pending  <= 4'd0;
        end else begin
            job_done <= 1'b0;
            bus_err  <= 1'b0;

            case (ws)
                WS_IDLE: begin
                    if (job_start) begin
                        cur_wr_addr    <= out_addr;
                        data_bytes_rem <= out_data_size;
                        pad_bytes_rem  <= out_pad_size;
                        ws             <= WS_AW_REQ;
                    end
                end

                WS_AW_REQ: begin
                    if (total_bytes_rem == 24'd0) begin
                        ws <= WS_WAIT_B;
                    end else if (!wr_req_valid) begin
                        beats_in_burst <= wr_burst_len(total_beats_rem) + 8'd1;
                        wr_req_addr    <= cur_wr_addr;
                        wr_req_len     <= wr_burst_len(total_beats_rem);
                        wr_req_valid   <= 1'b1;
                    end
                    if (wr_req_valid && wr_req_ready) begin
                        wr_req_valid     <= 1'b0;
                        burst_beats_rem  <= beats_in_burst;
                        wr_resp_pending  <= wr_resp_pending + 4'd1;
                        ws               <= (data_bytes_rem > 24'd0) ? WS_DATA : WS_PAD;
                    end
                end

                WS_DATA: begin
                    if (wr_wvalid && wr_wready) begin
                        burst_beats_rem <= burst_beats_rem - 8'd1;
                        if (data_bytes_rem >= 24'd8)
                            data_bytes_rem <= data_bytes_rem - 24'd8;
                        else
                            data_bytes_rem <= 24'd0;

                        if (burst_beats_rem == 8'd1) begin
                            // Burst complete — advance address
                            cur_wr_addr <= cur_wr_addr + {beats_in_burst, 3'b000};
                            ws <= (total_bytes_rem > 24'd0) ? WS_AW_REQ : WS_WAIT_B;
                        end else if (data_bytes_rem == 24'd0) begin
                            ws <= WS_PAD;
                        end
                    end
                end

                WS_PAD: begin
                    if (wr_wvalid && wr_wready) begin
                        burst_beats_rem <= burst_beats_rem - 8'd1;
                        pad_bytes_rem   <= (pad_bytes_rem >= 8'd8) ?
                                           pad_bytes_rem - 8'd8 : 8'd0;
                        if (burst_beats_rem == 8'd1) begin
                            cur_wr_addr <= cur_wr_addr + {beats_in_burst, 3'b000};
                            ws <= (total_bytes_rem > 24'd0) ? WS_AW_REQ : WS_WAIT_B;
                        end
                    end
                end

                WS_WAIT_B: begin
                    if (wr_resp_valid) begin
                        if (wr_resp_err) begin
                            bus_err <= 1'b1;
                            ws      <= WS_IDLE;
                        end else begin
                            wr_resp_pending <= wr_resp_pending - 4'd1;
                            if (wr_resp_pending == 4'd1)
                                ws <= WS_DONE;
                        end
                    end
                end

                WS_DONE: begin
                    job_done <= 1'b1;
                    ws       <= WS_IDLE;
                end

                default: ws <= WS_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    ASSERT_OUT_FIFO_NO_OVERFLOW : assert property (
        @(posedge clk) disable iff (!rst_n)
        out_fifo_wr_en |-> !out_fifo_full
    ) else $error("[output_ctrl] Output FIFO overflow");
    `endif

endmodule
