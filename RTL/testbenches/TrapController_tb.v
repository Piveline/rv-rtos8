`timescale 1ns/1ps
`include "modules/headers/trap.vh"
 
module TrapController_tb;
 
  // ============================================================
  // Signal Declaration
  // ============================================================
  reg         clk;
  reg         clk_enable;
  reg         reset;
 
  // [CHANGED] single pc → 5 pipeline stage PCs
  reg  [31:0] ID_pc;
  reg  [31:0] EX_pc;
  reg  [31:0] EX2_pc;
  reg  [31:0] MEM_pc;
  reg  [31:0] WB_pc;
 
  // [CHANGED] 3-bit → 4-bit to support TIMER_INTERRUPT_IRQ
  reg  [3:0]  trap_status;
  reg  [31:0] csr_read_data;
 
  wire [31:0] trap_target;
  wire        ic_clean;
  wire        debug_mode;
  wire        trap_done;
  wire        csr_write_enable;
  wire [11:0] csr_trap_address;
  wire [31:0] csr_trap_write_data;
 
  // [NEW] added output ports
  wire        misaligned_instruction_flush;
  wire        misaligned_memory_flush;
  wire        pth_done_flush;
  wire        standby_mode;
  wire        mret_executed;
 
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
    .mret_executed                (mret_executed)
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
    $dumpfile("Trap_Controller_tb_result.vcd");
    $dumpvars(0, TrapController_tb);
  end
 
  // ============================================================
  // Monitor
  // ============================================================
  initial begin
    $display("time | th_state | csr_addr | csr_wd       | csr_we | trap_tgt   | standby | ic_clean | debug | trap_done | mret_exec | pth_flush | mi_flush | mm_flush");
    $monitor("%4t |   %b   |   %h   | %h |   %b    | %h |    %b    |    %b     |   %b   |     %b     |     %b     |     %b     |    %b     |    %b",
             $time,
             trap_controller.trap_handle_state,
             csr_trap_address,
             csr_trap_write_data,
             csr_write_enable,
             trap_target,
             standby_mode,
             ic_clean,
             debug_mode,
             trap_done,
             mret_executed,
             pth_done_flush,
             misaligned_instruction_flush,
             misaligned_memory_flush);
  end
 
  // ============================================================
  // Task: advance clock by n edges
  // ============================================================
  task tick;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1)
        @(posedge clk) #1;
    end
  endtask
 
  // ============================================================
  // Task: set all pipeline stage PCs at once
  // ============================================================
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
 
  // ============================================================
  // Testbench
  // ============================================================
  initial begin
    $display("==================== TrapController Test START ====================");
 
    // -- Initialization --
    clk_enable    = 1;
    reset         = 1;
    trap_status   = `TRAP_NONE;
    csr_read_data = 32'h0000_0000;
    set_pc(0, 0, 0, 0, 0);
    tick(2); reset = 0; tick(1);
 
    // ============================================================
    // TEST 1: ECALL
    //   IDLE → MEM_STANDBY → WB_STANDBY → RTRE_STANDBY
    //        → ECALL_MEPC_WRITE(EX_pc→mepc) → WRITE_MEPC(mcause=11)
    //        → WRITE_MCAUSE → READ_MTVEC → GOTO_MTVEC → IDLE
    //
    // Expected:
    //   mepc           = EX_pc = 32'h0000_1100
    //   mcause         = 32'd11
    //   trap_target    = mtvec = 32'h1000_AA00
    //   standby_mode   = 1 (MEM_STANDBY ~ RTRE_STANDBY)
    //   pth_done_flush = 1 (READ_MTVEC, GOTO_MTVEC)
    // ============================================================
    $display("\n--- TEST 1: ECALL ---");
    set_pc(32'h0000_1000, 32'h0000_1100, 32'h0000_10F0, 32'h0000_10E0, 32'h0000_10D0);
    trap_status   = `TRAP_ECALL;
    csr_read_data = 32'h1000_AA00;  // mtvec value (used at READ_MTVEC/GOTO_MTVEC)
    tick(10);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 2: MRET (ECALL return — mepc+4)
    //   IDLE → READ_MEPC → RETURN_MRET → IDLE
    //
    // Expected:
    //   trap_target   = mepc + 4 = 32'h0000_1104
    //   mret_executed = 1 (1-cycle pulse at RETURN_MRET)
    //   is_timer_interrupt = 0 → mepc+4
    // ============================================================
    $display("\n--- TEST 2: MRET (ECALL return, mepc+4) ---");
    trap_status   = `TRAP_MRET;
    csr_read_data = 32'h0000_1100;  // mepc value
    tick(3);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 3: MISALIGNED_INSTRUCTION
    //   IDLE → WRITE_MEPC(MEM_pc→mepc) → WRITE_MCAUSE(mcause=0)
    //        → READ_MTVEC → GOTO_MTVEC → IDLE
    //
    // Expected:
    //   mepc                         = MEM_pc = 32'h0000_2000
    //   mcause                       = 32'd0
    //   trap_target                  = mtvec = 32'h1000_AA00
    //   misaligned_instruction_flush = 1 (READ_MTVEC, GOTO_MTVEC)
    // ============================================================
    $display("\n--- TEST 3: MISALIGNED_INSTRUCTION ---");
    set_pc(32'h0000_2030, 32'h0000_2020, 32'h0000_2010, 32'h0000_2000, 32'h0000_1FF0);
    trap_status   = `TRAP_MISALIGNED_INSTRUCTION;
    csr_read_data = 32'h1000_AA00;
    tick(6);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 4: MRET (MISALIGNED_INSTRUCTION return — mepc+4)
    //
    // Expected:
    //   trap_target   = 32'h0000_2004
    //   mret_executed = 1
    // ============================================================
    $display("\n--- TEST 4: MRET (MISALIGNED_INSTRUCTION return, mepc+4) ---");
    trap_status   = `TRAP_MRET;
    csr_read_data = 32'h0000_2000;
    tick(3);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 5: MISALIGNED_LOAD
    //
    // Expected:
    //   mepc                    = MEM_pc = 32'h0000_3000
    //   mcause                  = 32'd4
    //   misaligned_memory_flush = 1
    // ============================================================
    $display("\n--- TEST 5: MISALIGNED_LOAD ---");
    set_pc(32'h0000_3030, 32'h0000_3020, 32'h0000_3010, 32'h0000_3000, 32'h0000_2FF0);
    trap_status   = `TRAP_MISALIGNED_LOAD;
    csr_read_data = 32'h1000_AA00;
    tick(6);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 6: MISALIGNED_STORE
    //
    // Expected:
    //   mepc                    = MEM_pc = 32'h0000_4000
    //   mcause                  = 32'd6
    //   misaligned_memory_flush = 1
    // ============================================================
    $display("\n--- TEST 6: MISALIGNED_STORE ---");
    set_pc(32'h0000_4030, 32'h0000_4020, 32'h0000_4010, 32'h0000_4000, 32'h0000_3FF0);
    trap_status   = `TRAP_MISALIGNED_STORE;
    csr_read_data = 32'h1000_AA00;
    tick(6);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 7: EBREAK
    //   IDLE → WRITE_MEPC(MEM_pc→mepc) → WRITE_MCAUSE(mcause=3)
    //        → WRITE_MCAUSE: debug_mode_reg=1, trap_done=1 → IDLE
    //
    // Expected:
    //   mepc       = MEM_pc = 32'h0000_BBB0
    //   mcause     = 32'd3
    //   debug_mode = 1 (set after WRITE_MCAUSE)
    // ============================================================
    $display("\n--- TEST 7: EBREAK ---");
    set_pc(32'h0000_BBD0, 32'h0000_BBC0, 32'h0000_BBB8, 32'h0000_BBB0, 32'h0000_BBA0);
    trap_status = `TRAP_EBREAK;
    tick(4);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 8: MRET (EBREAK return — debug_mode=0, mepc+4)
    //
    // Expected:
    //   trap_target   = 32'h0000_BBB4
    //   debug_mode    = 0
    //   mret_executed = 1
    // ============================================================
    $display("\n--- TEST 8: MRET (EBREAK return, debug_mode off) ---");
    trap_status   = `TRAP_MRET;
    csr_read_data = 32'h0000_BBB0;
    tick(3);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 9: TIMER INTERRUPT
    //   IDLE → MEM_STANDBY → WB_STANDBY → RTRE_STANDBY
    //        → ECALL_MEPC_WRITE(EX_pc→mepc) → WRITE_MEPC(mcause=0x8000_0007)
    //        → WRITE_MCAUSE → READ_MTVEC → GOTO_MTVEC → IDLE
    //
    // Expected:
    //   mepc             = EX_pc = 32'h0000_5100
    //   mcause           = 32'h8000_0007
    //   trap_target      = mtvec = 32'h1000_AA00
    //   standby_mode     = 1 (during standby stages)
    //   is_timer_interrupt = 1 (latched at ECALL_MEPC_WRITE)
    // ============================================================
    $display("\n--- TEST 9: TIMER INTERRUPT ---");
    set_pc(32'h0000_5130, 32'h0000_5100, 32'h0000_50F0, 32'h0000_50E0, 32'h0000_50D0);
    trap_status   = `TIMER_INTERRUPT_IRQ;
    csr_read_data = 32'h1000_AA00;
    tick(9);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 10: MRET (TIMER INTERRUPT return — mepc as-is, re-execute)
    //   is_timer_interrupt=1 → trap_target = mepc (not +4)
    //
    // Expected:
    //   trap_target   = 32'h0000_5100 (mepc as-is)
    //   mret_executed = 1
    // ============================================================
    $display("\n--- TEST 10: MRET (TIMER INTERRUPT return, mepc same) ---");
    trap_status   = `TRAP_MRET;
    csr_read_data = 32'h0000_5100;
    tick(3);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 11: FENCE.I
    //
    // Expected:
    //   ic_clean = 1
    // ============================================================
    $display("\n--- TEST 11: FENCE.I ---");
    trap_status = `TRAP_FENCEI;
    tick(1);
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    // TEST 12: clk_enable=0 stall during ECALL → verify FSM holds state
    // ============================================================
    $display("\n--- TEST 12: clk_enable=0 stall during ECALL ---");
    set_pc(32'h0000_6030, 32'h0000_6020, 32'h0000_6010, 32'h0000_6000, 32'h0000_5FF0);
    trap_status  = `TRAP_ECALL;
    csr_read_data = 32'h1000_AA00;
    tick(2);              // enter MEM_STANDBY
    clk_enable = 0;
    tick(3);              // FSM must hold (no state change)
    clk_enable = 1;
    tick(8);              // resume remaining states
    trap_status = `TRAP_NONE;
    tick(1);
 
    // ============================================================
    $display("\n==================== TrapController Test END ====================");
    $finish;
  end
 
endmodule