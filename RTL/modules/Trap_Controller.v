`include "modules/headers/trap.vh"
 
module TrapController #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire clk_enable,
    input wire reset,

    input wire [XLEN-1:0] IF_pc,
    input wire [XLEN-1:0] IO_pc,
    input wire [XLEN-1:0] ID_pc,
    input wire [XLEN-1:0] EXR_pc,
    input wire [XLEN-1:0] EX_pc,
    input wire [XLEN-1:0] EX2_pc,
    input wire [XLEN-1:0] MEM_pc,
    input wire [XLEN-1:0] WB_pc,

    input wire [3:0] trap_status,
    input wire [XLEN-1:0] csr_read_data,

    output reg [XLEN-1:0] trap_target,
    output reg ic_clean,
    output reg debug_mode,

    output reg csr_write_enable,
    output reg trap_csr_access,
    output reg [11:0] csr_trap_address,
    output reg [XLEN-1:0] csr_trap_write_data,

    output reg trap_done,
    output reg misaligned_instruction_flush,
    output reg misaligned_memory_flush,
    output reg pth_done_flush,
    output reg standby_mode,
    output reg mret_executed,
    output reg pth_read,
    output reg goto_mtvec
);

localparam IDLE             = 4'b0000;
localparam WRITE_MEPC       = 4'b0001;  // write mcause
localparam WRITE_MCAUSE     = 4'b0010;  // prepare/read mtvec
localparam READ_MTVEC       = 4'b0011;
localparam READ_MEPC        = 4'b0100;
localparam GOTO_MTVEC       = 4'b0101;
localparam RETURN_MRET      = 4'b0110;
localparam MEM_STANDBY      = 4'b0111;
localparam WB_STANDBY       = 4'b1000;
localparam RTRE_STANDBY     = 4'b1001;
localparam ECALL_MEPC_WRITE = 4'b1010;
localparam RETURN_MRET_D1   = 4'b1011;
localparam RETURN_MRET_D2   = 4'b1100;
localparam GOTO_MRET       = 4'b1101;

reg [3:0] trap_handle_state;
reg [3:0] next_trap_handle_state;

reg debug_mode_reg;
reg is_timer_interrupt;
reg [3:0] latched_trap_status;

wire [XLEN-1:0] MCAUSE_TIMER_INTERRUPT = {1'b1, {(XLEN-5){1'b0}}, 4'd7};
wire [XLEN-1:0] MCAUSE_ECALL_MMODE     = {{(XLEN-4){1'b0}}, 4'd11};
wire [XLEN-1:0] MCAUSE_EBREAK          = {{(XLEN-3){1'b0}}, 3'd3};
wire [XLEN-1:0] MCAUSE_LOAD_MISALIGN   = {{(XLEN-3){1'b0}}, 3'd4};
wire [XLEN-1:0] MCAUSE_STORE_MISALIGN  = {{(XLEN-3){1'b0}}, 3'd6};
wire [XLEN-1:0] MCAUSE_INST_MISALIGN   = {XLEN{1'b0}};

// ============================================================
// Sequential
// ============================================================
always @(posedge clk or posedge reset) begin
    if (reset) begin
        trap_handle_state   <= IDLE;
        debug_mode_reg      <= 1'b0;
        is_timer_interrupt  <= 1'b0;
        latched_trap_status <= `TRAP_NONE;
    end
    else if (clk_enable) begin
        trap_handle_state <= next_trap_handle_state;

        /*
         * Latch the original trap cause only when a new trap is accepted
         * in IDLE.  After timer trap entry, mstatus.MIE becomes 0, so
         * ExceptionDetector may drop trap_status back to TRAP_NONE.
         * The FSM must still remember that the original cause was timer IRQ.
         */
        if (trap_handle_state == IDLE) begin
            if (trap_status != `TRAP_NONE && trap_status != `TRAP_FENCEI) begin
                latched_trap_status <= trap_status;

                /*
                 * Keep is_timer_interrupt across the whole timer handler.
                 * Do not clear it when MRET is detected, because MRET needs
                 * to know whether it is returning from a timer interrupt.
                 */
                if (trap_status == `TIMER_INTERRUPT_IRQ)
                    is_timer_interrupt <= 1'b1;
                else if (trap_status != `TRAP_MRET)
                    is_timer_interrupt <= 1'b0;
            end
        end

        if (trap_handle_state == RETURN_MRET) begin
            is_timer_interrupt <= 1'b0;
        end

        if (trap_handle_state == IDLE && trap_status == `TRAP_MRET) begin
            debug_mode_reg <= 1'b0;
        end

        if (trap_handle_state == WRITE_MCAUSE &&
            latched_trap_status == `TRAP_EBREAK) begin
            debug_mode_reg <= 1'b1;
        end
    end
