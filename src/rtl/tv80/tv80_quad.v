`timescale 1ns / 1ps
`default_nettype none

/*
 tv80_quad.v

 One tv80 logic for four CPUs (tv80q_core, made by tools/mkquad.py out of tv80_core). A slot of 8 clocks (one T-state
 of the 3.5 MHz CPUs at 28 MHz):

   slot 2k     CPU k: its cen (its machine gives it in this clock only), the state of CPU k is read and written
   slot 2k+1   CPU k again without cen ("peek"): the logic shows the new state of CPU k, its outputs go to machine k
               straight (live) in this clock and are kept for it until its next peek

 So machine k sees its CPU as a tv80_core whose cen is in slot 2k: the outputs change after the clock of cen (here
 in the clock after it, live; a tv80_core shows them from the same clock on), every input is taken in slot 2k, the
 asynchronous reset is synchronous (reset_n of CPU k in its slots). src/sim/tb_tv80q.v compares it with four
 tv80_core clock for clock.
*/

module tv80_quad #(
	parameter Mode = 0,
	parameter IOWait = 1
) (
	input wire clk,
	input wire [2:0] slot,          // the slot of this clock: 2k = cen of CPU k, 2k+1 = its peek

	// CPU k: bits k (k*8, k*16...)
	input wire [3:0] reset_n,
	input wire [3:0] cen,           // high in slot 2k only
	input wire [3:0] wait_n,
	input wire [3:0] int_n,
	input wire [3:0] nmi_n,
	input wire [4*8-1:0] dinst,
	input wire [4*8-1:0] di,

	output wire [4*16-1:0] A,
	output wire [4*8-1:0] dout,
	output wire [4*7-1:0] mc,
	output wire [4*7-1:0] ts,
	output wire [3:0] m1_n,
	output wire [3:0] iorq,
	output wire [3:0] no_read,
	output wire [3:0] write,
	output wire [3:0] intcycle_n,
	output wire [3:0] halt_n
);

wire [1:0] th = slot[2:1];
wire peek = slot[0];

// the CPU of this clock
wire c_reset_n = reset_n[th];
wire c_cen = cen[th] & ~peek;
wire c_wait_n = wait_n[th];
wire c_int_n = int_n[th];
wire c_nmi_n = nmi_n[th];
wire [7:0] c_dinst = dinst[th*8 +: 8];
wire [7:0] c_di = di[th*8 +: 8];

wire [15:0] l_A;
wire [7:0] l_dout;
wire [6:0] l_mc, l_ts;
wire l_m1_n, l_iorq, l_no_read, l_write, l_intcycle_n, l_halt_n;

tv80q_core #(.Mode(Mode), .IOWait(IOWait)) core (
	.th(th),
	.reset_n(c_reset_n),
	.clk(clk),
	.cen(c_cen),
	.wait_n(c_wait_n),
	.int_n(c_int_n),
	.nmi_n(c_nmi_n),
	.busrq_n(1'b1),
	.dinst(c_dinst),
	.di(c_di),
	.m1_n(l_m1_n),
	.iorq(l_iorq),
	.no_read(l_no_read),
	.write(l_write),
	.rfsh_n(),
	.halt_n(l_halt_n),
	.busak_n(),
	.A(l_A),
	.dout(l_dout),
	.mc(l_mc),
	.ts(l_ts),
	.intcycle_n(l_intcycle_n),
	.IntE(),
	.stop()
);

// the outputs of CPU k: live in its peek, kept from it after
localparam OW = 16 + 8 + 7 + 7 + 6;
wire [OW-1:0] live = {l_A, l_dout, l_mc, l_ts, l_m1_n, l_iorq, l_no_read, l_write, l_intcycle_n, l_halt_n};

genvar k;
generate
	for (k = 0; k < 4; k = k + 1) begin : g_cpu
		reg [OW-1:0] kept = {OW{1'b0}};
		always @(posedge clk)
			if (peek && th == k)
				kept <= live;
		wire [OW-1:0] o = (peek && th == k) ? live : kept;
		assign {A[k*16 +: 16], dout[k*8 +: 8], mc[k*7 +: 7], ts[k*7 +: 7], m1_n[k], iorq[k], no_read[k], write[k],
			intcycle_n[k], halt_n[k]} = o;
	end
endgenerate

endmodule
