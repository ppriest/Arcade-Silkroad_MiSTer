// SPDX-License-Identifier: GPL-3.0-or-later
//
// silkroad.cpp's sprites (draw_sprites, 192-232) drawn a line ahead into a double-buffered line
// buffer, from silkroad_spriteram's snapshot.
//
// An entry is two longs: X (word 0, bits 8-0), Y (word 1), tile (word 2) and attr (word 3: bit
// 15 tile bit 16, 12 priority, 11-8 width - 1, 7 flip X, 5-0 colour); the list ends at the
// first entry whose attr bits 15-8 are 0xFF. A strip of width tiles, one tall: tile k of it at
// bitmap X + 8 + 16k, Y to Y + 15, tile number + k, or + (width - 1 - k) mirrored when flipped.
// Screen pixel x is bitmap X - 50, line y bitmap Y - 16 (454).
//
// MAME's pixel op (prio_transpen, emu/drawgfxt.ipp 189-200) lets the first opaque sprite pixel
// at a position claim it, shown or hidden by the layers: so each position here keeps the first
// opaque pixel, {priority, colour, pen}, and the compositor decides whether it shows.
//
// The scanner tests one entry a clock from the Y table; hits queue for the fetcher, which reads
// the entry's other words, then each tile row in view (a region A granule and half a region B
// granule, as silkroad_tilemaps), and hands the 16 pixels to a writer.
module silkroad_sprites (
	input  logic        clk,
	input  logic        reset,

	input  logic        line_start,
	input  logic        render_en,
	input  logic [7:0]  render_line,

	output logic [10:0] snap_addr,
	input  logic [15:0] snap_data,
	output logic [8:0]  ytab_addr,
	input  logic [16:0] ytab_data,

	output logic        gfx_req,
	output logic        gfx_b,
	output logic [23:0] gfx_off,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_data,

	input  logic [8:0]  rd_x,
	output logic        sp_valid,       // a sprite claimed this position
	output logic [12:0] sp_px,          // {priority, colour[5:0], pen[5:0]}

	output logic        busy,
	output logic        overrun_ev
);

	localparam int W = 380;

	// ---- line buffer and the claimed-position bits ----
	logic         wbank;
	logic [511:0] taken [0:1];
	logic         lb_we;
	logic [8:0]   lb_waddr;
	logic [12:0]  lb_wdata;

	dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(13)) u_lb (
		.clk(clk),
		.a_addr({wbank, lb_waddr}), .a_wel(lb_we), .a_weh(lb_we), .a_wdata(lb_wdata), .a_rdata(),
		.b_addr({~wbank, rd_x}), .b_rdata(sp_px)
	);
	always_ff @(posedge clk) sp_valid <= taken[~wbank][rd_x];

	function automatic logic [1:0] pair(input logic [31:0] b, input logic [3:0] x);
		logic [7:0] lo, hi;
		lo = x[3] ? b[23:16] : b[7:0];
		hi = x[3] ? b[31:24] : b[15:8];
		pair = {hi[3'd7 - x[2:0]], lo[3'd7 - x[2:0]]};
	endfunction

	// render_line is sampled at line_start: vcnt moves on 132 pixels later, mid-render
	logic [7:0] rline;
	always_ff @(posedge clk) if (line_start) rline <= render_line;
	wire [16:0] yline = 17'({1'b0, rline} + 9'd16);

	// ---- scanner: one Y-table entry a clock, hits into the queue ----
	logic        sc_run, sc_done;
	logic [9:0]  sc_issue;             // next entry to address (512 = past the end)
	logic        q_v;                  // ytab_data valid for entry q_n this clock
	logic [8:0]  q_n;
	logic [12:0] fifo [0:15];          // {entry, row}
	logic [4:0]  f_wr, f_rd;
	wire  [4:0]  f_cnt = f_wr - f_rd;
	wire         f_full = (f_cnt >= 5'd14);   // room for the two results in flight
	wire  [16:0] dy = yline - {1'b0, ytab_data[15:0]};
	wire         q_end = ytab_data[16];
	wire         q_hit = (dy < 17'd16);

	assign ytab_addr = sc_issue[8:0];

	// ---- fetcher ----
	typedef enum logic [3:0] {F_IDLE, F_W0, F_W2, F_W3, F_CAP, F_TILE, F_A, F_B, F_NEXT} fstate_t;
	fstate_t fs;
	logic [8:0]  e_n;
	logic [3:0]  e_row;
	logic [8:0]  e_x;
	logic [16:0] e_tile;
	logic [3:0]  e_wm1;
	logic        e_flip, e_pri;
	logic [5:0]  e_colour;
	logic [3:0]  e_k;
	logic [63:0] ga;
	logic [15:0] w0q, w2q;
	logic [1:0]  cap_cnt;

	wire signed [11:0] px = $signed({3'b000, e_x}) + 12'sd8 + $signed({4'b0, e_k, 4'b0000}) - 12'sd50;
	wire               in_view = (px > -12'sd16) && (px < 12'sd380);
	wire        [16:0] tnum = 17'(e_tile + {13'd0, e_flip ? 4'(e_wm1 - e_k) : e_k});

	// ---- writer ----
	logic        w_busy;
	logic [3:0]  w_i;
	logic signed [11:0] w_px;
	logic        w_flip, w_pri;
	logic [5:0]  w_colour;
	logic [63:0] w_a;
	logic [31:0] w_b;
	wire  [3:0]  w_x   = w_flip ? 4'(15 - w_i) : w_i;
	wire  [5:0]  w_pen = ~{pair(w_a[31:0], w_x), pair(w_a[63:32], w_x), pair(w_b, w_x)};
	wire signed [11:0] w_sx = w_px + $signed({8'd0, w_i});
	wire         w_in  = (w_sx >= 0) && (w_sx < W);
	wire  [8:0]  w_pos = w_sx[8:0];

	assign lb_we    = w_busy && w_in && (w_pen != 6'd0) && !taken[wbank][w_pos];
	assign lb_waddr = w_pos;
	assign lb_wdata = {w_pri, w_colour, w_pen};

	assign busy = sc_run || (fs != F_IDLE) || w_busy || (f_cnt != 5'd0);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			wbank <= 1'b0; taken[0] <= '0; taken[1] <= '0;
			sc_run <= 1'b0; sc_done <= 1'b1; sc_issue <= 10'd0; q_v <= 1'b0; q_n <= 9'd0;
			f_wr <= 5'd0; f_rd <= 5'd0; fs <= F_IDLE; gfx_req <= 1'b0; w_busy <= 1'b0;
			overrun_ev <= 1'b0;
		end else begin
			overrun_ev <= 1'b0;

			// writer
			if (lb_we) taken[wbank][w_pos] <= 1'b1;
			if (w_busy) begin
				w_i <= w_i + 4'd1;
				if (w_i == 4'd15) w_busy <= 1'b0;
			end

			if (line_start) begin
				overrun_ev <= busy;
				wbank <= ~wbank;
				taken[~wbank] <= '0;            // the bank rendered next
				sc_run   <= render_en;
				sc_issue <= 10'd0;
				q_v      <= 1'b0;
				f_wr <= 5'd0; f_rd <= 5'd0;
				fs <= F_IDLE; gfx_req <= 1'b0; w_busy <= 1'b0;
			end else begin
				// ---- scanner ----
				q_v <= 1'b0;
				if (sc_run) begin
					if (q_v && q_end) begin
						sc_run <= 1'b0;                          // end of list (212)
					end else if (q_v && q_hit && f_full) begin
						sc_issue <= {1'b0, q_n};                 // replay from this entry
					end else begin
						if (q_v && q_hit) begin
							fifo[f_wr[3:0]] <= {q_n, dy[3:0]};
							f_wr <= f_wr + 5'd1;
						end
						if (sc_issue == 10'd512) begin
							if (!q_v) sc_run <= 1'b0;
						end else begin
							q_v      <= 1'b1;
							q_n      <= sc_issue[8:0];
							sc_issue <= sc_issue + 10'd1;
						end
					end
				end

				// ---- fetcher ----
				case (fs)
					F_IDLE: if (f_cnt != 5'd0) begin
						{e_n, e_row} <= fifo[f_rd[3:0]];
						f_rd <= f_rd + 5'd1;
						fs <= F_W0;
					end
					F_W0: begin snap_addr <= {e_n, 2'd0}; fs <= F_W2; end
					F_W2: begin snap_addr <= {e_n, 2'd2}; fs <= F_W3; end
					F_W3: begin snap_addr <= {e_n, 2'd3}; w0q <= snap_data; fs <= F_CAP; end   // word 0
					F_CAP: begin w2q <= snap_data; fs <= F_TILE; cap_cnt <= 2'd0; end          // word 2
					F_TILE: begin                                                                // word 3
						e_x      <= w0q[8:0];
						e_tile   <= {snap_data[15], w2q};
						e_wm1    <= snap_data[11:8];
						e_pri    <= snap_data[12];
						e_flip   <= snap_data[7];
						e_colour <= snap_data[5:0];
						e_k      <= 4'd0;
						fs       <= F_NEXT;
					end
					F_NEXT: begin                                // tile e_k of the strip
						if (in_view) begin
							gfx_req <= 1'b1;
							gfx_b   <= 1'b0;
							gfx_off <= {tnum, e_row, 3'b000};
							fs      <= F_A;
						end else if (e_k == e_wm1) fs <= F_IDLE;
						else e_k <= e_k + 4'd1;
					end
					F_A: if (gfx_valid) begin
						ga      <= gfx_data;
						gfx_req <= 1'b0;
						fs      <= F_B;
					end
					F_B: begin
						if (!gfx_req) begin
							gfx_req <= 1'b1;
							gfx_b   <= 1'b1;
							gfx_off <= {1'b0, tnum, e_row[3:1], 3'b000};
						end else if (gfx_valid && !w_busy) begin
							gfx_req  <= 1'b0;
							w_busy   <= 1'b1;
							w_i      <= 4'd0;
							w_px     <= px;
							w_flip   <= e_flip;
							w_pri    <= e_pri;
							w_colour <= e_colour;
							w_a      <= ga;
							w_b      <= e_row[0] ? gfx_data[63:32] : gfx_data[31:0];
							if (e_k == e_wm1) fs <= F_IDLE;
							else begin e_k <= e_k + 4'd1; fs <= F_NEXT; end
						end
					end
					default: fs <= F_IDLE;
				endcase
			end
		end
	end

endmodule
