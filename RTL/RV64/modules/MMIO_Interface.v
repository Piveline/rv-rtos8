// ============================================================================
// MMIO Interface - Central Address Decoder & Data Router
// ============================================================================
//
// Memory Map:
//   0x0200_0000 ~ 0x0200_000F  CLINT (mtime / mtimecmp)
//   0x1001_0000                UART TX data (write-only)
//   0x1001_0004                UART status  (read-only, bit 0 = busy)
//   0x1002_0000 ~ 0x1002_095F  VRAM 80×30   (write-only, byte-addressed)
//   0x1003_0000                KB scancode  (read-only)
//   0x1003_0004                KB status    (read: bit 0 = new_data,
//                                            write: acknowledge/clear)
//
// ============================================================================

module MMIOInterface #(
    parameter XLEN = 64
)(
    input clk,
    input clk_enable,
    input reset,

    // --- CPU bus ---
    input [XLEN-1:0] address,
    input [XLEN-1:0] write_data,
    input write_enable,

    // --- Unified MMIO read data → CPU ---
    output reg [XLEN-1:0] mmio_read_data,

    // --- UART ---
    input             uart_busy,
    output reg [7:0]  uart_tx_data,
    output reg        uart_tx_start,

    // --- CLINT ---
    input [XLEN-1:0]      clint_read_data,
    output wire       clint_we,

    // --- VRAM ---
    output wire        vram_we,
    output wire [11:0] vram_addr,
    output reg  [7:0]  vram_data,

    // --- Keyboard ---
    input [7:0]       kb_scancode,
    input             kb_new_data,
    output wire       kb_ack
);

    // ========================================================================
    // Address Decode - region hit signals
    // ========================================================================
    wire hit_clint     = (address[31:16] == 16'h0200);
    wire hit_uart_tx   = (address == 64'h0000_0000_1001_0000);
    wire hit_uart_stat = (address == 64'h0000_0000_1001_0004);
    wire hit_vram      = (address[31:16] == 16'h1002) &&
                         (address[15:0]  <  16'h0960);
    wire hit_kb_scan   = (address == 64'h0000_0000_1003_0000);
    wire hit_kb_stat   = (address == 64'h0000_0000_1003_0004);

    // ========================================================================
    // Read Mux (combinational)
    // ========================================================================
    always @(*) begin
        if (hit_clint)
            mmio_read_data = clint_read_data;
        else if (hit_uart_stat)
            mmio_read_data = {63'b0, uart_busy};
        else if (hit_kb_scan)
            mmio_read_data = {56'b0, kb_scancode};
        else if (hit_kb_stat)
            mmio_read_data = {63'b0, kb_new_data};
        else
            mmio_read_data = {XLEN{1'b0}};
    end

    // ========================================================================
    // Write - CLINT
    // ========================================================================
    assign clint_we = write_enable && hit_clint;

    // ========================================================================
    // Write - UART TX
    // ========================================================================
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            uart_tx_data  <= 8'h0;
            uart_tx_start <= 1'b0;
        end else begin
            uart_tx_start <= 1'b0;
            if (clk_enable && write_enable && hit_uart_tx && !uart_busy) begin
                uart_tx_data  <= write_data[7:0];
                uart_tx_start <= 1'b1;
            end
        end
    end

    // ========================================================================
    // Write - VRAM 
    // ========================================================================
    assign vram_we   = write_enable && hit_vram;
    assign vram_addr = address[11:0];

    always @(*) begin
        case (address[2:0])
            3'b000: vram_data = write_data[7:0];
            3'b001: vram_data = write_data[15:8];
            3'b010: vram_data = write_data[23:16];
            3'b011: vram_data = write_data[31:24];
            3'b100: vram_data = write_data[39:32];
            3'b101: vram_data = write_data[47:40];
            3'b110: vram_data = write_data[55:48];
            3'b111: vram_data = write_data[63:56];
        endcase
    end

    // ========================================================================
    // Write - Keyboard Acknowledge
    // ========================================================================
    assign kb_ack = write_enable && hit_kb_stat;

endmodule