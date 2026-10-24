// SPDX-License-Identifier: GPL-3.0-or-later
//
// The board's sound (silkroad.cpp:461-473): a YM2151 (jt51) and two OKI M6295 (jt6295), no
// sound CPU; the 68020 writes them directly (maincpu.sv).
//
//   YM2151   3.579545 MHz crystal (464): a phase accumulator from clk_sys, 0x131745A9 / 2^32
//            of 48 MHz, 3579545.0 Hz; cen_p1 every second enable, as jt51 wants
//   OKI 1    32 MHz / 32 = 1 MHz (466), one enable in 48, pin 7 high; 0x20000-0x3FFFF banked by
//            the register at 0xC00034 (oki_map, 334-337; silkroad_sdram_top maps the address)
//   OKI 2    32 MHz / 16 = 2 MHz (471), one enable in 24, pin 7 high, not banked
//   Both OKI clocks and pin 7 are "not verified" in the driver.
//
// ROM: each OKI's address goes out as {bank, chip address}; oki_rom_bridge turns the chip's
// level interface into held fetches.
//
// Mix (464-473): the YM2151's left and right to the two speakers at 1.0, each OKI to both at
// 0.45. MAME's M6295 reaches full scale with one voice at full volume; jt6295 sums its four
// voices into 14 bits with a voice at 12, so an OKI counts x 16 x 0.45 = x 7.2, taken as x 7
// (shift and subtract; docs/HACKS.md). Summed and clamped to 16 bits per side.
module silkroad_sound (
	input  logic         clk,
	input  logic         reset,

	// maincpu: one-clock write strobes, and the read data
	input  logic         oki1_wr,
	input  logic         oki2_wr,
	input  logic         ym_wr,
	input  logic         ym_a0,
	input  logic [7:0]  wdata,
	output logic [7:0]  oki1_dout,
	output logic [7:0]  oki2_dout,
	output logic [7:0]  ym_dout,
	input  logic         oki1_bank_we,
	input  logic [1:0]  bank,

	// sample ROMs: {bank, chip address}, held req until valid
	output logic         oki1_rom_req,
	output logic [19:0] oki1_rom_addr,
	input  logic         oki1_rom_valid,
	input  logic [7:0]  oki1_rom_data,
	output logic         oki2_rom_req,
	output logic [19:0] oki2_rom_addr,
	input  logic         oki2_rom_valid,
	input  logic [7:0]  oki2_rom_data,

	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r
);
	// ---- clock enables ----
	logic [5:0]  div1;
	logic [4:0]  div2;
	logic        cen1, cen2;
	logic [31:0] acc_ym;
	logic        cen_ym, ym_half;
	always_ff @(posedge clk) begin
		if (reset) begin
			div1 <= 6'd0; div2 <= 5'd0; cen1 <= 1'b0; cen2 <= 1'b0;
			acc_ym <= 32'd0; cen_ym <= 1'b0; ym_half <= 1'b0;
		end else begin
			div1 <= (div1 == 6'd47) ? 6'd0 : div1 + 6'd1;
			cen1 <= (div1 == 6'd47);
			div2 <= (div2 == 5'd23) ? 5'd0 : div2 + 5'd1;
			cen2 <= (div2 == 5'd23);
			{cen_ym, acc_ym} <= {1'b0, acc_ym} + 33'h0_1317_45A9;
			if (cen_ym) ym_half <= ~ym_half;
		end
	end
	wire cen_ym_p1 = cen_ym && ym_half;

	// ---- YM2151 ----
	logic signed [15:0] ym_l, ym_r;
	jt51 u_ym (
		.rst(reset), .clk(clk), .cen(cen_ym), .cen_p1(cen_ym_p1),
		.cs_n(~ym_wr), .wr_n(~ym_wr), .a0(ym_a0), .din(wdata), .dout(ym_dout),
		.ct1(), .ct2(), .irq_n(), .sample(),
		.left(ym_l), .right(ym_r), .xleft(), .xright()
	);

	// ---- OKI 1's bank ----
	logic [1:0] oki1_bank;
	always_ff @(posedge clk) begin
		if (reset)             oki1_bank <= 2'd0;
		else if (oki1_bank_we) oki1_bank <= bank;
	end

	// okim6295::write ignores a start for a voice that is already playing; jt6295 restarts it.
	// So the second byte of a start reaches the chip with the busy voices masked off (dout[3:0]
	// is busy | start). The first/second byte state follows jt6295_ctrl's own.
	logic oki1_pend, oki2_pend;
	always_ff @(posedge clk) begin
		if (reset) begin
			oki1_pend <= 1'b0;
			oki2_pend <= 1'b0;
		end else begin
			if (oki1_wr) oki1_pend <= !oki1_pend && wdata[7];
			if (oki2_wr) oki2_pend <= !oki2_pend && wdata[7];
		end
	end
	wire [7:0] oki1_din = oki1_pend ? {wdata[7:4] & ~oki1_dout[3:0], wdata[3:0]} : wdata;
	wire [7:0] oki2_din = oki2_pend ? {wdata[7:4] & ~oki2_dout[3:0], wdata[3:0]} : wdata;

	logic [17:0] oki1_chip_addr, oki2_chip_addr;
	logic [7:0]  oki1_chip_data, oki2_chip_data;
	logic        oki1_chip_ok, oki2_chip_ok;
	logic signed [13:0] oki1_snd, oki2_snd;

	// jt6295 takes a write on the falling edge of wrn, sampled on clk; ss = pin 7
	jt6295 #(.INTERPOL(0)) u_oki1 (
		.rst(reset), .clk(clk), .cen(cen1), .ss(1'b1),
		.wrn(~oki1_wr), .din(oki1_din), .dout(oki1_dout),
		.rom_addr(oki1_chip_addr), .rom_data(oki1_chip_data), .rom_ok(oki1_chip_ok),
		.sound(oki1_snd), .sample()
	);
	oki_rom_bridge u_oki1_bridge (
		.clk(clk), .reset(reset),
		.rom_addr(oki1_chip_addr), .rom_data(oki1_chip_data), .rom_ok(oki1_chip_ok), .bank(oki1_bank),
		.req(oki1_rom_req), .addr(oki1_rom_addr), .valid(oki1_rom_valid), .data(oki1_rom_data)
	);

	jt6295 #(.INTERPOL(0)) u_oki2 (
		.rst(reset), .clk(clk), .cen(cen2), .ss(1'b1),
		.wrn(~oki2_wr), .din(oki2_din), .dout(oki2_dout),
		.rom_addr(oki2_chip_addr), .rom_data(oki2_chip_data), .rom_ok(oki2_chip_ok),
		.sound(oki2_snd), .sample()
	);
	oki_rom_bridge u_oki2_bridge (
		.clk(clk), .reset(reset),
		.rom_addr(oki2_chip_addr), .rom_data(oki2_chip_data), .rom_ok(oki2_chip_ok), .bank(2'd0),
		.req(oki2_rom_req), .addr(oki2_rom_addr), .valid(oki2_rom_valid), .data(oki2_rom_data)
	);

	// ---- mix ----
	logic signed [14:0] oki_sum;
	logic signed [18:0] oki_x7, sum_l, sum_r;
	function automatic logic signed [15:0] clamp16(input logic signed [18:0] v);
		clamp16 = (v > 19'sd32767) ? 16'sh7FFF : (v < -19'sd32768) ? 16'sh8000 : v[15:0];
	endfunction
	always_ff @(posedge clk) begin
		oki_sum <= oki1_snd + oki2_snd;
		oki_x7  <= ({{4{oki_sum[14]}}, oki_sum} <<< 3) - {{4{oki_sum[14]}}, oki_sum};
		sum_l   <= {{3{ym_l[15]}}, ym_l} + oki_x7;
		sum_r   <= {{3{ym_r[15]}}, ym_r} + oki_x7;
		audio_l <= clamp16(sum_l);
		audio_r <= clamp16(sum_r);
	end
endmodule
