`timescale 1ns / 1ps
module tb_ay;
reg clk = 0; always #17.8 clk = ~clk;
reg we = 0; reg [3:0] wa = 0; reg [7:0] wd = 0;
wire [7:0] a, b, c;
ay_psg u(.clk(clk), .we(we), .wa(wa), .wd(wd), .ch_a(a), .ch_b(b), .ch_c(c));
task w(input [3:0] r, input [7:0] v); begin @(posedge clk) begin we <= 1; wa <= r; wd <= v; end @(posedge clk) we <= 0; end endtask
integer edges = 0; reg pa = 0; integer i; integer lv[0:15];
initial begin
	w(0, 8'd10); w(1, 0); w(7, 8'b111110); w(8, 15);
	// tone A period 10: toggles every 10*128 clocks -> 20 toggles in 25600 clocks
	repeat (25600) begin @(posedge clk); if ((a != 0) != pa) begin edges = edges + 1; pa = (a != 0); end end
	$display("tone edges %0d (expect ~20), level %h", edges, a);
	// envelope shape 1010 (\/\/), period 1: step every 256 clocks, use A with env
	w(7, 8'b111111); w(8, 8'h10); w(11, 1); w(12, 0); w(13, 4'b1010);
	for (i = 0; i < 40; i = i + 1) begin repeat (256) @(posedge clk); $write("%0d ", u.env); end
	$display("");
	w(13, 4'b1101);
	for (i = 0; i < 24; i = i + 1) begin repeat (256) @(posedge clk); $write("%0d ", u.env); end
	$display("");
	w(13, 4'b0000);
	for (i = 0; i < 24; i = i + 1) begin repeat (256) @(posedge clk); $write("%0d ", u.env); end
	$display(""); $finish;
end
endmodule
