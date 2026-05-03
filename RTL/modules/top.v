// ============================================================================
// Nexys Video - PS/2 Keyboard + HDMI Text Display (Team Version)
// ============================================================================
//
// 팀원 코드(ps2_rx, char_buffer, font_rom, vga_ctrl)를 Nexys Video 보드에
// 맞게 통합한 Top Module.
//
// 변경 사항:
//   - VGA 아날로그 출력 → HDMI TMDS 출력 (rgb2dvi IP 사용)
//   - 카운터 분주 → Clocking Wizard PLL (25MHz pixel + 125MHz serial)
//   - PS/2 핀: inout + IOBUF, 200ms inhibit sequence 추가
//   - VGA 4-bit RGB → 8-bit RGB 확장
//   - rgb2dvi 채널 순서 보정: {R, B, G}
//
// IP 필요:
//   - clk_wiz_0: 100MHz → clk_out1(25MHz), clk_out2(125MHz)
//   - rgb2dvi_0: kGenerateSerialClk = FALSE
//
// ============================================================================

module top (
    input  wire        CLK100MHZ,       // 100 MHz system clock (R4)
    input  wire        CPU_RESETN,      // Active-low reset (G4)

    // PS/2 Keyboard (PIC24 USB-to-PS/2 bridge)
    inout  wire        PS2_CLK,         // Directly active on W17
    inout  wire        PS2_DATA,        // Directly active on N13

    // HDMI TX (TMDS)
    output wire [2:0]  HDMI_TX_P,       // TMDS data channels (positive)
    output wire [2:0]  HDMI_TX_N,       // TMDS data channels (negative)
    output wire        HDMI_TX_CLK_P,   // TMDS clock (positive)
    output wire        HDMI_TX_CLK_N,   // TMDS clock (negative)

    // Debug LEDs
    output wire [7:0]  LED
);

    // ========================================================================
    // Clock Generation - Clocking Wizard PLL
    // ========================================================================
    // 카운터 분주 대신 PLL 사용 (jitter 최소화, rgb2dvi 요구사항)

    wire clk_25m;       // 25 MHz pixel clock
    wire clk_125m;      // 125 MHz serial clock (TMDS)
    wire pll_locked;

    clk_wiz_0 pll_inst (
        .clk_in1  (CLK100MHZ),
        .clk_out1 (clk_25m),
        .clk_out2 (clk_125m),
        .reset    (~CPU_RESETN),
        .locked   (pll_locked)
    );

    // ========================================================================
    // Reset Synchronizer (pixel clock domain)
    // ========================================================================

    wire raw_reset = ~CPU_RESETN;

    reg [2:0] rst_sync;
    wire rst = rst_sync[2];

    always @(posedge clk_25m or negedge pll_locked) begin
        if (!pll_locked)
            rst_sync <= 3'b111;
        else
            rst_sync <= {rst_sync[1:0], 1'b0};
    end

    // ========================================================================
    // PS/2 - IOBUF + 200ms Inhibit Sequence
    // ========================================================================
    //
    // Nexys Video의 PIC24FJ128은 USB HID→PS/2 브릿지 역할.
    // FPGA가 리셋 직후 CLK을 ~200ms LOW로 잡아야(inhibit) PIC24가
    // 호스트가 존재함을 인식하고 HID 모드로 진입한다.
    // inhibit 해제 후 CLK/DATA를 high-Z로 놓으면 PIC24가 BAT(0xAA) 전송.

    // IOBUF: tri-state control (active-low T: 0=output, 1=high-Z)
    wire ps2_clk_i, ps2_data_i;
    wire ps2_clk_o, ps2_clk_t;

    IOBUF #(.DRIVE(12), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW"))
    iobuf_ps2_clk (
        .O  (ps2_clk_i),       // FPGA가 읽는 값
        .IO (PS2_CLK),          // 외부 핀
        .I  (ps2_clk_o),        // FPGA가 출력하는 값
        .T  (ps2_clk_t)         // 1=high-Z, 0=drive
    );

    IOBUF #(.DRIVE(12), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW"))
    iobuf_ps2_data (
        .O  (ps2_data_i),
        .IO (PS2_DATA),
        .I  (1'b0),             // DATA는 항상 high-Z (수신 전용)
        .T  (1'b1)
    );

    // 200ms inhibit timer (25MHz 기준: 25,000,000 * 0.2 = 5,000,000 cycles)
    localparam INHIBIT_COUNT = 5_000_000;
    reg [22:0] inhibit_timer;
    reg        inhibit_done;

    always @(posedge clk_25m or posedge rst) begin
        if (rst) begin
            inhibit_timer <= 0;
            inhibit_done  <= 1'b0;
        end else if (!inhibit_done) begin
            if (inhibit_timer == INHIBIT_COUNT - 1)
                inhibit_done <= 1'b1;
            else
                inhibit_timer <= inhibit_timer + 1;
        end
    end

    // inhibit 중: CLK = drive LOW / inhibit 완료: CLK = high-Z
    assign ps2_clk_o = 1'b0;                    // 출력값은 항상 LOW
    assign ps2_clk_t = inhibit_done ? 1'b1 : 1'b0;  // done → high-Z, else drive

    // ========================================================================
    // PS/2 Receiver (팀원 모듈 그대로 사용)
    // ========================================================================
    // ps2_rx는 input wire를 받으므로 IOBUF 출력(ps2_clk_i, ps2_data_i)을 연결

    wire [7:0] scancode;
    wire       valid;

    ps2_rx ps2 (
        .clk      (clk_25m),
        .rst      (rst),
        .ps2_clk  (ps2_clk_i),     // IOBUF를 통해 읽은 신호
        .ps2_dat  (ps2_data_i),     // IOBUF를 통해 읽은 신호
        .scancode (scancode),
        .valid    (valid)
    );

    // ========================================================================
    // Character Buffer (팀원 모듈 그대로 사용)
    // ========================================================================

    wire [6:0] buf_col;
    wire [4:0] buf_row;
    wire [7:0] char_out;

    char_buffer cbuf (
        .clk      (clk_25m),
        .rst      (rst),
        .scancode (scancode),
        .valid    (valid),
        .col      (buf_col),
        .row      (buf_row),
        .char_out (char_out)
    );

    // ========================================================================
    // Font ROM (팀원 모듈 그대로 사용)
    // ========================================================================

    wire [7:0] font_char;
    wire [3:0] font_row_idx;
    wire [7:0] font_bitmap;

    font_rom fnt (
        .char   (font_char),
        .row    (font_row_idx),
        .bitmap (font_bitmap)
    );

    // ========================================================================
    // VGA Controller (팀원 모듈 그대로 사용)
    // ========================================================================
    // vga_ctrl의 4-bit RGB 출력을 8-bit로 확장해서 rgb2dvi에 전달

    wire [3:0] vga_r, vga_g, vga_b;
    wire       hsync, vsync;

    vga_ctrl vga (
        .clk_25m    (clk_25m),
        .rst        (rst),
        .buf_col    (buf_col),
        .buf_row    (buf_row),
        .char_out   (char_out),
        .font_char  (font_char),
        .font_row   (font_row_idx),
        .font_bitmap(font_bitmap),
        .hsync      (hsync),
        .vsync      (vsync),
        .vga_r      (vga_r),
        .vga_g      (vga_g),
        .vga_b      (vga_b)
    );

    // ========================================================================
    // RGB 확장 (4-bit → 8-bit) + 채널 스왑
    // ========================================================================
    // rgb2dvi는 24-bit vid_pData를 받음.
    // Nexys Video의 rgb2dvi에서 실험적으로 확인된 채널 순서: {R, B, G}

    wire [7:0] r8 = {vga_r, vga_r};    // 4'hF → 8'hFF, 4'h0 → 8'h00
    wire [7:0] g8 = {vga_g, vga_g};
    wire [7:0] b8 = {vga_b, vga_b};

    wire [23:0] vid_data = {r8, b8, g8};   // 채널 스왑: {R, B, G}

    // ========================================================================
    // Video Active 신호 생성
    // ========================================================================
    // vga_ctrl 내부의 active 영역 정보를 재생성 (원본 모듈은 export 안 함)
    // vga_ctrl의 hsync/vsync는 1클럭 지연되어 출력되므로 active도 맞춰줌

    reg [9:0] h_cnt, v_cnt;

    always @(posedge clk_25m or posedge rst) begin
        if (rst) begin
            h_cnt <= 0;
            v_cnt <= 0;
        end else begin
            if (h_cnt == 799) begin
                h_cnt <= 0;
                v_cnt <= (v_cnt == 524) ? 0 : v_cnt + 1;
            end else begin
                h_cnt <= h_cnt + 1;
            end
        end
    end

    // 1클럭 지연 - vga_ctrl 내부의 always @(posedge) 출력과 동기화
    reg video_active;
    always @(posedge clk_25m) begin
        video_active <= (h_cnt < 640) && (v_cnt < 480);
    end

    // ========================================================================
    // rgb2dvi - DVI/HDMI TMDS Encoder
    // ========================================================================

    rgb2dvi_0 hdmi_encoder (
        .TMDS_Clk_p  (HDMI_TX_CLK_P),
        .TMDS_Clk_n  (HDMI_TX_CLK_N),
        .TMDS_Data_p (HDMI_TX_P),
        .TMDS_Data_n (HDMI_TX_N),
        .vid_pData   (vid_data),
        .vid_pHSync  (hsync),
        .vid_pVSync  (vsync),
        .vid_pVDE    (video_active),
        .PixelClk    (clk_25m),
        .SerialClk   (clk_125m),
        .aRst        (rst)
    );

    // ========================================================================
    // PS/2 Debug LEDs
    // ========================================================================
    //
    // LED[0]: inhibit_done      - 200ms 타이머 완료 (켜져야 정상)
    // LED[1]: ps2_clk 활동 감지  - PS/2 클럭 LOW가 한 번이라도 감지되면 ON
    // LED[2]: valid 누적         - scan code가 한 번이라도 수신되면 ON
    // LED[3]: break_flag 상태    - F0(break code) 수신 시 일시적 ON
    // LED[7:4]: 마지막 scancode 하위 4비트

    reg clk_ever_low;
    reg valid_ever;

    always @(posedge clk_25m or posedge rst) begin
        if (rst) begin
            clk_ever_low <= 1'b0;
            valid_ever   <= 1'b0;
        end else begin
            if (!ps2_clk_i)
                clk_ever_low <= 1'b1;
            if (valid)
                valid_ever <= 1'b1;
        end
    end

    assign LED[0]   = inhibit_done;
    assign LED[1]   = clk_ever_low;
    assign LED[2]   = valid_ever;
    assign LED[3]   = 1'b0;            // 예비
    assign LED[7:4] = scancode[3:0];

endmodule