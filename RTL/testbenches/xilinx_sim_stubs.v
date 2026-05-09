// ============================================================================
// Xilinx IP Behavioral Stubs for Vivado Simulation
// ============================================================================
// 이 파일은 Vivado behavioral simulation에서 Xilinx IP 없이 
// SoC TOP을 시뮬레이션하기 위한 stub 모듈들입니다.
//
// 사용법: Vivado에서 Simulation Sources에 추가하되,
//         실제 IP가 프로젝트에 있으면 이 파일은 제외하세요.
// ============================================================================

// ============================================================================
// clk_wiz_0 — PLL Stub
// ============================================================================
// clk_out1 = pixel_clk  (25 MHz,  period = 40ns)
// clk_out2 = serial_clk (125 MHz, period = 8ns)  — 시뮬레이션에서는 미사용
// clk_out3 = sys_clk    (100 MHz, period = 10ns)
// ============================================================================
module clk_wiz_0 (
    input  wire clk_in1,
    output reg  clk_out1,   // pixel_clk  25 MHz
    output reg  clk_out2,   // serial_clk 125 MHz
    output reg  clk_out3,   // sys_clk    100 MHz
    input  wire reset,
    output reg  locked
);

    // pixel_clk: 25 MHz (period = 40ns)
    initial clk_out1 = 0;
    always #20 clk_out1 = ~clk_out1;

    // serial_clk: 125 MHz (period = 8ns)
    initial clk_out2 = 0;
    always #4 clk_out2 = ~clk_out2;

    // sys_clk: 100 MHz (period = 10ns)
    initial clk_out3 = 0;
    always #5 clk_out3 = ~clk_out3;

    // PLL lock — 리셋 해제 후 200ns 뒤 lock
    initial locked = 0;
    always @(posedge clk_in1 or posedge reset) begin
        if (reset)
            locked <= 1'b0;
    end

    initial begin
        #200;
        @(posedge clk_in1);
        locked = 1'b1;
    end

endmodule

// ============================================================================
// rgb2dvi_0 — HDMI TMDS Encoder Stub
// ============================================================================
// 시뮬레이션에서 TMDS 인코딩은 불필요하므로 출력을 0으로 고정합니다.
// ============================================================================
module rgb2dvi_0 (
    output wire        TMDS_Clk_p,
    output wire        TMDS_Clk_n,
    output wire [2:0]  TMDS_Data_p,
    output wire [2:0]  TMDS_Data_n,
    input  wire [23:0] vid_pData,
    input  wire        vid_pHSync,
    input  wire        vid_pVSync,
    input  wire        vid_pVDE,
    input  wire        PixelClk,
    input  wire        SerialClk,
    input  wire        aRst
);

    assign TMDS_Clk_p  = 1'b0;
    assign TMDS_Clk_n  = 1'b1;
    assign TMDS_Data_p = 3'b000;
    assign TMDS_Data_n = 3'b111;

endmodule

// ============================================================================
// IOBUF — Xilinx I/O Buffer Stub
// ============================================================================
`ifndef IOBUF_DEFINED
`define IOBUF_DEFINED
module IOBUF #(
    parameter DRIVE        = 12,
    parameter IBUF_LOW_PWR = "TRUE",
    parameter IOSTANDARD   = "DEFAULT",
    parameter SLEW         = "SLOW"
)(
    output wire O,
    inout  wire IO,
    input  wire I,
    input  wire T       // T=1: Hi-Z (input mode), T=0: drive
);

    assign IO = (T == 1'b0) ? I : 1'bz;
    assign O  = IO;

endmodule
`endif
