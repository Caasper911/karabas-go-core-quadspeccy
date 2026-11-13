`timescale 1ns / 1ps
`default_nettype none

/*
 video_out.v

 The VGA picture of the selected machine (milestone 1: full screen only): a scan doubler of the
 Pentagon raster. clk = clk_bus, 28 MHz.

 A native line (448 pixels at 7 MHz, 64 us) is written into one of two line buffers while the
 line before it is read twice at 14 MHz (two lines of 32 us): 896 x 640 clocks of 28 MHz,
 31.25 kHz, 48.8 Hz, the raster of the 50 Hz VGA mode of TS-Conf (its OSD offsets fit).

 pix is the colour of the pixel hc / vc of two ce7 before (pentagon.v), so it is written at the
 position of hc / vc delayed by two ce7.

 Quad view (full = 0): four quadrants at 21 MHz, scale 4/3 (docs/QUAD_SCALE.md, variant B): this module makes
 the pixels of the next VGA row on clk_bus into the row buffer of video_px.v, which shows them at clk_sys / 4.
 Machine 2 * row + column. A paper line comes from the line buffer of its machine, read from the SDRAM during the
 VGA row before the one that makes it (q_go); the border has the colour of that native line (taken by the
 machine). The selected machine has a frame (colour in video_px), the machines that are not built are grey. The
 picture of the quad view is the screen memory at the time of the fetch, not the beam of the machine:
 multicolour and border effects are not exact there. r, g, b, hs, vs: the full screen (and the syncs of both).

 VGA (vga_x 0..447 at 14 MHz, dl the native line shown):
   vga_x 0..255 paper, 256..319 right border, 320..383 blank (hsync 328..375), 384..447 left border
   dl 240..255 blank, vsync in 242..243 (4 VGA lines); both syncs low active
*/

module video_out #(
	parameter NUM_MACHINES = 4
) (
	input wire clk,
	input wire ce7,
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire w_ce7,               // the raster of the machine shown full screen (its pix), for the line buffer
	input wire [8:0] w_hc,
	input wire [8:0] w_vc,
	input wire [8:0] vga_x,
	input wire [9:0] vga_p,
	input wire [9:0] vga_l,
	input wire flash,

	// mode: 1 the selected machine full screen, 0 the quad view; sel the selected machine
	input wire full,
	input wire [1:0] sel,

	input wire [3:0] pix,

	// quad view: line requests to the machines of the top (q_go[0]: 0, 1) and bottom (q_go[1]: 2, 3) row,
	// the line buffers and border memories of the machines (machine i: bits i)
	output reg [1:0] q_go = 2'b00,
	output reg [7:0] q_vc = 8'd0,
	output reg q_buf = 1'b0,
	output wire [5:0] q_addr,
	input wire [4*16-1:0] q_words,
	output wire [8:0] q_brd_addr,
	input wire [4*3-1:0] q_brds,
	// the row buffer of video_px (written here), the rows it shows
	output wire pb_we,
	output wire [10:0] pb_addr,
	output wire [4:0] pb_d,
	output reg qs_start = 1'b0,
	output reg qs_par = 1'b0,
	output reg qs_vis = 1'b0,

	// diagnostics: five squares (8 VGA pixels x 16 VGA lines) in the left border of the top border lines
	// 264..271, x 388 + 12 * i: square i < 4 green when diag_ok[i], red when not; square 4 blinks white with
	// diag_blink (the raster runs)
	input wire diag_en,
	input wire [3:0] diag_ok,
	input wire diag_blink,

	output reg [7:0] r = 8'd0,
	output reg [7:0] g = 8'd0,
	output reg [7:0] b = 8'd0,
	output reg hs = 1'b1,
	output reg vs = 1'b1
);

reg [8:0] hd1 = 9'd0, hd2 = 9'd0;
reg [8:0] vd1 = 9'd0, vd2 = 9'd0;

always @(posedge clk)
	if (w_ce7) begin
		hd1 <= w_hc;
		hd2 <= hd1;
		vd1 <= w_vc;
		vd2 <= vd1;
	end

wire [3:0] lb_q;

