`timescale 1ns / 1ps
`default_nettype none

/*
 video_px.v

 The last stage of the video on clk_sys (84 MHz) with the pixel clock of the video DAC (V_CLK):
 - full screen: the picture of video_out (clk_bus, 28 MHz) taken with ce28 (bus_ce: the clk_sys period that ends with
   an edge of clk_bus), pixels of 28 MHz as before;
 - quad view: pixels of 21.02 MHz = clk_sys / 4 (ce21) from the row buffer that video_out fills on clk_bus one row
   ahead (two rows of 576 pixels, a 5-bit code). A VGA line is 896 clocks of clk_bus = 2688 of clk_sys = 672
   pixels of 21 MHz exactly, so with the counter c started at each row (qs_start of video_out) the pixels keep
   their place: no jitter. The syncs of video_out are taken with the same ce, so for the monitor the mode is the
   same in both views (Win+` switches without a new lock).
 ce_px is the enable of the pixels (also for kg_osd_overlay, CE_IN), v_clk the clock of the DAC: ce_px taken on the
 falling clk_sys, high from half a clock before to half a clock after the edge where the pixel changes (as bus_ce).
*/

module video_px (
	input wire clk_sys,
	input wire ce28,
	input wire ce28_n,            // the value of ce28 at the next clock (bus_ce)
	input wire full,

	// the full screen of video_out (clk_bus registers)
	input wire [7:0] r_i,
	input wire [7:0] g_i,
	input wire [7:0] b_i,
	input wire hs_i,
	input wire vs_i,

	// the row buffer, written by video_out on clk_bus; the rows shown
	input wire clk_bus,
	input wire pb_we,
	input wire [10:0] pb_addr,
	input wire [4:0] pb_d,
	input wire qs_start,
	input wire qs_par,
	input wire qs_vis,
	input wire [2:0] rim_col,     // colour of the frame of the selected machine {G, R, B}, bright

	output reg ce_px = 1'b0,
	(* IOB = "TRUE" *) output reg v_clk = 1'b0,
	output reg [7:0] r = 8'd0,
	output reg [7:0] g = 8'd0,
	output reg [7:0] b = 8'd0,
	output reg hs = 1'b1,
	output reg vs = 1'b1
);

// the 21 MHz pixels of a row: c counts clk_sys from the start of the row, ce21 in the clock with c[1:0] = 3
reg st_d = 1'b0;
reg [11:0] c = 12'd0;
reg par = 1'b0, vis = 1'b0;
reg ce21 = 1'b0;
always @(posedge clk_sys) begin
	st_d <= qs_start;
	if (qs_start && !st_d) begin
		c <= 12'd0;
		par <= qs_par;
		vis <= qs_vis;
	end else
		c <= c + 1'd1;
	ce21 <= (c[1:0] == 2'd2);
end

wire [9:0] px = c[11:2];
wire [4:0] pb_q;
kg_sdpram #(.DW(5), .AW(11)) rowbuf(
	.clka(clk_bus),
	.wea(pb_we),
	.addra(pb_addr),
	.dina(pb_d),
	.clkb(clk_sys),
	.enb(ce21),
	.addrb({par, px}),
	.doutb(pb_q)
);

reg q_on = 1'b0;   // pb_q is a pixel of the picture
always @(posedge clk_sys)
	if (ce21)
		q_on <= vis && (px < 10'd576);

// ce_px = full ? ce28 : ce21, a register; v_clk from a copy of it (near the pin), in the IOB: the half clock from it to
// the falling edge was the worst path of clk_sys (0.05 ns) with the multiplexer in front of v_clk
(* equivalent_register_removal = "no" *) reg vck_d = 1'b0;
always @(posedge clk_sys) begin
	ce_px <= full ? ce28_n : (c[1:0] == 2'd2);
	vck_d <= full ? ce28_n : (c[1:0] == 2'd2);
end

always @(negedge clk_sys)
	v_clk <= vck_d;

always @(posedge clk_sys)
	if (ce_px) begin
		hs <= hs_i;
		vs <= vs_i;
		if (full) begin
			r <= r_i;
			g <= g_i;
			b <= b_i;
		end else if (!q_on) begin
			r <= 8'd0;
			g <= 8'd0;
			b <= 8'd0;
		end else if (pb_q[4]) begin
			// 10000 the frame of the selected machine, 10001 a machine that is not built (grey)
			r <= pb_q[0] ? 8'h30 : (rim_col[1] ? 8'hFF : 8'h00);
			g <= pb_q[0] ? 8'h30 : (rim_col[2] ? 8'hFF : 8'h00);
			b <= pb_q[0] ? 8'h30 : (rim_col[0] ? 8'hFF : 8'h00);
		end else begin
			r <= pb_q[1] ? (pb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
			g <= pb_q[2] ? (pb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
			b <= pb_q[0] ? (pb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
		end
	end

endmodule
