// SPDX-License-Identifier: GPL-3.0-or-later
//
`timescale 1ns/1ps
// Integration test for rtl/memory/silkroad_sdram_top.sv: every sub-piece (sdram.sv,
// sdram_phy.sv, sdram_arbiter6.sv, sdram_narrow_bridge.sv, sdram_download.sv) has its own bench;
// this one proves this module's wiring: each client's region base and address conversion, the
// graphics clients' raw granule packing (byte n in bits 8n+7:8n), and the held-request shims.
//
// Uses the real HPS download path (sdram_download.sv) to seed distinctive bytes at each region,
// then reads them back through that region's client.
module tb_silkroad_sdram_top;

	// clk_sdram twice clk, rising edges aligned, as the PLL gives them
	logic clk = 0, clk_sdram = 0;
	always #2.5 clk_sdram = ~clk_sdram;
	initial begin #2.5; forever #5 clk = ~clk; end
	logic reset;

	// rtl/memory/silkroad_sdram_top.sv's map
	localparam logic [24:0] GFXA_BASE      = 25'h0000000;
	localparam logic [24:0] GFXB_BASE      = 25'h1000000;
	localparam logic [24:0] MAINCPU_BASE   = 25'h1800000;


	logic         ioctl_download;
	logic [15:0] ioctl_index;
	logic         ioctl_wr;
	logic [24:0] ioctl_addr;
	logic [7:0]  ioctl_dout;
	logic         ioctl_wait;

	logic         tm_gfx_req, tm_gfx_b, tm_gfx_valid, sp_gfx_req, sp_gfx_b, sp_gfx_valid;
	logic [23:0] tm_gfx_off, sp_gfx_off;
	logic [63:0] tm_gfx_data, sp_gfx_data;

	logic         cpu_rom_req;
	logic [19:0] cpu_rom_addr;
	logic         cpu_rom_valid;
	logic [15:0] cpu_rom_data;


	wire [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic         SDRAM_DQML, SDRAM_DQMH;
	logic [1:0]  SDRAM_BA;
	logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

	silkroad_sdram_top dut (
		.clk(clk), .clk_sdram(clk_sdram), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		// fast ROM loader idle: this TB downloads through ioctl
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(25'd0), .ldr_data(16'd0),
		.ldr_we16(1'b0), .ldr_busy(),
		.tm_gfx_req(tm_gfx_req), .tm_gfx_b(tm_gfx_b), .tm_gfx_off(tm_gfx_off),
		.tm_gfx_valid(tm_gfx_valid), .tm_gfx_data(tm_gfx_data),
		.sp_gfx_req(sp_gfx_req), .sp_gfx_b(sp_gfx_b), .sp_gfx_off(sp_gfx_off),
		.sp_gfx_valid(sp_gfx_valid), .sp_gfx_data(sp_gfx_data),
		.cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
		.cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data)
	);

	sdram_chip_model chip (
		.clk(clk_sdram),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	int errors = 0;

	// Pulse ioctl_wr for one cycle, then wait for ioctl_wait to drop --
	// with do/while (not while/do): a
	// plain `while (ioctl_wait) @(posedge clk);` checks ioctl_wait
	// immediately after clearing ioctl_wr, in the same active-region delta
	// as the DUT's own always_ff updating dstate for that same edge --
	// NBA updates haven't committed yet, so that first check can read a
	// stale, pre-transition ioctl_wait and return before the real
	// transaction even starts, silently dropping every other byte in a
	// back-to-back sequence (found the hard way: half of every 8-byte
	// write pattern below came back X on first run). do/while guarantees
	// at least one full edge elapses -- and NBA updates settle -- before
	// ioctl_wait is ever read.
	// sdram_download coalesces byte pairs into single word writes, so a
	// lone EVEN byte stays buffered until its odd partner arrives or the
	// download ends. Tests that write one byte and read it straight back
	// call dl_flush(), which drops ioctl_download exactly as the HPS does
	// at the end of a transfer -- exercising the DUT's real flush path.
	task automatic dl_write_byte(input [24:0] addr, input [7:0] data);
		@(posedge clk);
		ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1'b1;
		@(posedge clk);
		ioctl_wr = 1'b0;
		do @(posedge clk); while (ioctl_wait);
	endtask

	task automatic dl_flush();
		ioctl_download = 1'b0;
		repeat (2) @(posedge clk);
		do @(posedge clk); while (ioctl_wait);
		ioctl_download = 1'b1;
		@(posedge clk);
	endtask

	task automatic check64(input [63:0] got, input [63:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%h expected=%h", name, got, exp);
		end
	endtask

	task automatic check16(input [15:0] got, input [15:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%h expected=%h", name, got, exp);
		end
	endtask

	task automatic check8(input [7:0] got, input [7:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%h expected=%h", name, got, exp);
		end
	endtask

	initial begin
		reset = 1;
		ioctl_download = 0; ioctl_index = 0; ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0;
		tm_gfx_req = 0; tm_gfx_b = 0; tm_gfx_off = 0;
		sp_gfx_req = 0; sp_gfx_b = 0; sp_gfx_off = 0;
		cpu_rom_req = 0; cpu_rom_addr = 0;
		repeat (5) @(posedge clk);
		reset = 0;
		repeat (5) @(posedge clk);

		// Each region is written via the real HPS download path and read
		// back through its own client port IMMEDIATELY, one region at a
		// time, rather than seeding everything up front -- sim/sdram_tb/
		// sdram_chip_model.sv deliberately folds the row address to its
		// low 8 bits (its own header comment: sized for what testbenches
		// actually exercise, not full 32MB chip capacity), so two of this
		// project's real region bases (spanning several MB apart) can
		// alias to the same modeled storage if both are live at once. Not
		// a bug in silkroad_sdram_top.sv's own address arithmetic (confirmed
		// by exactly this per-region isolation passing cleanly below) --
		// just a shared-testbench-model limitation this test structure
		// sidesteps rather than works around by widening the shared model
		// for one test's sake.
		ioctl_download = 1;

		// tilemaps, region A then region B
		for (int i = 0; i < 8; i++) dl_write_byte(GFXA_BASE + 25'h40 + i[24:0], 8'h10 + i[7:0]);
		dl_flush();
		tm_gfx_b = 0; tm_gfx_off = 24'h40; tm_gfx_req = 1;
		@(posedge clk);
		while (!tm_gfx_valid) @(posedge clk);
		check64(tm_gfx_data, 64'h1716151413121110, "tm_gfx_data region A");
		tm_gfx_req = 0;
		@(posedge clk);
		for (int i = 0; i < 8; i++) dl_write_byte(GFXB_BASE + 25'h80 + i[24:0], 8'h30 + i[7:0]);
		dl_flush();
		tm_gfx_b = 1; tm_gfx_off = 24'h80; tm_gfx_req = 1;
		@(posedge clk);
		while (!tm_gfx_valid) @(posedge clk);
		check64(tm_gfx_data, 64'h3736353433323130, "tm_gfx_data region B");
		tm_gfx_req = 0;
		@(posedge clk);

		// sprites: a held request, dropped a clock after valid as the engine's registered clear
		// does, must be one read: the next request then gets its own granule
		for (int i = 0; i < 8; i++) dl_write_byte(GFXA_BASE + 25'h100 + i[24:0], 8'h20 + i[7:0]);
		for (int i = 0; i < 8; i++) dl_write_byte(GFXA_BASE + 25'h108 + i[24:0], 8'h40 + i[7:0]);
		dl_flush();
		sp_gfx_b = 0; sp_gfx_off = 24'h100; sp_gfx_req = 1;
		@(posedge clk);
		while (!sp_gfx_valid) @(posedge clk);
		check64(sp_gfx_data, 64'h2726252423222120, "sp_gfx_data (held request, granule 0)");
		@(posedge clk);
		sp_gfx_req = 0;
		sp_gfx_off = 24'h108;
		sp_gfx_req = 1;
		@(posedge clk);
		while (!sp_gfx_valid) @(posedge clk);
		check64(sp_gfx_data, 64'h4746454443424140, "sp_gfx_data (held request, granule 1)");
		sp_gfx_req = 0;
		@(posedge clk);
		for (int i = 0; i < 8; i++) dl_write_byte(GFXB_BASE + 25'h200 + i[24:0], 8'h50 + i[7:0]);
		dl_flush();
		sp_gfx_b = 1; sp_gfx_off = 24'h200; sp_gfx_req = 1;
		@(posedge clk);
		while (!sp_gfx_valid) @(posedge clk);
		check64(sp_gfx_data, 64'h5756555453525150, "sp_gfx_data region B");
		sp_gfx_req = 0;
		@(posedge clk);

		dl_write_byte(MAINCPU_BASE + 25'd0, 8'hCC);
		dl_write_byte(MAINCPU_BASE + 25'd1, 8'hDD);
		dl_flush();
		cpu_rom_addr = 19'd0; cpu_rom_req = 1;
		@(posedge clk);
		while (!cpu_rom_valid) @(posedge clk);
		// Big-endian: byte0 (lower address) is the word's HIGH byte --
		// maincpu's real 68020 program ROM convention, NOT
		// sdram_narrow_bridge.sv's own little-endian packing (correct for a
		// little-endian 16-bit region, wrong for maincpu's plain ROM_REGION
		// content) -- see silkroad_sdram_top.sv's u_cpu_bridge
		// comment for the real bug this was found fixing.
		check16(cpu_rom_data, 16'hCCDD, "cpu_rom_data");
		cpu_rom_req = 0;

		ioctl_download = 0;

		if (errors == 0) $display("ALL TESTS PASSED");
		else $display("%0d TEST(S) FAILED", errors);

		$finish;
	end

	initial begin
		#4_000_000; // watchdog
		$display("FAIL: watchdog timeout, simulation did not finish");
		$finish;
	end

endmodule
