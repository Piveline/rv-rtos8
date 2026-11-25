module EXR_EX_Register #(
    parameter XLEN = 32
) (
    input wire clk,
    input wire clk_enable,
    input wire flush,
    input wire EXR_EX_stall,

    input wire [XLEN-1:0] EXR_src_A,           // forwarded + src_select 적용 완료
    input wire [XLEN-1:0] EXR_src_B,           // forwarded + src_select 적용 완료

    input wire [XLEN-1:0] EXR_pc,
    input wire [XLEN-1:0] EXR_pc_plus_4,
    input wire EXR_branch_estimation,
    input wire [31:0] EXR_instruction,
    input wire EXR_jump,
    input wire EXR_memory_read,
    input wire EXR_memory_write,
    input wire [2:0] EXR_register_file_write_data_select,
    input wire EXR_register_write_enable,
    input wire EXR_csr_write_enable,
    input wire EXR_branch,
    input wire [6:0] EXR_opcode,
    input wire [2:0] EXR_funct3,
    input wire [6:0] EXR_funct7,
    input wire [4:0] EXR_rd,
    input wire [19:0] EXR_raw_imm,
    input wire [XLEN-1:0] EXR_read_data2,      // store data (forwarded)
    input wire [4:0] EXR_rs1,
    input wire [4:0] EXR_rs2,
    input wire [XLEN-1:0] EXR_imm,
    input wire [XLEN-1:0] EXR_csr_read_data,
    input wire EXR_is_load,
    input wire [2:0] EXR_forward_select,

    output reg [XLEN-1:0] EX_src_A,
    output reg [XLEN-1:0] EX_src_B,

    output reg [XLEN-1:0] EX_pc,
    output reg [XLEN-1:0] EX_pc_plus_4,
    output reg EX_branch_estimation,
    output reg [31:0] EX_instruction,
    output reg EX_jump,
    output reg EX_memory_read,
    output reg EX_memory_write,
    output reg [2:0] EX_register_file_write_data_select,
    output reg EX_register_write_enable,
    output reg EX_csr_write_enable,
    output reg EX_branch,
    output reg [6:0] EX_opcode,
    output reg [2:0] EX_funct3,
    output reg [6:0] EX_funct7,
    output reg [4:0] EX_rd,
    output reg [19:0] EX_raw_imm,
    output reg [XLEN-1:0] EX_read_data2,
    output reg [4:0] EX_rs1,
    output reg [4:0] EX_rs2,
    output reg [XLEN-1:0] EX_imm,
    output reg [XLEN-1:0] EX_csr_read_data,
    output reg EX_is_load,
    output reg [2:0] EX_forward_select
);

always @(posedge clk) begin
    if (clk_enable) begin
        if (flush) begin
            EX_src_A <= {XLEN{1'b0}};
            EX_src_B <= {XLEN{1'b0}};
            EX_pc <= {XLEN{1'b0}};
            EX_pc_plus_4 <= {XLEN{1'b0}};
            EX_branch_estimation <= 1'b0;
            EX_instruction <= 32'h0000_0013;
            EX_jump <= 1'b0;
            EX_memory_read <= 1'b0;
            EX_memory_write <= 1'b0;
            EX_register_file_write_data_select <= 3'b0;
            EX_register_write_enable <= 1'b0;
            EX_csr_write_enable <= 1'b0;
            EX_branch <= 1'b0;
            EX_opcode <= 7'b0;
            EX_funct3 <= 3'b0;
            EX_funct7 <= 7'b0;
            EX_rd <= 5'b0;
            EX_raw_imm <= 20'b0;
            EX_read_data2 <= {XLEN{1'b0}};
            EX_rs1 <= 5'b0;
            EX_rs2 <= 5'b0;
            EX_imm <= {XLEN{1'b0}};
            EX_csr_read_data <= {XLEN{1'b0}};
            EX_is_load <= 1'b0;
            EX_forward_select <= 3'b0;
        end
        else if (!EXR_EX_stall) begin
            EX_src_A <= EXR_src_A;
            EX_src_B <= EXR_src_B;
            EX_pc <= EXR_pc;
            EX_pc_plus_4 <= EXR_pc_plus_4;
            EX_branch_estimation <= EXR_branch_estimation;
            EX_instruction <= EXR_instruction;
            EX_jump <= EXR_jump;
            EX_memory_read <= EXR_memory_read;
            EX_memory_write <= EXR_memory_write;
            EX_register_file_write_data_select <= EXR_register_file_write_data_select;
            EX_register_write_enable <= EXR_register_write_enable;
            EX_csr_write_enable <= EXR_csr_write_enable;
            EX_branch <= EXR_branch;
            EX_opcode <= EXR_opcode;
            EX_funct3 <= EXR_funct3;
            EX_funct7 <= EXR_funct7;
            EX_rd <= EXR_rd;
            EX_raw_imm <= EXR_raw_imm;
            EX_read_data2 <= EXR_read_data2;
            EX_rs1 <= EXR_rs1;
            EX_rs2 <= EXR_rs2;
            EX_imm <= EXR_imm;
            EX_csr_read_data <= EXR_csr_read_data;
            EX_is_load <= EXR_is_load;
            EX_forward_select <= EXR_forward_select;
        end
    end
end

endmodule