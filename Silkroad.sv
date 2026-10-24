// SPDX-License-Identifier: GPL-3.0-or-later
//
// Top-level HPS/DIP/video glue for the Unico SR2001A board (MAME silkroad.cpp), wiring
// rtl/silkroad_top.sv into the MiSTer framework.
//
// Input layout is silkroad.cpp's INPUT_PORTS (339-415): one 32-bit port at $C00000, and the
// DIP switches in bits 31-16 of $C00004.
// MiSTer joystick bit order (0=Right,1=Left,2=Down,3=Up,4..6=Buttons,
// 10=Start,11=Coin) follows rmonic79/Arcade-Raiden_MiSTer.
//
// Video goes through sys/arcade_video.v (scandoubler, gamma, scanline FX) and
// sys/video_freak.sv (aspect, integer scale, crop), with rtl/video/screen_rotate_two.sv
// tapping the output to rotate it for HDMI via the HPS framebuffer. Flip is the core's own
// (flip_screen), so both outputs show it.
//
// Sound: the YM2151 (jt51) in stereo and two OKI M6295 (jt6295) on both sides, mixed in the core.
//
// SDRAM_CLK's phase is estimated, not swept (rtl/pll/pll_0002.v, docs/HACKS.md).
module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM is driven by screen_rotate_two (HDMI framebuffer rotation), below.

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Required output once MISTER_FB is enabled; the rotator has no blanking need.
assign FB_FORCE_BLANK = 0;

