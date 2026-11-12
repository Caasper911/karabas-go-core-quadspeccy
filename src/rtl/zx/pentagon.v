`timescale 1ns / 1ps
`default_nettype none

/*
 pentagon.v

 One Pentagon 128 machine: T80 at 3.5 MHz, 128 KB RAM and 32 KB ROM in its SDRAM bank (two
 channels of sdram_ctrl), ports #FE and #7FFD, the Pentagon INT, the video of the paper and the
 border. No contention (Pentagon). clk = clk_bus, 28 MHz; the raster and the enables come from
 zx_timing, shared by all the machines (docs/ARCHITECTURE.md).

 Memory (byte address in the bank of the machine):
   0x00000..0x1FFFF  RAM pages 0..7
   0x20000..0x2FFFF  ROM area, 16 KB per ROM: 0 = 128 editor, 1 = 48 BASIC (#7FFD bit 4),
                     2, 3 reserved (TR-DOS, service); filled by the ROM loader of the top

 CPU memory cycles. The T80 takes the data of a read at the CPU clock that ends T2 (the opcode of
 M1 too), one T-state after its RD_n would go low (T80se). The request to the SDRAM is made at the
 start of T1 from the state of the T80 (MC / TS / Write / NoRead / IORQ), so the access has two
 T-states (48 clk_sys); the worst case of the schedule is 41 clk_sys (docs/ARCHITECTURE.md). If
 the data is still not there at the end of T2, WAIT_n inserts wait states (it must not happen;
 sim checks it). A write is posted at the start of T2 (DO is valid from the end of T1).
 I/O cycles have the automatic wait state of the Z80 (IOWait = 1).

 Video. The fetcher reads the bitmap and the attribute of a character from the screen page
 (#7FFD bit 3: page 7, else 5) through channel B at most 12 pixels before the character is shown,
 into a buffer of two characters; pix is the colour of hc / vc two ce7 later.
*/

module pentagon (
	input wire clk,
	input wire reset,
	input wire pause,

	// raster (zx_timing)
	input wire ce7,
	input wire ce_cpu,
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire int_n,
	input wire [4:0] frame,

	// input / output
	input wire [39:0] keys,       // pressed keys: bit row * 5 + column, row n = A(8+n) low
	input wire [7:0] kempston,
	input wire tape_in,
	output reg beeper = 1'b0,
	output reg mic = 1'b0,

	// SDRAM channel A (CPU)
	output reg a_req = 1'b0,
	output reg a_we = 1'b0,
	output reg [22:0] a_addr = 23'd0,
	output reg [7:0] a_din = 8'd0,
	input wire a_ack,
	input wire [7:0] a_q,

	// SDRAM channel B (video)
	output reg b_req = 1'b0,
	output reg [22:0] b_addr = 23'd0,
	input wire b_ack,
	input wire [7:0] b_q,

	// video: colour {bright, G, R, B} of the pixel hc / vc of two ce7 before
	output reg [3:0] pix = 4'd0,

	// debug, sticky until reset: a read was late (wait states were inserted); a read returned non-zero data
	output reg late = 1'b0,
	output reg nz = 1'b0
);

// ---------------------------------------------------------------------------------------------
// CPU

wire [15:0] cpu_a;
wire [7:0] cpu_do;
wire [2:0] cpu_mc;
wire [2:0] cpu_ts;
wire cpu_iorq, cpu_noread, cpu_write, cpu_intcycle_n;
wire cpu_cen = ce_cpu & ~pause;
wire cpu_wait_n;
wire [7:0] cpu_di;
reg [7:0] cpu_di_reg = 8'd0;

