`timescale 1ns / 1ps

module Divider_DWORD_tb;
    reg clk;
    reg clk_enable;
    reg reset;
    reg division_start;
    reg is_signed;
    reg [63:0] dividend;
    reg [63:0] divisor;

    wire [63:0] quotient;
    wire [63:0] remainder;
    wire busy;

    integer test_count;
    integer pass_count;
    integer fail_count;
    integer i;

    Divider_DWORD #(.XLEN(64)) divider_dword (
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
    function [127:0] reference_div;   // {quotient, remainder}
        input [63:0] a;
        input [63:0] b;
        input s;
        begin
            if (b == 64'b0)
                reference_div = {64'hFFFF_FFFF_FFFF_FFFF, a};
            else if (s && a == 64'h8000_0000_0000_0000 && b == 64'hFFFF_FFFF_FFFF_FFFF)
                reference_div = {a, 64'b0};
            else if (s)
                reference_div = {$signed(a) / $signed(b), $signed(a) % $signed(b)};
            else
                reference_div = {a / b, a % b};
        end
    endfunction

    task run_division;
        input [63:0] a;
        input [63:0] b;
        input s;
        input [63:0] next_a;    // operands of the following instruction
        input [63:0] next_b;
        reg [127:0] expected;
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
            while (busy && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            test_count = test_count + 1;

            if (busy) begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %s | test: 0x%016h / 0x%016h | expected: q=0x%016h r=0x%016h | actual: busy never deasserted",
                         test_count, s ? "signed  " : "unsigned", a, b,
                         expected[127:64], expected[63:0]);
            end
            else if ({quotient, remainder} !== expected) begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %s | test: 0x%016h / 0x%016h | expected: q=0x%016h r=0x%016h | actual: q=0x%016h r=0x%016h",
                         test_count, s ? "signed  " : "unsigned", a, b,
                         expected[127:64], expected[63:0], quotient, remainder);
            end
            else begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %s | test: 0x%016h / 0x%016h | expected: q=0x%016h r=0x%016h | actual: q=0x%016h r=0x%016h",
                         test_count, s ? "signed  " : "unsigned", a, b,
                         expected[127:64], expected[63:0], quotient, remainder);
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
        dividend       = 64'b0;
        divisor        = 64'b0;

        repeat (3) @(negedge clk);
        reset = 1'b0;

        $display("============================================");
        $display(" Divider_DWORD Testbench");
        $display("============================================");

        // --------------------------------------------------------------------
        // Phase 1: directed vectors
        // --------------------------------------------------------------------
        $display("[TB] Phase 1: directed vectors");

        // Same shape as the Divider_WORD failure: 0x28/0x11 with a different
        // dividend presented on the following cycle
        run_division(64'h28, 64'h11, 1'b0, 64'h1000_1554, 64'h11);
        run_division(64'h28, 64'h11, 1'b1, 64'h1000_1554, 64'h11);

        run_division(64'd100, 64'd7, 1'b0, 64'd0, 64'd0);
        run_division(64'd100, 64'd7, 1'b1, 64'hFFFF_FFFF_FFFF_FFFF, 64'h1);
        run_division(64'hFFFF_FFFF_FFFF_FF9C, 64'd7,                  1'b1, 64'd100, 64'd3);   // -100 / 7
        run_division(64'd100,                  64'hFFFF_FFFF_FFFF_FFF9, 1'b1, 64'd5,   64'd5);   // 100 / -7
        run_division(64'hFFFF_FFFF_FFFF_FF9C, 64'hFFFF_FFFF_FFFF_FFF9, 1'b1, 64'd5,   64'd0);   // -100 / -7
        run_division(64'hFFFF_FFFF_FFFF_FF9C, 64'd7,                  1'b0, 64'd1,   64'd1);
        run_division(64'hFFFF_FFFF_FFFF_FFFF, 64'd1,                  1'b0, 64'd0,   64'd3);
        run_division(64'd5,                    64'd10,                 1'b0, 64'hDEAD_BEEF_CAFE_F00D, 64'h1);
        run_division(64'd0,                    64'd12345,              1'b1, 64'h7FFF_FFFF_FFFF_FFFF, 64'h2);

        // Operands wider than 32 bits
        run_division(64'h0123_4567_89AB_CDEF, 64'h0000_0000_0001_0000, 1'b0, 64'h1, 64'h1);
        run_division(64'hFEDC_BA98_7654_3210, 64'h0000_0001_0000_0001, 1'b0, 64'h1, 64'h1);
        run_division(64'hFEDC_BA98_7654_3210, 64'h0000_0001_0000_0001, 1'b1, 64'h1, 64'h1);
        run_division(64'h7FFF_FFFF_FFFF_FFFF, 64'h8000_0000_0000_0000, 1'b0, 64'h1, 64'h1);
        run_division(64'h7FFF_FFFF_FFFF_FFFF, 64'h8000_0000_0000_0000, 1'b1, 64'h1, 64'h1);

        // Divide by zero: q = all ones, r = dividend
        run_division(64'h1234_5678_9ABC_DEF0, 64'd0, 1'b0, 64'h1, 64'h1);
        run_division(64'h8765_4321_0FED_CBA9, 64'd0, 1'b1, 64'h1, 64'h1);

        // Signed overflow: q = dividend, r = 0
        run_division(64'h8000_0000_0000_0000, 64'hFFFF_FFFF_FFFF_FFFF, 1'b1, 64'h1, 64'h1);
        // Same operands unsigned are an ordinary division
        run_division(64'h8000_0000_0000_0000, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 64'h1, 64'h1);

        // A divide-by-zero-shaped next instruction must not affect the result
        run_division(64'd1000, 64'd10, 1'b0, 64'd1000, 64'd0);
        run_division(64'h8000_0000_0000_0000, 64'd2, 1'b1,
                     64'h8000_0000_0000_0000, 64'hFFFF_FFFF_FFFF_FFFF);

        // --------------------------------------------------------------------
        // Phase 2: random vectors
        // --------------------------------------------------------------------
        $display("[TB] Phase 2: random vectors");
        for (i = 0; i < 2000; i = i + 1) begin
            run_division({$random, $random}, {$random, $random}, i[0],
                         {$random, $random}, {$random, $random});
        end
        // 32-bit divisors exercise long quotients
        for (i = 0; i < 500; i = i + 1) begin
            run_division({$random, $random}, {32'b0, $random}, i[0],
                         {$random, $random}, {$random, $random});
        end
        // Small divisors
        for (i = 0; i < 500; i = i + 1) begin
            run_division({$random, $random}, ({32'b0, $random} & 64'hF) + 64'd1, i[0],
                         {$random, $random}, {$random, $random});
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
