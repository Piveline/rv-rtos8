`timescale 1ns / 1ps

/*
 * Core + Data Cache integration testbench
 * - RV32IM54F8SP core with the data cache on the DDR region (0x8000_0000 ~)
 * - AXI4 slave DDR model with random latency (128KB window at 0x8000_0000)
 * - Programs are assembled with llvm-mc (rv32im) and loaded into the instruction memory
 * - Each program ends with a store to DONE_ADDR, then registers / DDR contents are checked
 */
module RV32IM54F_8SP_data_cache_tb;
    parameter XLEN = 32;

    localparam [XLEN-1:0] DONE_ADDR = 32'h1001_0000;
    localparam integer TIMEOUT = 20000;
    localparam [31:0] HALT = 32'h0000_006F; // jal x0, 0

    reg clk;
    reg reset;

    wire [31:0] retire_instruction;
    wire [XLEN-1:0] MMIO_data_memory_write_data;
    wire [XLEN-1:0] MMIO_data_memory_address;
    wire MMIO_data_memory_write_enable;

    // AXI
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid;
    reg m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    reg m_axi_wready;
    reg [1:0] m_axi_bresp;
    reg m_axi_bvalid;
    wire m_axi_bready;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid;
    reg m_axi_arready;
    reg [63:0] m_axi_rdata;
    reg [1:0] m_axi_rresp;
    reg m_axi_rlast;
    reg m_axi_rvalid;
    wire m_axi_rready;

    integer test_count;
    integer pass_count;
    integer fail_count;
    integer i;
    integer cycles;
    reg done;

    RV32IM54F8SP #(
        .XLEN(XLEN)
    ) rv32im54f_8sp (
        .clk(clk),
        .clk_enable(1'b1),
        .reset(reset),
        .UART_busy(1'b0),
        .timer_interrupt_pending(1'b0),
        .MMIO_read_data({XLEN{1'b0}}),
        .data_cache_m_axi_awready(m_axi_awready),
        .data_cache_m_axi_wready(m_axi_wready),
        .data_cache_m_axi_bresp(m_axi_bresp),
        .data_cache_m_axi_bvalid(m_axi_bvalid),
        .data_cache_m_axi_arready(m_axi_arready),
        .data_cache_m_axi_rdata(m_axi_rdata),
        .data_cache_m_axi_rresp(m_axi_rresp),
        .data_cache_m_axi_rlast(m_axi_rlast),
        .data_cache_m_axi_rvalid(m_axi_rvalid),
        .retire_instruction(retire_instruction),
        .MMIO_data_memory_write_data(MMIO_data_memory_write_data),
        .MMIO_data_memory_address(MMIO_data_memory_address),
        .MMIO_data_memory_write_enable(MMIO_data_memory_write_enable),
        .data_cache_m_axi_awaddr(m_axi_awaddr),
        .data_cache_m_axi_awlen(m_axi_awlen),
        .data_cache_m_axi_awsize(m_axi_awsize),
        .data_cache_m_axi_awburst(m_axi_awburst),
        .data_cache_m_axi_awvalid(m_axi_awvalid),
        .data_cache_m_axi_wdata(m_axi_wdata),
        .data_cache_m_axi_wstrb(m_axi_wstrb),
        .data_cache_m_axi_wlast(m_axi_wlast),
        .data_cache_m_axi_wvalid(m_axi_wvalid),
        .data_cache_m_axi_bready(m_axi_bready),
        .data_cache_m_axi_araddr(m_axi_araddr),
        .data_cache_m_axi_arlen(m_axi_arlen),
        .data_cache_m_axi_arsize(m_axi_arsize),
        .data_cache_m_axi_arburst(m_axi_arburst),
        .data_cache_m_axi_arvalid(m_axi_arvalid),
        .data_cache_m_axi_rready(m_axi_rready)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Every program ends with a store to DONE_ADDR
    always @(posedge clk) begin
        if (reset)
            done <= 1'b0;
        else if (MMIO_data_memory_write_enable && MMIO_data_memory_address == DONE_ADDR)
            done <= 1'b1;
    end

    // ------------------------------------------------------------------------
    // DDR model : 128KB at 0x8000_0000, initial 32-bit word at address A is A
    // ------------------------------------------------------------------------
    reg [63:0] ddr [0:16383];

    task init_ddr;
        reg [31:0] a;
        begin
            for (i = 0; i < 16384; i = i + 1) begin
                a = 32'h8000_0000 + i * 8;
                ddr[i] = {a + 32'd4, a};
            end
        end
    endtask

    function [63:0] merge8(input [63:0] o, input [63:0] n, input [7:0] s);
        integer b;
        begin
            merge8 = o;
            for (b = 0; b < 8; b = b + 1)
                if (s[b])
                    merge8[b*8 +: 8] = n[b*8 +: 8];
        end
    endfunction

    function [31:0] ddr_word(input [31:0] a);
        reg [63:0] w;
        begin
            w = ddr[a[16:3]];
            ddr_word = a[2] ? w[63:32] : w[31:0];
        end
    endfunction

    // AXI protocol monitor
    reg write_outstanding;
    integer ar_count;
    integer aw_count;

    always @(posedge clk) begin
        if (!reset) begin
            if (m_axi_arvalid && m_axi_arready) begin
                ar_count = ar_count + 1;
                if (m_axi_araddr[31:17] != 15'h4000) begin
                    $display("[FAIL-AXI] ARADDR out of the DDR window: %h", m_axi_araddr);
                    fail_count = fail_count + 1;
                end
                if (write_outstanding) begin
                    $display("[FAIL-AXI] AR issued before BRESP of the previous write");
                    fail_count = fail_count + 1;
                end
            end
            if (m_axi_awvalid && m_axi_awready) begin
                aw_count = aw_count + 1;
                if (m_axi_awaddr[31:17] != 15'h4000) begin
                    $display("[FAIL-AXI] AWADDR out of the DDR window: %h", m_axi_awaddr);
                    fail_count = fail_count + 1;
                end
            end
        end
    end

    // AXI slave : read channel (random latency)
    reg ar_busy;
    reg [31:0] r_addr;
    reg [7:0] r_len;
    integer r_beat;
    integer r_wait;
    integer ar_wait;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid <= 1'b0;
            m_axi_rlast <= 1'b0;
            m_axi_rresp <= 2'b00;
            m_axi_rdata <= 64'h0;
            ar_busy <= 1'b0;
            r_beat <= 0;
            r_wait <= 0;
            ar_wait <= 0;
        end
        else begin
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_arready <= 1'b0;
                ar_busy <= 1'b1;
                r_addr <= m_axi_araddr;
                r_len <= m_axi_arlen;
                r_beat <= 0;
                r_wait <= ($random & 7) + 2;
            end
            else if (!ar_busy && m_axi_arvalid) begin
                if (ar_wait == 0) begin
                    m_axi_arready <= 1'b1;
                    ar_wait <= $random & 3;
                end
                else
                    ar_wait <= ar_wait - 1;
            end
            if (ar_busy) begin
                if (m_axi_rvalid && m_axi_rready) begin
                    if (m_axi_rlast) begin
                        m_axi_rvalid <= 1'b0;
                        m_axi_rlast <= 1'b0;
                        ar_busy <= 1'b0;
                    end
                    else begin
                        r_beat <= r_beat + 1;
                        if (($random & 1) == 0) begin
                            m_axi_rdata <= ddr[(r_addr[16:3] + r_beat + 1) & 14'h3FFF];
                            m_axi_rlast <= (r_beat + 1 == r_len);
                        end
                        else begin
                            m_axi_rvalid <= 1'b0;
                            r_wait <= $random & 3;
                        end
                    end
                end
                else if (!m_axi_rvalid) begin
                    if (r_wait == 0) begin
                        m_axi_rvalid <= 1'b1;
                        m_axi_rdata <= ddr[(r_addr[16:3] + r_beat) & 14'h3FFF];
                        m_axi_rlast <= (r_beat == r_len);
                    end
                    else
                        r_wait <= r_wait - 1;
                end
            end
        end
    end

    // AXI slave : write channel (random latency)
    reg aw_busy;
    reg b_pend;
    reg [31:0] w_addr;
    reg [7:0] w_len;
    integer w_beat;
    integer b_wait;
    integer aw_wait;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            m_axi_awready <= 1'b0;
            m_axi_wready <= 1'b0;
            m_axi_bvalid <= 1'b0;
            m_axi_bresp <= 2'b00;
            aw_busy <= 1'b0;
            b_pend <= 1'b0;
            w_beat <= 0;
            b_wait <= 0;
            aw_wait <= 0;
            write_outstanding <= 1'b0;
        end
        else begin
            if (m_axi_awvalid && m_axi_awready) begin
                m_axi_awready <= 1'b0;
                aw_busy <= 1'b1;
                w_addr <= m_axi_awaddr;
                w_len <= m_axi_awlen;
                w_beat <= 0;
                write_outstanding <= 1'b1;
            end
            else if (!aw_busy && !b_pend && m_axi_awvalid) begin
                if (aw_wait == 0) begin
                    m_axi_awready <= 1'b1;
                    aw_wait <= $random & 3;
                end
                else
                    aw_wait <= aw_wait - 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                ddr[(w_addr[16:3] + w_beat) & 14'h3FFF] <= merge8(ddr[(w_addr[16:3] + w_beat) & 14'h3FFF], m_axi_wdata, m_axi_wstrb);
                if (m_axi_wlast != (w_beat == w_len)) begin
                    $display("[FAIL-AXI] WLAST mismatch at beat %0d (len %0d)", w_beat, w_len);
                    fail_count = fail_count + 1;
                end
                w_beat <= w_beat + 1;
                m_axi_wready <= 1'b0;
                if (m_axi_wlast) begin
                    aw_busy <= 1'b0;
                    b_pend <= 1'b1;
                    b_wait <= $random & 7;
                end
            end
            else
                m_axi_wready <= aw_busy && (($random & 3) != 0);
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                b_pend <= 1'b0;
                write_outstanding <= 1'b0;
            end
            else if (b_pend && !m_axi_bvalid) begin
                if (b_wait == 0)
                    m_axi_bvalid <= 1'b1;
                else
                    b_wait <= b_wait - 1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    task clear_imem;
        begin
            for (i = 0; i < 1024; i = i + 1)
                rv32im54f_8sp.instruction_memory.data[i] = HALT;
            for (i = 0; i < 32; i = i + 1)
                rv32im54f_8sp.register_file.registers[i] = {XLEN{1'b0}};
        end
    endtask

    task run_program;
        input [8*24-1:0] name;
        begin
            reset = 1'b1;
            repeat (5) @(posedge clk);
            #1;
            reset = 1'b0;

            cycles = 0;
            while (!done && cycles < TIMEOUT) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            repeat (10) @(posedge clk);
            #1;

            if (!done) begin
                test_count = test_count + 1;
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: program end | expected: store to 0x%h | actual: timeout after %0d cycles",
                    test_count, name, DONE_ADDR, TIMEOUT);
            end
            else
                $display("[TB] %0s finished in %0d cycles (D$ access %0d, miss %0d, wb %0d)",
                    name, cycles, rv32im54f_8sp.data_cache_perf_access, rv32im54f_8sp.data_cache_perf_miss,
                    rv32im54f_8sp.data_cache_perf_wb);
        end
    endtask

    task check_reg;
        input [8*24-1:0] name;
        input integer rd;
        input [XLEN-1:0] expected;
        reg [XLEN-1:0] actual;
        begin
            actual = rv32im54f_8sp.register_file.registers[rd];
            test_count = test_count + 1;
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %0s | test: x%0d | expected: 0x%h | actual: 0x%h",
                    test_count, name, rd, expected, actual);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: x%0d | expected: 0x%h | actual: 0x%h",
                    test_count, name, rd, expected, actual);
            end
        end
    endtask

    task check_value;
        input [8*24-1:0] name;
        input [8*24-1:0] what;
        input integer expected;
        input integer actual;
        begin
            test_count = test_count + 1;
            if (actual == expected) begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %0s | test: %0s | expected: %0d | actual: %0d",
                    test_count, name, what, expected, actual);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: %0s | expected: %0d | actual: %0d",
                    test_count, name, what, expected, actual);
            end
        end
    endtask

    task check_ddr;
        input [8*24-1:0] name;
        input [31:0] addr;
        input [31:0] expected;
        reg [31:0] actual;
        begin
            actual = ddr_word(addr);
            test_count = test_count + 1;
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %0s | test: DDR[%h] | expected: 0x%h | actual: 0x%h",
                    test_count, name, addr, expected, actual);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: DDR[%h] | expected: 0x%h | actual: 0x%h",
                    test_count, name, addr, expected, actual);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Test programs (llvm-mc -triple=riscv32 -mattr=+m)
    // ------------------------------------------------------------------------
    task load_basic;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80000537; // 0004: lui a0, 0x80000
            rv32im54f_8sp.instruction_memory.data[2] = 32'h123455b7; // 0008: lui a1, 0x12345
            rv32im54f_8sp.instruction_memory.data[3] = 32'h67858593; // 000c: addi a1, a1, 0x678
            rv32im54f_8sp.instruction_memory.data[4] = 32'h00b52023; // 0010: sw a1, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00052603; // 0014: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h00452683; // 0018: lw a3, 0x4(a0)
            rv32im54f_8sp.instruction_memory.data[7] = 32'h00d60733; // 001c: add a4, a2, a3
            rv32im54f_8sp.instruction_memory.data[8] = 32'h000fa023; // 0020: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h0000006f; // 0024: jal zero, 0x24 <_start+0x24>
        end
    endtask

    task load_bytes;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80000537; // 0004: lui a0, 0x80000
            rv32im54f_8sp.instruction_memory.data[2] = 32'h10050513; // 0008: addi a0, a0, 0x100
            rv32im54f_8sp.instruction_memory.data[3] = 32'h112235b7; // 000c: lui a1, 0x11223
            rv32im54f_8sp.instruction_memory.data[4] = 32'h34458593; // 0010: addi a1, a1, 0x344
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00b52023; // 0014: sw a1, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h0aa00293; // 0018: addi t0, zero, 0xaa
            rv32im54f_8sp.instruction_memory.data[7] = 32'h005500a3; // 001c: sb t0, 0x1(a0)
            rv32im54f_8sp.instruction_memory.data[8] = 32'h0000c2b7; // 0020: lui t0, 0xc
            rv32im54f_8sp.instruction_memory.data[9] = 32'heef28293; // 0024: addi t0, t0, -0x111
            rv32im54f_8sp.instruction_memory.data[10] = 32'h00551123; // 0028: sh t0, 0x2(a0)
            rv32im54f_8sp.instruction_memory.data[11] = 32'h00052603; // 002c: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[12] = 32'h00150683; // 0030: lb a3, 0x1(a0)
            rv32im54f_8sp.instruction_memory.data[13] = 32'h00154703; // 0034: lbu a4, 0x1(a0)
            rv32im54f_8sp.instruction_memory.data[14] = 32'h00251783; // 0038: lh a5, 0x2(a0)
            rv32im54f_8sp.instruction_memory.data[15] = 32'h00255803; // 003c: lhu a6, 0x2(a0)
            rv32im54f_8sp.instruction_memory.data[16] = 32'h00452883; // 0040: lw a7, 0x4(a0)
            rv32im54f_8sp.instruction_memory.data[17] = 32'h000fa023; // 0044: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[18] = 32'h0000006f; // 0048: jal zero, 0x48 <_start+0x48>
        end
    endtask

    task load_evict;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80000537; // 0004: lui a0, 0x80000
            rv32im54f_8sp.instruction_memory.data[2] = 32'h20050513; // 0008: addi a0, a0, 0x200
            rv32im54f_8sp.instruction_memory.data[3] = 32'h800045b7; // 000c: lui a1, 0x80004
            rv32im54f_8sp.instruction_memory.data[4] = 32'h20058593; // 0010: addi a1, a1, 0x200
            rv32im54f_8sp.instruction_memory.data[5] = 32'h80008637; // 0014: lui a2, 0x80008
            rv32im54f_8sp.instruction_memory.data[6] = 32'h20060613; // 0018: addi a2, a2, 0x200
            rv32im54f_8sp.instruction_memory.data[7] = 32'h06f00293; // 001c: addi t0, zero, 0x6f
            rv32im54f_8sp.instruction_memory.data[8] = 32'h00552023; // 0020: sw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h0de00293; // 0024: addi t0, zero, 0xde
            rv32im54f_8sp.instruction_memory.data[10] = 32'h0055a023; // 0028: sw t0, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[11] = 32'h14d00293; // 002c: addi t0, zero, 0x14d
            rv32im54f_8sp.instruction_memory.data[12] = 32'h00562023; // 0030: sw t0, 0x0(a2)
            rv32im54f_8sp.instruction_memory.data[13] = 32'h00052a03; // 0034: lw s4, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[14] = 32'h0005aa83; // 0038: lw s5, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[15] = 32'h00062b03; // 003c: lw s6, 0x0(a2)
            rv32im54f_8sp.instruction_memory.data[16] = 32'h000fa023; // 0040: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[17] = 32'h0000006f; // 0044: jal zero, 0x44 <_start+0x44>
        end
    endtask

    task load_loop;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80001537; // 0004: lui a0, 0x80001
            rv32im54f_8sp.instruction_memory.data[2] = 32'h00000313; // 0008: addi t1, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[3] = 32'h01000393; // 000c: addi t2, zero, 0x10
            rv32im54f_8sp.instruction_memory.data[4] = 32'h00050413; // 0010: addi s0, a0, 0x0
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00131493; // 0014: slli s1, t1, 0x1
            rv32im54f_8sp.instruction_memory.data[6] = 32'h006484b3; // 0018: add s1, s1, t1
            rv32im54f_8sp.instruction_memory.data[7] = 32'h00942023; // 001c: sw s1, 0x0(s0)
            rv32im54f_8sp.instruction_memory.data[8] = 32'h00440413; // 0020: addi s0, s0, 0x4
            rv32im54f_8sp.instruction_memory.data[9] = 32'h00130313; // 0024: addi t1, t1, 0x1
            rv32im54f_8sp.instruction_memory.data[10] = 32'hfe7346e3; // 0028: blt t1, t2, 0x14 <st>
            rv32im54f_8sp.instruction_memory.data[11] = 32'h00000313; // 002c: addi t1, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[12] = 32'h00000a13; // 0030: addi s4, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[13] = 32'h00050413; // 0034: addi s0, a0, 0x0
            rv32im54f_8sp.instruction_memory.data[14] = 32'h00042483; // 0038: lw s1, 0x0(s0)
            rv32im54f_8sp.instruction_memory.data[15] = 32'h009a0a33; // 003c: add s4, s4, s1
            rv32im54f_8sp.instruction_memory.data[16] = 32'h00440413; // 0040: addi s0, s0, 0x4
            rv32im54f_8sp.instruction_memory.data[17] = 32'h00130313; // 0044: addi t1, t1, 0x1
            rv32im54f_8sp.instruction_memory.data[18] = 32'hfe7348e3; // 0048: blt t1, t2, 0x38 <ld>
            rv32im54f_8sp.instruction_memory.data[19] = 32'h000fa023; // 004c: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[20] = 32'h0000006f; // 0050: jal zero, 0x50 <ld+0x18>
        end
    endtask

    task load_mixed;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h10000537; // 0004: lui a0, 0x10000
            rv32im54f_8sp.instruction_memory.data[2] = 32'h04050513; // 0008: addi a0, a0, 0x40
            rv32im54f_8sp.instruction_memory.data[3] = 32'h800025b7; // 000c: lui a1, 0x80002
            rv32im54f_8sp.instruction_memory.data[4] = 32'h05500293; // 0010: addi t0, zero, 0x55
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00552023; // 0014: sw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h06600313; // 0018: addi t1, zero, 0x66
            rv32im54f_8sp.instruction_memory.data[7] = 32'h0065a023; // 001c: sw t1, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[8] = 32'h00052a03; // 0020: lw s4, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h0005aa83; // 0024: lw s5, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h00052b03; // 0028: lw s6, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[11] = 32'h000fa023; // 002c: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[12] = 32'h0000006f; // 0030: jal zero, 0x30 <_start+0x30>
        end
    endtask

    task load_chase;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80003537; // 0004: lui a0, 0x80003
            rv32im54f_8sp.instruction_memory.data[2] = 32'h10050513; // 0008: addi a0, a0, 0x100
            rv32im54f_8sp.instruction_memory.data[3] = 32'h800055b7; // 000c: lui a1, 0x80005
            rv32im54f_8sp.instruction_memory.data[4] = 32'h00b52023; // 0010: sw a1, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00052603; // 0014: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h00062683; // 0018: lw a3, 0x0(a2)
            rv32im54f_8sp.instruction_memory.data[7] = 32'h00068733; // 001c: add a4, a3, zero
            rv32im54f_8sp.instruction_memory.data[8] = 32'h000fa023; // 0020: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h0000006f; // 0024: jal zero, 0x24 <_start+0x24>
        end
    endtask

    task load_muldiv;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80006537; // 0004: lui a0, 0x80006
            rv32im54f_8sp.instruction_memory.data[2] = 32'h00700293; // 0008: addi t0, zero, 0x7
            rv32im54f_8sp.instruction_memory.data[3] = 32'h00552023; // 000c: sw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[4] = 32'h00052303; // 0010: lw t1, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[5] = 32'h026303b3; // 0014: mul t2, t1, t1
            rv32im54f_8sp.instruction_memory.data[6] = 32'h0263c433; // 0018: div s0, t2, t1
            rv32im54f_8sp.instruction_memory.data[7] = 32'h00852223; // 001c: sw s0, 0x4(a0)
            rv32im54f_8sp.instruction_memory.data[8] = 32'h00452483; // 0020: lw s1, 0x4(a0)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h000fa023; // 0024: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h0000006f; // 0028: jal zero, 0x28 <_start+0x28>
        end
    endtask


    task load_edge;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'ha0000537; // 0004: lui a0, 0xa0000
            rv32im54f_8sp.instruction_memory.data[2] = 32'h800005b7; // 0008: lui a1, 0x80000
            rv32im54f_8sp.instruction_memory.data[3] = 32'hff058593; // 000c: addi a1, a1, -0x10
            rv32im54f_8sp.instruction_memory.data[4] = 32'h07700293; // 0010: addi t0, zero, 0x77
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00552023; // 0014: sw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h0055a023; // 0018: sw t0, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[7] = 32'h00052a03; // 001c: lw s4, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[8] = 32'h0005aa83; // 0020: lw s5, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h000fa023; // 0024: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h0000006f; // 0028: jal zero, 0x28 <_start+0x28>
        end
    endtask


    // ------------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------------
    integer round;
    integer ar0;
    integer aw0;

    initial begin
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        ar_count = 0;
        aw_count = 0;
        reset = 1'b1;

        // Instruction_Memory loads its firmware image at time 0; overwrite after
        #1;

        $display("============================================");
        $display(" RV32IM54F_8SP + Data Cache Integration Testbench");
        $display("============================================");

        for (round = 0; round < 2; round = round + 1) begin
            $display("[TB] ---- round %0d (random AXI latency) ----", round);
            init_ddr;

            $display("[TB] 1. sw/lw to DDR, refill neighbor, load-use");
            load_basic;
            run_program("basic");
            check_reg("basic", 12, 32'h1234_5678);
            check_reg("basic", 13, 32'h8000_0004);
            check_reg("basic", 14, 32'h9234_567C);

            $display("[TB] 2. sb/sh merge, lb/lbu/lh/lhu sign handling");
            load_bytes;
            run_program("bytes");
            check_reg("bytes", 12, 32'hBEEF_AA44);
            check_reg("bytes", 13, 32'hFFFF_FFAA);
            check_reg("bytes", 14, 32'h0000_00AA);
            check_reg("bytes", 15, 32'hFFFF_BEEF);
            check_reg("bytes", 16, 32'h0000_BEEF);
            check_reg("bytes", 17, 32'h8000_0104);

            $display("[TB] 3. dirty eviction (3 tags on one set) and write-back to DDR");
            load_evict;
            run_program("evict");
            check_reg("evict", 20, 32'd111);
            check_reg("evict", 21, 32'd222);
            check_reg("evict", 22, 32'd333);
            check_ddr("evict", 32'h8000_0200, 32'd111);

            $display("[TB] 4. store / load loops with branches");
            load_loop;
            run_program("loop");
            check_reg("loop", 20, 32'd360);

            $display("[TB] 5. DataMemory (0x1000_xxxx) and DDR mixed");
            load_mixed;
            run_program("mixed");
            check_reg("mixed", 20, 32'h55);
            check_reg("mixed", 21, 32'h66);
            check_reg("mixed", 22, 32'h55);
            check_ddr("mixed", 32'h8000_2000, 32'h8000_2000);

            $display("[TB] 6. loaded value used as the next load address");
            load_chase;
            run_program("chase");
            check_reg("chase", 12, 32'h8000_5000);
            check_reg("chase", 13, 32'h8000_5000);
            check_reg("chase", 14, 32'h8000_5000);

            $display("[TB] 7. DDR load feeding mul/div, result stored back");
            load_muldiv;
            run_program("muldiv");
            check_reg("muldiv", 7, 32'd49);
            check_reg("muldiv", 8, 32'd7);
            check_reg("muldiv", 9, 32'd7);

            $display("[TB] 8. addresses just outside the DDR window do not use the cache");
            ar0 = ar_count;
            aw0 = aw_count;
            load_edge;
            run_program("edge");
            check_value("edge", "D$ accesses", 0, rv32im54f_8sp.data_cache_perf_access);
            check_value("edge", "AXI transactions", 0, (ar_count - ar0) + (aw_count - aw0));
        end

        $display("[TB] AXI transactions: AR %0d, AW %0d", ar_count, aw_count);
        $display("============================================");
        $display(" PASS: %0d  FAIL: %0d", pass_count, fail_count);
        $display("============================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL-TIMEOUT] global timeout");
        $finish;
    end

endmodule
