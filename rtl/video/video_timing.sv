// Raw video timing. H total 512 and V total 262 at 8 MHz, chosen in docs/HACKS.md
// (15.625 kHz, 59.637 Hz against MAME's 60 Hz). 380 x 224 visible, silkroad.cpp's visible
// area (454).
//
// The compositor reads column k while hcnt = k (h_active, hcnt 0-379), and it is on the
// output during the following pixel period, so the visible window is hcnt 1-380: screen
// x = hcnt - 1. line_start fires once the last column has been read (into hcnt 381).
//
// hsync is a 38-pixel (4.75 us) pulse from hcnt 420; vsync 3 lines starting 8 lines into
// vblank. Chosen, not from MAME, which has no sync widths.
//
// hcnt/vcnt are raw raster counters (not gated by ce_pix themselves --
// they only ADVANCE on ce_pix cycles, but hold their value the rest of the
// time, matching Template_MiSTer's existing ce_pix/CE_PIXEL convention).
// vcnt_active is the tilemap engines' expected 0-223 view (garbage/frozen
// outside the active window is fine since h_active/line_start already gate
// when it's actually consumed).
//
// frame_start fires on vblank's rising edge (vcnt 223->224).
module video_timing (
	input  logic clk,
	input  logic ce_pix,
	input  logic reset,

	output logic [8:0] hcnt,          // 0-511, raw raster column
	output logic [8:0] vcnt,          // 0-261, raw raster line
	output logic [7:0] vcnt_active,   // vcnt truncated to tilemap_line_engine's 0-223 port width
	// The line the NEXT line_start prefetches for. line_start fires at the end
	// of the ACTIVE window (hcnt == H_ACTIVE-1) while vcnt still holds the line
	// just displayed, but the data it fetches is shown on the following line --
	// so the tilemap engines must index with vcnt+1, not vcnt. Wrapped on
	// V_TOTAL before truncating: vcnt_active is a raw truncation of a 0-261
	// counter, so at the last raster line it reads 6, and a plain vcnt+1 would
	// fetch line 0 as row 6.
	output logic [7:0] vcnt_next_active,

	// vcnt+2, wrapped the same way. The per-scanline SPRITE path needs one
	// more line of lead than the tilemaps: the tilemap engines latch
	// vcnt_next_active at line_start and display that row on the very next
	// line, whereas sprite_line_buffer swaps banks on line_start, so a bank
	// filled after one line_start is not displayed until after the NEXT one --
	// one extra line of latency. Indexing the sprite render with vcnt+1 put
	// its rows one scanline BELOW the tilemaps on hardware.
	output logic [7:0] vcnt_next2_active,

	output logic h_active,   // 1 while hcnt in [0,379]: the compositor's read window
	output logic v_active,   // 1 while vcnt in [0,223]
	output logic hblank,     // 0 while hcnt in [1,380]: the output's window
	output logic vblank,
	output logic hsync,
	output logic vsync,

	output logic line_start,    // 1-cycle pulse (on a ce_pix cycle), hcnt 380 -> 381
	output logic frame_start    // 1-cycle pulse (on a ce_pix cycle), vblank rising edge
);

	localparam int H_TOTAL   = 512;
	localparam int H_ACTIVE  = 380;
	localparam int H_SYNC_ST = 420;
	localparam int H_SYNC_EN = 420 + 38;

	localparam int V_TOTAL   = 262;
	localparam int V_ACTIVE  = 224;
	localparam int V_SYNC_ST = 224 + 8;
	localparam int V_SYNC_EN = 224 + 8 + 3;

	assign h_active = (hcnt < H_ACTIVE);
	assign v_active = (vcnt < V_ACTIVE);
	assign hblank   = (hcnt == 9'd0) || (hcnt > H_ACTIVE);
	assign vblank   = ~v_active;
	assign hsync    = (hcnt >= H_SYNC_ST) && (hcnt < H_SYNC_EN);
	assign vsync    = (vcnt >= V_SYNC_ST) && (vcnt < V_SYNC_EN);

	assign vcnt_active = vcnt[7:0];
	wire [8:0] vcnt_next = (vcnt == V_TOTAL - 1) ? 9'd0 : (vcnt + 9'd1);
	assign vcnt_next_active = vcnt_next[7:0];
	wire [8:0] vcnt_next2 = (vcnt >= V_TOTAL - 2) ? (vcnt - (V_TOTAL - 2)) : (vcnt + 9'd2);
	assign vcnt_next2_active = vcnt_next2[7:0];

	logic v_active_prev;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			hcnt          <= 9'd0;
			vcnt          <= 9'd0;
			line_start    <= 1'b0;
			frame_start   <= 1'b0;
			v_active_prev <= 1'b1;
		end else begin
			line_start  <= 1'b0;
			frame_start <= 1'b0;

			if (ce_pix) begin
				v_active_prev <= v_active;

				if (hcnt == H_TOTAL - 1) begin
					hcnt <= 9'd0;
					if (vcnt == V_TOTAL - 1) vcnt <= 9'd0;
					else                       vcnt <= vcnt + 9'd1;
				end else begin
					hcnt <= hcnt + 9'd1;
				end

				if (hcnt == H_ACTIVE) line_start <= 1'b1;

				if (v_active_prev && !v_active) frame_start <= 1'b1;
			end
		end
	end

endmodule
