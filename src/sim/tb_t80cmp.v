`timescale 1ns / 1ps

/*
 tb_t80cmp.v: T80 (VHDL, version 351 of TS-Conf, the reference) against tv80_core, clock for clock, made from
 tb_tv80q.v (the same programs and stimulus). Both with the bus of pentagon.v: DInst the data, DI the data taken at
 the end of T2. Compared where it is the bus of the machine: A in T1 / T2 (T80 puts the refresh address out in T3 / T4
 of M1, tv80 without TV80_REFRESH does not), the machine cycle and T-state, Write / NoRead / IORQ in T1, the data of a
 write in T2, IntCycle_n, HALT_n. Prints the first difference with the opcode history of the CPU.

 Below, the text of tb_tv80q.v:

 The equivalence of tv80_quad (one tv80 logic for four CPUs, tools/mkquad.py) with four tv80_core, clock for clock.

 Four reference tv80_core and one tv80_quad on the same clock; CPU k gets its cen in slot 2k (of 8) in both. Each CPU
 has its own 64 KB memory of random bytes (the program: random code goes through every prefix, undocumented opcodes,
 block instructions, HALT, jumps, IM 0 / 1 / 2, EI / DI), and its own random WAIT, INT, NMI, skipped cens (a pause) and
 resets; the reference and the quad CPU k get the same (the same seed), each from its own outputs. Every clock every
 output of every CPU is compared (A, dout, mc, ts, m1_n, iorq, no_read, write, intcycle_n, halt_n); the first
 difference stops the test. Prints "tb_tv80q: <n> errors".

 `define CLOCKS: the length (default 2 000 000 clocks = 250 000 T-states per CPU).
*/

module tb_t80cmp;

