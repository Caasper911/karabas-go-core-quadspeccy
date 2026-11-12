`timescale 1ns / 1ps
`default_nettype none

/*
 zx_timing.v

 The raster and clock enables of the Pentagon 128, one for all the machines (they run in lock
 step). clk = clk_bus, 28 MHz.

 - ce7:   the pixel clock, 7 MHz (every 4th clock); hc / vc advance with it.
 - ce_cpu: the CPU clock, 3.5 MHz (every second ce7, at the end of an odd pixel): one T-state is
           two pixels, hc[8:1] is the T-state in the line.
 - hc 0..447 pixels (224 T): 0..255 paper, 256..319 right border, 320..383 blank (sync),
   384..447 left border.
 - vc 0..319 lines: 0..191 paper, 192..239 bottom border, 240..255 blank (sync), 256..319 top
   border.
 - int_n: low 32 T from line 239, pixel 312 (T 156): 68 T before the end of the line, so the
   first paper pixel comes 80 * 224 + 68 = 17988 T after the start of INT (Pentagon).
 - vga_x / vga_half: the doubled raster of the scan doubler, 14 MHz pixels (2 clocks): the native
   line is shown twice, first half vga_half 0, then 1; vga_x 0..447 as hc.
*/

module zx_timing (
	input wire clk,
	input wire reset,

	output reg ce7 = 1'b0,
	output reg ce_cpu = 1'b0,
	output reg ce14 = 1'b0,
	output reg [8:0] hc = 9'd0,
	output reg [8:0] vc = 9'd0,
	output reg int_n = 1'b1,
	output reg [4:0] frame = 5'd0,
	output reg [8:0] vga_x = 9'd0,
	output reg vga_half = 1'b0
);

reg [1:0] sub = 2'd0;

always @(posedge clk) begin
	if (reset) begin
		sub <= 2'd0;
		hc <= 9'd0;
		vc <= 9'd0;
		ce7 <= 1'b0;
		ce_cpu <= 1'b0;
		ce14 <= 1'b0;
		int_n <= 1'b1;
		vga_x <= 9'd0;
		vga_half <= 1'b0;
	end else begin
		sub <= sub + 1'd1;
		// the enables are high in the clock that ends the period
		ce7 <= (sub == 2'd2);
		ce_cpu <= (sub == 2'd2) && hc[0];
		ce14 <= sub[0] == 1'b0;

		if (ce7) begin
			if (hc == 9'd447) begin
				hc <= 9'd0;
				if (vc == 9'd319) begin
					vc <= 9'd0;
				end else begin
					vc <= vc + 1'd1;
					if (vc == 9'd239)
						frame <= frame + 1'd1;
				end
			end else
				hc <= hc + 1'd1;

			if (vc == 9'd239 && hc == 9'd311)
				int_n <= 1'b0;
			else if (vc == 9'd239 && hc == 9'd375)
				int_n <= 1'b1;
		end

		// 14 MHz: two VGA pixels per native pixel, the line twice
		if (ce14) begin
			if (vga_x == 9'd447) begin
				vga_x <= 9'd0;
				vga_half <= ~vga_half;
			end else
				vga_x <= vga_x + 1'd1;
		end
	end
end

endmodule
