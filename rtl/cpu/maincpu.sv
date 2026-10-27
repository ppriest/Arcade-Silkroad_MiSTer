// SPDX-License-Identifier: GPL-3.0-or-later
//
// Main CPU: 68EC020 at 16 MHz (silkroad.cpp:445). Drives the vendored TG68KdotC_Kernel
// directly (rtl/cpu/tg68k/, PROVENANCE.md; every kernel signal needs an explicit zero
// initializer, github.com/TobiFlex/TG68K.C/issues/21), plus address decode, BRAM-region
// ports and the held, autovectored level-4 vblank IRQ (irq4_line_hold, silkroad.cpp:447).
//
// The decode is silkroad.cpp's cpu_map (314-331). Program ROM (0x000000-0x1FFFFF, 2 MB) is
// req/valid; the BRAM regions are synchronous with one cycle of read latency. Unmapped reads
// return 0, MAME's default for a map without unmap_value_high; the video registers are
// write-only (329) and read 0.
//
// The 68EC020 has a 32-bit bus in MAME; TG68K's here is 16 bits, so a long access is two
// word cycles. The I/O handlers are bytes (324-328), each on its own byte lane; the game
// uses byte accesses there (docs/boot_trace_mame.txt).
//
// sim/maincpu_tb/tb_tg68k_isolate.sv runs the vendored kernel alone; sim/boot_tb runs
// silkroad's own boot against MAME's bus trace.
//
// IPL: the kernel inverts its IPL input (`IPL_nr <= NOT IPL`), so level 4 is
// requested by driving 3'b011, not 3'b100.

