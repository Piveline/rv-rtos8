// ============================================================================
// tb_SoC_TOP — RV64IM72F8SP SoC Testbench
// FreeRTOS + Rhealstone 6-benchmark RTL Simulation Version
//   (based on the PS/2 Keyboard Mash TURBO Stress TB)
// ============================================================================
//
// Usage example (run in RTL/RV64):
//   ./test.sh 72F8SP_SoC_TOP.v 72F8SP_SoC_TOP_tb.v
//
// Rhealstone sequence:
//   After boot, the TB types the following shell commands over PS/2 and waits
//   for each "Rhealstone: <name> - <N> cycles" result line on UART:
//     rheal switch / preempt / msg / sem / deadlock / intr
//   Firmware: Firmware/FreeRTOS_RV64_Rheal_sim (reduced iteration count)
//   PASS = 6 results, no error message, no timeout, no reboot.
//
// The keyboard mash stress tasks below are kept but no longer called.
//
// Notes:
//   - Do NOT `include the SoC TOP file here if test.sh already compiles it.
//   - This TB avoids direct references to fragile internal keyboard FIFO signals
//     by default, so it should not fail on missing dut.kb_fifo_full, etc.
//   - Optional internal MMIO debug can be enabled with:
//       iverilog -DENABLE_DUT_MMIO_DEBUG ...
//
// Stress goal:
//   Aggressively inject the same keyboard-mash payload with very short intervals:
//     asdlkifgjnas;lodfgihasdgo;pihjsdo;pig
//   using realistic make/break taps, make-only bursts, repeated Enter storms,
//   and immediate recovery commands.
//
//   This is meant to reproduce failures where typing 3+ characters quickly
//   causes the shell/SoC to restart or lose keyboard input.
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
`include "./modules/RV64IM72F_8SP.v"

module tb_SoC_TOP;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter CLK_PERIOD    = 10;        // 100 MHz
    parameter SIM_TIME_US   = 5000000;   // 5.0 s timeout for intensive keyboard RTL simulation
    parameter RESET_HOLD_NS = 200;

    // PS/2 clock timing
    // TURBO mode for RTL stress: 2us half-period => 250kHz PS/2 clock.
    // This is intentionally much faster than a real PS/2 keyboard.
    // It is useful for exposing FIFO/ack/polling/stack-corruption bugs quickly.
    // If your ps2_rx has a very slow debounce/filter, try 5_000 first.
    localparam PS2_CLK_HALF = 2_000;

    // Remove most inter-byte idle delay in turbo mode.
    localparam PS2_BYTE_PRE_IDLE  = 1_000;
    localparam PS2_BYTE_POST_IDLE = 1_000;

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
    RV64IM72F8SPSoCTOP #(.XLEN(64)) dut (
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
        $dumpfile("soc_waveform_rheal.vcd");
        $dumpvars(1, tb_SoC_TOP);          // TB top-level: uart_tx, PS2, LED ...
        //$dumpvars(0, tb_SoC_TOP.dut.cpu);  // whole CPU core
    end
/*
    initial begin
        $dumpfile("cpu_core_only.vcd");
        $dumpvars(0, tb_SoC_TOP.dut.cpu);
    end
*/
    // ========================================================================
    // UART TX Monitor
    // ========================================================================
    integer uart_log_fd;
    integer uart_char_count;
    integer boot_banner_count;
    integer stress_error_count;
    reg [7:0] uart_rx_byte;
    reg [8*64-1:0] uart_recent;
    reg [8*19-1:0] uart_recent19;
    reg stress_active;

    localparam [8*19-1:0] BOOT_BANNER = "System Initialized.";

    // --- Rhealstone result detection ---
    integer rheal_done_count;      // number of "... cycles" result lines
    integer rheal_fail_count;      // "failed" / "unknown" messages
    integer rheal_timeout_count;   // commands that timed out
    reg [8*6-1:0] uart_tail6;      // last 6 UART characters

    initial begin
        rheal_done_count    = 0;
        rheal_fail_count    = 0;
        rheal_timeout_count = 0;
        uart_tail6          = {8*6{1'b0}};
    end

    initial begin
        uart_log_fd       = $fopen("uart_output_rheal.log", "w");
        uart_char_count   = 0;
        boot_banner_count = 0;
        stress_error_count = 0;
        uart_recent       = {8*64{1'b0}};
        uart_recent19     = {8*19{1'b0}};
        stress_active     = 1'b0;
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

            // Shift recent UART stream for simple reboot/banner detection.
            uart_recent   = {uart_recent[8*63-1:0], uart_rx_byte};
            uart_recent19 = {uart_recent19[8*18-1:0], uart_rx_byte};

            if (uart_recent19 == BOOT_BANNER) begin
                boot_banner_count = boot_banner_count + 1;
                $display("[TB]   %0t: Boot banner observed count=%0d",
                    $time, boot_banner_count);

                if (stress_active && boot_banner_count > 1) begin
                    stress_error_count = stress_error_count + 1;
                    $display("[TB][ERR] %0t: Possible reset/restart during keyboard mash stress!",
                        $time);
                end
            end

            // Rhealstone result / error detection
            uart_tail6 = {uart_tail6[8*5-1:0], uart_rx_byte};

            if (uart_tail6 == "cycles") begin
                rheal_done_count = rheal_done_count + 1;
                $display("[TB]   %0t: Rhealstone result #%0d received",
                    $time, rheal_done_count);
            end

            // "xTaskCreate failed", "unknown rheal benchmark"
            if (uart_tail6 == "failed" || uart_tail6 == "nknown") begin
                rheal_fail_count = rheal_fail_count + 1;
                $display("[TB][ERR] %0t: Rhealstone error message on UART", $time);
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
            #PS2_BYTE_PRE_IDLE;

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

            #PS2_BYTE_POST_IDLE;
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
    // PS/2 Intensive Mash Input Helpers
    // ========================================================================
    integer ps2_payload_count;
    integer ps2_make_only_count;
    integer ps2_tap_count;

    task ps2_tap_key;
        input [7:0] make_code;
        input integer gap_after_ns;
        begin
            ps2_send_byte(make_code);
            #0;
            ps2_send_byte(8'hF0);
            ps2_send_byte(make_code);
            ps2_tap_count = ps2_tap_count + 1;
            #(gap_after_ns);
        end
    endtask

    task ps2_tap_key_fast;
        input [7:0] make_code;
        begin
            ps2_tap_key(make_code, 0);
        end
    endtask

    task ps2_make_only_key;
        input [7:0] make_code;
        input integer gap_after_ns;
        begin
            // Typematic-like / FIFO stress mode:
            // send make code only, no F0 break sequence.
            ps2_send_byte(make_code);
            ps2_make_only_count = ps2_make_only_count + 1;
            #(gap_after_ns);
        end
    endtask

    task ps2_enter;
        begin
            ps2_tap_key(8'h5A, 0);
        end
    endtask

    task ps2_space;
        begin
            ps2_tap_key(8'h29, 0);
        end
    endtask

    task type_mash_payload_tap;
        input integer gap_after_ns;
        begin
            // Payload: asdlkifgjnas;lodfgihasdgo;pihjsdo;pig
            ps2_tap_key(8'h1C, gap_after_ns); // a
            ps2_tap_key(8'h1B, gap_after_ns); // s
            ps2_tap_key(8'h23, gap_after_ns); // d
            ps2_tap_key(8'h4B, gap_after_ns); // l
            ps2_tap_key(8'h42, gap_after_ns); // k
            ps2_tap_key(8'h43, gap_after_ns); // i
            ps2_tap_key(8'h2B, gap_after_ns); // f
            ps2_tap_key(8'h34, gap_after_ns); // g
            ps2_tap_key(8'h3B, gap_after_ns); // j
            ps2_tap_key(8'h31, gap_after_ns); // n
            ps2_tap_key(8'h1C, gap_after_ns); // a
            ps2_tap_key(8'h1B, gap_after_ns); // s
            ps2_tap_key(8'h4C, gap_after_ns); // ;
            ps2_tap_key(8'h4B, gap_after_ns); // l
            ps2_tap_key(8'h44, gap_after_ns); // o
            ps2_tap_key(8'h23, gap_after_ns); // d
            ps2_tap_key(8'h2B, gap_after_ns); // f
            ps2_tap_key(8'h34, gap_after_ns); // g
            ps2_tap_key(8'h43, gap_after_ns); // i
            ps2_tap_key(8'h33, gap_after_ns); // h
            ps2_tap_key(8'h1C, gap_after_ns); // a
            ps2_tap_key(8'h1B, gap_after_ns); // s
            ps2_tap_key(8'h23, gap_after_ns); // d
            ps2_tap_key(8'h34, gap_after_ns); // g
            ps2_tap_key(8'h44, gap_after_ns); // o
            ps2_tap_key(8'h4C, gap_after_ns); // ;
            ps2_tap_key(8'h4D, gap_after_ns); // p
            ps2_tap_key(8'h43, gap_after_ns); // i
            ps2_tap_key(8'h33, gap_after_ns); // h
            ps2_tap_key(8'h3B, gap_after_ns); // j
            ps2_tap_key(8'h1B, gap_after_ns); // s
            ps2_tap_key(8'h23, gap_after_ns); // d
            ps2_tap_key(8'h44, gap_after_ns); // o
            ps2_tap_key(8'h4C, gap_after_ns); // ;
            ps2_tap_key(8'h4D, gap_after_ns); // p
            ps2_tap_key(8'h43, gap_after_ns); // i
            ps2_tap_key(8'h34, gap_after_ns); // g
            ps2_payload_count = ps2_payload_count + 1;
        end
    endtask

    task type_mash_payload_make_only;
        input integer gap_after_ns;
        begin
            // Same payload, but make-code only. This is intentionally harsher
            // than normal typing and helps expose FIFO/ack/polling bugs.
            ps2_make_only_key(8'h1C, gap_after_ns); // a
            ps2_make_only_key(8'h1B, gap_after_ns); // s
            ps2_make_only_key(8'h23, gap_after_ns); // d
            ps2_make_only_key(8'h4B, gap_after_ns); // l
            ps2_make_only_key(8'h42, gap_after_ns); // k
            ps2_make_only_key(8'h43, gap_after_ns); // i
            ps2_make_only_key(8'h2B, gap_after_ns); // f
            ps2_make_only_key(8'h34, gap_after_ns); // g
            ps2_make_only_key(8'h3B, gap_after_ns); // j
            ps2_make_only_key(8'h31, gap_after_ns); // n
            ps2_make_only_key(8'h1C, gap_after_ns); // a
            ps2_make_only_key(8'h1B, gap_after_ns); // s
            ps2_make_only_key(8'h4C, gap_after_ns); // ;
            ps2_make_only_key(8'h4B, gap_after_ns); // l
            ps2_make_only_key(8'h44, gap_after_ns); // o
            ps2_make_only_key(8'h23, gap_after_ns); // d
            ps2_make_only_key(8'h2B, gap_after_ns); // f
            ps2_make_only_key(8'h34, gap_after_ns); // g
            ps2_make_only_key(8'h43, gap_after_ns); // i
            ps2_make_only_key(8'h33, gap_after_ns); // h
            ps2_make_only_key(8'h1C, gap_after_ns); // a
            ps2_make_only_key(8'h1B, gap_after_ns); // s
            ps2_make_only_key(8'h23, gap_after_ns); // d
            ps2_make_only_key(8'h34, gap_after_ns); // g
            ps2_make_only_key(8'h44, gap_after_ns); // o
            ps2_make_only_key(8'h4C, gap_after_ns); // ;
            ps2_make_only_key(8'h4D, gap_after_ns); // p
            ps2_make_only_key(8'h43, gap_after_ns); // i
            ps2_make_only_key(8'h33, gap_after_ns); // h
            ps2_make_only_key(8'h3B, gap_after_ns); // j
            ps2_make_only_key(8'h1B, gap_after_ns); // s
            ps2_make_only_key(8'h23, gap_after_ns); // d
            ps2_make_only_key(8'h44, gap_after_ns); // o
            ps2_make_only_key(8'h4C, gap_after_ns); // ;
            ps2_make_only_key(8'h4D, gap_after_ns); // p
            ps2_make_only_key(8'h43, gap_after_ns); // i
            ps2_make_only_key(8'h34, gap_after_ns); // g
            ps2_payload_count = ps2_payload_count + 1;
        end
    endtask

    task type_probe_commands;
        begin
            // Small post-stress probes. If these do not echo/return prompt,
            // shell input path likely wedged.
            ps2_tap_key(8'h2B, 0); // f
            ps2_tap_key(8'h2D, 0); // r
            ps2_tap_key(8'h24, 0); // e
            ps2_tap_key(8'h24, 0); // e
            ps2_enter();
            #100_000;

            ps2_tap_key(8'h3C, 0); // u
            ps2_tap_key(8'h4D, 0); // p
            ps2_tap_key(8'h2C, 0); // t
            ps2_tap_key(8'h43, 0); // i
            ps2_tap_key(8'h3A, 0); // m
            ps2_tap_key(8'h24, 0); // e
            ps2_enter();
            #100_000;
        end
    endtask

    task run_ultra_keyboard_mash_sequence;
        integer round;
        begin
            ps2_payload_count = 0;
            ps2_make_only_count = 0;
            ps2_tap_count = 0;

            stress_active = 1'b1;
            $display("[TB]   %0t: === ULTRA KEYBOARD MASH STRESS START ===", $time);
            $display("[TB]   Payload = asdlkifgjnas;lodfgihasdgo;pihjsdo;pig");

            // Phase 0: sync with shell by pressing Enter once.
            $display("[TB]   %0t: Phase 0: Enter sync", $time);
            ps2_enter();
            #100_000;

            // Phase 1: realistic fast taps with almost no gap.
            $display("[TB]   %0t: Phase 1: realistic make/break taps, no extra gap", $time);
            for (round = 0; round < 4; round = round + 1) begin
                $display("[TB]   %0t: Phase 1 round %0d", $time, round);
                type_mash_payload_tap(0);
                ps2_enter();
                #10_000;
            end

            // Phase 2: slightly more realistic but still aggressive taps.
            $display("[TB]   %0t: Phase 2: realistic make/break taps, 2us gap", $time);
            for (round = 0; round < 3; round = round + 1) begin
                $display("[TB]   %0t: Phase 2 round %0d", $time, round);
                type_mash_payload_tap(2_000);
                ps2_enter();
                #10_000;
            end

            // Phase 3: make-only burst. This can overflow weak PS/2 FIFO paths.
            $display("[TB]   %0t: Phase 3: make-only burst", $time);
            for (round = 0; round < 8; round = round + 1) begin
                $display("[TB]   %0t: Phase 3 round %0d", $time, round);
                type_mash_payload_make_only(0);
                ps2_enter();
                #5_000;
            end

            // Phase 4: Enter storm, catches command parser / line reset bugs.
            $display("[TB]   %0t: Phase 4: repeated Enter storm", $time);
            for (round = 0; round < 20; round = round + 1) begin
                ps2_enter();
                #0;
            end

            // Phase 5: recovery probes. These should still work after stress.
            $display("[TB]   %0t: Phase 5: recovery probe commands", $time);
            type_probe_commands();

            stress_active = 1'b0;
            $display("[TB]   %0t: === ULTRA KEYBOARD MASH STRESS END ===", $time);
            $display("[TB]   Payload rounds=%0d, tap_keys=%0d, make_only_keys=%0d, boot_banners=%0d, stress_errors=%0d",
                ps2_payload_count,
                ps2_tap_count,
                ps2_make_only_count,
                boot_banner_count,
                stress_error_count);
        end
    endtask


    // ========================================================================
    // Rhealstone command input
    // ========================================================================
    // Shell reads 1 scancode per 1 ms tick (vTaskDelay(1)) and the KB FIFO is 8 deep.
    // One key = 3 bytes (make, F0, make) -> keep >= 3 ms per key to avoid FIFO overflow.
    localparam KEY_GAP_NS       = 5_000_000;     // 5 ms between keys
    localparam RHEAL_TIMEOUT_NS = 200_000_000;   // max 200 ms per command

    // ASCII -> PS/2 Set 2 make code (only characters used by "rheal ...")
    function [7:0] ascii_to_scan;
        input [7:0] ch;
        begin
            case (ch)
                "a": ascii_to_scan = 8'h1C;  "c": ascii_to_scan = 8'h21;
                "d": ascii_to_scan = 8'h23;  "e": ascii_to_scan = 8'h24;
                "g": ascii_to_scan = 8'h34;  "h": ascii_to_scan = 8'h33;
                "i": ascii_to_scan = 8'h43;  "k": ascii_to_scan = 8'h42;
                "l": ascii_to_scan = 8'h4B;  "m": ascii_to_scan = 8'h3A;
                "n": ascii_to_scan = 8'h31;  "o": ascii_to_scan = 8'h44;
                "p": ascii_to_scan = 8'h4D;  "r": ascii_to_scan = 8'h2D;
                "s": ascii_to_scan = 8'h1B;  "t": ascii_to_scan = 8'h2C;
                "w": ascii_to_scan = 8'h1D;  " ": ascii_to_scan = 8'h29;
                default: begin
                    ascii_to_scan = 8'h00;
                    $display("[TB][ERR] no scan code for '%c'", ch);
                end
            endcase
        end
    endfunction

    // Type a string (max 16 chars) and press Enter
    task type_cmd;
        input [8*16-1:0] str;
        integer i;
        reg [7:0] ch;
        begin
            for (i = 15; i >= 0; i = i - 1) begin
                ch = str[i*8 +: 8];
                if (ch != 8'h00)            // skip zero padding of short strings
                    ps2_tap_key(ascii_to_scan(ch), KEY_GAP_NS);
            end
            ps2_enter();
        end
    endtask

    // Type one rheal command and wait for its "... cycles" result line
    task run_rheal;
        input [8*16-1:0] cmd;
        integer expected;
        time    t_start;
        begin
            expected = rheal_done_count + 1;
            $display("[TB]   %0t: >>> %0s", $time, cmd);
            type_cmd(cmd);

            t_start = $time;
            while ((rheal_done_count < expected) &&
                   (($time - t_start) < RHEAL_TIMEOUT_NS))
                #100_000;

            if (rheal_done_count < expected) begin
                rheal_timeout_count = rheal_timeout_count + 1;
                $display("[TB][ERR] %0t: timeout waiting result of '%0s'", $time, cmd);
            end

            #3_000_000;   // wait for the next prompt (3 ms)
        end
    endtask

    // ========================================================================
    // Main Sequence — FreeRTOS + Rhealstone 6 benchmarks
    // ========================================================================
    initial begin
        CPU_RESETN     = 1'b0;

        ps2_clk_oe     = 1'b0;
        ps2_data_oe    = 1'b0;
        ps2_clk_drive  = 1'b1;
        ps2_data_drive = 1'b1;

        $display("============================================");
        $display(" RV64IM72F8SP SoC Testbench - FreeRTOS + Rhealstone 6 benchmarks");
        $display(" Commands: rheal switch/preempt/msg/sem/deadlock/intr");
        $display(" Sim: %0d us (%0d ms)", SIM_TIME_US, SIM_TIME_US / 1000);
        $display(" PS2_CLK_HALF=%0d ns, byte pre/post idle=%0d/%0d ns",
            PS2_CLK_HALF, PS2_BYTE_PRE_IDLE, PS2_BYTE_POST_IDLE);
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

        // Reboot during benchmarks is counted as an error (stress_error_count)
        stress_active = 1'b1;

        run_rheal("rheal switch");
        run_rheal("rheal preempt");
        run_rheal("rheal msg");
        run_rheal("rheal sem");
        run_rheal("rheal deadlock");
        run_rheal("rheal intr");

        stress_active = 1'b0;

        $display("============================================");
        $display(" Rhealstone summary (%0t)", $time);
        $display("   results received : %0d / 6", rheal_done_count);
        $display("   error messages   : %0d", rheal_fail_count);
        $display("   timeouts         : %0d", rheal_timeout_count);
        $display("   reboots          : %0d", stress_error_count);
        $display("   UART chars       : %0d", uart_char_count);
        if (rheal_done_count == 6 && rheal_fail_count == 0 &&
            rheal_timeout_count == 0 && stress_error_count == 0)
            $display("   >>> PASS");
        else
            $display("   >>> FAIL");
        $display("============================================");
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
        #(SIM_TIME_US * 64'd1000);   // 64-bit: 5,000,000 * 1000 overflows 32-bit integer
        $display("[TB]   %0t: Timeout finish", $time);
        $display("[TB]   UART chars observed: %0d", uart_char_count);
        $finish;
    end

    // ========================================================================
    // CPU Trap / Restart Monitor (debug: find why the CPU reboots)
    //   - keeps the last 32 retired PCs (WB stage)
    //   - prints unusual traps (not ECALL / MRET / TIMER)
    //   - when PC goes back to 0 after boot, dumps the PC history once
    // ========================================================================
    reg [63:0] pc_hist [0:31];
    reg [4:0]  pc_hist_ptr;
    reg        restart_dumped;
    reg        trap_prev;
    integer    hi;

    initial begin
        pc_hist_ptr    = 5'd0;
        restart_dumped = 1'b0;
        trap_prev      = 1'b0;
    end

    always @(posedge tb_SoC_TOP.dut.cpu.clk) begin
        if (tb_SoC_TOP.dut.cpu.clk_enable && !tb_SoC_TOP.dut.cpu.reset) begin
            // retired PC history
            if (tb_SoC_TOP.dut.cpu.instruction_retired) begin
                pc_hist[pc_hist_ptr] = tb_SoC_TOP.dut.cpu.WB_pc;
                pc_hist_ptr = pc_hist_ptr + 5'd1;
            end

            // unusual traps (rising edge of trapped)
            if (tb_SoC_TOP.dut.cpu.trapped && !trap_prev &&
                tb_SoC_TOP.dut.cpu.trap_status != 4'b0010 &&   // ECALL
                tb_SoC_TOP.dut.cpu.trap_status != 4'b0100 &&   // MRET
                tb_SoC_TOP.dut.cpu.trap_status != 4'b1000) begin // TIMER
                $display("[TRAP] %0t: status=%b WB_pc=%h MEM_pc=%h mepc=%h mcause=%h target=%h",
                    $time,
                    tb_SoC_TOP.dut.cpu.trap_status,
                    tb_SoC_TOP.dut.cpu.WB_pc,
                    tb_SoC_TOP.dut.cpu.MEM_pc,
                    tb_SoC_TOP.dut.cpu.csr_file.mepc,
                    tb_SoC_TOP.dut.cpu.csr_file.mcause,
                    tb_SoC_TOP.dut.cpu.trap_target);
            end
            trap_prev = tb_SoC_TOP.dut.cpu.trapped;

            // restart: PC back to 0 after the first boot banner
            if (!restart_dumped && boot_banner_count >= 1 &&
                tb_SoC_TOP.dut.cpu.pc == 64'd0) begin
                restart_dumped = 1'b1;
                $display("[RESTART] %0t: PC returned to 0. mepc=%h mcause=%h mtvec=%h",
                    $time,
                    tb_SoC_TOP.dut.cpu.csr_file.mepc,
                    tb_SoC_TOP.dut.cpu.csr_file.mcause,
                    tb_SoC_TOP.dut.cpu.csr_file.mtvec);
                $display("[RESTART] last 32 retired PCs (oldest -> newest):");
                for (hi = 0; hi < 32; hi = hi + 1)
                    $display("[RESTART]   %h", pc_hist[(pc_hist_ptr + hi) % 32]);
            end
        end
    end

endmodule