module PCPlus4 (
    input [31:0] pc,        // Current pc value
	output [31:0] pc_plus_4 // pc+4 value
);
    assign pc_plus_4 = pc + 4;

endmodule