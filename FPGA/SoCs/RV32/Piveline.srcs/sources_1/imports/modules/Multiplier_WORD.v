// 3-Stage Pipelined 32x32 Multiplier with DSP Block Inference
// Stage 1: Input registration & sign handling
// Stage 2: DSP multiplication
// Stage 3: Sign correction & output

module Multiplier_WORD (
    input clk,
    input clk_enable,
    input reset,
    input mul_start,                // Start multiplication pulse
    
    input [31:0] src_A,
    input [31:0] src_B,
    input signed_A,
    input signed_B,
    
    output reg [31:0] prod_high,
    output reg [31:0] prod_low,
    output reg mul_busy             // Indicates multiplication in progress
);

    // Pipeline stage counter (0 = idle, 1-3 = stages)
    reg [1:0] stage;
    
    // Stage 1 registers: Input capture & sign handling
    reg [31:0] abs_A_s1;
    reg [31:0] abs_B_s1;
    reg result_sign_s1;
    
    // Stage 2 registers: DSP multiplication result
    (* use_dsp = "yes" *) reg [63:0] prod_unsigned_s2;
    reg result_sign_s2;
    
    // Combinatorial signals for Stage 1
    wire [31:0] abs_A = (signed_A && src_A[31]) ? (~src_A + 1'b1) : src_A;
    wire [31:0] abs_B = (signed_B && src_B[31]) ? (~src_B + 1'b1) : src_B;
    wire result_sign = (signed_A && src_A[31]) ^ (signed_B && src_B[31]);
    
    // Combinatorial multiplication (will be pipelined into Stage 2)
    wire [63:0] mult_result = abs_A_s1 * abs_B_s1;
    
    // Combinatorial sign correction for Stage 3
    wire [63:0] prod_corrected = result_sign_s2 ? (~prod_unsigned_s2 + 1'b1) : prod_unsigned_s2;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            stage <= 2'd0;
            mul_busy <= 1'b0;
            abs_A_s1 <= 32'd0;
            abs_B_s1 <= 32'd0;
            result_sign_s1 <= 1'b0;
            prod_unsigned_s2 <= 64'd0;
            result_sign_s2 <= 1'b0;
            prod_high <= 32'd0;
            prod_low <= 32'd0;
        end
        else if (clk_enable) begin
            case (stage)
                2'd0: begin // IDLE
                    if (mul_start) begin
                        // Stage 1: Capture inputs and compute absolute values
                        abs_A_s1 <= abs_A;
                        abs_B_s1 <= abs_B;
                        result_sign_s1 <= result_sign;
                        mul_busy <= 1'b1;
                        stage <= 2'd1;
                    end
                    else begin
                        mul_busy <= 1'b0;
                    end
                end
                
                2'd1: begin // Stage 1 -> Stage 2
                    // Stage 2: Perform DSP multiplication
                    prod_unsigned_s2 <= mult_result;
                    result_sign_s2 <= result_sign_s1;
                    stage <= 2'd2;
                end
                
                2'd2: begin // Stage 2 -> Stage 3
                    // Stage 3: Apply sign correction and output
                    prod_high <= prod_corrected[63:32];
                    prod_low <= prod_corrected[31:0];
                    stage <= 2'd3;
                end
                
                2'd3: begin // Stage 3 -> IDLE
                    // Multiplication complete
                    mul_busy <= 1'b0;
                    stage <= 2'd0;
                end
                
                default: begin
                    stage <= 2'd0;
                    mul_busy <= 1'b0;
                end
            endcase
        end
    end

endmodule