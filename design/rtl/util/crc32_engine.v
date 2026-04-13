// =============================================================================
// File        : crc32_engine.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : CRC-32 engine supporting two algorithms selectable at runtime:
//                 alg_sel=0 → CRC-32/IEEE 802.3  (poly 0x04C11DB7)
//                 alg_sel=1 → CRC-32C/Castagnoli (poly 0x1EDC6F41)
//               Both use: init=0xFFFFFFFF, reflect input, reflect output,
//               final XOR 0xFFFFFFFF.
//
//               Processes 8 bytes (64 bits) per clock cycle.
//               To process fewer bytes in the last beat, use byte_valid[7:0]
//               to mask invalid bytes (0 = byte not included in CRC).
//               Byte 0 of wr_data is the lowest-address byte.
//
//               Usage:
//                 1. Assert init_n (active-low) for one cycle to reset.
//                 2. For each 8-byte aligned beat of data: assert valid,
//                    drive wr_data with the 8 bytes, drive byte_valid with
//                    a bitmask of which bytes count (all-1 for full beats).
//                 3. Read crc_out when valid is de-asserted (or any time
//                    after last beat).
// =============================================================================

module crc32_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,           // synchronous init: resets CRC state to 0xFFFFFFFF

    // Configuration
    input  wire        alg_sel,        // 0=IEEE 802.3, 1=CRC-32C

    // Data input (processed on posedge when valid=1)
    input  wire        valid,
    input  wire [63:0] wr_data,        // 8 bytes; byte 0 = wr_data[7:0]
    input  wire [ 7:0] byte_valid,     // which bytes to include

    // Result
    output wire [31:0] crc_out         // running CRC value (finalized with XOR)
);

    // -----------------------------------------------------------------------
    // CRC-32 combinational functions — one byte at a time, reflected.
    // reflect(b) is the bit-reversal; for reflected-mode CRC we process
    // data LSB-first.  The byte-at-a-time table is pre-baked into
    // the function via the standard Galois LFSR formulation.
    // -----------------------------------------------------------------------

    // IEEE 802.3 poly: 0x04C11DB7 → reflected = 0xEDB88320
    // CRC-32C poly:    0x1EDC6F41 → reflected = 0x82F63B78

    function automatic [31:0] crc32_byte_ieee;
        input [31:0] crc_in;
        input [ 7:0] data;
        integer i;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'b0, data};
            for (i = 0; i < 8; i = i + 1)
                c = (c[0]) ? ({1'b0, c[31:1]} ^ 32'hEDB88320)
                           :  {1'b0, c[31:1]};
            crc32_byte_ieee = c;
        end
    endfunction

    function automatic [31:0] crc32_byte_c;
        input [31:0] crc_in;
        input [ 7:0] data;
        integer i;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'b0, data};
            for (i = 0; i < 8; i = i + 1)
                c = (c[0]) ? ({1'b0, c[31:1]} ^ 32'h82F63B78)
                           :  {1'b0, c[31:1]};
            crc32_byte_c = c;
        end
    endfunction

    // -----------------------------------------------------------------------
    // 8-byte combinational update (unrolled for synthesis performance)
    // -----------------------------------------------------------------------

    function automatic [31:0] crc32_8byte_ieee;
        input [31:0] crc_in;
        input [63:0] data;
        input [ 7:0] bv;    // byte valid mask
        integer j;
        reg [31:0] c;
        begin
            c = crc_in;
            for (j = 0; j < 8; j = j + 1) begin
                if (bv[j])
                    c = crc32_byte_ieee(c, data[j*8 +: 8]);
            end
            crc32_8byte_ieee = c;
        end
    endfunction

    function automatic [31:0] crc32_8byte_c;
        input [31:0] crc_in;
        input [63:0] data;
        input [ 7:0] bv;
        integer j;
        reg [31:0] c;
        begin
            c = crc_in;
            for (j = 0; j < 8; j = j + 1) begin
                if (bv[j])
                    c = crc32_byte_c(c, data[j*8 +: 8]);
            end
            crc32_8byte_c = c;
        end
    endfunction

    // -----------------------------------------------------------------------
    // State register
    // -----------------------------------------------------------------------
    reg [31:0] crc_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_reg <= 32'hFFFFFFFF;
        end else if (init) begin
            // Synchronous init: reset CRC accumulator to the standard initial value.
            // Using a dedicated init input avoids gating rst_n combinationally,
            // which can cause synthesis/STA issues with asynchronous reset trees.
            crc_reg <= 32'hFFFFFFFF;
        end else if (valid) begin
            if (alg_sel == 1'b0)
                crc_reg <= crc32_8byte_ieee(crc_reg, wr_data, byte_valid);
            else
                crc_reg <= crc32_8byte_c(crc_reg, wr_data, byte_valid);
        end
    end

    // Final XOR 0xFFFFFFFF to produce the CRC output
    assign crc_out = crc_reg ^ 32'hFFFFFFFF;

    // -----------------------------------------------------------------------
    `ifdef ENABLE_COVERAGE
    covergroup cg_crc32 @(posedge clk);
        cp_alg     : coverpoint alg_sel;
        cp_bv_full : coverpoint (byte_valid == 8'hFF) iff (valid);
        cp_bv_part : coverpoint (byte_valid != 8'hFF && byte_valid != 8'h00) iff (valid);
    endgroup
    cg_crc32 cg_crc32_inst = new();
    `endif

endmodule