T80 #(.Mode(0), .IOWait(1)) cpu (
	.RESET_n(~reset),
	.CLK_n(clk),
	.CEN(cpu_cen),
	.WAIT_n(cpu_wait_n),
	.INT_n(int_n),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(),
	.IORQ(cpu_iorq),
	.NoRead(cpu_noread),
	.Write(cpu_write),
	.RFSH_n(),
	.HALT_n(),
	.BUSAK_n(),
	.A(cpu_a),
	.DInst(cpu_di),
	.DI(cpu_di_reg),
	.DO(cpu_do),
	.MC(cpu_mc),
	.TS(cpu_ts),
	.IntCycle_n(cpu_intcycle_n),
	.IntE(),
	.Stop(),
	.R800_mode(1'b0),
	.out0(1'b0),
	.REG(),
	.DIRSet(1'b0),
	.DIR(212'd0)
);

// the T-state changes at a CPU clock; its decode is made in the clock after it
reg cen_d = 1'b0;
always @(posedge clk)
	cen_d <= cpu_cen;

wire m1_cycle = (cpu_mc == 3'd1);
wire mem_rd = m1_cycle ? cpu_intcycle_n : (~cpu_noread & ~cpu_write & ~cpu_iorq);
wire mem_wr = ~m1_cycle & cpu_write & ~cpu_iorq;
wire io_rd = ~m1_cycle & cpu_iorq & ~cpu_write;
wire io_wr = ~m1_cycle & cpu_iorq & cpu_write;

// ---------------------------------------------------------------------------------------------
// ports

reg [5:0] p7ffd = 6'd0;   // 2..0 RAM page at C000, 3 screen, 4 ROM, 5 lock
reg [2:0] border = 3'd0;
wire lock = p7ffd[5];

// memory map
reg [22:0] map_addr;
always @* begin
	case (cpu_a[15:14])
		2'd0: map_addr = {5'd0, 2'b10, 1'b0, p7ffd[4], cpu_a[13:0]};   // ROM 0 / 1
		2'd1: map_addr = {6'd0, 3'd5, cpu_a[13:0]};
		2'd2: map_addr = {6'd0, 3'd2, cpu_a[13:0]};
		default: map_addr = {6'd0, p7ffd[2:0], cpu_a[13:0]};
	endcase
end
wire is_rom = (cpu_a[15:14] == 2'd0);

// keyboard columns of the selected rows
reg [4:0] kb_col;
integer r;
always @* begin
	kb_col = 5'b11111;
	for (r = 0; r < 8; r = r + 1)
		if (!cpu_a[8 + r])
			kb_col = kb_col & ~keys[r*5 +: 5];
end

reg [7:0] port_q;
always @* begin
	if (!cpu_a[0])
		port_q = {1'b1, tape_in, 1'b1, kb_col};
	else if (cpu_a[7:0] == 8'h1F)
		port_q = kempston;
	else
		port_q = 8'hFF;
end

// ---------------------------------------------------------------------------------------------
// memory requests of the CPU

wire a_busy = a_req ^ a_ack;

reg pend = 1'b0;           // a request waits for the channel (a posted write is not done yet)
reg pend_we = 1'b0;
reg [22:0] pend_addr = 23'd0;
reg [7:0] pend_din = 8'd0;
reg rd_cycle = 1'b0;       // this M-cycle reads memory: its data is a_q when the channel is free
reg wr_done = 1'b0;        // the write / port write of this M-cycle is made

always @(posedge clk) begin
	if (reset) begin
		pend <= 1'b0;
		rd_cycle <= 1'b0;
		wr_done <= 1'b0;
		p7ffd <= 6'd0;
		border <= 3'd0;
		beeper <= 1'b0;
		mic <= 1'b0;
		late <= 1'b0;
		nz <= 1'b0;
	end else begin
		if (cen_d) begin
			if (cpu_ts == 3'd1) begin
				wr_done <= 1'b0;
				rd_cycle <= mem_rd;
				if (mem_rd) begin
					pend <= 1'b1;
					pend_we <= 1'b0;
					pend_addr <= map_addr;
				end
			end
			if (cpu_ts == 3'd2 && !wr_done) begin
				if (mem_wr) begin
					wr_done <= 1'b1;
					if (!is_rom) begin
						pend <= 1'b1;
						pend_we <= 1'b1;
						pend_addr <= map_addr;
						pend_din <= cpu_do;
					end
				end
				if (io_wr) begin
					wr_done <= 1'b1;
					if (!cpu_a[0]) begin
						border <= cpu_do[2:0];
						mic <= cpu_do[3];
						beeper <= cpu_do[4];
					end
					if (!cpu_a[15] && !cpu_a[1] && !lock)
						p7ffd <= cpu_do[5:0];
				end
			end
			if (cpu_ts == 3'd3)
				rd_cycle <= 1'b0;
		end

		// pend goes to the channel when it is free (a one-clock pend is taken at once)
		if (pend && !a_busy && !(cen_d && (cpu_ts == 3'd1 || cpu_ts == 3'd2))) begin
			pend <= 1'b0;
			a_req <= ~a_req;
			a_we <= pend_we;
			a_addr <= pend_addr;
			a_din <= pend_din;
		end

		if (cpu_cen && cpu_ts == 3'd2 && !cpu_wait_n)
			late <= 1'b1;
		if (cpu_cen && cpu_ts == 3'd2 && cpu_wait_n && rd_cycle && a_q != 8'd0)
			nz <= 1'b1;
	end
end

// data of a read: wait while it is not there
assign cpu_wait_n = ~(rd_cycle & (pend | a_busy));
assign cpu_di = io_rd ? port_q : (cpu_intcycle_n ? a_q : 8'hFF);

// T80se: DI is taken into the register at the end of T2 (the instruction register takes DInst)
always @(posedge clk)
	if (cpu_cen && cpu_ts == 3'd2 && cpu_wait_n)
		cpu_di_reg <= cpu_di;

// ---------------------------------------------------------------------------------------------
// video fetch

localparam [3:0] AHEAD = 4'd12;   // pixels before its character a fetch may start

wire scr7 = p7ffd[3];
reg [8:0] tl = 9'd0;              // target line
reg [5:0] fk = 6'd32;             // character being fetched, 32: none
reg [7:0] bmp0 = 8'd0, bmp1 = 8'd0, atr0 = 8'd0, atr1 = 8'd0;
reg [1:0] fst = 2'd0;             // 0 idle, 1 bitmap, 2 attribute
wire b_busy = b_req ^ b_ack;

wire [8:0] next_line = (vc == 9'd319) ? 9'd0 : vc + 1'd1;
// a fetch of character fk may start: at the end of the line before for 0, else at 8 * fk - AHEAD
wire fetch_ok = (fk == 6'd0) || ((vc == tl) && ({1'b0, hc} + AHEAD >= {fk[4:0], 3'b000}));

wire [12:0] bmp_off = {tl[7:6], tl[2:0], tl[5:3], fk[4:0]};
wire [12:0] atr_off = {3'b110, tl[7:3], fk[4:0]};

always @(posedge clk) begin
	if (reset) begin
		fk <= 6'd32;
		fst <= 2'd0;
	end else begin
		if (ce7 && hc == 9'd436) begin
			tl <= next_line;
			fk <= (next_line < 9'd192) ? 6'd0 : 6'd32;
			fst <= 2'd0;
		end else begin
			case (fst)
				2'd0: if (!fk[5] && fetch_ok && !b_busy) begin
					b_addr <= {6'd0, scr7 ? 3'd7 : 3'd5, 1'b0, bmp_off};
					b_req <= ~b_req;
					fst <= 2'd1;
				end
				2'd1: if (!b_busy) begin
					if (fk[0]) bmp1 <= b_q; else bmp0 <= b_q;
					b_addr <= {6'd0, scr7 ? 3'd7 : 3'd5, 1'b0, atr_off};
					b_req <= ~b_req;
					fst <= 2'd2;
				end
				default: if (!b_busy) begin
					if (fk[0]) atr1 <= b_q; else atr0 <= b_q;
					fk <= fk + 1'd1;
					fst <= 2'd0;
				end
			endcase
		end
	end
end

// ---------------------------------------------------------------------------------------------
// pixels: stage 1 loads / shifts, stage 2 makes the colour

wire paper = (vc < 9'd192) && (hc < 9'd256);
wire blank = (hc >= 9'd320 && hc < 9'd384) || (vc >= 9'd240 && vc < 9'd256);

reg [7:0] shreg = 8'd0;
reg [7:0] attr_r = 8'd0;
reg pap_r = 1'b0, blank_r = 1'b0;
reg [2:0] brd_r = 3'd0;

always @(posedge clk) begin
	if (ce7) begin
		pap_r <= paper;
		blank_r <= blank;
		brd_r <= border;
		if (paper && hc[2:0] == 3'd0) begin
			shreg <= hc[3] ? bmp1 : bmp0;
			attr_r <= hc[3] ? atr1 : atr0;
		end else
			shreg <= {shreg[6:0], 1'b0};

		if (blank_r)
			pix <= 4'd0;
		else if (pap_r)
			pix <= (shreg[7] ^ (attr_r[7] & frame[4])) ? {attr_r[6], attr_r[2:0]} : {attr_r[6], attr_r[5:3]};
		else
			pix <= {1'b0, brd_r};
	end
end

endmodule
