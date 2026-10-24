`timescale 1ns/1ps
// rom_cache against a granule server with a varying latency and a ROM model: 200,000 word reads
// in the 68020's pattern (runs of sequential words with jumps, revisits of a small working set,
// and random far addresses so lines are evicted), each checked against the ROM; then a download
// (inval) rewrites the ROM and every read must see the new contents. Counts hits and misses.
//
//     scripts/run_sim.sh rom_cache_tb
module tb_rom_cache;
	logic clk = 0;
	always #5 clk = ~clk;
	logic reset = 1, inval = 0;

	logic        req = 0, valid;
	logic [24:0] addr = 0;
	logic [15:0] data;
	logic        g_req, g_valid = 0;
	logic [24:0] g_addr;
	logic [63:0] g_data = 0;

	rom_cache dut (.*);

	// ROM: 2 MB at 0x1800000, word w holds a hash of its address and a generation
	int gen = 0;
	function automatic logic [15:0] rom_word(input logic [24:0] a, input int g);
		logic [31:0] h;
		h = {7'd0, a[24:1], 1'b0} * 32'h9E3779B1 + 32'(g) * 32'h85EBCA6B;
		return h[31:16] ^ h[15:0];
	endfunction

	// granule server: answers a held g_req after 6-20 clocks, then waits for it to drop
	int lat = 0;
	logic busy = 0;
	always @(posedge clk) begin
		g_valid <= 1'b0;
		if (g_req && !busy && !g_valid) begin busy <= 1'b1; lat <= 6 + $urandom_range(14); end
		else if (busy) begin
			if (lat == 0) begin
				g_valid <= 1'b1;
				for (int i = 0; i < 4; i++) g_data[16 * i +: 16] <= rom_word(g_addr + 25'(2 * i), gen);
				busy <= 1'b0;
			end else lat <= lat - 1;
		end
	end

	int errors = 0, nreads = 0, fills = 0;
	always @(posedge clk) if (g_valid) fills++;

	task automatic read(input logic [24:0] a);
		@(posedge clk);
		addr <= a; req <= 1'b1;
		@(posedge clk);
		req <= 1'b0;
		while (!valid) @(posedge clk);
		if (data !== rom_word(a, gen)) begin
			errors++;
			if (errors <= 5) $display("FAIL %06x: %04x, ROM %04x (gen %0d)", a, data, rom_word(a, gen), gen);
		end
		nreads++;
		repeat ($urandom_range(2)) @(posedge clk);
	endtask

	logic [24:0] pc, hot [0:15];
	initial begin
		repeat (5) @(posedge clk);
		reset = 0;
		for (int i = 0; i < 16; i++) hot[i] = 25'h1800000 + 25'({$urandom_range(32767), 1'b0});
		pc = 25'h1800100;
		for (int pass = 0; pass < 2; pass++) begin
			for (int n = 0; n < 100000; n++) begin
				automatic int r = $urandom_range(99);
				if (r < 85)      pc = pc + 25'd2;                                         // next word
				else if (r < 95) pc = hot[$urandom_range(15)];                            // a loop
				else             pc = 25'h1800000 + 25'({$urandom_range(1048575), 1'b0}); // a far jump
				read(pc);
			end
			if (pass == 0) begin
				// a download: the ROM changes while inval is high
				@(posedge clk) inval <= 1'b1;
				gen = 1;
				repeat (50) @(posedge clk);
				inval <= 1'b0;
				$display("after %0d reads: %0d granule fills", nreads, fills);
			end
		end
		$display("%0d reads, %0d granule fills (%0.1f%% of reads), %0d wrong", nreads, fills,
		         100.0 * fills / nreads, errors);
		if (errors == 0) $display("PASS: rom_cache, every read the ROM's word, before and after a download");
		else             $display("FAIL: %0d", errors);
		$finish;
	end
endmodule
