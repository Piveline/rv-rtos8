module clint #(
    parameter XLEN = 64,
    parameter CLK_FREQ  = 100_000_000,  // CPU 클럭 주파수: 100MHz
    parameter TICK_FREQ = 1_000         // 1초당 tick 횟수: 1000번
                                        // DIVIDER = 100_000_000 / 1_000 = 100_000
)(
    input  wire        clk,
    input  wire        rst,
 
    // 입력
    input  wire        write_enable,
    input  wire [XLEN-1:0] write_data,
    input  wire [XLEN-1:0] write_address,
    input  wire [XLEN-1:0] read_address,

    // 출력
    output reg  [XLEN-1:0] read_data,
    output wire        timer_interrupt
);
 
// ============================================================
// 1. 클럭 분주기 (100MHz → 1kHz tick 생성)
//    100,000,000 / 1,000 = 100,000 클럭마다 tick 1번
// ============================================================
localparam DIVIDER = CLK_FREQ / TICK_FREQ;  // 100_000
 
reg [$clog2(DIVIDER)-1:0] div_cnt;
reg                        tick;
 
always @(posedge clk) begin
    if (rst) begin
        div_cnt <= 0;
        tick    <= 1'b0;
    end else if (div_cnt == DIVIDER - 1) begin
        div_cnt <= 0;
        tick    <= 1'b1;
    end else begin
        div_cnt <= div_cnt + 1;
        tick    <= 1'b0;
    end
end
 
// ============================================================
// 2. MTIME (읽기/쓰기 가능, tick마다 +1)
// ============================================================
reg [63:0] mtime;
 
always @(posedge clk) begin
    if (rst) begin
        mtime <= 64'b0;
    end else if (write_enable) begin
        case (write_address)
            64'h0000_0000_0200_0000: mtime[XLEN-1:0]  <= write_data;  // high 쓰기
            default: ;
        endcase
    end else if (tick) begin
        mtime <= mtime + 1;  // 100,000클럭마다 +1
    end
end
 
// ============================================================
// 3. MTIMECMP (읽기/쓰기 가능, 증가 로직 없음)
// ============================================================
reg [63:0] mtimecmp;
 
always @(posedge clk) begin
    if (rst) begin
        mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // 초기값: 최댓값
    end else if (write_enable) begin
        case (write_address)
            64'h0000_0000_0200_0008: mtimecmp[XLEN-1:0]  <= write_data;  // low 쓰기
            default: ;
        endcase
    end
end
 
// ============================================================
// 4. 메모리 읽기 (read_address로 해당 데이터 인출)
// ============================================================
always @(*) begin
    case (read_address)
        64'h0000_0000_0200_0000: read_data = mtime[XLEN-1:0];     // MTIME low
        64'h0000_0000_0200_0008: read_data = mtimecmp[XLEN-1:0];  // MTIMECMP lowq
        default:       read_data = XLEN{1'b0};
    endcase
end
 
// ============================================================
// 5. 타이머 인터럽트
//    assign timer_interrupt = (mtime >= mtimecmp)
// ============================================================
assign timer_interrupt = (mtime >= mtimecmp) ? 1'b1 : 1'b0;
 
endmodule