// Signed 16-bit stereo: silkroad.cpp routes the YM2151's left and right to two speakers and
// both OKIs to each (461-473). The OSD's Audio mix: status 0 Mono (AUDIO_MIX 3), 1 None (0),
// 2 25% (1), 3 50% (2).
assign AUDIO_S   = 1;
assign AUDIO_MIX = status[80:79] - 2'd1;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
// Debug OSD page visibility: every P1 line carries an H1 prefix, so the
// whole page is hidden when status_menumask bit 1 is set. The bit tracks
// the DEBUG_ISSP macro (defined only by the Silkroad_stp revision), so the
// instrumented build shows the Debug page and the release build hides it --
// same source, no code removed, the status bits still function if set by
// a .CFG (only the MENU is hidden).
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
localparam DEBUG_TRACER_EN = 1'b1;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
// Release: the debug tracer (trace buffers, overlay dump bands) compiles
// out entirely alongside the hidden menu -- BRAM back, no debug logic.
localparam DEBUG_TRACER_EN = 1'b0;
`endif
wire debug_menu_hide = DEBUG_MENU_HIDE;

localparam CONF_STR = {
	"Silkroad;;",
	"-;",
	"H5O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H5O[48:47],Orientation,Auto,Off,CW,CCW;",
	"O[49],Flip Screen,Off,On;",
	"H5O[93:91],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"H5O[94],Vertical crop,Disabled,216p (5x);",
	"H5O[99:95],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H5O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[80:79],Audio mix,Mono,None,25%,50%;",
	"H3O[78],Autosave Hiscores,Off,On;",
	"O[64],CRT Adjust,Off,On;",
	"H2O[71:65],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[77:72],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[85:81],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[89:86],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[90],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[56],Trace overlay,Off,On;",
	"H1P1O[58:57],Trace source,CPU addr+data,CPU fetch addr,SpriteRAM wr,Palette wr;",
	"H1P1O[62:59],Trace window,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"H1P1O[63],Re-arm capture,A,B;",
	"H1P1-;",
	"H1P1O[40],Sprites,On,Off;",
	"H1P1O[41],Tilemap 0,On,Off;",
	"H1P1O[42],Tilemap 1,On,Off;",
	"H1P1O[43],Tilemap 2,On,Off;",
	"H1P1O[54],Frame-count auto-pause,Off,On;",
	"-;",
	"R[0],Reset;",
	// The joystick bits: buttons at 4-9, Start 10, Coin 11, Pause 12, Service 13. The .mra's
	// <buttons> list assigns them and pads the unused button slots with "-" so these stay put
	// (scripts/build_mra.py); this line only has to agree with it.
	"J1,Button 1,Button 2,Button 3,-,-,-,Start,Coin,Pause,Service;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire         direct_video;
wire         video_rotated;
wire  [15:0] core_audio_l, core_audio_r;   // silkroad_core's mix
wire         vga_de_raw;
wire  [21:0] gamma_bus;
wire  [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire [31:0] joystick_0, joystick_1;

wire         ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
wire         ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire         ioctl_wait;

// NOTE: hps_io stays in BYTE mode (no WIDE). WIDE(1) would halve the
// HPS-side transfers, but sys/hiscore.v parses the ioctl stream a byte at
// a time (field positions from ioctl_addr[2:0], byte-cascaded registers)
// and returns 8-bit upload data, so it cannot run on a 16-bit ioctl.
// ROM loading is sped up on the SDRAM side instead -- sdram_download
// coalesces byte pairs into single word writes, which also halves the
// ioctl_wait stalls since even bytes are accepted without any SDRAM
// transaction at all.
hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	// H1 the Debug page; H2 CRT Adjust's settings while it is off; H3 hiscore autosave unless the
	// .mra carried hiscore data; H5 the HDMI scaler's options under direct video
	.status_menumask({direct_video, 1'b0, ~hs_configured, ~status[64], debug_menu_hide, status[5]}),
	.direct_video(direct_video),
	// the rotator's state, so the MiSTer main knows the HDMI picture is rotated (screenshot
	// aspect, vfilter_vertical_default)
	.video_rotated(video_rotated),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// hiscore save/restore (rtl/hiscore.v): index 3 is the config the .mra
	// carries, index 4 the saved score dump read back and written out.
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// clk_sys = 48 MHz, clk_sdram = 96 MHz in phase with it, for the SDRAM controller alone
// (rtl/pll/pll_0002.v; docs/ROADMAP.md, Clocks).
//
// outclk_2 is SDRAM_CLK, 96 MHz 252 degrees behind clk_sdram (rtl/pll/pll_0002.v for why).
// The phase decides which burst beat each read lane captures; simulation cannot catch a
// wrong one, the chip model has no notion of clock phase. It drives the SDRAM_CLK pin
// directly; silkroad_top's SDRAM_CLK output is the simulation placeholder.
wire clk_sys, clk_sdram, clk_sdram_shifted, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_sdram_shifted),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

// ce_pix: 48 MHz / 6 = 8 MHz = 32 MHz / 4, the pixel clock chosen in docs/HACKS.md
// (not measured on a PCB).
reg [2:0] ce_pix_cnt = 0;
wire       ce_pix = (ce_pix_cnt == 0);
always @(posedge clk_sys) ce_pix_cnt <= (ce_pix_cnt == 3'd5) ? 3'd0 : ce_pix_cnt + 3'd1;

// ldr_active is deliberately NOT in `reset` -- rom_loader is itself reset by
// it. The core sees the copy as an extended download instead.
wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// Do NOT add ldr_active to this reset. The loader writes SDRAM THROUGH
// silkroad_top (ldr_req/ldr_addr/ldr_data), so it would hold
// silkroad_sdram_top in reset too and the copy would write nothing (tried in
// the Psikyo core: black screen). silkroad_top holds only the CPU and video
// logic during the copy (its core_reset). The rotator is protected by gating
// its DDRAM_BUSY (see below).

///////////////////////   INPUTS   ////////////////////////////////

// silkroad.cpp INPUT_PORTS_START( silkroad ), all IP_ACTIVE_LOW (hence the `~`: hps_io's
// joystick bits are active high):
//   bits 31-24  P1 UP, DOWN, RIGHT, LEFT, B1, B2, B3, unused
//   bits 23-16  P2 UP, DOWN, RIGHT, LEFT, B1, B2, B3, unused
//   bits 15-8   unknown (bit 8 "makes the 020 lock up", 350): held high, as MAME's defaults
//   bit 7       IPT_CUSTOM with no handler: reads 1 in MAME (docs/boot_trace_mame.txt)
//   bits 6-0    SERVICE2, TEST, SERVICE1, START2, START1, COIN2, COIN1. TEST is the test
//               switch (PORT_SERVICE_NO_TOGGLE, 345), on the Service button (bit 13) and F2;
//               SERVICE1 and 2 are service coins, on keys 9 and 0, as MAME has them.
// Joystick bit numbering comes from the .mra <buttons> list (names map from
// bit 4), which must put Start at 10 and Coin at 11 -- see pause_btn.
// MAME's default keys alongside the pads (rtl/mame_keys.sv): arrows, LCtrl LAlt Space, 1 start,
// 5 coin for player 1; R F D G, A S Q, 2, 6 for player 2; P pause, F2 test, 9 and 0 service.
wire [31:0] key0, key1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(3), .START(10), .COIN(11), .PAUSE(12), .SERVICE(13)) u_mame_keys (
	.clk(clk_sys), .ps2_key(ps2_key), .key0(key0), .key1(key1), .svc_coin(svc_coin)
);
wire [31:0] joy0 = joystick_0 | key0;
wire [31:0] joy1 = joystick_1 | key1;

wire [31:0] p1p2_in = {
	~joy0[3], ~joy0[2], ~joy0[0], ~joy0[1],  // P1 UP,DOWN,RIGHT,LEFT
	~joy0[4], ~joy0[5], ~joy0[6], 1'b1,      // P1 B1,B2,B3
	~joy1[3], ~joy1[2], ~joy1[0], ~joy1[1],  // P2 UP,DOWN,RIGHT,LEFT
	~joy1[4], ~joy1[5], ~joy1[6], 1'b1,      // P2 B1,B2,B3
	8'hFF,
	1'b1,                                    // custom (no handler in the driver)
	~svc_coin[1],                            // SERVICE2
	~(joy0[13] | joy1[13]),                  // TEST
	~svc_coin[0],                            // SERVICE1
	~joy1[10], ~joy0[10],                    // START2, START1
	~joy1[11], ~joy0[11]                     // COIN2, COIN1
};

// DIP switches: silkroad.cpp's DSW port has SWA in bits 23-16 and SWB in 31-24 (380-415);
// bits 15-0 have no fields and read 0.
//
// DIP switches arrive as an ioctl download with index 254 (8 bytes, LE
// uint64), NOT through the status word -- see mra_loader.cpp's
// arcade_sw_send(). Saved state lives in config/dips/<mra name>, not the .CFG.
// The .mra's <switches> default byte 0 is SWA (port bits 23-16), byte 1 SWB (31-24).
reg [63:0] dip_sw;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 254) && !ioctl_addr[24:3])
		dip_sw[{ioctl_addr[2:0], 3'b000} +: 8] <= ioctl_dout;
end

wire [15:0] dsw16  = dip_sw[15:0];

// .mra mod byte, <rom index="1">: bits 2:1 = the set's orientation (0 ROT0, 1 ROT90,
// 2 ROT270); both sets are ROT0. Latched, not reset by `reset`: MiSTer holds reset through
// the download.
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd1) && (ioctl_addr == 27'd0)) mod_byte <= ioctl_dout;
end
wire [31:0] dsw_in = {dsw16, 16'h0000};

// ---- orientation, aspect, flip ----
// Orientation "Auto" follows the set's own (mod byte bits 2:1, from the GAME line: 0 ROT0,
// 1 ROT90, 2 ROT270); the aspect is 4:3, 3:4 when rotated, whatever the pixel count. ARY 0
// means "stretch" to video_freak.
wire [1:0]  game_rot   = mod_byte[2:1];
wire [1:0]  rot_sel    = status[48:47];   // Auto, Off, CW, CCW
wire        rotate_en  = (rot_sel == 2'd0) ? (game_rot != 2'd0) : (rot_sel != 2'd1);
wire        rotate_ccw = (rot_sel == 2'd0) ? (game_rot == 2'd2) : (rot_sel == 2'd3);
wire [1:0]  ar         = status[122:121];
wire [11:0] base_arx   = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : 12'({ar} - 2'd1);
wire [11:0] base_ary   = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;

// Flip screen: one flip in the core's video, so HDMI and analog show the same. The driver
// has no flip DIP; the .mra carries a fake one in DIP byte 2 bit 0, read here and not by the
// game. The OSD option and the fake DIP together flip twice.
wire        flip_screen = status[49] ^ dip_sw[16];

// ---- debug tracer controls (rtl/debug/debug_tracer.sv) ----
// Live from the OSD, so the capture window can be walked across a long boot
// WITHOUT a rebuild -- that is the whole point of the module. status[55] is a
// plain level whose CHANGE re-arms, so toggling it between A and B retriggers
// capture without resetting the core and disturbing CPU state.
// Bits placed in status[63:56] -- CFG byte 7 -- per docs/mister_framework_notes.md.
// Two constraints, both learned the hard way:
//   * The official docs state the classic O/o option syntax addresses bits
//     0-63 ONLY (O = upper 32, o = lower 32, i.e. +32). Bits placed at 64-71
//     were outside that window and the source select never responded.
//   * At the time, DIPs were (wrongly) read from the status word, so bits
//     48-55 were contested. DIPs now arrive via ioctl index 254 and consume
//     no status bits, but these controls are left where they are.
// status[63:56] is above the DIP range and inside the documented window, and
// still lands in a single CFG byte so all four controls are one byte write to
// /media/fat/config/<core>.CFG:
//   bit0 overlay, bits2:1 source, bits6:3 window, bit7 re-arm
wire        dbg_overlay = status[56];

// Force-disable rendering per pipeline, for isolating what is actually drawing
// what. status[55:40] is free: the .mra's three <switches> bytes occupy
// status[39:16] and the tracer controls sit at status[63:56].
//   [0] sprites  [1] tilemap layer 0  [2] tilemap layer 1
wire [3:0] dbg_render_dis = status[43:40];
// Freeze the 68020 so a frame can be captured and compared against a MAME dump
// of the same moment. Video and the debug overlay keep running.
// Pause is toggled by the Pause button rather than an OSD entry.
//
// The bit comes from the .mra's <buttons> element, NOT from CONF_STR's J1 list
// -- when an .mra declares buttons, that mapping governs:
//
//   names="Button 1,Button 2,Button 3,-,-,-,Start,Coin,Pause"
//
// Names map to joystick bits from bit 4, so the three "-" placeholders pad
// positions 3-5 and put Start at 10, Coin at 11 (which is exactly what the
// input wiring below already uses) and Pause at 12 -- the bit is a function
// of THIS .mra's button list, never a constant copied from another core's.
//
// Edge-triggered toggle, not a level: the button is momentary, so holding it
// would only pause while held.
wire        pause_btn = joy0[12] | joy1[12];
`ifdef DEBUG_ISSP
// Frame-count auto-pause enable (rtl/silkroad_core.sv). Off by default, so
// it never fires unless turned on from the OSD.
wire        dbg_autopause_frame_en = status[54];
`endif
reg         pause_btn_d, pause;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                        pause <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause <= ~pause;
end
// The CPU is also paused while hiscore touches work RAM; it borrows the CPU's
// RAM port for writes, so the core must actually be stopped first. hiscore
// waits ACCESS_PAUSEPAD cycles after asserting this before it reads or writes.
wire pause_core = pause | hs_pause;
wire [1:0] dbg_src     = status[58:57];
wire [3:0] dbg_window  = status[62:59];
wire        dbg_rearm   = status[63];
wire [23:0] dbg_pixel;

// ---- MAME hiscore.dat support (rtl/hiscore.v) ----
// Restores the score table into work RAM once the game has initialised it,
// and reads it back out to be saved. The .mra carries the hiscore.dat entry
// as rom index 3 (address/length plus the start/end sentinel bytes that
// tell the module the table is initialised and safe to write); index 4 is
// the saved dump. With no index-3 data the module stays unconfigured and
// nothing ever touches game RAM.
//
// HS_ADDRESSWIDTH=17: the entries are 0xFExxxx and work RAM is the 128KB at
// 0xFE0000, so the low 17 bits of the configured address ARE the offset.
// HS_SCOREWIDTH=8: a table of up to 256 bytes.
wire        hs_configured;
wire [16:0] hs_address;
wire  [7:0] hs_data_in, hs_data_out;
wire        hs_write;
wire        hs_read;
wire        hs_pause;

hiscore #(
	.HS_ADDRESSWIDTH(17),
	.HS_SCOREWIDTH(8),
	// One hiscore.dat entry per game here, so the config tables are tiny;
	// the default depth of 16 cost four whole M10K blocks and this design
	// is BRAM-bound (the fitter reported 553/553 with logic at 40%).
	.CFG_ADDRESSWIDTH(2),
	.CFG_LENGTHWIDTH(1)
) u_hiscore (
	.clk(clk_sys),
	.reset(reset),
	.paused(pause_core),
	.autosave(status[78]),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_index(ioctl_index[7:0]),
	.OSD_STATUS(OSD_STATUS),
	.data_from_hps(ioctl_dout),
	.data_from_ram(hs_data_out),
	.ram_address(hs_address),
	.data_to_hps(ioctl_din),
	.data_to_ram(hs_data_in),
	.ram_write(hs_write),
	.ram_intent_read(hs_read),
	.ram_intent_write(),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

///////////////////////   VIDEO   ///////////////////////////////

wire [8:0] hcnt, vcnt;
wire        hblank, vblank, hsync, vsync;

wire [14:0] rgb;


silkroad_top #(.DEBUG_TRACER(DEBUG_TRACER_EN)) silkroad_top
(
	.clk(clk_sys),
	.clk_sdram(clk_sdram),
	.ce_pix(ce_pix),
	.reset(reset),
	.init(~pll_locked),

	.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(), // real pin driven directly from clk_sdram_shifted above
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.p1p2_in(p1p2_in),
	.dsw_in(dsw_in),
	.flip(flip_screen),
	.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
	.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),

	.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
	.hsync(hsync), .vsync(vsync), .rgb(rgb), .audio_l(core_audio_l), .audio_r(core_audio_r),

	.dbg_overlay(dbg_overlay), .dbg_render_dis(dbg_render_dis), .pause(pause_core),
	.hs_address(hs_address), .hs_data_in(hs_data_in),
	.hs_data_out(hs_data_out), .hs_read(hs_read), .hs_write(hs_write),
`ifdef DEBUG_ISSP
	.dbg_autopause_frame_en(dbg_autopause_frame_en),
