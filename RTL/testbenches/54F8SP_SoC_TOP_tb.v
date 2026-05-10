// ============================================================================
// tb_SoC_TOP — RV32IM54F8SP SoC Testbench
// PS/2 Keyboard Input Simulation Version
// ============================================================================
// iverilog + GTKWave:
//   $dumpvars(0, tb_SoC_TOP) 로 모든 계층의 모든 신호를 VCD에 기록합니다.
//
// Expected input sequence:
//   a b c Enter
//
// PS/2 Set 2 scancodes:
//   a     = 0x1C
//   b     = 0x32
//   c     = 0x21
//   Enter = 0x5A
// ============================================================================

`timescale 1ns / 1ps

`include "./testbenches/xilinx_sim_stubs.v"

// TOP module
// 경로/파일명이 다르면 여기만 네 프로젝트에 맞게 수정하면 됨.
// `include "./modules/54F8SP_SoC_TOP.v"

// SoC peripheral modules
`include "./modules/MMIO_Interface.v"
`include "./modules/CLINT.v"
`include "./modules/VRAM.v"
`include "./modules/ps2_rx.v"
`include "./modules/UART_TX.v"
`include "./modules/font_rom.v"
`include "./modules/vga_ctrl.v"

// CPU core top
`include "./modules/RV32IM54F_8SP.v"

// 나머지 CPU 내부 모듈들은 test.sh에서 modules/*.v로 같이 컴파일하거나,
// 필요하면 아래에 include를 추가하면 됨.
// 예:
// `include "./modules/ALU.v"
// `include "./modules/ALUController.v"
// `include "./modules/ByteEnableLogic.v"
// ...

