// SPDX-License-Identifier: GPL-3.0-or-later
//
// CPU + video core for the Unico SR2001A board (silkroad.cpp): rtl/cpu/maincpu.sv on the
// block RAMs, the video registers (rtl/video/silkroad_vregs.sv), the sound (rtl/sound), and
// the video: three tilemaps (rtl/video/silkroad_tilemaps.sv) and the sprites
// (rtl/video/silkroad_spriteram.sv, silkroad_sprites.sv), each rendered a line ahead into
// line buffers, mixed here as screen_update does (262-278). ROM contents are external, behind
// the req/valid ports (rtl/memory/silkroad_sdram_top.sv); HPS/DIP/CRT glue is one level up in
// Silkroad.sv.
//
// Timing (video_timing.sv): 512 x 262 at 8 MHz, 380 x 224 shown. At line_start (the end of
// line n's active columns) the line buffers swap and both engines render line n + 2
// (vcnt_next2_active), which the display reads after the next swap.
//
// Mixing (the model is scripts/render_model.py, pixel-identical to MAME on 26 scenes): the
// backdrop is pen 0x7C0 (264); layers 0, 1, 2 drawn in order over it, pen 0 transparent; the
// layers' priority codes 0, 1, 2 are ORed where opaque, so only layers 1 and 2 count. A sprite
// position holds the first opaque sprite pixel; it shows when its priority bit is 0 and neither
// layer 1 nor 2 is opaque there, or when its bit is 1 and layer 2 is not (pri_mask, 208).
module silkroad_core #(
	parameter bit DEBUG_TRACER  = 1'b1
) (
	input  logic clk,
	input  logic ce_pix,
	input  logic reset,
	// Video timing runs from its own reset, which does not include the ROM download, so the
	// raster keeps running (and a CRT keeps sync) while the game loads.
	input  logic video_reset,

	// CPU program ROM -- external (SDRAM stack).
	output logic         cpu_rom_req,
	output logic [19:0] cpu_rom_addr,     // word address, 2 MB
	input  logic         cpu_rom_valid,
	input  logic [15:0] cpu_rom_data,

	// Graphics ROM, held requests: the tilemaps (Port 0) and the sprites (Port 1). *_b selects
	// region B; *_off is a byte offset into the region, 8-aligned.
	output logic         tm_gfx_req,
	output logic         tm_gfx_b,
	output logic [23:0] tm_gfx_off,
	input  logic         tm_gfx_valid,
	input  logic [63:0] tm_gfx_data,
	output logic         sp_gfx_req,
	output logic         sp_gfx_b,
	output logic [23:0] sp_gfx_off,
	input  logic         sp_gfx_valid,
	input  logic [63:0] sp_gfx_data,

	// OKI sample ROMs -- external. The address is {bank, the chip's 18-bit address}; the
	// SDRAM side maps it. Byte reads, held req.
	output logic         oki1_rom_req,
	output logic [19:0] oki1_rom_addr,
	input  logic         oki1_rom_valid,
	input  logic [7:0]  oki1_rom_data,
	output logic         oki2_rom_req,
	output logic [19:0] oki2_rom_addr,
	input  logic         oki2_rom_valid,
	input  logic [7:0]  oki2_rom_data,

	// YM2151 and both OKIs, mixed as silkroad.cpp does, signed 16-bit per side
	output logic [15:0] audio_l,
	output logic [15:0] audio_r,

	// Inputs (raw values -- caller owns debouncing/mapping).
	input  logic [31:0] p1p2_in,
	input  logic [31:0] dsw_in,
	// Flip screen, latched at frame start: the frame is the unflipped one turned 180 degrees.
	input  logic         flip,

	// ---- hiscore access to work RAM (rtl/hiscore.v) ----
	// Byte address within the 128KB work RAM (0xFE0000-0xFFFFFF). Reads and writes borrow the
	// CPU's port, which is safe because hiscore only touches the RAM with the CPU paused.
	input  logic [16:0] hs_address,
	input  logic [7:0]  hs_data_in,
	output logic [7:0]  hs_data_out,
	input  logic         hs_read,
	input  logic         hs_write,

	// Video output.
	output logic [8:0]  hcnt,
	output logic [8:0]  vcnt,
	output logic         hblank,
	output logic         vblank,
	output logic         hsync,
	output logic         vsync,
	output logic [14:0] rgb,

	// ---- debug (rtl/debug/debug_tracer.sv), compiled out when DEBUG_TRACER = 0 ----
	input  logic         dbg_overlay,
	//   [0] sprites  [1] tilemap layer 0  [2] tilemap layer 1  [3] tilemap layer 2
	input  logic [3:0]  dbg_render_dis,
	input  logic         pause,
`ifdef DEBUG_ISSP
	input  logic         dbg_autopause_frame_en,
`endif
	input  logic [1:0]  dbg_src,
	input  logic [3:0]  dbg_window,
	input  logic         dbg_rearm,
	output logic [23:0] dbg_pixel
);

	// ---- video timing ----
	logic [7:0] vcnt_active, vcnt_next_active, vcnt_next2_active;
	logic       h_active, v_active;
	logic       line_start, frame_start;

	video_timing u_timing (
		.clk(clk), .ce_pix(ce_pix), .reset(video_reset),
		.hcnt(hcnt), .vcnt(vcnt), .vcnt_active(vcnt_active), .vcnt_next_active(vcnt_next_active),
		.vcnt_next2_active(vcnt_next2_active),
		.h_active(h_active), .v_active(v_active),
		.hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start)
	);

	logic flip_screen;
	always_ff @(posedge clk or posedge video_reset) begin
		if (video_reset)      flip_screen <= 1'b0;
		else if (frame_start) flip_screen <= flip;
	end

