`timescale 1ns / 1ps

module IF_IO_Register_tb;
    parameter XLEN = 32;

    localparam [31:0] NOP = 32'h0000_0013;

    localparam EXP_ADMIT  = 0;   // IF instruction enters IO
    localparam EXP_SQUASH = 1;   // IO receives a NOP bubble
    localparam EXP_HOLD   = 2;   // IO keeps its previous contents

    reg clk;
    reg clk_enable;
    reg flush;
    reg IF_IO_stall;
    reg branch_estimation;
    reg jump;
    reg [6:0] ID_opcode;
    reg [6:0] ID_funct7;
    reg [6:0] EX2_opcode;
    reg load_use_hazard;
    reg exr_data_stall;
    reg branch_prediction_miss;
    reg [XLEN-1:0] branch_target;

    reg [XLEN-1:0] IF_pc;
    reg [XLEN-1:0] IF_pc_plus_4;
    reg [31:0] IF_instruction;

    wire [XLEN-1:0] IO_pc;
    wire [XLEN-1:0] IO_pc_plus_4;
    wire [31:0] IO_instruction;

    integer test_count;
    integer pass_count;
    integer fail_count;

    IF_IO_Register #(.XLEN(XLEN)) if_io_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(flush),
        .IF_IO_stall(IF_IO_stall),
        .branch_estimation(branch_estimation),
        .jump(jump),
        .ID_opcode(ID_opcode),
        .ID_funct7(ID_funct7),
        .EX2_opcode(EX2_opcode),
        .load_use_hazard(load_use_hazard),
        .exr_data_stall(exr_data_stall),
        .branch_prediction_miss(branch_prediction_miss),
        .branch_target(branch_target),

        .IF_pc(IF_pc),
        .IF_pc_plus_4(IF_pc_plus_4),
        .IF_instruction(IF_instruction),

        .IO_pc(IO_pc),
        .IO_pc_plus_4(IO_pc_plus_4),
        .IO_instruction(IO_instruction)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Unique, recognisable encoding per fetch address
    function [31:0] inst_of;
        input [XLEN-1:0] pc;
        begin
            inst_of = 32'hC0DE_0000 | pc[15:0];
        end
    endfunction

    // Control inputs return to idle after every cycle
    task idle_controls;
        begin
            flush                  = 1'b0;
            IF_IO_stall            = 1'b0;
            branch_estimation      = 1'b0;
            jump                   = 1'b0;
            ID_opcode              = 7'b0010011;   // OP-IMM, not an M-extension op
            ID_funct7              = 7'b0;
            EX2_opcode             = 7'b0010011;   // not a store
            load_use_hazard        = 1'b0;
            exr_data_stall         = 1'b0;
            branch_prediction_miss = 1'b0;
        end
    endtask

    // Present `pc` in IF with the controls already set, clock once and check IO
    task cycle;
        input [8*44-1:0] name;
        input [XLEN-1:0] pc;
        input integer exp;
        reg [XLEN-1:0] exp_pc;
        reg [XLEN-1:0] exp_pc_plus_4;
        reg [31:0] exp_inst;
        begin
            IF_pc          = pc;
            IF_pc_plus_4   = pc + 4;
            IF_instruction = inst_of(pc);

            case (exp)
                EXP_ADMIT: begin
                    exp_pc = pc; exp_pc_plus_4 = pc + 4; exp_inst = inst_of(pc);
                end
                EXP_SQUASH: begin
                    exp_pc = {XLEN{1'b0}}; exp_pc_plus_4 = {XLEN{1'b0}}; exp_inst = NOP;
                end
                default: begin
                    exp_pc = IO_pc; exp_pc_plus_4 = IO_pc_plus_4; exp_inst = IO_instruction;
                end
            endcase

            @(posedge clk);
            #1;

            test_count = test_count + 1;
            if (IO_pc === exp_pc && IO_pc_plus_4 === exp_pc_plus_4 && IO_instruction === exp_inst) begin
                pass_count = pass_count + 1;
                $display("[PASS] #%04d %0s | test: IF_pc=0x%h | expected: IO_pc=0x%h IO_inst=0x%h | actual: IO_pc=0x%h IO_inst=0x%h",
                         test_count, name, pc, exp_pc, exp_inst, IO_pc, IO_instruction);
            end
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] #%04d %0s | test: IF_pc=0x%h | expected: IO_pc=0x%h IO_inst=0x%h | actual: IO_pc=0x%h IO_inst=0x%h",
                         test_count, name, pc, exp_pc, exp_inst, IO_pc, IO_instruction);
            end

            idle_controls;
        end
    endtask

    initial begin
        test_count    = 0;
        pass_count    = 0;
        fail_count    = 0;
        clk_enable    = 1'b1;
        branch_target = {XLEN{1'b0}};
        IF_pc          = {XLEN{1'b0}};
        IF_pc_plus_4   = {XLEN{1'b0}};
        IF_instruction = NOP;
        idle_controls;

        $display("============================================");
        $display(" IF_IO_Register Testbench (XLEN=%0d)", XLEN);
        $display("============================================");

        // The register has no reset; one flush brings its internal state to
        // a known value, as the first redirect does in the pipeline.
        @(negedge clk);
        flush = 1'b1;
        @(posedge clk); #1;
        idle_controls;
        @(posedge clk); #1;

        // --------------------------------------------------------------------
        $display("[TB] 1. Pass-through, stall and flush");
        // --------------------------------------------------------------------
        cycle("pass-through",                  'h100, EXP_ADMIT);
        cycle("pass-through",                  'h104, EXP_ADMIT);
        IF_IO_stall = 1'b1;
        cycle("IF_IO_stall holds IO",          'h108, EXP_HOLD);
        cycle("stall released",                'h108, EXP_ADMIT);
        flush = 1'b1;
        cycle("flush",                         'h10C, EXP_SQUASH);
        cycle("flush shadow (flush_reg)",      'h110, EXP_SQUASH);
        cycle("after flush",                   'h114, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 2. Predicted-taken branch, 2-deep shadow");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h200;
        cycle("prediction, wrong path",        'h118, EXP_SQUASH);
        cycle("shadow 1, wrong path",          'h11C, EXP_SQUASH);
        cycle("branch target",                 'h200, EXP_ADMIT);
        cycle("after target",                  'h204, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 3. Predicted-taken branch, 3-deep shadow");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h300;
        cycle("prediction, wrong path",        'h208, EXP_SQUASH);
        cycle("shadow 1, wrong path",          'h20C, EXP_SQUASH);
        cycle("shadow 2, wrong path",          'h210, EXP_SQUASH);
        cycle("branch target",                 'h300, EXP_ADMIT);
        cycle("after target",                  'h304, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 4. Shadow extended by exr_data_stall");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h400;
        cycle("prediction, wrong path",        'h308, EXP_SQUASH);
        IF_IO_stall = 1'b1; exr_data_stall = 1'b1;
        cycle("exr_data_stall bubble",         'h30C, EXP_SQUASH);
        cycle("stall released, wrong path",    'h30C, EXP_SQUASH);
        cycle("branch target",                 'h400, EXP_ADMIT);
        cycle("after target",                  'h404, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 5. Shadow extended by IF_IO_stall");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h500;
        cycle("prediction, wrong path",        'h408, EXP_SQUASH);
        IF_IO_stall = 1'b1;
        cycle("stalled",                       'h40C, EXP_HOLD);
        cycle("shadow 1, wrong path",          'h40C, EXP_SQUASH);
        IF_IO_stall = 1'b1;
        cycle("stalled",                       'h410, EXP_HOLD);
        cycle("shadow 2, wrong path",          'h410, EXP_SQUASH);
        cycle("branch target",                 'h500, EXP_ADMIT);
        cycle("after target",                  'h504, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 6. Load-use hazard inside the shadow");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h600;
        cycle("prediction, wrong path",        'h508, EXP_SQUASH);
        load_use_hazard = 1'b1;
        cycle("shadow 1 + load-use",           'h50C, EXP_SQUASH);
        cycle("shadow 2, wrong path",          'h510, EXP_SQUASH);
        cycle("branch target not squashed",    'h600, EXP_ADMIT);
        cycle("after target",                  'h604, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 7. Short backward branch (loop head)");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h126C;
        cycle("prediction, wrong path",        'h1274, EXP_SQUASH);
        cycle("shadow 1, wrong path",          'h1278, EXP_SQUASH);
        cycle("loop head",                     'h126C, EXP_ADMIT);
        cycle("loop body",                     'h1270, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 8. Misprediction ends the shadow");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h800;
        cycle("prediction, wrong path",        'h1308, EXP_SQUASH);
        cycle("shadow 1, wrong path",          'h130C, EXP_SQUASH);
        branch_prediction_miss = 1'b1; flush = 1'b1;
        cycle("misprediction flush",           'h1310, EXP_SQUASH);
        cycle("flush shadow (flush_reg)",      'h900, EXP_SQUASH);
        cycle("correct path admitted",         'h904, EXP_ADMIT);
        cycle("correct path admitted",         'h908, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 9. branch_prediction_miss alone clears the shadow");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'hA00;
        cycle("prediction, wrong path",        'h910, EXP_SQUASH);
        cycle("shadow 1, wrong path",          'h914, EXP_SQUASH);
        branch_prediction_miss = 1'b1;
        cycle("miss, still wrong path",        'h918, EXP_SQUASH);
        cycle("non-target admitted",           'hB00, EXP_ADMIT);
        cycle("non-target admitted",           'hB04, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 10. Misprediction and prediction on the same cycle");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'hC00;
        branch_prediction_miss = 1'b1; flush = 1'b1;
        cycle("miss + prediction",             'hB08, EXP_SQUASH);
        cycle("flush shadow (flush_reg)",      'hB0C, EXP_SQUASH);
        cycle("miss target, no starvation",    'hD00, EXP_ADMIT);
        cycle("no starvation",                 'hD04, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 11. Jump ends the shadow");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'hE00;
        cycle("prediction, wrong path",        'hD08, EXP_SQUASH);
        jump = 1'b1;
        cycle("jump",                          'hD0C, EXP_SQUASH);
        cycle("jump shadow (flush_reg)",       'hD10, EXP_SQUASH);
        cycle("jump target admitted",          'hF00, EXP_ADMIT);
        cycle("after jump target",             'hF04, EXP_ADMIT);

        // --------------------------------------------------------------------
        $display("[TB] 12. Prediction while an M-extension op is in ID");
        // --------------------------------------------------------------------
        branch_estimation = 1'b1; branch_target = 'h1000;
        ID_opcode = 7'b0110011; ID_funct7 = 7'b000_0001;
        cycle("prediction ignored (M-ext)",    'hF08, EXP_ADMIT);
        cycle("no shadow opened",              'hF0C, EXP_ADMIT);

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
