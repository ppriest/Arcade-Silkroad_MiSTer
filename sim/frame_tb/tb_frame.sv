`timescale 1ns/1ps
// Whole frames from captured MAME state, through silkroad_top and the real SDRAM path.
//
// The set's ROM image is read into the chip model; a capture's sprite RAM, palette, three VRAMs
// and video registers are written through the core's CPU write ports (the maincpu output nets,
// forced while the 68020 is paused). The sprite snapshot is taken at line 248 as in play; the
// first frame after it is recorded, and the next, blanking included, for
// scripts/frame_compare.py.
//
// RUN FROM THE REPOSITORY ROOT, after python sim/frame_tb/prep.py <capture>:
//     scripts/run_sim.sh frame_tb +CAP=debug/silkroad-sw600 +IMG=debug/silkroad-image.sdram
//         [+FRAMES=2] [+DIS=n] [+FLIP=1]   DIS: dbg_render_dis (bit 0 sprites, 1 layer 0, 2 layer 1, 3 layer 2);
//         FLIP: flip screen (compare with scripts/frame_compare.py --flip)
// Writes <CAP>/rtl_frames.hex: one line per pixel clock, {vblank, hblank} as one hex digit then
// rgb[14:0] as four, 512 x 262 a frame.
module tb_frame;
	localparam real HALF = 10.4167;     // 48 MHz
	// clk_sdram twice clk, rising edges aligned, as the PLL gives them
	logic clk = 0, clk_sdram = 0;
	always #(HALF / 2) clk_sdram = ~clk_sdram;
	initial begin #(HALF / 2); forever #(HALF) clk = ~clk; end
	logic [2:0] ce_div = 0;
	logic       ce_pix;
	always_ff @(posedge clk) ce_div <= (ce_div == 3'd5) ? 3'd0 : ce_div + 3'd1;
	assign ce_pix = (ce_div == 3'd0);   // Silkroad.sv: clk_sys / 6

	logic reset = 1;
	logic [3:0] dis = 4'd0;
	logic       flip = 1'b0;
	logic [8:0]  hcnt, vcnt;
	logic        hblank, vblank, hsync, vsync;
	logic [14:0] rgb;

	wire  [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
	logic [1:0]  SDRAM_BA;

	silkroad_top dut (
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(), .hs_read(1'b0), .hs_write(1'b0),
		.dbg_overlay(1'b0), .dbg_render_dis(dis), .pause(1'b1),
		.dbg_src(2'd0), .dbg_window(4'd0), .dbg_rearm(1'b0), .dbg_pixel(),
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(25'd0), .ldr_data(16'd0), .ldr_we16(1'b0), .ldr_busy(),
		.clk(clk), .clk_sdram(clk_sdram), .ce_pix(ce_pix), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(25'd0),
		.ioctl_dout(8'd0), .ioctl_wait(),
		.p1p2_in(32'hffffffff), .dsw_in(32'hffffffff), .flip(flip),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb)
	);

	sdram_chip_model_wide chip (
		.clk(clk_sdram),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- the CPU write ports, driven from here while loading ----
	localparam int NWORDS = 2048 + 4096 + 3 * 8192 + 12;
	logic [15:0] st [0:NWORDS-1];
	logic [12:0] ld_addr = 0;
	logic [15:0] ld_data = 0;
	logic        ld_spr = 0, ld_pal = 0, ld_v0 = 0, ld_v1 = 0, ld_v2 = 0, ld_vr = 0;

	task automatic load_region(input int base, input int n, input int which);
		for (int i = 0; i < n; i++) begin
			@(negedge clk);
			ld_addr = 13'(i);
			ld_data = st[base + i];
			{ld_spr, ld_pal, ld_v0, ld_v1, ld_v2, ld_vr} = 6'b100000 >> which;
		end
		@(negedge clk);
		{ld_spr, ld_pal, ld_v0, ld_v1, ld_v2, ld_vr} = 6'b000000;
	endtask

	task automatic load_state();
		force dut.u_core.spr_cpu_addr    = ld_addr[10:0];
		force dut.u_core.spr_cpu_wdata   = ld_data;
		force dut.u_core.spr_cpu_wel     = ld_spr;
		force dut.u_core.spr_cpu_weh     = ld_spr;
		force dut.u_core.pal_cpu_addr    = ld_addr[11:0];
		force dut.u_core.pal_cpu_wdata   = ld_data;
		force dut.u_core.pal_cpu_wel     = ld_pal;
		force dut.u_core.pal_cpu_weh     = ld_pal;
		force dut.u_core.vram_cpu_addr   = ld_addr;
		force dut.u_core.vram_cpu_wdata  = ld_data;
		force dut.u_core.vram0_cpu_wel   = ld_v0;
		force dut.u_core.vram0_cpu_weh   = ld_v0;
		force dut.u_core.vram1_cpu_wel   = ld_v1;
		force dut.u_core.vram1_cpu_weh   = ld_v1;
		force dut.u_core.vram2_cpu_wel   = ld_v2;
		force dut.u_core.vram2_cpu_weh   = ld_v2;
		force dut.u_core.vregs_cpu_addr  = ld_addr[3:0];
		force dut.u_core.vregs_cpu_wdata = ld_data;
		force dut.u_core.vregs_cpu_wel   = ld_vr;
		force dut.u_core.vregs_cpu_weh   = ld_vr;
		load_region(0, 2048, 0);
		load_region(2048, 4096, 1);
		load_region(2048 + 4096, 8192, 2);
		load_region(2048 + 4096 + 8192, 8192, 3);
		load_region(2048 + 4096 + 2 * 8192, 8192, 4);
		load_region(2048 + 4096 + 3 * 8192, 12, 5);
		@(negedge clk);
		release dut.u_core.spr_cpu_addr;   release dut.u_core.spr_cpu_wdata;
		release dut.u_core.spr_cpu_wel;    release dut.u_core.spr_cpu_weh;
		release dut.u_core.pal_cpu_addr;   release dut.u_core.pal_cpu_wdata;
		release dut.u_core.pal_cpu_wel;    release dut.u_core.pal_cpu_weh;
		release dut.u_core.vram_cpu_addr;  release dut.u_core.vram_cpu_wdata;
		release dut.u_core.vram0_cpu_wel;  release dut.u_core.vram0_cpu_weh;
		release dut.u_core.vram1_cpu_wel;  release dut.u_core.vram1_cpu_weh;
		release dut.u_core.vram2_cpu_wel;  release dut.u_core.vram2_cpu_weh;
		release dut.u_core.vregs_cpu_addr; release dut.u_core.vregs_cpu_wdata;
		release dut.u_core.vregs_cpu_wel;  release dut.u_core.vregs_cpu_weh;
	endtask

	// ---- recording ----
	int    fd, frames = 2, nrec = 0;
	logic  recording = 0;
	always @(posedge clk) if (recording && ce_pix) begin
		$fwrite(fd, "%1x%04x\n", {vblank, hblank}, {1'b0, rgb});
		nrec++;
	end

	// +LAYERS=1: also each layer's line-buffer output for the column being read, one line per
	// visible pixel of the first recorded frame, to <CAP>/rtl_layers.hex: l0 l1 l2 {valid, sprite}
	int  layers = 0, fdl = 0;
	always @(posedge clk) if (recording && layers != 0 && fdl != 0 && ce_pix && dut.u_core.hcnt < 380 && dut.u_core.vcnt < 224)
		$fwrite(fdl, "%03x %03x %03x %1x%04x\n", dut.u_core.l0_px, dut.u_core.l1_px, dut.u_core.l2_px,
		        dut.u_core.sp_valid, dut.u_core.sp_px);

	initial begin
		string cap, img;
		int    f, n;
		if (!$value$plusargs("CAP=%s", cap)) $fatal(1, "+CAP=<capture dir> missing");
		if (!$value$plusargs("IMG=%s", img)) $fatal(1, "+IMG=<debug/<set>-image.sdram> missing");
		void'($value$plusargs("FRAMES=%d", frames));
		void'($value$plusargs("DIS=%d", dis));
		void'($value$plusargs("FLIP=%d", flip));
		void'($value$plusargs("LAYERS=%d", layers));
		$readmemh({cap, "/cpu_state.hex"}, st);
		f = $fopen(img, "rb");
		if (f == 0) $fatal(1, "cannot open %s", img);
		n = $fread(chip.mem, f);
		$fclose(f);
		$display("image: %0d bytes into the chip model", n);

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (20) @(posedge clk);
		load_state();
		$display("%t: state loaded (vcnt %0d)", $time, vcnt);

		// past the sprite snapshot at line 248, then from the first pixel clock of line 0
		wait (vcnt == 9'd250);
		wait (vcnt == 0 && hcnt == 0 && ce_pix);
		fd = $fopen({cap, "/rtl_frames.hex"}, "w");
		if (layers != 0) fdl = $fopen({cap, "/rtl_layers.hex"}, "w");
		recording = 1;
		repeat (frames * 512 * 262) @(posedge clk iff ce_pix);
		recording = 0;
		$fclose(fd);
		if (fdl != 0) $fclose(fdl);
		$display("%t: %0d pixel clocks recorded to %s/rtl_frames.hex", $time, nrec, cap);
		$display("lines cut short: tilemaps %0d, sprites %0d; worst render: tilemaps %0d clk, sprites %0d clk (of 3072), %0d frames run",
		         dut.u_core.tm_ovr_cnt, dut.u_core.sp_ovr_cnt, dut.u_core.tm_render_max, dut.u_core.sp_render_max,
		         dut.u_core.ovr_frames);
		$finish;
	end
endmodule
