`include "modules/headers/opcode.vh"
`include "modules/headers/store_funct3.vh"
`include "modules/headers/load_funct3.vh"
`include "modules/headers/trap.vh"

module ExceptionDetector (
    input clk,  
    input clk_enable,
    input reset,
    input timer_interrupt,
    input mstatus_mie,
    input mie_mtie,
    input [6:0] ID_opcode,
    input [6:0] EXR_opcode,
    input [6:0] EX_opcode,
    input [6:0] EX2_opcode,
    input [6:0] MEM_opcode,
    input [2:0] ID_funct3,
    input [2:0] EXR_funct3,
    input [2:0] EX_funct3,
    input [2:0] EX2_funct3,
    input [2:0] MEM_funct3,
    input [1:0] alu_result,
    input [1:0] EX2_alu_result,
    input [1:0] MEM_alu_result,
    input [11:0] raw_imm,
    input [11:0] EXR_raw_imm,
    input [11:0] EX_raw_imm,
    input [11:0] EX2_raw_imm,
    input EXR_jump,
    input EX_jump,
    input EX2_jump,
    input csr_write_enable,
    input [1:0] branch_target_lsbs,
    input branch_estimation,
    input branch_prediction_miss,
    
    output reg trapped,
    output reg [3:0] trap_status
);
    reg ID_trapped;
    reg [3:0] ID_trap_status;
    reg EXR_trapped;
    reg [3:0] EXR_trap_status;
    reg EX_trapped;
    reg [3:0] EX_trap_status;
    reg EX2_trapped;
    reg [3:0] EX2_trap_status;
    reg MEM_trapped;
    reg [3:0] MEM_trap_status;
    reg trapped_combinatorial;
    reg [3:0] trap_status_combinatorial;
    wire timer_irq_vld=timer_interrupt && mstatus_mie && mie_mtie && !trapped;
    always @(*) begin
        ID_trap_status = `TRAP_NONE;
        ID_trapped = 1'b0;

        case (ID_opcode)
            `OPCODE_FENCE: begin    // Zifencei
                if (ID_funct3 == 3'b001) begin
                    ID_trapped = 1'b1;
                    ID_trap_status = `TRAP_FENCEI;
                end
            end

            `OPCODE_ENVIRONMENT: begin // EBREAK, ECALL, MRET
                if (ID_funct3 == 3'b0) begin
                        ID_trapped = 1'b1;
                    if (raw_imm == 12'b0011_0000_0010) begin
                        ID_trap_status = `TRAP_MRET;
                    end
                    else if (raw_imm[0]) begin
                        ID_trap_status = `TRAP_EBREAK;
                    end
                end
                else begin
                    ID_trapped = 1'b0;
                    ID_trap_status = `TRAP_NONE;
                end
            end

            `OPCODE_BRANCH: begin // Misaligned
            if (branch_estimation == 1'b1) begin
                if (branch_target_lsbs == 2'b0) begin
                    ID_trapped = 1'b0;
                    ID_trap_status = `TRAP_NONE;
                end 
                else begin
                    ID_trapped = 1'b1;
                    ID_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end
            end

            default: begin
                ID_trapped = 1'b0;
                ID_trap_status = `TRAP_NONE;
            end

        endcase

        EXR_trapped = 1'b0;
        EXR_trap_status = `TRAP_NONE;

        case (EXR_opcode)
            `OPCODE_ENVIRONMENT: begin // EBREAK, ECALL, MRET
                if (EXR_funct3 == 3'b0) begin
                        EXR_trapped = 1'b1;
                    if (EXR_raw_imm == 12'b0011_0000_0010) begin
                        EXR_trap_status = `TRAP_MRET;
                    end
                    else if (EXR_raw_imm[0]) begin
                        EXR_trap_status = `TRAP_EBREAK;
                    end
                end
                else begin
                    EXR_trapped = 1'b0;
                    EXR_trap_status = `TRAP_NONE;
                end
            end
            default: begin
                EXR_trapped = 1'b0;
                EXR_trap_status = `TRAP_NONE;
            end
        endcase

        EX_trapped = 1'b0;
        EX_trap_status = `TRAP_NONE;

        case (EX_opcode)
            `OPCODE_ENVIRONMENT: begin // EBREAK, ECALL, MRET
                if (EX_funct3 == 3'b0) begin
                        EX_trapped = 1'b1;
                    if (EX_raw_imm == 12'b0011_0000_0010) begin
                        EX_trap_status = `TRAP_MRET;
                    end
                    else if (EX_raw_imm[0]) begin
                        EX_trap_status = `TRAP_EBREAK;
                    end
                end
                else begin
                    EX_trapped = 1'b0;
                    EX_trap_status = `TRAP_NONE;
                end
            end
            `OPCODE_LOAD: begin
                case (EX_funct3)
                    `LOAD_LH, `LOAD_LHU: begin
                        if (alu_result[0] == 1'b1) begin
                            EX_trapped = 1'b1;
                            EX_trap_status = `TRAP_MISALIGNED_LOAD;
                        end 
                        else begin
                            EX_trapped = 1'b0;
                            EX_trap_status = `TRAP_NONE;
                        end
                    end
                    `LOAD_LW: begin
                        if (alu_result[1:0] != 2'b00) begin
                            EX_trapped = 1'b1;
                            EX_trap_status = `TRAP_MISALIGNED_LOAD;
                        end 
                        else begin
                            EX_trapped = 1'b0;
                            EX_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        EX_trapped = 1'b0;
                        EX_trap_status = `TRAP_NONE;
                    end
                endcase
            end
            `OPCODE_JAL, `OPCODE_JALR: begin
                if (alu_result == 2'b0) begin
                    EX_trapped = 1'b0;
                    EX_trap_status = `TRAP_NONE;
                end 
                else begin
                    EX_trapped = 1'b1;
                    EX_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end   
            default: begin
                EX_trapped = 1'b0;
                EX_trap_status = `TRAP_NONE;
            end
        endcase

        EX2_trapped = 1'b0;
        EX2_trap_status = `TRAP_NONE;

        case (EX2_opcode)
        `OPCODE_ENVIRONMENT: begin // EBREAK, ECALL, MRET
                if (EX2_funct3 == 3'b0) begin
                        EX2_trapped = 1'b1;
                    if (EX2_raw_imm == 12'b0011_0000_0010) begin
                        EX2_trap_status = `TRAP_MRET;
                    end
                    else if (EX2_raw_imm[0]) begin
                        EX2_trap_status = `TRAP_EBREAK;
                    end
                    else if (EX2_raw_imm == 12'b0) begin
                        EX2_trap_status = `TRAP_ECALL;
                    end
                end
                else begin
                    EX2_trapped = 1'b0;
                    EX2_trap_status = `TRAP_NONE;
                end
            end
            `OPCODE_STORE: begin
                case (EX2_funct3)
                    `STORE_SH: begin
                        if (EX2_alu_result[0] == 1'b1) begin
                            EX2_trapped = 1'b1;
                            EX2_trap_status = `TRAP_MISALIGNED_STORE;
                        end 
                        else begin
                            EX2_trapped = 1'b0;
                            EX2_trap_status = `TRAP_NONE;
                        end
                    end
                    `STORE_SW: begin
                        if (EX2_alu_result[1:0] != 2'b00) begin
                            EX2_trapped = 1'b1;
                            EX2_trap_status = `TRAP_MISALIGNED_STORE;
                        end 
                        else begin
                            EX2_trapped = 1'b0;
                            EX2_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        EX2_trapped = 1'b0;
                        EX2_trap_status = `TRAP_NONE;
                    end 
                endcase
            end

            `OPCODE_LOAD: begin
                case (EX2_funct3)
                    `LOAD_LH, `LOAD_LHU: begin
                        if (EX2_alu_result[0] == 1'b1) begin
                            EX2_trapped = 1'b1;
                            EX2_trap_status = `TRAP_MISALIGNED_LOAD;
                        end 
                        else begin
                            EX2_trapped = 1'b0;
                            EX2_trap_status = `TRAP_NONE;
                        end
                    end
                    `LOAD_LW: begin
                        if (EX2_alu_result[1:0] != 2'b00) begin
                            EX2_trapped = 1'b1;
                            EX2_trap_status = `TRAP_MISALIGNED_LOAD;
                        end 
                        else begin
                            EX2_trapped = 1'b0;
                            EX2_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        EX2_trapped = 1'b0;
                        EX2_trap_status = `TRAP_NONE;
                    end
                endcase
            end
            `OPCODE_JAL, `OPCODE_JALR: begin
                if (EX2_alu_result == 2'b0) begin
                    EX2_trapped = 1'b0;
                    EX2_trap_status = `TRAP_NONE;
                end 
                else begin
                    EX2_trapped = 1'b1;
                    EX2_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end    
            default: begin
                EX2_trapped = 1'b0;
                EX2_trap_status = `TRAP_NONE;
            end
        endcase

        MEM_trapped = 1'b0;
        MEM_trap_status = `TRAP_NONE;

        case (MEM_opcode)
            `OPCODE_STORE: begin
                case (MEM_funct3)
                    `STORE_SH: begin
                        if (MEM_alu_result[0] == 1'b1) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_STORE;
                        end 
                        else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    `STORE_SW: begin
                        if (MEM_alu_result[1:0] != 2'b00) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_STORE;
                        end 
                        else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        MEM_trapped = 1'b0;
                        MEM_trap_status = `TRAP_NONE;
                    end 
                endcase
            end

            `OPCODE_LOAD: begin
                case (MEM_funct3)
                    `LOAD_LH, `LOAD_LHU: begin
                        if (MEM_alu_result[0] == 1'b1) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_LOAD;
                        end 
                        else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    `LOAD_LW: begin
                        if (MEM_alu_result[1:0] != 2'b00) begin
                            MEM_trapped = 1'b1;
                            MEM_trap_status = `TRAP_MISALIGNED_LOAD;
                        end 
                        else begin
                            MEM_trapped = 1'b0;
                            MEM_trap_status = `TRAP_NONE;
                        end
                    end
                    default: begin
                        MEM_trapped = 1'b0;
                        MEM_trap_status = `TRAP_NONE;
                    end
                endcase
            end
            `OPCODE_JAL, `OPCODE_JALR: begin
                if (MEM_alu_result == 2'b0) begin
                    MEM_trapped = 1'b0;
                    MEM_trap_status = `TRAP_NONE;
                end 
                else begin
                    MEM_trapped = 1'b1;
                    MEM_trap_status = `TRAP_MISALIGNED_INSTRUCTION;
                end
            end    
            default: begin
                MEM_trapped = 1'b0;
                MEM_trap_status = `TRAP_NONE;
            end
        endcase
        if (MEM_trapped) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = MEM_trap_status;
        end 
        else if (EX2_trapped) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = EX2_trap_status;
        end 
        else if (EX_trapped && !branch_prediction_miss && !EX2_jump) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = EX_trap_status;
        end 
        else if (EXR_trapped && !branch_prediction_miss && !EX2_jump && !EX_jump) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = EXR_trap_status;
        end 
        else if (ID_trapped && !branch_prediction_miss && !EX2_jump && !EX_jump) begin
            trapped_combinatorial = 1'b1;
            trap_status_combinatorial = ID_trap_status;
        end 
        else if (timer_irq_vld) begin
            trapped_combinatorial=1'b1;
            trap_status_combinatorial=  `TIMER_INTERRUPT_IRQ; // 4'h8
        end
        else begin
            trapped_combinatorial = 1'b0;
            trap_status_combinatorial = `TRAP_NONE;
        end
    end
    
    // Synchronous trap signal output
    always @(posedge clk  or posedge reset) begin
        if (reset) begin
            trapped <= 1'b0;
            trap_status <= `TRAP_NONE;
        end 
        else if (clk_enable) begin
            trapped <= trapped_combinatorial;
            trap_status <= trap_status_combinatorial;
        end
    end
endmodule