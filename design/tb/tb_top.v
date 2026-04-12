// =============================================================================
// File        : tb_top.v
// Project     : AES Decryption Engine IP
// Company     : SSVD
// Description : Top-level simulation testbench.
//
// Components:
//   - u_dut  : aes_decrypt_engine (DUT)
//   - u_mem  : fake_mem           (AXI4 Subordinate memory model)
//   - Inline : Fake Host CPU tasks (AXI4-Lite r/w, interrupt handler)
//
// Memory map (see gen_mem.c / mem_init.hex):
//   0x0000_1000 : Descriptor ring (4 × 32 B)
//   0x0000_1100 : Input buffer TC0 (4 blk, IEEE 802.3 CRC)
//   0x0000_1200 : Input buffer TC1 (2 blk, CRC-32C)
//   0x0000_1300 : Input buffer TC2 (4 blk, CRC-32C, ciphertext corrupted)
//   0x0000_1400 : Output buffer TC0 (64 B)
//   0x0000_1480 : Output buffer TC1 (32 B)
//   0x0000_1500 : Output buffer TC2 (64 B, CRC error → output valid but state = CRC_ERR)
//
// Test sequence:
//   TC0 : 4-block decrypt, IEEE 802.3 CRC, interrupt=1  → PAUSE; verify output
//   TC1 : 2-block decrypt, CRC-32C,        interrupt=1  → PAUSE; verify output
//   TC2 : 4-block decrypt, CRC-32C,        last=1       → STOP;  verify CRC_ERR state
//
// Simulator  : NCVerilog (Xcelium)
// Dump format: FSDB (Novas/Verdi) via $fsdbDumpfile / $fsdbDumpvars
//              Falls back to VCD if `NOVCD is NOT defined and `NOFSDB is defined
// =============================================================================

`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// Register offsets (mirrors aes_decrypt_defs.vh for task use)
// ---------------------------------------------------------------------------
`define REG_CTRL          8'h00
`define REG_STATUS        8'h04
`define REG_IRQ_STATUS    8'h08
`define REG_IRQ_ENABLE    8'h0C
`define REG_CMD_BUF_ADDR  8'h10
`define REG_CMD_BUF_SIZE  8'h14
`define REG_CMD_HEAD_PTR  8'h18
`define REG_CMD_TAIL_PTR  8'h1C
`define REG_AES_KEY_0     8'h20
`define REG_AES_KEY_1     8'h24
`define REG_AES_KEY_2     8'h28
`define REG_AES_KEY_3     8'h2C
`define REG_CRC_CTRL      8'h30
`define REG_AXI_OUTSTAND  8'h34
`define REG_INTERVAL      8'h40

`define STATE_STOP        2'b00
`define STATE_ACTIVE      2'b01
`define STATE_PAUSE       2'b10

`define CTRL_START        32'h0000_0001
`define CTRL_RESUME       32'h0000_0002
`define CTRL_IMM_STOP     32'h0000_0004

`define IRQ_DESC_DONE     32'h0000_0001
`define IRQ_BUS_ERROR     32'h0000_0002

// Descriptor state codes
`define DSTATE_OK         8'h01
`define DSTATE_CRC_ERR    8'h02

// Memory base
`define MEM_BASE          32'h0000_1000
`define RING_BASE         32'h0000_1000
`define INBUF0            32'h0000_1100
`define INBUF1            32'h0000_1200
`define INBUF2            32'h0000_1300
`define OUTBUF0           32'h0000_1400
`define OUTBUF1           32'h0000_1480
`define OUTBUF2           32'h0000_1500

