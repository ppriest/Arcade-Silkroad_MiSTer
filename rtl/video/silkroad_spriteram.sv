// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sprite RAM (0x40C000-0x40CFFF, 2048 words, silkroad.cpp:317) and the snapshot the sprite
// line engine draws from.
//
// silkroad.cpp draws from live sprite RAM at vblank start (186); the game writes the list only
// in the first ten lines of vblank (docs/write_timing_mame.txt). copy_start, after those writes,
// copies the RAM to the snapshot one word a clock (copy_busy meanwhile; silkroad_core holds a
// 68020 sprite RAM write until it ends), so each displayed line pairs with the list MAME's frame
// uses. While copying, entry n's Y (word 4n + 1) and end marker (word 4n + 3, bits 15-8 = 0xFF,
// 212) go into a second table, so the scanner tests one word an entry while the fetcher reads
// whole entries from the snapshot.
module silkroad_spriteram (
	input  logic        clk,
	input  logic        reset,

	input  logic        copy_start,
	output logic        copy_busy,

	input  logic [10:0] cpu_addr,
	input  logic        cpu_wel, cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	// the snapshot: a word, a clock after the address
	input  logic [10:0] snap_addr,
	output logic [15:0] snap_data,
	// the Y table: {end of list, Y}, a clock after the address
	input  logic [8:0]  ytab_addr,
	output logic [16:0] ytab_data
);

	logic        copying, wr_en;
	logic [10:0] rd_a, wr_a;
	logic [15:0] live_q;
	logic [15:0] y_hold;

	assign copy_busy = copying | wr_en;

	dpram #(.ADDR_WIDTH(11), .DATA_WIDTH(16)) u_live (
		.clk(clk),
		.a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata),
		.b_addr(rd_a), .b_rdata(live_q)
	);

	dpram #(.ADDR_WIDTH(11), .DATA_WIDTH(16)) u_snap (
		.clk(clk),
		.a_addr(wr_a), .a_wel(wr_en), .a_weh(wr_en), .a_wdata(live_q), .a_rdata(),
		.b_addr(snap_addr), .b_rdata(snap_data)
	);

	wire ytab_we = wr_en && (wr_a[1:0] == 2'd3);
	dpram #(.ADDR_WIDTH(9), .DATA_WIDTH(17)) u_ytab (
		.clk(clk),
		.a_addr(wr_a[10:2]), .a_wel(ytab_we), .a_weh(ytab_we),
		.a_wdata({live_q[15:8] == 8'hFF, y_hold}), .a_rdata(),
		.b_addr(ytab_addr), .b_rdata(ytab_data)
	);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			copying <= 1'b0; wr_en <= 1'b0; rd_a <= 11'd0; wr_a <= 11'd0; y_hold <= 16'd0;
		end else begin
			wr_en <= 1'b0;
			if (wr_en && wr_a[1:0] == 2'd1) y_hold <= live_q;
			if (copy_start) begin
				copying <= 1'b1;
				rd_a    <= 11'd0;
			end else if (copying) begin
				wr_en <= 1'b1;
				wr_a  <= rd_a;
				if (rd_a == 11'h7FF) copying <= 1'b0;
				else                 rd_a    <= rd_a + 11'd1;
			end
		end
	end

endmodule
