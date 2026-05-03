`include "./load_funct3.vh"
`include "./store_funct3.vh"

module ByteEnableLogic #(
	parameter XLEN = 32
)(
    input memory_read,							// signal indicating that register file should read from data memory
    input memory_write,							// signal indicating that register file should write to data memory
    input [2:0] funct3,							// funct3
	input [XLEN-1:0] register_file_read_data,		// data read from register file
	input [XLEN-1:0] data_memory_read_data,			// data read from data memory
	input [2:0] address,						// address for checking alignment
	
	output reg [XLEN-1:0] register_file_write_data,	// data to write at register file
	output reg [XLEN-1:0] data_memory_write_data,	// data to write at data memory
    output reg [3:0] write_mask					// bitmask for writing data
);

    always @(*) begin
        if (memory_read) begin
			data_memory_write_data = {XLEN{1'b0}};
			write_mask = 4'b0;
			
			case (funct3)
				`LOAD_LB: begin
                case (address[1:0])
                    2'b00: register_file_write_data = {{(XLEN-8){data_memory_read_data[7]}},  data_memory_read_data[7:0]};
                    2'b01: register_file_write_data = {{(XLEN-8){data_memory_read_data[15]}}, data_memory_read_data[15:8]};
                    2'b10: register_file_write_data = {{(XLEN-8){data_memory_read_data[23]}}, data_memory_read_data[23:16]};
                    2'b11: register_file_write_data = {{(XLEN-8){data_memory_read_data[31]}}, data_memory_read_data[31:24]};
                endcase
            end
				`LOAD_LH: begin
                case (address[1])
                    1'b0: register_file_write_data = {{(XLEN-16){data_memory_read_data[15]}}, data_memory_read_data[15:0]};
                    1'b1: register_file_write_data = {{(XLEN-16){data_memory_read_data[31]}}, data_memory_read_data[31:16]};
                endcase
            end
				`LOAD_LW: register_file_write_data = data_memory_read_data;

				`LOAD_LBU: begin
                case (address[1:0])
                    2'b00: register_file_write_data = {{(XLEN-8){1'b0}}, data_memory_read_data[7:0]};
                    2'b01: register_file_write_data = {{(XLEN-8){1'b0}}, data_memory_read_data[15:8]};
                    2'b10: register_file_write_data = {{(XLEN-8){1'b0}}, data_memory_read_data[23:16]};
                    2'b11: register_file_write_data = {{(XLEN-8){1'b0}}, data_memory_read_data[31:24]};
                endcase
            end
				`LOAD_LHU: begin
                case (address[1])
                    1'b0: register_file_write_data = {{(XLEN-16){1'b0}}, data_memory_read_data[15:0]};
                    1'b1: register_file_write_data = {{(XLEN-16){1'b0}}, data_memory_read_data[31:16]};
                endcase
            end
				default: register_file_write_data = {XLEN{1'b0}};
			endcase
		end
		else if (memory_write) begin
			register_file_write_data = {XLEN{1'b0}};
						
			case (funct3)
				`STORE_SB: begin
					data_memory_write_data = {4{register_file_read_data[7:0]}};
					
					case (address[1:0])
						2'b00: write_mask = 4'b0001;
						2'b01: write_mask = 4'b0010;
						2'b10: write_mask = 4'b0100;
						2'b11: write_mask = 4'b1000;
					endcase
				end
				`STORE_SH: begin
					data_memory_write_data = {2{register_file_read_data[15:0]}};
					
					case (address[1])
						1'b0: write_mask = 4'b0011;
						1'b1: write_mask = 4'b1100;
						default: write_mask = 4'b0;
					endcase
				end
				`STORE_SW: begin
					data_memory_write_data = register_file_read_data;
					if (address[1:0] == 2'b00) begin
						write_mask = 4'b1111;
					end
					else begin
						write_mask = 4'b0;
					end
				end
				default: begin
					data_memory_write_data = {XLEN{1'b0}};
					write_mask = 4'b0;
				end
			endcase
		end
		else begin
			register_file_write_data = {XLEN{1'b0}};
			data_memory_write_data = {XLEN{1'b0}};
			write_mask = 4'b0;
		end
    end

endmodule