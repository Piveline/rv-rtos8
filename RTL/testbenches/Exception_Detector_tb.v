`timescale 1ns/1ps
`include "modules/headers/opcode.vh"

module ExceptionDetector_tb;
    // ==========================================
    // 1. 신호 선언부 (Signal Declarations)
    // ==========================================
    reg clk;
    reg clk_enable;
    reg reset;
    
    // Interrupt signals
    reg timer_interrupt;
    reg mstatus_mie;
    reg mie_mtie;

    // ID Stage
    reg [6:0] ID_opcode;
    reg [2:0] ID_funct3;
    reg [11:0] raw_imm;
    reg [1:0] branch_target_lsbs;
    reg branch_estimation;

    // EXR Stage
    reg [6:0] EXR_opcode;
    reg [2:0] EXR_funct3;
    reg [11:0] EXR_raw_imm;
    reg EXR_jump;

    // EX Stage
    reg [6:0] EX_opcode;
    reg [2:0] EX_funct3;
    reg [11:0] EX_raw_imm;
    reg [1:0] alu_result;
    reg EX_jump;

    // EX2 Stage
    reg [6:0] EX2_opcode;
    reg [2:0] EX2_funct3;
    reg [11:0] EX2_raw_imm;
    reg [1:0] EX2_alu_result;
    reg EX2_jump;

    // MEM Stage
    reg [6:0] MEM_opcode;
    reg [2:0] MEM_funct3;
    reg [1:0] MEM_alu_result;

    // Branch/CSR control
    reg branch_prediction_miss;
    reg csr_write_enable;

    // Outputs
    wire trapped;
    wire [3:0] trap_status; // 4-bit로 수정됨

    // ==========================================
    // 2. DUT (Device Under Test) 인스턴스화
    // ==========================================
    ExceptionDetector exception_detector (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        
        .timer_interrupt(timer_interrupt),
        .mstatus_mie(mstatus_mie),
        .mie_mtie(mie_mtie),
        
        .ID_opcode(ID_opcode), .EXR_opcode(EXR_opcode), .EX_opcode(EX_opcode),
        .EX2_opcode(EX2_opcode), .MEM_opcode(MEM_opcode),
        
        .ID_funct3(ID_funct3), .EXR_funct3(EXR_funct3), .EX_funct3(EX_funct3),
        .EX2_funct3(EX2_funct3), .MEM_funct3(MEM_funct3),
        
        .alu_result(alu_result), .EX2_alu_result(EX2_alu_result), .MEM_alu_result(MEM_alu_result),
        
        .raw_imm(raw_imm), .EXR_raw_imm(EXR_raw_imm), .EX_raw_imm(EX_raw_imm), .EX2_raw_imm(EX2_raw_imm),
        
        .EXR_jump(EXR_jump), .EX_jump(EX_jump), .EX2_jump(EX2_jump),
        
        .csr_write_enable(csr_write_enable),
        .branch_target_lsbs(branch_target_lsbs),
        .branch_estimation(branch_estimation),
        .branch_prediction_miss(branch_prediction_miss),
        
        .trapped(trapped),
        .trap_status(trap_status)
    );

    // ==========================================
    // 3. Clock Generation (10ns period)
    // ==========================================
    always #5 clk = ~clk;

    // 편의를 위한 파이프라인 초기화 Task
    task clear_pipeline;
    begin
        ID_opcode = 0; EXR_opcode = 0; EX_opcode = 0; EX2_opcode = 0; MEM_opcode = 0;
        ID_funct3 = 0; EXR_funct3 = 0; EX_funct3 = 0; EX2_funct3 = 0; MEM_funct3 = 0;
        raw_imm = 0; EXR_raw_imm = 0; EX_raw_imm = 0; EX2_raw_imm = 0;
        alu_result = 0; EX2_alu_result = 0; MEM_alu_result = 0;
        EXR_jump = 0; EX_jump = 0; EX2_jump = 0;
        branch_target_lsbs = 0; branch_estimation = 0; branch_prediction_miss = 0;
        csr_write_enable = 0; timer_interrupt = 0; mstatus_mie = 0; mie_mtie = 0;
    end
    endtask

    // ==========================================
    // 4. Test Sequence
    // ==========================================
    initial begin
        $display("==================== Exception Detector Test START ====================");
        
        // 초기화 및 리셋
        clk = 0;
        clk_enable = 1;
        reset = 1;
        clear_pipeline();

        #15 reset = 0; // 리셋 해제

        // --------------------------------------------------
        // Test 1: No exception
        // --------------------------------------------------
        $display("\n[Test 1] No exception (R-Type): ");
        @(negedge clk);
        ID_opcode = `OPCODE_RTYPE;
        
        @(posedge clk); #1;
        $display("opcode: %b, trapped: %b, trap_status: %b", ID_opcode, trapped, trap_status);
        clear_pipeline();

        // --------------------------------------------------
        // Test 2: EBREAK/ECALL/MRET (ID Stage)
        // --------------------------------------------------
        $display("\n[Test 2] EBREAK/ECALL/MRET (ID Stage): ");
        
        @(negedge clk);
        ID_opcode = `OPCODE_ENVIRONMENT;
        ID_funct3 = 3'b000;
        raw_imm = 12'b000000000001; // EBREAK
        @(posedge clk); #1;
        $display("EBREAK -> funct12[0]: %b, trapped: %b, trap_status: %b", raw_imm[0], trapped, trap_status);
        
        @(negedge clk);
        raw_imm = 12'b000000000000; // ECALL
        @(posedge clk); #1;
        $display("ECALL  -> funct12: %b, trapped: %b, trap_status: %b", raw_imm, trapped, trap_status);
        
        @(negedge clk);
        raw_imm = 12'b001100000010; // MRET
        @(posedge clk); #1;
        $display("MRET   -> funct12: %b, trapped: %b, trap_status: %b", raw_imm, trapped, trap_status);
        clear_pipeline();

        // --------------------------------------------------
        // Test 3: Address Misaligned (Branch - ID Stage)
        // --------------------------------------------------
        $display("\n[Test 3] Address Misaligned - Branch: ");
        
        @(negedge clk);
        ID_opcode = `OPCODE_BRANCH;
        branch_estimation = 1'b1;
        branch_target_lsbs = 2'b00; // Aligned
        @(posedge clk); #1;
        $display("Aligned Branch   -> target_lsbs: %b, trapped: %b, trap_status: %b", branch_target_lsbs, trapped, trap_status);

        @(negedge clk);
        branch_target_lsbs = 2'b01; // Misaligned
        @(posedge clk); #1;
        $display("Misaligned Branch-> target_lsbs: %b, trapped: %b, trap_status: %b", branch_target_lsbs, trapped, trap_status);
        clear_pipeline();

        // --------------------------------------------------
        // Test 4: Address Misaligned (JAL / JALR - EX Stage)
        // --------------------------------------------------
        $display("\n[Test 4] Address Misaligned - Jump: ");
        
        @(negedge clk);
        EX_opcode = `OPCODE_JAL;
        alu_result = 2'b00; // Aligned
        @(posedge clk); #1;
        $display("Aligned JAL      -> alu_result: %b, trapped: %b, trap_status: %b", alu_result, trapped, trap_status);

        @(negedge clk);
        alu_result = 2'b10; // Misaligned
        @(posedge clk); #1;
        $display("Misaligned JAL   -> alu_result: %b, trapped: %b, trap_status: %b", alu_result, trapped, trap_status);
        clear_pipeline();

        // --------------------------------------------------
        // Test 5: Data Misaligned (Load - EX Stage) [새로운 시나리오]
        // --------------------------------------------------
        $display("\n[Test 5] Data Misaligned - Load (Word): ");
        
        @(negedge clk);
        EX_opcode = `OPCODE_LOAD;
        EX_funct3 = 3'b010; // LOAD_LW (일반적으로 010)
        alu_result = 2'b00; // Aligned
        @(posedge clk); #1;
        $display("Aligned LW       -> alu_result: %b, trapped: %b, trap_status: %b", alu_result, trapped, trap_status);

        @(negedge clk);
        alu_result = 2'b01; // Misaligned (Word는 하위 2비트가 00이어야 함)
        @(posedge clk); #1;
        $display("Misaligned LW    -> alu_result: %b, trapped: %b, trap_status: %b", alu_result, trapped, trap_status);
        clear_pipeline();

        // --------------------------------------------------
        // Test 6: Data Misaligned (Store - EX2 Stage) [새로운 시나리오]
        // --------------------------------------------------
        $display("\n[Test 6] Data Misaligned - Store (Word): ");
        
        @(negedge clk);
        EX2_opcode = `OPCODE_STORE;
        EX2_funct3 = 3'b010; // STORE_SW
        EX2_alu_result = 2'b00; // Aligned
        @(posedge clk); #1;
        $display("Aligned SW       -> EX2_alu_result: %b, trapped: %b, trap_status: %b", EX2_alu_result, trapped, trap_status);

        @(negedge clk);
        EX2_alu_result = 2'b11; // Misaligned
        @(posedge clk); #1;
        $display("Misaligned SW    -> EX2_alu_result: %b, trapped: %b, trap_status: %b", EX2_alu_result, trapped, trap_status);
        clear_pipeline();

        // --------------------------------------------------
        // Test 7: Timer Interrupt [새로운 시나리오]
        // --------------------------------------------------
        $display("\n[Test 7] Timer Interrupt: ");
        
        @(negedge clk);
        // 정상적인 명령어 진행 중에 인터럽트가 발생한 상황 가정
        ID_opcode = `OPCODE_RTYPE; 
        timer_interrupt = 1'b1;
        mstatus_mie = 1'b1;
        mie_mtie = 1'b1;
        
        @(posedge clk); #1;
        $display("Timer Interrupt Active -> trapped: %b, trap_status: %h", trapped, trap_status);
        
        $display("\n====================  Exception Detector Test END  ====================");
        $stop;
    end

endmodule