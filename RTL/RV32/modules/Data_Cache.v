`timescale 1ns / 1ps
/*
 * Data Cache Module
 * - 32KB (NUM_SETS=512), 2-Way Set Associative, 32B Line Size
 * - True LRU, Write-Back, Write-Allocate, Dirty bit per line
 * - AXI4 Bus Master Interface (64-bit data, INCR burst x 4 beat)
 * - FENCE.I : CLEAN (dirty write-back, valid kept)
 * - INVAL : write-back + invalidate all (MMIO cold flush)
 * - Interface style follows the instruction cache (feat/icache)
 */
module DataCache #(
    parameter NUM_SETS = 512, // 16 ~ 512 (1KB ~ 32KB), power of 2
    parameter CACHE_EN = 1 // 0 : every access bypasses the cache
)(
    // ==================== INPUTS ====================
    // Clock / Reset
    input wire clk,
    input wire reset,
    input wire clk_enable,

    // CPU Core -> D-Cache
    input wire cpu_req_valid,
    input wire cpu_req_we, // 0 : LOAD, 1 : STORE
    input wire [31:0] cpu_req_addr,
    input wire [31:0] cpu_req_wdata,
    input wire [3:0] cpu_req_wstrb, // byte enable (write_mask)

    // Control
    input wire fence_i_req, // FENCE.I (CLEAN) : level until fence_i_done
    input wire inval_req, // cold flush (write-back + invalidate all)
    input wire perf_clear,

    // AXI4 Slave -> D-Cache
    input wire m_axi_awready, // AW
    input wire m_axi_wready, // W
    input wire [1:0] m_axi_bresp, // B
    input wire m_axi_bvalid,
    input wire m_axi_arready, // AR
    input wire [63:0] m_axi_rdata, // R
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,
    input wire m_axi_rvalid,

    // ==================== OUTPUTS ====================
    // D-Cache -> CPU Core
    output reg [31:0] cpu_rdata, // aligned word (byte extract / sign-ext in core)
    output reg cpu_ready, // 1-cycle pulse : request done

    // Control
    output reg fence_i_done, // 1-cycle pulse after last BRESP
    output reg inval_done, // 1-cycle pulse

    // Performance counters
    output reg [31:0] perf_access,
    output reg [31:0] perf_miss,
    output reg [31:0] perf_wb,
    output reg [31:0] perf_stall,

    // D-Cache -> AXI4 Slave
    output reg [31:0] m_axi_awaddr, // AW
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output reg m_axi_awvalid,
    output wire [63:0] m_axi_wdata, // W
    output wire [7:0] m_axi_wstrb,
    output wire m_axi_wlast,
    output reg m_axi_wvalid,
    output wire m_axi_bready, // B
    output reg [31:0] m_axi_araddr, // AR
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output reg m_axi_arvalid,
    output wire m_axi_rready // R
);

    localparam INDEX_BITS = $clog2(NUM_SETS);
    localparam TAG_BITS = 32 - 5 - INDEX_BITS;

    localparam STATE_IDLE = 4'd0;
    localparam STATE_LOOKUP = 4'd1;
    localparam STATE_WB_READ = 4'd2; // victim line -> wb_buf (4 beats)
    localparam STATE_WB_AW = 4'd3;
    localparam STATE_WB_W = 4'd4;
    localparam STATE_WB_B = 4'd5;
    localparam STATE_ALLOC_AR = 4'd6;
    localparam STATE_ALLOC_R = 4'd7;
    localparam STATE_BYPASS_AR = 4'd8;
    localparam STATE_BYPASS_R = 4'd9;
    localparam STATE_BYPASS_AW = 4'd10;
    localparam STATE_BYPASS_W = 4'd11;
    localparam STATE_BYPASS_B = 4'd12;
    localparam STATE_SCAN = 4'd13; // FENCE.I / INVAL set-way walk
    localparam STATE_SCAN_WAIT = 4'd14; // wait for req to drop after done pulse

    reg [3:0] state;

    // Latched Request Info
    reg [31:0] latched_addr;
    reg latched_we;
    reg [31:0] latched_wdata;
    reg [3:0] latched_wstrb;
    reg latched_target_way;
    reg [63:0] latched_axi_data;

    // Address Decoding (Use stable latched_addr during operation)
    wire [31:0] active_addr = (state == STATE_IDLE) ? cpu_req_addr : latched_addr;
    wire [TAG_BITS-1:0] a_tag = active_addr[31:5+INDEX_BITS];
    wire [INDEX_BITS-1:0] a_idx = active_addr[5+INDEX_BITS-1:5];
    wire [4:0] a_offset = active_addr[4:0];
    wire a_cacheable = (CACHE_EN != 0) && (active_addr[31:29] == 3'b100);

    // Store data / strobe placed on the 64-bit lane selected by addr[2]
    wire [63:0] store_data64 = {latched_wdata, latched_wdata};
    wire [7:0] store_strb8 = latched_addr[2] ? {latched_wstrb, 4'b0000} : {4'b0000, latched_wstrb};

    function [63:0] merge_bytes(input [63:0] old_data, input [63:0] new_data, input [7:0] strb);
        integer b;
        begin
            merge_bytes = old_data;
            for (b = 0; b < 8; b = b + 1)
                if (strb[b]) merge_bytes[b*8 +: 8] = new_data[b*8 +: 8];
        end
    endfunction

    // Tag / State Arrays
    reg [TAG_BITS-1:0] tag_ram_w0 [0:NUM_SETS-1];
    reg [TAG_BITS-1:0] tag_ram_w1 [0:NUM_SETS-1];
    reg valid_w0 [0:NUM_SETS-1];
    reg valid_w1 [0:NUM_SETS-1];
    reg dirty_w0 [0:NUM_SETS-1];
    reg dirty_w1 [0:NUM_SETS-1];
    reg lru_bit [0:NUM_SETS-1]; // way to evict next

    // Data Arrays (32B line = 4 x 64-bit)
    (* ram_style = "block" *) reg [63:0] data_ram_w0 [0:(NUM_SETS*4)-1];
    (* ram_style = "block" *) reg [63:0] data_ram_w1 [0:(NUM_SETS*4)-1];

    // Write-back bookkeeping
    reg [INDEX_BITS-1:0] wb_idx;
    reg wb_way;
    reg [TAG_BITS-1:0] wb_tag;
    reg wb_from_scan;
    reg [2:0] wb_rd_cnt;
    reg [1:0] wb_cnt;
    reg [63:0] wb_buf [0:3];

    // FENCE.I / INVAL walk
    reg [INDEX_BITS-1:0] scan_set;
    reg scan_way;
    reg scan_inval;

    reg [1:0] burst_cnt;

    // Synchronous BRAM Read (1-cycle latency)
    reg [63:0] read_data_w0, read_data_w1;
    wire [INDEX_BITS+1:0] ram_read_idx = (state == STATE_WB_READ) ? {wb_idx, wb_rd_cnt[1:0]}
        : {a_idx, a_offset[4:3]};
    always @(posedge clk) begin
        if (clk_enable) begin
            read_data_w0 <= data_ram_w0[ram_read_idx];
            read_data_w1 <= data_ram_w1[ram_read_idx];
        end
    end

    // AXI constant fields
    assign m_axi_arlen = (state == STATE_BYPASS_AR) ? 8'd0 : 8'd3;
    assign m_axi_arsize = 3'b011;
    assign m_axi_arburst = 2'b01;
    assign m_axi_rready = (state == STATE_ALLOC_R) || (state == STATE_BYPASS_R);

    assign m_axi_awlen = (state == STATE_BYPASS_AW) ? 8'd0 : 8'd3;
    assign m_axi_awsize = 3'b011;
    assign m_axi_awburst = 2'b01;
    assign m_axi_wdata = (state == STATE_BYPASS_W) ? store_data64 : wb_buf[wb_cnt];
    assign m_axi_wstrb = (state == STATE_BYPASS_W) ? store_strb8 : 8'hFF;
    assign m_axi_wlast = (state == STATE_BYPASS_W) ? 1'b1 : (wb_cnt == 2'd3);
    assign m_axi_bready = (state == STATE_WB_B) || (state == STATE_BYPASS_B);

    // Lookup helpers
    wire hit_w0 = valid_w0[a_idx] && (tag_ram_w0[a_idx] == a_tag);
    wire hit_w1 = valid_w1[a_idx] && (tag_ram_w1[a_idx] == a_tag);
    wire target_way_comb = valid_w0[a_idx] ? (valid_w1[a_idx] ? lru_bit[a_idx] : 1'b1) : 1'b0;
    wire victim_dirty_comb = target_way_comb ? (valid_w1[a_idx] && dirty_w1[a_idx])
        : (valid_w0[a_idx] && dirty_w0[a_idx]);
    wire [TAG_BITS-1:0] victim_tag_comb = target_way_comb ? tag_ram_w1[a_idx] : tag_ram_w0[a_idx];

    // Scan helpers
    wire scan_valid = scan_way ? valid_w1[scan_set] : valid_w0[scan_set];
    wire scan_dirty = scan_way ? dirty_w1[scan_set] : dirty_w0[scan_set];
    wire scan_last = scan_way && (scan_set == NUM_SETS-1);

    // Extracted target word from AXI refill
    wire [63:0] current_extracted_data = (burst_cnt == a_offset[4:3]) ? m_axi_rdata : latched_axi_data;

    // Miss-service states counted as stall cycles
    wire in_miss_service = (state == STATE_WB_READ) || (state == STATE_WB_AW) || (state == STATE_WB_W) ||
        (state == STATE_WB_B) || (state == STATE_ALLOC_AR) || (state == STATE_ALLOC_R) ||
        (state == STATE_BYPASS_AR) || (state == STATE_BYPASS_R) ||
        (state == STATE_BYPASS_AW) || (state == STATE_BYPASS_W) || (state == STATE_BYPASS_B);

    // Data RAM write port
    // kept in a reset-free block so that Vivado can map the arrays to BRAM
    reg data_we_w0;
    reg data_we_w1;
    reg [INDEX_BITS+1:0] data_waddr;
    reg [63:0] data_wdata;

    always @(*) begin
        data_we_w0 = 1'b0;
        data_we_w1 = 1'b0;
        data_waddr = {a_idx, a_offset[4:3]};
        data_wdata = 64'h0;
        if (!reset && clk_enable) begin
            if (state == STATE_LOOKUP && a_cacheable && latched_we && (hit_w0 || hit_w1)) begin
                // STORE hit : merge bytes into the word read during IDLE
                data_we_w0 = hit_w0;
                data_we_w1 = !hit_w0;
                data_wdata = merge_bytes(hit_w0 ? read_data_w0 : read_data_w1, store_data64, store_strb8);
            end
            else if (state == STATE_ALLOC_R && m_axi_rvalid && m_axi_rready) begin
                // refill beat, STORE miss merges into the target beat
                data_we_w0 = (latched_target_way == 1'b0);
                data_we_w1 = (latched_target_way == 1'b1);
                data_waddr = {a_idx, burst_cnt};
                if (latched_we && burst_cnt == a_offset[4:3])
                    data_wdata = merge_bytes(m_axi_rdata, store_data64, store_strb8);
                else
                    data_wdata = m_axi_rdata;
            end
        end
    end

    always @(posedge clk) begin
        if (data_we_w0) data_ram_w0[data_waddr] <= data_wdata;
        if (data_we_w1) data_ram_w1[data_waddr] <= data_wdata;
    end

    // Tag RAM write port (end of refill)
    wire tag_we = !reset && clk_enable && (state == STATE_ALLOC_R) && m_axi_rvalid && m_axi_rready && m_axi_rlast;

    always @(posedge clk) begin
        if (tag_we && latched_target_way == 1'b0) tag_ram_w0[a_idx] <= a_tag;
        if (tag_we && latched_target_way == 1'b1) tag_ram_w1[a_idx] <= a_tag;
    end

    integer i;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            cpu_ready <= 1'b0;
            cpu_rdata <= 32'h0;
            fence_i_done <= 1'b0;
            inval_done <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr <= 32'h0;
            m_axi_awvalid <= 1'b0;
            m_axi_awaddr <= 32'h0;
            m_axi_wvalid <= 1'b0;
            burst_cnt <= 2'b0;
            wb_cnt <= 2'b0;
            wb_rd_cnt <= 3'b0;
            wb_idx <= {INDEX_BITS{1'b0}};
            wb_way <= 1'b0;
            wb_tag <= {TAG_BITS{1'b0}};
            wb_from_scan <= 1'b0;
            scan_set <= {INDEX_BITS{1'b0}};
            scan_way <= 1'b0;
            scan_inval <= 1'b0;
            latched_addr <= 32'h0;
            latched_we <= 1'b0;
            latched_wdata <= 32'h0;
            latched_wstrb <= 4'h0;
            latched_target_way <= 1'b0;
            latched_axi_data <= 64'h0;
            perf_access <= 32'h0;
            perf_miss <= 32'h0;
            perf_wb <= 32'h0;
            perf_stall <= 32'h0;
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid_w0[i] <= 1'b0;
                valid_w1[i] <= 1'b0;
                dirty_w0[i] <= 1'b0;
                dirty_w1[i] <= 1'b0;
                lru_bit[i] <= 1'b0;
            end
        end else if (clk_enable) begin

            if (perf_clear) begin
                perf_access <= 32'h0;
                perf_miss <= 32'h0;
                perf_wb <= 32'h0;
                perf_stall <= 32'h0;
            end else if (in_miss_service && !wb_from_scan) begin
                perf_stall <= perf_stall + 32'd1;
            end

            case (state)
                STATE_IDLE: begin
                    cpu_ready <= 1'b0;

                    if (fence_i_req || inval_req) begin
                        // In-flight request is already finished (only checked in IDLE)
                        scan_set <= {INDEX_BITS{1'b0}};
                        scan_way <= 1'b0;
                        scan_inval <= inval_req;
                        state <= STATE_SCAN;
                    end
                    else if (cpu_req_valid) begin
                        latched_addr <= cpu_req_addr;
                        latched_we <= cpu_req_we;
                        latched_wdata <= cpu_req_wdata;
                        latched_wstrb <= cpu_req_wstrb;
                        wb_from_scan <= 1'b0;
                        state <= STATE_LOOKUP;
                    end
                end

                STATE_LOOKUP: begin
                    if (a_cacheable) begin
                        if (!perf_clear) perf_access <= perf_access + 32'd1;

                        if (hit_w0 || hit_w1) begin
                            // HIT
                            if (latched_we) begin
                                // data word is written by the data RAM write port below
                                if (hit_w0) dirty_w0[a_idx] <= 1'b1;
                                else dirty_w1[a_idx] <= 1'b1;
                            end else begin
                                if (hit_w0) cpu_rdata <= a_offset[2] ? read_data_w0[63:32] : read_data_w0[31:0];
                                else cpu_rdata <= a_offset[2] ? read_data_w1[63:32] : read_data_w1[31:0];
                            end
                            lru_bit[a_idx] <= hit_w0 ? 1'b1 : 1'b0;
                            cpu_ready <= 1'b1;
                            state <= STATE_IDLE;
                        end else begin
                            // MISS (write-allocate for both LOAD and STORE)
                            if (!perf_clear) perf_miss <= perf_miss + 32'd1;
                            latched_target_way <= target_way_comb;
                            if (victim_dirty_comb) begin
                                wb_idx <= a_idx;
                                wb_way <= target_way_comb;
                                wb_tag <= victim_tag_comb;
                                wb_from_scan <= 1'b0;
                                wb_rd_cnt <= 3'd0;
                                state <= STATE_WB_READ;
                            end else begin
                                m_axi_arvalid <= 1'b1;
                                m_axi_araddr <= {latched_addr[31:5], 5'b00000};
                                state <= STATE_ALLOC_AR;
                            end
                        end
                    end else begin
                        // BYPASS (MMIO-free uncached path : single beat)
                        if (latched_we) begin
                            m_axi_awvalid <= 1'b1;
                            m_axi_awaddr <= {latched_addr[31:3], 3'b000};
                            state <= STATE_BYPASS_AW;
                        end else begin
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr <= {latched_addr[31:3], 3'b000};
                            state <= STATE_BYPASS_AR;
                        end
                    end
                end

                // ---------------- Write-back (victim or scan) ----------------
                STATE_WB_READ: begin
                    // ram_read_idx = {wb_idx, wb_rd_cnt}; data arrives next cycle
                    if (wb_rd_cnt != 3'd0)
                        wb_buf[wb_rd_cnt - 3'd1] <= wb_way ? read_data_w1 : read_data_w0;
                    if (wb_rd_cnt == 3'd4) begin
                        m_axi_awvalid <= 1'b1;
                        m_axi_awaddr <= {wb_tag, wb_idx, 5'b00000};
                        state <= STATE_WB_AW;
                    end
                    wb_rd_cnt <= wb_rd_cnt + 3'd1;
                end

                STATE_WB_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid <= 1'b1;
                        wb_cnt <= 2'd0;
                        state <= STATE_WB_W;
                    end
                end

                STATE_WB_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (wb_cnt == 2'd3) begin
                            m_axi_wvalid <= 1'b0;
                            state <= STATE_WB_B;
                        end
                        wb_cnt <= wb_cnt + 2'd1;
                    end
                end

                STATE_WB_B: begin
                    if (m_axi_bvalid) begin
                        if (!perf_clear) perf_wb <= perf_wb + 32'd1;
                        if (wb_way) dirty_w1[wb_idx] <= 1'b0;
                        else dirty_w0[wb_idx] <= 1'b0;

                        if (wb_from_scan) begin
                            if (scan_inval) begin
                                if (scan_way) valid_w1[scan_set] <= 1'b0;
                                else valid_w0[scan_set] <= 1'b0;
                            end
                            if (scan_last) begin
                                if (scan_inval) inval_done <= 1'b1;
                                else fence_i_done <= 1'b1;
                                state <= STATE_SCAN_WAIT;
                            end else begin
                                if (scan_way) scan_set <= scan_set + 1'b1;
                                scan_way <= ~scan_way;
                                state <= STATE_SCAN;
                            end
                        end else begin
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr <= {latched_addr[31:5], 5'b00000};
                            state <= STATE_ALLOC_AR;
                        end
                    end
                end

                // ---------------- Refill ----------------
                STATE_ALLOC_AR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        burst_cnt <= 2'b0;
                        state <= STATE_ALLOC_R;
                    end
                end

                STATE_ALLOC_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        // each beat is written by the data RAM write port below
                        if (burst_cnt == a_offset[4:3]) latched_axi_data <= m_axi_rdata;
                        burst_cnt <= burst_cnt + 2'd1;

                        if (m_axi_rlast) begin
                            // tag is written by the tag RAM write port below
                            if (latched_target_way == 1'b0) begin
                                valid_w0[a_idx] <= 1'b1;
                                dirty_w0[a_idx] <= latched_we;
                            end else begin
                                valid_w1[a_idx] <= 1'b1;
                                dirty_w1[a_idx] <= latched_we;
                            end
                            lru_bit[a_idx] <= ~latched_target_way;
                            if (!latched_we)
                                cpu_rdata <= a_offset[2] ? current_extracted_data[63:32] : current_extracted_data[31:0];
                            cpu_ready <= 1'b1;
                            state <= STATE_IDLE;
                        end
                    end
                end

                // ---------------- Uncached single access ----------------
                STATE_BYPASS_AR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        state <= STATE_BYPASS_R;
                    end
                end

                STATE_BYPASS_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        cpu_rdata <= a_offset[2] ? m_axi_rdata[63:32] : m_axi_rdata[31:0];
                        cpu_ready <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                STATE_BYPASS_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid <= 1'b1;
                        state <= STATE_BYPASS_W;
                    end
                end

                STATE_BYPASS_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                        state <= STATE_BYPASS_B;
                    end
                end

                STATE_BYPASS_B: begin
                    if (m_axi_bvalid) begin
                        cpu_ready <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                // ---------------- FENCE.I (CLEAN) / INVAL walk ----------------
                STATE_SCAN: begin
                    if (scan_valid && scan_dirty) begin
                        wb_idx <= scan_set;
                        wb_way <= scan_way;
                        wb_tag <= scan_way ? tag_ram_w1[scan_set] : tag_ram_w0[scan_set];
                        wb_from_scan <= 1'b1;
                        wb_rd_cnt <= 3'd0;
                        state <= STATE_WB_READ;
                    end else begin
                        if (scan_inval) begin
                            if (scan_way) valid_w1[scan_set] <= 1'b0;
                            else valid_w0[scan_set] <= 1'b0;
                        end
                        if (scan_last) begin
                            if (scan_inval) inval_done <= 1'b1;
                            else fence_i_done <= 1'b1;
                            state <= STATE_SCAN_WAIT;
                        end else begin
                            if (scan_way) scan_set <= scan_set + 1'b1;
                            scan_way <= ~scan_way;
                        end
                    end
                end

                STATE_SCAN_WAIT: begin
                    // done was a 1-cycle pulse; wait until the requester drops req
                    fence_i_done <= 1'b0;
                    inval_done <= 1'b0;
                    wb_from_scan <= 1'b0;
                    if (!fence_i_req && !inval_req) state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule
