`timescale 1ns / 1ps
`default_nettype none

/*
 pentagon.v

 One Pentagon 128 machine: T80 at 3.5 MHz, 128 KB RAM and 32 KB ROM in its SDRAM bank (two
 channels of sdram_ctrl), ports #FE and #7FFD, the Pentagon INT, the video of the paper and the
 border. No contention (Pentagon). clk = clk_bus, 28 MHz; the raster and the enables come from
 zx_timing, shared by all the machines (docs/ARCHITECTURE.md).

 Memory (byte address in the bank of the machine):
   0x00000..0x1FFFF  RAM pages 0..7 (page p < 8 at p * 16 KB)
   0x20000..0x2FFFF  ROM area, 16 KB per ROM: 0 = 128 editor, 1 = 48 BASIC (#7FFD bit 4),
                     2 reserved (TR-DOS), 3 the ESXDOS ROM of the DivMMC (8 KB); filled by the ROM
                     loader of the top
   0x80000..0xFFFFF  DivMMC RAM, 64 banks of 8 KB
   0x120000..0x1FFFFF RAM pages 8..63 (page p at 0x100000 + p * 16 KB)

 1024 KB RAM as Profi (karabas-go-core-profi, mem1024: OSD Memory size 1024K): port #DFFD (full address) 2..0 the bits 5..3 of the page in C000 (with
 #7FFD 2..0: 64 pages of 16 KB); its other bits (SCO, WOROM, CPM, SCR, DS80 of Profi) are ignored. Cleared by a reset.
 The AY ports take A13 = 1 (#FFFD / #BFFD) so that #DFFD is not one of them. With 128K (mem1024 0) #DFFD is not
 decoded, its page bits count as 0 and the AY ports are those of Pentagon (A15 = 1, A1 = 0).

 DivMMC (divmmc_en): ports #E3 (7 CONMEM, 6 MAPRAM, 5..0 the RAM bank at 2000), #E7 (bit 0 the card
 select), #EB (SPI: a write sends the byte, a read gives the byte of the exchange before and sends
 FF). Mapped (CONMEM or automap): 0000-1FFF the ESXDOS ROM (with MAPRAM: RAM bank 3, read only),
 2000-3FFF the RAM bank (read only with MAPRAM and bank 3). Automap on the opcode fetch of 0000,
 0008, 0038, 0066, 04C6, 0562 (after the fetch) and 3D00-3DFF (the fetch itself, any ROM); off after
 the fetch of 1FF8-1FFF. As divmmc.vhd of divgmx (MVV): a reset of the machine keeps #E3 and the
 automap state (power on clears them; a reset with NMI held clears #E3). MAPRAM is only cleared by a power on (or DivMMC off). The SPI master runs at
 7 MHz (4 clocks per bit, mode 0) to the card of the board or kg_sd_emu (the top chooses). The CPU
 waits on an access of #EB while an exchange is running or the emulated card waits for the MCU
 (sd_wait).

 Z-Controller (always on, with the DivMMC on or off): the same SPI master and card select. Port #57 as #EB (a write
 sends the byte, a read gives the byte of the exchange before and sends FF); a write of #77 sets the card select
 from bit 1 (0 selected; bit 0, the power of the card, is not used); a read of #77 gives FC (bit 0 a card is in,
 bit 1 not write protected). Ports by A7..A0 (as karabas-go-core-profi).

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

 The fetcher runs in the quad view too: the quad view shows pix through the frame buffer (quad_fb.v).
*/

