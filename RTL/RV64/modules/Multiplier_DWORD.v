// 3-Stage Pipelined 64x64 Multiplier with DSP Block Inference
// Uses four 32x32 DSP multipliers in parallel
// Stage 1: Input registration & sign handling
// Stage 2: Four parallel DSP multiplications  
// Stage 3: Partial product addition, sign correction & output

module Multiplier_DWORD (
    input clk,
    input clk_enable,
    input reset,
    input mul_start,                // Start multiplication pulse
    
    input [63:0] src_A,
    input [63:0] src_B,
    input signed_A,
    input signed_B,

    output reg [63:0] prod_high,
    output reg [63:0] prod_low,
    output reg mul_busy             // Indicates multiplication in progress
);

    // Pipeline stage counter (0 = idle, 1-3 = stages)
    reg [1:0] stage;
    
    // Stage 1 registers: Input capture & sign handling
    reg [63:0] abs_A_s1;
    reg [63:0] abs_B_s1;
    reg result_sign_s1;
    
    // Stage 2 registers: Four partial products from DSP
    (* use_dsp = "yes" *) reg [63:0] prod_AHBH_s2;  // A[63:32] * B[63:32]
    (* use_dsp = "yes" *) reg [63:0] prod_AHBL_s2;  // A[63:32] * B[31:0]
    (* use_dsp = "yes" *) reg [63:0] prod_ALBH_s2;  // A[31:0] * B[63:32]
    (* use_dsp = "yes" *) reg [63:0] prod_ALBL_s2;  // A[31:0] * B[31:0]
    reg result_sign_s2;
    
    // Combinatorial signals for Stage 1
    wire [63:0] abs_A = (signed_A && src_A[63]) ? (~src_A + 1'b1) : src_A;
    wire [63:0] abs_B = (signed_B && src_B[63]) ? (~src_B + 1'b1) : src_B;
    wire result_sign = (signed_A && src_A[63]) ^ (signed_B && src_B[63]);
    
    // Combinatorial multiplications for Stage 2 (four 32x32 -> 64-bit multiplies)
    wire [63:0] mult_AHBH = abs_A_s1[63:32] * abs_B_s1[63:32];
    wire [63:0] mult_AHBL = abs_A_s1[63:32] * abs_B_s1[31:0];
    wire [63:0] mult_ALBH = abs_A_s1[31:0] * abs_B_s1[63:32];
    wire [63:0] mult_ALBL = abs_A_s1[31:0] * abs_B_s1[31:0];
    
    // Combinatorial partial product addition and sign correction for Stage 3
    // Product = AHBH<<64 + AHBL<<32 + ALBH<<32 + ALBL
    wire [127:0] unsigned_sum = {prod_AHBH_s2, 64'd0} + 
                                 {32'd0, prod_AHBL_s2, 32'd0} + 
                                 {32'd0, prod_ALBH_s2, 32'd0} + 
                                 {64'd0, prod_ALBL_s2};
    wire [127:0] prod_corrected = result_sign_s2 ? (~unsigned_sum + 1'b1) : unsigned_sum;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            stage <= 2'd0;
            mul_busy <= 1'b0;
            abs_A_s1 <= 64'd0;
            abs_B_s1 <= 64'd0;
            result_sign_s1 <= 1'b0;
            prod_AHBH_s2 <= 64'd0;
            prod_AHBL_s2 <= 64'd0;
            prod_ALBH_s2 <= 64'd0;
            prod_ALBL_s2 <= 64'd0;
            result_sign_s2 <= 1'b0;
            prod_high <= 64'd0;
            prod_low <= 64'd0;
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
                    // Stage 2: Perform four parallel DSP multiplications
                    prod_AHBH_s2 <= mult_AHBH;
                    prod_AHBL_s2 <= mult_AHBL;
                    prod_ALBH_s2 <= mult_ALBH;
                    prod_ALBL_s2 <= mult_ALBL;
                    result_sign_s2 <= result_sign_s1;
                    stage <= 2'd2;
                end
                
                2'd2: begin // Stage 2 -> Stage 3
                    // Stage 3: Add partial products, apply sign correction, output
                    prod_high <= prod_corrected[127:64];
                    prod_low <= prod_corrected[63:0];
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