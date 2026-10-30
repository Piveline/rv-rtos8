`timescale 1ns / 1ps

module Divider_WORD_tb;
    reg clk;
    reg clk_enable;
    reg reset;
    reg division_start;
    reg is_signed;
    reg [31:0] dividend;
    reg [31:0] divisor;

    wire [31:0] quotient;
    wire [31:0] remainder;
    wire busy;

    integer test_count;
    integer pass_count;
    integer fail_count;
    integer i;

    Divider_WORD divider_word (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .division_start(division_start),
        .is_signed(is_signed),
        .dividend(dividend),
        .divisor(divisor),
        .quotient(quotient),
        .remainder(remainder),
        .busy(busy)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // RISC-V M-extension reference results
    function [63:0] reference_div;   // {quotient, remainder}
        input [31:0] a;
        input [31:0] b;
        input s;
        begin
            if (b == 32'b0)
                reference_div = {32'hFFFF_FFFF, a};
            else if (s && a == 32'h8000_0000 && b == 32'hFFFF_FFFF)
                reference_div = {a, 32'b0};
            else if (s)
                reference_div = {$signed(a) / $signed(b), $signed(a) % $signed(b)};
            else
                reference_div = {a / b, a % b};
        end
    endfunction

    task run_division;
        input [31:0] a;
        input [31:0] b;
        input s;
        input [31:0] next_a;    // operands of the following instruction
        input [31:0] next_b;
        reg [63:0] expected;
        integer cycles;
        begin
            expected = reference_div(a, b, s);

            @(negedge clk);
            division_start = 1'b1;
            is_signed      = s;
            dividend       = a;
            divisor        = b;

            @(negedge clk);
            division_start = 1'b0;
            dividend       = next_a;
            divisor        = next_b;

            cycles = 0;
            while (busy && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            test_count = test_count + 1;

            if (busy) begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %s | test: 0x%08h / 0x%08h | expected: q=0x%08h r=0x%08h | actual: busy never deasserted",
                         test_count, s ? "signed  " : "unsigned", a, b,
                         expected[63:32], expected[31:0]);
            end
            else if ({quotient, remainder} !== expected) begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %s | test: 0x%08h / 0x%08h | expected: q=0x%08h r=0x%08h | actual: q=0x%08h r=0x%08h",
                         test_count, s ? "signed  " : "unsigned", a, b,
                         expected[63:32], expected[31:0], quotient, remainder);
            end
            else begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %s | test: 0x%08h / 0x%08h | expected: q=0x%08h r=0x%08h | actual: q=0x%08h r=0x%08h",
                         test_count, s ? "signed  " : "unsigned", a, b,
                         expected[63:32], expected[31:0], quotient, remainder);
            end
        end
    endtask

    initial begin
        test_count     = 0;
        pass_count     = 0;
        fail_count     = 0;
        clk_enable     = 1'b1;
        reset          = 1'b1;
        division_start = 1'b0;
        is_signed      = 1'b0;
        dividend       = 32'b0;
        divisor        = 32'b0;

        repeat (3) @(negedge clk);
        reset = 1'b0;

        $display("============================================");
        $display(" Divider_WORD Testbench");
        $display("============================================");

        // --------------------------------------------------------------------
        // Phase 1: directed vectors
        // --------------------------------------------------------------------
        $display("[TB] Phase 1: directed vectors");

        // Observed failure: 0x28/0x11 computed as 0x10001554/0x11
        run_division(32'h0000_0028, 32'h0000_0011, 1'b0, 32'h1000_1554, 32'h0000_0011);
        run_division(32'h0000_0028, 32'h0000_0011, 1'b1, 32'h1000_1554, 32'h0000_0011);

        run_division(32'd100,       32'd7,         1'b0, 32'd0,         32'd0);
        run_division(32'd100,       32'd7,         1'b1, 32'hFFFF_FFFF, 32'h0000_0001);
        run_division(32'hFFFF_FF9C, 32'd7,         1'b1, 32'd100,       32'd3);   // -100 / 7
        run_division(32'd100,       32'hFFFF_FFF9, 1'b1, 32'd5,         32'd5);   // 100 / -7
        run_division(32'hFFFF_FF9C, 32'hFFFF_FFF9, 1'b1, 32'd5,         32'd0);   // -100 / -7
        run_division(32'hFFFF_FF9C, 32'd7,         1'b0, 32'd1,         32'd1);
        run_division(32'hFFFF_FFFF, 32'd1,         1'b0, 32'd0,         32'd3);
        run_division(32'd5,         32'd10,        1'b0, 32'hDEAD_BEEF, 32'h1);
        run_division(32'd0,         32'd12345,     1'b1, 32'h7FFF_FFFF, 32'h2);

        // Divide by zero: q = all ones, r = dividend
        run_division(32'h1234_5678, 32'd0,         1'b0, 32'h1,         32'h1);
        run_division(32'h8765_4321, 32'd0,         1'b1, 32'h1,         32'h1);

        // Signed overflow: q = dividend, r = 0
        run_division(32'h8000_0000, 32'hFFFF_FFFF, 1'b1, 32'h1,         32'h1);
        // Same operands unsigned are an ordinary division
        run_division(32'h8000_0000, 32'hFFFF_FFFF, 1'b0, 32'h1,         32'h1);

        // A divide-by-zero-shaped next instruction must not affect the result
        run_division(32'd1000,      32'd10,        1'b0, 32'd1000,      32'd0);
        run_division(32'h8000_0000, 32'd2,         1'b1, 32'h8000_0000, 32'hFFFF_FFFF);

        // --------------------------------------------------------------------
        // Phase 2: random vectors
        // --------------------------------------------------------------------
        $display("[TB] Phase 2: random vectors");
        for (i = 0; i < 2000; i = i + 1) begin
            run_division($random, $random, i[0], $random, $random);
        end
        // Small divisors exercise long quotients
        for (i = 0; i < 500; i = i + 1) begin
            run_division($random, ($random & 32'hF) + 1, i[0], $random, $random);
        end

        $display("============================================");
        $display(" PASS: %0d  FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" TESTS FAILED");
        $display("============================================");
        $finish;
    end

endmodule
