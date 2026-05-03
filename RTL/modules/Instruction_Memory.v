`include "./branch_funct3.vh"
`include "./itype_funct3.vh"
`include "./load_funct3.vh"
`include "./rtype_funct3.vh"
`include "./rtype_mul_funct3.vh"
`include "./store_funct3.vh"
`include "./opcode.vh"
`include "./csr_funct3.vh"

module InstructionMemory #(
    parameter XLEN = 32
)(
	input clk,
	input clk_enable,
	input pc_stall,
	input read_stall,
    input [XLEN-1:0] pc,
	input [XLEN-1:0] rom_address,

    output reg [31:0] instruction,
	output reg [XLEN-1:0] rom_read_data
);

	(* ram_style = "block" *) reg [31:0] data [0:8191];
	wire rom_access = (rom_address[31:16] == 16'h0000);

	always @(posedge clk) begin
		if (clk_enable && !pc_stall) begin
			instruction <= data[pc[15:2]];
		end
	end

	always @(posedge clk) begin
		if (clk_enable && !read_stall) begin
			if (rom_access) begin
				rom_read_data <= data[rom_address[15:2]];
			end
			else begin
				rom_read_data <= {XLEN{1'b0}};
			end
		end
	end
	
	initial begin
		 $readmemh("./coremark_RV32IM_100MHz.mem", data);
		// ──────────────────────────────────────────────
		// Trap Handler 시작 주소. mtvec = 0000_1000 = 4096 ÷ 4 Byte = 1024
		// Trap Handler 진입 시 기존 GPR의 레지스터 내용들을 별도의 메모리 Heap 구역에 store하고 수행해야하지만, 현재 단계에서는 생략함.
		// CSR mcause 확인해서 ecall이면 x1 = 0000_0000으로 만들기, misaligned면 x2에 FF더하기
		// 조건 분기; 비교문 작성을 위한 적재 작업
		data[7000] = {12'h342, 5'd0, 3'b010, 5'd6, `OPCODE_ENVIRONMENT}; 					// csrrs x6, mcause, x0:	레지스터 x6에 mcause값 적재
		data[7001] = {12'd11, 5'd0, `ITYPE_ADDI, 5'd7, `OPCODE_ITYPE};						// addi x7, x0, 11: 		레지스터 x7에 ECALL 코드 값 11 적재
		data[7002] = {12'd2, 5'd0, `ITYPE_ADDI, 5'd8, `OPCODE_ITYPE};						// addi x8, x0, 2: 			레지스터 x8에 ILLEGAL INSTRUCTION 코드 값 2 적재
		data[7003] = {12'd4, 5'd0, `ITYPE_ADDI, 5'd9, `OPCODE_ITYPE};						// addi x9, x0, 4: 			레지스터 x9에 MISALIGNED LOAD 코드 값 4 적재
		data[7004] = {12'd6, 5'd0, `ITYPE_ADDI, 5'd10, `OPCODE_ITYPE};						// addi x10, x0, 6: 		레지스터 x10에 MISALIGNED STORE 코드 값 6 적재

		// mcause 분석해서 해당하는 Trap Handler 주소로 분기
		data[7005] = {1'b0, 6'b0, 5'd7, 5'd6, `BRANCH_BEQ, 4'b1100, 1'b0, `OPCODE_BRANCH};	// beq x6, x7, +24: 		ECALL; x6과 x7이 같다면 24바이트 이후 주솟값으로 분기 = data[1035]
		data[7006] = {1'b0, 6'd0, 5'd0, 5'd6, `BRANCH_BEQ, 4'b1110, 1'b0, `OPCODE_BRANCH};	// beq x6, x0, +28: 		MISALIGNED INSTRUCTION; x6값이 0과 같다면 28바이트 이후 주솟값으로 분기 = data[1037]
		data[7007] = {1'b0, 6'd0, 5'd10, 5'd6, `BRANCH_BEQ, 4'b1100, 1'b0, `OPCODE_BRANCH};	// beq x6, x10, +24: 		MISALIGNED STORE; x6값이 x10과 같다면 24바이트 이후 주솟값으로 분기 = data[1037]
		data[7008] = {1'b0, 6'd0, 5'd9, 5'd6, `BRANCH_BEQ, 4'b1010, 1'b0, `OPCODE_BRANCH};	// beq x6, x9, +20: 		MISALIGNED LOAD; x6값이 x9와 같다면 20바이트 이후 주솟값으로 분기 = data[1037]
		data[7009] = {1'b0, 6'd0, 5'd8, 5'd6, `BRANCH_BEQ, 4'b1000, 1'b0, `OPCODE_BRANCH};	// beq x6, x8, +16: 		ILLEGAL; x6값이 x8과 같다면 16바이트 이후 주솟값으로 분기 = data[1037]
		data[7010] = {1'b0, 10'b000_0001_000, 1'b0, 8'b0, 5'd0, `OPCODE_JAL};				// jal x0, +16: 			TH 끝내기 (mret 명령어 주소로 가기)
		
		// ECALL Trap Handler @ data[1035]
		data[7011] = {12'd0, 5'd0, `ITYPE_ADDI, 5'd1, `OPCODE_ITYPE};						// addi x1, x0, 0: 			레지스터 x1 값 0으로 비우기
		data[7012] = {1'b0, 10'b000_0000_100, 1'b0, 8'b0, 5'd0, `OPCODE_JAL};				// jal x0, +8:				TH 끝내기 (mret 명령어 주소로 가기)

		// ILLEGAL / MISALIGNED Trap Handler @ data[1037]
		data[7013] = {12'hFF, 5'd2, `ITYPE_ADDI, 5'd30, `OPCODE_ITYPE};						// addi x30, x2, 255: 		x30 레지스터에 x2(BC00_0000) + 0xFF = bc00_00ff

		// ESCAPE Trap Handler @ data[1038]
		data[7014] = {12'b001100000010, 5'b0, 3'b0, 5'b0, `OPCODE_ENVIRONMENT};				// MRET: PC = CSR[mepc]

		// HINT; NOP for 'x' signal after MRET in pipeline
		data[7015] = {12'h2BC, 5'd0, `ITYPE_ADDI, 5'd0, `OPCODE_ITYPE};						// ADDI:  x0 = x0 + 2BC = 0000_0000
		data[7016] = {12'h2BC, 5'd0, `ITYPE_ADDI, 5'd0, `OPCODE_ITYPE};						// ADDI:  x0 = x0 + 2BC = 0000_0000
		data[7017] = {12'h2BC, 5'd0, `ITYPE_ADDI, 5'd0, `OPCODE_ITYPE};						// ADDI:  x0 = x0 + 2BC = 0000_0000
		data[7018] = {12'h2BC, 5'd0, `ITYPE_ADDI, 5'd0, `OPCODE_ITYPE};						// ADDI:  x0 = x0 + 2BC = 0000_0000
	end

endmodule