`ifdef DEBUG_ISSP
	// Frame-count auto-pause: pause N frames after the last (re)arm over JTAG. Source: bit 16 =
	// rearm pulse, bits 15:0 = target frame count.
	wire [16:0] frame_pause_src;
	logic         frame_pause_rearm_d, frame_pause_armed, frame_pause_fired;
	logic [15:0] frame_pause_target, frame_pause_count;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			frame_pause_rearm_d <= 1'b0;
			frame_pause_armed    <= 1'b0;
			frame_pause_fired    <= 1'b0;
			frame_pause_count    <= 16'd0;
		end else begin
			frame_pause_rearm_d <= frame_pause_src[16];
			if (frame_pause_src[16] & ~frame_pause_rearm_d) begin
				frame_pause_target <= frame_pause_src[15:0];
				frame_pause_count  <= 16'd0;
				frame_pause_armed  <= 1'b1;
				frame_pause_fired  <= 1'b0;
			end else if (!dbg_autopause_frame_en) begin
				frame_pause_armed <= 1'b0;
				frame_pause_fired <= 1'b0;
			end else if (frame_pause_armed && frame_start) begin
				if (frame_pause_count == frame_pause_target) begin
					frame_pause_fired <= 1'b1;
					frame_pause_armed <= 1'b0;
				end else begin
					frame_pause_count <= frame_pause_count + 1'b1;
				end
			end
		end
	end

	altsource_probe #(
		.sld_auto_instance_index("YES"), .instance_id("F"), .probe_width(16), .source_width(17),
		.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
	) u_issp_framepause (
		.probe(frame_pause_count), .source(frame_pause_src), .source_clk(clk), .source_ena(1'b1)
	);

	wire auto_pause_frame = dbg_autopause_frame_en && frame_pause_fired;
`endif

	// Declared before maincpu uses it (a port bound to an undeclared name becomes an implicit
	// 1-bit net, and ModelSim rejects the later declaration, vlog-2388).
	logic spr_copy_busy;

	wire effective_pause = pause