module pentagon #(
	parameter CPU = 1      // 1 tv80, 0 T80, 2 outside (one tv80_quad for the four machines, ports x_*)
) (
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
	input wire [23:0] mouse,      // Kempston mouse: {buttons byte, y, x} (quad_mouse.v)
	input wire tape_in,
	output reg beeper = 1'b0,
	output reg mic = 1'b0,
	input wire nmi,               // NMI while high
	input wire areset,            // power on (the start of the core): clears the DivMMC, a reset does not
	input wire mem1024,           // 1024 KB (Profi, #DFFD); 0: 128 KB, #DFFD not decoded, the AY ports as Pentagon

	// TR-DOS and the Beta Disk (the controller hrdy_fdc in the top): this machine has them (OSD FDD, DivMMC off)
	input wire trdos_en,
	output wire fdc_cs,           // an I/O access to a register of the VG93 (#1F, #3F, #5F, #7F) in TR-DOS
	output wire fdc_csff,         // to the system port #FF in TR-DOS
	output wire fdc_rd,           // the I/O read / write of this M-cycle
	output wire fdc_wr,
	input wire [7:0] fdc_q,
	input wire fdc_busy,          // WAIT of the controller

	// DivMMC
	input wire divmmc_en,
	output reg spi_sck = 1'b0,
	output reg spi_mosi = 1'b1,
	output reg spi_cs_n = 1'b1,
	input wire spi_miso,
	input wire sd_wait,           // the emulated card waits for the MCU

	// TurboSound (two AY): the register writes of the machine (to the generators when it is the selected one),
	// its register copies read by index {chip, register} (to load the generators when it becomes selected)
	output reg ay_we = 1'b0,
	output reg [4:0] ay_wa = 5'd0,
	output reg [7:0] ay_wd = 8'd0,
	input wire [4:0] ay_ra,
	output wire [7:0] ay_rd,

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

	// the CPU outside (CPU = 2): its outputs in, what it takes out (machine k: its slot 2k of tv80_quad)
	input wire [15:0] x_a,
	input wire [7:0] x_do,
	input wire [6:0] x_mc,          // one-hot as tv80
	input wire [6:0] x_ts,
	input wire x_iorq,
	input wire x_noread,
	input wire x_write,
	input wire x_intcycle_n,
	output wire x_cen,
	output wire x_wait_n,
	output wire x_reset_n,
	output wire x_nmi_n,
	output wire [7:0] x_dinst,
	output wire [7:0] x_di,

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

// The CPU: CPU = 1 tv80 (Verilog, of karabas_go_v6z80p: T80 ported to Verilog, with its fixes of the X / Y flags of
// CPI / CPD; ~40 % fewer LUTs than T80), 0 T80 (VHDL, version 351 of TS-Conf). Both give the same signals of the
// T80 core (MC, TS, Write, NoRead, IORQ, IntCycle_n) to the bus logic below.
generate
	if (CPU == 1) begin : g_tv80
		// tv80 gives the machine cycle and the T-state one-hot (mc[0] = M1, ts[n] = Tn): to the numbers of T80
		wire [6:0] tv_mc, tv_ts;
		assign cpu_mc = tv_mc[0] ? 3'd1 : tv_mc[1] ? 3'd2 : tv_mc[2] ? 3'd3 : tv_mc[3] ? 3'd4 : tv_mc[4] ? 3'd5 :
			tv_mc[5] ? 3'd6 : 3'd7;
		assign cpu_ts = tv_ts[1] ? 3'd1 : tv_ts[2] ? 3'd2 : tv_ts[3] ? 3'd3 : tv_ts[4] ? 3'd4 : tv_ts[5] ? 3'd5 :
			tv_ts[6] ? 3'd6 : 3'd0;
		tv80_core #(.Mode(0), .IOWait(1)) cpu (
			.reset_n(~reset),
			.clk(clk),
			.cen(cpu_cen),
			.wait_n(cpu_wait_n),
			.int_n(int_n),
			.nmi_n(~nmi),
			.busrq_n(1'b1),
			.m1_n(),
			.iorq(cpu_iorq),
			.no_read(cpu_noread),
			.write(cpu_write),
			.rfsh_n(),
			.halt_n(),
			.busak_n(),
			.A(cpu_a),
			.dinst(cpu_di),
			.di(cpu_di_reg),
			.dout(cpu_do),
			.mc(tv_mc),
			.ts(tv_ts),
			.intcycle_n(cpu_intcycle_n),
			.IntE(),
			.stop()
		);
	end else if (CPU == 2) begin : g_outside
		assign cpu_a = x_a;
		assign cpu_do = x_do;
		assign cpu_mc = x_mc[0] ? 3'd1 : x_mc[1] ? 3'd2 : x_mc[2] ? 3'd3 : x_mc[3] ? 3'd4 : x_mc[4] ? 3'd5 :
			x_mc[5] ? 3'd6 : 3'd7;
		assign cpu_ts = x_ts[1] ? 3'd1 : x_ts[2] ? 3'd2 : x_ts[3] ? 3'd3 : x_ts[4] ? 3'd4 : x_ts[5] ? 3'd5 :
			x_ts[6] ? 3'd6 : 3'd0;
		assign cpu_iorq = x_iorq;
		assign cpu_noread = x_noread;
		assign cpu_write = x_write;
		assign cpu_intcycle_n = x_intcycle_n;
	end else begin : g_t80
		T80 #(.Mode(0), .IOWait(1)) cpu (
			.RESET_n(~reset),
			.CLK_n(clk),
			.CEN(cpu_cen),
			.WAIT_n(cpu_wait_n),
			.INT_n(int_n),
			.NMI_n(~nmi),
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
	end
endgenerate

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
reg [2:0] pdffd = 3'd0;   // Profi 1024: #DFFD 2..0, the page bits 5..3
reg [2:0] border = 3'd0;
wire lock = p7ffd[5];
wire [5:0] page = {mem1024 ? pdffd : 3'd0, p7ffd[2:0]};
// RAM page p, offset a: pages 0..7 at p * 16 KB, 8..63 at 0x100000 + p * 16 KB
function [22:0] ram_addr;
	input [5:0] p;
	input [13:0] a;
	ram_addr = {2'b00, |p[5:3], p, a};
endfunction

// DivMMC registers
reg dv_conmem = 1'b0, dv_mapram = 1'b0;
reg [5:0] dv_bank = 6'd0;
reg dv_automap = 1'b0, dv_detect = 1'b0;

// the opcode fetch of this M-cycle maps the DivMMC at once (3D00-3DFF, with any ROM, as divmmc.vhd of
// divgmx): the read of the opcode itself comes from the DivMMC
wire dv_instant = m1_cycle & cpu_intcycle_n & (cpu_a[15:8] == 8'h3D);
wire dv_mapped = divmmc_en & (dv_conmem | dv_automap | dv_instant);

// TR-DOS (Beta Disk, as Pentagon): on with an opcode fetch from 3D00..3DFF while the ROM of BASIC 48 is on, off with an
// opcode fetch from the RAM (4000..FFFF); while on, the TR-DOS ROM (ROM 2, 0x28000) is in 0000..3FFF and the ports of
// the controller are there. The fetch at 3Dxx itself comes from the TR-DOS ROM (the font of BASIC 48 is there).
reg dos = 1'b0;
wire dos_instant = m1_cycle & cpu_intcycle_n & (cpu_a[15:8] == 8'h3D) & p7ffd[4];
wire dos_rom = trdos_en & (dos | dos_instant);

// memory map
reg [22:0] map_addr;
reg map_ro;
always @* begin
	map_ro = 1'b0;
	if (dv_mapped && cpu_a[15:13] == 3'b000) begin
		map_ro = 1'b1;
		map_addr = dv_mapram ? {4'b0001, 6'd3, cpu_a[12:0]} : {5'd0, 2'b10, 2'b11, cpu_a[13:0]};
	end else if (dv_mapped && cpu_a[15:13] == 3'b001) begin
		map_ro = dv_mapram && dv_bank == 6'd3;
		map_addr = {4'b0001, dv_bank, cpu_a[12:0]};
	end else case (cpu_a[15:14])
		2'd0: begin map_ro = 1'b1; map_addr = {5'd0, 2'b10, dos_rom ? 2'b10 : {1'b0, p7ffd[4]}, cpu_a[13:0]}; end   // ROM 0 / 1 / TR-DOS
		2'd1: map_addr = ram_addr(6'd5, cpu_a[13:0]);
		2'd2: map_addr = ram_addr(6'd2, cpu_a[13:0]);
		default: map_addr = ram_addr(page, cpu_a[13:0]);
	endcase
end
wire is_rom = map_ro;

// DivMMC ports
wire dv_port_e3 = divmmc_en && cpu_a[7:0] == 8'hE3;
wire dv_port_e7 = divmmc_en && cpu_a[7:0] == 8'hE7;
wire dv_port_eb = divmmc_en && cpu_a[7:0] == 8'hEB;
// Z-Controller: #57 the SPI data (as #EB), #77 the card select
wire zc_port_57 = cpu_a[7:0] == 8'h57;
wire zc_port_77 = cpu_a[7:0] == 8'h77;
wire spi_port = dv_port_eb | zc_port_57;

// keyboard columns of the selected rows
reg [4:0] kb_col;
integer r;
always @* begin
	kb_col = 5'b11111;
	for (r = 0; r < 8; r = r + 1)
		if (!cpu_a[8 + r])
			kb_col = kb_col & ~keys[r*5 +: 5];
end

reg [7:0] spi_in = 8'hFF;   // the byte of the last exchange
reg [7:0] eb_q = 8'hFF;     // what this IN of #EB gives: spi_in when it started its exchange
// TurboSound: #FFFD (A15 = 1, A14 = 1, A1 = 0) register select or, with FF / FE (F8..FF: bit 0), the chip
// (FF the first, FE the second); #BFFD (A14 = 0) data. The registers of the two chips are kept here (32 x 8 of
// distributed RAM, the bits the AY has): the reads of #FFFD come from them, the generators (ay_psg, only for the
// selected machine, in the top) get the writes and are loaded from them when the machine becomes selected.
wire ay_port = cpu_a[15] & (cpu_a[13] | ~mem1024) & ~cpu_a[1];   // A13 with 1024K: not #DFFD
reg ay_chip = 1'b0;
reg [3:0] ay_reg = 4'd0;
reg ay_rv = 1'b1;             // the register select had 0 in bits 7..4 (else the chip is not addressed)
reg [5:0] ay_clr = 6'd0;      // a reset clears the 32 registers (the AY RESET), one a clock
reg [7:0] ay_ram [0:31];
integer ay_i;
initial for (ay_i = 0; ay_i < 32; ay_i = ay_i + 1) ay_ram[ay_i] = 8'd0;
assign ay_rd = ay_ram[ay_ra];

reg [7:0] port_q;
always @* begin
	if (spi_port)
		port_q = io_done ? eb_q : spi_in;
	else if (zc_port_77)
		port_q = 8'hFC;
	else if (!cpu_a[0])
		port_q = {1'b1, tape_in, 1'b1, kb_col};
	else if (fdc_cs || fdc_csff)
		port_q = fdc_q;
	else if (ay_port && cpu_a[14])
		port_q = ay_rv ? ay_ram[{ay_chip, ay_reg}] : 8'hFF;
	else if (cpu_a[7:0] == 8'h1F)
		port_q = kempston;
	else if (cpu_a[7:0] == 8'hDF)
		// Kempston mouse: #FADF buttons (A8 = 0), #FBDF x, #FFDF y (A10)
		port_q = !cpu_a[8] ? mouse[23:16] : cpu_a[10] ? mouse[15:8] : mouse[7:0];
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
		pdffd <= 3'd0;
		// port #FE (border, MIC, beeper) is kept over a reset, as the ULA: the border stays until the ROM sets it
		late <= 1'b0;
		nz <= 1'b0;
	end else begin
		if (cen_d) begin
			if (cpu_ts == 3'd1) begin
				wr_done <= 1'b0;
				rd_cycle <= mem_rd;
				if (mem_rd) begin
					// straight to the channel when it is free (a clock earlier than through pend: the ports of
					// sdram_ctrl on clk_bus cost a clock each way)
					if (!a_busy && !pend) begin
						a_req <= ~a_req;
						a_we <= 1'b0;
						a_addr <= map_addr;
					end else begin
						pend <= 1'b1;
						pend_we <= 1'b0;
						pend_addr <= map_addr;
					end
				end
			end
			if (cpu_ts == 3'd2 && !wr_done) begin
				if (mem_wr) begin
					wr_done <= 1'b1;
					if (!is_rom) begin
						if (!a_busy && !pend) begin
							a_req <= ~a_req;
							a_we <= 1'b1;
							a_addr <= map_addr;
							a_din <= cpu_do;
						end else begin
							pend <= 1'b1;
							pend_we <= 1'b1;
							pend_addr <= map_addr;
							pend_din <= cpu_do;
						end
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
					if (mem1024 && cpu_a == 16'hDFFD)
						pdffd <= cpu_do[2:0];
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

		if (cpu_cen && cpu_ts == 3'd2 && rd_cycle && (pend || a_busy))
			late <= 1'b1;
		if (cpu_cen && cpu_ts == 3'd2 && cpu_wait_n && rd_cycle && a_q != 8'd0)
			nz <= 1'b1;
	end
end

// ---------------------------------------------------------------------------------------------
// TurboSound registers

// the bits of the register r the AY has (the rest read as 0)
function [7:0] ay_mask;
	input [3:0] r;
	case (r)
		4'd1, 4'd3, 4'd5, 4'd13: ay_mask = 8'h0F;
		4'd6, 4'd8, 4'd9, 4'd10: ay_mask = 8'h1F;
		default: ay_mask = 8'hFF;
	endcase
endfunction

always @(posedge clk) begin
	ay_we <= 1'b0;
	if (reset) begin
		ay_chip <= 1'b0;
		ay_reg <= 4'd0;
		ay_rv <= 1'b1;
		ay_clr <= 6'd32;
	end else if (ay_clr != 6'd0) begin
		ay_clr <= ay_clr - 1'd1;
		ay_we <= 1'b1;
		ay_wa <= ay_clr[4:0] - 1'd1;
		ay_wd <= 8'd0;
	end else if (cen_d && cpu_ts == 3'd2 && !wr_done && io_wr && ay_port) begin
		if (cpu_a[14]) begin
			if (&cpu_do[7:3])
				ay_chip <= ~cpu_do[0];
			else begin
				ay_reg <= cpu_do[3:0];
				ay_rv <= (cpu_do[7:4] == 4'd0);
			end
		end else if (ay_rv) begin
			ay_we <= 1'b1;
			ay_wa <= {ay_chip, ay_reg};
			ay_wd <= cpu_do & ay_mask(ay_reg);
		end
	end
	if (ay_we)
		ay_ram[ay_wa] <= ay_wd;
end

// ---------------------------------------------------------------------------------------------
// DivMMC: automap, ports, SPI master

reg [4:0] spi_cnt = 5'd0;     // 4 clocks per bit, 8 bits
reg spi_busy = 1'b0;
reg [7:0] spi_sr = 8'hFF;
reg io_done = 1'b0;           // the #EB access of this M-cycle is made
wire eb_cycle = spi_port & ~m1_cycle & cpu_iorq;   // #EB of the DivMMC or #57 of the Z-Controller
// the CPU waits only before the exchange of this access starts (the one before is still running, or the emulated
// card waits for the MCU); not for its own exchange: an IN gives the byte of the exchange before it (DivMMC).
// Waiting for its own exchange (the automatic TW of the I/O cycle) made the IN return the byte of the exchange it
// started: every answer of the card one byte late, no card found (found on the board with ESXDOS 0.8.9).
wire eb_wait = eb_cycle & ~io_done & (spi_busy | (sd_wait & ~cpu_write));

// The state of the DivMMC is kept over a reset of the machine (divmmc.vhd of divgmx, MVV): #E3, the card
// select, automap and detect are cleared at power on (areset) and while the DivMMC is off; #E3 and the card
// select also at a reset with NMI held (ESXDOS starts without its state). Clearing them at every reset made
// ESXDOS 0.8.9 reboot in a loop after a reset (found on the board).
wire m1_read = m1_cycle & cpu_intcycle_n & (cpu_ts == 3'd1 || cpu_ts == 3'd2);
wire dv_entry = cpu_a == 16'h0000 || cpu_a == 16'h0008 || cpu_a == 16'h0038 || cpu_a == 16'h0066 ||
	cpu_a == 16'h04C6 || cpu_a == 16'h0562;
wire dv_exit = cpu_a[15:3] == 13'b0001111111111;   // 1FF8-1FFF

always @(posedge clk) begin
	if (areset || !divmmc_en) begin
		dv_conmem <= 1'b0;
		dv_mapram <= 1'b0;
		dv_bank <= 6'd0;
		dv_automap <= 1'b0;
		dv_detect <= 1'b0;
	end else if (reset) begin
		if (nmi) begin
			dv_conmem <= 1'b0;
			dv_mapram <= 1'b0;
			dv_bank <= 6'd0;
		end
	end else begin
		// automap: an opcode fetch of an entry point sets detect, of 1FF8-1FFF clears it, of 3Dxx maps at once;
		// out of the fetch automap follows detect (the fetch itself still from before)
		if (m1_read && dv_entry)
			dv_detect <= 1'b1;
		else if (m1_read && dv_exit)
			dv_detect <= 1'b0;
		else if (m1_read && cpu_a[15:8] == 8'h3D) begin
			dv_automap <= 1'b1;
			dv_detect <= 1'b1;
		end else
			dv_automap <= dv_detect;

		// port writes (as the other ports, DO valid in T2)
		if (cen_d && cpu_ts == 3'd2 && !wr_done && io_wr) begin
			if (dv_port_e3) begin
				dv_conmem <= cpu_do[7];
				dv_mapram <= dv_mapram | cpu_do[6];
				dv_bank <= cpu_do[5:0];
			end
		end
	end
end

// the card select: #E7 bit 0 (DivMMC) or #77 bit 1 (Z-Controller); high at power on and at a reset with NMI held,
// kept over a plain reset (as the state of the DivMMC); not cleared with the DivMMC off (the Z-Controller has it)
always @(posedge clk)
	if (areset)
		spi_cs_n <= 1'b1;
	else if (reset) begin
		if (nmi)
			spi_cs_n <= 1'b1;
	end else if (cen_d && cpu_ts == 3'd2 && !wr_done && io_wr) begin
		if (dv_port_e7)
			spi_cs_n <= cpu_do[0];
		if (zc_port_77)
			spi_cs_n <= cpu_do[1];
	end

// the SPI exchanges (DivMMC and Z-Controller): cleared with the machine
always @(posedge clk) begin
	if (reset) begin
		spi_busy <= 1'b0;
		spi_sck <= 1'b0;
		spi_mosi <= 1'b1;
		io_done <= 1'b0;
	end else begin
		// #EB: one exchange per access, at the end of T2 when the CPU does not wait
		if (cpu_ts == 3'd1)
			io_done <= 1'b0;
		if (cpu_cen && cpu_ts == 3'd2 && cpu_wait_n && eb_cycle && !io_done && !spi_busy) begin
			io_done <= 1'b1;
			eb_q <= spi_in;
			spi_busy <= 1'b1;
			spi_cnt <= 5'd0;
			spi_sr <= cpu_write ? cpu_do : 8'hFF;
		end

		// the exchange: bit k: sck low and MOSI at 4k, sck high at 4k + 2, MISO taken at 4k + 3
		if (spi_busy) begin
			spi_cnt <= spi_cnt + 1'd1;
			case (spi_cnt[1:0])
				2'd0: begin spi_sck <= 1'b0; spi_mosi <= spi_sr[7]; end
				2'd2: spi_sck <= 1'b1;
				2'd3: begin
					spi_sr <= {spi_sr[6:0], spi_miso};
					if (spi_cnt == 5'd31)
						spi_busy <= 1'b0;
				end
				default: ;   // 1: nothing (a default here shifted twice a bit: every second bit went out)
			endcase
		end else
			spi_sck <= 1'b0;
	end
end

// the byte of the exchange before: what a read of #EB gives (taken when the exchange ends)
always @(posedge clk)
	if (reset)
		spi_in <= 8'hFF;
	else if (spi_busy && spi_cnt == 5'd31)
		spi_in <= {spi_sr[6:0], spi_miso};

// data of a read: wait while it is not there
assign cpu_wait_n = ~(rd_cycle & (pend | a_busy)) & ~eb_wait & ~(fdc_busy & (fdc_cs | fdc_csff));

// the TR-DOS flag (on a reset off) and the ports of the Beta Disk
always @(posedge clk)
	if (reset || !trdos_en)
		dos <= 1'b0;
	else if (m1_read && cpu_a[15:8] == 8'h3D && p7ffd[4])
		dos <= 1'b1;
	else if (m1_read && cpu_a[15:14] != 2'b00)
		dos <= 1'b0;
// the selects as the strobes (from T2): as the iordwr of TS-Conf, the VG93 sees CS with RD or WR only
wire io_cycle = ~m1_cycle & cpu_iorq & (cpu_ts != 3'd1);
assign fdc_cs = trdos_en & dos & io_cycle & ~cpu_a[7] & (cpu_a[4:0] == 5'h1F);
assign fdc_csff = trdos_en & dos & io_cycle & (cpu_a[7:0] == 8'hFF);
// the read / write strobes from T2 on, as /RD /WR of the Z80 (T80): the data out of the CPU is valid from T2; hrdy_fdc
// takes port #FF in every clock of a write, and the byte of before on the bus in T1 reset the VG93 through /MR now
// and then (TR-DOS: NO DISK; found on the board, src/sim TRDOS=1 checks it)
// /WE ends at T3 (T2 and TW only), before the address changes: the VG93 takes the register of a write by the address
// it samples at the end of /WE (vg93_host_bus); with /WE to the end of the M-cycle the address of the next cycle was
// there in the same clock and the byte went to another register or was lost (TR-DOS: NO DISK; found on the board).
// /WR of the Z80 ends in the middle of T3, the address changes in the next T1.
assign fdc_rd = io_rd & (cpu_ts != 3'd1);
assign fdc_wr = io_wr & (cpu_ts == 3'd2);
// FF (Pentagon: pull-ups) only in the acknowledge M1 of an interrupt. IntCycle_n of the T80 stays low for the whole
// answer to the interrupt (the acknowledge, the push of PC and the read of the IM2 vector from the table): FF on it
// made every IM 2 vector FFFF (found on the board: programs with IM 2 crashed or restarted).
assign cpu_di = io_rd ? port_q : ((m1_cycle && !cpu_intcycle_n) ? 8'hFF : a_q);

// to the CPU outside (CPU = 2), as the ports of the CPU inside
assign x_cen = cpu_cen;
assign x_wait_n = cpu_wait_n;
assign x_reset_n = ~reset;
assign x_nmi_n = ~nmi;
assign x_dinst = cpu_di;
assign x_di = cpu_di_reg;

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

// the raster fetch (not stopped by a reset of the machine: the ULA shows the memory during a reset)
always @(posedge clk) begin
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

// ---------------------------------------------------------------------------------------------
// pixels: stage 1 loads / shifts, stage 2 makes the colour

wire paper = (vc < 9'd192) && (hc < 9'd256);
// black: the sync, and the last visible row (the line of INT, 239: its paper part, and the left border before it, the
// pixels 392..447 of line 238; the left border of 239 belongs to the row of 240, in the blank anyway)
wire blank = (hc >= 9'd320 && hc < 9'd384) || (vc >= 9'd240 && vc < 9'd256) ||
	(vc == 9'd239 && hc < 9'd392) || (vc == 9'd238 && hc >= 9'd392);

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