`ifndef CLOCKS
`define CLOCKS 2000000
`endif

reg clk = 1'b0;
always #17.838 clk = ~clk;

reg [2:0] slot = 3'd0;
always @(posedge clk)
	slot <= slot + 1'd1;

// ---------------------------------------------------------------------------------------------
// stimulus per CPU (the same for the reference and the quad one)

reg [3:0] rst_n = 4'b0000;
reg [3:0] run = 4'b1111;        // its cen in its slot
reg [3:0] wait_n = 4'b1111;
reg [3:0] int_n = 4'b1111;
reg [3:0] nmi_n = 4'b1111;
wire [3:0] cen;
genvar g;
generate
	for (g = 0; g < 4; g = g + 1) begin : g_cen
		assign cen[g] = (slot == 2 * g) && run[g];
	end
endgenerate

integer seed = 1;
integer cycles = 0;
integer k;
integer rst_cnt [0:3];
integer int_cnt [0:3];
integer nmi_cnt [0:3];
initial for (k = 0; k < 4; k = k + 1) begin rst_cnt[k] = 20; int_cnt[k] = 0; nmi_cnt[k] = 0; end

// the stimulus changes at slot 7 (no slot of a CPU then: every CPU sees it at its next slot)
always @(posedge clk) begin
	cycles = cycles + 1;
	if (slot == 3'd7) begin
		for (k = 0; k < 4; k = k + 1) begin
			// reset: 20 T-states at the start, then now and then
			if (rst_cnt[k] > 0) begin
				rst_cnt[k] = rst_cnt[k] - 1;
				rst_n[k] <= 1'b0;
			end else begin
				rst_n[k] <= 1'b1;
				if (($random(seed) & 32'hFFFF) == 0)
					rst_cnt[k] = 3;
			end
			run[k] <= ($random(seed) & 15) != 0;          // 1 of 16 T-states without cen
			wait_n[k] <= ($random(seed) & 7) != 0;        // WAIT 1 of 8
			// INT: 32 T-states every ~256; NMI: 1..40 T-states every ~1000 (its edge is what counts: Oldnmi_n)
			if (int_cnt[k] > 0) begin
				int_cnt[k] = int_cnt[k] - 1;
				int_n[k] <= 1'b0;
			end else begin
				int_n[k] <= 1'b1;
				// CPU 0 rarely (its IFF2 stays set after EI), the others often: their states differ, a CPU reading
				// the state of another shows
				if (($random(seed) & (k == 0 ? 4095 : 255)) == 0)
					int_cnt[k] = 32;
			end
			if (nmi_cnt[k] > 0) begin
				nmi_cnt[k] = nmi_cnt[k] - 1;
				nmi_n[k] <= 1'b0;
			end else begin
				nmi_n[k] <= 1'b1;
				if (($random(seed) & 1023) == 0)
					nmi_cnt[k] = 1 + (($random(seed) & 32'h7FFFFFFF) % 40);
			end
		end
	end
end

// ---------------------------------------------------------------------------------------------
// memories: mem_r of the reference CPUs, mem_q of the quad one, the same random bytes at the start

reg [7:0] mem_r [0:4*65536-1];
reg [7:0] mem_q [0:4*65536-1];
integer i, rnd;
initial begin
	for (i = 0; i < 4 * 65536; i = i + 1) begin
		rnd = $random(seed);
		// one byte of 8 is ED: the ED instructions (LD A,I / LD A,R, RETN, IM, block ones) come often
		if (rnd[10:8] == 3'd0) rnd[7:0] = 8'hED;
		// no HALT (with interrupts off it sleeps until a reset): EI instead, so interrupts are taken often
		if (rnd[7:0] == 8'h76) rnd[7:0] = 8'hFB;
		mem_r[i] = rnd[7:0];
		mem_q[i] = rnd[7:0];
	end
end

// ---------------------------------------------------------------------------------------------
// the reference: four T80, four tv80_core; each with the data register of pentagon (taken at cen in T2)

// WAIT as in the machine: only in a cycle with the bus (read, write or I/O; not in the internal cycles, where T80 does
// not look at it, as a Z80, and tv80 does); from the state of T80, the same for both
wire [3:0] bus_wait_n;

wire [4*16-1:0] r_A, q_A;
wire [4*8-1:0] r_dout, q_dout, r_di, q_di;
wire [4*7-1:0] r_mc, q_mc, r_ts, q_ts;
wire [3:0] r_m1_n, r_iorq, r_no_read, r_write, r_intcycle_n, r_halt_n;
wire [3:0] q_m1_n, q_iorq, q_no_read, q_write, q_intcycle_n, q_halt_n;

generate
	for (g = 0; g < 4; g = g + 1) begin : g_ref
		assign r_di[g*8 +: 8] = r_iorq[g] ? (r_A[g*16 +: 8] ^ r_A[g*16 + 8 +: 8]) : mem_r[g * 65536 + r_A[g*16 +: 16]];
		assign q_di[g*8 +: 8] = q_iorq[g] ? (q_A[g*16 +: 8] ^ q_A[g*16 + 8 +: 8]) : mem_q[g * 65536 + q_A[g*16 +: 16]];
		reg [7:0] r_dreg = 8'd0, q_dreg = 8'd0;
		always @(posedge clk) begin
			if (cen[g] && r_ts[g*7 + 2] && bus_wait_n[g]) r_dreg <= r_di[g*8 +: 8];
			if (cen[g] && q_ts[g*7 + 2] && bus_wait_n[g]) q_dreg <= q_di[g*8 +: 8];
		end

		wire [2:0] t_mc, t_ts;
		// (and not in I/O cycles for now: T80 and tv80 combine an external WAIT with the automatic TW differently, a
		// known difference, see docs/PLAN.md; the machine has WAIT in I/O only on #EB of the DivMMC)
		// and not in M1: on WAIT in T2 of M1, T80 makes an extra T5 (CCF of 5 T-states); in the machine WAIT in M1 would
		// be a late read of the SDRAM, which does not happen (late)
		assign bus_wait_n[g] = wait_n[g] | (r_no_read[g] & ~r_write[g] & ~r_iorq[g]) | r_iorq[g] | ~r_m1_n[g] | r_mc[g*7];
		T80 #(.Mode(0), .IOWait(1)) ref (
			.RESET_n(rst_n[g]), .CLK_n(clk), .CEN(cen[g]), .WAIT_n(bus_wait_n[g]), .INT_n(int_n[g]), .NMI_n(nmi_n[g]),
			.BUSRQ_n(1'b1), .M1_n(r_m1_n[g]), .IORQ(r_iorq[g]), .NoRead(r_no_read[g]), .Write(r_write[g]), .RFSH_n(),
			.HALT_n(r_halt_n[g]), .BUSAK_n(), .A(r_A[g*16 +: 16]), .DInst(r_di[g*8 +: 8]), .DI(r_dreg), .DO(r_dout[g*8 +: 8]),
			.MC(t_mc), .TS(t_ts), .IntCycle_n(r_intcycle_n[g]), .IntE(), .Stop(), .R800_mode(1'b0), .out0(1'b0), .REG(),
			.DIRSet(1'b0), .DIR(212'd0)
		);
		// T80 numbers as the one-hot of tv80 (MC 1 = bit 0, TS n = bit n)
		assign r_mc[g*7 +: 7] = 7'b0000001 << (t_mc - 3'd1);
		assign r_ts[g*7 +: 7] = 7'b0000001 << t_ts;

		tv80_core #(.Mode(0), .IOWait(1)) dut (
			.reset_n(rst_n[g]), .clk(clk), .cen(cen[g]), .wait_n(bus_wait_n[g]), .int_n(int_n[g]), .nmi_n(nmi_n[g]),
			.busrq_n(1'b1), .dinst(q_di[g*8 +: 8]), .di(q_dreg),
			.m1_n(q_m1_n[g]), .iorq(q_iorq[g]), .no_read(q_no_read[g]), .write(q_write[g]), .rfsh_n(),
			.halt_n(q_halt_n[g]), .busak_n(), .A(q_A[g*16 +: 16]), .dout(q_dout[g*8 +: 8]), .mc(q_mc[g*7 +: 7]),
			.ts(q_ts[g*7 +: 7]), .intcycle_n(q_intcycle_n[g]), .IntE(), .stop()
		);

		always @(posedge clk) begin
			if (cen[g] && r_write[g] && !r_iorq[g] && r_ts[g*7 + 2])
				mem_r[g * 65536 + r_A[g*16 +: 16]] <= r_dout[g*8 +: 8];
			if (cen[g] && q_write[g] && !q_iorq[g] && q_ts[g*7 + 2])
				mem_q[g * 65536 + q_A[g*16 +: 16]] <= q_dout[g*8 +: 8];
		end
	end
endgenerate

// the last 16 cens of each CPU: T80 mc / ts, tv80 mc / ts, WAIT, A (T80)
reg [47:0] tr [0:63];
integer tn, tq;
always @(posedge clk)
	for (tn = 0; tn < 4; tn = tn + 1)
		if (cen[tn]) begin
			for (tq = 15; tq > 0; tq = tq - 1) tr[tn*16 + tq] = tr[tn*16 + tq - 1];
			tr[tn*16] = {r_mc[tn*7 +: 7], r_ts[tn*7 +: 7], q_mc[tn*7 +: 7], q_ts[tn*7 +: 7], 3'd0, bus_wait_n[tn],
				r_A[tn*16 +: 16]};
		end

// the opcode history of each CPU (the last 8 opcode fetches of T80): printed with a difference
reg [23:0] hist [0:31];
integer hn, hq;
always @(posedge clk)
	for (hn = 0; hn < 4; hn = hn + 1)
		if (cen[hn] && !r_m1_n[hn] && r_ts[hn*7 + 2] && bus_wait_n[hn]) begin
			for (hq = 7; hq > 0; hq = hq - 1) hist[hn*8 + hq] = hist[hn*8 + hq - 1];
			hist[hn*8] = {r_A[hn*16 +: 16], r_di[hn*8 +: 8]};
		end

// ---------------------------------------------------------------------------------------------
// compare: every clock, every CPU (not in its reset and the T-state after: the reference resets at once, the quad
// CPU in its slot)

integer errors = 0;
integer settle [0:3];
integer m1s [0:3];
integer ints [0:3];
initial for (k = 0; k < 4; k = k + 1) begin settle[k] = 0; m1s[k] = 0; ints[k] = 0; end
reg [3:0] diff;

always @(negedge clk) begin
	for (k = 0; k < 4; k = k + 1) begin
		if (!rst_n[k])
			settle[k] = 16;
		else if (settle[k] > 0)
			settle[k] = settle[k] - 1;
		else begin
			if (cen[k] && !r_m1_n[k]) m1s[k] = m1s[k] + 1;
			if (cen[k] && !r_intcycle_n[k] && r_ts[k*7 + 1]) ints[k] = ints[k] + 1;
			// What the programs see: the T-state where each opcode fetch starts (M1 T1) and its address, the T-state,
			// address and data of each write (memory and port: OUT to #FE is the border) and the interrupt acknowledges.
			// Not compared: where inside an instruction a read happens (RLD reads (HL) in M2 on T80, in M3 on tv80, the
			// same 18 T-states; no contention on the Pentagon) and the address of the internal cycles.
			if ((r_m1_n[k] == 1'b0 && r_ts[k*7 + 1]) !== (q_m1_n[k] == 1'b0 && q_ts[k*7 + 1]) ||
				(!r_m1_n[k] && r_ts[k*7 + 1] && r_A[k*16 +: 16] !== q_A[k*16 +: 16]) ||
				// `MEMWR: also the T-state of the memory writes (EX (SP),HL writes in another order on tv80: no WZ)
`ifdef MEMWR
				(r_write[k] && r_ts[k*7 + 2]) !== (q_write[k] && q_ts[k*7 + 2]) ||
				(r_write[k] && r_ts[k*7 + 2] && (r_A[k*16 +: 16] !== q_A[k*16 +: 16] ||
					r_dout[k*8 +: 8] !== q_dout[k*8 +: 8] || r_iorq[k] !== q_iorq[k])) ||
`else
				(r_write[k] && r_iorq[k] && r_ts[k*7 + 2]) !== (q_write[k] && q_iorq[k] && q_ts[k*7 + 2]) ||
				(r_write[k] && r_iorq[k] && r_ts[k*7 + 2] && (r_A[k*16 +: 16] !== q_A[k*16 +: 16] ||
					r_dout[k*8 +: 8] !== q_dout[k*8 +: 8])) ||
`endif
				(!r_intcycle_n[k] && r_ts[k*7 + 1]) !== (!q_intcycle_n[k] && q_ts[k*7 + 1])) begin
				errors = errors + 1;
				$display("%t clock %0d CPU %0d differs: T80 A %h do %h mc %b ts %b m1 %b io %b nr %b wr %b ic %b h %b",
					$time, cycles, k, r_A[k*16 +: 16], r_dout[k*8 +: 8], r_mc[k*7 +: 7], r_ts[k*7 +: 7], r_m1_n[k],
					r_iorq[k], r_no_read[k], r_write[k], r_intcycle_n[k], r_halt_n[k]);
				$display("%t                          tv80 A %h do %h mc %b ts %b m1 %b io %b nr %b wr %b ic %b h %b",
					$time, q_A[k*16 +: 16], q_dout[k*8 +: 8], q_mc[k*7 +: 7], q_ts[k*7 +: 7], q_m1_n[k],
					q_iorq[k], q_no_read[k], q_write[k], q_intcycle_n[k], q_halt_n[k]);
				for (hq = 15; hq >= 0; hq = hq - 1)
					$display("  cen -%0d: T80 mc %b ts %b | tv80 mc %b ts %b | wait_n %b | A %h", hq,
						tr[k*16 + hq][47:41], tr[k*16 + hq][40:34], tr[k*16 + hq][33:27], tr[k*16 + hq][26:20],
						tr[k*16 + hq][16], tr[k*16 + hq][15:0]);
				$write("  opcodes of T80 before (newest first):");
				for (hq = 0; hq < 8; hq = hq + 1) $write(" %h:%h", hist[k*8 + hq][23:8], hist[k*8 + hq][7:0]);
				$write("%c", 8'd10);
				$display("tb_t80cmp: %0d errors", errors);
				$finish;
			end
		end
	end
	if (cycles == `CLOCKS) begin
		$display("tb_t80cmp: %0d clocks, M1 cycles per CPU %0d %0d %0d %0d, interrupts %0d %0d %0d %0d",
			cycles, m1s[0], m1s[1], m1s[2], m1s[3], ints[0], ints[1], ints[2], ints[3]);
		$display("tb_t80cmp: %0d errors", errors);
		$finish;
	end
end

endmodule
