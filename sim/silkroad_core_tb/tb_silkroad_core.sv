`timescale 1ns/1ps
// Real functional test for rtl/silkroad_core.sv: a genuine CPU program
// (test_video.s, assembled with vasm -- sim/silkroad_core_tb/test_video.hex)
// writes one tile into layer 0's VRAM, one palette entry, and layer 0's
// control word, then parks in a self-loop. The test then confirms the
// expected, distinctive palette color actually reaches the compositor's
// rgb output during real active-display scanout -- proving the whole
// chain (CPU bus -> maincpu.sv -> vram0 dpram -> tilemap_line_engine ->
// compositor -> palette dpram -> rgb) is wired correctly end-to-end, not
// just that it elaborates (see tb_silkroad_core_smoke.sv for that narrower
// check). Gfx ROMs are stubbed to an all-zero row (every tile pixel decodes
// as pen 0), same simplification tb_silkroad_core_smoke.sv uses -- real gfx
// ROM content is the SDRAM stack's job, not this integration test's.
module tb_silkroad_core;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;
	logic ce_pix = 1'b1;

	logic         cpu_rom_req;
	logic [18:0] cpu_rom_addr;
	logic         cpu_rom_valid;
	logic [15:0] cpu_rom_data;

	logic         tm_gfx_req, tm_gfx_b, sp_gfx_req, sp_gfx_b;
	logic [23:0] tm_gfx_off, sp_gfx_off;
	logic         tm_gfx_valid, sp_gfx_valid;
	logic [63:0] tm_gfx_data, sp_gfx_data;

	logic [8:0]  hcnt, vcnt;
	logic         hblank, vblank, hsync, vsync;
	logic [14:0] rgb;

	silkroad_core dut (
		// hiscore work-RAM port tied off (rtl/hiscore.v not in this TB)
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(), .hs_read(1'b0), .hs_write(1'b0),
		// debug/pause ports tied off
		.dbg_overlay(1'b0), .dbg_render_dis(4'd0), .pause(1'b0),
		.dbg_src(2'd0), .dbg_window(4'd0), .dbg_rearm(1'b0), .dbg_pixel(),
		.clk(clk), .ce_pix(ce_pix), .reset(reset), .video_reset(reset),
		.cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
		.cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
		.tm_gfx_req(tm_gfx_req), .tm_gfx_b(tm_gfx_b), .tm_gfx_off(tm_gfx_off),
		.tm_gfx_valid(tm_gfx_valid), .tm_gfx_data(tm_gfx_data),
		.sp_gfx_req(sp_gfx_req), .sp_gfx_b(sp_gfx_b), .sp_gfx_off(sp_gfx_off),
		.sp_gfx_valid(sp_gfx_valid), .sp_gfx_data(sp_gfx_data),
		.p1p2_in(32'hFFFFFFFF), .dsw_in(32'hFFFFFFFF), .flip(1'b0),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb)
	);

	// graphics ROM stubbed to all-zero granules, a clock after each request (held requests):
	// inverted (ROMREGION_INVERT) that is pen 63 everywhere, so every layer is opaque
	always_ff @(posedge clk) begin
		tm_gfx_valid <= tm_gfx_req && !tm_gfx_valid;
		sp_gfx_valid <= sp_gfx_req && !sp_gfx_valid;
	end
	assign tm_gfx_data = 64'h0;
	assign sp_gfx_data = 64'h0;

	// ---- CPU ROM model: 5-cycle req/valid latency, same style
	// sim/maincpu_tb/tb_maincpu.sv already used to verify maincpu.sv. ----
	localparam int ROM_LATENCY = 5;
	logic [15:0] rom [0:524287];
	logic         rom_busy;
	int           rom_cnt;

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			rom_busy       <= 1'b0;
			cpu_rom_valid <= 1'b0;
		end else begin
			cpu_rom_valid <= 1'b0;
			if (cpu_rom_req && !rom_busy) begin
				rom_busy <= 1'b1;
				rom_cnt   <= 0;
			end else if (rom_busy) begin
				if (rom_cnt == ROM_LATENCY - 1) begin
					cpu_rom_valid <= 1'b1;
					cpu_rom_data   <= rom[cpu_rom_addr];
					rom_busy        <= 1'b0;
				end else begin
					rom_cnt <= rom_cnt + 1;
				end
			end
		end
	end

	localparam int FRAME_CYCLES = 456 * 262; // 119472, matches video_timing.sv's raw timing

	int match_count = 0;
	logic [14:0] last_match_rgb;
	int match_hcnt, match_vcnt;

	initial begin
		reset = 1;
		for (int i = 0; i < 524288; i++) rom[i] = 16'h0000;

		// Reset vectors: SP=0x00FFFFFC (top of work RAM), PC=0x8 (start),
		// same convention as sim/maincpu_tb/tb_maincpu.sv.
		rom[0] = 16'h00FF; rom[1] = 16'hFFFC;
		rom[2] = 16'h0000; rom[3] = 16'h0008;

		$readmemh("sim/silkroad_core_tb/test_video.hex", rom, 4);

		repeat (5) @(posedge clk);
		reset = 0;

		// Let the CPU program (a handful of instructions) complete and let
		// 2 full frames elapse for margin, then sample real active-display
		// scanout during frame 3.
		repeat (2 * FRAME_CYCLES) @(posedge clk);

		// Confirm the CPU program's writes actually landed where expected
		// before checking the rendered pixel -- narrows a future failure
		// here to "CPU bus/decode" vs. "video pipeline" immediately.
		$display("CHECK vram0[0]=%h (expect 0000) palette[0x03F]=%h (expect 1234)",
				   dut.u_vram0.mem[0], dut.u_palette.mem[12'h03F]);

		// Directly scan hcnt/vcnt for the expected tile-origin window
		// across one full active frame, sampling rgb every cycle.
		for (int i = 0; i < FRAME_CYCLES; i++) begin
			@(posedge clk);
			#1;
			if (!hblank && !vblank && hcnt < 9'd32 && vcnt < 9'd32) begin
				if (rgb === 15'h1234) begin
					match_count++;
					last_match_rgb = rgb;
					match_hcnt = hcnt;
					match_vcnt = vcnt;
				end
			end
		end

		if (match_count > 0) begin
			$display("PASS: rgb=0x1234 observed %0d time(s) in the expected tile-origin window (e.g. hcnt=%0d vcnt=%0d) -- full CPU write -> VRAM -> tilemap engine -> compositor -> palette -> rgb path verified",
					   match_count, match_hcnt, match_vcnt);
		end else begin
			$display("FAIL: expected rgb=0x1234 was never observed in the tile-origin window (hcnt<32, vcnt<32)");
		end

		$finish;
	end

	initial begin
		#40_000_000; // watchdog
		$display("FAIL: watchdog timeout, simulation did not finish");
		$finish;
	end

endmodule
