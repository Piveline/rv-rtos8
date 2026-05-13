// ============================================================================
// tb_SoC_TOP — RV32IM54F8SP SoC Testbench
// PS/2 Keyboard Intensive Stress Simulation Version
// ============================================================================
//
// Usage example:
//   ./test.sh 54F8SP_SoC_TOP.v 54F8SP_SoC_TOP_tb.v
//
// Notes:
//   - Do NOT `include the SoC TOP file here if test.sh already compiles it.
//   - This TB avoids direct references to fragile internal keyboard FIFO signals
//     by default, so it should not fail on missing dut.kb_fifo_full, etc.
//   - Optional internal MMIO debug can be enabled with:
//       iverilog -DENABLE_DUT_MMIO_DEBUG ...
//
// Stress phases:
//   1. Normal commands: abc, free, uptime, echo abc
//   2. Backspace / history
//   3. Rapid letter burst
//   4. Typematic-like repeated make codes
//   5. Long line beyond MAX_CMD_LEN
//   6. Repeated Enter
//   7. Recovery commands
//
// ============================================================================

`timescale 1ns / 1ps

`include "./testbenches/xilinx_sim_stubs.v"

// --------------------------------------------------------------------------
// Do NOT include TOP here when test.sh already compiles 54F8SP_SoC_TOP.v.
// --------------------------------------------------------------------------
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

module tb_SoC_TOP;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter CLK_PERIOD    = 10;        // 100 MHz
    parameter SIM_TIME_US   = 250000;    // 250 ms timeout
    parameter RESET_HOLD_NS = 200;

    // PS/2 clock timing
    // 30us half-period => about 16.7kHz PS/2 clock
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
    // PS/2 is open-drain: drive 0, release for 1.
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
        $dumpfile("soc_waveform_ps2_stress.vcd");
        $dumpvars(0, tb_SoC_TOP);
    end

    // ========================================================================
    // UART TX Monitor
    // ========================================================================
    integer uart_log_fd;
    integer uart_char_count;
    reg [7:0] uart_rx_byte;

    initial begin
        uart_log_fd     = $fopen("uart_output.log", "w");
        uart_char_count = 0;
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

            uart_char_count = uart_char_count + 1;

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
    // Optional DUT MMIO Debug Monitor
    // ========================================================================
    // Disabled by default to avoid elaboration errors when internal signal names
    // differ across top-module revisions.
    //
    // Enable only when these internal names exist in your current TOP:
    //   dut.sys_clk
    //   dut.sys_reset
    //   dut.cpu_mmio_address
    //   dut.cpu_mmio_write_enable
    //   dut.cpu_mmio_write_data
    //   dut.mmio_read_data
    //