module maincpu (
	input  logic clk,
	input  logic reset,

	// program ROM, req/valid -- WORD address into the 2 MB region
	output logic         rom_req,
	output logic [19:0] rom_addr,
	input  logic         rom_valid,
	input  logic [15:0] rom_data,

	// sprite RAM (0x40C000-0x40CFFF, 2048 words), 1-cycle sync BRAM port
	output logic [10:0] spriteram_addr,
	output logic         spriteram_wel, spriteram_weh,
	output logic [15:0] spriteram_wdata,
	input  logic [15:0] spriteram_rdata,

	// palette RAM: 0x600000-0x603FFF, the upper word of each long only (umask32 0xffff0000,
	// silkroad.cpp:318), 4096 entries
	output logic [11:0] palette_addr,
	output logic         palette_wel, palette_weh,
	output logic [15:0] palette_wdata,
	input  logic [15:0] palette_rdata,

	// tilemap VRAM, 8192 words each: layer 0 0x800000-0x803FFF, layer 1 0x804000-0x807FFF,
	// layer 2 0x808000-0x80BFFF (silkroad.cpp:319-321). One address bus for all three.
	output logic [12:0] vram_addr,
	output logic [15:0] vram_wdata,
	output logic         vram0_wel, vram0_weh,
	input  logic [15:0] vram0_rdata,
	output logic         vram1_wel, vram1_weh,
	input  logic [15:0] vram1_rdata,
	output logic         vram2_wel, vram2_weh,
	input  logic [15:0] vram2_rdata,

	// video registers 0xC0010C-0xC00123, 12 words, write-only (silkroad.cpp:329)
	output logic [3:0]  vregs_addr,
	output logic         vregs_wel, vregs_weh,
	output logic [15:0] vregs_wdata,

	// work RAM (0xFE0000-0xFFFFFF, 65536 words)
	output logic [15:0] workram_addr,
	output logic         workram_wel, workram_weh,
	output logic [15:0] workram_wdata,
	input  logic [15:0] workram_rdata,

	// input ports (read-only, raw values -- caller owns debouncing/mapping)
	input  logic [31:0] p1p2_in,     // 0xC00000-0xC00003
	input  logic [31:0] dsw_in,      // 0xC00004-0xC00007

	// Sound, all bytes (silkroad.cpp:324-327): OKI 1 at 0xC00025, the YM2151 at 0xC00029
	// (address) and 0xC0002D (data), OKI 2 at 0xC00031 -- the odd byte of their words -- and
	// OKI 1's bank at 0xC00034, the even byte.
	output logic         oki1_wr, oki2_wr,       // pulse: command byte in snd_wdata
	output logic         ym_wr,                  // pulse: snd_wdata to the YM2151
	output logic         ym_a0,                  // 0 address, 1 data
	output logic [7:0]  snd_wdata,
	input  logic [7:0]  oki1_dout, oki2_dout, ym_dout,
	output logic         oki1_bank_we,
	output logic [1:0]  oki_bank,

	// Freeze the CPU (debug). Gates the 16 MHz clock enable, so the 68020
	// simply stops stepping; video timing and the debug overlay keep running,
	// which is what makes a frame comparable against a MAME dump.
	input  logic         pause,

	// Sprite RAM is being copied for the next frame (spriteram_dbuf): a sprite RAM write
	// waits, uncommitted, until it ends. MAME's copy takes no time.
	input  logic         spr_hold,

	// vblank IRQ (level 4, held/autovectored -- see header)
	input  logic         vblank
);

	// =====================================================================
	// CPU: TG68KdotC_Kernel driven DIRECTLY, at a 16 MHz clock enable.
	//
	// This module used to instantiate the TG68K.vhd WRAPPER. That wrapper is
	// an async-68000-BUS ADAPTER, not the CPU: it emulates real 68000 bus
	// phases (AS/UDS/LDS/DTACK) and therefore contains falling-edge
	// registers, and it assumes CLK *is* the CPU clock. Rate-limiting it to
	// 16 MHz meant fighting its design -- see docs/LESSONS_LEARNED.md and
	// docs/LESSONS_LEARNED.md ("TG68K.C") for the chain of failures that caused.
	//
	// The kernel underneath is entirely rising-edge and exposes clkena_in
	// for exactly this purpose. Established cores drive it directly and own
	// the bus interface themselves; mist-devel/plus_too's tg68k.v is the
	// reference. Its interface is synchronous and far simpler:
	//
	//   busstate: 00 fetch code, 10 read data, 11 write data, 01 no access
	//   data_in / data_write are SEPARATE ports -- no bidirectional DATA net
	//
	// Consequences, all of which delete code that existed only to serve the
	// wrapper: no DATA tri-state, no AS/UDS/LDS phase emulation, no DTACK
	// handshake, and no VPA/E-clock autovector games (IPL_autovector is
	// simply tied high). It also removes the need for any CPU
	// set_multicycle_path in Silkroad.sdc -- an all-rising-edge kernel gated
	// by a real clock enable has no half-cycle paths to mis-constrain.
	// =====================================================================

	// ---- 16 MHz CPU clock enable ----
	// The board clocks the 68EC020 at 32 MHz / 2 = 16 MHz (silkroad.cpp:445). clk_sys is
	// 48 MHz, so the enable is exactly 1 in 3. Silkroad.sdc's multicycles depend on that
	// minimum gap of 3.
	localparam int CE_NUM = 1;     // 16 MHz
	localparam int CE_DEN = 3;     // 48 MHz

	logic [10:0] ce_acc;
	logic        cpu_ce;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			ce_acc <= 11'd0;
			cpu_ce <= 1'b0;
		end else if (pause) begin
			cpu_ce <= 1'b0;
		end else if (ce_acc + CE_NUM >= CE_DEN) begin
			ce_acc <= 11'(ce_acc + CE_NUM - CE_DEN);
			cpu_ce <= 1'b1;
		end else begin
			ce_acc <= 11'(ce_acc + CE_NUM);
			cpu_ce <= 1'b0;
		end
	end

	// ---- kernel instance ----
	logic [31:0] a32;
	logic [15:0] cpu_din, cpu_dout;
	logic [1:0]  busstate;
	logic        nWr, nUDS, nLDS;
	logic [2:0]  fc;
	logic [2:0]  ipl;
	logic        cpu_clkena;

	TG68KdotC_Kernel #(
		.SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
		.MUL_Mode(2), .DIV_Mode(2), .BitField(2),
		.BarrelShifter(0), .MUL_Hardware(1)
	) u_cpu (
		.clk(clk),
		.nReset(~reset),
		.clkena_in(cpu_clkena),
		.data_in(cpu_din),
		.IPL(ipl),
		.IPL_autovector(1'b1),   // the level-4 vblank IRQ is autovectored
		.berr(1'b0),             // active HIGH in the kernel; no bus errors here
		.CPU(2'b11),             // 68020
		.addr_out(a32),
		.data_write(cpu_dout),
		.nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
		.busstate(busstate),
		.longword(),
		.nResetOut(),
		.FC(fc),
		.clr_berr(),
		.skipFetch(),
		.regin_out(), .CACR_out(), .VBR_out()
	);

	// ---- address decode (unchanged from the previous implementation) ----
	logic [23:0] addr24;
	assign addr24 = a32[23:0];

	logic is_rom, is_spriteram, is_palette, is_vram0, is_vram1, is_vram2, is_vregs, is_workram;
	logic is_p1p2, is_dsw;

	assign is_rom        = (addr24 <= 24'h1FFFFF);
	assign is_spriteram  = (addr24 >= 24'h40C000) && (addr24 <= 24'h40CFFF);
	assign is_palette    = (addr24 >= 24'h600000) && (addr24 <= 24'h603FFF) && !addr24[1];
	assign is_vram0      = (addr24 >= 24'h800000) && (addr24 <= 24'h803FFF);
	assign is_vram1      = (addr24 >= 24'h804000) && (addr24 <= 24'h807FFF);
	assign is_vram2      = (addr24 >= 24'h808000) && (addr24 <= 24'h80BFFF);
	assign is_vregs      = (addr24 >= 24'hC0010C) && (addr24 <= 24'hC00123);
	assign is_workram    = (addr24 >= 24'hFE0000) && (addr24 <= 24'hFFFFFF);

	assign is_p1p2       = (addr24 >= 24'hC00000) && (addr24 <= 24'hC00003);
	assign is_dsw        = (addr24 >= 24'hC00004) && (addr24 <= 24'hC00007);

	// I/O words, 0xC00000-0xC0003F (word index addr24[5:1])
	wire       is_io      = (addr24[23:6] == 18'h30000);
	wire [4:0] io_word    = addr24[5:1];
	wire is_oki1      = is_io && io_word == 5'd18;              // 0xC00025, odd byte
	wire is_ym_a      = is_io && io_word == 5'd20;              // 0xC00029, odd byte
	wire is_ym_d      = is_io && io_word == 5'd22;              // 0xC0002D, odd byte
	wire is_oki2      = is_io && io_word == 5'd24;              // 0xC00031, odd byte
	wire is_oki1_bank = is_io && io_word == 5'd26;              // 0xC00034, even byte

	// word-address translation (drop bit 0 -- every region is word-granular)
	assign rom_addr       = a32[20:1];
	assign spriteram_addr = a32[11:1];
	assign palette_addr   = a32[13:2];
	assign vram_addr      = a32[13:1];
	assign vregs_addr     = 4'(addr24[5:1] - 5'd6);           // 0xC0010C is word 0
	assign workram_addr   = a32[16:1];

	// ---- bus access state ----
	// The CPU is stalled purely by holding cpu_clkena low; there is no DTACK.
	// acc_ready is a LEVEL, not a pulse, so it cannot be missed by the 16 MHz
	// enable the way a one-cycle valid could -- the CPU simply advances on the
	// first cpu_ce tick after the access completes.
	logic        acc_ready;
	logic [15:0] acc_data;

	// Settle/latency phase counter. The CPU's address (a32) is a registered
	// kernel output that changes on a cpu_ce tick, but its downstream path
	// measures ~14 ns -- longer than one 11.64 ns clock -- so it is NOT
	// settled during the first cycle after a step. Acting in that cycle
	// would commit a BRAM write to a half-settled ADDRESS, which repeating
	// the write later does not undo.
	//   acc_ph == 0 : address still settling, do nothing
	//   acc_ph == 1 : address settled -> commit writes here
	//   acc_ph == 2 : BRAM has output data for the settled address -> capture
	// (BRAM registers its address each edge and returns data one cycle
	// later, so the first output that corresponds to a settled address
	// appears at phase 2.)
	logic [1:0]  acc_ph;

	wire mem_needed = (busstate != 2'b01);
	wire is_write   = (busstate == 2'b11);

	assign cpu_clkena = cpu_ce && (!mem_needed || acc_ready);

	// ROM req is a ONE-CYCLE PULSE, not a held level.
	//
	// rtl/memory/rom_cache.sv takes the request in its idle state and returns
	// to idle once the access is answered. If req is still asserted then, it
	// immediately starts ANOTHER access, and keeps doing so until req drops --
	// burning SDRAM bandwidth and making cpu_rom_valid pulse repeatedly for a
	// single CPU access.
	//
	// The cache's own state machine is the authority on the req shape, and it
	// wants a PULSE -- not held-until-acknowledged (sdram_arbiter6.sv documents
	// a different contract for its own port; it does not apply here).
	logic rom_req_sent;
	assign rom_req = mem_needed && !is_write && is_rom && !acc_ready && !rom_req_sent;

	// ---- read mux (BRAM + input ports; ROM comes via rom_data) ----
	logic [15:0] read_mux;
	always_comb begin
		if      (is_spriteram) read_mux = spriteram_rdata;
		else if (is_palette)   read_mux = palette_rdata;
		else if (is_vram0)     read_mux = vram0_rdata;
		else if (is_vram1)     read_mux = vram1_rdata;
		else if (is_vram2)     read_mux = vram2_rdata;
		else if (is_workram)   read_mux = workram_rdata;
		else if (is_p1p2)      read_mux = a32[1] ? p1p2_in[15:0] : p1p2_in[31:16];
		else if (is_dsw)       read_mux = a32[1] ? dsw_in[15:0]  : dsw_in[31:16];
		else if (is_oki1)      read_mux = {8'h00, oki1_dout};
		else if (is_ym_a)      read_mux = {8'h00, 8'hFF};    // ymfm: the data port reads 0xFF
		else if (is_ym_d)      read_mux = {8'h00, ym_dout};
		else if (is_oki2)      read_mux = {8'h00, oki2_dout};
		else                   read_mux = 16'h0000;   // unmapped, and the write-only registers
	end

	wire spr_wr_hold = is_spriteram && is_write && spr_hold;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			acc_ready    <= 1'b0;
			acc_data     <= 16'h0000;
			acc_ph       <= 2'd0;
			rom_req_sent <= 1'b0;
		end else if (cpu_clkena) begin
			// CPU has consumed this access; arm for the next one
			acc_ready    <= 1'b0;
			acc_ph       <= 2'd0;
			rom_req_sent <= 1'b0;
		end else if (mem_needed && !acc_ready && !spr_wr_hold) begin
			if (rom_req) rom_req_sent <= 1'b1;   // one pulse per access
			if (acc_ph != 2'd3) acc_ph <= acc_ph + 2'd1;
			if (is_rom && !is_write) begin
				// SDRAM latency dominates; rom_req is held until valid
				if (rom_valid) begin
					acc_data  <= rom_data;
					acc_ready <= 1'b1;
				end
			end else begin
				// writes commit at phase 1, reads capture at phase 2
				if (!is_write && acc_ph == 2'd2) acc_data <= read_mux;
				if (is_write ? (acc_ph >= 2'd1) : (acc_ph >= 2'd2))
					acc_ready <= 1'b1;
			end
		end
	end

	assign cpu_din = acc_data;   // registered and stable -- never combinational

	// ---- writes ----
	// Held for exactly the cycle at which the address is settled and the
	// access completes (acc_ph == 1) -- see acc_ph's comment. One cycle is
	// all a synchronous BRAM port needs.
	wire wr_now = mem_needed && is_write && !acc_ready && (acc_ph == 2'd1) && !spr_wr_hold;

	assign spriteram_wel   = wr_now && is_spriteram && !nLDS;
	assign spriteram_weh   = wr_now && is_spriteram && !nUDS;
	assign spriteram_wdata = cpu_dout;

	assign palette_wel   = wr_now && is_palette && !nLDS;
	assign palette_weh   = wr_now && is_palette && !nUDS;
	assign palette_wdata = cpu_dout;

	assign vram_wdata  = cpu_dout;
	assign vram0_wel   = wr_now && is_vram0 && !nLDS;
	assign vram0_weh   = wr_now && is_vram0 && !nUDS;
	assign vram1_wel   = wr_now && is_vram1 && !nLDS;
	assign vram1_weh   = wr_now && is_vram1 && !nUDS;
	assign vram2_wel   = wr_now && is_vram2 && !nLDS;
	assign vram2_weh   = wr_now && is_vram2 && !nUDS;

	assign vregs_wel   = wr_now && is_vregs && !nLDS;
	assign vregs_weh   = wr_now && is_vregs && !nUDS;
	assign vregs_wdata = cpu_dout;

	assign workram_wel   = wr_now && is_workram && !nLDS;
	assign workram_weh   = wr_now && is_workram && !nUDS;
	assign workram_wdata = cpu_dout;

	// I/O writes: byte handlers, the chips on the odd byte (lower lane), the bank register on
	// the even byte (upper lane). The coin counters at 0xC00039 are not modelled.
	assign oki1_wr      = wr_now && is_oki1 && !nLDS;
	assign oki2_wr      = wr_now && is_oki2 && !nLDS;
	assign ym_wr        = wr_now && (is_ym_a || is_ym_d) && !nLDS;
	assign ym_a0        = is_ym_d;
	assign snd_wdata    = cpu_dout[7:0];
	// bank 3 is ignored (silkroad.cpp:297)
	assign oki1_bank_we = wr_now && is_oki1_bank && !nUDS && cpu_dout[9:8] != 2'd3;
	assign oki_bank     = cpu_dout[9:8];

	// ---- vblank IRQ: level 4, held until the CPU acknowledges ----
	// vblank is a LEVEL held for the full 38-line vertical blank (~2.4 ms).
	// The CPU acknowledges within microseconds, i.e. while vblank is still
	// high, so set-priority would discard the acknowledge and pin ipl at
	// level 4 forever -- the ISR would re-enter after every RTE. Match MAME's
	// irq4_line_hold: assert on the RISING edge, hold until acknowledged, and
	// let the acknowledge win.
	//
	// An interrupt-acknowledge cycle is FC=3'b111 during a real memory access.
	logic irq_pending, vblank_d;

	wire iack = mem_needed && (fc == 3'b111);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			irq_pending <= 1'b0;
			vblank_d    <= 1'b0;
		end else begin
			vblank_d <= vblank;
			if (iack)                      irq_pending <= 1'b0;
			else if (vblank && !vblank_d)  irq_pending <= 1'b1;
		end
	end

	// The kernel inverts IPL internally (IPL_nr <= NOT IPL), so level 4 is
	// requested by driving 3'b011, NOT 3'b100.
	assign ipl = irq_pending ? 3'b011 : 3'b111;

`ifdef DEBUG_ISSP
	// ISSP "C" (scripts/read_issp.tcl): where the 68020 is fetching and how far the boot
	// has got (interrupts, palette and VRAM writes). Counters saturate, survive the
	// core's reset, and clear on source bit 0.
	logic        dbg_clr;
	logic [23:0] dbg_fetch;
	logic [15:0] dbg_iacks, dbg_pal_w, dbg_rom_rd, dbg_vram_w;
	wire         dbg_consume = cpu_clkena && mem_needed;
	function automatic [15:0] sat_inc(input [15:0] v, input en);
		sat_inc = (en && v != 16'hFFFF) ? v + 16'd1 : v;
	endfunction
	always_ff @(posedge clk) begin
		if (dbg_consume && busstate == 2'b00) dbg_fetch <= a32[23:0];
		if (dbg_clr) begin
			dbg_iacks <= 0; dbg_pal_w <= 0; dbg_rom_rd <= 0; dbg_vram_w <= 0;
		end else begin
			dbg_iacks  <= sat_inc(dbg_iacks,  dbg_consume && fc == 3'b111);
			dbg_pal_w  <= sat_inc(dbg_pal_w,  palette_wel || palette_weh);
			dbg_vram_w <= sat_inc(dbg_vram_w, vram0_wel || vram0_weh || vram1_wel || vram1_weh ||
			                                  vram2_wel || vram2_weh);
			dbg_rom_rd <= sat_inc(dbg_rom_rd, rom_req);
		end
	end
	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id("C"),
		.probe_width(91),
		.source_width(1),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp_cpu (
		.probe({dbg_vram_w, irq_pending, pause, reset, dbg_rom_rd, dbg_pal_w, dbg_iacks, dbg_fetch}),
		.source(dbg_clr),
		.source_clk(clk),
		.source_ena(1'b1)
	);
`endif

endmodule
