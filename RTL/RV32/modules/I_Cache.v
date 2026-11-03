/*
 * RV32IM54F8SP I-Cache (Instruction Cache) Module
 * - 32KB, 2-Way Set Associative, 32B Line Size
 * - True LRU, Read-Only, AXI4 Bus Master Interface
 */
module ICache_RV32 (
    input  wire         clk,
    input  wire         reset,
    input  wire         clk_enable,

    // CPU Core <-> I-Cache Interface
    input  wire         cpu_req_valid,
    input  wire [31:0]  cpu_req_addr,
    input  wire         cpu_flush,
    output reg  [31:0]  cpu_rdata,
    output reg          cpu_ready,
    input  wire         fence_i_req,
    output reg          fence_i_done,

    // AXI4 Master Interface (AR Channel)
    output reg  [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output reg          m_axi_arvalid,
    input  wire         m_axi_arready,

    // AXI4 Master Interface (R Channel)
    input  wire [63:0]  m_axi_rdata,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready
);

    localparam NUM_SETS = 512;
    localparam WAY_NUM  = 2;

    localparam STATE_IDLE      = 3'd0;
    localparam STATE_LOOKUP    = 3'd1;
    localparam STATE_ALLOC_AR  = 3'd2;
    localparam STATE_ALLOC_R   = 3'd3;
    localparam STATE_BYPASS_AR = 3'd4;
    localparam STATE_BYPASS_R  = 3'd5;
    localparam STATE_FENCE     = 3'd6;

    reg [2:0] state;

    // Latched Request Info
    reg [31:0] latched_addr;
    reg [63:0] latched_axi_data;
    reg        latched_target_way;
    
    // Address Decoding (Use stable latched_addr during operation)
    wire [31:0] active_addr = (state == STATE_IDLE) ? cpu_req_addr : latched_addr;
    wire [17:0] a_tag       = active_addr[31:14];
    wire [8:0]  a_idx       = active_addr[13:5];
    wire [4:0]  a_offset    = active_addr[4:0];
    wire        a_cacheable = (active_addr[31:29] == 3'b100);

    reg [17:0] tag_ram_w0 [0:NUM_SETS-1];
    reg [17:0] tag_ram_w1 [0:NUM_SETS-1];
    reg valid_w0 [0:NUM_SETS-1];
    reg valid_w1 [0:NUM_SETS-1];
    reg lru_bit  [0:NUM_SETS-1];

    (* ram_style = "block" *) reg [63:0] data_ram_w0 [0:(NUM_SETS*4)-1];
    (* ram_style = "block" *) reg [63:0] data_ram_w1 [0:(NUM_SETS*4)-1];

    reg  [63:0] read_data_w0, read_data_w1;
    wire [10:0] ram_read_idx = {active_addr[13:5], active_addr[4:3]};
    
    // Synchronous BRAM Read (1-cycle latency)
    always @(posedge clk) begin
        if (clk_enable) begin
            read_data_w0 <= data_ram_w0[ram_read_idx];
            read_data_w1 <= data_ram_w1[ram_read_idx];
        end
    end

    reg [1:0] burst_cnt;
    reg       flush_latch;
    reg [9:0] fence_cnt;

    assign m_axi_arlen   = a_cacheable ? 8'd3 : 8'd0;
    assign m_axi_arsize  = 3'b011;
    assign m_axi_arburst = 2'b01;
    assign m_axi_rready  = (state == STATE_ALLOC_R) || (state == STATE_BYPASS_R);
    
    // Target way selection (Latched upon Miss)
    wire target_way_comb = valid_w0[a_idx] ? (valid_w1[a_idx] ? lru_bit[a_idx] : 1'b1) : 1'b0;
    
    // Extracted target word from AXI
    wire [63:0] current_extracted_data = (burst_cnt == a_offset[4:3]) ? m_axi_rdata : latched_axi_data;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= STATE_IDLE;
            cpu_ready     <= 1'b0;
            cpu_rdata     <= 32'h0;
            fence_i_done  <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= 32'h0;
            burst_cnt     <= 2'b0;
            flush_latch   <= 1'b0;
            fence_cnt     <= 10'd0;
            latched_addr  <= 32'h0;
            latched_target_way <= 1'b0;
            
            begin: INIT_VALID
                integer i;
                for (i = 0; i < NUM_SETS; i = i + 1) begin
                    valid_w0[i] <= 1'b0;
                    valid_w1[i] <= 1'b0;
                    lru_bit[i]  <= 1'b0;
                end
            end
        end else if (clk_enable) begin
            
            if (cpu_flush) flush_latch <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    cpu_ready    <= 1'b0;
                    fence_i_done <= 1'b0;
                    
                    if (fence_i_req) begin
                        state <= STATE_FENCE;
                        fence_cnt <= 10'd0;
                    end
                    else if (cpu_req_valid) begin
                        latched_addr <= cpu_req_addr;
                        state        <= STATE_LOOKUP;
                    end
                end

                STATE_LOOKUP: begin
                    if (a_cacheable) begin
                        if (valid_w0[a_idx] && (tag_ram_w0[a_idx] == a_tag)) begin
                            // HIT Way 0
                            cpu_ready <= 1'b1;
                            cpu_rdata <= a_offset[2] ? read_data_w0[63:32] : read_data_w0[31:0];
                            lru_bit[a_idx] <= 1'b1;
                            state <= STATE_IDLE;
                        end else if (valid_w1[a_idx] && (tag_ram_w1[a_idx] == a_tag)) begin
                            // HIT Way 1
                            cpu_ready <= 1'b1;
                            cpu_rdata <= a_offset[2] ? read_data_w1[63:32] : read_data_w1[31:0];
                            lru_bit[a_idx] <= 1'b0;
                            state <= STATE_IDLE;
                        end else begin
                            // MISS
                            latched_target_way <= target_way_comb;
                            m_axi_arvalid      <= 1'b1;
                            m_axi_araddr       <= {latched_addr[31:5], 5'b00000};
                            state              <= STATE_ALLOC_AR;
                        end
                    end else begin 
                        // BYPASS
                        m_axi_arvalid <= 1'b1;
                        m_axi_araddr  <= {latched_addr[31:3], 3'b000};
                        state         <= STATE_BYPASS_AR;
                    end
                end

                STATE_ALLOC_AR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        burst_cnt     <= 2'b0;
                        state         <= STATE_ALLOC_R;
                    end
                end

                STATE_ALLOC_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (latched_target_way == 1'b0) data_ram_w0[{a_idx, burst_cnt}] <= m_axi_rdata;
                        else                            data_ram_w1[{a_idx, burst_cnt}] <= m_axi_rdata;
                        
                        if (burst_cnt == a_offset[4:3]) latched_axi_data <= m_axi_rdata;
                        
                        burst_cnt <= burst_cnt + 2'd1;

                        if (m_axi_rlast) begin
                            if (latched_target_way == 1'b0) begin tag_ram_w0[a_idx] <= a_tag; valid_w0[a_idx] <= 1'b1; end 
                            else                            begin tag_ram_w1[a_idx] <= a_tag; valid_w1[a_idx] <= 1'b1; end
                            lru_bit[a_idx] <= ~latched_target_way;
                            
                            cpu_ready <= 1'b1;
                            if (flush_latch) begin
                                cpu_rdata <= 32'h0000_0013;
                                flush_latch <= 1'b0;
                            end else begin
                                cpu_rdata <= a_offset[2] ? current_extracted_data[63:32] : current_extracted_data[31:0];
                            end
                            state <= STATE_IDLE;
                        end
                    end
                end

                STATE_BYPASS_AR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        state         <= STATE_BYPASS_R;
                    end
                end

                STATE_BYPASS_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        cpu_ready <= 1'b1;
                        if (flush_latch) begin
                            cpu_rdata <= 32'h0000_0013;
                            flush_latch <= 1'b0;
                        end else begin
                            cpu_rdata <= a_offset[2] ? m_axi_rdata[63:32] : m_axi_rdata[31:0];
                        end
                        state <= STATE_IDLE;
                    end
                end

                STATE_FENCE: begin
                    if (fence_cnt < NUM_SETS) begin
                        valid_w0[fence_cnt] <= 1'b0;
                        valid_w1[fence_cnt] <= 1'b0;
                        fence_cnt <= fence_cnt + 10'd1;
                    end else begin
                        fence_i_done <= 1'b1;
                        state        <= STATE_IDLE;
                    end
                end
            endcase
        end
    end
endmodule