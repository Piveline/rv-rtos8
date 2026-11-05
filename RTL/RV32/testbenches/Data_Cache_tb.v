`timescale 1ns / 1ps

/*
 * Testbench for DataCache
 * - AXI4 slave memory model with random latency (AR/R/AW/W/B)
 * - Shadow memory (golden model) : every LOAD is compared against it
 * - Directed tests + random test, then full memory compare after INVAL
 * - Parameters : -PDataCache_tb.NSETS=16 -PDataCache_tb.TB_CACHE_EN=0
 */
module DataCache_tb;

    parameter NSETS = 512;
    parameter TB_CACHE_EN = 1;
    parameter RAND_OPS = 10000;
    localparam IB = $clog2(NSETS);

    reg clk;
    reg reset;
    reg clk_enable;

    always #5 clk = ~clk;

    // CPU side
    reg cpu_req_valid;
    reg cpu_req_we;
    reg [31:0] cpu_req_addr;
    reg [31:0] cpu_req_wdata;
    reg [3:0] cpu_req_wstrb;
    wire [31:0] cpu_rdata;
    wire cpu_ready;
    reg fence_i_req;
    wire fence_i_done;
    reg inval_req;
    wire inval_done;
    reg perf_clear;
    wire [31:0] perf_access, perf_miss, perf_wb, perf_stall;

    // AXI
    wire [31:0] m_axi_awaddr; wire [7:0] m_axi_awlen; wire [2:0] m_axi_awsize; wire [1:0] m_axi_awburst;
    wire m_axi_awvalid; reg m_axi_awready;
    wire [63:0] m_axi_wdata; wire [7:0] m_axi_wstrb; wire m_axi_wlast;
    wire m_axi_wvalid; reg m_axi_wready;
    reg [1:0] m_axi_bresp; reg m_axi_bvalid; wire m_axi_bready;
    wire [31:0] m_axi_araddr; wire [7:0] m_axi_arlen; wire [2:0] m_axi_arsize; wire [1:0] m_axi_arburst;
    wire m_axi_arvalid; reg m_axi_arready;
    reg [63:0] m_axi_rdata; reg [1:0] m_axi_rresp; reg m_axi_rlast;
    reg m_axi_rvalid; wire m_axi_rready;

    DataCache #(.NUM_SETS(NSETS), .CACHE_EN(TB_CACHE_EN)) data_cache (
        .clk(clk), .reset(reset), .clk_enable(clk_enable),
        .cpu_req_valid(cpu_req_valid), .cpu_req_we(cpu_req_we), .cpu_req_addr(cpu_req_addr),
        .cpu_req_wdata(cpu_req_wdata), .cpu_req_wstrb(cpu_req_wstrb),
        .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .fence_i_req(fence_i_req), .fence_i_done(fence_i_done),
        .inval_req(inval_req), .inval_done(inval_done),
        .perf_clear(perf_clear), .perf_access(perf_access), .perf_miss(perf_miss),
        .perf_wb(perf_wb), .perf_stall(perf_stall),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    integer pass_count;
    integer fail_count;

    // ------------------------------------------------------------
    // Memory model : DDR window 0x8000_0000 + 512KB, uncached window 0x1000_0000 + 64KB
    // ------------------------------------------------------------
    reg [63:0] mem_c [0:65535];
    reg [63:0] mem_u [0:8191];
    reg [63:0] sh_c [0:65535]; // shadow (golden)
    reg [63:0] sh_u [0:8191];

    function [63:0] mem_rd(input [31:0] a);
        begin
            if (a[31]) mem_rd = mem_c[a[18:3]];
            else mem_rd = mem_u[a[15:3]];
        end
    endfunction

    function [63:0] merge8(input [63:0] o, input [63:0] n, input [7:0] s);
        integer b;
        begin
            merge8 = o;
            for (b = 0; b < 8; b = b + 1) if (s[b]) merge8[b*8 +: 8] = n[b*8 +: 8];
        end
    endfunction

    // ------------------------------------------------------------
    // AXI protocol monitor
    // ------------------------------------------------------------
    integer ar_count, aw_count;
    reg [7:0] last_arlen;

    always @(posedge clk) begin
        if (!reset) begin
            if (m_axi_arvalid && m_axi_arready) begin
                ar_count = ar_count + 1;
                last_arlen = m_axi_arlen;
                if (m_axi_arsize != 3'b011 || m_axi_arburst != 2'b01) begin
                    $display("[FAIL-AXI] ARSIZE/ARBURST wrong"); fail_count = fail_count + 1;
                end
                if (m_axi_arlen == 8'd3 && m_axi_araddr[4:0] != 0) begin
                    $display("[FAIL-AXI] burst ARADDR not 32B aligned: %h", m_axi_araddr); fail_count = fail_count + 1;
                end
                if (m_axi_arlen != 8'd3 && m_axi_arlen != 8'd0) begin
                    $display("[FAIL-AXI] unexpected ARLEN %d", m_axi_arlen); fail_count = fail_count + 1;
                end
            end
            if (m_axi_awvalid && m_axi_awready) begin
                aw_count = aw_count + 1;
                if (m_axi_awlen == 8'd3 && m_axi_awaddr[4:0] != 0) begin
                    $display("[FAIL-AXI] burst AWADDR not 32B aligned: %h", m_axi_awaddr); fail_count = fail_count + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // AXI slave : read channel (random latency)
    // ------------------------------------------------------------
    reg ar_busy;
    reg [31:0] r_addr;
    reg [7:0] r_len;
    integer r_beat, r_wait, ar_wait;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            m_axi_arready <= 1'b0; m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0; m_axi_rresp <= 2'b00;
            ar_busy <= 1'b0; r_beat <= 0; r_wait <= 0; ar_wait <= 0;
        end else begin
            // AR
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_arready <= 1'b0;
                ar_busy <= 1'b1; r_addr <= m_axi_araddr; r_len <= m_axi_arlen;
                r_beat <= 0; r_wait <= ($random & 3) + 1;
            end else if (!ar_busy && m_axi_arvalid) begin
                if (ar_wait == 0) begin m_axi_arready <= 1'b1; ar_wait <= $random & 3; end
                else ar_wait <= ar_wait - 1;
            end
            // R
            if (ar_busy) begin
                if (m_axi_rvalid && m_axi_rready) begin
                    if (m_axi_rlast) begin
                        m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0; ar_busy <= 1'b0;
                    end else begin
                        r_beat <= r_beat + 1;
                        if (($random & 1) == 0) begin // back-to-back beat
                            m_axi_rdata <= mem_rd(r_addr + 8*(r_beat+1));
                            m_axi_rlast <= (r_beat + 1 == r_len);
                        end else begin // insert gap
                            m_axi_rvalid <= 1'b0; r_wait <= ($random & 3);
                        end
                    end
                end else if (!m_axi_rvalid) begin
                    if (r_wait == 0) begin
                        m_axi_rvalid <= 1'b1;
                        m_axi_rdata <= mem_rd(r_addr + 8*r_beat);
                        m_axi_rlast <= (r_beat == r_len);
                    end else r_wait <= r_wait - 1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // AXI slave : write channel (random latency)
    // ------------------------------------------------------------
    reg aw_busy, b_pend;
    reg [31:0] w_addr, wa;
    reg [7:0] w_len;
    integer w_beat, b_wait, aw_wait;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            m_axi_awready <= 1'b0; m_axi_wready <= 1'b0; m_axi_bvalid <= 1'b0; m_axi_bresp <= 2'b00;
            aw_busy <= 1'b0; b_pend <= 1'b0; w_beat <= 0; b_wait <= 0; aw_wait <= 0;
        end else begin
            // AW
            if (m_axi_awvalid && m_axi_awready) begin
                m_axi_awready <= 1'b0;
                aw_busy <= 1'b1; w_addr <= m_axi_awaddr; w_len <= m_axi_awlen; w_beat <= 0;
            end else if (!aw_busy && !b_pend && m_axi_awvalid) begin
                if (aw_wait == 0) begin m_axi_awready <= 1'b1; aw_wait <= $random & 3; end
                else aw_wait <= aw_wait - 1;
            end
            // W
            if (m_axi_wvalid && m_axi_wready) begin
                wa = w_addr + 8*w_beat;
                if (wa[31]) mem_c[wa[18:3]] <= merge8(mem_c[wa[18:3]], m_axi_wdata, m_axi_wstrb);
                else mem_u[wa[15:3]] <= merge8(mem_u[wa[15:3]], m_axi_wdata, m_axi_wstrb);
                if (m_axi_wlast != (w_beat == w_len)) begin
                    $display("[FAIL-AXI] WLAST mismatch at beat %0d (len %0d)", w_beat, w_len); fail_count = fail_count + 1;
                end
                w_beat <= w_beat + 1;
                m_axi_wready <= 1'b0;
                if (m_axi_wlast) begin
                    aw_busy <= 1'b0; b_pend <= 1'b1; b_wait <= ($random & 7);
                end
            end else begin
                m_axi_wready <= aw_busy && (($random & 3) != 0);
            end
            // B
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0; b_pend <= 1'b0;
            end else if (b_pend && !m_axi_bvalid) begin
                if (b_wait == 0) m_axi_bvalid <= 1'b1;
                else b_wait <= b_wait - 1;
            end
        end
    end

    // ------------------------------------------------------------
    // CPU tasks
    // ------------------------------------------------------------
    function [31:0] mk_addr(input integer tag, input integer set, input integer off);
        mk_addr = 32'h8000_0000 | (tag << (5 + IB)) | (set << 5) | off;
    endfunction

    task wait_ready;
        integer tout;
        begin
            tout = 0;
            while (!cpu_ready && tout < 2000) begin @(negedge clk); tout = tout + 1; end
            if (tout >= 2000) begin
                $display("[FAIL-TIMEOUT] cpu_ready never asserted (addr %h)", cpu_req_addr);
                fail_count = fail_count + 1;
                $finish;
            end
        end
    endtask

    task do_req(input we, input [31:0] addr, input [31:0] wdata, input [3:0] wstrb, output [31:0] rdata);
        begin
            @(negedge clk);
            cpu_req_valid = 1'b1; cpu_req_we = we; cpu_req_addr = addr;
            cpu_req_wdata = wdata; cpu_req_wstrb = wstrb;
            @(negedge clk);
            wait_ready;
            rdata = cpu_rdata;
            cpu_req_valid = 1'b0; cpu_req_we = 1'b0;
            @(negedge clk);
            if (cpu_ready) begin
                $display("[FAIL-PROTOCOL] cpu_ready longer than 1 cycle (addr %h)", addr);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_load(input [31:0] addr, output ok);
        reg [31:0] rd, exp;
        reg [63:0] w;
        begin
            do_req(1'b0, addr, 32'h0, 4'h0, rd);
            w = addr[31] ? sh_c[addr[18:3]] : sh_u[addr[15:3]];
            exp = addr[2] ? w[63:32] : w[31:0];
            ok = (rd === exp);
            if (!ok) begin
                $display("[FAIL-DATA] LOAD %h : got %h exp %h", addr, rd, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_store(input [31:0] addr, input [31:0] wdata, input [3:0] wstrb);
        reg [31:0] rd;
        reg [7:0] s8;
        begin
            do_req(1'b1, addr, wdata, wstrb, rd);
            s8 = addr[2] ? {wstrb, 4'h0} : {4'h0, wstrb};
            if (addr[31]) sh_c[addr[18:3]] = merge8(sh_c[addr[18:3]], {wdata, wdata}, s8);
            else sh_u[addr[15:3]] = merge8(sh_u[addr[15:3]], {wdata, wdata}, s8);
        end
    endtask

    task do_maint(input inval); // inval=0 : FENCE.I (CLEAN), inval=1 : cold flush
        integer tout, width;
        begin
            @(negedge clk);
            if (inval) inval_req = 1'b1; else fence_i_req = 1'b1;
            tout = 0;
            while (!(inval ? inval_done : fence_i_done) && tout < 200000) begin @(negedge clk); tout = tout + 1; end
            if (tout >= 200000) begin
                $display("[FAIL-TIMEOUT] %s done never asserted", inval ? "INVAL" : "FENCE.I");
                fail_count = fail_count + 1; $finish;
            end
            // done must be a 1-cycle pulse; requester keeps req level until it sees done
            @(negedge clk);
            if (inval ? inval_done : fence_i_done) begin
                $display("[FAIL-PROTOCOL] done pulse longer than 1 cycle"); fail_count = fail_count + 1;
            end
            inval_req = 1'b0; fence_i_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task check_mem_vs_shadow(input [511:0] msg);
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < 65536; k = k + 1) if (mem_c[k] !== sh_c[k]) bad = bad + 1;
            for (k = 0; k < 8192; k = k + 1) if (mem_u[k] !== sh_u[k]) bad = bad + 1;
            check(bad == 0, msg);
            if (bad != 0) $display(" (%0d words differ)", bad);
        end
    endtask

    task check(input cond, input [511:0] msg);
        begin
            if (cond) begin pass_count = pass_count + 1; $display(" -> [PASS] %0s", msg); end
            else begin fail_count = fail_count + 1; $display(" -> [FAIL] %0s", msg); end
        end
    endtask

    // ------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------
    integer k, n, miss0, wb0, ar0, aw0, acc0;
    integer op, rtag, rset, roff;
    reg ok, all_ok;
    reg [31:0] A, B, C, rd;

    initial begin
        clk = 0; reset = 1; clk_enable = 1;
        cpu_req_valid = 0; cpu_req_we = 0; cpu_req_addr = 0; cpu_req_wdata = 0; cpu_req_wstrb = 0;
        fence_i_req = 0; inval_req = 0; perf_clear = 0;
        pass_count = 0; fail_count = 0; ar_count = 0; aw_count = 0;
        for (k = 0; k < 65536; k = k + 1) begin mem_c[k] = {$random, $random}; sh_c[k] = mem_c[k]; end
        for (k = 0; k < 8192; k = k + 1) begin mem_u[k] = {$random, $random}; sh_u[k] = mem_u[k]; end

        $display("========================================================");
        $display(" DataCache testbench NUM_SETS=%0d CACHE_EN=%0d", NSETS, TB_CACHE_EN);
        $display("========================================================");
        repeat (5) @(negedge clk);
        reset = 0;
        repeat (2) @(negedge clk);

        if (TB_CACHE_EN) begin
            // -------- TEST 1 : load miss -> hit --------
            $display("\n[TEST 1] LOAD miss then hit");
            A = mk_addr(1, 3, 12);
            miss0 = perf_miss; ar0 = ar_count;
            do_load(A, ok); check(ok, "miss returns correct data");
            check(perf_miss == miss0 + 1 && ar_count == ar0 + 1 && last_arlen == 3, "miss issued one 4-beat burst");
            ar0 = ar_count; miss0 = perf_miss;
            do_load(A, ok); check(ok && perf_miss == miss0 && ar_count == ar0, "second access hits (no AXI)");
            do_load(A + 16, ok); check(ok && ar_count == ar0, "other word in same line hits");

            // -------- TEST 2 : store hit --------
            $display("\n[TEST 2] STORE hit -> dirty, read back");
            ar0 = ar_count; aw0 = aw_count;
            do_store(A, 32'hCAFE_BABE, 4'hF);
            do_load(A, ok); check(ok, "read back stored word");
            check(ar_count == ar0 && aw_count == aw0, "store hit generated no AXI traffic (write-back)");
            check(mem_c[A[18:3]] !== sh_c[A[18:3]], "memory still old (dirty only in cache)");

            // -------- TEST 3 : store miss (write-allocate) --------
            $display("\n[TEST 3] STORE miss -> write-allocate");
            B = mk_addr(2, 7, 4);
            ar0 = ar_count; miss0 = perf_miss;
            do_store(B, 32'h1234_5678, 4'hF);
            check(ar_count == ar0 + 1 && perf_miss == miss0 + 1, "store miss refilled the line");
            ar0 = ar_count;
            do_load(B, ok); check(ok && ar_count == ar0, "stored word hits after allocate");
            do_load(B - 4, ok); check(ok, "neighbor word from refill is correct");

            // -------- TEST 4 : byte / half stores --------
            $display("\n[TEST 4] Byte / halfword stores");
            all_ok = 1;
            do_store(B, 32'h0000_00AA, 4'b0001);
            do_store(B, 32'h0000_BB00, 4'b0010);
            do_store(B, 32'hDDCC_0000, 4'b1100);
            do_load(B, ok); all_ok = all_ok & ok;
            do_store(B + 2, 32'h7788_0000, 4'b1100);
            do_load(B, ok); all_ok = all_ok & ok;
            check(all_ok, "partial writes merge correctly");

            // -------- TEST 5 : dirty eviction -> write-back --------
            $display("\n[TEST 5] Dirty eviction -> write-back");
            // set 3 : A (tag 1, dirty) already there. Fill tag 4, then tag 5 evicts LRU
            wb0 = perf_wb; aw0 = aw_count;
            do_load(mk_addr(4, 3, 0), ok); // way 2 of set 3 ; A becomes LRU
            do_load(mk_addr(5, 3, 0), ok); // evicts A (dirty)
            check(perf_wb == wb0 + 1 && aw_count == aw0 + 1, "exactly one write-back burst");
            check(mem_c[A[18:3]] === sh_c[A[18:3]], "evicted dirty data reached memory");
            do_load(A, ok); check(ok, "re-load of evicted line returns stored data");

            // -------- TEST 6 : LRU --------
            $display("\n[TEST 6] LRU replacement");
            n = 9;
            do_load(mk_addr(1, n, 0), ok);
            do_load(mk_addr(2, n, 0), ok);
            do_load(mk_addr(1, n, 0), ok); // tag1 = MRU, tag2 = LRU
            do_load(mk_addr(3, n, 0), ok); // evicts tag2
            miss0 = perf_miss;
            do_load(mk_addr(1, n, 0), ok);
            check(perf_miss == miss0, "MRU line survived");
            do_load(mk_addr(2, n, 0), ok);
            check(perf_miss == miss0 + 1, "LRU line was evicted");

            // -------- TEST 7 : uncached access --------
            $display("\n[TEST 7] Uncached (non-DDR) single access");
            C = 32'h1000_0040;
            ar0 = ar_count; acc0 = perf_access;
            do_load(C, ok); check(ok && last_arlen == 0, "uncached load uses single beat (ARLEN=0)");
            do_load(C, ok); check(ar_count == ar0 + 2 && perf_access == acc0, "uncached load is never cached");
            aw0 = aw_count;
            do_store(C + 4, 32'h5555_AAAA, 4'b0110);
            check(aw_count == aw0 + 1 && mem_u[C[15:3]] === sh_u[C[15:3]], "uncached store written through");

            // -------- TEST 8 : FENCE.I (CLEAN) --------
            $display("\n[TEST 8] FENCE.I : write back dirty, keep valid");
            do_store(mk_addr(6, 20, 8), 32'hFEED_0001, 4'hF);
            do_store(mk_addr(6, 21, 8), 32'hFEED_0002, 4'hF);
            do_maint(1'b0);
            check_mem_vs_shadow("all dirty data in memory after FENCE.I");
            miss0 = perf_miss;
            do_load(mk_addr(6, 20, 8), ok);
            check(ok && perf_miss == miss0, "line still valid after FENCE.I (hit)");
            wb0 = perf_wb;
            do_maint(1'b0);
            check(perf_wb == wb0, "second FENCE.I has nothing to write back");

            // -------- TEST 9 : INVAL (cold flush) --------
            $display("\n[TEST 9] INVAL : write back + invalidate all");
            do_store(mk_addr(7, 30, 0), 32'h0BAD_F00D, 4'hF);
            do_maint(1'b1);
            check_mem_vs_shadow("dirty data in memory after INVAL");
            miss0 = perf_miss;
            do_load(mk_addr(7, 30, 0), ok);
            check(ok && perf_miss == miss0 + 1, "line invalid after INVAL (miss)");
        end

        // -------- TEST 10 : random --------
        $display("\n[TEST 10] Random %0d operations (conflict-heavy)", RAND_OPS);
        all_ok = 1;
        for (k = 0; k < RAND_OPS; k = k + 1) begin
            op = $random & 15;
            rtag = $random & 7;
            rset = $random & 7;
            roff = ($random & 7) * 4;
            A = mk_addr(rtag, rset, roff);
            if (op == 15) do_maint(1'b0);
            else if (op == 14) begin
                if (($random & 3) == 0) do_maint(1'b1);
                else do_load(32'h1000_0000 | (($random & 255) * 4), ok);
            end
            else if (op < 7) begin do_load(A, ok); all_ok = all_ok & ok; end
            else begin
                n = $random & 15; if (n == 0) n = 15;
                do_store(A, $random, n[3:0]);
            end
        end
        check(all_ok, "all random loads matched shadow memory");
        do_maint(1'b1);
        check_mem_vs_shadow("memory equals shadow after final INVAL");

        $display("\n perf: access=%0d miss=%0d wb=%0d stall=%0d", perf_access, perf_miss, perf_wb, perf_stall);
        $display("\n========================================================");
        $display(" SIMULATION FINISHED PASS: %0d FAIL: %0d", pass_count, fail_count);
        $display("========================================================");
        if (fail_count == 0) $display(">>> ALL TEST CASES PASSED SUCCESSFULLY! <<<");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("[FAIL-TIMEOUT] global timeout"); $finish;
    end

endmodule
