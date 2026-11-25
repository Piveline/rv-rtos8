`timescale 1ps/100fs
//=============================================================================
// tb_design_1 : 메모리 경로(SmartConnect + MIG) 검증용 테스트벤치 (Vivado xsim)
//  - DUT  : design_1_wrapper (Block Design design_1)
//  - 메모리: ddr3_model.sv (MIG 예제 설계의 Micron DDR3 모델, x16 4Gb sg125)
//  - S00 = I-cache 자리(읽기 전용), S01 = D-cache 자리(읽기/쓰기)
// 검사 항목
//  1) init_calib_complete 가 1이 되고 이후 계속 1을 유지하는가
//  2) S01 4-beat 버스트 쓰기 -> B 응답 OKAY -> 같은 주소 읽기 비교
//  3) S01 부분 쓰기(wstrb) 결과가 바이트 단위로 맞는가
//  4) S00(I-cache 자리)가 S01이 쓴 데이터를 같은 주소에서 읽는가 (공유 메모리)
//  5) 읽기 지연(AR 접수 -> 첫 rvalid) 사이클 수 출력
//=============================================================================
module tb_design_1;

  // ---------------- 클럭 / 리셋 ----------------
  reg sys_clock = 1'b0;
  always #5000 sys_clock = ~sys_clock;          // 100MHz 보드 클럭 (주기 10ns = 10000ps)
  reg reset = 1'b0;                             // 보드 리셋 버튼: 0 = 리셋(active-low)
  initial begin #200000; reset = 1'b1; end      // 200ns 후 리셋 해제

  wire cpu_clk;
  wire init_calib_complete_0;

  // ---------------- AXI 신호 (TB = 캐시 역할) ----------------
  reg  [31:0] s00_araddr = 0;
  reg  [1:0] s00_arburst = 0;
  reg  [3:0] s00_arcache = 0;
  reg  [7:0] s00_arlen = 0;
  reg  s00_arlock = 0;
  reg  [2:0] s00_arprot = 0;
  reg  [3:0] s00_arqos = 0;
  reg  [2:0] s00_arsize = 0;
  reg  s00_arvalid = 0;
  reg  [31:0] s00_awaddr = 0;
  reg  [1:0] s00_awburst = 0;
  reg  [3:0] s00_awcache = 0;
  reg  [7:0] s00_awlen = 0;
  reg  s00_awlock = 0;
  reg  [2:0] s00_awprot = 0;
  reg  [3:0] s00_awqos = 0;
  reg  [2:0] s00_awsize = 0;
  reg  s00_awvalid = 0;
  reg  s00_bready = 0;
  reg  s00_rready = 0;
  reg  [63:0] s00_wdata = 0;
  reg  s00_wlast = 0;
  reg  [7:0] s00_wstrb = 0;
  reg  s00_wvalid = 0;
  wire s00_arready;
  wire s00_awready;
  wire [1:0] s00_bresp;
  wire s00_bvalid;
  wire [63:0] s00_rdata;
  wire s00_rlast;
  wire [1:0] s00_rresp;
  wire s00_rvalid;
  wire s00_wready;
  reg  [31:0] s01_araddr = 0;
  reg  [1:0] s01_arburst = 0;
  reg  [3:0] s01_arcache = 0;
  reg  [7:0] s01_arlen = 0;
  reg  s01_arlock = 0;
  reg  [2:0] s01_arprot = 0;
  reg  [3:0] s01_arqos = 0;
  reg  [2:0] s01_arsize = 0;
  reg  s01_arvalid = 0;
  reg  [31:0] s01_awaddr = 0;
  reg  [1:0] s01_awburst = 0;
  reg  [3:0] s01_awcache = 0;
  reg  [7:0] s01_awlen = 0;
  reg  s01_awlock = 0;
  reg  [2:0] s01_awprot = 0;
  reg  [3:0] s01_awqos = 0;
  reg  [2:0] s01_awsize = 0;
  reg  s01_awvalid = 0;
  reg  s01_bready = 0;
  reg  s01_rready = 0;
  reg  [63:0] s01_wdata = 0;
  reg  s01_wlast = 0;
  reg  [7:0] s01_wstrb = 0;
  reg  s01_wvalid = 0;
  wire s01_arready;
  wire s01_awready;
  wire [1:0] s01_bresp;
  wire s01_bvalid;
  wire [63:0] s01_rdata;
  wire s01_rlast;
  wire [1:0] s01_rresp;
  wire s01_rvalid;
  wire s01_wready;

  // ---------------- DDR3 핀 ----------------
  wire [14:0] ddr3_addr;  wire [2:0] ddr3_ba;
  wire ddr3_cas_n, ddr3_ras_n, ddr3_we_n, ddr3_reset_n;
  wire [0:0] ddr3_ck_n, ddr3_ck_p, ddr3_cke, ddr3_odt;
  wire [1:0] ddr3_dm;
  wire [15:0] ddr3_dq;  wire [1:0] ddr3_dqs_n, ddr3_dqs_p;

  // ---------------- DUT ----------------
  design_1_wrapper dut (
    .S00_AXI_0_araddr  (s00_araddr),
    .S00_AXI_0_arburst (s00_arburst),
    .S00_AXI_0_arcache (s00_arcache),
    .S00_AXI_0_arlen   (s00_arlen),
    .S00_AXI_0_arlock  (s00_arlock),
    .S00_AXI_0_arprot  (s00_arprot),
    .S00_AXI_0_arqos   (s00_arqos),
    .S00_AXI_0_arsize  (s00_arsize),
    .S00_AXI_0_arvalid (s00_arvalid),
    .S00_AXI_0_awaddr  (s00_awaddr),
    .S00_AXI_0_awburst (s00_awburst),
    .S00_AXI_0_awcache (s00_awcache),
    .S00_AXI_0_awlen   (s00_awlen),
    .S00_AXI_0_awlock  (s00_awlock),
    .S00_AXI_0_awprot  (s00_awprot),
    .S00_AXI_0_awqos   (s00_awqos),
    .S00_AXI_0_awsize  (s00_awsize),
    .S00_AXI_0_awvalid (s00_awvalid),
    .S00_AXI_0_bready  (s00_bready),
    .S00_AXI_0_rready  (s00_rready),
    .S00_AXI_0_wdata   (s00_wdata),
    .S00_AXI_0_wlast   (s00_wlast),
    .S00_AXI_0_wstrb   (s00_wstrb),
    .S00_AXI_0_wvalid  (s00_wvalid),
    .S00_AXI_0_arready (s00_arready),
    .S00_AXI_0_awready (s00_awready),
    .S00_AXI_0_bresp   (s00_bresp),
    .S00_AXI_0_bvalid  (s00_bvalid),
    .S00_AXI_0_rdata   (s00_rdata),
    .S00_AXI_0_rlast   (s00_rlast),
    .S00_AXI_0_rresp   (s00_rresp),
    .S00_AXI_0_rvalid  (s00_rvalid),
    .S00_AXI_0_wready  (s00_wready),
    .S01_AXI_0_araddr  (s01_araddr),
    .S01_AXI_0_arburst (s01_arburst),
    .S01_AXI_0_arcache (s01_arcache),
    .S01_AXI_0_arlen   (s01_arlen),
    .S01_AXI_0_arlock  (s01_arlock),
    .S01_AXI_0_arprot  (s01_arprot),
    .S01_AXI_0_arqos   (s01_arqos),
    .S01_AXI_0_arsize  (s01_arsize),
    .S01_AXI_0_arvalid (s01_arvalid),
    .S01_AXI_0_awaddr  (s01_awaddr),
    .S01_AXI_0_awburst (s01_awburst),
    .S01_AXI_0_awcache (s01_awcache),
    .S01_AXI_0_awlen   (s01_awlen),
    .S01_AXI_0_awlock  (s01_awlock),
    .S01_AXI_0_awprot  (s01_awprot),
    .S01_AXI_0_awqos   (s01_awqos),
    .S01_AXI_0_awsize  (s01_awsize),
    .S01_AXI_0_awvalid (s01_awvalid),
    .S01_AXI_0_bready  (s01_bready),
    .S01_AXI_0_rready  (s01_rready),
    .S01_AXI_0_wdata   (s01_wdata),
    .S01_AXI_0_wlast   (s01_wlast),
    .S01_AXI_0_wstrb   (s01_wstrb),
    .S01_AXI_0_wvalid  (s01_wvalid),
    .S01_AXI_0_arready (s01_arready),
    .S01_AXI_0_awready (s01_awready),
    .S01_AXI_0_bresp   (s01_bresp),
    .S01_AXI_0_bvalid  (s01_bvalid),
    .S01_AXI_0_rdata   (s01_rdata),
    .S01_AXI_0_rlast   (s01_rlast),
    .S01_AXI_0_rresp   (s01_rresp),
    .S01_AXI_0_rvalid  (s01_rvalid),
    .S01_AXI_0_wready  (s01_wready),
    .cpu_clk               (cpu_clk),
    .ddr3_sdram_addr       (ddr3_addr),
    .ddr3_sdram_ba         (ddr3_ba),
    .ddr3_sdram_cas_n      (ddr3_cas_n),
    .ddr3_sdram_ck_n       (ddr3_ck_n),
    .ddr3_sdram_ck_p       (ddr3_ck_p),
    .ddr3_sdram_cke        (ddr3_cke),
    .ddr3_sdram_dm         (ddr3_dm),
    .ddr3_sdram_dq         (ddr3_dq),
    .ddr3_sdram_dqs_n      (ddr3_dqs_n),
    .ddr3_sdram_dqs_p      (ddr3_dqs_p),
    .ddr3_sdram_odt        (ddr3_odt),
    .ddr3_sdram_ras_n      (ddr3_ras_n),
    .ddr3_sdram_reset_n    (ddr3_reset_n),
    .ddr3_sdram_we_n       (ddr3_we_n),
    .init_calib_complete_0 (init_calib_complete_0),
    .reset                 (reset),
    .sys_clock             (sys_clock)
  );

  // ---------------- DDR3 칩 모델 ----------------
  // Nexys Video 보드는 CS# 핀이 GND에 묶여 있어 MIG에 cs_n 출력이 없음 -> 모델의 cs_n = 0
  ddr3_model u_ddr3 (
    .rst_n   (ddr3_reset_n),
    .ck      (ddr3_ck_p),
    .ck_n    (ddr3_ck_n),
    .cke     (ddr3_cke),
    .cs_n    (1'b0),
    .ras_n   (ddr3_ras_n),
    .cas_n   (ddr3_cas_n),
    .we_n    (ddr3_we_n),
    .dm_tdqs (ddr3_dm),
    .ba      (ddr3_ba),
    .addr    (ddr3_addr),
    .dq      (ddr3_dq),
    .dqs     (ddr3_dqs_p),
    .dqs_n   (ddr3_dqs_n),
    .tdqs_n  (),
    .odt     (ddr3_odt)
  );

  // ---------------- 공통 변수 ----------------
  reg [63:0] wbuf [0:3];
  reg [63:0] rbuf [0:3];
  integer errors = 0;
  integer last_read_latency = 0;
  integer i;
  reg calib_seen = 1'b0;

  // 우리가 쓰지 않는 신호(고정값)와 항상 받을 준비(ready)
  initial begin
    s00_rready = 1'b1;  s00_bready = 1'b1;    // S00: 읽기 전용, AW/W는 0으로 묶어 둠
    s01_rready = 1'b1;  s01_bready = 1'b1;
  end

  // ---- 검사 1: 보정 완료 후 init_calib_complete가 떨어지면 오류 ----
  always @(posedge init_calib_complete_0) calib_seen = 1'b1;
  always @(negedge init_calib_complete_0)
    if (calib_seen) begin
      $display("[%t] ERROR init_calib_complete 가 보정 후 0으로 떨어짐", $time);
      errors = errors + 1;
    end

  // ---- S01 쓰기: addr부터 (len+1) beat, 모든 beat에 같은 strb ----
  task automatic s01_write(input [31:0] addr, input [7:0] len, input [7:0] strb);
    integer k;
    begin
      @(posedge cpu_clk);
      s01_awaddr <= addr; s01_awlen <= len; s01_awsize <= 3'd3; s01_awburst <= 2'b01; s01_awvalid <= 1'b1;
      @(negedge cpu_clk); while (!s01_awready) @(negedge cpu_clk);
      @(posedge cpu_clk); s01_awvalid <= 1'b0;               // AW 핸드셰이크 완료
      for (k = 0; k <= len; k = k + 1) begin
        s01_wdata <= wbuf[k]; s01_wstrb <= strb; s01_wlast <= (k == len); s01_wvalid <= 1'b1;
        @(negedge cpu_clk); while (!s01_wready) @(negedge cpu_clk);
        @(posedge cpu_clk);                                   // W beat 전달
      end
      s01_wvalid <= 1'b0; s01_wlast <= 1'b0;
      @(negedge cpu_clk); while (!s01_bvalid) @(negedge cpu_clk);   // B(쓰기 영수증) 대기
      if (s01_bresp != 2'b00) begin
        $display("[%t] ERROR S01 bresp=%b addr=%h", $time, s01_bresp, addr); errors = errors + 1;
      end else
        $display("[%t] S01 쓰기 완료 addr=%h len=%0d strb=%h  (bresp=OKAY)", $time, addr, len+1, strb);
      @(posedge cpu_clk);
    end
  endtask

  // ---- S00 읽기: addr부터 (len+1) beat를 읽어 rbuf[]에 저장, 첫 데이터까지 지연(사이클) 기록 ----
  task automatic s00_read(input [31:0] addr, input [7:0] len);
    integer i, lat;
    begin
      @(posedge cpu_clk);
      s00_araddr <= addr; s00_arlen <= len; s00_arsize <= 3'd3; s00_arburst <= 2'b01; s00_arvalid <= 1'b1;
      @(negedge cpu_clk); while (!s00_arready) @(negedge cpu_clk);
      @(posedge cpu_clk); s00_arvalid <= 1'b0;              // AR 핸드셰이크 완료
      lat = 0;
      for (i = 0; i <= len; i = i + 1) begin
        @(negedge cpu_clk);
        while (!s00_rvalid) begin @(negedge cpu_clk); if (i == 0) lat = lat + 1; end
        rbuf[i] = s00_rdata;
        if (s00_rresp != 2'b00) begin $display("[%t] ERROR S00 rresp=%b addr=%h", $time, s00_rresp, addr); errors = errors + 1; end
        if (s00_rlast != (i == len)) begin $display("[%t] ERROR S00 rlast 위치 이상 (beat %0d)", $time, i); errors = errors + 1; end
        @(posedge cpu_clk);                                   // rready=1 이므로 이 클럭에 beat 전달
      end
      last_read_latency = lat;
    end
  endtask

  // ---- S01 읽기: addr부터 (len+1) beat를 읽어 rbuf[]에 저장, 첫 데이터까지 지연(사이클) 기록 ----
  task automatic s01_read(input [31:0] addr, input [7:0] len);
    integer i, lat;
    begin
      @(posedge cpu_clk);
      s01_araddr <= addr; s01_arlen <= len; s01_arsize <= 3'd3; s01_arburst <= 2'b01; s01_arvalid <= 1'b1;
      @(negedge cpu_clk); while (!s01_arready) @(negedge cpu_clk);
      @(posedge cpu_clk); s01_arvalid <= 1'b0;              // AR 핸드셰이크 완료
      lat = 0;
      for (i = 0; i <= len; i = i + 1) begin
        @(negedge cpu_clk);
        while (!s01_rvalid) begin @(negedge cpu_clk); if (i == 0) lat = lat + 1; end
        rbuf[i] = s01_rdata;
        if (s01_rresp != 2'b00) begin $display("[%t] ERROR S01 rresp=%b addr=%h", $time, s01_rresp, addr); errors = errors + 1; end
        if (s01_rlast != (i == len)) begin $display("[%t] ERROR S01 rlast 위치 이상 (beat %0d)", $time, i); errors = errors + 1; end
        @(posedge cpu_clk);                                   // rready=1 이므로 이 클럭에 beat 전달
      end
      last_read_latency = lat;
    end
  endtask

  task check(input [63:0] got, input [63:0] exp, input [8*24-1:0] what);
    if (got !== exp) begin
      $display("[%t] ERROR %0s : 읽음=%h 기대=%h", $time, what, got, exp); errors = errors + 1;
    end else
      $display("[%t]   OK  %0s : %h", $time, what, got);
  endtask

  // ---------------- 시나리오 ----------------
  initial begin
    $timeformat(-9, 1, " ns", 12);
    $display("=== tb_design_1 시작: DDR3 보정 대기 ===");
    wait (init_calib_complete_0 === 1'b1);
    $display("[%t] Calibration Done (init_calib_complete = 1)", $time);
    repeat (20) @(posedge cpu_clk);

    // 1) S01 4-beat 쓰기 후 읽기 비교 (캐시 라인 32B 하나)
    wbuf[0] = 64'h0123_4567_89AB_CDEF; wbuf[1] = 64'hFEDC_BA98_7654_3210;
    wbuf[2] = 64'hDEAD_BEEF_CAFE_F00D; wbuf[3] = 64'h1122_3344_5566_7788;
    s01_write(32'h8000_0000, 8'd3, 8'hFF);
    s01_read (32'h8000_0000, 8'd3);
    $display("[%t] S01 읽기 지연: AR 접수 후 첫 데이터까지 %0d 사이클(cpu_clk)", $time, last_read_latency);
    for (i = 0; i < 4; i = i + 1) check(rbuf[i], wbuf[i], "S01 burst read");

    // 2) 부분 쓰기: 8바이트 전체 쓴 뒤 하위 4바이트만 덮어쓰기
    wbuf[0] = 64'h1111_1111_2222_2222;
    s01_write(32'h8000_0100, 8'd0, 8'hFF);
    wbuf[0] = 64'hAAAA_BBBB_CCCC_DDDD;
    s01_write(32'h8000_0100, 8'd0, 8'h0F);                  // 바이트 0~3만 씀
    s01_read (32'h8000_0100, 8'd0);
    check(rbuf[0], 64'h1111_1111_CCCC_DDDD, "S01 partial write");

    // 3) S00(I-cache 자리)가 S01이 쓴 데이터를 읽는지 (공유 메모리)
    s00_read(32'h8000_0000, 8'd3);
    $display("[%t] S00 읽기 지연: %0d 사이클(cpu_clk)", $time, last_read_latency);
    check(rbuf[0], 64'h0123_4567_89AB_CDEF, "S00 shared read b0");
    check(rbuf[1], 64'hFEDC_BA98_7654_3210, "S00 shared read b1");
    check(rbuf[2], 64'hDEAD_BEEF_CAFE_F00D, "S00 shared read b2");
    check(rbuf[3], 64'h1122_3344_5566_7788, "S00 shared read b3");

    repeat (20) @(posedge cpu_clk);
    if (errors == 0) $display("=== TEST PASSED ===");
    else             $display("=== TEST FAILED : 오류 %0d 건 ===", errors);
    $finish;
  end

  // 감시 타이머: 3ms 안에 끝나지 않으면 중단 (보정 실패 등)
  initial begin
    #3000000000.0;
    if (!init_calib_complete_0) $display("=== TEST FAILED : 보정(init_calib_complete) 미완료 ===");
    else                        $display("=== TEST FAILED : 시간 초과 ===");
    $finish;
  end

endmodule
