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