kg_sdpram #(.DW(4), .AW(10)) linebuf (
	.clka(clk),
	.wea(w_ce7),
	.addra({vd2[0], hd2}),
	.dina(pix),
	.clkb(clk),
	.enb(1'b1),
	.addrb({~vc[0], vga_x}),
	.doutb(lb_q)
);

// the line shown: the one before vc
wire [8:0] dl = (vc == 9'd0) ? 9'd319 : vc - 1'd1;

// ---------------------------------------------------------------------------------------------
// quad view: scale 4/3 at 21 MHz (docs/QUAD_SCALE.md, variant B)
//
// The quadrants are shown at 21.02 MHz = clk_sys / 4 (video_px.v): 576 x 608 pixels, quadrant 288 x 304 of
// 288 x 228 Spectrum pixels (16 + 256 + 16, 18 + 192 + 18), a native line on 4 / 3 VGA lines (src = yq * 3 / 4).
// Here, on clk_bus, the pixels of the next VGA row are made one a clock (rx 0..575) into the row buffer of
// video_px (pb_*, two rows, a 5-bit code: 0 + {bright, G, R, B}, 10000 frame, 10001 absent). The paper line of a
// row comes from the line buffer of its machine (qbuf, filled during the row before: q_go two rows ahead, only
// when the native line changes).
//
// Rows: sy 0..607 the picture (row 0 = line 512 of the doubled raster), a row starts at vga_p 768 (qx 0).

// the doubled line shown (full screen: 2 * dl + half) and the row: from vga_p 768 (after the back porch) the next
wire [9:0] ld = (vga_l < 10'd2) ? vga_l + 10'd638 : vga_l - 10'd2;
wire [9:0] row = (vga_p >= 10'd768) ? ((ld == 10'd639) ? 10'd0 : ld + 1'd1) : ld;
wire [9:0] sy = (row >= 10'd512) ? row - 10'd512 : row + 10'd128;
wire [9:0] qx = (vga_p >= 10'd768) ? vga_p - 10'd768 : vga_p + 10'd128;
wire [9:0] sy1 = (sy == 10'd639) ? 10'd0 : sy + 1'd1;    // the row made now
wire [9:0] sy2 = (sy1 == 10'd639) ? 10'd0 : sy1 + 1'd1;  // the row fetched now

// a row y: its quadrant row, line in the quadrant, native line (vq: 0..191 paper, 192..209 bottom border,
// 302..319 top border)
function [8:0] yq_of;
	input [9:0] y;
	yq_of = (y >= 10'd304) ? y - 10'd304 : y[8:0];
endfunction
function [8:0] vq_of;
	input [9:0] y;
	reg [8:0] yq;
	reg [10:0] t;
	reg [8:0] src;
	begin
		yq = yq_of(y);
		t = {2'b00, yq} * 2'd3;
		src = t[10:2];
		vq_of = (src < 9'd18) ? src + 9'd302 : src - 9'd18;
	end
endfunction

wire [8:0] vq1 = vq_of(sy1);
wire [8:0] vq2 = vq_of(sy2);
wire [8:0] yq1 = yq_of(sy1);

// fetch: at the start of row sy the paper line of row sy + 2, if it is another than that of row sy + 1
always @(posedge clk) begin
	q_go <= 2'b00;
	if (!full && vga_p == 10'd768 && sy2 < 10'd608 && vq2 < 9'd192 &&
			(sy2 == 10'd0 || sy2 == 10'd304 || vq2 != vq1)) begin
		q_go <= (sy2 >= 10'd304) ? 2'b10 : 2'b01;
		q_vc <= vq2[7:0];
		q_buf <= vq2[0];
	end
end

// make row sy1: pixel rx = qx (0..575)
wire r_on = (qx < 10'd576) && (sy1 < 10'd608);
wire col = (qx >= 10'd288);
wire [8:0] xq = col ? qx - 10'd288 : qx[8:0];
wire [8:0] hq = xq - 9'd16;                       // the native pixel of the paper
wire [1:0] qm = {sy1 >= 10'd304, col};

assign q_addr = {vq1[0], hq[7:3]};
assign q_brd_addr = vq1;

reg ra_on = 1'b0, ra_paper = 1'b0, ra_rim = 1'b0, ra_absent = 1'b0, ra_par = 1'b0;
reg [9:0] ra_x = 10'd0;
reg [1:0] ra_m = 2'd0;
reg [2:0] ra_bit = 3'd0;

always @(posedge clk) begin
	ra_on <= r_on && !full;
	ra_x <= qx;
	ra_par <= sy1[0];
	ra_paper <= (vq1 < 9'd192) && (xq >= 9'd16) && (xq < 9'd272);
	ra_rim <= (qm == sel) && (xq < 9'd2 || xq >= 9'd286 || yq1 < 9'd2 || yq1 >= 9'd302);
	ra_absent <= (qm >= NUM_MACHINES);
	ra_m <= qm;
	ra_bit <= hq[2:0];
end

// q_words / q_brds: the block RAMs of the machines, one clock after q_addr / q_brd_addr
wire [15:0] ra_word = q_words[ra_m*16 +: 16];
wire [2:0] ra_brd = q_brds[ra_m*3 +: 3];
wire ra_ink = ra_word[15 - ra_bit] ^ (ra_word[7] & flash);
wire [3:0] ra_pix = ra_paper ? (ra_ink ? {ra_word[6], ra_word[2:0]} : {ra_word[6], ra_word[5:3]}) : {1'b0, ra_brd};

assign pb_we = ra_on;
assign pb_addr = {ra_par, ra_x};
assign pb_d = ra_rim ? 5'b10000 : ra_absent ? 5'b10001 : {1'b0, ra_pix};

// to video_px: the start of a row (qx 0), the parity of the row shown, whether it is in the picture
always @(posedge clk) begin
	qs_start <= (qx == 10'd0);
	qs_par <= sy[0];
	qs_vis <= (sy < 10'd608);
end

wire [3:0] c_pix = lb_q;

reg blank_a = 1'b1, hs_a = 1'b1, vs_a = 1'b1;
reg diag_a = 1'b0;
reg [2:0] diag_i = 3'd0;
wire diag_line = diag_en && dl >= 9'd264 && dl < 9'd272;

always @(posedge clk) begin
	// stage a: the address goes into the line buffer, the syncs of the same position
	blank_a <= (vga_x >= 9'd320 && vga_x < 9'd384) || (dl >= 9'd240 && dl < 9'd256);
	hs_a <= ~(vga_x >= 9'd328 && vga_x < 9'd376);
	vs_a <= ~(dl == 9'd242 || dl == 9'd243);
	diag_a <= 1'b1;
	if (diag_line && vga_x >= 9'd388 && vga_x < 9'd396) diag_i <= 3'd0;
	else if (diag_line && vga_x >= 9'd400 && vga_x < 9'd408) diag_i <= 3'd1;
	else if (diag_line && vga_x >= 9'd412 && vga_x < 9'd420) diag_i <= 3'd2;
	else if (diag_line && vga_x >= 9'd424 && vga_x < 9'd432) diag_i <= 3'd3;
	else if (diag_line && vga_x >= 9'd436 && vga_x < 9'd444) diag_i <= 3'd4;
	else diag_a <= 1'b0;

	// stage b: the colour
	hs <= hs_a;
	vs <= vs_a;
	if (blank_a) begin
		r <= 8'd0;
		g <= 8'd0;
		b <= 8'd0;
	end else if (diag_a) begin
		if (diag_i == 3'd4) begin
			r <= diag_blink ? 8'hFF : 8'h00;
			g <= diag_blink ? 8'hFF : 8'h00;
			b <= diag_blink ? 8'hFF : 8'h00;
		end else begin
			r <= diag_ok[diag_i[1:0]] ? 8'h00 : 8'hFF;
			g <= diag_ok[diag_i[1:0]] ? 8'hFF : 8'h00;
			b <= 8'h00;
		end
	end else begin
		r <= c_pix[1] ? (c_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
		g <= c_pix[2] ? (c_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
		b <= c_pix[0] ? (c_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
	end
end

endmodule
