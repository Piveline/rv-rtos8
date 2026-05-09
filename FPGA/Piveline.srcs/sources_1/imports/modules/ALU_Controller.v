`include "./alu_op.vh"
`include "./branch_funct3.vh"
`include "./csr_funct3.vh"
`include "./itype_funct3.vh"
`include "./opcode.vh"
`include "./rtype_funct3.vh"
`include "./rtype_mul_funct3.vh"

module ALUController (
	input clk,
	input clk_enable,
	input reset,
    input [6:0] opcode,        		// opcode
	input [2:0] funct3,				// funct3
	input funct7_0,					// 0th index of funct7
    input funct7_5,					// 5th index of funct7
    input imm_10,					// 10th index of imm
	input div_busy,                 // division unit busy signal
	input mul_busy,                 // multiplication unit busy signal
	input load_use_hazard,          // load-use hazard - delay mul/div start
	input ex_kill,                  // EX-stage instruction squashed (flush)

    output reg [4:0] alu_op,		// ALU operation signal
	output div_start,
	output mul_start
);
	// Division control signals
	wire is_div;
	reg div_inflight;

	assign is_div = (opcode == `OPCODE_RTYPE) && (funct7_0) &&
					((funct3 == `RTYPE_DIV) ||
					(funct3 == `RTYPE_DIVU) ||
					(funct3 == `RTYPE_REM) ||
					(funct3 == `RTYPE_REMU));

	// Gate div_start with !load_use_hazard and !ex_kill to ensure operands are ready
	assign div_start = is_div && !div_inflight && !ex_kill;

	// Multiplication control signals
	wire is_mul;
	reg mul_inflight;

	assign is_mul = (opcode == `OPCODE_RTYPE) && (funct7_0) &&
					((funct3 == `RTYPE_MUL) ||
					(funct3 == `RTYPE_MULH) ||
					(funct3 == `RTYPE_MULHSU) ||
					(funct3 == `RTYPE_MULHU));

	// Gate mul_start with !load_use_hazard and !ex_kill to ensure operands are ready
	assign mul_start = is_mul && !mul_inflight && !ex_kill;

	// Division inflight state machine
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			div_inflight <= 1'b0;
		end
		else if (clk_enable) begin
			if (ex_kill) begin
				div_inflight <= 1'b0;
			end
			else if (div_start) begin
				div_inflight <= 1'b1;
			end
			else if (!div_busy) begin
				div_inflight <= 1'b0;
			end
			else if (!is_div) begin
				div_inflight <= 1'b0;
			end 
		end
	end

	// Multiplication inflight state machine
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			mul_inflight <= 1'b0;
		end
		else if (clk_enable) begin
			if (ex_kill) begin
				mul_inflight <= 1'b0;
			end
			else if (mul_start) begin
				mul_inflight <= 1'b1;
			end
			else if (!mul_busy) begin
				mul_inflight <= 1'b0;
			end
			else if (!is_mul) begin
				mul_inflight <= 1'b0;
			end 
		end
	end

    always @(*) begin
		alu_op = `ALU_OP_NOP; // default NOP
        case (opcode)
			`OPCODE_AUIPC, `OPCODE_JAL, `OPCODE_JALR, `OPCODE_LOAD, `OPCODE_STORE: begin
				alu_op = `ALU_OP_ADD;
			end
			`OPCODE_BRANCH: begin
				case (funct3)
					`BRANCH_BEQ: alu_op = `ALU_OP_SUB; // If subtraction result is zero, equal
					`BRANCH_BNE: alu_op = `ALU_OP_SUB; // If subtraction result is not zero, not equal
					`BRANCH_BLT: alu_op = `ALU_OP_SLT; // If SLT result is not zero, less
					`BRANCH_BGE: alu_op = `ALU_OP_SLT; // If SLT result is zero, greater or equal
					`BRANCH_BLTU: alu_op = `ALU_OP_SLTU; // If SLTU result is not zero, less (unsigned)
					`BRANCH_BGEU: alu_op = `ALU_OP_SLTU; // If SLTU result is zero, greater or equal (unsigned)
					default: alu_op = `ALU_OP_NOP;
				endcase
			end
			`OPCODE_ITYPE: begin
				case (funct3)
					`ITYPE_ADDI: alu_op = `ALU_OP_ADD;
					`ITYPE_SLLI: alu_op = `ALU_OP_SLL;
					`ITYPE_SLTI: alu_op = `ALU_OP_SLT;
					`ITYPE_SLTIU: alu_op = `ALU_OP_SLTU;
					`ITYPE_XORI: alu_op = `ALU_OP_XOR;
					`ITYPE_SRXI: begin // srli or srai
						if (imm_10) begin
							alu_op = `ALU_OP_SRA; // srai : imm[10] = 1
						end
						else begin
							alu_op = `ALU_OP_SRL; // srli : imm[10] = 0
						end
					end
					`ITYPE_ORI: alu_op = `ALU_OP_OR; // ori : 110 ; - 
					`ITYPE_ANDI: alu_op = `ALU_OP_AND; // andi : 111 ; -
					default: alu_op = `ALU_OP_NOP;
				endcase
			end 
			`OPCODE_RTYPE: begin
				
				if (funct7_0) begin // M extension operations
					case (funct3)
						`RTYPE_MUL: alu_op = `ALU_OP_MUL;
						`RTYPE_MULH: alu_op = `ALU_OP_MULH;
						`RTYPE_MULHSU: alu_op = `ALU_OP_MULHSU;
						`RTYPE_MULHU: alu_op = `ALU_OP_MULHU;
						`RTYPE_DIV: alu_op = `ALU_OP_DIV;
						`RTYPE_DIVU: alu_op = `ALU_OP_DIVU;
						`RTYPE_REM: alu_op = `ALU_OP_REM;
						`RTYPE_REMU: alu_op = `ALU_OP_REMU;
						default: alu_op = `ALU_OP_NOP;
					endcase
				end
				else begin
					// I extension operations
					case (funct3)
						`RTYPE_ADDSUB: begin // add or sub
							if (funct7_5) begin
								alu_op = `ALU_OP_SUB; // sub : funct7 = 0100000
							end
							else begin
								alu_op = `ALU_OP_ADD; // add : funct7 = 0000000 
							end
						end
						`RTYPE_SLL: alu_op = `ALU_OP_SLL;
						`RTYPE_SLT: alu_op = `ALU_OP_SLT;
						`RTYPE_SLTU: alu_op = `ALU_OP_SLTU;
						`RTYPE_XOR: alu_op = `ALU_OP_XOR;
						`RTYPE_SRX: begin // srl or sra
							if (funct7_5) begin
								alu_op = `ALU_OP_SRA; // sra : funct7 = 0100000
							end
							else begin
								alu_op = `ALU_OP_SRL; // srl : funct7 = 0000000
							end
						end
						`RTYPE_OR: alu_op = `ALU_OP_OR;
						`RTYPE_AND: alu_op = `ALU_OP_AND;
						default: alu_op = `ALU_OP_NOP;
					endcase
				end
                
            end
			`OPCODE_ENVIRONMENT: begin
				case (funct3)
					`CSR_CSRRW: alu_op = `ALU_OP_ADD; // will perform +0 operation
					`CSR_CSRRS: alu_op = `ALU_OP_OR;
					`CSR_CSRRC: alu_op = `ALU_OP_ABJ;
					`CSR_CSRRWI: alu_op = `ALU_OP_ADD; // will perform +0 operation
					`CSR_CSRRSI: alu_op = `ALU_OP_OR;
					`CSR_CSRRCI: alu_op = `ALU_OP_ABJ;
					default: alu_op = `ALU_OP_NOP;
				endcase
			end
			default: alu_op = `ALU_OP_NOP;
        endcase
    end

endmodule