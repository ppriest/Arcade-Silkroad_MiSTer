// SPDX-License-Identifier: GPL-3.0-or-later
//
// The video registers at 0xC0010C-0xC00123 (silkroad.cpp:329): six 32-bit words, write-only,
// held here as twelve 16-bit halves (half 2n is regs[n] bits 31-16, 2n+1 bits 15-0). The
// scroll values are taken as silkroad.cpp's screen_update does (266-273):
//
//   layer 0  X regs[0] 31-16   Y regs[0] 15-0
//   layer 1  X regs[2] 15-0    Y regs[5] 31-16
//   layer 2  X regs[2] 31-16   Y regs[1] 31-16
//
// The other halves (regs[1] 15-0, regs[3], regs[4], regs[5] 15-0) are stored, unused by
// MAME, and readable through the debug dump. The game writes these only in vblank
// (docs/write_timing_mame.txt), so they are read live.
module silkroad_vregs (
	input  logic        clk,
	input  logic        reset,

	input  logic [3:0]  cpu_addr,        // half index, 0 = 0xC0010C
	input  logic        cpu_wel, cpu_weh,
	input  logic [15:0] cpu_wdata,

	output logic [15:0] l0_x, l0_y,
	output logic [15:0] l1_x, l1_y,
	output logic [15:0] l2_x, l2_y,

	input  logic [3:0]  dbg_addr,
	output logic [15:0] dbg_data
);

	logic [15:0] r [0:11];

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			for (int i = 0; i < 12; i++) r[i] <= 16'h0000;
		end else if (cpu_addr < 4'd12) begin
			if (cpu_wel) r[cpu_addr][7:0]  <= cpu_wdata[7:0];
			if (cpu_weh) r[cpu_addr][15:8] <= cpu_wdata[15:8];
		end
	end

	assign l0_x = r[0];
	assign l0_y = r[1];
	assign l1_x = r[5];
	assign l1_y = r[10];
	assign l2_x = r[4];
	assign l2_y = r[2];

	always_ff @(posedge clk) dbg_data <= (dbg_addr < 4'd12) ? r[dbg_addr] : 16'h0000;

endmodule
