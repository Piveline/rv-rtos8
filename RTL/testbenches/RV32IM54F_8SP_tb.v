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
    // This model is aligned with the real clint.v behavior:
    //   - CLINT range: 0x0200_0000 ~ 0x0200_000F
    //   - mtime increments at 1 kHz from a 100 MHz CPU clock
    //   - mtime write has priority over tick increment
    //   - mtimecmp is 64-bit, split into LO/HI 32-bit registers
    // ------------------------------------------------------------------------
    reg [XLEN-1:0] mmio_read_data;

    localparam integer CLK_FREQ  = 100_000_000;
    localparam integer TICK_FREQ = 1_000;
    localparam integer DIVIDER   = CLK_FREQ / TICK_FREQ;

    localparam [31:0] MTIME_LO     = 32'h0200_0000;
    localparam [31:0] MTIME_HI     = 32'h0200_0004;
    localparam [31:0] MTIMECMP_LO  = 32'h0200_0008;
    localparam [31:0] MTIMECMP_HI  = 32'h0200_000C;

    reg [$clog2(DIVIDER)-1:0] div_cnt;
    reg                       tick;

    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    wire timer_interrupt_pending;

    assign timer_interrupt_pending = (mtime >= mtimecmp) ? 1'b1 : 1'b0;

    // In this core-only TB, the CPU's MMIO address is used as both
    // the CLINT read address and write address.
    wire [31:0] clint_address;
    assign clint_address = mmio_data_memory_address[31:0];

    wire clint_selected;
    wire clint_write_enable;

    assign clint_selected =
        (clint_address == MTIME_LO)    ||
        (clint_address == MTIME_HI)    ||
        (clint_address == MTIMECMP_LO) ||
        (clint_address == MTIMECMP_HI);

    // Important:
    // Do not pass every MMIO write to CLINT.  In the real SoC, the MMIO decoder
    // selects CLINT only for CLINT addresses.  If every UART/VRAM/KB write were
    // treated as clint_write_enable, mtime's tick increment could be suppressed
    // because the real clint.v gives write_enable priority over tick.
    assign clint_write_enable =
        mmio_data_memory_write_enable && clint_selected;

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
    // 1. Clock divider: 100 MHz -> 1 kHz tick
    // Same behavior as clint.v
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            div_cnt <= 0;
            tick    <= 1'b0;
        end
        else if (div_cnt == DIVIDER - 1) begin
            div_cnt <= 0;
            tick    <= 1'b1;
        end
        else begin
            div_cnt <= div_cnt + 1;
            tick    <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // 2. MTIME
    // Same behavior as clint.v:
    //   reset -> 0
    //   write_enable has priority over tick increment
    //   tick -> mtime + 1
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            mtime <= 64'b0;
        end
        else if (clint_write_enable) begin
            case (clint_address)
                MTIME_LO: mtime[31:0]  <= mmio_data_memory_write_data[31:0];
                MTIME_HI: mtime[63:32] <= mmio_data_memory_write_data[31:0];
                default: ;
            endcase
        end
        else if (tick) begin
            mtime <= mtime + 64'd1;
        end
    end

    // ------------------------------------------------------------------------
    // 3. MTIMECMP
    // Same behavior as clint.v:
    //   reset -> all 1s
    //   writable split low/high
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end
        else if (clint_write_enable) begin
            case (clint_address)
                MTIMECMP_LO: mtimecmp[31:0]  <= mmio_data_memory_write_data[31:0];
                MTIMECMP_HI: mtimecmp[63:32] <= mmio_data_memory_write_data[31:0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // 4. MMIO read mux
    // CPU lw from CLINT address sees the corresponding split 32-bit value.
    // Other MMIO reads return zero in this core-only TB.
    // ------------------------------------------------------------------------
    always @(*) begin
        case (clint_address)
            MTIME_LO:     mmio_read_data = mtime[31:0];
            MTIME_HI:     mmio_read_data = mtime[63:32];
            MTIMECMP_LO:  mmio_read_data = mtimecmp[31:0];
            MTIMECMP_HI:  mmio_read_data = mtimecmp[63:32];
            default:      mmio_read_data = {XLEN{1'b0}};
        endcase
    end

    // ------------------------------------------------------------------------
    // Optional debug prints
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && tick) begin
            $display("[%0t ns] CLINT tick: mtime=%0d mtimecmp=%0d irq=%b",
                     $time, mtime + 64'd1, mtimecmp, timer_interrupt_pending);
        end

        if (!reset && clint_write_enable) begin
            case (clint_address)
                MTIME_LO:
                    $display("[%0t ns] CLINT write MTIME_LO    <= 0x%08h",
                             $time, mmio_data_memory_write_data[31:0]);
                MTIME_HI:
                    $display("[%0t ns] CLINT write MTIME_HI    <= 0x%08h",
                             $time, mmio_data_memory_write_data[31:0]);
                MTIMECMP_LO:
                    $display("[%0t ns] CLINT write MTIMECMP_LO <= 0x%08h",
                             $time, mmio_data_memory_write_data[31:0]);
                MTIMECMP_HI:
                    $display("[%0t ns] CLINT write MTIMECMP_HI <= 0x%08h",
                             $time, mmio_data_memory_write_data[31:0]);
                default: ;
            endcase
        end
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

        // With CLK_FREQ=100MHz and TICK_FREQ=1kHz:
        //   1 mtime tick = 1 ms = 1,000,000 ns
        // This 2 ms simulation should produce about two mtime increments.
        #200000000;

        $display("==================== RV32IM54F_8SP Core-only Test END ======================");
        $display("mtime    = %h", mtime);
        $display("mtimecmp = %h", mtimecmp);
        $display("timer_interrupt_pending = %b", timer_interrupt_pending);

        $stop;
    end

endmodule