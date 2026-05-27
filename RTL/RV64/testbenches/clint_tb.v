`timescale 1ns / 1ps
 
// ============================================================
// CLINT 테스트벤치
// 테스트 항목:
//   1. 리셋 후 mtime = 0 확인
//   2. mtime tick 증가 확인
//   3. mtime 쓰기 확인
//   4. mtimecmp 쓰기 확인
//   5. timer_interrupt 발생 확인 (mtime >= mtimecmp)
//   6. mtimecmp 갱신 후 timer_interrupt 클리어 확인
// ============================================================
 
module clint_tb;
 
// 시뮬레이션용 파라미터 (빠른 시뮬을 위해 작은 값 사용)
localparam CLK_FREQ  = 10;   // 10Hz
localparam TICK_FREQ = 2;    // 2Hz → 5클럭마다 tick 1번
localparam CLK_PERIOD = 10;  // 10ns
 
// ============================================================
// 신호 선언
// ============================================================
reg         clk;
reg         rst;
reg         write_enable;
reg  [31:0] write_data;
reg  [31:0] write_address;
reg  [31:0] read_address;
wire [31:0] read_data;
wire        timer_interrupt;
 
// ============================================================
// DUT 인스턴스
// ============================================================
clint #(
    .CLK_FREQ (CLK_FREQ),
    .TICK_FREQ(TICK_FREQ)
) dut (
    .clk           (clk),
    .rst           (rst),
    .write_enable  (write_enable),
    .write_data    (write_data),
    .write_address (write_address),
    .read_address  (read_address),
    .read_data     (read_data),
    .timer_interrupt(timer_interrupt)
);
 
// ============================================================
// 클럭 생성
// ============================================================
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;
 
// ============================================================
// 태스크: 쓰기
// ============================================================
task write_reg;
    input [31:0] addr;
    input [31:0] data;
    begin
        @(posedge clk);
        write_address = addr;
        write_data    = data;
        write_enable  = 1;
        @(posedge clk);
        write_enable  = 0;
    end
endtask
 
// ============================================================
// 태스크: 읽기
// ============================================================
task read_reg;
    input [31:0] addr;
    begin
        @(posedge clk);
        read_address = addr;
    end
endtask
 
// ============================================================
// 메인 테스트
// ============================================================
initial begin
    $dumpfile("clint_tb.vcd");
    $dumpvars(0, clint_tb);
 
    // 초기값
    rst           = 1;
    write_enable  = 0;
    write_data    = 0;
    write_address = 0;
    read_address  = 0;
 
    // -------------------------------------------------------
    // 테스트 1: 리셋 후 mtime = 0 확인
    // -------------------------------------------------------
    repeat(3) @(posedge clk);
    rst = 0;
    $display("=== 테스트 1: 리셋 해제 ===");
    read_reg(32'h0200_0000);
    @(posedge clk);
    $display("MTIME low  = %0d (기대값: 0)", read_data);
    read_reg(32'h0200_0004);
    @(posedge clk);
    $display("MTIME high = %0d (기대값: 0)", read_data);
 
    // -------------------------------------------------------
    // 테스트 2: mtime tick 증가 확인
    // 5클럭마다 tick 1번 → 20클럭 후 mtime = 4
    // -------------------------------------------------------
    $display("\n=== 테스트 2: mtime tick 증가 확인 ===");
    repeat(20) @(posedge clk);
    read_reg(32'h0200_0000);
    @(posedge clk);
    $display("MTIME low = %0d (기대값: 4 근처)", read_data);
 
    // -------------------------------------------------------
    // 테스트 3: mtime 쓰기 확인
    // -------------------------------------------------------
    $display("\n=== 테스트 3: mtime 쓰기 확인 ===");
    write_reg(32'h0200_0000, 32'd999);  // mtime low = 999
    write_reg(32'h0200_0004, 32'd0);    // mtime high = 0
    read_reg(32'h0200_0000);
    @(posedge clk);
    $display("MTIME low = %0d (기대값: 999)", read_data);
 
    // -------------------------------------------------------
    // 테스트 4: mtimecmp 쓰기 확인
    // -------------------------------------------------------
    $display("\n=== 테스트 4: mtimecmp 쓰기 확인 ===");
    write_reg(32'h0200_0008, 32'd50);  // mtimecmp low = 50
    write_reg(32'h0200_000C, 32'd0);   // mtimecmp high = 0
    read_reg(32'h0200_0008);
    @(posedge clk);
    $display("MTIMECMP low = %0d (기대값: 50)", read_data);
 
    // -------------------------------------------------------
    // 테스트 5: timer_interrupt 발생 확인
    // mtime을 작은 값으로 리셋 후 mtimecmp = 10 설정
    // mtime이 10 도달하면 interrupt = 1
    // -------------------------------------------------------
    $display("\n=== 테스트 5: timer_interrupt 발생 확인 ===");
    write_reg(32'h0200_0000, 32'd0);   // mtime low 리셋
    write_reg(32'h0200_0004, 32'd0);   // mtime high 리셋
    write_reg(32'h0200_0008, 32'hFFFF_FFFF);  // 1. low를 먼저 최대값으로 막아놓고
    write_reg(32'h0200_000C, 32'd0);           // 2. high 설정
    write_reg(32'h0200_0008, 32'd10);          // 3. low 최종값 설정
 
    repeat(100) @(posedge clk);
    $display("timer_interrupt = %0d (기대값: 1)", timer_interrupt);
    read_reg(32'h0200_0000);
    @(posedge clk);
    $display("현재 MTIME low = %0d", read_data);
 
    // -------------------------------------------------------
    // 테스트 6: mtimecmp 갱신 후 timer_interrupt 클리어
    // -------------------------------------------------------
    $display("\n=== 테스트 6: mtimecmp 갱신 후 interrupt 클리어 ===");
    write_reg(32'h0200_000C, 32'hFFFF_FFFF);  
    write_reg(32'h0200_0008, 32'hFFFF_FFFF); 
    @(posedge clk);
    $display("timer_interrupt = %0d (기대값: 0)", timer_interrupt);
 
    $display("\n=== 테스트 완료 ===");
    #100;
    $finish;
end
 
// ============================================================
// interrupt 변화 모니터링
// ============================================================
always @(posedge timer_interrupt)
    $display("[interrupt 발생] timer_interrupt = 1, 시각 = %0t ns", $time);
 
always @(negedge timer_interrupt)
    $display("[interrupt 클리어] timer_interrupt = 0, 시각 = %0t ns", $time);
 
endmodule