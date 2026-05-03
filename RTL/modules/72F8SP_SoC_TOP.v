module RV32IM72F8SPSoCTOP #(
    parameter XLEN = 32
)(
    input clk,                      // 100MHz system clock from Nexys Video
    input reset_n,                  // System reset (active low)
    input btn_up,                   // Benchmark Start FPGA Button

    output [7:0] led,               // LED[0]: Standby, LED[7:1]: OPCODE[6:0]
    output uart_tx_in               // UART TX pin
);
    wire reset = ~reset_n;

    // Internal 3-stage Reset Synchronization
    wire internal_reset;
    reg [2:0] reset_sync;
    assign internal_reset = reset_sync[2];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            reset_sync <= 3'b111;
        end else begin
            reset_sync <= {reset_sync[1:0], 1'b0};
        end
    end

    // Clock enable control
    reg cpu_clk_enable;
    wire benchmark_start;

    // Button controlled benchmark execution
    always @(posedge clk or posedge internal_reset) begin
        if (internal_reset) begin
            cpu_clk_enable <= 1'b0;
        end else begin
            if (benchmark_start) begin
                cpu_clk_enable <= 1'b1;
            end
        end
    end
    
    // UART signals
    wire tx_start;
    wire [7:0] tx_data;
    wire tx_busy;
    
    // CPU-MMIO Interface Signals
    wire [XLEN-1:0] MMIO_data_memory_write_data;
    wire [XLEN-1:0] MMIO_data_memory_address;
    wire MMIO_data_memory_write_enable;
    wire [XLEN-1:0] mmio_uart_status;
    wire mmio_uart_status_hit;         
    wire [7:0] mmio_uart_tx_data;      
    wire mmio_uart_tx_start;        
    
    // CPU Signals
    wire [31:0] retire_instruction;
    wire [6:0] current_opcode;
    assign current_opcode = retire_instruction[6:0];

    // LED Output
    assign led[0] = ~cpu_clk_enable;    // Standby mode when no clk.
    assign led[7:1] = current_opcode;   // retired instruction's opcode

    // Module instances
    UnifiedUARTController unified_uart_controller (
        .clk(clk),
        .reset(internal_reset),
        .btn_up(btn_up),
        .mmio_tx_data(mmio_uart_tx_data),
        .mmio_tx_start(mmio_uart_tx_start),

        .tx_start(tx_start),
        .tx_data(tx_data),
        .benchmark_start(benchmark_start)
    );

    // UART Transmitter; UART TX
    UARTTX uart_tx (
        .clk(clk),
        .reset(internal_reset),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx(uart_tx_in),
        .tx_busy(tx_busy)
    );
    
    MMIOInterface #(.XLEN(XLEN)) mmio_interface (
        .clk(clk),
        .clk_enable(cpu_clk_enable),
        .reset(internal_reset),
        .data_memory_write_data(MMIO_data_memory_write_data),
        .data_memory_address(MMIO_data_memory_address),
        .data_memory_write_enable(MMIO_data_memory_write_enable),
        .UART_busy(tx_busy),

        .mmio_uart_tx_data(mmio_uart_tx_data),
        .mmio_uart_status(mmio_uart_status),
        .mmio_uart_tx_start(mmio_uart_tx_start),
        .mmio_uart_status_hit(mmio_uart_status_hit)
    );
    
    // CPU Core with MMIO Interface
    RV32IM72F8SP #(.XLEN(XLEN)) rv32im72f_8sp (
        .clk(clk),
        .clk_enable(cpu_clk_enable),
        .reset(internal_reset),
        .UART_busy(tx_busy),

        .retire_instruction(retire_instruction),
        .MMIO_data_memory_write_data(MMIO_data_memory_write_data),
        .MMIO_data_memory_address(MMIO_data_memory_address),
        .MMIO_data_memory_write_enable(MMIO_data_memory_write_enable)
    );

endmodule
