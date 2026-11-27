`timescale 1ns / 1ps

// Timer-IRQ testbench (I-Cache integration, plan T4).
// The IRQ is raised after N core cycles for N = N_MIN..N_MAX (in the cached build that edge
// may be inside an instruction cache miss stall). Two levels of checking:
//
// 1. Self-check (every build, PASS/FAIL + non-zero exit on failure): each run must finish,
//    take the handler exactly once (x20 = 1) and record an mepc inside the interrupted
//    nop window 0x1c..0xe0 (x21).
// 2. Differential: the same file can also be built against the original (non-cached) core;
//    one line "R first=<core cycle the IRQ was first visible> ..." per run is printed, and for
//    every first-seen key present in both builds, (done, core cycles, x20, x21) must be identical.
//
// Run from RTL/RV32:
//   iverilog -DHAS_ICACHE -o irq.vvp modules/RV32IM54F_8SP.v testbenches/RV32IM54F_8SP_irq_tb.v
//   vvp -n irq.vvp
// PROGRAM_BASE works as in RV32IM54F_8SP_core_tb (0x8000_1000 runs the program from DDR
// through the I-Cache); x21 is printed as mepc - PROGRAM_BASE so ROM and DDR runs compare.

`ifdef HAS_ICACHE
`include "./modules/Dummy_DDR_Memory.v"
`endif

module RV32IM54F_8SP_irq_tb;
    parameter XLEN = 32;
    parameter N_MIN = 6;
    parameter N_MAX = 70;
    parameter ICACHE_SETS = 128;
    parameter DDR_READ_LATENCY = 60;
    parameter [31:0] PROGRAM_BASE = 32'h0000_0000;
    localparam [31:0] JALR_X30 = 32'h000F_0067; // jalr x0, 0(x30)
    localparam integer MAX_CYCLES = 4000;
    localparam [31:0] HALT = 32'h0000_006F;

    reg clk;
    reg reset;
    reg irq;

    wire [31:0] retire_instruction;
    wire [XLEN-1:0] MMIO_data_memory_write_data;
    wire [XLEN-1:0] MMIO_data_memory_address;
    wire MMIO_data_memory_write_enable;

`ifdef HAS_ICACHE
    wire [31:0] instruction_cache_araddr;
    wire [7:0] instruction_cache_arlen;
    wire [2:0] instruction_cache_arsize;
    wire [1:0] instruction_cache_arburst;
    wire instruction_cache_arvalid;
    wire instruction_cache_arready;
    wire [63:0] instruction_cache_rdata;
    wire [1:0] instruction_cache_rresp;
    wire instruction_cache_rlast;
    wire instruction_cache_rvalid;
    wire instruction_cache_rready;

    RV32IM54F8SP #(.XLEN(XLEN), .ICACHE_NUM_SETS(ICACHE_SETS)) dut (
`else
    RV32IM54F8SP #(.XLEN(XLEN)) dut (
`endif
        .clk(clk),
        .clk_enable(1'b1),
        .reset(reset),
        .UART_busy(1'b0),
        .timer_interrupt_pending(irq),
        .MMIO_read_data({XLEN{1'b0}}),
        // data cache AXI4 master: these programs make no DDR data access
        .data_cache_m_axi_awready(1'b0),
        .data_cache_m_axi_wready(1'b0),
        .data_cache_m_axi_bresp(2'b00),
        .data_cache_m_axi_bvalid(1'b0),
        .data_cache_m_axi_arready(1'b0),
        .data_cache_m_axi_rdata(64'h0),
        .data_cache_m_axi_rresp(2'b00),
        .data_cache_m_axi_rlast(1'b0),
        .data_cache_m_axi_rvalid(1'b0),
`ifdef HAS_ICACHE
        .instruction_cache_m_axi_arready(instruction_cache_arready),
        .instruction_cache_m_axi_rdata(instruction_cache_rdata),
        .instruction_cache_m_axi_rresp(instruction_cache_rresp),
        .instruction_cache_m_axi_rlast(instruction_cache_rlast),
        .instruction_cache_m_axi_rvalid(instruction_cache_rvalid),
        .instruction_cache_m_axi_araddr(instruction_cache_araddr),
        .instruction_cache_m_axi_arlen(instruction_cache_arlen),
        .instruction_cache_m_axi_arsize(instruction_cache_arsize),
        .instruction_cache_m_axi_arburst(instruction_cache_arburst),
        .instruction_cache_m_axi_arvalid(instruction_cache_arvalid),
        .instruction_cache_m_axi_rready(instruction_cache_rready),