`endif
	.dbg_src(dbg_src), .dbg_window(dbg_window), .dbg_rearm(dbg_rearm),
	.dbg_pixel(dbg_pixel)
);

// ---- video output via sys/arcade_video.v ----
// This core used to drive VGA_R/G/B, VGA_DE/HS/VS, CLK_VIDEO and CE_PIXEL by
// hand, bypassing the framework's video path entirely. That worked, but gave
// up everything arcade_video provides: the scandoubler (so a VGA/CRT setup got
// no 31 kHz option), gamma correction, scanline effects, and video_freak's
// aspect-ratio and cropping handling. sys/arcade_video.v, video_mixer.sv and
// video_freak.sv were all sitting in the tree unused.
//
// The picture is xRGB_555 internally; arcade_video takes a packed bus, so each
// 5-bit channel is expanded to 8 by replicating its top bits (NOT zero-padded,
// which would darken full-brightness colours).
//
// The debug overlay is injected BEFORE arcade_video so it still works, but note
// that scanlines/gamma will alter the pixel values the decoder reads -- keep
// fx=0 and gamma off when capturing a trace, or the decode is meaningless.
// ---- CRT Adjust (rtl/video/crt_chain.sv) ----
// Slides the picture on an analog CRT without ever touching the sync: the
// CONTENT is moved inside a line buffer while HSync/VSync stay native, so the
// monitor keeps its lock while you adjust. Sits between the core's raster and
// arcade_video, so (as the module documents for the core-side variant) HDMI
// follows the adjustment too -- leave CRT Adjust Off for an untouched HDMI
// image. NOTE this core is rotated: on the HDMI/rotated output H-Position
// moves the image vertically and V-Shift horizontally, since both act on the
// NATIVE raster, which is what a real CRT in a TATE cabinet wants.
// H-Size and V-Size are 15 kHz only; PVM-mode V-Size retimes the lines.
wire crt_adj_on   = status[64];
wire crt_scale_en = ~(forced_scandoubler | |status[46:44]);
// H-Position: the OSD stores the INDEX into the option list, and that list has
// 97 entries (0, +1..+48, -48..-1) -- so the negative half wraps at 97, NOT at
// 128. Raiden hit exactly this: wrapping at 128 made "-1" jump 32 pixels.
wire  [6:0] crt_hpos_idx = status[71:65];
wire signed [8:0] crt_hoffset = (crt_hpos_idx <= 7'd48)
	? $signed({2'b00, crt_hpos_idx})
	: $signed({2'b00, crt_hpos_idx}) - 9'sd97;
// V-Shift is a plain signed 6-bit field: its 64-entry list (0..+31, -32..-1)
// IS two's complement, so no wrap fixup is needed.
wire signed [5:0] crt_voffset = $signed(status[77:72]);
wire signed [4:0] crt_hsize   = $signed(status[85:81]);
// V-Size's list has 15 entries, so its negative half wraps at 15, not 16.
wire  [3:0] crt_vsz_idx  = status[89:86];
wire signed [3:0] crt_vsz_step = (crt_vsz_idx <= 4'd7)
	? $signed(crt_vsz_idx)
	: $signed(crt_vsz_idx - 4'd15);

wire       crt_ce;
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

crt_chain #(.HTOTAL(512), .VTOTAL(262), .ACTIVE_W(380), .RD_BASE(24)) crt_chain   // RD_BASE: 6 clk a pixel, x4
(
	.clk(clk_sys),
	.ce_pix(ce_pix),

	.active(crt_adj_on),
	.scale_en(crt_scale_en),
	.hoffset(crt_hoffset),
	.voffset(crt_voffset),
	.hsize(crt_hsize),
	.vsize_step(crt_vsz_step),
	.vsize_cabinet(status[90]),

	.r_in(r8_raw), .g_in(g8_raw), .b_in(b8_raw),
	.hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),

	.ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

wire [7:0] r8_raw = dbg_overlay ? dbg_pixel[23:16] : {rgb[14:10], rgb[14:12]};
wire [7:0] g8_raw = dbg_overlay ? dbg_pixel[15:8]  : {rgb[9:5],   rgb[9:7]};
wire [7:0] b8_raw = dbg_overlay ? dbg_pixel[7:0]   : {rgb[4:0],   rgb[4:2]};

arcade_video #(.WIDTH(380), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_ce),

	.RGB_in({crt_r, crt_g, crt_b}),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// ---- integer scaling, crop, aspect (sys/video_freak.sv) ----
// 216 of the 224 lines is exactly 5x on a 1080-line display.
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX(base_arx),
	.ARY(base_ary),
	.CROP_SIZE(status[94] ? 12'd216 : 12'd0),
	.CROP_OFF(status[99:95]),
	.SCALE(status[93:91])
);

// ---- Fast ROM loading (rtl/memory/rom_loader.sv) ----
// The .mra's <rom index="0"> carries address="0x30000000", which makes the HPS
// DMA the ROM straight into DDR3: the core sees ioctl_download assert and
// deassert with NO ioctl_wr pulses at all. That is how the mode is detected --
// if any ioctl_wr arrives for index 0 the .mra is an old byte-streaming one and
// sdram_download handles it exactly as before, so both kinds still load.
// (Mechanism from srg320/Arcade-PsikyoSH2_MiSTer.)
// Trigger, mirroring srg320/Arcade-PsikyoSH2_MiSTer: the copy is started out of
// RESET, not from a download-completion edge. With address=0x30000000 the HPS
// DMAs the ROM into DDR3 without the byte-wise ioctl handshake, so an
// end-of-download edge is not a signal the core can rely on seeing at all --
// which is why the first attempt loaded nothing and left SDRAM unwritten.
// MiSTer resets the core once the ROM is in place, so reset-release is the
// point at which DDR3 is known good.
//
// dl_seen_wr still selects the mode: if any ioctl_wr arrived for index 0 the
// .mra is an old byte-streaming one, sdram_download has already filled SDRAM,
// and copying DDR3 over it would destroy a working load.
reg  dl_seen_wr  = 1'b0;   // any byte streamed through the FPGA for index 0
reg  dl_active_d = 1'b0;
reg  ldr_pending = 1'b0;
reg  ldr_start   = 1'b0;
reg  ldr_done    = 1'b0;
wire dl_index0 = ioctl_download && (ioctl_index == 16'd0);
always @(posedge clk_sys) begin
	ldr_start   <= 1'b0;
	dl_active_d <= dl_index0;
	if (dl_index0 && !dl_active_d)  dl_seen_wr <= 1'b0;   // a new index-0 load begins
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;   // ...and it is streaming bytes

	// A new index-0 download is the only thing that makes a copy due again.
	if (dl_index0 && !dl_active_d) ldr_done <= 1'b0;

	if (reset) begin
		ldr_pending <= 1'b1;
	end else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		// Only when the ROM did NOT come through the byte path, and only once
		// per download: dl_seen_wr stays 0 forever after a DDR3 load, so
		// without ldr_done every later reset -- OSD reset, the reset button,
		// a PLL relock -- would recopy all 18.5MB with the bus taken from the
		// rotator mid-picture.
		if (!dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

wire        ldr_active;
wire        ldr_req, ldr_we16, ldr_busy;
wire [24:0] ldr_addr;
wire [15:0] ldr_data;
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;

rom_loader #(.LENGTH(28'h1AC0000)) u_rom_loader (   // silkroad_sdram_top ROM_END
	.clk(clk_sys), .reset(reset),
	.start(ldr_start), .busy(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.dl_req(ldr_req), .dl_addr(ldr_addr), .dl_data(ldr_data),
	.dl_we16(ldr_we16), .dl_busy(ldr_busy)
);

// DDR3 read port for the loader. DDRAM is otherwise owned by the rotator, so
// the physical pins are muxed below: the loader only runs with the core in
// reset, when there is no picture to rotate.
wire [7:0]  ldr_DDRAM_BURSTCNT;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;
wire [7:0]  ldr_DDRAM_BE;

ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);

`ifdef DEBUG_ISSP
// Fast ROM load visibility. The first attempt produced an unbootable core with
// no way to tell whether the copy never ran or ran against the wrong data, so
// the loader now reports its own progress. reset is tied low so the counters
// survive the core resets that bracket a load.
issp_probe #(.INSTANCE_ID("L")) u_issp_loader (
	.clk(clk_sys),
	.wr_issued(ldr_start),               // times the copy was started
	.wr_acked(ldr_ddr_valid),            // DDR3 granules actually returned
	.cpu_rd_acked(ldr_req & ~ldr_busy),  // SDRAM word writes issued
	.cpu_rd_nonzero(1'b1),
	.sdram_ready(ldr_active),
	.dl_req(dl_seen_wr),                 // 1 = the byte path was used
	.ioctl_download(dl_index0),
	.reset(1'b0),
	.cpu_rd_addr({4'd0, ldr_addr[24:10]}),
	.cpu_rd_data(ldr_data)
);
`endif

// ---- HDMI rotation / flip via the HPS framebuffer (sys DDRAM) ----
// Orientation and the OSD's Flip 180 are handled here, for HDMI only. Flip
// screen in the video pipeline (silkroad_core.sv's flip_screen) is
// separate and reaches the CRT raster as well.
//
// screen_rotate_two is Sorgelig's standard MiSTer rotator (GPL v2), taken
// from Arcade-SKNS_MiSTer. It is a TAP, not a filter:
// VGA_R/G/B/HS/VS/DE still drive the analog output directly for CRT use,
// while this writes a rotated (and optionally 180-flipped) copy into DDRAM
// and points the HPS framebuffer at it for HDMI. So CRT keeps the native
// raster and HDMI gets rotation and flip, which is why this also gives us
// flip "for free" without touching the tilemap or sprite paths.
//
// The rotator owns DDRAM. two_screen is 0 -- an SKNS-specific dual-screen
// mode.

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO     (CLK_VIDEO),
	.CE_PIXEL      (CE_PIXEL),

	.VGA_R         (VGA_R),
	.VGA_G         (VGA_G),
	.VGA_B         (VGA_B),
	.VGA_HS        (VGA_HS),
	.VGA_VS        (VGA_VS),
	.VGA_DE        (VGA_DE),

	.rotate_ccw    (rotate_ccw),
	.no_rotate     (~rotate_en),
	.flip          (1'b0),   // flip is the core's (flip_screen), for both outputs
	.two_screen    (1'b0),
	.video_rotated (video_rotated),

	.FB_EN         (FB_EN),
	.FB_FORMAT     (FB_FORMAT),
	.FB_WIDTH      (FB_WIDTH),
	.FB_HEIGHT     (FB_HEIGHT),
	.FB_BASE       (FB_BASE),
	.FB_STRIDE     (FB_STRIDE),
	.FB_VBL        (FB_VBL),
	.FB_LL         (FB_LL),

	.DDRAM_CLK     (rot_DDRAM_CLK),
	// Held busy while the loader owns the bus. The mux below routes the
	// rotator's writes away from DDR3 during a copy, but it still samples
	// DDRAM_BUSY to decide whether each write was accepted -- and between
	// loader transactions BUSY is low, so it would take phantom writes as
	// accepted and advance its pointer, leaving a stale band in the frame
	// buffer at a fixed position. It has no reset port, so nothing
	// recovers that. Holding BUSY makes it stall and retry instead.
	.DDRAM_BUSY    (DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR    (rot_DDRAM_ADDR),
	.DDRAM_DIN     (rot_DDRAM_DIN),
	.DDRAM_BE      (rot_DDRAM_BE),
	.DDRAM_WE      (rot_DDRAM_WE),
	.DDRAM_RD      (rot_DDRAM_RD)
);

// DDRAM pin mux: the ROM loader takes the bus while it is copying (core in
// reset, nothing to display), the rotator has it the rest of the time.
wire        rot_DDRAM_CLK;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
wire        rot_DDRAM_WE, rot_DDRAM_RD;

assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

// The core's stereo mix (rtl/sound/silkroad_sound.sv)
assign AUDIO_L = core_audio_l;
assign AUDIO_R = core_audio_r;

endmodule
