`timescale 1ns / 1ps

`ifdef HAS_ICACHE
`include "./modules/Dummy_DDR_Memory.v"
`endif

module RV32IM54F_8SP_core_tb;
    parameter XLEN = 32;
    // I-Cache configuration (used only when compiled with -DHAS_ICACHE)
    parameter ICACHE_SETS = 128;
    parameter ICACHE_EN = 1;
    parameter DDR_READ_LATENCY = 60;
    // Where each program runs. 0 : Boot ROM as written (the original core layout).
    // Otherwise ROM word 0 is "jalr x0, 0(x30)" with x30 = PROGRAM_BASE and the program is
    // copied there: 0x0000_1000 = Boot ROM (uncached), 0x8000_1000 = DDR (through the I-Cache).
    // Traces print pc[28:0], so a ROM run and a DDR run of the same program compare line by line.
    parameter [31:0] PROGRAM_BASE = 32'h0000_0000;

    localparam [XLEN-1:0] DONE_ADDR = 32'h1001_0000;
    localparam integer    TIMEOUT   = 5000;
    localparam [31:0]     HALT      = 32'h0000_006F;   // jal x0, 0
    localparam [31:0] JALR_X30 = 32'h000F_0067; // jalr x0, 0(x30)
    localparam DDR_PROGRAM = PROGRAM_BASE[31];

    reg clk;
    reg reset;

    wire [31:0] retire_instruction;
    wire [XLEN-1:0] MMIO_data_memory_write_data;
    wire [XLEN-1:0] MMIO_data_memory_address;
    wire MMIO_data_memory_write_enable;

    integer test_count;
    integer pass_count;
    integer fail_count;
    integer i;
    integer cycles;
    integer cycles_alias;
    integer cycles_noalias;
    reg done;

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

    RV32IM54F8SP #(.XLEN(XLEN), .ICACHE_NUM_SETS(ICACHE_SETS), .ICACHE_EN(ICACHE_EN)) dut (
