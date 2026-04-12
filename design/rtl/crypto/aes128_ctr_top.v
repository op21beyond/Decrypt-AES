// =============================================================================
// File        : aes128_ctr_top.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES-128 CTR mode top — keystream generator + XOR.
//               Accepts a stream of 128-bit ciphertext blocks and produces
//               128-bit plaintext blocks.
//
//               Counter block format (NIST SP 800-38A):
//                 counter_blk = {nonce[95:0], ctr[31:0]}
//               Counter increments by 1 per block (mod 2^32).
//
//               Pipeline latency = 10 clock cycles (from in_valid to out_valid).
//               Backpressure: in_stall input halts counter advancement and
//               pipeline feeding to avoid key-stream / ciphertext misalignment.
//               When in_stall=1, no new counter block is submitted to the pipe.
//
//               Key schedule is computed externally (aes128_key_sched) and
//               registered in the parent module; rk_in must be stable while
//               operating on a single job.  A new job resets the counter.
// =============================================================================

`include "inc/aes_decrypt_defs.vh"

module aes128_ctr_top (
    input  wire         clk,
    input  wire         rst_n,

    // Job control
    input  wire         job_start,      // pulse: load nonce/initial_ctr for new job
    input  wire [95:0]  nonce,          // IV[95:0] from AES header
    input  wire [31:0]  initial_ctr,    // initial counter from AES header
    input  wire [1407:0] rk_in,         // 11 round keys (stable per job)

    // Ciphertext input stream (128-bit blocks, one per clock when valid+!stall)
    input  wire         in_valid,       // ciphertext block present
    input  wire [127:0] in_cipher,      // ciphertext block
    output wire         in_stall,       // back-pressure from AES pipeline

    // Plaintext output stream
    output wire         out_valid,
    output wire [127:0] out_plain
);

    // -----------------------------------------------------------------------
    // Counter register
    // -----------------------------------------------------------------------
    reg [31:0] ctr_reg;

    // in_stall: assert when AES output FIFO is full (connected externally)
    // For now this module outputs stall = 0; the parent manages flow.
    // The parent must only assert in_valid when it has ciphertext ready AND
    // the downstream output path can accept data within 10 cycles.
    assign in_stall = 1'b0;  // parent manages flow; override if needed

    // Current counter block submitted to AES pipeline
    wire [127:0] counter_blk = {nonce, ctr_reg};

    // Advance counter each time we submit a block
    wire submit = in_valid && !in_stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctr_reg <= 32'b0;
        end else if (job_start) begin
            ctr_reg <= initial_ctr;
        end else if (submit) begin
            ctr_reg <= ctr_reg + 32'd1;
        end
    end

    // -----------------------------------------------------------------------
    // AES encrypt pipeline: encrypts counter blocks to produce keystream
    // -----------------------------------------------------------------------
    wire        ks_valid;
    wire [127:0] ks_data;

    aes128_enc_pipe u_aes_pipe (
        .clk       (clk),
        .rst_n     (rst_n),
        .rk_in     (rk_in),
        .in_valid  (submit),
        .in_data   (counter_blk),
        .out_valid (ks_valid),
        .out_data  (ks_data)
    );

    // -----------------------------------------------------------------------
    // Delay ciphertext to align with keystream output (10-cycle pipeline)
    // -----------------------------------------------------------------------
    // Shift register to delay in_cipher by 10 cycles
    reg [127:0] cipher_delay [0:9];
    reg         cipher_valid_delay [0:9];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 10; i = i + 1) begin
                cipher_delay[i]       <= 128'b0;
                cipher_valid_delay[i] <= 1'b0;
            end
        end else begin
            cipher_delay[0]       <= in_cipher;
            cipher_valid_delay[0] <= submit;
            for (i = 1; i < 10; i = i + 1) begin
                cipher_delay[i]       <= cipher_delay[i-1];
                cipher_valid_delay[i] <= cipher_valid_delay[i-1];
            end
        end
    end

    // XOR keystream with delayed ciphertext → plaintext
    assign out_valid = ks_valid && cipher_valid_delay[9];
    assign out_plain = ks_data ^ cipher_delay[9];

    // -----------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    // Keystream and ciphertext valid must be in sync
    ASSERT_CTR_SYNC : assert property (
        @(posedge clk) disable iff (!rst_n)
        (ks_valid == cipher_valid_delay[9])
    ) else $error("[aes128_ctr_top] Keystream/ciphertext valid mismatch");
    `endif

    `ifdef ENABLE_COVERAGE
    covergroup cg_ctr @(posedge clk);
        cp_ctr_wrap : coverpoint (ctr_reg == 32'hFFFFFFFF) iff (submit);
        cp_active   : coverpoint out_valid;
    endgroup
    cg_ctr cg_ctr_inst = new();
    `endif

endmodule
