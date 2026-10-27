// SPDX-License-Identifier: GPL-3.0-or-later
//
// Single-port wrapper around one of rtl/memory/sdram/sdram.sv's three
// physical ports, translating its toggle-based req/ack handshake into this
// project's standard req(pulse-while-!busy)/valid(pulse)/busy client
// interface, so the arbiter and the video engines sit on top without knowing
// which physical transport is underneath.
//
// Address is a 25-bit BYTE offset into the SDRAM chip's real 32MB capacity
// (MT48LC16M16).
//
// Two transaction shapes, matching sdram.sv's own port contract:
//   - READ:  8-byte-aligned granule in (`addr`'s low 3 bits should be 0),
//            full 64-bit `port_dout` out, assembled by sdram.sv's own
//            burst-4 read logic.
//   - WRITE: single BYTE in (`wdata`), `addr[0]` selects the low or high
//            byte lane of the 16-bit word at `addr[24:1]`; `we16` writes
//            both lanes at once.

module sdram_phy (
	input  logic clk,
	input  logic reset,

	// one of sdram.sv's three physical ports
	output logic [24:1] port_addr,
	output logic         port_wrl,
	output logic         port_wrh,
	output logic [15:0] port_din,
	input  logic [63:0] port_dout,
	output logic         port_req,
	input  logic         port_ack,

	// client interface
	input  logic         req,      // pulse: start a transaction (only while !busy)
	input  logic         we,       // 0 = 8-byte-granule burst read, 1 = write
	// 1 = write BOTH byte lanes from wdata[15:0] (addr must be even); 0 =
	// write the single byte wdata[7:0] into the lane addr[0] selects. The
	// wide form halves the download's transactions: sdram_download pairs
	// consecutive bytes, rom_loader writes four words per 8-byte granule.
	input  logic         we16,
	input  logic [24:0] addr,     // byte offset into the 32MB SDRAM chip
	input  logic [15:0] wdata,    // data to write (we=1 only); see we16
	output logic         busy,     // 1 while a transaction is in flight
	output logic         valid,    // 1-cycle pulse: rdata holds the requested granule (read only)
	output logic [63:0] rdata     // held until the next read completes
);

	typedef enum logic {S_IDLE, S_WAIT} state_t;
	state_t state;

	logic req_toggle;

	assign port_req = req_toggle;
	assign busy      = (state != S_IDLE);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state      <= S_IDLE;
			req_toggle <= 1'b0;
			valid      <= 1'b0;
		end else begin
			valid <= 1'b0;
			case (state)
				S_IDLE: begin
					if (req) begin
						port_addr  <= addr[24:1];
						port_wrl   <= we && (we16 || !addr[0]);
						port_wrh   <= we && (we16 ||  addr[0]);
						// byte form replicates so the lane select picks the real one;
						// word form drives both lanes with the real 16-bit value
						port_din   <= we16 ? wdata : {wdata[7:0], wdata[7:0]};
						req_toggle <= ~req_toggle;
						state      <= S_WAIT;
					end
				end

				S_WAIT: begin
					if (port_ack == req_toggle) begin
						// port_dout is shared by sdram.sv's three ports and may be on a faster
						// clock: the next read on any port overwrites it, so keep a copy
						if (!we) begin
							valid <= 1'b1;
							rdata <= port_dout;
						end
						state <= S_IDLE;
					end
				end

				default: ;
			endcase
		end
	end

endmodule
