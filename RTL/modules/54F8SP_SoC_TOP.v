module RV32IM72F8SPSoCTOP #(
    parameter XLEN = 32
)(
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,

    // PS/2 Keyboard
    inout  wire        PS2_CLK,
    inout  wire        PS2_DATA,

    // HDMI TX
    output wire [2:0]  HDMI_TX_P,
    output wire [2:0]  HDMI_TX_N,
    output wire        HDMI_TX_CLK_P,
    output wire        HDMI_TX_CLK_N,

    // UART
    output wire        uart_tx,

    // Debug LEDs
    output wire [7:0]  LED
);
    // Clock Generation
    // sys_clk (100MHz): CLK100MHZ from onboard crystal oscillator
    // pixel_clk (25MHz) + serial_clk (125MHz): PLL 

    wire sys_clk = CLK100MHZ;

    wire pixel_clk;     // 25 MHz
    wire serial_clk;    // 125 MHz
    wire pll_locked;

    clk_wiz_0 pll_inst (
        .clk_in1  (CLK100MHZ),
        .clk_out1 (pixel_clk),
        .clk_out2 (serial_clk),
        .reset    (~CPU_RESETN),
        .locked   (pll_locked)
    );

    // Reset Synchronizers for each clock domain

    // --- sys_clk domain (100 MHz) ---
    reg [2:0] rst_sys_sync;
    wire sys_reset = rst_sys_sync[2];

    always @(posedge sys_clk or negedge pll_locked) begin
        if (!pll_locked)
            rst_sys_sync <= 3'b111;
        else
            rst_sys_sync <= {rst_sys_sync[1:0], 1'b0};
    end

    // --- pixel_clk domain (25 MHz) ---
    reg [2:0] rst_pix_sync;
    wire pix_reset = rst_pix_sync[2];

    always @(posedge pixel_clk or negedge pll_locked) begin
        if (!pll_locked)
            rst_pix_sync <= 3'b111;
        else
            rst_pix_sync <= {rst_pix_sync[1:0], 1'b0};
    end

    // CPU Clock Enable — FreeRTOS: always ON
    reg cpu_clk_enable;
    always @(posedge sys_clk or posedge sys_reset) begin
        if (sys_reset)
            cpu_clk_enable <= 1'b0;
        else
            cpu_clk_enable <= 1'b1;
    end

    
    // PS/2 — IOBUF + 200ms Inhibit (pixel_clk domain)
    wire ps2_clk_i, ps2_data_i;
    wire ps2_clk_o, ps2_clk_t;

    IOBUF #(.DRIVE(12), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW"))
    iobuf_ps2_clk (
        .O  (ps2_clk_i),
        .IO (PS2_CLK),
        .I  (ps2_clk_o),
        .T  (ps2_clk_t)
    );

    IOBUF #(.DRIVE(12), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW"))
    iobuf_ps2_data (
        .O  (ps2_data_i),
        .IO (PS2_DATA),
        .I  (1'b0),
        .T  (1'b1)
    );

    // 200ms inhibit timer (25MHz × 0.2s = 5,000,000)
    localparam INHIBIT_COUNT = 5_000_000;
    reg [22:0] inhibit_timer;
    reg        inhibit_done;

    always @(posedge pixel_clk or posedge pix_reset) begin
        if (pix_reset) begin
            inhibit_timer <= 0;
            inhibit_done  <= 1'b0;
        end else if (!inhibit_done) begin
            if (inhibit_timer == INHIBIT_COUNT - 1)
                inhibit_done <= 1'b1;
            else
                inhibit_timer <= inhibit_timer + 1;
        end
    end

    assign ps2_clk_o = 1'b0;
    assign ps2_clk_t = inhibit_done ? 1'b1 : 1'b0;

    
    // PS/2 Receiver (pixel_clk domain)
    wire [7:0] scancode;
    wire       scancode_valid;

    ps2_rx ps2 (
        .clk      (pixel_clk),
        .rst      (pix_reset),
        .ps2_clk  (ps2_clk_i),
        .ps2_dat  (ps2_data_i),
        .scancode (scancode),
        .valid    (scancode_valid)
    );

    
    // PS/2 CDC — scancode를 pixel_clk → sys_clk 도메인으로 전달
    
    //
    // toggle 방식 CDC:
    //   pixel_clk: valid 시 scancode 래치 + toggle 반전
    //   sys_clk:   toggle 변화 감지 → scancode 캡처 + new_data 세트
    //              CPU가 0x1003_0004에 쓰면 new_data 클리어

    // --- pixel_clk domain ---
    reg [7:0] kb_scancode_pix;
    reg       kb_toggle_pix;

    always @(posedge pixel_clk or posedge pix_reset) begin
        if (pix_reset) begin
            kb_scancode_pix <= 8'h00;
            kb_toggle_pix   <= 1'b0;
        end else if (scancode_valid) begin
            kb_scancode_pix <= scancode;
            kb_toggle_pix   <= ~kb_toggle_pix;
        end
    end

    // --- sys_clk domain ---
    reg [1:0] kb_toggle_sync;
    reg       kb_toggle_prev;
    reg [7:0] kb_scancode_sys;
    reg       kb_new_data;

    // KB acknowledge: CPU writes to 0x1003_0004
    wire kb_ack;   // 정의는 MMIO 쓰기 섹션에서

    always @(posedge sys_clk or posedge sys_reset) begin
        if (sys_reset) begin
            kb_toggle_sync <= 2'b00;
            kb_toggle_prev <= 1'b0;
            kb_scancode_sys <= 8'h00;
            kb_new_data     <= 1'b0;
        end else begin
            // 2-stage synchronizer for toggle signal
            kb_toggle_sync <= {kb_toggle_sync[0], kb_toggle_pix};
            kb_toggle_prev <= kb_toggle_sync[1];

            // Toggle 변화 감지 → 새 스캔코드 도착
            if (kb_toggle_sync[1] != kb_toggle_prev) begin
                kb_scancode_sys <= kb_scancode_pix;  // 안전: toggle 후 값 안정
                kb_new_data     <= 1'b1;
            end

            // CPU acknowledge로 클리어
            if (kb_ack)
                kb_new_data <= 1'b0;
        end
    end

    
    // CLINT — Machine Timer (sys_clk domain)
    wire        timer_interrupt;
    wire [31:0] clint_read_data;

    // CLINT 쓰기: CPU가 0x0200_xxxx에 쓸 때
    wire clint_we = MMIO_data_memory_write_enable &&
                    (MMIO_data_memory_address[31:16] == 16'h0200);

    clint #(
        .CLK_FREQ  (100_000_000),
        .TICK_FREQ (1_000)
    ) clint_inst (
        .clk           (sys_clk),
        .rst           (sys_reset),
        .write_enable  (clint_we),
        .write_data    (MMIO_data_memory_write_data),
        .write_address (MMIO_data_memory_address),
        .read_address  (MMIO_data_memory_address),
        .read_data     (clint_read_data),
        .timer_interrupt (timer_interrupt)
    );

    
    // 8. UART (sys_clk domain)
    wire       tx_start;
    wire [7:0] tx_data;
    wire       tx_busy;
    wire [7:0] mmio_uart_tx_data;
    wire       mmio_uart_tx_start;
    wire [XLEN-1:0] mmio_uart_status;
    wire       mmio_uart_status_hit;

    UnifiedUARTController unified_uart_controller (
        .clk           (sys_clk),
        .reset         (sys_reset),
        .btn_up        (1'b0),         //unused
        .mmio_tx_data  (mmio_uart_tx_data),
        .mmio_tx_start (mmio_uart_tx_start),
        .tx_start      (tx_start),
        .tx_data       (tx_data),
        .benchmark_start () //unused
    );

    UARTTX uart_tx (
        .clk      (sys_clk),
        .reset    (sys_reset),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx       (uart_tx),
        .tx_busy  (tx_busy)
    );

    MMIOInterface #(.XLEN(XLEN)) mmio_interface (
        .clk                       (sys_clk),
        .clk_enable                (cpu_clk_enable),
        .reset                     (sys_reset),
        .data_memory_write_data    (MMIO_data_memory_write_data),
        .data_memory_address       (MMIO_data_memory_address),
        .data_memory_write_enable  (MMIO_data_memory_write_enable),
        .UART_busy                 (tx_busy),
        .mmio_uart_tx_data         (mmio_uart_tx_data),
        .mmio_uart_status          (mmio_uart_status),
        .mmio_uart_tx_start        (mmio_uart_tx_start),
        .mmio_uart_status_hit      (mmio_uart_status_hit)
    );

    
    // SoC MMIO Read Mux (combinational)
    
    // CPU가 MMIO 주소를 읽을 때 올바른 데이터를 돌려주는 통합 mux.
    // CPU 내부의 mmio_hit_reg가 이 데이터를 선택할지 결정.

    reg [XLEN-1:0] soc_mmio_read_data;

    always @(*) begin
        casez (MMIO_data_memory_address)
            32'h0200_????: soc_mmio_read_data = clint_read_data;
            32'h1001_0004: soc_mmio_read_data = {31'b0, tx_busy};
            32'h1003_0000: soc_mmio_read_data = {24'b0, kb_scancode_sys};
            32'h1003_0004: soc_mmio_read_data = {31'b0, kb_new_data};
            default:       soc_mmio_read_data = 32'b0;
        endcase
    end

    
    // MMIO Write Decode (sys_clk domain)
    

    // VRAM 쓰기: 0x1002_0000 ~ 0x1002_095F
    wire vram_we = MMIO_data_memory_write_enable &&
                   (MMIO_data_memory_address[31:16] == 16'h1002) &&
                   (MMIO_data_memory_address[15:0] < 16'h0960);
    wire [11:0] vram_waddr = MMIO_data_memory_address[11:0];
    wire [7:0]  vram_wdata = MMIO_data_memory_write_data[7:0];

    // KB acknowledge: 0x1003_0004 쓰기
    assign kb_ack = MMIO_data_memory_write_enable &&
                    (MMIO_data_memory_address == 32'h1003_0004);

    
    // CPU Core (sys_clk domain)

    wire [31:0]     retire_instruction;
    wire [XLEN-1:0] MMIO_data_memory_write_data;
    wire [XLEN-1:0] MMIO_data_memory_address;
    wire            MMIO_data_memory_write_enable;

    RV32IM72F8SP #(.XLEN(XLEN)) rv32im72f8sp (
        .clk                        (sys_clk),
        .clk_enable                 (cpu_clk_enable),
        .reset                      (sys_reset),
        .UART_busy                  (tx_busy),
        .timer_interrupt_pending    (timer_interrupt),
        .mmio_read_data             (soc_mmio_read_data),

        .retire_instruction         (retire_instruction),
        .MMIO_data_memory_write_data    (MMIO_data_memory_write_data),
        .MMIO_data_memory_address       (MMIO_data_memory_address),
        .MMIO_data_memory_write_enable  (MMIO_data_memory_write_enable)
    );

    
    // Dual-Port VRAM (쓰기: sys_clk, 읽기: pixel_clk)
    wire [6:0] vga_col;
    wire [4:0] vga_row;
    wire [7:0] vram_char_out;
    wire [11:0] vram_read_addr = vga_row * 7'd80 + {5'b0, vga_col};

    VRAM vram (
        // Port A — CPU write (100 MHz)
        .clk_a   (sys_clk),
        .we_a    (vram_we),
        .addr_a  (vram_waddr),
        .din_a   (vram_wdata),

        // Port B — VGA read (25 MHz)
        .clk_b   (pixel_clk),
        .addr_b  (vram_read_addr),
        .dout_b  (vram_char_out)
    );

    
    // Font ROM (combinational — 클럭 도메인 무관)
    wire [7:0] font_char;
    wire [3:0] font_row_idx;
    wire [7:0] font_bitmap;

    font_rom fnt (
        .char   (font_char),
        .row    (font_row_idx),
        .bitmap (font_bitmap)
    );

    
    // VGA Controller (pixel_clk domain)
    // char_buffer 대신 VRAM에서 읽은 vram_char_out을 사용
    wire [3:0] vga_r, vga_g, vga_b;
    wire       hsync, vsync;

    vga_ctrl vga (
        .clk_25m    (pixel_clk),
        .rst        (pix_reset),
        .buf_col    (vga_col),
        .buf_row    (vga_row),
        .char_out   (vram_char_out),
        .font_char  (font_char),
        .font_row   (font_row_idx),
        .font_bitmap(font_bitmap),
        .hsync      (hsync),
        .vsync      (vsync),
        .vga_r      (vga_r),
        .vga_g      (vga_g),
        .vga_b      (vga_b)
    );

    
    // RGB 4-bit → 8-bit 확장 + 채널 스왑
    wire [7:0] r8 = {vga_r, vga_r};
    wire [7:0] g8 = {vga_g, vga_g};
    wire [7:0] b8 = {vga_b, vga_b};
    wire [23:0] vid_data = {r8, b8, g8};   // 채널 순서: {R, B, G}

    
    // Video Active 재생성
    // vga_ctrl이 vde를 export하지 않으므로 top에서 재생성
    reg [9:0] h_cnt, v_cnt;

    always @(posedge pixel_clk or posedge pix_reset) begin
        if (pix_reset) begin
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

    reg video_active;
    always @(posedge pixel_clk) begin
        video_active <= (h_cnt < 640) && (v_cnt < 480);
    end

    
    // rgb2dvi — HDMI TMDS Encoder
    

    rgb2dvi_0 hdmi_encoder (
        .TMDS_Clk_p  (HDMI_TX_CLK_P),
        .TMDS_Clk_n  (HDMI_TX_CLK_N),
        .TMDS_Data_p (HDMI_TX_P),
        .TMDS_Data_n (HDMI_TX_N),
        .vid_pData   (vid_data),
        .vid_pHSync  (hsync),
        .vid_pVSync  (vsync),
        .vid_pVDE    (video_active),
        .PixelClk    (pixel_clk),
        .SerialClk   (serial_clk),
        .aRst        (pix_reset)
    );

    
    // Debug LEDs
    // LED[0]: cpu_clk_enable
    // LED[1]: timer_interrupt
    // LED[2]: kb_new_data
    // LED[3]: inhibit_done
    // LED[7:4]: 마지막 scancode 하위 4비트

    assign LED[0]   = cpu_clk_enable;
    assign LED[1]   = timer_interrupt;
    assign LED[2]   = kb_new_data;
    assign LED[3]   = inhibit_done;
    assign LED[7:4] = kb_scancode_sys[3:0];

endmodule