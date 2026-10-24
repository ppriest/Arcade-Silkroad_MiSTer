`timescale 1ns/1ps
// Self-checking test of rtl/video/crt_chain.sv on the video_timing raster,
// sampled the way arcade_video samples it.
//   $ verilator --binary --timing -Wno-fatal --top-module tb_crt_chain \
//       sim/crt_chain_tb/tb_crt_chain.sv rtl/video/video_timing.sv \
//       rtl/video/crt_chain.sv rtl/video/crt_vsize.sv rtl/video/crt_adjust.sv
//   $ obj_dir/Vtb_crt_chain
module tb_crt_chain;

	logic clk = 0;
	always #5 clk = ~clk;

	logic [3:0] ce_cnt = 0;
	wire ce_pix = (ce_cnt == 0);
	always_ff @(posedge clk) ce_cnt <= (ce_cnt == 11) ? 4'd0 : ce_cnt + 4'd1;

	logic [8:0] hcnt, vcnt;
	logic       hblank, vblank, hsync, vsync;
	video_timing u_timing (
		.clk(clk), .ce_pix(ce_pix), .reset(1'b0),
		.hcnt(hcnt), .vcnt(vcnt), .vcnt_active(), .vcnt_next_active(), .vcnt_next2_active(),
		.h_active(), .v_active(), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .line_start(), .frame_start()
	);

	wire act_in = ~(hblank | vblank);

	logic              active = 0, scale_en = 1, cabinet = 0;
	logic signed [8:0] hoffset = 0;
	logic signed [5:0] voffset = 0;
	logic signed [4:0] hsize = 0;
	logic signed [3:0] vsize_step = 0;

	logic       ce;
	logic [7:0] r, g, b;
	logic       hs, vs, hb, vb;

	crt_chain dut (
		.clk(clk), .ce_pix(ce_pix),
		.active(active), .scale_en(scale_en),
		.hoffset(hoffset), .voffset(voffset), .hsize(hsize),
		.vsize_step(vsize_step), .vsize_cabinet(cabinet),
		.r_in(act_in ? hcnt[7:0] : 8'd0), .g_in(act_in ? vcnt[7:0] : 8'd0),
		.b_in(act_in ? 8'h5A : 8'd0),
		.hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),
		.ce_out(ce), .r_out(r), .g_out(g), .b_out(b),
		.hs_out(hs), .vs_out(vs), .hb_out(hb), .vb_out(vb)
	);

	logic av_hbl = 1, av_vbl = 1;
	always_ff @(posedge clk) if (ce) begin
		av_hbl <= hb;
		if (av_hbl & ~hb) av_vbl <= vb;
	end
	wire pic = ~hb & ~((av_hbl & ~hb) ? vb : av_vbl);

	int clk_n = 0;
	always_ff @(posedge clk) clk_n <= clk_n + 1;

	logic old_hs = 0, old_vs = 0, old_pic = 0, line_has_pic = 0;
	logic [7:0] exp_r;
	int lines, pic_lines, px, pic_start, line_start;
	int px_min, px_max, w_min, w_max, per_min, per_max, bad, g_first, g_last;
	int frames = 0;
	int f_lines, f_pic_lines, f_px_min, f_px_max, f_w_min, f_w_max;
	int f_per_min, f_per_max, f_bad, f_g_first, f_g_last;

	task automatic new_frame;
		lines = 0; pic_lines = 0; bad = 0; g_first = -1; g_last = -1;
		px_min = 1 << 30; px_max = 0; w_min = 1 << 30; w_max = 0;
		per_min = 1 << 30; per_max = 0;
	endtask
	initial begin new_frame(); line_start = 0; end

	always @(posedge clk) if (ce) begin
		old_hs <= hs; old_vs <= vs; old_pic <= pic;
		if (hs & ~old_hs) begin
			if (line_start != 0) begin
				per_min = (clk_n - line_start < per_min) ? clk_n - line_start : per_min;
				per_max = (clk_n - line_start > per_max) ? clk_n - line_start : per_max;
			end
			line_start = clk_n;
			lines++;
			if (line_has_pic) pic_lines++;
			line_has_pic = 0;
		end
		if (pic & ~old_pic) begin
			if (g_first < 0) g_first = int'(g);
			g_last = int'(g); pic_start = clk_n; px = 0; exp_r = r;
		end
		if (pic) begin
			px++; line_has_pic = 1;
			if (r != exp_r || b != 8'h5A) bad++;
			exp_r = r + 8'd1;
		end
		if (~pic & old_pic) begin
			w_min  = (clk_n - pic_start < w_min) ? clk_n - pic_start : w_min;
			w_max  = (clk_n - pic_start > w_max) ? clk_n - pic_start : w_max;
			px_min = (px < px_min) ? px : px_min;
			px_max = (px > px_max) ? px : px_max;
		end
		if (vs & ~old_vs) begin
			f_lines = lines; f_pic_lines = pic_lines; f_bad = bad;
			f_px_min = px_min; f_px_max = px_max; f_w_min = w_min; f_w_max = w_max;
			f_per_min = per_min; f_per_max = per_max;
			f_g_first = g_first; f_g_last = g_last;
			frames++;
			new_frame();
		end
	end

	int fails = 0;

	// Checks the last of `n` frames; -1 = don't care.
	task automatic check(string name, int n, int e_lines, int e_pic, int e_px,
	                     int e_w, int e_per, int e_gf, int e_gl);
		int f0 = frames;
		bit ok;
		wait (frames >= f0 + n);
		ok = (e_lines < 0 || f_lines == e_lines) && (e_pic < 0 || f_pic_lines == e_pic)
		  && (f_px_min == f_px_max) && (e_px < 0 || f_px_max == e_px)
		  && (e_w < 0 || f_w_max == e_w) && (f_bad == 0)
		  && (f_per_max - f_per_min <= 1) && (e_per < 0 || f_per_min == e_per)
		  && (e_gf < 0 || f_g_first == e_gf) && (e_gl < 0 || f_g_last == e_gl);
		$display("%s %-28s lines=%0d pic_lines=%0d px=%0d..%0d w=%0d..%0d period=%0d..%0d bad=%0d src=%0d..%0d",
			ok ? "PASS" : "FAIL", name, f_lines, f_pic_lines, f_px_min, f_px_max,
			f_w_min, f_w_max, f_per_min, f_per_max, f_bad, f_g_first, f_g_last);
		if (!ok) fails++;
	endtask

	initial begin
		//            name                   frames lines pic  px   w     period src
		check("off (native)",                 3, 262, 224, 320, 3840, 5472, 0, 223);
		active = 1;
		check("on, all zero",                 3, 262, 223, 320, 3840, 5472, 1, 223);
		hoffset = -1;
		check("H-Position -1",                3, 262, 223, 320, 3840, 5472, 1, 223);
		hoffset = -48;
		check("H-Position -48",               3, 262, 223, 320, 3840, 5472, 1, 223);
		hsize = 8;
		check("H-Size +8, H-Position -48",    3, 262, 223, 317, 4450, 5472, 1, 223);
		hoffset = 0;
		check("H-Size +8",                    3, 262, 223, 269, -1,   5472, 1, 223);
		hsize = -16;
		check("H-Size -16",                   3, 262, 223, 320, 2560, 5472, 1, 223);
		hsize = 8; vsize_step = 7; scale_en = 0;
		check("scaling locked out",           3, 262, 223, 320, 3840, 5472, 1, 223);
		hsize = 0; vsize_step = 0; scale_en = 1;
		vsize_step = 1;
		check("PVM +1 (taller)",              8, 259, 223, -1,  -1,   5535, 1, 223);
		vsize_step = 2;
		check("PVM +2",                       8, 256, 223, -1,  -1,   5600, 1, 223);
		vsize_step = 7;
		check("PVM +7",                      25, 241, 223, -1,  -1,   5948, 1, 223);
		vsize_step = -7;
		check("PVM -7 (shorter)",            50, 283, 223, -1,  -1,   5065, 1, 223);
		vsize_step = 0;
		check("PVM back to 0",               25, 262, 223, 320, 3840, 5472, 1, 223);
		cabinet = 1; vsize_step = 7;
		check("Cabinet +7",                  25, 262, 244, -1,  -1,   5472, -1, -1);
		hsize = 8; hoffset = -20; voffset = 3;
		check("Cabinet +7, all controls",     5, 262, 244, 289, -1,   5472, -1, -1);
		active = 0;
		check("off again",                    3, 262, 224, 320, 3840, 5472, 0, 223);

		if (fails != 0) $fatal(1, "%0d scenario(s) FAILED", fails);
		$display("ALL PASS");
		$finish;
	end

endmodule
