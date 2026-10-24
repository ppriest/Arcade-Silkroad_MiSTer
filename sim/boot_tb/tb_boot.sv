`timescale 1ns/1ps
// silkroad's boot on maincpu, against MAME's bus trace (scripts/compare_boot_trace.py).
//
// The program ROM is the .mra image's (sim/boot_tb/gen_fixture.py). RAM regions are block-RAM
// models. Every I/O read gets MAME's value for the same read, in order (replay.hex): inputs,
// DIPs, the OKI and YM2151 status. The vblank interrupt is raised where MAME took it
// (irq.hex): once the CPU has made as many writes as MAME had and is repeating MAME's last
// data access before the vector read -- while that access is on the bus, or once it has
// completed when MAME returned to the instruction that made it (a loop later). Accesses are
// counted with the two 16-bit halves of a long merged, as the comparer merges them.
//
// Writes every bus access the 68020 completes, in MAME's "seq rw addr mask data" form
// (32-bit-aligned address, byte-lane mask, data in its lanes), to
// debug/<set>-boot/<set>_rtl.trace.
//
// RUN FROM THE REPOSITORY ROOT, after
//     python scripts/mame_boot_trace.py silkroad 2000000
//     python sim/boot_tb/gen_fixture.py
//     scripts/run_sim.sh boot_tb [+MAXACC=n] [+SET=silkroad]
//     python scripts/compare_boot_trace.py compare silkroad
module tb_boot;
	localparam real HALF = 10.4167;          // 48 MHz clk_sys
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;
	logic vblank = 0;

	// ---- program ROM: req/valid, 12-cycle latency (the SDRAM's uncontended read) ----
	logic [15:0] prg [0:1048575];
	initial $readmemh("sim/boot_tb/maincpu.hex", prg);
	logic         rom_req, rom_valid;
	logic [19:0] rom_addr, rom_addr_l;
	logic [15:0] rom_data;
	int           rom_cnt = -1;
	always_ff @(posedge clk) begin
		rom_valid <= 1'b0;
		if (rom_req) begin rom_cnt <= 12; rom_addr_l <= rom_addr; end
		else if (rom_cnt > 0) rom_cnt <= rom_cnt - 1;
		else if (rom_cnt == 0) begin rom_valid <= 1'b1; rom_data <= prg[rom_addr_l]; rom_cnt <= -1; end
	end

	// ---- block-RAM regions: one cycle of read latency, byte lanes ----
	logic [10:0] spriteram_addr;
	logic [11:0] palette_addr;
	logic [12:0] vram_addr;
	logic [3:0]  vregs_addr;
	logic [15:0] workram_addr;
	logic        spriteram_wel, spriteram_weh, palette_wel, palette_weh;
	logic        vram0_wel, vram0_weh, vram1_wel, vram1_weh, vram2_wel, vram2_weh;
	logic        vregs_wel, vregs_weh, workram_wel, workram_weh;
	logic [15:0] spriteram_wdata, palette_wdata, vram_wdata, vregs_wdata, workram_wdata;
	logic [15:0] spriteram_rdata, palette_rdata, vram0_rdata, vram1_rdata, vram2_rdata, workram_rdata;
	logic [15:0] spriteram [0:2047], palette [0:4095], vram0 [0:8191], vram1 [0:8191], vram2 [0:8191];
	logic [15:0] workram [0:65535];
	always @(posedge clk) begin
		spriteram_rdata <= spriteram[spriteram_addr];
		if (spriteram_wel) spriteram[spriteram_addr][7:0]  <= spriteram_wdata[7:0];
		if (spriteram_weh) spriteram[spriteram_addr][15:8] <= spriteram_wdata[15:8];
		palette_rdata <= palette[palette_addr];
		if (palette_wel) palette[palette_addr][7:0]  <= palette_wdata[7:0];
		if (palette_weh) palette[palette_addr][15:8] <= palette_wdata[15:8];
		vram0_rdata <= vram0[vram_addr];
		if (vram0_wel) vram0[vram_addr][7:0]  <= vram_wdata[7:0];
		if (vram0_weh) vram0[vram_addr][15:8] <= vram_wdata[15:8];
		vram1_rdata <= vram1[vram_addr];
		if (vram1_wel) vram1[vram_addr][7:0]  <= vram_wdata[7:0];
		if (vram1_weh) vram1[vram_addr][15:8] <= vram_wdata[15:8];
		vram2_rdata <= vram2[vram_addr];
		if (vram2_wel) vram2[vram_addr][7:0]  <= vram_wdata[7:0];
		if (vram2_weh) vram2[vram_addr][15:8] <= vram_wdata[15:8];
		workram_rdata <= workram[workram_addr];
		if (workram_wel) workram[workram_addr][7:0]  <= workram_wdata[7:0];
		if (workram_weh) workram[workram_addr][15:8] <= workram_wdata[15:8];
	end

	// ---- I/O: the current replay entry's value on every input ----
	localparam int NREP = 65536;
	logic [23:0] rep_a [0:NREP-1];
	logic [31:0] rep_m [0:NREP-1], rep_d [0:NREP-1];
	int          nrep = 0, rp = 0;
	logic [31:0] rep_rem;
	wire  [31:0] cur = (rp < nrep) ? rep_d[rp] : 32'hffffffff;
	logic        oki1_wr, oki2_wr, ym_wr, ym_a0, oki1_bank_we;
	logic [7:0]  snd_wdata;
	logic [1:0]  oki_bank;

	maincpu dut (
		.clk(clk), .reset(reset),
		.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
		.spriteram_addr(spriteram_addr), .spriteram_wel(spriteram_wel), .spriteram_weh(spriteram_weh),
		.spriteram_wdata(spriteram_wdata), .spriteram_rdata(spriteram_rdata),
		.palette_addr(palette_addr), .palette_wel(palette_wel), .palette_weh(palette_weh),
		.palette_wdata(palette_wdata), .palette_rdata(palette_rdata),
		.vram_addr(vram_addr), .vram_wdata(vram_wdata),
		.vram0_wel(vram0_wel), .vram0_weh(vram0_weh), .vram0_rdata(vram0_rdata),
		.vram1_wel(vram1_wel), .vram1_weh(vram1_weh), .vram1_rdata(vram1_rdata),
		.vram2_wel(vram2_wel), .vram2_weh(vram2_weh), .vram2_rdata(vram2_rdata),
		.vregs_addr(vregs_addr), .vregs_wel(vregs_wel), .vregs_weh(vregs_weh), .vregs_wdata(vregs_wdata),
		.workram_addr(workram_addr), .workram_wel(workram_wel), .workram_weh(workram_weh),
		.workram_wdata(workram_wdata), .workram_rdata(workram_rdata),
		.p1p2_in(cur), .dsw_in(cur), .pause(1'b0),
		.oki1_wr(oki1_wr), .oki2_wr(oki2_wr), .ym_wr(ym_wr), .ym_a0(ym_a0), .snd_wdata(snd_wdata),
		.oki1_dout(cur[23:16]), .oki2_dout(cur[23:16]), .ym_dout(cur[23:16]),
		.oki1_bank_we(oki1_bank_we), .oki_bank(oki_bank),
		.spr_hold(1'b0), .vblank(vblank)
	);

	// ---- interrupt sync points ----
	localparam int NIRQ = 256;
	int          irq_w [0:NIRQ-1];
	logic        irq_rw [0:NIRQ-1];
	logic [23:0] irq_a [0:NIRQ-1];
	logic [31:0] irq_m [0:NIRQ-1];
	logic        irq_late [0:NIRQ-1];
	logic [23:0] irq_pc [0:NIRQ-1];
	int          nirq = 0, ip = 0, iacks = 0;

	// ---- trace: one line per access the CPU consumes ----
	string set = "silkroad";
	int    fd, nacc = 0, maxacc = 4000000, writes = 0;
	logic        prev_rw = 0, prev_valid = 0;
	logic [23:0] prev_a = 0;
	logic [31:0] prev_m = 0, acc_m = 0;
	wire   consume = dut.cpu_clkena && (dut.busstate != 2'b01);

	function automatic bit in_rom(input logic [23:0] a); return a <= 24'h1FFFFF; endfunction
	function automatic bit in_ram(input logic [23:0] a);
		return (a >= 24'h40C000 && a <= 24'h40CFFF) || (a >= 24'h600000 && a <= 24'h603FFF) ||
		       (a >= 24'h800000 && a <= 24'h80BFFF) || (a >= 24'hFE0000);
	endfunction

	// The interrupt is raised while the matching access is still on the bus, before the CPU
	// consumes it, so the request reaches the kernel's IPL input within that instruction, as
	// MAME's level was there before the instruction ended. Raised on completion instead, TG68K
	// took it one instruction later in the vblank wait loop (return address 0x5A82 for MAME's
	// 0x5A88).
	wire         pend    = !reset && dut.busstate != 2'b01 && !dut.acc_ready;
	wire         pend_wr = (dut.busstate == 2'b11);
	wire [23:0]  pend_a  = {dut.a32[23:2], 2'b00};
	wire [31:0]  pend_m0 = {16'h0000, (dut.nUDS ? 8'h00 : 8'hff), (dut.nLDS ? 8'h00 : 8'hff)};
	wire [31:0]  pend_m  = dut.a32[1] ? pend_m0 : pend_m0 << 16;
	wire         pend_merge = prev_valid && prev_rw == pend_wr && prev_a == pend_a && !(prev_m & pend_m);
	wire         pend_hit = pend && ip < nirq && !irq_late[ip] && !in_rom(pend_a)
	                        && (writes + ((pend_wr && !pend_merge) ? 1 : 0)) == irq_w[ip]
	                        && pend_wr == irq_rw[ip] && pend_a == irq_a[ip]
	                        && ((pend_merge ? (acc_m | pend_m) : pend_m) == irq_m[ip]);

	int vb_hold = 0;
	always @(posedge clk) begin
		if (vb_hold > 0) vb_hold <= vb_hold - 1;
		vblank <= (vb_hold > 0);
		if (pend_hit && vb_hold == 0) begin vb_hold <= 64; ip++; end
		if (!reset && consume) begin
			logic [31:0] mask, data;
			logic [15:0] w;
			logic        wr, merged;
			logic [23:0] a;
			wr   = (dut.busstate == 2'b11);
			w    = wr ? dut.cpu_dout : dut.acc_data;
			mask = {16'h0000, (dut.nUDS ? 8'h00 : 8'hff), (dut.nLDS ? 8'h00 : 8'hff)};
			if (wr == 0 && dut.nUDS && dut.nLDS) mask[15:0] = 16'hffff;   // a fetch drives no strobes
			data = {16'h0000, w};
			if (!dut.a32[1]) begin mask = mask << 16; data = data << 16; end
			a = {dut.a32[23:2], 2'b00};
			if (dut.fc == 3'b111) iacks++;
			if (nacc < maxacc) begin
				nacc++;
				$fwrite(fd, "%0d\t%s\t%06X\t%08X\t%08X\n", nacc, wr ? "w" : "r", a, mask, data & mask);
			end
			// the half of a split access merges with the half before it (merge_halves)
			merged = prev_valid && prev_rw == wr && prev_a == a && !(prev_m & mask);
			acc_m  = merged ? (acc_m | mask) : mask;
			if (wr && !merged) writes++;
			prev_valid = 1; prev_rw = wr; prev_a = a; prev_m = mask;
			// replay pointer: an entry is used up when its lanes have all been read
			// a late interrupt: raised as the matching access completes, so it is taken after
			// the next instruction
			if (ip < nirq && irq_late[ip] && writes == irq_w[ip] && wr == irq_rw[ip] && a == irq_a[ip]
			    && acc_m == irq_m[ip] && vb_hold == 0) begin
				vb_hold <= 64;
				ip++;
			end
			if (!wr && !in_rom(a) && !in_ram(a) && rp < nrep) begin
				if (a != rep_a[rp]) $display("%t: I/O read %06X, replay expects %06X (entry %0d)", $time, a, rep_a[rp], rp);
				rep_rem = rep_rem & ~mask;
				if (rep_rem == 0) begin rp++; rep_rem = (rp < nrep) ? rep_m[rp] : 0; end
			end
		end
	end

	int ms = 400;
	initial begin
		int f, n;
		void'($value$plusargs("MS=%d", ms));
		void'($value$plusargs("MAXACC=%d", maxacc));
		void'($value$plusargs("SET=%s", set));
		f = $fopen("sim/boot_tb/replay.hex", "r");
		if (f == 0) $fatal(1, "no sim/boot_tb/replay.hex: run sim/boot_tb/gen_fixture.py");
		while (nrep < NREP && $fscanf(f, "%h %h %h\n", rep_a[nrep], rep_m[nrep], rep_d[nrep]) == 3) nrep++;
		$fclose(f);
		f = $fopen("sim/boot_tb/irq.hex", "r");
		while (nirq < NIRQ && $fscanf(f, "%h %h %h %h %h %h\n", irq_w[nirq], irq_rw[nirq], irq_a[nirq], irq_m[nirq],
		                              irq_late[nirq], irq_pc[nirq]) == 6) nirq++;
		$fclose(f);
		rep_rem = rep_m[0];
		$display("%0d I/O reads to replay, %0d interrupt points", nrep, nirq);
		fd = $fopen($sformatf("debug/%s-boot/%s_rtl.trace", set, set), "w");
		if (fd == 0) $fatal(1, "cannot open debug/%s-boot/%s_rtl.trace (run mame_boot_trace.py first)", set, set);
		$fwrite(fd, "# RTL bus accesses from reset (sim/boot_tb), seq rw addr mask data\n");
		repeat (20) @(posedge clk);
		reset = 0;
		fork
			begin wait (nacc >= maxacc); end
			begin #(longint'(ms) * 1ms); end
		join_any
		disable fork;
		$fclose(fd);
		$display("%0d accesses traced, %0d writes; %0d of %0d I/O reads replayed; %0d of %0d interrupts raised, %0d acknowledged",
		         nacc, writes, rp, nrep, ip, nirq, iacks);
		$finish;
	end
endmodule
