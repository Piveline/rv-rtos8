`include "./branch_funct3.vh"

module BranchLogic #(
    parameter XLEN = 32
)(
    input branch,
    input branch_estimation,
    input [2:0] funct3,
    input [XLEN-1:0] pc,
    input [XLEN-1:0] imm,

    // ALU results for branch comparison (from EX2 stage)
    // alu_zero: 1 if rs1 == rs2 (ALU computed SUB, result is 0)
    // alu_result[0]: 1 if rs1 < rs2 (ALU computed SLT or SLTU)
    input alu_zero,
    input [XLEN-1:0] alu_result,

    output reg branch_taken,
    output reg [XLEN-1:0] branch_target_actual,
    output reg branch_prediction_miss
);

    // Branch decision based on ALU results
    // BEQ/BNE: ALU computes SUB, alu_zero indicates equality
    // BLT/BGE: ALU computes SLT, alu_result[0] indicates rs1 < rs2 (signed)
    // BLTU/BGEU: ALU computes SLTU, alu_result[0] indicates rs1 < rs2 (unsigned)

    always @(*) begin
        if (branch) begin
            case (funct3)
                `BRANCH_BEQ:  branch_taken = alu_zero;              // rs1 == rs2
                `BRANCH_BNE:  branch_taken = ~alu_zero;             // rs1 != rs2
                `BRANCH_BLT:  branch_taken = alu_result[0];         // rs1 < rs2 (signed)
                `BRANCH_BGE:  branch_taken = ~alu_result[0];        // rs1 >= rs2 (signed)
                `BRANCH_BLTU: branch_taken = alu_result[0];         // rs1 < rs2 (unsigned)
                `BRANCH_BGEU: branch_taken = ~alu_result[0];        // rs1 >= rs2 (unsigned)
                default:      branch_taken = 1'b0;
            endcase

            branch_prediction_miss = (branch_estimation != branch_taken);

            if (branch_taken) begin
                branch_target_actual = pc + imm;
            end
            else begin
                branch_target_actual = pc + 4;
            end
        end
        else begin
            branch_taken = 1'b0;
            branch_target_actual = {XLEN{1'b0}};
            branch_prediction_miss = 1'b0;
        end
    end

endmodule
