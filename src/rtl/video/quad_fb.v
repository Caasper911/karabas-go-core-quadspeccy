`timescale 1ns / 1ps
`default_nettype none

/*
 quad_fb.v

 The frame buffer of the quad view in the SRAM (sram_ctrl.v): every machine writes the visible part of its picture,
 368 x 288 pixels (56 + 256 + 56, 48 + 192 + 48: the picture of the full screen), as it makes it on its raster (pix of
 pentagon.v: the beam, with the border and multicolour as in the full screen); video_out reads it for the quadrants.
 clk = clk_bus (28 MHz).

 Write: four pixels {bright, G, R, B} in a word (the left one in bits 15..12); machine k collects them on its raster
 (ce7 / hc / vc of raster_delay: pix is the colour of hc / vc of two ce7 before, as the line buffer of video_out
 takes it) and leaves the word in a register, one per 16 clocks; it goes to the SRAM in a clock without a read
 (fixed priority, machine 0 first: at most 4 words per 16 clocks, 12 free clocks).
 Read: video_out asks for the word of the four pixels that are shown 2..5 clocks later (rd in the clocks with
 vga_p[1:0] = 2 of the quad view, at most one in 4 clocks); word is that word from the third clock after rd on, for
 four clocks.

 Two frames per machine: the frame bit fb changes at line 256 of the raster (blank: the last visible line 239 has been
 written, the first one 272 is not yet); the machines write frame fb, video_out reads ~fb, the last whole frame.
 The rasters of VGA and the machines are in lock step: the top quadrants are shown in the native lines 273..97, the
 bottom ones in 97..240, each within one value of fb, so the picture never tears.

 Word address: {0, 0, frame, machine, yq (0..287), word in the line (0..91)}.
*/

module quad_fb (
	input wire clk,
	input wire clk_sys,

	// the raster of zx_timing (the frame bit)
	input wire ce7,
	input wire [8:0] hc,
	input wire [8:0] vc,

	// the machines: raster (raster_delay) and colour, machine k: bits k
	input wire [3:0] m_ce7,
	input wire [4*9-1:0] m_hc,
	input wire [4*9-1:0] m_vc,
	input wire [4*4-1:0] m_pix,

	// read for video_out
	input wire rd,
	input wire [17:0] rd_addr,      // {machine, yq, word}
	output reg [15:0] word = 16'd0,

	// pins
	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MRD_N,
	output wire [1:0] MWR_N
);

reg fb = 1'b0;
always @(posedge clk)
	if (ce7 && hc == 9'd0 && vc == 9'd256)
		fb <= ~fb;

// ---------------------------------------------------------------------------------------------
// the collectors of the machines

wire [3:0] pend;
wire [4*16-1:0] w_words;
wire [4*19-1:0] w_addrs;
wire [3:0] grant;

genvar k;
generate
	for (k = 0; k < 4; k = k + 1) begin : g_m
		localparam [1:0] KM = k;
		reg [8:0] hd1 = 9'd0, hd2 = 9'd0;
		reg [8:0] vd1 = 9'd0, vd2 = 9'd0;
		reg [11:0] sh = 12'd0;
		reg p = 1'b0;
		reg [15:0] w_word = 16'd0;
		reg [18:0] w_addr = 19'd0;
		wire [3:0] pix = m_pix[k*4 +: 4];

		// the pixel hd2 / vd2 has the colour pix; the left border (392..447) is the start of the row of the next line
		// (the beam draws it before the paper of that line): the border of a change of colour in the blank (Rage)
		// was a line lower beside the paper
		wire lb = (hd2 >= 9'd392);
		wire [8:0] vr = !lb ? vd2 : (vd2 == 9'd319) ? 9'd0 : vd2 + 1'd1;
		wire h_vis = lb || (hd2 < 9'd312);
		wire v_vis = (vr >= 9'd272) || (vr < 9'd240);
		wire [8:0] xq = lb ? hd2 - 9'd392 : hd2 + 9'd56;
		wire [8:0] yq = (vr >= 9'd272) ? vr - 9'd272 : vr + 9'd48;

		always @(posedge clk) begin
			if (m_ce7[k]) begin
				hd1 <= m_hc[k*9 +: 9];
				hd2 <= hd1;
				vd1 <= m_vc[k*9 +: 9];
				vd2 <= vd1;
				sh <= {sh[7:0], pix};
			end
			if (m_ce7[k] && h_vis && v_vis && xq[1:0] == 2'd3) begin
				w_word <= {sh, pix};
				w_addr <= {fb, KM, yq, xq[8:2]};
				p <= 1'b1;
			end else if (grant[k])
				p <= 1'b0;
		end

		assign pend[k] = p;
		assign w_words[k*16 +: 16] = w_word;
		assign w_addrs[k*19 +: 19] = w_addr;
	end
endgenerate

// one write in a clock without a read, machine 0 first
assign grant[0] = ~rd & pend[0];
assign grant[1] = ~rd & pend[1] & ~pend[0];
assign grant[2] = ~rd & pend[2] & ~pend[1] & ~pend[0];
assign grant[3] = ~rd & pend[3] & ~pend[2] & ~pend[1] & ~pend[0];
wire [1:0] gm = pend[0] ? 2'd0 : pend[1] ? 2'd1 : pend[2] ? 2'd2 : 2'd3;
wire w_req = |grant;

// ---------------------------------------------------------------------------------------------
// the SRAM

wire [15:0] q;

sram_ctrl sram(
	.clk_bus(clk),
	.clk_sys(clk_sys),
	.req(rd | w_req),
	.we(~rd),
	.addr(rd ? {2'b00, ~fb, rd_addr} : {2'b00, w_addrs[gm*19 +: 19]}),
	.din(w_words[gm*16 +: 16]),
	.q(q),
	.MA(MA),
	.MD(MD),
	.MRD_N(MRD_N),
	.MWR_N(MWR_N)
);

// the word of a read is in q two clocks after rd
reg [1:0] rd_d = 2'b00;
always @(posedge clk) begin
	rd_d <= {rd_d[0], rd};
	if (rd_d[1])
		word <= q;
end

endmodule
