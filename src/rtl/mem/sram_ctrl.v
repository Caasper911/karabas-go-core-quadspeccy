`timescale 1ns / 1ps
`default_nettype none

/*
 sram_ctrl.v

 The asynchronous SRAM of the boards (2M x 16, 10 ns, /RD and /WR per byte: MRD_N, MWR_N; the chip select is tied),
 for the frame buffer of the quad view (quad_fb.v): one access of a whole word every clock of clk_bus (28 MHz,
 35.7 ns), clk_sys (84 MHz) = clk_bus * 3 for the write strobe. From the sram_ctrl of SpeccyWall (two ports there),
 the timing of the SRAM of TS-Conf (rtl/tsconf/dram/sram.v there: three clk_sys).

 A request in clock n (req, one clock):
   n + 1   MA and MRD_N from their registers on clk_bus (IOB): the whole clock for the access. A read has both /RD low;
           its word is taken with the clk_bus edge at the end of n + 1 (IOB): 35.7 ns = 12 ns out + 10 ns tAA + 12 ns in
           + board. That register is on clk_sys (the third edge of the clock, the same edge): the IOB of MD packs its
           input register with the output ones only on one clock (on clk_bus the data out stayed in the fabric).
           A write: both /WR low from the first to the second clk_sys edge after the start of n + 1 (11.9 ns), the
           data driven from the first to the third (registers on clk_sys, IOB): address set up and held one clk_sys
           around /WR, the data one clk_sys before its end and after it; in a write /RD stays high, so the SRAM stops
           driving at the start of n + 1 and the data goes out one clk_sys later (no fight after a read).
   n + 2   q: the word of a read of n

 The phase of clk_sys in a clock of clk_bus: bt toggles with clk_bus, bts samples it with clk_sys; bt != bts in the
 first clk_sys of the clock (both clocks from one PLL, every edge of clk_bus is an edge of clk_sys).
*/

module sram_ctrl (
	input wire clk_bus,
	input wire clk_sys,

	input wire req,
	input wire we,
	input wire [20:0] addr,         // word
	input wire [15:0] din,
	output wire [15:0] q,

	// pins
	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MRD_N,
	output wire [1:0] MWR_N
);

// every pin through a register in its IOB (OFF / TFF / IFF), as SDR_* of sdram_ctrl: the same delay for every bit;
// equivalent_register_removal off: the two bits of /RD, /WR (and the 16 of the output enable) are equal, XST merged
// them into one register, which cannot go into two IOBs (found in the map report)
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [20:0] ma_r = 21'd0;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [1:0] rd_n = 2'b11;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [1:0] wr_n = 2'b11;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] md_o = 16'd0;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] md_t = 16'hFFFF;   // 1: Z
(* IOB = "TRUE" *) reg [15:0] md_i = 16'd0;
assign MA = ma_r;
assign MRD_N = rd_n;
assign MWR_N = wr_n;

// ---------------------------------------------------------------------------------------------
// clk_bus: the address, /RD, the data of a write (fabric)

reg w_go = 1'b0;                // this clock writes
reg [15:0] w_data = 16'd0;
reg bt = 1'b0;

always @(posedge clk_bus) begin
	bt <= ~bt;
	w_go <= req & we;
	if (req) begin
		ma_r <= addr;
		rd_n <= we ? 2'b11 : 2'b00;
		w_data <= din;
	end else
		rd_n <= 2'b11;
end
assign q = md_i;

// ---------------------------------------------------------------------------------------------
// clk_sys: /WR, the data out of a write, the read word

reg bts = 1'b0;
reg f2 = 1'b0, f3 = 1'b0;      // the second / third clk_sys edge of the clock of clk_bus comes
wire f1 = bt ^ bts;             // the first comes

always @(posedge clk_sys) begin
	bts <= bt;
	f2 <= f1;
	f3 <= f2;
	if (f1 && w_go) begin
		wr_n <= 2'b00;
		md_o <= w_data;
		md_t <= 16'h0000;
	end
	if (f2)
		wr_n <= 2'b11;
	if (f3) begin
		md_t <= 16'hFFFF;
		md_i <= MD;     // at the edge of clk_bus
	end
end

genvar k;
generate
	for (k = 0; k < 16; k = k + 1) begin : g_md
		assign MD[k] = md_t[k] ? 1'bz : md_o[k];
	end
endgenerate

endmodule
