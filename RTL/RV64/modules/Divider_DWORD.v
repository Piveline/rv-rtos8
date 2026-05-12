`include "./alu_op.vh"

module Divider_DWORD #(
    parameter XLEN = 64
) (
    input wire clk,
    input wire clk_enable,
    input wire reset,
    input wire division_start,
    input wire is_signed,
    input wire [XLEN-1:0] dividend,
    input wire [XLEN-1:0] divisor,

    output wire [XLEN-1:0] quotient,
    output wire [XLEN-1:0] remainder,
    output wire busy
);

    localparam IDLE = 2'b00;
    localparam INITIALIZE = 2'b01;
    localparam CALCULATE = 2'b10;
    localparam FINALIZE = 2'b11;

    reg [1:0] state;
    reg [6:0] bit_counter;
    reg busy_reg;
    reg [XLEN-1:0] divisor_reg;
    reg [XLEN-1:0] quotient_reg;
    reg [XLEN-1:0] remainder_reg;
    reg [2*XLEN-1:0] remainder_quotient; //128-bit
    reg quotient_sign;
    reg remainder_sign;
    reg div_by_zero_flag;
    reg div_overflow_flag;
    reg [XLEN-1:0] dividend_reg;

    wire [2*XLEN-1:0] shifted_rq;
    wire [XLEN:0] subtract_result;  // 65-bit subtract

    assign shifted_rq = {remainder_quotient[2*XLEN-2:0], 1'b0};
    assign subtract_result = {1'b0, shifted_rq[2*XLEN-1:XLEN]} - {1'b0, divisor_reg};   // 65-bit subtract, MSB is sign bit(borrow)

    wire div_by_zero = (divisor == {XLEN{1'b0}});
    wire div_overflow = (is_signed && (dividend == {1'b1, {XLEN-1{1'b0}}}) && (divisor == {XLEN{1'b1}}));
    assign quotient = (div_by_zero_flag) ? {XLEN{1'b1}} : 
                      (div_overflow_flag) ? dividend_reg : quotient_reg;
    assign remainder = (div_by_zero_flag) ? dividend_reg :
                      (div_overflow_flag) ? {XLEN{1'b0}} : remainder_reg;
    assign busy = (div_by_zero_flag || div_overflow_flag) ? 1'b0 : busy_reg;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy_reg <= 1'b0;
            bit_counter <= 7'b0;
            divisor_reg <= {XLEN{1'b0}};
            quotient_reg <= {XLEN{1'b0}};
            remainder_reg <= {XLEN{1'b0}};
            remainder_quotient <= {2*XLEN{1'b0}};
            quotient_sign <= 1'b0;
            remainder_sign <= 1'b0;
            div_by_zero_flag <= 1'b0;
            div_overflow_flag <= 1'b0;
            dividend_reg <= {XLEN{1'b0}};
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
                    bit_counter <= 7'd64;
                    state <= CALCULATE;
                    if (is_signed) begin
                        quotient_sign <= dividend[XLEN-1] ^ divisor[XLEN-1];
                        remainder_sign <= dividend[XLEN-1];

                        if (dividend[XLEN-1]) begin
                            remainder_quotient <= {{XLEN{1'b0}}, (~dividend + 1'b1)};
                        end
                        else begin
                            remainder_quotient <= {{XLEN{1'b0}}, dividend};
                        end

                        if (divisor[XLEN-1]) begin
                            divisor_reg <= (~divisor + 1'b1);
                        end
                        else begin
                            divisor_reg <= divisor;
                        end
                    end
                    else begin
                        quotient_sign <= 1'b0;
                        remainder_sign <= 1'b0;
                        remainder_quotient <= {{XLEN{1'b0}}, dividend};
                        divisor_reg <= divisor;
                    end
                end
                CALCULATE: begin
                    if (bit_counter == 7'b0) begin
                        state <= FINALIZE;
                    end
                    else begin
                        bit_counter <= bit_counter - 1'b1;
                        if (subtract_result[XLEN] == 1'b0) begin
                            remainder_quotient <= {subtract_result[XLEN-1:0], shifted_rq[XLEN-1:1], 1'b1};
                        end
                        else begin
                            remainder_quotient <= shifted_rq;
                        end
                    end
                end

                FINALIZE: begin
                    busy_reg <= 1'b0;
                    state <= IDLE;
                    if (is_signed) begin
                        if (quotient_sign) begin
                            quotient_reg <= (~remainder_quotient[XLEN-1:0] + 1'b1);
                        end
                        else begin
                            quotient_reg <= remainder_quotient[XLEN-1:0];
                        end
                        if (remainder_sign) begin
                            remainder_reg <= (~remainder_quotient[2*XLEN-1:XLEN] + 1'b1);
                        end
                        else begin
                            remainder_reg <= remainder_quotient[2*XLEN-1:XLEN];
                        end
                    end
                    else begin
                        quotient_reg <= remainder_quotient[XLEN-1:0];
                        remainder_reg <= remainder_quotient[2*XLEN-1:XLEN];
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