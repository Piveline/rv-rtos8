`timescale 1ns / 1ps

module tb_ICache_RV32;

    reg clk;
    reg reset;
    reg clk_enable;

    always #5 clk = ~clk;

    reg         cpu_req_valid;
    reg  [31:0] cpu_req_addr;
    reg         cpu_flush;
    wire [31:0] cpu_rdata;
    wire        cpu_ready;
    reg         fence_i_req;
    wire        fence_i_done;

    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;

    reg  [63:0] m_axi_rdata;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;

    integer test_pass_count;
    integer test_fail_count;
    reg [31:0]  resp_data;
    integer     timeout;
    integer     base_done;
    integer     base_done_hi;
    integer     issue_pass [1:5];
    integer     issue_fail [1:5];
    integer     idx;

    ICache_RV32 dut (
        .clk(clk), .reset(reset), .clk_enable(clk_enable),
        .cpu_req_valid(cpu_req_valid), .cpu_req_addr(cpu_req_addr),
        .cpu_flush(cpu_flush), .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .fence_i_req(fence_i_req), .fence_i_done(fence_i_done),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    // External AXI Transaction Monitor (No DUT internal access)
    reg        axi_ar_handshake_seen;
    reg [31:0] axi_last_araddr;
    reg [7:0]  axi_last_arlen;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            axi_ar_handshake_seen <= 1'b0;
            axi_last_araddr       <= 32'h0;
            axi_last_arlen        <= 8'h0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                axi_ar_handshake_seen <= 1'b1;
                axi_last_araddr       <= m_axi_araddr;
                axi_last_arlen        <= m_axi_arlen;
            end
        end
    end

    task clear_axi_monitor;
        begin
            axi_ar_handshake_seen = 1'b0;
            axi_last_araddr       = 32'h0;
            axi_last_arlen        = 8'h0;
        end
    endtask

    // External FENCE.I Done Monitor (No DUT internal access)
    integer fence_done_cnt;
    integer fence_done_hi_cnt;
    reg     fence_done_d;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            fence_done_cnt    <= 0;
            fence_done_hi_cnt <= 0;
            fence_done_d      <= 1'b0;
        end else begin
            fence_done_d <= fence_i_done;
            if (fence_i_done) begin
                fence_done_hi_cnt <= fence_done_hi_cnt + 1;
                if (!fence_done_d) fence_done_cnt <= fence_done_cnt + 1;
            end
        end
    end

    // TB AXI Slave Model
    reg [31:0] latched_araddr;
    reg [7:0]  latched_arlen;
    reg        axi_read_active;
    integer    axi_beat_cnt;
    reg [2:0]  r_delay_cnt;

    initial begin
        m_axi_arready   = 1'b0;
        m_axi_rvalid    = 1'b0;
        m_axi_rlast     = 1'b0;
        m_axi_rdata     = 64'h0;
        axi_read_active = 1'b0;
        axi_beat_cnt    = 0;
        r_delay_cnt     = 0;
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            m_axi_arready   <= 1'b0;
            axi_read_active <= 1'b0;
        end else begin
            if (m_axi_arvalid && !m_axi_arready && !axi_read_active) begin
                m_axi_arready   <= 1'b1;
                latched_araddr  <= m_axi_araddr;
                latched_arlen   <= m_axi_arlen;
                axi_read_active <= 1'b1;
            end else begin
                m_axi_arready   <= 1'b0;
            end
            if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                axi_read_active <= 1'b0;
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            m_axi_rvalid <= 1'b0;
            m_axi_rlast  <= 1'b0;
            r_delay_cnt  <= 0;
            axi_beat_cnt <= 0;
        end else begin
            if (axi_read_active && !m_axi_rvalid) begin
                if (r_delay_cnt < 2) begin
                    r_delay_cnt <= r_delay_cnt + 1;
                end else begin
                    axi_beat_cnt <= 0;
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= generate_mock_mem_data(latched_araddr, 0);
                    m_axi_rlast  <= (latched_arlen == 8'd0);
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                if (axi_beat_cnt < latched_arlen) begin
                    axi_beat_cnt <= axi_beat_cnt + 1;
                    m_axi_rdata  <= generate_mock_mem_data(latched_araddr, axi_beat_cnt + 1);
                    m_axi_rlast  <= (axi_beat_cnt + 1 == latched_arlen);
                end else begin
                    m_axi_rvalid <= 1'b0;
                    m_axi_rlast  <= 1'b0;
                    r_delay_cnt  <= 0;
                end
            end
        end
    end

    function [63:0] generate_mock_mem_data(input [31:0] base_addr, input integer beat);
        reg [31:0] word0, word1;
        begin
            word0 = base_addr + (beat * 8)     + 32'h0000_1000;
            word1 = base_addr + (beat * 8) + 4 + 32'h0000_1000;
            generate_mock_mem_data = {word1, word0};
        end
    endfunction

    // Robust CPU Request-Response Handshake Task
    task execute_req;
        input  [31:0] addr;
        output [31:0] rdata;
        integer tout;
        begin
            // 1. Clear request and wait for cpu_ready to be 0
            cpu_req_valid = 1'b0;
            tout = 0;
            while (cpu_ready && tout < 100) begin
                @(negedge clk);
                tout = tout + 1;
            end

            // 2. Drive new request at negedge
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr  = addr;

            // 3. Wait for cpu_ready pulse
            tout = 0;
            while (!cpu_ready && tout < 500) begin
                @(negedge clk);
                tout = tout + 1;
            end

            if (tout >= 500) begin
                $display("[FAIL-TIMEOUT] cpu_ready never asserted for addr 0x%h", addr);
                test_fail_count = test_fail_count + 1;
                rdata = 32'hDEAD_BEEF;
            end else begin
                // 4. Sample data at the exact cycle cpu_ready is high
                rdata = cpu_rdata;
            end

            // 5. Deassert cpu_req_valid IMMEDIATELY in the same negedge cycle
            cpu_req_valid = 1'b0;
            cpu_req_addr  = 32'h0;

            // 6. Verify 1-cycle pulse duration on next cycle
            @(negedge clk);
            if (cpu_ready) begin
                $display("[FAIL-PROTOCOL] cpu_ready remained high for >1 cycle after addr 0x%h", addr);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask

    task assert_test(input condition, input [255:0] msg);
        begin
            if (condition) begin
                $display("  -> [PASS] %s", msg);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  -> [FAIL] %s", msg);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask

    task wait_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(negedge clk);
        end
    endtask

    task wait_fence_done;
        input integer base_cnt;
        input integer max_cycles;
        integer k;
        begin
            k = 0;
            while ((fence_done_cnt <= base_cnt) && (k < max_cycles)) begin
                @(negedge clk);
                k = k + 1;
            end
        end
    endtask

    // CPU Request with a cpu_flush window
    // flush is high for flush_len cycles, starting flush_delay cycles after the request is driven
    // The window is completed even after the response (flush held into IDLE)
    task execute_req_flush;
        input  [31:0] addr;
        input  integer flush_delay;
        input  integer flush_len;
        output [31:0] rdata;
        integer c;
        reg     got_resp;
        begin
            cpu_req_valid = 1'b0;
            c = 0;
            while (cpu_ready && c < 100) begin
                @(negedge clk);
                c = c + 1;
            end

            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr  = addr;
            rdata         = 32'hDEAD_BEEF;
            got_resp      = 1'b0;
            c             = 0;

            while ((!got_resp || (c < flush_delay + flush_len)) && c < 500) begin
                cpu_flush = (c >= flush_delay) && (c < flush_delay + flush_len);
                if (!got_resp && cpu_ready) begin
                    got_resp      = 1'b1;
                    rdata         = cpu_rdata;
                    cpu_req_valid = 1'b0;
                    cpu_req_addr  = 32'h0;
                end
                @(negedge clk);
                c = c + 1;
            end
            cpu_flush = 1'b0;

            if (!got_resp) begin
                $display("[FAIL-TIMEOUT] cpu_ready never asserted for addr 0x%h", addr);
                test_fail_count = test_fail_count + 1;
                cpu_req_valid   = 1'b0;
            end

            @(negedge clk);
        end
    endtask

    // Assertion tagged with the reported issue number (1..5)
    task assert_issue;
        input integer id;
        input         condition;
        input [511:0] msg;
        begin
            if (condition) begin
                $display("  -> [PASS][ISSUE %0d] %0s", id, msg);
                test_pass_count = test_pass_count + 1;
                issue_pass[id]  = issue_pass[id] + 1;
            end else begin
                $display("  -> [FAIL][ISSUE %0d] %0s", id, msg);
                test_fail_count = test_fail_count + 1;
                issue_fail[id]  = issue_fail[id] + 1;
            end
        end
    endtask

    // Main Test Execution
    initial begin
        clk             = 1'b0;
        reset           = 1'b1;
        clk_enable      = 1'b1;
        cpu_req_valid   = 1'b0;
        cpu_req_addr    = 32'h0;
        cpu_flush       = 1'b0;
        fence_i_req     = 1'b0;
        test_pass_count = 0;
        test_fail_count = 0;
        resp_data       = 32'h0;
        for (idx = 1; idx <= 5; idx = idx + 1) begin
            issue_pass[idx] = 0;
            issue_fail[idx] = 0;
        end

        #25 reset = 1'b0;

        $display("========================================================");
        $display("   RV32IM54F8SP I-CACHE FULL VERIFICATION SUITE         ");
        $display("========================================================");

        // TEST 1: Primary Miss & Line Refill
        $display("\n[TEST 1] Cache Miss & Refill (0x8000_0000)");
        clear_axi_monitor();
        execute_req(32'h8000_0000, resp_data);
        assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd3) && (resp_data == 32'h8000_1000),
                    "Miss Refill Data 0x80001000");

        // TEST 2-4: Cache Hits on Same Line
        $display("\n[TEST 2] Cache Hit Offset 0x4 (0x8000_0004)");
        clear_axi_monitor();
        execute_req(32'h8000_0004, resp_data);
        assert_test(!axi_ar_handshake_seen && (resp_data == 32'h8000_1004),
                    "Hit Data 0x80001004 (Single-cycle)");

        $display("\n[TEST 3] Cache Hit Offset 0x8 (0x8000_0008)");
        clear_axi_monitor();
        execute_req(32'h8000_0008, resp_data);
        assert_test(!axi_ar_handshake_seen && (resp_data == 32'h8000_1008),
                    "Hit Data 0x80001008 (Single-cycle)");

        $display("\n[TEST 4] Cache Hit Offset 0x1C (0x8000_001C)");
        clear_axi_monitor();
        execute_req(32'h8000_001C, resp_data);
        assert_test(!axi_ar_handshake_seen && (resp_data == 32'h8000_101C),
                    "Hit Data 0x8000101C (Single-cycle)");

        // TEST 5: Bypass / Uncached Access
        $display("\n[TEST 5] Uncached / Bypass Read (0x0000_0100)");
        clear_axi_monitor();
        execute_req(32'h0000_0100, resp_data);
        assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd0) && (resp_data == 32'h0000_1100),
                    "Bypass Single Read (ARLEN=0) & Data 0x00001100");

        // TEST 6-7: 2-Way Associativity and LRU Eviction
        $display("\n[TEST 6] Tag Replacement - Fill Way 1 (0x8004_0000)");
        clear_axi_monitor();
        execute_req(32'h8004_0000, resp_data); // Diff Tag, Same Index 0
        assert_test(axi_ar_handshake_seen && (resp_data == 32'h8004_1000),
                    "Diff Tag inserted into Way 1");

        $display("\n[TEST 7] Tag Replacement - Evict Way 0 by LRU (0x8008_0000)");
        clear_axi_monitor();
        execute_req(32'h8008_0000, resp_data); // 3rd Tag, evicts Way 0
        assert_test(axi_ar_handshake_seen && (resp_data == 32'h8008_1000),
                    "Evicted Way 0 properly");

        // TEST 8: Pipeline Flush Injection
        $display("\n[TEST 8] Pipeline Flush Injection (0x800C_0040)");
        clear_axi_monitor();
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_addr  = 32'h800C_0040;
        
        timeout = 0;
        while (!m_axi_arvalid && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        
        @(negedge clk);
        cpu_flush = 1'b1;
        @(negedge clk);
        cpu_flush = 1'b0;
        
        timeout = 0;
        while (!cpu_ready && timeout < 500) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        
        resp_data = cpu_rdata;
        cpu_req_valid = 1'b0;
        cpu_req_addr  = 32'h0;
        
        assert_test(resp_data == 32'h0000_0013,
                    "Flush correctly squashed output instruction to NOP (0x00000013)");

        clear_axi_monitor();
        execute_req(32'h800C_0040, resp_data);
        assert_test(!axi_ar_handshake_seen && (resp_data == 32'h800C_1040),
                    "Flushed line was saved in cache and served as HIT on re-access");

        // TEST 9: FENCE.I Invalidation
        $display("\n[TEST 9] FENCE.I Invalidation Request");
        clear_axi_monitor();
        
        @(negedge clk);
        fence_i_req = 1'b1;
        
        timeout = 0;
        while (!fence_i_done && timeout < 1000) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        
        fence_i_req = 1'b0;
        @(negedge clk);

        clear_axi_monitor();
        execute_req(32'h8008_0000, resp_data); // Previously cached address
        
        assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd3) && (resp_data == 32'h8008_1000),
                    "FENCE.I forced Cache Miss & Refill on 0x8008_0000");

        // ============================================================
        // ISSUE-FIX VERIFICATION (fence_i_req / cpu_flush handling)
        // ============================================================
        $display("\n--------------------------------------------------------");
        $display(" ISSUE-FIX VERIFICATION (fence_i_req / cpu_flush)");
        $display("--------------------------------------------------------");

        // TEST 10: [ISSUE 1] FENCE.I request must be held internally until done
        $display("\n[TEST 10] FENCE.I req pulse is held internally until done");

        // 10a: 1-cycle fence_i_req pulse while IDLE (req is low long before done)
        execute_req(32'h8000_0200, resp_data);
        base_done = fence_done_cnt;
        @(negedge clk);
        fence_i_req = 1'b1;
        @(negedge clk);
        fence_i_req = 1'b0;
        wait_fence_done(base_done, 1000);
        assert_issue(1, fence_done_cnt == base_done + 1,
                     "1-cycle req in IDLE -> FENCE.I completes (done)");
        wait_cycles(700);
        assert_issue(1, fence_done_cnt == base_done + 1,
                     "No extra done after 1-cycle req");
        clear_axi_monitor();
        execute_req(32'h8000_0200, resp_data);
        assert_issue(1, axi_ar_handshake_seen && (resp_data == 32'h8000_1200),
                     "Line invalidated after 1-cycle req (re-miss)");

        // 10b: 1-cycle fence_i_req pulse while a miss refill is in flight
        clear_axi_monitor();
        base_done = fence_done_cnt;
        cpu_req_valid = 1'b0;
        @(negedge clk);
        cpu_req_valid = 1'b1;
        cpu_req_addr  = 32'h8000_0400;

        timeout = 0;
        while (!m_axi_arvalid && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end

        fence_i_req = 1'b1;
        @(negedge clk);
        fence_i_req = 1'b0;

        timeout = 0;
        while (!cpu_ready && timeout < 500) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        resp_data     = cpu_rdata;
        cpu_req_valid = 1'b0;
        cpu_req_addr  = 32'h0;

        assert_issue(1, resp_data == 32'h8000_1400,
                     "Refill response intact while FENCE.I req is pending");
        wait_fence_done(base_done, 1000);
        assert_issue(1, fence_done_cnt == base_done + 1,
                     "1-cycle req during miss is not lost (done)");
        wait_cycles(700);
        assert_issue(1, fence_done_cnt == base_done + 1,
                     "No extra done after pending FENCE.I");
        clear_axi_monitor();
        execute_req(32'h8000_0400, resp_data);
        assert_issue(1, axi_ar_handshake_seen && (resp_data == 32'h8000_1400),
                     "Line invalidated by the pending FENCE.I (re-miss)");

        // TEST 11: [ISSUE 2] fence_i_req held high must not re-run FENCE.I
        $display("\n[TEST 11] FENCE.I req held high after done (no re-execution)");
        execute_req(32'h8000_0600, resp_data);
        base_done    = fence_done_cnt;
        base_done_hi = fence_done_hi_cnt;
        @(negedge clk);
        fence_i_req = 1'b1;
        wait_fence_done(base_done, 1000);
        assert_issue(2, fence_done_cnt == base_done + 1,
                     "FENCE.I completes with req held high");
        wait_cycles(1500);
        assert_issue(2, fence_done_cnt == base_done + 1,
                     "No second FENCE.I while req stays high (1500 cycles)");
        assert_issue(2, fence_done_hi_cnt == base_done_hi + 1,
                     "done is a single 1-cycle pulse");
        fence_i_req = 1'b0;
        wait_cycles(3);
        clear_axi_monitor();
        execute_req(32'h8000_0600, resp_data);
        assert_issue(2, axi_ar_handshake_seen && (resp_data == 32'h8000_1600),
                     "Cache resumes after req drops (line was invalidated)");
        wait_cycles(700);
        assert_issue(2, fence_done_cnt == base_done + 1,
                     "No FENCE.I re-run after req dropped");

        // TEST 12: [ISSUE 3] cpu_flush while IDLE must be released immediately
        $display("\n[TEST 12] cpu_flush while IDLE is released immediately");

        // 12a: 1-cycle flush with no request, then a miss
        wait_cycles(2);
        cpu_flush = 1'b1;
        @(negedge clk);
        cpu_flush = 1'b0;
        wait_cycles(3);
        execute_req(32'h8000_0800, resp_data);
        assert_issue(3, resp_data == 32'h8000_1800,
                     "Miss after IDLE flush is not squashed");

        // 12b: flush in IDLE, request driven in the very next cycle
        wait_cycles(2);
        cpu_flush = 1'b1;
        @(negedge clk);
        cpu_flush     = 1'b0;
        cpu_req_valid = 1'b1;
        cpu_req_addr  = 32'h8000_0A00;
        timeout = 0;
        while (!cpu_ready && timeout < 500) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        resp_data     = cpu_rdata;
        cpu_req_valid = 1'b0;
        cpu_req_addr  = 32'h0;
        @(negedge clk);
        assert_issue(3, resp_data == 32'h8000_1A00,
                     "Miss right after IDLE flush is not squashed");

        // 12c: hit after IDLE flush
        wait_cycles(2);
        cpu_flush = 1'b1;
        @(negedge clk);
        cpu_flush = 1'b0;
        execute_req(32'h8000_0804, resp_data);
        assert_issue(3, resp_data == 32'h8000_1804,
                     "Hit after IDLE flush is not squashed");

        // TEST 13: [ISSUE 4/5] cpu_flush during a hit is released at the hit response
        $display("\n[TEST 13] cpu_flush during HIT is released at the hit response");

        // 13a: 1-cycle flush in the LOOKUP cycle of a hit
        execute_req_flush(32'h8000_0800, 1, 1, resp_data);
        assert_issue(4, resp_data == 32'h0000_0013,
                     "Hit response squashed to NOP by flush");
        clear_axi_monitor();
        execute_req(32'h8000_0C00, resp_data);
        assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_1C00),
                     "Next miss after flushed hit is not squashed");
        clear_axi_monitor();
        execute_req(32'h8000_0800, resp_data);
        assert_issue(4, !axi_ar_handshake_seen && (resp_data == 32'h8000_1800),
                     "Next hit after flushed hit is not squashed");

        // 13b: flush held high across the hit response and into IDLE
        execute_req_flush(32'h8000_0804, 1, 5, resp_data);
        assert_issue(4, resp_data == 32'h0000_0013,
                     "Hit squashed with multi-cycle flush");
        clear_axi_monitor();
        execute_req(32'h8000_0E00, resp_data);
        assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_1E00),
                     "Miss after multi-cycle flush is not squashed");

        // TEST 14: [ISSUE 5] flush during a refill must not leak into later requests
        $display("\n[TEST 14] cpu_flush during MISS refill does not leak into next miss");

        // 14a: flush pulse early in the refill, released before the response
        execute_req_flush(32'h8000_1000, 2, 3, resp_data);
        assert_issue(5, resp_data == 32'h0000_0013,
                     "Refill response squashed (flush latched in flight)");
        clear_axi_monitor();
        execute_req(32'h8000_1000, resp_data);
        assert_issue(5, !axi_ar_handshake_seen && (resp_data == 32'h8000_2000),
                     "Squashed refill still allocated the line (HIT)");
        clear_axi_monitor();
        execute_req(32'h8000_1400, resp_data);
        assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_2400),
                     "Next miss after squashed refill is not squashed");

        // 14b: flush held through the refill response and into IDLE
        execute_req_flush(32'h8000_1800, 2, 12, resp_data);
        assert_issue(5, resp_data == 32'h0000_0013,
                     "Refill response squashed (flush held past response)");
        clear_axi_monitor();
        execute_req(32'h8000_1C00, resp_data);
        assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_2C00),
                     "Next miss after held flush is not squashed");

        $display("\n========================================================");
        $display(" ISSUE-FIX SUMMARY (PASS = problem is corrected)");
        $display("========================================================");
        $display("  [ISSUE 1] fence_i_req held internally until done   : %0s (pass=%0d fail=%0d)",
                 (issue_fail[1] == 0 && issue_pass[1] > 0) ? "PASS" : "FAIL", issue_pass[1], issue_fail[1]);
        $display("  [ISSUE 2] no FENCE.I re-run while req stays high   : %0s (pass=%0d fail=%0d)",
                 (issue_fail[2] == 0 && issue_pass[2] > 0) ? "PASS" : "FAIL", issue_pass[2], issue_fail[2]);
        $display("  [ISSUE 3] IDLE cpu_flush released immediately      : %0s (pass=%0d fail=%0d)",
                 (issue_fail[3] == 0 && issue_pass[3] > 0) ? "PASS" : "FAIL", issue_pass[3], issue_fail[3]);
        $display("  [ISSUE 4] hit-time cpu_flush released at response  : %0s (pass=%0d fail=%0d)",
                 (issue_fail[4] == 0 && issue_pass[4] > 0) ? "PASS" : "FAIL", issue_pass[4], issue_fail[4]);
        $display("  [ISSUE 5] no stale flush squashing the next miss   : %0s (pass=%0d fail=%0d)",
                 (issue_fail[5] == 0 && issue_pass[5] > 0) ? "PASS" : "FAIL", issue_pass[5], issue_fail[5]);

        $display("\n========================================================");
        $display("SIMULATION FINISHED");
        $display("PASS: %0d", test_pass_count);
        $display("FAIL: %0d", test_fail_count);
        $display("========================================================");

        if (test_fail_count == 0)
            $display(">>> ALL TEST CASES PASSED SUCCESSFULLY! <<<");
        else
            $display(">>> SIMULATION FAILED WITH ERRORS! <<<");

        $finish;
    end

endmodule