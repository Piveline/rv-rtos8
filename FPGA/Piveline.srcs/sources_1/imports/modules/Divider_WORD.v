`include "./alu_op.vh"

module Divider_WORD #(
    parameter XLEN = 32
)(
    input clk,
    input clk_enable,
    input reset,
    input division_start,
    input is_signed,
    input [31:0] dividend,
    input [31:0] divisor,

    output [31:0] quotient,
    output [31:0] remainder,
    output busy
);
    // Refined Division Algorithm 

    // FSM States
    localparam IDLE         = 3'b000;
    localparam INITIALIZE   = 3'b001;
    localparam CALCULATE    = 3'b010;
    localparam FINALIZE     = 3'b011;

    reg [2:0] state;
    reg [5:0] bit_counter;
    reg [31:0] quotient_reg;
    reg [31:0] remainder_reg;
    reg busy_reg;
    reg [63:0] remainder_quotient;
    reg [31:0] divisor_reg;
    reg quotient_sign;
    reg remainder_sign;
    reg div_by_zero_flag;
    reg div_overflow_flag;
    reg [31:0] dividend_reg;
    
    wire [63:0] shifted_rq;
    wire [32:0] subtract_result;
    
    assign shifted_rq = {remainder_quotient[62:0], 1'b0};
    assign subtract_result = {1'b0, shifted_rq[63:32]} - {1'b0, divisor_reg};

    wire div_by_zero = (divisor == 32'b0);
    wire div_overflow = (is_signed && (dividend == 32'h8000_0000) && (divisor == 32'hFFFF_FFFF));
    
    assign quotient = div_by_zero_flag ? 32'hFFFF_FFFF : 
                      (div_overflow_flag) ? dividend_reg : quotient_reg;
    assign remainder = (div_by_zero_flag) ? dividend_reg :
                       (div_overflow_flag) ? 32'b0 : remainder_reg;
    assign busy = (div_by_zero_flag || div_overflow_flag) ? 1'b0 : busy_reg;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy_reg <= 1'b0;
            bit_counter <= 6'b0;
            divisor_reg <= 32'b0;
            quotient_reg <= 32'b0;
            remainder_reg <= 32'b0;
            remainder_quotient <= 64'b0;
            quotient_sign <= 1'b0;
            remainder_sign <= 1'b0;
            div_by_zero_flag <= 1'b0;
            div_overflow_flag <= 1'b0;
            dividend_reg <= 32'b0;
        end
        else if (clk_enable) begin
            if (division_start) begin
                div_by_zero_flag <= div_by_zero;
                div_overflow_flag <= div_overflow;
                dividend_reg <= dividend;
            end
            case (state)
                IDLE: begin
                    if (division_start && !div_by_zero && !div_overflow) begin
                        busy_reg <= 1'b1;
                        state <= INITIALIZE;
                    end
                    else begin
                        busy_reg <= 1'b0;
                        state <= IDLE;
                    end
                end
                INITIALIZE: begin
                    bit_counter <= 6'd32;
                    state <= CALCULATE;
                    if (is_signed) begin
                        quotient_sign <= dividend[31] ^ divisor[31];
                        remainder_sign <= dividend[31];
                        
                        // dividend absolute value (upper 32bits are 0)
                        if (dividend[31]) begin
                            remainder_quotient <= {32'b0, (~dividend + 1'b1)};
                        end
                        else begin
                            remainder_quotient <= {32'b0, dividend};
                        end
                        
                        // divisor absolute value
                        if (divisor[31]) begin
                            divisor_reg <= (~divisor + 1'b1);
                        end
                        else begin
                            divisor_reg <= divisor;
                        end
                    end
                    else begin
                        // Unsigned
                        quotient_sign <= 1'b0;
                        remainder_sign <= 1'b0;
                        remainder_quotient <= {32'b0, dividend};
                        divisor_reg <= divisor;
                    end
                end
                // CALCULATE
                CALCULATE: begin
                    if (bit_counter == 6'b0) begin
                        state <= FINALIZE;
                    end
                    else begin
                        bit_counter <= bit_counter - 1'b1;
                        if (subtract_result[32] == 1'b0) begin
                            // subtract success, quotient bit = 1
                            remainder_quotient <= {subtract_result[31:0], shifted_rq[31:1], 1'b1};
                        end
                        else begin
                            // subtract failed: shift only, quotient bit = 0
                            remainder_quotient <= shifted_rq;
                        end
                    end
                end
                
                FINALIZE: begin
                    busy_reg <= 1'b0;
                    state <= IDLE;
                    if (is_signed) begin
                        if (quotient_sign) begin
                            quotient_reg <= (~remainder_quotient[31:0] + 1'b1);
                        end
                        else begin
                            quotient_reg <= remainder_quotient[31:0];
                        end
                        if (remainder_sign) begin
                            remainder_reg <= (~remainder_quotient[63:32] + 1'b1);
                        end
                        else begin
                            remainder_reg <= remainder_quotient[63:32];
                        end
                    end
                    else begin
                        quotient_reg <= remainder_quotient[31:0];
                        remainder_reg <= remainder_quotient[63:32];
                    end
                end

                default: begin
                    busy_reg <= 1'b0;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule