module font_rom (
    input  wire [7:0] char,
    input  wire [3:0] row,
    output wire [7:0] bitmap
);

    reg [7:0] rom [0:4095];

    initial begin
        $readmemh("./cp437_8x16.mem", rom);
    end

    assign bitmap = rom[{char, row}];

endmodule