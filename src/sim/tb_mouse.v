`timescale 1ns / 1ps
// quad_mouse: the cursor of the quad view (moves, clamped to 736 x 576), a left press selects the quadrant under it
// (not a machine that is not built), the positions of the machines in the full screen (only the shown one moves,
// buttons only there), the cursor hidden after 244 vertical syncs without a report. "tb_mouse: N errors".
module tb_mouse;
reg clk = 0; always #17.8 clk = ~clk;
reg [7:0] mx = 0, my = 0; reg [3:0] mz = 0; reg [2:0] mb = 0; reg upd = 0; reg full = 0; reg [1:0] sel = 0;
reg vs = 1; reg midq = 1;
wire [95:0] q; wire [9:0] cx, cy; wire con, swe, fset, qset; wire [1:0] sin;
quad_mouse #(.NUM_MACHINES(3)) u(.clk(clk), .ms_x(mx), .ms_y(my), .ms_z(mz), .ms_b(mb), .ms_upd(upd), .full(full),
	.sel(sel), .vsync(vs), .mid_quad(midq), .ms_q(q), .cur_x(cx), .cur_y(cy), .cur_on(con), .sel_we(swe),
	.sel_in(sin), .full_set(fset), .quad_set(qset));
always @(posedge clk) begin
	if (fset) full <= 1;
	if (qset) full <= 0;
end
task vsyncs(input integer k);
	integer j;
	for (j = 0; j < k; j = j + 1) begin vs = 0; repeat (3) @(negedge clk); vs = 1; repeat (3) @(negedge clk); end
endtask
integer errors = 0, n;
always @(posedge clk) if (swe) sel <= sin;
task rep(input [7:0] x, input [7:0] y, input [2:0] b);
	begin @(negedge clk); mx = x; my = y; mb = b; upd = ~upd; repeat (4) @(negedge clk); end
endtask
task chk(input integer c, input [255:0] what);
	begin if (!c) begin errors = errors + 1; $display("ERROR: %0s (cx %0d cy %0d sel %0d on %b)", what, cx, cy, sel, con); end end
endtask
initial begin
	repeat (4) @(negedge clk);
	chk(!con, "hidden at the start");
	rep(8'd10, 8'd20, 0); chk(cx == 378 && cy == 308 && con, "move");
	rep(8'd127, 8'd127, 0); rep(8'd127, 8'd127, 0); rep(8'd127, 8'd127, 0); chk(cx == 735 && cy == 575, "clamp max");
	rep(8'd1, 8'd1, 3'b001); chk(sel == 0, "no machine 3 (not built)");
	rep(8'd0, 8'd0, 0);
	rep(-8'd128, 8'd0, 0); rep(-8'd128, 8'd0, 0); rep(-8'd128, 8'd0, 0); chk(cx == 351, "left");
	rep(8'd0, 8'd0, 3'b001); chk(sel == 2, "select 2 (bottom left)");
	rep(8'd0, 8'd0, 3'b001); chk(sel == 2, "held: no new select");
	rep(8'd0, 8'd0, 0);
	for (n = 0; n < 5; n = n + 1) rep(-8'd128, -8'd128, 0); chk(cx == 0 && cy == 0, "clamp 0");
	rep(8'd0, 8'd0, 3'b001); chk(sel == 0, "select 0");
	rep(8'd0, 8'd0, 0);
	rep(8'd127, 8'd0, 0); rep(8'd127, 8'd0, 0); rep(8'd127, 8'd0, 0); rep(8'd0, 8'd0, 3'b010); chk(sel == 0, "right button: no select");
	rep(8'd0, 8'd0, 3'b001); chk(sel == 1, "select 1");
	rep(8'd0, 8'd0, 0);
	// full screen: machine 1 moves, 0 not
	full = 1;
	rep(8'd5, 8'd3, 3'b001);
	chk(q[1*24 +: 8] == 8'h84 && q[1*24 + 8 +: 8] == 8'h7C, "machine 1 x / y");
	chk(q[1*24 + 16 +: 3] == 3'b110, "machine 1 buttons");
	chk(q[0 +: 8] == 8'h7F && q[16 +: 3] == 3'b111, "machine 0 not moved, no buttons");
	chk(cx == 381, "cursor not moved in the full screen");
	full = 0;
	rep(8'd0, 8'd0, 0);   // released (it was held in the full screen)
	// double click: the second press within 20 vertical syncs in the same quadrant -> full screen
	rep(8'd0, 8'd0, 3'b001); rep(8'd0, 8'd0, 0); vsyncs(5); rep(8'd0, 8'd0, 3'b001); rep(8'd0, 8'd0, 0);
	chk(full && sel == 1, "double click: full screen of 1");
	// the middle button in the full screen: back to the quad view, the machine does not see it
	rep(8'd0, 8'd0, 3'b100);
	chk(!full, "middle: quad view");
	full = 1; rep(8'd0, 8'd0, 3'b100);
	chk(q[1*24 + 16 +: 3] == 3'b111, "middle not to the machine");
	rep(8'd0, 8'd0, 0); full = 0;
	// a slow double click (the second press 21 vsyncs later): no full screen
	rep(8'd0, 8'd0, 3'b001); rep(8'd0, 8'd0, 0); vsyncs(21); rep(8'd0, 8'd0, 3'b001); rep(8'd0, 8'd0, 0);
	chk(!full, "slow double click: quad view");
	vsyncs(21);   // the second press opened a new window
	// two presses in two quadrants: no full screen
	rep(8'd0, 8'd0, 3'b001); rep(8'd0, 8'd0, 0); rep(-8'd100, 8'd0, 0); rep(8'd0, 8'd0, 3'b001); rep(8'd0, 8'd0, 0);
	chk(!full && sel == 0, "presses in two quadrants: quad view");
	// Mouse middle = Machine: no quad view, the machine sees the button
	midq = 0; full = 1; rep(8'd0, 8'd0, 3'b100);
	chk(full && q[0*24 + 16 +: 3] == 3'b011, "middle to the machine");
	rep(8'd0, 8'd0, 0); full = 0; midq = 1;
	// hidden after 244 vertical syncs
	for (n = 0; n < 243; n = n + 1) begin vs = 0; repeat (3) @(negedge clk); vs = 1; repeat (3) @(negedge clk); end
	chk(con, "still shown after 243");
	vs = 0; repeat (3) @(negedge clk); vs = 1; repeat (3) @(negedge clk);
	chk(!con, "hidden after 244");
	rep(0, 0, 0); chk(con, "shown by a report");
	$display("tb_mouse: %0d errors", errors);
	$finish;
end
endmodule
