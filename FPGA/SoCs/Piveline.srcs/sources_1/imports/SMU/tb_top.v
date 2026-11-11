`timescale 1ns/1ps

module tb_top;
    // 입력
    reg        CLK100MHZ;
    reg        CPU_RESETN;
    reg        PS2_CLK;
    reg        PS2_DATA;

    // 출력
    wire       VGA_HS;
    wire       VGA_VS;
    wire [3:0] VGA_R;
    wire [3:0] VGA_G;
    wire [3:0] VGA_B;

    // DUT 연결
    top dut (
        .CLK100MHZ (CLK100MHZ),
        .CPU_RESETN(CPU_RESETN),
        .PS2_CLK   (PS2_CLK),
        .PS2_DATA  (PS2_DATA),
        .VGA_HS    (VGA_HS),
        .VGA_VS    (VGA_VS),
        .VGA_R     (VGA_R),
        .VGA_G     (VGA_G),
        .VGA_B     (VGA_B)
    );

    // 100MHz 클럭 생성 (10ns 주기)
    initial CLK100MHZ = 0;
    always #5 CLK100MHZ = ~CLK100MHZ;

    // PS/2 한 바이트 전송 태스크
    // PS/2 프레임: start(0) + data[7:0] + parity + stop(1)
    task ps2_send_byte;
        input [7:0] data;
        integer i;
        reg parity;
        reg [10:0] frame;
        begin
            parity = ~^data; // 홀수 패리티
            frame  = {1'b1, parity, data, 1'b0};
            // start bit부터 11비트 전송
            for (i = 0; i < 11; i = i+1) begin
                PS2_CLK  = 1; #20000; // 20us HIGH
                PS2_DATA = frame[i];
                PS2_CLK  = 0; #20000; // 20us LOW
            end
            PS2_CLK  = 1;
            PS2_DATA = 1;
            #40000; // 여유시간
        end
    endtask

    // 키 누름 + 뗌 시뮬레이션
    task press_key;
        input [7:0] scancode;
        begin
            ps2_send_byte(scancode); // make code (키 누름)
            #10000;
            ps2_send_byte(8'hF0);   // break prefix
            #10000;
            ps2_send_byte(scancode); // break code (키 뗌)
            #10000;
        end
    endtask

    initial begin
        // 초기화
        CPU_RESETN = 0;
        PS2_CLK    = 1;
        PS2_DATA   = 1;
        #100;

        // 리셋 해제
        CPU_RESETN = 1;
        #200;

        // 'A' 키 입력 (스캔코드 0x1C)
        $display("=== 'A' 키 입력 ===");
        press_key(8'h1C);
        #50000;

        // 'B' 키 입력 (스캔코드 0x32)
        $display("=== 'B' 키 입력 ===");
        press_key(8'h32);
        #50000;

        // 'C' 키 입력 (스캔코드 0x21)
        $display("=== 'C' 키 입력 ===");
        press_key(8'h21);
        #50000;

        // VGA 신호 확인
        $display("VGA_HS=%b VGA_VS=%b", VGA_HS, VGA_VS);
        $display("VGA_R=%h VGA_G=%h VGA_B=%h", VGA_R, VGA_G, VGA_B);

        #20000000;  // 20ms로 늘림
        $display("=== 시뮬레이션 완료 ===");
        $finish;
    end

    // 파형 저장
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end

endmodule