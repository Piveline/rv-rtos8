`include "./modules/headers/alu_op.vh"
`include "./modules/ALU_WORD.v"
`include "./modules/Multiplier_WORD.v"
`include "./modules/Divider_WORD.v"
`include "./modules/ALU_DWORD.v"
`include "./modules/Multiplier_DWORD.v"
`include "./modules/Divider_DWORD.v"

module ALU #(
    parameter XLEN = 64
)(
    input clk,
    input clk_enable,
    input reset,

    input [XLEN-1:0] src_A,             // source operand A
    input [XLEN-1:0] src_B,             // source operand B
    input [4:0] alu_op,        		// ALU operation signal (from ALU Control module)
    input input_size_word,

    input div_start,
    input mul_start,

    output mul_busy,
    output div_busy,

    output [31:0] alu_word_result_out,
    output reg [XLEN-1:0] alu_result   // ALU result
);
    wire [31:0] alu_word_result;
    wire alu_word_zero;

    wire [XLEN-1:0] alu_dword_result;
    wire alu_dword_zero;

    wire [31:0] prod_high_word;
    wire [31:0] prod_low_word;

    wire [63:0] prod_high_dword;
    wire [63:0] prod_low_dword;

    assign alu_word_result_out = alu_word_result;

    // Multiplier busy signals
    wire mul_busy_word;
    wire mul_busy_dword;

    assign mul_busy = mul_busy_word | mul_busy_dword;

    // Divider outputs
    wire [31:0] quot_word;
    wire [31:0] rem_word;
    wire div_busy_word;

    wire [XLEN-1:0] quot_dword;
    wire [XLEN-1:0] rem_dword;
    wire div_busy_dword;

    assign div_busy = div_busy_word | div_busy_dword;

    ALU_WORD alu_word (
        .src_A(src_A[31:0]),
        .src_B(src_B[31:0]),
        .alu_op(alu_op),
        
        .alu_result(alu_word_result)
    );

    ALU_DWORD alu_dword (
        .src_A(src_A),
        .src_B(src_B),
        .alu_op(alu_op),
        
        .alu_result(alu_dword_result)
    );

    Multiplier_WORD multiplier_word (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .mul_start(mul_start && input_size_word),
        .src_A(src_A[31:0]),
        .src_B(src_B[31:0]),
        .signed_A(alu_op == `ALU_OP_MULH | alu_op == `ALU_OP_MULHSU),
        .signed_B(alu_op == `ALU_OP_MULH),

        .prod_high(prod_high_word),
        .prod_low(prod_low_word),
        .mul_busy(mul_busy_word)
    );

    Multiplier_DWORD multiplier_dword (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .mul_start(mul_start && !input_size_word),
        .src_A(src_A),
        .src_B(src_B),
        .signed_A(alu_op == `ALU_OP_MULH | alu_op == `ALU_OP_MULHSU),
        .signed_B(alu_op == `ALU_OP_MULH),

        .prod_high(prod_high_dword),
        .prod_low(prod_low_dword),
        .mul_busy(mul_busy_dword)
    );

    Divider_WORD divider_word (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .division_start(div_start && input_size_word),
        .is_signed(alu_op == `ALU_OP_DIV || alu_op == `ALU_OP_REM),
        .dividend(src_A[31:0]),
        .divisor(src_B[31:0]),
        .quotient(quot_word),
        .remainder(rem_word),
        .busy(div_busy_word)
    );

    Divider_DWORD #(.XLEN(XLEN)) divider_dword (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .division_start(div_start && !input_size_word),
        .is_signed(alu_op == `ALU_OP_DIV || alu_op == `ALU_OP_REM),
        .dividend(src_A),
        .divisor(src_B),
        .quotient(quot_dword),
        .remainder(rem_dword),
        .busy(div_busy_dword)
    );
    

    always @(*) begin
        case (alu_op)
            `ALU_OP_MUL: begin
                if (input_size_word) begin
                    alu_result = {{32{prod_low_word[31]}}, prod_low_word};
                end
                else begin
                    alu_result = prod_low_dword;
                end
            end
            `ALU_OP_MULH, `ALU_OP_MULHSU, `ALU_OP_MULHU: begin
                if (input_size_word) begin
                    alu_result = {{32{prod_high_word[31]}}, prod_high_word};
                end
                else begin
                    alu_result = prod_high_dword;
                end
            end

            `ALU_OP_DIV, `ALU_OP_DIVU: begin
                if (input_size_word) begin
                    alu_result = {{32{quot_word[31]}}, quot_word};
                end
                else begin
                    alu_result = quot_dword;
                end
            end

            `ALU_OP_REM, `ALU_OP_REMU: begin
                if (input_size_word) begin
                    alu_result = {{32{rem_word[31]}}, rem_word};
                end
                else begin
                    alu_result = rem_dword;
                end
            end
            
            default: begin
                alu_result = alu_dword_result;
            end
        endcase
    end

endmodule