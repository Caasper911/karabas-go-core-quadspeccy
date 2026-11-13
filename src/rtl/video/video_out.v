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

 Quad view (full = 0): the visible part of the raster, 736 clocks x 576 lines, holds four quadrants of
 368 x 288: the visible picture of the full screen (56 + 256 + 56 pixels, 48 + 192 + 48 lines), one
 pixel per clock of 28 MHz and one line per VGA line, half the size of the full screen in both
 directions. Machine 2 * row + column. A paper line comes from the line buffer of its machine, read
 from the SDRAM during the VGA line before it (q_go); the border has the colour of that native line
 (taken by the machine). The selected machine has a frame of rim_col (OSD), the machines that are not built
 are grey. The picture of the quad view is the screen memory at the time of the fetch, not the beam
 of the machine: multicolour and border effects are not exact there.

 VGA (vga_x 0..447 at 14 MHz, dl the native line shown), the porches of 720 x 576 p50: monitors take the black level
 at the start of the back porch; with the 16 clocks of before (0.57 us) some of them took the colour of the border
 there and lit the picture (found on monitors):
   vga_x 0..255 paper, 256..311 right border, 312..391 blank: front porch 312..319 (16 clocks, 0.57 us), hsync
   320..351 (64, 2.3 us), back porch 352..391 (80, 2.9 us); 392..447 left border (56 + 256 + 56 visible, 736 clocks)
   dl 0..191 paper, 192..239 bottom border, 240..271 blank (vsync in 242..243: 4 + 4 + 56 VGA lines), 272..319 top
   border (48 + 192 + 48 visible, 576 VGA lines); both syncs low active
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
	input wire [2:0] rim_col,     // colour of the frame of the selected machine {G, R, B}, bright
	input wire [9:0] cur_x,       // the mouse cursor of the quad view (picture position of its top left pixel)
	input wire [9:0] cur_y,
	input wire cur_on,

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
// quad view

