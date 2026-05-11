module EX_EX2_Register #(
    parameter XLEN = 32
)(
    // pipeline register control signals
    input wire clk,
    input wire clk_enable,
    input wire flush,
    input wire EX_EX2_stall,

    // signals from EX stage
    input wire [XLEN-1:0] EX_pc,
    input wire [XLEN-1:0] EX_pc_plus_4,
    input wire [31:0] EX_instruction,
    input wire [2:0] EX_register_file_write_data_select,
    input wire EX_register_write_enable,
    input wire EX_memory_read,
    input wire EX_memory_write,
    input wire EX_csr_write_enable,
    input wire [6:0] EX_opcode,
    input wire [2:0] EX_funct3,
    input wire [4:0] EX_rs1,
    input wire [4:0] EX_rs2,
    input wire [4:0] EX_rd,
    input wire [XLEN-1:0] EX_read_data1,
    input wire [XLEN-1:0] EX_read_data2,
    input wire [XLEN-1:0] EX_imm,
    input wire [19:0] EX_raw_imm,
    input wire [XLEN-1:0] EX_csr_read_data,
    input wire [XLEN-1:0] EX_alu_result,
    input wire EX_branch,
    input wire EX_branch_estimation,
    input wire EX_alu_zero,
    input wire EX_jump,
    input wire EX_is_load,
    input wire [31:0] EX_alu_word_result,
    input wire EX_input_size_word,
    input wire [2:0] EX_forward_select,

    // signals to EX2 stage (Branch Logic)
    output reg [XLEN-1:0] EX2_pc,
    output reg [XLEN-1:0] EX2_pc_plus_4,
    output reg [31:0] EX2_instruction,
    output reg EX2_memory_read,
    output reg EX2_memory_write,
    output reg [2:0] EX2_register_file_write_data_select,
    output reg EX2_register_write_enable,
    output reg EX2_csr_write_enable,
    output reg [6:0] EX2_opcode,
    output reg [2:0] EX2_funct3,
    output reg [4:0] EX2_rs1,
    output reg [4:0] EX2_rs2,
    output reg [4:0] EX2_rd,
    output reg [XLEN-1:0] EX2_read_data1,
    output reg [XLEN-1:0] EX2_read_data2,
    output reg [XLEN-1:0] EX2_imm,
    output reg [19:0] EX2_raw_imm,
    output reg [XLEN-1:0] EX2_csr_read_data,
    output reg [XLEN-1:0] EX2_alu_result,
    output reg EX2_branch,
    output reg EX2_branch_estimation,
    output reg EX2_alu_zero,
    output reg EX2_jump,
    output reg EX2_is_load,
    output reg [31:0] EX2_alu_word_result,
    output reg EX2_input_size_word,
    output reg [2:0] EX2_forward_select
);

always @(posedge clk) begin
    if (clk_enable) begin
        if (flush) begin
            EX2_pc <= {XLEN{1'b0}};
            EX2_pc_plus_4 <= {XLEN{1'b0}};
            EX2_instruction <= 32'h0000_0013; // ADDI x0, x0, 0 = RISC-V NOP, HINT
            EX2_register_file_write_data_select <= 3'b0;
            EX2_register_write_enable <= 1'b0;
            EX2_memory_read <= 1'b0;
            EX2_memory_write <= 1'b0;
            EX2_csr_write_enable <= 1'b0;
            EX2_opcode <= 7'h0;
            EX2_funct3 <= 3'b0;
            EX2_rs1 <= 5'h0;
            EX2_rs2 <= 5'h0;
            EX2_rd <= 5'h0;
            EX2_read_data1 <= {XLEN{1'b0}};
            EX2_read_data2 <= {XLEN{1'b0}};
            EX2_imm <= {XLEN{1'b0}};
            EX2_raw_imm <= 20'b0;
            EX2_csr_read_data <= {XLEN{1'b0}};
            EX2_alu_result <= {XLEN{1'b0}};
            EX2_branch <= 1'b0;
            EX2_branch_estimation <= 1'b0;
            EX2_alu_zero <= 1'b0;
            EX2_jump <= 1'b0;
            EX2_is_load <= 1'b0;
            EX2_alu_word_result <= 32'b0;
            EX2_input_size_word <= 1'b0;
            EX2_forward_select <= 3'b0;
        end 
        else if (!EX_EX2_stall) begin
            EX2_pc <= EX_pc;
            EX2_pc_plus_4 <= EX_pc_plus_4;
            EX2_instruction <= EX_instruction;
            EX2_register_file_write_data_select <= EX_register_file_write_data_select;
            EX2_register_write_enable <= EX_register_write_enable;
            EX2_memory_read <= EX_memory_read;
            EX2_memory_write <= EX_memory_write;
            EX2_csr_write_enable <= EX_csr_write_enable;
            EX2_opcode <= EX_opcode;
            EX2_funct3 <= EX_funct3;
            EX2_rs1 <= EX_rs1;
            EX2_rs2 <= EX_rs2;
            EX2_rd <= EX_rd;
            EX2_read_data1 <= EX_read_data1;
            EX2_read_data2 <= EX_read_data2;
            EX2_imm <= EX_imm;
            EX2_raw_imm <= EX_raw_imm;
            EX2_csr_read_data <= EX_csr_read_data;
            EX2_alu_result <= EX_alu_result;
            EX2_branch <= EX_branch;
            EX2_branch_estimation <= EX_branch_estimation;
            EX2_alu_zero <= EX_alu_zero;
            EX2_jump <= EX_jump;
            EX2_is_load <= EX_is_load;
            EX2_alu_word_result <= EX_alu_word_result;
            EX2_input_size_word <= EX_input_size_word;
            EX2_forward_select <= EX_forward_select;
        end 
    end
end

endmodule