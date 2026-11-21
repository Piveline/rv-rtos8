// ============================================================================
// Dual-Port VRAM — 80×30 Character Buffer
// ============================================================================
// Port A (sys_clk, 100MHz): CPU writes via MMIO
// Port B (pixel_clk, 25MHz): VGA controller reads for display
//
// Vivado infers True Dual-Port Block RAM from this template.
// ============================================================================

module VRAM (
    // Port A — CPU side (100 MHz)
    input  wire        clk_a,
    input  wire        we_a,
    input  wire [11:0] addr_a,     // 0 ~ 2399
    input  wire [7:0]  din_a,

    // Port B — VGA side (25 MHz)
    input  wire        clk_b,
    input  wire [11:0] addr_b,     // row*80 + col
    output reg  [7:0]  dout_b
);

    (* ram_style = "block" *) reg [7:0] mem [0:2399];

    // blank character (ASCII 0x20) initialization
    integer i;
    initial begin
        for (i = 0; i < 2400; i = i + 1)
            mem[i] = 8'h20;
    end

    // Port A: Write only (CPU → VRAM)
    always @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= din_a;
    end

    // Port B: Read only (VRAM → VGA controller)
    always @(posedge clk_b) begin
        dout_b <= mem[addr_b];
    end

endmodule