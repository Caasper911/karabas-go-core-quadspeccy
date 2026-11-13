`timescale 1ns / 1ps
// The picture of video_out against a model (a pixel a clock of clk_bus, 28 MHz; the DAC takes it with V_CLK):
// - quad view: the machines answer q_go by filling their line buffer (line q_vc into buffer q_buf) 400 clocks later,
//   words and border colours are a hash of machine and native line; every pixel of the picture (736 x 576, quadrants
//   368 x 288: 56 + 256 + 56 pixels, 48 + 192 + 48 lines, frame of the selected machine, grey for a machine not
//   built) against the expected one, black outside it;
// - full screen (pix: one colour): 576 lines of 736 lit pixels from the same place;
// - every line 896 clocks, the picture 80 clocks after the end of hsync (back porch).
// Ends with "tb_vpx: N errors". Run: src/sim/run_vpx.sh
module tb_vpx;

reg clk = 1'b0;
always #17.838 clk = ~clk;

wire ce7, ce_cpu, int_n, vga_half; wire [8:0] hc, vc, vga_x; wire [9:0] vga_p, vga_l; wire [4:0] frame;
zx_timing t(.clk(clk), .reset(1'b0), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(), .hc(hc), .vc(vc), .int_n(int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l));

// the model of the machines
function [15:0] word_of(input [1:0] m, input [7:0] line, input [4:0] col);
	reg [15:0] h;
	begin
		h = {line, 3'd0, col} * 16'h9E37 + {m, 8'd0} + line;
		word_of = {h[15:8], 1'b0, h[6:0]};   // no flash
	end
endfunction
function [2:0] brd_of(input [1:0] m, input [8:0] line);
	brd_of = 3'd1 + ((line + m) % 7);     // never black
endfunction

reg [15:0] qb [0:255];   // {machine, buffer, column}
wire [1:0] q_go; wire [7:0] q_vc; wire q_buf; wire [5:0] q_addr; wire [8:0] q_brd_addr;
reg [63:0] q_words = 64'd0; reg [11:0] q_brds = 12'd0;
integer k, fill_t0 = -1, fill_t1 = -1;
reg [7:0] f_vc0, f_vc1; reg f_b0, f_b1;
always @(posedge clk) begin
	if (q_go[0]) begin fill_t0 = 400; f_vc0 = q_vc; f_b0 = q_buf; end
	if (q_go[1]) begin fill_t1 = 400; f_vc1 = q_vc; f_b1 = q_buf; end
	if (fill_t0 == 0) for (k = 0; k < 32; k = k + 1) begin
		qb[{2'd0, f_b0, k[4:0]}] = word_of(0, f_vc0, k); qb[{2'd1, f_b0, k[4:0]}] = word_of(1, f_vc0, k);
	end
	if (fill_t1 == 0) for (k = 0; k < 32; k = k + 1) begin
		qb[{2'd2, f_b1, k[4:0]}] = word_of(2, f_vc1, k); qb[{2'd3, f_b1, k[4:0]}] = word_of(3, f_vc1, k);
	end
	if (fill_t0 >= 0) fill_t0 = fill_t0 - 1;
	if (fill_t1 >= 0) fill_t1 = fill_t1 - 1;
	q_words <= {qb[{2'd3, q_addr}], qb[{2'd2, q_addr}], qb[{2'd1, q_addr}], qb[{2'd0, q_addr}]};
	q_brds <= {brd_of(3, q_brd_addr), brd_of(2, q_brd_addr), brd_of(1, q_brd_addr), brd_of(0, q_brd_addr)};
end

reg full = 1'b0;
reg [1:0] sel = 2'd1;
wire [7:0] r, g, b; wire hs, vs;
video_out #(.NUM_MACHINES(3)) vo(.clk(clk), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(ce7), .w_hc(hc), .w_vc(vc),
	.vga_x(vga_x), .vga_p(vga_p), .vga_l(vga_l), .flash(1'b0), .full(full), .sel(sel), .rim_col(3'd4), .pix(4'd5),
	.q_go(q_go), .q_vc(q_vc), .q_buf(q_buf), .q_addr(q_addr), .q_words(q_words), .q_brd_addr(q_brd_addr),
	.q_brds(q_brds), .diag_en(1'b0), .diag_ok(4'd0), .diag_blink(1'b0), .r(r), .g(g), .b(b), .hs(hs), .vs(vs));

// the expected colour of quad pixel x (0..735) of row y (0..575)
function [23:0] rgb_of(input [3:0] c);
	rgb_of = {c[1] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0, c[2] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0,
		c[0] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0};
endfunction
function [23:0] expect_of(input integer x, input integer y);
	integer yq, xq, vq, m, hq;
	reg [15:0] w;
	begin
		yq = (y >= 288) ? y - 288 : y;
		xq = (x >= 368) ? x - 368 : x;
		m = ((y >= 288) ? 2 : 0) + ((x >= 368) ? 1 : 0);
		vq = (yq < 48) ? yq + 272 : yq - 48;
		hq = xq - 56;
		if (m == sel && (xq < 2 || xq >= 366 || yq < 2 || yq >= 286))
			expect_of = 24'h00FF00;
		else if (m >= 3)
			expect_of = 24'h303030;
		else if (vq < 192 && xq >= 56 && xq < 312) begin
			w = word_of(m, vq, hq / 8);
			expect_of = w[15 - (hq % 8)] ? rgb_of({w[6], w[2:0]}) : rgb_of({w[6], w[5:3]});
		end else
			expect_of = rgb_of({1'b0, brd_of(m, vq)});
	end
endfunction

// the pixels per line from the end of hsync; in the quad frame the first line with a lit pixel is row 0
integer line = -1, row = -1, x0 = -1, errors = 0, checks = 0, frames = 0, pix_line = 0, bad_len = 0;
integer i, lit, first, f_x0 = -1, f_lines = 0;
reg hs_d = 1'b1, vs_d = 1'b1;
reg [23:0] line_rgb [0:1023];
always @(posedge clk) begin
	if (hs && !hs_d) begin
		if (frames >= 1 && line >= 0 && pix_line != 896) begin
			bad_len = bad_len + 1;
			if (bad_len < 5) $display("frame %0d line %0d: %0d clocks", frames, line, pix_line);
		end
		lit = 0; first = -1;
		for (i = 0; i < pix_line; i = i + 1)
			if (line_rgb[i] != 24'd0) begin
				lit = lit + 1;
				if (first < 0) first = i;
			end
		// quad: frame 2
		if (!full && frames == 2 && lit) begin
			if (row < 0) begin row = 0; x0 = first; end
			else if (first != x0) begin
				errors = errors + 1;
				if (errors < 10) $display("row %0d starts at %0d, row 0 at %0d", row, first, x0);
			end
			if (row < 576) begin
				for (i = 0; i < pix_line; i = i + 1)
					if ((i < x0 || i >= x0 + 736) && line_rgb[i] != 24'd0) begin
						errors = errors + 1;
						if (errors < 10) $display("row %0d pixel %0d outside the picture: %h", row, i, line_rgb[i]);
					end
				for (i = 0; i < 736; i = i + 1) begin
					checks = checks + 1;
					if (line_rgb[x0 + i] !== expect_of(i, row)) begin
						errors = errors + 1;
						if (errors < 10) $display("row %0d x %0d: %h, expected %h", row, i, line_rgb[x0 + i], expect_of(i, row));
					end
				end
			end
			row = row + 1;
		end
		// full screen: frame 4
		if (full && frames == 4 && lit) begin
			f_lines = f_lines + 1;
			if (lit != 736 || (f_x0 >= 0 && first != f_x0)) begin
				errors = errors + 1;
				if (errors < 10) $display("full: line %0d: %0d lit from %0d", line, lit, first);
			end
			f_x0 = first;
		end
		line = line + 1;
		pix_line = 0;
	end
	if (vs && !vs_d) begin
		frames = frames + 1;
		line = 0;
		if (frames == 3) begin
			$display("tb_vpx: quad: %0d rows, %0d pixels checked, the picture %0d clocks after hsync", row, checks, x0);
			if (row != 576) errors = errors + 1;
			full = 1'b1;
			line = -1;   // the line of the switch
		end
		if (frames == 5) begin
			$display("tb_vpx: full: %0d lit lines, the picture %0d clocks after hsync", f_lines, f_x0);
			if (f_lines != 576) errors = errors + 1;
			if (bad_len) $display("tb_vpx: %0d lines of a wrong length", bad_len);
			$display("tb_vpx: %0d errors", errors + bad_len);
			$finish;
		end
	end
	if (pix_line < 1024) line_rgb[pix_line] = {r, g, b};
	pix_line = pix_line + 1;
	hs_d = hs;
	vs_d = vs;
end

endmodule
