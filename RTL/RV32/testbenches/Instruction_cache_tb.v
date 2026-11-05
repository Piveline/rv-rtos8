`timescale 1ns / 1ps

module InstructionCache_tb;

	reg clk;
	reg reset;
	reg clk_enable;

	always #5 clk = ~clk;

	reg cpu_req_valid;
	reg [31:0] cpu_req_addr;
	reg cpu_flush;
	wire [31:0] cpu_rdata;
	wire cpu_ready;
	reg fence_i_req;
	wire fence_i_done;

	wire [31:0] m_axi_araddr;
	wire [7:0] m_axi_arlen;
	wire [2:0] m_axi_arsize;
	wire [1:0] m_axi_arburst;
	wire m_axi_arvalid;
	reg m_axi_arready;

	reg [63:0] m_axi_rdata;
	reg m_axi_rlast;
	reg m_axi_rvalid;
	wire m_axi_rready;

	integer test_pass_count;
	integer test_fail_count;
	reg [31:0] resp_data;
	integer timeout;
	integer base_done;
	integer base_done_hi;
	integer issue_pass [1:5];
	integer issue_fail [1:5];
	integer idx;

	InstructionCache instruction_cache (
		.clk(clk),
		.reset(reset),
		.clk_enable(clk_enable),
		.cpu_req_valid(cpu_req_valid),
		.cpu_req_addr(cpu_req_addr),
		.cpu_flush(cpu_flush),
		.cpu_rdata(cpu_rdata),
		.cpu_ready(cpu_ready),
		.fence_i_req(fence_i_req),
		.fence_i_done(fence_i_done),
		.m_axi_araddr(m_axi_araddr),
		.m_axi_arlen(m_axi_arlen),
		.m_axi_arsize(m_axi_arsize),
		.m_axi_arburst(m_axi_arburst),
		.m_axi_arvalid(m_axi_arvalid),
		.m_axi_arready(m_axi_arready),
		.m_axi_rdata(m_axi_rdata),
		.m_axi_rlast(m_axi_rlast),
		.m_axi_rvalid(m_axi_rvalid),
		.m_axi_rready(m_axi_rready)
	);

	// External AXI Transaction Monitor (No InstructionCache internal access)
	reg axi_ar_handshake_seen;
	reg [31:0] axi_last_araddr;
	reg [7:0] axi_last_arlen;

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			axi_ar_handshake_seen <= 1'b0;
			axi_last_araddr <= 32'h0;
			axi_last_arlen <= 8'h0;
		end else begin
			if (m_axi_arvalid && m_axi_arready) begin
				axi_ar_handshake_seen <= 1'b1;
				axi_last_araddr <= m_axi_araddr;
				axi_last_arlen <= m_axi_arlen;
			end
		end
	end

	task clear_axi_monitor;
		begin
			axi_ar_handshake_seen = 1'b0;
			axi_last_araddr = 32'h0;
			axi_last_arlen = 8'h0;
		end
	endtask

	// External FENCE.I Done Monitor (No InstructionCache internal access)
	integer fence_done_cnt;
	integer fence_done_hi_cnt;
	reg fence_done_d;

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			fence_done_cnt <= 0;
			fence_done_hi_cnt <= 0;
			fence_done_d <= 1'b0;
		end else begin
			fence_done_d <= fence_i_done;
			if (fence_i_done) begin
				fence_done_hi_cnt <= fence_done_hi_cnt + 1;
				if (!fence_done_d) fence_done_cnt <= fence_done_cnt + 1;
			end
		end
	end

	// TB AXI Slave Model
	// axi_stress = 0 : original fixed-latency slave (ARREADY 1 cycle, RVALID back-to-back)
	// axi_stress = 1 : random ARREADY delay (0..3 cycles) and random RVALID gaps inside a burst
	reg axi_stress;
	reg [31:0] latched_araddr;
	reg [7:0] latched_arlen;
	reg axi_read_active;
	integer axi_beat_cnt;
	reg [2:0] r_delay_cnt;
	reg [2:0] ar_wait;
	reg [2:0] ar_target;
	reg beat_pending;
	reg [1:0] gap_cnt;
	integer rnd_ar;
	integer rnd_r;

	initial begin
		m_axi_arready = 1'b0;
		m_axi_rvalid = 1'b0;
		m_axi_rlast = 1'b0;
		m_axi_rdata = 64'h0;
		axi_read_active = 1'b0;
		axi_beat_cnt = 0;
		r_delay_cnt = 0;
		axi_stress = 1'b0;
		ar_wait = 0;
		ar_target = 0;
		beat_pending = 1'b0;
		gap_cnt = 0;
		rnd_ar = 32'h1234_5678;
		rnd_r = 32'h0BAD_CAFE;
	end

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			m_axi_arready <= 1'b0;
			axi_read_active <= 1'b0;
			ar_wait <= 0;
			ar_target <= 0;
		end else begin
			if (m_axi_arvalid && !m_axi_arready && !axi_read_active) begin
				if (axi_stress && (ar_wait < ar_target)) begin
					ar_wait <= ar_wait + 1;
					m_axi_arready <= 1'b0;
				end else begin
					m_axi_arready <= 1'b1;
					latched_araddr <= m_axi_araddr;
					latched_arlen <= m_axi_arlen;
					axi_read_active <= 1'b1;
					ar_wait <= 0;
					ar_target <= axi_stress ? ($random(rnd_ar) & 3) : 0;
				end
			end else begin
				m_axi_arready <= 1'b0;
			end
			if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
				axi_read_active <= 1'b0;
			end
		end
	end

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			m_axi_rvalid <= 1'b0;
			m_axi_rlast <= 1'b0;
			r_delay_cnt <= 0;
			axi_beat_cnt <= 0;
			beat_pending <= 1'b0;
			gap_cnt <= 0;
		end else begin
			if (beat_pending) begin
				// RVALID gap inside a burst (stress mode only)
				if (gap_cnt > 1) begin
					gap_cnt <= gap_cnt - 1;
				end else begin
					beat_pending <= 1'b0;
					m_axi_rvalid <= 1'b1;
					m_axi_rdata <= generate_mock_mem_data(latched_araddr, axi_beat_cnt);
					m_axi_rlast <= (axi_beat_cnt == latched_arlen);
				end
			end else if (axi_read_active && !m_axi_rvalid) begin
				if (r_delay_cnt < 2) begin
					r_delay_cnt <= r_delay_cnt + 1;
				end else begin
					axi_beat_cnt <= 0;
					m_axi_rvalid <= 1'b1;
					m_axi_rdata <= generate_mock_mem_data(latched_araddr, 0);
					m_axi_rlast <= (latched_arlen == 8'd0);
				end
			end else if (m_axi_rvalid && m_axi_rready) begin
				if (axi_beat_cnt < latched_arlen) begin
					axi_beat_cnt <= axi_beat_cnt + 1;
					if (axi_stress && ($random(rnd_r) & 1)) begin
						m_axi_rvalid <= 1'b0;
						m_axi_rlast <= 1'b0;
						beat_pending <= 1'b1;
						gap_cnt <= 1 + ($random(rnd_r) & 1);
					end else begin
						m_axi_rdata <= generate_mock_mem_data(latched_araddr, axi_beat_cnt + 1);
						m_axi_rlast <= (axi_beat_cnt + 1 == latched_arlen);
					end
				end else begin
					m_axi_rvalid <= 1'b0;
					m_axi_rlast <= 1'b0;
					r_delay_cnt <= 0;
				end
			end
		end
	end

	function [63:0] generate_mock_mem_data(input [31:0] base_addr, input integer beat);
		reg [31:0] word0, word1;
		begin
			word0 = base_addr + (beat * 8) + 32'h0000_1000;
			word1 = base_addr + (beat * 8) + 4 + 32'h0000_1000;
			generate_mock_mem_data = {word1, word0};
		end
	endfunction

	// Robust CPU Request-Response Handshake Task
	task execute_req;
		input [31:0] addr;
		output [31:0] rdata;
		integer tout;
		begin
			// 1. Clear request and wait for cpu_ready to be 0
			cpu_req_valid = 1'b0;
			tout = 0;
			while (cpu_ready && tout < 100) begin
				@(negedge clk);
				tout = tout + 1;
			end

			// 2. Drive new request at negedge
			@(negedge clk);
			cpu_req_valid = 1'b1;
			cpu_req_addr = addr;

			// 3. Wait for cpu_ready pulse
			tout = 0;
			while (!cpu_ready && tout < 500) begin
				@(negedge clk);
				tout = tout + 1;
			end

			if (tout >= 500) begin
				$display("[FAIL-TIMEOUT] cpu_ready never asserted for addr 0x%h", addr);
				test_fail_count = test_fail_count + 1;
				rdata = 32'hDEAD_BEEF;
			end else begin
				// 4. Sample data at the exact cycle cpu_ready is high
				rdata = cpu_rdata;
			end

			// 5. Deassert cpu_req_valid IMMEDIATELY in the same negedge cycle
			cpu_req_valid = 1'b0;
			cpu_req_addr = 32'h0;

			// 6. Verify 1-cycle pulse duration on next cycle
			@(negedge clk);
			if (cpu_ready !== 1'b0) begin
				$display("[FAIL-PROTOCOL] cpu_ready remained high for >1 cycle after addr 0x%h", addr);
				test_fail_count = test_fail_count + 1;
			end
		end
	endtask

	// NOTE: msg is a Verilog string packed into a vector. 8 bits per character, so a
	// [255:0] vector keeps only the LAST 32 characters and silently drops the head of
	// longer strings (this is what produced "[PASS] che Miss & Refill ...").
	// 1024 bits = 128 characters.
	task assert_test(input condition, input [1023:0] msg);
		begin
			if (condition === 1'b1) begin // X/Z counts as FAIL
				$display("  -> [PASS] %0s", msg);
				test_pass_count = test_pass_count + 1;
			end else begin
				$display("  -> [FAIL] %0s", msg);
				test_fail_count = test_fail_count + 1;
			end
		end
	endtask

	task wait_cycles;
		input integer n;
		integer k;
		begin
			for (k = 0; k < n; k = k + 1) @(negedge clk);
		end
	endtask

	task wait_fence_done;
		input integer base_cnt;
		input integer max_cycles;
		integer k;
		begin
			k = 0;
			while ((fence_done_cnt <= base_cnt) && (k < max_cycles)) begin
				@(negedge clk);
				k = k + 1;
			end
		end
	endtask

	// CPU Request with a cpu_flush window
	// flush is high for flush_len cycles, starting flush_delay cycles after the request is driven
	// The window is completed even after the response (flush held into IDLE)
	task execute_req_flush;
		input [31:0] addr;
		input integer flush_delay;
		input integer flush_len;
		output [31:0] rdata;
		integer c;
		reg got_resp;
		begin
			cpu_req_valid = 1'b0;
			c = 0;
			while (cpu_ready && c < 100) begin
				@(negedge clk);
				c = c + 1;
			end

			@(negedge clk);
			cpu_req_valid = 1'b1;
			cpu_req_addr = addr;
			rdata = 32'hDEAD_BEEF;
			got_resp = 1'b0;
			c = 0;

			while ((!got_resp || (c < flush_delay + flush_len)) && c < 500) begin
				cpu_flush = (c >= flush_delay) && (c < flush_delay + flush_len);
				if (!got_resp && cpu_ready) begin
					got_resp = 1'b1;
					rdata = cpu_rdata;
					cpu_req_valid = 1'b0;
					cpu_req_addr = 32'h0;
				end
				@(negedge clk);
				c = c + 1;
			end
			cpu_flush = 1'b0;

			if (!got_resp) begin
				$display("[FAIL-TIMEOUT] cpu_ready never asserted for addr 0x%h", addr);
				test_fail_count = test_fail_count + 1;
				cpu_req_valid = 1'b0;
			end

			@(negedge clk);
		end
	endtask

	// CPU Request with a 1-cycle cpu_flush or fence_i_req pulse injected in a chosen FSM phase.
	// The phase is detected only from external signals (no internal access):
	//   PH_LOOKUP   : first cycle after the request is accepted (miss -> LOOKUP state)
	//   PH_ADDR     : m_axi_arvalid is high (ALLOC_AR / BYPASS_AR)
	//   PH_DATA_MID : a non-last R beat is being accepted (ALLOC_R, before rlast)
	localparam PH_LOOKUP = 0;
	localparam PH_ADDR = 1;
	localparam PH_DATA_MID = 2;

	task execute_req_inject;
		input [31:0] addr;
		input integer phase;
		input inject_fence; // 0: cpu_flush pulse, 1: fence_i_req pulse
		output [31:0] rdata;
		output injected;
		integer c;
		reg got_resp;
		reg hit_phase;
		begin
			cpu_req_valid = 1'b0;
			c = 0;
			while (cpu_ready && c < 100) begin
				@(negedge clk);
				c = c + 1;
			end

			@(negedge clk);
			cpu_req_valid = 1'b1;
			cpu_req_addr = addr;
			rdata = 32'hDEAD_BEEF;
			got_resp = 1'b0;
			injected = 1'b0;
			c = 0;

			while (!got_resp && c < 500) begin
				@(negedge clk);
				c = c + 1;
				// pulses last exactly one cycle
				cpu_flush = 1'b0;
				fence_i_req = 1'b0;

				if (cpu_ready === 1'b1) begin
					got_resp = 1'b1;
					rdata = cpu_rdata;
					cpu_req_valid = 1'b0;
					cpu_req_addr = 32'h0;
				end else if (!injected) begin
					case (phase)
						PH_LOOKUP: hit_phase = (c == 1);
						PH_ADDR: hit_phase = (m_axi_arvalid === 1'b1);
						PH_DATA_MID: hit_phase = (m_axi_rvalid === 1'b1) && (m_axi_rready === 1'b1) && (m_axi_rlast === 1'b0);
						default: hit_phase = 1'b0;
					endcase
					if (hit_phase) begin
						if (inject_fence) fence_i_req = 1'b1;
						else cpu_flush = 1'b1;
						injected = 1'b1;
					end
				end
			end
			cpu_flush = 1'b0;
			fence_i_req = 1'b0;

			if (!got_resp) begin
				$display("[FAIL-TIMEOUT] cpu_ready never asserted for addr 0x%h", addr);
				test_fail_count = test_fail_count + 1;
				cpu_req_valid = 1'b0;
			end

			@(negedge clk);
		end
	endtask

	// Flush pulse in a given phase of a cacheable miss:
	// response must be NOP, the line must still be allocated, the next miss must not be squashed
	task check_flush_in_phase;
		input [31:0] addr;
		input [31:0] next_addr;
		input integer phase;
		input [1023:0] tag;
		reg [31:0] d;
		reg inj;
		begin
			clear_axi_monitor();
			execute_req_inject(addr, phase, 1'b0, d, inj);
			assert_test(inj && axi_ar_handshake_seen && (d === 32'h0000_0013), tag);
			check_cached(addr, 1'b1, "  ...squashed refill still allocated the line (HIT)");
			check_cached(next_addr, 1'b0, "  ...next miss is not squashed (flush consumed)");
		end
	endtask

	// FENCE.I pulse in a given phase of a cacheable miss:
	// response must be intact, exactly one done pulse must follow, the line must re-miss
	task check_fence_in_phase;
		input [31:0] addr;
		input integer phase;
		input [1023:0] tag;
		reg [31:0] d;
		reg inj;
		integer base;
		begin
			base = fence_done_cnt;
			clear_axi_monitor();
			execute_req_inject(addr, phase, 1'b1, d, inj);
			assert_test(inj && axi_ar_handshake_seen && (d === addr + 32'h0000_1000), tag);
			wait_fence_done(base, 1000);
			assert_test(fence_done_cnt == base + 1, "  ...pending FENCE.I is not lost (done)");
			wait_cycles(700);
			assert_test(fence_done_cnt == base + 1, "  ...no extra done");
			check_cached(addr, 1'b0, "  ...line invalidated by the pending FENCE.I (re-miss)");
		end
	endtask

	// Assertion tagged with the reported issue number (1..5)
	task assert_issue;
		input integer id;
		input condition;
		input [1023:0] msg;
		begin
			if (condition === 1'b1) begin // X/Z counts as FAIL
				$display("  -> [PASS][ISSUE %0d] %0s", id, msg);
				test_pass_count = test_pass_count + 1;
				issue_pass[id] = issue_pass[id] + 1;
			end else begin
				$display("  -> [FAIL][ISSUE %0d] %0s", id, msg);
				test_fail_count = test_fail_count + 1;
				issue_fail[id] = issue_fail[id] + 1;
			end
		end
	endtask


	// ============================================================
	// Helpers added for the coverage extension (TEST 15 ~ 22)
	// ============================================================

	// Cacheable access with hit/miss expectation. Data is always addr + 0x1000 (mock memory).
	task check_cached;
		input [31:0] addr;
		input exp_hit;
		input [1023:0] msg;
		reg [31:0] d;
		begin
			clear_axi_monitor();
			execute_req(addr, d);
			if (exp_hit)
				assert_test(!axi_ar_handshake_seen && (d == addr + 32'h0000_1000), msg);
			else
				assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd3) &&
					(axi_last_araddr == {addr[31:5], 5'b00000}) && (d == addr + 32'h0000_1000), msg);
		end
	endtask

	// Same check, but only counts failures (used inside loops, aggregated by the caller)
	task check_cached_quiet;
		input [31:0] addr;
		input exp_hit;
		inout integer fails;
		reg [31:0] d;
		reg ok;
		begin
			clear_axi_monitor();
			execute_req(addr, d);
			if (exp_hit)
				ok = !axi_ar_handshake_seen && (d == addr + 32'h0000_1000);
			else
				ok = axi_ar_handshake_seen && (axi_last_arlen == 8'd3) &&
					(axi_last_araddr == {addr[31:5], 5'b00000}) && (d == addr + 32'h0000_1000);
			if (ok !== 1'b1) begin // X/Z counts as mismatch
				fails = fails + 1;
				$display("     [detail] addr=0x%h exp_%0s: ar_seen=%0d arlen=%0d araddr=0x%h data=0x%h",
					addr, exp_hit ? "HIT " : "MISS", axi_ar_handshake_seen, axi_last_arlen, axi_last_araddr, d);
			end
		end
	endtask

	// Non-cacheable (bypass) access: single 8-byte beat, 8-byte aligned ARADDR, correct word picked
	task check_bypass;
		input [31:0] addr;
		input [1023:0] msg;
		reg [31:0] d;
		begin
			clear_axi_monitor();
			execute_req(addr, d);
			assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd0) &&
				(axi_last_araddr == {addr[31:3], 3'b000}) && (d == addr + 32'h0000_1000), msg);
		end
	endtask

	// FENCE.I with req held until done (protocol used by the SoC)
	task do_fence;
		integer base, k;
		begin
			base = fence_done_cnt;
			@(negedge clk);
			fence_i_req = 1'b1;
			k = 0;
			while ((fence_done_cnt <= base) && (k < 2000)) begin
				@(negedge clk);
				k = k + 1;
			end
			fence_i_req = 1'b0;
			if (k >= 2000) begin
				$display("[FAIL-TIMEOUT] fence_i_done never asserted");
				test_fail_count = test_fail_count + 1;
			end
			@(negedge clk);
			@(negedge clk);
		end
	endtask

	// Behavioral reference model (valid / tag / true-LRU per set)
	reg m_v0 [0:511];
	reg m_v1 [0:511];
	reg [17:0] m_t0 [0:511];
	reg [17:0] m_t1 [0:511];
	reg m_lru [0:511];
	integer m_i;

	task model_clear;
		begin
			for (m_i = 0; m_i < 512; m_i = m_i + 1) begin
				m_v0[m_i] = 1'b0;
				m_v1[m_i] = 1'b0;
				m_lru[m_i] = 1'b0;
			end
		end
	endtask

	// Random scoreboard: compares InstructionCache against the reference model (hit/miss, data, AXI attributes)
	integer sb_req, sb_hit, sb_miss, sb_byp, sb_fence, sb_mism;

	task rand_scoreboard;
		input integer n;
		input integer seed_in;
		integer i, seed, kind, sel;
		reg [8:0] idx;
		reg [14:0] tg;
		reg [2:0] wd;
		reg [17:0] full_tag;
		reg [31:0] addr, d, rnd;
		reg exp_hit, hit0, hit1, way, ok;
		reg [8:0] set_pool [0:5];
		reg [14:0] tag_pool [0:4];
		begin
			seed = seed_in;
			sb_req = 0; sb_hit = 0; sb_miss = 0; sb_byp = 0; sb_fence = 0; sb_mism = 0;

			// small pools -> frequent conflicts, both low and high index / tag bits are exercised
			set_pool[0] = 9'd0; set_pool[1] = 9'd1; set_pool[2] = 9'd17;
			set_pool[3] = 9'd255; set_pool[4] = 9'd256; set_pool[5] = 9'd511;
			tag_pool[0] = 15'h0000; tag_pool[1] = 15'h0001; tag_pool[2] = 15'h0002;
			tag_pool[3] = 15'h4000; tag_pool[4] = 15'h2AAA;

			do_fence;
			model_clear;

			for (i = 0; i < n; i = i + 1) begin
				rnd = $random(seed);
				kind = (rnd & 32'h7FFF_FFFF) % 100;

				if (kind < 3) begin
					do_fence;
					model_clear;
					sb_fence = sb_fence + 1;
				end else if (kind < 13) begin
					// non-cacheable
					rnd = $random(seed);
					addr = rnd & 32'hFFFF_FFFC;
					if (addr[31:29] == 3'b100) addr[31] = 1'b0;
					clear_axi_monitor();
					execute_req(addr, d);
					ok = axi_ar_handshake_seen && (axi_last_arlen == 8'd0) &&
						(axi_last_araddr == {addr[31:3], 3'b000}) && (d == addr + 32'h0000_1000);
					sb_byp = sb_byp + 1;
					sb_req = sb_req + 1;
					if (ok !== 1'b1) begin // X/Z counts as mismatch
						sb_mism = sb_mism + 1;
						if (sb_mism <= 5) $display("     [SB-MISMATCH] bypass addr=0x%h data=0x%h arlen=%0d araddr=0x%h",
							addr, d, axi_last_arlen, axi_last_araddr);
					end
				end else begin
					// cacheable
					rnd = $random(seed); sel = (rnd & 32'h7FFF_FFFF) % 6; idx = set_pool[sel];
					rnd = $random(seed); sel = (rnd & 32'h7FFF_FFFF) % 5; tg = tag_pool[sel];
					rnd = $random(seed); wd = rnd[2:0];
					addr = {3'b100, tg, idx, wd, 2'b00};
					full_tag = {3'b100, tg};

					hit0 = m_v0[idx] && (m_t0[idx] == full_tag);
					hit1 = m_v1[idx] && (m_t1[idx] == full_tag);
					exp_hit = hit0 || hit1;
					if (hit0) m_lru[idx] = 1'b1;
					else if (hit1) m_lru[idx] = 1'b0;
					else begin
						way = !m_v0[idx] ? 1'b0 : (!m_v1[idx] ? 1'b1 : m_lru[idx]);
						if (!way) begin m_v0[idx] = 1'b1; m_t0[idx] = full_tag; end
						else begin m_v1[idx] = 1'b1; m_t1[idx] = full_tag; end
						m_lru[idx] = ~way;
					end

					clear_axi_monitor();
					execute_req(addr, d);
					ok = (d == addr + 32'h0000_1000) && (axi_ar_handshake_seen == !exp_hit);
					if (!exp_hit)
						ok = ok && (axi_last_arlen == 8'd3) && (axi_last_araddr == {addr[31:5], 5'b00000});
					sb_req = sb_req + 1;
					if (exp_hit) sb_hit = sb_hit + 1; else sb_miss = sb_miss + 1;
					if (ok !== 1'b1) begin // X/Z counts as mismatch
						sb_mism = sb_mism + 1;
						if (sb_mism <= 5) $display("     [SB-MISMATCH] addr=0x%h exp=%0s data=0x%h ar_seen=%0d",
							addr, exp_hit ? "HIT" : "MISS", d, axi_ar_handshake_seen);
					end
				end
			end
		end
	endtask

	// Main Test Execution
	initial begin
		clk = 1'b0;
		reset = 1'b1;
		clk_enable = 1'b1;
		cpu_req_valid = 1'b0;
		cpu_req_addr = 32'h0;
		cpu_flush = 1'b0;
		fence_i_req = 1'b0;
		test_pass_count = 0;
		test_fail_count = 0;
		resp_data = 32'h0;
		for (idx = 1; idx <= 5; idx = idx + 1) begin
			issue_pass[idx] = 0;
			issue_fail[idx] = 0;
		end

		#25 reset = 1'b0;

		$display("========================================================");
		$display("   RV32IM54F8SP Instruction-CACHE FULL VERIFICATION SUITE         ");
		$display("========================================================");

		// TEST 1: Primary Miss & Line Refill
		$display("\n[TEST 1] Cache Miss & Refill (0x8000_0000)");
		clear_axi_monitor();
		execute_req(32'h8000_0000, resp_data);
		assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd3) && (resp_data == 32'h8000_1000),
			"Miss Refill Data 0x80001000");

		// TEST 2-4: Cache Hits on Same Line
		$display("\n[TEST 2] Cache Hit Offset 0x4 (0x8000_0004)");
		clear_axi_monitor();
		execute_req(32'h8000_0004, resp_data);
		assert_test(!axi_ar_handshake_seen && (resp_data == 32'h8000_1004),
			"Hit Data 0x80001004 (no AXI traffic)");

		$display("\n[TEST 3] Cache Hit Offset 0x8 (0x8000_0008)");
		clear_axi_monitor();
		execute_req(32'h8000_0008, resp_data);
		assert_test(!axi_ar_handshake_seen && (resp_data == 32'h8000_1008),
			"Hit Data 0x80001008 (no AXI traffic)");

		$display("\n[TEST 4] Cache Hit Offset 0x1C (0x8000_001C)");
		clear_axi_monitor();
		execute_req(32'h8000_001C, resp_data);
		assert_test(!axi_ar_handshake_seen && (resp_data == 32'h8000_101C),
			"Hit Data 0x8000101C (no AXI traffic)");

		// TEST 5: Bypass / Uncached Access
		$display("\n[TEST 5] Uncached / Bypass Read (0x0000_0100)");
		clear_axi_monitor();
		execute_req(32'h0000_0100, resp_data);
		assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd0) && (resp_data == 32'h0000_1100),
			"Bypass Single Read (ARLEN=0) & Data 0x00001100");

		// TEST 6-7: 2-Way Associativity and LRU Eviction
		$display("\n[TEST 6] Tag Replacement - Fill Way 1 (0x8004_0000)");
		clear_axi_monitor();
		execute_req(32'h8004_0000, resp_data); // Diff Tag, Same Index 0
		assert_test(axi_ar_handshake_seen && (resp_data == 32'h8004_1000),
			"Diff Tag inserted into Way 1");

		$display("\n[TEST 7] Tag Replacement - Evict Way 0 by LRU (0x8008_0000)");
		clear_axi_monitor();
		execute_req(32'h8008_0000, resp_data); // 3rd Tag, evicts Way 0
		assert_test(axi_ar_handshake_seen && (resp_data == 32'h8008_1000),
			"Evicted Way 0 properly");

		// TEST 8: Pipeline Flush Injection
		$display("\n[TEST 8] Pipeline Flush Injection (0x800C_0040)");
		clear_axi_monitor();
		@(negedge clk);
		cpu_req_valid = 1'b1;
		cpu_req_addr = 32'h800C_0040;

		timeout = 0;
		while (!m_axi_arvalid && timeout < 100) begin
			@(negedge clk);
			timeout = timeout + 1;
		end

		@(negedge clk);
		cpu_flush = 1'b1;
		@(negedge clk);
		cpu_flush = 1'b0;

		timeout = 0;
		while (!cpu_ready && timeout < 500) begin
			@(negedge clk);
			timeout = timeout + 1;
		end

		resp_data = cpu_rdata;
		cpu_req_valid = 1'b0;
		cpu_req_addr = 32'h0;

		assert_test(resp_data == 32'h0000_0013,
			"Flush correctly squashed output instruction to NOP (0x00000013)");

		clear_axi_monitor();
		execute_req(32'h800C_0040, resp_data);
		assert_test(!axi_ar_handshake_seen && (resp_data == 32'h800C_1040),
			"Flushed line was saved in cache and served as HIT on re-access");

		// TEST 9: FENCE.I Invalidation
		$display("\n[TEST 9] FENCE.I Invalidation Request");
		clear_axi_monitor();

		@(negedge clk);
		fence_i_req = 1'b1;

		timeout = 0;
		while (!fence_i_done && timeout < 1000) begin
			@(negedge clk);
			timeout = timeout + 1;
		end

		fence_i_req = 1'b0;
		@(negedge clk);

		clear_axi_monitor();
		execute_req(32'h8008_0000, resp_data); // Previously cached address

		assert_test(axi_ar_handshake_seen && (axi_last_arlen == 8'd3) && (resp_data == 32'h8008_1000),
			"FENCE.I forced Cache Miss & Refill on 0x8008_0000");

		// ============================================================
		// ISSUE-FIX VERIFICATION (fence_i_req / cpu_flush handling)
		// ============================================================
		$display("\n--------------------------------------------------------");
		$display(" ISSUE-FIX VERIFICATION (fence_i_req / cpu_flush)");
		$display("--------------------------------------------------------");

		// TEST 10: [ISSUE 1] FENCE.I request must be held internally until done
		$display("\n[TEST 10] FENCE.I req pulse is held internally until done");

		// 10a: 1-cycle fence_i_req pulse while IDLE (req is low long before done)
		execute_req(32'h8000_0200, resp_data);
		base_done = fence_done_cnt;
		@(negedge clk);
		fence_i_req = 1'b1;
		@(negedge clk);
		fence_i_req = 1'b0;
		wait_fence_done(base_done, 1000);
		assert_issue(1, fence_done_cnt == base_done + 1,
			"1-cycle req in IDLE -> FENCE.I completes (done)");
		wait_cycles(700);
		assert_issue(1, fence_done_cnt == base_done + 1,
			"No extra done after 1-cycle req");
		clear_axi_monitor();
		execute_req(32'h8000_0200, resp_data);
		assert_issue(1, axi_ar_handshake_seen && (resp_data == 32'h8000_1200),
			"Line invalidated after 1-cycle req (re-miss)");

		// 10b: 1-cycle fence_i_req pulse while a miss refill is in flight
		clear_axi_monitor();
		base_done = fence_done_cnt;
		cpu_req_valid = 1'b0;
		@(negedge clk);
		cpu_req_valid = 1'b1;
		cpu_req_addr = 32'h8000_0400;

		timeout = 0;
		while (!m_axi_arvalid && timeout < 100) begin
			@(negedge clk);
			timeout = timeout + 1;
		end

		fence_i_req = 1'b1;
		@(negedge clk);
		fence_i_req = 1'b0;

		timeout = 0;
		while (!cpu_ready && timeout < 500) begin
			@(negedge clk);
			timeout = timeout + 1;
		end
		resp_data = cpu_rdata;
		cpu_req_valid = 1'b0;
		cpu_req_addr = 32'h0;

		assert_issue(1, resp_data == 32'h8000_1400,
			"Refill response intact while FENCE.I req is pending");
		wait_fence_done(base_done, 1000);
		assert_issue(1, fence_done_cnt == base_done + 1,
			"1-cycle req during miss is not lost (done)");
		wait_cycles(700);
		assert_issue(1, fence_done_cnt == base_done + 1,
			"No extra done after pending FENCE.I");
		clear_axi_monitor();
		execute_req(32'h8000_0400, resp_data);
		assert_issue(1, axi_ar_handshake_seen && (resp_data == 32'h8000_1400),
			"Line invalidated by the pending FENCE.I (re-miss)");

		// TEST 11: [ISSUE 2] fence_i_req held high must not re-run FENCE.I
		$display("\n[TEST 11] FENCE.I req held high after done (no re-execution)");
		execute_req(32'h8000_0600, resp_data);
		base_done = fence_done_cnt;
		base_done_hi = fence_done_hi_cnt;
		@(negedge clk);
		fence_i_req = 1'b1;
		wait_fence_done(base_done, 1000);
		assert_issue(2, fence_done_cnt == base_done + 1,
			"FENCE.I completes with req held high");
		wait_cycles(1500);
		assert_issue(2, fence_done_cnt == base_done + 1,
			"No second FENCE.I while req stays high (1500 cycles)");
		assert_issue(2, fence_done_hi_cnt == base_done_hi + 1,
			"done is a single 1-cycle pulse");
		fence_i_req = 1'b0;
		wait_cycles(3);
		clear_axi_monitor();
		execute_req(32'h8000_0600, resp_data);
		assert_issue(2, axi_ar_handshake_seen && (resp_data == 32'h8000_1600),
			"Cache resumes after req drops (line was invalidated)");
		wait_cycles(700);
		assert_issue(2, fence_done_cnt == base_done + 1,
			"No FENCE.I re-run after req dropped");

		// TEST 12: [ISSUE 3] cpu_flush while IDLE must be released immediately
		$display("\n[TEST 12] cpu_flush while IDLE is released immediately");

		// 12a: 1-cycle flush with no request, then a miss
		wait_cycles(2);
		cpu_flush = 1'b1;
		@(negedge clk);
		cpu_flush = 1'b0;
		wait_cycles(3);
		execute_req(32'h8000_0800, resp_data);
		assert_issue(3, resp_data == 32'h8000_1800,
			"Miss after IDLE flush is not squashed");

		// 12b: flush in IDLE, request driven in the very next cycle
		wait_cycles(2);
		cpu_flush = 1'b1;
		@(negedge clk);
		cpu_flush = 1'b0;
		cpu_req_valid = 1'b1;
		cpu_req_addr = 32'h8000_0A00;
		timeout = 0;
		while (!cpu_ready && timeout < 500) begin
			@(negedge clk);
			timeout = timeout + 1;
		end
		resp_data = cpu_rdata;
		cpu_req_valid = 1'b0;
		cpu_req_addr = 32'h0;
		@(negedge clk);
		assert_issue(3, resp_data == 32'h8000_1A00,
			"Miss right after IDLE flush is not squashed");

		// 12c: hit after IDLE flush
		wait_cycles(2);
		cpu_flush = 1'b1;
		@(negedge clk);
		cpu_flush = 1'b0;
		execute_req(32'h8000_0804, resp_data);
		assert_issue(3, resp_data == 32'h8000_1804,
			"Hit after IDLE flush is not squashed");

		// TEST 13: [ISSUE 4/5] cpu_flush during a hit is released at the hit response
		$display("\n[TEST 13] cpu_flush during HIT is released at the hit response");

		// 13a: 1-cycle flush in the LOOKUP cycle of a hit
		execute_req_flush(32'h8000_0800, 1, 1, resp_data);
		assert_issue(4, resp_data == 32'h0000_0013,
			"Hit response squashed to NOP by flush");
		clear_axi_monitor();
		execute_req(32'h8000_0C00, resp_data);
		assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_1C00),
			"Next miss after flushed hit is not squashed");
		clear_axi_monitor();
		execute_req(32'h8000_0800, resp_data);
		assert_issue(4, !axi_ar_handshake_seen && (resp_data == 32'h8000_1800),
			"Next hit after flushed hit is not squashed");

		// 13b: flush held high across the hit response and into IDLE
		execute_req_flush(32'h8000_0804, 1, 5, resp_data);
		assert_issue(4, resp_data == 32'h0000_0013,
			"Hit squashed with multi-cycle flush");
		clear_axi_monitor();
		execute_req(32'h8000_0E00, resp_data);
		assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_1E00),
			"Miss after multi-cycle flush is not squashed");

		// TEST 14: [ISSUE 5] flush during a refill must not leak into later requests
		$display("\n[TEST 14] cpu_flush during MISS refill does not leak into next miss");

		// 14a: flush pulse early in the refill, released before the response
		execute_req_flush(32'h8000_1000, 2, 3, resp_data);
		assert_issue(5, resp_data == 32'h0000_0013,
			"Refill response squashed (flush latched in flight)");
		clear_axi_monitor();
		execute_req(32'h8000_1000, resp_data);
		assert_issue(5, !axi_ar_handshake_seen && (resp_data == 32'h8000_2000),
			"Squashed refill still allocated the line (HIT)");
		clear_axi_monitor();
		execute_req(32'h8000_1400, resp_data);
		assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_2400),
			"Next miss after squashed refill is not squashed");

		// 14b: flush held through the refill response and into IDLE
		execute_req_flush(32'h8000_1800, 2, 12, resp_data);
		assert_issue(5, resp_data == 32'h0000_0013,
			"Refill response squashed (flush held past response)");
		clear_axi_monitor();
		execute_req(32'h8000_1C00, resp_data);
		assert_issue(5, axi_ar_handshake_seen && (resp_data == 32'h8000_2C00),
			"Next miss after held flush is not squashed");

		$display("\n========================================================");
		$display(" ISSUE-FIX SUMMARY (PASS = problem is corrected)");
		$display("========================================================");
		$display("  [ISSUE 1] fence_i_req held internally until done   : %0s (pass=%0d fail=%0d)",
			(issue_fail[1] == 0 && issue_pass[1] > 0) ? "PASS" : "FAIL", issue_pass[1], issue_fail[1]);
		$display("  [ISSUE 2] no FENCE.I re-run while req stays high   : %0s (pass=%0d fail=%0d)",
			(issue_fail[2] == 0 && issue_pass[2] > 0) ? "PASS" : "FAIL", issue_pass[2], issue_fail[2]);
		$display("  [ISSUE 3] IDLE cpu_flush released immediately      : %0s (pass=%0d fail=%0d)",
			(issue_fail[3] == 0 && issue_pass[3] > 0) ? "PASS" : "FAIL", issue_pass[3], issue_fail[3]);
		$display("  [ISSUE 4] hit-time cpu_flush released at response  : %0s (pass=%0d fail=%0d)",
			(issue_fail[4] == 0 && issue_pass[4] > 0) ? "PASS" : "FAIL", issue_pass[4], issue_fail[4]);
		$display("  [ISSUE 5] no stale flush squashing the next miss   : %0s (pass=%0d fail=%0d)",
			(issue_fail[5] == 0 && issue_pass[5] > 0) ? "PASS" : "FAIL", issue_pass[5], issue_fail[5]);


		// ============================================================
		// COVERAGE EXTENSION (TEST 15 ~ 22)
		// Closes gaps found by mutation testing of the original suite:
		// way1 / LRU / tag aliasing / FENCE.I range / bypass / critical word / randomized scoreboard
		// ============================================================
		$display("\n--------------------------------------------------------");
		$display(" COVERAGE EXTENSION (way1, LRU, tag, FENCE.I range, ...)");
		$display("--------------------------------------------------------");

		// TEST 15: LRU victim selection follows allocation order
		$display("\n[TEST 15] 2-way LRU: victim follows allocation order (set 101)");
		check_cached(32'h8000_0CA0, 1'b0, "A miss -> fills way0");
		check_cached(32'h8004_0CA0, 1'b0, "B miss -> fills way1");
		check_cached(32'h8008_0CA0, 1'b0, "C miss -> evicts oldest line A");
		check_cached(32'h8004_0CA0, 1'b1, "B still resident (HIT, way1 data path)");
		check_cached(32'h8008_0CA0, 1'b1, "C resident (HIT, way0 data path)");
		check_cached(32'h8000_0CA0, 1'b0, "A was evicted (MISS)");

		// TEST 16: LRU update on hits (way0 hit and way1 hit)
		$display("\n[TEST 16] 2-way LRU: hit on either way refreshes recency (set 102)");
		check_cached(32'h8000_0CC0, 1'b0, "A miss (way0)");
		check_cached(32'h8004_0CC0, 1'b0, "B miss (way1)");
		check_cached(32'h8000_0CC0, 1'b1, "A hit (way0) -> B becomes LRU");
		check_cached(32'h8008_0CC0, 1'b0, "C miss evicts B (not A)");
		check_cached(32'h8000_0CC0, 1'b1, "A survived eviction (HIT)");
		check_cached(32'h8008_0CC0, 1'b1, "C hit (way1) -> A becomes LRU");
		check_cached(32'h800C_0CC0, 1'b0, "D miss evicts A (not C)");
		check_cached(32'h8008_0CC0, 1'b1, "C survived eviction (HIT)");
		check_cached(32'h8000_0CC0, 1'b0, "A was evicted (MISS)");

		// TEST 17: flush on a way1 hit
		$display("\n[TEST 17] cpu_flush squashes a HIT served from way1 (set 103)");
		check_cached(32'h8000_0CE0, 1'b0, "A miss (way0)");
		check_cached(32'h8004_0CE0, 1'b0, "B miss (way1)");
		execute_req_flush(32'h8004_0CE0, 1, 1, resp_data);
		assert_test(resp_data == 32'h0000_0013, "way1 hit squashed to NOP by flush");
		check_cached(32'h8004_0CE0, 1'b1, "way1 hit after flushed hit is not squashed");

		// TEST 18: critical-word / whole-line refill (miss at every word offset, then read the full line)
		$display("\n[TEST 18] Miss at every word offset, then read back the whole line");
		begin : T18
			integer k, w, f_miss, f_hit;
			reg [31:0] line_base;
			f_miss = 0;
			f_hit = 0;
			for (k = 0; k < 8; k = k + 1) begin
				line_base = 32'h8000_0000 + ((300 + k) * 32);
				check_cached_quiet(line_base + (k * 4), 1'b0, f_miss);
				for (w = 0; w < 8; w = w + 1)
					check_cached_quiet(line_base + (w * 4), 1'b1, f_hit);
			end
			assert_test(f_miss == 0, "Miss at word offset 0..7: data, ARADDR(line aligned), ARLEN=3");
			assert_test(f_hit == 0, "All 8 words of every refilled line read back correctly (HIT)");
		end

		// TEST 19: bypass path
		$display("\n[TEST 19] Bypass: upper word, no allocation, cacheable region boundaries");
		check_bypass(32'h0000_0104, "Bypass upper word (offset[2]=1), ARADDR 8B aligned");
		check_bypass(32'h0000_0104, "Bypass is not allocated (second access goes to AXI again)");
		check_bypass(32'h7FFF_FFFC, "0x7FFF_FFFC is below DDR window -> bypass");
		check_cached(32'h9FFF_FFFC, 1'b0, "0x9FFF_FFFC is inside DDR window -> cached refill");
		check_bypass(32'hA000_0000, "0xA000_0000 is above DDR window -> bypass");
		check_bypass(32'h4000_0000, "0x4000_0000 -> bypass");

		// TEST 20: every tag bit participates in the compare (no aliasing)
		$display("\n[TEST 20] Tag compare: lines differing in a single tag bit never alias");
		begin : T20
			integer k, f;
			reg [31:0] a0, a1;
			f = 0;
			for (k = 14; k <= 28; k = k + 1) begin
				a0 = 32'h8000_0000 | ((200 + (k - 14)) << 5);
				a1 = a0 ^ (32'h1 << k);
				check_cached_quiet(a0, 1'b0, f);
				check_cached_quiet(a1, 1'b0, f); // must be a MISS with its own data
				check_cached_quiet(a0, 1'b1, f);
				check_cached_quiet(a1, 1'b1, f);
			end
			assert_test(f == 0, "addr[28:14] each distinguish lines in the same set (15 bits x 2 ways)");
		end

		// TEST 21: FENCE.I invalidates every set and both ways
		$display("\n[TEST 21] FENCE.I invalidates all sets / both ways (sets 0,1,255,256,257,510,511)");
		begin : T21
			integer s, f_pre, f_hit, f_post;
			integer sets [0:6];
			reg [31:0] l0, l1;
			sets[0] = 0; sets[1] = 1; sets[2] = 255; sets[3] = 256;
			sets[4] = 257; sets[5] = 510; sets[6] = 511;
			f_pre = 0; f_hit = 0; f_post = 0;
			for (s = 0; s < 7; s = s + 1) begin
				l0 = 32'h8010_0000 | (sets[s] << 5);
				l1 = 32'h8014_0000 | (sets[s] << 5);
				check_cached_quiet(l0, 1'b0, f_pre);
				check_cached_quiet(l1, 1'b0, f_pre);
				check_cached_quiet(l0, 1'b1, f_hit);
				check_cached_quiet(l1, 1'b1, f_hit);
			end
			do_fence;
			for (s = 0; s < 7; s = s + 1) begin
				l0 = 32'h8010_0000 | (sets[s] << 5);
				l1 = 32'h8014_0000 | (sets[s] << 5);
				check_cached_quiet(l0, 1'b0, f_post);
				check_cached_quiet(l1, 1'b0, f_post);
			end
			assert_test(f_pre == 0 && f_hit == 0, "Both ways of all 7 sets were populated before FENCE.I");
			assert_test(f_post == 0, "After FENCE.I every line (way0 & way1, low & high sets) re-misses");
		end

		// TEST 22: flush arriving in the same cycle as the request (documented InstructionCache behaviour)
		$display("\n[TEST 22] cpu_flush concurrent with request acceptance squashes that request");
		check_cached(32'h8000_0D00, 1'b0, "prime line (set 104)");
		execute_req_flush(32'h8000_0D00, 0, 1, resp_data);
		assert_test(resp_data == 32'h0000_0013, "flush in the accept cycle -> response squashed to NOP");
		check_cached(32'h8000_0D20, 1'b0, "next request is not squashed");

		// TEST 23: randomized scoreboard against a reference model
		$display("\n[TEST 23] Randomized scoreboard vs. reference model (hit/miss, LRU, data, AXI)");
		axi_stress = 1'b0;
		rand_scoreboard(2000, 32'h00C0_FFEE);
		$display("     requests=%0d hit=%0d miss=%0d bypass=%0d fence=%0d mismatch=%0d",
			sb_req, sb_hit, sb_miss, sb_byp, sb_fence, sb_mism);
		assert_test(sb_mism == 0 && sb_hit > 100 && sb_miss > 100, "Scoreboard, fixed-latency AXI slave");

		axi_stress = 1'b1;
		rand_scoreboard(2000, 32'h0BAD_5EED);
		$display("     requests=%0d hit=%0d miss=%0d bypass=%0d fence=%0d mismatch=%0d",
			sb_req, sb_hit, sb_miss, sb_byp, sb_fence, sb_mism);
		assert_test(sb_mism == 0 && sb_hit > 100 && sb_miss > 100, "Scoreboard, random ARREADY delay + RVALID gaps");
		axi_stress = 1'b0;

		// TEST 24: flush / FENCE.I arriving in every in-flight phase of a request
		// (TEST 8/10b/14 only inject while ARVALID is high; LOOKUP and the R burst were uncovered)
		$display("\n[TEST 24] flush / FENCE.I latched in every in-flight phase (LOOKUP, AR, R burst, bypass)");
		check_flush_in_phase(32'h8020_0F0C, 32'h8020_0F2C, PH_LOOKUP,   "flush in miss LOOKUP cycle -> refill squashed to NOP");
		check_flush_in_phase(32'h8020_0F4C, 32'h8020_0F6C, PH_ADDR,     "flush while ARVALID (ALLOC_AR) -> refill squashed to NOP");
		check_flush_in_phase(32'h8020_0F8C, 32'h8020_0FAC, PH_DATA_MID, "flush during R burst (ALLOC_R) -> refill squashed to NOP");
		check_fence_in_phase(32'h8020_100C, PH_LOOKUP,   "FENCE.I in miss LOOKUP cycle -> refill data intact");
		check_fence_in_phase(32'h8020_102C, PH_ADDR,     "FENCE.I while ARVALID (ALLOC_AR) -> refill data intact");
		check_fence_in_phase(32'h8020_104C, PH_DATA_MID, "FENCE.I during R burst (ALLOC_R) -> refill data intact");
		begin : T24_BYPASS
			reg inj;
			clear_axi_monitor();
			execute_req_inject(32'h0000_0204, PH_LOOKUP, 1'b0, resp_data, inj);
			assert_test(inj && axi_ar_handshake_seen && (resp_data === 32'h0000_0013), "flush in bypass LOOKUP cycle -> NOP");
			check_bypass(32'h0000_0304, "  ...next bypass is not squashed");
			clear_axi_monitor();
			execute_req_inject(32'h0000_0204, PH_ADDR, 1'b0, resp_data, inj);
			assert_test(inj && axi_ar_handshake_seen && (resp_data === 32'h0000_0013), "flush while ARVALID (BYPASS_AR) -> NOP");
			check_bypass(32'h0000_0304, "  ...next bypass is not squashed");
		end

		// same in-flight injections with the stressed AXI slave (ARREADY delay / RVALID gaps)
		axi_stress = 1'b1;
		check_flush_in_phase(32'h8024_0F8C, 32'h8024_0FAC, PH_DATA_MID, "[stress] flush during R burst -> refill squashed to NOP");
		check_fence_in_phase(32'h8024_104C, PH_DATA_MID, "[stress] FENCE.I during R burst -> refill data intact");
		axi_stress = 1'b0;

		$display("\n========================================================");
		$display("SIMULATION FINISHED");
		$display("PASS: %0d", test_pass_count);
		$display("FAIL: %0d", test_fail_count);
		$display("========================================================");

		if (test_fail_count == 0 && test_pass_count > 0) begin
			$display(">>> ALL TEST CASES PASSED SUCCESSFULLY! <<<");
			$finish;
		end else begin
			$display(">>> SIMULATION FAILED WITH ERRORS! <<<");
			// non-zero vvp exit code so scripts / CI detect the failure ($finish always exits 0)
			$fatal(1, "Instruction cache TB: %0d test(s) failed", test_fail_count);
		end
	end

endmodule