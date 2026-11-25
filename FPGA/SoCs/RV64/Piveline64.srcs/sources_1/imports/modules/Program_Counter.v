module ProgramCounter #(
    parameter XLEN = 64
)(
    input clk,
    input clk_enable,
    input reset,
    input [XLEN-1:0] next_pc,
    output reg [XLEN-1:0] pc
);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pc <= {XLEN{1'b0}};
        end 
        else if (clk_enable) begin
            pc <= next_pc;
        end
    end

endmodule