module tb_SoC_TOP;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter CLK_PERIOD    = 10;       // 100 MHz
    parameter SIM_TIME_US   = 50000;    // 50 ms
    parameter RESET_HOLD_NS = 200;

    // PS/2 clock timing
    // 30us half-period => 약 16.7kHz PS/2 clock
    localparam PS2_CLK_HALF = 30_000;

    // UART 115200 baud
    localparam UART_BIT_PERIOD = 8680;

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
    // PS/2 Bus Model — open-drain + pullup
    // ========================================================================
    // PS/2는 open-drain이므로 0은 drive, 1은 release가 정석.
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
    // VCD Dump
    // ========================================================================
    initial begin
        $dumpfile("soc_waveform_ps2.vcd");
        $dumpvars(0, tb_SoC_TOP);
    end

    // ========================================================================
    // UART TX Monitor
    // ========================================================================
    integer uart_log_fd;
    reg [7:0] uart_rx_byte;

    initial begin
        uart_log_fd = $fopen("uart_output.log", "w");
    end

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

            if (uart_rx_byte >= 8'h20 && uart_rx_byte < 8'h7F) begin
                $display("[UART] %0t: '%c' (0x%02h)",
                    $time, uart_rx_byte, uart_rx_byte);
            end
            else if (uart_rx_byte == 8'h0A) begin
                $display("[UART] %0t: <LF>", $time);
            end
            else if (uart_rx_byte == 8'h0D) begin
                $display("[UART] %0t: <CR>", $time);
            end
            else begin
                $display("[UART] %0t: 0x%02h", $time, uart_rx_byte);
            end

            if (uart_log_fd != 0) begin
                $fwrite(uart_log_fd, "%c", uart_rx_byte);
            end
        end
    end

    // ========================================================================
    // LED Monitor
    // ========================================================================
    reg [7:0] led_prev;

    initial begin
        led_prev = 8'hxx;
    end

    always @(LED) begin
        if (LED !== led_prev) begin
            $display("[LED]  %0t: LED=0x%02h [%b_%b_%b_%b_%b_%b_%b_%b]",
                $time,
                LED,
                LED[7], LED[6], LED[5], LED[4],
                LED[3], LED[2], LED[1], LED[0]);
            led_prev = LED;
        end
    end

    // ========================================================================
    // Optional Internal Keyboard Debug Monitor
    // ========================================================================
    // TOP 내부 신호명이 지금 코드와 같을 때만 유효.
    // 만약 컴파일러가 hierarchical reference를 싫어하면 이 블록을 주석 처리하면 됨.
    /*
    always @(posedge dut.sys_clk) begin
        if (!dut.sys_reset) begin
            if (dut.scancode_valid) begin
                $display("[KBD]  %0t: scancode_valid scancode=0x%02h",
                    $time, dut.scancode);
            end

            if (dut.kb_cdc_pulse) begin
                $display("[KBD]  %0t: kb_cdc_pulse", $time);
            end

            if (dut.kb_fifo_push) begin
                $display("[KBD]  %0t: FIFO PUSH data=0x%02h wr=%0d rd=%0d full=%b empty=%b",
                    $time,
                    dut.kb_scancode_pix,
                    dut.kb_fifo_wr,
                    dut.kb_fifo_rd,
                    dut.kb_fifo_full,
                    dut.kb_fifo_empty);
            end

            if (dut.kb_ack) begin
                $display("[KBD]  %0t: KB ACK", $time);
            end

            if (dut.kb_fifo_pop) begin
                $display("[KBD]  %0t: FIFO POP head=0x%02h wr=%0d rd=%0d full=%b empty=%b",
                    $time,
                    dut.kb_scancode_sys,
                    dut.kb_fifo_wr,
                    dut.kb_fifo_rd,
                    dut.kb_fifo_full,
                    dut.kb_fifo_empty);
            end
        end
    end
*/
    // ========================================================================
    // Optional CPU MMIO Debug Monitor
    // ========================================================================
    always @(posedge dut.sys_clk) begin
        if (!dut.sys_reset) begin
            if (dut.cpu_mmio_address[31:0] == 32'h1003_0004) begin
                $display("[MMIO] %0t: KB_STAT addr seen, we=%b wdata=0x%08h rdata=0x%08h kb_new=%b",
                    $time,
                    dut.cpu_mmio_write_enable,
                    dut.cpu_mmio_write_data,
                    dut.mmio_read_data,
                    dut.kb_new_data);
            end

            if (dut.cpu_mmio_address[31:0] == 32'h1003_0000) begin
                $display("[MMIO] %0t: KB_SCAN addr seen, we=%b rdata=0x%08h scan=0x%02h",
                    $time,
                    dut.cpu_mmio_write_enable,
                    dut.mmio_read_data,
                    dut.kb_scancode_sys);
            end

            if (dut.cpu_mmio_write_enable &&
                dut.cpu_mmio_address[31:0] == 32'h1003_0004) begin
                $display("[MMIO] %0t: WRITE KB_STAT wdata=0x%08h",
                    $time,
                    dut.cpu_mmio_write_data);
            end
        end
    end

    // ========================================================================
    // PS/2 Open-Drain Drive Helpers
    // ========================================================================
    task ps2_drive_clk;
        input val;
        begin
            if (val == 1'b0) begin
                ps2_clk_drive = 1'b0;
                ps2_clk_oe    = 1'b1;
            end
            else begin
                ps2_clk_drive = 1'b1;
                ps2_clk_oe    = 1'b0;   // release high
            end
        end
    endtask

    task ps2_drive_data;
        input val;
        begin
            if (val == 1'b0) begin
                ps2_data_drive = 1'b0;
                ps2_data_oe    = 1'b1;
            end
            else begin
                ps2_data_drive = 1'b1;
                ps2_data_oe    = 1'b0;  // release high
            end
        end
    endtask

    task ps2_idle;
        begin
            ps2_drive_clk(1'b1);
            ps2_drive_data(1'b1);
        end
    endtask

    // PS/2 receiver는 보통 falling edge에서 data를 sample.
    // 따라서 data를 먼저 안정화시키고 CLK falling edge를 만든다.
    task ps2_send_bit;
        input bitval;
        begin
            ps2_drive_clk(1'b1);
            ps2_drive_data(bitval);
            #(PS2_CLK_HALF);

            ps2_drive_clk(1'b0);
            #(PS2_CLK_HALF);
        end
    endtask

    task ps2_send_byte;
        input [7:0] data;
        reg parity;
        integer i;
        begin
            parity = ~(^data); // odd parity

            ps2_idle();
            #(PS2_CLK_HALF * 2);

            // Start bit
            ps2_send_bit(1'b0);

            // Data bits, LSB first
            for (i = 0; i < 8; i = i + 1) begin
                ps2_send_bit(data[i]);
            end

            // Odd parity
            ps2_send_bit(parity);

            // Stop bit
            ps2_send_bit(1'b1);

            ps2_idle();

            $display("[PS2]  %0t: Sent byte 0x%02h", $time, data);

            #(PS2_CLK_HALF * 4);
        end
    endtask

    task ps2_press_key;
        input [7:0] make_code;
        begin
            $display("[PS2]  %0t: Press key make=0x%02h", $time, make_code);

            // Make code
            ps2_send_byte(make_code);

            #100_000;

            // Break sequence: F0 + make_code
            ps2_send_byte(8'hF0);
            ps2_send_byte(make_code);

            #200_000;
        end
    endtask

    // ========================================================================
    // Main Sequence — PS/2 Input Test
    // ========================================================================
    initial begin
        CPU_RESETN     = 1'b0;

        ps2_clk_oe     = 1'b0;
        ps2_data_oe    = 1'b0;
        ps2_clk_drive  = 1'b1;
        ps2_data_drive = 1'b1;

        $display("============================================");
        $display(" RV32IM54F8SP SoC Testbench - PS/2 MODE");
        $display(" Sim: %0d us (%0d ms)", SIM_TIME_US, SIM_TIME_US / 1000);
        $display(" Input sequence: a b c Enter");
        $display("============================================");

        // Reset
        #RESET_HOLD_NS;
        CPU_RESETN = 1'b1;
        $display("[TB]   %0t: Reset released", $time);

        // PLL lock 대기
        wait (dut.pll_locked == 1'b1);
        $display("[TB]   %0t: PLL locked", $time);

        // reset synchronizer release 대기
        wait (dut.sys_reset == 1'b0);
        wait (dut.pix_reset == 1'b0);
        $display("[TB]   %0t: sys/pix reset released", $time);

        // --------------------------------------------------------------------
        // Fast simulation shortcut:
        // 실제 TOP은 PS/2 inhibit를 약 200ms 걸어둠.
        // 시뮬레이션에서는 오래 기다리지 않기 위해 강제로 inhibit_done=1 처리.
        // --------------------------------------------------------------------
        force dut.inhibit_done = 1'b1;
        $display("[TB]   %0t: Forced dut.inhibit_done = 1", $time);

        // 시스템이 prompt 출력하고 shell loop에 들어갈 시간 확보
        #5_000_000; // 5ms

        $display("[TB]   %0t: Start PS/2 keyboard input", $time);

        // Type "abc\n"
        ps2_press_key(8'h1C); // a
        ps2_press_key(8'h32); // b
        ps2_press_key(8'h21); // c
        ps2_press_key(8'h5A); // Enter

        $display("[TB]   %0t: Keyboard input sequence done", $time);

        // 입력 후 관찰 시간
        #20_000_000; // 20ms

        $display("[TB]   %0t: Test done", $time);
        $finish;
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
        $display("[TB]   %0t: %0d ms | LED=0x%02h | kb_new=%b kb_full=%b",
            $time,
            ms_cnt,
            LED,
            );
    end

    // ========================================================================
    // Timeout
    // ========================================================================
    initial begin
        #(SIM_TIME_US * 1000);
        $display("[TB]   %0t: Timeout finish", $time);
        $finish;
    end

endmodule