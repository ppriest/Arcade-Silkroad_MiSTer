`timescale 1ns/1ps
// Elaboration/wiring smoke test for rtl/silkroad_core.sv -- NOT a functional
// test (see tb_silkroad_core.sv for that). This just ties off every external
// port with simple always-valid ROM stubs and confirms the whole design
// elaborates and runs a few thousand cycles with no X propagation /
// crashes, catching port-name/width wiring mistakes across the ~15-module
// integration before investing in a real CPU-program-driven test.
module tb_silkroad_core_smoke;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;
	logic ce_pix = 1'b1; // matches this project's existing video testbenches -- see docs/phase1_sdram_map.md's ce_pix note

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

	// Immediate-valid ROM stubs: CPU ROM returns NOP ($4E71) forever, gfx
	// ROMs return all-zero rows/entries. Enough to run the CPU/timing/
	// sequencing wiring without X propagation; not real graphics content.
	assign cpu_rom_valid = 1'b1;
	assign cpu_rom_data   = 16'h4E71;

	// graphics ROM stubbed to all-zero granules, a clock after each request (held requests):
	// inverted (ROMREGION_INVERT) that is pen 63 everywhere, so every layer is opaque
	always_ff @(posedge clk) begin
		tm_gfx_valid <= tm_gfx_req && !tm_gfx_valid;
		sp_gfx_valid <= sp_gfx_req && !sp_gfx_valid;
	end
	assign tm_gfx_data = 64'h0;
	assign sp_gfx_data = 64'h0;

	int cycles = 0;
	always @(posedge clk) cycles++;

	initial begin
		reset = 1;
		repeat (5) @(posedge clk);
		reset = 0;

		// Run past several full frames (456*262 = 119472 cycles/frame at
		// ce_pix=1) so frame_start/spriteram swap/render-kickoff sequencing
		// actually exercises, not just reset wiring.
		repeat (3 * 119472) @(posedge clk);

		$display("Ran %0d cycles with no crash -- silkroad_core wiring elaborates and runs clean", cycles);
		$finish;
	end

	// Watchdog: bail out loudly rather than hanging forever if something
	// is structurally wrong (matches this project's established caution
	// around ModelSim runs after the maincpu.sv crash investigation).
	initial begin
		#20_000_000; // 2M cycles at 10ns/cycle
		$display("FAIL: watchdog timeout, simulation did not finish");
		$finish;
	end

endmodule