`endif
        .retire_instruction(retire_instruction),
        .MMIO_data_memory_write_data(MMIO_data_memory_write_data),
        .MMIO_data_memory_address(MMIO_data_memory_address),
        .MMIO_data_memory_write_enable(MMIO_data_memory_write_enable)
    );

`ifdef HAS_ICACHE
    DummyDDRMemory #(
        .ADDRESS_WIDTH(14),
        .READ_LATENCY(DDR_READ_LATENCY)
    ) dummy_ddr_memory (
        .clk(clk),
        .reset(reset),
        .s_axi_awaddr(32'h0),
        .s_axi_awlen(8'd0),
        .s_axi_awsize(3'd0),
        .s_axi_awburst(2'd0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata(64'h0),
        .s_axi_wstrb(8'h0),
        .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        .s_axi_bresp(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b0),
        .s_axi_araddr(instruction_cache_araddr),
        .s_axi_arlen(instruction_cache_arlen),
        .s_axi_arsize(instruction_cache_arsize),
        .s_axi_arburst(instruction_cache_arburst),
        .s_axi_arvalid(instruction_cache_arvalid),
        .s_axi_arready(instruction_cache_arready),
        .s_axi_rdata(instruction_cache_rdata),
        .s_axi_rresp(instruction_cache_rresp),
        .s_axi_rlast(instruction_cache_rlast),
        .s_axi_rvalid(instruction_cache_rvalid),
        .s_axi_rready(instruction_cache_rready)
    );

    initial begin
        for (i = 0; i < 16384; i = i + 1)
            dummy_ddr_memory.memory[i] = {HALT, HALT};
    end

    wire ce = !dut.cache_stall; // pipeline cycles (cache miss stall cycles are not counted)
`else
    wire ce = 1'b1;
`endif

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer n_irq;          // raise the IRQ once ccount >= n_irq
    integer ccount;         // core cycles since reset release
    integer first_seen;     // ccount at the first core edge with irq = 1
    integer done_cycle;
    reg done;
    reg irq_fired;

    always @(posedge clk) begin
        if (reset) begin
            ccount <= 0;
            irq <= 1'b0;
            irq_fired <= 1'b0;
            first_seen <= -1;
            done <= 1'b0;
            done_cycle <= -1;
        end else begin
            // raised on a raw clock edge: in the cached build this edge may be inside a cache miss stall
            if (!irq_fired && ccount >= n_irq) begin
                irq <= 1'b1;
                irq_fired <= 1'b1;
            end
            if (ce) begin
                ccount <= ccount + 1;
                if (irq && first_seen < 0) first_seen <= ccount;
                if (MMIO_data_memory_write_enable && MMIO_data_memory_address == 32'h1001_000C)
                    irq <= 1'b0;                        // handler acknowledges the timer
                if (MMIO_data_memory_write_enable && MMIO_data_memory_address == 32'h1001_0000 && !done) begin
                    done <= 1'b1;
                    done_cycle <= ccount;
                end
            end
        end
    end

    integer i, n, k;
    integer pass_count, fail_count;
    reg [XLEN-1:0] r20, r21;

    task load_program;
        begin
            for (i = 0; i < 1024; i = i + 1)
                dut.instruction_memory.data[i] = HALT;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui  x31,0x10010
            dut.instruction_memory.data[1] = 32'h10000293;   // 0004: li   x5,0x100
            dut.instruction_memory.data[2] = 32'h30529073;   // 0008: csrw mtvec,x5
            dut.instruction_memory.data[3] = 32'h08000313;   // 000c: li   x6,0x80
            dut.instruction_memory.data[4] = 32'h30431073;   // 0010: csrw mie,x6     (MTIE)
            dut.instruction_memory.data[5] = 32'h00800313;   // 0014: li   x6,8
            dut.instruction_memory.data[6] = 32'h30031073;   // 0018: csrw mstatus,x6 (MIE)
            for (i = 7; i < 56; i = i + 1)
                dut.instruction_memory.data[i] = 32'h00000013;   // 001c..00dc: nop (several cold lines)
            dut.instruction_memory.data[56] = 32'h000fa023;  // 00e0: sw x0,0(x31)    (DONE)
            dut.instruction_memory.data[57] = 32'h0000006f;  // 00e4: j .
            dut.instruction_memory.data[64] = 32'h001a0a13;  // 0100: addi x20,x20,1  (handler)
            dut.instruction_memory.data[65] = 32'h34102af3;  // 0104: csrr x21,mepc
            dut.instruction_memory.data[66] = 32'h000fa623;  // 0108: sw x0,12(x31)   (TB drops the IRQ)
            dut.instruction_memory.data[67] = 32'h30200073;  // 010c: mret
            dut.instruction_memory.data[68] = 32'h0000006f;  // 0110: j .  (must not be reached)
            if (PROGRAM_BASE != 32'h0) begin
                dut.instruction_memory.data[1] = 32'h100F0293; // 0004: addi x5,x30,0x100 (mtvec = base + 0x100)
                for (i = 0; i < 1024; i = i + 1)
                    write_program_word(i, dut.instruction_memory.data[i]);
                for (i = 0; i < 1024; i = i + 1)
                    dut.instruction_memory.data[i] = HALT;
                dut.instruction_memory.data[0] = JALR_X30;
            end
        end
    endtask

    // Word n of the program at PROGRAM_BASE
    task write_program_word;
        input integer n;
        input [31:0] value;
        integer word;
        begin
            word = (PROGRAM_BASE & 32'h1FFF_FFFF) / 4 + n;
            if (PROGRAM_BASE[31]) begin
`ifdef HAS_ICACHE
                if (word % 2)
                    dummy_ddr_memory.memory[word / 2][63:32] = value;
                else
                    dummy_ddr_memory.memory[word / 2][31:0] = value;
`endif
            end
            else
                dut.instruction_memory.data[word] = value;
        end
    endtask

    initial begin
        reset = 1'b1;
        n_irq = 1 << 30;
        pass_count = 0;
        fail_count = 0;
        #1;
        load_program;
        for (n = N_MIN; n <= N_MAX; n = n + 1) begin
            reset = 1'b1;
            n_irq = n;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = {XLEN{1'b0}};
            dut.register_file.registers[30] = PROGRAM_BASE;
            repeat (5) @(posedge clk);
            #1 reset = 1'b0;
            k = 0;
            while (!done && k < MAX_CYCLES) begin
                @(posedge clk);
                k = k + 1;
            end
            // let the handler side effects drain (20 core cycles)
            k = 0;
            while (k < 20) begin
                @(posedge clk);
                if (ce) k = k + 1;
            end
            #1;
            r20 = dut.register_file.registers[20];
            r21 = dut.register_file.registers[21] - PROGRAM_BASE;
            $display("R first=%0d n=%0d done=%0d cyc=%0d x20=%0d x21=%h",
                     first_seen, n, done, done_cycle, r20, r21);
            if (done === 1'b1 && first_seen >= 0 && r20 === 32'd1 &&
                r21 >= 32'h1c && r21 <= 32'he0 && r21[1:0] === 2'b00)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] N=%0d: expected done=1, IRQ seen, x20=1, x21 in 0x1c..0xe0", n);
            end
        end
        $display("============================================");
        $display(" IRQ runs: PASS: %0d  FAIL: %0d", pass_count, fail_count);
        $display("============================================");
        if (fail_count != 0)
            $fatal(1, "RV32IM54F_8SP_irq_tb: %0d run(s) failed", fail_count);
        $finish;
    end

endmodule
