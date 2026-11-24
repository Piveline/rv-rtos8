`timescale 1ns / 1ps
/*
 * Data Cache Module
 * - 32KB (NUM_SETS=512), 2-Way Set Associative, 32B Line Size
 * - True LRU, Write-Back, Write-Allocate, Dirty bit per line
 * - AXI4 Bus Master Interface (64-bit data, INCR burst x 4 beat)
 * - FENCE.I : CLEAN (dirty write-back, valid kept)
 * - INVAL : write-back + invalidate all (MMIO cold flush)
 * - AXI error handling
 *   RRESP error on refill : line is not kept (valid=0), request ends with cpu_error
 *   BRESP error on victim write-back : refill is aborted, victim stays dirty, cpu_error
 *   BRESP error on FENCE.I / INVAL write-back : line stays dirty and valid, scan_error
 *   Refill ends on the 4th beat or on RLAST, whichever comes first;
 *   RLAST on the wrong beat is an error (the core never waits forever on a missing RLAST)
 * - valid / dirty / LRU of a set are kept in one small distributed RAM (5 bits per set);
 *   it is cleared one set per cycle after reset (STATE_INIT, NUM_SETS cycles). A MEM access
 *   that arrives during INIT waits (cpu_busy), everything else in the core keeps running.
 * - Pipeline interface (same timing as the old BRAM data memory)
 *   EX2 : lookup_address is read from the data array when mem_advance = 1
 *   MEM : tag compare; a load hit returns cpu_rdata in the same cycle (no stall)
 *         a store hit writes the array in its first MEM cycle and reports
 *         cpu_store_done in the second (same 2-phase store as the old data memory)
 *   miss : cpu_busy = 1 until the line is in; the core freezes on cpu_busy
 *          (core_clk_enable), then the line is read again (RELOOKUP) and the
 *          access finishes as a hit
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
    input wire mem_advance, // MEM takes a new instruction at this edge (array is read for lookup_address)
    input wire [31:0] lookup_address, // EX2 address
    input wire cpu_req_valid, // MEM holds a cacheable-region access (level)
    input wire cpu_req_we, // 0 : LOAD, 1 : STORE
    input wire [31:0] cpu_req_addr, // MEM address
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
    output wire [31:0] cpu_rdata, // aligned word for the MEM access (byte extract / sign-ext in core)
    output wire cpu_busy, // 1 : the MEM access is not finished, freeze the core
    output wire cpu_store_done, // 0 : first cycle of a store (2-phase store, same as the old data memory)
    output wire cpu_error, // the MEM access ended with an AXI error, cpu_rdata is not valid

    // Control
    output reg fence_i_done, // 1-cycle pulse after last BRESP
    output reg inval_done, // 1-cycle pulse
    output reg scan_error, // with fence_i_done / inval_done : a write-back got an error response

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
    localparam STATE_INIT = 4'd1; // clear valid / dirty / LRU after reset, one set per cycle
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
    localparam STATE_RELOOKUP = 4'd15; // read the MEM address again after a refill / scan

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
    // Per-set state : {lru (way to evict next), dirty_w1, dirty_w0, valid_w1, valid_w0}
    localparam META_VALID_W0 = 0;
    localparam META_VALID_W1 = 1;
    localparam META_DIRTY_W0 = 2;
    localparam META_DIRTY_W1 = 3;
    localparam META_LRU = 4;
    (* ram_style = "distributed" *) reg [4:0] meta_ram [0:NUM_SETS-1];
    reg [INDEX_BITS-1:0] init_set;

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
    reg refill_error; // error response or RLAST on the wrong beat seen during this refill
    reg scan_error_seen; // a FENCE.I / INVAL write-back got an error response
    reg scan_done_pending; // scan finished, done pulse goes out after RELOOKUP

    // Result of the access currently in MEM (cleared when MEM takes a new instruction)
    reg served; // finished by the FSM (bypass access or AXI error) : answer is in served_rdata
    reg served_error;
    reg [31:0] served_rdata;
    reg store_written; // store hit already written (second MEM cycle of the store)

    // AXI response : SLVERR (10) and DECERR (11) are errors
    wire refill_beat = (state == STATE_ALLOC_R) && m_axi_rvalid && m_axi_rready;
    wire refill_last_beat = m_axi_rlast || (burst_cnt == 2'd3);
    wire refill_beat_error = m_axi_rresp[1] || (m_axi_rlast != (burst_cnt == 2'd3));
    wire refill_failed = refill_error || refill_beat_error;

    // Synchronous BRAM Read (1-cycle latency)
    // EX2 address on mem_advance, victim beats in WB_READ, MEM address in RELOOKUP.
    // Otherwise the registers keep the word of the instruction in MEM.
    reg [63:0] read_data_w0, read_data_w1;
    wire [INDEX_BITS-1:0] lookup_idx = lookup_address[5+INDEX_BITS-1:5];
    wire [INDEX_BITS-1:0] mem_idx = cpu_req_addr[5+INDEX_BITS-1:5];
    wire [INDEX_BITS+1:0] ram_read_idx = (state == STATE_WB_READ) ? {wb_idx, wb_rd_cnt[1:0]}
        : (state == STATE_RELOOKUP) ? {mem_idx, cpu_req_addr[4:3]}
        : {lookup_idx, lookup_address[4:3]};
    wire ram_read_enable = (state == STATE_WB_READ) || (state == STATE_RELOOKUP) || mem_advance;
    always @(posedge clk) begin
        if (clk_enable && ram_read_enable) begin
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

    // Per-set state read (one read address : the scan set during FENCE.I / INVAL, else the access set)
    wire meta_from_scan = (state == STATE_SCAN) || (wb_from_scan &&
        ((state == STATE_WB_READ) || (state == STATE_WB_AW) || (state == STATE_WB_W) || (state == STATE_WB_B)));
    wire [INDEX_BITS-1:0] meta_idx = meta_from_scan ? scan_set : a_idx;
    wire [4:0] meta = meta_ram[meta_idx];
    wire meta_valid_w0 = meta[META_VALID_W0];
    wire meta_valid_w1 = meta[META_VALID_W1];
    wire meta_dirty_w0 = meta[META_DIRTY_W0];
    wire meta_dirty_w1 = meta[META_DIRTY_W1];
    wire meta_lru = meta[META_LRU];

    // Lookup helpers
    wire hit_w0 = meta_valid_w0 && (tag_ram_w0[a_idx] == a_tag);
    wire hit_w1 = meta_valid_w1 && (tag_ram_w1[a_idx] == a_tag);
    wire target_way_comb = meta_valid_w0 ? (meta_valid_w1 ? meta_lru : 1'b1) : 1'b0;
    wire victim_dirty_comb = target_way_comb ? (meta_valid_w1 && meta_dirty_w1)
        : (meta_valid_w0 && meta_dirty_w0);
    wire [TAG_BITS-1:0] victim_tag_comb = target_way_comb ? tag_ram_w1[a_idx] : tag_ram_w0[a_idx];

    // MEM stage : hit check on the word read at the EX2 -> MEM edge
    wire mem_hit = hit_w0 || hit_w1; // a_* follow cpu_req_addr in IDLE
    wire [63:0] mem_hit_data = hit_w0 ? read_data_w0 : read_data_w1;
    wire [31:0] mem_hit_word = cpu_req_addr[2] ? mem_hit_data[63:32] : mem_hit_data[31:0];
    wire mem_need_fsm = cpu_req_valid && !served && (!a_cacheable || !mem_hit);
    wire store_hit_write = (state == STATE_IDLE) && cpu_req_valid && cpu_req_we && a_cacheable &&
        mem_hit && !served && !store_written;

    assign cpu_busy = ((state != STATE_IDLE) && (state != STATE_SCAN_WAIT) && (state != STATE_INIT)) ||
        ((state == STATE_INIT) && cpu_req_valid) ||
        ((state == STATE_IDLE) && (fence_i_req || inval_req || mem_need_fsm));
    assign cpu_rdata = served ? served_rdata : mem_hit_word;
    assign cpu_error = served && served_error;
    assign cpu_store_done = !(cpu_req_valid && cpu_req_we) || served || store_written;

    // MEM store word placed on the 64-bit lane (hit path uses the live MEM inputs)
    wire [63:0] mem_store_data64 = {cpu_req_wdata, cpu_req_wdata};
    wire [7:0] mem_store_strb8 = cpu_req_addr[2] ? {cpu_req_wstrb, 4'b0000} : {4'b0000, cpu_req_wstrb};

    // Scan helpers
    wire scan_valid = scan_way ? meta_valid_w1 : meta_valid_w0;
    wire scan_dirty = scan_way ? meta_dirty_w1 : meta_dirty_w0;
    wire scan_last = scan_way && (scan_set == NUM_SETS-1);

    // Extracted target word from AXI refill
    wire [63:0] current_extracted_data = (burst_cnt == a_offset[4:3]) ? m_axi_rdata : latched_axi_data;

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
            if (store_hit_write) begin
                // STORE hit : merge bytes into the word read at the EX2 -> MEM edge
                data_we_w0 = hit_w0;
                data_we_w1 = !hit_w0;
                data_waddr = {mem_idx, cpu_req_addr[4:3]};
                data_wdata = merge_bytes(mem_hit_data, mem_store_data64, mem_store_strb8);
            end
            else if (state == STATE_ALLOC_R && m_axi_rvalid && m_axi_rready) begin
                // refill beat (a STORE miss is written as a hit after RELOOKUP)
                data_we_w0 = (latched_target_way == 1'b0);
                data_we_w1 = (latched_target_way == 1'b1);
                data_waddr = {a_idx, burst_cnt};
                data_wdata = m_axi_rdata;
            end
        end
    end

    always @(posedge clk) begin
        if (data_we_w0) data_ram_w0[data_waddr] <= data_wdata;
        if (data_we_w1) data_ram_w1[data_waddr] <= data_wdata;
    end

    // Tag RAM write port (end of refill)
    wire tag_we = !reset && clk_enable && refill_beat && refill_last_beat;

    always @(posedge clk) begin
        if (tag_we && latched_target_way == 1'b0) tag_ram_w0[a_idx] <= a_tag;
        if (tag_we && latched_target_way == 1'b1) tag_ram_w1[a_idx] <= a_tag;
    end

    // Per-set state write port (at most one set changes per cycle)
    reg meta_we;
    reg [INDEX_BITS-1:0] meta_widx;
    reg [4:0] meta_wdata;

    always @(*) begin
        meta_we = 1'b0;
        meta_widx = meta_idx;
        meta_wdata = meta;
        if (!reset && clk_enable) begin
            case (state)
                STATE_INIT: begin
                    meta_we = 1'b1;
                    meta_widx = init_set;
                    meta_wdata = 5'b00000;
                end
                STATE_IDLE: begin
                    if (!fence_i_req && !inval_req && cpu_req_valid && !served && a_cacheable && mem_hit) begin
                        meta_we = 1'b1;
                        meta_wdata[META_LRU] = hit_w0;
                        if (store_hit_write) begin
                            if (hit_w0) meta_wdata[META_DIRTY_W0] = 1'b1;
                            else meta_wdata[META_DIRTY_W1] = 1'b1;
                        end
                    end
                end
                STATE_ALLOC_R: begin
                    if (refill_beat && refill_last_beat) begin
                        meta_we = 1'b1;
                        if (latched_target_way == 1'b0) begin
                            meta_wdata[META_VALID_W0] = !refill_failed;
                            meta_wdata[META_DIRTY_W0] = 1'b0;
                        end else begin
                            meta_wdata[META_VALID_W1] = !refill_failed;
                            meta_wdata[META_DIRTY_W1] = 1'b0;
                        end
                        if (!refill_failed) meta_wdata[META_LRU] = ~latched_target_way;
                    end
                end
                STATE_WB_B: begin
                    if (m_axi_bvalid && !m_axi_bresp[1]) begin
                        // write-back accepted : the line is clean (and gone for INVAL)
                        meta_we = 1'b1;
                        if (wb_way) meta_wdata[META_DIRTY_W1] = 1'b0;
                        else meta_wdata[META_DIRTY_W0] = 1'b0;
                        if (wb_from_scan && scan_inval) begin
                            if (scan_way) meta_wdata[META_VALID_W1] = 1'b0;
                            else meta_wdata[META_VALID_W0] = 1'b0;
                        end
                    end
                end
                STATE_SCAN: begin
                    if (!(scan_valid && scan_dirty) && scan_inval) begin
                        meta_we = 1'b1;
                        if (scan_way) meta_wdata[META_VALID_W1] = 1'b0;
                        else meta_wdata[META_VALID_W0] = 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (meta_we) meta_ram[meta_widx] <= meta_wdata;
    end

    integer i;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= STATE_INIT;
            served <= 1'b0;
            served_error <= 1'b0;
            served_rdata <= 32'h0;
            store_written <= 1'b0;
            scan_done_pending <= 1'b0;
            fence_i_done <= 1'b0;
            inval_done <= 1'b0;
            scan_error <= 1'b0;
            refill_error <= 1'b0;
            scan_error_seen <= 1'b0;
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
            init_set <= {INDEX_BITS{1'b0}};
        end else if (clk_enable) begin

            if (perf_clear) begin
                perf_access <= 32'h0;
                perf_miss <= 32'h0;
                perf_wb <= 32'h0;
                perf_stall <= 32'h0;
            end else if (cpu_busy && !wb_from_scan && !scan_done_pending &&
                (state != STATE_SCAN) && !(state == STATE_IDLE && (fence_i_req || inval_req))) begin
                perf_stall <= perf_stall + 32'd1;
            end

            // MEM takes a new instruction : forget the result of the previous one
            if (mem_advance) begin
                served <= 1'b0;
                served_error <= 1'b0;
                store_written <= 1'b0;
                if (cpu_req_valid && a_cacheable && !perf_clear) perf_access <= perf_access + 32'd1;
            end

            case (state)
                STATE_INIT: begin
                    init_set <= init_set + 1'b1;
                    if (init_set == NUM_SETS - 1) state <= STATE_IDLE;
                end

                STATE_IDLE: begin
                    if (fence_i_req || inval_req) begin
                        // the access in MEM (if any) is finished or frozen; RELOOKUP restores its word
                        scan_set <= {INDEX_BITS{1'b0}};
                        scan_way <= 1'b0;
                        scan_inval <= inval_req;
                        scan_error_seen <= 1'b0;
                        state <= STATE_SCAN;
                    end
                    else if (cpu_req_valid && !served && a_cacheable && mem_hit) begin
                        // HIT : load data goes out combinationally, store writes once
                        // LRU / dirty are written by the per-set state write port below
                        if (store_hit_write) store_written <= 1'b1;
                    end
                    else if (mem_need_fsm) begin
                        latched_addr <= cpu_req_addr;
                        latched_we <= cpu_req_we;
                        latched_wdata <= cpu_req_wdata;
                        latched_wstrb <= cpu_req_wstrb;
                        wb_from_scan <= 1'b0;
                        if (a_cacheable) begin
                            // MISS (write-allocate for both LOAD and STORE)
                            if (!perf_clear) perf_miss <= perf_miss + 32'd1;
                            latched_target_way <= target_way_comb;
                            if (victim_dirty_comb) begin
                                wb_idx <= a_idx;
                                wb_way <= target_way_comb;
                                wb_tag <= victim_tag_comb;
                                wb_rd_cnt <= 3'd0;
                                state <= STATE_WB_READ;
                            end else begin
                                m_axi_arvalid <= 1'b1;
                                m_axi_araddr <= {cpu_req_addr[31:5], 5'b00000};
                                state <= STATE_ALLOC_AR;
                            end
                        end else begin
                            // BYPASS (uncached single beat)
                            if (cpu_req_we) begin
                                m_axi_awvalid <= 1'b1;
                                m_axi_awaddr <= {cpu_req_addr[31:3], 3'b000};
                                state <= STATE_BYPASS_AW;
                            end else begin
                                m_axi_arvalid <= 1'b1;
                                m_axi_araddr <= {cpu_req_addr[31:3], 3'b000};
                                state <= STATE_BYPASS_AR;
                            end
                        end
                    end
                end

                STATE_RELOOKUP: begin
                    // ram_read_idx = MEM address this cycle; the access finishes as a hit next cycle
                    if (scan_done_pending) begin
                        scan_done_pending <= 1'b0;
                        if (scan_inval) inval_done <= 1'b1;
                        else fence_i_done <= 1'b1;
                        scan_error <= scan_error_seen;
                        state <= STATE_SCAN_WAIT;
                    end else begin
                        state <= STATE_IDLE;
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
                        if (!m_axi_bresp[1]) begin
                            // write-back accepted : the line is clean now
                            if (!perf_clear) perf_wb <= perf_wb + 32'd1;
                        end

                        if (wb_from_scan) begin
                            // on an error the line stays dirty and valid (data is not lost)
                            if (m_axi_bresp[1])
                                scan_error_seen <= 1'b1;
                            if (scan_last) begin
                                scan_done_pending <= 1'b1;
                                state <= STATE_RELOOKUP;
                            end else begin
                                if (scan_way) scan_set <= scan_set + 1'b1;
                                scan_way <= ~scan_way;
                                state <= STATE_SCAN;
                            end
                        end else if (m_axi_bresp[1]) begin
                            // victim could not be written back : keep it and give up this request
                            served <= 1'b1;
                            served_error <= 1'b1;
                            state <= STATE_IDLE;
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
                        refill_error <= 1'b0;
                        state <= STATE_ALLOC_R;
                    end
                end

                STATE_ALLOC_R: begin
                    if (refill_beat) begin
                        // each beat is written by the data RAM write port below
                        if (burst_cnt == a_offset[4:3]) latched_axi_data <= m_axi_rdata;
                        burst_cnt <= burst_cnt + 2'd1;
                        if (refill_beat_error) refill_error <= 1'b1;

                        if (refill_last_beat) begin
                            // tag is written by the tag RAM write port below
                            if (refill_failed) begin
                                // broken line : not kept (per-set state write port), the victim was already clean
                                served <= 1'b1;
                                served_error <= 1'b1;
                                served_rdata <= a_offset[2] ? current_extracted_data[63:32] : current_extracted_data[31:0];
                                state <= STATE_IDLE;
                            end else begin
                                // clean line in; a STORE writes it as a hit after RELOOKUP
                                state <= STATE_RELOOKUP;
                            end
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
                        served <= 1'b1;
                        served_rdata <= a_offset[2] ? m_axi_rdata[63:32] : m_axi_rdata[31:0];
                        served_error <= m_axi_rresp[1] || !m_axi_rlast;
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
                        served <= 1'b1;
                        served_error <= m_axi_bresp[1];
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
                        // INVAL clears valid through the per-set state write port
                        if (scan_last) begin
                            scan_done_pending <= 1'b1;
                            state <= STATE_RELOOKUP;
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
                    scan_error <= 1'b0;
                    wb_from_scan <= 1'b0;
                    if (!fence_i_req && !inval_req) state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule
