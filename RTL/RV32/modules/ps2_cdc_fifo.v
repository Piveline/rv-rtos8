// ============================================================================
// ps2_cdc_fifo — 8-deep Async FIFO for PS/2 CDC (pixel_clk → sys_clk)
// ============================================================================
// Gray-code pointer synchronization. Vivado distributed RAM compatible.
// Write: pixel_clk domain (scancode_valid → push)
// Read:  sys_clk domain   (kb_ack → pop)
// ============================================================================

module ps2_cdc_fifo (
    // Write side (pixel_clk domain)
    input  wire       wr_clk,
    input  wire       wr_rst,
    input  wire       wr_en,
    input  wire [7:0] wr_data,
    output wire       wr_full,

    // Read side (sys_clk domain)
    input  wire       rd_clk,
    input  wire       rd_rst,
    input  wire       rd_en,
    output wire [7:0] rd_data,
    output wire       rd_empty
);

    localparam DEPTH  = 8;
    localparam ADDR_W = 3;

    // ========================================================================
    // FIFO Memory — separate always block for Vivado distributed RAM inference
    // ========================================================================
    (* ram_style = "distributed" *)
    reg [7:0] mem [0:DEPTH-1];

    always @(posedge wr_clk) begin
        if (wr_en && !wr_full)
            mem[wr_addr] <= wr_data;
    end

    // ========================================================================
    // Write pointer (wr_clk domain)
    // ========================================================================
    reg [ADDR_W:0] wr_ptr_bin;

    wire [ADDR_W:0]   wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1);
    wire [ADDR_W-1:0] wr_addr     = wr_ptr_bin[ADDR_W-1:0];

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst)
            wr_ptr_bin <= 0;
        else if (wr_en && !wr_full)
            wr_ptr_bin <= wr_ptr_bin + 1;
    end

    // ========================================================================
    // Read pointer (rd_clk domain)
    // ========================================================================
    reg [ADDR_W:0] rd_ptr_bin;

    wire [ADDR_W:0]   rd_ptr_gray = rd_ptr_bin ^ (rd_ptr_bin >> 1);
    wire [ADDR_W-1:0] rd_addr     = rd_ptr_bin[ADDR_W-1:0];

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst)
            rd_ptr_bin <= 0;
        else if (rd_en && !rd_empty)
            rd_ptr_bin <= rd_ptr_bin + 1;
    end

    // ========================================================================
    // Read data — async read from distributed RAM
    // ========================================================================
    assign rd_data = mem[rd_addr];

    // ========================================================================
    // Synchronize wr_ptr_gray → rd_clk domain (for empty flag)
    // ========================================================================
    reg [ADDR_W:0] wr_gray_rd_sync1, wr_gray_rd_sync2;

    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            wr_gray_rd_sync1 <= 0;
            wr_gray_rd_sync2 <= 0;
        end else begin
            wr_gray_rd_sync1 <= wr_ptr_gray;
            wr_gray_rd_sync2 <= wr_gray_rd_sync1;
        end
    end

    // ========================================================================
    // Synchronize rd_ptr_gray → wr_clk domain (for full flag)
    // ========================================================================
    reg [ADDR_W:0] rd_gray_wr_sync1, rd_gray_wr_sync2;

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            rd_gray_wr_sync1 <= 0;
            rd_gray_wr_sync2 <= 0;
        end else begin
            rd_gray_wr_sync1 <= rd_ptr_gray;
            rd_gray_wr_sync2 <= rd_gray_wr_sync1;
        end
    end

    // ========================================================================
    // Empty & Full flags
    // ========================================================================
    // Empty (rd domain): rd gray == synchronized wr gray
    assign rd_empty = (rd_ptr_gray == wr_gray_rd_sync2);

    // Full (wr domain): wr gray == synchronized rd gray with MSB inverted
    // In Gray code, full = top 2 bits differ, rest match
    assign wr_full = (wr_ptr_gray == {~rd_gray_wr_sync2[ADDR_W:ADDR_W-1],
                                       rd_gray_wr_sync2[ADDR_W-2:0]});

endmodule
