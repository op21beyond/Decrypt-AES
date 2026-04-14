// =============================================================================
// File        : tb_core.sv
// Project     : AES Decryption Engine IP
// Description : Shared testbench body — included verbatim inside the module
//               by tb_top.v (NCVerilog) and tb_top_verilator.sv (Verilator).
//               `clk` and `rst_n` must be declared in the enclosing module
//               before this file is included.
//
// NOTE (backdoor coupling): check_output_counter, check_desc_*, TC4-TC6 use
//   hierarchical references such as u_mem.backdoor_read8 / backdoor_write8.
//   Verilator 5.x supports these for module-level tasks, but long-term the
//   preferred approach is an explicit debug interface or DPI-C bridge so that
//   the dependency on simulator-specific hierarchical access is removed.
// =============================================================================

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

    wire irq;

    // =========================================================================
    // DUT
    // =========================================================================
    aes_decrypt_engine u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_awaddr    (s_awaddr),  .s_awvalid (s_awvalid), .s_awready (s_awready),
        .s_wdata     (s_wdata),   .s_wstrb   (s_wstrb),
        .s_wvalid    (s_wvalid),  .s_wready  (s_wready),
        .s_bresp     (s_bresp),   .s_bvalid  (s_bvalid),  .s_bready  (s_bready),
        .s_araddr    (s_araddr),  .s_arvalid (s_arvalid), .s_arready (s_arready),
        .s_rdata     (s_rdata),   .s_rresp   (s_rresp),
        .s_rvalid    (s_rvalid),  .s_rready  (s_rready),
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
        .irq         (irq)
    );

    // =========================================================================
    // Fake Memory (4 KB)
    // =========================================================================
    fake_mem #(
        .MEM_BASE  (`MEM_BASE),
        .MEM_WORDS (512),
        .HEX_FILE  ("mem_init.hex")
    ) u_mem (
        .clk       (clk),
        .rst_n     (rst_n),
        .s_araddr  (m_araddr),  .s_arlen  (m_arlen),
        .s_arvalid (m_arvalid), .s_arready(m_arready),
        .s_rdata   (m_rdata),   .s_rresp  (m_rresp),
        .s_rlast   (m_rlast),   .s_rvalid (m_rvalid), .s_rready(m_rready),
        .s_awaddr  (m_awaddr),  .s_awlen  (m_awlen),
        .s_awvalid (m_awvalid), .s_awready(m_awready),
        .s_wdata   (m_wdata),   .s_wstrb  (m_wstrb),
        .s_wlast   (m_wlast),   .s_wvalid (m_wvalid), .s_wready(m_wready),
        .s_bresp   (m_bresp),   .s_bvalid (m_bvalid), .s_bready(m_bready)
    );

    // =========================================================================
    // FSDB / VCD dump
    //   TB_SKIP_WAVES : defined by Verilator wrapper — dump handled by tb_dpi.cpp
    //   NOFSDB        : fall back to $dumpfile/$dumpvars when FSDB is unavailable
    // =========================================================================
`ifndef TB_SKIP_WAVES
    initial begin
        `ifndef NOFSDB
            $fsdbDumpfile("dump.fsdb");
            $fsdbDumpvars(0, `TB_TOP_MODULE_NAME);
        `else
            $dumpfile("dump.vcd");
            $dumpvars(0, `TB_TOP_MODULE_NAME);
        `endif
    end
`endif

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    integer err_cnt;
    integer test_cnt;

    // =========================================================================
    // AXI4-Lite register access tasks
    // =========================================================================
    task axil_write;
        input [7:0]  addr;
        input [31:0] data;
        integer      to;
        begin
            to = 200;
            @(negedge clk);
            s_awaddr  = addr;  s_awvalid = 1'b1;
            s_wdata   = data;  s_wstrb   = 4'hF;  s_wvalid = 1'b1;
            s_bready  = 1'b1;
            @(posedge clk);
            while (!(s_awready && s_wready) && to > 0) begin
                @(posedge clk); to = to - 1;
            end
            @(negedge clk);
            s_awvalid = 1'b0;  s_wvalid = 1'b0;
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

    task axil_read;
        input  [7:0]  addr;
        output [31:0] data;
        integer       to;
        begin
            to = 200;
            @(negedge clk);
            s_araddr  = addr;  s_arvalid = 1'b1;  s_rready = 1'b1;
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
                $display("[ERROR] axil_read timeout @ addr=%02Xh t=%0t", addr, $time);
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
                repeat(100) @(posedge clk);
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
    // Verify output buffer: expected plaintext = counter pattern pt[i] = i & 0xFF
    // =========================================================================
    task check_output_counter;
        input [31:0] buf_base;   // byte address in fake_mem
        input [31:0] n_bytes;    // number of bytes to check
        input [63:0] tc_name;    // 8-char tag for display
        reg   [ 7:0] got;
        integer      i, fail;
        begin
            fail = 0;
            for (i = 0; i < n_bytes; i = i + 1) begin
                u_mem.backdoor_read8(buf_base + i, got);
                if (got !== (i & 8'hFF)) begin
                    if (fail < 4)
                        $display("[FAIL] %s byte[%0d]: got 0x%02X exp 0x%02X",
                                 tc_name, i, got, i & 8'hFF);
                    fail = fail + 1;
                end
            end
            if (fail == 0)
                $display("[PASS] %s output = counter pattern (%0d B)", tc_name, n_bytes);
            else begin
                $display("[FAIL] %s %0d byte(s) mismatched", tc_name, fail);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // Verify descriptor state byte (byte 1 of descriptor = state code)
    task check_desc_state;
        input [31:0] desc_base;
        input [7:0]  expected;
        input [63:0] tc_name;
        reg   [7:0]  got;
        begin
            u_mem.backdoor_read8(desc_base + 1, got);
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

    // Verify valid bit cleared (IP clears it after processing)
    task check_desc_valid_cleared;
        input [31:0] desc_base;
        input [63:0] tc_name;
        reg   [7:0]  got;
        begin
            u_mem.backdoor_read8(desc_base, got);
            if (got[0] === 1'b0)
                $display("[PASS] %s valid bit cleared by IP", tc_name);
            else begin
                $display("[FAIL] %s valid bit NOT cleared (ctrl=0x%02X)", tc_name, got);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // Verify STATUS.BUS_ERROR bit
    task check_bus_error_set;
        input [63:0] tc_name;
        reg   [31:0] rd;
        begin
            axil_read(`REG_STATUS, rd);
            if (rd[2] === 1'b1)
                $display("[PASS] %s STATUS.BUS_ERROR=1", tc_name);
            else begin
                $display("[FAIL] %s STATUS.BUS_ERROR not set (STATUS=0x%08X)",
                         tc_name, rd);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // Verify IRQ_STATUS[1] (BUS_ERROR interrupt)
    task check_irq_buserr_set;
        input [63:0] tc_name;
        reg   [31:0] rd;
        begin
            axil_read(`REG_IRQ_STATUS, rd);
            if (rd[1] === 1'b1)
                $display("[PASS] %s IRQ_STATUS.BUS_ERROR=1", tc_name);
            else begin
                $display("[FAIL] %s IRQ_STATUS.BUS_ERROR not set (IRQ=0x%08X)",
                         tc_name, rd);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end
    endtask

    // =========================================================================
    // AES-128 key (NIST SP 800-38A F.5.1)
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

        s_awaddr  = 8'h0;  s_awvalid = 1'b0;
        s_wdata   = 32'h0; s_wstrb   = 4'h0; s_wvalid = 1'b0; s_bready = 1'b0;
        s_araddr  = 8'h0;  s_arvalid = 1'b0; s_rready = 1'b0;

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

        axil_write(`REG_CMD_BUF_ADDR, `RING_BASE);
        axil_write(`REG_CMD_BUF_SIZE, 32'd4);           // 4-slot ring
        axil_write(`REG_AXI_OUTSTAND, 32'h0001_0001);   // max 1 rd, 1 wr outstanding
        axil_write(`REG_INTERVAL,     32'h0000_0020);   // 32-cycle poll interval
        axil_write(`REG_IRQ_ENABLE,   32'h0000_0003);   // enable DESC_DONE + BUS_ERROR

        axil_write(`REG_AES_KEY_0, KEY_W0);
        axil_write(`REG_AES_KEY_1, KEY_W1);
        axil_write(`REG_AES_KEY_2, KEY_W2);
        axil_write(`REG_AES_KEY_3, KEY_W3);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_STOP)
            $display("  STATUS.STATE = STOP (OK)");
        else begin
            $display("[FAIL] Expected STOP, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end

        // ==================================================================
        // TC0: 1 AES block (16 B), 0 B pad, IEEE 802.3
        // ==================================================================
        $display("\n[TC0] 1 block (16B), 0B pad, IEEE — interrupt=1");
        axil_write(`REG_CRC_CTRL, 32'h0);           // IEEE 802.3
        axil_write(`REG_CMD_TAIL_PTR, 32'd1);        // submit Desc 0
        axil_write(`REG_CTRL, `CTRL_START);

        wait_irq(500_000);
        $display("  IRQ at t=%0t", $time);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_PAUSE)
            $display("  STATUS = PAUSE (OK)");
        else begin
            $display("[FAIL] TC0: expected PAUSE, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end
        axil_read(`REG_IRQ_STATUS, rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);    // W1C clear

        check_output_counter(`OUTBUF0, 16, "TC0");
        check_desc_state    (`RING_BASE + 0*32, `DSTATE_OK,  "TC0");
        check_desc_valid_cleared(`RING_BASE + 0*32, "TC0");

        // ==================================================================
        // TC1: 3 AES blocks (48 B), 16 B pad, CRC-32C
        // ==================================================================
        $display("\n[TC1] 3 blocks (48B), 16B pad, CRC-32C — interrupt=1");
        axil_write(`REG_CRC_CTRL, 32'h1);           // CRC-32C
        axil_write(`REG_CMD_TAIL_PTR, 32'd2);        // submit Desc 1 (tail 1→2)
        axil_write(`REG_CTRL, `CTRL_RESUME);

        wait_irq(1_000_000);
        $display("  IRQ at t=%0t", $time);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_PAUSE)
            $display("  STATUS = PAUSE (OK)");
        else begin
            $display("[FAIL] TC1: expected PAUSE, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end
        axil_read(`REG_IRQ_STATUS, rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);

        check_output_counter(`OUTBUF1, 48, "TC1");
        check_desc_state    (`RING_BASE + 1*32, `DSTATE_OK, "TC1");
        check_desc_valid_cleared(`RING_BASE + 1*32, "TC1");

        // Verify 16B padding region in OUTBUF1 is NOT written (no out_pad_size)
        // out_pad_size=0 for TC1; bytes beyond 48 should remain 0xCC (canary)
        begin : tc1_pad_check
            reg [7:0] canary;
            u_mem.backdoor_read8(`OUTBUF1 + 48, canary);
            if (canary === 8'hCC)
                $display("[PASS] TC1 output padding guard byte intact (0xCC)");
            else begin
                $display("[FAIL] TC1 output overran (byte[48]=0x%02X, exp 0xCC)", canary);
                err_cnt = err_cnt + 1;
            end
            test_cnt = test_cnt + 1;
        end

        // ==================================================================
        // TC2: 6 AES blocks (96 B), 32 B pad, IEEE 802.3
        // ==================================================================
        $display("\n[TC2] 6 blocks (96B), 32B pad, IEEE 802.3 — interrupt=1");
        axil_write(`REG_CRC_CTRL, 32'h0);           // IEEE 802.3
        axil_write(`REG_CMD_TAIL_PTR, 32'd3);        // submit Desc 2 (tail 2→3)
        axil_write(`REG_CTRL, `CTRL_RESUME);

        wait_irq(2_000_000);
        $display("  IRQ at t=%0t", $time);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_PAUSE)
            $display("  STATUS = PAUSE (OK)");
        else begin
            $display("[FAIL] TC2: expected PAUSE, got STATUS=0x%08X", rd_val);
            err_cnt = err_cnt + 1;
        end
        axil_read(`REG_IRQ_STATUS, rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);

        check_output_counter(`OUTBUF2, 96, "TC2");
        check_desc_state    (`RING_BASE + 2*32, `DSTATE_OK, "TC2");
        check_desc_valid_cleared(`RING_BASE + 2*32, "TC2");

        // ==================================================================
        // TC3: 3 blocks (48 B), 8 B pad, CRC-32C, CRC error, last=1
        // RING WRAP-AROUND: tail set to 0 (wraps past slot 3)
        //   head=3, tail=0 (3≠0) → IP fetches slot 3 → head wraps 3→0
        // ==================================================================
        $display("\n[TC3] 3 blocks (48B), 8B pad, CRC-32C, CRC_ERR, last=1");
        $display("      [RING WRAP] tail set to 0 (head=3, tail=0 → wrap test)");
        axil_write(`REG_CRC_CTRL, 32'h1);           // CRC-32C
        // tail wraps: 3+1 mod 4 = 0; setting 0 signals slot 3 is ready
        axil_write(`REG_CMD_TAIL_PTR, 32'd0);
        axil_write(`REG_CTRL, `CTRL_RESUME);

        // last=1 → engine goes to STOP (no interrupt)
        wait_state(`STATE_STOP, 2_000_000);
        $display("  STATUS = STOP at t=%0t", $time);

        check_desc_state    (`RING_BASE + 3*32, `DSTATE_CRC_ERR, "TC3");
        check_desc_valid_cleared(`RING_BASE + 3*32, "TC3");

        // Verify head pointer wrapped to 0
        axil_read(`REG_CMD_HEAD_PTR, rd_val);
        if (rd_val[9:0] === 10'd0) begin
            $display("[PASS] TC3 head pointer wrapped to 0");
            test_cnt = test_cnt + 1;
        end else begin
            $display("[FAIL] TC3 head pointer = %0d (expected 0 after wrap)", rd_val[9:0]);
            err_cnt  = err_cnt + 1;
            test_cnt = test_cnt + 1;
        end

        // Verify STATUS.BUS_ERROR is NOT set (only CRC error, no bus fault)
        axil_read(`REG_STATUS, rd_val);
        if (!rd_val[2]) begin
            $display("[PASS] TC3 STATUS.BUS_ERROR=0 (CRC_ERR only, no bus fault)");
            test_cnt = test_cnt + 1;
        end else begin
            $display("[FAIL] TC3 STATUS.BUS_ERROR unexpectedly set");
            err_cnt  = err_cnt + 1;
            test_cnt = test_cnt + 1;
        end

        // ==================================================================
        // TC4: BUS ERROR INJECTION
        //   - Inject SLVERR on descriptor-fetch read at RING_BASE (slot 0)
        //   - Write a valid descriptor to slot 0 (reuse TC0 params)
        //   - Start engine → descriptor fetch → SLVERR → BUS_ERR state → STOP
        //   - Verify STATUS.BUS_ERROR=1, IRQ_BUS_ERROR=1
        // ==================================================================
        $display("\n[TC4] Bus error injection — SLVERR on descriptor fetch");

        // Restore slot 0 with a fresh TC0-like descriptor (valid=1, no flags)
        u_mem.backdoor_write8(`RING_BASE + 0*32 + 0, 8'h01); // ctrl: valid=1
        u_mem.backdoor_write8(`RING_BASE + 0*32 + 1, 8'h00); // state = idle

        // Arm read-error injection at RING_BASE (the descriptor fetch address)
        u_mem.set_read_error(`RING_BASE);

        // Clear any stale BUS_ERROR / IRQ from previous tests
        axil_read(`REG_STATUS, rd_val);
        if (rd_val[2]) axil_write(`REG_STATUS, 32'h4);   // W1C BUS_ERROR
        axil_read(`REG_IRQ_STATUS, rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);

        // Ring is empty: head=0, tail=0.  Advance tail to 1 to submit slot 0.
        axil_write(`REG_CMD_TAIL_PTR, 32'd1);
        axil_write(`REG_CTRL, `CTRL_START);

        // Engine tries to fetch Desc 0 → SLVERR → TOP_BUS_ERR → STOP
        wait_state(`STATE_STOP, 200_000);
        $display("  STATUS = STOP at t=%0t (bus error handled)", $time);

        // Disarm error injection
        u_mem.clear_read_error();

        check_bus_error_set("TC4_BUSERR");
        check_irq_buserr_set("TC4_BUSERR");

        // Clear BUS_ERROR and IRQ for next tests
        axil_write(`REG_STATUS,     32'h4);   // W1C BUS_ERROR bit
        axil_read(`REG_IRQ_STATUS, rd_val);
        axil_write(`REG_IRQ_STATUS, rd_val);

        // ==================================================================
        // TC5: INVALID DESCRIPTOR POLLING
        //   - Write descriptor to slot 0 with valid=0 (ring: head=1, tail=2)
        //   - Wait INTERVAL cycles for engine to detect valid=0 → fetch_invalid
        //   - TB backdoor-writes valid=1 after 3 poll attempts
        //   - Engine re-polls, finds valid=1 → processes job → STOP
        // ==================================================================
        $display("\n[TC5] Invalid descriptor polling (valid=0 then backdoor set valid=1)");

        // Restore TC0 descriptor at slot 0 but with valid=0
        u_mem.backdoor_write8(`RING_BASE + 0*32 + 0, 8'h00); // ctrl: valid=0 (no flags)
        u_mem.backdoor_write8(`RING_BASE + 0*32 + 1, 8'h00); // state = idle

        // Fill in rest of descriptor fields (in_addr, out_addr, sizes)
        // Reuse INBUF0 and OUTBUF0, 16B data, 0B pad, no interrupt, no last
        begin : tc5_desc
            integer b;
            // in_addr = INBUF0 (little-endian)
            u_mem.backdoor_write8(`RING_BASE + 4,  `INBUF0[7:0]);
            u_mem.backdoor_write8(`RING_BASE + 5,  `INBUF0[15:8]);
            u_mem.backdoor_write8(`RING_BASE + 6,  `INBUF0[23:16]);
            u_mem.backdoor_write8(`RING_BASE + 7,  `INBUF0[31:24]);
            // out_addr = OUTBUF0
            u_mem.backdoor_write8(`RING_BASE + 8,  `OUTBUF0[7:0]);
            u_mem.backdoor_write8(`RING_BASE + 9,  `OUTBUF0[15:8]);
            u_mem.backdoor_write8(`RING_BASE + 10, `OUTBUF0[23:16]);
            u_mem.backdoor_write8(`RING_BASE + 11, `OUTBUF0[31:24]);
            // IN_DATA_SIZE=16, IN_PAD_SIZE=0
            u_mem.backdoor_write8(`RING_BASE + 12, 8'd16);
            u_mem.backdoor_write8(`RING_BASE + 13, 8'd0);
            u_mem.backdoor_write8(`RING_BASE + 14, 8'd0);
            u_mem.backdoor_write8(`RING_BASE + 15, 8'd0);  // pad_size byte
            // OUT_DATA_SIZE=16, OUT_PAD_SIZE=0
            u_mem.backdoor_write8(`RING_BASE + 16, 8'd16);
            u_mem.backdoor_write8(`RING_BASE + 17, 8'd0);
            u_mem.backdoor_write8(`RING_BASE + 18, 8'd0);
            u_mem.backdoor_write8(`RING_BASE + 19, 8'd0);
            b = b; // suppress unused-variable warning
        end

        // Re-init OUTBUF0 canary
        begin : tc5_canary
            integer i;
            for (i = 0; i < 16; i = i + 1)
                u_mem.backdoor_write8(`OUTBUF0 + i, 8'hCC);
        end

        axil_write(`REG_CRC_CTRL, 32'h0);      // IEEE 802.3 (matches INBUF0)
        axil_write(`REG_CMD_TAIL_PTR, 32'd1);   // head=0, tail=1 → slot 0 pending
        axil_write(`REG_CTRL, `CTRL_START);

        // Wait for a few poll intervals (engine is waiting on valid=0)
        // INTERVAL=32 cycles; wait ~100 cycles then set valid=1 via backdoor
        repeat(150) @(posedge clk);

        $display("  TC5: setting valid=1 via backdoor write at t=%0t", $time);
        u_mem.backdoor_write8(`RING_BASE + 0*32 + 0, 8'h01); // valid=1, last=0

        // Engine should now pick up the descriptor, process it, and stop
        // (no interrupt, no last → keeps running but ring is empty → polls)
        // Use immediate stop to cleanly terminate
        wait_state(`STATE_ACTIVE, 200_000);   // wait until engine is active
        repeat(50) @(posedge clk);
        axil_write(`REG_CTRL, `CTRL_IMM_STOP);
        wait_state(`STATE_STOP, 100_000);
        $display("  TC5 completed and stopped at t=%0t", $time);

        // Verify that OUTBUF0 was written (not all 0xCC anymore)
        begin : tc5_check
            reg [7:0] got;
            u_mem.backdoor_read8(`OUTBUF0 + 0, got);
            if (got !== 8'hCC) begin
                $display("[PASS] TC5 valid=0 polling: output written (byte[0]=0x%02X)", got);
                test_cnt = test_cnt + 1;
            end else begin
                $display("[FAIL] TC5 OUTBUF0 still 0xCC — descriptor not processed");
                err_cnt  = err_cnt + 1;
                test_cnt = test_cnt + 1;
            end
        end

        // ==================================================================
        // TC6: IMMEDIATE STOP
        //   Issue CTRL_START then CTRL_IMM_STOP a few cycles later.
        //   Ring is empty (head=tail), so engine enters ACTIVE polling.
        //   Verify engine returns to STOP cleanly.
        // ==================================================================
        $display("\n[TC6] Immediate stop — CTRL_START then CTRL_IMM_STOP quickly");

        // Ensure ring is empty: tail == head (== 0 at this point after wraps)
        axil_read(`REG_CMD_HEAD_PTR, rd_val);
        axil_write(`REG_CMD_TAIL_PTR, rd_val);  // tail = head → empty

        axil_write(`REG_CTRL, `CTRL_START);
        repeat(8) @(posedge clk);    // let FSM enter ACTIVE/FETCH
        axil_write(`REG_CTRL, `CTRL_IMM_STOP);
        repeat(20) @(posedge clk);

        axil_read(`REG_STATUS, rd_val);
        if (rd_val[1:0] === `STATE_STOP) begin
            $display("[PASS] TC6 IMMEDIATE_STOP: returned to STOP");
            test_cnt = test_cnt + 1;
        end else begin
            $display("[FAIL] TC6 IMMEDIATE_STOP: STATUS=0x%08X (expected STOP)", rd_val);
            err_cnt  = err_cnt + 1;
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
    // Simulation timeout watchdog (500 ms)
    // =========================================================================
    initial begin
        #500_000_000;
        $display("[FATAL] Simulation timeout at t=%0t", $time);
        $finish;
    end
