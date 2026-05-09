`timescale 1ns/1ps

module tb_RV32IM54F8SPSoCTOP;

    // ============================================================
    // 1. DUT external pins
    // ============================================================
    reg CLK100MHZ;
    reg CPU_RESETN;

    tri1 PS2_CLK;
    tri1 PS2_DATA;

    wire [2:0] HDMI_TX_P;
    wire [2:0] HDMI_TX_N;
    wire       HDMI_TX_CLK_P;
    wire       HDMI_TX_CLK_N;

    wire uart_tx;
    wire [7:0] LED;

    // ============================================================
    // 2. DUT
    // ============================================================
    RV32IM54F8SPSoCTOP #(
        .XLEN(32)
    ) dut (
        .CLK100MHZ     (CLK100MHZ),
        .CPU_RESETN    (CPU_RESETN),

        .PS2_CLK       (PS2_CLK),
        .PS2_DATA      (PS2_DATA),

        .HDMI_TX_P     (HDMI_TX_P),
        .HDMI_TX_N     (HDMI_TX_N),
        .HDMI_TX_CLK_P (HDMI_TX_CLK_P),
        .HDMI_TX_CLK_N (HDMI_TX_CLK_N),

        .uart_tx       (uart_tx),
        .LED           (LED)
    );

    // ============================================================
    // 3. 100 MHz input clock
    // ============================================================
    initial begin
        CLK100MHZ = 1'b0;
        forever #5 CLK100MHZ = ~CLK100MHZ;   // 100 MHz
    end

    // ============================================================
    // 4. Reset sequence
    // ============================================================
    initial begin
        CPU_RESETN = 1'b0;

        repeat (20) @(posedge CLK100MHZ);
        CPU_RESETN = 1'b1;
    end

    // ============================================================
    // 5. Wave dump
    // ============================================================
    integer sim_cycles;

    initial begin
        sim_cycles = 500000;

        if (!$value$plusargs("CYCLES=%d", sim_cycles))
            sim_cycles = 500000;

        $dumpfile("soc_wave.vcd");

        // 너무 크게 dump하면 VCD가 폭발하므로 기본은 주요 SoC 계층만 dump
        $dumpvars(0, tb_RV32IM54F8SPSoCTOP);
        $dumpvars(0, dut.clint_inst);
        $dumpvars(0, dut.mmio);
        $dumpvars(0, dut.uart_tx_inst);

`ifdef DUMP_FULL_CPU
        // CPU 내부까지 전부 보고 싶을 때만 켜기
        // 주의: IMEM/DMEM 배열 때문에 VCD 크기가 매우 커질 수 있음
        $dumpvars(0, dut.cpu);
`endif

        wait (CPU_RESETN === 1'b1);
        wait (dut.sys_reset === 1'b0);

        $display("[TB] Reset released.");
        $display("[TB] sys_clk started, cpu_clk_enable=%b", dut.cpu_clk_enable);

        repeat (sim_cycles) @(posedge dut.sys_clk);

        $display("[TB] Simulation finished after %0d sys_clk cycles.", sim_cycles);
        $finish;
    end

    // ============================================================
    // 6. UART print monitor
    //    실제 serial tx decoding 대신, MMIO에서 UARTTX로 넘어가는 byte를 직접 출력
    // ============================================================
    always @(posedge dut.sys_clk) begin
        if (!dut.sys_reset && dut.uart_tx_start) begin
            $write("%c", dut.uart_tx_data);
        end
    end

    // ============================================================
    // 7. Optional MMIO monitor
    // ============================================================
`ifdef TB_VERBOSE
    always @(posedge dut.sys_clk) begin
        if (!dut.sys_reset && dut.cpu_mmio_write_enable) begin
            $display("[MMIO-W] t=%0t addr=0x%08h data=0x%08h clint_we=%b vram_we=%b uart_start=%b",
                     $time,
                     dut.cpu_mmio_address,
                     dut.cpu_mmio_write_data,
                     dut.clint_we,
                     dut.vram_we,
                     dut.uart_tx_start);
        end
    end

    always @(posedge dut.sys_clk) begin
        if (!dut.sys_reset && dut.timer_interrupt) begin
            $display("[CLINT] t=%0t timer_interrupt=1 mtime=%0d mtimecmp=%0d",
                     $time,
                     dut.clint_inst.mtime,
                     dut.clint_inst.mtimecmp);
        end
    end
