// The complete SDRAM backend: one SDRAM chip (rtl/memory/sdram/sdram.sv), its 3 physical ports
// wrapped in req/valid (rtl/memory/sdram_phy.sv). Port 0 is the tilemaps', Port 1 the sprites',
// one client each; Port 2 is shared by the OKI sample caches, the main CPU and the ROM download
// (rtl/memory/sdram_arbiter6.sv), the CPU through rtl/memory/sdram_narrow_bridge.sv, the download
// through rtl/memory/sdram_download.sv. This module adds each region's base to the clients'
// offsets; the *_BASE localparams are the layout scripts/build_mra.py builds the .mra from.
//
// sdram.sv alone runs on clk_sdram, twice clk with its rising edges aligned (one PLL); the
// three sdram_phy wrappers and every client stay on clk. sdram.sv's ports are toggle
// handshakes whose address, data and request are registers on one side and whose ack and
// dout are registers on the other, so each crossing is a register-to-register path between
// related clocks that STA times; sdram_phy keeps its own copy of the granule, since dout is
// shared by the three ports and the next read overwrites it.
module silkroad_sdram_top (
	input  logic clk,
	input  logic clk_sdram,
	input  logic reset,
	input  logic init,

	output logic [12:0] SDRAM_A,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic [1:0]  SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_CLK,
	output logic         SDRAM_CKE,
	inout  wire [15:0]  SDRAM_DQ,

	// HPS ROM download (hps_io's real ioctl_* interface -- see
	// rtl/memory/sdram_download.sv's own header).
	input  logic         ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic         ioctl_wr,
	input  logic [24:0] ioctl_addr,
	input  logic [7:0]  ioctl_dout,
	output logic         ioctl_wait,

	// Fast ROM load: rom_loader drives the SDRAM write port directly while
	// ldr_active is high, in place of the byte-wise ioctl path. Both cannot
	// run at once -- ldr_active is only asserted once the HPS has finished
	// DMAing the ROM into DDR3, and the core is held in reset throughout.
	input  logic         ldr_active,
	input  logic         ldr_req,
	input  logic [24:0] ldr_addr,
	input  logic [15:0] ldr_data,
	input  logic         ldr_we16,
	output logic         ldr_busy,

	// Graphics ROM: the tilemaps on Port 0, the sprites on Port 1, one client each. *_b selects
	// region B, *_off is the 8-aligned byte offset in the region; held requests.
	input  logic         tm_gfx_req,
	input  logic         tm_gfx_b,
	input  logic [23:0] tm_gfx_off,
	output logic         tm_gfx_valid,
	output logic [63:0] tm_gfx_data,
	input  logic         sp_gfx_req,
	input  logic         sp_gfx_b,
	input  logic [23:0] sp_gfx_off,
	output logic         sp_gfx_valid,
	output logic [63:0] sp_gfx_data,

	// maincpu program fetch -- Port 2, arbiter client c2.
	input  logic         cpu_rom_req,
	input  logic [19:0] cpu_rom_addr,     // word address, 2 MB
	output logic         cpu_rom_valid,
	output logic [15:0] cpu_rom_data,

	// OKI sample ROMs: {bank, chip address} bytes, held req (oki_rom_bridge)
	input  logic         oki1_rom_req,
	input  logic [19:0] oki1_rom_addr,
	output logic         oki1_rom_valid,
	output logic [7:0]  oki1_rom_data,
	input  logic         oki2_rom_req,
	input  logic [19:0] oki2_rom_addr,
	output logic         oki2_rom_valid,
	output logic [7:0]  oki2_rom_data
);

	// Byte offsets into the 32 MB SDRAM chip, each region sized for the
	// largest set (docs/HARDWARE_NOTES.md). scripts/build_mra.py reads these
	// localparams: they are the single source of the .mra layout.
	// gfx region A: thirds 0 and 1 of MAME's "gfx" interleaved by 32 bits, so a tile row's
	// planes 5-2 are one 8-byte granule at tile * 128 + row * 8; region B: third 2 as it is,
	// planes 1-0 at tile * 64 + row * 4 (docs/ROADMAP.md, Memory plan; checked against MAME's
	// decode by scripts/gfx_layout_check.py). Tiles 0x00000-0x17FFF are sprites, 0x18000 up
	// background tiles. Neither is inverted here: ROMREGION_INVERT is applied in the decode.
	localparam logic [24:0] GFXA_BASE      = 25'h0000000;   // 16 MB
	localparam logic [24:0] GFXB_BASE      = 25'h1000000;   // 8 MB
	localparam logic [24:0] MAINCPU_BASE   = 25'h1800000;   // 2 MB
	localparam logic [24:0] OKI1_BASE      = 25'h1A00000;   // 512 KB
	localparam logic [24:0] OKI2_BASE      = 25'h1A80000;   // 256 KB
	localparam logic [24:0] ROM_END        = 25'h1AC0000;

	// ---- raw SDRAM chip, 3 physical ports ----
	logic [24:1] p0_addr, p1_addr, p2_addr;
	logic         p0_wrl, p0_wrh, p1_wrl, p1_wrh, p2_wrl, p2_wrh;
	logic [15:0] p0_din, p1_din, p2_din;
	logic [63:0] p0_dout, p1_dout, p2_dout;
	logic         p0_req, p1_req, p2_req;
	logic         p0_ack, p1_ack, p2_ack;

	// refresh every 748 clk_sdram cycles, 7.79 us at 96 MHz
	sdram #(.RFS_INTERVAL(748)) mem_ctrl (
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.init(init), .clk(clk_sdram),
		// byte address bit 25 (64 MB modules) unused: 32 MB map
		.addr0({1'b0, p0_addr}), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .req0(p0_req), .ack0(p0_ack),
		.addr1({1'b0, p1_addr}), .wrl1(p1_wrl), .wrh1(p1_wrh), .din1(p1_din), .dout1(p1_dout), .req1(p1_req), .ack1(p1_ack),
		.addr2({1'b0, p2_addr}), .wrl2(p2_wrl), .wrh2(p2_wrh), .din2(p2_din), .dout2(p2_dout), .req2(p2_req), .ack2(p2_ack)
	);

	// ---- Ports 0 and 1: the tilemaps and the sprites, one client each ----
	//
	// Each client holds its request until valid and drops it on the clock valid arrives
	// (silkroad_tilemaps, silkroad_sprites). sdram_phy wants a pulse while !busy, and its valid
	// lands on the clock it returns to idle, where it would re-sample a still-high request; the
	// shim below issues once per request and returns to idle only on valid, so a held request
	// is one read (in the Psikyo core a client wired straight to sdram_phy made a second read
	// on the clock valid pulsed). Granules reach the clients as the chip packs them, byte n of
	// the granule in bits 8n+7:8n.
	function automatic logic [24:0] gfx_addr(input logic b, input logic [23:0] off);
		gfx_addr = b ? (GFXB_BASE + {1'b0, off}) : (GFXA_BASE + {1'b0, off});
	endfunction

	typedef enum logic [1:0] {G_IDLE, G_ISSUE, G_WAIT} gstate_t;
	gstate_t      g0_st, g1_st;
	logic         g0_phy_req, g0_busy, g1_phy_req, g1_busy;

	assign g0_phy_req = (g0_st == G_ISSUE) && !g0_busy;
	assign g1_phy_req = (g1_st == G_ISSUE) && !g1_busy;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			g0_st <= G_IDLE;
			g1_st <= G_IDLE;
		end else begin
			case (g0_st)
				G_IDLE:  if (tm_gfx_req) g0_st <= G_ISSUE;
				G_ISSUE: if (!g0_busy)   g0_st <= G_WAIT;
				G_WAIT:  if (tm_gfx_valid) g0_st <= G_IDLE;
				default: g0_st <= G_IDLE;
			endcase
			case (g1_st)
				G_IDLE:  if (sp_gfx_req) g1_st <= G_ISSUE;
				G_ISSUE: if (!g1_busy)   g1_st <= G_WAIT;
				G_WAIT:  if (sp_gfx_valid) g1_st <= G_IDLE;
				default: g1_st <= G_IDLE;
			endcase
		end
	end

	sdram_phy phy0 (
		.clk(clk), .reset(reset),
		.port_addr(p0_addr), .port_wrl(p0_wrl), .port_wrh(p0_wrh),
		.port_din(p0_din), .port_dout(p0_dout), .port_req(p0_req), .port_ack(p0_ack),
		.req(g0_phy_req), .we(1'b0), .we16(1'b0), .addr(gfx_addr(tm_gfx_b, tm_gfx_off)), .wdata(16'd0),
		.busy(g0_busy), .valid(tm_gfx_valid), .rdata(tm_gfx_data)
	);

	sdram_phy phy1 (
		.clk(clk), .reset(reset),
		.port_addr(p1_addr), .port_wrl(p1_wrl), .port_wrh(p1_wrh),
		.port_din(p1_din), .port_dout(p1_dout), .port_req(p1_req), .port_ack(p1_ack),
		.req(g1_phy_req), .we(1'b0), .we16(1'b0), .addr(gfx_addr(sp_gfx_b, sp_gfx_off)), .wdata(16'd0),
		.busy(g1_busy), .valid(sp_gfx_valid), .rdata(sp_gfx_data)
	);

	// ---- Port 2: arbiter (spritelut, maincpu, download) ----
	logic         p2phy_req, p2phy_we, p2phy_busy, p2phy_valid;
	logic [24:0] p2phy_addr;
	logic [15:0] p2phy_wdata;
	logic        p2phy_we16;
	logic [63:0] p2phy_rdata;

	sdram_phy phy2 (
		.clk(clk), .reset(reset),
		.port_addr(p2_addr), .port_wrl(p2_wrl), .port_wrh(p2_wrh),
		.port_din(p2_din), .port_dout(p2_dout), .port_req(p2_req), .port_ack(p2_ack),
		.req(p2phy_req), .we(p2phy_we), .we16(p2phy_we16), .addr(p2phy_addr), .wdata(p2phy_wdata),
		.busy(p2phy_busy), .valid(p2phy_valid), .rdata(p2phy_rdata)
	);

	logic         c0_req, c1_req, c2_req, c3_req, c4_req;
	logic [24:0] c0_addr, c1_addr, c2_addr, c3_addr, c4_addr;
	logic         c0_valid, c1_valid, c2_valid, c3_valid, c4_valid;
	logic [63:0] c0_data, c1_data, c2_data, c3_data, c4_data;
	logic         dl_req, dl_busy;
	logic [24:0] dl_addr;
	logic [15:0] dl_data;
	logic        dl_we16;
	logic         arb_dl_req, arb_dl_we16, arb_dl_busy;
	logic [24:0] arb_dl_addr;
	logic [15:0] arb_dl_data;

	sdram_arbiter6 u_arbiter (
		.clk(clk), .reset(reset),
		.phy_req(p2phy_req), .phy_we(p2phy_we), .phy_we16(p2phy_we16), .phy_addr(p2phy_addr), .phy_wdata(p2phy_wdata),
		.phy_busy(p2phy_busy), .phy_valid(p2phy_valid), .phy_rdata(p2phy_rdata),
		.c0_req(c0_req), .c0_addr(c0_addr), .c0_valid(c0_valid), .c0_data(c0_data),
		.c1_req(c1_req), .c1_addr(c1_addr), .c1_valid(c1_valid), .c1_data(c1_data),
		.c2_req(c2_req), .c2_addr(c2_addr), .c2_valid(c2_valid), .c2_data(c2_data),
		.c3_req(c3_req), .c3_addr(c3_addr), .c3_valid(c3_valid), .c3_data(c3_data),
		.c4_req(c4_req), .c4_addr(c4_addr), .c4_valid(c4_valid), .c4_data(c4_data),
		.dl_req(arb_dl_req), .dl_addr(arb_dl_addr), .dl_data(arb_dl_data),
		.dl_we16(arb_dl_we16), .dl_busy(arb_dl_busy)
	);

	// Bulk loader wins the write port whenever it is running; otherwise the
	// ioctl download path keeps it, so an .mra without the DDR3 address
	// attribute still loads exactly as before.
	assign arb_dl_req   = ldr_active ? ldr_req   : dl_req;
	assign arb_dl_addr  = ldr_active ? ldr_addr  : dl_addr;
	assign arb_dl_data  = ldr_active ? ldr_data  : dl_data;
	assign arb_dl_we16  = ldr_active ? ldr_we16  : dl_we16;
	assign dl_busy      = ldr_active ? 1'b0      : arb_dl_busy;
	assign ldr_busy     = ldr_active ? arb_dl_busy : 1'b0;

	// c0, c4: the two OKIs' sample streams, which sdram_arbiter6 serves ahead of the round
	// robin. jt6295 does not wait for a miss (sample_cache.sv), so each chip's four channels
	// keep their own granules with next-granule prefetch. OKI 1's 256 KB space maps onto its
	// 512 KB ROM as oki_map (silkroad.cpp:334-337): below 0x20000 directly, 0x20000-0x3FFFF to
	// ROM 0x20000 + bank x 0x20000 (machine_start, 439). OKI 2 reads its 256 KB ROM directly.
	// The address is {bank, the chip's 18 bits}.
	function automatic logic [18:0] oki_rom_offset(input logic [19:0] a);
		oki_rom_offset = (a[17:0] < 18'h20000) ? {1'b0, a[17:0]} : {1'b0, a[17:0]} + {a[19:18], 17'h00000};
	endfunction

	logic [25:0] oki1_g_addr, oki2_g_addr;
	sample_cache #(.ENTRIES(8)) u_oki1_cache (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(oki1_rom_req), .addr({1'b0, OKI1_BASE + {6'd0, oki_rom_offset(oki1_rom_addr)}}),
		.valid(oki1_rom_valid), .data(oki1_rom_data),
		.g_req(c0_req), .g_addr(oki1_g_addr), .g_valid(c0_valid), .g_data(c0_data)
	);
	sample_cache #(.ENTRIES(8)) u_oki2_cache (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(oki2_rom_req), .addr({1'b0, OKI2_BASE + {7'd0, oki2_rom_addr[17:0]}}),
		.valid(oki2_rom_valid), .data(oki2_rom_data),
		.g_req(c4_req), .g_addr(oki2_g_addr), .g_valid(c4_valid), .g_data(c4_data)
	);
	assign c0_addr = oki1_g_addr[24:0];
	assign c4_addr = oki2_g_addr[24:0];

	// c3: no client
	assign c3_req  = 1'b0;
	assign c3_addr = '0;

	// c1: no client
	assign c1_req  = 1'b0;
	assign c1_addr = '0;

	// c2: maincpu program fetch through its cache -- 16-bit word client, cpu_rom_addr is a WORD address.
	//
	// Byte swap at the maincpu-specific seam: sdram_narrow_bridge.sv packs 16-bit words
	// little-endian (EVEN byte address in the LOW byte), but the image holds the program as
	// the 68020 sees it, byte n at address n (MAME's big-endian "maincpu" region, which
	// ROM_LOAD32_WORD_SWAP fills). The swap lives here rather than in the bridge.
	logic [15:0] cpu_rom_data_le;
	assign cpu_rom_data = {cpu_rom_data_le[7:0], cpu_rom_data_le[15:8]};

	// rom_cache: 16 KB of program lines, so most of the CPU's fetches do not reach the chip the
	// tile and sprite engines share
	rom_cache u_cpu_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(cpu_rom_req), .addr(MAINCPU_BASE + {4'd0, cpu_rom_addr, 1'b0}),
		.valid(cpu_rom_valid), .data(cpu_rom_data_le),
		.g_req(c2_req), .g_addr(c2_addr), .g_valid(c2_valid), .g_data(c2_data)
	);

	// HPS ROM download -- ioctl_addr is already an absolute byte address
	// across the whole flat map, no per-region base to add here.
	sdram_download u_download (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
	);

endmodule
