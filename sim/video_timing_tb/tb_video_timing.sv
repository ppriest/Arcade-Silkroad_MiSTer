`timescale 1ns/1ps
// video_timing over two whole frames, every pixel: 512 x 262; the engines' window h_active at
// hcnt 0-379 and the output's (hblank low) at 1-380; hsync 420-457; vblank from line 224,
// vsync 232-234; line_start once a line, as hcnt goes 380 -> 381; frame_start once a frame, as
// vblank rises; vcnt_next/next2 wrapped on 262; nothing moves without ce_pix (every 3rd clk).
module tb_video_timing;
	logic clk = 0;
	always #5 clk = ~clk;

	logic       reset = 1, ce_pix = 0;
	logic [8:0] hcnt, vcnt;
	logic [7:0] vcnt_active, vcnt_next_active, vcnt_next2_active;
	logic       h_active, v_active, hblank, vblank, hsync, vsync, line_start, frame_start;

	video_timing dut (.*);

	int ce_div = 0;
	always_ff @(posedge clk) begin
		ce_div <= (ce_div == 2) ? 0 : ce_div + 1;
		ce_pix <= (ce_div == 2);
	end

	int errors = 0, lines = 0, frames = 0, n = 0;
	logic [8:0] h_prev = 9'd0;
	logic       ce_prev = 1'b0;

	task automatic fail(input string what);
		errors++;
		if (errors <= 10) $display("FAIL %s at h %0d v %0d", what, hcnt, vcnt);
	endtask

	always @(posedge clk) if (!reset) begin
		// hcnt is seen changed the clk after a ce_pix
		if (!ce_prev && hcnt !== h_prev) fail("hcnt moved without ce_pix");
		h_prev  <= hcnt;
		ce_prev <= ce_pix;
		if (h_active !== (hcnt < 380))                     fail("h_active");
		if (hblank   !== (hcnt == 0 || hcnt > 380))         fail("hblank");
		if (hsync    !== (hcnt >= 420 && hcnt < 458))       fail("hsync");
		if (vblank   !== (vcnt >= 224))                     fail("vblank");
		if (vsync    !== (vcnt >= 232 && vcnt < 235))       fail("vsync");
		if (vcnt_next_active  !== 8'((vcnt + 1) % 262))     fail("vcnt_next_active");
		if (vcnt_next2_active !== 8'((vcnt + 2) % 262))     fail("vcnt_next2_active");
		if (line_start) begin
			lines++;
			if (hcnt !== 9'd381) fail("line_start not at the start of hcnt 381");
		end
		if (frame_start) begin
			frames++;
			if (vcnt !== 9'd224 || hcnt !== 9'd1) fail("frame_start not as vblank rises");
		end
		if (ce_pix && hcnt == 511 && vcnt == 261) n++;
	end

	initial begin
		repeat (5) @(posedge clk);
		reset = 0;
		wait (n == 2);
		@(posedge clk);
		if (lines != 2 * 262) begin errors++; $display("FAIL %0d line_start pulses in two frames", lines); end
		if (frames != 2)      begin errors++; $display("FAIL %0d frame_start pulses in two frames", frames); end
		if (errors == 0) $display("PASS: video_timing, two frames of 512 x 262");
		else             $display("FAIL: %0d", errors);
		$finish;
	end
endmodule