// the doubled line shown (full screen: 2 * dl + half) and the screen position: q from the left edge of
// the picture (after the back porch, p 784), sy from its top (line 544 = 2 * dl 272, the first visible line of the top
// border); the picture is the visible part of the raster, 736 x 576, four quadrants of 368 x 288 (56 + 256 + 56,
// 48 + 192 + 48: the border of the full screen)
wire [9:0] ld = (vga_l < 10'd2) ? vga_l + 10'd638 : vga_l - 10'd2;
wire [9:0] row = (vga_p >= 10'd784) ? ((ld == 10'd639) ? 10'd0 : ld + 1'd1) : ld;
wire [9:0] sy = (row >= 10'd544) ? row - 10'd544 : row + 10'd96;
wire [9:0] qx = (vga_p >= 10'd784) ? vga_p - 10'd784 : vga_p + 10'd112;

wire q_vis = (qx < 10'd736) && (sy < 10'd576);
wire col = (qx >= 10'd368);
wire qrow = (sy >= 10'd288);
wire [8:0] xq = col ? qx - 10'd368 : qx[8:0];
wire [8:0] yq = qrow ? sy - 10'd288 : sy[8:0];
// the native position of the pixel
wire [8:0] hq = (xq < 9'd56) ? xq + 9'd392 : xq - 9'd56;
wire [8:0] vq = (yq < 9'd48) ? yq + 9'd272 : yq - 9'd48;
wire [1:0] qm = {qrow, col};

assign q_addr = {sy[0], hq[7:3]};
assign q_brd_addr = vq;


// the request of the next line, at the start of a line of the picture
wire [9:0] sy_n = (sy == 10'd639) ? 10'd0 : sy + 1'd1;
wire [8:0] yq_n = (sy_n >= 10'd288) ? sy_n - 10'd288 : sy_n[8:0];
wire [8:0] vq_n = (yq_n < 9'd48) ? yq_n + 9'd272 : yq_n - 9'd48;

always @(posedge clk) begin
	q_go <= 2'b00;
	if (!full && vga_p == 10'd784 && sy_n < 10'd576 && vq_n < 9'd192) begin
		q_go <= (sy_n >= 10'd288) ? 2'b10 : 2'b01;
		q_vc <= vq_n[7:0];
		q_buf <= sy_n[0];
	end
end

// the cursor of the quad view (quad_mouse.v), 16 x 16: a row is {mask, white} (bit 15 the left pixel), black outline
function [31:0] cursor_row;
	input [3:0] r;
	case (r)
		4'd0: cursor_row = 32'h8000_0000;
		4'd1: cursor_row = 32'hC000_0000;
		4'd2: cursor_row = 32'hE000_4000;
		4'd3: cursor_row = 32'hF000_6000;
		4'd4: cursor_row = 32'hF800_7000;
		4'd5: cursor_row = 32'hFC00_7800;
		4'd6: cursor_row = 32'hFE00_7C00;
		4'd7: cursor_row = 32'hFF00_7E00;
		4'd8: cursor_row = 32'hFF80_7F00;
		4'd9: cursor_row = 32'hFFC0_7F80;
		4'd10: cursor_row = 32'hFFE0_7FC0;
		4'd11: cursor_row = 32'hFFF0_7E00;
		4'd12: cursor_row = 32'hFF00_7600;
		4'd13: cursor_row = 32'hFF80_6700;
		4'd14: cursor_row = 32'hE780_4300;
		default: cursor_row = 32'hC300_0000;
	endcase
endfunction

wire [9:0] cdx = qx - cur_x;
wire [9:0] cdy = sy - cur_y;
wire [31:0] c_row = cursor_row(cdy[3:0]);

reg qa_vis = 1'b0, qa_paper = 1'b0, qa_rim = 1'b0, qa_absent = 1'b0, qa_cur = 1'b0, qa_cur_w = 1'b0;
reg [1:0] qa_m = 2'd0;
reg [2:0] qa_bit = 3'd0;
// q_words / q_brds come from the block RAMs of the machines, one clock after q_addr / q_brd_addr: the word of
// stage a, taken from the machine of stage a
wire [15:0] qa_word = q_words[qa_m*16 +: 16];
wire [2:0] qa_brd = q_brds[qa_m*3 +: 3];

always @(posedge clk) begin
	qa_vis <= q_vis;
	qa_paper <= (hq < 9'd256) && (vq < 9'd192);
	qa_rim <= (qm == sel) && (xq < 9'd2 || xq >= 9'd366 || yq < 9'd2 || yq >= 9'd286);
	qa_absent <= (qm >= NUM_MACHINES);
	qa_cur <= cur_on && cdx < 10'd16 && cdy < 10'd16 && c_row[16 + 15 - cdx[3:0]];
	qa_cur_w <= c_row[15 - cdx[3:0]];
	qa_m <= qm;
	qa_bit <= hq[2:0];
end

wire qa_ink = qa_word[15 - qa_bit] ^ (qa_word[7] & flash);
wire [3:0] q_pix = qa_paper ? (qa_ink ? {qa_word[6], qa_word[2:0]} : {qa_word[6], qa_word[5:3]}) : {1'b0, qa_brd};

// the colour of the line buffer (full) or of the quad view
wire [3:0] c_pix = full ? lb_q : q_pix;

reg blank_a = 1'b1, hs_a = 1'b1, vs_a = 1'b1;
reg diag_a = 1'b0;
reg [2:0] diag_i = 3'd0;
wire diag_line = diag_en && dl >= 9'd272 && dl < 9'd280;

always @(posedge clk) begin
	// stage a: the address goes into the line buffer, the syncs of the same position
	// lines: by the rows of the picture (sy, from the left border at vga_x 392), as the quad view; with dl (which
	// changes at vga_x 0) the first visible line had no left border and the one after the last had it
	blank_a <= (vga_x >= 9'd312 && vga_x < 9'd392) || (sy >= 10'd576);
	hs_a <= ~(vga_x >= 9'd320 && vga_x < 9'd352);
	vs_a <= ~(dl == 9'd242 || dl == 9'd243);
	diag_a <= 1'b1;
	if (diag_line && vga_x >= 9'd394 && vga_x < 9'd402) diag_i <= 3'd0;
	else if (diag_line && vga_x >= 9'd404 && vga_x < 9'd412) diag_i <= 3'd1;
	else if (diag_line && vga_x >= 9'd414 && vga_x < 9'd422) diag_i <= 3'd2;
	else if (diag_line && vga_x >= 9'd424 && vga_x < 9'd432) diag_i <= 3'd3;
	else if (diag_line && vga_x >= 9'd434 && vga_x < 9'd442) diag_i <= 3'd4;
	else diag_a <= 1'b0;

	// stage b: the colour
	hs <= hs_a;
	vs <= vs_a;
	if (blank_a) begin
		r <= 8'd0;
		g <= 8'd0;
		b <= 8'd0;
	end else if (!full && !qa_vis) begin
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
	end else if (!full && qa_cur) begin
		r <= qa_cur_w ? 8'hFF : 8'h00;
		g <= qa_cur_w ? 8'hFF : 8'h00;
		b <= qa_cur_w ? 8'hFF : 8'h00;
	end else if (!full && qa_rim) begin
		r <= rim_col[1] ? 8'hFF : 8'h00;
		g <= rim_col[2] ? 8'hFF : 8'h00;
		b <= rim_col[0] ? 8'hFF : 8'h00;
	end else if (!full && qa_absent) begin
		r <= 8'h30;
		g <= 8'h30;
		b <= 8'h30;
	end else begin
		r <= c_pix[1] ? (c_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
		g <= c_pix[2] ? (c_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
		b <= c_pix[0] ? (c_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
	end
end

endmodule
