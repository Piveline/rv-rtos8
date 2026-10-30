`timescale 1ns / 1ps

module Hazard_Unit_tb;
    localparam [6:0] OP_ALU   = 7'b0110011;
    localparam [6:0] OP_STORE = 7'b0100011;

    reg reset;
    reg trap_done;
    reg csr_ready;
    reg standby_mode;
    reg div_start;
    reg div_busy;
    reg mul_start;
    reg mul_busy;
    reg write_done;
    reg [2:0] trap_status;
    reg misaligned_instruction_flush;
    reg misaligned_memory_flush;
    reg pth_done_flush;
    reg [4:0] EXR_rs1;
    reg [4:0] EXR_rs2;
    reg [1:0] EXR_alu_src_A_select;
    reg [2:0] EXR_alu_src_B_select;
    reg [6:0] EXR_opcode;
    reg EXR_csr_write_enable;
    reg EXR_jump;
    reg [4:0] EX_rd;
    reg [6:0] EX_opcode;
    reg EX_register_write_enable;
    reg EX_is_load;
    reg [2:0] EX_forward_select;
    reg EX_csr_write_enable;
    reg [4:0] EX2_rd;
    reg [6:0] EX2_opcode;
    reg EX2_branch;
    reg EX2_register_write_enable;
    reg ex2_is_load;
    reg [4:0] MEM_rd;
    reg [6:0] MEM_opcode;
    reg [4:0] MEM_rs2;
    reg MEM_register_write_enable;
    reg MEM_csr_write_enable;
    reg [11:0] MEM_csr_write_address;
    reg [4:0] WB_rd;
    reg WB_register_write_enable;
    reg WB_csr_write_enable;
    reg [11:0] WB_csr_write_address;
    reg retire_register_write_enable;
    reg [4:0] retire_rd;
    reg EX2_jump;
    reg branch_prediction_miss;
    reg mret_done;

    wire [1:0] hazard_ex;
    wire [1:0] hazard_ex2;
    wire [1:0] hazard_mem;
    wire [1:0] hazard_wb;
    wire [1:0] hazard_retire;
    wire store_hazard_ex;
    wire store_hazard_ex2;
    wire store_hazard_mem;
    wire store_hazard_wb;
    wire store_hazard_wb_to_mem;
    wire load_use_hazard;
    wire exr_data_stall;
    wire IF_IO_flush;
    wire IO_ID_flush;
    wire ID_EXR_flush;
    wire EXR_EX_flush;
    wire EX_EX2_flush;
    wire EX_MEM_flush;
    wire MEM_WB_flush;
    wire IF_IO_stall;
    wire IO_ID_stall;
    wire ID_EXR_stall;
    wire EXR_EX_stall;
    wire EX_EX2_stall;
    wire EX_MEM_stall;
    wire MEM_WB_stall;

    integer test_count;
    integer pass_count;
    integer fail_count;

    HazardUnit hazard_unit (
        .reset(reset),
        .trap_done(trap_done),
        .csr_ready(csr_ready),
        .standby_mode(standby_mode),
        .div_start(div_start),
        .div_busy(div_busy),
        .mul_start(mul_start),
        .mul_busy(mul_busy),
        .write_done(write_done),
        .trap_status(trap_status),
        .misaligned_instruction_flush(misaligned_instruction_flush),
        .misaligned_memory_flush(misaligned_memory_flush),
        .pth_done_flush(pth_done_flush),
        .EXR_rs1(EXR_rs1),
        .EXR_rs2(EXR_rs2),
        .EXR_alu_src_A_select(EXR_alu_src_A_select),
        .EXR_alu_src_B_select(EXR_alu_src_B_select),
        .EXR_opcode(EXR_opcode),
        .EXR_csr_write_enable(EXR_csr_write_enable),
        .EXR_jump(EXR_jump),
        .EX_rd(EX_rd),
        .EX_opcode(EX_opcode),
        .EX_register_write_enable(EX_register_write_enable),
        .EX_is_load(EX_is_load),
        .EX_forward_select(EX_forward_select),
        .EX_csr_write_enable(EX_csr_write_enable),
        .EX2_rd(EX2_rd),
        .EX2_opcode(EX2_opcode),
        .EX2_branch(EX2_branch),
        .EX2_register_write_enable(EX2_register_write_enable),
        .ex2_is_load(ex2_is_load),
        .MEM_rd(MEM_rd),
        .MEM_opcode(MEM_opcode),
        .MEM_rs2(MEM_rs2),
        .MEM_register_write_enable(MEM_register_write_enable),
        .MEM_csr_write_enable(MEM_csr_write_enable),
        .MEM_csr_write_address(MEM_csr_write_address),
        .WB_rd(WB_rd),
        .WB_register_write_enable(WB_register_write_enable),
        .WB_csr_write_enable(WB_csr_write_enable),
        .WB_csr_write_address(WB_csr_write_address),
        .retire_register_write_enable(retire_register_write_enable),
        .retire_rd(retire_rd),
        .EX2_jump(EX2_jump),
        .branch_prediction_miss(branch_prediction_miss),
        .mret_done(mret_done),

        .hazard_ex(hazard_ex),
        .hazard_ex2(hazard_ex2),
        .hazard_mem(hazard_mem),
        .hazard_wb(hazard_wb),
        .hazard_retire(hazard_retire),
        .store_hazard_ex(store_hazard_ex),
        .store_hazard_ex2(store_hazard_ex2),
        .store_hazard_mem(store_hazard_mem),
        .store_hazard_wb(store_hazard_wb),
        .store_hazard_wb_to_mem(store_hazard_wb_to_mem),
        .load_use_hazard(load_use_hazard),
        .exr_data_stall(exr_data_stall),
        .IF_IO_flush(IF_IO_flush),
        .IO_ID_flush(IO_ID_flush),
        .ID_EXR_flush(ID_EXR_flush),
        .EXR_EX_flush(EXR_EX_flush),
        .EX_EX2_flush(EX_EX2_flush),
        .EX_MEM_flush(EX_MEM_flush),
        .MEM_WB_flush(MEM_WB_flush),
        .IF_IO_stall(IF_IO_stall),
        .IO_ID_stall(IO_ID_stall),
        .ID_EXR_stall(ID_EXR_stall),
        .EXR_EX_stall(EXR_EX_stall),
        .EX_EX2_stall(EX_EX2_stall),
        .EX_MEM_stall(EX_MEM_stall),
        .MEM_WB_stall(MEM_WB_stall)
    );

    // Output groups, printed as bit strings
    //   fwd   = {hazard_ex, hazard_ex2, hazard_mem, hazard_wb, hazard_retire}  ([1]=rs2, [0]=rs1)
    //   store = {ex, ex2, mem, wb, wb_to_mem}
    //   flush / stall = {IF_IO, IO_ID, ID_EXR, EXR_EX, EX_EX2, EX_MEM, MEM_WB}
    wire [9:0] fwd = {hazard_ex, hazard_ex2, hazard_mem, hazard_wb, hazard_retire};
    wire [4:0] store = {store_hazard_ex, store_hazard_ex2, store_hazard_mem, store_hazard_wb, store_hazard_wb_to_mem};
    wire [6:0] flush = {IF_IO_flush, IO_ID_flush, ID_EXR_flush, EXR_EX_flush, EX_EX2_flush, EX_MEM_flush, MEM_WB_flush};
    wire [6:0] stall = {IF_IO_stall, IO_ID_stall, ID_EXR_stall, EXR_EX_stall, EX_EX2_stall, EX_MEM_stall, MEM_WB_stall};

    // Idle pipeline: no hazards, trap FSM idle, memory write finished.
    // EXR holds an ALU op reading x1 (rs1) and x2 (rs2).
    task idle;
        begin
            reset = 0; trap_done = 1; csr_ready = 1; standby_mode = 0;
            div_start = 0; div_busy = 0; mul_start = 0; mul_busy = 0; write_done = 1;
            trap_status = 3'b000; misaligned_instruction_flush = 0; misaligned_memory_flush = 0; pth_done_flush = 0;
            EXR_rs1 = 5'd1; EXR_rs2 = 5'd2; EXR_alu_src_A_select = 2'b01; EXR_alu_src_B_select = 3'b001;
            EXR_opcode = OP_ALU; EXR_csr_write_enable = 0; EXR_jump = 0;
            EX_rd = 5'd10; EX_opcode = OP_ALU; EX_register_write_enable = 1; EX_is_load = 0;
            EX_forward_select = 3'd0; EX_csr_write_enable = 0;
            EX2_rd = 5'd11; EX2_opcode = OP_ALU; EX2_branch = 0; EX2_register_write_enable = 1; ex2_is_load = 0;
            MEM_rd = 5'd12; MEM_opcode = OP_ALU; MEM_rs2 = 5'd20; MEM_register_write_enable = 1;
            MEM_csr_write_enable = 0; MEM_csr_write_address = 12'h0;
            WB_rd = 5'd13; WB_register_write_enable = 1; WB_csr_write_enable = 0; WB_csr_write_address = 12'h0;
            retire_register_write_enable = 1; retire_rd = 5'd14;
            EX2_jump = 0; branch_prediction_miss = 0; mret_done = 0;
        end
    endtask

    task check;
        input [8*24-1:0] name;
        input [8*44-1:0] desc;
        input [9:0] exp_fwd;
        input [4:0] exp_store;
        input exp_exr_stall;
        input [6:0] exp_flush;
        input [6:0] exp_stall;
        begin
            #1;
            test_count = test_count + 1;
            if (fwd === exp_fwd && store === exp_store && exr_data_stall === exp_exr_stall &&
                load_use_hazard === exp_exr_stall && flush === exp_flush && stall === exp_stall) begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %0s | test: %0s | expected: fwd=%b store=%b exr_stall=%b flush=%b stall=%b | actual: fwd=%b store=%b exr_stall=%b flush=%b stall=%b",
                         test_count, name, desc, exp_fwd, exp_store, exp_exr_stall, exp_flush, exp_stall,
                         fwd, store, exr_data_stall, flush, stall);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: %0s | expected: fwd=%b store=%b exr_stall=%b flush=%b stall=%b | actual: fwd=%b store=%b exr_stall=%b flush=%b stall=%b",
                         test_count, name, desc, exp_fwd, exp_store, exp_exr_stall, exp_flush, exp_stall,
                         fwd, store, exr_data_stall, flush, stall);
            end
            idle;
        end
    endtask

    initial begin
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        idle;

        $display("============================================");
        $display(" Hazard_Unit Testbench");
        $display("============================================");
        $display(" fwd   = {ex, ex2, mem, wb, retire} x {rs2, rs1}");
        $display(" store = {ex, ex2, mem, wb, wb_to_mem}");
        $display(" flush / stall = {IF_IO, IO_ID, ID_EXR, EXR_EX, EX_EX2, EX_MEM, MEM_WB}");

        // --------------------------------------------------------------------
        $display("[TB] 1. Forwarding selection");
        // --------------------------------------------------------------------
        check("idle", "no dependency", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        EX_rd = 5'd1; EX_forward_select = 3'd1;
        check("EX forward rs1", "EX(lui) writes x1", 10'b01_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        EX2_rd = 5'd2;
        check("BR forward rs2", "EX2 writes x2", 10'b00_10_00_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        MEM_rd = 5'd1;
        check("MEM forward rs1", "MEM writes x1", 10'b00_00_01_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        WB_rd = 5'd2;
        check("WB forward rs2", "WB writes x2", 10'b00_00_00_10_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        retire_rd = 5'd1;
        check("retire forward rs1", "retire writes x1", 10'b00_00_00_00_01, 5'b00000, 0, 7'b0000000, 7'b0000000);

        MEM_rd = 5'd1; WB_rd = 5'd1; retire_rd = 5'd1;
        check("priority MEM > WB > ret", "MEM, WB, retire all write x1", 10'b00_00_01_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        WB_rd = 5'd2; retire_rd = 5'd2;
        check("priority WB > retire", "WB, retire both write x2", 10'b00_00_00_10_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        MEM_rd = 5'd0; EXR_rs1 = 5'd0;
        check("x0 never forwarded", "MEM writes x0, EXR reads x0", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        MEM_rd = 5'd1; EXR_alu_src_A_select = 2'b10;
        check("rs1 not used", "src A = PC, MEM writes x1", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        MEM_rd = 5'd2; MEM_register_write_enable = 0;
        check("no write enable", "MEM x2 without write enable", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b0000000);

        // --------------------------------------------------------------------
        $display("[TB] 2. EXR data stall");
        // --------------------------------------------------------------------
        EX_rd = 5'd1; EX_forward_select = 3'd0;
        check("ALU in EX, rs1", "EX(add) writes x1", 10'b00_00_00_00_00, 5'b00000, 1, 7'b0001000, 7'b1110000);

        EX_rd = 5'd2; EX_is_load = 1; EX_forward_select = 3'd0;
        check("load in EX, rs2", "EX(ld) writes x2", 10'b00_00_00_00_00, 5'b00000, 1, 7'b0001000, 7'b1110000);

        EX2_rd = 5'd1; ex2_is_load = 1;
        check("load in BR, rs1", "EX2(ld) writes x1", 10'b00_00_00_00_00, 5'b00000, 1, 7'b0001000, 7'b1110000);

        EX_rd = 5'd1; retire_rd = 5'd2;
        check("stall + retire forward", "EX(add) x1, retire x2", 10'b00_00_00_00_10, 5'b00000, 1, 7'b0001000, 7'b1110000);

        EX_rd = 5'd2; retire_rd = 5'd1;
        check("stall + retire forward", "EX(add) x2, retire x1", 10'b00_00_00_00_01, 5'b00000, 1, 7'b0001000, 7'b1110000);

        EX_rd = 5'd1; div_busy = 1;
        check("stall under divide", "EX(add) x1 while div_busy", 10'b00_00_00_00_00, 5'b00000, 1, 7'b0000000, 7'b1111111);

        EX_rd = 5'd1; branch_prediction_miss = 1;
        check("stall vs misprediction", "EX(add) x1 + misprediction", 10'b00_00_00_00_00, 5'b00000, 1, 7'b1111100, 7'b0000000);

        // --------------------------------------------------------------------
        $display("[TB] 3. Store data forwarding");
        // --------------------------------------------------------------------
        EXR_opcode = OP_STORE; EX_rd = 5'd2; EX_forward_select = 3'd1;
        check("store from EX", "store rs2=x2, EX(lui) x2", 10'b00_00_00_00_00, 5'b10000, 0, 7'b0000000, 7'b0000000);

        EXR_opcode = OP_STORE; EX2_rd = 5'd2;
        check("store from BR", "store rs2=x2, EX2 x2", 10'b00_00_00_00_00, 5'b01000, 0, 7'b0000000, 7'b0000000);

        EXR_opcode = OP_STORE; MEM_rd = 5'd2;
        check("store from MEM", "store rs2=x2, MEM x2", 10'b00_00_00_00_00, 5'b00100, 0, 7'b0000000, 7'b0000000);

        EXR_opcode = OP_STORE; WB_rd = 5'd2;
        check("store from WB", "store rs2=x2, WB x2", 10'b00_00_00_00_00, 5'b00010, 0, 7'b0000000, 7'b0000000);

        EXR_opcode = OP_STORE; EX_rd = 5'd2; EX_forward_select = 3'd0;
        check("store, ALU in EX", "store rs2=x2, EX(add) x2", 10'b00_00_00_00_00, 5'b00000, 1, 7'b0001000, 7'b1110000);

        MEM_opcode = OP_STORE; MEM_rs2 = 5'd13;
        check("store WB -> MEM", "MEM store rs2=x13, WB x13", 10'b00_00_00_00_00, 5'b00001, 0, 7'b0000000, 7'b0000000);

        // --------------------------------------------------------------------
        $display("[TB] 4. Flush and stall control");
        // --------------------------------------------------------------------
        reset = 1;
        check("reset", "reset", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111111, 7'b0000000);

        pth_done_flush = 1;
        check("pth_done_flush", "trap FSM done", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111111, 7'b0000000);

        branch_prediction_miss = 1;
        check("misprediction", "branch_prediction_miss", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111100, 7'b0000000);

        branch_prediction_miss = 1; div_busy = 1;
        check("misprediction + div", "miss while div_busy", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111000, 7'b1111111);

        EX2_jump = 1;
        check("jump", "EX2_jump", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111100, 7'b0000000);

        EX2_jump = 1; write_done = 0;
        check("jump + store pending", "EX2_jump, write not done", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111000, 7'b1111111);

        mret_done = 1;
        check("mret_done", "mret_done", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1000000);

        standby_mode = 1;
        check("standby", "standby_mode", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1110000);

        trap_done = 0;
        check("trap FSM busy", "trap_done = 0", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1111111);

        trap_done = 0; branch_prediction_miss = 1;
        check("trap busy + miss", "trap_done = 0, misprediction", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1111111);

        csr_ready = 0;
        check("CSR not ready", "csr_ready = 0", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1111111);

        mul_start = 1;
        check("multiply", "mul_start", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1111111);

        write_done = 0;
        check("store pending", "write_done = 0", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0000000, 7'b1111111);

        EXR_csr_write_enable = 1; MEM_csr_write_enable = 1;
        check("CSR data hazard", "csrw in EXR and MEM", 10'b00_00_00_00_00, 5'b00000, 0, 7'b0001000, 7'b1110000);

        EXR_csr_write_enable = 1; WB_csr_write_enable = 1; EX2_jump = 1;
        check("CSR hazard vs jump", "csrw in EXR and WB + jump", 10'b00_00_00_00_00, 5'b00000, 0, 7'b1111100, 7'b0000000);

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
