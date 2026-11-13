`timescale 1ns / 1ps
`default_nettype none

/*
 quad_mouse.v

 The USB mouse of the MCU (MS_X / MS_Y / MS_Z deltas and MS_B, MS_UPD toggles with each report; HID: x right, y down,
 button bit 0 left):
 - full screen: the Kempston mouse of the selected machine. Each machine has its own position (x, y, wheel), moved
   only while it is the one shown, so a machine sees no jump when it is selected again. The ports of machine k:
   ms_q[k*24 +: 24] = {buttons byte, y, x}: x grows to the right, y up (the delta negated), the buttons byte
   {wheel, 1, ~b} as kg_cursor / tsconf (buttons released for the machines not shown).
 - quad view: a cursor of the core on the picture (cur_x 0..735, cur_y 0..575, the top left pixel of the arrow is the
   hot spot); a press of the left button selects the machine of the quadrant under it (sel_we, sel_in). The cursor
   hides after 5 seconds without a report (cur_on: 244 vertical syncs of the VGA), any report shows it again.
   A second press of the left button in the same quadrant within 20 vertical syncs (0.4 s) of the first: the machine
   full screen (full_set).
 - mid_quad (1 in the top; the OSD item Mouse middle was removed): a press of the middle button in the full screen goes back to the quad view
   (quad_set) and the machines do not see the middle button; else it is a button of the Kempston mouse.
*/

module quad_mouse #(
	parameter NUM_MACHINES = 4
) (
	input wire clk,
	input wire [7:0] ms_x,
	input wire [7:0] ms_y,
	input wire [3:0] ms_z,
	input wire [2:0] ms_b,
	input wire ms_upd,
	input wire full,
	input wire [1:0] sel,
	input wire vsync,             // the vertical sync of the VGA (low active, 48.8 Hz): counts the idle time
	input wire mid_quad,          // the middle button: back to the quad view (not to the machines)

	output wire [4*24-1:0] ms_q,
	output reg [9:0] cur_x = 10'd368,
	output reg [9:0] cur_y = 10'd288,
	output wire cur_on,
	output reg sel_we = 1'b0,
	output reg [1:0] sel_in = 2'd0,
	output reg full_set = 1'b0,   // a clock: the selected machine full screen (double click)
	output reg quad_set = 1'b0    // a clock: the quad view (middle button)
);

// the positions of the machines
reg [7:0] mx [0:3];
reg [7:0] my [0:3];
reg [3:0] mz [0:3];
integer i;
initial for (i = 0; i < 4; i = i + 1) begin mx[i] = 8'h7F; my[i] = 8'h7F; mz[i] = 4'd7; end

reg upd_d = 1'b0;
wire upd = (ms_upd != upd_d);
reg b0_d = 1'b0, b2_d = 1'b0;
// double click: vertical syncs since the last press of the left button (20: none pending), its quadrant
reg [4:0] dc_t = 5'd20;
reg [1:0] dc_q = 2'd0;
wire [1:0] cur_q = {cur_y >= 10'd288, cur_x >= 10'd368};

// the cursor of the quad view: a new position clamped to the picture
wire [10:0] nx = {1'b0, cur_x} + {{3{ms_x[7]}}, ms_x};
wire [10:0] ny = {1'b0, cur_y} + {{3{ms_y[7]}}, ms_y};

// 5 s without a report: 244 vertical syncs (their start)
reg [7:0] idle = 8'd244;
assign cur_on = (idle != 8'd244);
reg vs_d = 1'b1;

always @(posedge clk) begin
	upd_d <= ms_upd;
	vs_d <= vsync;
	sel_we <= 1'b0;
	full_set <= 1'b0;
	quad_set <= 1'b0;
	if (vs_d && !vsync && idle != 8'd244)
		idle <= idle + 1'd1;
	if (vs_d && !vsync && dc_t != 5'd20)
		dc_t <= dc_t + 1'd1;
	if (upd) begin
		idle <= 8'd0;
		b0_d <= ms_b[0];
		b2_d <= ms_b[2];
		if (full) begin
			mx[sel] <= mx[sel] + ms_x;
			my[sel] <= my[sel] - ms_y;
			mz[sel] <= mz[sel] - ms_z;
			dc_t <= 5'd20;
			if (mid_quad && ms_b[2] && !b2_d)
				quad_set <= 1'b1;
		end else begin
			cur_x <= nx[10] ? 10'd0 : (nx > 11'd735) ? 10'd735 : nx[9:0];
			cur_y <= ny[10] ? 10'd0 : (ny > 11'd575) ? 10'd575 : ny[9:0];
			// the left button pressed: the machine under the cursor (where it was before this report's move)
			if (ms_b[0] && !b0_d && cur_q < NUM_MACHINES) begin
				sel_we <= 1'b1;
				sel_in <= cur_q;
				// the second press of a double click: full screen; else the first
				if (dc_t != 5'd20 && dc_q == cur_q) begin
					full_set <= 1'b1;
					dc_t <= 5'd20;
				end else begin
					dc_t <= 5'd0;
					dc_q <= cur_q;
				end
			end
		end
	end
end

genvar k;
generate
	for (k = 0; k < 4; k = k + 1) begin : g_q
		wire shown = full && sel == k;
		assign ms_q[k*24 +: 24] = {mz[k], 1'b1, shown ? ~(ms_b & {~mid_quad, 2'b11}) : 3'b111, my[k], mx[k]};
	end
endgenerate

endmodule
