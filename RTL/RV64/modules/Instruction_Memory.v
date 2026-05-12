`include "./modules/headers/branch_funct3.vh"
`include "./modules/headers/itype_funct3.vh"
`include "./modules/headers/load_funct3.vh"
`include "./modules/headers/rtype_funct3.vh"
`include "./modules/headers/rtype_mul_funct3.vh"
`include "./modules/headers/store_funct3.vh"
`include "./modules/headers/opcode.vh"
`include "./modules/headers/csr_funct3.vh"

module InstructionMemory #(
    parameter XLEN = 64
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
				rom_read_data <= {data[{rom_address[15:3], 1'b1}], data[{rom_address[15:3], 1'b0}]};			end
			else begin
				rom_read_data <= {XLEN{1'b0}};
			end
		end
	end
	
	initial begin
		$readmemh("./modules/firmware_RV64.mem", data);
	end

endmodule