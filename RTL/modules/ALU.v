`include "./headers/alu_op.vh"

module ALU #(
    parameter XLEN = 32
)(
    input clk,
    input clk_enable,
    input reset,

    input [XLEN-1:0] src_A,             // source operand A
    input [XLEN-1:0] src_B,             // source operand B
    input [4:0] alu_op,        		// ALU operation signal (from ALU Control module)

    input div_start,
    input mul_start,

    output mul_busy,
    output div_busy,

    output reg [XLEN-1:0] alu_result   // ALU result
);
    wire [31:0] alu_word_result;

    wire [31:0] prod_high_word;
    wire [31:0] prod_low_word;

    // Multiplier busy signals
    wire mul_busy_word;

    assign mul_busy = mul_busy_word;

    // Divider outputs
    wire [31:0] quot_word;
    wire [31:0] rem_word;
    wire div_busy_word;

    assign div_busy = div_busy_word;

    ALU_WORD alu_word (
        .src_A(src_A[31:0]),
        .src_B(src_B[31:0]),
        .alu_op(alu_op),
        
        .alu_result(alu_word_result)
    );

    Multiplier_WORD multiplier_word (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .mul_start(mul_start),
        .src_A(src_A[31:0]),
        .src_B(src_B[31:0]),
        .signed_A(alu_op == `ALU_OP_MULH | alu_op == `ALU_OP_MULHSU),
        .signed_B(alu_op == `ALU_OP_MULH),

        .prod_high(prod_high_word),
        .prod_low(prod_low_word),
        .mul_busy(mul_busy_word)
    );

    Divider_WORD divider_word (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .division_start(div_start),
        .is_signed(alu_op == `ALU_OP_DIV || alu_op == `ALU_OP_REM),
        .dividend(src_A[31:0]),
        .divisor(src_B[31:0]),
        .quotient(quot_word),
        .remainder(rem_word),
        .busy(div_busy_word)
    );

    always @(*) begin
        case (alu_op)
            `ALU_OP_MUL: begin
                    alu_result = prod_low_word;
            end
            `ALU_OP_MULH, `ALU_OP_MULHSU, `ALU_OP_MULHU: begin
                    alu_result = prod_high_word;
            end

            `ALU_OP_DIV, `ALU_OP_DIVU: begin
                    alu_result = quot_word;
            end

            `ALU_OP_REM, `ALU_OP_REMU: begin
                    alu_result = rem_word;
            end
            
            default: begin
                alu_result = alu_word_result;
            end
        endcase
    end

endmodule
