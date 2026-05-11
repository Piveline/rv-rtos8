module PCController #(
	parameter XLEN = 32
)(
    input jump, 				// signal indicating if PC should jump
	input branch_estimation,	// signal indicating if PC should take the branch
	input branch_prediction_miss,	
	input trapped,				// signal indicating if trap has occurred
	input [XLEN-1:0] pc,			// current pc value
	input [XLEN-1:0] jump_target,	// target address for jump
	input [XLEN-1:0] branch_target, // target address for branch from branch predictor
	input [XLEN-1:0] branch_target_actual, // actual branch target address when mispredicted
	input [XLEN-1:0] trap_target,	// target address for trap
	input pc_stall,				// signal indicating if pc update should be paused

	output reg [XLEN-1:0] next_pc	// next pc value
);

    always @(*) begin
		if (!pc_stall) begin
			if (trapped) begin
				next_pc = trap_target;
			end
			else if (branch_prediction_miss) begin
				next_pc = branch_target_actual;
			end
			else if (jump) begin
				next_pc = jump_target;
			end
			else if (branch_estimation) begin
				next_pc = branch_target;
			end
			else begin
				next_pc = pc + 4;
			end
		end
		else begin
			next_pc = pc;
		end
    end

endmodule