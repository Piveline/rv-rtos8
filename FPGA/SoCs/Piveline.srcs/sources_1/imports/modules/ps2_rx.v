module ps2_rx (
    input  wire       clk,
    input  wire       rst,
    input  wire       ps2_clk,
    input  wire       ps2_dat,
    output reg  [7:0] scancode,   // 받은 스캔코드
    output reg        valid        // 1클럭 펄스: 새 데이터 도착
);
    // PS/2 클럭 하강 엣지 감지
    reg ps2_clk_r0, ps2_clk_r1;
    wire ps2_negedge = ~ps2_clk_r0 & ps2_clk_r1;
    
    always @(posedge clk) begin
        ps2_clk_r0 <= ps2_clk;
        ps2_clk_r1 <= ps2_clk_r0;
    end

    // 11비트 수신 (start + 8data + parity + stop)
    reg [10:0] shift_reg;
    reg [3:0]  bit_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            shift_reg <= 0;
            bit_cnt   <= 0;
            scancode  <= 0;
            valid     <= 0;
        end else begin
            valid <= 0;
            if (ps2_negedge) begin
                shift_reg <= {ps2_dat, shift_reg[10:1]};
                bit_cnt   <= bit_cnt + 1;
                if (bit_cnt == 10) begin
                    bit_cnt  <= 0;
                    scancode <= shift_reg[9:2];  // 데이터 8비트
                    valid    <= 1;
                end
            end
        end
    end
endmodule