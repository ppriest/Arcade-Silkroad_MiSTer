// SPDX-License-Identifier: GPL-3.0-or-later
//
// silkroad.cpp's three tilemaps (252-258, get_tile_info 236-247), rendered a line ahead into
// double-buffered line buffers. One sequencer draws layers 0, 1, 2 in turn for the line after
// next (silkroad_core's convention, the same as the sprite line), then idles until line_start
// swaps the buffers.
//
// Per layer: 64 x 64 tiles of 16 x 16, TILEMAP_SCAN_ROWS. VRAM entry n is words 2n (bits 31-16:
// tile, + 0x18000) and 2n+1 (bit 7 flip X, bits 4-0 colour). Bitmap pixel (X, Y), X = screen
// x + 50 and Y = line + 16 (set_visarea, 454), shows tilemap pixel ((X + scrollx) & 1023,
// (Y + scrolly) & 1023). 25 tiles cover the 380 columns at any fine scroll; their pixels land at
// (tile column x 16 + i) & 511 in the line buffer, and the display reads (x + 50 + scrollx) & 511.
//
// A tile row is 12 bytes (docs/ROADMAP.md, Memory plan): planes 5-2 as one granule of region A
// at tile x 128 + row x 8 (thirds 0 and 1, four bytes each), planes 1-0 as the half of a region B
// granule at tile x 64 + row x 4 (third 2). Each third gives 2 bits of a pixel x: the bit
// 7 - (x & 7) of byte 0 (plane +0) and byte 1 (plane +8) for x < 8, of bytes 2 and 3 for x >= 8;
// the first plane listed is the pen's MSB (tiles16x16x6_layout, 422-431); the region is
// inverted (ROMREGION_INVERT, 488). scripts/gfx_layout_check.py proves this against MAME's
// decode. Granule bytes are little-endian: byte n is bits 8n+7:8n.
//
// Line buffer entry: {colour[4:0], pen[5:0]}; pen 0 is transparent on all three layers.
module silkroad_tilemaps (
	input  logic        clk,
	input  logic        reset,

	input  logic        line_start,     // swap the buffers; start render_line if render_en
	input  logic        render_en,
	input  logic [7:0]  render_line,    // 0-223

	input  logic [15:0] sx0, sy0, sx1, sy1, sx2, sy2,

	// the three VRAMs' read ports, one address for all (one layer at a time)
	output logic [12:0] vram_addr,
	input  logic [15:0] vram0_data, vram1_data, vram2_data,

	// graphics ROM: held request; gfx_b selects region B; gfx_off is a byte offset, 8-aligned
	output logic        gfx_req,
	output logic        gfx_b,
	output logic [23:0] gfx_off,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_data,

	// display: screen column, data a clock later
	input  logic [8:0]  rd_x,
	output logic [10:0] l0_px, l1_px, l2_px,

	output logic        busy,
	output logic        overrun_ev       // line_start while still rendering: the rest was cut
);

	// ---- line buffers ----
	logic        wbank;                   // the bank being rendered; the display reads ~wbank
	logic [8:0]  dxoff [0:2];             // display-side (50 + scrollx) & 511, per layer
	logic [8:0]  rxoff [0:2];             // the render-side value, handed over at the swap
	logic        lb_we [0:2];
	logic [8:0]  lb_waddr;
	logic [10:0] lb_wdata;

	genvar g;
	generate for (g = 0; g < 3; g++) begin : g_lb
		logic [10:0] rdata;
		dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(11)) u_lb (
			.clk(clk),
			.a_addr({wbank, lb_waddr}), .a_wel(lb_we[g]), .a_weh(lb_we[g]), .a_wdata(lb_wdata), .a_rdata(),
			.b_addr({~wbank, 9'(rd_x + dxoff[g])}), .b_rdata(rdata)
		);
	end endgenerate
	assign l0_px = g_lb[0].rdata;
	assign l1_px = g_lb[1].rdata;
	assign l2_px = g_lb[2].rdata;

	// ---- pen decode ----
	function automatic logic [1:0] pair(input logic [31:0] b, input logic [3:0] x);
		logic [7:0] lo, hi;
		lo = x[3] ? b[23:16] : b[7:0];
		hi = x[3] ? b[31:24] : b[15:8];
		pair = {hi[3'd7 - x[2:0]], lo[3'd7 - x[2:0]]};
	endfunction

	// ---- sequencer ----
	// The VRAM reader runs one tile ahead: while tile k's two granules are fetched it reads tile
	// k + 1's entry, so the next request goes out on the clock the last one's data arrives, the
	// request held high with the new address (the port shim issues once per request it sees
	// after a valid).
	typedef enum logic [2:0] {S_IDLE, S_ROW, S_TAKE, S_A, S_B, S_REUSE} state_t;
	state_t st;
	logic [1:0]  layer;
	logic [4:0]  k;                       // tile 0-24 of the layer's line being fetched
	logic [5:0]  trow, tcol0;
	logic [3:0]  row;
	logic [16:0] tile;
	logic [4:0]  colour;
	logic        flip;
	logic [8:0]  base;                    // the tile's first position in the line buffer
	logic [63:0] ga;
	// The last tile row fetched on this layer's line: a run of the same tile (empty tiles,
	// mostly) is drawn from it without fetching again.
	logic        last_ok;
	logic [16:0] last_tile;
	logic [31:0] last_b;

	wire [15:0] sx = (layer == 2'd0) ? sx0 : (layer == 2'd1) ? sx1 : sx2;
	wire [15:0] sy = (layer == 2'd0) ? sy0 : (layer == 2'd1) ? sy1 : sy2;
	wire [15:0] vdata = (layer == 2'd0) ? vram0_data : (layer == 2'd1) ? vram1_data : vram2_data;
	// render_line is sampled at line_start: vcnt moves on 132 pixels later, before the later
	// layers' rows are worked out
	logic [7:0] rline;
	always_ff @(posedge clk) if (line_start) rline <= render_line;
	wire [9:0]  ypix = 10'({2'b00, rline} + 10'd16 + sy[9:0]);
	wire [9:0]  xpix = 10'(10'd50 + sx[9:0]);

	// ---- VRAM reader: entry kv of the layer's line into nxt_* ----
	logic [1:0]  vu;                      // 0 idle, 1 code addressed, 2 attr addressed, 3 code in
	logic [4:0]  kv;
	logic        nxt_ok;
	logic [16:0] nxt_tile;
	logic [4:0]  nxt_colour;
	logic        nxt_flip;
	logic        take;                    // the sequencer takes nxt_* this clock

	// ---- writer: 16 pixels of the last tile row, one a clock ----
	logic        w_busy;
	logic [3:0]  w_i;
	logic [1:0]  w_layer;
	logic [8:0]  w_base;
	logic [4:0]  w_colour;
	logic        w_flip;
	logic [63:0] w_a;
	logic [31:0] w_b;

	wire [3:0] w_x = w_flip ? 4'(15 - w_i) : w_i;
	wire [5:0] w_pen = ~{pair(w_a[31:0], w_x), pair(w_a[63:32], w_x), pair(w_b, w_x)};

	always_comb begin
		for (int i = 0; i < 3; i++) lb_we[i] = w_busy && (w_layer == 2'(i));
		lb_waddr = 9'(w_base + 9'(w_i));
		lb_wdata = {w_colour, w_pen};
	end

	assign busy = (st != S_IDLE) || w_busy;

	// the next tile, taken from the reader: reused, or its region A fetch started (req held)
	wire nxt_reuse = last_ok && (last_tile == nxt_tile);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st <= S_IDLE; wbank <= 1'b0; gfx_req <= 1'b0; w_busy <= 1'b0; overrun_ev <= 1'b0;
			layer <= 2'd0; k <= 5'd0; last_ok <= 1'b0; vu <= 2'd0; kv <= 5'd0; nxt_ok <= 1'b0;
			for (int i = 0; i < 3; i++) begin dxoff[i] <= 9'd0; rxoff[i] <= 9'd0; end
		end else begin
			overrun_ev <= 1'b0;

			if (w_busy) begin
				w_i <= w_i + 4'd1;
				if (w_i == 4'd15) w_busy <= 1'b0;
			end

			if (line_start) begin
				overrun_ev <= (st != S_IDLE);
				wbank <= ~wbank;
				for (int i = 0; i < 3; i++) dxoff[i] <= rxoff[i];
				gfx_req <= 1'b0;   // an aborted fetch: the port shim completes it and drops it
				w_busy  <= 1'b0;
				layer   <= 2'd0;
				last_ok <= 1'b0;
				vu      <= 2'd0;
				nxt_ok  <= 1'b0;
				st      <= render_en ? S_ROW : S_IDLE;
			end else begin
				// ---- VRAM reader ----
				if (take) nxt_ok <= 1'b0;
				case (vu)
					2'd0: if ((st != S_IDLE && st != S_ROW) && !nxt_ok && kv != 5'd25) begin
						vram_addr <= {trow, 6'(tcol0 + 6'(kv)), 1'b0};
						vu <= 2'd1;
					end
					2'd1: begin vram_addr <= {trow, 6'(tcol0 + 6'(kv)), 1'b1}; vu <= 2'd2; end
					2'd2: begin nxt_tile <= 17'(vdata + 17'h18000); vu <= 2'd3; end      // the code word
					2'd3: begin                                                          // the attribute
						nxt_colour <= vdata[4:0];
						nxt_flip   <= vdata[7];
						nxt_ok     <= 1'b1;
						kv         <= kv + 5'd1;
						vu         <= 2'd0;
					end
				endcase

				case (st)
					S_ROW: begin               // the layer's row and first column
						trow  <= ypix[9:4];
						row   <= ypix[3:0];
						tcol0 <= xpix[9:4];
						rxoff[layer] <= 9'(xpix);
						k     <= 5'd0;
						kv    <= 5'd0;
						nxt_ok <= 1'b0;
						vu    <= 2'd0;
						last_ok <= 1'b0;
						st    <= S_TAKE;
					end
					S_TAKE: if (nxt_ok) begin
						tile   <= nxt_tile;
						colour <= nxt_colour;
						flip   <= nxt_flip;
						base   <= 9'({6'(tcol0 + 6'(k)), 4'd0});
						if (nxt_reuse) st <= S_REUSE;
						else begin
							gfx_req <= 1'b1;
							gfx_b   <= 1'b0;
							gfx_off <= {nxt_tile, row, 3'b000};
							st      <= S_A;
						end
					end
					S_A: if (gfx_valid) begin  // region A in; region B requested, req held
						ga      <= gfx_data;
						gfx_b   <= 1'b1;
						gfx_off <= {1'b0, tile, row[3:1], 3'b000};
						st      <= S_B;
					end
					S_B: if (gfx_valid && !w_busy) begin
						w_busy   <= 1'b1;
						w_i      <= 4'd0;
						w_layer  <= layer;
						w_base   <= base;
						w_colour <= colour;
						w_flip   <= flip;
						w_a      <= ga;
						w_b      <= row[0] ? gfx_data[63:32] : gfx_data[31:0];
						last_b   <= row[0] ? gfx_data[63:32] : gfx_data[31:0];
						last_tile <= tile;
						last_ok  <= 1'b1;
						if (k == 5'd24) begin
							gfx_req <= 1'b0;
							if (layer == 2'd2) st <= S_IDLE;
							else begin layer <= layer + 2'd1; st <= S_ROW; end
						end else begin
							k <= k + 5'd1;
							if (nxt_ok && !(last_ok_next(tile, nxt_tile))) begin
								// chain: the next tile's region A on the clock this data arrived
								tile    <= nxt_tile;
								colour  <= nxt_colour;
								flip    <= nxt_flip;
								base    <= 9'({6'(tcol0 + 6'(k + 5'd1)), 4'd0});
								gfx_b   <= 1'b0;
								gfx_off <= {nxt_tile, row, 3'b000};
								st      <= S_A;
							end else begin
								gfx_req <= 1'b0;
								st      <= S_TAKE;
							end
						end
					end
					S_REUSE: if (!w_busy) begin
						w_busy   <= 1'b1;
						w_i      <= 4'd0;
						w_layer  <= layer;
						w_base   <= base;
						w_colour <= colour;
						w_flip   <= flip;
						w_a      <= ga;
						w_b      <= last_b;
						if (k == 5'd24) begin
							if (layer == 2'd2) st <= S_IDLE;
							else begin layer <= layer + 2'd1; st <= S_ROW; end
						end else begin
							k  <= k + 5'd1;
							st <= S_TAKE;
						end
					end
					default: ;
				endcase
			end
		end
	end

	// The reader's tile is taken in S_TAKE, or chained from S_B when it is not a reuse of the
	// tile just fetched (a reuse goes through S_TAKE, which sees it).
	function automatic logic last_ok_next(input logic [16:0] cur, input logic [16:0] nxt);
		last_ok_next = (cur == nxt);
	endfunction
	assign take = !line_start && (((st == S_TAKE) && nxt_ok) ||
	              ((st == S_B) && gfx_valid && !w_busy && k != 5'd24 && nxt_ok && (tile != nxt_tile)));

endmodule
