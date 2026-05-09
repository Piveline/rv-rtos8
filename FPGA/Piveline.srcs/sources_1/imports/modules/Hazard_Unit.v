`include "./opcode.vh"
`include "./alu_src_select.vh"
`include "./trap.vh"

module HazardUnit (
    input wire reset,
    input wire trap_done,
    input wire csr_ready,
    input wire standby_mode,
    input wire div_start,
    input wire div_busy,
    input wire mul_start,
    input wire mul_busy,
    input wire write_done,
    input wire [2:0] trap_status,
    input wire misaligned_instruction_flush,
    input wire misaligned_memory_flush,
    input wire pth_done_flush,
    input wire [4:0] EXR_rs1,
    input wire [4:0] EXR_rs2,
    input wire [1:0] EXR_alu_src_A_select,
    input wire [2:0] EXR_alu_src_B_select,
    input wire [6:0] EXR_opcode,
    input wire EXR_csr_write_enable,
    input wire EXR_jump,
    input wire [4:0] EX_rd,
    input wire [6:0] EX_opcode,
    input wire EX_register_write_enable,
    input wire EX_is_load,
    input wire [2:0] EX_forward_select,
    input wire EX_csr_write_enable,
    input wire [4:0] EX2_rd,
    input wire [6:0] EX2_opcode,
    input wire EX2_branch,
    input wire EX2_register_write_enable,
    input wire ex2_is_load,
    input wire [4:0] MEM_rd,
    input wire [6:0] MEM_opcode,
    input wire [4:0] MEM_rs2,
    input wire MEM_register_write_enable,
    input wire MEM_csr_write_enable,
    input wire [11:0] MEM_csr_write_address,
    input wire [4:0] WB_rd,
    input wire WB_register_write_enable,
    input wire WB_csr_write_enable,
    input wire [11:0] WB_csr_write_address,
    input wire retire_register_write_enable,
    input wire [4:0] retire_rd,
    input wire EX2_jump,
    input wire branch_prediction_miss,

    output reg [1:0] hazard_ex,     // NEW: EX-EXR (non-ALU only)
    output reg [1:0] hazard_ex2,    // BR-EXR (was EX2→EX)
    output reg [1:0] hazard_mem,    // MEM-EXR
    output reg [1:0] hazard_wb,     // WB-EXR
    output reg [1:0] hazard_retire,

    output wire store_hazard_ex,    // NEW: store forwarding from EX
    output wire store_hazard_ex2,
    output wire store_hazard_mem,
    output wire store_hazard_wb,
    output wire store_hazard_wb_to_mem,
    output wire load_use_hazard,

    output wire exr_data_stall,

    output reg IF_IO_flush,
    output reg IO_ID_flush,
    output reg ID_EXR_flush,    // was ID_EX_flush
    output reg EXR_EX_flush,    // NEW
    output reg EX_EX2_flush,
    output reg EX_MEM_flush,
    output reg MEM_WB_flush,

    output reg IF_IO_stall,
    output reg IO_ID_stall,
    output reg ID_EXR_stall,    // was ID_EX_stall
    output reg EXR_EX_stall,    // NEW
    output reg EX_EX2_stall,
    output reg EX_MEM_stall,
    output reg MEM_WB_stall,
    output reg retire_stall
);

    wire is_store = (EXR_opcode == `OPCODE_STORE);
    wire is_store_mem = (MEM_opcode == `OPCODE_STORE);

    wire uses_rs1 = (EXR_alu_src_A_select == `ALU_SRC_A_RD1);
    wire uses_rs2 = (EXR_alu_src_B_select == `ALU_SRC_B_RD2);

    wire ex_can_forward = (EX_forward_select != 3'd0);  // LUI/JAL/JALR/CSR

    // Raw dependency detection
    wire ex_dep_rs1 = EX_register_write_enable && (EX_rd != 5'd0) && (EX_rd == EXR_rs1);
    wire ex_dep_rs2 = EX_register_write_enable && (EX_rd != 5'd0) && (EX_rd == EXR_rs2);

    // Forwarding possible: non-ALU, non-LOAD producer in EX
    wire ex_hazard_rs1 = uses_rs1 && ex_dep_rs1 && ex_can_forward;
    wire ex_hazard_rs2 = uses_rs2 && ex_dep_rs2 && ex_can_forward;

    // Stall required: ALU or LOAD producer in EX (combinational result or data not ready)
    wire ex_stall_rs1 = uses_rs1 && ex_dep_rs1 && !ex_can_forward;
    wire ex_stall_rs2 = uses_rs2 && ex_dep_rs2 && !ex_can_forward;
    wire ex_stall_store = is_store && ex_dep_rs2 && !ex_can_forward;
    wire ex_data_stall = ex_stall_rs1 || ex_stall_rs2 || ex_stall_store;

    wire br_hazard_rs1 = uses_rs1 && EX2_register_write_enable && (EX2_rd != 5'd0) && (EX2_rd == EXR_rs1);
    wire br_hazard_rs2 = uses_rs2 && EX2_register_write_enable && (EX2_rd != 5'd0) && (EX2_rd == EXR_rs2);

    // Load in BR: data not ready until MEM output - 1-cycle stall
    wire load_br_use_rs1  = ex2_is_load && uses_rs1 && (EX2_rd != 5'd0) && (EX2_rd == EXR_rs1);
    wire load_br_use_rs2  = ex2_is_load && uses_rs2 && (EX2_rd != 5'd0) && (EX2_rd == EXR_rs2);
    wire load_br_use_store = ex2_is_load && is_store && (EX2_rd != 5'd0) && (EX2_rd == EXR_rs2);
    wire load_br_use_hazard = load_br_use_rs1 || load_br_use_rs2 || load_br_use_store;

    wire mem_hazard_rs1 = uses_rs1 && MEM_register_write_enable && (MEM_rd != 5'd0) && (MEM_rd == EXR_rs1);
    wire mem_hazard_rs2 = uses_rs2 && MEM_register_write_enable && (MEM_rd != 5'd0) && (MEM_rd == EXR_rs2);

    wire wb_hazard_rs1 = uses_rs1 && WB_register_write_enable && (WB_rd != 5'd0) && (WB_rd == EXR_rs1);
    wire wb_hazard_rs2 = uses_rs2 && WB_register_write_enable && (WB_rd != 5'd0) && (WB_rd == EXR_rs2);

    wire retire_hazard_rs1 = uses_rs1 && retire_register_write_enable && (retire_rd != 5'd0) && (retire_rd == EXR_rs1);
    wire retire_hazard_rs2 = uses_rs2 && retire_register_write_enable && (retire_rd != 5'd0) && (retire_rd == EXR_rs2);

    assign exr_data_stall = ex_data_stall || load_br_use_hazard;
    assign load_use_hazard = exr_data_stall;

    wire store_ex_hazard_rs2  = is_store && ex_dep_rs2 && ex_can_forward;
    wire store_ex2_hazard_rs2 = is_store && EX2_register_write_enable && (EX2_rd != 5'd0) && (EX2_rd == EXR_rs2);
    wire store_mem_hazard_rs2 = is_store && MEM_register_write_enable && (MEM_rd != 5'd0) && (MEM_rd == EXR_rs2);
    wire store_wb_hazard_rs2  = is_store && WB_register_write_enable  && (WB_rd  != 5'd0) && (WB_rd  == EXR_rs2);

    // Priority: EX > BR > MEM > WB
    assign store_hazard_ex  = store_ex_hazard_rs2;
    assign store_hazard_ex2 = store_ex2_hazard_rs2 && !ex2_is_load && !store_hazard_ex;
    assign store_hazard_mem = store_mem_hazard_rs2 && !store_hazard_ex && !store_hazard_ex2;
    assign store_hazard_wb  = store_wb_hazard_rs2  && !store_hazard_ex && !store_hazard_ex2 && !store_hazard_mem;

    // WB→MEM store data forwarding (unchanged - between MEM and WB stages)
    assign store_hazard_wb_to_mem = is_store_mem &&
                                    WB_register_write_enable &&
                                    (WB_rd != 5'd0) &&
                                    (WB_rd == MEM_rs2);

    wire csr_data_hazard = EXR_csr_write_enable && (
        EX_csr_write_enable || MEM_csr_write_enable || WB_csr_write_enable
    );

    always @(*) begin
        hazard_ex  = 2'b00;
        hazard_ex2 = 2'b00;
        hazard_mem = 2'b00;
        hazard_wb  = 2'b00;
        hazard_retire = 2'b00;

        IF_IO_flush  = 1'b0;
        IO_ID_flush  = 1'b0;
        ID_EXR_flush = 1'b0;
        EXR_EX_flush = 1'b0;
        EX_EX2_flush = 1'b0;
        EX_MEM_flush = 1'b0;
        MEM_WB_flush = 1'b0;

        IF_IO_stall  = 1'b0;
        IO_ID_stall  = 1'b0;
        ID_EXR_stall = 1'b0;
        EXR_EX_stall = 1'b0;
        EX_EX2_stall = 1'b0;
        EX_MEM_stall = 1'b0;
        MEM_WB_stall = 1'b0;
        retire_stall = 1'b0;

        // ALU forwarding hazards (priority: EX > BR > MEM > WB)
        // For Store instructions, rs2 is NOT an ALU source → mask [1]
        // EX-EXR: non-ALU producers only (registered data available)
        hazard_ex[0] = ex_hazard_rs1;
        hazard_ex[1] = is_store ? 1'b0 : ex_hazard_rs2;

        // BR(EX2)-EXR: non-load, masked by EX priority
        hazard_ex2[0] = br_hazard_rs1 && !ex2_is_load && !hazard_ex[0];
        hazard_ex2[1] = is_store ? 1'b0 : (br_hazard_rs2 && !ex2_is_load && !hazard_ex[1]);

        // MEM-EXR: masked by EX, BR priority
        hazard_mem[0] = mem_hazard_rs1 && !hazard_ex[0] && !hazard_ex2[0];
        hazard_mem[1] = is_store ? 1'b0 : (mem_hazard_rs2 && !hazard_ex[1] && !hazard_ex2[1]);

        // WB-EXR: masked by EX, BR, MEM priority
        hazard_wb[0] = wb_hazard_rs1 && !hazard_ex[0] && !hazard_ex2[0] && !hazard_mem[0];
        hazard_wb[1] = is_store ? 1'b0 : (wb_hazard_rs2 && !hazard_ex[1] && !hazard_ex2[1] && !hazard_mem[1]);

        hazard_retire[0] = retire_hazard_rs1 && !hazard_wb[0] && !hazard_ex[0] && !hazard_ex2[0] && !hazard_mem[0];
        hazard_retire[1] = is_store ? 1'b0 : (retire_hazard_rs2 && !hazard_ex[1] && !hazard_ex2[1] && !hazard_mem[1] && !hazard_wb[1]);

        if (trap_done && (branch_prediction_miss || EX2_jump)) begin
            IF_IO_flush  = 1'b1;
            IO_ID_flush  = 1'b1;
            ID_EXR_flush = 1'b1;
            EXR_EX_flush = 1'b1;    // NEW: extra stage to flush
            if (branch_prediction_miss) begin
                if (write_done && csr_ready && !div_start && !div_busy && !mul_start && !mul_busy) begin
                    EX_EX2_flush = 1'b1;
                end
            end
            else if (EX2_jump && !pth_done_flush && write_done) begin
                EX_EX2_flush = 1'b1;
            end
        end

        if (pth_done_flush || reset) begin
            IF_IO_flush  = 1'b1;
            IO_ID_flush  = 1'b1;
            ID_EXR_flush = 1'b1;
            EXR_EX_flush = 1'b1;    // NEW
            EX_EX2_flush = 1'b1;
            EX_MEM_flush = 1'b1;
            MEM_WB_flush = 1'b1;
        end

        if (standby_mode) begin
            IF_IO_stall  = 1'b1;
            IO_ID_stall  = 1'b1;
            ID_EXR_stall = 1'b1;
        end
        else if (!trap_done || !csr_ready) begin
            IF_IO_stall  = 1'b1;
            IO_ID_stall  = 1'b1;
            ID_EXR_stall = 1'b1;
            EXR_EX_stall = 1'b1;    // NEW
            EX_EX2_stall = 1'b1;
            EX_MEM_stall = 1'b1;
            MEM_WB_stall = 1'b1;
        end
        else if (div_start || div_busy || mul_start || mul_busy) begin
            IF_IO_stall  = 1'b1;
            IO_ID_stall  = 1'b1;
            ID_EXR_stall = 1'b1;
            EXR_EX_stall = 1'b1;    // NEW
            EX_EX2_stall = 1'b1;
            EX_MEM_stall = 1'b1;
            MEM_WB_stall = 1'b1;
        end
        else if (!write_done) begin
            IF_IO_stall  = 1'b1;
            IO_ID_stall  = 1'b1;
            ID_EXR_stall = 1'b1;
            EXR_EX_stall = 1'b1;    // NEW
            EX_EX2_stall = 1'b1;
            EX_MEM_stall = 1'b1;
            MEM_WB_stall = 1'b1;
        end

        if (exr_data_stall && trap_done && csr_ready && !standby_mode &&
            !div_start && !div_busy && !mul_start && !mul_busy && write_done && !branch_prediction_miss && !EX2_jump) begin
            IF_IO_stall  = 1'b1;
            IO_ID_stall  = 1'b1;
            ID_EXR_stall = 1'b1;
            EXR_EX_flush = 1'b1;    // bubble into EX (was EX_EX2_flush)
        end

        if (exr_data_stall && retire_hazard_rs1) begin
                retire_stall = 1'b1;
        end

        if (csr_data_hazard && trap_done && csr_ready && !standby_mode &&
            !div_start && !div_busy && !mul_start && !mul_busy && write_done && !EX2_jump) begin
            IF_IO_stall  = 1'b1;
            IO_ID_stall  = 1'b1;
            ID_EXR_stall = 1'b1;
            EXR_EX_flush = 1'b1;
        end
    end

endmodule