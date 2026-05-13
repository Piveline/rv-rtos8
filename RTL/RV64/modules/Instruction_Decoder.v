`include "./modules/headers/opcode.vh"

module InstructionDecoder (
	input [31:0] instruction,
    
    output [6:0] opcode,
	output [2:0] funct3,
	output [6:0] funct7,
	output [4:0] rs1,
	output [5:0] rs2,			// RV64I 6-bit shamt
	output [4:0] rd,
	output reg [19:0] raw_imm
);
    assign opcode = instruction[6:0];
	assign funct3 = instruction[14:12];
	assign rs1 = instruction[19:15];
	assign rd = instruction[11:7];
	
	wire i_shift = (opcode == `OPCODE_ITYPE) && (funct3 == `ITYPE_SLLI || funct3 == `ITYPE_SRXI);

	assign rs2 = i_shift ? {1'b0, instruction[25:20]} : {1'b0, instruction[24:20]}; // 6-bit shamt for RV64I shifts
	assign funct7 = i_shift ? {1'b0, instruction[31:26]} : {instruction[31:25]};

    always @(*) begin
        case (opcode)
			`OPCODE_LUI, `OPCODE_AUIPC: begin // U-type
				raw_imm = instruction[31:12];
            end
			
			`OPCODE_JAL: begin // J-type
				raw_imm = {instruction[31], instruction[19:12], instruction[20], instruction[30:21]};
			end
			
			`OPCODE_JALR, `OPCODE_LOAD, `OPCODE_FENCE, `OPCODE_ENVIRONMENT: begin // I-type
				raw_imm = {8'b0, instruction[31:20]};
			end

			`OPCODE_ITYPE: begin
				if ((funct3 == `ITYPE_SLLI) || (funct3 == `ITYPE_SRXI)) begin
					raw_imm = {9'b0, instruction[30], 4'b0, instruction[25:20]}; // 6-bit shamt for RV64I shifts
				end 
				else begin
					raw_imm = {8'b0, instruction[31:20]};
				end
			end

			`OPCODE_ITYPE_WORD: begin
				if ((funct3 == `ITYPE_SLLI) || (funct3 == `ITYPE_SRXI)) begin
					raw_imm = {9'b0, instruction[30], 5'b0, instruction[24:20]}; // 5-bit shamt for RV32I shifts
				end 
				else begin
					raw_imm = {8'b0, instruction[31:20]};
				end
			end
			
			`OPCODE_BRANCH: begin // B-type
				raw_imm = {instruction[31], instruction[7], instruction[30:25], instruction[11:8]};
			end
			
			`OPCODE_STORE: begin // S-type
				raw_imm = {8'b0, instruction[31:25], instruction[11:7]};
			end
			
			`OPCODE_RTYPE, `OPCODE_RTYPE_WORD, `OPCODE_ATOMIC: begin // R type
				raw_imm = 20'b0;
			end

			default: begin
				raw_imm = 20'b0;
            end
		endcase
    end

endmodule