module vga_ctrl (
    input  wire        clk_25m,
    input  wire        rst,
    // 폰트/문자 버퍼 연결
    output wire [6:0]  buf_col,
    output wire [4:0]  buf_row,
    input  wire [7:0]  char_out,
    output wire [7:0]  font_char,
    output wire [3:0]  font_row,
    input  wire [7:0]  font_bitmap,
    // VGA 출력
    output reg         hsync,
    output reg         vsync,
    output reg  [3:0]  vga_r,
    output reg  [3:0]  vga_g,
    output reg  [3:0]  vga_b
);
    // 640x480 @ 60Hz 타이밍
    localparam H_ACTIVE = 640, H_FP = 16, H_SYNC = 96,  H_BP = 48;
    localparam V_ACTIVE = 480, V_FP = 10, V_SYNC = 2,   V_BP = 33;
    localparam H_TOTAL  = 800, V_TOTAL = 525;

    reg [9:0] hcnt, vcnt;

    // 카운터
    always @(posedge clk_25m or posedge rst) begin
        if (rst) begin hcnt <= 0; vcnt <= 0; end
        else begin
            if (hcnt == H_TOTAL-1) begin
                hcnt <= 0;
                vcnt <= (vcnt == V_TOTAL-1) ? 0 : vcnt+1;
            end else
                hcnt <= hcnt + 1;
        end
    end

    wire active = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    // 글자 위치 계산 (8x8 폰트 기준)
    // 640/8 = 80열, 480/8 = 60행 (여기서는 30행만 사용)
    assign buf_col  = hcnt[9:3];       // hcnt / 8
    assign buf_row  = vcnt[8:4];       // vcnt / 16 (행간격 16픽셀)
    assign font_char = char_out;
    assign font_row  = vcnt[3:0];      // 글자 내 행

    // 현재 픽셀이 글자인지
    wire pixel_on = active & font_bitmap[7 - hcnt[2:0]];

    // sync 신호
    always @(posedge clk_25m) begin
        hsync <= ~(hcnt >= H_ACTIVE+H_FP && hcnt < H_ACTIVE+H_FP+H_SYNC);
        vsync <= ~(vcnt >= V_ACTIVE+V_FP && vcnt < V_ACTIVE+V_FP+V_SYNC);
        // 글자: 흰색, 배경: 파란색
        vga_r <= pixel_on ? 4'hF : 4'h0;
        vga_g <= pixel_on ? 4'hF : 4'h0;
        vga_b <= 4'hF;
    end
endmodule