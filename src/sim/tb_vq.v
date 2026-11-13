`timescale 1ns / 1ps
// video_out (machines with block RAM: q_words / q_brds one clock after the address) against the version before
// (work_v/video_out_old.v, asynchronous reads): the same RGB / syncs every clock in the quad view. The old copy:
//   git show 4ea395d:src/rtl/video/video_out.v | sed 's/^module video_out/module video_out_old/' > work_v/video_out_old.v
// work_v/vq.prj: kg_sdpram, zx_timing, video_out_old, video_out, tb_vq; fuse -top tb_vq; prints "tb_vq: ... 0 errors".
module tb_vq;
reg clk = 0; always #17.8 clk = ~clk;
wire ce7, ce_cpu, int_n; wire [8:0] hc, vc, vga_x; wire [9:0] vga_p, vga_l; wire [4:0] frame;
zx_timing t(.clk(clk), .reset(1'b0), .ce14(), .vga_half(), .ce7(ce7), .ce_cpu(ce_cpu), .hc(hc), .vc(vc), .int_n(int_n), .frame(frame),
	.vga_x(vga_x), .vga_p(vga_p), .vga_l(vga_l));
// contents: a hash of machine, address
function [15:0] wf(input [1:0] m, input [5:0] a); wf = {a, m, 2'b01, ~a[3:0], m} * 16'h9E37 + {m, a}; endfunction
function [2:0] bf(input [1:0] m, input [8:0] a); bf = a[5:3] ^ {m, a[0]}; endfunction
wire [5:0] qa0, qa1; wire [8:0] ba0, ba1;
wire [63:0] qw0 = {wf(3, qa0), wf(2, qa0), wf(1, qa0), wf(0, qa0)};
wire [11:0] qb0 = {bf(3, ba0), bf(2, ba0), bf(1, ba0), bf(0, ba0)};
reg [63:0] qw1 = 0; reg [11:0] qb1 = 0;
always @(posedge clk) begin
	qw1 <= {wf(3, qa1), wf(2, qa1), wf(1, qa1), wf(0, qa1)};
	qb1 <= {bf(3, ba1), bf(2, ba1), bf(1, ba1), bf(0, ba1)};
end
wire [7:0] r0, g0, b0, r1, g1, b1; wire hs0, vs0, hs1, vs1;
reg flash = 0; reg [1:0] sel = 1;
video_out_old v0(.clk(clk), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(ce7), .w_hc(hc), .w_vc(vc), .vga_x(vga_x),
	.vga_p(vga_p), .vga_l(vga_l), .flash(flash), .full(1'b0), .sel(sel), .rim_col(3'd4), .pix(4'd0),
	.q_go(), .q_vc(), .q_buf(), .q_addr(qa0), .q_words(qw0), .q_brd_addr(ba0), .q_brds(qb0),
	.diag_en(1'b1), .diag_ok(4'b1010), .diag_blink(frame[4]), .r(r0), .g(g0), .b(b0), .hs(hs0), .vs(vs0));
video_out v1(.clk(clk), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(ce7), .w_hc(hc), .w_vc(vc), .vga_x(vga_x),
	.vga_p(vga_p), .vga_l(vga_l), .flash(flash), .full(1'b0), .sel(sel), .rim_col(3'd4), .pix(4'd0),
	.q_go(), .q_vc(), .q_buf(), .q_addr(qa1), .q_words(qw1), .q_brd_addr(ba1), .q_brds(qb1),
	.diag_en(1'b1), .diag_ok(4'b1010), .diag_blink(frame[4]), .r(r1), .g(g1), .b(b1), .hs(hs1), .vs(vs1));
integer n = 0, err = 0, lit = 0;
always @(posedge clk) begin
	n = n + 1;
	if (n > 100) begin
		if ({r0, g0, b0, hs0, vs0} !== {r1, g1, b1, hs1, vs1}) begin
			err = err + 1;
			if (err < 10) $display("diff at %0d p %0d l %0d: %h %h", n, vga_p, vga_l, {r0, g0, b0}, {r1, g1, b1});
		end
		if (r0 | g0 | b0) lit = lit + 1;
	end
	if (n == 100000) flash = 1;
	if (n == 400000) sel = 2;
	if (n == 2 * 573440 + 200) begin
		$display("tb_vq: %0d clocks, %0d lit, %0d errors", n, lit, err);
		$finish;
	end
end
endmodule
