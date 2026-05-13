module DataMemory #(
    parameter XLEN = 64
)(
    input clk,
    input clk_enable,
    input read_stall,
    input write_enable,
    input [XLEN-1:0] address,
    input [XLEN-1:0] write_data,
    input [7:0] write_mask,
    input [XLEN-1:0] rom_read_data,
    output [XLEN-1:0] rom_address,
    output [XLEN-1:0] read_data,
    output write_done
);

    // Byte-banked BRAM (8 banks × 8-bit × 4096 entries = 32KB)
    (* ram_style = "block" *) reg [7:0] memory_bank0 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank1 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank2 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank3 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank4 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank5 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank6 [0:4095];
    (* ram_style = "block" *) reg [7:0] memory_bank7 [0:4095];

    wire [12:0] ram_address = address[15:3];
    wire ram_access = (address[31:16] == 16'h1000);
    wire rom_access = (address[31:16] == 16'h0000);
    wire do_write = clk_enable && write_enable;
    assign rom_address = address;

    reg [XLEN-1:0] ram_read_data;
    reg ram_access_r;
    reg rom_access_r;
    reg write_phase;
    
    wire do_ram_write = do_write && !write_phase && ram_access;
    assign write_done = !do_write || write_phase;

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) begin
            memory_bank0[i] = 8'b0;
            memory_bank1[i] = 8'b0;
            memory_bank2[i] = 8'b0;
            memory_bank3[i] = 8'b0;
            memory_bank4[i] = 8'b0;
            memory_bank5[i] = 8'b0;
            memory_bank6[i] = 8'b0;
            memory_bank7[i] = 8'b0;
        end
        write_phase = 1'b0;
    end

    always @(posedge clk) begin
        if (clk_enable && !read_stall) begin
            ram_read_data <= {memory_bank7[ram_address],
                              memory_bank6[ram_address],
                              memory_bank5[ram_address],
                              memory_bank4[ram_address],
                              memory_bank3[ram_address],
                              memory_bank2[ram_address],
                              memory_bank1[ram_address],
                              memory_bank0[ram_address]};

            ram_access_r <= ram_access;
            rom_access_r <= rom_access;
        end
    end

    always @(posedge clk) begin
        if (do_ram_write) begin
            if (write_mask[0]) memory_bank0[ram_address] <= write_data[7:0];
            if (write_mask[1]) memory_bank1[ram_address] <= write_data[15:8];
            if (write_mask[2]) memory_bank2[ram_address] <= write_data[23:16];
            if (write_mask[3]) memory_bank3[ram_address] <= write_data[31:24];
            if (write_mask[4]) memory_bank4[ram_address] <= write_data[39:32];
            if (write_mask[5]) memory_bank5[ram_address] <= write_data[47:40];
            if (write_mask[6]) memory_bank6[ram_address] <= write_data[55:48];
            if (write_mask[7]) memory_bank7[ram_address] <= write_data[63:56];
        end
    end
    
    always @(posedge clk) begin
        if (clk_enable) begin
            if (do_write && !write_phase)
                write_phase <= 1'b1;
            else if (!read_stall)
                write_phase <= 1'b0;
        end
    end

    assign read_data = ram_access_r ? ram_read_data :
                       rom_access_r ? rom_read_data :
                       {XLEN{1'b0}};

endmodule