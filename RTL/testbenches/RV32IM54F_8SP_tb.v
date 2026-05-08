`timescale 1ns/1ps

module RV32IM54F_8SP_tb #(
    parameter XLEN = 32
);
    reg clk;
    reg reset;

    wire [31:0] retire_instruction;
    wire [XLEN-1:0] mmio_data_memory_address;
    wire [XLEN-1:0] mmio_data_memory_write_data;
    wire mmio_data_memory_write_enable;

    // ------------------------------------------------------------------------
    // Core-only MMIO / CLINT model
    // ------------------------------------------------------------------------
    reg [XLEN-1:0] mmio_read_data;
    reg [31:0] mtime;
    reg [31:0] mtimecmp;
    wire timer_interrupt_pending;

    assign timer_interrupt_pending = (mtime >= mtimecmp);

    localparam [31:0] MTIME_LO    = 32'h0200_0000;
    localparam [31:0] MTIMECMP_LO = 32'h0200_4000;

    RV32IM54F8SP #(
        .XLEN(XLEN)
    ) rv32im54f_8sp (
        .clk(clk),
        .clk_enable(1'b1),
        .reset(reset),
        .UART_busy(1'b0),
        .timer_interrupt_pending(timer_interrupt_pending),
        .MMIO_read_data(mmio_read_data),

        .retire_instruction(retire_instruction),
        .MMIO_data_memory_address(mmio_data_memory_address),
        .MMIO_data_memory_write_data(mmio_data_memory_write_data),
        .MMIO_data_memory_write_enable(mmio_data_memory_write_enable)
    );

    // Generate clock signal: 100 MHz, period = 10 ns
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Simple CLINT model
    // mtime increments every clock for fast simulation.
    // mtimecmp is updated when CPU writes to 0x02004000.
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mtime    <= 32'd0;
            mtimecmp <= 32'hFFFF_FFFF;
        end
        else begin
            mtime <= mtime + 32'd1;

            if (mmio_data_memory_write_enable &&
                mmio_data_memory_address == MTIMECMP_LO) begin
                mtimecmp <= mmio_data_memory_write_data[31:0];
            end
        end
    end

    // ------------------------------------------------------------------------
    // MMIO read mux
    // CPU lw from 0x02000000 sees mtime.
    // CPU lw from 0x02004000 sees mtimecmp.
    // ------------------------------------------------------------------------
    always @(*) begin
        case (mmio_data_memory_address)
            MTIME_LO:    mmio_read_data = mtime;
            MTIMECMP_LO: mmio_read_data = mtimecmp;
            default:     mmio_read_data = {XLEN{1'b0}};
        endcase
    end

    initial begin
        $dumpfile("testbenches/results/waveforms/RV32IM54F_8SP_tb.vcd");
        $dumpvars(0, rv32im54f_8sp);
        $dumpvars(0, RV32IM54F_8SP_tb);

        $display("==================== RV32IM54F_8SP Core-only Test START ====================");

        clk = 0;
        reset = 1;

        #50;
        reset = 0;

        // Timer interrupt까지 보려면 3340ns는 조금 짧을 수 있어서 넉넉하게.
        #2000000;

        $display("==================== RV32IM54F_8SP Core-only Test END ======================");
        $display("mtime    = %h", mtime);
        $display("mtimecmp = %h", mtimecmp);
        $display("timer_interrupt_pending = %b", timer_interrupt_pending);

        $stop;
    end

endmodule