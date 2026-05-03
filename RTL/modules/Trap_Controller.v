`include "modules/headers/trap.vh"
 
module TrapController #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire clk_enable,
    input wire reset,
    input wire [XLEN-1:0] ID_pc,
    input wire [XLEN-1:0] EX_pc,   // PC saved to mepc for ECALL/TIMER_INTERRUPT
    input wire [XLEN-1:0] EX2_pc,
    input wire [XLEN-1:0] MEM_pc,  // PC saved to mepc for MISALIGNED/EBREAK
    input wire [XLEN-1:0] WB_pc,
    input wire [3:0] trap_status,  // [CHANGED] 3-bit → 4-bit to support TIMER_INTERRUPT_IRQ
    input wire [XLEN-1:0] csr_read_data,
 
    output reg [XLEN-1:0] trap_target,      // jump target: mtvec (handler) or mepc (return)
    output reg ic_clean,                    // instruction cache flush for Zifencei
    output reg debug_mode,                  // debug mode flag: set by EBREAK, cleared by MRET
    output reg csr_write_enable,
    output reg [11:0] csr_trap_address,
    output reg [XLEN-1:0] csr_trap_write_data,
    output reg trap_done,                   // PTH FSM completion flag (0 = stall PC)
    output reg misaligned_instruction_flush,
    output reg misaligned_memory_flush,
    output reg pth_done_flush,
    output reg standby_mode,                // pipeline drain in progress
    output reg mret_executed                // [NEW] 1-cycle pulse when RETURN_MRET completes
);
 
// ============================================================
// FSM States
// ============================================================
localparam  IDLE             = 4'b0000,
            WRITE_MEPC       = 4'b0001,  // actually writes mcause (state name offset by 1 cycle)
            WRITE_MCAUSE     = 4'b0010,  // starts reading mtvec
            READ_MTVEC       = 4'b0011,  // outputs mtvec as trap_target
            READ_MEPC        = 4'b0100,  // reads mepc for MRET return
            GOTO_MTVEC       = 4'b0101,  // holds mtvec, flushes pipeline
            RETURN_MRET      = 4'b0110,  // outputs return address, pulses mret_executed
            MEM_STANDBY      = 4'b0111,  // pipeline drain stage 1
            WB_STANDBY       = 4'b1000,  // pipeline drain stage 2
            RTRE_STANDBY     = 4'b1001,  // pipeline drain stage 3
            ECALL_MEPC_WRITE = 4'b1010;  // saves EX_pc to mepc after pipeline drain
 
// ============================================================
// Internal registers
// ============================================================
reg [3:0] trap_handle_state, next_trap_handle_state;
reg debug_mode_reg;
 
// [NEW] Timer interrupt latch
// Purpose: FSM takes multiple cycles from IDLE to GOTO_MTVEC.
//          During this time, trap_status may change to TRAP_NONE.
//          At MRET time, we need to know if the original trap was a timer interrupt
//          to decide between mepc (timer) and mepc+4 (ECALL).
//          → Latch the value at ECALL_MEPC_WRITE and hold until RETURN_MRET completes.
reg is_timer_interrupt;
 
// ============================================================
// Sequential: FSM state update
// ============================================================
always @(posedge clk or posedge reset) begin
    if (reset) begin
        trap_handle_state  <= IDLE;
        debug_mode_reg     <= 1'b0;
        is_timer_interrupt <= 1'b0;
    end
    else if (clk_enable) begin
        trap_handle_state <= next_trap_handle_state;
 
        // -- is_timer_interrupt latch --
        // Latch at ECALL_MEPC_WRITE because:
        //   - Pipeline is fully drained at this point
        //   - trap_status still holds TIMER_INTERRUPT_IRQ at this cycle
        //   - Latching at IDLE would miss by 1 clock due to state transition
        if (trap_handle_state == ECALL_MEPC_WRITE) begin
            if (trap_status == `TIMER_INTERRUPT_IRQ)
                is_timer_interrupt <= 1'b1;
            else
                is_timer_interrupt <= 1'b0;
        end
        // Clear only after RETURN_MRET: timer interrupt handling fully complete
        if (trap_handle_state == RETURN_MRET) begin
            is_timer_interrupt <= 1'b0;
        end
 
        // -- debug_mode register --
        // EBREAK: set debug_mode at WRITE_MCAUSE
        // MRET:   clear debug_mode at IDLE
        case (trap_status)
            `TRAP_MRET: begin
                if (trap_handle_state == IDLE)
                    debug_mode_reg <= 1'b0;
            end
            `TRAP_EBREAK: begin
                if (trap_handle_state == WRITE_MCAUSE)
                    debug_mode_reg <= 1'b1;
            end
            default: ;
        endcase
    end
