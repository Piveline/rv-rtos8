// ============================================================================
// tb_SoC_TOP — RV32IM54F8SP SoC Testbench
// Idle / No-input version
// ============================================================================
// iverilog + GTKWave:
//   $dumpvars(0, tb_SoC_TOP) 로 모든 계층의 모든 신호를 VCD에 기록합니다.
//
// Vivado xsim:
//   Scope 패널에서 계층을 펼쳐 신호를 파형에 드래그하세요.
// ============================================================================

`timescale 1ns / 1ps
`include "./testbenches/xilinx_sim_stubs.v"
`include "./modules/MMIO_Interface.v"
`include "./modules/CLINT.v"
`include "./modules/VRAM.v"
`include "./modules/ps2_rx.v"
`include "./modules/UART_TX.v"
`include "./modules/font_rom.v"
`include "./modules/RV32IM54F_8SP.v"
`include "./modules/vga_ctrl.v"

module tb_SoC_TOP;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter CLK_PERIOD    = 10;       // 100 MHz
    parameter SIM_TIME_US   = 5000;     // 시뮬레이션 시간 (µs, 기본 5ms)
    parameter RESET_HOLD_NS = 50;      // 리셋 유지 시간

    // ========================================================================
    // DUT Port Signals
    // ========================================================================
    reg         CLK100MHZ;
    reg         CPU_RESETN;

    wire        PS2_CLK;
    wire        PS2_DATA;
    reg         ps2_clk_drive;
    reg         ps2_data_drive;
    reg         ps2_clk_oe;
    reg         ps2_data_oe;

    wire [2:0]  HDMI_TX_P;
    wire [2:0]  HDMI_TX_N;
    wire        HDMI_TX_CLK_P;
    wire        HDMI_TX_CLK_N;

    wire        uart_tx;
    wire [7:0]  LED;

    // ========================================================================
    // PS/2 Bus Model (open-drain + pullup)
    // ========================================================================
    assign PS2_CLK  = ps2_clk_oe  ? ps2_clk_drive  : 1'bz;
    assign PS2_DATA = ps2_data_oe ? ps2_data_drive : 1'bz;

    pullup(PS2_CLK);
    pullup(PS2_DATA);

    // ========================================================================
    // Clock — 100 MHz
    // ========================================================================
    initial CLK100MHZ = 1'b0;
    always #(CLK_PERIOD / 2) CLK100MHZ = ~CLK100MHZ;

    // ========================================================================
    // DUT
    // ========================================================================
    RV32IM54F8SPSoCTOP #(.XLEN(32)) dut (
        .CLK100MHZ       (CLK100MHZ),
        .CPU_RESETN      (CPU_RESETN),
        .PS2_CLK         (PS2_CLK),
        .PS2_DATA        (PS2_DATA),
        .HDMI_TX_P       (HDMI_TX_P),
        .HDMI_TX_N       (HDMI_TX_N),
        .HDMI_TX_CLK_P   (HDMI_TX_CLK_P),
        .HDMI_TX_CLK_N   (HDMI_TX_CLK_N),
        .uart_tx         (uart_tx),
        .LED             (LED)
    );

    // ========================================================================
    // VCD 파형 덤프 — 모든 계층, 모든 신호
    // ========================================================================
    initial begin
        $dumpfile("soc_waveform.vcd");
        $dumpvars(0, tb_SoC_TOP);
    end

    // ========================================================================
    // UART TX Monitor
    // ========================================================================
    localparam UART_BIT_PERIOD = 8680;  // 115200 baud @ 100MHz, BAUD_DIV=868

    integer uart_log_fd;

    initial begin
        uart_log_fd = $fopen("uart_output.log", "w");
    end

    reg [7:0] uart_rx_byte;

    always begin
        @(negedge uart_tx);

        #(UART_BIT_PERIOD / 2);

        if (uart_tx == 1'b0) begin
            uart_rx_byte = 8'h00;

            repeat (8) begin
                #UART_BIT_PERIOD;
                uart_rx_byte = {uart_tx, uart_rx_byte[7:1]};
            end

            #UART_BIT_PERIOD;

            if (uart_rx_byte >= 8'h20 && uart_rx_byte < 8'h7F)
                $display("[UART] %0t: '%c' (0x%02h)",
                    $time, uart_rx_byte, uart_rx_byte);
            else if (uart_rx_byte == 8'h0A)
                $display("[UART] %0t: <LF>", $time);
            else if (uart_rx_byte == 8'h0D)
                $display("[UART] %0t: <CR>", $time);
            else
                $display("[UART] %0t: 0x%02h", $time, uart_rx_byte);

            if (uart_log_fd != 0)
                $fwrite(uart_log_fd, "%c", uart_rx_byte);
        end
    end

    // ========================================================================
    // LED Monitor
    // ========================================================================
    // LED[0]=clk_en  [1]=timer_irq  [2]=kb_new  [3]=inhibit_done  [7:4]=scan[3:0]
    reg [7:0] led_prev;

    initial begin
        led_prev = 8'hxx;
    end

    always @(LED) begin
        if (LED !== led_prev) begin
            $display("[LED]  %0t: 0x%02h [clk_en=%b irq=%b kb=%b inhibit=%b scan=%04b]",
                $time, LED, LED[0], LED[1], LED[2], LED[3], LED[7:4]);
            led_prev = LED;
        end
    end

    // ========================================================================
    // PS/2 Stimulus Tasks
    // ========================================================================
    // Idle 테스트에서는 호출하지 않음.
    // 나중에 키 입력 테스트가 필요하면 ps2_press_key()를 다시 호출하면 됨.
    localparam PS2_CLK_HALF = 20_000;

    task ps2_send_byte;
        input [7:0] data;
        reg parity;
        integer i;
        begin
            parity = ~(^data);

            ps2_data_oe = 1'b1;
            ps2_clk_oe  = 1'b1;

            // Start bit
            ps2_data_drive = 1'b0;
            ps2_clk_drive  = 1'b1;
            #(PS2_CLK_HALF);
            ps2_clk_drive = 1'b0;
            #(PS2_CLK_HALF);

            // 8 data bits, LSB first
            for (i = 0; i < 8; i = i + 1) begin
                ps2_clk_drive  = 1'b1;
                ps2_data_drive = data[i];
                #(PS2_CLK_HALF);
                ps2_clk_drive = 1'b0;
                #(PS2_CLK_HALF);
            end

            // Parity
            ps2_clk_drive  = 1'b1;
            ps2_data_drive = parity;
            #(PS2_CLK_HALF);
            ps2_clk_drive = 1'b0;
            #(PS2_CLK_HALF);

            // Stop
            ps2_clk_drive  = 1'b1;
            ps2_data_drive = 1'b1;
            #(PS2_CLK_HALF);
            ps2_clk_drive = 1'b0;
            #(PS2_CLK_HALF);

            // Release bus
            ps2_clk_drive = 1'b1;
            #(PS2_CLK_HALF);
            ps2_clk_oe  = 1'b0;
            ps2_data_oe = 1'b0;

            $display("[PS2]  %0t: Sent 0x%02h", $time, data);
            #(PS2_CLK_HALF * 4);
        end
    endtask

    task ps2_press_key;
        input [7:0] make_code;
        begin
            ps2_send_byte(make_code);
            #100_000;
            ps2_send_byte(8'hF0);
            ps2_send_byte(make_code);
            #200_000;
        end
    endtask

    // ========================================================================
    // Main Sequence — Idle / No PS/2 Input
    // ========================================================================
    initial begin
        CPU_RESETN     = 1'b0;

        // PS/2 line을 TB가 구동하지 않음.
        // pullup에 의해 PS2_CLK, PS2_DATA는 idle-high 상태가 됨.
        ps2_clk_oe     = 1'b0;
        ps2_data_oe    = 1'b0;
        ps2_clk_drive  = 1'b1;
        ps2_data_drive = 1'b1;

        $display("============================================");
        $display(" RV32IM54F8SP SoC Testbench - IDLE MODE");
        $display(" Sim: %0d us (%0d ms)", SIM_TIME_US, SIM_TIME_US / 1000);
        $display("============================================");

        // Reset
        #RESET_HOLD_NS;
        CPU_RESETN = 1'b1;
        $display("[TB]   %0t: Reset released", $time);

        // 아무 입력도 넣지 않고 idle 상태 관찰
        $display("[TB]   %0t: No PS/2 input. System is running idle.", $time);

        // 여기서 $finish 하지 않음.
        // 아래 Timeout 블록이 SIM_TIME_US 이후 종료함.
    end

    // ========================================================================
    // 1ms Status Monitor
    // ========================================================================
    integer ms_cnt;

    initial begin
        ms_cnt = 0;
    end

    always begin
        #1_000_000;
        ms_cnt = ms_cnt + 1;
        $display("[TB]   %0t: %0d ms | LED=0x%02h", $time, ms_cnt, LED);
    end

endmodule