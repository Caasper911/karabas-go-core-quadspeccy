`timescale 1ns / 1ps
`default_nettype none

/*
 raster_delay.v

 The raster of zx_timing (ce7, hc, vc, int_n, frame) D clocks later, for machine k of the quad CPU (D = 2k): its CPU
 has its cen in slot 2k of tv80_quad, 2k clocks after ce_cpu, so with this raster its CPU, its INT, its video fetch and
 the border it shows are in the same relation as those of machine 0 (multicolour and border effects at the same
 place on the four; found on the board with Rage: machines 2..4 shifted by up to 4 pixels).
*/

module raster_delay #(
	parameter D = 0
) (
	input wire clk,
	input wire ce7_i,
	input wire [8:0] hc_i,
	input wire [8:0] vc_i,
	input wire int_n_i,
	input wire [4:0] frame_i,
	output wire ce7,
	output wire [8:0] hc,
	output wire [8:0] vc,
	output wire int_n,
	output wire [4:0] frame
);

localparam W = 1 + 9 + 9 + 1 + 5;
wire [W-1:0] in = {ce7_i, hc_i, vc_i, int_n_i, frame_i};

generate
	if (D == 0) begin : g_none
		assign {ce7, hc, vc, int_n, frame} = in;
	end else begin : g_delay
		reg [W-1:0] sr [0:D-1];
		integer i;
		initial for (i = 0; i < D; i = i + 1) sr[i] = {1'b0, 9'd0, 9'd0, 1'b1, 5'd0};
		always @(posedge clk) begin
			sr[0] <= in;
			for (i = 1; i < D; i = i + 1)
				sr[i] <= sr[i - 1];
		end
		assign {ce7, hc, vc, int_n, frame} = sr[D-1];
	end
endgenerate

endmodule
