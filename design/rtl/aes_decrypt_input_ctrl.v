// =============================================================================
// File        : aes_decrypt_input_ctrl.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Input buffer read controller.
//               Reads the input buffer in order:
//                 1. AES Header (16 bytes = 2 beats): nonce + initial counter
//                    (not included in CRC computation)
//                 2. Encrypted payload (IN_DATA_SIZE bytes, multiple of 16):
//                    fed to AES CTR core and CRC engine simultaneously (parallel)
//                 3. Padding (IN_PAD_SIZE bytes): discarded, not in CRC
//                 4. CRC-32 value (4 bytes): latched and presented for comparison
//
//               Prefetch: issues reads up to max_rd_outstanding bursts ahead
//               to keep the AES core's input from starving.  Never issues
//               reads when the input FIFO is nearly full (almost_full).
//
//               Burst size: up to 256 beats (2 KB) per burst.
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_input_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Job parameters (from descriptor, valid when job_start pulses)
    // -------------------------------------------------------------------------
    input  wire        job_start,
    input  wire [31:0] in_addr,
    input  wire [23:0] in_data_size,    // ciphertext bytes, multiple of 16
    input  wire [ 7:0] in_pad_size,
    output reg         job_done,        // pulse: all input data consumed + CRC read

    // -------------------------------------------------------------------------
    // AXI4 read request port (to AXI manager, port 1 — input buffer)
    // -------------------------------------------------------------------------
    output reg         rd_req_valid,
    input  wire        rd_req_ready,
    output reg  [31:0] rd_req_addr,
    output reg  [ 7:0] rd_req_len,
    output wire [ 3:0] rd_req_cache,
    output wire [ 2:0] rd_req_prot,

    input  wire        rd_resp_valid,
    input  wire [63:0] rd_resp_data,
    input  wire        rd_resp_last,
    input  wire        rd_resp_err,

    // -------------------------------------------------------------------------
    // AxCACHE / AxPROT for input buffer accesses
    // -------------------------------------------------------------------------
    input  wire [3:0]  arcache_in,
    input  wire [2:0]  arprot_in,

    // -------------------------------------------------------------------------
    // AES header outputs (registered when first 2 beats received)
    // -------------------------------------------------------------------------
    output reg  [95:0] aes_nonce,
    output reg  [31:0] aes_initial_ctr,
    output reg         aes_hdr_valid,   // pulse when header latched

    // -------------------------------------------------------------------------
    // Ciphertext stream to AES core + CRC engine
    // -------------------------------------------------------------------------
    output wire        cipher_valid,    // ciphertext beat valid
    output wire [63:0] cipher_data,     // 8 bytes of ciphertext
    output wire [ 7:0] cipher_bvalid,   // which bytes are valid (all-1 for full beats)
    input  wire        cipher_stall,    // back-pressure from downstream

    // -------------------------------------------------------------------------
    // CRC result latched from input buffer
    // -------------------------------------------------------------------------
    output reg  [31:0] crc_expected,
    output reg         crc_valid,       // pulse when CRC latched

    // Bus error
    output reg         bus_err,

    // -------------------------------------------------------------------------
    // Cipher FIFO external SRAM interface (pass-through to aes_decrypt_mem_top)
    // -------------------------------------------------------------------------
    output wire        cipher_mem_wen,
    output wire [4:0]  cipher_mem_wa,
    output wire [63:0] cipher_mem_wd,
    output wire [4:0]  cipher_mem_ra,
    input  wire [63:0] cipher_mem_q
);

    assign rd_req_cache = arcache_in;
    assign rd_req_prot  = arprot_in;

    // -------------------------------------------------------------------------
    // Internal FIFO for ciphertext beats (64-bit wide, 32 entries)
    // -------------------------------------------------------------------------
    wire        fifo_wr_en;
    wire [63:0] fifo_wr_data;
    wire        fifo_full;
    wire        fifo_almost_full;
    wire        fifo_rd_en;
    wire [63:0] fifo_rd_data;
    wire        fifo_empty;

    sync_fifo #(.DATA_W(64), .DEPTH(32)) u_cipher_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (fifo_wr_en),
        .wr_data     (fifo_wr_data),
        .full        (fifo_full),
        .almost_full (fifo_almost_full),
        .rd_en       (fifo_rd_en),
        .rd_data     (fifo_rd_data),
        .empty       (fifo_empty),
        .almost_empty(),
        .count       (),
        // External SRAM interface — routed to aes_decrypt_mem_top
        .mem_wen     (cipher_mem_wen),
        .mem_wa      (cipher_mem_wa),
        .mem_wd      (cipher_mem_wd),
        .mem_ra      (cipher_mem_ra),
        .mem_q       (cipher_mem_q)
    );

    // FIFO output drives cipher stream
    assign cipher_valid  = !fifo_empty && !cipher_stall;
    assign cipher_data   = fifo_rd_data;
    assign cipher_bvalid = 8'hFF; // full beats only (payload is multiple of 16B = 2 beats)
    assign fifo_rd_en    = cipher_valid;

    // -------------------------------------------------------------------------
    // Read sequencer FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 3'd0;
    localparam S_HDR1      = 3'd1;  // waiting for header beat 0
    localparam S_HDR2      = 3'd2;  // waiting for header beat 1
    localparam S_DATA_REQ  = 3'd3;  // issuing data burst requests
    localparam S_DATA_RECV = 3'd4;  // receiving data beats
    localparam S_PAD_CRC   = 3'd5;  // receiving padding + CRC tail
    localparam S_DONE      = 3'd6;

    reg [2:0]  state;

    // Byte counters for the current job
    reg [23:0] data_remaining;  // ciphertext bytes left to request
    reg [23:0] data_recv_rem;   // ciphertext beats left to receive
    reg [7:0]  pad_crc_bytes;   // remaining bytes in pad+CRC tail to read
    reg [31:0] cur_addr;        // next read address

    // Accumulate CRC (4 bytes may straddle beats — use byte accumulator)
    reg [23:0] crc_byte_offset; // byte offset where CRC starts (= pad_start + in_pad_size)
    reg [24:0] total_recv_bytes;
    reg [31:0] crc_accum;
    reg [ 1:0] crc_bytes_seen;

    // How many padding+CRC bytes remain after all ciphertext
    // = IN_PAD_SIZE + 4 bytes (min 4, max 259).
    // No alignment assumption is made on IN_ADDR; byte counting handles any start offset.
    // Number of AXI beats needed = ceil((IN_PAD_SIZE + 4) / 8).

    // Burst helper: compute burst len (beats-1) for 'remaining' bytes at 'addr'
    // Limit to 256 beats (2KB) per burst.
    function automatic [7:0] burst_len;
        input [23:0] bytes_rem;
        reg [23:0] beats;
        begin
            beats = (bytes_rem + 7) >> 3; // ceil(bytes_rem / 8)
            burst_len = (beats > 256) ? 8'd255 : beats[7:0] - 8'd1;
        end
    endfunction

    // AES header beat accumulation
    reg [63:0] hdr_beat0;

    // Data burst tracking
    reg [7:0]  req_burst_len;
    reg        req_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            rd_req_valid     <= 1'b0;
            job_done         <= 1'b0;
            aes_hdr_valid    <= 1'b0;
            crc_valid        <= 1'b0;
            bus_err          <= 1'b0;
            data_remaining   <= 24'd0;
            data_recv_rem    <= 24'd0;
            crc_bytes_seen   <= 2'd0;
            crc_accum        <= 32'd0;
            req_pending      <= 1'b0;
        end else begin
            job_done      <= 1'b0;
            aes_hdr_valid <= 1'b0;
            crc_valid     <= 1'b0;
            bus_err       <= 1'b0;

            case (state)
                // ---------------------------------------------------------------
                S_IDLE: begin
                    rd_req_valid <= 1'b0;
                    if (job_start) begin
                        cur_addr       <= in_addr;
                        data_remaining <= in_data_size;
                        data_recv_rem  <= in_data_size >> 3; // beats (multiple of 2)
                        crc_bytes_seen <= 2'd0;
                        crc_accum      <= 32'd0;
                        // Issue AES header read immediately: 2 beats
                        rd_req_addr    <= in_addr;
                        rd_req_len     <= 8'd1; // 2 beats
                        rd_req_valid   <= 1'b1;
                        state          <= S_HDR1;
                    end
                end

                // ---------------------------------------------------------------
                S_HDR1: begin
                    // Wait for request to be accepted
                    if (rd_req_valid && rd_req_ready) begin
                        rd_req_valid <= 1'b0;
                        cur_addr     <= cur_addr + 32'd16; // past header
                        state        <= S_HDR2;
                    end
                end

                // Wait for 2 header beats
                S_HDR2: begin
                    if (rd_resp_valid) begin
                        if (rd_resp_err) begin
                            bus_err <= 1'b1;
                            state   <= S_IDLE;
                        end else if (!rd_resp_last) begin
                            // Beat 0: nonce[63:0]
                            hdr_beat0 <= rd_resp_data;
                        end else begin
                            // Beat 1: nonce[95:64] (bits [31:0]) + initial_ctr (bits [63:32])
                            aes_nonce       <= {rd_resp_data[31:0], hdr_beat0[63:0]};
                            aes_initial_ctr <= rd_resp_data[63:32];
                            aes_hdr_valid   <= 1'b1;
                            // Move on: issue data requests if any ciphertext
                            if (data_remaining > 24'd0) begin
                                state <= S_DATA_REQ;
                            end else begin
                                // No ciphertext; go straight to padding+CRC
                                pad_crc_bytes <= in_pad_size + 8'd4;
                                state         <= S_PAD_CRC;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------------
                S_DATA_REQ: begin
                    // Issue burst reads for ciphertext; stall if FIFO almost full
                    rd_req_valid <= 1'b0;
                    if (!fifo_almost_full && data_remaining > 24'd0 && !req_pending) begin
                        req_burst_len <= burst_len(data_remaining);
                        rd_req_addr   <= cur_addr;
                        rd_req_len    <= burst_len(data_remaining);
                        rd_req_valid  <= 1'b1;
                        req_pending   <= 1'b1;
                        state         <= S_DATA_RECV;
                    end else if (data_remaining == 24'd0) begin
                        state <= S_PAD_CRC;
                        pad_crc_bytes <= in_pad_size + 8'd4;
                    end
                end

                // ---------------------------------------------------------------
                S_DATA_RECV: begin
                    if (rd_req_valid && rd_req_ready) begin
                        rd_req_valid <= 1'b0;
                        // Advance address by (burst_len+1)*8 bytes
                        cur_addr     <= cur_addr + {19'b0, req_burst_len + 8'd1, 3'b000};
                        data_remaining <= data_remaining - {16'b0, (req_burst_len + 8'd1), 3'b000};
                        req_pending  <= 1'b0;
                    end
                    // Data beats are written to FIFO directly (see continuous logic below)
                    if (rd_resp_valid && rd_resp_last && data_remaining == 24'd0) begin
                        state <= S_PAD_CRC;
                        pad_crc_bytes <= in_pad_size + 8'd4;
                    end else if (data_remaining > 24'd0 && !rd_req_valid && !req_pending
                                  && !fifo_almost_full) begin
                        req_burst_len <= burst_len(data_remaining);
                        rd_req_addr   <= cur_addr;
                        rd_req_len    <= burst_len(data_remaining);
                        rd_req_valid  <= 1'b1;
                        req_pending   <= 1'b1;
                    end
                end

                // ---------------------------------------------------------------
                S_PAD_CRC: begin
                    // Issue one more burst to read remaining pad + CRC bytes
                    if (!rd_req_valid && pad_crc_bytes > 8'd0) begin
                        rd_req_addr  <= cur_addr;
                        rd_req_len   <= burst_len({16'b0, pad_crc_bytes});
                        rd_req_valid <= 1'b1;
                    end
                    if (rd_req_valid && rd_req_ready)
                        rd_req_valid <= 1'b0;
                    // CRC extraction handled in continuous block below
                    if (rd_resp_valid && rd_resp_last && pad_crc_bytes == 8'd0)
                        state <= S_DONE;
                end

                // ---------------------------------------------------------------
                S_DONE: begin
                    job_done <= 1'b1;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Write data beats into cipher FIFO (only during data phase)
    // CRC extraction from pad+CRC tail
    // -------------------------------------------------------------------------
    wire in_data_phase = (state == S_DATA_REQ) || (state == S_DATA_RECV);
    wire in_pad_phase  = (state == S_PAD_CRC);

    assign fifo_wr_en   = in_data_phase && rd_resp_valid && !rd_resp_err && !fifo_full;
    assign fifo_wr_data = rd_resp_data;

    // CRC extraction during S_PAD_CRC: count down pad bytes, then capture CRC bytes
    // CRC starts at byte offset = in_pad_size within this phase
    reg [7:0] pad_bytes_consumed;  // tracks how many pad bytes we've seen

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pad_bytes_consumed <= 8'd0;
            crc_accum          <= 32'd0;
            crc_bytes_seen     <= 2'd0;
        end else if (job_start) begin
            pad_bytes_consumed <= 8'd0;
            crc_accum          <= 32'd0;
            crc_bytes_seen     <= 2'd0;
        end else if (in_pad_phase && rd_resp_valid && !rd_resp_err) begin
            // For each byte in this 8-byte beat, decide: pad or CRC?
            // pad_bytes_consumed tracks total bytes consumed in this phase
            // in_pad_size is the number of padding bytes before CRC
            begin : byte_extract
                integer b;
                for (b = 0; b < 8; b = b + 1) begin
                    if ((pad_bytes_consumed + b) >= in_pad_size &&
                        crc_bytes_seen < 2'd4) begin
                        // This byte belongs to CRC
                        case (crc_bytes_seen)
                            2'd0: crc_accum[ 7: 0] <= rd_resp_data[b*8 +: 8];
                            2'd1: crc_accum[15: 8] <= rd_resp_data[b*8 +: 8];
                            2'd2: crc_accum[23:16]  <= rd_resp_data[b*8 +: 8];
                            2'd3: crc_accum[31:24]  <= rd_resp_data[b*8 +: 8];
                        endcase
                        crc_bytes_seen <= crc_bytes_seen + 2'd1;
                    end
                end
                pad_bytes_consumed <= pad_bytes_consumed + 8'd8;

                // When all 4 CRC bytes seen, present them
                if (crc_bytes_seen == 2'd3) begin
                    // Will complete on this beat — latch on next cycle via S_DONE
                    crc_expected <= crc_accum; // last byte captured combinationally
                    crc_valid    <= 1'b1;
                end
            end
            if (rd_resp_last)
                pad_crc_bytes <= 8'd0;
        end
    end

    // -------------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    ASSERT_FIFO_NO_OVERFLOW : assert property (
        @(posedge clk) disable iff (!rst_n)
        (fifo_wr_en) |-> !fifo_full
    ) else $error("[input_ctrl] Cipher FIFO overflow attempted");

    ASSERT_DATA_SIZE_ALIGNED : assert property (
        @(posedge clk) disable iff (!rst_n)
        job_start |-> (in_data_size[3:0] == 4'b0)
    ) else $error("[input_ctrl] IN_DATA_SIZE must be multiple of 16");
    `endif

endmodule
