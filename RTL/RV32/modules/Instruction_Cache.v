/*
 * RV32IM54F8SP Instruction Cache Module
 * - 2-Way Set Associative, 32B Line Size, NUM_SETS sets (default 512 = 32KB)
 * - True LRU, Read-Only, AXI4 Bus Master Interface (AR / R, 64-bit, INCR x 4 beat)
 * - Pipeline interface (same timing as a synchronous instruction memory, 1-cycle read latency)
 *   IF : lookup_address is read from the data array when fetch_advance = 1
 *   next cycle : tag compare on cpu_req_addr; a hit returns cpu_rdata in the same cycle
 *   miss : cpu_busy = 1 until the line is in; the core freezes on cpu_busy, then the line
 *          is read again (RELOOKUP) and the fetch finishes as a hit
 * - AXI error handling
 *   RRESP error or RLAST on the wrong beat : the line is not kept and the fetch ends with
 *   served_rdata and cpu_error (level until the next fetch_advance)
 *   The refill ends on the 4th beat or on RLAST, whichever comes first
 * - FENCE.I : fence_i_req is a level held until fence_i_done (1-cycle pulse);
 *   req must be low for at least one cycle before the next request
 */

module InstructionCache #(
	parameter NUM_SETS = 512, // power of 2, 16 ~ 512
	parameter CACHE_EN = 1, // 0 : every access bypasses the cache
	parameter [31:0] CACHEABLE_BASE = 32'h8000_0000,
	parameter [31:0] CACHEABLE_MASK = 32'hE000_0000
)(
	input wire clk,
	input wire reset,
	input wire clk_enable,

	// CPU Core -> Instruction Cache
	input wire fetch_advance, // IF takes a new pc at this edge (array is read for lookup_address)
	input wire [31:0] lookup_address, // IF pc
	input wire cpu_req_valid, // the fetch now at the output is a cacheable-region fetch (level)
	input wire [31:0] cpu_req_addr, // address of that fetch
	input wire fence_i_req,
	input wire perf_clear,

	// Instruction Cache -> CPU Core
	output wire [31:0] cpu_rdata,
	output wire cpu_busy, // 1 : the fetch is not finished, freeze the core
	output wire cpu_error, // the fetch ended with an AXI error, cpu_rdata is not valid
	output reg fence_i_done,

	// Performance counters
	output reg [31:0] perf_access,
	output reg [31:0] perf_miss,
	output reg [31:0] perf_stall,

	// AXI4 Master Interface (AR Channel)
	input wire m_axi_arready,
	output reg m_axi_arvalid,
	output reg [31:0] m_axi_araddr,
	output wire [7:0] m_axi_arlen,
	output wire [2:0] m_axi_arsize,
	output wire [1:0] m_axi_arburst,

	// AXI4 Master Interface (R Channel)
	input wire [63:0] m_axi_rdata,
	input wire [1:0] m_axi_rresp,
	input wire m_axi_rlast,
	input wire m_axi_rvalid,
	output wire m_axi_rready
);

	localparam INDEX_BITS = $clog2(NUM_SETS);
	localparam TAG_BITS = 32 - 5 - INDEX_BITS;

	localparam STATE_IDLE = 3'd0;
	localparam STATE_RELOOKUP = 3'd1; // read the fetch address again after a refill
	localparam STATE_ALLOC_AR = 3'd2;
	localparam STATE_ALLOC_R = 3'd3;
	localparam STATE_BYPASS_AR = 3'd4;
	localparam STATE_BYPASS_R = 3'd5;
	localparam STATE_FENCE = 3'd6;
	localparam STATE_FENCE_WAIT = 3'd7;

	reg [2:0] state;

	// Latched Request Info
	reg [31:0] latched_addr;
	reg [63:0] latched_axi_data;
	reg latched_target_way;

	// Address Decoding (Use stable latched_addr during operation)
	wire fetch_check_state = (state == STATE_IDLE) || (state == STATE_FENCE_WAIT);
	wire [31:0] active_addr = fetch_check_state ? cpu_req_addr : latched_addr;
	wire [TAG_BITS-1:0] a_tag = active_addr[31:5+INDEX_BITS];
	wire [INDEX_BITS-1:0] a_idx = active_addr[5+INDEX_BITS-1:5];
	wire [4:2] a_offset = active_addr[4:2]; // [4:3] beat, [2] word
	wire a_cacheable = (CACHE_EN != 0) && ((active_addr & CACHEABLE_MASK) == CACHEABLE_BASE);

	reg [TAG_BITS-1:0] tag_ram_w0 [0:NUM_SETS-1];
	reg [TAG_BITS-1:0] tag_ram_w1 [0:NUM_SETS-1];
	reg [NUM_SETS-1:0] valid_w0;
	reg [NUM_SETS-1:0] valid_w1;
	reg [NUM_SETS-1:0] lru_bit; // way to evict next

	(* ram_style = "block" *) reg [63:0] data_ram_w0 [0:(NUM_SETS*4)-1];
	(* ram_style = "block" *) reg [63:0] data_ram_w1 [0:(NUM_SETS*4)-1];

	reg [1:0] burst_cnt;
	reg refill_error; // error response or RLAST on the wrong beat seen during this refill
	reg [INDEX_BITS:0] fence_cnt;

	// Result of the fetch now at the output (cleared when IF takes a new pc)
	reg served; // finished by the FSM (bypass or AXI error) : answer is in served_rdata
	reg served_error;
	reg [31:0] served_rdata;

	// Synchronous BRAM Read (1-cycle latency)
	// IF pc on fetch_advance, the fetch address again in RELOOKUP.
	// Otherwise the registers keep the word of the fetch at the output.
	reg [63:0] read_data_w0, read_data_w1;
	wire [INDEX_BITS-1:0] lookup_idx = lookup_address[5+INDEX_BITS-1:5];
	wire [INDEX_BITS+1:0] ram_read_idx = (state == STATE_RELOOKUP) ? {a_idx, a_offset[4:3]}
		: {lookup_idx, lookup_address[4:3]};
	wire ram_read_enable = fetch_advance || (state == STATE_RELOOKUP);

	always @(posedge clk) begin
		if (clk_enable && ram_read_enable) begin
			read_data_w0 <= data_ram_w0[ram_read_idx];
			read_data_w1 <= data_ram_w1[ram_read_idx];
		end
	end

	// AXI response : SLVERR (10) and DECERR (11) are errors
	// RREADY only on enabled edges, so a slave that ignores clk_enable never loses a beat
	assign m_axi_arlen = (state == STATE_BYPASS_AR) ? 8'd0 : 8'd3;
	assign m_axi_arsize = 3'b011;
	assign m_axi_arburst = 2'b01;
	assign m_axi_rready = clk_enable && ((state == STATE_ALLOC_R) || (state == STATE_BYPASS_R));

	wire ar_handshake = m_axi_arvalid && m_axi_arready;
	wire refill_beat = (state == STATE_ALLOC_R) && m_axi_rvalid && m_axi_rready;
	wire refill_last_beat = m_axi_rlast || (burst_cnt == 2'd3);
	wire refill_beat_error = m_axi_rresp[1] || (m_axi_rlast != (burst_cnt == 2'd3));
	wire refill_failed = refill_error || refill_beat_error;

	// Lookup on the word read at the fetch edge
	wire hit_w0 = valid_w0[a_idx] && (tag_ram_w0[a_idx] == a_tag);
	wire hit_w1 = valid_w1[a_idx] && (tag_ram_w1[a_idx] == a_tag);
	wire fetch_hit = a_cacheable && (hit_w0 || hit_w1);
	wire [63:0] fetch_hit_data = hit_w0 ? read_data_w0 : read_data_w1;
	wire [31:0] fetch_hit_word = cpu_req_addr[2] ? fetch_hit_data[63:32] : fetch_hit_data[31:0];
	wire fetch_need_fsm = cpu_req_valid && !served && !fetch_hit;
	wire target_way_comb = valid_w0[a_idx] ? (valid_w1[a_idx] ? lru_bit[a_idx] : 1'b1) : 1'b0;

	// FENCE_WAIT stays busy until req drops: the requester sees fence_i_done while the
	// core is still frozen (FENCE.I is still in EX2 when the core moves again)
	assign cpu_busy = !fetch_check_state || fence_i_req || fetch_need_fsm;
	assign cpu_rdata = served ? served_rdata : fetch_hit ? fetch_hit_word : 32'h0000_0013;
	assign cpu_error = served && served_error;

	// Extracted target word from AXI refill
	wire [63:0] current_extracted_data = (burst_cnt == a_offset[4:3]) ? m_axi_rdata : latched_axi_data;

	// Data / tag RAM writes live in reset-less blocks so they can be inferred as BRAM
	wire data_we = !reset && refill_beat;
	wire tag_we = data_we && refill_last_beat;

	always @(posedge clk) begin
		if (data_we && latched_target_way == 1'b0) data_ram_w0[{a_idx, burst_cnt}] <= m_axi_rdata;
		if (data_we && latched_target_way == 1'b1) data_ram_w1[{a_idx, burst_cnt}] <= m_axi_rdata;
	end

	always @(posedge clk) begin
		if (tag_we && latched_target_way == 1'b0) tag_ram_w0[a_idx] <= a_tag;
		if (tag_we && latched_target_way == 1'b1) tag_ram_w1[a_idx] <= a_tag;
	end

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			state <= STATE_IDLE;
			served <= 1'b0;
			served_error <= 1'b0;
			served_rdata <= 32'h0000_0013;
			fence_i_done <= 1'b0;
			m_axi_arvalid <= 1'b0;
			m_axi_araddr <= 32'h0;
			burst_cnt <= 2'b0;
			refill_error <= 1'b0;
			fence_cnt <= {(INDEX_BITS+1){1'b0}};
			latched_addr <= 32'h0;
			latched_axi_data <= 64'h0;
			latched_target_way <= 1'b0;
			perf_access <= 32'h0;
			perf_miss <= 32'h0;
			perf_stall <= 32'h0;
			valid_w0 <= {NUM_SETS{1'b0}};
			valid_w1 <= {NUM_SETS{1'b0}};
			lru_bit <= {NUM_SETS{1'b0}};
		end
		// The AR handshake is also taken on an edge with clk_enable = 0: a slave that does not
		// see clk_enable has already accepted the address there (state is ALLOC_AR / BYPASS_AR).
		else if (clk_enable || ar_handshake) begin

			if (clk_enable) begin
				if (perf_clear) begin
					perf_access <= 32'h0;
					perf_miss <= 32'h0;
					perf_stall <= 32'h0;
				end
				else if (cpu_busy && (state != STATE_FENCE) && !fence_i_req) begin
					perf_stall <= perf_stall + 32'd1;
				end

				// IF takes a new pc : forget the result of the previous fetch
				if (fetch_advance) begin
					served <= 1'b0;
					served_error <= 1'b0;
					if (cpu_req_valid && a_cacheable && !perf_clear) perf_access <= perf_access + 32'd1;
				end
			end

			case (state)
				STATE_IDLE: begin
					fence_i_done <= 1'b0;

					if (fence_i_req) begin
						fence_cnt <= {(INDEX_BITS+1){1'b0}};
						state <= STATE_FENCE;
					end
					else if (cpu_req_valid && !served && fetch_hit) begin
						lru_bit[a_idx] <= hit_w0;
					end
					else if (fetch_need_fsm) begin
						latched_addr <= cpu_req_addr;
						if (a_cacheable) begin
							// MISS
							if (!perf_clear) perf_miss <= perf_miss + 32'd1;
							latched_target_way <= target_way_comb;
							m_axi_arvalid <= 1'b1;
							m_axi_araddr <= {cpu_req_addr[31:5], 5'b00000};
							state <= STATE_ALLOC_AR;
						end else begin
							// BYPASS (uncached single beat)
							m_axi_arvalid <= 1'b1;
							m_axi_araddr <= {cpu_req_addr[31:3], 3'b000};
							state <= STATE_BYPASS_AR;
						end
					end
				end

				STATE_RELOOKUP: begin
					// ram_read_idx = fetch address this cycle; the fetch finishes as a hit next cycle
					state <= STATE_IDLE;
				end

				STATE_ALLOC_AR: begin
					if (ar_handshake) begin
						m_axi_arvalid <= 1'b0;
						burst_cnt <= 2'b0;
						refill_error <= 1'b0;
						state <= STATE_ALLOC_R;
					end
				end

				STATE_ALLOC_R: begin
					if (refill_beat) begin
						// each beat is written by the data RAM write port above
						if (burst_cnt == a_offset[4:3]) latched_axi_data <= m_axi_rdata;
						burst_cnt <= burst_cnt + 2'd1;
						if (refill_beat_error) refill_error <= 1'b1;

						if (refill_last_beat) begin
							if (refill_failed) begin
								// broken line : do not keep it, answer this fetch once with an error
								if (latched_target_way == 1'b0) valid_w0[a_idx] <= 1'b0;
								else valid_w1[a_idx] <= 1'b0;
								served <= 1'b1;
								served_error <= 1'b1;
								served_rdata <= a_offset[2] ? current_extracted_data[63:32] : current_extracted_data[31:0];
								state <= STATE_IDLE;
							end else begin
								if (latched_target_way == 1'b0) valid_w0[a_idx] <= 1'b1;
								else valid_w1[a_idx] <= 1'b1;
								lru_bit[a_idx] <= ~latched_target_way;
								state <= STATE_RELOOKUP;
							end
						end
					end
				end

				STATE_BYPASS_AR: begin
					if (ar_handshake) begin
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

				STATE_FENCE: begin
					if (!fence_cnt[INDEX_BITS]) begin // fence_cnt < NUM_SETS
						valid_w0[fence_cnt[INDEX_BITS-1:0]] <= 1'b0;
						valid_w1[fence_cnt[INDEX_BITS-1:0]] <= 1'b0;
						fence_cnt <= fence_cnt + 1'b1;
					end else begin
						fence_i_done <= 1'b1;
						state <= STATE_FENCE_WAIT;
					end
				end

				STATE_FENCE_WAIT: begin
					fence_i_done <= 1'b0; // 1-cycle pulse
					if (!fence_i_req) state <= STATE_IDLE; // wait for req to drop (prevents re-running FENCE.I)
				end

				default: state <= STATE_IDLE;
			endcase
		end
	end
endmodule
