`timescale 1ns / 1ps

module RV64IM72F_8SP_tb;
    parameter XLEN = 64;

    localparam [XLEN-1:0] DONE_ADDR = 64'h0000_0000_1001_0000;
    localparam integer    TIMEOUT   = 5000;
    localparam [31:0]     HALT      = 32'h0000_006F;   // jal x0, 0

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

    RV64IM72F8SP #(.XLEN(XLEN)) dut (
        .clk(clk),
        .clk_enable(1'b1),
        .reset(reset),
        .UART_busy(1'b0),
        .timer_interrupt_pending(1'b0),
        .MMIO_read_data({XLEN{1'b0}}),

        .retire_instruction(retire_instruction),
        .MMIO_data_memory_write_data(MMIO_data_memory_write_data),
        .MMIO_data_memory_address(MMIO_data_memory_address),
        .MMIO_data_memory_write_enable(MMIO_data_memory_write_enable)
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

    task clear_imem;
        begin
            for (i = 0; i < 1024; i = i + 1)
                dut.instruction_memory.data[i] = HALT;
            for (i = 0; i < 32; i = i + 1)
                dut.register_file.registers[i] = {XLEN{1'b0}};
        end
    endtask

    // ------------------------------------------------------------------------
    // Test programs (assembled with riscv64-unknown-elf-gcc -march=rv64im_zicsr)
    // ------------------------------------------------------------------------
    task load_ld_stall_rs2_gap2;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100006b7;   // 0004: lui x13,0x10000
            dut.instruction_memory.data[2] = 32'h00700713;   // 0008: li x14,7
            dut.instruction_memory.data[3] = 32'h00e6b023;   // 000c: sd x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f42829b;   // 0014: addiw x5,x5,1268
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
            dut.instruction_memory.data[17] = 32'h0006b303;   // 0044: ld x6,0(x13)
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
            dut.instruction_memory.data[3] = 32'h00e6b023;   // 000c: sd x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f42829b;   // 0014: addiw x5,x5,1268
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
            dut.instruction_memory.data[16] = 32'h0006b303;   // 0040: ld x6,0(x13)
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
            dut.instruction_memory.data[3] = 32'h00e6b023;   // 000c: sd x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f42829b;   // 0014: addiw x5,x5,1268
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
            dut.instruction_memory.data[18] = 32'h0006b303;   // 0048: ld x6,0(x13)
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
            dut.instruction_memory.data[3] = 32'h00e6b023;   // 000c: sd x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f42829b;   // 0014: addiw x5,x5,1268
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
            dut.instruction_memory.data[17] = 32'h0006b303;   // 0044: ld x6,0(x13)
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
            dut.instruction_memory.data[3] = 32'h00e6b023;   // 000c: sd x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f42829b;   // 0014: addiw x5,x5,1268
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
            dut.instruction_memory.data[3] = 32'h00e6b023;   // 000c: sd x14,0(x13)
            dut.instruction_memory.data[4] = 32'h2fad72b7;   // 0010: lui x5,0x2fad7
            dut.instruction_memory.data[5] = 32'h4f42829b;   // 0014: addiw x5,x5,1268
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

    task load_csr_alias;
        begin
            clear_imem;
            dut.instruction_memory.data[0] = 32'h10010fb7;   // 0000: lui x31,0x10010
            dut.instruction_memory.data[1] = 32'h100000b7;   // 0004: lui x1,0x10000
            dut.instruction_memory.data[2] = 32'h01400113;   // 0008: li x2,20
            dut.instruction_memory.data[3] = 32'h00006237;   // 000c: lui x4,0x6
            dut.instruction_memory.data[4] = 32'ha5a2021b;   // 0010: addiw x4,x4,-1446
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
            dut.instruction_memory.data[4] = 32'ha5a2021b;   // 0010: addiw x4,x4,-1446
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
            dut.instruction_memory.data[11] = 32'h2342829b;   // 002c: addiw x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h30200073;   // 0038: mret
            dut.instruction_memory.data[15] = 32'h00001a37;   // 003c: lui x20,0x1
            dut.instruction_memory.data[16] = 32'hbada0a1b;   // 0040: addiw x20,x20,-1107
            dut.instruction_memory.data[17] = 32'h000fa023;   // 0044: sw x0,0(x31)
            dut.instruction_memory.data[18] = 32'h0000006f;   // 0048: j 48 <_start+0x48>
            dut.instruction_memory.data[19] = 32'h34002af3;   // 004c: csrr x21,mscratch
            dut.instruction_memory.data[20] = 32'h34102b73;   // 0050: csrr x22,mepc
            dut.instruction_memory.data[21] = 32'h00006a37;   // 0054: lui x20,0x6
            dut.instruction_memory.data[22] = 32'h00da0a1b;   // 0058: addiw x20,x20,13
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
            dut.instruction_memory.data[11] = 32'h2342829b;   // 002c: addiw x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h30200073;   // 003c: mret
            dut.instruction_memory.data[16] = 32'h00001a37;   // 0040: lui x20,0x1
            dut.instruction_memory.data[17] = 32'hbada0a1b;   // 0044: addiw x20,x20,-1107
            dut.instruction_memory.data[18] = 32'h000fa023;   // 0048: sw x0,0(x31)
            dut.instruction_memory.data[19] = 32'h0000006f;   // 004c: j 4c <_start+0x4c>
            dut.instruction_memory.data[20] = 32'h34002af3;   // 0050: csrr x21,mscratch
            dut.instruction_memory.data[21] = 32'h34102b73;   // 0054: csrr x22,mepc
            dut.instruction_memory.data[22] = 32'h00006a37;   // 0058: lui x20,0x6
            dut.instruction_memory.data[23] = 32'h00da0a1b;   // 005c: addiw x20,x20,13
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
            dut.instruction_memory.data[11] = 32'h2342829b;   // 002c: addiw x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h30200073;   // 0040: mret
            dut.instruction_memory.data[17] = 32'h00001a37;   // 0044: lui x20,0x1
            dut.instruction_memory.data[18] = 32'hbada0a1b;   // 0048: addiw x20,x20,-1107
            dut.instruction_memory.data[19] = 32'h000fa023;   // 004c: sw x0,0(x31)
            dut.instruction_memory.data[20] = 32'h0000006f;   // 0050: j 50 <_start+0x50>
            dut.instruction_memory.data[21] = 32'h34002af3;   // 0054: csrr x21,mscratch
            dut.instruction_memory.data[22] = 32'h34102b73;   // 0058: csrr x22,mepc
            dut.instruction_memory.data[23] = 32'h00006a37;   // 005c: lui x20,0x6
            dut.instruction_memory.data[24] = 32'h00da0a1b;   // 0060: addiw x20,x20,13
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
            dut.instruction_memory.data[11] = 32'h2342829b;   // 002c: addiw x5,x5,564
            dut.instruction_memory.data[12] = 32'h34029073;   // 0030: csrw mscratch,x5
            dut.instruction_memory.data[13] = 32'h00000013;   // 0034: nop
            dut.instruction_memory.data[14] = 32'h00000013;   // 0038: nop
            dut.instruction_memory.data[15] = 32'h00000013;   // 003c: nop
            dut.instruction_memory.data[16] = 32'h00000013;   // 0040: nop
            dut.instruction_memory.data[17] = 32'h30200073;   // 0044: mret
            dut.instruction_memory.data[18] = 32'h00001a37;   // 0048: lui x20,0x1
            dut.instruction_memory.data[19] = 32'hbada0a1b;   // 004c: addiw x20,x20,-1107
            dut.instruction_memory.data[20] = 32'h000fa023;   // 0050: sw x0,0(x31)
            dut.instruction_memory.data[21] = 32'h0000006f;   // 0054: j 54 <_start+0x54>
            dut.instruction_memory.data[22] = 32'h34002af3;   // 0058: csrr x21,mscratch
            dut.instruction_memory.data[23] = 32'h34102b73;   // 005c: csrr x22,mepc
            dut.instruction_memory.data[24] = 32'h00006a37;   // 0060: lui x20,0x6
            dut.instruction_memory.data[25] = 32'h00da0a1b;   // 0064: addiw x20,x20,13
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
            dut.instruction_memory.data[12] = 32'h0050b423;   // 0030: sd x5,8(x1)
            dut.instruction_memory.data[13] = 32'h0080b483;   // 0034: ld x9,8(x1)
            dut.instruction_memory.data[14] = 32'h00608823;   // 0038: sb x6,16(x1)
            dut.instruction_memory.data[15] = 32'h0100c503;   // 003c: lbu x10,16(x1)
            dut.instruction_memory.data[16] = 32'h02829593;   // 0040: slli x11,x5,0x28
            dut.instruction_memory.data[17] = 32'h4285d613;   // 0044: srai x12,x11,0x28
            dut.instruction_memory.data[18] = 32'hfff0069b;   // 0048: addiw x13,x0,-1
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
            // let older instructions finish writing back
            repeat (10) @(posedge clk);
            #1;

            if (!done) begin
                test_count = test_count + 1;
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: program end | expected: store to 0x%h | actual: timeout after %0d cycles",
                         test_count, name, DONE_ADDR, TIMEOUT);
            end
            else begin
                $display("[TB]   %0s finished in %0d cycles", name, cycles);
            end
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
        $display(" RV64IM72F_8SP Core Testbench");
        $display("============================================");

        // --------------------------------------------------------------------
        // 1. EXR operand hold: a forwarded operand must survive an exr_data_stall
        //    while its producer drains past retire (lui x5; nop*k; ld/addi x6; add x9)
        // --------------------------------------------------------------------
        $display("[TB] 1. EXR operand hold: a forwarded operand must survive an exr_data_stall");
        load_ld_stall_rs2_gap2;
        run_program("ld stall, rs2, gap 2");
        check_reg("ld stall, rs2, gap 2", 9, 64'h0000_0000_3773_0007);
        load_ld_stall_rs2_gap1;
        run_program("ld stall, rs2, gap 1");
        check_reg("ld stall, rs2, gap 1", 9, 64'h0000_0000_3773_0007);
        load_ld_stall_rs2_gap3;
        run_program("ld stall, rs2, gap 3");
        check_reg("ld stall, rs2, gap 3", 9, 64'h0000_0000_3773_0007);
        load_ld_stall_rs1_gap2;
        run_program("ld stall, rs1, gap 2");
        check_reg("ld stall, rs1, gap 2", 9, 64'h0000_0000_3773_0007);
        load_alu_stall_rs2_gap2;
        run_program("alu stall, rs2, gap 2");
        check_reg("alu stall, rs2, gap 2", 9, 64'h0000_0000_3773_0007);
        load_alu_stall_rs1_gap2;
        run_program("alu stall, rs1, gap 2");
        check_reg("alu stall, rs1, gap 2", 9, 64'h0000_0000_3773_0007);

        // --------------------------------------------------------------------
        // 2. IO-stage CSR address qualification: stores whose instr[31:20]
        //    equals 0x340/0x304/0x344 are not CSR accesses
        // --------------------------------------------------------------------
        $display("[TB] 2. IO-stage CSR address qualification: stores whose instr[31:20]");
        load_csr_alias;
        run_program("stores aliasing CSRs");
        cycles_alias = cycles;
        check_reg("stores aliasing CSRs", 20, 64'h5A5A);
        check_reg("stores aliasing CSRs", 21, 64'h5A5A);
        load_csr_noalias;
        run_program("stores, no CSR alias");
        cycles_noalias = cycles;
        check_reg("stores, no CSR alias", 20, 64'h5A5A);
        check_reg("stores, no CSR alias", 21, 64'h5A5A);
        check_value("stores aliasing CSRs", "cycles vs no alias", cycles_noalias, cycles_alias);

        // --------------------------------------------------------------------
        // 3. CSR write in WB while the trap FSM drives the CSR port:
        //    csrw mscratch; nop*k; mret must keep mepc and return to target
        // --------------------------------------------------------------------
        $display("[TB] 3. CSR write in WB while the trap FSM drives the CSR port:");
        load_mret_gap1;
        run_program("csrw, 1 nop, mret");
        check_reg("csrw, 1 nop, mret", 20, 64'h600D);
        check_reg("csrw, 1 nop, mret", 22, 64'h4c);
        load_mret_gap2;
        run_program("csrw, 2 nops, mret");
        check_reg("csrw, 2 nops, mret", 20, 64'h600D);
        check_reg("csrw, 2 nops, mret", 22, 64'h50);
        load_mret_gap3;
        run_program("csrw, 3 nops, mret");
        check_reg("csrw, 3 nops, mret", 20, 64'h600D);
        check_reg("csrw, 3 nops, mret", 22, 64'h54);
        load_mret_gap4;
        run_program("csrw, 4 nops, mret");
        check_reg("csrw, 4 nops, mret", 20, 64'h600D);
        check_reg("csrw, 4 nops, mret", 21, 64'h1234);
        check_reg("csrw, 4 nops, mret", 22, 64'h58);

        // --------------------------------------------------------------------
        // 4. General regression
        // --------------------------------------------------------------------
        $display("[TB] 4. General regression");
        load_basic;
        run_program("basic");
        check_reg("basic", 2, 64'd55);
        check_reg("basic", 5, 64'd3025);
        check_reg("basic", 7, 64'd432);
        check_reg("basic", 8, 64'd1);
        check_reg("basic", 9, 64'd3025);
        check_reg("basic", 10, 64'd7);
        check_reg("basic", 12, 64'd3025);
        check_reg("basic", 13, 64'hFFFF_FFFF_FFFF_FFFF);

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
