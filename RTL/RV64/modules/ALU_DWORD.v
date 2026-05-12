`include "./alu_op.vh"

module ALU_DWORD #(
    parameter XLEN = 64
)(
    input [XLEN-1:0] src_A,             // source operand A
    input [XLEN-1:0] src_B,             // source operand B
    input [4:0] alu_op,        		// ALU operation signal (from ALU Control module)

    output reg [XLEN-1:0] alu_result   // ALU result
);
    always @(*) begin
        case (alu_op)
            `ALU_OP_ADD: begin
                alu_result = src_A + src_B;
            end

            `ALU_OP_SUB: begin
                alu_result = src_A - src_B;
            end
            
            `ALU_OP_AND: begin
                alu_result = src_A & src_B;
            end
            
            `ALU_OP_OR: begin
                alu_result = src_A | src_B;
            end
            
            `ALU_OP_XOR: begin
                alu_result = src_A ^ src_B;
            end
            
            `ALU_OP_SLT: begin
                alu_result = ($signed(src_A) < $signed(src_B)) ? 64'd1 : 64'd0;
            end

            `ALU_OP_SLTU: begin
                alu_result = (src_A < src_B) ? 64'd1 : 64'd0;
            end
			
			`ALU_OP_SLL: begin
				alu_result = src_A << src_B[5:0];
			end
			
			`ALU_OP_SRL: begin
				alu_result = src_A >> src_B[5:0];
			end
			
			`ALU_OP_SRA: begin
				alu_result = $signed(src_A) >>> src_B[5:0];
			end

            `ALU_OP_ABJ: begin
				alu_result = src_B & (~src_A);
			end

			`ALU_OP_NOP: begin
				alu_result = 64'd0;
			end

            default: begin
                alu_result = 64'd0; // Default case: zero result
            end
        endcase
    end

endmodule