end
 
// ============================================================
// debug_mode output
// ============================================================
always @(*) begin
    debug_mode = debug_mode_reg;
end
 
// ============================================================
// Combinational: FSM output and next state logic
// ============================================================
always @(*) begin
    // Default outputs: prevent latches
    ic_clean                     = 1'b0;
    csr_write_enable             = 1'b0;
    csr_trap_address             = 12'b0;
    csr_trap_write_data          = {XLEN{1'b0}};
    trap_target                  = {XLEN{1'b0}};
    trap_done                    = 1'b1;
    misaligned_instruction_flush = 1'b0;
    misaligned_memory_flush      = 1'b0;
    pth_done_flush               = 1'b0;
    standby_mode                 = 1'b0;
    mret_executed                = 1'b0;
    next_trap_handle_state       = IDLE;
 
    // No trap: stay in IDLE
    if (trap_status == `TRAP_NONE) begin
        next_trap_handle_state = IDLE;
 
    // FENCEI: flush instruction cache and return
    end else if (trap_status == `TRAP_FENCEI) begin
        ic_clean               = 1'b1;
        trap_done              = 1'b1;
        next_trap_handle_state = IDLE;
 
    // TIMER_INTERRUPT_IRQ already being processed: block re-entry
    // Without this condition, when FSM returns to IDLE after handling timer interrupt,
    // if trap_status is still TIMER_INTERRUPT_IRQ, FSM would start a second handling.
    // is_timer_interrupt=1 means "already handled" → ignore the signal.
    end else if (trap_status == `TIMER_INTERRUPT_IRQ && is_timer_interrupt &&
                 trap_handle_state == IDLE) begin
        next_trap_handle_state = IDLE;
 
    // All other traps: FSM
    end else begin
        case (trap_handle_state)
 
            // IDLE: decide handling path based on trap type
            IDLE: begin
                if (trap_status == `TRAP_MRET) begin
                    // MRET: read mepc to get return address
                    csr_trap_address       = 12'h341; // mepc
                    trap_done              = 1'b0;
                    next_trap_handle_state = READ_MEPC;
 
                end else if (trap_status == `TRAP_ECALL ||
                             trap_status == `TIMER_INTERRUPT_IRQ) begin
                    // ECALL / TIMER_INTERRUPT: same flow
                    // Both require pipeline drain → mepc save → mcause write → mtvec jump
                    // Differences (mcause value, return address) handled in later states
                    standby_mode           = 1'b1;
                    trap_done              = 1'b0;
                    next_trap_handle_state = MEM_STANDBY;
 
                end else begin
                    // EBREAK, MISALIGNED_*: immediately save MEM_pc to mepc
                    // No standby needed: trap detected at MEM stage already
                    csr_write_enable       = 1'b1;
                    csr_trap_address       = 12'h341; // mepc
                    csr_trap_write_data    = MEM_pc;
                    trap_done              = 1'b0;
                    next_trap_handle_state = WRITE_MEPC;
                end
            end
 
            // Pipeline drain stage 1, 2, 3
            // Wait 3 cycles for in-flight instructions (MEM, WB stages) to complete
            // before saving mepc to ensure correct return address
            MEM_STANDBY: begin
                standby_mode           = 1'b1;
                trap_done              = 1'b0;
                next_trap_handle_state = WB_STANDBY;
            end
 
            WB_STANDBY: begin
                standby_mode           = 1'b1;
                trap_done              = 1'b0;
                next_trap_handle_state = RTRE_STANDBY;
            end
 
            RTRE_STANDBY: begin
                standby_mode           = 1'b1;
                trap_done              = 1'b0;
                next_trap_handle_state = ECALL_MEPC_WRITE;
            end
 
            // Save EX_pc to mepc after pipeline drain
            // EX_pc used because: after standby, the instruction at EX stage
            // is the one that triggered the trap
            ECALL_MEPC_WRITE: begin
                standby_mode           = 1'b0;
                csr_write_enable       = 1'b1;
                csr_trap_address       = 12'h341; // mepc
                csr_trap_write_data    = EX_pc;
                trap_done              = 1'b0;
                next_trap_handle_state = WRITE_MEPC;
            end
 
            // Write mcause (state name is offset by 1 cycle from original design)
            // mcause values (RISC-V spec):
            //   0x80000007 = bit[31]=1(interrupt) + cause=7(Machine Timer)
            //   11 = ECALL from M-mode
            //   3  = EBREAK
            //   4  = Load address misaligned
            //   6  = Store address misaligned
            //   0  = Instruction address misaligned
            // Use is_timer_interrupt latch instead of trap_status
            // because trap_status may already be TRAP_NONE at this point
            WRITE_MEPC: begin
                csr_write_enable    = 1'b1;
                csr_trap_address    = 12'h342; // mcause
                if (is_timer_interrupt)
                    csr_trap_write_data = 32'h8000_0007;
                else if (trap_status == `TRAP_EBREAK)
                    csr_trap_write_data = 32'd3;
                else if (trap_status == `TRAP_ECALL)
                    csr_trap_write_data = 32'd11;
                else if (trap_status == `TRAP_MISALIGNED_LOAD)
                    csr_trap_write_data = 32'd4;
                else if (trap_status == `TRAP_MISALIGNED_STORE)
                    csr_trap_write_data = 32'd6;
                else
                    csr_trap_write_data = 32'd0; // MISALIGNED_INSTRUCTION
                trap_done              = 1'b0;
                next_trap_handle_state = WRITE_MCAUSE;
            end
 
            // EBREAK: enter debug mode and stop FSM
            // Others: start reading mtvec (handler address)
            WRITE_MCAUSE: begin
                if (trap_status == `TRAP_EBREAK) begin
                    trap_done              = 1'b1;
                    next_trap_handle_state = IDLE;
                end else begin
                    csr_write_enable       = 1'b0;
                    csr_trap_address       = 12'h305; // mtvec
                    trap_target            = csr_read_data;
                    trap_done              = 1'b0;
                    next_trap_handle_state = READ_MTVEC;
                end
            end
 
            // Hold mtvec as trap_target for 2 cycles to ensure stable delivery
            READ_MTVEC: begin
                csr_trap_address = 12'h305; // mtvec
                trap_target      = csr_read_data;
                if (trap_status == `TRAP_MISALIGNED_INSTRUCTION)
                    misaligned_instruction_flush = 1'b1;
                else if (trap_status == `TRAP_MISALIGNED_STORE ||
                         trap_status == `TRAP_MISALIGNED_LOAD)
                    misaligned_memory_flush = 1'b1;
                trap_done              = 1'b1;
                pth_done_flush         = 1'b1;
                next_trap_handle_state = GOTO_MTVEC;
            end
 
            GOTO_MTVEC: begin
                csr_trap_address = 12'h305; // mtvec
                trap_target      = csr_read_data;
                if (trap_status == `TRAP_MISALIGNED_INSTRUCTION)
                    misaligned_instruction_flush = 1'b1;
                else if (trap_status == `TRAP_MISALIGNED_STORE ||
                         trap_status == `TRAP_MISALIGNED_LOAD)
                    misaligned_memory_flush = 1'b1;
                trap_done              = 1'b1;
                pth_done_flush         = 1'b1;
                next_trap_handle_state = IDLE;
            end
 
            // MRET return address decision:
            //   Timer interrupt → mepc as-is (re-execute interrupted instruction)
            //   ECALL / others  → mepc + 4   (advance to next instruction)
            // {csr_read_data[XLEN-1:2], 2'b0}: force 4-byte alignment to prevent misaligned fetch
            READ_MEPC: begin
                csr_trap_address = 12'h341; // mepc
                if (is_timer_interrupt)
                    trap_target = {csr_read_data[XLEN-1:2], 2'b0};      // mepc as-is
                else
                    trap_target = {csr_read_data[XLEN-1:2], 2'b0} + 4;  // mepc + 4
                trap_done              = 1'b0;
                next_trap_handle_state = RETURN_MRET;
            end
 
            RETURN_MRET: begin
                csr_trap_address = 12'h341; // mepc
                if (is_timer_interrupt)
                    trap_target = {csr_read_data[XLEN-1:2], 2'b0};      // mepc as-is
                else
                    trap_target = {csr_read_data[XLEN-1:2], 2'b0} + 4;  // mepc + 4
                trap_done              = 1'b1;
                mret_executed          = 1'b1; // [NEW] 1-cycle pulse: MRET complete
                next_trap_handle_state = IDLE;
            end
 
            default: begin
                next_trap_handle_state = IDLE;
            end
 
        endcase
    end
end
 
endmodule