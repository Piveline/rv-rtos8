`timescale 1ns / 1ps

`include "./modules/Dummy_DDR_Memory.v"

/*
 * Core + Instruction Cache + Data Cache testbench (both caches miss at the same time)
 * - The program runs from DDR (0x8000_1000) through the instruction cache and loads / stores
 *   DDR data (0x8001_0000 ~ 0x8001_FFFF) through the data cache.
 * - Two DummyDDRMemory models, one per cache AXI4 master (separate read / write latency per run).
 * - 48 blocks, each : lui / addi x1 (data address), 2 ~ 9 nops, lw x4, 6 nops,
 *   add x2,x2,x4; sw x2,4(x1); lw x5,4(x1), 6 nops, add x6,x6,x5. The nops after a load keep the
 *   fetch running, so a load miss in MEM meets a fetch miss on the next line at different distances.
 *   The data addresses use 6 data cache sets x 4 tags (2 ways), so dirty lines are written back
 *   and read again. The program then reads back the 40 written words into x7.
 * - Checks : x2 / x6 / x7 against a reference model, and at least one cycle where both caches
 *   are busy (an overlapping instruction and data cache miss).
 *
 * Run from RTL/RV32:
 *   iverilog -o dual.vvp modules/RV32IM54F_8SP.v testbenches/RV32IM54F_8SP_dual_cache_tb.v
 *   vvp -n dual.vvp
 */
