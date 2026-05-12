module RV64IM72F8SPSoCTOP #(
    parameter XLEN = 64
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
 
    // ========================================================================
    // 1. Clock Generation
    // ========================================================================
  
    wire pixel_clk;
    wire serial_clk;
    wire pll_locked;
 
    clk_wiz_0 pll_inst (
        .clk_in1  (CLK100MHZ),
        .clk_out1 (pixel_clk),
        .clk_out2 (serial_clk),
        .clk_out3 (sys_clk),
        .reset    (~CPU_RESETN),
        .locked   (pll_locked)
    );
 
    // ========================================================================
    // 2. Reset Synchronizers
    // ========================================================================
 
    reg [2:0] rst_sys_sync;
    wire sys_reset = rst_sys_sync[2];
 
    always @(posedge sys_clk or negedge pll_locked) begin
        if (!pll_locked)
            rst_sys_sync <= 3'b111;
        else
            rst_sys_sync <= {rst_sys_sync[1:0], 1'b0};
    end
 
    reg [2:0] rst_pix_sync;
    wire pix_reset = rst_pix_sync[2];
 
    always @(posedge pixel_clk or negedge pll_locked) begin
        if (!pll_locked)
            rst_pix_sync <= 3'b111;
        else
            rst_pix_sync <= {rst_pix_sync[1:0], 1'b0};
    end
 
    // ========================================================================
    // 3. CPU Clock Enable
    // ========================================================================
 
    reg cpu_clk_enable;
    always @(posedge sys_clk or posedge sys_reset) begin
        if (sys_reset)
            cpu_clk_enable <= 1'b0;
        else
            cpu_clk_enable <= 1'b1;
    end
 
    // ========================================================================
    // 4. PS/2 - IOBUF + 200ms Inhibit (pixel_clk domain)
    // ========================================================================
 
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
 
    // ========================================================================
    // 5. PS/2 Receiver (pixel_clk domain)
    // ========================================================================
 
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
 
    // ========================================================================
    // 6. PS/2 CDC - pixel_clk → sys_clk + 8-entry Inline FIFO
    // ========================================================================
    //
    // 동작 흐름:
    //   pixel_clk 도메인: scancode_valid 펄스마다 toggle 반전 + scancode 래치
    //   sys_clk   도메인: toggle CDC → 엣지 감지 → FIFO push
    //   CPU 읽기: KB_SCAN = FIFO head, KB_STAT[0] = !empty
    //   CPU 쓰기: KB_STAT에 1 write → FIFO pop (acknowledge)
    //
    // ========================================================================

    // --- pixel_clk 도메인: scancode 래치 + toggle ---
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

    // --- sys_clk 도메인: toggle CDC + 엣지 감지 ---
    reg [1:0] kb_toggle_sync;
    reg       kb_toggle_prev;

    always @(posedge sys_clk or posedge sys_reset) begin
        if (sys_reset) begin
            kb_toggle_sync <= 2'b00;
            kb_toggle_prev <= 1'b0;
        end else begin
            kb_toggle_sync <= {kb_toggle_sync[0], kb_toggle_pix};
            kb_toggle_prev <= kb_toggle_sync[1];
        end
    end

    wire kb_cdc_pulse = (kb_toggle_sync[1] != kb_toggle_prev);

    // --- 8-entry inline FIFO (distributed RAM, 별도 모듈 없음) ---
    //
    // 주의: Vivado distributed RAM 추론 조건
    //   - memory write는 async reset이 없는 always @(posedge clk) 블록에 있어야 함
    //   - pointer 로직과 memory write를 분리해야 정상 합성됨
    //
    wire kb_ack;    // ← MMIO KB_STAT write (pop)

    (* ram_style = "distributed" *) reg [7:0] kb_fifo_mem [0:7];
    reg [3:0] kb_fifo_wr;   // [3]=wrap bit, [2:0]=address
    reg [3:0] kb_fifo_rd;

    wire kb_fifo_empty = (kb_fifo_wr == kb_fifo_rd);
    wire kb_fifo_full  = (kb_fifo_wr[3] != kb_fifo_rd[3]) &&
                         (kb_fifo_wr[2:0] == kb_fifo_rd[2:0]);

    wire       kb_fifo_push = kb_cdc_pulse && !kb_fifo_full;
    wire       kb_fifo_pop  = kb_ack && !kb_fifo_empty;

    wire [7:0] kb_scancode_sys = kb_fifo_mem[kb_fifo_rd[2:0]];  // → MMIO
    wire       kb_new_data     = ~kb_fifo_empty;                 // → MMIO

    // (A) pointer 로직: async reset 포함
    always @(posedge sys_clk or posedge sys_reset) begin
        if (sys_reset) begin
            kb_fifo_wr <= 4'd0;
            kb_fifo_rd <= 4'd0;
        end else begin
            if (kb_fifo_push)
                kb_fifo_wr <= kb_fifo_wr + 4'd1;
            if (kb_fifo_pop)
                kb_fifo_rd <= kb_fifo_rd + 4'd1;
        end
    end

    // (B) memory write: async reset 없음 — Vivado distributed RAM 추론 필수 조건
    always @(posedge sys_clk) begin
        if (kb_fifo_push)
            kb_fifo_mem[kb_fifo_wr[2:0]] <= kb_scancode_pix;
    end
 
    // ========================================================================
    // 7. CPU Core (sys_clk domain)
    // ========================================================================
 
    wire [31:0]     retire_instruction;
    wire [XLEN-1:0] cpu_mmio_address;
    wire [XLEN-1:0] cpu_mmio_write_data;
    wire            cpu_mmio_write_enable;
    wire            timer_interrupt;
    wire [XLEN-1:0] mmio_read_data;
 
    RV64IM72F8SP #(.XLEN(XLEN)) cpu (
        .clk                        (sys_clk),
        .clk_enable                 (cpu_clk_enable),
        .reset                      (sys_reset),
        .UART_busy                  (tx_busy),
        .timer_interrupt_pending    (timer_interrupt),
        .MMIO_read_data             (mmio_read_data),
 
        .retire_instruction             (retire_instruction),
        .MMIO_data_memory_write_data    (cpu_mmio_write_data),
        .MMIO_data_memory_address       (cpu_mmio_address),
        .MMIO_data_memory_write_enable  (cpu_mmio_write_enable)
    );
 
    // ========================================================================
    // 8. MMIO Interface 
    // ========================================================================
 
    wire       clint_we;
    wire       vram_we;
    wire [11:0] vram_addr;
    wire [7:0]  vram_data;
    wire [7:0]  uart_tx_data;
    wire        uart_tx_start;
    wire [XLEN-1:0] clint_read_data;
 
    MMIOInterface #(.XLEN(XLEN)) mmio (
        .clk            (sys_clk),
        .clk_enable     (cpu_clk_enable),
        .reset          (sys_reset),
 
        // CPU bus
        .address        (cpu_mmio_address),
        .write_data     (cpu_mmio_write_data),
        .write_enable   (cpu_mmio_write_enable),
        .mmio_read_data (mmio_read_data),
 
        // UART
        .uart_busy      (tx_busy),
        .uart_tx_data   (uart_tx_data),
        .uart_tx_start  (uart_tx_start),
 
        // CLINT
        .clint_read_data (clint_read_data),
        .clint_we        (clint_we),
 
        // VRAM
        .vram_we    (vram_we),
        .vram_addr  (vram_addr),
        .vram_data  (vram_data),
 
        // Keyboard
        .kb_scancode (kb_scancode_sys),
        .kb_new_data (kb_new_data),
        .kb_ack      (kb_ack)
    );
 
    // ========================================================================
    // 9. CLINT (sys_clk domain)
    // ========================================================================
 
    clint #(
        .CLK_FREQ  (100_000_000),
        .TICK_FREQ (1_000)
    ) clint_inst (
        .clk            (sys_clk),
        .rst            (sys_reset),
        .write_enable   (clint_we),
        .write_data     (cpu_mmio_write_data),
        .write_address  (cpu_mmio_address),
        .read_address   (cpu_mmio_address),
        .read_data      (clint_read_data),
        .timer_interrupt (timer_interrupt)
    );
 
    // ========================================================================
    // 10. UART TX (sys_clk domain)
    // ========================================================================
 
    wire tx_busy;
 
    UARTTX uart_tx_inst (
        .clk      (sys_clk),
        .reset    (sys_reset),
        .tx_start (uart_tx_start),
        .tx_data  (uart_tx_data),
        .tx       (uart_tx),
        .tx_busy  (tx_busy)
    );
 
    // ========================================================================
    // 11. Dual-Port VRAM 
    // ========================================================================
 
    wire [6:0]  vga_col;
    wire [4:0]  vga_row;
    wire [7:0]  vram_char_out;
    wire [11:0] vram_read_addr = vga_row * 7'd80 + {5'b0, vga_col};
 
    VRAM vram_inst (
        .clk_a   (sys_clk),
        .we_a    (vram_we),
        .addr_a  (vram_addr),
        .din_a   (vram_data),
 
        .clk_b   (pixel_clk),
        .addr_b  (vram_read_addr),
        .dout_b  (vram_char_out)
    );
 
    // ========================================================================
    // 12. Font ROM
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
    // 13. VGA Controller (pixel_clk domain)
    // ========================================================================
 
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
 
    // ========================================================================
    // 14. RGB
    // ========================================================================
 
    wire [7:0] r8 = {vga_r, vga_r};
    wire [7:0] g8 = {vga_g, vga_g};
    wire [7:0] b8 = {vga_b, vga_b};
    wire [23:0] vid_data = {r8, b8, g8};
 
    // ========================================================================
    // 15. Video Active 
    // ========================================================================
 
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
 
    // ========================================================================
    // 16. rgb2dvi - HDMI TMDS Encoder
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
        .PixelClk    (pixel_clk),
        .SerialClk   (serial_clk),
        .aRst        (pix_reset)
    );
 
    // ========================================================================
    // 17. Debug LEDs
    // ========================================================================
 
    assign LED[0]   = cpu_clk_enable;
    assign LED[1]   = timer_interrupt;
    assign LED[2]   = kb_new_data;
    assign LED[3]   = inhibit_done;
    assign LED[7:4] = kb_scancode_sys[3:0];
 
endmodule