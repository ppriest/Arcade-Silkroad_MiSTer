// SPDX-License-Identifier: GPL-3.0-or-later
//
// Routes Port 2's clients onto one physical sdram_phy port: the two OKI sample caches (c0,
// c4), the main CPU's program fetch (c2, through rom_cache) and the ROM download's write
// path. c1 and c3 have no client in this core.
//
// Read consumers all speak the same 64-bit-granule contract sdram_phy's read side provides
// (8-byte-aligned address in, full burst-4 granule out); the narrower CPU client sits behind
// rtl/memory/rom_cache.sv, which is NOT part of this module: this arbiter only knows about
// 64-bit granules, matching sdram_phy/sdram.sv exactly, so it stays a pure transport-layer
// module with no per-consumer width knowledge.
//
// The download write path has absolute priority: it is only active during ROM loading,
// before gameplay starts, so it cannot cost anything at runtime. The reads are served
// round-robin, except the two OKI caches, which are promoted above it (below).
//
// c0: OKI 1 sample cache (rtl/sound/sample_cache.sv)
// c1: no client
// c2: maincpu program fetch (via rom_cache)
// c3: no client
// c4: OKI 2 sample cache

module sdram_arbiter6 (
	input  logic clk,
	input  logic reset,

	// physical port (to sdram_phy)
	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [24:0] phy_addr,
	output logic [15:0] phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0] phy_rdata,

	// consumer 0: OKI 1 sample cache
	input  logic         c0_req,
	input  logic [24:0] c0_addr,
	output logic         c0_valid,
	output logic [63:0] c0_data,

	// consumer 1: no client
	input  logic         c1_req,
	input  logic [24:0] c1_addr,
	output logic         c1_valid,
	output logic [63:0] c1_data,

	// consumer 2: maincpu program fetch (through rom_cache)
	input  logic         c2_req,
	input  logic [24:0] c2_addr,
	output logic         c2_valid,
	output logic [63:0] c2_data,

	// consumer 3: no client
	input  logic         c3_req,
	input  logic [24:0] c3_addr,
	output logic         c3_valid,
	output logic [63:0] c3_data,

	// consumer 4: OKI 2 sample cache. Very low bandwidth -- 1 MHz on the chip
	// is about one byte every 48 clk at 48 MHz -- so it costs the round robin
	// almost nothing.
	input  logic         c4_req,
	input  logic [24:0] c4_addr,
	output logic         c4_valid,
	output logic [63:0] c4_data,

	// ROM-download write path -- absolute priority, hold dl_req until
	// dl_busy asserts (NOT hps_io's raw one-shot ioctl_wr pulse -- see
	// rtl/memory/sdram_download.sv for the translation layer)
	input  logic         dl_req,
	input  logic [24:0] dl_addr,
	input  logic [15:0] dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);

	logic [4:0] c_req;
	logic [24:0] c_addr [0:4];
	assign c_req    = {c4_req, c3_req, c2_req, c1_req, c0_req};
	assign c_addr[0] = c0_addr;
	assign c_addr[1] = c1_addr;
	assign c_addr[2] = c2_addr;
	assign c_addr[3] = c3_addr;
	assign c_addr[4] = c4_addr;

	typedef enum logic [1:0] {A_IDLE, A_ISSUE, A_WAIT_READ, A_WAIT_WRITE} astate_t;
	astate_t astate;

	logic [2:0] rr_ptr;
	logic [2:0] sel;
	logic         sel_is_dl;

	// The two OKI sample streams (c0 = OKI 1, c4 = OKI 2) are promoted above the
	// round-robin. They are the only latency-critical clients on this port:
	// jt6295 does not wait for a miss -- sample_cache.sv keeps each chip's four
	// channels' granules with next-granule prefetch -- whereas the CPU fetch
	// has slack. Their bandwidth is negligible -- a byte per stream every few
	// hundred cycles against program-fetch traffic measured in granules per
	// scanline -- so promoting them costs the other client nothing it notices.
	//
	// This matters because the physical arbitration in sdram/sdram.sv is FIXED
	// priority, not fair: port 0 (both tilemaps) preempts port 1 (sprite
	// gfxrom), which preempts port 2 -- this arbiter. So on a busy screen the
	// sample fetches are already last in line physically, and then queue behind
	// the CPU fetch here.
	//
	// adpcm_tog alternates between the two so neither can starve the other
	// when both are streaming.
	logic [2:0] next_sel;
	logic         found;
	logic         adpcm_tog;
	always_comb begin
		found    = 1'b0;
		next_sel = rr_ptr;
		if (c_req[0] && c_req[4]) begin
			next_sel = adpcm_tog ? 3'd4 : 3'd0;
			found    = 1'b1;
		end else if (c_req[0]) begin
			next_sel = 3'd0;
			found    = 1'b1;
		end else if (c_req[4]) begin
			next_sel = 3'd4;
			found    = 1'b1;
		end else for (int i = 0; i < 5; i++) begin
			logic [3:0] sum;   // 4 bits: rr_ptr(<=4) + i(<=4) = up to 8 -- a
								// 3-bit sum wrapped 4+4 to 0 BEFORE the >=5
								// check, so with rr_ptr==4 the scan set was
								// {4,0,1,2,0} and one client was never scanned.
			sum = {1'b0, rr_ptr} + i[3:0];
			if (sum >= 4'd5) sum = sum - 4'd5;
			if (!found && c_req[sum[2:0]]) begin
				next_sel = sum[2:0];
				found    = 1'b1;
			end
		end
	end

	assign dl_busy = (astate != A_IDLE) && sel_is_dl;

	assign phy_addr  = sel_is_dl ? dl_addr : c_addr[sel];
	assign phy_wdata = dl_data;
	assign phy_we    = sel_is_dl;
	assign phy_we16  = dl_we16;
	assign phy_req   = (astate == A_ISSUE) && !phy_busy;

	assign c0_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd0) && phy_valid;
	assign c1_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd1) && phy_valid;
	assign c2_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd2) && phy_valid;
	assign c3_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd3) && phy_valid;
	assign c0_data  = phy_rdata;
	assign c1_data  = phy_rdata;
	assign c2_data  = phy_rdata;
	assign c3_data  = phy_rdata;
	assign c4_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd4) && phy_valid;
	assign c4_data  = phy_rdata;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			astate <= A_IDLE;
			rr_ptr <= 3'd0;
			sel_is_dl <= 1'b0;
			adpcm_tog <= 1'b0;
		end else begin
			case (astate)
				A_IDLE: begin
					if (dl_req) begin
						sel_is_dl <= 1'b1;
						astate    <= A_ISSUE;
					end else if (found) begin
						sel       <= next_sel;
						sel_is_dl <= 1'b0;
						astate    <= A_ISSUE;
					end
				end

				A_ISSUE: begin
					// phy_req pulsed this cycle (combinational, gated by
					// !phy_busy). Once accepted, move to the matching wait
					// state; if phy_busy was unexpectedly still high (should
					// not happen given this arbiter fully serializes access
					// to sdram_phy), simply retry next cycle.
					if (!phy_busy) astate <= sel_is_dl ? A_WAIT_WRITE : A_WAIT_READ;
				end

				A_WAIT_READ: begin
					if (phy_valid) begin
						// alternate the OKI pair on each grant to one of them
						if (sel == 3'd0 || sel == 3'd4) adpcm_tog <= ~adpcm_tog;
						rr_ptr <= (sel == 3'd4) ? 3'd0 : sel + 3'd1;
						astate <= A_IDLE;
					end
				end

				A_WAIT_WRITE: begin
					if (!phy_busy) astate <= A_IDLE;
				end
			endcase
		end
	end

endmodule
