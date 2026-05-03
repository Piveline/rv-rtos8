`include "./opcode.vh"

module ForwardUnit #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire clk_enable,
    input wire EX_MEM_stall,
    input wire EX_MEM_flush,

    input wire [1:0] hazard_ex,     // NEW: EX-EXR forwarding
    input wire [1:0] hazard_ex2,    // BR-EXR forwarding
    input wire [1:0] hazard_mem,    // MEM-EXR forwarding
    input wire [1:0] hazard_wb,     // WB-EXR forwarding
    input wire [1:0] hazard_retire,

    input wire store_hazard_ex,     // NEW
    input wire store_hazard_ex2,
    input wire store_hazard_mem,
    input wire store_hazard_wb,
    input wire store_hazard_wb_to_mem,

    input wire [XLEN-1:0] EX_imm,
    input wire [XLEN-1:0] EX_pc_plus_4,
    input wire [XLEN-1:0] EX_csr_read_data,
    input wire [2:0] EX_forward_select,

    input wire [XLEN-1:0] EX2_imm,
    input wire [XLEN-1:0] EX2_alu_result,
    input wire [XLEN-1:0] EX2_csr_read_data,
    input wire [XLEN-1:0] EX2_pc_plus_4,
    input wire [2:0] EX2_forward_select,
    input wire ex2_is_load,

    input wire [XLEN-1:0] byte_enable_logic_register_file_write_data,
    input wire [XLEN-1:0] retire_byte_enable_logic_register_file_write_data,
    input wire [XLEN-1:0] WB_forward_data_value,
    input wire [XLEN-1:0] csr_read_data,

    output wire [XLEN-1:0] alu_forward_source_data_a,
    output wire [XLEN-1:0] alu_forward_source_data_b,
    output wire [2:0] alu_forward_source_select_a,
    output wire [2:0] alu_forward_source_select_b,

    output wire [XLEN-1:0] MEM_forward_data_value_out,

    output wire [XLEN-1:0] store_forward_data,
    output wire store_forward_enable,
    output wire [XLEN-1:0] store_wb_to_mem_forward_data,
    output wire store_wb_to_mem_forward_enable,

    output wire [XLEN-1:0] csr_forward_data
);

    // EX forward data value (NEW)
    // Non-ALU producer data from EXR_EX register outputs (already registered)
    // ALU/LOAD cases are handled by stall, never reach this mux
    reg [XLEN-1:0] EX_forward_data_value;
    always @(*) begin
        case (EX_forward_select)
            3'd1:    EX_forward_data_value = EX_imm;           // LUI
            3'd2:    EX_forward_data_value = EX_pc_plus_4;     // JAL / JALR
            3'd3:    EX_forward_data_value = EX_csr_read_data; // CSR
            default: EX_forward_data_value = {XLEN{1'b0}};     // ALU/LOAD - stalled, not used
        endcase
    end

    // BR(EX2) forward data value (same logic as 7-stage)
    reg [XLEN-1:0] EX2_forward_data_value;
    always @(*) begin
        case (EX2_forward_select)
            3'd0:    EX2_forward_data_value = EX2_alu_result;
            3'd1:    EX2_forward_data_value = EX2_imm;
            3'd2:    EX2_forward_data_value = EX2_pc_plus_4;
            3'd3:    EX2_forward_data_value = EX2_csr_read_data;
            default: EX2_forward_data_value = EX2_alu_result;
        endcase
    end

    // MEM forward data value pipeline (pre-register for timing)
    // Registered at BR-MEM boundary to select between load data and non-load data
    wire MEM_forward_is_load_next = ex2_is_load;

    reg [XLEN-1:0] MEM_non_load_forward_data_next;
    always @(*) begin
        case (EX2_forward_select)
            3'd1:    MEM_non_load_forward_data_next = EX2_imm;
            3'd2:    MEM_non_load_forward_data_next = EX2_pc_plus_4;
            3'd3:    MEM_non_load_forward_data_next = EX2_csr_read_data;
            default: MEM_non_load_forward_data_next = EX2_alu_result;
        endcase
    end

    reg MEM_forward_is_load;
    reg [XLEN-1:0] MEM_non_load_forward_data;

    always @(posedge clk) begin
        if (EX_MEM_flush) begin
            MEM_forward_is_load <= 1'b0;
            MEM_non_load_forward_data <= {XLEN{1'b0}};
        end
        else if (clk_enable && !EX_MEM_stall) begin
            MEM_forward_is_load <= MEM_forward_is_load_next;
            MEM_non_load_forward_data <= MEM_non_load_forward_data_next;
        end
    end

    wire [XLEN-1:0] MEM_forward_data_value = MEM_forward_is_load
        ? byte_enable_logic_register_file_write_data
        : MEM_non_load_forward_data;

    assign MEM_forward_data_value_out = MEM_forward_data_value;

    wire [XLEN-1:0] retire_forward_data_value = retire_byte_enable_logic_register_file_write_data;

    // CSR forward (unchanged - direct read from CSR file)
    assign csr_forward_data = csr_read_data;

    // ALU source forwarding selection (priority: EX > BR > MEM > WB)
    // Encoding: 000=none, 001=EX, 010=BR, 011=MEM, 100=WB
    assign alu_forward_source_select_a =
        hazard_ex[0]  ? 3'b001 :
        hazard_ex2[0] ? 3'b010 :
        hazard_mem[0] ? 3'b011 :
        hazard_wb[0]  ? 3'b100 : 
        hazard_retire[0] ? 3'b101 : 3'b000;

    assign alu_forward_source_select_b =
        hazard_ex[1]  ? 3'b001 :
        hazard_ex2[1] ? 3'b010 :
        hazard_mem[1] ? 3'b011 :
        hazard_wb[1]  ? 3'b100 : 
        hazard_retire[1] ? 3'b101 : 3'b000;

    assign alu_forward_source_data_a =
        ({XLEN{hazard_ex[0]}}  & EX_forward_data_value)  |
        ({XLEN{hazard_ex2[0]}} & EX2_forward_data_value) |
        ({XLEN{hazard_mem[0]}} & MEM_forward_data_value)  |
        ({XLEN{hazard_wb[0]}}  & WB_forward_data_value)  |
        ({XLEN{hazard_retire[0]}} & retire_forward_data_value);

    assign alu_forward_source_data_b =
        ({XLEN{hazard_ex[1]}}  & EX_forward_data_value)  |
        ({XLEN{hazard_ex2[1]}} & EX2_forward_data_value) |
        ({XLEN{hazard_mem[1]}} & MEM_forward_data_value)  |
        ({XLEN{hazard_wb[1]}}  & WB_forward_data_value)  |
        ({XLEN{hazard_retire[1]}} & retire_forward_data_value);

    // Store data forwarding (to EXR store data mux, priority: EX > BR > MEM > WB)
    assign store_forward_enable = store_hazard_ex || store_hazard_ex2 || store_hazard_mem || store_hazard_wb;
    assign store_forward_data =
        ({XLEN{store_hazard_ex}}  & EX_forward_data_value)  |
        ({XLEN{store_hazard_ex2}} & EX2_forward_data_value) |
        ({XLEN{store_hazard_mem}} & MEM_forward_data_value)  |
        ({XLEN{store_hazard_wb}}  & WB_forward_data_value);

    assign store_wb_to_mem_forward_enable = store_hazard_wb_to_mem;
    assign store_wb_to_mem_forward_data = WB_forward_data_value;

endmodule