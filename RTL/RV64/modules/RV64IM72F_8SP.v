`include "./modules/headers/alu_src_select.vh"
`include "./modules/headers/rf_wd_select.vh"
`include "./modules/headers/alu_op.vh"
`include "./modules/headers/opcode.vh"

`include "./modules/ALU.v"
`include "./modules/ALU_Controller.v"
`include "./modules/Branch_Logic.v"
`include "./modules/Branch_Predictor.v"
`include "./modules/Byte_Enable_Logic.v"
`include "./modules/CSR_File.v"
`include "./modules/Control_Unit.v"
`include "./modules/Data_Memory.v"
`include "./modules/Exception_Detector.v"
`include "./modules/Forward_Unit.v"
`include "./modules/Hazard_Unit.v"
`include "./modules/Immediate_Generator.v"
`include "./modules/Instruction_Decoder.v"
`include "./modules/Instruction_Memory.v"
`include "./modules/PC_Controller.v"
`include "./modules/PC_Plus_4.v"
`include "./modules/Program_Counter.v"
`include "./modules/Register_File.v"
`include "./modules/Trap_Controller.v"
`include "./modules/IF_IO_Register.v"
`include "./modules/IO_ID_Register.v"
`include "./modules/ID_EX_Register.v"
`include "./modules/EXR_EX_Register.v"
`include "./modules/EX_EX2_Register.v"
`include "./modules/EX_MEM_Register.v"
`include "./modules/MEM_WB_Register.v"

