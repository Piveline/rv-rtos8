module char_buffer (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  scancode,
    input  wire        valid,
    // VGA에서 읽기용
    input  wire [6:0]  col,       // 0~79 (80열)
    input  wire [4:0]  row,       // 0~29 (30행)
    output wire [7:0]  char_out   // 해당 위치 ASCII
);
    // 80x30 문자 버퍼
    reg [7:0] buffer [0:2399];    // 80*30 = 2400
    reg [6:0] cur_col;
    reg [4:0] cur_row;

    // PS/2 스캔코드 → ASCII 변환 (간단 버전)
    reg [7:0] ascii;
    reg       break_flag;
    reg       is_char;

    always @(*) begin
        case (scancode)
            8'h1C: ascii = 8'h41; // A
            8'h32: ascii = 8'h42; // B
            8'h21: ascii = 8'h43; // C
            8'h23: ascii = 8'h44; // D
            8'h24: ascii = 8'h45; // E
            8'h2B: ascii = 8'h46; // F
            8'h34: ascii = 8'h47; // G
            8'h33: ascii = 8'h48; // H
            8'h43: ascii = 8'h49; // I
            8'h3B: ascii = 8'h4A; // J
            8'h42: ascii = 8'h4B; // K
            8'h4B: ascii = 8'h4C; // L
            8'h3A: ascii = 8'h4D; // M
            8'h31: ascii = 8'h4E; // N
            8'h44: ascii = 8'h4F; // O
            8'h4D: ascii = 8'h50; // P
            8'h15: ascii = 8'h51; // Q
            8'h2D: ascii = 8'h52; // R
            8'h1B: ascii = 8'h53; // S
            8'h2C: ascii = 8'h54; // T
            8'h3C: ascii = 8'h55; // U
            8'h2A: ascii = 8'h56; // V
            8'h1D: ascii = 8'h57; // W
            8'h22: ascii = 8'h58; // X
            8'h35: ascii = 8'h59; // Y
            8'h1A: ascii = 8'h5A; // Z
            8'h29: ascii = 8'h20; // Space
            default: ascii = 8'h00;
        endcase
        is_char = (ascii != 8'h00);
    end

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cur_col    <= 0;
            cur_row    <= 0;
            break_flag <= 0;
            for (i = 0; i < 2400; i = i+1)
                buffer[i] <= 8'h20; // 공백으로 초기화
                buffer[0] <= 8'h48;  // H
                buffer[1] <= 8'h45;  // E
                buffer[2] <= 8'h4C;  // L
                buffer[3] <= 8'h4C;  // L
                buffer[4] <= 8'h4F;  // O
        end else if (valid) begin
            if (scancode == 8'hF0) begin
                break_flag <= 1;    // 다음은 break code
            end else if (break_flag) begin
                break_flag <= 0;    // break code 무시
            end else if (is_char) begin
                // 현재 위치에 글자 저장
                buffer[cur_row * 80 + cur_col] <= ascii;
                // 커서 이동
                if (cur_col == 79) begin
                    cur_col <= 0;
                    cur_row <= (cur_row == 29) ? 0 : cur_row + 1;
                end else
                    cur_col <= cur_col + 1;
            end
        end
    end

    assign char_out = buffer[row * 80 + col];
endmodule