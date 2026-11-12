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

 VGA (vga_x 0..447 at 14 MHz, dl the native line shown):
   vga_x 0..255 paper, 256..319 right border, 320..383 blank (hsync 328..375), 384..447 left border
   dl 240..255 blank, vsync in 242..243 (4 VGA lines); both syncs low active
*/

module video_out (
	input wire clk,
	input wire ce7,
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire [8:0] vga_x,

	input wire [3:0] pix,

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
	if (ce7) begin
		hd1 <= hc;
		hd2 <= hd1;
		vd1 <= vc;
		vd2 <= vd1;
	end

wire [3:0] lb_q;

kg_sdpram #(.DW(4), .AW(10)) linebuf (
	.clka(clk),
	.wea(ce7),
	.addra({vd2[0], hd2}),
	.dina(pix),
	.clkb(clk),
	.enb(1'b1),
	.addrb({~vc[0], vga_x}),
	.doutb(lb_q)
);

// the line shown: the one before vc
wire [8:0] dl = (vc == 9'd0) ? 9'd319 : vc - 1'd1;

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
		r <= lb_q[1] ? (lb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
		g <= lb_q[2] ? (lb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
		b <= lb_q[0] ? (lb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
	end
end

endmodule