`else
    RV32IM54F8SP #(.XLEN(XLEN)) dut (
`endif
        .clk(clk),
        .clk_enable(1'b1),
        .reset(reset),
        .UART_busy(1'b0),
        .timer_interrupt_pending(1'b0),
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
    // DDR window 0x8000_0000 ~ 0x8001_FFFF (128KB), read only for the I-Cache
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
`endif

    initial clk = 1'b0;
    always #5 clk = ~clk;

`ifdef HAS_ICACHE
    wire core_cycle = !dut.cache_stall; // pipeline cycles (cache miss stall cycles are not counted)
`else
    wire core_cycle = 1'b1;
`endif

`ifdef TRACE
    // Per-core-cycle state trace (compare a cached build against the baseline core)
    always @(posedge clk) begin
        if (!reset && core_cycle)
            $display("T pc=%h ipc=%h IO=%h ID=%h EXR=%h EX=%h EX2=%h MEM=%h WB=%h trp=%b st=%h tdone=%b csr=%b wd=%b ifs=%b fr=%b x5=%h x6=%h x9=%h",
                     dut.pc & 32'h1FFF_FFFF, dut.instruction_pc & 32'h1FFF_FFFF, dut.IO_instruction, dut.ID_instruction, dut.EXR_instruction,
                     dut.EX_instruction, dut.EX2_instruction, dut.MEM_instruction, dut.WB_instruction,
                     dut.trapped, dut.trap_status, dut.trap_done, dut.csr_ready, dut.write_done,
                     dut.IF_IO_stall, dut.if_io_register.flush_reg,
                     dut.register_file.registers[5], dut.register_file.registers[6], dut.register_file.registers[9]);
    end
`endif

    // Every program ends with a store to DONE_ADDR
    always @(posedge clk) begin
        if (reset)
            done <= 1'b0;
        else if (MMIO_data_memory_write_enable && MMIO_data_memory_address == DONE_ADDR)
            done <= 1'b1;
    end

    // Self-modifying-code backdoor: a store to PATCH_ADDR rewrites IM word 16 (0x0040)
    // (stores cannot reach the instruction memory, so the TB patches it)
    localparam [XLEN-1:0] PATCH_ADDR = 32'h1001_0008;
    reg patch_en;
    initial patch_en = 1'b0;
    // second backdoor: a store to PATCH2_ADDR rewrites IM word 5 (0x0014)
    localparam [XLEN-1:0] PATCH2_ADDR = 32'h1001_0010;
    always @(posedge clk) begin
        if (patch_en && MMIO_data_memory_write_enable && MMIO_data_memory_address == PATCH_ADDR)
            write_program_word(16, 32'h00200513);   // addi x10,x0,2
        if (patch_en && MMIO_data_memory_write_enable && MMIO_data_memory_address == PATCH2_ADDR)
            write_program_word(5, 32'h00200613);    // addi x12,x0,2
    end

    // Word n of the running program (at PROGRAM_BASE)
    task write_program_word;
        input integer n;
        input [31:0] value;
        integer word;
        begin
            word = (PROGRAM_BASE & 32'h1FFF_FFFF) / 4 + n;
            if (DDR_PROGRAM) begin
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

    // The load_* tasks write the program at ROM word 0; move it to PROGRAM_BASE
    task place_program;
        begin
            if (PROGRAM_BASE != 32'h0) begin
                for (i = 0; i < 1024; i = i + 1)
                    write_program_word(i, dut.instruction_memory.data[i]);
                for (i = 0; i < 1024; i = i + 1)
                    dut.instruction_memory.data[i] = HALT;
                dut.instruction_memory.data[0] = JALR_X30;
                dut.register_file.registers[30] = PROGRAM_BASE;
            end
        end
    endtask

    // I-Cache FENCE.I done pulses since the last reset
    integer fence_done_count;
    always @(posedge clk) begin
        if (reset)
            fence_done_count <= 0;
`ifdef HAS_ICACHE
        else if (dut.instruction_cache.fence_i_done)
            fence_done_count <= fence_done_count + 1;
`endif
    end

    // FENCE.I ordering check (white box): the I-Cache invalidation must never start while an
    // older store in MEM has not done its memory write yet.
    //   store_unwritten : DataMemory has a store whose write cycle has not happened
    //   fi_violations   : FENCE.I FSM left IDLE (fence_i_req raised) with store_unwritten (whole run)
    //   fi_held         : cycles a FENCE.I sat in EX2 behind such a store (per program; proves
    //                     the ordering case is actually exercised)
    integer fi_violations;
    integer fi_held;
    initial fi_violations = 0;
`ifdef HAS_ICACHE
    wire store_unwritten = dut.data_memory.write_enable && !dut.data_memory.write_phase;
    always @(posedge clk) begin
        if (reset)
            fi_held <= 0;
        else begin
            if (dut.fi_state == 2'd0 && dut.instruction_cache_fence_i_req && store_unwritten) begin
                fi_violations <= fi_violations + 1;
                $display("[TB]   FENCE.I ordering violation at %0t: invalidation started before the store in MEM was written", $time);
            end
            if (dut.fi_state == 2'd0 && dut.EX2_is_fence_i && store_unwritten)
                fi_held <= fi_held + 1;
        end
    end
`else
    always @(posedge clk) if (reset) fi_held <= 0;
`endif

    task clear_imem;
        begin
            for (i = 0; i < 1024; i = i + 1)
                dut.instruction_memory.data[i] = HALT;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = {XLEN{1'b0}};
        end
    endtask

    // ------------------------------------------------------------------------
    // Test programs (assembled with riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32)
    // ------------------------------------------------------------------------
    task load_ld_stall_rs2_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h377302b7;   // 0038: lui x5,0x37730
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h0006a303;   // 0044: lw x6,0(x13)
            dut.instruction_memory.data[18] = 32'h005304b3;   // 0048: add x9,x6,x5
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <_start+0x60>
        end
    endtask

    task load_ld_stall_rs2_gap1;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h377302b7;   // 0038: lui x5,0x37730
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h0006a303;   // 0040: lw x6,0(x13)
            dut.instruction_memory.data[17] = 32'h005304b3;   // 0044: add x9,x6,x5
            dut.instruction_memory.data[18] = 32'h00000013;   // 0048: nop
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h000fa023;   // 0058: sw x0,0(x31)
            dut.instruction_memory.data[23] = 32'h0000006f;   // 005c: j 5c <_start+0x5c>
        end
    endtask

    task load_ld_stall_rs2_gap3;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h377302b7;   // 0038: lui x5,0x37730
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h00000013;   // 0044: nop
            dut.instruction_memory.data[18] = 32'h0006a303;   // 0048: lw x6,0(x13)
            dut.instruction_memory.data[19] = 32'h005304b3;   // 004c: add x9,x6,x5
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h00000013;   // 005c: nop
            dut.instruction_memory.data[24] = 32'h000fa023;   // 0060: sw x0,0(x31)
            dut.instruction_memory.data[25] = 32'h0000006f;   // 0064: j 64 <_start+0x64>
        end
    endtask

    task load_ld_stall_rs1_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h377302b7;   // 0038: lui x5,0x37730
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h0006a303;   // 0044: lw x6,0(x13)
            dut.instruction_memory.data[18] = 32'h006284b3;   // 0048: add x9,x5,x6
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <_start+0x60>
        end
    endtask

    task load_alu_stall_rs2_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h377302b7;   // 0038: lui x5,0x37730
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h00700313;   // 0044: li x6,7
            dut.instruction_memory.data[18] = 32'h005304b3;   // 0048: add x9,x6,x5
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <_start+0x60>
        end
    endtask

    task load_alu_stall_rs1_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h377302b7;   // 0038: lui x5,0x37730
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h00700313;   // 0044: li x6,7
            dut.instruction_memory.data[18] = 32'h006284b3;   // 0048: add x9,x5,x6
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <_start+0x60>
        end
    endtask

    task load_freeze_rs2_gap1;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h06300313;   // 0038: li x6,99
            dut.instruction_memory.data[15] = 32'h377302b7;   // 003c: lui x5,0x37730
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h0006a303;   // 0044: lw x6,0(x13)
            dut.instruction_memory.data[18] = 32'h005304b3;   // 0048: add x9,x6,x5
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <_start+0x60>
        end
    endtask

    task load_freeze_rs2_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h06300313;   // 0038: li x6,99
            dut.instruction_memory.data[15] = 32'h377302b7;   // 003c: lui x5,0x37730
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h00000013;   // 0044: nop
            dut.instruction_memory.data[18] = 32'h0006a303;   // 0048: lw x6,0(x13)
            dut.instruction_memory.data[19] = 32'h005304b3;   // 004c: add x9,x6,x5
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h00000013;   // 005c: nop
            dut.instruction_memory.data[24] = 32'h000fa023;   // 0060: sw x0,0(x31)
            dut.instruction_memory.data[25] = 32'h0000006f;   // 0064: j 64 <_start+0x64>
        end
    endtask

    task load_freeze_rs1_gap1;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h06300313;   // 0038: li x6,99
            dut.instruction_memory.data[15] = 32'h377302b7;   // 003c: lui x5,0x37730
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h0006a303;   // 0044: lw x6,0(x13)
            dut.instruction_memory.data[18] = 32'h006284b3;   // 0048: add x9,x5,x6
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <_start+0x60>
        end
    endtask

    task load_freeze_rs1_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6a023;   // 000c: sw x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f428293;   // 0014: addi x5,x5,1268
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h00000013;   // 0028: nop
            dut.instruction_memory.data[11] = 32'h00000013;   // 002c: nop
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h06300313;   // 0038: li x6,99
            dut.instruction_memory.data[15] = 32'h377302b7;   // 003c: lui x5,0x37730
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h00000013;   // 0044: nop
            dut.instruction_memory.data[18] = 32'h0006a303;   // 0048: lw x6,0(x13)
            dut.instruction_memory.data[19] = 32'h006284b3;   // 004c: add x9,x5,x6
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h00000013;   // 005c: nop
            dut.instruction_memory.data[24] = 32'h000fa023;   // 0060: sw x0,0(x31)
            dut.instruction_memory.data[25] = 32'h0000006f;   // 0064: j 64 <_start+0x64>
        end
    endtask

    task load_csr_alias;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100000b7;   // 0004: lui x1,0x10000
            dut.instruction_memory.data[2] = 32'h01400113;   // 0008: li x2,20
            dut.instruction_memory.data[3] = 32'h00006237;   // 000c: lui x4,0x6
            dut.instruction_memory.data[4] = 32'ha5a20213;   // 0010: addi x4,x4,-1446
            dut.instruction_memory.data[5] = 32'h3400a023;   // 0014: sw x0,832(x1)
            dut.instruction_memory.data[6] = 32'h3040a023;   // 0018: sw x4,768(x1)
            dut.instruction_memory.data[7] = 32'h3440a023;   // 001c: sw x4,832(x1)
            dut.instruction_memory.data[8] = 32'hfff10113;   // 0020: addi x2,x2,-1
            dut.instruction_memory.data[9] = 32'hfe0118e3;   // 0024: bnez x2,14 <loop>
            dut.instruction_memory.data[10] = 32'h3000aa03;   // 0028: lw x20,768(x1)
            dut.instruction_memory.data[11] = 32'h3400aa83;   // 002c: lw x21,832(x1)
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h000fa023;   // 0040: sw x0,0(x31)
            dut.instruction_memory.data[17] = 32'h0000006f;   // 0044: j 44 <loop+0x30>
        end
    endtask

    task load_csr_noalias;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100000b7;   // 0004: lui x1,0x10000
            dut.instruction_memory.data[2] = 32'h01400113;   // 0008: li x2,20
            dut.instruction_memory.data[3] = 32'h00006237;   // 000c: lui x4,0x6
            dut.instruction_memory.data[4] = 32'ha5a20213;   // 0010: addi x4,x4,-1446
            dut.instruction_memory.data[5] = 32'h3600a023;   // 0014: sw x0,864(x1)
            dut.instruction_memory.data[6] = 32'h3240a023;   // 0018: sw x4,800(x1)
            dut.instruction_memory.data[7] = 32'h3640a023;   // 001c: sw x4,864(x1)
            dut.instruction_memory.data[8] = 32'hfff10113;   // 0020: addi x2,x2,-1
            dut.instruction_memory.data[9] = 32'hfe0118e3;   // 0024: bnez x2,14 <loop>
            dut.instruction_memory.data[10] = 32'h3200aa03;   // 0028: lw x20,800(x1)
            dut.instruction_memory.data[11] = 32'h3600aa83;   // 002c: lw x21,864(x1)
            dut.instruction_memory.data[12] = 32'h00000013;   // 0030: nop
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h000fa023;   // 0040: sw x0,0(x31)
            dut.instruction_memory.data[17] = 32'h0000006f;   // 0044: j 44 <loop+0x30>
        end
    endtask

    task load_mret_gap1;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h00000517;   // 0004: auipc x10,0x0
            dut.instruction_memory.data[2] = 32'h04850513;   // 0008: addi x10,x10,72
            dut.instruction_memory.data[3] = 32'h34151073;   // 000c: csrw mepc,x10
            dut.instruction_memory.data[4] = 32'h00000013;   // 0010: nop
            dut.instruction_memory.data[5] = 32'h00000013;   // 0014: nop
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h000012b7;   // 0028: lui x5,0x1
            dut.instruction_memory.data[11] = 32'h23428293;   // 002c: addi x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h30200073;   // 0038: mret
            dut.instruction_memory.data[15] = 32'h00001a37;   // 003c: lui x20,0x1
            dut.instruction_memory.data[16] = 32'hbada0a13;   // 0040: addi x20,x20,-1107
            dut.instruction_memory.data[17] = 32'h000fa023;   // 0044: sw x0,0(x31)
            dut.instruction_memory.data[18] = 32'h0000006f;   // 0048: j 48 <_start+0x48>
            dut.instruction_memory.data[19] = 32'h34002af3;   // 004c: csrr x21,mscratch
            dut.instruction_memory.data[20] = 32'h34102b73;   // 0050: csrr x22,mepc
            dut.instruction_memory.data[21] = 32'h00006a37;   // 0054: lui x20,0x6
            dut.instruction_memory.data[22] = 32'h00da0a13;   // 0058: addi x20,x20,13
            dut.instruction_memory.data[23] = 32'h00000013;   // 005c: nop
            dut.instruction_memory.data[24] = 32'h00000013;   // 0060: nop
            dut.instruction_memory.data[25] = 32'h00000013;   // 0064: nop
            dut.instruction_memory.data[26] = 32'h00000013;   // 0068: nop
            dut.instruction_memory.data[27] = 32'h000fa023;   // 006c: sw x0,0(x31)
            dut.instruction_memory.data[28] = 32'h0000006f;   // 0070: j 70 <target+0x24>
        end
    endtask

    task load_mret_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h00000517;   // 0004: auipc x10,0x0
            dut.instruction_memory.data[2] = 32'h04c50513;   // 0008: addi x10,x10,76
            dut.instruction_memory.data[3] = 32'h34151073;   // 000c: csrw mepc,x10
            dut.instruction_memory.data[4] = 32'h00000013;   // 0010: nop
            dut.instruction_memory.data[5] = 32'h00000013;   // 0014: nop
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h000012b7;   // 0028: lui x5,0x1
            dut.instruction_memory.data[11] = 32'h23428293;   // 002c: addi x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h30200073;   // 003c: mret
            dut.instruction_memory.data[16] = 32'h00001a37;   // 0040: lui x20,0x1
            dut.instruction_memory.data[17] = 32'hbada0a13;   // 0044: addi x20,x20,-1107
            dut.instruction_memory.data[18] = 32'h000fa023;   // 0048: sw x0,0(x31)
            dut.instruction_memory.data[19] = 32'h0000006f;   // 004c: j 4c <_start+0x4c>
            dut.instruction_memory.data[20] = 32'h34002af3;   // 0050: csrr x21,mscratch
            dut.instruction_memory.data[21] = 32'h34102b73;   // 0054: csrr x22,mepc
            dut.instruction_memory.data[22] = 32'h00006a37;   // 0058: lui x20,0x6
            dut.instruction_memory.data[23] = 32'h00da0a13;   // 005c: addi x20,x20,13
            dut.instruction_memory.data[24] = 32'h00000013;   // 0060: nop
            dut.instruction_memory.data[25] = 32'h00000013;   // 0064: nop
            dut.instruction_memory.data[26] = 32'h00000013;   // 0068: nop
            dut.instruction_memory.data[27] = 32'h00000013;   // 006c: nop
            dut.instruction_memory.data[28] = 32'h000fa023;   // 0070: sw x0,0(x31)
            dut.instruction_memory.data[29] = 32'h0000006f;   // 0074: j 74 <target+0x24>
        end
    endtask

    task load_mret_gap3;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h00000517;   // 0004: auipc x10,0x0
            dut.instruction_memory.data[2] = 32'h05050513;   // 0008: addi x10,x10,80
            dut.instruction_memory.data[3] = 32'h34151073;   // 000c: csrw mepc,x10
            dut.instruction_memory.data[4] = 32'h00000013;   // 0010: nop
            dut.instruction_memory.data[5] = 32'h00000013;   // 0014: nop
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h000012b7;   // 0028: lui x5,0x1
            dut.instruction_memory.data[11] = 32'h23428293;   // 002c: addi x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h30200073;   // 0040: mret
            dut.instruction_memory.data[17] = 32'h00001a37;   // 0044: lui x20,0x1
            dut.instruction_memory.data[18] = 32'hbada0a13;   // 0048: addi x20,x20,-1107
            dut.instruction_memory.data[19] = 32'h000fa023;   // 004c: sw x0,0(x31)
            dut.instruction_memory.data[20] = 32'h0000006f;   // 0050: j 50 <_start+0x50>
            dut.instruction_memory.data[21] = 32'h34002af3;   // 0054: csrr x21,mscratch
            dut.instruction_memory.data[22] = 32'h34102b73;   // 0058: csrr x22,mepc
            dut.instruction_memory.data[23] = 32'h00006a37;   // 005c: lui x20,0x6
            dut.instruction_memory.data[24] = 32'h00da0a13;   // 0060: addi x20,x20,13
            dut.instruction_memory.data[25] = 32'h00000013;   // 0064: nop
            dut.instruction_memory.data[26] = 32'h00000013;   // 0068: nop
            dut.instruction_memory.data[27] = 32'h00000013;   // 006c: nop
            dut.instruction_memory.data[28] = 32'h00000013;   // 0070: nop
            dut.instruction_memory.data[29] = 32'h000fa023;   // 0074: sw x0,0(x31)
            dut.instruction_memory.data[30] = 32'h0000006f;   // 0078: j 78 <target+0x24>
        end
    endtask

    task load_mret_gap4;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h00000517;   // 0004: auipc x10,0x0
            dut.instruction_memory.data[2] = 32'h05450513;   // 0008: addi x10,x10,84
            dut.instruction_memory.data[3] = 32'h34151073;   // 000c: csrw mepc,x10
            dut.instruction_memory.data[4] = 32'h00000013;   // 0010: nop
            dut.instruction_memory.data[5] = 32'h00000013;   // 0014: nop
            dut.instruction_memory.data[6] = 32'h00000013;   // 0018: nop
            dut.instruction_memory.data[7] = 32'h00000013;   // 001c: nop
            dut.instruction_memory.data[8] = 32'h00000013;   // 0020: nop
            dut.instruction_memory.data[9] = 32'h00000013;   // 0024: nop
            dut.instruction_memory.data[10] = 32'h000012b7;   // 0028: lui x5,0x1
            dut.instruction_memory.data[11] = 32'h23428293;   // 002c: addi x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h30200073;   // 0044: mret
            dut.instruction_memory.data[18] = 32'h00001a37;   // 0048: lui x20,0x1
            dut.instruction_memory.data[19] = 32'hbada0a13;   // 004c: addi x20,x20,-1107
            dut.instruction_memory.data[20] = 32'h000fa023;   // 0050: sw x0,0(x31)
            dut.instruction_memory.data[21] = 32'h0000006f;   // 0054: j 54 <_start+0x54>
            dut.instruction_memory.data[22] = 32'h34002af3;   // 0058: csrr x21,mscratch
            dut.instruction_memory.data[23] = 32'h34102b73;   // 005c: csrr x22,mepc
            dut.instruction_memory.data[24] = 32'h00006a37;   // 0060: lui x20,0x6
            dut.instruction_memory.data[25] = 32'h00da0a13;   // 0064: addi x20,x20,13
            dut.instruction_memory.data[26] = 32'h00000013;   // 0068: nop
            dut.instruction_memory.data[27] = 32'h00000013;   // 006c: nop
            dut.instruction_memory.data[28] = 32'h00000013;   // 0070: nop
            dut.instruction_memory.data[29] = 32'h00000013;   // 0074: nop
            dut.instruction_memory.data[30] = 32'h000fa023;   // 0078: sw x0,0(x31)
            dut.instruction_memory.data[31] = 32'h0000006f;   // 007c: j 7c <target+0x24>
        end
    endtask

    task load_basic;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100000b7;   // 0004: lui x1,0x10000
            dut.instruction_memory.data[2] = 32'h00000113;   // 0008: li x2,0
            dut.instruction_memory.data[3] = 32'h00100193;   // 000c: li x3,1
            dut.instruction_memory.data[4] = 32'h00b00213;   // 0010: li x4,11
            dut.instruction_memory.data[5] = 32'h00310133;   // 0014: add x2,x2,x3
            dut.instruction_memory.data[6] = 32'h00118193;   // 0018: addi x3,x3,1
            dut.instruction_memory.data[7] = 32'hfe419ce3;   // 001c: bne x3,x4,14 <loop>
            dut.instruction_memory.data[8] = 32'h022102b3;   // 0020: mul x5,x2,x2
            dut.instruction_memory.data[9] = 32'h00700313;   // 0024: li x6,7
            dut.instruction_memory.data[10] = 32'h0262d3b3;   // 0028: divu x7,x5,x6
            dut.instruction_memory.data[11] = 32'h0262f433;   // 002c: remu x8,x5,x6
            dut.instruction_memory.data[12] = 32'h0050a423;   // 0030: sw x5,8(x1)
            dut.instruction_memory.data[13] = 32'h0080a483;   // 0034: lw x9,8(x1)
            dut.instruction_memory.data[14] = 32'h00608823;   // 0038: sb x6,16(x1)
            dut.instruction_memory.data[15] = 32'h0100c503;   // 003c: lbu x10,16(x1)
            dut.instruction_memory.data[16] = 32'h01429593;   // 0040: slli x11,x5,0x14
            dut.instruction_memory.data[17] = 32'h4145d613;   // 0044: srai x12,x11,0x14
            dut.instruction_memory.data[18] = 32'hfff00693;   // 0048: li x13,-1
            dut.instruction_memory.data[19] = 32'h00000013;   // 004c: nop
            dut.instruction_memory.data[20] = 32'h00000013;   // 0050: nop
            dut.instruction_memory.data[21] = 32'h00000013;   // 0054: nop
            dut.instruction_memory.data[22] = 32'h00000013;   // 0058: nop
            dut.instruction_memory.data[23] = 32'h000fa023;   // 005c: sw x0,0(x31)
            dut.instruction_memory.data[24] = 32'h0000006f;   // 0060: j 60 <loop+0x4c>
        end
    endtask

    // Reset the core, run the loaded program until it stores to DONE_ADDR
    task run_program;
        input [8*24-1:0] name;
        integer clocks;
        integer wait_clocks;
        begin
            place_program;
            reset = 1'b1;
            repeat (5) @(posedge clk);
            #1;
            reset = 1'b0;

            // cycles counts core cycles (cache miss stall cycles are not counted)
            cycles = 0;
            clocks = 0;
            while (!done && cycles < TIMEOUT && clocks < TIMEOUT * 100) begin
                @(posedge clk);
                if (core_cycle) cycles = cycles + 1;
                clocks = clocks + 1;
            end
            // let older instructions finish writing back (10 core cycles)
            i = 0;
            wait_clocks = 0;
            while (i < 10 && wait_clocks < 10000) begin
                @(posedge clk);
                if (core_cycle) i = i + 1;
                wait_clocks = wait_clocks + 1;
            end
            #1;

            if (!done) begin
                test_count = test_count + 1;
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: program end | expected: store to 0x%h | actual: timeout after %0d cycles",
                         test_count, name, DONE_ADDR, TIMEOUT);
            end
            else begin
                $display("[TB]   %0s finished in %0d cycles (%0d clocks)", name, cycles, clocks);
            end
        end
    endtask
    // FENCE.I must not restart the program (x8 counts passes through 0x0004)
    task load_fencei_restart;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h00140413;   // 0004: addi x8,x8,1
            dut.instruction_memory.data[2] = 32'h00000013;   // 0008: nop
            dut.instruction_memory.data[3] = 32'h00000013;   // 000c: nop
            dut.instruction_memory.data[4] = 32'h0000100f;   // 0010: fence.i
            dut.instruction_memory.data[5] = 32'h00200313;   // 0014: li x6,2
            dut.instruction_memory.data[6] = 32'h00300393;   // 0018: li x7,3
            for (i = 7; i < 14; i = i + 1)
                dut.instruction_memory.data[i] = 32'h00000013;   // 001c..0034: nop
            dut.instruction_memory.data[14] = 32'h000fa023;  // 0038: sw x0,0(x31)
            dut.instruction_memory.data[15] = 32'h0000006f;  // 003c: j .
        end
    endtask

    // F() at 0x40 returns 1; the TB patches it to return 2 before the second call.
    // with_fence = 1: fence.i between the patch and the second call -> x12 = 2
    // with_fence = 0: control (x12 = 1 with an I-Cache: the stale line is still cached)
    task load_fencei_smc;
        input with_fence;
        begin
            clear_imem;
            dut.instruction_memory.data[0]  = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1]  = 32'h03c000ef;   // 0004: jal x1,0x40     (caches line 0x40)
            dut.instruction_memory.data[2]  = 32'h00050593;   // 0008: mv x11,x10      (x11 = 1)
            dut.instruction_memory.data[3]  = 32'h000fa423;   // 000c: sw x0,8(x31)    (TB patches F)
            dut.instruction_memory.data[4]  = 32'h00000013;   // 0010: nop
            dut.instruction_memory.data[5]  = 32'h100006b7;   // 0014: lui x13,0x10000
            dut.instruction_memory.data[6]  = 32'h0006a023;   // 0018: sw x0,0(x13)    (RAM store right before fence.i)
            dut.instruction_memory.data[7]  = with_fence ? 32'h0000100f : 32'h00000013;   // 001c: fence.i / nop
            dut.instruction_memory.data[8]  = 32'h020000ef;   // 0020: jal x1,0x40
            dut.instruction_memory.data[9]  = 32'h00050613;   // 0024: mv x12,x10
            dut.instruction_memory.data[10] = 32'h000fa023;   // 0028: sw x0,0(x31)    (DONE)
            dut.instruction_memory.data[11] = 32'h0000006f;   // 002c: j .
            dut.instruction_memory.data[16] = 32'h00100513;   // 0040: F: li x10,1 (patched to li x10,2)
            dut.instruction_memory.data[17] = 32'h00008067;   // 0044: ret
        end
    endtask

    // The instruction right after fence.i (0x14) is patched while fence.i is in EX, i.e. after
    // 0x14 was already fetched. Only the FENCE.I redirect (refetch of pc+4 after the
    // invalidation) makes the new instruction execute: x12 = 2 with the I-Cache integration,
    // x12 = 1 on the original core (its fence.i is a NOP).
    task load_fencei_refetch;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h00000013;   // 0004: nop
            dut.instruction_memory.data[2] = 32'h000fa823;   // 0008: sw x0,16(x31)   (TB patches 0x14)
            dut.instruction_memory.data[3] = 32'h00000013;   // 000c: nop
            dut.instruction_memory.data[4] = 32'h0000100f;   // 0010: fence.i
            dut.instruction_memory.data[5] = 32'h00100613;   // 0014: li x12,1 (patched to li x12,2)
            for (i = 6; i < 12; i = i + 1)
                dut.instruction_memory.data[i] = 32'h00000013;   // 0018..002c: nop
            dut.instruction_memory.data[12] = 32'h000fa023;  // 0030: sw x0,0(x31)
            dut.instruction_memory.data[13] = 32'h0000006f;  // 0034: j .
        end
    endtask

    task check_reg;
        input [8*24-1:0] name;
        input integer rd;
        input [XLEN-1:0] expected;
        reg [XLEN-1:0] actual;
        begin
            actual = dut.register_file.registers[rd];
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

    initial begin
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        reset      = 1'b1;

        // Instruction_Memory loads its firmware image at time 0; overwrite after
        #1;

        $display("============================================");
        $display(" RV32IM54F_8SP Core Testbench");
        $display("============================================");

        // --------------------------------------------------------------------
        // 1. EXR operand hold: a forwarded operand must survive an exr_data_stall
        //    while its producer drains past retire (lui x5; nop*k; lw/addi x6; add x9)
        //    retire freeze: addi x6; lui x5; nop*k; lw x6; add x9 must not lose x5
        //    while an older write to x6 sits in retire
        // --------------------------------------------------------------------
        $display("[TB] 1. EXR operand hold: a forwarded operand must survive an exr_data_stall");
        load_ld_stall_rs2_gap2;
        run_program("ld stall, rs2, gap 2");
        check_reg("ld stall, rs2, gap 2", 9, 32'h3773_0007);
        load_ld_stall_rs2_gap1;
        run_program("ld stall, rs2, gap 1");
        check_reg("ld stall, rs2, gap 1", 9, 32'h3773_0007);
        load_ld_stall_rs2_gap3;
        run_program("ld stall, rs2, gap 3");
        check_reg("ld stall, rs2, gap 3", 9, 32'h3773_0007);
        load_ld_stall_rs1_gap2;
        run_program("ld stall, rs1, gap 2");
        check_reg("ld stall, rs1, gap 2", 9, 32'h3773_0007);
        load_alu_stall_rs2_gap2;
        run_program("alu stall, rs2, gap 2");
        check_reg("alu stall, rs2, gap 2", 9, 32'h3773_0007);
        load_alu_stall_rs1_gap2;
        run_program("alu stall, rs1, gap 2");
        check_reg("alu stall, rs1, gap 2", 9, 32'h3773_0007);
        load_freeze_rs2_gap1;
        run_program("freeze, rs2, gap 1");
        check_reg("freeze, rs2, gap 1", 9, 32'h3773_0007);
        load_freeze_rs2_gap2;
        run_program("freeze, rs2, gap 2");
        check_reg("freeze, rs2, gap 2", 9, 32'h3773_0007);
        load_freeze_rs1_gap1;
        run_program("freeze, rs1, gap 1");
        check_reg("freeze, rs1, gap 1", 9, 32'h3773_0007);
        load_freeze_rs1_gap2;
        run_program("freeze, rs1, gap 2");
        check_reg("freeze, rs1, gap 2", 9, 32'h3773_0007);

        // --------------------------------------------------------------------
        // 2. IO-stage CSR address qualification: stores whose instr[31:20]
        //    equals 0x340/0x304/0x344 are not CSR accesses
        // --------------------------------------------------------------------
        $display("[TB] 2. IO-stage CSR address qualification: stores whose instr[31:20]");
        load_csr_alias;
        run_program("stores aliasing CSRs");
        cycles_alias = cycles;
        check_reg("stores aliasing CSRs", 20, 32'h5A5A);
        check_reg("stores aliasing CSRs", 21, 32'h5A5A);
        load_csr_noalias;
        run_program("stores, no CSR alias");
        cycles_noalias = cycles;
        check_reg("stores, no CSR alias", 20, 32'h5A5A);
        check_reg("stores, no CSR alias", 21, 32'h5A5A);
        check_value("stores aliasing CSRs", "cycles vs no alias", cycles_noalias, cycles_alias);

        // --------------------------------------------------------------------
        // 3. CSR write in WB while the trap FSM drives the CSR port:
        //    csrw mscratch; nop*k; mret must keep mepc and return to target
        // --------------------------------------------------------------------
        $display("[TB] 3. CSR write in WB while the trap FSM drives the CSR port:");
        load_mret_gap1;
        run_program("csrw, 1 nop, mret");
        check_reg("csrw, 1 nop, mret", 20, 32'h600D);
        check_reg("csrw, 1 nop, mret", 22, PROGRAM_BASE + 32'h4c);
        load_mret_gap2;
        run_program("csrw, 2 nops, mret");
        check_reg("csrw, 2 nops, mret", 20, 32'h600D);
        check_reg("csrw, 2 nops, mret", 22, PROGRAM_BASE + 32'h50);
        load_mret_gap3;
        run_program("csrw, 3 nops, mret");
        check_reg("csrw, 3 nops, mret", 20, 32'h600D);
        check_reg("csrw, 3 nops, mret", 22, PROGRAM_BASE + 32'h54);
        load_mret_gap4;
        run_program("csrw, 4 nops, mret");
        check_reg("csrw, 4 nops, mret", 20, 32'h600D);
        check_reg("csrw, 4 nops, mret", 21, 32'h1234);
        check_reg("csrw, 4 nops, mret", 22, PROGRAM_BASE + 32'h58);

        // --------------------------------------------------------------------
        // 4. General regression
        // --------------------------------------------------------------------
        $display("[TB] 4. General regression");
        load_basic;
        run_program("basic");
        check_reg("basic", 2, 32'd55);
        check_reg("basic", 5, 32'd3025);
        check_reg("basic", 7, 32'd432);
        check_reg("basic", 8, 32'd1);
        check_reg("basic", 9, 32'd3025);
        check_reg("basic", 10, 32'd7);
        check_reg("basic", 12, 32'hFFFF_FBD1);
        check_reg("basic", 13, 32'hFFFF_FFFF);

        // --------------------------------------------------------------------
        // 5. FENCE.I: no restart, younger instructions still execute
        // --------------------------------------------------------------------
        $display("[TB] 5. FENCE.I");
        load_fencei_restart;
        run_program("fence.i no restart");
        check_reg("fence.i no restart", 8, 32'd1);
        check_reg("fence.i no restart", 6, 32'd2);
        check_reg("fence.i no restart", 7, 32'd3);

        // self-modifying code: the patched F() is seen only after fence.i
        patch_en = 1'b1;
        load_fencei_smc(1'b1);
        run_program("fence.i smc");
        check_reg("fence.i smc", 11, 32'd1);
        check_reg("fence.i smc", 12, 32'd2);
`ifdef HAS_ICACHE
        check_value("fence.i smc", "icache fence_i_done", 1, fence_done_count);
        check_value("fence.i smc", "fence.i held by store", 1, (fi_held > 0) ? 1 : 0);
        check_value("fence.i smc", "ordering violations", 0, fi_violations);
`endif
        load_fencei_smc(1'b0);
        run_program("smc control, no fence.i");
        check_reg("smc control, no fence.i", 11, 32'd1);
`ifdef HAS_ICACHE
        if (ICACHE_EN != 0 && DDR_PROGRAM)
            check_reg("smc control, no fence.i", 12, 32'd1);   // stale cached line
        else
            check_reg("smc control, no fence.i", 12, 32'd2);   // Boot ROM is not cached
        check_value("smc control, no fence.i", "icache fence_i_done", 0, fence_done_count);
`else
        check_reg("smc control, no fence.i", 12, 32'd2);       // no cache: the patch is seen
`endif

        // fence.i must refetch the younger instructions after the invalidation
        load_fencei_refetch;
        run_program("fence.i refetch pc+4");
`ifdef HAS_ICACHE
        check_reg("fence.i refetch pc+4", 12, 32'd2);
`else
        check_reg("fence.i refetch pc+4", 12, 32'd1);          // original core: fence.i is a NOP
`endif
        patch_en = 1'b0;

`ifdef HAS_ICACHE
        check_value("all programs", "fence.i order violations", 0, fi_violations);
`endif

        $display("============================================");
        $display(" PASS: %0d  FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" TESTS FAILED");
        $display("============================================");
        $finish;
    end

endmodule
