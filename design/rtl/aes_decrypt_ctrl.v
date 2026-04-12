// =============================================================================
// File        : aes_decrypt_ctrl.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Top-level control FSM for the AES Decryption Engine.
//               Implements the STOP / ACTIVE / PAUSE state machine and
//               orchestrates the descriptor fetch, job pipeline, and
//               write-back sub-modules.
//
//               Job pipeline per descriptor:
//                 1. Write in-progress state to descriptor (writeback early)
//                 2. Start input_ctrl  (reads AES header, ciphertext, CRC)
//                 3. Start AES CTR core (after AES header arrives)
//                 4. Start output_ctrl (writes plaintext as it comes)
//                 5. Compare CRC when input_ctrl signals CRC available
//                 6. Wait for output_ctrl to finish
//                 7. Write final state to descriptor (writeback final)
//                 8. Advance head pointer; check interrupt/last flags
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes_decrypt_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Register interface
    // -------------------------------------------------------------------------
    input  wire        ctrl_start,
    input  wire        ctrl_resume,
    input  wire        ctrl_immediate_stop,

    output reg  [1:0]  status_state,        // to regfile STATUS.STATE
    output reg         hw_set_bus_error,    // → regfile STATUS.BUS_ERROR
    output reg         hw_set_irq_done,     // → regfile IRQ_STATUS.DESCRIPTOR_DONE
    output reg         hw_set_irq_buserr,   // → regfile IRQ_STATUS.BUS_ERROR

    input  wire [31:0] cmd_buf_addr,
    input  wire [9:0]  cmd_buf_size,
    input  wire [9:0]  cmd_tail_ptr,
    output wire [9:0]  cmd_head_ptr_out,
    input  wire [15:0] interval_cycles,
    input  wire [127:0] aes_key,
    input  wire        crc_alg_sel,

    // -------------------------------------------------------------------------
    // Descriptor fetch sub-module
    // -------------------------------------------------------------------------
    output reg         fetch_start,
    input  wire        fetch_done,
    input  wire        fetch_invalid,
    input  wire        fetch_bus_err,
    input  wire [9:0]  fetch_head_ptr,      // from desc_fetch
    input  wire [7:0]  desc_ctrl_byte,
    input  wire [31:0] desc_in_addr,
    input  wire [31:0] desc_out_addr,
    input  wire [23:0] desc_in_data_size,
    input  wire [ 7:0] desc_in_pad_size,
    input  wire [23:0] desc_out_data_size,
    input  wire [ 7:0] desc_out_pad_size,

    // -------------------------------------------------------------------------
    // Input controller sub-module
    // -------------------------------------------------------------------------
    output reg         input_job_start,
    input  wire        input_job_done,
    input  wire        input_bus_err,
    input  wire [95:0] aes_nonce,
    input  wire [31:0] aes_initial_ctr,
    input  wire        aes_hdr_valid,
    input  wire [31:0] crc_expected,
    input  wire        crc_valid,

    // -------------------------------------------------------------------------
    // AES CTR core sub-module
    // -------------------------------------------------------------------------
    output reg         aes_job_start,
    output reg  [95:0] aes_nonce_reg,
    output reg  [31:0] aes_ctr_reg,
    input  wire [1407:0] aes_rk_in,        // from key schedule (external)

    // -------------------------------------------------------------------------
    // CRC engine sub-module
    // -------------------------------------------------------------------------
    output reg         crc_init,           // reset CRC state
    input  wire [31:0] crc_computed,       // running CRC from engine

    // -------------------------------------------------------------------------
    // Output controller sub-module
    // -------------------------------------------------------------------------
    output reg         output_job_start,
    input  wire        output_job_done,
    input  wire        output_bus_err,

    // -------------------------------------------------------------------------
    // Write-back sub-module
    // -------------------------------------------------------------------------
    output reg         wb_start,
    output reg  [31:0] wb_addr,
    output reg  [ 7:0] wb_ctrl_orig,
    output reg  [ 7:0] wb_state_code,
    input  wire        wb_done,
    input  wire        wb_bus_err
);

    // -------------------------------------------------------------------------
    // Head pointer tracking (delegate management to desc_fetch, mirror here)
    // -------------------------------------------------------------------------
    assign cmd_head_ptr_out = fetch_head_ptr;

    // -------------------------------------------------------------------------
    // Main FSM states
    // -------------------------------------------------------------------------
    localparam TOP_STOP        = 4'd0;
    localparam TOP_FETCH       = 4'd1;   // issue fetch, wait for result
    localparam TOP_INTERVAL    = 4'd2;   // valid=0, waiting interval
    localparam TOP_WB_INPROG   = 4'd3;   // write in-progress state to descriptor
    localparam TOP_JOB_RUN     = 4'd4;   // running input/AES/output pipeline
    localparam TOP_CRC_CHECK   = 4'd5;   // compare CRC
    localparam TOP_WAIT_OUT    = 4'd6;   // waiting for output_ctrl to finish
    localparam TOP_WB_FINAL    = 4'd7;   // write final descriptor state
    localparam TOP_CHECK_FLAGS = 4'd8;   // evaluate interrupt/last flags
    localparam TOP_PAUSE       = 4'd9;   // paused waiting for resume
    localparam TOP_BUS_ERR     = 4'd10;  // bus error recovery (drain + stop)
    localparam TOP_IMM_STOP    = 4'd11;  // immediate stop (drain + stop)

    reg [3:0] state;

    // Interval counter
    reg [15:0] interval_cnt;

    // Job result tracking
    reg        job_crc_err;
    reg        job_rd_err;
    reg        job_wr_err;

    // Current descriptor's address (for write-back)
    reg [31:0] cur_desc_addr;

    // Saved descriptor fields for use across pipeline stages
    reg [7:0]  saved_ctrl_byte;
    reg [23:0] saved_in_data_size;

    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= TOP_STOP;
            status_state    <= `STATE_STOP;
            hw_set_bus_error<= 1'b0;
            hw_set_irq_done <= 1'b0;
            hw_set_irq_buserr<= 1'b0;
            fetch_start     <= 1'b0;
            input_job_start <= 1'b0;
            aes_job_start   <= 1'b0;
            output_job_start<= 1'b0;
            wb_start        <= 1'b0;
            crc_init        <= 1'b0;
            job_crc_err     <= 1'b0;
            job_rd_err      <= 1'b0;
            job_wr_err      <= 1'b0;
            interval_cnt    <= 16'd0;
        end else begin
            // Default pulse signals
            fetch_start      <= 1'b0;
            input_job_start  <= 1'b0;
            aes_job_start    <= 1'b0;
            output_job_start <= 1'b0;
            wb_start         <= 1'b0;
            crc_init         <= 1'b0;
            hw_set_bus_error <= 1'b0;
            hw_set_irq_done  <= 1'b0;
            hw_set_irq_buserr<= 1'b0;

            // Immediate stop takes priority from any non-STOP state
            if (ctrl_immediate_stop && state != TOP_STOP && state != TOP_IMM_STOP) begin
                state        <= TOP_IMM_STOP;
                status_state <= `STATE_STOP;
            end else begin

            case (state)
                // -----------------------------------------------------------
                TOP_STOP: begin
                    if (ctrl_start || ctrl_resume) begin
                        state        <= TOP_FETCH;
                        status_state <= `STATE_ACTIVE;
                    end
                end

                // -----------------------------------------------------------
                TOP_FETCH: begin
                    // Check ring buffer not empty before fetching
                    if (fetch_head_ptr != cmd_tail_ptr) begin
                        // Compute descriptor address for write-back later
                        cur_desc_addr <= cmd_buf_addr +
                                         {fetch_head_ptr, 5'b00000};
                        fetch_start   <= 1'b1;
                        state         <= TOP_FETCH; // wait for result
                    end
                    // wait for fetch_done or fetch_invalid or bus_err
                    if (fetch_done) begin
                        saved_ctrl_byte    <= desc_ctrl_byte;
                        state              <= TOP_WB_INPROG;
                    end else if (fetch_invalid) begin
                        interval_cnt <= interval_cycles;
                        state        <= TOP_INTERVAL;
                    end else if (fetch_bus_err) begin
                        state <= TOP_BUS_ERR;
                    end
                end

                // -----------------------------------------------------------
                TOP_INTERVAL: begin
                    // Wait before retrying a valid=0 descriptor
                    if (interval_cnt == 16'd0) begin
                        state <= TOP_FETCH;
                    end else begin
                        interval_cnt <= interval_cnt - 16'd1;
                    end
                end

                // -----------------------------------------------------------
                TOP_WB_INPROG: begin
                    // Issue write-back of in-progress marker before starting job
                    wb_addr      <= cur_desc_addr;
                    wb_ctrl_orig <= saved_ctrl_byte;
                    wb_state_code<= `DSTATE_IN_PROGRESS;
                    wb_start     <= 1'b1;
                    state        <= TOP_WB_INPROG;
                    if (wb_done) begin
                        // Start the job pipeline
                        job_crc_err     <= 1'b0;
                        job_rd_err      <= 1'b0;
                        job_wr_err      <= 1'b0;
                        crc_init        <= 1'b1;  // reset CRC engine
                        input_job_start <= 1'b1;
                        output_job_start<= 1'b1;
                        state           <= TOP_JOB_RUN;
                    end else if (wb_bus_err) begin
                        state <= TOP_BUS_ERR;
                    end
                end

                // -----------------------------------------------------------
                TOP_JOB_RUN: begin
                    // Start AES when header is available
                    if (aes_hdr_valid) begin
                        aes_nonce_reg   <= aes_nonce;
                        aes_ctr_reg     <= aes_initial_ctr;
                        aes_job_start   <= 1'b1;
                    end

                    // Collect errors
                    if (input_bus_err)  job_rd_err <= 1'b1;
                    if (output_bus_err) job_wr_err <= 1'b1;

                    // CRC available — latch and compare
                    if (crc_valid) begin
                        state <= TOP_CRC_CHECK;
                    end

                    // Any bus error → abort
                    if (input_bus_err || output_bus_err) begin
                        state <= TOP_BUS_ERR;
                    end
                end

                // -----------------------------------------------------------
                TOP_CRC_CHECK: begin
                    if (crc_computed != crc_expected)
                        job_crc_err <= 1'b1;
                    state <= TOP_WAIT_OUT;
                end

                // -----------------------------------------------------------
                TOP_WAIT_OUT: begin
                    if (output_bus_err) begin
                        job_wr_err <= 1'b1;
                        state      <= TOP_BUS_ERR;
                    end else if (output_job_done) begin
                        state <= TOP_WB_FINAL;
                    end
                end

                // -----------------------------------------------------------
                TOP_WB_FINAL: begin
                    // Determine result state code
                    wb_addr       <= cur_desc_addr;
                    wb_ctrl_orig  <= saved_ctrl_byte;
                    wb_state_code <= job_wr_err  ? `DSTATE_WR_ERR  :
                                     job_rd_err  ? `DSTATE_RD_ERR  :
                                     job_crc_err ? `DSTATE_CRC_ERR : `DSTATE_OK;
                    wb_start      <= 1'b1;
                    state         <= TOP_WB_FINAL;
                    if (wb_done) begin
                        state <= TOP_CHECK_FLAGS;
                    end else if (wb_bus_err) begin
                        state <= TOP_BUS_ERR;
                    end
                end

                // -----------------------------------------------------------
                TOP_CHECK_FLAGS: begin
                    // Evaluate interrupt and last flags from saved descriptor
                    if (saved_ctrl_byte[`HDR_INTERRUPT]) begin
                        hw_set_irq_done <= 1'b1;
                        status_state    <= `STATE_PAUSE;
                        state           <= TOP_PAUSE;
                    end else if (saved_ctrl_byte[`HDR_LAST]) begin
                        status_state <= `STATE_STOP;
                        state        <= TOP_STOP;
                    end else begin
                        state <= TOP_FETCH;  // continue to next descriptor
                    end

                    // Note: last flag check occurs after interrupt (spec order)
                    if (saved_ctrl_byte[`HDR_LAST] && !saved_ctrl_byte[`HDR_INTERRUPT]) begin
                        status_state <= `STATE_STOP;
                        state        <= TOP_STOP;
                    end
                end

                // -----------------------------------------------------------
                TOP_PAUSE: begin
                    if (ctrl_resume) begin
                        status_state <= `STATE_ACTIVE;
                        // If last was also set, stop after pause rather than continue
                        if (saved_ctrl_byte[`HDR_LAST]) begin
                            status_state <= `STATE_STOP;
                            state        <= TOP_STOP;
                        end else begin
                            state <= TOP_FETCH;
                        end
                    end
                end

                // -----------------------------------------------------------
                TOP_BUS_ERR: begin
                    // Signal error; all AXI transactions drain naturally via
                    // the sub-modules.  Transition to STOP after one cycle.
                    hw_set_bus_error  <= 1'b1;
                    hw_set_irq_buserr <= 1'b1;
                    status_state      <= `STATE_STOP;
                    state             <= TOP_STOP;
                end

                // -----------------------------------------------------------
                TOP_IMM_STOP: begin
                    // STOP already asserted before entering; just land here.
                    state <= TOP_STOP;
                end

                default: state <= TOP_STOP;
            endcase
            end // !ctrl_immediate_stop
        end
    end

    // -------------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    ASSERT_SINGLE_JOB : assert property (
        @(posedge clk) disable iff (!rst_n)
        (state == TOP_JOB_RUN) |-> !(input_job_start || output_job_start)
    ) else $error("[ctrl] job start signals must not re-fire during TOP_JOB_RUN");

    ASSERT_STATE_ENCODING : assert property (
        @(posedge clk) disable iff (!rst_n)
        status_state inside {`STATE_STOP, `STATE_ACTIVE, `STATE_PAUSE}
    ) else $error("[ctrl] invalid STATUS.STATE encoding");
    `endif

    `ifdef ENABLE_COVERAGE
    covergroup cg_ctrl_state @(posedge clk);
        cp_state     : coverpoint state;
        cp_crc_err   : coverpoint job_crc_err iff (state == TOP_WB_FINAL);
        cp_last_intr : coverpoint {saved_ctrl_byte[`HDR_LAST],
                                   saved_ctrl_byte[`HDR_INTERRUPT]}
                        iff (state == TOP_CHECK_FLAGS);
    endgroup
    cg_ctrl_state cg_ctrl_inst = new();
    `endif

endmodule
