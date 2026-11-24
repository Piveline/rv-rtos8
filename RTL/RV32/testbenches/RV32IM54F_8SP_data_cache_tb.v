`timescale 1ns / 1ps

`include "./modules/Dummy_DDR_Memory.v"

/*
 * Core + Data Cache integration testbench
 * - RV32IM54F8SP core with the data cache on the DDR region (0x8000_0000 ~)
 * - DDR side, 128KB window at 0x8000_0000, chosen per round
 *   round 0, 1 : TB AXI4 slave model with random latency
 *   round 2    : DummyDDRMemory (synthesizable stand-in, fixed 60-cycle read / write latency)
 * - Hit timing : the same program on DataMemory (BRAM) and on the D-Cache must take the
 *   same number of cycles, except the cycles the core was frozen by misses
 * - AXI error handling
 *   round 0, 1 : RLAST on the wrong beat (early / missing) from the TB model
 *   round 2    : SLVERR from DummyDDRMemory error mode (refill error, write-back error)
 * - Programs are assembled with llvm-mc (rv32im) and loaded into the instruction memory
 * - Each program ends with a store to DONE_ADDR, then registers / DDR contents are checked
 */
module RV32IM54F_8SP_data_cache_tb;
    parameter XLEN = 32;

    localparam [XLEN-1:0] DONE_ADDR = 32'h1001_0000;
    localparam integer TIMEOUT = 20000;
    localparam [31:0] HALT = 32'h0000_006F; // jal x0, 0
    localparam integer DUMMY_READ_LATENCY = 60;
    localparam integer DUMMY_WRITE_LATENCY = 60;

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
    wire m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    wire m_axi_wready;
    wire [1:0] m_axi_bresp;
    wire m_axi_bvalid;
    wire m_axi_bready;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid;
    wire m_axi_arready;
    wire [63:0] m_axi_rdata;
    wire [1:0] m_axi_rresp;
    wire m_axi_rlast;
    wire m_axi_rvalid;
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
    // DDR side select : TB model (random latency) or DummyDDRMemory (fixed latency)
    // ------------------------------------------------------------------------
    reg use_dummy_ddr;

    reg model_awready;
    reg model_wready;
    reg [1:0] model_bresp;
    reg model_bvalid;
    reg model_arready;
    reg [63:0] model_rdata;
    reg [1:0] model_rresp;
    reg model_rlast;
    reg [1:0] model_rlast_mode; // 0 : normal, 1 : RLAST on beat 1, 2 : RLAST never asserted
    reg model_rvalid;
    wire model_awvalid = m_axi_awvalid && !use_dummy_ddr;
    wire model_arvalid = m_axi_arvalid && !use_dummy_ddr;

    wire dummy_awready;
    wire dummy_wready;
    wire [1:0] dummy_bresp;
    wire dummy_bvalid;
    wire dummy_arready;
    wire [63:0] dummy_rdata;
    wire [1:0] dummy_rresp;
    wire dummy_rlast;
    wire dummy_rvalid;

    DummyDDRMemory #(
        .ADDRESS_WIDTH(14),
        .READ_LATENCY(DUMMY_READ_LATENCY),
        .WRITE_LATENCY(DUMMY_WRITE_LATENCY),
        .ERROR_ENABLE(1),
        .ERROR_ADDRESS_MASK(32'hFFFF_F000),
        .READ_ERROR_ADDRESS(32'h8001_F000),
        .WRITE_ERROR_ADDRESS(32'h8001_E000)
    ) dummy_ddr_memory (
        .clk(clk),
        .reset(reset),
        .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen),
        .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),
        .s_axi_awvalid(m_axi_awvalid && use_dummy_ddr),
        .s_axi_awready(dummy_awready),
        .s_axi_wdata(m_axi_wdata),
        .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),
        .s_axi_wvalid(m_axi_wvalid && use_dummy_ddr),
        .s_axi_wready(dummy_wready),
        .s_axi_bresp(dummy_bresp),
        .s_axi_bvalid(dummy_bvalid),
        .s_axi_bready(m_axi_bready && use_dummy_ddr),
        .s_axi_araddr(m_axi_araddr),
        .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arvalid(m_axi_arvalid && use_dummy_ddr),
        .s_axi_arready(dummy_arready),
        .s_axi_rdata(dummy_rdata),
        .s_axi_rresp(dummy_rresp),
        .s_axi_rlast(dummy_rlast),
        .s_axi_rvalid(dummy_rvalid),
        .s_axi_rready(m_axi_rready && use_dummy_ddr)
    );

    assign m_axi_awready = use_dummy_ddr ? dummy_awready : model_awready;
    assign m_axi_wready = use_dummy_ddr ? dummy_wready : model_wready;
    assign m_axi_bresp = use_dummy_ddr ? dummy_bresp : model_bresp;
    assign m_axi_bvalid = use_dummy_ddr ? dummy_bvalid : model_bvalid;
    assign m_axi_arready = use_dummy_ddr ? dummy_arready : model_arready;
    assign m_axi_rdata = use_dummy_ddr ? dummy_rdata : model_rdata;
    assign m_axi_rresp = use_dummy_ddr ? dummy_rresp : model_rresp;
    assign m_axi_rlast = use_dummy_ddr ? dummy_rlast : model_rlast;
    assign m_axi_rvalid = use_dummy_ddr ? dummy_rvalid : model_rvalid;

    // DummyDDRMemory latency check (cycles counted from the handshake edge)
    integer read_latency_start;
    integer write_latency_start;
    integer read_latency_error;
    integer write_latency_error;
    integer read_latency_seen;
    integer write_latency_seen;
    integer read_latency_count;
    integer write_latency_count;
    reg read_first_beat;
    integer cycle_now;

    always @(posedge clk) begin
        if (reset) begin
            cycle_now = 0;
            read_first_beat = 1'b0;
        end
        else begin
            cycle_now = cycle_now + 1;
            if (use_dummy_ddr) begin
                if (m_axi_arvalid && m_axi_arready) begin
                    read_latency_start = cycle_now;
                    read_first_beat = 1'b1;
                end
                else if (read_first_beat && m_axi_rvalid) begin
                    read_first_beat = 1'b0;
                    read_latency_seen = cycle_now - read_latency_start;
                    read_latency_count = read_latency_count + 1;
                    if (read_latency_seen != DUMMY_READ_LATENCY)
                        read_latency_error = read_latency_error + 1;
                end
                if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                    write_latency_start = cycle_now;
                else if (m_axi_bvalid && m_axi_bready) begin
                    write_latency_seen = cycle_now - write_latency_start;
                    write_latency_count = write_latency_count + 1;
                    if (write_latency_seen != DUMMY_WRITE_LATENCY)
                        write_latency_error = write_latency_error + 1;
                end
            end
        end
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
                dummy_ddr_memory.memory[i] = {a + 32'd4, a};
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
            w = use_dummy_ddr ? dummy_ddr_memory.memory[a[16:3]] : ddr[a[16:3]];
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

    function model_rlast_at(input integer beat);
        begin
            case (model_rlast_mode)
                2'd1: model_rlast_at = (beat == 1) || (beat == r_len);
                2'd2: model_rlast_at = 1'b0;
                default: model_rlast_at = (beat == r_len);
            endcase
        end
    endfunction

    // D-Cache error responses seen by the core (cpu_error rises once per failed access)
    integer cache_error_count;
    reg cache_error_d;

    always @(posedge clk) begin
        if (reset)
            cache_error_d <= 1'b0;
        else begin
            cache_error_d <= rv32im54f_8sp.data_cache_cpu_error;
            if (rv32im54f_8sp.data_cache_cpu_error && !cache_error_d)
                cache_error_count = cache_error_count + 1;
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
            model_arready <= 1'b0;
            model_rvalid <= 1'b0;
            model_rlast <= 1'b0;
            model_rresp <= 2'b00;
            model_rdata <= 64'h0;
            ar_busy <= 1'b0;
            r_beat <= 0;
            r_wait <= 0;
            ar_wait <= 0;
        end
        else begin
            if (model_arvalid && model_arready) begin
                model_arready <= 1'b0;
                ar_busy <= 1'b1;
                r_addr <= m_axi_araddr;
                r_len <= m_axi_arlen;
                r_beat <= 0;
                r_wait <= ($random & 7) + 2;
            end
            else if (!ar_busy && model_arvalid) begin
                if (ar_wait == 0) begin
                    model_arready <= 1'b1;
                    ar_wait <= $random & 3;
                end
                else
                    ar_wait <= ar_wait - 1;
            end
            if (ar_busy) begin
                if (model_rvalid && m_axi_rready) begin
                    if (model_rlast || r_beat == r_len) begin
                        model_rvalid <= 1'b0;
                        model_rlast <= 1'b0;
                        ar_busy <= 1'b0;
                    end
                    else begin
                        r_beat <= r_beat + 1;
                        if (($random & 1) == 0) begin
                            model_rdata <= ddr[(r_addr[16:3] + r_beat + 1) & 14'h3FFF];
                            model_rlast <= model_rlast_at(r_beat + 1);
                        end
                        else begin
                            model_rvalid <= 1'b0;
                            r_wait <= $random & 3;
                        end
                    end
                end
                else if (!model_rvalid) begin
                    if (r_wait == 0) begin
                        model_rvalid <= 1'b1;
                        model_rdata <= ddr[(r_addr[16:3] + r_beat) & 14'h3FFF];
                        model_rlast <= model_rlast_at(r_beat);
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
            model_awready <= 1'b0;
            model_wready <= 1'b0;
            model_bvalid <= 1'b0;
            model_bresp <= 2'b00;
            aw_busy <= 1'b0;
            b_pend <= 1'b0;
            w_beat <= 0;
            b_wait <= 0;
            aw_wait <= 0;
            write_outstanding <= 1'b0;
        end
        else begin
            if (model_awvalid && model_awready) begin
                model_awready <= 1'b0;
                aw_busy <= 1'b1;
                w_addr <= m_axi_awaddr;
                w_len <= m_axi_awlen;
                w_beat <= 0;
                write_outstanding <= 1'b1;
            end
            else if (!aw_busy && !b_pend && model_awvalid) begin
                if (aw_wait == 0) begin
                    model_awready <= 1'b1;
                    aw_wait <= $random & 3;
                end
                else
                    aw_wait <= aw_wait - 1;
            end
            if (m_axi_wvalid && model_wready) begin
                ddr[(w_addr[16:3] + w_beat) & 14'h3FFF] <= merge8(ddr[(w_addr[16:3] + w_beat) & 14'h3FFF], m_axi_wdata, m_axi_wstrb);
                if (m_axi_wlast != (w_beat == w_len)) begin
                    $display("[FAIL-AXI] WLAST mismatch at beat %0d (len %0d)", w_beat, w_len);
                    fail_count = fail_count + 1;
                end
                w_beat <= w_beat + 1;
                model_wready <= 1'b0;
                if (m_axi_wlast) begin
                    aw_busy <= 1'b0;
                    b_pend <= 1'b1;
                    b_wait <= $random & 7;
                end
            end
            else
                model_wready <= aw_busy && (($random & 3) != 0);
            if (model_bvalid && m_axi_bready) begin
                model_bvalid <= 1'b0;
                b_pend <= 1'b0;
                write_outstanding <= 1'b0;
            end
            else if (b_pend && !model_bvalid) begin
                if (b_wait == 0)
                    model_bvalid <= 1'b1;
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


    task load_burst;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80003537; // 0004: lui a0, 0x80003
            rv32im54f_8sp.instruction_memory.data[2] = 32'h01c52603; // 0008: lw a2, 0x1c(a0)
            rv32im54f_8sp.instruction_memory.data[3] = 32'h00852683; // 000c: lw a3, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[4] = 32'h01452703; // 0010: lw a4, 0x14(a0)
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00052783; // 0014: lw a5, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h800035b7; // 0018: lui a1, 0x80003
            rv32im54f_8sp.instruction_memory.data[7] = 32'h40058593; // 001c: addi a1, a1, 0x400
            rv32im54f_8sp.instruction_memory.data[8] = 32'h01100293; // 0020: addi t0, zero, 0x11
            rv32im54f_8sp.instruction_memory.data[9] = 32'h0055a023; // 0024: sw t0, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h02200293; // 0028: addi t0, zero, 0x22
            rv32im54f_8sp.instruction_memory.data[11] = 32'h0055a623; // 002c: sw t0, 0xc(a1)
            rv32im54f_8sp.instruction_memory.data[12] = 32'h03300293; // 0030: addi t0, zero, 0x33
            rv32im54f_8sp.instruction_memory.data[13] = 32'h0055a823; // 0034: sw t0, 0x10(a1)
            rv32im54f_8sp.instruction_memory.data[14] = 32'h04400293; // 0038: addi t0, zero, 0x44
            rv32im54f_8sp.instruction_memory.data[15] = 32'h0055ae23; // 003c: sw t0, 0x1c(a1)
            rv32im54f_8sp.instruction_memory.data[16] = 32'h80007337; // 0040: lui t1, 0x80007
            rv32im54f_8sp.instruction_memory.data[17] = 32'h40030313; // 0044: addi t1, t1, 0x400
            rv32im54f_8sp.instruction_memory.data[18] = 32'h00032383; // 0048: lw t2, 0x0(t1)
            rv32im54f_8sp.instruction_memory.data[19] = 32'h8000b337; // 004c: lui t1, 0x8000b
            rv32im54f_8sp.instruction_memory.data[20] = 32'h40030313; // 0050: addi t1, t1, 0x400
            rv32im54f_8sp.instruction_memory.data[21] = 32'h00032383; // 0054: lw t2, 0x0(t1)
            rv32im54f_8sp.instruction_memory.data[22] = 32'h0005aa03; // 0058: lw s4, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[23] = 32'h00c5aa83; // 005c: lw s5, 0xc(a1)
            rv32im54f_8sp.instruction_memory.data[24] = 32'h0105ab03; // 0060: lw s6, 0x10(a1)
            rv32im54f_8sp.instruction_memory.data[25] = 32'h01c5ab83; // 0064: lw s7, 0x1c(a1)
            rv32im54f_8sp.instruction_memory.data[26] = 32'h0045ac03; // 0068: lw s8, 0x4(a1)
            rv32im54f_8sp.instruction_memory.data[27] = 32'h000fa023; // 006c: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[28] = 32'h0000006f; // 0070: jal zero, 0x70 <_start+0x70>
        end
    endtask

    task load_axierr;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h8001f537; // 0004: lui a0, 0x8001f
            rv32im54f_8sp.instruction_memory.data[2] = 32'h00052603; // 0008: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[3] = 32'h00052683; // 000c: lw a3, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[4] = 32'h800005b7; // 0010: lui a1, 0x80000
            rv32im54f_8sp.instruction_memory.data[5] = 32'h10058593; // 0014: addi a1, a1, 0x100
            rv32im54f_8sp.instruction_memory.data[6] = 32'h0005a703; // 0018: lw a4, 0x0(a1)
            rv32im54f_8sp.instruction_memory.data[7] = 32'h8001e2b7; // 001c: lui t0, 0x8001e
            rv32im54f_8sp.instruction_memory.data[8] = 32'h05a00313; // 0020: addi t1, zero, 0x5a
            rv32im54f_8sp.instruction_memory.data[9] = 32'h0062a023; // 0024: sw t1, 0x0(t0)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h8001a3b7; // 0028: lui t2, 0x8001a
            rv32im54f_8sp.instruction_memory.data[11] = 32'h0003a783; // 002c: lw a5, 0x0(t2)
            rv32im54f_8sp.instruction_memory.data[12] = 32'h800163b7; // 0030: lui t2, 0x80016
            rv32im54f_8sp.instruction_memory.data[13] = 32'h0003a803; // 0034: lw a6, 0x0(t2)
            rv32im54f_8sp.instruction_memory.data[14] = 32'h0002a883; // 0038: lw a7, 0x0(t0)
            rv32im54f_8sp.instruction_memory.data[15] = 32'h000fa023; // 003c: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[16] = 32'h0000006f; // 0040: jal zero, 0x40 <_start+0x40>
        end
    endtask

    task load_rlast;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80007537; // 0004: lui a0, 0x80007
            rv32im54f_8sp.instruction_memory.data[2] = 32'h00052603; // 0008: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[3] = 32'h02052683; // 000c: lw a3, 0x20(a0)
            rv32im54f_8sp.instruction_memory.data[4] = 32'h800005b7; // 0010: lui a1, 0x80000
            rv32im54f_8sp.instruction_memory.data[5] = 32'h10058593; // 0014: addi a1, a1, 0x100
            rv32im54f_8sp.instruction_memory.data[6] = 32'h000fa023; // 0018: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[7] = 32'h0000006f; // 001c: jal zero, 0x1c <_start+0x1c>
        end
    endtask

    task load_hit_ddr;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80004537; // 0004: lui a0, 0x80004
            rv32im54f_8sp.instruction_memory.data[2] = 32'hb0002a73; // 0008: csrrs s4, mcycle, zero
            rv32im54f_8sp.instruction_memory.data[3] = 32'h01100293; // 000c: addi t0, zero, 0x11
            rv32im54f_8sp.instruction_memory.data[4] = 32'h00552023; // 0010: sw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00052603; // 0014: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h02200293; // 0018: addi t0, zero, 0x22
            rv32im54f_8sp.instruction_memory.data[7] = 32'h03300313; // 001c: addi t1, zero, 0x33
            rv32im54f_8sp.instruction_memory.data[8] = 32'h00552423; // 0020: sw t0, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h00652423; // 0024: sw t1, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h00852683; // 0028: lw a3, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[11] = 32'h0aa00293; // 002c: addi t0, zero, 0xaa
            rv32im54f_8sp.instruction_memory.data[12] = 32'h005500a3; // 0030: sb t0, 0x1(a0)
            rv32im54f_8sp.instruction_memory.data[13] = 32'h00052703; // 0034: lw a4, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[14] = 32'h01400393; // 0038: addi t2, zero, 0x14
            rv32im54f_8sp.instruction_memory.data[15] = 32'h00000793; // 003c: addi a5, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[16] = 32'h00052283; // 0040: lw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[17] = 32'h005787b3; // 0044: add a5, a5, t0
            rv32im54f_8sp.instruction_memory.data[18] = 32'h00852303; // 0048: lw t1, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[19] = 32'h00530833; // 004c: add a6, t1, t0
            rv32im54f_8sp.instruction_memory.data[20] = 32'hfff38393; // 0050: addi t2, t2, -0x1
            rv32im54f_8sp.instruction_memory.data[21] = 32'hfe0396e3; // 0054: bne t2, zero, 0x40 <_start+0x40>
            rv32im54f_8sp.instruction_memory.data[22] = 32'hb0002af3; // 0058: csrrs s5, mcycle, zero
            rv32im54f_8sp.instruction_memory.data[23] = 32'h000fa023; // 005c: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[24] = 32'h0000006f; // 0060: jal zero, 0x60 <_start+0x60>
        end
    endtask

    task load_hit_bram;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h10000537; // 0004: lui a0, 0x10000
            rv32im54f_8sp.instruction_memory.data[2] = 32'hb0002a73; // 0008: csrrs s4, mcycle, zero
            rv32im54f_8sp.instruction_memory.data[3] = 32'h01100293; // 000c: addi t0, zero, 0x11
            rv32im54f_8sp.instruction_memory.data[4] = 32'h00552023; // 0010: sw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[5] = 32'h00052603; // 0014: lw a2, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h02200293; // 0018: addi t0, zero, 0x22
            rv32im54f_8sp.instruction_memory.data[7] = 32'h03300313; // 001c: addi t1, zero, 0x33
            rv32im54f_8sp.instruction_memory.data[8] = 32'h00552423; // 0020: sw t0, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h00652423; // 0024: sw t1, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[10] = 32'h00852683; // 0028: lw a3, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[11] = 32'h0aa00293; // 002c: addi t0, zero, 0xaa
            rv32im54f_8sp.instruction_memory.data[12] = 32'h005500a3; // 0030: sb t0, 0x1(a0)
            rv32im54f_8sp.instruction_memory.data[13] = 32'h00052703; // 0034: lw a4, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[14] = 32'h01400393; // 0038: addi t2, zero, 0x14
            rv32im54f_8sp.instruction_memory.data[15] = 32'h00000793; // 003c: addi a5, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[16] = 32'h00052283; // 0040: lw t0, 0x0(a0)
            rv32im54f_8sp.instruction_memory.data[17] = 32'h005787b3; // 0044: add a5, a5, t0
            rv32im54f_8sp.instruction_memory.data[18] = 32'h00852303; // 0048: lw t1, 0x8(a0)
            rv32im54f_8sp.instruction_memory.data[19] = 32'h00530833; // 004c: add a6, t1, t0
            rv32im54f_8sp.instruction_memory.data[20] = 32'hfff38393; // 0050: addi t2, t2, -0x1
            rv32im54f_8sp.instruction_memory.data[21] = 32'hfe0396e3; // 0054: bne t2, zero, 0x40 <_start+0x40>
            rv32im54f_8sp.instruction_memory.data[22] = 32'hb0002af3; // 0058: csrrs s5, mcycle, zero
            rv32im54f_8sp.instruction_memory.data[23] = 32'h000fa023; // 005c: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[24] = 32'h0000006f; // 0060: jal zero, 0x60 <_start+0x60>
        end
    endtask

    task load_hold;
        begin
            clear_imem;
            rv32im54f_8sp.instruction_memory.data[0] = 32'h10010fb7; // 0000: lui t6, 0x10010
            rv32im54f_8sp.instruction_memory.data[1] = 32'h80004537; // 0004: lui a0, 0x80004
            rv32im54f_8sp.instruction_memory.data[2] = 32'h07700293; // 0008: addi t0, zero, 0x77
            rv32im54f_8sp.instruction_memory.data[3] = 32'h04552423; // 000c: sw t0, 0x48(a0)
            rv32im54f_8sp.instruction_memory.data[4] = 32'h05500293; // 0010: addi t0, zero, 0x55
            rv32im54f_8sp.instruction_memory.data[5] = 32'h04552623; // 0014: sw t0, 0x4c(a0)
            rv32im54f_8sp.instruction_memory.data[6] = 32'h00700313; // 0018: addi t1, zero, 0x7
            rv32im54f_8sp.instruction_memory.data[7] = 32'h00300393; // 001c: addi t2, zero, 0x3
            rv32im54f_8sp.instruction_memory.data[8] = 32'h04852603; // 0020: lw a2, 0x48(a0)
            rv32im54f_8sp.instruction_memory.data[9] = 32'h00000013; // 0024: addi zero, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[10] = 32'h027346b3; // 0028: div a3, t1, t2
            rv32im54f_8sp.instruction_memory.data[11] = 32'h00d60733; // 002c: add a4, a2, a3
            rv32im54f_8sp.instruction_memory.data[12] = 32'h04c52783; // 0030: lw a5, 0x4c(a0)
            rv32im54f_8sp.instruction_memory.data[13] = 32'h00000013; // 0034: addi zero, zero, 0x0
            rv32im54f_8sp.instruction_memory.data[14] = 32'h02730833; // 0038: mul a6, t1, t2
            rv32im54f_8sp.instruction_memory.data[15] = 32'h010788b3; // 003c: add a7, a5, a6
            rv32im54f_8sp.instruction_memory.data[16] = 32'h000fa023; // 0040: sw zero, 0x0(t6)
            rv32im54f_8sp.instruction_memory.data[17] = 32'h0000006f; // 0044: jal zero, 0x44 <_start+0x44>
        end
    endtask

    // ------------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------------
    integer round;
    integer errors0;
    integer bram_cycles;
    integer bram_mcycle;
    integer ddr_stall;
    integer ar0;
    integer aw0;

    initial begin
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        ar_count = 0;
        aw_count = 0;
        use_dummy_ddr = 1'b0;
        model_rlast_mode = 2'd0;
        cache_error_count = 0;
        read_latency_error = 0;
        write_latency_error = 0;
        read_latency_count = 0;
        write_latency_count = 0;
        read_latency_seen = 0;
        write_latency_seen = 0;
        reset = 1'b1;

        // Instruction_Memory loads its firmware image at time 0; overwrite after
        #1;

        $display("============================================");
        $display(" RV32IM54F_8SP + Data Cache Integration Testbench");
        $display("============================================");

        for (round = 0; round < 3; round = round + 1) begin
            use_dummy_ddr = (round == 2);
            if (use_dummy_ddr)
                $display("[TB] ---- round %0d (DummyDDRMemory, read %0d / write %0d cycles) ----",
                    round, DUMMY_READ_LATENCY, DUMMY_WRITE_LATENCY);
            else
                $display("[TB] ---- round %0d (TB AXI model, random latency) ----", round);
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

            $display("[TB] 9. every beat of a refill / write-back burst lands on the right word");
            load_burst;
            run_program("burst");
            check_reg("burst", 12, 32'h8000_301C);
            check_reg("burst", 13, 32'h8000_3008);
            check_reg("burst", 14, 32'h8000_3014);
            check_reg("burst", 15, 32'h8000_3000);
            check_reg("burst", 20, 32'h11);
            check_reg("burst", 21, 32'h22);
            check_reg("burst", 22, 32'h33);
            check_reg("burst", 23, 32'h44);
            check_reg("burst", 24, 32'h8000_3404);
            check_ddr("burst", 32'h8000_3400, 32'h11);
            check_ddr("burst", 32'h8000_340C, 32'h22);
            check_ddr("burst", 32'h8000_3410, 32'h33);
            check_ddr("burst", 32'h8000_341C, 32'h44);

            $display("[TB] 10. hit timing : D$ hits cost no extra cycle compared with DataMemory (BRAM)");
            load_hit_bram;
            run_program("hit bram");
            bram_cycles = cycles;
            bram_mcycle = rv32im54f_8sp.register_file.registers[21] - rv32im54f_8sp.register_file.registers[20];
            load_hit_ddr;
            run_program("hit ddr");
            ddr_stall = rv32im54f_8sp.data_cache_perf_stall;
            check_reg("hit ddr", 12, 32'h0000_0011);
            check_reg("hit ddr", 13, 32'h0000_0033);
            check_reg("hit ddr", 14, 32'h0000_AA11);
            check_reg("hit ddr", 15, 32'h000D_4954);
            check_reg("hit ddr", 16, 32'h0000_AA44);
            check_value("hit ddr", "D$ misses", 1, rv32im54f_8sp.data_cache_perf_miss);
            check_value("hit ddr", "cycles - miss stall", bram_cycles, cycles - ddr_stall);
            check_value("hit ddr", "mcycle - miss stall", bram_mcycle,
                rv32im54f_8sp.register_file.registers[21] - rv32im54f_8sp.register_file.registers[20] - ddr_stall);

            $display("[TB] 10-2. load hit kept in MEM while div / mul stall the pipeline");
            load_hold;
            run_program("hold");
            check_reg("hold", 12, 32'h0000_0077);
            check_reg("hold", 14, 32'h0000_0079);
            check_reg("hold", 15, 32'h0000_0055);
            check_reg("hold", 17, 32'h0000_006A);

            if (!use_dummy_ddr) begin
                $display("[TB] 11. RLAST on the wrong beat : refill ends, error reported, core does not hang");
                load_rlast;
                model_rlast_mode = 2'd1;
                errors0 = cache_error_count;
                run_program("rlast early");
                check_value("rlast early", "D$ errors", 2, cache_error_count - errors0);
                model_rlast_mode = 2'd2;
                errors0 = cache_error_count;
                run_program("rlast missing");
                check_value("rlast missing", "D$ errors", 2, cache_error_count - errors0);
                check_value("rlast missing", "D$ misses", 2, rv32im54f_8sp.data_cache_perf_miss);
                model_rlast_mode = 2'd0;
            end
            else begin
                $display("[TB] 11. SLVERR : refill error line is dropped, write-back error keeps the dirty line");
                errors0 = cache_error_count;
                load_axierr;
                run_program("axierr");
                check_value("axierr", "D$ errors", 3, cache_error_count - errors0);
                check_value("axierr", "D$ misses", 6, rv32im54f_8sp.data_cache_perf_miss);
                check_reg("axierr", 14, 32'h8000_0100);
                check_reg("axierr", 15, 32'h8001_A000);
                check_reg("axierr", 17, 32'h0000_005A);
                check_ddr("axierr", 32'h8001_E000, 32'h8001_E000);
            end
        end

        $display("[TB] 12. DummyDDRMemory latency (measured on every burst of round 2)");
        check_value("dummy", "read bursts seen", 1, read_latency_count > 0);
        check_value("dummy", "write bursts seen", 1, write_latency_count > 0);
        check_value("dummy", "read latency errors", 0, read_latency_error);
        check_value("dummy", "write latency errors", 0, write_latency_error);
        $display("[TB] DummyDDRMemory: %0d read bursts (last %0d cycles), %0d write bursts (last %0d cycles)",
            read_latency_count, read_latency_seen, write_latency_count, write_latency_seen);

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
