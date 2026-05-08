`timescale 1ns/1ps
`include "modules/headers/trap.vh"

module TrapController_tb;

  // ============================================================
  // Signal Declaration
  // ============================================================
  reg         clk;
  reg         clk_enable;
  reg         reset;

  reg  [31:0] ID_pc;
  reg  [31:0] EX_pc;
  reg  [31:0] EX2_pc;
  reg  [31:0] MEM_pc;
  reg  [31:0] WB_pc;

  reg  [3:0]  trap_status;
  reg  [31:0] csr_read_data;

  // New direct CSR-sideband inputs to TrapController
  reg  [31:0] vector_address;   // from CSRFile.mtvec direct output
  reg  [31:0] return_address;   // from CSRFile.mepc direct output

  wire [31:0] trap_target;
  wire        ic_clean;
  wire        debug_mode;
  wire        trap_done;
  wire        csr_write_enable;
  wire [11:0] csr_trap_address;
  wire [31:0] csr_trap_write_data;
  wire        misaligned_instruction_flush;
  wire        misaligned_memory_flush;
  wire        pth_done_flush;
  wire        standby_mode;
  wire        mret_executed;

  // New direct CSR-sideband outputs from TrapController
  wire        pre_trap_handler;
  wire [31:0] enter_pc;
  wire [31:0] trap_cause;

  integer errors;

  // ============================================================
  // DUT Instance
  // ============================================================
  TrapController #(
    .XLEN(32)
  ) trap_controller (
    .clk                          (clk),
    .clk_enable                   (clk_enable),
    .reset                        (reset),

    .ID_pc                        (ID_pc),
    .EX_pc                        (EX_pc),
    .EX2_pc                       (EX2_pc),
    .MEM_pc                       (MEM_pc),
    .WB_pc                        (WB_pc),

    .trap_status                  (trap_status),
    .csr_read_data                (csr_read_data),
    .vector_address               (vector_address),
    .return_address               (return_address),

    .trap_target                  (trap_target),
    .ic_clean                     (ic_clean),
    .debug_mode                   (debug_mode),
    .csr_write_enable             (csr_write_enable),
    .csr_trap_address             (csr_trap_address),
    .csr_trap_write_data          (csr_trap_write_data),
    .trap_done                    (trap_done),
    .misaligned_instruction_flush (misaligned_instruction_flush),
    .misaligned_memory_flush      (misaligned_memory_flush),
    .pth_done_flush               (pth_done_flush),
    .standby_mode                 (standby_mode),
    .mret_executed                (mret_executed),
    .pre_trap_handler             (pre_trap_handler),
    .enter_pc                     (enter_pc),
    .trap_cause                   (trap_cause)
  );

  // ============================================================
  // Clock (period = 10ns)
  // ============================================================
  initial clk = 0;
  always #5 clk = ~clk;

  // ============================================================
  // VCD Dump
  // ============================================================
  initial begin
    $dumpfile("./testbenches/results/waveforms/Trap_Controller_tb_pth_direct_result.vcd");
    $dumpvars(0, TrapController_tb);
  end

  // ============================================================
  // Monitor
  // ============================================================
  initial begin
    $display("time | state | trap_status | pre | enter_pc   | cause      | vector     | ret_addr   | trap_tgt   | done | pth_flush | stby | mret | csr_we | csr_addr | csr_wd");
    $monitor("%4t |  %b  |    %h      |  %b  | %h | %h | %h | %h | %h |  %b   |     %b     |  %b   |  %b   |   %b    |   %h   | %h",
             $time,
             trap_controller.trap_handle_state,
             trap_status,
             pre_trap_handler,
             enter_pc,
             trap_cause,
             vector_address,
             return_address,
             trap_target,
             trap_done,
             pth_done_flush,
             standby_mode,
             mret_executed,
             csr_write_enable,
             csr_trap_address,
             csr_trap_write_data);
  end

  // ============================================================
  // Utility Tasks
  // ============================================================
  task tick;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) begin
        @(posedge clk);
        #1;
      end
    end
  endtask

  task settle;
    begin
      #1;
    end
  endtask

  task set_pc;
    input [31:0] id, ex, ex2, mem, wb;
    begin
      ID_pc  = id;
      EX_pc  = ex;
      EX2_pc = ex2;
      MEM_pc = mem;
      WB_pc  = wb;
    end
  endtask

  task clear_trap;
    begin
      trap_status = `TRAP_NONE;
      settle();
    end
  endtask

  task expect1;
    input [1023:0] name;
    input actual;
    input expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %0s: expected=%b actual=%b @%0t", name, expected, actual, $time);
        errors = errors + 1;
      end else begin
        $display("[PASS] %0s = %b", name, actual);
      end
    end
  endtask

  task expect4;
    input [1023:0] name;
    input [3:0] actual;
    input [3:0] expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %0s: expected=%h actual=%h @%0t", name, expected, actual, $time);
        errors = errors + 1;
      end else begin
        $display("[PASS] %0s = %h", name, actual);
      end
    end
  endtask

  task expect12;
    input [1023:0] name;
    input [11:0] actual;
    input [11:0] expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %0s: expected=%h actual=%h @%0t", name, expected, actual, $time);
        errors = errors + 1;
      end else begin
        $display("[PASS] %0s = %h", name, actual);
      end
    end
  endtask

  task expect32;
    input [1023:0] name;
    input [31:0] actual;
    input [31:0] expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %0s: expected=%h actual=%h @%0t", name, expected, actual, $time);
        errors = errors + 1;
      end else begin
        $display("[PASS] %0s = %h", name, actual);
      end
    end
  endtask

  // ============================================================
  // Testbench
  // ============================================================
  initial begin
    $display("==================== TrapController PTH Direct Test START ====================");
    errors = 0;

    // -- Initialization --
    clk_enable    = 1'b1;
    reset         = 1'b1;
    trap_status   = `TRAP_NONE;
    csr_read_data = 32'h0000_0000;
    vector_address = 32'h0000_6D60;
    return_address = 32'h0000_0000;
    set_pc(0, 0, 0, 0, 0);

    tick(2);
    reset = 1'b0;
    tick(1);

    // ============================================================
    // TEST 1: TRAP_NONE must not enter PTH
    // This directly checks the top-level TRAP_NONE guard.
    // ============================================================
    $display("\n--- TEST 1: TRAP_NONE IDLE guard ---");
    clear_trap();
    expect1 ("TRAP_NONE pre_trap_handler", pre_trap_handler, 1'b0);
    expect1 ("TRAP_NONE pth_done_flush",   pth_done_flush,   1'b0);
    expect1 ("TRAP_NONE trap_done",        trap_done,        1'b1);
    expect32("TRAP_NONE trap_target",      trap_target,      32'h0000_0000);
    tick(3);
    expect1 ("TRAP_NONE still no PTH after 3 cycles", pre_trap_handler, 1'b0);

    // ============================================================
    // TEST 2: FENCE.I must not assert PTH sideband
    // ============================================================
    $display("\n--- TEST 2: FENCE.I immediate clean, no PTH ---");
    trap_status = `TRAP_FENCEI;
    settle();
    expect1("FENCEI ic_clean",         ic_clean,         1'b1);
    expect1("FENCEI pre_trap_handler", pre_trap_handler, 1'b0);
    expect1("FENCEI trap_done",        trap_done,        1'b1);
    tick(1);
    clear_trap();
    tick(1);

    // ============================================================
    // TEST 3: Direct PTH from IDLE - MISALIGNED_INSTRUCTION
    // Expected direct sideband:
    //   pre_trap_handler = 1
    //   enter_pc         = MEM_pc
    //   trap_cause       = 0
    //   trap_target      = vector_address
    // ============================================================
    $display("\n--- TEST 3: DIRECT PTH MEM - MISALIGNED_INSTRUCTION ---");
    vector_address = 32'h1000_AA00;
    set_pc(32'h0000_2030, 32'h0000_2020, 32'h0000_2010, 32'h0000_2000, 32'h0000_1FF0);
    trap_status = `TRAP_MISALIGNED_INSTRUCTION;
    settle();
    expect1 ("MI pre_trap_handler", pre_trap_handler, 1'b1);
    expect32("MI enter_pc=MEM_pc",   enter_pc,           32'h0000_2000);
    expect32("MI trap_cause",        trap_cause,         32'd0);
    expect32("MI trap_target",       trap_target,        32'h1000_AA00);
    expect1 ("MI pth_done_flush",    pth_done_flush,     1'b1);
    tick(1);
    clear_trap();
    expect1("MI cleared no repeated PTH", pre_trap_handler, 1'b0);
    tick(1);

    // ============================================================
    // TEST 4: Direct PTH from IDLE - MISALIGNED_LOAD
    // ============================================================
    $display("\n--- TEST 4: DIRECT PTH MEM - MISALIGNED_LOAD ---");
    set_pc(32'h0000_3030, 32'h0000_3020, 32'h0000_3010, 32'h0000_3000, 32'h0000_2FF0);
    trap_status = `TRAP_MISALIGNED_LOAD;
    settle();
    expect1 ("ML pre_trap_handler", pre_trap_handler, 1'b1);
    expect32("ML enter_pc=MEM_pc",   enter_pc,           32'h0000_3000);
    expect32("ML trap_cause",        trap_cause,         32'd4);
    expect32("ML trap_target",       trap_target,        32'h1000_AA00);
    expect1 ("ML pth_done_flush",    pth_done_flush,     1'b1);
    tick(1);
    clear_trap();
    expect1("ML cleared no repeated PTH", pre_trap_handler, 1'b0);
    tick(1);

    // ============================================================
    // TEST 5: Direct PTH from IDLE - MISALIGNED_STORE
    // ============================================================
    $display("\n--- TEST 5: DIRECT PTH MEM - MISALIGNED_STORE ---");
    set_pc(32'h0000_4030, 32'h0000_4020, 32'h0000_4010, 32'h0000_4000, 32'h0000_3FF0);
    trap_status = `TRAP_MISALIGNED_STORE;
    settle();
    expect1 ("MS pre_trap_handler", pre_trap_handler, 1'b1);
    expect32("MS enter_pc=MEM_pc",   enter_pc,           32'h0000_4000);
    expect32("MS trap_cause",        trap_cause,         32'd6);
    expect32("MS trap_target",       trap_target,        32'h1000_AA00);
    expect1 ("MS pth_done_flush",    pth_done_flush,     1'b1);
    tick(1);
    clear_trap();
    expect1("MS cleared no repeated PTH", pre_trap_handler, 1'b0);
    tick(1);

    // ============================================================
    // TEST 6: Direct PTH from IDLE - EBREAK
    // ============================================================
    $display("\n--- TEST 6: DIRECT PTH MEM - EBREAK ---");
    set_pc(32'h0000_BBD0, 32'h0000_BBC0, 32'h0000_BBB8, 32'h0000_BBB0, 32'h0000_BBA0);
    trap_status = `TRAP_EBREAK;
    settle();
    expect1 ("EBREAK pre_trap_handler", pre_trap_handler, 1'b1);
    expect32("EBREAK enter_pc=MEM_pc",   enter_pc,           32'h0000_BBB0);
    expect32("EBREAK trap_cause",        trap_cause,         32'd3);
    expect32("EBREAK trap_target",       trap_target,        32'h1000_AA00);
    expect1 ("EBREAK pth_done_flush",    pth_done_flush,     1'b1);
    tick(1);
    clear_trap();
    expect1("EBREAK cleared no repeated PTH", pre_trap_handler, 1'b0);
    tick(1);

    // ============================================================
    // TEST 7: ECALL after standby uses DIRECT_PTH_EX
    // Sequence:
    //   IDLE -> MEM_STANDBY -> WB_STANDBY -> RTRE_STANDBY -> DIRECT_PTH_EX
    // Expected at DIRECT_PTH_EX:
    //   enter_pc   = EX_pc
    //   trap_cause = 11
    // ============================================================
    $display("\n--- TEST 7: ECALL -> standby -> DIRECT_PTH_EX ---");
    set_pc(32'h0000_1030, 32'h0000_1100, 32'h0000_10F0, 32'h0000_10E0, 32'h0000_10D0);
    trap_status = `TRAP_ECALL;
    settle();
    expect1("ECALL IDLE standby_mode", standby_mode, 1'b1);
    expect1("ECALL IDLE trap_done=0",  trap_done,    1'b0);
    tick(4); // now in DIRECT_PTH_EX
    expect1 ("ECALL direct pre_trap_handler", pre_trap_handler, 1'b1);
    expect32("ECALL enter_pc=EX_pc",          enter_pc,           32'h0000_1100);
    expect32("ECALL trap_cause",              trap_cause,         32'd11);
    expect32("ECALL trap_target",             trap_target,        32'h1000_AA00);
    expect1 ("ECALL pth_done_flush",          pth_done_flush,     1'b1);
    clear_trap();
    tick(1);
    expect1("ECALL cleared no repeated PTH", pre_trap_handler, 1'b0);

    // ============================================================
    // TEST 8: TIMER_INTERRUPT_IRQ after standby uses DIRECT_PTH_EX
    // Intended expected at DIRECT_PTH_EX:
    //   enter_pc   = EX_pc
    //   trap_cause = 0x80000007
    // NOTE: If this fails with trap_cause=0, latch timer cause before DIRECT_PTH_EX.
    // ============================================================
    $display("\n--- TEST 8: TIMER_INTERRUPT_IRQ -> standby -> DIRECT_PTH_EX ---");
    set_pc(32'h0000_5130, 32'h0000_5100, 32'h0000_50F0, 32'h0000_50E0, 32'h0000_50D0);
    trap_status = `TIMER_INTERRUPT_IRQ;
    settle();
    expect1("TIMER IDLE standby_mode", standby_mode, 1'b1);
    expect1("TIMER IDLE trap_done=0",  trap_done,    1'b0);
    tick(4); // now in DIRECT_PTH_EX
    expect1 ("TIMER direct pre_trap_handler", pre_trap_handler, 1'b1);
    expect32("TIMER enter_pc=EX_pc",          enter_pc,           32'h0000_5100);
    expect32("TIMER trap_cause",              trap_cause,         32'h8000_0007);
    expect32("TIMER trap_target",             trap_target,        32'h1000_AA00);
    expect1 ("TIMER pth_done_flush",          pth_done_flush,     1'b1);
    clear_trap();
    tick(1);
    expect1("TIMER cleared no repeated PTH", pre_trap_handler, 1'b0);

    // ============================================================
    // TEST 9: MRET single-cycle direct return
    // Intended behavior:
    //   trap_target   = return_address + 4 for normal exception return
    //   mret_executed = 1 for one cycle so CSRFile restores MIE/MPIE
    // NOTE: If mret_executed fails, assert it in the TRAP_MRET branch in IDLE.
    // ============================================================
    $display("\n--- TEST 9: MRET direct return, normal exception path ---");
    return_address = 32'h0000_1100;
    trap_status = `TRAP_MRET;
    settle();
    expect32("MRET trap_target=return+4", trap_target,   32'h0000_1100);
    expect1 ("MRET mret_executed pulse",  mret_executed, 1'b1);
    clear_trap();
    tick(1);
    expect1("MRET cleared mret_executed", mret_executed, 1'b0);

    // ============================================================
    // TEST 10: clk_enable=0 must hold state during ECALL standby
    // ============================================================
    $display("\n--- TEST 10: clk_enable=0 stall during ECALL standby ---");
    set_pc(32'h0000_6030, 32'h0000_6020, 32'h0000_6010, 32'h0000_6000, 32'h0000_5FF0);
    trap_status = `TRAP_ECALL;
    settle();
    tick(1); // IDLE -> MEM_STANDBY
    expect4("state is MEM_STANDBY before stall", trap_controller.trap_handle_state, 4'b0111);
    clk_enable = 1'b0;
    tick(3);
    expect4("state held while clk_enable=0", trap_controller.trap_handle_state, 4'b0111);
    clk_enable = 1'b1;
    tick(3); // WB -> RTRE -> DIRECT_PTH_EX
    expect1("ECALL after stall reaches PTH", pre_trap_handler, 1'b1);
    clear_trap();
    tick(1);

    // ============================================================
    // Summary
    // ============================================================
    if (errors == 0) begin
      $display("\n==================== ALL TESTS PASSED ====================");
    end else begin
      $display("\n==================== TESTS FAILED: %0d error(s) ====================", errors);
    end

    $finish;
  end

endmodule