`endif

    // ============================================================
    // 8. Optional fast CLINT tick
    //    실제 100MHz/1000Hz = 100000 cycles/tick은 시뮬레이션이 느림.
    //    -DFAST_CLINT를 주면 1000 cycles마다 tick을 강제로 넣음.
    //    기능 검증용이며 정확한 real-time 검증용은 아님.
    // ============================================================
`ifdef FAST_CLINT
    initial begin
        wait (dut.sys_reset === 1'b0);

        forever begin
            repeat (1000) @(posedge dut.sys_clk);

            force dut.clint_inst.tick = 1'b1;
            @(posedge dut.sys_clk);
            release dut.clint_inst.tick;
        end
    end
`endif

    // ============================================================
    // 9. PS/2 scancode injection helper
    //    실제 PS/2 waveform을 만들지 않고 ps2_rx 출력 쪽을 force해서
    //    SoC 내부 CDC/kb_new_data/kb_ack 흐름을 볼 수 있게 함.
    // ============================================================
    task inject_scancode;
        input [7:0] code;
        begin
            wait (dut.pix_reset === 1'b0);

            force dut.scancode       = code;
            force dut.scancode_valid = 1'b1;

            @(posedge dut.pixel_clk);

            force dut.scancode_valid = 1'b0;
            @(posedge dut.pixel_clk);

            release dut.scancode;
            release dut.scancode_valid;

            repeat (50) @(posedge dut.sys_clk);
        end
    endtask

    task kb_make;
        input [7:0] code;
        begin
            inject_scancode(code);
        end
    endtask

    task kb_break;
        input [7:0] code;
        begin
            inject_scancode(8'hF0);
            inject_scancode(code);
        end
    endtask

    // PS/2 Set-2 scancode 기준: uptime + Enter
    task type_uptime;
        begin
            // u p t i m e Enter
            kb_make(8'h3C); // u
            kb_make(8'h4D); // p
            kb_make(8'h2C); // t
            kb_make(8'h43); // i
            kb_make(8'h3A); // m
            kb_make(8'h24); // e
            kb_make(8'h5A); // Enter
        end
    endtask

`ifdef TYPE_UPTIME
    initial begin
        wait (dut.sys_reset === 1'b0);

        // shell prompt가 뜰 시간을 조금 줌
        repeat (200000) @(posedge dut.sys_clk);

        $display("\n[TB] Injecting keyboard command: uptime");
        type_uptime();
    end
`endif

endmodule


// ============================================================================
// Testbench stubs
// Use these only for non-Vivado simulation, e.g. Icarus/GTKWave.
// Compile with: +define+TB_STUBS
// ============================================================================

`ifdef TB_STUBS

module clk_wiz_0 (
    input  wire clk_in1,
    input  wire reset,
    output wire clk_out1,   // pixel_clk
    output wire clk_out2,   // serial_clk
    output wire clk_out3,   // sys_clk
    output wire locked
);
    reg pixel_clk_r;
    reg [1:0] pix_div;

    initial begin
        pixel_clk_r = 1'b0;
        pix_div     = 2'd0;
    end

    // sys_clk = 100 MHz
    assign clk_out3 = clk_in1;

    // serial_clk는 여기서는 실제 HDMI 검증 목적이 아니므로 100 MHz로 대체
    assign clk_out2 = clk_in1;

    // pixel_clk = 약 25 MHz
    always @(posedge clk_in1 or posedge reset) begin
        if (reset) begin
            pix_div     <= 2'd0;
            pixel_clk_r <= 1'b0;
        end else begin
            pix_div <= pix_div + 1'b1;
            if (pix_div == 2'd1) begin
                pix_div     <= 2'd0;
                pixel_clk_r <= ~pixel_clk_r;
            end
        end
    end

    assign clk_out1 = pixel_clk_r;
    assign locked   = ~reset;

endmodule


module IOBUF #(
    parameter DRIVE       = 12,
    parameter IBUF_LOW_PWR = "FALSE",
    parameter IOSTANDARD  = "LVCMOS33",
    parameter SLEW        = "SLOW"
)(
    output wire O,
    inout  wire IO,
    input  wire I,
    input  wire T
);
    assign O  = IO;
    assign IO = T ? 1'bz : I;
endmodule


module rgb2dvi_0 (
    output wire       TMDS_Clk_p,
    output wire       TMDS_Clk_n,
    output wire [2:0] TMDS_Data_p,
    output wire [2:0] TMDS_Data_n,

    input  wire [23:0] vid_pData,
    input  wire        vid_pHSync,
    input  wire        vid_pVSync,
    input  wire        vid_pVDE,
    input  wire        PixelClk,
    input  wire        SerialClk,
    input  wire        aRst
);
    assign TMDS_Clk_p  = PixelClk;
    assign TMDS_Clk_n  = ~PixelClk;
    assign TMDS_Data_p = 3'b000;
    assign TMDS_Data_n = 3'b111;
endmodule

`endif