end

// ============================================================
// Debug mode output
// ============================================================
always @(*) begin
    debug_mode = debug_mode_reg;
end

// ============================================================
// Combinational FSM
// ============================================================
always @(*) begin
    ic_clean                     = 1'b0;
    csr_write_enable             = 1'b0;
    trap_csr_access              = 1'b0;
    csr_trap_address             = 12'b0;
    csr_trap_write_data          = {XLEN{1'b0}};
    trap_target                  = {XLEN{1'b0}};
    trap_done                    = 1'b1;
    misaligned_instruction_flush = 1'b0;
    misaligned_memory_flush      = 1'b0;
    pth_done_flush               = 1'b0;
    standby_mode                 = 1'b0;
    mret_executed                = 1'b0;
    next_trap_handle_state       = trap_handle_state;
    goto_mtvec                    = 1'b0;
    pth_read                     = 1'b0;

    case (trap_handle_state)

        IDLE: begin
            next_trap_handle_state = IDLE;

            if (trap_status == `TRAP_NONE) begin
                trap_done = 1'b1;
            end

            else if (trap_status == `TRAP_FENCEI) begin
                ic_clean  = 1'b1;
                trap_done = 1'b1;
            end

            else if (trap_status == `TRAP_MRET) begin
                trap_csr_access        = 1'b1;
                csr_trap_address       = 12'h341; // mepc
                trap_done              = 1'b0;
                next_trap_handle_state = READ_MEPC;
            end

            else if (trap_status == `TRAP_ECALL ||
                     trap_status == `TIMER_INTERRUPT_IRQ) begin
                /*
                 * ECALL / timer interrupt detected before final trap entry.
                 * Drain pipeline first, then save mepc/mcause.
                 */
                standby_mode           = 1'b1;
                trap_done              = 1'b0;
                next_trap_handle_state = MEM_STANDBY;
            end

            else begin
                /*
                 * EBREAK / misaligned exceptions.
                 * Existing design saves MEM_pc for these cases.
                 */
                trap_csr_access        = 1'b1;
                csr_write_enable       = 1'b1;
                csr_trap_address       = 12'h341; // mepc
                csr_trap_write_data    = MEM_pc;
                trap_done              = 1'b0;
                next_trap_handle_state = WRITE_MEPC;
            end
        end

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

        ECALL_MEPC_WRITE: begin
            /*
             * Save interrupted PC to mepc.
             * For your current top-level, EX_pc is connected to EXR_pc.
             */
            trap_csr_access        = 1'b1;
            csr_write_enable       = 1'b1;
            csr_trap_address       = 12'h341; // mepc
            csr_trap_write_data = (EXR_pc != 32'b0) ? EXR_pc : 
                                (ID_pc  != 32'b0) ? ID_pc : 
                                (IO_pc != 32'b0) ? IO_pc : 
                                (IF_pc != 32'b0) ? IF_pc : 32'b0; // Handle the case when the trap is from an instruction before EX stage
            trap_done              = 1'b0;
            next_trap_handle_state = WRITE_MEPC;
        end

        WRITE_MEPC: begin
            /*
             * Write mcause.
             * Use latched_trap_status, not live trap_status.
             */
            trap_csr_access     = 1'b1;
            csr_write_enable    = 1'b1;
            csr_trap_address    = 12'h342; // mcause

            if (latched_trap_status == `TIMER_INTERRUPT_IRQ)
                csr_trap_write_data = MCAUSE_TIMER_INTERRUPT;
            else if (latched_trap_status == `TRAP_ECALL)
                csr_trap_write_data = MCAUSE_ECALL_MMODE;
            else if (latched_trap_status == `TRAP_EBREAK)
                csr_trap_write_data = MCAUSE_EBREAK;
            else if (latched_trap_status == `TRAP_MISALIGNED_LOAD)
                csr_trap_write_data = MCAUSE_LOAD_MISALIGN;
            else if (latched_trap_status == `TRAP_MISALIGNED_STORE)
                csr_trap_write_data = MCAUSE_STORE_MISALIGN;
            else
                csr_trap_write_data = MCAUSE_INST_MISALIGN;

            trap_done              = 1'b0;
            next_trap_handle_state = WRITE_MCAUSE;
        end

        WRITE_MCAUSE: begin
            if (latched_trap_status == `TRAP_EBREAK) begin
                trap_done              = 1'b1;
                next_trap_handle_state = IDLE;
            end
            else begin
                trap_csr_access        = 1'b1;
                csr_trap_address       = 12'h305; // mtvec
                trap_target            = csr_read_data;
                trap_done              = 1'b0;
                next_trap_handle_state = READ_MTVEC;
            end
        end

        READ_MTVEC: begin
            trap_csr_access  = 1'b1;
            csr_trap_address = 12'h305; // mtvec
            pth_read         = 1'b1;
            goto_mtvec=1'b1;
            trap_target      = csr_read_data;

            if (latched_trap_status == `TRAP_MISALIGNED_INSTRUCTION)
                misaligned_instruction_flush = 1'b1;
            else if (latched_trap_status == `TRAP_MISALIGNED_STORE ||
                     latched_trap_status == `TRAP_MISALIGNED_LOAD)
                misaligned_memory_flush = 1'b1;

            trap_done              = 1'b1;
            pth_done_flush         = 1'b1;
            next_trap_handle_state = GOTO_MTVEC;
        end

        GOTO_MTVEC: begin
            trap_csr_access  = 1'b1;
            csr_trap_address = 12'h305; // mtvec
            goto_mtvec=1'b1;
            pth_read         = 1'b1;
            trap_target      = csr_read_data;

            if (latched_trap_status == `TRAP_MISALIGNED_INSTRUCTION)
                misaligned_instruction_flush = 1'b1;
            else if (latched_trap_status == `TRAP_MISALIGNED_STORE ||
                     latched_trap_status == `TRAP_MISALIGNED_LOAD)
                misaligned_memory_flush = 1'b1;

            trap_done              = 1'b1;
            pth_done_flush         = 1'b1;
            next_trap_handle_state = IDLE;
        end

        READ_MEPC: begin
            /*
             * Architectural MRET target is mepc as-is.
             * Do not add +4 here.  ECALL skip should be handled by software
             * trap handler if needed.
             */
            trap_csr_access        = 1'b1;
            csr_trap_address       = 12'h341; // mepc
            trap_target            = {csr_read_data[XLEN-1:2], 2'b00};
            trap_done              = 1'b0;
            pth_read               = 1'b1;
            next_trap_handle_state = RETURN_MRET;
        end

        RETURN_MRET: begin
            trap_csr_access        = 1'b1;
            csr_trap_address       = 12'h341; // mepc
            trap_target            = {csr_read_data[XLEN-1:2], 2'b00};
            trap_done              = 1'b1;
            mret_executed          = 1'b1;
            pth_read               = 1'b1;
            next_trap_handle_state = RETURN_MRET_D1;
        end

        RETURN_MRET_D1: begin
            trap_csr_access        = 1'b1;
            csr_trap_address       = 12'h341; // mepc
            trap_target            = {csr_read_data[XLEN-1:2], 2'b00};
            trap_done              = 1'b1;
            mret_executed          = 1'b1;
            pth_read               = 1'b1;
            next_trap_handle_state = RETURN_MRET_D2;
        end

        RETURN_MRET_D2: begin
            trap_csr_access        = 1'b1;
            csr_trap_address       = 12'h341; // mepc
            trap_target            = {csr_read_data[XLEN-1:2], 2'b00};
            trap_done              = 1'b1;
            mret_executed          = 1'b1;
            pth_read               = 1'b1;
            next_trap_handle_state = GOTO_MRET;
        end

        GOTO_MRET: begin
            trap_csr_access        = 1'b1;
            csr_trap_address       = 12'h341; // mepc
            trap_target            = {csr_read_data[XLEN-1:2], 2'b00};
            trap_done              = 1'b1;
            mret_executed          = 1'b1;
            pth_read               = 1'b1;
            next_trap_handle_state = IDLE;
            pth_done_flush         = 1'b1;
        end

        default: begin
            next_trap_handle_state = IDLE;
        end

    endcase
end

endmodule