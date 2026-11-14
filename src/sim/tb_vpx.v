`timescale 1ns / 1ps
// The picture of video_out against a model (a pixel a clock of clk_bus, 28 MHz; the DAC takes it with V_CLK):
// - quad view: four machines (raster_delay 2k as the core) make pix on their raster, a colour of machine, frame, line
//   and pixel (every pixel differs from frame to frame: as border effects), written by quad_fb into a model of the
//   SRAM (2M x 16, 10 ns; checks /WR, address and data held around it, no fight on MD); every pixel of the picture
//   (736 x 576, quadrants 368 x 288: 56 + 256 + 56 pixels, 48 + 192 + 48 lines, frame of the selected machine, grey
//   for a machine not built) against the colour of the frame before the one being written (fid - 1: no tear), black
//   outside it; the mouse cursor (16 x 16 at 500, 300) over it; quad frames 3 and 4;
// - full screen (pix: one colour): 576 lines of 736 lit pixels from the same place;
// - every line 896 clocks, the picture 80 clocks after the end of hsync (back porch).
// Ends with "tb_vpx: N errors". Run: src/sim/run_vpx.sh
module tb_vpx;

// clk_sys 84 MHz, clk_bus = clk_sys / 3: every rising edge of clk_bus is one of clk_sys
reg clk = 1'b0, clk_sys = 1'b0;
always #5.946 clk_sys = ~clk_sys;
always #17.838 clk = ~clk;

wire ce7, ce_cpu, int_n, vga_half; wire [8:0] hc, vc, vga_x; wire [9:0] vga_p, vga_l; wire [4:0] frame;
zx_timing t(.clk(clk), .reset(1'b0), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(), .hc(hc), .vc(vc), .int_n(int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l));

// the frame id: changes where quad_fb changes its frame bit
integer fid = 0;
always @(posedge clk)
	if (ce7 && hc == 9'd0 && vc == 9'd256)
		fid <= fid + 1;

// the model of the machines: the colour of pixel h / v of frame f (never black)
function [3:0] col_of(input integer m, input integer f, input integer v, input integer h);
	reg [31:0] x;
	begin
		x = (((f * 7 + m) * 331 + v) * 467 + h) * 32'h9E3779B1;
		col_of = {x[20], 3'd1 + (x[31:16] % 7)};
	end
endfunction

wire [3:0] m_ce7; wire [35:0] m_hc, m_vc; reg [15:0] m_pix = 16'd0;
genvar gk;
generate
	for (gk = 0; gk < 4; gk = gk + 1) begin : g_m
		raster_delay #(.D(2 * gk)) rd(.clk(clk), .ce7_i(ce7), .hc_i(hc), .vc_i(vc), .int_n_i(int_n), .frame_i(frame),
			.ce7(m_ce7[gk]), .hc(m_hc[gk*9 +: 9]), .vc(m_vc[gk*9 +: 9]), .int_n(), .frame());
		// pix is the colour of hc / vc of two ce7 before (pentagon.v)
		reg [8:0] ph = 9'd0, pv = 9'd0;
		always @(posedge clk)
			if (m_ce7[gk]) begin
				ph <= m_hc[gk*9 +: 9];
				pv <= m_vc[gk*9 +: 9];
				m_pix[gk*4 +: 4] <= col_of(gk, fid, pv, ph);
			end
	end
endgenerate

// the SRAM
wire [20:0] MA; wire [15:0] MD; wire [1:0] MRD_N, MWR_N;
reg [15:0] mem [0:(1 << 20) - 1];
integer sram_err = 0;
assign #10 MD = (MRD_N == 2'b00) ? mem[MA] : 16'bz;
reg [20:0] wa; real w_t0;
always @(negedge MWR_N[0]) begin
	wa = MA; w_t0 = $realtime;
	if (MWR_N != 2'b00 || MRD_N != 2'b11) begin sram_err = sram_err + 1; $display("%t: SRAM /WR %b /RD %b", $time, MWR_N, MRD_N); end
end
always @(posedge MWR_N[0]) if ($time > 0) begin   // not the x -> 1 at the start
	if (MA !== wa || ^MD === 1'bx || $realtime - w_t0 < 10.0) begin
		sram_err = sram_err + 1;
		if (sram_err < 10) $display("%t: SRAM write %h -> %h, data %h, %0.1f ns", $time, wa, MA, MD, $realtime - w_t0);
	end
	mem[wa[19:0]] = MD;
end
// the FPGA drives MD while the SRAM may (/RD low and 10 ns after it)
always @(posedge clk_sys)
	if (fbuf.sram.md_t != 16'hFFFF && MRD_N != 2'b11) begin
		sram_err = sram_err + 1;
		if (sram_err < 10) $display("%t: MD driven by both", $time);
	end

reg full = 1'b0;
reg [1:0] sel = 2'd1;
wire fb_rd; wire [17:0] fb_raddr; wire [15:0] fb_word;
quad_fb fbuf(.clk(clk), .clk_sys(clk_sys), .ce7(ce7), .hc(hc), .vc(vc), .m_ce7(m_ce7), .m_hc(m_hc), .m_vc(m_vc),
	.m_pix(m_pix), .rd(fb_rd), .rd_addr(fb_raddr), .word(fb_word), .MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N));

wire [7:0] r, g, b; wire hs, vs;
video_out #(.NUM_MACHINES(3)) vo(.clk(clk), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(ce7), .w_hc(hc), .w_vc(vc),
	.vga_x(vga_x), .vga_p(vga_p), .vga_l(vga_l), .full(full), .sel(sel), .rim_col(3'd4), .cur_x(10'd500), .cur_y(10'd300), .cur_on(1'b1), .pix(4'd5),
	.fb_rd(fb_rd), .fb_raddr(fb_raddr), .fb_word(fb_word),
	.diag_en(1'b0), .diag_ok(4'd0), .diag_blink(1'b0), .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .de());

// the expected colour of quad pixel x (0..735) of row y (0..575)
function [23:0] rgb_of(input [3:0] c);
	rgb_of = {c[1] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0, c[2] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0,
		c[0] ? (c[3] ? 8'hFF : 8'hCA) : 8'd0};
endfunction
function [23:0] expect_of(input integer x, input integer y, input integer f);
	integer yq, xq, vq, m, hq;
	reg [31:0] cr;
	begin
		cr = vo.cursor_row(y - 300);
		yq = (y >= 288) ? y - 288 : y;
		xq = (x >= 368) ? x - 368 : x;
		m = ((y >= 288) ? 2 : 0) + ((x >= 368) ? 1 : 0);
		vq = (yq < 48) ? yq + 272 : yq - 48;
		hq = (xq < 56) ? xq + 392 : xq - 56;
		if (x >= 500 && x < 516 && y >= 300 && y < 316 && cr[16 + 15 - (x - 500)])
			expect_of = cr[15 - (x - 500)] ? 24'hFFFFFF : 24'h000000;
		else if (m == sel && (xq < 2 || xq >= 366 || yq < 2 || yq >= 286))
			expect_of = 24'h00FF00;
		else if (m >= 3)
			expect_of = 24'h303030;
		else
			expect_of = rgb_of(col_of(m, f, vq, hq));
	end
endfunction

// the pixels per line from the end of hsync; in the quad frame the first line with a lit pixel is row 0
integer line = -1, row = -1, x0 = -1, errors = 0, checks = 0, frames = 0, pix_line = 0, bad_len = 0;
integer i, lit, first, f_x0 = -1, f_lines = 0;
reg hs_d = 1'b1, vs_d = 1'b1;
integer f_line = 0, q_frames = 0;   // fid while the line was shown
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
		// quad: frames 2 and 3
		if (!full && (frames == 2 || frames == 3) && lit) begin
			if (row < 0) begin row = 0; if (x0 < 0) x0 = first; end
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
					if (line_rgb[x0 + i] !== expect_of(i, row, f_line - 1)) begin
						errors = errors + 1;
						if (errors < 10) $display("row %0d x %0d: %h, expected %h (frame %0d), frame before %h", row, i,
							line_rgb[x0 + i], expect_of(i, row, f_line - 1), f_line - 1, expect_of(i, row, f_line - 2));
					end
				end
			end
			row = row + 1;
		end
		// full screen: frame 5
		if (full && frames == 5 && lit) begin
			f_lines = f_lines + 1;
			if (lit != 736 || (f_x0 >= 0 && first != f_x0)) begin
				errors = errors + 1;
				if (errors < 10) $display("full: line %0d: %0d lit from %0d", line, lit, first);
			end
			f_x0 = first;
		end
		line = line + 1;
		pix_line = 0;
		f_line = fid;
	end
	if (vs && !vs_d) begin
		frames = frames + 1;
		line = 0;
		if (frames == 3 || frames == 4) begin
			$display("tb_vpx: quad: %0d rows, %0d pixels checked, the picture %0d clocks after hsync", row, checks, x0);
			if (row != 576) errors = errors + 1;
			row = -1;
		end
		if (frames == 4) begin
			full = 1'b1;
			line = -1;   // the line of the switch
		end
		if (frames == 6) begin
			$display("tb_vpx: full: %0d lit lines, the picture %0d clocks after hsync", f_lines, f_x0);
			if (f_lines != 576) errors = errors + 1;
			if (bad_len) $display("tb_vpx: %0d lines of a wrong length", bad_len);
			if (sram_err) $display("tb_vpx: %0d SRAM errors", sram_err);
			$display("tb_vpx: %0d errors", errors + bad_len + sram_err);
			$finish;
		end
	end
	if (pix_line < 1024) line_rgb[pix_line] = {r, g, b};
	pix_line = pix_line + 1;
	hs_d = hs;
	vs_d = vs;
end

endmodule
