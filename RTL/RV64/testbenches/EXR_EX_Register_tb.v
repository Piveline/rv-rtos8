`timescale 1ns / 1ps

module EXR_EX_Register_tb;
    parameter XLEN = 64;

    // Width of every port concatenated, in declaration order
    localparam W = 7*XLEN + 1 + 32 + 3 + 3 + 3 + 7 + 3 + 7 + 5 + 20 + 5 + 6 + 1 + 3;

    reg clk;
    reg clk_enable;
    reg flush;
    reg EXR_EX_stall;

    reg [XLEN-1:0] EXR_src_A;
    reg [XLEN-1:0] EXR_src_B;
    reg [XLEN-1:0] EXR_pc;
    reg [XLEN-1:0] EXR_pc_plus_4;
    reg EXR_branch_estimation;
    reg [31:0] EXR_instruction;
    reg EXR_jump;
    reg EXR_memory_read;
    reg EXR_memory_write;
    reg [2:0] EXR_register_file_write_data_select;
    reg EXR_register_write_enable;
    reg EXR_csr_write_enable;
    reg EXR_branch;
    reg [6:0] EXR_opcode;
    reg [2:0] EXR_funct3;
    reg [6:0] EXR_funct7;
    reg [4:0] EXR_rd;
    reg [19:0] EXR_raw_imm;
    reg [XLEN-1:0] EXR_read_data2;
    reg [4:0] EXR_rs1;
    reg [5:0] EXR_rs2;
    reg [XLEN-1:0] EXR_imm;
    reg [XLEN-1:0] EXR_csr_read_data;
    reg EXR_is_load;
    reg [2:0] EXR_forward_select;

    wire [XLEN-1:0] EX_src_A;
    wire [XLEN-1:0] EX_src_B;
    wire [XLEN-1:0] EX_pc;
    wire [XLEN-1:0] EX_pc_plus_4;
    wire EX_branch_estimation;
    wire [31:0] EX_instruction;
    wire EX_jump;
    wire EX_memory_read;
    wire EX_memory_write;
    wire [2:0] EX_register_file_write_data_select;
    wire EX_register_write_enable;
    wire EX_csr_write_enable;
    wire EX_branch;
    wire [6:0] EX_opcode;
    wire [2:0] EX_funct3;
    wire [6:0] EX_funct7;
    wire [4:0] EX_rd;
    wire [19:0] EX_raw_imm;
    wire [XLEN-1:0] EX_read_data2;
    wire [4:0] EX_rs1;
    wire [5:0] EX_rs2;
    wire [XLEN-1:0] EX_imm;
    wire [XLEN-1:0] EX_csr_read_data;
    wire EX_is_load;
    wire [2:0] EX_forward_select;

    integer test_count;
    integer pass_count;
    integer fail_count;
    integer i;

    EXR_EX_Register #(.XLEN(XLEN)) exr_ex_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(flush),
        .EXR_EX_stall(EXR_EX_stall),

        .EXR_src_A(EXR_src_A),
        .EXR_src_B(EXR_src_B),

        .EXR_pc(EXR_pc),
        .EXR_pc_plus_4(EXR_pc_plus_4),
        .EXR_branch_estimation(EXR_branch_estimation),
        .EXR_instruction(EXR_instruction),
        .EXR_jump(EXR_jump),
        .EXR_memory_read(EXR_memory_read),
        .EXR_memory_write(EXR_memory_write),
        .EXR_register_file_write_data_select(EXR_register_file_write_data_select),
        .EXR_register_write_enable(EXR_register_write_enable),
        .EXR_csr_write_enable(EXR_csr_write_enable),
        .EXR_branch(EXR_branch),
        .EXR_opcode(EXR_opcode),
        .EXR_funct3(EXR_funct3),
        .EXR_funct7(EXR_funct7),
        .EXR_rd(EXR_rd),
        .EXR_raw_imm(EXR_raw_imm),
        .EXR_read_data2(EXR_read_data2),
        .EXR_rs1(EXR_rs1),
        .EXR_rs2(EXR_rs2),
        .EXR_imm(EXR_imm),
        .EXR_csr_read_data(EXR_csr_read_data),
        .EXR_is_load(EXR_is_load),
        .EXR_forward_select(EXR_forward_select),

        .EX_src_A(EX_src_A),
        .EX_src_B(EX_src_B),

        .EX_pc(EX_pc),
        .EX_pc_plus_4(EX_pc_plus_4),
        .EX_branch_estimation(EX_branch_estimation),
        .EX_instruction(EX_instruction),
        .EX_jump(EX_jump),
        .EX_memory_read(EX_memory_read),
        .EX_memory_write(EX_memory_write),
        .EX_register_file_write_data_select(EX_register_file_write_data_select),
        .EX_register_write_enable(EX_register_write_enable),
        .EX_csr_write_enable(EX_csr_write_enable),
        .EX_branch(EX_branch),
        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .EX_funct7(EX_funct7),
        .EX_rd(EX_rd),
        .EX_raw_imm(EX_raw_imm),
        .EX_read_data2(EX_read_data2),
        .EX_rs1(EX_rs1),
        .EX_rs2(EX_rs2),
        .EX_imm(EX_imm),
        .EX_csr_read_data(EX_csr_read_data),
        .EX_is_load(EX_is_load),
        .EX_forward_select(EX_forward_select)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function [W-1:0] in_vec;
        input dummy;
        in_vec = {
        EXR_src_A, EXR_src_B, EXR_pc, EXR_pc_plus_4, EXR_branch_estimation, EXR_instruction,
        EXR_jump, EXR_memory_read, EXR_memory_write, EXR_register_file_write_data_select,
        EXR_register_write_enable, EXR_csr_write_enable, EXR_branch, EXR_opcode, EXR_funct3,
        EXR_funct7, EXR_rd, EXR_raw_imm, EXR_read_data2, EXR_rs1, EXR_rs2, EXR_imm,
        EXR_csr_read_data, EXR_is_load, EXR_forward_select
    };
    endfunction

    wire [W-1:0] out_vec = {
        EX_src_A, EX_src_B, EX_pc, EX_pc_plus_4, EX_branch_estimation, EX_instruction,
        EX_jump, EX_memory_read, EX_memory_write, EX_register_file_write_data_select,
        EX_register_write_enable, EX_csr_write_enable, EX_branch, EX_opcode, EX_funct3,
        EX_funct7, EX_rd, EX_raw_imm, EX_read_data2, EX_rs1, EX_rs2, EX_imm,
        EX_csr_read_data, EX_is_load, EX_forward_select
    };

    // Flush contents: everything zero except the instruction, which becomes a NOP
    localparam [W-1:0] FLUSH_VEC = {
        {4*XLEN{1'b0}}, 1'b0, 32'h0000_0013,
        1'b0, 1'b0, 1'b0, 3'b0,
        1'b0, 1'b0, 1'b0, 7'b0, 3'b0,
        7'b0, 5'b0, 20'b0, {XLEN{1'b0}}, 5'b0, 6'b0, {XLEN{1'b0}},
        {XLEN{1'b0}}, 1'b0, 3'b0
    };

    // Reference model of the register contents
    reg [W-1:0] exp_vec;
    reg [5:0] exp_rs2;
    reg [XLEN-1:0] exp_pc;
    reg [31:0] exp_instruction;


    task randomize_inputs;
        begin
            EXR_src_A = {$random, $random};
            EXR_src_B = {$random, $random};
            EXR_pc = {$random, $random};
            EXR_pc_plus_4 = {$random, $random};
            EXR_branch_estimation = $random;
            EXR_instruction = $random;
            EXR_jump = $random;
            EXR_memory_read = $random;
            EXR_memory_write = $random;
            EXR_register_file_write_data_select = $random;
            EXR_register_write_enable = $random;
            EXR_csr_write_enable = $random;
            EXR_branch = $random;
            EXR_opcode = $random;
            EXR_funct3 = $random;
            EXR_funct7 = $random;
            EXR_rd = $random;
            EXR_raw_imm = $random;
            EXR_read_data2 = {$random, $random};
            EXR_rs1 = $random;
            EXR_rs2 = $random;
            EXR_imm = {$random, $random};
            EXR_csr_read_data = {$random, $random};
            EXR_is_load = $random;
            EXR_forward_select = $random;
        end
    endtask

    // Clock once with the controls and inputs already set, then compare every output
    task cycle;
        input [8*24-1:0] name;
        begin
            #1;   // let the inputs set by the caller settle
            if (clk_enable) begin
                if (flush)
                    exp_vec = FLUSH_VEC;
                else if (!EXR_EX_stall)
                    exp_vec = in_vec(1'b0);
            end
            exp_rs2         = exp_vec[3 + 1 + 2*XLEN +: 6];
            exp_pc          = exp_vec[W - 2*XLEN - 1 -: XLEN];
            exp_instruction = exp_vec[W - 4*XLEN - 2 -: 32];

            @(posedge clk);
            #1;

            test_count = test_count + 1;
            if (out_vec === exp_vec) begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %0s | test: EXR_rs2=0x%h en=%b stall=%b flush=%b | expected: EX_rs2=0x%h EX_pc=0x%h EX_inst=0x%h | actual: EX_rs2=0x%h EX_pc=0x%h EX_inst=0x%h",
                         test_count, name, EXR_rs2, clk_enable, EXR_EX_stall, flush,
                         exp_rs2, exp_pc, exp_instruction, EX_rs2, EX_pc, EX_instruction);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: EXR_rs2=0x%h en=%b stall=%b flush=%b | expected: EX_rs2=0x%h EX_pc=0x%h EX_inst=0x%h | actual: EX_rs2=0x%h EX_pc=0x%h EX_inst=0x%h",
                         test_count, name, EXR_rs2, clk_enable, EXR_EX_stall, flush,
                         exp_rs2, exp_pc, exp_instruction, EX_rs2, EX_pc, EX_instruction);
                $display("       all ports expected: 0x%h", exp_vec);
                $display("       all ports actual:   0x%h", out_vec);
            end

            clk_enable   = 1'b1;
            flush        = 1'b0;
            EXR_EX_stall = 1'b0;
        end
    endtask

    initial begin
        test_count   = 0;
        pass_count   = 0;
        fail_count   = 0;
        clk_enable   = 1'b1;
        flush        = 1'b0;
        EXR_EX_stall = 1'b0;
        randomize_inputs;

        $display("============================================");
        $display(" EXR_EX_Register Testbench (XLEN=%0d)", XLEN);
        $display("============================================");

        // --------------------------------------------------------------------
        $display("[TB] 1. Flush");
        // --------------------------------------------------------------------
        flush = 1'b1;
        cycle("flush");

        // --------------------------------------------------------------------
        $display("[TB] 2. rs2 pass-through, all 6-bit values");
        // --------------------------------------------------------------------
        for (i = 0; i < 64; i = i + 1) begin
            randomize_inputs;
            EXR_rs2 = i;
            cycle("rs2 pass-through");
        end

        // --------------------------------------------------------------------
        $display("[TB] 3. Stall holds, flush clears, clk_enable=0 holds");
        // --------------------------------------------------------------------
        randomize_inputs; EXR_rs2 = 6'h3F;
        cycle("load rs2=0x3f");
        randomize_inputs; EXR_rs2 = 6'h05; EXR_EX_stall = 1'b1;
        cycle("stall holds");
        randomize_inputs; EXR_rs2 = 6'h05; EXR_EX_stall = 1'b1;
        cycle("stall holds");
        randomize_inputs; EXR_rs2 = 6'h05;
        cycle("stall released");
        randomize_inputs; EXR_rs2 = 6'h2A; flush = 1'b1;
        cycle("flush");
        randomize_inputs; EXR_rs2 = 6'h2A; flush = 1'b1; EXR_EX_stall = 1'b1;
        cycle("flush beats stall");
        randomize_inputs; EXR_rs2 = 6'h21;
        cycle("load rs2=0x21");
        randomize_inputs; EXR_rs2 = 6'h00; clk_enable = 1'b0;
        cycle("clk_enable=0 holds");
        randomize_inputs; EXR_rs2 = 6'h00; clk_enable = 1'b0; flush = 1'b1;
        cycle("clk_enable=0 holds");

        // --------------------------------------------------------------------
        $display("[TB] 4. Random inputs and controls");
        // --------------------------------------------------------------------
        for (i = 0; i < 1000; i = i + 1) begin
            randomize_inputs;
            EXR_EX_stall = ($random & 3) == 0;
            flush        = ($random & 7) == 0;
            clk_enable   = ($random & 15) != 0;
            cycle("random");
        end

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