`ifdef ENABLE_DUT_MMIO_DEBUG
    integer cnt_kb_stat_read;
    integer cnt_kb_scan_read;
    integer cnt_kb_stat_write;

    reg prev_kb_stat_read;
    reg prev_kb_scan_read;
    reg prev_kb_stat_write;

    wire kb_stat_read_now  =
        (dut.cpu_mmio_address[31:0] == 32'h1003_0004) &&
        !dut.cpu_mmio_write_enable;

    wire kb_scan_read_now  =
        (dut.cpu_mmio_address[31:0] == 32'h1003_0000) &&
        !dut.cpu_mmio_write_enable;

    wire kb_stat_write_now =
        (dut.cpu_mmio_address[31:0] == 32'h1003_0004) &&
        dut.cpu_mmio_write_enable;

    initial begin
        cnt_kb_stat_read  = 0;
        cnt_kb_scan_read  = 0;
        cnt_kb_stat_write = 0;
        prev_kb_stat_read  = 1'b0;
        prev_kb_scan_read  = 1'b0;
        prev_kb_stat_write = 1'b0;
    end

    always @(posedge dut.sys_clk) begin
        if (dut.sys_reset) begin
            prev_kb_stat_read  <= 1'b0;
            prev_kb_scan_read  <= 1'b0;
            prev_kb_stat_write <= 1'b0;
        end
        else begin
            prev_kb_stat_read  <= kb_stat_read_now;
            prev_kb_scan_read  <= kb_scan_read_now;
            prev_kb_stat_write <= kb_stat_write_now;

            if (kb_stat_read_now && !prev_kb_stat_read) begin
                cnt_kb_stat_read = cnt_kb_stat_read + 1;
            end

            if (kb_scan_read_now && !prev_kb_scan_read) begin
                cnt_kb_scan_read = cnt_kb_scan_read + 1;
                $display("[MMIO] %0t: KB_SCAN READ rdata=0x%08h",
                    $time, dut.mmio_read_data);
            end

            if (kb_stat_write_now && !prev_kb_stat_write) begin
                cnt_kb_stat_write = cnt_kb_stat_write + 1;
                $display("[MMIO] %0t: KB_STAT WRITE wdata=0x%08h",
                    $time, dut.cpu_mmio_write_data);
            end
        end
    end

    always begin
        #5_000_000;
        $display("[MMIO_SUM] %0t: stat_read=%0d scan_read=%0d stat_write=%0d",
            $time,
            cnt_kb_stat_read,
            cnt_kb_scan_read,
            cnt_kb_stat_write);
    end
`endif

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

    // PS/2 receiver normally samples data on the falling edge.
    // So data is stabilized before pulling clock low.
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
    // PS/2 Stress Input Helpers
    // ========================================================================
    task ps2_tap_key;
        input [7:0] make_code;
        input integer gap_after_ns;
        begin
            ps2_send_byte(make_code);
            #50_000;
            ps2_send_byte(8'hF0);
            ps2_send_byte(make_code);
            #(gap_after_ns);
        end
    endtask

    task ps2_tap_key_fast;
        input [7:0] make_code;
        begin
            ps2_send_byte(make_code);
            #10_000;
            ps2_send_byte(8'hF0);
            ps2_send_byte(make_code);
            #10_000;
        end
    endtask

    task ps2_enter;
        begin
            ps2_tap_key(8'h5A, 100_000);
        end
    endtask

    task ps2_backspace;
        begin
            ps2_tap_key(8'h66, 100_000);
        end
    endtask

    task type_abc_enter;
        begin
            ps2_tap_key(8'h1C, 100_000); // a
            ps2_tap_key(8'h32, 100_000); // b
            ps2_tap_key(8'h21, 100_000); // c
            ps2_enter();
        end
    endtask

    task type_free_enter;
        begin
            ps2_tap_key(8'h2B, 80_000);  // f
            ps2_tap_key(8'h2D, 80_000);  // r
            ps2_tap_key(8'h24, 80_000);  // e
            ps2_tap_key(8'h24, 80_000);  // e
            ps2_enter();
        end
    endtask

    task type_uptime_enter;
        begin
            ps2_tap_key(8'h3C, 80_000);  // u
            ps2_tap_key(8'h4D, 80_000);  // p
            ps2_tap_key(8'h2C, 80_000);  // t
            ps2_tap_key(8'h43, 80_000);  // i
            ps2_tap_key(8'h3A, 80_000);  // m
            ps2_tap_key(8'h24, 80_000);  // e
            ps2_enter();
        end
    endtask

    task type_echo_abc_enter;
        begin
            ps2_tap_key(8'h24, 80_000);  // e
            ps2_tap_key(8'h21, 80_000);  // c
            ps2_tap_key(8'h33, 80_000);  // h
            ps2_tap_key(8'h44, 80_000);  // o
            ps2_tap_key(8'h29, 80_000);  // space
            ps2_tap_key(8'h1C, 80_000);  // a
            ps2_tap_key(8'h32, 80_000);  // b
            ps2_tap_key(8'h21, 80_000);  // c
            ps2_enter();
        end
    endtask

    task type_history_enter;
        begin
            ps2_tap_key(8'h33, 80_000);  // h
            ps2_tap_key(8'h43, 80_000);  // i
            ps2_tap_key(8'h1B, 80_000);  // s
            ps2_tap_key(8'h2C, 80_000);  // t
            ps2_tap_key(8'h44, 80_000);  // o
            ps2_tap_key(8'h2D, 80_000);  // r
            ps2_tap_key(8'h35, 80_000);  // y
            ps2_enter();
        end
    endtask

    task type_backspace_test_enter;
        begin
            // abc -> backspace -> backspace -> de -> Enter
            ps2_tap_key(8'h1C, 80_000);  // a
            ps2_tap_key(8'h32, 80_000);  // b
            ps2_tap_key(8'h21, 80_000);  // c
            ps2_backspace();
            ps2_backspace();
            ps2_tap_key(8'h23, 80_000);  // d
            ps2_tap_key(8'h24, 80_000);  // e
            ps2_enter();
        end
    endtask

    task type_long_line_enter;
        integer i;
        begin
            // MAX_CMD_LEN=64 boundary/overflow behavior test.
            // Firmware should ignore extra chars beyond buffer size.
            for (i = 0; i < 90; i = i + 1) begin
                case (i % 6)
                    0: ps2_tap_key_fast(8'h1C); // a
                    1: ps2_tap_key_fast(8'h32); // b
                    2: ps2_tap_key_fast(8'h21); // c
                    3: ps2_tap_key_fast(8'h23); // d
                    4: ps2_tap_key_fast(8'h24); // e
                    5: ps2_tap_key_fast(8'h2B); // f
                endcase
            end
            ps2_enter();
        end
    endtask

    task type_typematic_like_a_enter;
        integer i;
        begin
            // Real keyboards repeat make codes while a key is held.
            // Send repeated make 'a' without break, then send final break.
            for (i = 0; i < 20; i = i + 1) begin
                ps2_send_byte(8'h1C); // repeated make 'a'
                #30_000;
            end

            ps2_send_byte(8'hF0);
            ps2_send_byte(8'h1C);
            ps2_enter();
        end
    endtask

    task type_rapid_letter_burst_enter;
        integer i;
        begin
            // Rapid burst to stress FIFO / ack / load-use / polling path.
            for (i = 0; i < 32; i = i + 1) begin
                case (i[2:0])
                    3'd0: ps2_tap_key_fast(8'h1C); // a
                    3'd1: ps2_tap_key_fast(8'h1B); // s
                    3'd2: ps2_tap_key_fast(8'h23); // d
                    3'd3: ps2_tap_key_fast(8'h2B); // f
                    3'd4: ps2_tap_key_fast(8'h3B); // j
                    3'd5: ps2_tap_key_fast(8'h42); // k
                    3'd6: ps2_tap_key_fast(8'h4B); // l
                    3'd7: ps2_tap_key_fast(8'h4C); // ;
                endcase
            end
            ps2_enter();
        end
    endtask

    task run_keyboard_stress_sequence;
        integer round;
        begin
            $display("[TB]   %0t: === Keyboard stress sequence start ===", $time);

            // Phase 1: normal commands repeated
            for (round = 0; round < 3; round = round + 1) begin
                $display("[TB]   %0t: Phase 1 normal round %0d", $time, round);
                type_abc_enter();
                #1_000_000;
                type_free_enter();
                #1_000_000;
                type_uptime_enter();
                #1_000_000;
                type_echo_abc_enter();
                #1_000_000;
            end

            // Phase 2: backspace / history
            $display("[TB]   %0t: Phase 2 backspace/history", $time);
            type_backspace_test_enter();
            #1_000_000;
            type_history_enter();
            #1_000_000;

            // Phase 3: rapid burst
            $display("[TB]   %0t: Phase 3 rapid burst", $time);
            type_rapid_letter_burst_enter();
            #2_000_000;

            // Phase 4: typematic-like repeated make
            $display("[TB]   %0t: Phase 4 typematic-like repeat", $time);
            type_typematic_like_a_enter();
            #2_000_000;

            // Phase 5: long line overflow boundary
            $display("[TB]   %0t: Phase 5 long line", $time);
            type_long_line_enter();
            #2_000_000;

            // Phase 6: repeated Enter
            $display("[TB]   %0t: Phase 6 repeated enter", $time);
            for (round = 0; round < 10; round = round + 1) begin
                ps2_enter();
                #100_000;
            end

            // Phase 7: recovery commands
            $display("[TB]   %0t: Phase 7 recovery commands", $time);
            type_free_enter();
            #1_000_000;
            type_uptime_enter();
            #1_000_000;
            type_abc_enter();

            $display("[TB]   %0t: === Keyboard stress sequence end ===", $time);
        end
    endtask

    // ========================================================================
    // Main Sequence — Keyboard Stress Test
    // ========================================================================
    initial begin
        CPU_RESETN     = 1'b0;

        ps2_clk_oe     = 1'b0;
        ps2_data_oe    = 1'b0;
        ps2_clk_drive  = 1'b1;
        ps2_data_drive = 1'b1;

        $display("============================================");
        $display(" RV32IM54F8SP SoC Testbench - PS/2 STRESS MODE");
        $display(" Sim: %0d us (%0d ms)", SIM_TIME_US, SIM_TIME_US / 1000);
        $display("============================================");

        // Reset
        #RESET_HOLD_NS;
        CPU_RESETN = 1'b1;
        $display("[TB]   %0t: Reset released", $time);

        // Wait for PLL and synchronized resets.
        // These internal names existed in your previous TOP.
        wait (dut.pll_locked == 1'b1);
        $display("[TB]   %0t: PLL locked", $time);

        wait (dut.sys_reset == 1'b0);
        wait (dut.pix_reset == 1'b0);
        $display("[TB]   %0t: sys/pix reset released", $time);

        // Fast simulation shortcut:
        // Real TOP inhibits PS/2 clock for about 200ms.
        // Force inhibit_done to avoid waiting in simulation.
        force dut.inhibit_done = 1'b1;
        $display("[TB]   %0t: Forced dut.inhibit_done = 1", $time);

        // Give firmware time to print prompt and enter shell loop.
        #8_000_000;

        run_keyboard_stress_sequence();

        // Observe idle behavior after stress.
        #20_000_000;

        $display("[TB]   %0t: Stress test done", $time);
        $display("[TB]   UART chars observed: %0d", uart_char_count);
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

        $display("[TB]   %0t: %0d ms | LED=0x%02h | UART_CHARS=%0d",
            $time,
            ms_cnt,
            LED,
            uart_char_count);
    end

    // ========================================================================
    // Timeout
    // ========================================================================
    initial begin
        #(SIM_TIME_US * 1000);
        $display("[TB]   %0t: Timeout finish", $time);
        $display("[TB]   UART chars observed: %0d", uart_char_count);
        $finish;
    end

endmodule