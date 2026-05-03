module MMIOInterface #(
    parameter XLEN = 32
)(
    input clk,
    input clk_enable,
    input reset,
    input [XLEN-1:0] data_memory_write_data,
    input [XLEN-1:0] data_memory_address,
    input data_memory_write_enable,
    input UART_busy,

    output reg [7:0] mmio_uart_tx_data,
    output [XLEN-1:0] mmio_uart_status,
    output reg mmio_uart_tx_start,
    output mmio_uart_status_hit
);

    localparam UART_TX_ADDR = 32'h1001_0000;     // Write-Only
    localparam UART_STATUS_ADDR = 32'h1001_0004; // Read-Only

    wire uart_tx_hit = (data_memory_address == UART_TX_ADDR);
    wire uart_stat_hit = (data_memory_address == UART_STATUS_ADDR);
    assign mmio_uart_status_hit = uart_tx_hit || uart_stat_hit;
    assign mmio_uart_status = uart_stat_hit ? {{(XLEN-1){1'b0}}, UART_busy} : 32'h0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mmio_uart_tx_data <= 8'h0;
            mmio_uart_tx_start <= 1'b0;
        end else begin
            mmio_uart_tx_start <= 1'b0;

            if (clk_enable && data_memory_write_enable && uart_tx_hit && !UART_busy) begin
                mmio_uart_tx_data <= data_memory_write_data[7:0];
                mmio_uart_tx_start <= 1'b1;
            end
            else begin
                mmio_uart_tx_data <= 8'b0;
                mmio_uart_tx_start <= 1'b0;
            end
        end
    end

endmodule