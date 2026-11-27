`timescale 1ns / 1ps

`include "./modules/Instruction_Cache.v"
`include "./modules/Dummy_DDR_Memory.v"

/*
 * Instruction Cache testbench
 * - The testbench drives the cache the way the core does: lookup_address is read on fetch_advance,
 *   cpu_req_addr / cpu_req_valid describe the fetch at the output, and the "core" moves on
 *   only on an edge with clk_enable = 1 and cpu_busy = 0
 * - Every fetch is checked against the memory (cpu_rdata) and against a reference
 *   model of the cache: hit = no AXI burst, miss = one burst, LRU victim, FENCE.I invalidation
 * - AXI slave : testbench model (random latency, SLVERR on one beat or RLAST missing,
 *   gated by clk_enable or not) or DummyDDRMemory (fixed latency, SLVERR window at 0x8001_F000)
 * - RRESP / RLAST are not checked by the cache: with SLVERR or a missing RLAST the data is
 *   still correct, so every fetch returns the memory word and every refill keeps its line
 * - Run from RTL/RV32:
 *   iverilog -PInstructionCache_tb.NUM_SETS=16 -o ic.vvp testbenches/Instruction_cache_tb.v
 *   vvp -n ic.vvp
 */
module InstructionCache_tb;
	parameter NUM_SETS = 512;
	parameter CACHE_EN = 1;
	parameter RANDOM_FETCHES = 20000; // per random phase

	localparam INDEX_BITS = $clog2(NUM_SETS);
	localparam WAY_BYTES = NUM_SETS * 32;
	localparam DDR_WORDS = 16384; // 64-bit words : 128KB window at 0x8000_0000
	localparam [31:0] NOP = 32'h0000_0013;
	localparam DUMMY_READ_LATENCY = 6;
	localparam [31:0] DUMMY_ERROR_ADDRESS = 32'h8001_F000;
	localparam STREAM_SIZE = 65536;

	reg clk;
	reg reset;
	reg clk_enable;

	initial clk = 1'b0;
	always #5 clk = ~clk;

	// ------------------------------------------------------------------------
	// Core side
	// ------------------------------------------------------------------------
	reg [31:0] stream [0:STREAM_SIZE-1]; // fetch addresses, in order
	integer stream_len;
	integer stream_pos;
	reg stall; // pc_stall of the core
	reg [31:0] fetch_pc; // cpu_req_addr (instruction_pc of the core)
	reg issued; // cpu_req_valid
	reg fence_req;
	reg perf_clear;

	wire [31:0] cpu_rdata;
	wire cpu_busy;
	wire fence_i_done;
	wire [31:0] perf_access;
	wire [31:0] perf_miss;
	wire [31:0] perf_stall;

	wire [31:0] lookup_address = stream[stream_pos];
	wire fetch_advance = clk_enable && !cpu_busy && !stall && !reset && (stream_pos < stream_len);

	// ------------------------------------------------------------------------
	// AXI
	// ------------------------------------------------------------------------
	wire [31:0] m_axi_araddr;
	wire [7:0] m_axi_arlen;
	wire [2:0] m_axi_arsize;
	wire [1:0] m_axi_arburst;
	wire m_axi_arvalid;
	wire m_axi_arready;
	wire [63:0] m_axi_rdata;
	wire [1:0] m_axi_rresp;
	wire m_axi_rlast;
	wire m_axi_rvalid;
	wire m_axi_rready;

	InstructionCache #(
		.NUM_SETS(NUM_SETS),
		.CACHE_EN(CACHE_EN)
	) instruction_cache (
		.clk(clk),
		.reset(reset),
		.clk_enable(clk_enable),
		.fetch_advance(fetch_advance),
		.lookup_address(lookup_address),
		.cpu_req_valid(issued),
		.cpu_req_addr(fetch_pc),
		.fence_i_req(fence_req),
		.perf_clear(perf_clear),
		.cpu_rdata(cpu_rdata),
		.cpu_busy(cpu_busy),
		.fence_i_done(fence_i_done),
		.perf_access(perf_access),
		.perf_miss(perf_miss),
		.perf_stall(perf_stall),
		.m_axi_arready(m_axi_arready),
		.m_axi_arvalid(m_axi_arvalid),
		.m_axi_araddr(m_axi_araddr),
		.m_axi_arlen(m_axi_arlen),
		.m_axi_arsize(m_axi_arsize),
		.m_axi_arburst(m_axi_arburst),
		.m_axi_rdata(m_axi_rdata),
		.m_axi_rresp(m_axi_rresp),
		.m_axi_rlast(m_axi_rlast),
		.m_axi_rvalid(m_axi_rvalid),
		.m_axi_rready(m_axi_rready)
	);

	// Memory contents (TB model and DummyDDRMemory hold the same words)
	reg [63:0] memory [0:DDR_WORDS-1];

	function [31:0] memory_word(input [31:0] address);
		reg [63:0] line_word;
		begin
			line_word = memory[(address >> 3) & (DDR_WORDS-1)];
			memory_word = address[2] ? line_word[63:32] : line_word[31:0];
		end
	endfunction

	// ------------------------------------------------------------------------
	// Slave select
	// ------------------------------------------------------------------------
	reg use_dummy;
	reg slave_gated; // TB model only : 1 = moves only on clk_enable edges (like InstructionMemory)

	wire dummy_arready;
	wire [63:0] dummy_rdata;
	wire [1:0] dummy_rresp;
	wire dummy_rlast;
	wire dummy_rvalid;

	DummyDDRMemory #(
		.ADDRESS_WIDTH(14),
		.READ_LATENCY(DUMMY_READ_LATENCY),
		.ERROR_ENABLE(1),
		.ERROR_ADDRESS_MASK(32'hFFFF_F000),
		.READ_ERROR_ADDRESS(DUMMY_ERROR_ADDRESS)
	) dummy_ddr_memory (
		.clk(clk),
		.reset(reset),
		.s_axi_awaddr(32'h0),
		.s_axi_awlen(8'd0),
		.s_axi_awsize(3'd0),
		.s_axi_awburst(2'd0),
		.s_axi_awvalid(1'b0),
		.s_axi_awready(),
		.s_axi_wdata(64'h0),
		.s_axi_wstrb(8'h0),
		.s_axi_wlast(1'b0),
		.s_axi_wvalid(1'b0),
		.s_axi_wready(),
		.s_axi_bresp(),
		.s_axi_bvalid(),
		.s_axi_bready(1'b0),
		.s_axi_araddr(m_axi_araddr),
		.s_axi_arlen(m_axi_arlen),
		.s_axi_arsize(m_axi_arsize),
		.s_axi_arburst(m_axi_arburst),
		.s_axi_arvalid(m_axi_arvalid && use_dummy),
		.s_axi_arready(dummy_arready),
		.s_axi_rdata(dummy_rdata),
		.s_axi_rresp(dummy_rresp),
		.s_axi_rlast(dummy_rlast),
		.s_axi_rvalid(dummy_rvalid),
		.s_axi_rready(m_axi_rready && use_dummy)
	);

	// ------------------------------------------------------------------------
	// TB AXI slave model
	// error mode per burst : 0 none, 1 SLVERR on one beat, 2 RLAST missing (data is correct in both)
	// ------------------------------------------------------------------------
	reg model_active; // a burst is accepted
	reg [31:0] model_address;
	reg [7:0] model_length;
	reg [7:0] model_beat;
	reg [3:0] model_wait;
	reg [3:0] model_ar_wait;
	reg [1:0] model_error_mode;
	reg [1:0] model_error_beat;
	reg model_rvalid;
	reg [63:0] model_rdata;
	reg [1:0] model_rresp;
	reg model_rlast;
	integer latency_max; // R latency 0 .. latency_max-1, beat gaps and AR wait 0 .. 2
	integer error_rate; // 1 of error_rate bursts gets SLVERR or a missing RLAST, 0 = never
	reg [1:0] force_error_mode; // directed tests : error mode of the next burst
	reg [1:0] force_error_beat;

	wire model_step = !slave_gated || clk_enable;
	wire model_arready = !use_dummy && !model_active && (model_ar_wait == 4'd0) && model_step;

	assign m_axi_arready = use_dummy ? dummy_arready : model_arready;
	assign m_axi_rdata = use_dummy ? dummy_rdata : model_rdata;
	assign m_axi_rresp = use_dummy ? dummy_rresp : model_rresp;
	assign m_axi_rlast = use_dummy ? dummy_rlast : model_rlast;
	assign m_axi_rvalid = use_dummy ? dummy_rvalid : model_rvalid;

	function integer random_below(input integer limit);
		begin
			if (limit <= 1) random_below = 0;
			else random_below = $unsigned($random) % limit;
		end
	endfunction

	task model_present_beat;
		input [7:0] beat;
		begin
			model_rvalid <= 1'b1;
			model_rdata <= memory[((model_address >> 3) + beat) & (DDR_WORDS-1)];
			model_rresp <= (model_error_mode == 2'd1 && beat == model_error_beat) ? 2'b10 : 2'b00;
			model_rlast <= (model_error_mode == 2'd2) ? 1'b0 : (beat == model_length);
		end
	endtask

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			model_active <= 1'b0;
			model_rvalid <= 1'b0;
			model_rlast <= 1'b0;
			model_rresp <= 2'b00;
			model_rdata <= 64'h0;
			model_beat <= 8'd0;
			model_wait <= 4'd0;
			model_ar_wait <= 4'd0;
		end
		else if (!use_dummy && model_step) begin
			if (!model_active) begin
				if (m_axi_arvalid && model_arready) begin
					model_active <= 1'b1;
					model_address <= m_axi_araddr;
					model_length <= m_axi_arlen;
					model_beat <= 8'd0;
					model_wait <= random_below(latency_max);
					model_ar_wait <= random_below(3);
					if (force_error_mode != 2'd0) begin
						model_error_mode <= force_error_mode;
						model_error_beat <= force_error_beat;
						force_error_mode <= 2'd0;
					end
					else if (error_rate != 0 && random_below(error_rate) == 0) begin
						model_error_mode <= ($random & 1) ? 2'd1 : 2'd2;
						model_error_beat <= (m_axi_arlen == 8'd0) ? 2'd0 : random_below(4);
					end
					else begin
						model_error_mode <= 2'd0;
					end
				end
				else if (model_ar_wait != 4'd0) begin
					model_ar_wait <= model_ar_wait - 4'd1;
				end
			end
			else if (model_rvalid) begin
				if (m_axi_rready) begin
					if (model_beat == model_length) begin
						model_rvalid <= 1'b0;
						model_rlast <= 1'b0;
						model_active <= 1'b0;
					end
					else begin
						model_beat <= model_beat + 8'd1;
						model_wait <= random_below(3);
						if (random_below(3) == 0) model_present_beat(model_beat + 8'd1);
						else model_rvalid <= 1'b0;
					end
				end
			end
			else if (model_wait != 4'd0) begin
				model_wait <= model_wait - 4'd1;
			end
			else begin
				model_present_beat(model_beat);
			end
		end
	end

	// ------------------------------------------------------------------------
	// Reference model of the cache
	// ------------------------------------------------------------------------
	reg reference_valid0 [0:NUM_SETS-1];
	reg reference_valid1 [0:NUM_SETS-1];
	reg [31:0] reference_tag0 [0:NUM_SETS-1];
	reg [31:0] reference_tag1 [0:NUM_SETS-1];
	reg reference_lru [0:NUM_SETS-1]; // way to evict next
	integer set_index;

	function cacheable(input [31:0] address);
		cacheable = (CACHE_EN != 0) && (address[31:29] == 3'b100);
	endfunction

	function [INDEX_BITS-1:0] index_of(input [31:0] address);
		index_of = address[5+INDEX_BITS-1:5];
	endfunction

	function [31:0] tag_of(input [31:0] address);
		tag_of = address >> (5 + INDEX_BITS);
	endfunction

	// 0 : miss, 1 : hit way 0, 2 : hit way 1
	function [1:0] reference_lookup(input [31:0] address);
		begin
			if (reference_valid0[index_of(address)] && reference_tag0[index_of(address)] == tag_of(address))
				reference_lookup = 2'd1;
			else if (reference_valid1[index_of(address)] && reference_tag1[index_of(address)] == tag_of(address))
				reference_lookup = 2'd2;
			else
				reference_lookup = 2'd0;
		end
	endfunction

	task reference_reset;
		begin
			for (set_index = 0; set_index < NUM_SETS; set_index = set_index + 1) begin
				reference_valid0[set_index] = 1'b0;
				reference_valid1[set_index] = 1'b0;
				reference_lru[set_index] = 1'b0;
			end
		end
	endtask

	task reference_invalidate;
		begin
			for (set_index = 0; set_index < NUM_SETS; set_index = set_index + 1) begin
				reference_valid0[set_index] = 1'b0;
				reference_valid1[set_index] = 1'b0;
			end
		end
	endtask

	// end of a 4-beat refill : the victim way gets the line (RRESP / RLAST do not matter)
	task reference_refill;
		input [31:0] address;
		reg victim;
		reg [INDEX_BITS-1:0] index;
		begin
			index = index_of(address);
			victim = !reference_valid0[index] ? 1'b0 : !reference_valid1[index] ? 1'b1 : reference_lru[index];
			if (victim == 1'b0) begin
				reference_valid0[index] = 1'b1;
				reference_tag0[index] = tag_of(address);
			end
			else begin
				reference_valid1[index] = 1'b1;
				reference_tag1[index] = tag_of(address);
			end
			reference_lru[index] = ~victim;
		end
	endtask

	// ------------------------------------------------------------------------
	// Monitor, checker and core driver
	// ------------------------------------------------------------------------
	integer error_count; // protocol / data / model mismatches
	integer ar_count; // AR handshakes
	integer refill_count; // AR handshakes with ARLEN = 3
	integer burst_done_count;
	reg burst_open;
	reg [31:0] burst_address;
	reg [7:0] burst_length;
	reg [7:0] burst_beats;
	reg ar_pending; // ARVALID was high without ARREADY on the previous edge
	reg [31:0] ar_pending_address;
	reg [7:0] ar_pending_length;

	integer fence_done_count;
	integer fence_gap;
	integer fence_rate; // random phases : 1 of fence_rate cycles raises fence_i_req, 0 = never
	reg fence_done_previous;

	// fetch at the output
	reg checked;
	reg predicted_hit;
	integer ar_at_issue;
	integer fence_at_issue;
	reg [31:0] saved_rdata;
	integer completed_count;
	integer hit_count;
	integer wait_cycles;

	// expected performance counters
	integer access_expected;
	integer miss_expected;
	integer stall_expected;

	integer cycle_count;
	reg check_messages; // print every mismatch (directed) or only the first few (random)
	integer mismatch_print;

	task report_mismatch;
		input [8*64-1:0] what;
		begin
			error_count = error_count + 1;
			if (check_messages || mismatch_print < 10)
				$display("     [mismatch] t=%0t %0s : pc=%h rdata=%h expected=%h", $time, what,
					fetch_pc, cpu_rdata, memory_word(fetch_pc));
			mismatch_print = mismatch_print + 1;
		end
	endtask

	reg [1:0] lookup_result;
	integer ar_since;

	always @(posedge clk) begin
		cycle_count = cycle_count + 1;
		if (reset) begin
			issued <= 1'b0;
			fence_req <= 1'b0;
			checked = 1'b0;
			burst_open = 1'b0;
			ar_pending = 1'b0;
			fence_done_previous = 1'b0;
			access_expected = 0;
			miss_expected = 0;
			stall_expected = 0;
			if (!issued && !fence_req && (cpu_rdata !== NOP || cpu_busy !== 1'b0)) begin
				error_count = error_count + 1;
				$display("     [mismatch] t=%0t during reset : rdata=%h busy=%b", $time, cpu_rdata, cpu_busy);
			end
		end
		else begin
			// ---------------- AXI protocol ----------------
			if (m_axi_rready && !clk_enable) begin
				error_count = error_count + 1;
				$display("     [mismatch] t=%0t RREADY with clk_enable = 0", $time);
			end
			if (ar_pending && (!m_axi_arvalid || m_axi_araddr != ar_pending_address || m_axi_arlen != ar_pending_length)) begin
				error_count = error_count + 1;
				$display("     [mismatch] t=%0t ARVALID / ARADDR changed before ARREADY", $time);
			end
			ar_pending = m_axi_arvalid && !m_axi_arready;
			ar_pending_address = m_axi_araddr;
			ar_pending_length = m_axi_arlen;

			if (m_axi_arvalid && m_axi_arready) begin
				ar_count = ar_count + 1;
				if (burst_open || m_axi_arsize != 3'b011 || m_axi_arburst != 2'b01 ||
					!((m_axi_arlen == 8'd3 && m_axi_araddr[4:0] == 5'd0) || (m_axi_arlen == 8'd0 && m_axi_araddr[2:0] == 3'd0))) begin
					error_count = error_count + 1;
					$display("     [mismatch] t=%0t bad AR : open=%b addr=%h len=%0d size=%0d burst=%0d", $time,
						burst_open, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst);
				end
				if (m_axi_arlen == 8'd3) begin
					refill_count = refill_count + 1;
					if (!perf_clear) miss_expected = miss_expected + 1;
				end
				burst_open = 1'b1;
				burst_address = m_axi_araddr;
				burst_length = m_axi_arlen;
				burst_beats = 8'd0;
			end

			if (m_axi_rvalid && m_axi_rready) begin
				if (!burst_open) begin
					error_count = error_count + 1;
					$display("     [mismatch] t=%0t R beat without a burst", $time);
				end
				// the burst ends on the beat count, like the cache (RLAST is not looked at)
				if (burst_beats == burst_length) begin
					burst_open = 1'b0;
					burst_done_count = burst_done_count + 1;
					if (burst_length == 8'd3) reference_refill(burst_address);
				end
				burst_beats = burst_beats + 8'd1;
			end

			// ---------------- FENCE.I handshake (core side runs on clk_enable) ----------------
			if (clk_enable) begin
				if (fence_done_previous && fence_i_done) begin
					error_count = error_count + 1;
					$display("     [mismatch] t=%0t fence_i_done longer than 1 cycle", $time);
				end
				if (fence_i_done && !fence_req) begin
					error_count = error_count + 1;
					$display("     [mismatch] t=%0t fence_i_done without a request", $time);
				end
				fence_done_previous = fence_i_done;
				if (fence_req && cpu_busy !== 1'b1) begin
					error_count = error_count + 1;
					$display("     [mismatch] t=%0t cpu_busy = 0 while fence_i_req is high", $time);
				end
				if (fence_req && fence_i_done) begin
					// req is held up to the done cycle and dropped here (level protocol)
					fence_req <= 1'b0;
					fence_done_count = fence_done_count + 1;
					fence_gap = 1 + random_below(3);
					reference_invalidate;
					if (issued) begin
						checked = 1'b0;
						ar_at_issue = ar_count;
					end
				end
				else if (!fence_req && fence_gap > 0) begin
					fence_gap = fence_gap - 1;
				end
				else if (!fence_req && fence_rate != 0 && random_below(fence_rate) == 0 && stream_pos < stream_len) begin
					fence_req <= 1'b1;
				end
			end

			// ---------------- performance counters ----------------
			if (clk_enable) begin
				if (perf_clear) begin
					access_expected = 0;
					miss_expected = 0;
					stall_expected = 0;
				end
				else begin
					if (cpu_busy && !fence_req) stall_expected = stall_expected + 1;
					if (fetch_advance && issued && cacheable(fetch_pc)) access_expected = access_expected + 1;
				end
			end

			// ---------------- fetch completion ----------------
			if (clk_enable && !cpu_busy && issued) begin
				if (!checked) begin
					ar_since = ar_count - ar_at_issue;
					if (cpu_rdata !== memory_word(fetch_pc))
						report_mismatch("cpu_rdata");
					if (fence_at_issue == fence_done_count) begin
						if (!cacheable(fetch_pc)) begin
							if (ar_since != 1 || burst_length != 8'd0) report_mismatch("bypass is not one single-beat burst");
						end
						else if (predicted_hit) begin
							if (ar_since != 0) report_mismatch("model hit, cache went to AXI");
						end
						else if (ar_since != 1) begin
							report_mismatch("model miss, cache did not refill once");
						end
						if (cacheable(fetch_pc) && ar_since == 0) begin
							lookup_result = reference_lookup(fetch_pc);
							if (lookup_result == 2'd1) reference_lru[index_of(fetch_pc)] = 1'b1;
							else if (lookup_result == 2'd2) reference_lru[index_of(fetch_pc)] = 1'b0;
							if (predicted_hit) hit_count = hit_count + 1;
						end
					end
					saved_rdata = cpu_rdata;
					checked = 1'b1;
					completed_count = completed_count + 1;
				end
				else if (cpu_rdata !== saved_rdata) begin
					report_mismatch("output changed while the fetch was held");
				end
			end

			// watchdog
			if (issued && !checked) wait_cycles = wait_cycles + 1;
			else wait_cycles = 0;
			if (wait_cycles > 20000) begin
				$display("[FAIL] fetch of %h never finished (state=%0d)", fetch_pc, instruction_cache.state);
				$fatal(1, "InstructionCache_tb: hang");
			end

			// ---------------- next fetch ----------------
			if (fetch_advance) begin
				fetch_pc <= lookup_address;
				issued <= 1'b1;
				stream_pos <= stream_pos + 1;
				lookup_result = reference_lookup(lookup_address);
				predicted_hit = cacheable(lookup_address) && (lookup_result != 2'd0);
				ar_at_issue = ar_count;
				fence_at_issue = fence_done_count;
				checked = 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------------
	// clk_enable / stall stimulus (changed between edges)
	// ------------------------------------------------------------------------
	integer clk_enable_rate; // 1 of clk_enable_rate cycles has clk_enable = 0, 0 = always 1
	integer stall_rate;

	always @(negedge clk) begin
		clk_enable = (clk_enable_rate == 0) ? 1'b1 : (random_below(clk_enable_rate) != 0);
		stall = (stall_rate == 0) ? 1'b0 : (random_below(stall_rate) == 0);
	end

	// ------------------------------------------------------------------------
	// Test helpers
	// ------------------------------------------------------------------------
	integer pass_count;
	integer fail_count;

	task check;
		input condition;
		input [8*96-1:0] name;
		begin
			if (condition) begin
				pass_count = pass_count + 1;
				$display("  -> [PASS] %0s", name);
			end
			else begin
				fail_count = fail_count + 1;
				$display("  -> [FAIL] %0s", name);
			end
		end
	endtask

	task check_no_mismatch;
		input [8*96-1:0] name;
		input integer before;
		begin
			if (error_count == before) begin
				pass_count = pass_count + 1;
				$display("  -> [PASS] %0s", name);
			end
			else begin
				fail_count = fail_count + 1;
				$display("  -> [FAIL] %0s (%0d mismatches)", name, error_count - before);
			end
		end
	endtask

	task fill_memory;
		input [31:0] seed;
		integer w;
		reg [31:0] address;
		begin
			for (w = 0; w < DDR_WORDS; w = w + 1) begin
				address = 32'h8000_0000 + w * 8;
				memory[w] = {(address + 32'd4) ^ seed, address ^ seed};
				dummy_ddr_memory.memory[w] = memory[w];
			end
		end
	endtask

	task set_memory_word;
		input [31:0] address;
		input [31:0] value;
		integer w;
		begin
			w = (address >> 3) & (DDR_WORDS-1);
			if (address[2]) memory[w][63:32] = value;
			else memory[w][31:0] = value;
			dummy_ddr_memory.memory[w] = memory[w];
		end
	endtask

	// run the fetches stream[0 .. count-1] and wait until the last one is answered
	task run_stream;
		input integer count;
		integer guard;
		begin
			@(negedge clk);
			stream_pos = 0;
			stream_len = count;
			guard = 0;
			while (!(stream_pos == stream_len && issued && checked && !fence_req) && guard < 4000000) begin
				@(negedge clk);
				guard = guard + 1;
			end
			if (guard >= 4000000) begin
				$display("[FAIL] stream did not finish");
				$fatal(1, "InstructionCache_tb: stream timeout");
			end
		end
	endtask

	task wait_stream_done;
		begin
			while (!(stream_pos == stream_len && issued && checked && !fence_req)) @(negedge clk);
		end
	endtask

	task do_reset;
		begin
			@(negedge clk);
			reset = 1'b1;
			stream_len = 0;
			stream_pos = 0;
			repeat (3) @(negedge clk);
			reset = 1'b0;
			reference_reset;
		end
	endtask

	task clear_perf;
		begin
			@(negedge clk);
			perf_clear = 1'b1;
			@(negedge clk);
			while (!clk_enable) @(negedge clk);
			perf_clear = 1'b0;
		end
	endtask

	task check_perf;
		input [8*48-1:0] name;
		begin
			check(perf_access == access_expected && perf_miss == miss_expected && perf_stall == stall_expected,
				name);
			if (!(perf_access == access_expected && perf_miss == miss_expected && perf_stall == stall_expected))
				$display("     access %0d/%0d miss %0d/%0d stall %0d/%0d (cache/expected)",
					perf_access, access_expected, perf_miss, miss_expected, perf_stall, stall_expected);
		end
	endtask

	task set_quiet;
		begin
			clk_enable_rate = 0;
			stall_rate = 0;
			fence_rate = 0;
			error_rate = 0;
			latency_max = 1;
			use_dummy = 1'b0;
			slave_gated = 1'b0;
		end
	endtask

	// address in the DDR window : tag 0 .. 3 (so sets see conflicts), any set, any word
	function [31:0] random_address;
		input dummy_errors;
		begin
			random_address = 32'h8000_0000 + random_below(4) * WAY_BYTES + ($unsigned($random) % NUM_SETS) * 32
				+ random_below(8) * 4;
			if (dummy_errors && random_below(64) == 0)
				random_address = DUMMY_ERROR_ADDRESS + ($unsigned($random) % 1024) * 4;
			else if (random_below(128) == 0)
				random_address = $unsigned($random) % 32'h0002_0000 & 32'hFFFF_FFFC; // not cacheable : bypass
		end
	endfunction

	task random_phase;
		input [8*128-1:0] name;
		input dummy;
		input gated;
		input integer ce_rate;
		input integer errors;
		input integer fences;
		integer n;
		integer before;
		integer hits_before;
		integer refills_before;
		integer fences_before;
		begin
			$display("\n[RANDOM] %0s", name);
			set_quiet;
			use_dummy = dummy;
			slave_gated = gated;
			latency_max = 6;
			do_reset;
			clear_perf;
			stream[0] = random_address(dummy);
			for (n = 1; n < RANDOM_FETCHES; n = n + 1) begin
				if (random_below(4) != 0 && stream[n-1][31:29] == 3'b100)
					stream[n] = 32'h8000_0000 + ((stream[n-1] + 4) & 32'h0001_FFFC); // straight-line code
				else
					stream[n] = random_address(dummy);
			end
			before = error_count;
			hits_before = hit_count;
			refills_before = refill_count;
			fences_before = fence_done_count;
			mismatch_print = 0;
			check_messages = 1'b0;
			clk_enable_rate = ce_rate;
			stall_rate = 4;
			error_rate = errors;
			fence_rate = fences;
			run_stream(RANDOM_FETCHES);
			fence_rate = 0;
			clk_enable_rate = 0;
			stall_rate = 0;
			repeat (4) @(negedge clk);
			$display("     %0d fetches, %0d hits, %0d refills, %0d FENCE.I", RANDOM_FETCHES,
				hit_count - hits_before, refill_count - refills_before, fence_done_count - fences_before);
			check_no_mismatch("every fetch matches memory and the reference model", before);
			check_perf("perf counters");
			check_messages = 1'b1;
		end
	endtask

	// ------------------------------------------------------------------------
	// Tests
	// ------------------------------------------------------------------------
	integer before;
	integer ar_before;
	integer refill_before;
	integer t_start;
	integer t_end;
	integer busy_seen;
	integer k;
	integer fence_cycles;
	reg [31:0] base;

	initial begin
		pass_count = 0;
		fail_count = 0;
		error_count = 0;
		ar_count = 0;
		refill_count = 0;
		burst_done_count = 0;
		fence_done_count = 0;
		fence_gap = 0;
		completed_count = 0;
		hit_count = 0;
		wait_cycles = 0;
		access_expected = 0;
		miss_expected = 0;
		stall_expected = 0;
		cycle_count = 0;
		check_messages = 1'b1;
		mismatch_print = 0;
		force_error_mode = 2'd0;
		force_error_beat = 2'd0;
		perf_clear = 1'b0;
		fetch_pc = 32'h0;
		stream_len = 0;
		stream_pos = 0;
		reset = 1'b1;
		set_quiet;
		clk_enable = 1'b1;
		stall = 1'b0;
		fill_memory(32'h0);
		reference_reset;
		repeat (3) @(negedge clk);
		reset = 1'b0;

		$display("==================================================================");
		$display(" InstructionCache_tb  NUM_SETS=%0d  CACHE_EN=%0d", NUM_SETS, CACHE_EN);
		$display("==================================================================");

		// --------------------------------------------------------------------
		$display("\n[T-I01] one line : word offsets 0 .. 7");
		base = 32'h8000_0100;
		for (k = 0; k < 8; k = k + 1) stream[k] = base + k * 4;
		for (k = 0; k < 8; k = k + 1) stream[8 + k] = base + (7 - k) * 4;
		before = error_count;
		ar_before = ar_count;
		run_stream(16);
		check_no_mismatch("16 fetches return the memory word", before);
		if (CACHE_EN != 0) check(ar_count - ar_before == 1, "one refill, the other 15 fetches hit");
		else check(ar_count - ar_before == 16, "CACHE_EN=0 : every fetch is a single-beat AXI read");

		// --------------------------------------------------------------------
		if (CACHE_EN != 0) begin
			$display("\n[T-I02] hit throughput");
			for (k = 0; k < 64; k = k + 1) stream[k] = 32'h8000_0400 + k * 4;
			run_stream(64); // warm 8 lines
			for (k = 0; k < 65; k = k + 1) stream[k] = 32'h8000_0400 + (k % 64) * 4;
			before = error_count;
			ar_before = ar_count;
			busy_seen = 0;
			@(negedge clk);
			stream_pos = 0;
			stream_len = 65;
			t_start = cycle_count;
			while (stream_pos < 65) begin
				@(negedge clk);
				if (cpu_busy) busy_seen = busy_seen + 1;
			end
			t_end = cycle_count;
			wait_stream_done;
			$display("     64 fetches in %0d cycles (%0d.%02d clk/fetch)", t_end - t_start - 1,
				(t_end - t_start - 1) / 64, ((t_end - t_start - 1) % 64) * 100 / 64);
			check(t_end - t_start - 1 == 64, "hits only : 1.00 clk/fetch");
			check(busy_seen == 0 && ar_count == ar_before, "no cpu_busy and no AXI access on hits");
			check_no_mismatch("hit data", before);
		end

		// --------------------------------------------------------------------
		if (CACHE_EN != 0) begin
			$display("\n[T-I03] LRU and victim choice (A, B, C in one set)");
			do_reset;
			base = 32'h8000_0040;
			stream[0] = base; // A miss -> way 0 (invalid first)
			stream[1] = base + WAY_BYTES; // B miss -> way 1
			stream[2] = base; // A hit (B is LRU)
			stream[3] = base + 2 * WAY_BYTES; // C miss -> evicts B
			stream[4] = base; // A hit
			stream[5] = base + WAY_BYTES; // B miss -> evicts C
			stream[6] = base + 2 * WAY_BYTES; // C miss -> evicts A
			stream[7] = base + WAY_BYTES; // B hit
			stream[8] = base; // A miss
			before = error_count;
			ar_before = ar_count;
			run_stream(9);
			check_no_mismatch("every fetch follows the reference model (invalid way first, then LRU)", before);
			check(ar_count - ar_before == 6, "6 refills, 3 hits");
		end

		// --------------------------------------------------------------------
		$display("\n[T-I04 / T-I05] AXI attributes, random slave latency");
		$display("     (AR attributes, ARVALID hold, one burst at a time, RREADY gating are checked on every edge)");
		set_quiet;
		latency_max = 8;
		for (k = 0; k < 256; k = k + 1) stream[k] = 32'h8000_2000 + k * 4;
		before = error_count;
		run_stream(256);
		check_no_mismatch("256 sequential fetches with random AR / R wait", before);

		// --------------------------------------------------------------------
		$display("\n[T-I06] FENCE.I");
		set_quiet;
		do_reset;
		for (k = 0; k < 8; k = k + 1) stream[k] = 32'h8000_3000 + k * 4;
		stream[8] = 32'h8000_3040; // held at the output during the FENCE.I (refetched after it)
		run_stream(9);
		// idle cache : req -> done
		@(negedge clk);
		fence_req = 1'b1;
		fence_cycles = 0;
		busy_seen = 0;
		k = fence_done_count;
		while (fence_done_count == k) begin
			@(negedge clk);
			fence_cycles = fence_cycles + 1;
			if (fence_req && !cpu_busy) busy_seen = busy_seen + 1;
		end
		check(fence_cycles == NUM_SETS + 3, "req to done sampled : NUM_SETS + 2 cycles in the cache");
		$display("     %0d cycles from req to the edge that saw done", fence_cycles);
		check(busy_seen == 0, "cpu_busy stays 1 until req drops");
		// new memory contents are seen after the invalidation
		wait_stream_done; // the fetch held at the output is read again first
		set_memory_word(32'h8000_3008, 32'hCAFE_0001);
		stream[0] = 32'h8000_3008;
		before = error_count;
		ar_before = ar_count;
		run_stream(1);
		check(ar_count - ar_before == 1 && cpu_rdata == 32'hCAFE_0001,
			"after FENCE.I the line is read again and the new word is returned");
		check_no_mismatch("data after FENCE.I", before);
		// req raised while a refill is on the bus : the refill finishes first
		set_quiet;
		latency_max = 12;
		stream[0] = 32'h8000_3100;
		@(negedge clk);
		ar_before = ar_count;
		refill_before = burst_done_count;
		stream_pos = 0;
		stream_len = 1;
		while (ar_count == ar_before) @(negedge clk);
		fence_req = 1'b1;
		k = fence_done_count;
		before = error_count;
		wait_stream_done;
		check(fence_done_count == k + 1, "one done for a req raised during a refill");
		check(ar_count - ar_before == ((CACHE_EN != 0) ? 2 : 1),
			CACHE_EN != 0 ? "refill finished, line invalidated, fetched again" : "bypass finished before the FENCE.I");
		check_no_mismatch("fetch around FENCE.I", before);
		// back-to-back requests (req low for one cycle between them)
		k = fence_done_count;
		for (ar_before = 0; ar_before < 3; ar_before = ar_before + 1) begin
			@(negedge clk);
			fence_req = 1'b1;
			while (fence_req) @(negedge clk);
		end
		check(fence_done_count == k + 3, "3 requests with 1 low cycle between them -> 3 done pulses");

		// --------------------------------------------------------------------
		$display("\n[T-I07] NUM_SETS=%0d : index [%0d:5], tag [31:%0d], way size %0d bytes",
			NUM_SETS, 4 + INDEX_BITS, 5 + INDEX_BITS, WAY_BYTES);
		if (CACHE_EN != 0) begin
			set_quiet;
			do_reset;
			// same index, different tags -> one set; next index -> another set
			stream[0] = 32'h8000_0000;
			stream[1] = 32'h8000_0000 + WAY_BYTES;
			stream[2] = 32'h8000_0000 + 32;
			stream[3] = 32'h8000_0000;
			stream[4] = 32'h8000_0000 + WAY_BYTES;
			stream[5] = 32'h8000_0000 + 32;
			before = error_count;
			ar_before = ar_count;
			run_stream(6);
			check(ar_count - ar_before == 3, "addresses WAY_BYTES apart share a set, the next line does not");
			check_no_mismatch("index / tag split", before);
		end

		// --------------------------------------------------------------------
		$display("\n[T-I08] not cacheable : single-beat bypass, never allocated");
		set_quiet;
		stream[0] = 32'h0000_1234 & 32'hFFFF_FFFC;
		stream[1] = 32'h0000_1234 & 32'hFFFF_FFFC;
		stream[2] = 32'h0000_1238;
		before = error_count;
		ar_before = ar_count;
		run_stream(3);
		check(ar_count - ar_before == 3, "3 fetches outside the cacheable region -> 3 AXI reads");
		check_no_mismatch("bypass data (ARLEN = 0, 8-byte aligned)", before);

		// --------------------------------------------------------------------
		$display("\n[T-I09] AXI response ignored : SLVERR / missing RLAST, data and line kept");
		set_quiet;
		do_reset;
		before = error_count;
		// SLVERR on beat 2 of a refill (CACHE_EN=0 : on the single beat of a bypass read)
		force_error_mode = 2'd1;
		force_error_beat = (CACHE_EN != 0) ? 2'd2 : 2'd0;
		stream[0] = 32'h8000_4004;
		ar_before = ar_count;
		run_stream(1);
		check(cpu_rdata === memory_word(32'h8000_4004),
			CACHE_EN != 0 ? "SLVERR on a refill beat : fetch returns the memory word" : "CACHE_EN=0 : SLVERR on a bypass read, fetch returns the memory word");
		stream[0] = 32'h8000_4004;
		stream[1] = 32'h8000_4010; // beat 2 of the same line
		ar_before = ar_count;
		run_stream(2);
		check(ar_count - ar_before == (CACHE_EN != 0 ? 0 : 2),
			CACHE_EN != 0 ? "the line is kept : same line again hits with no AXI access" : "CACHE_EN=0 : each fetch is a bypass read");
		// RLAST never asserted
		force_error_mode = 2'd2;
		force_error_beat = 2'd0;
		stream[0] = 32'h8000_4200;
		ar_before = ar_count;
		run_stream(1);
		check(cpu_rdata === memory_word(32'h8000_4200) && ar_count - ar_before == 1,
			CACHE_EN != 0 ? "RLAST missing : the refill ends on the 4th beat" : "RLAST missing : the bypass read ends on its beat");
		stream[0] = 32'h8000_421C; // last word of the same line
		ar_before = ar_count;
		run_stream(1);
		check(ar_count - ar_before == (CACHE_EN != 0 ? 0 : 1),
			CACHE_EN != 0 ? "the line is kept : last word of it hits" : "CACHE_EN=0 : bypass read again");
		// SLVERR on a bypass read (not cacheable)
		force_error_mode = 2'd1;
		force_error_beat = 2'd0;
		stream[0] = 32'h0000_1244;
		ar_before = ar_count;
		run_stream(1);
		check(cpu_rdata === memory_word(32'h0000_1244) && ar_count - ar_before == 1,
			"SLVERR on a bypass read : the data is passed on");
		check_no_mismatch("every fetch matches memory and the reference model", before);

		// --------------------------------------------------------------------
		$display("\n[T-I10] reset during a refill, clk_enable toggling");
		set_quiet;
		latency_max = 4;
		stream[0] = 32'h8000_5000;
		run_stream(1);
		stream[0] = 32'h8000_5040;
		@(negedge clk);
		k = burst_done_count;
		ar_before = ar_count;
		stream_pos = 0;
		stream_len = 1;
		while (!(burst_open && burst_beats >= 1) && burst_done_count == k) @(negedge clk);
		reset = 1'b1;
		stream_len = 0;
		stream_pos = 0;
		repeat (2) @(negedge clk);
		check(cpu_rdata === NOP && cpu_busy === 1'b0, "during reset : cpu_rdata = NOP, cpu_busy = 0");
		reset = 1'b0;
		reference_reset;
		@(negedge clk);
		check(cpu_rdata === NOP && cpu_busy === 1'b0 && m_axi_arvalid === 1'b0, "after reset : no request, NOP, idle bus");
		stream[0] = 32'h8000_5000;
		stream[1] = 32'h8000_5040;
		before = error_count;
		ar_before = ar_count;
		run_stream(2);
		check(ar_count - ar_before == 2, "every line is invalid after reset (both fetches miss)");
		check_no_mismatch("fetches after reset", before);
		// clk_enable toggling with a slave that ignores clk_enable and one that follows it
		for (k = 0; k < 2; k = k + 1) begin
			set_quiet;
			slave_gated = k;
			latency_max = 6;
			clk_enable_rate = 2;
			for (t_start = 0; t_start < 512; t_start = t_start + 1) stream[t_start] = random_address(1'b0);
			before = error_count;
			run_stream(512);
			clk_enable_rate = 0;
			check_no_mismatch(k ? "clk_enable 50% off, slave gated by clk_enable" : "clk_enable 50% off, slave not gated (AR taken on any edge)", before);
		end

		// --------------------------------------------------------------------
		$display("\n[T-I12] performance counters");
		set_quiet;
		do_reset;
		clear_perf;
		stall_rate = 3;
		for (k = 0; k < 300; k = k + 1) stream[k] = 32'h8000_6000 + (k % 100) * 4;
		run_stream(300);
		stall_rate = 0;
		repeat (2) @(negedge clk);
		check_perf("access / miss / stall after 300 fetches");
		if (CACHE_EN != 0) check(perf_access != 0 && perf_miss == 13, "counters are counting (13 lines for 100 words)");
		else check(perf_access == 0 && perf_miss == 0, "CACHE_EN=0 : bypass fetches are not counted as access / miss");
		$display("     access=%0d miss=%0d stall=%0d", perf_access, perf_miss, perf_stall);
		clear_perf;
		check(perf_access == 0 && perf_miss == 0 && perf_stall == 0, "perf_clear zeroes all counters");

		// --------------------------------------------------------------------
		random_phase("T-I11 testbench slave, gated, clk_enable 25% off, SLVERR / RLAST missing injected (ignored), FENCE.I", 1'b0, 1'b1, 4, 16, 500);
		random_phase("T-I11 testbench slave, not gated, clk_enable 25% off, SLVERR / RLAST missing injected (ignored)", 1'b0, 1'b0, 4, 16, 1000);
		random_phase("T-I11 testbench slave, clk_enable on, no injection, FENCE.I", 1'b0, 1'b0, 0, 0, 2000);
		random_phase("T-I11 DummyDDRMemory, SLVERR window (ignored), clk_enable 25% off", 1'b1, 1'b0, 4, 0, 1000);

		$display("\n==================================================================");
		$display(" fetches checked: %0d, protocol / data / model mismatches: %0d", completed_count, error_count);
		$display(" PASS: %0d", pass_count);
		$display(" FAIL: %0d", fail_count);
		$display("==================================================================");
		if (fail_count != 0 || error_count != 0) $fatal(1, "InstructionCache_tb: %0d failure(s)", fail_count);
		$finish;
	end

endmodule