module RV64IM72F8SP #(
    parameter XLEN = 64
)(
    input clk,
    input clk_enable,
    input reset,
    input UART_busy,
    input timer_interrupt_pending,
    input [XLEN-1:0] MMIO_read_data,

     // IO Interface
    
    output wire [31:0] retire_instruction,
    output wire [XLEN-1:0] MMIO_data_memory_write_data,
    output wire [XLEN-1:0] MMIO_data_memory_address,
    output wire MMIO_data_memory_write_enable
);

    // Program Counter and PC Plus 4
    wire [XLEN-1:0] pc;
    wire [XLEN-1:0] pc_plus_4_signal;
    wire [XLEN-1:0] next_pc;
    
    // Instruction Memory and Debug Interface
    wire [31:0] im_instruction;
    wire [31:0] dbg_instruction = 32'b00000001011110110000110000110011;
    reg [31:0] instruction;
    wire [XLEN-1:0] IF_imm;
    wire [6:0] IF_opcode;

    // ROM bypass signals
    wire [XLEN-1:0] rom_read_data;

    assign IF_imm = {{(XLEN-13){IO_instruction[31]}}, IO_instruction[31], IO_instruction[7], IO_instruction[30:25], IO_instruction[11:8], 1'b0};
    assign IF_opcode = (IO_instruction[6:0]);

    // Instruction Decoder
    wire [6:0] opcode;
    wire [2:0] funct3;
    wire [6:0] funct7;
    wire [4:0] rs1;
    wire [5:0] rs2;
    wire [4:0] rd;
    wire [19:0] raw_imm;
    
    // Immediate Generator
    wire [XLEN-1:0] imm;

    // Control Unit
    wire pc_stall;
    wire jump;
    wire branch;
    wire [1:0] alu_src_A_select;
    wire [2:0] alu_src_B_select;
    wire memory_read;
    wire memory_write;
    wire register_file_write;
    wire [2:0] register_file_write_data_select;
    wire cu_csr_write_enable;

    // Branch Logic and Branch Predictor
    wire branch_taken;
    wire [XLEN-1:0] branch_target;
    wire [XLEN-1:0] branch_target_actual;

    // Register File
    wire [XLEN-1:0] register_file_write_data;
    wire [XLEN-1:0] read_data1;
    wire [XLEN-1:0] read_data2;

    // ALU Controller
    wire [4:0] alu_op;
    wire input_size_word;

    // ALU
    wire [XLEN-1:0] alu_result;
    wire alu_zero;
    wire [31:0] alu_word_result_out;
    wire [31:0] EX2_alu_word_result;
    wire EX2_input_size_word;
    wire EX2_is_muldiv_word = (EX2_opcode == `OPCODE_RTYPE_WORD) && EX2_instruction[25];
    wire [XLEN-1:0] EX2_alu_result_final = (EX2_input_size_word && !EX2_is_muldiv_word) ? {{32{EX2_alu_word_result[31]}}, EX2_alu_word_result} : EX2_alu_result;

    // Divider Unit
    wire div_start;
    wire div_busy;

    // Multiplier Unit
    wire mul_start;
    wire mul_busy;
    
    // Data Memory and Byte Enable Logic
    wire [XLEN-1:0] data_memory_read_data;
    wire [XLEN-1:0] byte_enable_logic_register_file_write_data;
    wire [XLEN-1:0] data_memory_write_data;
    wire [7:0] write_mask;
    wire write_done;

    // CSR File
    wire csr_write_enable;
    reg [11:0] csr_read_address;
    reg [11:0] csr_write_address;
    reg [XLEN-1:0] csr_write_data;
    wire [XLEN-1:0] csr_read_out;
    wire csr_ready;
    reg instruction_retired;

    // Exception_Detector
    wire trapped;
    wire [3:0] trap_status;

    // Trap Controller
    wire trap_done;
    wire debug_mode;
    wire tc_csr_write_enable;
    wire [XLEN-1:0] trap_target;
    wire [11:0] csr_trap_address;
    wire [XLEN-1:0] csr_trap_write_data;
    wire pth_done_flush;
    wire standby_mode;
    wire trap_csr_access;
    
    // IF_IO_Register
    wire [XLEN-1:0] IO_pc;
    wire [XLEN-1:0] IO_pc_plus_4;
    wire [31:0] IO_instruction;

    // IO_ID_Register
    wire [XLEN-1:0] ID_pc;
    wire [XLEN-1:0] ID_pc_plus_4;
    wire [31:0] ID_instruction;
    wire ID_branch_estimation;
    wire ID_valid_csr_address;

    // =========================================================================
    // EXR stage wires (from ID_EXR Register, was ID_EX)
    // =========================================================================
    wire [XLEN-1:0] EXR_pc;
    wire [XLEN-1:0] EXR_pc_plus_4;
    wire EXR_branch_estimation;
    wire [31:0] EXR_instruction;
    wire EXR_jump;
    wire EXR_memory_read;
    wire EXR_memory_write;
    wire [2:0] EXR_register_file_write_data_select;
    wire EXR_register_write_enable;
    wire EXR_csr_write_enable;
    wire EXR_branch;
    wire [1:0] EXR_alu_src_A_select;
    wire [2:0] EXR_alu_src_B_select;
    wire [6:0] EXR_opcode;
    wire [2:0] EXR_funct3;
    wire [6:0] EXR_funct7;
    wire [4:0] EXR_rd;
    wire [19:0] EXR_raw_imm;
    wire [XLEN-1:0] EXR_read_data1;
    wire [XLEN-1:0] EXR_read_data2;
    wire [4:0] EXR_rs1;
    wire [5:0] EXR_rs2;
    wire [XLEN-1:0] EXR_imm;
    wire [XLEN-1:0] EXR_csr_read_data;

    // EXR stage combinational signals
    wire EXR_is_load = (EXR_opcode == `OPCODE_LOAD);

    reg [2:0] EXR_forward_select;
    always @(*) begin
        case (EXR_opcode)
            `OPCODE_LUI:         EXR_forward_select = 3'd1;
            `OPCODE_JAL:         EXR_forward_select = 3'd2;
            `OPCODE_JALR:        EXR_forward_select = 3'd2;
            `OPCODE_ENVIRONMENT: EXR_forward_select = 3'd3;
            default:             EXR_forward_select = 3'd0;
        endcase
    end

    // =========================================================================
    // EX stage wires (from EXR_EX Register - NEW)
    // =========================================================================
    wire [XLEN-1:0] EX_src_A;      // resolved ALU operand A
    wire [XLEN-1:0] EX_src_B;      // resolved ALU operand B
    wire [XLEN-1:0] EX_pc;
    wire [XLEN-1:0] EX_pc_plus_4;
    wire EX_branch_estimation;
    wire [31:0] EX_instruction;
    wire EX_jump;
    wire EX_memory_read;
    wire EX_memory_write;
    wire [2:0] EX_register_file_write_data_select;
    wire EX_register_write_enable;
    wire EX_csr_write_enable;
    wire EX_branch;
    wire [6:0] EX_opcode;
    wire [2:0] EX_funct3;
    wire [6:0] EX_funct7;
    wire [4:0] EX_rd;
    wire [19:0] EX_raw_imm;
    wire [XLEN-1:0] EX_read_data2;
    wire [4:0] EX_rs1;
    wire [5:0] EX_rs2;
    wire [XLEN-1:0] EX_imm;
    wire [XLEN-1:0] EX_csr_read_data;
    wire EX_is_load;
    wire [2:0] EX_forward_select;

    // =========================================================================
    // EX2/BR stage wires
    // =========================================================================
    wire EX2_is_load;
    wire [XLEN-1:0] EX2_pc;
    wire [XLEN-1:0] EX2_pc_plus_4;
    wire [31:0] EX2_instruction;

    wire EX2_memory_read;
    wire EX2_memory_write;

    wire [2:0] EX2_register_file_write_data_select;
    wire EX2_register_write_enable;
    wire EX2_csr_write_enable;

    wire [6:0] EX2_opcode;
    wire [2:0] EX2_funct3;
    wire [4:0] EX2_rs1;
    wire [4:0] EX2_rs2;
    wire [4:0] EX2_rd;

    wire [XLEN-1:0] EX2_read_data1;
    wire [XLEN-1:0] EX2_read_data2;
    wire [XLEN-1:0] EX2_imm;
    wire [19:0] EX2_raw_imm;

    wire [XLEN-1:0] EX2_csr_read_data;
    wire [XLEN-1:0] EX2_alu_result;

    wire EX2_branch;
    wire EX2_branch_estimation;
    wire EX2_alu_zero;
    wire EX2_jump;

    assign EX2_alu_zero = (EX2_alu_result == 0);

    // =========================================================================
    // MEM stage wires
    // =========================================================================
    wire [XLEN-1:0] MEM_pc;
    wire [XLEN-1:0] MEM_pc_plus_4;
    wire [31:0] MEM_instruction;

    wire MEM_memory_read;
    wire MEM_memory_write;
    wire [2:0] MEM_register_file_write_data_select;
    wire MEM_register_write_enable;
    wire MEM_csr_write_enable;
    wire [6:0] MEM_opcode;
    wire [2:0] MEM_funct3;
    wire [4:0] MEM_rs1;
    wire [4:0] MEM_rs2;
    wire [4:0] MEM_rd;
    wire [XLEN-1:0] MEM_read_data2;
    wire [XLEN-1:0] MEM_imm;
    wire [19:0] MEM_raw_imm;
    wire [XLEN-1:0] MEM_csr_read_data;
    wire [XLEN-1:0] MEM_alu_result;
    wire [XLEN-1:0] MEM_data_memory_write_data;
    wire [XLEN-1:0] MEM_forward_data_value;
    wire [XLEN-1:0] MEM_forward_data_value_out;

    // =========================================================================
    // WB stage wires
    // =========================================================================
    wire [XLEN-1:0] WB_pc;
    wire [XLEN-1:0] WB_pc_plus_4;
    wire [31:0] WB_instruction;
    wire [6:0] WB_opcode;

    wire MEM_WB_flush;
    wire [2:0] WB_register_file_write_data_select;
    wire [XLEN-1:0] WB_imm;
    wire [19:0] WB_raw_imm;
    wire [XLEN-1:0] WB_csr_read_data;
    wire [XLEN-1:0] WB_alu_result;
    wire WB_register_write_enable;
    wire WB_csr_write_enable;
    wire [4:0] WB_rs1;
    wire [4:0] WB_rd;

    wire [XLEN-1:0] WB_byte_enable_logic_register_file_write_data;
    wire [XLEN-1:0] WB_data_memory_write_data;
    wire WB_memory_write;
    wire [XLEN-1:0] WB_forward_data_value;

    // Retire stage registers
    reg [4:0] retire_rd;
    reg retire_register_write_enable;
    reg [6:0] retire_opcode;
    reg [XLEN-1:0] retire_alu_result;
    reg [XLEN-1:0] retire_imm;
    reg [XLEN-1:0] retire_pc_plus_4;
    reg [XLEN-1:0] retire_csr_read_data;
    reg [XLEN-1:0] retire_byte_enable_logic_register_file_write_data;

    // =========================================================================
    // Hazard Unit signals
    // =========================================================================
    wire IF_IO_flush;
    wire IO_ID_flush;
    wire ID_EXR_flush;      // was ID_EX_flush
    wire EXR_EX_flush;      // NEW
    wire EX_EX2_flush;
    wire EX_MEM_flush;
    wire IF_IO_stall;
    wire IO_ID_stall;
    wire ID_EXR_stall;      // was ID_EX_stall
    wire EXR_EX_stall;      // NEW
    wire EX_EX2_stall;
    wire EX_MEM_stall;
    wire MEM_WB_stall;
    wire retire_stall;
    wire store_hazard_ex;    // NEW
    wire store_hazard_ex2;
    wire store_hazard_mem;
    wire store_hazard_wb;
    wire store_hazard_wb_to_mem;
    wire load_use_hazard;
    wire misaligned_instruction_flush;
    wire misaligned_memory_flush;

    // =========================================================================
    // Forward Unit signals
    // =========================================================================
    wire [1:0] hazard_ex;    // NEW: EX-EXR
    wire [1:0] hazard_ex2;
    wire [1:0] hazard_mem;
    wire [1:0] hazard_wb;
    wire [1:0] hazard_retire;
    wire [XLEN-1:0] csr_forward_data;
    wire [XLEN-1:0] alu_forward_source_data_a;
    wire [XLEN-1:0] alu_forward_source_data_b;
    wire [2:0] alu_forward_source_select_a;
    wire [2:0] alu_forward_source_select_b;

    // EXR stage store data forwarding
    wire [XLEN-1:0] store_forward_data;
    wire store_forward_enable;
    wire [XLEN-1:0] EXR_read_data2_MUX;
    assign EXR_read_data2_MUX = store_forward_enable ? store_forward_data : EXR_read_data2;
    wire [2:0] EX2_forward_select;

    // WB->MEM store data forwarding
    wire [XLEN-1:0] store_wb_to_mem_forward_data;
    wire store_wb_to_mem_forward_enable;
    wire [XLEN-1:0] MEM_read_data2_MUX;
    assign MEM_read_data2_MUX = store_wb_to_mem_forward_enable ? store_wb_to_mem_forward_data : MEM_read_data2;

    // Branch Predictor
    wire branch_estimation;
    wire branch_prediction_miss;
    
    wire [31:0] writeback_instruction = WB_instruction;
    assign retire_instruction = writeback_instruction;

    wire csr_write_enable_source;
    assign csr_write_enable_source = tc_csr_write_enable ? tc_csr_write_enable : WB_csr_write_enable;

    // IO signals for MMIO Interface
    assign MMIO_data_memory_write_data = data_memory_write_data;
    assign MMIO_data_memory_write_enable = MEM_memory_write;
    assign MMIO_data_memory_address = MEM_alu_result;

    // MMIO Interface logics
    reg mmio_hit_reg;
    always @(posedge clk or posedge reset) begin
        if (reset)
            mmio_hit_reg <= 1'b0;
        else if (clk_enable && !EX_MEM_stall)
            mmio_hit_reg <= (EX2_alu_result[31:24] == 8'h02) ||
                            (EX2_alu_result[31:16] == 16'h1001) ||
                            (EX2_alu_result[31:16] == 16'h1002) ||
                            (EX2_alu_result[31:16] == 16'h1003);
        end

    wire [XLEN-1:0] data_memory_read_data_muxed;
    assign data_memory_read_data_muxed = mmio_hit_reg ? MMIO_read_data : data_memory_read_data;

    // =========================================================================
    // EXR stage combinational logic: ALU source selection + forwarding
    // (Moved from old EX stage - this is the critical path split)
    // =========================================================================

    // Normal ALU source selection (before forwarding)
    reg [XLEN-1:0] EXR_normal_source_a;
    reg [XLEN-1:0] EXR_normal_source_b;

    // Resolved ALU operands (after forwarding)
    reg [XLEN-1:0] EXR_src_A;
    reg [XLEN-1:0] EXR_src_B;

    always @(*) begin
        // ALU source A selection
        case (EXR_alu_src_A_select)
            `ALU_SRC_A_RD1: EXR_normal_source_a = EXR_read_data1;
            `ALU_SRC_A_PC:  EXR_normal_source_a = EXR_pc;
            `ALU_SRC_A_RS1: EXR_normal_source_a = {59'b0, EXR_rs1};
            default:         EXR_normal_source_a = {XLEN{1'b0}};
        endcase

        // ALU source B selection
        case (EXR_alu_src_B_select)
            `ALU_SRC_B_RD2:   EXR_normal_source_b = EXR_read_data2;
            `ALU_SRC_B_IMM:   EXR_normal_source_b = EXR_imm;
            `ALU_SRC_B_SHAMT: EXR_normal_source_b = {58'b0, EXR_imm[5:0]};
            `ALU_SRC_B_CSR:   EXR_normal_source_b = EXR_csr_read_data;
            default:           EXR_normal_source_b = {XLEN{1'b0}};
        endcase

        // Forwarding mux A (priority: EX > BR > MEM > WB > normal)
        case (alu_forward_source_select_a)
            3'b001:  EXR_src_A = alu_forward_source_data_a;
            3'b010:  EXR_src_A = alu_forward_source_data_a;
            3'b011:  EXR_src_A = alu_forward_source_data_a;
            3'b100:  EXR_src_A = alu_forward_source_data_a;
            3'b101:  EXR_src_A = alu_forward_source_data_a;
            default: EXR_src_A = EXR_normal_source_a;
        endcase

        // Forwarding mux B (priority: EX > BR > MEM > WB > normal)
        case (alu_forward_source_select_b)
            3'b001:  EXR_src_B = alu_forward_source_data_b;
            3'b010:  EXR_src_B = alu_forward_source_data_b;
            3'b011:  EXR_src_B = alu_forward_source_data_b;
            3'b100:  EXR_src_B = alu_forward_source_data_b;
            3'b101:  EXR_src_B = alu_forward_source_data_b;
            default: EXR_src_B = EXR_normal_source_b;
        endcase

        // CSR address and data selection (unchanged - WB/trap write, ID read)
        if (trap_csr_access) begin
            csr_write_data   = csr_trap_write_data;
            csr_write_address = csr_trap_address;
            csr_read_address  = csr_trap_address;
        end
        else begin
            csr_write_data   = WB_alu_result;
            csr_write_address = WB_raw_imm[11:0];
            csr_read_address  = raw_imm[11:0];
        end

        // Debug mode instruction selection (unchanged)
        if (debug_mode) instruction = dbg_instruction;
        else instruction = im_instruction;
    end

    reg [XLEN-1:0] jump_target_latch;
    reg jumpped_latch;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            jump_target_latch <= {XLEN{1'b0}};
            jumpped_latch <= 1'b0;
        end
        else if (clk_enable) begin
            jump_target_latch <= EX2_jump ? EX2_alu_result : {XLEN{1'b0}};
            if (standby_mode && jumpped) begin
                jumpped_latch <= 1'b1;
            end
            else if (standby_mode) begin
                jumpped_latch <= jumpped_latch;
            end
            else begin
                jumpped_latch <= 1'b0;
            end
        end
    end
    wire jumpped = jump_target_latch == pc;

    wire [11:0] IO_csr_address = IO_instruction[31:20];
    wire IO_valid_csr_address = (IO_csr_address == 12'hB00) ||
                               (IO_csr_address == 12'hB02) ||
                               (IO_csr_address == 12'hF11) ||
                               (IO_csr_address == 12'hF12) ||
                               (IO_csr_address == 12'hF14) ||
                               (IO_csr_address == 12'h300) ||
                               (IO_csr_address == 12'h301) ||
                               (IO_csr_address == 12'h304) ||
                               (IO_csr_address == 12'h305) ||
                               (IO_csr_address == 12'h340) ||
                               (IO_csr_address == 12'h341) ||
                               (IO_csr_address == 12'h342) ||
                               (IO_csr_address == 12'h344);

    // =========================================================================
    // Module Instantiations
    // =========================================================================

    ALU alu (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .src_A(EX_src_A), 
        .src_B(EX_src_B), 
        .alu_op(alu_op),
        .input_size_word(input_size_word),
        .div_start(div_start),
        .div_busy(div_busy),
        .mul_start(mul_start),
        .mul_busy(mul_busy),

        .alu_word_result_out(alu_word_result_out),
        .alu_result(alu_result)
    );

    ALUController alu_controller (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .opcode(EX_opcode),             // from EXR_EX register
        .funct3(EX_funct3),
        .funct7_5(EX_funct7[5]),
        .funct7_0(EX_funct7[0]),
        .imm_10(EX_imm[10]),
        .div_busy(div_busy),
        .mul_busy(mul_busy),
        .load_use_hazard(load_use_hazard),
        .ex_kill(ID_EXR_flush),          // CHANGED: was ID_EX_flush

        .input_size_word(input_size_word),
        .div_start(div_start),
        .mul_start(mul_start),
        .alu_op(alu_op)
    );

    BranchLogic branch_logic (
        .branch(EX2_branch),
        .branch_estimation(EX2_branch_estimation),
        .funct3(EX2_funct3),
        .pc(EX2_pc),
        .imm(EX2_imm),
        .alu_zero(EX2_alu_zero),
        .alu_result(EX2_alu_result),

        .branch_taken(branch_taken),
        .branch_prediction_miss(branch_prediction_miss),
        .branch_target_actual(branch_target_actual)
    );

    BranchPredictor #(.XLEN(XLEN)) branch_predictor(
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .IF_opcode(IF_opcode),
        .IF_pc(IO_pc),
        .IF_imm(IF_imm),
        .EX_branch(EX2_branch),
        .EX_branch_taken(branch_taken),

        .branch_estimation(branch_estimation),
        .branch_target(branch_target)
    );

    ByteEnableLogic byte_enable_logic (
        .memory_read(MEM_memory_read),
        .memory_write(MEM_memory_write),
        .funct3(MEM_funct3),
        .register_file_read_data(MEM_read_data2_MUX),
        .data_memory_read_data(data_memory_read_data_muxed),
        .address(MEM_alu_result[2:0]),

        .register_file_write_data(byte_enable_logic_register_file_write_data),
        .data_memory_write_data(data_memory_write_data),
        .write_mask(write_mask)
    );

    ControlUnit control_unit (
        .write_done(write_done),
        .opcode(opcode),
        .funct3(funct3),
        .trap_done(trap_done),
        .csr_ready(csr_ready),
        .IF_IO_stall(IF_IO_stall),

        .pc_stall(pc_stall),
        .jump(jump),
        .branch(branch),
        .alu_src_A_select(alu_src_A_select),
        .alu_src_B_select(alu_src_B_select),
        .register_file_write(register_file_write),
        .register_file_write_data_select(register_file_write_data_select),
        .memory_read(memory_read),
        .memory_write(memory_write),
        .csr_write_enable(cu_csr_write_enable)
    );

    CSRFile #(.XLEN(XLEN)) csr_file (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .trapped(trapped),
        .trap_status(trap_status),
        .csr_write_enable(csr_write_enable_source),
        .csr_read_address(csr_read_address),
        .csr_write_address(csr_write_address),
        .csr_write_data(csr_write_data),
        .instruction_retired(instruction_retired),
        .valid_csr_address(trapped ? 1'b1 : ID_valid_csr_address),
        .mret_executed(mret_executed),
        .timer_interrupt_pending(timer_interrupt_pending),
        .pth_read(pth_read),

        .csr_read_out(csr_read_out),
        .csr_ready(csr_ready),
        .mstatus_mie(mstatus_mie),
        .mie_mtie(mie_mtie)
    );

    wire [XLEN-1:0] data_memory_address;
    assign data_memory_address = (MEM_memory_write && !write_done) ? MEM_alu_result :
                                EX2_memory_read ? EX2_alu_result :
                                MEM_alu_result;

    DataMemory data_memory (
        .clk(clk),
        .clk_enable(clk_enable),
        .read_stall(EX_MEM_stall),
        .write_enable(MEM_memory_write && !mmio_hit_reg),
        .address(data_memory_address),
        .write_data(data_memory_write_data),
        .write_mask(write_mask),
        .rom_read_data(rom_read_data),

        .write_done(write_done),
        .read_data(data_memory_read_data)
    );

    ExceptionDetector exception_detector (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .ID_opcode(opcode),
        .ID_funct3(funct3),
        .EXR_opcode(EXR_opcode),
        .EXR_funct3(EXR_funct3),
        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .EX2_opcode(EX2_opcode),
        .EX2_funct3(EX2_funct3),
        .MEM_opcode(MEM_opcode),
        .MEM_funct3(MEM_funct3),
        .raw_imm(raw_imm[11:0]),
        .EXR_raw_imm(EXR_raw_imm[11:0]),
        .EX_raw_imm(EX_raw_imm[11:0]),
        .EX2_raw_imm(EX2_raw_imm[11:0]),
        .EXR_jump(EXR_jump),
        .EX_jump(EX_jump),
        .EX2_jump(EX2_jump),
        .csr_write_enable(cu_csr_write_enable),
        .alu_result(alu_result[1:0]),
        .EX2_alu_result(EX2_alu_result[1:0]),
        .MEM_alu_result(MEM_alu_result[1:0]),
        .branch_target_lsbs(branch_target[1:0]),
        .branch_estimation(branch_estimation),
        .branch_prediction_miss(branch_prediction_miss),
        .timer_interrupt(timer_interrupt_pending),
        .mstatus_mie(mstatus_mie),
        .mie_mtie(mie_mtie),

        .trapped(trapped),
        .trap_status(trap_status)
    );

    ForwardUnit forward_unit (
        .clk(clk),
        .clk_enable(clk_enable),
        .EX_MEM_stall(EX_MEM_stall),
        .EX_MEM_flush(EX_MEM_flush),

        .hazard_ex(hazard_ex),            // NEW
        .hazard_ex2(hazard_ex2),
        .hazard_mem(hazard_mem),
        .hazard_wb(hazard_wb),
        .hazard_retire(hazard_retire),

        .store_hazard_ex(store_hazard_ex),  // NEW
        .store_hazard_ex2(store_hazard_ex2),
        .store_hazard_mem(store_hazard_mem),
        .store_hazard_wb(store_hazard_wb),
        .store_hazard_wb_to_mem(store_hazard_wb_to_mem),

        // EX stage (NEW - from EXR_EX register)
        .EX_imm(EX_imm),
        .EX_pc_plus_4(EX_pc_plus_4),
        .EX_csr_read_data(EX_csr_read_data),
        .EX_forward_select(EX_forward_select),

        // BR/EX2 stage
        .ex2_is_load(EX2_is_load),
        .EX2_imm(EX2_imm),
        .EX2_alu_result(EX2_alu_result_final),
        .EX2_csr_read_data(EX2_csr_read_data),
        .EX2_pc_plus_4(EX2_pc_plus_4),
        .EX2_forward_select(EX2_forward_select),

        .byte_enable_logic_register_file_write_data(byte_enable_logic_register_file_write_data),
        .retire_byte_enable_logic_register_file_write_data(retire_byte_enable_logic_register_file_write_data),
        .MEM_forward_data_value_out(MEM_forward_data_value_out),
        .WB_forward_data_value(WB_forward_data_value),

        .alu_forward_source_data_a(alu_forward_source_data_a),
        .alu_forward_source_data_b(alu_forward_source_data_b),
        .alu_forward_source_select_a(alu_forward_source_select_a),
        .alu_forward_source_select_b(alu_forward_source_select_b),

        .store_forward_data(store_forward_data),
        .store_forward_enable(store_forward_enable),

        .store_wb_to_mem_forward_data(store_wb_to_mem_forward_data),
        .store_wb_to_mem_forward_enable(store_wb_to_mem_forward_enable),

        .csr_read_data(csr_read_out),
        .csr_forward_data(csr_forward_data)
    );

    HazardUnit hazard_unit (
        .reset(reset),
        .trap_done(trap_done),
        .standby_mode(standby_mode),
        .div_start(div_start),
        .div_busy(div_busy),
        .mul_start(mul_start),
        .mul_busy(mul_busy),
        .write_done(write_done),
        .trap_status(trap_status),
        .misaligned_instruction_flush(misaligned_instruction_flush),
        .misaligned_memory_flush(misaligned_memory_flush),
        .pth_done_flush(pth_done_flush),
        .csr_ready(csr_ready),

        // Consumer: EXR stage
        .EXR_rs1(EXR_rs1),
        .EXR_rs2(EXR_rs2[4:0]),
        .EXR_alu_src_A_select(EXR_alu_src_A_select),
        .EXR_alu_src_B_select(EXR_alu_src_B_select),
        .EXR_opcode(EXR_opcode),
        .EXR_csr_write_enable(EXR_csr_write_enable),
        .EXR_jump(EXR_jump),
        .exr_data_stall(exr_data_stall),

        // Producer: EX stage (NEW)
        .EX_rd(EX_rd),
        .EX_opcode(EX_opcode),
        .EX_register_write_enable(EX_register_write_enable),
        .EX_is_load(EX_is_load),
        .EX_forward_select(EX_forward_select),
        .EX_csr_write_enable(EX_csr_write_enable),

        // Producer: BR/EX2 stage
        .EX2_rd(EX2_rd),
        .EX2_opcode(EX2_opcode),
        .EX2_branch(EX2_branch),
        .EX2_register_write_enable(EX2_register_write_enable),
        .ex2_is_load(EX2_is_load),

        // Producer: MEM stage
        .MEM_rd(MEM_rd),
        .MEM_opcode(MEM_opcode),
        .MEM_rs2(MEM_rs2),
        .MEM_register_write_enable(MEM_register_write_enable),
        .MEM_csr_write_enable(MEM_csr_write_enable),
        .MEM_csr_write_address(MEM_raw_imm[11:0]),

        // Producer: WB stage
        .WB_rd(WB_rd),
        .WB_register_write_enable(WB_register_write_enable),
        .WB_csr_write_enable(WB_csr_write_enable),
        .WB_csr_write_address(WB_raw_imm[11:0]),

        .retire_register_write_enable(retire_register_write_enable),
        .retire_rd(retire_rd),

        .EX2_jump(EX2_jump),
        .branch_prediction_miss(branch_prediction_miss),

        // Forwarding hazards
        .hazard_ex(hazard_ex),
        .hazard_ex2(hazard_ex2),
        .hazard_mem(hazard_mem),
        .hazard_wb(hazard_wb),
        .hazard_retire(hazard_retire),

        // Store hazards
        .store_hazard_ex(store_hazard_ex),
        .store_hazard_ex2(store_hazard_ex2),
        .store_hazard_mem(store_hazard_mem),
        .store_hazard_wb(store_hazard_wb),
        .store_hazard_wb_to_mem(store_hazard_wb_to_mem),
        .load_use_hazard(load_use_hazard),

        // Flush
        .IF_IO_flush(IF_IO_flush),
        .IO_ID_flush(IO_ID_flush),
        .ID_EXR_flush(ID_EXR_flush),
        .EXR_EX_flush(EXR_EX_flush),
        .EX_EX2_flush(EX_EX2_flush),
        .EX_MEM_flush(EX_MEM_flush),
        .MEM_WB_flush(MEM_WB_flush),

        // Stall
        .IF_IO_stall(IF_IO_stall),
        .IO_ID_stall(IO_ID_stall),
        .ID_EXR_stall(ID_EXR_stall),
        .EXR_EX_stall(EXR_EX_stall),
        .EX_EX2_stall(EX_EX2_stall),
        .EX_MEM_stall(EX_MEM_stall),
        .MEM_WB_stall(MEM_WB_stall),
        .retire_stall(retire_stall)
    );

    ImmediateGenerator immediate_generator (
        .raw_imm(raw_imm),
        .opcode(opcode),
        .imm(imm)
    );

    InstructionDecoder instruction_decoder (
        .instruction(ID_instruction),
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .rs1(rs1),
        .rs2(rs2),
        .rd(rd),
        .raw_imm(raw_imm)
    );

    InstructionMemory instruction_memory (
        .clk(clk),
        .clk_enable(clk_enable),
        .pc_stall(pc_stall),
        .read_stall(EX_MEM_stall),
        .pc(pc),
        .instruction(im_instruction),
        .rom_address(EX2_alu_result),
        .rom_read_data(rom_read_data)
    );

    ProgramCounter program_counter (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .next_pc(next_pc),
        .pc(pc)
    );

    PCPlus4 pc_plus_4 (
        .pc(pc),
        .pc_plus_4(pc_plus_4_signal)
    );

    PCController pc_controller (
        .jump(EX2_jump),
        .branch_estimation(branch_estimation),
        .branch_prediction_miss(branch_prediction_miss),
        .trapped(trapped || goto_mtvec),
        .pc(pc),
        .jump_target(EX2_alu_result),
        .branch_target(branch_target),
        .branch_target_actual(branch_target_actual),
        .trap_target(trap_target),
        .pc_stall(pc_stall),
        .next_pc(next_pc)
    );

    RegisterFile register_file (
        .clk(clk),
        .clk_enable(clk_enable),
        .read_reg1(rs1),
        .read_reg2(rs2[4:0]),
        .write_reg(WB_rd),
        .write_data(register_file_write_data),
        .write_enable(WB_register_write_enable),

        .read_data1(read_data1),
        .read_data2(read_data2)
    );

    TrapController #(.XLEN(XLEN)) trap_controller (
        .clk(clk),
        .clk_enable(clk_enable),
        .reset(reset),
        .jumpped_latch(jumpped_latch),
        .trap_status(trap_status),
        .branch_taken(branch_taken),
        .pc(pc),
        .IF_pc(instruction_pc),
        .IO_pc(IO_pc),
        .ID_pc(ID_pc),
        .EX_pc(EX_pc),                    // from old EX stage - used for precise exceptions, but renamed to EXR_pc in new design
        .EXR_pc(EXR_pc),                  // CHANGED: EX_pc - EXR_pc
        .EX2_pc(EX2_pc),
        .MEM_pc(MEM_pc),
        .WB_pc(WB_pc),
        .csr_read_data(csr_read_out),

        .debug_mode(debug_mode),
        .trap_target(trap_target),
        .trap_done(trap_done),
        .misaligned_instruction_flush(misaligned_instruction_flush),
        .misaligned_memory_flush(misaligned_memory_flush),
        .pth_done_flush(pth_done_flush),
        .standby_mode(standby_mode),
        .trap_csr_access(trap_csr_access),
        .csr_write_enable(tc_csr_write_enable),
        .csr_trap_address(csr_trap_address),
        .csr_trap_write_data(csr_trap_write_data),
        .mret_executed(mret_executed),
        .pth_read(pth_read),
        .goto_mtvec(goto_mtvec)
    );

    // =========================================================================
    // Pipeline Registers
    // =========================================================================

    IF_IO_Register #(.XLEN(XLEN)) if_io_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(IF_IO_flush),
        .IF_IO_stall(IF_IO_stall),
        .branch_estimation(branch_estimation),
        .load_use_hazard(load_use_hazard),
        .jump(EXR_jump),                   // CHANGED: EX_jump - EXR_jump
        .exr_data_stall(exr_data_stall),

        .IF_pc(instruction_pc),
        .IF_pc_plus_4(instruction_pc_plus_4),
        .IF_instruction(instruction),

        .IO_pc(IO_pc),
        .IO_pc_plus_4(IO_pc_plus_4),
        .IO_instruction(IO_instruction),

        .ID_opcode(opcode),
        .ID_funct7(funct7),

        .EX2_opcode(EX2_opcode)
    );

    IO_ID_Register #(.XLEN(XLEN)) io_id_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(IO_ID_flush),
        .IO_ID_stall(IO_ID_stall),

        .IO_pc(IO_pc),
        .IO_pc_plus_4(IO_pc_plus_4),
        .IO_instruction(IO_instruction),
        .branch_estimation(branch_estimation),
        .IO_valid_csr_address(IO_valid_csr_address),

        .ID_pc(ID_pc),
        .ID_pc_plus_4(ID_pc_plus_4),
        .ID_instruction(ID_instruction),
        .ID_branch_estimation(ID_branch_estimation),
        .ID_valid_csr_address(ID_valid_csr_address)
    );

    // ID - EXR pipeline register (was ID_EX, outputs renamed to EXR_)
    ID_EX_Register #(.XLEN(XLEN)) id_exr_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(ID_EXR_flush),             // CHANGED
        .ID_EX_stall(ID_EXR_stall),      // CHANGED
        
        .ID_pc(ID_pc),
        .ID_pc_plus_4(ID_pc_plus_4),
        .ID_branch_estimation(ID_branch_estimation),
        .ID_instruction(ID_instruction),

        .ID_jump(jump),
        .ID_branch(branch),
        .ID_alu_src_A_select(alu_src_A_select),
        .ID_alu_src_B_select(alu_src_B_select),
        .ID_memory_read(memory_read),
        .ID_memory_write(memory_write),
        .ID_register_file_write_data_select(register_file_write_data_select),
        .ID_register_write_enable(register_file_write),
        .ID_csr_write_enable(cu_csr_write_enable),
        .ID_opcode(opcode),
        .ID_funct3(funct3),
        .ID_funct7(funct7),
        .ID_rd(rd),
        .ID_raw_imm(raw_imm),
        .ID_read_data1(read_data1),
        .ID_read_data2(read_data2),
        .ID_rs1(rs1),
        .ID_rs2(rs2),
        .ID_imm(imm),
        .ID_csr_read_data(csr_read_out),

        // Outputs - EXR stage (all renamed from EX_ to EXR_)
        .EX_pc(EXR_pc),
        .EX_pc_plus_4(EXR_pc_plus_4),
        .EX_branch_estimation(EXR_branch_estimation),
        .EX_instruction(EXR_instruction),
        .EX_jump(EXR_jump),
        .EX_branch(EXR_branch),
        .EX_alu_src_A_select(EXR_alu_src_A_select),
        .EX_alu_src_B_select(EXR_alu_src_B_select),
        .EX_memory_read(EXR_memory_read),
        .EX_memory_write(EXR_memory_write),
        .EX_register_file_write_data_select(EXR_register_file_write_data_select),
        .EX_register_write_enable(EXR_register_write_enable),
        .EX_csr_write_enable(EXR_csr_write_enable),
        .EX_opcode(EXR_opcode),
        .EX_funct3(EXR_funct3),
        .EX_funct7(EXR_funct7),
        .EX_rd(EXR_rd),
        .EX_raw_imm(EXR_raw_imm),
        .EX_read_data1(EXR_read_data1),
        .EX_read_data2(EXR_read_data2),
        .EX_rs1(EXR_rs1),
        .EX_rs2(EXR_rs2),
        .EX_imm(EXR_imm),
        .EX_csr_read_data(EXR_csr_read_data)
    );

    // EXR - EX pipeline register (NEW)
    EXR_EX_Register #(.XLEN(XLEN)) exr_ex_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(EXR_EX_flush),
        .EXR_EX_stall(EXR_EX_stall),

        // Resolved operands from EXR stage
        .EXR_src_A(EXR_src_A),
        .EXR_src_B(EXR_src_B),

        // Pass-through
        .EXR_pc(EXR_pc),
        .EXR_pc_plus_4(EXR_pc_plus_4),
        .EXR_branch_estimation(EXR_branch_estimation),
        .EXR_instruction(EXR_instruction),
        .EXR_jump(EXR_jump),
        .EXR_memory_read(EXR_memory_read),
        .EXR_memory_write(EXR_memory_write),
        .EXR_register_file_write_data_select(EXR_register_file_write_data_select),
        .EXR_register_write_enable(EXR_register_write_enable),
        .EXR_csr_write_enable(EXR_csr_write_enable),
        .EXR_branch(EXR_branch),
        .EXR_opcode(EXR_opcode),
        .EXR_funct3(EXR_funct3),
        .EXR_funct7(EXR_funct7),
        .EXR_rd(EXR_rd),
        .EXR_raw_imm(EXR_raw_imm),
        .EXR_read_data2(EXR_read_data2_MUX),  // store-forwarded data
        .EXR_rs1(EXR_rs1),
        .EXR_rs2(EXR_rs2),
        .EXR_imm(EXR_imm),
        .EXR_csr_read_data(EXR_csr_read_data),
        .EXR_is_load(EXR_is_load),
        .EXR_forward_select(EXR_forward_select),

        // Outputs - EX stage
        .EX_src_A(EX_src_A),
        .EX_src_B(EX_src_B),
        .EX_pc(EX_pc),
        .EX_pc_plus_4(EX_pc_plus_4),
        .EX_branch_estimation(EX_branch_estimation),
        .EX_instruction(EX_instruction),
        .EX_jump(EX_jump),
        .EX_memory_read(EX_memory_read),
        .EX_memory_write(EX_memory_write),
        .EX_register_file_write_data_select(EX_register_file_write_data_select),
        .EX_register_write_enable(EX_register_write_enable),
        .EX_csr_write_enable(EX_csr_write_enable),
        .EX_branch(EX_branch),
        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .EX_funct7(EX_funct7),
        .EX_rd(EX_rd),
        .EX_raw_imm(EX_raw_imm),
        .EX_read_data2(EX_read_data2),
        .EX_rs1(EX_rs1),
        .EX_rs2(EX_rs2),
        .EX_imm(EX_imm),
        .EX_csr_read_data(EX_csr_read_data),
        .EX_is_load(EX_is_load),
        .EX_forward_select(EX_forward_select)
    );

    // EX - EX2/BR pipeline register (inputs now from EXR_EX register outputs)
    EX_EX2_Register #(.XLEN(XLEN)) ex_ex2_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(EX_EX2_flush),
        .EX_EX2_stall(EX_EX2_stall),

        .EX_pc(EX_pc),
        .EX_pc_plus_4(EX_pc_plus_4),
        .EX_instruction(EX_instruction),

        .EX_register_file_write_data_select(EX_register_file_write_data_select),
        .EX_register_write_enable(EX_register_write_enable),

        .EX_memory_read(EX_memory_read),
        .EX_memory_write(EX_memory_write),

        .EX_csr_write_enable(EX_csr_write_enable),

        .EX_opcode(EX_opcode),
        .EX_funct3(EX_funct3),
        .EX_rs1(EX_rs1),
        .EX_rs2(EX_rs2[4:0]),
        .EX_rd(EX_rd),

        .EX_read_data1({XLEN{1'b0}}),     // No longer used in 8-stage
        .EX_read_data2(EX_read_data2),     // Store data (forwarded in EXR)

        .EX_imm(EX_imm),
        .EX_raw_imm(EX_raw_imm),

        .EX_csr_read_data(EX_csr_read_data),
        .EX_alu_result(alu_result),

        .EX_branch(EX_branch),
        .EX_jump(EX_jump),
        .EX_branch_estimation(EX_branch_estimation),
        .EX_is_load(EX_is_load),
        .EX_alu_word_result(alu_word_result_out),
        .EX_input_size_word(input_size_word),
        .EX_forward_select(EX_forward_select),

        // Outputs to EX2/BR stage
        .EX2_pc(EX2_pc),
        .EX2_pc_plus_4(EX2_pc_plus_4),
        .EX2_instruction(EX2_instruction),

        .EX2_memory_read(EX2_memory_read),
        .EX2_memory_write(EX2_memory_write),

        .EX2_register_file_write_data_select(EX2_register_file_write_data_select),
        .EX2_register_write_enable(EX2_register_write_enable),

        .EX2_csr_write_enable(EX2_csr_write_enable),

        .EX2_opcode(EX2_opcode),
        .EX2_funct3(EX2_funct3),
        .EX2_rs1(EX2_rs1),
        .EX2_rs2(EX2_rs2),
        .EX2_rd(EX2_rd),

        .EX2_read_data1(EX2_read_data1),
        .EX2_read_data2(EX2_read_data2),

        .EX2_imm(EX2_imm),
        .EX2_raw_imm(EX2_raw_imm),

        .EX2_csr_read_data(EX2_csr_read_data),
        .EX2_alu_result(EX2_alu_result),

        .EX2_branch(EX2_branch),
        .EX2_jump(EX2_jump),
        .EX2_branch_estimation(EX2_branch_estimation),
        .EX2_is_load(EX2_is_load),
        .EX2_alu_word_result(EX2_alu_word_result),
        .EX2_input_size_word(EX2_input_size_word),
        .EX2_forward_select(EX2_forward_select)
    );

    EX_MEM_Register #(.XLEN(XLEN)) ex_mem_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .flush(EX_MEM_flush),
        .EX_MEM_stall(EX_MEM_stall),

        .EX_pc(EX2_pc),
        .EX_pc_plus_4(EX2_pc_plus_4),
        .EX_instruction(EX2_instruction),

        .EX_memory_read(EX2_memory_read),
        .EX_memory_write(EX2_memory_write),
        .EX_register_file_write_data_select(EX2_register_file_write_data_select),
        .EX_register_write_enable(EX2_register_write_enable),
        .EX_csr_write_enable(EX2_csr_write_enable),
        .EX_opcode(EX2_opcode),
        .EX_funct3(EX2_funct3),
        .EX_rs1(EX2_rs1),
        .EX_rs2(EX2_rs2[4:0]),
        .EX_rd(EX2_rd),
        .EX_raw_imm(EX2_raw_imm),
        .EX_read_data2(EX2_read_data2),
        .EX_imm(EX2_imm),
        .EX_csr_read_data(EX2_csr_read_data),

        .EX_alu_result(EX2_alu_result_final),

        .MEM_pc(MEM_pc),
        .MEM_pc_plus_4(MEM_pc_plus_4),
        .MEM_instruction(MEM_instruction),
        .MEM_memory_read(MEM_memory_read),
        .MEM_memory_write(MEM_memory_write),
        .MEM_register_file_write_data_select(MEM_register_file_write_data_select),
        .MEM_register_write_enable(MEM_register_write_enable),
        .MEM_csr_write_enable(MEM_csr_write_enable),
        .MEM_opcode(MEM_opcode),
        .MEM_funct3(MEM_funct3),
        .MEM_rs1(MEM_rs1),
        .MEM_rs2(MEM_rs2),
        .MEM_rd(MEM_rd),
        .MEM_raw_imm(MEM_raw_imm),
        .MEM_read_data2(MEM_read_data2),
        .MEM_imm(MEM_imm),
        .MEM_csr_read_data(MEM_csr_read_data),
        .MEM_alu_result(MEM_alu_result)
    );

    MEM_WB_Register #(.XLEN(XLEN)) mem_wb_register (
        .clk(clk),
        .clk_enable(clk_enable),
        .MEM_WB_stall(MEM_WB_stall),
        .flush(MEM_WB_flush),

        .MEM_pc(MEM_pc),
        .MEM_pc_plus_4(MEM_pc_plus_4),
        .MEM_instruction(MEM_instruction),

        .MEM_register_file_write_data_select(MEM_register_file_write_data_select),
        .MEM_imm(MEM_imm),
        .MEM_csr_read_data(MEM_csr_read_data),
        .MEM_alu_result(MEM_alu_result),
        .MEM_register_write_enable(MEM_register_write_enable),
        .MEM_csr_write_enable(MEM_csr_write_enable),
        .MEM_rs1(MEM_rs1),
        .MEM_rd(MEM_rd),
        .MEM_raw_imm(MEM_raw_imm),
        .MEM_opcode(MEM_opcode),

        .MEM_byte_enable_logic_register_file_write_data(byte_enable_logic_register_file_write_data),
        .MEM_data_memory_write_data(data_memory_write_data),
        .MEM_memory_write(MEM_memory_write),
        .MEM_forward_data_value(MEM_forward_data_value_out),

        .WB_pc(WB_pc),
        .WB_pc_plus_4(WB_pc_plus_4),
        .WB_instruction(WB_instruction),
        .WB_register_file_write_data_select(WB_register_file_write_data_select),
        .WB_imm(WB_imm),
        .WB_csr_read_data(WB_csr_read_data),
        .WB_alu_result(WB_alu_result),
        .WB_register_write_enable(WB_register_write_enable),
        .WB_csr_write_enable(WB_csr_write_enable),
        .WB_rs1(WB_rs1),
        .WB_rd(WB_rd),
        .WB_raw_imm(WB_raw_imm),
        .WB_opcode(WB_opcode),
        .WB_byte_enable_logic_register_file_write_data(WB_byte_enable_logic_register_file_write_data),
        .WB_data_memory_write_data(WB_data_memory_write_data),
        .WB_memory_write(WB_memory_write),
        .WB_forward_data_value(WB_forward_data_value)
    );

    reg [XLEN-1:0] instruction_pc;
    wire [XLEN-1:0] instruction_pc_plus_4 = instruction_pc + 4;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            instruction_pc <= {XLEN{1'b0}};
        end
        else if (clk_enable && !pc_stall) begin
            instruction_pc <= pc;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            retire_rd <= 5'b0;
            retire_register_write_enable <= 1'b0;
            retire_opcode <= 7'b0;
            retire_alu_result <= {XLEN{1'b0}};
            retire_imm <= {XLEN{1'b0}};
            retire_pc_plus_4 <= {XLEN{1'b0}};
            retire_csr_read_data <= {XLEN{1'b0}};
            retire_byte_enable_logic_register_file_write_data <= {XLEN{1'b0}};
            instruction_retired <= 1'b0;
        end 
        else if (clk_enable) begin
            if (retire_stall) begin
                retire_rd <= retire_rd;
                retire_register_write_enable <= retire_register_write_enable;
                retire_opcode <= retire_opcode;
                retire_alu_result <= retire_alu_result;
                retire_imm <= retire_imm;
                retire_pc_plus_4 <= retire_pc_plus_4;
                retire_csr_read_data <= retire_csr_read_data;
                retire_byte_enable_logic_register_file_write_data <= retire_byte_enable_logic_register_file_write_data;
            end
            else begin
                retire_rd <= WB_rd;
                retire_register_write_enable <= WB_register_write_enable;
                retire_opcode <= WB_opcode;
                retire_alu_result <= WB_alu_result;
                retire_imm <= WB_imm;
                retire_pc_plus_4 <= WB_pc_plus_4;
                retire_csr_read_data <= WB_csr_read_data;
                retire_byte_enable_logic_register_file_write_data <= register_file_write_data;
            end
            if (!MEM_WB_stall && !MEM_WB_flush && WB_instruction != 32'h00000013) begin
                instruction_retired <= 1'b1;
            end 
            else begin
                instruction_retired <= 1'b0;
            end
        end
    end

    assign register_file_write_data = WB_forward_data_value;

endmodule
