`timescale 1ns / 1ps
// The quad view at 21 MHz (video_out + video_px, docs/QUAD_SCALE.md variant B) against a model of the picture:
// the machines answer q_go by filling their line buffer (line q_vc into buffer q_buf) 600 clocks later, words and
// border colours are a hash of machine and native line; every pixel the DAC takes (rising V_CLK) in the picture
// is compared with the expected one (quadrant 288 x 304, 16 + 256 + 16 pixels, native line = 3 / 4 of the row,
// 18 + 192 + 18 lines, frame of the selected machine, grey for a machine not built). Also: 672 pixels a line in the
// quad view, 896 in the full screen. Ends with "tb_vpx: N errors".
// Run: src/sim/run_vpx.sh
module tb_vpx;

reg clk_sys = 1'b0, clk_bus = 1'b0;
always #5.946 clk_sys = ~clk_sys;
always #17.838 clk_bus = ~clk_bus;

wire ce7, ce_cpu, int_n, vga_half; wire [8:0] hc, vc, vga_x; wire [9:0] vga_p, vga_l; wire [4:0] frame;
zx_timing t(.clk(clk_bus), .reset(1'b0), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(), .hc(hc), .vc(vc), .int_n(int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l));
wire ce28, ce28_n;
bus_ce bc(.clk_sys(clk_sys), .clk_bus(clk_bus), .ce(ce28), .ce_n(ce28_n), .v_clk());

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
always @(posedge clk_bus) begin
	if (q_go[0]) begin fill_t0 = 600; f_vc0 = q_vc; f_b0 = q_buf; end
	if (q_go[1]) begin fill_t1 = 600; f_vc1 = q_vc; f_b1 = q_buf; end
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
reg narrow = 1'b1;
reg [1:0] sel = 2'd1;
wire [7:0] vr, vg, vb; wire vhs, vvs;
wire pb_we, qs_start, qs_par, qs_vis; wire [10:0] pb_addr; wire [4:0] pb_d;
video_out #(.NUM_MACHINES(3)) vo(.clk(clk_bus), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(ce7), .w_hc(hc), .w_vc(vc),
	.vga_x(vga_x), .vga_p(vga_p), .vga_l(vga_l), .flash(1'b0), .full(full), .narrow(narrow), .sel(sel), .pix(4'd5),
	.q_go(q_go), .q_vc(q_vc), .q_buf(q_buf), .q_addr(q_addr), .q_words(q_words), .q_brd_addr(q_brd_addr),
	.q_brds(q_brds), .pb_we(pb_we), .pb_addr(pb_addr), .pb_d(pb_d), .qs_start(qs_start), .qs_par(qs_par),
	.qs_vis(qs_vis), .diag_en(1'b0), .diag_ok(4'd0), .diag_blink(1'b0),
	.r(vr), .g(vg), .b(vb), .hs(vhs), .vs(vvs));
wire ce_px, v_clk; wire [7:0] r, g, b; wire hs, vs;
video_px px(.clk_sys(clk_sys), .ce28(ce28), .ce28_n(ce28_n), .full(full), .narrow(narrow), .r_i(vr), .g_i(vg), .b_i(vb), .hs_i(vhs), .vs_i(vvs),
	.clk_bus(clk_bus), .pb_we(pb_we), .pb_addr(pb_addr), .pb_d(pb_d), .qs_start(qs_start), .qs_par(qs_par),
	.qs_vis(qs_vis), .rim_col(3'd4), .ce_px(ce_px), .v_clk(v_clk), .r(r), .g(g), .b(b), .hs(hs), .vs(vs));

// the expected colour of quad pixel x (0..575) of row y (0..607)
function [23:0] rgb_of(input [3:0] c);
	rgb_of = {c[1] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0, c[2] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0,
		c[0] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0};
endfunction
// narrow: quadrant 288, border 16 / 18, line = 3 / 4 of the row; normal: 384, 64 / 64, line = row
function [23:0] expect_of(input integer x, input integer y);
	integer yq, xq, src, vq, m, hq, qw, bl, bt;
	reg [15:0] w;
	begin
		qw = narrow ? 288 : 384;
		bl = narrow ? 16 : 64;
		bt = narrow ? 18 : 64;
		yq = (y >= 304) ? y - 304 : y;
		xq = (x >= qw) ? x - qw : x;
		m = ((y >= 304) ? 2 : 0) + ((x >= qw) ? 1 : 0);
		src = narrow ? yq * 3 / 4 : yq;
		vq = (src < bt) ? src + 320 - bt : src - bt;
		hq = xq - bl;
		if (m == sel && (xq < 2 || xq >= qw - 2 || yq < 2 || yq >= 302))
			expect_of = 24'h00FF00;
		else if (m >= 3)
			expect_of = 24'h303030;
		else if (vq < 192 && xq >= bl && xq < bl + 256) begin
			w = word_of(m, vq, hq / 8);
			expect_of = w[15 - (hq % 8)] ? rgb_of({w[6], w[2:0]}) : rgb_of({w[6], w[5:3]});
		end else
			expect_of = rgb_of({1'b0, brd_of(m, vq)});
	end
endfunction

// the samples of the DAC: per line from the end of hsync; the first line with a lit sample is row 0, the first lit
// sample of it is pixel 0
integer n = 0, line = -1, row = -1, x0 = -1, errors = 0, checks = 0, frames = 0, pix_line = 0, bad_len = 0;
reg hs_d = 1'b1, vs_d = 1'b1, lit_line = 1'b0;
reg [23:0] line_rgb [0:1023];
integer i;
always @(posedge v_clk) begin
	if (hs && !hs_d) begin
		// a line ended: its length (from the second frame on), then the pixels of a row
		if (frames >= 1 && line >= 0 && pix_line != ((full || !narrow) ? 896 : 672)) begin
			bad_len = bad_len + 1;
			if (bad_len < 5) $display("frame %0d line %0d: %0d pixels", frames, line, pix_line);
		end
		if (!full && (frames == 2 || frames == 4)) begin
			lit_line = 1'b0;
			for (i = 0; i < pix_line; i = i + 1)
				if (line_rgb[i] != 24'd0 && !lit_line) begin
					lit_line = 1'b1;
					if (row < 0) begin row = 0; x0 = i; end
					else if (i != x0) begin
						errors = errors + 1;
						if (errors < 10) $display("row %0d starts at %0d, row 0 at %0d", row, i, x0);
					end
				end
			if (row >= 0 && row < 608) begin
				for (i = 0; i < (narrow ? 576 : 768); i = i + 1) begin
					checks = checks + 1;
					if (line_rgb[x0 + i] !== expect_of(i, row)) begin
						errors = errors + 1;
						if (errors < 10) $display("row %0d x %0d: %h, expected %h", row, i, line_rgb[x0 + i], expect_of(i, row));
					end
				end
				row = row + 1;
			end
		end
		line = line + 1;
		pix_line = 0;
	end
	if (vs && !vs_d) begin
		frames = frames + 1;
		line = 0;
		if ((frames == 3 || frames == 5) && row != 608) begin
			errors = errors + 1;
			$display("frame %0d: %0d rows", frames, row);
		end
		// frames 2 narrow, 4 normal (each after a frame to settle), 6 full screen
		if (frames == 3) begin
			$display("tb_vpx: quad narrow: %0d pixels checked", checks);
			narrow = 1'b0;
			// the line of the switch has pixels of both, the next one a pixel less: the pixel phase is set again at
			// the start of a row of the picture (qs_start), in the middle of a VGA line
			line = -2;
		end
		if (frames == 4)
			x0 = -1;      // pixel 0 is found again (another pixel clock)
		if (frames == 5) begin
			$display("tb_vpx: quad normal: %0d pixels checked", checks);
			full = 1'b1;
			line = -1;
		end
		if (frames == 7) begin
			if (bad_len) $display("tb_vpx: %0d lines of a wrong length", bad_len);
			$display("tb_vpx: %0d errors", errors + bad_len);
			$finish;
		end
		row = -1;
	end
	if (pix_line < 1024) line_rgb[pix_line] = {r, g, b};
	pix_line = pix_line + 1;
	hs_d = hs;
	vs_d = vs;
end

endmodule
