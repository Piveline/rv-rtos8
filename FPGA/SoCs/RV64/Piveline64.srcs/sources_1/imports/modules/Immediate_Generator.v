`include "./opcode.vh"

module ImmediateGenerator #(
	parameter XLEN = 64
)(
    input [19:0] raw_imm, 	// raw immediate value from Instruction Decoder
	input [6:0] opcode,		// opcode from Instruction Decoder
    output reg [XLEN-1:0] imm	// sign-extension of the raw immediate value
);
	
	always @(*) begin
		case (opcode)
			`OPCODE_JALR, `OPCODE_LOAD, `OPCODE_ITYPE, `OPCODE_ITYPE_WORD, `OPCODE_FENCE, `OPCODE_ENVIRONMENT: begin // I-type
				imm = {{52{raw_imm[11]}}, raw_imm[11:0]};
			end
			`OPCODE_STORE: begin // S-Type
				imm = {{52{raw_imm[11]}}, raw_imm[11:0]};
			end
			`OPCODE_LUI, `OPCODE_AUIPC: begin // U-Type
				imm = {{32{raw_imm[19]}}, raw_imm, 12'b0};
			end
			`OPCODE_BRANCH: begin // B-Type
				imm = {{51{raw_imm[11]}}, raw_imm[11:0], 1'b0};
			end
			`OPCODE_JAL: begin // J-Type
				imm = {{43{raw_imm[19]}}, raw_imm[19:0], 1'b0};
			end
			default: begin
				imm = {XLEN{1'b0}};
			end
        endcase
	end
	
endmodule