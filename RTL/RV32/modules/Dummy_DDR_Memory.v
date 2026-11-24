/*
 * Dummy DDR Memory (AXI4 slave)
 * - Synthesizable stand-in for the DDR3 + MIG path until the memory group's DDR is ready
 * - 64-bit data, INCR bursts, one transaction at a time (matches the D-Cache: 1 outstanding)
 * - Block RAM with byte write enables, size = 2^ADDRESS_WIDTH words of 64 bits (default 128KB)
 * - Fixed latency
 *   READ_LATENCY  : cycles from the AR handshake to the first RVALID
 *   WRITE_LATENCY : cycles from the last W handshake (WLAST) to BVALID
 * - Address bits above the RAM size are ignored (the window repeats)
 * - Error mode (ERROR_ENABLE = 1, for testbenches)
 *   a burst whose start address matches READ_ERROR_ADDRESS gets SLVERR on every R beat
 *   a burst whose start address matches WRITE_ERROR_ADDRESS gets SLVERR on B and is not stored
 *   (compared under ERROR_ADDRESS_MASK)
 */

module DummyDDRMemory #(
    parameter ADDRESS_WIDTH = 14,
    parameter READ_LATENCY = 60,
    parameter WRITE_LATENCY = 60,
    parameter INIT_FILE = "",
    parameter ERROR_ENABLE = 0,
    parameter [31:0] ERROR_ADDRESS_MASK = 32'hFFFF_F000,
    parameter [31:0] READ_ERROR_ADDRESS = 32'h8001_F000,
    parameter [31:0] WRITE_ERROR_ADDRESS = 32'h8001_E000
)(
    input wire clk,
    input wire reset,

    // AW channel
    input wire [31:0] s_axi_awaddr,
    input wire [7:0] s_axi_awlen,
    input wire [2:0] s_axi_awsize,
    input wire [1:0] s_axi_awburst,
    input wire s_axi_awvalid,
    output wire s_axi_awready,

    // W channel
    input wire [63:0] s_axi_wdata,
    input wire [7:0] s_axi_wstrb,
    input wire s_axi_wlast,
    input wire s_axi_wvalid,
    output wire s_axi_wready,

    // B channel
    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,

    // AR channel
    input wire [31:0] s_axi_araddr,
    input wire [7:0] s_axi_arlen,
    input wire [2:0] s_axi_arsize,
    input wire [1:0] s_axi_arburst,
    input wire s_axi_arvalid,
    output wire s_axi_arready,

    // R channel
    output wire [63:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rlast,
    output wire s_axi_rvalid,
    input wire s_axi_rready
);

    localparam STATE_IDLE = 3'd0;
    localparam STATE_READ_WAIT = 3'd1; // counting READ_LATENCY
    localparam STATE_READ_DATA = 3'd2; // sending R beats
    localparam STATE_WRITE_DATA = 3'd3; // taking W beats
    localparam STATE_WRITE_WAIT = 3'd4; // counting WRITE_LATENCY
    localparam STATE_WRITE_RESPONSE = 3'd5; // BVALID until BREADY

    reg [2:0] state;
    reg [ADDRESS_WIDTH-1:0] base_index; // word index of the first beat
    reg [7:0] burst_length; // AxLEN of the current burst
    reg [7:0] beat;
    reg [15:0] wait_count;
    reg burst_error; // current burst is answered with SLVERR

    (* ram_style = "block" *) reg [63:0] memory [0:(1 << ADDRESS_WIDTH)-1];
    reg [63:0] read_data;

    integer byte_index;

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory);
    end

    // Handshakes
    assign s_axi_arready = (state == STATE_IDLE);
    assign s_axi_awready = (state == STATE_IDLE) && !s_axi_arvalid;
    assign s_axi_wready = (state == STATE_WRITE_DATA);
    assign s_axi_rvalid = (state == STATE_READ_DATA);
    assign s_axi_rlast = (state == STATE_READ_DATA) && (beat == burst_length);
    assign s_axi_rresp = burst_error ? 2'b10 : 2'b00;
    assign s_axi_rdata = read_data;
    assign s_axi_bvalid = (state == STATE_WRITE_RESPONSE);
    assign s_axi_bresp = burst_error ? 2'b10 : 2'b00;

    wire read_handshake = s_axi_rvalid && s_axi_rready;
    wire write_handshake = s_axi_wvalid && s_axi_wready;

    // Next read beat is fetched one cycle early so R beats can go out back to back
    wire [7:0] read_next_beat = read_handshake ? (beat + 8'd1) : beat;
    wire [ADDRESS_WIDTH-1:0] read_index = base_index + read_next_beat;
    wire [ADDRESS_WIDTH-1:0] write_index = base_index + beat;

    // Block RAM read port (1-cycle latency)
    always @(posedge clk) begin
        read_data <= memory[read_index];
    end

    // Block RAM write port with byte enables
    always @(posedge clk) begin
        if (write_handshake && !burst_error) begin
            for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin
                if (s_axi_wstrb[byte_index])
                    memory[write_index][byte_index*8 +: 8] <= s_axi_wdata[byte_index*8 +: 8];
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            base_index <= {ADDRESS_WIDTH{1'b0}};
            burst_length <= 8'd0;
            beat <= 8'd0;
            wait_count <= 16'd0;
            burst_error <= 1'b0;
        end
        else begin
            case (state)
                STATE_IDLE: begin
                    beat <= 8'd0;
                    if (s_axi_arvalid) begin
                        base_index <= s_axi_araddr[ADDRESS_WIDTH+2:3];
                        burst_length <= s_axi_arlen;
                        burst_error <= (ERROR_ENABLE != 0) &&
                            ((s_axi_araddr & ERROR_ADDRESS_MASK) == READ_ERROR_ADDRESS);
                        wait_count <= READ_LATENCY - 2;
                        state <= STATE_READ_WAIT;
                    end
                    else if (s_axi_awvalid) begin
                        base_index <= s_axi_awaddr[ADDRESS_WIDTH+2:3];
                        burst_length <= s_axi_awlen;
                        burst_error <= (ERROR_ENABLE != 0) &&
                            ((s_axi_awaddr & ERROR_ADDRESS_MASK) == WRITE_ERROR_ADDRESS);
                        state <= STATE_WRITE_DATA;
                    end
                end

                STATE_READ_WAIT: begin
                    // read_data picks up beat 0 on the last waiting cycle
                    if (wait_count == 16'd0)
                        state <= STATE_READ_DATA;
                    else
                        wait_count <= wait_count - 16'd1;
                end

                STATE_READ_DATA: begin
                    if (read_handshake) begin
                        beat <= beat + 8'd1;
                        if (beat == burst_length)
                            state <= STATE_IDLE;
                    end
                end

                STATE_WRITE_DATA: begin
                    if (write_handshake) begin
                        beat <= beat + 8'd1;
                        if (s_axi_wlast) begin
                            wait_count <= WRITE_LATENCY - 2;
                            state <= STATE_WRITE_WAIT;
                        end
                    end
                end

                STATE_WRITE_WAIT: begin
                    if (wait_count == 16'd0)
                        state <= STATE_WRITE_RESPONSE;
                    else
                        wait_count <= wait_count - 16'd1;
                end

                STATE_WRITE_RESPONSE: begin
                    if (s_axi_bready)
                        state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
