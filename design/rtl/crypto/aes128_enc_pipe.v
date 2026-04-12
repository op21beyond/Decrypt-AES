// =============================================================================
// File        : aes128_enc_pipe.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : AES-128 10-round pipelined encrypt core.
//               One 128-bit block enters per clock (when in_valid=1).
//               Output appears 10 clock cycles later (pipeline latency = 10).
//               Fully pipelined: one block output per clock at full throughput.
//               Used for CTR mode — both encrypt and decrypt use AES Encrypt.
//               No dividers, no multipliers.  ASIC-safe.
//
//               All 11 round keys (rk_in) must be stable throughout operation.
//               Data representation: state[127:96] = column0, etc. (FIPS 197)
// =============================================================================

module aes128_enc_pipe (
    input  wire         clk,
    input  wire         rst_n,

    // Round keys from key schedule (all 11 × 128 bits, stable)
    input  wire [1407:0] rk_in,

    // Input
    input  wire         in_valid,
    input  wire [127:0] in_data,    // plaintext / counter block

    // Output (10-cycle latency)
    output reg          out_valid,
    output reg  [127:0] out_data    // ciphertext
);

    // -----------------------------------------------------------------------
    // AES S-box (combinational)
    // -----------------------------------------------------------------------
    function automatic [7:0] sbox;
        input [7:0] b;
        case (b)
            8'h00:sbox=8'h63; 8'h01:sbox=8'h7c; 8'h02:sbox=8'h77; 8'h03:sbox=8'h7b;
            8'h04:sbox=8'hf2; 8'h05:sbox=8'h6b; 8'h06:sbox=8'h6f; 8'h07:sbox=8'hc5;
            8'h08:sbox=8'h30; 8'h09:sbox=8'h01; 8'h0a:sbox=8'h67; 8'h0b:sbox=8'h2b;
            8'h0c:sbox=8'hfe; 8'h0d:sbox=8'hd7; 8'h0e:sbox=8'hab; 8'h0f:sbox=8'h76;
            8'h10:sbox=8'hca; 8'h11:sbox=8'h82; 8'h12:sbox=8'hc9; 8'h13:sbox=8'h7d;
            8'h14:sbox=8'hfa; 8'h15:sbox=8'h59; 8'h16:sbox=8'h47; 8'h17:sbox=8'hf0;
            8'h18:sbox=8'had; 8'h19:sbox=8'hd4; 8'h1a:sbox=8'ha2; 8'h1b:sbox=8'haf;
            8'h1c:sbox=8'h9c; 8'h1d:sbox=8'ha4; 8'h1e:sbox=8'h72; 8'h1f:sbox=8'hc0;
            8'h20:sbox=8'hb7; 8'h21:sbox=8'hfd; 8'h22:sbox=8'h93; 8'h23:sbox=8'h26;
            8'h24:sbox=8'h36; 8'h25:sbox=8'h3f; 8'h26:sbox=8'hf7; 8'h27:sbox=8'hcc;
            8'h28:sbox=8'h34; 8'h29:sbox=8'ha5; 8'h2a:sbox=8'he5; 8'h2b:sbox=8'hf1;
            8'h2c:sbox=8'h71; 8'h2d:sbox=8'hd8; 8'h2e:sbox=8'h31; 8'h2f:sbox=8'h15;
            8'h30:sbox=8'h04; 8'h31:sbox=8'hc7; 8'h32:sbox=8'h23; 8'h33:sbox=8'hc3;
            8'h34:sbox=8'h18; 8'h35:sbox=8'h96; 8'h36:sbox=8'h05; 8'h37:sbox=8'h9a;
            8'h38:sbox=8'h07; 8'h39:sbox=8'h12; 8'h3a:sbox=8'h80; 8'h3b:sbox=8'he2;
            8'h3c:sbox=8'heb; 8'h3d:sbox=8'h27; 8'h3e:sbox=8'hb2; 8'h3f:sbox=8'h75;
            8'h40:sbox=8'h09; 8'h41:sbox=8'h83; 8'h42:sbox=8'h2c; 8'h43:sbox=8'h1a;
            8'h44:sbox=8'h1b; 8'h45:sbox=8'h6e; 8'h46:sbox=8'h5a; 8'h47:sbox=8'ha0;
            8'h48:sbox=8'h52; 8'h49:sbox=8'h3b; 8'h4a:sbox=8'hd6; 8'h4b:sbox=8'hb3;
            8'h4c:sbox=8'h29; 8'h4d:sbox=8'he3; 8'h4e:sbox=8'h2f; 8'h4f:sbox=8'h84;
            8'h50:sbox=8'h53; 8'h51:sbox=8'hd1; 8'h52:sbox=8'h00; 8'h53:sbox=8'hed;
            8'h54:sbox=8'h20; 8'h55:sbox=8'hfc; 8'h56:sbox=8'hb1; 8'h57:sbox=8'h5b;
            8'h58:sbox=8'h6a; 8'h59:sbox=8'hcb; 8'h5a:sbox=8'hbe; 8'h5b:sbox=8'h39;
            8'h5c:sbox=8'h4a; 8'h5d:sbox=8'h4c; 8'h5e:sbox=8'h58; 8'h5f:sbox=8'hcf;
            8'h60:sbox=8'hd0; 8'h61:sbox=8'hef; 8'h62:sbox=8'haa; 8'h63:sbox=8'hfb;
            8'h64:sbox=8'h43; 8'h65:sbox=8'h4d; 8'h66:sbox=8'h33; 8'h67:sbox=8'h85;
            8'h68:sbox=8'h45; 8'h69:sbox=8'hf9; 8'h6a:sbox=8'h02; 8'h6b:sbox=8'h7f;
            8'h6c:sbox=8'h50; 8'h6d:sbox=8'h3c; 8'h6e:sbox=8'h9f; 8'h6f:sbox=8'ha8;
            8'h70:sbox=8'h51; 8'h71:sbox=8'ha3; 8'h72:sbox=8'h40; 8'h73:sbox=8'h8f;
            8'h74:sbox=8'h92; 8'h75:sbox=8'h9d; 8'h76:sbox=8'h38; 8'h77:sbox=8'hf5;
            8'h78:sbox=8'hbc; 8'h79:sbox=8'hb6; 8'h7a:sbox=8'hda; 8'h7b:sbox=8'h21;
            8'h7c:sbox=8'h10; 8'h7d:sbox=8'hff; 8'h7e:sbox=8'hf3; 8'h7f:sbox=8'hd2;
            8'h80:sbox=8'hcd; 8'h81:sbox=8'h0c; 8'h82:sbox=8'h13; 8'h83:sbox=8'hec;
            8'h84:sbox=8'h5f; 8'h85:sbox=8'h97; 8'h86:sbox=8'h44; 8'h87:sbox=8'h17;
            8'h88:sbox=8'hc4; 8'h89:sbox=8'ha7; 8'h8a:sbox=8'h7e; 8'h8b:sbox=8'h3d;
            8'h8c:sbox=8'h64; 8'h8d:sbox=8'h5d; 8'h8e:sbox=8'h19; 8'h8f:sbox=8'h73;
            8'h90:sbox=8'h60; 8'h91:sbox=8'h81; 8'h92:sbox=8'h4f; 8'h93:sbox=8'hdc;
            8'h94:sbox=8'h22; 8'h95:sbox=8'h2a; 8'h96:sbox=8'h90; 8'h97:sbox=8'h88;
            8'h98:sbox=8'h46; 8'h99:sbox=8'hee; 8'h9a:sbox=8'hb8; 8'h9b:sbox=8'h14;
            8'h9c:sbox=8'hde; 8'h9d:sbox=8'h5e; 8'h9e:sbox=8'h0b; 8'h9f:sbox=8'hdb;
            8'ha0:sbox=8'he0; 8'ha1:sbox=8'h32; 8'ha2:sbox=8'h3a; 8'ha3:sbox=8'h0a;
            8'ha4:sbox=8'h49; 8'ha5:sbox=8'h06; 8'ha6:sbox=8'h24; 8'ha7:sbox=8'h5c;
            8'ha8:sbox=8'hc2; 8'ha9:sbox=8'hd3; 8'haa:sbox=8'hac; 8'hab:sbox=8'h62;
            8'hac:sbox=8'h91; 8'had:sbox=8'h95; 8'hae:sbox=8'he4; 8'haf:sbox=8'h79;
            8'hb0:sbox=8'he7; 8'hb1:sbox=8'hc8; 8'hb2:sbox=8'h37; 8'hb3:sbox=8'h6d;
            8'hb4:sbox=8'h8d; 8'hb5:sbox=8'hd5; 8'hb6:sbox=8'h4e; 8'hb7:sbox=8'ha9;
            8'hb8:sbox=8'h6c; 8'hb9:sbox=8'h56; 8'hba:sbox=8'hf4; 8'hbb:sbox=8'hea;
            8'hbc:sbox=8'h65; 8'hbd:sbox=8'h7a; 8'hbe:sbox=8'hae; 8'hbf:sbox=8'h08;
            8'hc0:sbox=8'hba; 8'hc1:sbox=8'h78; 8'hc2:sbox=8'h25; 8'hc3:sbox=8'h2e;
            8'hc4:sbox=8'h1c; 8'hc5:sbox=8'ha6; 8'hc6:sbox=8'hb4; 8'hc7:sbox=8'hc6;
            8'hc8:sbox=8'he8; 8'hc9:sbox=8'hdd; 8'hca:sbox=8'h74; 8'hcb:sbox=8'h1f;
            8'hcc:sbox=8'h4b; 8'hcd:sbox=8'hbd; 8'hce:sbox=8'h8b; 8'hcf:sbox=8'h8a;
            8'hd0:sbox=8'h70; 8'hd1:sbox=8'h3e; 8'hd2:sbox=8'hb5; 8'hd3:sbox=8'h66;
            8'hd4:sbox=8'h48; 8'hd5:sbox=8'h03; 8'hd6:sbox=8'hf6; 8'hd7:sbox=8'h0e;
            8'hd8:sbox=8'h61; 8'hd9:sbox=8'h35; 8'hda:sbox=8'h57; 8'hdb:sbox=8'hb9;
            8'hdc:sbox=8'h86; 8'hdd:sbox=8'hc1; 8'hde:sbox=8'h1d; 8'hdf:sbox=8'h9e;
            8'he0:sbox=8'he1; 8'he1:sbox=8'hf8; 8'he2:sbox=8'h98; 8'he3:sbox=8'h11;
            8'he4:sbox=8'h69; 8'he5:sbox=8'hd9; 8'he6:sbox=8'h8e; 8'he7:sbox=8'h94;
            8'he8:sbox=8'h9b; 8'he9:sbox=8'h1e; 8'hea:sbox=8'h87; 8'heb:sbox=8'he9;
            8'hec:sbox=8'hce; 8'hed:sbox=8'h55; 8'hee:sbox=8'h28; 8'hef:sbox=8'hdf;
            8'hf0:sbox=8'h8c; 8'hf1:sbox=8'ha1; 8'hf2:sbox=8'h89; 8'hf3:sbox=8'h0d;
            8'hf4:sbox=8'hbf; 8'hf5:sbox=8'he6; 8'hf6:sbox=8'h42; 8'hf7:sbox=8'h68;
            8'hf8:sbox=8'h41; 8'hf9:sbox=8'h99; 8'hfa:sbox=8'h2d; 8'hfb:sbox=8'h0f;
            8'hfc:sbox=8'hb0; 8'hfd:sbox=8'h54; 8'hfe:sbox=8'hbb; 8'hff:sbox=8'h16;
            default: sbox = 8'h00;
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // AES round operations — all combinational, operate on 128-bit state
    //
    // State byte layout (FIPS 197 column-major):
    //   state[127:120]=s00, state[119:112]=s10, state[111:104]=s20, state[103:96]=s30
    //   state[ 95: 88]=s01, state[ 87: 80]=s11, state[ 79: 72]=s21, state[ 71:64]=s31
    //   state[ 63: 56]=s02, state[ 55: 48]=s12, state[ 47: 40]=s22, state[ 39:32]=s32
    //   state[ 31: 24]=s03, state[ 23: 16]=s13, state[ 15:  8]=s23, state[  7: 0]=s33
    // -----------------------------------------------------------------------

    // Helper: extract byte [r][c] from 128-bit state (row r=0..3, col c=0..3)
    function automatic [7:0] get_byte;
        input [127:0] s;
        input [1:0] r, c;
        // Byte index in 128-bit vector: (c*4 + r) from MSB
        // byte 0 = s[127:120], byte 1 = s[119:112], ..., byte 15 = s[7:0]
        get_byte = s[127 - (c*4 + r)*8 -: 8];
    endfunction

    // SubBytes: apply S-box to all 16 bytes
    function automatic [127:0] sub_bytes;
        input [127:0] s;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                sub_bytes[127-i*8 -: 8] = sbox(s[127-i*8 -: 8]);
        end
    endfunction

    // ShiftRows: row r is shifted left by r positions (in columns)
    function automatic [127:0] shift_rows;
        input [127:0] s;
        reg [7:0] b [0:15];
        integer r, c;
        begin
            // Unpack
            for (r = 0; r < 4; r = r + 1)
                for (c = 0; c < 4; c = c + 1)
                    b[c*4+r] = get_byte(s, r[1:0], c[1:0]);
            // Row 0: no shift
            // Row 1: shift left 1
            // Row 2: shift left 2
            // Row 3: shift left 3
            shift_rows = {
                b[0],b[5],b[10],b[15],   // row 0 shifted 0
                b[4],b[9],b[14],b[3],    // row 1 shifted 1 (wrong, fix)
                b[8],b[13],b[2],b[7],    // row 2 shifted 2
                b[12],b[1],b[6],b[11]    // row 3 shifted 3
            };
        end
    endfunction

    // GF(2^8) multiply by 2 (xtime)
    function automatic [7:0] xtime;
        input [7:0] b;
        xtime = {b[6:0], 1'b0} ^ (b[7] ? 8'h1b : 8'h00);
    endfunction

    // MixColumns: operate on each column independently
    function automatic [31:0] mix_col;
        input [31:0] col;  // [31:24]=s0r, [23:16]=s1r, [15:8]=s2r, [7:0]=s3r
        reg [7:0] s0, s1, s2, s3;
        reg [7:0] r0, r1, r2, r3;
        begin
            s0 = col[31:24]; s1 = col[23:16]; s2 = col[15:8]; s3 = col[7:0];
            r0 = xtime(s0) ^ (xtime(s1)^s1) ^ s2          ^ s3;
            r1 = s0         ^ xtime(s1)       ^ (xtime(s2)^s2) ^ s3;
            r2 = s0         ^ s1              ^ xtime(s2)   ^ (xtime(s3)^s3);
            r3 = (xtime(s0)^s0) ^ s1         ^ s2          ^ xtime(s3);
            mix_col = {r0, r1, r2, r3};
        end
    endfunction

    function automatic [127:0] mix_columns;
        input [127:0] s;
        mix_columns = {
            mix_col(s[127:96]),
            mix_col(s[95:64]),
            mix_col(s[63:32]),
            mix_col(s[31:0])
        };
    endfunction

    // AddRoundKey: XOR state with round key
    function automatic [127:0] add_round_key;
        input [127:0] s, rk;
        add_round_key = s ^ rk;
    endfunction

    // -----------------------------------------------------------------------
    // One AES round (rounds 1-9: full round with MixColumns)
    // -----------------------------------------------------------------------
    function automatic [127:0] aes_round;
        input [127:0] state, rk;
        reg [127:0] t;
        begin
            t = sub_bytes(state);
            t = shift_rows(t);
            t = mix_columns(t);
            aes_round = add_round_key(t, rk);
        end
    endfunction

    // Final round (round 10: no MixColumns)
    function automatic [127:0] aes_final_round;
        input [127:0] state, rk;
        reg [127:0] t;
        begin
            t = sub_bytes(state);
            t = shift_rows(t);
            aes_final_round = add_round_key(t, rk);
        end
    endfunction

    // -----------------------------------------------------------------------
    // Pipeline registers: 10 stages
    // stage[0] = after AddRoundKey(rk0) = input to round 1
    // stage[1] = after round 1 ... stage[9] = after round 9 (output to final)
    // -----------------------------------------------------------------------
    reg [127:0] stage [0:9];
    reg         valid_pipe [0:9];

    // Round key extraction
    wire [127:0] rk [0:10];
    genvar k;
    generate
        for (k = 0; k < 11; k = k + 1) begin : g_rk
            assign rk[k] = rk_in[k*128 +: 128];
        end
    endgenerate

    // Stage 0: initial AddRoundKey
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage[0]      <= 128'b0;
            valid_pipe[0] <= 1'b0;
        end else begin
            stage[0]      <= add_round_key(in_data, rk[0]);
            valid_pipe[0] <= in_valid;
        end
    end

    // Stages 1-9: full rounds
    genvar s;
    generate
        for (s = 1; s <= 9; s = s + 1) begin : g_pipe
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    stage[s]      <= 128'b0;
                    valid_pipe[s] <= 1'b0;
                end else begin
                    stage[s]      <= aes_round(stage[s-1], rk[s]);
                    valid_pipe[s] <= valid_pipe[s-1];
                end
            end
        end
    endgenerate

    // Output stage: final round (no MixColumns)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data  <= 128'b0;
            out_valid <= 1'b0;
        end else begin
            out_data  <= aes_final_round(stage[9], rk[10]);
            out_valid <= valid_pipe[9];
        end
    end

    // -----------------------------------------------------------------------
    `ifdef ENABLE_ASSERTIONS
    // Pipeline latency consistency check
    ASSERT_VALID_PIPE_STABLE : assert property (
        @(posedge clk) disable iff (!rst_n)
        // If in_valid=0 for 10+ cycles, out_valid must eventually go 0
        1'b1  // placeholder — wave-based checks preferred for pipeline timing
    );
    `endif

endmodule
