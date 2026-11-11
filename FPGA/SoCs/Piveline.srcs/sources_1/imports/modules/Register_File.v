module RegisterFile # (
    parameter XLEN = 32
)(
    input clk,                      // clock signal
    input clk_enable,
    input [4:0] read_reg1,          // take address of register 1 to read stored value
    input [4:0] read_reg2,          // take address of register 2 to read stored value
    input [4:0] write_reg,          // take address of register to write value
    input [XLEN-1:0] write_data,        // data to write
    input write_enable,             // enabling signal for writing register

    output reg [XLEN-1:0] read_data1,   // data from register 1
    output reg [XLEN-1:0] read_data2    // data from register 2
);

    reg [XLEN-1:0] registers [0:31]; // 32 registers with XLEN bits each

    // Read operation
    always @(*) begin
        // Read port 1
        if (read_reg1 == 5'd0)
            read_data1 = 32'd0;
        else if (clk_enable && write_enable && write_reg == read_reg1)
            read_data1 = write_data;
        else
            read_data1 = registers[read_reg1];

        // Read port 2
        if (read_reg2 == 5'd0)
            read_data2 = 32'd0;
        else if (clk_enable && write_enable && write_reg == read_reg2)
            read_data2 = write_data;
        else
            read_data2 = registers[read_reg2];
    end

    // Write operation
    always @(posedge clk) begin
        if (clk_enable && write_enable && write_reg != 5'd0) begin
            registers[write_reg] <= write_data; // write to register if not x0
        end
    end

endmodule