module RV32IM54F_8SP_dual_cache_tb;
    parameter XLEN = 32;
    parameter ICACHE_SETS = 128;
    parameter I_READ_LATENCY = 60;
    parameter D_READ_LATENCY = 60;
    parameter D_WRITE_LATENCY = 60;

    localparam [XLEN-1:0] DONE_ADDR = 32'h1001_0000;
    localparam integer TIMEOUT = 200000;
    localparam [31:0] HALT = 32'h0000_006F; // jal x0, 0

    reg clk;
    reg reset;

    wire [31:0] retire_instruction;
    wire [XLEN-1:0] MMIO_data_memory_write_data;
    wire [XLEN-1:0] MMIO_data_memory_address;
    wire MMIO_data_memory_write_enable;

    // Instruction cache AXI4 master (read only)
    wire [31:0] i_araddr;
    wire [7:0] i_arlen;
    wire [2:0] i_arsize;
    wire [1:0] i_arburst;
    wire i_arvalid;
    wire i_arready;
    wire [63:0] i_rdata;
    wire [1:0] i_rresp;
    wire i_rlast;
    wire i_rvalid;
    wire i_rready;

    // Data cache AXI4 master
    wire [31:0] d_awaddr;
    wire [7:0] d_awlen;
    wire [2:0] d_awsize;
    wire [1:0] d_awburst;
    wire d_awvalid;
    wire d_awready;
    wire [63:0] d_wdata;
    wire [7:0] d_wstrb;
    wire d_wlast;
    wire d_wvalid;
    wire d_wready;
    wire [1:0] d_bresp;
    wire d_bvalid;
    wire d_bready;
    wire [31:0] d_araddr;
    wire [7:0] d_arlen;
    wire [2:0] d_arsize;
    wire [1:0] d_arburst;
    wire d_arvalid;
    wire d_arready;
    wire [63:0] d_rdata;
    wire [1:0] d_rresp;
    wire d_rlast;
    wire d_rvalid;
    wire d_rready;

    RV32IM54F8SP #(.XLEN(XLEN), .ICACHE_NUM_SETS(ICACHE_SETS)) dut (
        .clk(clk),
        .clk_enable(1'b1),
        .reset(reset),
        .UART_busy(1'b0),
        .timer_interrupt_pending(1'b0),
        .MMIO_read_data({XLEN{1'b0}}),
        .data_cache_m_axi_awready(d_awready),
        .data_cache_m_axi_wready(d_wready),
        .data_cache_m_axi_bresp(d_bresp),
        .data_cache_m_axi_bvalid(d_bvalid),
        .data_cache_m_axi_arready(d_arready),
        .data_cache_m_axi_rdata(d_rdata),
        .data_cache_m_axi_rresp(d_rresp),
        .data_cache_m_axi_rlast(d_rlast),
        .data_cache_m_axi_rvalid(d_rvalid),
        .instruction_cache_m_axi_arready(i_arready),
        .instruction_cache_m_axi_rdata(i_rdata),
        .instruction_cache_m_axi_rresp(i_rresp),
        .instruction_cache_m_axi_rlast(i_rlast),
        .instruction_cache_m_axi_rvalid(i_rvalid),
        .retire_instruction(retire_instruction),
        .MMIO_data_memory_write_data(MMIO_data_memory_write_data),
        .MMIO_data_memory_address(MMIO_data_memory_address),
        .MMIO_data_memory_write_enable(MMIO_data_memory_write_enable),
        .data_cache_m_axi_awaddr(d_awaddr),
        .data_cache_m_axi_awlen(d_awlen),
        .data_cache_m_axi_awsize(d_awsize),
        .data_cache_m_axi_awburst(d_awburst),
        .data_cache_m_axi_awvalid(d_awvalid),
        .data_cache_m_axi_wdata(d_wdata),
        .data_cache_m_axi_wstrb(d_wstrb),
        .data_cache_m_axi_wlast(d_wlast),
        .data_cache_m_axi_wvalid(d_wvalid),
        .data_cache_m_axi_bready(d_bready),
        .data_cache_m_axi_araddr(d_araddr),
        .data_cache_m_axi_arlen(d_arlen),
        .data_cache_m_axi_arsize(d_arsize),
        .data_cache_m_axi_arburst(d_arburst),
        .data_cache_m_axi_arvalid(d_arvalid),
        .data_cache_m_axi_rready(d_rready),
        .instruction_cache_m_axi_araddr(i_araddr),
        .instruction_cache_m_axi_arlen(i_arlen),
        .instruction_cache_m_axi_arsize(i_arsize),
        .instruction_cache_m_axi_arburst(i_arburst),
        .instruction_cache_m_axi_arvalid(i_arvalid),
        .instruction_cache_m_axi_rready(i_rready)
    );

    // DDR window 0x8000_0000 ~ 0x8001_FFFF (128KB) seen by the instruction cache (code)
    DummyDDRMemory #(
        .ADDRESS_WIDTH(14),
        .READ_LATENCY(I_READ_LATENCY)
    ) i_ddr (
        .clk(clk),
        .reset(reset),
        .s_axi_awaddr(32'h0),
        .s_axi_awlen(8'h0),
        .s_axi_awsize(3'h0),
        .s_axi_awburst(2'h0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata(64'h0),
        .s_axi_wstrb(8'h0),
        .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_wready(),
        .s_axi_bresp(),
        .s_axi_bvalid(),
        .s_axi_bready(1'b1),
        .s_axi_araddr(i_araddr),
        .s_axi_arlen(i_arlen),
        .s_axi_arsize(i_arsize),
        .s_axi_arburst(i_arburst),
        .s_axi_arvalid(i_arvalid),
        .s_axi_arready(i_arready),
        .s_axi_rdata(i_rdata),
        .s_axi_rresp(i_rresp),
        .s_axi_rlast(i_rlast),
        .s_axi_rvalid(i_rvalid),
        .s_axi_rready(i_rready)
    );

    // DDR window 0x8000_0000 ~ 0x8001_FFFF (128KB) seen by the data cache (data)
    DummyDDRMemory #(
        .ADDRESS_WIDTH(14),
        .READ_LATENCY(D_READ_LATENCY),
        .WRITE_LATENCY(D_WRITE_LATENCY)
    ) d_ddr (
        .clk(clk),
        .reset(reset),
        .s_axi_awaddr(d_awaddr),
        .s_axi_awlen(d_awlen),
        .s_axi_awsize(d_awsize),
        .s_axi_awburst(d_awburst),
        .s_axi_awvalid(d_awvalid),
        .s_axi_awready(d_awready),
        .s_axi_wdata(d_wdata),
        .s_axi_wstrb(d_wstrb),
        .s_axi_wlast(d_wlast),
        .s_axi_wvalid(d_wvalid),
        .s_axi_wready(d_wready),
        .s_axi_bresp(d_bresp),
        .s_axi_bvalid(d_bvalid),
        .s_axi_bready(d_bready),
        .s_axi_araddr(d_araddr),
        .s_axi_arlen(d_arlen),
        .s_axi_arsize(d_arsize),
        .s_axi_arburst(d_arburst),
        .s_axi_arvalid(d_arvalid),
        .s_axi_arready(d_arready),
        .s_axi_rdata(d_rdata),
        .s_axi_rresp(d_rresp),
        .s_axi_rlast(d_rlast),
        .s_axi_rvalid(d_rvalid),
        .s_axi_rready(d_rready)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // initial DDR data (the reference model uses the same function)
    function [31:0] ddr_init_word;
        input [31:0] address;
        begin
            ddr_init_word = (address * 32'h9E3779B1) ^ 32'h5A5A5A5A;
        end
    endfunction

    integer i;
    integer cycles;
    integer both_busy_cycles;
    integer instruction_busy_cycles;
    integer data_busy_cycles;
    integer pass_count;
    integer fail_count;
    reg done;

    always @(posedge clk) begin
        if (reset) begin
            done <= 1'b0;
            cycles <= 0;
            both_busy_cycles <= 0;
            instruction_busy_cycles <= 0;
            data_busy_cycles <= 0;
        end
        else begin
            cycles <= cycles + 1;
            if (dut.instruction_cache_cpu_busy) instruction_busy_cycles <= instruction_busy_cycles + 1;
            if (dut.data_cache_cpu_busy) data_busy_cycles <= data_busy_cycles + 1;
            if (dut.instruction_cache_cpu_busy && dut.data_cache_cpu_busy) both_busy_cycles <= both_busy_cycles + 1;
            if (MMIO_data_memory_write_enable && MMIO_data_memory_address == DONE_ADDR)
                done <= 1'b1;
        end
    end

    task check_value;
        input [8*24-1:0] name;
        input [31:0] expected;
        input [31:0] actual;
        begin
            if (expected === actual) begin
                pass_count = pass_count + 1;
                $display("[PASS] %0s | expected: 0x%08h | actual: 0x%08h", name, expected, actual);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s | expected: 0x%08h | actual: 0x%08h", name, expected, actual);
            end
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;
        reset = 1'b1;
        #1; // after the memories load their init files

        // Boot ROM : jump to the program in DDR
        for (i = 0; i < 64; i = i + 1)
            dut.instruction_memory.data[i] = HALT;
        dut.instruction_memory.data[0] = 32'h80001f37; // 0000: lui x30,0x80001
        dut.instruction_memory.data[1] = 32'h000f0067; // 0004: jalr x0,0(x30)

        for (i = 0; i < 16384; i = i + 1) begin
            i_ddr.memory[i] = {HALT, HALT};
            d_ddr.memory[i] = {ddr_init_word(32'h8000_0000 + i * 8 + 4), ddr_init_word(32'h8000_0000 + i * 8)};
        end

        // program : 1342 words at 0x8000_1000
        begin
            i_ddr.memory[512][31:0] = 32'h10010fb7; // 80001000: lui x31,0x10010   (DONE)
            i_ddr.memory[512][63:32] = 32'h00000113; // 80001004: li x2,0
            i_ddr.memory[513][31:0] = 32'h00000313; // 80001008: li x6,0
            i_ddr.memory[513][63:32] = 32'h00000393; // 8000100c: li x7,0
            i_ddr.memory[514][31:0] = 32'h800170b7; // 80001010: lui x1,0x80017
            i_ddr.memory[514][63:32] = 32'h99008093; // 80001014: addi x1,x1,-1648
            i_ddr.memory[515][31:0] = 32'h00000013; // 80001018: nop
            i_ddr.memory[515][63:32] = 32'h00000013; // 8000101c: nop
            i_ddr.memory[516][31:0] = 32'h0000a203; // 80001020: lw x4,0(x1)
            i_ddr.memory[516][63:32] = 32'h00000013; // 80001024: nop
            i_ddr.memory[517][31:0] = 32'h00000013; // 80001028: nop
            i_ddr.memory[517][63:32] = 32'h00000013; // 8000102c: nop
            i_ddr.memory[518][31:0] = 32'h00000013; // 80001030: nop
            i_ddr.memory[518][63:32] = 32'h00000013; // 80001034: nop
            i_ddr.memory[519][31:0] = 32'h00000013; // 80001038: nop
            i_ddr.memory[519][63:32] = 32'h00410133; // 8000103c: add x2,x2,x4
            i_ddr.memory[520][31:0] = 32'h0020a223; // 80001040: sw x2,4(x1)
            i_ddr.memory[520][63:32] = 32'h0040a283; // 80001044: lw x5,4(x1)
            i_ddr.memory[521][31:0] = 32'h00000013; // 80001048: nop
            i_ddr.memory[521][63:32] = 32'h00000013; // 8000104c: nop
            i_ddr.memory[522][31:0] = 32'h00000013; // 80001050: nop
            i_ddr.memory[522][63:32] = 32'h00000013; // 80001054: nop
            i_ddr.memory[523][31:0] = 32'h00000013; // 80001058: nop
            i_ddr.memory[523][63:32] = 32'h00000013; // 8000105c: nop
            i_ddr.memory[524][31:0] = 32'h00530333; // 80001060: add x6,x6,x5
            i_ddr.memory[524][63:32] = 32'h8001b0b7; // 80001064: lui x1,0x8001b
            i_ddr.memory[525][31:0] = 32'h98008093; // 80001068: addi x1,x1,-1664
            i_ddr.memory[525][63:32] = 32'h00000013; // 8000106c: nop
            i_ddr.memory[526][31:0] = 32'h00000013; // 80001070: nop
            i_ddr.memory[526][63:32] = 32'h00000013; // 80001074: nop
            i_ddr.memory[527][31:0] = 32'h0000a203; // 80001078: lw x4,0(x1)
            i_ddr.memory[527][63:32] = 32'h00000013; // 8000107c: nop
            i_ddr.memory[528][31:0] = 32'h00000013; // 80001080: nop
            i_ddr.memory[528][63:32] = 32'h00000013; // 80001084: nop
            i_ddr.memory[529][31:0] = 32'h00000013; // 80001088: nop
            i_ddr.memory[529][63:32] = 32'h00000013; // 8000108c: nop
            i_ddr.memory[530][31:0] = 32'h00000013; // 80001090: nop
            i_ddr.memory[530][63:32] = 32'h00410133; // 80001094: add x2,x2,x4
            i_ddr.memory[531][31:0] = 32'h0020a223; // 80001098: sw x2,4(x1)
            i_ddr.memory[531][63:32] = 32'h0040a283; // 8000109c: lw x5,4(x1)
            i_ddr.memory[532][31:0] = 32'h00000013; // 800010a0: nop
            i_ddr.memory[532][63:32] = 32'h00000013; // 800010a4: nop
            i_ddr.memory[533][31:0] = 32'h00000013; // 800010a8: nop
            i_ddr.memory[533][63:32] = 32'h00000013; // 800010ac: nop
            i_ddr.memory[534][31:0] = 32'h00000013; // 800010b0: nop
            i_ddr.memory[534][63:32] = 32'h00000013; // 800010b4: nop
            i_ddr.memory[535][31:0] = 32'h00530333; // 800010b8: add x6,x6,x5
            i_ddr.memory[535][63:32] = 32'h800190b7; // 800010bc: lui x1,0x80019
            i_ddr.memory[536][31:0] = 32'ha4008093; // 800010c0: addi x1,x1,-1472
            i_ddr.memory[536][63:32] = 32'h00000013; // 800010c4: nop
            i_ddr.memory[537][31:0] = 32'h00000013; // 800010c8: nop
            i_ddr.memory[537][63:32] = 32'h00000013; // 800010cc: nop
            i_ddr.memory[538][31:0] = 32'h00000013; // 800010d0: nop
            i_ddr.memory[538][63:32] = 32'h0000a203; // 800010d4: lw x4,0(x1)
            i_ddr.memory[539][31:0] = 32'h00000013; // 800010d8: nop
            i_ddr.memory[539][63:32] = 32'h00000013; // 800010dc: nop
            i_ddr.memory[540][31:0] = 32'h00000013; // 800010e0: nop
            i_ddr.memory[540][63:32] = 32'h00000013; // 800010e4: nop
            i_ddr.memory[541][31:0] = 32'h00000013; // 800010e8: nop
            i_ddr.memory[541][63:32] = 32'h00000013; // 800010ec: nop
            i_ddr.memory[542][31:0] = 32'h00410133; // 800010f0: add x2,x2,x4
            i_ddr.memory[542][63:32] = 32'h0020a223; // 800010f4: sw x2,4(x1)
            i_ddr.memory[543][31:0] = 32'h0040a283; // 800010f8: lw x5,4(x1)
            i_ddr.memory[543][63:32] = 32'h00000013; // 800010fc: nop
            i_ddr.memory[544][31:0] = 32'h00000013; // 80001100: nop
            i_ddr.memory[544][63:32] = 32'h00000013; // 80001104: nop
            i_ddr.memory[545][31:0] = 32'h00000013; // 80001108: nop
            i_ddr.memory[545][63:32] = 32'h00000013; // 8000110c: nop
            i_ddr.memory[546][31:0] = 32'h00000013; // 80001110: nop
            i_ddr.memory[546][63:32] = 32'h00530333; // 80001114: add x6,x6,x5
            i_ddr.memory[547][31:0] = 32'h800160b7; // 80001118: lui x1,0x80016
            i_ddr.memory[547][63:32] = 32'h55008093; // 8000111c: addi x1,x1,1360
            i_ddr.memory[548][31:0] = 32'h00000013; // 80001120: nop
            i_ddr.memory[548][63:32] = 32'h00000013; // 80001124: nop
            i_ddr.memory[549][31:0] = 32'h00000013; // 80001128: nop
            i_ddr.memory[549][63:32] = 32'h00000013; // 8000112c: nop
            i_ddr.memory[550][31:0] = 32'h00000013; // 80001130: nop
            i_ddr.memory[550][63:32] = 32'h0000a203; // 80001134: lw x4,0(x1)
            i_ddr.memory[551][31:0] = 32'h00000013; // 80001138: nop
            i_ddr.memory[551][63:32] = 32'h00000013; // 8000113c: nop
            i_ddr.memory[552][31:0] = 32'h00000013; // 80001140: nop
            i_ddr.memory[552][63:32] = 32'h00000013; // 80001144: nop
            i_ddr.memory[553][31:0] = 32'h00000013; // 80001148: nop
            i_ddr.memory[553][63:32] = 32'h00000013; // 8000114c: nop
            i_ddr.memory[554][31:0] = 32'h00410133; // 80001150: add x2,x2,x4
            i_ddr.memory[554][63:32] = 32'h0020a223; // 80001154: sw x2,4(x1)
            i_ddr.memory[555][31:0] = 32'h0040a283; // 80001158: lw x5,4(x1)
            i_ddr.memory[555][63:32] = 32'h00000013; // 8000115c: nop
            i_ddr.memory[556][31:0] = 32'h00000013; // 80001160: nop
            i_ddr.memory[556][63:32] = 32'h00000013; // 80001164: nop
            i_ddr.memory[557][31:0] = 32'h00000013; // 80001168: nop
            i_ddr.memory[557][63:32] = 32'h00000013; // 8000116c: nop
            i_ddr.memory[558][31:0] = 32'h00000013; // 80001170: nop
            i_ddr.memory[558][63:32] = 32'h00530333; // 80001174: add x6,x6,x5
            i_ddr.memory[559][31:0] = 32'h8001f0b7; // 80001178: lui x1,0x8001f
            i_ddr.memory[559][63:32] = 32'h98808093; // 8000117c: addi x1,x1,-1656
            i_ddr.memory[560][31:0] = 32'h00000013; // 80001180: nop
            i_ddr.memory[560][63:32] = 32'h00000013; // 80001184: nop
            i_ddr.memory[561][31:0] = 32'h00000013; // 80001188: nop
            i_ddr.memory[561][63:32] = 32'h00000013; // 8000118c: nop
            i_ddr.memory[562][31:0] = 32'h00000013; // 80001190: nop
            i_ddr.memory[562][63:32] = 32'h00000013; // 80001194: nop
            i_ddr.memory[563][31:0] = 32'h0000a203; // 80001198: lw x4,0(x1)
            i_ddr.memory[563][63:32] = 32'h00000013; // 8000119c: nop
            i_ddr.memory[564][31:0] = 32'h00000013; // 800011a0: nop
            i_ddr.memory[564][63:32] = 32'h00000013; // 800011a4: nop
            i_ddr.memory[565][31:0] = 32'h00000013; // 800011a8: nop
            i_ddr.memory[565][63:32] = 32'h00000013; // 800011ac: nop
            i_ddr.memory[566][31:0] = 32'h00000013; // 800011b0: nop
            i_ddr.memory[566][63:32] = 32'h00410133; // 800011b4: add x2,x2,x4
            i_ddr.memory[567][31:0] = 32'h0020a223; // 800011b8: sw x2,4(x1)
            i_ddr.memory[567][63:32] = 32'h0040a283; // 800011bc: lw x5,4(x1)
            i_ddr.memory[568][31:0] = 32'h00000013; // 800011c0: nop
            i_ddr.memory[568][63:32] = 32'h00000013; // 800011c4: nop
            i_ddr.memory[569][31:0] = 32'h00000013; // 800011c8: nop
            i_ddr.memory[569][63:32] = 32'h00000013; // 800011cc: nop
            i_ddr.memory[570][31:0] = 32'h00000013; // 800011d0: nop
            i_ddr.memory[570][63:32] = 32'h00000013; // 800011d4: nop
            i_ddr.memory[571][31:0] = 32'h00530333; // 800011d8: add x6,x6,x5
            i_ddr.memory[571][63:32] = 32'h8001b0b7; // 800011dc: lui x1,0x8001b
            i_ddr.memory[572][31:0] = 32'h98808093; // 800011e0: addi x1,x1,-1656
            i_ddr.memory[572][63:32] = 32'h00000013; // 800011e4: nop
            i_ddr.memory[573][31:0] = 32'h00000013; // 800011e8: nop
            i_ddr.memory[573][63:32] = 32'h00000013; // 800011ec: nop
            i_ddr.memory[574][31:0] = 32'h00000013; // 800011f0: nop
            i_ddr.memory[574][63:32] = 32'h00000013; // 800011f4: nop
            i_ddr.memory[575][31:0] = 32'h00000013; // 800011f8: nop
            i_ddr.memory[575][63:32] = 32'h00000013; // 800011fc: nop
            i_ddr.memory[576][31:0] = 32'h0000a203; // 80001200: lw x4,0(x1)
            i_ddr.memory[576][63:32] = 32'h00000013; // 80001204: nop
            i_ddr.memory[577][31:0] = 32'h00000013; // 80001208: nop
            i_ddr.memory[577][63:32] = 32'h00000013; // 8000120c: nop
            i_ddr.memory[578][31:0] = 32'h00000013; // 80001210: nop
            i_ddr.memory[578][63:32] = 32'h00000013; // 80001214: nop
            i_ddr.memory[579][31:0] = 32'h00000013; // 80001218: nop
            i_ddr.memory[579][63:32] = 32'h00410133; // 8000121c: add x2,x2,x4
            i_ddr.memory[580][31:0] = 32'h0020a223; // 80001220: sw x2,4(x1)
            i_ddr.memory[580][63:32] = 32'h0040a283; // 80001224: lw x5,4(x1)
            i_ddr.memory[581][31:0] = 32'h00000013; // 80001228: nop
            i_ddr.memory[581][63:32] = 32'h00000013; // 8000122c: nop
            i_ddr.memory[582][31:0] = 32'h00000013; // 80001230: nop
            i_ddr.memory[582][63:32] = 32'h00000013; // 80001234: nop
            i_ddr.memory[583][31:0] = 32'h00000013; // 80001238: nop
            i_ddr.memory[583][63:32] = 32'h00000013; // 8000123c: nop
            i_ddr.memory[584][31:0] = 32'h00530333; // 80001240: add x6,x6,x5
            i_ddr.memory[584][63:32] = 32'h800200b7; // 80001244: lui x1,0x80020
            i_ddr.memory[585][31:0] = 32'h8e008093; // 80001248: addi x1,x1,-1824
            i_ddr.memory[585][63:32] = 32'h00000013; // 8000124c: nop
            i_ddr.memory[586][31:0] = 32'h00000013; // 80001250: nop
            i_ddr.memory[586][63:32] = 32'h00000013; // 80001254: nop
            i_ddr.memory[587][31:0] = 32'h00000013; // 80001258: nop
            i_ddr.memory[587][63:32] = 32'h00000013; // 8000125c: nop
            i_ddr.memory[588][31:0] = 32'h00000013; // 80001260: nop
            i_ddr.memory[588][63:32] = 32'h00000013; // 80001264: nop
            i_ddr.memory[589][31:0] = 32'h00000013; // 80001268: nop
            i_ddr.memory[589][63:32] = 32'h0000a203; // 8000126c: lw x4,0(x1)
            i_ddr.memory[590][31:0] = 32'h00000013; // 80001270: nop
            i_ddr.memory[590][63:32] = 32'h00000013; // 80001274: nop
            i_ddr.memory[591][31:0] = 32'h00000013; // 80001278: nop
            i_ddr.memory[591][63:32] = 32'h00000013; // 8000127c: nop
            i_ddr.memory[592][31:0] = 32'h00000013; // 80001280: nop
            i_ddr.memory[592][63:32] = 32'h00000013; // 80001284: nop
            i_ddr.memory[593][31:0] = 32'h00410133; // 80001288: add x2,x2,x4
            i_ddr.memory[593][63:32] = 32'h0020a223; // 8000128c: sw x2,4(x1)
            i_ddr.memory[594][31:0] = 32'h0040a283; // 80001290: lw x5,4(x1)
            i_ddr.memory[594][63:32] = 32'h00000013; // 80001294: nop
            i_ddr.memory[595][31:0] = 32'h00000013; // 80001298: nop
            i_ddr.memory[595][63:32] = 32'h00000013; // 8000129c: nop
            i_ddr.memory[596][31:0] = 32'h00000013; // 800012a0: nop
            i_ddr.memory[596][63:32] = 32'h00000013; // 800012a4: nop
            i_ddr.memory[597][31:0] = 32'h00000013; // 800012a8: nop
            i_ddr.memory[597][63:32] = 32'h00530333; // 800012ac: add x6,x6,x5
            i_ddr.memory[598][31:0] = 32'h800160b7; // 800012b0: lui x1,0x80016
            i_ddr.memory[598][63:32] = 32'h55008093; // 800012b4: addi x1,x1,1360
            i_ddr.memory[599][31:0] = 32'h00000013; // 800012b8: nop
            i_ddr.memory[599][63:32] = 32'h00000013; // 800012bc: nop
            i_ddr.memory[600][31:0] = 32'h00000013; // 800012c0: nop
            i_ddr.memory[600][63:32] = 32'h00000013; // 800012c4: nop
            i_ddr.memory[601][31:0] = 32'h00000013; // 800012c8: nop
            i_ddr.memory[601][63:32] = 32'h00000013; // 800012cc: nop
            i_ddr.memory[602][31:0] = 32'h00000013; // 800012d0: nop
            i_ddr.memory[602][63:32] = 32'h00000013; // 800012d4: nop
            i_ddr.memory[603][31:0] = 32'h00000013; // 800012d8: nop
            i_ddr.memory[603][63:32] = 32'h0000a203; // 800012dc: lw x4,0(x1)
            i_ddr.memory[604][31:0] = 32'h00000013; // 800012e0: nop
            i_ddr.memory[604][63:32] = 32'h00000013; // 800012e4: nop
            i_ddr.memory[605][31:0] = 32'h00000013; // 800012e8: nop
            i_ddr.memory[605][63:32] = 32'h00000013; // 800012ec: nop
            i_ddr.memory[606][31:0] = 32'h00000013; // 800012f0: nop
            i_ddr.memory[606][63:32] = 32'h00000013; // 800012f4: nop
            i_ddr.memory[607][31:0] = 32'h00410133; // 800012f8: add x2,x2,x4
            i_ddr.memory[607][63:32] = 32'h0020a223; // 800012fc: sw x2,4(x1)
            i_ddr.memory[608][31:0] = 32'h0040a283; // 80001300: lw x5,4(x1)
            i_ddr.memory[608][63:32] = 32'h00000013; // 80001304: nop
            i_ddr.memory[609][31:0] = 32'h00000013; // 80001308: nop
            i_ddr.memory[609][63:32] = 32'h00000013; // 8000130c: nop
            i_ddr.memory[610][31:0] = 32'h00000013; // 80001310: nop
            i_ddr.memory[610][63:32] = 32'h00000013; // 80001314: nop
            i_ddr.memory[611][31:0] = 32'h00000013; // 80001318: nop
            i_ddr.memory[611][63:32] = 32'h00530333; // 8000131c: add x6,x6,x5
            i_ddr.memory[612][31:0] = 32'h8001c0b7; // 80001320: lui x1,0x8001c
            i_ddr.memory[612][63:32] = 32'hcd008093; // 80001324: addi x1,x1,-816
            i_ddr.memory[613][31:0] = 32'h00000013; // 80001328: nop
            i_ddr.memory[613][63:32] = 32'h00000013; // 8000132c: nop
            i_ddr.memory[614][31:0] = 32'h0000a203; // 80001330: lw x4,0(x1)
            i_ddr.memory[614][63:32] = 32'h00000013; // 80001334: nop
            i_ddr.memory[615][31:0] = 32'h00000013; // 80001338: nop
            i_ddr.memory[615][63:32] = 32'h00000013; // 8000133c: nop
            i_ddr.memory[616][31:0] = 32'h00000013; // 80001340: nop
            i_ddr.memory[616][63:32] = 32'h00000013; // 80001344: nop
            i_ddr.memory[617][31:0] = 32'h00000013; // 80001348: nop
            i_ddr.memory[617][63:32] = 32'h00410133; // 8000134c: add x2,x2,x4
            i_ddr.memory[618][31:0] = 32'h0020a223; // 80001350: sw x2,4(x1)
            i_ddr.memory[618][63:32] = 32'h0040a283; // 80001354: lw x5,4(x1)
            i_ddr.memory[619][31:0] = 32'h00000013; // 80001358: nop
            i_ddr.memory[619][63:32] = 32'h00000013; // 8000135c: nop
            i_ddr.memory[620][31:0] = 32'h00000013; // 80001360: nop
            i_ddr.memory[620][63:32] = 32'h00000013; // 80001364: nop
            i_ddr.memory[621][31:0] = 32'h00000013; // 80001368: nop
            i_ddr.memory[621][63:32] = 32'h00000013; // 8000136c: nop
            i_ddr.memory[622][31:0] = 32'h00530333; // 80001370: add x6,x6,x5
            i_ddr.memory[622][63:32] = 32'h800190b7; // 80001374: lui x1,0x80019
            i_ddr.memory[623][31:0] = 32'ha5008093; // 80001378: addi x1,x1,-1456
            i_ddr.memory[623][63:32] = 32'h00000013; // 8000137c: nop
            i_ddr.memory[624][31:0] = 32'h00000013; // 80001380: nop
            i_ddr.memory[624][63:32] = 32'h00000013; // 80001384: nop
            i_ddr.memory[625][31:0] = 32'h0000a203; // 80001388: lw x4,0(x1)
            i_ddr.memory[625][63:32] = 32'h00000013; // 8000138c: nop
            i_ddr.memory[626][31:0] = 32'h00000013; // 80001390: nop
            i_ddr.memory[626][63:32] = 32'h00000013; // 80001394: nop
            i_ddr.memory[627][31:0] = 32'h00000013; // 80001398: nop
            i_ddr.memory[627][63:32] = 32'h00000013; // 8000139c: nop
            i_ddr.memory[628][31:0] = 32'h00000013; // 800013a0: nop
            i_ddr.memory[628][63:32] = 32'h00410133; // 800013a4: add x2,x2,x4
            i_ddr.memory[629][31:0] = 32'h0020a223; // 800013a8: sw x2,4(x1)
            i_ddr.memory[629][63:32] = 32'h0040a283; // 800013ac: lw x5,4(x1)
            i_ddr.memory[630][31:0] = 32'h00000013; // 800013b0: nop
            i_ddr.memory[630][63:32] = 32'h00000013; // 800013b4: nop
            i_ddr.memory[631][31:0] = 32'h00000013; // 800013b8: nop
            i_ddr.memory[631][63:32] = 32'h00000013; // 800013bc: nop
            i_ddr.memory[632][31:0] = 32'h00000013; // 800013c0: nop
            i_ddr.memory[632][63:32] = 32'h00000013; // 800013c4: nop
            i_ddr.memory[633][31:0] = 32'h00530333; // 800013c8: add x6,x6,x5
            i_ddr.memory[633][63:32] = 32'h800180b7; // 800013cc: lui x1,0x80018
            i_ddr.memory[634][31:0] = 32'h40008093; // 800013d0: addi x1,x1,1024
            i_ddr.memory[634][63:32] = 32'h00000013; // 800013d4: nop
            i_ddr.memory[635][31:0] = 32'h00000013; // 800013d8: nop
            i_ddr.memory[635][63:32] = 32'h00000013; // 800013dc: nop
            i_ddr.memory[636][31:0] = 32'h00000013; // 800013e0: nop
            i_ddr.memory[636][63:32] = 32'h0000a203; // 800013e4: lw x4,0(x1)
            i_ddr.memory[637][31:0] = 32'h00000013; // 800013e8: nop
            i_ddr.memory[637][63:32] = 32'h00000013; // 800013ec: nop
            i_ddr.memory[638][31:0] = 32'h00000013; // 800013f0: nop
            i_ddr.memory[638][63:32] = 32'h00000013; // 800013f4: nop
            i_ddr.memory[639][31:0] = 32'h00000013; // 800013f8: nop
            i_ddr.memory[639][63:32] = 32'h00000013; // 800013fc: nop
            i_ddr.memory[640][31:0] = 32'h00410133; // 80001400: add x2,x2,x4
            i_ddr.memory[640][63:32] = 32'h0020a223; // 80001404: sw x2,4(x1)
            i_ddr.memory[641][31:0] = 32'h0040a283; // 80001408: lw x5,4(x1)
            i_ddr.memory[641][63:32] = 32'h00000013; // 8000140c: nop
            i_ddr.memory[642][31:0] = 32'h00000013; // 80001410: nop
            i_ddr.memory[642][63:32] = 32'h00000013; // 80001414: nop
            i_ddr.memory[643][31:0] = 32'h00000013; // 80001418: nop
            i_ddr.memory[643][63:32] = 32'h00000013; // 8000141c: nop
            i_ddr.memory[644][31:0] = 32'h00000013; // 80001420: nop
            i_ddr.memory[644][63:32] = 32'h00530333; // 80001424: add x6,x6,x5
            i_ddr.memory[645][31:0] = 32'h800190b7; // 80001428: lui x1,0x80019
            i_ddr.memory[645][63:32] = 32'ha4008093; // 8000142c: addi x1,x1,-1472
            i_ddr.memory[646][31:0] = 32'h00000013; // 80001430: nop
            i_ddr.memory[646][63:32] = 32'h00000013; // 80001434: nop
            i_ddr.memory[647][31:0] = 32'h00000013; // 80001438: nop
            i_ddr.memory[647][63:32] = 32'h00000013; // 8000143c: nop
            i_ddr.memory[648][31:0] = 32'h00000013; // 80001440: nop
            i_ddr.memory[648][63:32] = 32'h0000a203; // 80001444: lw x4,0(x1)
            i_ddr.memory[649][31:0] = 32'h00000013; // 80001448: nop
            i_ddr.memory[649][63:32] = 32'h00000013; // 8000144c: nop
            i_ddr.memory[650][31:0] = 32'h00000013; // 80001450: nop
            i_ddr.memory[650][63:32] = 32'h00000013; // 80001454: nop
            i_ddr.memory[651][31:0] = 32'h00000013; // 80001458: nop
            i_ddr.memory[651][63:32] = 32'h00000013; // 8000145c: nop
            i_ddr.memory[652][31:0] = 32'h00410133; // 80001460: add x2,x2,x4
            i_ddr.memory[652][63:32] = 32'h0020a223; // 80001464: sw x2,4(x1)
            i_ddr.memory[653][31:0] = 32'h0040a283; // 80001468: lw x5,4(x1)
            i_ddr.memory[653][63:32] = 32'h00000013; // 8000146c: nop
            i_ddr.memory[654][31:0] = 32'h00000013; // 80001470: nop
            i_ddr.memory[654][63:32] = 32'h00000013; // 80001474: nop
            i_ddr.memory[655][31:0] = 32'h00000013; // 80001478: nop
            i_ddr.memory[655][63:32] = 32'h00000013; // 8000147c: nop
            i_ddr.memory[656][31:0] = 32'h00000013; // 80001480: nop
            i_ddr.memory[656][63:32] = 32'h00530333; // 80001484: add x6,x6,x5
            i_ddr.memory[657][31:0] = 32'h800200b7; // 80001488: lui x1,0x80020
            i_ddr.memory[657][63:32] = 32'h8e808093; // 8000148c: addi x1,x1,-1816
            i_ddr.memory[658][31:0] = 32'h00000013; // 80001490: nop
            i_ddr.memory[658][63:32] = 32'h00000013; // 80001494: nop
            i_ddr.memory[659][31:0] = 32'h00000013; // 80001498: nop
            i_ddr.memory[659][63:32] = 32'h00000013; // 8000149c: nop
            i_ddr.memory[660][31:0] = 32'h00000013; // 800014a0: nop
            i_ddr.memory[660][63:32] = 32'h00000013; // 800014a4: nop
            i_ddr.memory[661][31:0] = 32'h0000a203; // 800014a8: lw x4,0(x1)
            i_ddr.memory[661][63:32] = 32'h00000013; // 800014ac: nop
            i_ddr.memory[662][31:0] = 32'h00000013; // 800014b0: nop
            i_ddr.memory[662][63:32] = 32'h00000013; // 800014b4: nop
            i_ddr.memory[663][31:0] = 32'h00000013; // 800014b8: nop
            i_ddr.memory[663][63:32] = 32'h00000013; // 800014bc: nop
            i_ddr.memory[664][31:0] = 32'h00000013; // 800014c0: nop
            i_ddr.memory[664][63:32] = 32'h00410133; // 800014c4: add x2,x2,x4
            i_ddr.memory[665][31:0] = 32'h0020a223; // 800014c8: sw x2,4(x1)
            i_ddr.memory[665][63:32] = 32'h0040a283; // 800014cc: lw x5,4(x1)
            i_ddr.memory[666][31:0] = 32'h00000013; // 800014d0: nop
            i_ddr.memory[666][63:32] = 32'h00000013; // 800014d4: nop
            i_ddr.memory[667][31:0] = 32'h00000013; // 800014d8: nop
            i_ddr.memory[667][63:32] = 32'h00000013; // 800014dc: nop
            i_ddr.memory[668][31:0] = 32'h00000013; // 800014e0: nop
            i_ddr.memory[668][63:32] = 32'h00000013; // 800014e4: nop
            i_ddr.memory[669][31:0] = 32'h00530333; // 800014e8: add x6,x6,x5
            i_ddr.memory[669][63:32] = 32'h800180b7; // 800014ec: lui x1,0x80018
            i_ddr.memory[670][31:0] = 32'h8e008093; // 800014f0: addi x1,x1,-1824
            i_ddr.memory[670][63:32] = 32'h00000013; // 800014f4: nop
            i_ddr.memory[671][31:0] = 32'h00000013; // 800014f8: nop
            i_ddr.memory[671][63:32] = 32'h00000013; // 800014fc: nop
            i_ddr.memory[672][31:0] = 32'h00000013; // 80001500: nop
            i_ddr.memory[672][63:32] = 32'h00000013; // 80001504: nop
            i_ddr.memory[673][31:0] = 32'h00000013; // 80001508: nop
            i_ddr.memory[673][63:32] = 32'h00000013; // 8000150c: nop
            i_ddr.memory[674][31:0] = 32'h0000a203; // 80001510: lw x4,0(x1)
            i_ddr.memory[674][63:32] = 32'h00000013; // 80001514: nop
            i_ddr.memory[675][31:0] = 32'h00000013; // 80001518: nop
            i_ddr.memory[675][63:32] = 32'h00000013; // 8000151c: nop
            i_ddr.memory[676][31:0] = 32'h00000013; // 80001520: nop
            i_ddr.memory[676][63:32] = 32'h00000013; // 80001524: nop
            i_ddr.memory[677][31:0] = 32'h00000013; // 80001528: nop
            i_ddr.memory[677][63:32] = 32'h00410133; // 8000152c: add x2,x2,x4
            i_ddr.memory[678][31:0] = 32'h0020a223; // 80001530: sw x2,4(x1)
            i_ddr.memory[678][63:32] = 32'h0040a283; // 80001534: lw x5,4(x1)
            i_ddr.memory[679][31:0] = 32'h00000013; // 80001538: nop
            i_ddr.memory[679][63:32] = 32'h00000013; // 8000153c: nop
            i_ddr.memory[680][31:0] = 32'h00000013; // 80001540: nop
            i_ddr.memory[680][63:32] = 32'h00000013; // 80001544: nop
            i_ddr.memory[681][31:0] = 32'h00000013; // 80001548: nop
            i_ddr.memory[681][63:32] = 32'h00000013; // 8000154c: nop
            i_ddr.memory[682][31:0] = 32'h00530333; // 80001550: add x6,x6,x5
            i_ddr.memory[682][63:32] = 32'h8001c0b7; // 80001554: lui x1,0x8001c
            i_ddr.memory[683][31:0] = 32'h8e808093; // 80001558: addi x1,x1,-1816
            i_ddr.memory[683][63:32] = 32'h00000013; // 8000155c: nop
            i_ddr.memory[684][31:0] = 32'h00000013; // 80001560: nop
            i_ddr.memory[684][63:32] = 32'h00000013; // 80001564: nop
            i_ddr.memory[685][31:0] = 32'h00000013; // 80001568: nop
            i_ddr.memory[685][63:32] = 32'h00000013; // 8000156c: nop
            i_ddr.memory[686][31:0] = 32'h00000013; // 80001570: nop
            i_ddr.memory[686][63:32] = 32'h00000013; // 80001574: nop
            i_ddr.memory[687][31:0] = 32'h00000013; // 80001578: nop
            i_ddr.memory[687][63:32] = 32'h0000a203; // 8000157c: lw x4,0(x1)
            i_ddr.memory[688][31:0] = 32'h00000013; // 80001580: nop
            i_ddr.memory[688][63:32] = 32'h00000013; // 80001584: nop
            i_ddr.memory[689][31:0] = 32'h00000013; // 80001588: nop
            i_ddr.memory[689][63:32] = 32'h00000013; // 8000158c: nop
            i_ddr.memory[690][31:0] = 32'h00000013; // 80001590: nop
            i_ddr.memory[690][63:32] = 32'h00000013; // 80001594: nop
            i_ddr.memory[691][31:0] = 32'h00410133; // 80001598: add x2,x2,x4
            i_ddr.memory[691][63:32] = 32'h0020a223; // 8000159c: sw x2,4(x1)
            i_ddr.memory[692][31:0] = 32'h0040a283; // 800015a0: lw x5,4(x1)
            i_ddr.memory[692][63:32] = 32'h00000013; // 800015a4: nop
            i_ddr.memory[693][31:0] = 32'h00000013; // 800015a8: nop
            i_ddr.memory[693][63:32] = 32'h00000013; // 800015ac: nop
            i_ddr.memory[694][31:0] = 32'h00000013; // 800015b0: nop
            i_ddr.memory[694][63:32] = 32'h00000013; // 800015b4: nop
            i_ddr.memory[695][31:0] = 32'h00000013; // 800015b8: nop
            i_ddr.memory[695][63:32] = 32'h00530333; // 800015bc: add x6,x6,x5
            i_ddr.memory[696][31:0] = 32'h8001a0b7; // 800015c0: lui x1,0x8001a
            i_ddr.memory[696][63:32] = 32'h54808093; // 800015c4: addi x1,x1,1352
            i_ddr.memory[697][31:0] = 32'h00000013; // 800015c8: nop
            i_ddr.memory[697][63:32] = 32'h00000013; // 800015cc: nop
            i_ddr.memory[698][31:0] = 32'h00000013; // 800015d0: nop
            i_ddr.memory[698][63:32] = 32'h00000013; // 800015d4: nop
            i_ddr.memory[699][31:0] = 32'h00000013; // 800015d8: nop
            i_ddr.memory[699][63:32] = 32'h00000013; // 800015dc: nop
            i_ddr.memory[700][31:0] = 32'h00000013; // 800015e0: nop
            i_ddr.memory[700][63:32] = 32'h00000013; // 800015e4: nop
            i_ddr.memory[701][31:0] = 32'h00000013; // 800015e8: nop
            i_ddr.memory[701][63:32] = 32'h0000a203; // 800015ec: lw x4,0(x1)
            i_ddr.memory[702][31:0] = 32'h00000013; // 800015f0: nop
            i_ddr.memory[702][63:32] = 32'h00000013; // 800015f4: nop
            i_ddr.memory[703][31:0] = 32'h00000013; // 800015f8: nop
            i_ddr.memory[703][63:32] = 32'h00000013; // 800015fc: nop
            i_ddr.memory[704][31:0] = 32'h00000013; // 80001600: nop
            i_ddr.memory[704][63:32] = 32'h00000013; // 80001604: nop
            i_ddr.memory[705][31:0] = 32'h00410133; // 80001608: add x2,x2,x4
            i_ddr.memory[705][63:32] = 32'h0020a223; // 8000160c: sw x2,4(x1)
            i_ddr.memory[706][31:0] = 32'h0040a283; // 80001610: lw x5,4(x1)
            i_ddr.memory[706][63:32] = 32'h00000013; // 80001614: nop
            i_ddr.memory[707][31:0] = 32'h00000013; // 80001618: nop
            i_ddr.memory[707][63:32] = 32'h00000013; // 8000161c: nop
            i_ddr.memory[708][31:0] = 32'h00000013; // 80001620: nop
            i_ddr.memory[708][63:32] = 32'h00000013; // 80001624: nop
            i_ddr.memory[709][31:0] = 32'h00000013; // 80001628: nop
            i_ddr.memory[709][63:32] = 32'h00530333; // 8000162c: add x6,x6,x5
            i_ddr.memory[710][31:0] = 32'h8001e0b7; // 80001630: lui x1,0x8001e
            i_ddr.memory[710][63:32] = 32'h54808093; // 80001634: addi x1,x1,1352
            i_ddr.memory[711][31:0] = 32'h00000013; // 80001638: nop
            i_ddr.memory[711][63:32] = 32'h00000013; // 8000163c: nop
            i_ddr.memory[712][31:0] = 32'h0000a203; // 80001640: lw x4,0(x1)
            i_ddr.memory[712][63:32] = 32'h00000013; // 80001644: nop
            i_ddr.memory[713][31:0] = 32'h00000013; // 80001648: nop
            i_ddr.memory[713][63:32] = 32'h00000013; // 8000164c: nop
            i_ddr.memory[714][31:0] = 32'h00000013; // 80001650: nop
            i_ddr.memory[714][63:32] = 32'h00000013; // 80001654: nop
            i_ddr.memory[715][31:0] = 32'h00000013; // 80001658: nop
            i_ddr.memory[715][63:32] = 32'h00410133; // 8000165c: add x2,x2,x4
            i_ddr.memory[716][31:0] = 32'h0020a223; // 80001660: sw x2,4(x1)
            i_ddr.memory[716][63:32] = 32'h0040a283; // 80001664: lw x5,4(x1)
            i_ddr.memory[717][31:0] = 32'h00000013; // 80001668: nop
            i_ddr.memory[717][63:32] = 32'h00000013; // 8000166c: nop
            i_ddr.memory[718][31:0] = 32'h00000013; // 80001670: nop
            i_ddr.memory[718][63:32] = 32'h00000013; // 80001674: nop
            i_ddr.memory[719][31:0] = 32'h00000013; // 80001678: nop
            i_ddr.memory[719][63:32] = 32'h00000013; // 8000167c: nop
            i_ddr.memory[720][31:0] = 32'h00530333; // 80001680: add x6,x6,x5
            i_ddr.memory[720][63:32] = 32'h800200b7; // 80001684: lui x1,0x80020
            i_ddr.memory[721][31:0] = 32'hcd008093; // 80001688: addi x1,x1,-816
            i_ddr.memory[721][63:32] = 32'h00000013; // 8000168c: nop
            i_ddr.memory[722][31:0] = 32'h00000013; // 80001690: nop
            i_ddr.memory[722][63:32] = 32'h00000013; // 80001694: nop
            i_ddr.memory[723][31:0] = 32'h0000a203; // 80001698: lw x4,0(x1)
            i_ddr.memory[723][63:32] = 32'h00000013; // 8000169c: nop
            i_ddr.memory[724][31:0] = 32'h00000013; // 800016a0: nop
            i_ddr.memory[724][63:32] = 32'h00000013; // 800016a4: nop
            i_ddr.memory[725][31:0] = 32'h00000013; // 800016a8: nop
            i_ddr.memory[725][63:32] = 32'h00000013; // 800016ac: nop
            i_ddr.memory[726][31:0] = 32'h00000013; // 800016b0: nop
            i_ddr.memory[726][63:32] = 32'h00410133; // 800016b4: add x2,x2,x4
            i_ddr.memory[727][31:0] = 32'h0020a223; // 800016b8: sw x2,4(x1)
            i_ddr.memory[727][63:32] = 32'h0040a283; // 800016bc: lw x5,4(x1)
            i_ddr.memory[728][31:0] = 32'h00000013; // 800016c0: nop
            i_ddr.memory[728][63:32] = 32'h00000013; // 800016c4: nop
            i_ddr.memory[729][31:0] = 32'h00000013; // 800016c8: nop
            i_ddr.memory[729][63:32] = 32'h00000013; // 800016cc: nop
            i_ddr.memory[730][31:0] = 32'h00000013; // 800016d0: nop
            i_ddr.memory[730][63:32] = 32'h00000013; // 800016d4: nop
            i_ddr.memory[731][31:0] = 32'h00530333; // 800016d8: add x6,x6,x5
            i_ddr.memory[731][63:32] = 32'h800120b7; // 800016dc: lui x1,0x80012
            i_ddr.memory[732][31:0] = 32'h54808093; // 800016e0: addi x1,x1,1352
            i_ddr.memory[732][63:32] = 32'h00000013; // 800016e4: nop
            i_ddr.memory[733][31:0] = 32'h00000013; // 800016e8: nop
            i_ddr.memory[733][63:32] = 32'h00000013; // 800016ec: nop
            i_ddr.memory[734][31:0] = 32'h00000013; // 800016f0: nop
            i_ddr.memory[734][63:32] = 32'h0000a203; // 800016f4: lw x4,0(x1)
            i_ddr.memory[735][31:0] = 32'h00000013; // 800016f8: nop
            i_ddr.memory[735][63:32] = 32'h00000013; // 800016fc: nop
            i_ddr.memory[736][31:0] = 32'h00000013; // 80001700: nop
            i_ddr.memory[736][63:32] = 32'h00000013; // 80001704: nop
            i_ddr.memory[737][31:0] = 32'h00000013; // 80001708: nop
            i_ddr.memory[737][63:32] = 32'h00000013; // 8000170c: nop
            i_ddr.memory[738][31:0] = 32'h00410133; // 80001710: add x2,x2,x4
            i_ddr.memory[738][63:32] = 32'h0020a223; // 80001714: sw x2,4(x1)
            i_ddr.memory[739][31:0] = 32'h0040a283; // 80001718: lw x5,4(x1)
            i_ddr.memory[739][63:32] = 32'h00000013; // 8000171c: nop
            i_ddr.memory[740][31:0] = 32'h00000013; // 80001720: nop
            i_ddr.memory[740][63:32] = 32'h00000013; // 80001724: nop
            i_ddr.memory[741][31:0] = 32'h00000013; // 80001728: nop
            i_ddr.memory[741][63:32] = 32'h00000013; // 8000172c: nop
            i_ddr.memory[742][31:0] = 32'h00000013; // 80001730: nop
            i_ddr.memory[742][63:32] = 32'h00530333; // 80001734: add x6,x6,x5
            i_ddr.memory[743][31:0] = 32'h800140b7; // 80001738: lui x1,0x80014
            i_ddr.memory[743][63:32] = 32'h8f008093; // 8000173c: addi x1,x1,-1808
            i_ddr.memory[744][31:0] = 32'h00000013; // 80001740: nop
            i_ddr.memory[744][63:32] = 32'h00000013; // 80001744: nop
            i_ddr.memory[745][31:0] = 32'h00000013; // 80001748: nop
            i_ddr.memory[745][63:32] = 32'h00000013; // 8000174c: nop
            i_ddr.memory[746][31:0] = 32'h00000013; // 80001750: nop
            i_ddr.memory[746][63:32] = 32'h0000a203; // 80001754: lw x4,0(x1)
            i_ddr.memory[747][31:0] = 32'h00000013; // 80001758: nop
            i_ddr.memory[747][63:32] = 32'h00000013; // 8000175c: nop
            i_ddr.memory[748][31:0] = 32'h00000013; // 80001760: nop
            i_ddr.memory[748][63:32] = 32'h00000013; // 80001764: nop
            i_ddr.memory[749][31:0] = 32'h00000013; // 80001768: nop
            i_ddr.memory[749][63:32] = 32'h00000013; // 8000176c: nop
            i_ddr.memory[750][31:0] = 32'h00410133; // 80001770: add x2,x2,x4
            i_ddr.memory[750][63:32] = 32'h0020a223; // 80001774: sw x2,4(x1)
            i_ddr.memory[751][31:0] = 32'h0040a283; // 80001778: lw x5,4(x1)
            i_ddr.memory[751][63:32] = 32'h00000013; // 8000177c: nop
            i_ddr.memory[752][31:0] = 32'h00000013; // 80001780: nop
            i_ddr.memory[752][63:32] = 32'h00000013; // 80001784: nop
            i_ddr.memory[753][31:0] = 32'h00000013; // 80001788: nop
            i_ddr.memory[753][63:32] = 32'h00000013; // 8000178c: nop
            i_ddr.memory[754][31:0] = 32'h00000013; // 80001790: nop
            i_ddr.memory[754][63:32] = 32'h00530333; // 80001794: add x6,x6,x5
            i_ddr.memory[755][31:0] = 32'h800140b7; // 80001798: lui x1,0x80014
            i_ddr.memory[755][63:32] = 32'h8e808093; // 8000179c: addi x1,x1,-1816
            i_ddr.memory[756][31:0] = 32'h00000013; // 800017a0: nop
            i_ddr.memory[756][63:32] = 32'h00000013; // 800017a4: nop
            i_ddr.memory[757][31:0] = 32'h00000013; // 800017a8: nop
            i_ddr.memory[757][63:32] = 32'h00000013; // 800017ac: nop
            i_ddr.memory[758][31:0] = 32'h00000013; // 800017b0: nop
            i_ddr.memory[758][63:32] = 32'h00000013; // 800017b4: nop
            i_ddr.memory[759][31:0] = 32'h0000a203; // 800017b8: lw x4,0(x1)
            i_ddr.memory[759][63:32] = 32'h00000013; // 800017bc: nop
            i_ddr.memory[760][31:0] = 32'h00000013; // 800017c0: nop
            i_ddr.memory[760][63:32] = 32'h00000013; // 800017c4: nop
            i_ddr.memory[761][31:0] = 32'h00000013; // 800017c8: nop
            i_ddr.memory[761][63:32] = 32'h00000013; // 800017cc: nop
            i_ddr.memory[762][31:0] = 32'h00000013; // 800017d0: nop
            i_ddr.memory[762][63:32] = 32'h00410133; // 800017d4: add x2,x2,x4
            i_ddr.memory[763][31:0] = 32'h0020a223; // 800017d8: sw x2,4(x1)
            i_ddr.memory[763][63:32] = 32'h0040a283; // 800017dc: lw x5,4(x1)
            i_ddr.memory[764][31:0] = 32'h00000013; // 800017e0: nop
            i_ddr.memory[764][63:32] = 32'h00000013; // 800017e4: nop
            i_ddr.memory[765][31:0] = 32'h00000013; // 800017e8: nop
            i_ddr.memory[765][63:32] = 32'h00000013; // 800017ec: nop
            i_ddr.memory[766][31:0] = 32'h00000013; // 800017f0: nop
            i_ddr.memory[766][63:32] = 32'h00000013; // 800017f4: nop
            i_ddr.memory[767][31:0] = 32'h00530333; // 800017f8: add x6,x6,x5
            i_ddr.memory[767][63:32] = 32'h8001b0b7; // 800017fc: lui x1,0x8001b
            i_ddr.memory[768][31:0] = 32'h99008093; // 80001800: addi x1,x1,-1648
            i_ddr.memory[768][63:32] = 32'h00000013; // 80001804: nop
            i_ddr.memory[769][31:0] = 32'h00000013; // 80001808: nop
            i_ddr.memory[769][63:32] = 32'h00000013; // 8000180c: nop
            i_ddr.memory[770][31:0] = 32'h00000013; // 80001810: nop
            i_ddr.memory[770][63:32] = 32'h00000013; // 80001814: nop
            i_ddr.memory[771][31:0] = 32'h00000013; // 80001818: nop
            i_ddr.memory[771][63:32] = 32'h00000013; // 8000181c: nop
            i_ddr.memory[772][31:0] = 32'h0000a203; // 80001820: lw x4,0(x1)
            i_ddr.memory[772][63:32] = 32'h00000013; // 80001824: nop
            i_ddr.memory[773][31:0] = 32'h00000013; // 80001828: nop
            i_ddr.memory[773][63:32] = 32'h00000013; // 8000182c: nop
            i_ddr.memory[774][31:0] = 32'h00000013; // 80001830: nop
            i_ddr.memory[774][63:32] = 32'h00000013; // 80001834: nop
            i_ddr.memory[775][31:0] = 32'h00000013; // 80001838: nop
            i_ddr.memory[775][63:32] = 32'h00410133; // 8000183c: add x2,x2,x4
            i_ddr.memory[776][31:0] = 32'h0020a223; // 80001840: sw x2,4(x1)
            i_ddr.memory[776][63:32] = 32'h0040a283; // 80001844: lw x5,4(x1)
            i_ddr.memory[777][31:0] = 32'h00000013; // 80001848: nop
            i_ddr.memory[777][63:32] = 32'h00000013; // 8000184c: nop
            i_ddr.memory[778][31:0] = 32'h00000013; // 80001850: nop
            i_ddr.memory[778][63:32] = 32'h00000013; // 80001854: nop
            i_ddr.memory[779][31:0] = 32'h00000013; // 80001858: nop
            i_ddr.memory[779][63:32] = 32'h00000013; // 8000185c: nop
            i_ddr.memory[780][31:0] = 32'h00530333; // 80001860: add x6,x6,x5
            i_ddr.memory[780][63:32] = 32'h8001e0b7; // 80001864: lui x1,0x8001e
            i_ddr.memory[781][31:0] = 32'h54008093; // 80001868: addi x1,x1,1344
            i_ddr.memory[781][63:32] = 32'h00000013; // 8000186c: nop
            i_ddr.memory[782][31:0] = 32'h00000013; // 80001870: nop
            i_ddr.memory[782][63:32] = 32'h00000013; // 80001874: nop
            i_ddr.memory[783][31:0] = 32'h00000013; // 80001878: nop
            i_ddr.memory[783][63:32] = 32'h00000013; // 8000187c: nop
            i_ddr.memory[784][31:0] = 32'h00000013; // 80001880: nop
            i_ddr.memory[784][63:32] = 32'h00000013; // 80001884: nop
            i_ddr.memory[785][31:0] = 32'h00000013; // 80001888: nop
            i_ddr.memory[785][63:32] = 32'h0000a203; // 8000188c: lw x4,0(x1)
            i_ddr.memory[786][31:0] = 32'h00000013; // 80001890: nop
            i_ddr.memory[786][63:32] = 32'h00000013; // 80001894: nop
            i_ddr.memory[787][31:0] = 32'h00000013; // 80001898: nop
            i_ddr.memory[787][63:32] = 32'h00000013; // 8000189c: nop
            i_ddr.memory[788][31:0] = 32'h00000013; // 800018a0: nop
            i_ddr.memory[788][63:32] = 32'h00000013; // 800018a4: nop
            i_ddr.memory[789][31:0] = 32'h00410133; // 800018a8: add x2,x2,x4
            i_ddr.memory[789][63:32] = 32'h0020a223; // 800018ac: sw x2,4(x1)
            i_ddr.memory[790][31:0] = 32'h0040a283; // 800018b0: lw x5,4(x1)
            i_ddr.memory[790][63:32] = 32'h00000013; // 800018b4: nop
            i_ddr.memory[791][31:0] = 32'h00000013; // 800018b8: nop
            i_ddr.memory[791][63:32] = 32'h00000013; // 800018bc: nop
            i_ddr.memory[792][31:0] = 32'h00000013; // 800018c0: nop
            i_ddr.memory[792][63:32] = 32'h00000013; // 800018c4: nop
            i_ddr.memory[793][31:0] = 32'h00000013; // 800018c8: nop
            i_ddr.memory[793][63:32] = 32'h00530333; // 800018cc: add x6,x6,x5
            i_ddr.memory[794][31:0] = 32'h8001d0b7; // 800018d0: lui x1,0x8001d
            i_ddr.memory[794][63:32] = 32'ha5008093; // 800018d4: addi x1,x1,-1456
            i_ddr.memory[795][31:0] = 32'h00000013; // 800018d8: nop
            i_ddr.memory[795][63:32] = 32'h00000013; // 800018dc: nop
            i_ddr.memory[796][31:0] = 32'h00000013; // 800018e0: nop
            i_ddr.memory[796][63:32] = 32'h00000013; // 800018e4: nop
            i_ddr.memory[797][31:0] = 32'h00000013; // 800018e8: nop
            i_ddr.memory[797][63:32] = 32'h00000013; // 800018ec: nop
            i_ddr.memory[798][31:0] = 32'h00000013; // 800018f0: nop
            i_ddr.memory[798][63:32] = 32'h00000013; // 800018f4: nop
            i_ddr.memory[799][31:0] = 32'h00000013; // 800018f8: nop
            i_ddr.memory[799][63:32] = 32'h0000a203; // 800018fc: lw x4,0(x1)
            i_ddr.memory[800][31:0] = 32'h00000013; // 80001900: nop
            i_ddr.memory[800][63:32] = 32'h00000013; // 80001904: nop
            i_ddr.memory[801][31:0] = 32'h00000013; // 80001908: nop
            i_ddr.memory[801][63:32] = 32'h00000013; // 8000190c: nop
            i_ddr.memory[802][31:0] = 32'h00000013; // 80001910: nop
            i_ddr.memory[802][63:32] = 32'h00000013; // 80001914: nop
            i_ddr.memory[803][31:0] = 32'h00410133; // 80001918: add x2,x2,x4
            i_ddr.memory[803][63:32] = 32'h0020a223; // 8000191c: sw x2,4(x1)
            i_ddr.memory[804][31:0] = 32'h0040a283; // 80001920: lw x5,4(x1)
            i_ddr.memory[804][63:32] = 32'h00000013; // 80001924: nop
            i_ddr.memory[805][31:0] = 32'h00000013; // 80001928: nop
            i_ddr.memory[805][63:32] = 32'h00000013; // 8000192c: nop
            i_ddr.memory[806][31:0] = 32'h00000013; // 80001930: nop
            i_ddr.memory[806][63:32] = 32'h00000013; // 80001934: nop
            i_ddr.memory[807][31:0] = 32'h00000013; // 80001938: nop
            i_ddr.memory[807][63:32] = 32'h00530333; // 8000193c: add x6,x6,x5
            i_ddr.memory[808][31:0] = 32'h8001c0b7; // 80001940: lui x1,0x8001c
            i_ddr.memory[808][63:32] = 32'h41008093; // 80001944: addi x1,x1,1040
            i_ddr.memory[809][31:0] = 32'h00000013; // 80001948: nop
            i_ddr.memory[809][63:32] = 32'h00000013; // 8000194c: nop
            i_ddr.memory[810][31:0] = 32'h0000a203; // 80001950: lw x4,0(x1)
            i_ddr.memory[810][63:32] = 32'h00000013; // 80001954: nop
            i_ddr.memory[811][31:0] = 32'h00000013; // 80001958: nop
            i_ddr.memory[811][63:32] = 32'h00000013; // 8000195c: nop
            i_ddr.memory[812][31:0] = 32'h00000013; // 80001960: nop
            i_ddr.memory[812][63:32] = 32'h00000013; // 80001964: nop
            i_ddr.memory[813][31:0] = 32'h00000013; // 80001968: nop
            i_ddr.memory[813][63:32] = 32'h00410133; // 8000196c: add x2,x2,x4
            i_ddr.memory[814][31:0] = 32'h0020a223; // 80001970: sw x2,4(x1)
            i_ddr.memory[814][63:32] = 32'h0040a283; // 80001974: lw x5,4(x1)
            i_ddr.memory[815][31:0] = 32'h00000013; // 80001978: nop
            i_ddr.memory[815][63:32] = 32'h00000013; // 8000197c: nop
            i_ddr.memory[816][31:0] = 32'h00000013; // 80001980: nop
            i_ddr.memory[816][63:32] = 32'h00000013; // 80001984: nop
            i_ddr.memory[817][31:0] = 32'h00000013; // 80001988: nop
            i_ddr.memory[817][63:32] = 32'h00000013; // 8000198c: nop
            i_ddr.memory[818][31:0] = 32'h00530333; // 80001990: add x6,x6,x5
            i_ddr.memory[818][63:32] = 32'h800130b7; // 80001994: lui x1,0x80013
            i_ddr.memory[819][31:0] = 32'h98808093; // 80001998: addi x1,x1,-1656
            i_ddr.memory[819][63:32] = 32'h00000013; // 8000199c: nop
            i_ddr.memory[820][31:0] = 32'h00000013; // 800019a0: nop
            i_ddr.memory[820][63:32] = 32'h00000013; // 800019a4: nop
            i_ddr.memory[821][31:0] = 32'h0000a203; // 800019a8: lw x4,0(x1)
            i_ddr.memory[821][63:32] = 32'h00000013; // 800019ac: nop
            i_ddr.memory[822][31:0] = 32'h00000013; // 800019b0: nop
            i_ddr.memory[822][63:32] = 32'h00000013; // 800019b4: nop
            i_ddr.memory[823][31:0] = 32'h00000013; // 800019b8: nop
            i_ddr.memory[823][63:32] = 32'h00000013; // 800019bc: nop
            i_ddr.memory[824][31:0] = 32'h00000013; // 800019c0: nop
            i_ddr.memory[824][63:32] = 32'h00410133; // 800019c4: add x2,x2,x4
            i_ddr.memory[825][31:0] = 32'h0020a223; // 800019c8: sw x2,4(x1)
            i_ddr.memory[825][63:32] = 32'h0040a283; // 800019cc: lw x5,4(x1)
            i_ddr.memory[826][31:0] = 32'h00000013; // 800019d0: nop
            i_ddr.memory[826][63:32] = 32'h00000013; // 800019d4: nop
            i_ddr.memory[827][31:0] = 32'h00000013; // 800019d8: nop
            i_ddr.memory[827][63:32] = 32'h00000013; // 800019dc: nop
            i_ddr.memory[828][31:0] = 32'h00000013; // 800019e0: nop
            i_ddr.memory[828][63:32] = 32'h00000013; // 800019e4: nop
            i_ddr.memory[829][31:0] = 32'h00530333; // 800019e8: add x6,x6,x5
            i_ddr.memory[829][63:32] = 32'h800180b7; // 800019ec: lui x1,0x80018
            i_ddr.memory[830][31:0] = 32'h40008093; // 800019f0: addi x1,x1,1024
            i_ddr.memory[830][63:32] = 32'h00000013; // 800019f4: nop
            i_ddr.memory[831][31:0] = 32'h00000013; // 800019f8: nop
            i_ddr.memory[831][63:32] = 32'h00000013; // 800019fc: nop
            i_ddr.memory[832][31:0] = 32'h00000013; // 80001a00: nop
            i_ddr.memory[832][63:32] = 32'h0000a203; // 80001a04: lw x4,0(x1)
            i_ddr.memory[833][31:0] = 32'h00000013; // 80001a08: nop
            i_ddr.memory[833][63:32] = 32'h00000013; // 80001a0c: nop
            i_ddr.memory[834][31:0] = 32'h00000013; // 80001a10: nop
            i_ddr.memory[834][63:32] = 32'h00000013; // 80001a14: nop
            i_ddr.memory[835][31:0] = 32'h00000013; // 80001a18: nop
            i_ddr.memory[835][63:32] = 32'h00000013; // 80001a1c: nop
            i_ddr.memory[836][31:0] = 32'h00410133; // 80001a20: add x2,x2,x4
            i_ddr.memory[836][63:32] = 32'h0020a223; // 80001a24: sw x2,4(x1)
            i_ddr.memory[837][31:0] = 32'h0040a283; // 80001a28: lw x5,4(x1)
            i_ddr.memory[837][63:32] = 32'h00000013; // 80001a2c: nop
            i_ddr.memory[838][31:0] = 32'h00000013; // 80001a30: nop
            i_ddr.memory[838][63:32] = 32'h00000013; // 80001a34: nop
            i_ddr.memory[839][31:0] = 32'h00000013; // 80001a38: nop
            i_ddr.memory[839][63:32] = 32'h00000013; // 80001a3c: nop
            i_ddr.memory[840][31:0] = 32'h00000013; // 80001a40: nop
            i_ddr.memory[840][63:32] = 32'h00530333; // 80001a44: add x6,x6,x5
            i_ddr.memory[841][31:0] = 32'h800180b7; // 80001a48: lui x1,0x80018
            i_ddr.memory[841][63:32] = 32'h41008093; // 80001a4c: addi x1,x1,1040
            i_ddr.memory[842][31:0] = 32'h00000013; // 80001a50: nop
            i_ddr.memory[842][63:32] = 32'h00000013; // 80001a54: nop
            i_ddr.memory[843][31:0] = 32'h00000013; // 80001a58: nop
            i_ddr.memory[843][63:32] = 32'h00000013; // 80001a5c: nop
            i_ddr.memory[844][31:0] = 32'h00000013; // 80001a60: nop
            i_ddr.memory[844][63:32] = 32'h0000a203; // 80001a64: lw x4,0(x1)
            i_ddr.memory[845][31:0] = 32'h00000013; // 80001a68: nop
            i_ddr.memory[845][63:32] = 32'h00000013; // 80001a6c: nop
            i_ddr.memory[846][31:0] = 32'h00000013; // 80001a70: nop
            i_ddr.memory[846][63:32] = 32'h00000013; // 80001a74: nop
            i_ddr.memory[847][31:0] = 32'h00000013; // 80001a78: nop
            i_ddr.memory[847][63:32] = 32'h00000013; // 80001a7c: nop
            i_ddr.memory[848][31:0] = 32'h00410133; // 80001a80: add x2,x2,x4
            i_ddr.memory[848][63:32] = 32'h0020a223; // 80001a84: sw x2,4(x1)
            i_ddr.memory[849][31:0] = 32'h0040a283; // 80001a88: lw x5,4(x1)
            i_ddr.memory[849][63:32] = 32'h00000013; // 80001a8c: nop
            i_ddr.memory[850][31:0] = 32'h00000013; // 80001a90: nop
            i_ddr.memory[850][63:32] = 32'h00000013; // 80001a94: nop
            i_ddr.memory[851][31:0] = 32'h00000013; // 80001a98: nop
            i_ddr.memory[851][63:32] = 32'h00000013; // 80001a9c: nop
            i_ddr.memory[852][31:0] = 32'h00000013; // 80001aa0: nop
            i_ddr.memory[852][63:32] = 32'h00530333; // 80001aa4: add x6,x6,x5
            i_ddr.memory[853][31:0] = 32'h800160b7; // 80001aa8: lui x1,0x80016
            i_ddr.memory[853][63:32] = 32'h54008093; // 80001aac: addi x1,x1,1344
            i_ddr.memory[854][31:0] = 32'h00000013; // 80001ab0: nop
            i_ddr.memory[854][63:32] = 32'h00000013; // 80001ab4: nop
            i_ddr.memory[855][31:0] = 32'h00000013; // 80001ab8: nop
            i_ddr.memory[855][63:32] = 32'h00000013; // 80001abc: nop
            i_ddr.memory[856][31:0] = 32'h00000013; // 80001ac0: nop
            i_ddr.memory[856][63:32] = 32'h00000013; // 80001ac4: nop
            i_ddr.memory[857][31:0] = 32'h0000a203; // 80001ac8: lw x4,0(x1)
            i_ddr.memory[857][63:32] = 32'h00000013; // 80001acc: nop
            i_ddr.memory[858][31:0] = 32'h00000013; // 80001ad0: nop
            i_ddr.memory[858][63:32] = 32'h00000013; // 80001ad4: nop
            i_ddr.memory[859][31:0] = 32'h00000013; // 80001ad8: nop
            i_ddr.memory[859][63:32] = 32'h00000013; // 80001adc: nop
            i_ddr.memory[860][31:0] = 32'h00000013; // 80001ae0: nop
            i_ddr.memory[860][63:32] = 32'h00410133; // 80001ae4: add x2,x2,x4
            i_ddr.memory[861][31:0] = 32'h0020a223; // 80001ae8: sw x2,4(x1)
            i_ddr.memory[861][63:32] = 32'h0040a283; // 80001aec: lw x5,4(x1)
            i_ddr.memory[862][31:0] = 32'h00000013; // 80001af0: nop
            i_ddr.memory[862][63:32] = 32'h00000013; // 80001af4: nop
            i_ddr.memory[863][31:0] = 32'h00000013; // 80001af8: nop
            i_ddr.memory[863][63:32] = 32'h00000013; // 80001afc: nop
            i_ddr.memory[864][31:0] = 32'h00000013; // 80001b00: nop
            i_ddr.memory[864][63:32] = 32'h00000013; // 80001b04: nop
            i_ddr.memory[865][31:0] = 32'h00530333; // 80001b08: add x6,x6,x5
            i_ddr.memory[865][63:32] = 32'h800140b7; // 80001b0c: lui x1,0x80014
            i_ddr.memory[866][31:0] = 32'h41008093; // 80001b10: addi x1,x1,1040
            i_ddr.memory[866][63:32] = 32'h00000013; // 80001b14: nop
            i_ddr.memory[867][31:0] = 32'h00000013; // 80001b18: nop
            i_ddr.memory[867][63:32] = 32'h00000013; // 80001b1c: nop
            i_ddr.memory[868][31:0] = 32'h00000013; // 80001b20: nop
            i_ddr.memory[868][63:32] = 32'h00000013; // 80001b24: nop
            i_ddr.memory[869][31:0] = 32'h00000013; // 80001b28: nop
            i_ddr.memory[869][63:32] = 32'h00000013; // 80001b2c: nop
            i_ddr.memory[870][31:0] = 32'h0000a203; // 80001b30: lw x4,0(x1)
            i_ddr.memory[870][63:32] = 32'h00000013; // 80001b34: nop
            i_ddr.memory[871][31:0] = 32'h00000013; // 80001b38: nop
            i_ddr.memory[871][63:32] = 32'h00000013; // 80001b3c: nop
            i_ddr.memory[872][31:0] = 32'h00000013; // 80001b40: nop
            i_ddr.memory[872][63:32] = 32'h00000013; // 80001b44: nop
            i_ddr.memory[873][31:0] = 32'h00000013; // 80001b48: nop
            i_ddr.memory[873][63:32] = 32'h00410133; // 80001b4c: add x2,x2,x4
            i_ddr.memory[874][31:0] = 32'h0020a223; // 80001b50: sw x2,4(x1)
            i_ddr.memory[874][63:32] = 32'h0040a283; // 80001b54: lw x5,4(x1)
            i_ddr.memory[875][31:0] = 32'h00000013; // 80001b58: nop
            i_ddr.memory[875][63:32] = 32'h00000013; // 80001b5c: nop
            i_ddr.memory[876][31:0] = 32'h00000013; // 80001b60: nop
            i_ddr.memory[876][63:32] = 32'h00000013; // 80001b64: nop
            i_ddr.memory[877][31:0] = 32'h00000013; // 80001b68: nop
            i_ddr.memory[877][63:32] = 32'h00000013; // 80001b6c: nop
            i_ddr.memory[878][31:0] = 32'h00530333; // 80001b70: add x6,x6,x5
            i_ddr.memory[878][63:32] = 32'h800160b7; // 80001b74: lui x1,0x80016
            i_ddr.memory[879][31:0] = 32'h54808093; // 80001b78: addi x1,x1,1352
            i_ddr.memory[879][63:32] = 32'h00000013; // 80001b7c: nop
            i_ddr.memory[880][31:0] = 32'h00000013; // 80001b80: nop
            i_ddr.memory[880][63:32] = 32'h00000013; // 80001b84: nop
            i_ddr.memory[881][31:0] = 32'h00000013; // 80001b88: nop
            i_ddr.memory[881][63:32] = 32'h00000013; // 80001b8c: nop
            i_ddr.memory[882][31:0] = 32'h00000013; // 80001b90: nop
            i_ddr.memory[882][63:32] = 32'h00000013; // 80001b94: nop
            i_ddr.memory[883][31:0] = 32'h00000013; // 80001b98: nop
            i_ddr.memory[883][63:32] = 32'h0000a203; // 80001b9c: lw x4,0(x1)
            i_ddr.memory[884][31:0] = 32'h00000013; // 80001ba0: nop
            i_ddr.memory[884][63:32] = 32'h00000013; // 80001ba4: nop
            i_ddr.memory[885][31:0] = 32'h00000013; // 80001ba8: nop
            i_ddr.memory[885][63:32] = 32'h00000013; // 80001bac: nop
            i_ddr.memory[886][31:0] = 32'h00000013; // 80001bb0: nop
            i_ddr.memory[886][63:32] = 32'h00000013; // 80001bb4: nop
            i_ddr.memory[887][31:0] = 32'h00410133; // 80001bb8: add x2,x2,x4
            i_ddr.memory[887][63:32] = 32'h0020a223; // 80001bbc: sw x2,4(x1)
            i_ddr.memory[888][31:0] = 32'h0040a283; // 80001bc0: lw x5,4(x1)
            i_ddr.memory[888][63:32] = 32'h00000013; // 80001bc4: nop
            i_ddr.memory[889][31:0] = 32'h00000013; // 80001bc8: nop
            i_ddr.memory[889][63:32] = 32'h00000013; // 80001bcc: nop
            i_ddr.memory[890][31:0] = 32'h00000013; // 80001bd0: nop
            i_ddr.memory[890][63:32] = 32'h00000013; // 80001bd4: nop
            i_ddr.memory[891][31:0] = 32'h00000013; // 80001bd8: nop
            i_ddr.memory[891][63:32] = 32'h00530333; // 80001bdc: add x6,x6,x5
            i_ddr.memory[892][31:0] = 32'h800100b7; // 80001be0: lui x1,0x80010
            i_ddr.memory[892][63:32] = 32'h40808093; // 80001be4: addi x1,x1,1032
            i_ddr.memory[893][31:0] = 32'h00000013; // 80001be8: nop
            i_ddr.memory[893][63:32] = 32'h00000013; // 80001bec: nop
            i_ddr.memory[894][31:0] = 32'h00000013; // 80001bf0: nop
            i_ddr.memory[894][63:32] = 32'h00000013; // 80001bf4: nop
            i_ddr.memory[895][31:0] = 32'h00000013; // 80001bf8: nop
            i_ddr.memory[895][63:32] = 32'h00000013; // 80001bfc: nop
            i_ddr.memory[896][31:0] = 32'h00000013; // 80001c00: nop
            i_ddr.memory[896][63:32] = 32'h00000013; // 80001c04: nop
            i_ddr.memory[897][31:0] = 32'h00000013; // 80001c08: nop
            i_ddr.memory[897][63:32] = 32'h0000a203; // 80001c0c: lw x4,0(x1)
            i_ddr.memory[898][31:0] = 32'h00000013; // 80001c10: nop
            i_ddr.memory[898][63:32] = 32'h00000013; // 80001c14: nop
            i_ddr.memory[899][31:0] = 32'h00000013; // 80001c18: nop
            i_ddr.memory[899][63:32] = 32'h00000013; // 80001c1c: nop
            i_ddr.memory[900][31:0] = 32'h00000013; // 80001c20: nop
            i_ddr.memory[900][63:32] = 32'h00000013; // 80001c24: nop
            i_ddr.memory[901][31:0] = 32'h00410133; // 80001c28: add x2,x2,x4
            i_ddr.memory[901][63:32] = 32'h0020a223; // 80001c2c: sw x2,4(x1)
            i_ddr.memory[902][31:0] = 32'h0040a283; // 80001c30: lw x5,4(x1)
            i_ddr.memory[902][63:32] = 32'h00000013; // 80001c34: nop
            i_ddr.memory[903][31:0] = 32'h00000013; // 80001c38: nop
            i_ddr.memory[903][63:32] = 32'h00000013; // 80001c3c: nop
            i_ddr.memory[904][31:0] = 32'h00000013; // 80001c40: nop
            i_ddr.memory[904][63:32] = 32'h00000013; // 80001c44: nop
            i_ddr.memory[905][31:0] = 32'h00000013; // 80001c48: nop
            i_ddr.memory[905][63:32] = 32'h00530333; // 80001c4c: add x6,x6,x5
            i_ddr.memory[906][31:0] = 32'h800200b7; // 80001c50: lui x1,0x80020
            i_ddr.memory[906][63:32] = 32'h8e808093; // 80001c54: addi x1,x1,-1816
            i_ddr.memory[907][31:0] = 32'h00000013; // 80001c58: nop
            i_ddr.memory[907][63:32] = 32'h00000013; // 80001c5c: nop
            i_ddr.memory[908][31:0] = 32'h0000a203; // 80001c60: lw x4,0(x1)
            i_ddr.memory[908][63:32] = 32'h00000013; // 80001c64: nop
            i_ddr.memory[909][31:0] = 32'h00000013; // 80001c68: nop
            i_ddr.memory[909][63:32] = 32'h00000013; // 80001c6c: nop
            i_ddr.memory[910][31:0] = 32'h00000013; // 80001c70: nop
            i_ddr.memory[910][63:32] = 32'h00000013; // 80001c74: nop
            i_ddr.memory[911][31:0] = 32'h00000013; // 80001c78: nop
            i_ddr.memory[911][63:32] = 32'h00410133; // 80001c7c: add x2,x2,x4
            i_ddr.memory[912][31:0] = 32'h0020a223; // 80001c80: sw x2,4(x1)
            i_ddr.memory[912][63:32] = 32'h0040a283; // 80001c84: lw x5,4(x1)
            i_ddr.memory[913][31:0] = 32'h00000013; // 80001c88: nop
            i_ddr.memory[913][63:32] = 32'h00000013; // 80001c8c: nop
            i_ddr.memory[914][31:0] = 32'h00000013; // 80001c90: nop
            i_ddr.memory[914][63:32] = 32'h00000013; // 80001c94: nop
            i_ddr.memory[915][31:0] = 32'h00000013; // 80001c98: nop
            i_ddr.memory[915][63:32] = 32'h00000013; // 80001c9c: nop
            i_ddr.memory[916][31:0] = 32'h00530333; // 80001ca0: add x6,x6,x5
            i_ddr.memory[916][63:32] = 32'h8001d0b7; // 80001ca4: lui x1,0x8001d
            i_ddr.memory[917][31:0] = 32'ha4808093; // 80001ca8: addi x1,x1,-1464
            i_ddr.memory[917][63:32] = 32'h00000013; // 80001cac: nop
            i_ddr.memory[918][31:0] = 32'h00000013; // 80001cb0: nop
            i_ddr.memory[918][63:32] = 32'h00000013; // 80001cb4: nop
            i_ddr.memory[919][31:0] = 32'h0000a203; // 80001cb8: lw x4,0(x1)
            i_ddr.memory[919][63:32] = 32'h00000013; // 80001cbc: nop
            i_ddr.memory[920][31:0] = 32'h00000013; // 80001cc0: nop
            i_ddr.memory[920][63:32] = 32'h00000013; // 80001cc4: nop
            i_ddr.memory[921][31:0] = 32'h00000013; // 80001cc8: nop
            i_ddr.memory[921][63:32] = 32'h00000013; // 80001ccc: nop
            i_ddr.memory[922][31:0] = 32'h00000013; // 80001cd0: nop
            i_ddr.memory[922][63:32] = 32'h00410133; // 80001cd4: add x2,x2,x4
            i_ddr.memory[923][31:0] = 32'h0020a223; // 80001cd8: sw x2,4(x1)
            i_ddr.memory[923][63:32] = 32'h0040a283; // 80001cdc: lw x5,4(x1)
            i_ddr.memory[924][31:0] = 32'h00000013; // 80001ce0: nop
            i_ddr.memory[924][63:32] = 32'h00000013; // 80001ce4: nop
            i_ddr.memory[925][31:0] = 32'h00000013; // 80001ce8: nop
            i_ddr.memory[925][63:32] = 32'h00000013; // 80001cec: nop
            i_ddr.memory[926][31:0] = 32'h00000013; // 80001cf0: nop
            i_ddr.memory[926][63:32] = 32'h00000013; // 80001cf4: nop
            i_ddr.memory[927][31:0] = 32'h00530333; // 80001cf8: add x6,x6,x5
            i_ddr.memory[927][63:32] = 32'h800130b7; // 80001cfc: lui x1,0x80013
            i_ddr.memory[928][31:0] = 32'h98008093; // 80001d00: addi x1,x1,-1664
            i_ddr.memory[928][63:32] = 32'h00000013; // 80001d04: nop
            i_ddr.memory[929][31:0] = 32'h00000013; // 80001d08: nop
            i_ddr.memory[929][63:32] = 32'h00000013; // 80001d0c: nop
            i_ddr.memory[930][31:0] = 32'h00000013; // 80001d10: nop
            i_ddr.memory[930][63:32] = 32'h0000a203; // 80001d14: lw x4,0(x1)
            i_ddr.memory[931][31:0] = 32'h00000013; // 80001d18: nop
            i_ddr.memory[931][63:32] = 32'h00000013; // 80001d1c: nop
            i_ddr.memory[932][31:0] = 32'h00000013; // 80001d20: nop
            i_ddr.memory[932][63:32] = 32'h00000013; // 80001d24: nop
            i_ddr.memory[933][31:0] = 32'h00000013; // 80001d28: nop
            i_ddr.memory[933][63:32] = 32'h00000013; // 80001d2c: nop
            i_ddr.memory[934][31:0] = 32'h00410133; // 80001d30: add x2,x2,x4
            i_ddr.memory[934][63:32] = 32'h0020a223; // 80001d34: sw x2,4(x1)
            i_ddr.memory[935][31:0] = 32'h0040a283; // 80001d38: lw x5,4(x1)
            i_ddr.memory[935][63:32] = 32'h00000013; // 80001d3c: nop
            i_ddr.memory[936][31:0] = 32'h00000013; // 80001d40: nop
            i_ddr.memory[936][63:32] = 32'h00000013; // 80001d44: nop
            i_ddr.memory[937][31:0] = 32'h00000013; // 80001d48: nop
            i_ddr.memory[937][63:32] = 32'h00000013; // 80001d4c: nop
            i_ddr.memory[938][31:0] = 32'h00000013; // 80001d50: nop
            i_ddr.memory[938][63:32] = 32'h00530333; // 80001d54: add x6,x6,x5
            i_ddr.memory[939][31:0] = 32'h800110b7; // 80001d58: lui x1,0x80011
            i_ddr.memory[939][63:32] = 32'ha5008093; // 80001d5c: addi x1,x1,-1456
            i_ddr.memory[940][31:0] = 32'h00000013; // 80001d60: nop
            i_ddr.memory[940][63:32] = 32'h00000013; // 80001d64: nop
            i_ddr.memory[941][31:0] = 32'h00000013; // 80001d68: nop
            i_ddr.memory[941][63:32] = 32'h00000013; // 80001d6c: nop
            i_ddr.memory[942][31:0] = 32'h00000013; // 80001d70: nop
            i_ddr.memory[942][63:32] = 32'h0000a203; // 80001d74: lw x4,0(x1)
            i_ddr.memory[943][31:0] = 32'h00000013; // 80001d78: nop
            i_ddr.memory[943][63:32] = 32'h00000013; // 80001d7c: nop
            i_ddr.memory[944][31:0] = 32'h00000013; // 80001d80: nop
            i_ddr.memory[944][63:32] = 32'h00000013; // 80001d84: nop
            i_ddr.memory[945][31:0] = 32'h00000013; // 80001d88: nop
            i_ddr.memory[945][63:32] = 32'h00000013; // 80001d8c: nop
            i_ddr.memory[946][31:0] = 32'h00410133; // 80001d90: add x2,x2,x4
            i_ddr.memory[946][63:32] = 32'h0020a223; // 80001d94: sw x2,4(x1)
            i_ddr.memory[947][31:0] = 32'h0040a283; // 80001d98: lw x5,4(x1)
            i_ddr.memory[947][63:32] = 32'h00000013; // 80001d9c: nop
            i_ddr.memory[948][31:0] = 32'h00000013; // 80001da0: nop
            i_ddr.memory[948][63:32] = 32'h00000013; // 80001da4: nop
            i_ddr.memory[949][31:0] = 32'h00000013; // 80001da8: nop
            i_ddr.memory[949][63:32] = 32'h00000013; // 80001dac: nop
            i_ddr.memory[950][31:0] = 32'h00000013; // 80001db0: nop
            i_ddr.memory[950][63:32] = 32'h00530333; // 80001db4: add x6,x6,x5
            i_ddr.memory[951][31:0] = 32'h8001a0b7; // 80001db8: lui x1,0x8001a
            i_ddr.memory[951][63:32] = 32'h54008093; // 80001dbc: addi x1,x1,1344
            i_ddr.memory[952][31:0] = 32'h00000013; // 80001dc0: nop
            i_ddr.memory[952][63:32] = 32'h00000013; // 80001dc4: nop
            i_ddr.memory[953][31:0] = 32'h00000013; // 80001dc8: nop
            i_ddr.memory[953][63:32] = 32'h00000013; // 80001dcc: nop
            i_ddr.memory[954][31:0] = 32'h00000013; // 80001dd0: nop
            i_ddr.memory[954][63:32] = 32'h00000013; // 80001dd4: nop
            i_ddr.memory[955][31:0] = 32'h0000a203; // 80001dd8: lw x4,0(x1)
            i_ddr.memory[955][63:32] = 32'h00000013; // 80001ddc: nop
            i_ddr.memory[956][31:0] = 32'h00000013; // 80001de0: nop
            i_ddr.memory[956][63:32] = 32'h00000013; // 80001de4: nop
            i_ddr.memory[957][31:0] = 32'h00000013; // 80001de8: nop
            i_ddr.memory[957][63:32] = 32'h00000013; // 80001dec: nop
            i_ddr.memory[958][31:0] = 32'h00000013; // 80001df0: nop
            i_ddr.memory[958][63:32] = 32'h00410133; // 80001df4: add x2,x2,x4
            i_ddr.memory[959][31:0] = 32'h0020a223; // 80001df8: sw x2,4(x1)
            i_ddr.memory[959][63:32] = 32'h0040a283; // 80001dfc: lw x5,4(x1)
            i_ddr.memory[960][31:0] = 32'h00000013; // 80001e00: nop
            i_ddr.memory[960][63:32] = 32'h00000013; // 80001e04: nop
            i_ddr.memory[961][31:0] = 32'h00000013; // 80001e08: nop
            i_ddr.memory[961][63:32] = 32'h00000013; // 80001e0c: nop
            i_ddr.memory[962][31:0] = 32'h00000013; // 80001e10: nop
            i_ddr.memory[962][63:32] = 32'h00000013; // 80001e14: nop
            i_ddr.memory[963][31:0] = 32'h00530333; // 80001e18: add x6,x6,x5
            i_ddr.memory[963][63:32] = 32'h800150b7; // 80001e1c: lui x1,0x80015
            i_ddr.memory[964][31:0] = 32'ha4808093; // 80001e20: addi x1,x1,-1464
            i_ddr.memory[964][63:32] = 32'h00000013; // 80001e24: nop
            i_ddr.memory[965][31:0] = 32'h00000013; // 80001e28: nop
            i_ddr.memory[965][63:32] = 32'h00000013; // 80001e2c: nop
            i_ddr.memory[966][31:0] = 32'h00000013; // 80001e30: nop
            i_ddr.memory[966][63:32] = 32'h00000013; // 80001e34: nop
            i_ddr.memory[967][31:0] = 32'h00000013; // 80001e38: nop
            i_ddr.memory[967][63:32] = 32'h00000013; // 80001e3c: nop
            i_ddr.memory[968][31:0] = 32'h0000a203; // 80001e40: lw x4,0(x1)
            i_ddr.memory[968][63:32] = 32'h00000013; // 80001e44: nop
            i_ddr.memory[969][31:0] = 32'h00000013; // 80001e48: nop
            i_ddr.memory[969][63:32] = 32'h00000013; // 80001e4c: nop
            i_ddr.memory[970][31:0] = 32'h00000013; // 80001e50: nop
            i_ddr.memory[970][63:32] = 32'h00000013; // 80001e54: nop
            i_ddr.memory[971][31:0] = 32'h00000013; // 80001e58: nop
            i_ddr.memory[971][63:32] = 32'h00410133; // 80001e5c: add x2,x2,x4
            i_ddr.memory[972][31:0] = 32'h0020a223; // 80001e60: sw x2,4(x1)
            i_ddr.memory[972][63:32] = 32'h0040a283; // 80001e64: lw x5,4(x1)
            i_ddr.memory[973][31:0] = 32'h00000013; // 80001e68: nop
            i_ddr.memory[973][63:32] = 32'h00000013; // 80001e6c: nop
            i_ddr.memory[974][31:0] = 32'h00000013; // 80001e70: nop
            i_ddr.memory[974][63:32] = 32'h00000013; // 80001e74: nop
            i_ddr.memory[975][31:0] = 32'h00000013; // 80001e78: nop
            i_ddr.memory[975][63:32] = 32'h00000013; // 80001e7c: nop
            i_ddr.memory[976][31:0] = 32'h00530333; // 80001e80: add x6,x6,x5
            i_ddr.memory[976][63:32] = 32'h800140b7; // 80001e84: lui x1,0x80014
            i_ddr.memory[977][31:0] = 32'h8e008093; // 80001e88: addi x1,x1,-1824
            i_ddr.memory[977][63:32] = 32'h00000013; // 80001e8c: nop
            i_ddr.memory[978][31:0] = 32'h00000013; // 80001e90: nop
            i_ddr.memory[978][63:32] = 32'h00000013; // 80001e94: nop
            i_ddr.memory[979][31:0] = 32'h00000013; // 80001e98: nop
            i_ddr.memory[979][63:32] = 32'h00000013; // 80001e9c: nop
            i_ddr.memory[980][31:0] = 32'h00000013; // 80001ea0: nop
            i_ddr.memory[980][63:32] = 32'h00000013; // 80001ea4: nop
            i_ddr.memory[981][31:0] = 32'h00000013; // 80001ea8: nop
            i_ddr.memory[981][63:32] = 32'h0000a203; // 80001eac: lw x4,0(x1)
            i_ddr.memory[982][31:0] = 32'h00000013; // 80001eb0: nop
            i_ddr.memory[982][63:32] = 32'h00000013; // 80001eb4: nop
            i_ddr.memory[983][31:0] = 32'h00000013; // 80001eb8: nop
            i_ddr.memory[983][63:32] = 32'h00000013; // 80001ebc: nop
            i_ddr.memory[984][31:0] = 32'h00000013; // 80001ec0: nop
            i_ddr.memory[984][63:32] = 32'h00000013; // 80001ec4: nop
            i_ddr.memory[985][31:0] = 32'h00410133; // 80001ec8: add x2,x2,x4
            i_ddr.memory[985][63:32] = 32'h0020a223; // 80001ecc: sw x2,4(x1)
            i_ddr.memory[986][31:0] = 32'h0040a283; // 80001ed0: lw x5,4(x1)
            i_ddr.memory[986][63:32] = 32'h00000013; // 80001ed4: nop
            i_ddr.memory[987][31:0] = 32'h00000013; // 80001ed8: nop
            i_ddr.memory[987][63:32] = 32'h00000013; // 80001edc: nop
            i_ddr.memory[988][31:0] = 32'h00000013; // 80001ee0: nop
            i_ddr.memory[988][63:32] = 32'h00000013; // 80001ee4: nop
            i_ddr.memory[989][31:0] = 32'h00000013; // 80001ee8: nop
            i_ddr.memory[989][63:32] = 32'h00530333; // 80001eec: add x6,x6,x5
            i_ddr.memory[990][31:0] = 32'h8001c0b7; // 80001ef0: lui x1,0x8001c
            i_ddr.memory[990][63:32] = 32'h8f008093; // 80001ef4: addi x1,x1,-1808
            i_ddr.memory[991][31:0] = 32'h00000013; // 80001ef8: nop
            i_ddr.memory[991][63:32] = 32'h00000013; // 80001efc: nop
            i_ddr.memory[992][31:0] = 32'h00000013; // 80001f00: nop
            i_ddr.memory[992][63:32] = 32'h00000013; // 80001f04: nop
            i_ddr.memory[993][31:0] = 32'h00000013; // 80001f08: nop
            i_ddr.memory[993][63:32] = 32'h00000013; // 80001f0c: nop
            i_ddr.memory[994][31:0] = 32'h00000013; // 80001f10: nop
            i_ddr.memory[994][63:32] = 32'h00000013; // 80001f14: nop
            i_ddr.memory[995][31:0] = 32'h00000013; // 80001f18: nop
            i_ddr.memory[995][63:32] = 32'h0000a203; // 80001f1c: lw x4,0(x1)
            i_ddr.memory[996][31:0] = 32'h00000013; // 80001f20: nop
            i_ddr.memory[996][63:32] = 32'h00000013; // 80001f24: nop
            i_ddr.memory[997][31:0] = 32'h00000013; // 80001f28: nop
            i_ddr.memory[997][63:32] = 32'h00000013; // 80001f2c: nop
            i_ddr.memory[998][31:0] = 32'h00000013; // 80001f30: nop
            i_ddr.memory[998][63:32] = 32'h00000013; // 80001f34: nop
            i_ddr.memory[999][31:0] = 32'h00410133; // 80001f38: add x2,x2,x4
            i_ddr.memory[999][63:32] = 32'h0020a223; // 80001f3c: sw x2,4(x1)
            i_ddr.memory[1000][31:0] = 32'h0040a283; // 80001f40: lw x5,4(x1)
            i_ddr.memory[1000][63:32] = 32'h00000013; // 80001f44: nop
            i_ddr.memory[1001][31:0] = 32'h00000013; // 80001f48: nop
            i_ddr.memory[1001][63:32] = 32'h00000013; // 80001f4c: nop
            i_ddr.memory[1002][31:0] = 32'h00000013; // 80001f50: nop
            i_ddr.memory[1002][63:32] = 32'h00000013; // 80001f54: nop
            i_ddr.memory[1003][31:0] = 32'h00000013; // 80001f58: nop
            i_ddr.memory[1003][63:32] = 32'h00530333; // 80001f5c: add x6,x6,x5
            i_ddr.memory[1004][31:0] = 32'h800140b7; // 80001f60: lui x1,0x80014
            i_ddr.memory[1004][63:32] = 32'hcd008093; // 80001f64: addi x1,x1,-816
            i_ddr.memory[1005][31:0] = 32'h00000013; // 80001f68: nop
            i_ddr.memory[1005][63:32] = 32'h00000013; // 80001f6c: nop
            i_ddr.memory[1006][31:0] = 32'h0000a203; // 80001f70: lw x4,0(x1)
            i_ddr.memory[1006][63:32] = 32'h00000013; // 80001f74: nop
            i_ddr.memory[1007][31:0] = 32'h00000013; // 80001f78: nop
            i_ddr.memory[1007][63:32] = 32'h00000013; // 80001f7c: nop
            i_ddr.memory[1008][31:0] = 32'h00000013; // 80001f80: nop
            i_ddr.memory[1008][63:32] = 32'h00000013; // 80001f84: nop
            i_ddr.memory[1009][31:0] = 32'h00000013; // 80001f88: nop
            i_ddr.memory[1009][63:32] = 32'h00410133; // 80001f8c: add x2,x2,x4
            i_ddr.memory[1010][31:0] = 32'h0020a223; // 80001f90: sw x2,4(x1)
            i_ddr.memory[1010][63:32] = 32'h0040a283; // 80001f94: lw x5,4(x1)
            i_ddr.memory[1011][31:0] = 32'h00000013; // 80001f98: nop
            i_ddr.memory[1011][63:32] = 32'h00000013; // 80001f9c: nop
            i_ddr.memory[1012][31:0] = 32'h00000013; // 80001fa0: nop
            i_ddr.memory[1012][63:32] = 32'h00000013; // 80001fa4: nop
            i_ddr.memory[1013][31:0] = 32'h00000013; // 80001fa8: nop
            i_ddr.memory[1013][63:32] = 32'h00000013; // 80001fac: nop
            i_ddr.memory[1014][31:0] = 32'h00530333; // 80001fb0: add x6,x6,x5
            i_ddr.memory[1014][63:32] = 32'h800200b7; // 80001fb4: lui x1,0x80020
            i_ddr.memory[1015][31:0] = 32'hcd008093; // 80001fb8: addi x1,x1,-816
            i_ddr.memory[1015][63:32] = 32'h00000013; // 80001fbc: nop
            i_ddr.memory[1016][31:0] = 32'h00000013; // 80001fc0: nop
            i_ddr.memory[1016][63:32] = 32'h00000013; // 80001fc4: nop
            i_ddr.memory[1017][31:0] = 32'h0000a203; // 80001fc8: lw x4,0(x1)
            i_ddr.memory[1017][63:32] = 32'h00000013; // 80001fcc: nop
            i_ddr.memory[1018][31:0] = 32'h00000013; // 80001fd0: nop
            i_ddr.memory[1018][63:32] = 32'h00000013; // 80001fd4: nop
            i_ddr.memory[1019][31:0] = 32'h00000013; // 80001fd8: nop
            i_ddr.memory[1019][63:32] = 32'h00000013; // 80001fdc: nop
            i_ddr.memory[1020][31:0] = 32'h00000013; // 80001fe0: nop
            i_ddr.memory[1020][63:32] = 32'h00410133; // 80001fe4: add x2,x2,x4
            i_ddr.memory[1021][31:0] = 32'h0020a223; // 80001fe8: sw x2,4(x1)
            i_ddr.memory[1021][63:32] = 32'h0040a283; // 80001fec: lw x5,4(x1)
            i_ddr.memory[1022][31:0] = 32'h00000013; // 80001ff0: nop
            i_ddr.memory[1022][63:32] = 32'h00000013; // 80001ff4: nop
            i_ddr.memory[1023][31:0] = 32'h00000013; // 80001ff8: nop
            i_ddr.memory[1023][63:32] = 32'h00000013; // 80001ffc: nop
            i_ddr.memory[1024][31:0] = 32'h00000013; // 80002000: nop
            i_ddr.memory[1024][63:32] = 32'h00000013; // 80002004: nop
            i_ddr.memory[1025][31:0] = 32'h00530333; // 80002008: add x6,x6,x5
            i_ddr.memory[1025][63:32] = 32'h800140b7; // 8000200c: lui x1,0x80014
            i_ddr.memory[1026][31:0] = 32'hcc008093; // 80002010: addi x1,x1,-832
            i_ddr.memory[1026][63:32] = 32'h00000013; // 80002014: nop
            i_ddr.memory[1027][31:0] = 32'h00000013; // 80002018: nop
            i_ddr.memory[1027][63:32] = 32'h00000013; // 8000201c: nop
            i_ddr.memory[1028][31:0] = 32'h00000013; // 80002020: nop
            i_ddr.memory[1028][63:32] = 32'h0000a203; // 80002024: lw x4,0(x1)
            i_ddr.memory[1029][31:0] = 32'h00000013; // 80002028: nop
            i_ddr.memory[1029][63:32] = 32'h00000013; // 8000202c: nop
            i_ddr.memory[1030][31:0] = 32'h00000013; // 80002030: nop
            i_ddr.memory[1030][63:32] = 32'h00000013; // 80002034: nop
            i_ddr.memory[1031][31:0] = 32'h00000013; // 80002038: nop
            i_ddr.memory[1031][63:32] = 32'h00000013; // 8000203c: nop
            i_ddr.memory[1032][31:0] = 32'h00410133; // 80002040: add x2,x2,x4
            i_ddr.memory[1032][63:32] = 32'h0020a223; // 80002044: sw x2,4(x1)
            i_ddr.memory[1033][31:0] = 32'h0040a283; // 80002048: lw x5,4(x1)
            i_ddr.memory[1033][63:32] = 32'h00000013; // 8000204c: nop
            i_ddr.memory[1034][31:0] = 32'h00000013; // 80002050: nop
            i_ddr.memory[1034][63:32] = 32'h00000013; // 80002054: nop
            i_ddr.memory[1035][31:0] = 32'h00000013; // 80002058: nop
            i_ddr.memory[1035][63:32] = 32'h00000013; // 8000205c: nop
            i_ddr.memory[1036][31:0] = 32'h00000013; // 80002060: nop
            i_ddr.memory[1036][63:32] = 32'h00530333; // 80002064: add x6,x6,x5
            i_ddr.memory[1037][31:0] = 32'h800140b7; // 80002068: lui x1,0x80014
            i_ddr.memory[1037][63:32] = 32'h41008093; // 8000206c: addi x1,x1,1040
            i_ddr.memory[1038][31:0] = 32'h00000013; // 80002070: nop
            i_ddr.memory[1038][63:32] = 32'h00000013; // 80002074: nop
            i_ddr.memory[1039][31:0] = 32'h00000013; // 80002078: nop
            i_ddr.memory[1039][63:32] = 32'h00000013; // 8000207c: nop
            i_ddr.memory[1040][31:0] = 32'h00000013; // 80002080: nop
            i_ddr.memory[1040][63:32] = 32'h0000a203; // 80002084: lw x4,0(x1)
            i_ddr.memory[1041][31:0] = 32'h00000013; // 80002088: nop
            i_ddr.memory[1041][63:32] = 32'h00000013; // 8000208c: nop
            i_ddr.memory[1042][31:0] = 32'h00000013; // 80002090: nop
            i_ddr.memory[1042][63:32] = 32'h00000013; // 80002094: nop
            i_ddr.memory[1043][31:0] = 32'h00000013; // 80002098: nop
            i_ddr.memory[1043][63:32] = 32'h00000013; // 8000209c: nop
            i_ddr.memory[1044][31:0] = 32'h00410133; // 800020a0: add x2,x2,x4
            i_ddr.memory[1044][63:32] = 32'h0020a223; // 800020a4: sw x2,4(x1)
            i_ddr.memory[1045][31:0] = 32'h0040a283; // 800020a8: lw x5,4(x1)
            i_ddr.memory[1045][63:32] = 32'h00000013; // 800020ac: nop
            i_ddr.memory[1046][31:0] = 32'h00000013; // 800020b0: nop
            i_ddr.memory[1046][63:32] = 32'h00000013; // 800020b4: nop
            i_ddr.memory[1047][31:0] = 32'h00000013; // 800020b8: nop
            i_ddr.memory[1047][63:32] = 32'h00000013; // 800020bc: nop
            i_ddr.memory[1048][31:0] = 32'h00000013; // 800020c0: nop
            i_ddr.memory[1048][63:32] = 32'h00530333; // 800020c4: add x6,x6,x5
            i_ddr.memory[1049][31:0] = 32'h800170b7; // 800020c8: lui x1,0x80017
            i_ddr.memory[1049][63:32] = 32'h99008093; // 800020cc: addi x1,x1,-1648
            i_ddr.memory[1050][31:0] = 32'h00000013; // 800020d0: nop
            i_ddr.memory[1050][63:32] = 32'h00000013; // 800020d4: nop
            i_ddr.memory[1051][31:0] = 32'h00000013; // 800020d8: nop
            i_ddr.memory[1051][63:32] = 32'h00000013; // 800020dc: nop
            i_ddr.memory[1052][31:0] = 32'h00000013; // 800020e0: nop
            i_ddr.memory[1052][63:32] = 32'h00000013; // 800020e4: nop
            i_ddr.memory[1053][31:0] = 32'h0000a203; // 800020e8: lw x4,0(x1)
            i_ddr.memory[1053][63:32] = 32'h00000013; // 800020ec: nop
            i_ddr.memory[1054][31:0] = 32'h00000013; // 800020f0: nop
            i_ddr.memory[1054][63:32] = 32'h00000013; // 800020f4: nop
            i_ddr.memory[1055][31:0] = 32'h00000013; // 800020f8: nop
            i_ddr.memory[1055][63:32] = 32'h00000013; // 800020fc: nop
            i_ddr.memory[1056][31:0] = 32'h00000013; // 80002100: nop
            i_ddr.memory[1056][63:32] = 32'h00410133; // 80002104: add x2,x2,x4
            i_ddr.memory[1057][31:0] = 32'h0020a223; // 80002108: sw x2,4(x1)
            i_ddr.memory[1057][63:32] = 32'h0040a283; // 8000210c: lw x5,4(x1)
            i_ddr.memory[1058][31:0] = 32'h00000013; // 80002110: nop
            i_ddr.memory[1058][63:32] = 32'h00000013; // 80002114: nop
            i_ddr.memory[1059][31:0] = 32'h00000013; // 80002118: nop
            i_ddr.memory[1059][63:32] = 32'h00000013; // 8000211c: nop
            i_ddr.memory[1060][31:0] = 32'h00000013; // 80002120: nop
            i_ddr.memory[1060][63:32] = 32'h00000013; // 80002124: nop
            i_ddr.memory[1061][31:0] = 32'h00530333; // 80002128: add x6,x6,x5
            i_ddr.memory[1061][63:32] = 32'h800140b7; // 8000212c: lui x1,0x80014
            i_ddr.memory[1062][31:0] = 32'h8e808093; // 80002130: addi x1,x1,-1816
            i_ddr.memory[1062][63:32] = 32'h00000013; // 80002134: nop
            i_ddr.memory[1063][31:0] = 32'h00000013; // 80002138: nop
            i_ddr.memory[1063][63:32] = 32'h00000013; // 8000213c: nop
            i_ddr.memory[1064][31:0] = 32'h00000013; // 80002140: nop
            i_ddr.memory[1064][63:32] = 32'h00000013; // 80002144: nop
            i_ddr.memory[1065][31:0] = 32'h00000013; // 80002148: nop
            i_ddr.memory[1065][63:32] = 32'h00000013; // 8000214c: nop
            i_ddr.memory[1066][31:0] = 32'h0000a203; // 80002150: lw x4,0(x1)
            i_ddr.memory[1066][63:32] = 32'h00000013; // 80002154: nop
            i_ddr.memory[1067][31:0] = 32'h00000013; // 80002158: nop
            i_ddr.memory[1067][63:32] = 32'h00000013; // 8000215c: nop
            i_ddr.memory[1068][31:0] = 32'h00000013; // 80002160: nop
            i_ddr.memory[1068][63:32] = 32'h00000013; // 80002164: nop
            i_ddr.memory[1069][31:0] = 32'h00000013; // 80002168: nop
            i_ddr.memory[1069][63:32] = 32'h00410133; // 8000216c: add x2,x2,x4
            i_ddr.memory[1070][31:0] = 32'h0020a223; // 80002170: sw x2,4(x1)
            i_ddr.memory[1070][63:32] = 32'h0040a283; // 80002174: lw x5,4(x1)
            i_ddr.memory[1071][31:0] = 32'h00000013; // 80002178: nop
            i_ddr.memory[1071][63:32] = 32'h00000013; // 8000217c: nop
            i_ddr.memory[1072][31:0] = 32'h00000013; // 80002180: nop
            i_ddr.memory[1072][63:32] = 32'h00000013; // 80002184: nop
            i_ddr.memory[1073][31:0] = 32'h00000013; // 80002188: nop
            i_ddr.memory[1073][63:32] = 32'h00000013; // 8000218c: nop
            i_ddr.memory[1074][31:0] = 32'h00530333; // 80002190: add x6,x6,x5
            i_ddr.memory[1074][63:32] = 32'h800190b7; // 80002194: lui x1,0x80019
            i_ddr.memory[1075][31:0] = 32'ha4808093; // 80002198: addi x1,x1,-1464
            i_ddr.memory[1075][63:32] = 32'h00000013; // 8000219c: nop
            i_ddr.memory[1076][31:0] = 32'h00000013; // 800021a0: nop
            i_ddr.memory[1076][63:32] = 32'h00000013; // 800021a4: nop
            i_ddr.memory[1077][31:0] = 32'h00000013; // 800021a8: nop
            i_ddr.memory[1077][63:32] = 32'h00000013; // 800021ac: nop
            i_ddr.memory[1078][31:0] = 32'h00000013; // 800021b0: nop
            i_ddr.memory[1078][63:32] = 32'h00000013; // 800021b4: nop
            i_ddr.memory[1079][31:0] = 32'h00000013; // 800021b8: nop
            i_ddr.memory[1079][63:32] = 32'h0000a203; // 800021bc: lw x4,0(x1)
            i_ddr.memory[1080][31:0] = 32'h00000013; // 800021c0: nop
            i_ddr.memory[1080][63:32] = 32'h00000013; // 800021c4: nop
            i_ddr.memory[1081][31:0] = 32'h00000013; // 800021c8: nop
            i_ddr.memory[1081][63:32] = 32'h00000013; // 800021cc: nop
            i_ddr.memory[1082][31:0] = 32'h00000013; // 800021d0: nop
            i_ddr.memory[1082][63:32] = 32'h00000013; // 800021d4: nop
            i_ddr.memory[1083][31:0] = 32'h00410133; // 800021d8: add x2,x2,x4
            i_ddr.memory[1083][63:32] = 32'h0020a223; // 800021dc: sw x2,4(x1)
            i_ddr.memory[1084][31:0] = 32'h0040a283; // 800021e0: lw x5,4(x1)
            i_ddr.memory[1084][63:32] = 32'h00000013; // 800021e4: nop
            i_ddr.memory[1085][31:0] = 32'h00000013; // 800021e8: nop
            i_ddr.memory[1085][63:32] = 32'h00000013; // 800021ec: nop
            i_ddr.memory[1086][31:0] = 32'h00000013; // 800021f0: nop
            i_ddr.memory[1086][63:32] = 32'h00000013; // 800021f4: nop
            i_ddr.memory[1087][31:0] = 32'h00000013; // 800021f8: nop
            i_ddr.memory[1087][63:32] = 32'h00530333; // 800021fc: add x6,x6,x5
            i_ddr.memory[1088][31:0] = 32'h800100b7; // 80002200: lui x1,0x80010
            i_ddr.memory[1088][63:32] = 32'h40008093; // 80002204: addi x1,x1,1024
            i_ddr.memory[1089][31:0] = 32'h00000013; // 80002208: nop
            i_ddr.memory[1089][63:32] = 32'h00000013; // 8000220c: nop
            i_ddr.memory[1090][31:0] = 32'h00000013; // 80002210: nop
            i_ddr.memory[1090][63:32] = 32'h00000013; // 80002214: nop
            i_ddr.memory[1091][31:0] = 32'h00000013; // 80002218: nop
            i_ddr.memory[1091][63:32] = 32'h00000013; // 8000221c: nop
            i_ddr.memory[1092][31:0] = 32'h00000013; // 80002220: nop
            i_ddr.memory[1092][63:32] = 32'h00000013; // 80002224: nop
            i_ddr.memory[1093][31:0] = 32'h00000013; // 80002228: nop
            i_ddr.memory[1093][63:32] = 32'h0000a203; // 8000222c: lw x4,0(x1)
            i_ddr.memory[1094][31:0] = 32'h00000013; // 80002230: nop
            i_ddr.memory[1094][63:32] = 32'h00000013; // 80002234: nop
            i_ddr.memory[1095][31:0] = 32'h00000013; // 80002238: nop
            i_ddr.memory[1095][63:32] = 32'h00000013; // 8000223c: nop
            i_ddr.memory[1096][31:0] = 32'h00000013; // 80002240: nop
            i_ddr.memory[1096][63:32] = 32'h00000013; // 80002244: nop
            i_ddr.memory[1097][31:0] = 32'h00410133; // 80002248: add x2,x2,x4
            i_ddr.memory[1097][63:32] = 32'h0020a223; // 8000224c: sw x2,4(x1)
            i_ddr.memory[1098][31:0] = 32'h0040a283; // 80002250: lw x5,4(x1)
            i_ddr.memory[1098][63:32] = 32'h00000013; // 80002254: nop
            i_ddr.memory[1099][31:0] = 32'h00000013; // 80002258: nop
            i_ddr.memory[1099][63:32] = 32'h00000013; // 8000225c: nop
            i_ddr.memory[1100][31:0] = 32'h00000013; // 80002260: nop
            i_ddr.memory[1100][63:32] = 32'h00000013; // 80002264: nop
            i_ddr.memory[1101][31:0] = 32'h00000013; // 80002268: nop
            i_ddr.memory[1101][63:32] = 32'h00530333; // 8000226c: add x6,x6,x5
            i_ddr.memory[1102][31:0] = 32'h800170b7; // 80002270: lui x1,0x80017
            i_ddr.memory[1102][63:32] = 32'h99008093; // 80002274: addi x1,x1,-1648
            i_ddr.memory[1103][31:0] = 32'h0040a283; // 80002278: lw x5,4(x1)
            i_ddr.memory[1103][63:32] = 32'h005383b3; // 8000227c: add x7,x7,x5
            i_ddr.memory[1104][31:0] = 32'h8001b0b7; // 80002280: lui x1,0x8001b
            i_ddr.memory[1104][63:32] = 32'h98008093; // 80002284: addi x1,x1,-1664
            i_ddr.memory[1105][31:0] = 32'h0040a283; // 80002288: lw x5,4(x1)
            i_ddr.memory[1105][63:32] = 32'h005383b3; // 8000228c: add x7,x7,x5
            i_ddr.memory[1106][31:0] = 32'h800190b7; // 80002290: lui x1,0x80019
            i_ddr.memory[1106][63:32] = 32'ha4008093; // 80002294: addi x1,x1,-1472
            i_ddr.memory[1107][31:0] = 32'h0040a283; // 80002298: lw x5,4(x1)
            i_ddr.memory[1107][63:32] = 32'h005383b3; // 8000229c: add x7,x7,x5
            i_ddr.memory[1108][31:0] = 32'h800160b7; // 800022a0: lui x1,0x80016
            i_ddr.memory[1108][63:32] = 32'h55008093; // 800022a4: addi x1,x1,1360
            i_ddr.memory[1109][31:0] = 32'h0040a283; // 800022a8: lw x5,4(x1)
            i_ddr.memory[1109][63:32] = 32'h005383b3; // 800022ac: add x7,x7,x5
            i_ddr.memory[1110][31:0] = 32'h8001f0b7; // 800022b0: lui x1,0x8001f
            i_ddr.memory[1110][63:32] = 32'h98808093; // 800022b4: addi x1,x1,-1656
            i_ddr.memory[1111][31:0] = 32'h0040a283; // 800022b8: lw x5,4(x1)
            i_ddr.memory[1111][63:32] = 32'h005383b3; // 800022bc: add x7,x7,x5
            i_ddr.memory[1112][31:0] = 32'h8001b0b7; // 800022c0: lui x1,0x8001b
            i_ddr.memory[1112][63:32] = 32'h98808093; // 800022c4: addi x1,x1,-1656
            i_ddr.memory[1113][31:0] = 32'h0040a283; // 800022c8: lw x5,4(x1)
            i_ddr.memory[1113][63:32] = 32'h005383b3; // 800022cc: add x7,x7,x5
            i_ddr.memory[1114][31:0] = 32'h800200b7; // 800022d0: lui x1,0x80020
            i_ddr.memory[1114][63:32] = 32'h8e008093; // 800022d4: addi x1,x1,-1824
            i_ddr.memory[1115][31:0] = 32'h0040a283; // 800022d8: lw x5,4(x1)
            i_ddr.memory[1115][63:32] = 32'h005383b3; // 800022dc: add x7,x7,x5
            i_ddr.memory[1116][31:0] = 32'h8001c0b7; // 800022e0: lui x1,0x8001c
            i_ddr.memory[1116][63:32] = 32'hcd008093; // 800022e4: addi x1,x1,-816
            i_ddr.memory[1117][31:0] = 32'h0040a283; // 800022e8: lw x5,4(x1)
            i_ddr.memory[1117][63:32] = 32'h005383b3; // 800022ec: add x7,x7,x5
            i_ddr.memory[1118][31:0] = 32'h800190b7; // 800022f0: lui x1,0x80019
            i_ddr.memory[1118][63:32] = 32'ha5008093; // 800022f4: addi x1,x1,-1456
            i_ddr.memory[1119][31:0] = 32'h0040a283; // 800022f8: lw x5,4(x1)
            i_ddr.memory[1119][63:32] = 32'h005383b3; // 800022fc: add x7,x7,x5
            i_ddr.memory[1120][31:0] = 32'h800180b7; // 80002300: lui x1,0x80018
            i_ddr.memory[1120][63:32] = 32'h40008093; // 80002304: addi x1,x1,1024
            i_ddr.memory[1121][31:0] = 32'h0040a283; // 80002308: lw x5,4(x1)
            i_ddr.memory[1121][63:32] = 32'h005383b3; // 8000230c: add x7,x7,x5
            i_ddr.memory[1122][31:0] = 32'h800200b7; // 80002310: lui x1,0x80020
            i_ddr.memory[1122][63:32] = 32'h8e808093; // 80002314: addi x1,x1,-1816
            i_ddr.memory[1123][31:0] = 32'h0040a283; // 80002318: lw x5,4(x1)
            i_ddr.memory[1123][63:32] = 32'h005383b3; // 8000231c: add x7,x7,x5
            i_ddr.memory[1124][31:0] = 32'h800180b7; // 80002320: lui x1,0x80018
            i_ddr.memory[1124][63:32] = 32'h8e008093; // 80002324: addi x1,x1,-1824
            i_ddr.memory[1125][31:0] = 32'h0040a283; // 80002328: lw x5,4(x1)
            i_ddr.memory[1125][63:32] = 32'h005383b3; // 8000232c: add x7,x7,x5
            i_ddr.memory[1126][31:0] = 32'h8001c0b7; // 80002330: lui x1,0x8001c
            i_ddr.memory[1126][63:32] = 32'h8e808093; // 80002334: addi x1,x1,-1816
            i_ddr.memory[1127][31:0] = 32'h0040a283; // 80002338: lw x5,4(x1)
            i_ddr.memory[1127][63:32] = 32'h005383b3; // 8000233c: add x7,x7,x5
            i_ddr.memory[1128][31:0] = 32'h8001a0b7; // 80002340: lui x1,0x8001a
            i_ddr.memory[1128][63:32] = 32'h54808093; // 80002344: addi x1,x1,1352
            i_ddr.memory[1129][31:0] = 32'h0040a283; // 80002348: lw x5,4(x1)
            i_ddr.memory[1129][63:32] = 32'h005383b3; // 8000234c: add x7,x7,x5
            i_ddr.memory[1130][31:0] = 32'h8001e0b7; // 80002350: lui x1,0x8001e
            i_ddr.memory[1130][63:32] = 32'h54808093; // 80002354: addi x1,x1,1352
            i_ddr.memory[1131][31:0] = 32'h0040a283; // 80002358: lw x5,4(x1)
            i_ddr.memory[1131][63:32] = 32'h005383b3; // 8000235c: add x7,x7,x5
            i_ddr.memory[1132][31:0] = 32'h800200b7; // 80002360: lui x1,0x80020
            i_ddr.memory[1132][63:32] = 32'hcd008093; // 80002364: addi x1,x1,-816
            i_ddr.memory[1133][31:0] = 32'h0040a283; // 80002368: lw x5,4(x1)
            i_ddr.memory[1133][63:32] = 32'h005383b3; // 8000236c: add x7,x7,x5
            i_ddr.memory[1134][31:0] = 32'h800120b7; // 80002370: lui x1,0x80012
            i_ddr.memory[1134][63:32] = 32'h54808093; // 80002374: addi x1,x1,1352
            i_ddr.memory[1135][31:0] = 32'h0040a283; // 80002378: lw x5,4(x1)
            i_ddr.memory[1135][63:32] = 32'h005383b3; // 8000237c: add x7,x7,x5
            i_ddr.memory[1136][31:0] = 32'h800140b7; // 80002380: lui x1,0x80014
            i_ddr.memory[1136][63:32] = 32'h8f008093; // 80002384: addi x1,x1,-1808
            i_ddr.memory[1137][31:0] = 32'h0040a283; // 80002388: lw x5,4(x1)
            i_ddr.memory[1137][63:32] = 32'h005383b3; // 8000238c: add x7,x7,x5
            i_ddr.memory[1138][31:0] = 32'h800140b7; // 80002390: lui x1,0x80014
            i_ddr.memory[1138][63:32] = 32'h8e808093; // 80002394: addi x1,x1,-1816
            i_ddr.memory[1139][31:0] = 32'h0040a283; // 80002398: lw x5,4(x1)
            i_ddr.memory[1139][63:32] = 32'h005383b3; // 8000239c: add x7,x7,x5
            i_ddr.memory[1140][31:0] = 32'h8001b0b7; // 800023a0: lui x1,0x8001b
            i_ddr.memory[1140][63:32] = 32'h99008093; // 800023a4: addi x1,x1,-1648
            i_ddr.memory[1141][31:0] = 32'h0040a283; // 800023a8: lw x5,4(x1)
            i_ddr.memory[1141][63:32] = 32'h005383b3; // 800023ac: add x7,x7,x5
            i_ddr.memory[1142][31:0] = 32'h8001e0b7; // 800023b0: lui x1,0x8001e
            i_ddr.memory[1142][63:32] = 32'h54008093; // 800023b4: addi x1,x1,1344
            i_ddr.memory[1143][31:0] = 32'h0040a283; // 800023b8: lw x5,4(x1)
            i_ddr.memory[1143][63:32] = 32'h005383b3; // 800023bc: add x7,x7,x5
            i_ddr.memory[1144][31:0] = 32'h8001d0b7; // 800023c0: lui x1,0x8001d
            i_ddr.memory[1144][63:32] = 32'ha5008093; // 800023c4: addi x1,x1,-1456
            i_ddr.memory[1145][31:0] = 32'h0040a283; // 800023c8: lw x5,4(x1)
            i_ddr.memory[1145][63:32] = 32'h005383b3; // 800023cc: add x7,x7,x5
            i_ddr.memory[1146][31:0] = 32'h8001c0b7; // 800023d0: lui x1,0x8001c
            i_ddr.memory[1146][63:32] = 32'h41008093; // 800023d4: addi x1,x1,1040
            i_ddr.memory[1147][31:0] = 32'h0040a283; // 800023d8: lw x5,4(x1)
            i_ddr.memory[1147][63:32] = 32'h005383b3; // 800023dc: add x7,x7,x5
            i_ddr.memory[1148][31:0] = 32'h800130b7; // 800023e0: lui x1,0x80013
            i_ddr.memory[1148][63:32] = 32'h98808093; // 800023e4: addi x1,x1,-1656
            i_ddr.memory[1149][31:0] = 32'h0040a283; // 800023e8: lw x5,4(x1)
            i_ddr.memory[1149][63:32] = 32'h005383b3; // 800023ec: add x7,x7,x5
            i_ddr.memory[1150][31:0] = 32'h800180b7; // 800023f0: lui x1,0x80018
            i_ddr.memory[1150][63:32] = 32'h41008093; // 800023f4: addi x1,x1,1040
            i_ddr.memory[1151][31:0] = 32'h0040a283; // 800023f8: lw x5,4(x1)
            i_ddr.memory[1151][63:32] = 32'h005383b3; // 800023fc: add x7,x7,x5
            i_ddr.memory[1152][31:0] = 32'h800160b7; // 80002400: lui x1,0x80016
            i_ddr.memory[1152][63:32] = 32'h54008093; // 80002404: addi x1,x1,1344
            i_ddr.memory[1153][31:0] = 32'h0040a283; // 80002408: lw x5,4(x1)
            i_ddr.memory[1153][63:32] = 32'h005383b3; // 8000240c: add x7,x7,x5
            i_ddr.memory[1154][31:0] = 32'h800140b7; // 80002410: lui x1,0x80014
            i_ddr.memory[1154][63:32] = 32'h41008093; // 80002414: addi x1,x1,1040
            i_ddr.memory[1155][31:0] = 32'h0040a283; // 80002418: lw x5,4(x1)
            i_ddr.memory[1155][63:32] = 32'h005383b3; // 8000241c: add x7,x7,x5
            i_ddr.memory[1156][31:0] = 32'h800160b7; // 80002420: lui x1,0x80016
            i_ddr.memory[1156][63:32] = 32'h54808093; // 80002424: addi x1,x1,1352
            i_ddr.memory[1157][31:0] = 32'h0040a283; // 80002428: lw x5,4(x1)
            i_ddr.memory[1157][63:32] = 32'h005383b3; // 8000242c: add x7,x7,x5
            i_ddr.memory[1158][31:0] = 32'h800100b7; // 80002430: lui x1,0x80010
            i_ddr.memory[1158][63:32] = 32'h40808093; // 80002434: addi x1,x1,1032
            i_ddr.memory[1159][31:0] = 32'h0040a283; // 80002438: lw x5,4(x1)
            i_ddr.memory[1159][63:32] = 32'h005383b3; // 8000243c: add x7,x7,x5
            i_ddr.memory[1160][31:0] = 32'h8001d0b7; // 80002440: lui x1,0x8001d
            i_ddr.memory[1160][63:32] = 32'ha4808093; // 80002444: addi x1,x1,-1464
            i_ddr.memory[1161][31:0] = 32'h0040a283; // 80002448: lw x5,4(x1)
            i_ddr.memory[1161][63:32] = 32'h005383b3; // 8000244c: add x7,x7,x5
            i_ddr.memory[1162][31:0] = 32'h800130b7; // 80002450: lui x1,0x80013
            i_ddr.memory[1162][63:32] = 32'h98008093; // 80002454: addi x1,x1,-1664
            i_ddr.memory[1163][31:0] = 32'h0040a283; // 80002458: lw x5,4(x1)
            i_ddr.memory[1163][63:32] = 32'h005383b3; // 8000245c: add x7,x7,x5
            i_ddr.memory[1164][31:0] = 32'h800110b7; // 80002460: lui x1,0x80011
            i_ddr.memory[1164][63:32] = 32'ha5008093; // 80002464: addi x1,x1,-1456
            i_ddr.memory[1165][31:0] = 32'h0040a283; // 80002468: lw x5,4(x1)
            i_ddr.memory[1165][63:32] = 32'h005383b3; // 8000246c: add x7,x7,x5
            i_ddr.memory[1166][31:0] = 32'h8001a0b7; // 80002470: lui x1,0x8001a
            i_ddr.memory[1166][63:32] = 32'h54008093; // 80002474: addi x1,x1,1344
            i_ddr.memory[1167][31:0] = 32'h0040a283; // 80002478: lw x5,4(x1)
            i_ddr.memory[1167][63:32] = 32'h005383b3; // 8000247c: add x7,x7,x5
            i_ddr.memory[1168][31:0] = 32'h800150b7; // 80002480: lui x1,0x80015
            i_ddr.memory[1168][63:32] = 32'ha4808093; // 80002484: addi x1,x1,-1464
            i_ddr.memory[1169][31:0] = 32'h0040a283; // 80002488: lw x5,4(x1)
            i_ddr.memory[1169][63:32] = 32'h005383b3; // 8000248c: add x7,x7,x5
            i_ddr.memory[1170][31:0] = 32'h800140b7; // 80002490: lui x1,0x80014
            i_ddr.memory[1170][63:32] = 32'h8e008093; // 80002494: addi x1,x1,-1824
            i_ddr.memory[1171][31:0] = 32'h0040a283; // 80002498: lw x5,4(x1)
            i_ddr.memory[1171][63:32] = 32'h005383b3; // 8000249c: add x7,x7,x5
            i_ddr.memory[1172][31:0] = 32'h8001c0b7; // 800024a0: lui x1,0x8001c
            i_ddr.memory[1172][63:32] = 32'h8f008093; // 800024a4: addi x1,x1,-1808
            i_ddr.memory[1173][31:0] = 32'h0040a283; // 800024a8: lw x5,4(x1)
            i_ddr.memory[1173][63:32] = 32'h005383b3; // 800024ac: add x7,x7,x5
            i_ddr.memory[1174][31:0] = 32'h800140b7; // 800024b0: lui x1,0x80014
            i_ddr.memory[1174][63:32] = 32'hcd008093; // 800024b4: addi x1,x1,-816
            i_ddr.memory[1175][31:0] = 32'h0040a283; // 800024b8: lw x5,4(x1)
            i_ddr.memory[1175][63:32] = 32'h005383b3; // 800024bc: add x7,x7,x5
            i_ddr.memory[1176][31:0] = 32'h800140b7; // 800024c0: lui x1,0x80014
            i_ddr.memory[1176][63:32] = 32'hcc008093; // 800024c4: addi x1,x1,-832
            i_ddr.memory[1177][31:0] = 32'h0040a283; // 800024c8: lw x5,4(x1)
            i_ddr.memory[1177][63:32] = 32'h005383b3; // 800024cc: add x7,x7,x5
            i_ddr.memory[1178][31:0] = 32'h800190b7; // 800024d0: lui x1,0x80019
            i_ddr.memory[1178][63:32] = 32'ha4808093; // 800024d4: addi x1,x1,-1464
            i_ddr.memory[1179][31:0] = 32'h0040a283; // 800024d8: lw x5,4(x1)
            i_ddr.memory[1179][63:32] = 32'h005383b3; // 800024dc: add x7,x7,x5
            i_ddr.memory[1180][31:0] = 32'h800100b7; // 800024e0: lui x1,0x80010
            i_ddr.memory[1180][63:32] = 32'h40008093; // 800024e4: addi x1,x1,1024
            i_ddr.memory[1181][31:0] = 32'h0040a283; // 800024e8: lw x5,4(x1)
            i_ddr.memory[1181][63:32] = 32'h005383b3; // 800024ec: add x7,x7,x5
            i_ddr.memory[1182][31:0] = 32'h000fa023; // 800024f0: sw x0,0(x31)      (DONE)
            i_ddr.memory[1182][63:32] = 32'h0000006f; // 800024f4: j .
        end

        repeat (5) @(posedge clk);
        #1 reset = 1'b0;

        i = 0;
        while (!done && i < TIMEOUT) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (20) @(posedge clk);
        #1;

        $display("============================================");
        $display(" Instruction + data cache, ICACHE_SETS=%0d, latency I=%0d D=%0d/%0d",
                 ICACHE_SETS, I_READ_LATENCY, D_READ_LATENCY, D_WRITE_LATENCY);
        $display(" %0d cycles, instruction cache busy %0d, data cache busy %0d, both busy %0d",
                 cycles, instruction_busy_cycles, data_busy_cycles, both_busy_cycles);
        $display("============================================");
        check_value("program end", 32'd1, {31'd0, done});
        check_value("x2 (running sum)", 32'h48054b00, dut.register_file.registers[2]);
        check_value("x6 (sum of stored)", 32'h9af5d738, dut.register_file.registers[6]);
        check_value("x7 (read back)", 32'h1a7464e6, dut.register_file.registers[7]);
        check_value("both caches busy", 32'd1, {31'd0, both_busy_cycles > 0});
        $display(" PASS: %0d  FAIL: %0d", pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1, "RV32IM54F_8SP_dual_cache_tb: %0d check(s) failed", fail_count);
        $finish;
    end

endmodule
