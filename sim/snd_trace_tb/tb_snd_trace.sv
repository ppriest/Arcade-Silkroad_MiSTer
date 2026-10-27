// SPDX-License-Identifier: GPL-3.0-or-later
//
`timescale 1ns/1ps
// A window of MAME's sound-chip writes replayed through silkroad_sound and the real SDRAM path
// (the OKIs' sample ROMs from the .mra image), the stereo mix recorded at 48 kHz for
// scripts/snd_trace.py --compare.
//
// <DIR>/window_events.txt: "clk kind value", 48 MHz, kind oki1, oki2, bank, yma, ymd
// (scripts/snd_trace.py). The window starts at the clk in <DIR>/window.txt's third field.
// RUN FROM THE REPOSITORY ROOT, after python scripts/snd_trace.py ... --window START SECONDS:
//     scripts/run_sim.sh snd_trace_tb +DIR=debug/snd_trace/play +IMG=debug/silkroad-image.sdram +START=n +N=96000
// Writes <DIR>/rtl_window.txt: "left right", one line every 1,000 clk from the window start.
module tb_snd_trace;
	localparam real HALF = 10.4167;     // 48 MHz
	// clk_sdram twice clk, rising edges aligned, as the PLL gives them
	logic clk = 0, clk_sdram = 0;
	always #(HALF / 2) clk_sdram = ~clk_sdram;
	initial begin #(HALF / 2); forever #(HALF) clk = ~clk; end
	logic reset = 1;

	wire  [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
	logic [1:0]  SDRAM_BA;

	logic         oki1_req, oki2_req, oki1_valid, oki2_valid;
	logic [19:0] oki1_addr, oki2_addr;
	logic [7:0]  oki1_data, oki2_data;

	silkroad_sdram_top u_sdram (
		.clk(clk), .clk_sdram(clk_sdram), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(25'd0),
		.ioctl_dout(8'd0), .ioctl_wait(),
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(25'd0), .ldr_data(16'd0), .ldr_we16(1'b0), .ldr_busy(),
		.tm_gfx_req(1'b0), .tm_gfx_b(1'b0), .tm_gfx_off(24'd0), .tm_gfx_valid(), .tm_gfx_data(),
		.sp_gfx_req(1'b0), .sp_gfx_b(1'b0), .sp_gfx_off(24'd0), .sp_gfx_valid(), .sp_gfx_data(),
		.cpu_rom_req(1'b0), .cpu_rom_addr(20'd0), .cpu_rom_valid(), .cpu_rom_data(),
		.oki1_rom_req(oki1_req), .oki1_rom_addr(oki1_addr), .oki1_rom_valid(oki1_valid), .oki1_rom_data(oki1_data),
		.oki2_rom_req(oki2_req), .oki2_rom_addr(oki2_addr), .oki2_rom_valid(oki2_valid), .oki2_rom_data(oki2_data)
	);

	sdram_chip_model_wide u_chip (
		.clk(clk_sdram),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	logic        wr1 = 0, wr2 = 0, ymw = 0, yma0 = 0, bwe = 0;
	logic [7:0]  wdata = 0;
	logic [1:0]  bank = 0;
	logic signed [15:0] audio_l, audio_r;

	silkroad_sound u_snd (
		.clk(clk), .reset(reset),
		.oki1_wr(wr1), .oki2_wr(wr2), .ym_wr(ymw), .ym_a0(yma0), .wdata(wdata),
		.oki1_dout(), .oki2_dout(), .ym_dout(),
		.oki1_bank_we(bwe), .bank(bank),
		.oki1_rom_req(oki1_req), .oki1_rom_addr(oki1_addr), .oki1_rom_valid(oki1_valid), .oki1_rom_data(oki1_data),
		.oki2_rom_req(oki2_req), .oki2_rom_addr(oki2_addr), .oki2_rom_valid(oki2_valid), .oki2_rom_data(oki2_data),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	longint t = 0, start = 0;
	logic   running = 0;
	always @(posedge clk) if (running) t <= t + 1;

	int fo, nsamp = 0, nmax = 96000;
	always @(posedge clk) if (running && t >= start && (t - start) % 1000 == 0 && nsamp < nmax) begin
		$fwrite(fo, "%0d %0d\n", audio_l, audio_r);
		nsamp <= nsamp + 1;
	end

	initial begin
		string dir, img, kind;
		int    f, n, fe, value;
		longint at;
		if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR missing");
		if (!$value$plusargs("IMG=%s", img)) $fatal(1, "+IMG missing");
		void'($value$plusargs("N=%d", nmax));
		void'($value$plusargs("START=%d", start));
		f = $fopen(img, "rb");
		if (f == 0) $fatal(1, "cannot open %s", img);
		n = $fread(u_chip.mem, f);
		$fclose(f);
		fe = $fopen({dir, "/window_events.txt"}, "r");
		if (fe == 0) $fatal(1, "cannot open %s/window_events.txt", dir);
		fo = $fopen({dir, "/rtl_window.txt"}, "w");

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (2000) @(posedge clk);           // sdram.sv's power-up sequence
		@(negedge clk);
		running = 1;
		while ($fscanf(fe, "%d %s %d\n", at, kind, value) == 3) begin
			while (t < at) @(negedge clk);
			wdata = 8'(value);
			if (kind == "bank")      begin bank = 2'(value >> 0); bwe = (value[1:0] != 2'd3); end
			else if (kind == "oki1") wr1 = 1'b1;
			else if (kind == "oki2") wr2 = 1'b1;
			else if (kind == "yma")  begin ymw = 1'b1; yma0 = 1'b0; end
			else if (kind == "ymd")  begin ymw = 1'b1; yma0 = 1'b1; end
			@(negedge clk);
			{wr1, wr2, ymw, bwe} = 4'b0000;
		end
		$fclose(fe);
		wait (nsamp >= nmax);
		$fclose(fo);
		$display("%0d samples recorded to %s/rtl_window.txt", nsamp, dir);
		$finish;
	end
endmodule