`ifdef DEBUG_ISSP
		| auto_pause_frame
`endif
		;

	// ---- CPU-facing BRAM region ports (maincpu.sv's own port shapes) ----
	logic [10:0] spr_cpu_addr;
	logic         spr_cpu_wel, spr_cpu_weh;
	logic [15:0] spr_cpu_wdata, spr_cpu_rdata;

	logic [11:0] pal_cpu_addr;
	logic         pal_cpu_wel, pal_cpu_weh;
	logic [15:0] pal_cpu_wdata, pal_cpu_rdata;

	logic [12:0] vram_cpu_addr;
	logic [15:0] vram_cpu_wdata;
	logic         vram0_cpu_wel, vram0_cpu_weh, vram1_cpu_wel, vram1_cpu_weh;
	logic         vram2_cpu_wel, vram2_cpu_weh;
	logic [15:0] vram0_cpu_rdata, vram1_cpu_rdata, vram2_cpu_rdata;

	logic [3:0]  vregs_cpu_addr;
	logic         vregs_cpu_wel, vregs_cpu_weh;
	logic [15:0] vregs_cpu_wdata;

	logic [15:0] workram_cpu_addr;
	logic         workram_cpu_wel, workram_cpu_weh;
	logic [15:0] workram_cpu_wdata, workram_cpu_rdata;

	logic        oki1_wr, oki2_wr, oki1_bank_we, ym_wr, ym_a0;
	logic [7:0]  snd_wdata, oki1_dout, oki2_dout, ym_dout;
	logic [1:0]  oki_bank;

	maincpu u_cpu (
		.clk(clk), .reset(reset),
		.rom_req(cpu_rom_req), .rom_addr(cpu_rom_addr), .rom_valid(cpu_rom_valid), .rom_data(cpu_rom_data),
		.spriteram_addr(spr_cpu_addr), .spriteram_wel(spr_cpu_wel), .spriteram_weh(spr_cpu_weh),
		.spriteram_wdata(spr_cpu_wdata), .spriteram_rdata(spr_cpu_rdata),
		.palette_addr(pal_cpu_addr), .palette_wel(pal_cpu_wel), .palette_weh(pal_cpu_weh),
		.palette_wdata(pal_cpu_wdata), .palette_rdata(pal_cpu_rdata),
		.vram_addr(vram_cpu_addr), .vram_wdata(vram_cpu_wdata),
		.vram0_wel(vram0_cpu_wel), .vram0_weh(vram0_cpu_weh), .vram0_rdata(vram0_cpu_rdata),
		.vram1_wel(vram1_cpu_wel), .vram1_weh(vram1_cpu_weh), .vram1_rdata(vram1_cpu_rdata),
		.vram2_wel(vram2_cpu_wel), .vram2_weh(vram2_cpu_weh), .vram2_rdata(vram2_cpu_rdata),
		.vregs_addr(vregs_cpu_addr), .vregs_wel(vregs_cpu_wel), .vregs_weh(vregs_cpu_weh),
		.vregs_wdata(vregs_cpu_wdata),
		.workram_addr(workram_cpu_addr), .workram_wel(workram_cpu_wel), .workram_weh(workram_cpu_weh),
		.workram_wdata(workram_cpu_wdata), .workram_rdata(workram_cpu_rdata),
		.p1p2_in(p1p2_in), .dsw_in(dsw_in), .pause(effective_pause), .spr_hold(spr_copy_busy),
		.oki1_wr(oki1_wr), .oki2_wr(oki2_wr), .ym_wr(ym_wr), .ym_a0(ym_a0), .snd_wdata(snd_wdata),
		.oki1_dout(oki1_dout), .oki2_dout(oki2_dout),
		.ym_dout(ym_dout),
		.oki1_bank_we(oki1_bank_we), .oki_bank(oki_bank),
		.vblank(vblank)
	);

	// ---- YM2151 and OKI M6295 x2 (rtl/sound/silkroad_sound.sv) ----
	silkroad_sound u_sound (
		.clk(clk), .reset(reset),
		.oki1_wr(oki1_wr), .oki2_wr(oki2_wr), .ym_wr(ym_wr), .ym_a0(ym_a0), .wdata(snd_wdata),
		.oki1_dout(oki1_dout), .oki2_dout(oki2_dout), .ym_dout(ym_dout),
		.oki1_bank_we(oki1_bank_we), .bank(oki_bank),
		.oki1_rom_req(oki1_rom_req), .oki1_rom_addr(oki1_rom_addr),
		.oki1_rom_valid(oki1_rom_valid), .oki1_rom_data(oki1_rom_data),
		.oki2_rom_req(oki2_rom_req), .oki2_rom_addr(oki2_rom_addr),
		.oki2_rom_valid(oki2_rom_valid), .oki2_rom_data(oki2_rom_data),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	// ---- work RAM: the CPU's port, shared with hiscore; port B unused ----
	// Reading through port B instead looks free but makes Quartus replicate the whole array
	// for a second read port (Psikyo: +102 M10K). Big-endian: an even byte is the high half.
	wire [15:0] hs_word_addr = hs_address[16:1];
	wire        hs_byte_odd  = hs_address[0];
	wire        hs_access       = hs_read | hs_write;
	wire [15:0] workram_a_addr  = hs_access ? hs_word_addr : workram_cpu_addr;
	wire        workram_a_wel   = hs_write ? hs_byte_odd  : workram_cpu_wel;
	wire        workram_a_weh   = hs_write ? ~hs_byte_odd : workram_cpu_weh;
	wire [15:0] workram_a_wdata = hs_write ? {hs_data_in, hs_data_in} : workram_cpu_wdata;

	logic [15:0] workram_unused_b;
	dpram #(.ADDR_WIDTH(16), .DATA_WIDTH(16)) u_workram (
		.clk(clk),
		.a_addr(workram_a_addr), .a_wel(workram_a_wel), .a_weh(workram_a_weh),
		.a_wdata(workram_a_wdata), .a_rdata(workram_cpu_rdata),
		.b_addr(16'd0), .b_rdata(workram_unused_b)
	);
	// registered next to the RAM: the raw M10K output to hiscore's FSM was the worst timing path
	always_ff @(posedge clk)
		hs_data_out <= hs_byte_odd ? workram_cpu_rdata[7:0] : workram_cpu_rdata[15:8];

	// ---- debug overlay dump addressing ----
	// The overlay replaces the picture, so the engines' read ports are free while it is up.
	//   rows   0- 31 : layer 0 and 1 VRAM, words 0-4095 ({vcnt[3:0],hcnt[7:0]})
	//   rows  32- 47 : the twelve video-register halves (hcnt[3:0])
	//   rows  48- 63 : palette, all 4096 entries
	wire        vram_dump_active  = DEBUG_TRACER && dbg_overlay && (vcnt < 9'd32);
	wire        vregs_dump_active = DEBUG_TRACER && dbg_overlay && (vcnt >= 9'd32) && (vcnt < 9'd48);
	wire        pal_dump_active   = DEBUG_TRACER && dbg_overlay && (vcnt >= 9'd48) && (vcnt < 9'd64);
	wire [12:0] vram_dump_addr    = {1'b0, vcnt[3:0], hcnt[7:0]};
	wire [11:0] pal_dump_addr     = {vcnt[3:0], hcnt[7:0]};
	logic [15:0] vregs_dump_data;

	// ---- palette: CPU write, compositor read ----
	logic [11:0] pal_addr;
	logic [15:0] pal_b_rdata;
	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
		.clk(clk),
		.a_addr(pal_cpu_addr), .a_wel(pal_cpu_wel), .a_weh(pal_cpu_weh),
		.a_wdata(pal_cpu_wdata), .a_rdata(pal_cpu_rdata),
		.b_addr(pal_dump_active ? pal_dump_addr : pal_addr), .b_rdata(pal_b_rdata)
	);

	// ---- tilemap VRAM: CPU write, tilemap engine read ----
	logic [12:0] tm_vram_addr;
	logic [15:0] vram0_b_rdata, vram1_b_rdata, vram2_b_rdata;
	wire  [12:0] vram_b_addr = vram_dump_active ? vram_dump_addr : tm_vram_addr;

	dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_vram0 (
		.clk(clk),
		.a_addr(vram_cpu_addr), .a_wel(vram0_cpu_wel), .a_weh(vram0_cpu_weh),
		.a_wdata(vram_cpu_wdata), .a_rdata(vram0_cpu_rdata),
		.b_addr(vram_b_addr), .b_rdata(vram0_b_rdata)
	);
	dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_vram1 (
		.clk(clk),
		.a_addr(vram_cpu_addr), .a_wel(vram1_cpu_wel), .a_weh(vram1_cpu_weh),
		.a_wdata(vram_cpu_wdata), .a_rdata(vram1_cpu_rdata),
		.b_addr(vram_b_addr), .b_rdata(vram1_b_rdata)
	);
	dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_vram2 (
		.clk(clk),
		.a_addr(vram_cpu_addr), .a_wel(vram2_cpu_wel), .a_weh(vram2_cpu_weh),
		.a_wdata(vram_cpu_wdata), .a_rdata(vram2_cpu_rdata),
		.b_addr(vram_b_addr), .b_rdata(vram2_b_rdata)
	);

	// ---- video registers (silkroad.cpp:329) ----
	logic [15:0] l0_x, l0_y, l1_x, l1_y, l2_x, l2_y;

	silkroad_vregs u_vregs (
		.clk(clk), .reset(reset),
		.cpu_addr(vregs_cpu_addr), .cpu_wel(vregs_cpu_wel), .cpu_weh(vregs_cpu_weh),
		.cpu_wdata(vregs_cpu_wdata),
		.l0_x(l0_x), .l0_y(l0_y), .l1_x(l1_x), .l1_y(l1_y), .l2_x(l2_x), .l2_y(l2_y),
		.dbg_addr(hcnt[3:0]), .dbg_data(vregs_dump_data)
	);

	// ---- render schedule ----
	// At line_start of raster line v the engines render visible line v + 2: lines 0-221 render
	// 2-223, lines 260 and 261 render 0 and 1 (V total 262).
	wire render_en = (vcnt < 9'd222) || (vcnt >= 9'd260);
	// The sprite snapshot after the game's last sprite write: MAME's writes end ten lines into
	// its 16-line vblank (docs/write_timing_mame.txt), here vblank starts at line 224 and the
	// copy runs at line 248, 2048 clk, before line 0's render at line 260.
	wire spr_copy_start = line_start && (vcnt == 9'd248);

	// Flip screen: line y shows source line 223 - y, column x source column 379 - x, for every
	// layer and the sprites alike (silkroad.cpp has no flip; the core's is the unflipped frame
	// turned 180 degrees). flip_screen is taken at vblank start, before line 0 renders (line 260).
	wire [7:0] render_line = flip_screen ? 8'(8'd223 - vcnt_next2_active) : vcnt_next2_active;

	// ---- tilemaps ----
	logic [8:0]  rd_x;
	logic [10:0] l0_px, l1_px, l2_px;
	logic        tm_busy, tm_ovr_ev;

	silkroad_tilemaps u_tilemaps (
		.clk(clk), .reset(reset),
		.line_start(line_start), .render_en(render_en), .render_line(render_line),
		.sx0(l0_x), .sy0(l0_y), .sx1(l1_x), .sy1(l1_y), .sx2(l2_x), .sy2(l2_y),
		.vram_addr(tm_vram_addr), .vram0_data(vram0_b_rdata), .vram1_data(vram1_b_rdata),
		.vram2_data(vram2_b_rdata),
		.gfx_req(tm_gfx_req), .gfx_b(tm_gfx_b), .gfx_off(tm_gfx_off),
		.gfx_valid(tm_gfx_valid), .gfx_data(tm_gfx_data),
		.rd_x(rd_x), .l0_px(l0_px), .l1_px(l1_px), .l2_px(l2_px),
		.busy(tm_busy), .overrun_ev(tm_ovr_ev)
	);

	// ---- sprites ----
	logic [10:0] snap_addr;
	logic [15:0] snap_data;
	logic [8:0]  ytab_addr;
	logic [16:0] ytab_data;
	logic        sp_valid, sp_busy, sp_ovr_ev;
	logic [12:0] sp_px;

`ifdef DEBUG_ISSP
	// JTAG read of the CPU-visible sprite RAM (instance "S"), while the CPU is paused.
	wire [10:0] dbg_spr_rd_addr;
	wire [10:0] spr_a_addr = effective_pause ? dbg_spr_rd_addr : spr_cpu_addr;
	altsource_probe #(
		.sld_auto_instance_index("YES"), .instance_id("S"), .probe_width(17), .source_width(11),
		.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
	) u_issp_sprrd (
		.probe({effective_pause, spr_cpu_rdata}), .source(dbg_spr_rd_addr), .source_clk(clk), .source_ena(1'b1)
	);
`else
	wire [10:0] spr_a_addr = spr_cpu_addr;
`endif

	silkroad_spriteram u_spriteram (
		.clk(clk), .reset(reset),
		.copy_start(spr_copy_start), .copy_busy(spr_copy_busy),
		.cpu_addr(spr_a_addr), .cpu_wel(spr_cpu_wel), .cpu_weh(spr_cpu_weh),
		.cpu_wdata(spr_cpu_wdata), .cpu_rdata(spr_cpu_rdata),
		.snap_addr(snap_addr), .snap_data(snap_data),
		.ytab_addr(ytab_addr), .ytab_data(ytab_data)
	);

	silkroad_sprites u_sprites (
		.clk(clk), .reset(reset),
		.line_start(line_start), .render_en(render_en), .render_line(render_line),
		.snap_addr(snap_addr), .snap_data(snap_data), .ytab_addr(ytab_addr), .ytab_data(ytab_data),
		.gfx_req(sp_gfx_req), .gfx_b(sp_gfx_b), .gfx_off(sp_gfx_off),
		.gfx_valid(sp_gfx_valid), .gfx_data(sp_gfx_data),
		.rd_x(rd_x), .sp_valid(sp_valid), .sp_px(sp_px),
		.busy(sp_busy), .overrun_ev(sp_ovr_ev)
	);

	// ---- compositor ----
	// rd_x is the column shown during the next pixel period: the line buffers answer a clock
	// after it, the palette a clock after that, and rgb is taken on the ce_pix that moves hcnt
	// on, so column x is on the output while hcnt = x + 1 (video_timing: hblank is low for
	// hcnt 1-380).
	assign rd_x = (hcnt >= 9'd380) ? 9'd0 : flip_screen ? 9'(9'd379 - hcnt) : hcnt;

	wire l0_on = (l0_px[5:0] != 6'd0) && !dbg_render_dis[1];
	wire l1_on = (l1_px[5:0] != 6'd0) && !dbg_render_dis[2];
	wire l2_on = (l2_px[5:0] != 6'd0) && !dbg_render_dis[3];
	wire sp_on = sp_valid && !dbg_render_dis[0] && (sp_px[12] ? !l2_on : !(l1_on || l2_on));
	always_comb begin
		if      (sp_on) pal_addr = sp_px[11:0];
		else if (l2_on) pal_addr = {1'b0, l2_px};
		else if (l1_on) pal_addr = {1'b0, l1_px};
		else if (l0_on) pal_addr = {1'b0, l0_px};
		else            pal_addr = 12'h7C0;
	end

	always_ff @(posedge clk) if (ce_pix) rgb <= pal_b_rdata[14:0];

	// ---- instrumentation ----
	// Rates, not flags: lines whose render line_start cut short, per engine, and the worst
	// render length in clk (a line is 3072).
	logic [19:0] tm_ovr_cnt = '0, sp_ovr_cnt = '0, ovr_frames = '0;
	logic [11:0] tm_cycles = '0, sp_cycles = '0, tm_render_max = '0, sp_render_max = '0;
	always_ff @(posedge clk) begin
		if (tm_ovr_ev)   tm_ovr_cnt <= tm_ovr_cnt + 1'b1;
		if (sp_ovr_ev)   sp_ovr_cnt <= sp_ovr_cnt + 1'b1;
		if (frame_start) ovr_frames <= ovr_frames + 1'b1;
		if (line_start) begin
			if (tm_cycles > tm_render_max) tm_render_max <= tm_cycles;
			if (sp_cycles > sp_render_max) sp_render_max <= sp_cycles;
			tm_cycles <= '0;
			sp_cycles <= '0;
		end else begin
			if (tm_busy && tm_cycles != 12'hFFF) tm_cycles <= tm_cycles + 1'b1;
			if (sp_busy && sp_cycles != 12'hFFF) sp_cycles <= sp_cycles + 1'b1;
		end
	end

`ifdef DEBUG_ISSP
	// ISSP "V" (scripts/read_issp.tcl): the render counters above, for reading without the
	// overlay. Source bit 0 is unused.
	altsource_probe #(
		.sld_auto_instance_index("YES"), .instance_id("V"), .probe_width(84), .source_width(1),
		.source_initial_value("0"), .enable_metastability("NO"), .lpm_type("altsource_probe")
	) u_issp_video (
		.probe({ovr_frames, sp_ovr_cnt, tm_ovr_cnt, sp_render_max, tm_render_max}),
		.source(), .source_clk(clk), .source_ena(1'b1)
	);
`endif

	// ---- debug tracer: CPU ROM reads, address and data, two buffers read out by scanline ----
	generate if (DEBUG_TRACER) begin : g_tracer
		logic [23:0] rd_addr, rd_data;
		logic        frz_a, frz_d;
		// word address 8 = exception vector 4 (illegal instruction): freeze on its first fetch
		wire trig_vec4 = (cpu_rom_addr == 20'd8);

		debug_tracer #(.DEPTH(128), .WIDTH(24)) u_trace_addr (
			.clk(clk), .cap_stb(cpu_rom_valid), .cap_data({4'd0, cpu_rom_addr}),
			.ctl_rearm(dbg_rearm), .ctl_window(dbg_window), .ctl_ring(dbg_src[0]),
			.ctl_trig_en(dbg_src[1]), .cap_trig(trig_vec4),
			.rd_index(vcnt - 9'd64), .rd_data(rd_addr), .frozen(frz_a)
		);
		debug_tracer #(.DEPTH(128), .WIDTH(24)) u_trace_data (
			.clk(clk), .cap_stb(cpu_rom_valid), .cap_data({cpu_rom_addr[7:0], cpu_rom_data}),
			.ctl_rearm(dbg_rearm), .ctl_window(dbg_window), .ctl_ring(dbg_src[0]),
			.ctl_trig_en(dbg_src[1]), .cap_trig(trig_vec4),
			.rd_index(vcnt - 9'd192), .rd_data(rd_data), .frozen(frz_d)
		);

		// rows 216-223: the controls echoed back with a 0xA5 marker, so a mis-decoded band shows
		wire [23:0] ctl_echo = {8'hA5, 1'b0, 1'b0, 1'b0, 1'b0,
								~dbg_render_dis[1], ~dbg_render_dis[2], frz_a, frz_d,
								dbg_rearm, dbg_window, dbg_src, 1'b1};

		//   row 213 worst tilemap render, 214 worst sprite render (clk)
		//   row 217 tilemap lines cut short, 219 sprite lines cut short, 220 frames
		assign dbg_pixel = (vcnt == 9'd213) ? {12'd0, tm_render_max}
						 : (vcnt == 9'd214) ? {12'd0, sp_render_max}
						 : (vcnt == 9'd217) ? {4'd0, tm_ovr_cnt}
						 : (vcnt == 9'd219) ? {4'd0, sp_ovr_cnt}
						 : (vcnt == 9'd220) ? {4'd0, ovr_frames}
						 : (vcnt >= 9'd216) ? ctl_echo
						 : (vcnt <  9'd16)  ? {8'h00, vram0_b_rdata}
						 : (vcnt <  9'd32)  ? {8'h00, vram1_b_rdata}
						 : (vcnt <  9'd48)  ? {8'h00, vregs_dump_data}
						 : (vcnt <  9'd64)  ? {8'h00, pal_b_rdata}
						 : (vcnt <  9'd192) ? rd_addr
											: rd_data;
	end else begin : g_no_tracer
		assign dbg_pixel = 24'd0;
	end endgenerate

endmodule