// ---------------------------------------------------------------------------
// Expected plaintext (NIST SP 800-38A F.5.1)
// ---------------------------------------------------------------------------
`define PT_B0_LO 64'h963d7e11_73931_72a  // wrong — see initial block below
// (Full 64-byte plaintext initialised in initial block as byte array)

module tb_top;

    // =========================================================================
    // Clock and reset
    // =========================================================================
    localparam CLK_HALF = 5;   // 10 ns period = 100 MHz

    reg clk, rst_n;

    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
    end

    // =========================================================================
    // AXI4-Lite interface (Fake CPU → DUT Subordinate)
    // =========================================================================
    reg  [7:0]  s_awaddr;
    reg         s_awvalid;
    wire        s_awready;
    reg  [31:0] s_wdata;
    reg  [3:0]  s_wstrb;
    reg         s_wvalid;
    wire        s_wready;
    wire [1:0]  s_bresp;
    wire        s_bvalid;
    reg         s_bready;

    reg  [7:0]  s_araddr;
    reg         s_arvalid;
    wire        s_arready;
    wire [31:0] s_rdata;
    wire [1:0]  s_rresp;
    wire        s_rvalid;
    reg         s_rready;

    // =========================================================================
    // AXI4 Manager interface (DUT → Fake Memory)
    // =========================================================================
    wire [31:0] m_awaddr;
    wire [ 7:0] m_awlen;
    wire [ 2:0] m_awsize;
    wire [ 1:0] m_awburst;
    wire [ 3:0] m_awcache;
    wire [ 2:0] m_awprot;
    wire        m_awvalid;
    wire        m_awready;
    wire [63:0] m_wdata;
    wire [ 7:0] m_wstrb;
    wire        m_wlast;
    wire        m_wvalid;
    wire        m_wready;
    wire [ 1:0] m_bresp;
    wire        m_bvalid;
    wire        m_bready;

    wire [31:0] m_araddr;
    wire [ 7:0] m_arlen;
    wire [ 2:0] m_arsize;
    wire [ 1:0] m_arburst;
    wire [ 3:0] m_arcache;
    wire [ 2:0] m_arprot;
    wire        m_arvalid;
    wire        m_arready;
    wire [63:0] m_rdata;
    wire [ 1:0] m_rresp;
    wire        m_rlast;
    wire        m_rvalid;
    wire        m_rready;

    // Interrupt
    wire irq;

    // =========================================================================
    // DUT
    // =========================================================================
    aes_decrypt_engine u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        // AXI4-Lite Subordinate
        .s_awaddr    (s_awaddr),  .s_awvalid (s_awvalid), .s_awready (s_awready),
        .s_wdata     (s_wdata),   .s_wstrb   (s_wstrb),
        .s_wvalid    (s_wvalid),  .s_wready  (s_wready),
        .s_bresp     (s_bresp),   .s_bvalid  (s_bvalid),  .s_bready  (s_bready),
        .s_araddr    (s_araddr),  .s_arvalid (s_arvalid), .s_arready (s_arready),
        .s_rdata     (s_rdata),   .s_rresp   (s_rresp),
        .s_rvalid    (s_rvalid),  .s_rready  (s_rready),
        // AXI4 Manager
        .m_awaddr    (m_awaddr),  .m_awlen   (m_awlen),   .m_awsize  (m_awsize),
        .m_awburst   (m_awburst), .m_awcache (m_awcache), .m_awprot  (m_awprot),
        .m_awvalid   (m_awvalid), .m_awready (m_awready),
        .m_wdata     (m_wdata),   .m_wstrb   (m_wstrb),   .m_wlast   (m_wlast),
        .m_wvalid    (m_wvalid),  .m_wready  (m_wready),
        .m_bresp     (m_bresp),   .m_bvalid  (m_bvalid),  .m_bready  (m_bready),
        .m_araddr    (m_araddr),  .m_arlen   (m_arlen),   .m_arsize  (m_arsize),
        .m_arburst   (m_arburst), .m_arcache (m_arcache), .m_arprot  (m_arprot),
        .m_arvalid   (m_arvalid), .m_arready (m_arready),
        .m_rdata     (m_rdata),   .m_rresp   (m_rresp),
        .m_rlast     (m_rlast),   .m_rvalid  (m_rvalid),  .m_rready  (m_rready),
        // IRQ
        .irq         (irq)
    );

    // =========================================================================
    // Fake Memory
    // =========================================================================
    fake_mem #(
        .MEM_BASE  (`MEM_BASE),
        .MEM_WORDS (256),
        .HEX_FILE  ("mem_init.hex")
    ) u_mem (
        .clk       (clk),
        .rst_n     (rst_n),
        // Read
        .s_araddr  (m_araddr),  .s_arlen  (m_arlen),
        .s_arvalid (m_arvalid), .s_arready(m_arready),
        .s_rdata   (m_rdata),   .s_rresp  (m_rresp),
        .s_rlast   (m_rlast),   .s_rvalid (m_rvalid), .s_rready(m_rready),
        // Write
        .s_awaddr  (m_awaddr),  .s_awlen  (m_awlen),
        .s_awvalid (m_awvalid), .s_awready(m_awready),
        .s_wdata   (m_wdata),   .s_wstrb  (m_wstrb),
        .s_wlast   (m_wlast),   .s_wvalid (m_wvalid), .s_wready(m_wready),
        .s_bresp   (m_bresp),   .s_bvalid (m_bvalid), .s_bready(m_bready)
    );

    // =========================================================================
    // FSDB / VCD dump
    // =========================================================================
    initial begin
        `ifndef NOFSDB
            $fsdbDumpfile("dump.fsdb");
            $fsdbDumpvars(0, tb_top);
        `else
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_top);
        `endif
    end

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    integer err_cnt;
    integer test_cnt;

    // Known-good plaintext (NIST SP 800-38A F.5.1, 64 bytes)
    reg [7:0] exp_pt [0:63];
    initial begin
        // Block 0
        exp_pt[ 0]=8'h6b; exp_pt[ 1]=8'hc1; exp_pt[ 2]=8'hbe; exp_pt[ 3]=8'he2;
        exp_pt[ 4]=8'h2e; exp_pt[ 5]=8'h40; exp_pt[ 6]=8'h9f; exp_pt[ 7]=8'h96;
        exp_pt[ 8]=8'he9; exp_pt[ 9]=8'h3d; exp_pt[10]=8'h7e; exp_pt[11]=8'h11;
        exp_pt[12]=8'h73; exp_pt[13]=8'h93; exp_pt[14]=8'h17; exp_pt[15]=8'h2a;
        // Block 1
        exp_pt[16]=8'hae; exp_pt[17]=8'h2d; exp_pt[18]=8'h8a; exp_pt[19]=8'h57;
        exp_pt[20]=8'h1e; exp_pt[21]=8'h03; exp_pt[22]=8'hac; exp_pt[23]=8'h9c;
        exp_pt[24]=8'h9e; exp_pt[25]=8'hb7; exp_pt[26]=8'h6f; exp_pt[27]=8'hac;
        exp_pt[28]=8'h45; exp_pt[29]=8'haf; exp_pt[30]=8'h8e; exp_pt[31]=8'h51;
        // Block 2
        exp_pt[32]=8'h30; exp_pt[33]=8'hc8; exp_pt[34]=8'h1c; exp_pt[35]=8'h46;
        exp_pt[36]=8'ha3; exp_pt[37]=8'h5c; exp_pt[38]=8'he4; exp_pt[39]=8'h11;
        exp_pt[40]=8'he5; exp_pt[41]=8'hfb; exp_pt[42]=8'hc1; exp_pt[43]=8'h19;
        exp_pt[44]=8'h1a; exp_pt[45]=8'h0a; exp_pt[46]=8'h52; exp_pt[47]=8'hef;
        // Block 3
        exp_pt[48]=8'hf6; exp_pt[49]=8'h9f; exp_pt[50]=8'h24; exp_pt[51]=8'h45;
        exp_pt[52]=8'hdf; exp_pt[53]=8'h4f; exp_pt[54]=8'h9b; exp_pt[55]=8'h17;
        exp_pt[56]=8'had; exp_pt[57]=8'h2b; exp_pt[58]=8'h41; exp_pt[59]=8'h7b;
        exp_pt[60]=8'he6; exp_pt[61]=8'h6c; exp_pt[62]=8'h37; exp_pt[63]=8'h10;
    end

    // =========================================================================
    // Fake CPU tasks — AXI4-Lite register access
    // =========================================================================

    // Write register (full 32-bit, all byte strobes active)
    task axil_write;
        input [7:0]  addr;
        input [31:0] data;
        integer      to;
        begin
            to = 200;
            @(negedge clk);
            s_awaddr  = addr;
            s_awvalid = 1'b1;
            s_wdata   = data;
            s_wstrb   = 4'hF;
            s_wvalid  = 1'b1;
            s_bready  = 1'b1;

            // Wait until both AWREADY and WREADY are seen
            @(posedge clk);
            while (!(s_awready && s_wready) && to > 0) begin
                @(posedge clk); to = to - 1;
            end
            @(negedge clk);
            s_awvalid = 1'b0;
            s_wvalid  = 1'b0;

            // Wait for write response
            to = 200;
            @(posedge clk);
            while (!s_bvalid && to > 0) begin
                @(posedge clk); to = to - 1;
            end
            @(negedge clk);
            s_bready = 1'b0;
            if (to == 0) begin
                $display("[ERROR] axil_write timeout @ addr=%02Xh data=%08Xh t=%0t",
                         addr, data, $time);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // Read register
    task axil_read;
        input  [7:0]  addr;
        output [31:0] data;
        integer       to;
        begin
            to = 200;
            @(negedge clk);
            s_araddr  = addr;
            s_arvalid = 1'b1;
            s_rready  = 1'b1;

            @(posedge clk);
            while (!s_arready && to > 0) begin
                @(posedge clk); to = to - 1;
            end
            @(negedge clk);
            s_arvalid = 1'b0;

            to = 200;
            @(posedge clk);
            while (!s_rvalid && to > 0) begin
                @(posedge clk); to = to - 1;
            end
            data = s_rdata;
            @(negedge clk);
            s_rready = 1'b0;
            if (to == 0) begin
                $display("[ERROR] axil_read timeout @ addr=%02Xh t=%0t",
                         addr, $time);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Wait for STATUS.STATE to reach expected value (polling)
    // =========================================================================
    task wait_state;
        input [1:0]  expected;
        input [31:0] timeout_cycles;
        reg   [31:0] rd;
        integer      to;
        begin
            to = timeout_cycles;
            rd = 32'hDEAD;
            while (rd[1:0] !== expected && to > 0) begin
                axil_read(`REG_STATUS, rd);
                to = to - 1000;
                repeat(100) @(posedge clk);  // coarse poll
            end
            if (to <= 0) begin
                $display("[ERROR] wait_state(%0b) timeout at t=%0t (STATUS=0x%08X)",
                         expected, $time, rd);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Wait for IRQ assertion with timeout
    // =========================================================================
    task wait_irq;
        input [31:0] timeout_cycles;
        integer      to;
        begin
            to = timeout_cycles;
            while (!irq && to > 0) begin
                @(posedge clk); to = to - 1;
            end
            if (to <= 0) begin
                $display("[ERROR] wait_irq timeout at t=%0t", $time);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Verify output buffer against expected plaintext
    // =========================================================================
    task check_output;
        input [31:0] buf_base;   // byte address in fake_mem
        input [31:0] n_bytes;    // number of bytes to check
        input [31:0] pt_offset;  // offset into exp_pt array
        input [63:0] tc_name;    // 8-char tag for display
        reg   [ 7:0] got;
        integer      i, fail;
        begin
            fail = 0;
            for (i = 0; i < n_bytes; i = i + 1) begin
                u_mem.backdoor_read8(buf_base + i, got);
                if (got !== exp_pt[pt_offset + i]) begin
                    if (fail < 4)  // report first 4 mismatches only
                        $display("[FAIL] %s byte[%0d]: got 0x%02X exp 0x%02X",
                                 tc_name, i, got, exp_pt[pt_offset + i]);
                    fail = fail + 1;
                end
            end
            if (fail == 0)
                $display("[PASS] %s output buffer matches expected plaintext (%0d B)",
                         tc_name, n_bytes);
            else begin
                $display("[FAIL] %s %0d byte(s) mismatched", tc_name, fail);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // Verify descriptor state byte
    task check_desc_state;
        input [31:0] desc_base;  // byte address of descriptor
        input [7:0]  expected;   // expected DSTATE_* code
        input [63:0] tc_name;
        reg   [7:0]  got;
        begin
            u_mem.backdoor_read8(desc_base + 1, got); // byte 1 = state byte
            if (got === expected)
                $display("[PASS] %s desc_state = 0x%02X", tc_name, got);
            else begin
                $display("[FAIL] %s desc_state: got 0x%02X exp 0x%02X",
                         tc_name, got, expected);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // Verify valid bit cleared (IP cleared it after processing)
    task check_desc_valid_cleared;
        input [31:0] desc_base;
        input [63:0] tc_name;
        reg   [7:0]  got;
        begin
            u_mem.backdoor_read8(desc_base, got); // byte 0 = ctrl byte
            if (got[0] === 1'b0)
                $display("[PASS] %s valid bit cleared by IP", tc_name);
            else begin
                $display("[FAIL] %s valid bit NOT cleared (ctrl=0x%02X)", tc_name, got);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // =========================================================================
    // NIST AES-128 key (stored little-endian per word: KEY_0 = key[31:0])
    // key = 2B7E151628AED2A6ABF7158809CF4F3C
    //   KEY_0 = 0x16157E2B  KEY_1 = 0xA6D2AE28
    //   KEY_2 = 0x8809CF4F  KEY_3 = 0x3C4FCF09  ← wait, this is BE
    // Register spec: KEY_0 holds bits [31:0] (LE: key[0] is LSB of KEY_0)
    //   key bytes: 2B 7E 15 16 28 AE D2 A6 AB F7 15 88 09 CF 4F 3C
    //   KEY_0 = { key[3],key[2],key[1],key[0] } = { 16, 15, 7E, 2B } → 0x16157E2B
    //   KEY_1 = { key[7],key[6],key[5],key[4] } = { A6, D2, AE, 28 } → 0xA6D2AE28
    //   KEY_2 = { key[11],key[10],key[9],key[8] } = { 88, 15, F7, AB } → 0x8815F7AB
    //   KEY_3 = { key[15],key[14],key[13],key[12] } = { 3C, 4F, CF, 09 } → 0x3C4FCF09
    // =========================================================================
    localparam KEY_W0 = 32'h16157E2B;
    localparam KEY_W1 = 32'hA6D2AE28;
    localparam KEY_W2 = 32'h8815F7AB;
    localparam KEY_W3 = 32'h3C4FCF09;

    // =========================================================================
    // Main test procedure
    // =========================================================================
    reg [31:0] rd_val;

    initial begin
        err_cnt  = 0;
        test_cnt = 0;

        // Idle all AXI4-Lite signals
        s_awaddr  = 8'h0;  s_awvalid = 1'b0;
        s_wdata   = 32'h0; s_wstrb   = 4'h0; s_wvalid = 1'b0; s_bready = 1'b0;
        s_araddr  = 8'h0;  s_arvalid = 1'b0; s_rready = 1'b0;

        // Wait for reset deassertion
        @(posedge rst_n);
        repeat(5) @(posedge clk);

        $display("");
        $display("==========================================================");
        $display("  AES Decrypt IP — Simulation Testbench");
        $display("==========================================================");
        $display("  t=%0t  Reset released", $time);

        // ------------------------------------------------------------------
        // [STEP 1] Configure IP
        // ------------------------------------------------------------------
        $display("\n[STEP 1] Configure IP registers");

        axil_write(`REG_CMD_BUF_ADDR, `RING_BASE);      // ring at 0x1000
        axil_write(`REG_CMD_BUF_SIZE, 32'd4);            // 4 descriptor slots
        axil_write(`REG_AXI_OUTSTAND, 32'h0001_0001);   // max 1 rd, 1 wr outstanding
        axil_write(`REG_INTERVAL,     32'h0000_0010);   // 16-cycle poll interval
        axil_write(`REG_IRQ_ENABLE,   32'h0000_0003);   // enable both interrupts

        // Write AES-128 key
        $display("  Writing AES-128 key");
        axil_write(`REG_AES_KEY_0, KEY_W0);
        axil_write(`REG_AES_KEY_1, KEY_W1);
        axil_write(`REG_AES_KEY_2, KEY_W2);
        axil_write(`REG_AES_KEY_3, KEY_W3);

        // Set CRC algorithm to IEEE 802.3 for TC0
        axil_write(`REG_CRC_CTRL, 32'h0);  // 0 = IEEE 802.3

        // Verify engine is in STOP state
        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_STOP)
            $display("  STATUS.STATE = STOP (OK)");
        else begin
            $display("[FAIL] Expected STOP, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end

        // ------------------------------------------------------------------
        // [STEP 2] Submit TC0 and start engine
        // ------------------------------------------------------------------
        $display("\n[STEP 2] Submit TC0 (Desc 0, interrupt=1) and START");

        // mem_init.hex already has Desc 0 written by gen_mem.c.
        // Advance tail to 1 (Desc 0 is now available to the IP).
        axil_write(`REG_CMD_TAIL_PTR, 32'd1);
        axil_write(`REG_CTRL, `CTRL_START);

        // ------------------------------------------------------------------
        // [STEP 3] Wait for PAUSE after TC0
        // ------------------------------------------------------------------
        $display("[STEP 3] Waiting for IRQ (TC0 interrupt=1)...");
        wait_irq(500_000);   // up to 5 ms
        $display("  IRQ asserted at t=%0t", $time);

        // Verify STATUS = PAUSE
        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_PAUSE)
            $display("  STATUS.STATE = PAUSE (OK)");
        else begin
            $display("[FAIL] Expected PAUSE, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end

        // Clear IRQ_STATUS
        axil_read(`REG_IRQ_STATUS, rd_val);
        $display("  IRQ_STATUS = 0x%08X", rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);   // W1C

        // ------------------------------------------------------------------
        // [STEP 4] Verify TC0 output
        // ------------------------------------------------------------------
        $display("\n[STEP 4] Verify TC0 output buffer");
        check_output(`OUTBUF0, 64, 0, "TC0");
        check_desc_state(`RING_BASE + 0*32, `DSTATE_OK, "TC0");
        check_desc_valid_cleared(`RING_BASE + 0*32, "TC0");

        // ------------------------------------------------------------------
        // [STEP 5] Change CRC algorithm to Castagnoli for TC1 and TC2
        // ------------------------------------------------------------------
        $display("\n[STEP 5] Change CRC_CTRL to Castagnoli");
        axil_write(`REG_CRC_CTRL, 32'h1);  // 1 = CRC-32C

        // Advance tail to 3 (Desc 1 and Desc 2 now visible)
        axil_write(`REG_CMD_TAIL_PTR, 32'd3);

        // Resume — process TC1 (interrupt=1) then TC2 (last=1)
        $display("  RESUME issued");
        axil_write(`REG_CTRL, `CTRL_RESUME);

        // ------------------------------------------------------------------
        // [STEP 6] Wait for PAUSE after TC1
        // ------------------------------------------------------------------
        $display("[STEP 6] Waiting for IRQ (TC1 interrupt=1)...");
        wait_irq(500_000);
        $display("  IRQ asserted at t=%0t", $time);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_PAUSE)
            $display("  STATUS.STATE = PAUSE (OK)");
        else begin
            $display("[FAIL] Expected PAUSE, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end

        axil_read(`REG_IRQ_STATUS, rd_val);
        $display("  IRQ_STATUS = 0x%08X", rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);

        // ------------------------------------------------------------------
        // [STEP 7] Verify TC1 output
        // ------------------------------------------------------------------
        $display("\n[STEP 7] Verify TC1 output buffer");
        check_output(`OUTBUF1, 32, 0, "TC1");
        check_desc_state(`RING_BASE + 1*32, `DSTATE_OK, "TC1");
        check_desc_valid_cleared(`RING_BASE + 1*32, "TC1");

        // ------------------------------------------------------------------
        // [STEP 8] Resume — process TC2 (CRC error, last=1)
        // ------------------------------------------------------------------
        $display("\n[STEP 8] RESUME for TC2 (CRC error expected, last=1)");
        axil_write(`REG_CTRL, `CTRL_RESUME);

        // Wait for STOP (TC2 has last=1)
        $display("  Waiting for STOP...");
        wait_state(`STATE_STOP, 500_000);
        $display("  STATUS.STATE = STOP at t=%0t", $time);

        // ------------------------------------------------------------------
        // [STEP 9] Verify TC2 — CRC error reported in descriptor
        // ------------------------------------------------------------------
        $display("\n[STEP 9] Verify TC2 descriptor state = CRC_ERR");
        check_desc_state(`RING_BASE + 2*32, `DSTATE_CRC_ERR, "TC2");
        check_desc_valid_cleared(`RING_BASE + 2*32, "TC2");

        // STATUS.BUS_ERROR should NOT be set (only CRC error, not bus error)
        axil_read(`REG_STATUS, rd_val);
        if (!rd_val[2]) begin
            $display("[PASS] TC2 STATUS.BUS_ERROR not set (correct — CRC_ERR only)");
            test_cnt = test_cnt + 1;
        end else begin
            $display("[FAIL] TC2 STATUS.BUS_ERROR unexpectedly set");
            err_cnt = err_cnt + 1;
            test_cnt = test_cnt + 1;
        end

        // ------------------------------------------------------------------
        // [STEP 10] Verify IMMEDIATE_STOP from ACTIVE
        // ------------------------------------------------------------------
        $display("\n[STEP 10] Test IMMEDIATE_STOP from ACTIVE state");

        // Reset ring for a new run: re-init desc 0 valid bit via reg write
        // (We just verify the control works; we don't need a full job here)
        axil_write(`REG_CMD_TAIL_PTR, 32'd3);  // keep tail ahead of head
        // Re-prime head: the IP advanced head to 3 after TC2. Ring is now empty.
        // Just issue START then IMMEDIATE_STOP.
        axil_write(`REG_CTRL, `CTRL_START);
        repeat(20) @(posedge clk);   // let FSM enter ACTIVE (fetch loop sees empty ring)
        axil_write(`REG_CTRL, `CTRL_IMM_STOP);
        repeat(10) @(posedge clk);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_STOP) begin
            $display("[PASS] IMMEDIATE_STOP returned to STOP state");
            test_cnt = test_cnt + 1;
        end else begin
            $display("[FAIL] IMMEDIATE_STOP: STATUS=0x%08X (expected STOP)", rd_val);
            err_cnt = err_cnt + 1;
            test_cnt = test_cnt + 1;
        end

        // ------------------------------------------------------------------
        // Report
        // ------------------------------------------------------------------
        $display("");
        $display("==========================================================");
        $display("  Results: %0d/%0d checks passed",
                 test_cnt - err_cnt, test_cnt);
        if (err_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", err_cnt);
        $display("==========================================================");

        repeat(20) @(posedge clk);
        $finish;
    end

    // =========================================================================
    // Simulation timeout watchdog
    // =========================================================================
    initial begin
        #200_000_000;  // 200 ms hard limit
        $display("[FATAL] Simulation timeout at t=%0t", $time);
        $finish;
    end

endmodule
