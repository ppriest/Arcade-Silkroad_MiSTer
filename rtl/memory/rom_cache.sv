// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 68020's program-ROM cache: direct-mapped, LINES lines of one 8-byte SDRAM granule each,
// in block RAM. It takes the CPU's fetches off the SDRAM chip the tile and sprite engines share
// (docs/ROADMAP.md: with every fetch reaching SDRAM, the tilemap engine cut about 0.84 lines a
// frame short on hardware).
//
// The ports are sdram_narrow_bridge's (WORD_BYTES = 2), so it replaces it in place: the client
// pulses req and holds addr until valid; a hit answers the clock after req, a miss holds g_req
// until g_valid and answers with the arriving granule. Granule word i is g_data[16i +: 16], the
// even byte its low half (sdram_narrow_bridge.sv's derivation). The region is ROM, written only
// by the download: while inval (ioctl_download) is high every read misses and nothing is filled,
// and when it falls, as after reset, the tags are cleared by a sweep of LINES clocks. A request
// that arrives while the cache is busy (the sweep, mostly: the CPU leaves reset as the download
// ends) is remembered and served after it; the client pulses req only once.
module rom_cache #(
	parameter int INDEX_BITS = 11          // 2048 lines, 16 KB
) (
	input  logic         clk,
	input  logic         reset,
	input  logic         inval,

	input  logic         req,
	input  logic [24:0] addr,
	output logic         valid,
	output logic [15:0] data,

	output logic         g_req,
	output logic [24:0] g_addr,
	input  logic         g_valid,
	input  logic [63:0] g_data
);

	localparam int LINES    = 1 << INDEX_BITS;
	localparam int TAG_BITS = 22 - INDEX_BITS;          // granule address addr[24:3]

	typedef enum logic [2:0] {C_CLR, C_IDLE, C_LOOK, C_FILL, C_DRAIN} cstate_t;
	cstate_t st;

	logic [INDEX_BITS-1:0] idx, clr_idx;
	logic [TAG_BITS-1:0]   tag;
	logic [1:0]            word_sel;

	wire [INDEX_BITS-1:0] a_idx = addr[3 + INDEX_BITS - 1:3];
	wire [TAG_BITS-1:0]   a_tag = addr[24:3 + INDEX_BITS];

	// ---- the line RAMs: read a clock after the address, one write port ----
	logic [63:0]         dmem [0:LINES-1];
	logic [TAG_BITS:0]   tmem [0:LINES-1];             // {valid, tag}
	logic [63:0]         d_q;
	logic [TAG_BITS:0]   t_q;
	logic                we;
	logic [INDEX_BITS-1:0] w_idx;
	logic [63:0]         w_data;
	logic [TAG_BITS:0]   w_tag;

	logic pend;                                         // a req seen while not idle
	wire  take = (st == C_IDLE) && (req || pend);
	wire [INDEX_BITS-1:0] r_idx = (st == C_IDLE) ? a_idx : idx;
	always_ff @(posedge clk) begin
		d_q <= dmem[r_idx];
		t_q <= tmem[r_idx];
		if (we) begin
			dmem[w_idx] <= w_data;
			tmem[w_idx] <= w_tag;
		end
	end

	always_comb begin
		we     = 1'b0;
		w_idx  = idx;
		w_data = g_data;
		w_tag  = {1'b1, tag};
		if (st == C_CLR) begin
			we    = 1'b1;
			w_idx = clr_idx;
			w_tag = '0;
		end else if (st == C_FILL && g_valid && !inval) begin
			we = 1'b1;
		end
	end

	wire hit = t_q[TAG_BITS] && (t_q[TAG_BITS-1:0] == tag) && !inval;
	logic inval_d, need_clr;                            // the download ended: sweep when no fill is out
	always_ff @(posedge clk) inval_d <= inval;

	assign g_addr = {tag, idx, 3'b000};
	assign g_req  = (st == C_FILL);
	assign valid  = ((st == C_LOOK) && hit) || ((st == C_FILL) && g_valid);
	assign data   = (st == C_FILL) ? g_data[16 * word_sel +: 16] : d_q[16 * word_sel +: 16];

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st      <= C_CLR;
			clr_idx <= '0;
			pend    <= 1'b0;
			need_clr <= 1'b0;
		end else if ((need_clr || (inval_d && !inval)) && st != C_FILL) begin
			st      <= C_CLR;                               // the download is over: clear the tags
			clr_idx <= '0;
			need_clr <= 1'b0;
			pend    <= pend | req;
		end else begin
			if (inval_d && !inval) need_clr <= 1'b1;
			if (req && st != C_IDLE) pend <= 1'b1;
			if (take) pend <= 1'b0;
			case (st)
				C_CLR: begin
					clr_idx <= clr_idx + 1'b1;
					if (&clr_idx) st <= C_IDLE;
				end
				C_IDLE: if (take) begin
					idx      <= a_idx;
					tag      <= a_tag;
					word_sel <= addr[2:1];
					st       <= C_LOOK;
				end
				C_LOOK: st <= hit ? C_DRAIN : C_FILL;
				C_FILL: if (g_valid) begin
					st      <= C_IDLE;
					clr_idx <= '0;
				end
				// one clock after a hit before the next request: the client's req for the next
				// access cannot come sooner (it waits for valid), and a pulse here is kept in pend
				C_DRAIN: st <= C_IDLE;
				default: st <= C_IDLE;
			endcase
		end
	end

endmodule
