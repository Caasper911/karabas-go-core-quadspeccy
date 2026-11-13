`timescale 1ns / 1ps

/*
 tb_pentagon.v

 One Pentagon 128 on sdram_ctrl with the SDRAM model, the ROMs of src/roms preloaded into its bank (roms.hex,
 made by run_sim.sh): it runs FRAMES frames and checks
   - the SDRAM commands against the timing of the model (sdram_model errors)
   - that no CPU read needed wait states (pentagon late)
   - that the CPU runs (the opcode fetch addresses, printed each frame)
 and writes the screen pages 5 and 7 (screen5.hex, screen7.hex) and #7FFD for render_screen.py.
 Prints "tb_pentagon: <n> errors" at the end.
*/

module tb_pentagon;

`ifndef FRAMES
`define FRAMES 4
`endif
parameter FRAMES = `FRAMES;
// the SDRAM bank of the machine (machine n of the core uses bank n; bank 3 has the last window of a round)
`ifndef BANK
`define BANK 0
`endif
parameter BANK = `BANK;
localparam [31:0] BOFS = BANK << 20;   // word index of the bank in the model: {bank, row[10:0], column} (2 MB a bank)
`ifndef TRDOS
`define TRDOS 0
`endif
// TRDOS = 1 (run_sim.sh): trtest.asm, the machine with TR-DOS, no DivMMC; the controller answers 5A
`ifndef MEMTEST
`define MEMTEST 0
`endif
`ifndef DIVMMC
`define DIVMMC ((`TRDOS || `MEMTEST) ? 0 : 1)
`endif
parameter DIVMMC = `DIVMMC;
`ifndef SDEMU
`define SDEMU 0
`endif
parameter USE_SDEMU = `SDEMU;
`ifndef SDTEST
`define SDTEST 0
`endif
`ifndef CUSTOM_ROM
`define CUSTOM_ROM 0
`endif

// DivMMC: fetches from its ROM, accesses of its RAM, exchanges on #EB
integer dv_fetches = 0, dv_ram = 0, eb_xfers = 0, at_zero = 0;
always @(posedge clk_bus) begin
	if (m.cen_d && m.cpu_ts == 3'd1 && m.cpu_mc == 3'd1 && m.dv_mapped && m.cpu_a[15:13] == 3'd0)
		dv_fetches = dv_fetches + 1;
	if (m.cen_d && m.cpu_ts == 3'd1 && m.dv_mapped && m.cpu_a[15:13] == 3'd1)
		dv_ram = dv_ram + 1;
	if (m.spi_busy && m.spi_cnt == 5'd0)
		eb_xfers = eb_xfers + 1;
	// trace: #E3 writes, fetches of the entry points and of 3Dxx
	if (m.cen_d && m.cpu_ts == 3'd2 && !m.wr_done && m.io_wr && m.dv_port_e3 && !reset)
		$display("%t OUT (E3),%h  pc %h", $time, m.cpu_do, last_pc);
	if (m.cen_d && m.cpu_ts == 3'd1 && m.cpu_mc == 3'd1 && m.cpu_intcycle_n && !reset &&
		(m.cpu_a == 16'h0066 || m.cpu_a == 16'h0008))
		$display("%t fetch %h mapped %b automap %b detect %b", $time, m.cpu_a, m.dv_mapped, m.dv_automap, m.dv_detect);
	if (m.cen_d && m.cpu_ts == 3'd1 && m.cpu_mc == 3'd1 && m.cpu_intcycle_n && m.cpu_a == 16'h0000 && !reset) begin
		at_zero = at_zero + 1;
		$display("%t fetch at 0000 (%0d), mapped %b, e3 %b%b %h", $time, at_zero, m.dv_mapped, m.dv_conmem, m.dv_mapram, m.dv_bank);
	end
end

reg clk_sys = 1'b0, clk_bus = 1'b0;
always #5.946 clk_sys = ~clk_sys;    // 84.09 MHz
always #17.838 clk_bus = ~clk_bus;   // 28.03 MHz, rising edges on rising edges of clk_sys

wire [3:0] a_req, a_ack, a_we, b_req, b_ack;
wire [4*23-1:0] a_addr, b_addr;
wire [4*8-1:0] a_din, a_q, b_q;
wire ready;

wire sdr_clk, sdr_ras_n, sdr_cas_n, sdr_we_n;
wire [1:0] sdr_ba, sdr_dqm;
wire [12:0] sdr_a;
wire [15:0] sdr_dq;

sdram_ctrl #(.INIT_WAIT(16'd200)) sdram(
	.clk(clk_sys),
	.clk_bus(clk_bus),
	.a_req(a_req), .a_ack(a_ack), .a_we(a_we), .a_addr(a_addr), .a_din(a_din), .a_q(a_q),
	.b_req(b_req), .b_ack(b_ack), .b_addr(b_addr), .b_q(b_q),
	.ready(ready),
	.SDR_CLK(sdr_clk), .SDR_BA(sdr_ba), .SDR_A(sdr_a), .SDR_DQM(sdr_dqm),
	.SDR_RAS_N(sdr_ras_n), .SDR_CAS_N(sdr_cas_n), .SDR_WE_N(sdr_we_n), .SDR_DQ(sdr_dq)
);

sdram_model #(.ROWS(2048), .RB(11)) chip(
	.clk(sdr_clk), .ba(sdr_ba), .a(sdr_a), .dqm(sdr_dqm),
	.ras_n(sdr_ras_n), .cas_n(sdr_cas_n), .we_n(sdr_we_n), .dq(sdr_dq)
);

// 128, 48, TR-DOS (FF), ESXDOS from 0x20000 (word 0x10000)
initial $readmemh("roms.hex", chip.mem, BOFS + 'h10000, BOFS + 'h16FFF);

wire ce7, ce_cpu, ce14, int_n, vga_half;
wire [8:0] hc, vc, vga_x;
wire [4:0] frame;

// a warm reset of the machine at frame RESET_AT (0: none), as Win+F12: the SDRAM keeps its contents
`ifndef RESET_AT
`define RESET_AT 0
`endif
reg warm = 1'b0;
integer warm_cnt = 0;
always @(posedge clk_bus)
	if (warm) begin
		warm_cnt = warm_cnt + 1;
		if (warm_cnt > 2000)
			warm <= 1'b0;
	end

reg reset = 1'b1;
always @(posedge clk_bus)
	reset <= ~ready | warm;

zx_timing timing(
	.clk(clk_bus), .reset(1'b0),
	.ce7(ce7), .ce_cpu(ce_cpu), .ce14(ce14), .hc(hc), .vc(vc), .int_n(int_n), .frame(frame),
	.vga_x(vga_x), .vga_half(vga_half)
);

wire [3:0] pix;
wire late, beeper, mic;

// QUAD = 1: the CPU of the machine is CPU 0 of a tv80_quad (as the top: slot counter on ce_cpu, the others in reset)
`ifndef QUAD
`define QUAD 0
`endif
reg [2:0] cslot = 3'd0;
always @(posedge clk_bus)
	cslot <= ce_cpu ? 3'd1 : cslot + 1'd1;
wire [15:0] x_a;
wire [7:0] x_do, x_dinst, x_di;
wire [6:0] x_mc, x_ts;
wire x_iorq, x_noread, x_write, x_intcycle_n, x_cen, x_wait_n, x_reset_n, x_nmi_n;
generate
	if (`QUAD) begin : g_quad
		wire [4*16-1:0] qa;
		wire [4*8-1:0] qdo;
		wire [4*7-1:0] qmc, qts;
		wire [3:0] qio, qnr, qwr, qic;
		tv80_quad #(.Mode(0), .IOWait(1)) cpus (
			.clk(clk_bus), .slot(cslot),
			.reset_n({3'b000, x_reset_n}), .cen({3'b000, x_cen}), .wait_n({3'b111, x_wait_n}), .int_n({4{int_n}}),
			.nmi_n({3'b111, x_nmi_n}), .dinst({24'hFFFFFF, x_dinst}), .di({24'hFFFFFF, x_di}),
			.A(qa), .dout(qdo), .mc(qmc), .ts(qts), .m1_n(), .iorq(qio), .no_read(qnr), .write(qwr), .intcycle_n(qic),
			.halt_n()
		);
		assign x_a = qa[15:0];
		assign x_do = qdo[7:0];
		assign x_mc = qmc[6:0];
		assign x_ts = qts[6:0];
		assign x_iorq = qio[0];
		assign x_noread = qnr[0];
		assign x_write = qwr[0];
		assign x_intcycle_n = qic[0];
	end
endgenerate

// TRDOS: a write to #FF must have its byte (3C in trtest.asm) on the data bus in every clock it is seen (hrdy_fdc
// takes port #FF in each such clock: a stale byte there reset the VG93 through /MR)
wire fdc_cs, fdc_csff, fdc_rd, fdc_wr, fdc_busy;
wire [7:0] fdc_q;
integer fdc_wait_clocks = 0;
always @(posedge clk_bus)
	if (fdc_busy && (fdc_cs || fdc_csff)) fdc_wait_clocks = fdc_wait_clocks + 1;
integer ff_writes = 0, ff_bad = 0;
always @(posedge clk_bus)
	if (fdc_csff && fdc_wr) begin
		ff_writes = ff_writes + 1;
		if (m.cpu_do != 8'h3C) begin
			ff_bad = ff_bad + 1;
			if (ff_bad < 5) $display("%t port #FF written with %h", $time, m.cpu_do);
		end
	end

// TRDOS: the controller of the top (hrdy_fdc, the VG93 model) on the bus of the machine, and a drive: index pulses
// (20000 clocks a turn, in the simulation), track 0 at the start 1, steps on the rising STEP (DIR 1 in)
wire fd_side1, fd_wg, fd_wdata, fd_step, fd_dir, fd_motor;
wire [1:0] fd_ds;
reg [7:0] fd_track = 8'd1;
integer fd_cnt = 0, fd_steps = 0, fd_motor_clocks = 0, fd_ds0_clocks = 0;
reg fd_step_d = 1'b0;
always @(posedge clk_bus) begin
	fd_cnt = (fd_cnt == 19999) ? 0 : fd_cnt + 1;
	fd_step_d <= fd_step;
	if (fd_step && !fd_step_d) begin
		fd_steps = fd_steps + 1;
		if (fd_dir) fd_track <= fd_track + 1'd1;
		else if (fd_track != 0) fd_track <= fd_track - 1'd1;
	end
	if (fd_motor) fd_motor_clocks = fd_motor_clocks + 1;
	if (fd_ds[0]) fd_ds0_clocks = fd_ds0_clocks + 1;
end
generate
	if (`TRDOS) begin : g_fdc
		hrdy_fdc fdc(.clk(clk_bus), .ds80(1'b0), .reset(reset), .ena_cpu(`QUAD ? (cslot == 3'd0) : ce_cpu),
			.a(m.cpu_a), .d(m.cpu_do), .wr_n(~fdc_wr), .rd_n(~fdc_rd), .iorq_n(~(fdc_rd | fdc_wr)),
			.cs_n(~fdc_cs), .csff_n(~fdc_csff), .oe_n(), .dout(fdc_q), .busy(fdc_busy), .intrq_o(), .drq_o(),
			.FDC_SIDE1(fd_side1), .FDC_RDATA(1'b0), .FDC_WPRT(1'b0), .FDC_TR00(fd_track == 8'd0),
			.FDC_INDEX(fd_cnt < 200), .FDC_WG(fd_wg), .FDC_WR_DATA(fd_wdata), .FDC_STEP(fd_step), .FDC_DIR(fd_dir),
			.FDC_MOTOR(fd_motor), .FDC_DS(fd_ds));
		// trace: HLD, /MR, port #FF, commands
		reg hld_d = 1'b0, mr_d = 1'b0;
		reg [7:0] ff_d = 8'd0, cmd_d = 8'd0;
		reg wr_d = 1'b0;
		integer hev = 0;
		always @(posedge clk_bus) begin
			hld_d <= fdc.vg93_top.HLD;
			mr_d <= fdc.port_ff_reg[2] & ~reset;
			ff_d <= fdc.port_ff_reg;
			if (fdc.vg93_top.HLD != hld_d) $display("%t fdc: HLD %b", $time, fdc.vg93_top.HLD);
			if ((fdc.port_ff_reg[2] & ~reset) != mr_d) $display("%t fdc: /MR %b", $time, fdc.port_ff_reg[2] & ~reset);
			if (fdc.port_ff_reg != ff_d) $display("%t fdc: #FF %h", $time, fdc.port_ff_reg);
			if (fdc.vg93_top.task_regs.cmd_reg != cmd_d) $display("%t fdc: command %h", $time, fdc.vg93_top.task_regs.cmd_reg);
			cmd_d <= fdc.vg93_top.task_regs.cmd_reg;
			if ((fdc.vg93_top.set_hld || fdc.vg93_top.clr_hld) && hev < 40) begin
				hev = hev + 1;
				$display("%t fdc: set_hld %b clr_hld %b hld_pin %b mr_s %b", $time, fdc.vg93_top.set_hld,
					fdc.vg93_top.clr_hld, fdc.vg93_top.hld_pin, fdc.vg93_top.drive.mr_s);
			end
			if (fdc_cs && fdc_wr && !wr_d) $display("%t fdc: write #%h <- %h (busy %b)", $time, m.cpu_a[7:0], m.cpu_do, fdc_busy);
			wr_d <= fdc_cs && fdc_wr;
		end
	end else begin : g_no_fdc
		assign fdc_q = 8'hFF;
		assign fdc_busy = 1'b0;
		assign {fd_side1, fd_wg, fd_wdata, fd_step, fd_dir, fd_motor} = 6'b100000;
		assign fd_ds = 2'b00;
	end
endgenerate

wire ay_we;
wire [4:0] ay_wa;
wire [7:0] ay_wd;
pentagon #(.CPU(`QUAD ? 2 : 1)) m(
	.clk(clk_bus), .reset(reset), .pause(1'b0),
	.ce7(ce7), .ce_cpu(`QUAD ? (cslot == 3'd0) : ce_cpu), .hc(hc), .vc(vc), .int_n(int_n), .frame(frame),
	.keys(40'd0), .kempston(8'd0), .tape_in(1'b0), .beeper(beeper), .mic(mic), .nmi(1'b0), .areset(~ready), .mem1024(`MEMTEST != 0),
	.trdos_en(`TRDOS != 0), .fdc_cs(fdc_cs), .fdc_csff(fdc_csff), .fdc_rd(fdc_rd), .fdc_wr(fdc_wr),
	.fdc_q(fdc_q), .fdc_busy(fdc_busy),
	.divmmc_en(DIVMMC != 0), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
	.spi_miso(USE_SDEMU ? emu_miso : 1'b1), .sd_wait(USE_SDEMU ? emu_wait : 1'b0),
	.a_req(m_a_req), .a_we(m_a_we), .a_addr(m_a_addr), .a_din(m_a_din), .a_ack(a_ack[BANK]), .a_q(a_q[BANK*8 +: 8]),
	.b_req(m_b_req), .b_addr(m_b_addr), .b_ack(b_ack[BANK]), .b_q(b_q[BANK*8 +: 8]),
	.pix(pix), .quad(1'b0), .q_go(1'b0), .q_vc(8'd0), .q_buf(1'b0), .q_addr(6'd0), .q_word(),
	.q_brd_addr(9'd0), .q_brd(),
	.x_a(x_a), .x_do(x_do), .x_mc(x_mc), .x_ts(x_ts), .x_iorq(x_iorq), .x_noread(x_noread), .x_write(x_write),
	.x_intcycle_n(x_intcycle_n), .x_cen(x_cen), .x_wait_n(x_wait_n), .x_reset_n(x_reset_n), .x_nmi_n(x_nmi_n),
	.x_dinst(x_dinst), .x_di(x_di),
	.late(late), .nz(),
	.ay_we(ay_we), .ay_wa(ay_wa), .ay_wd(ay_wd), .ay_ra(5'd0), .ay_rd()
);

// the AY register writes of the machine (after the clearing at the reset)
always @(posedge clk_bus)
	if (ay_we && !reset && ay_wd != 8'd0)
		$display("ay write: chip %0d R%0d = %02h", ay_wa[4], ay_wa[3:0], ay_wd);

// the emulated SD card (SDEMU = 1) as in the top, with a model of img_sdc: an image of 64 MB is mounted after the
// reset; a sector request ends after SD_DELAY clocks, a read gives the bytes lba[7:0] ^ index[7:0]
parameter SD_DELAY = 2800;    // 0.1 ms (img_sdc: 5-40 ms through the MCU)
reg img_mnt = 1'b0;
reg ready_d = 1'b0;
always @(posedge clk_bus) begin
	ready_d <= ready;
	img_mnt <= ready & ~ready_d;
end
wire spi_sck, spi_mosi, spi_cs_n, emu_miso, emu_wait, hd_rd, hd_wr;
wire [31:0] hd_lba;
wire [7:0] hd_byte_out;
reg hd_busy = 1'b0, hd_done = 1'b0, hd_strobe = 1'b0;
reg [8:0] hd_addr = 9'd0;
integer hd_cnt = 0, hd_reqs = 0;
always @(posedge clk_bus) begin
	hd_done <= 1'b0;
	hd_strobe <= 1'b0;
	if (!hd_busy && (hd_rd || hd_wr)) begin
		hd_busy <= 1'b1;
		hd_cnt = 0;
		hd_reqs = hd_reqs + 1;
		$display("%t img_sdc: %s lba %0d", $time, hd_rd ? "read" : "write", hd_lba);
	end else if (hd_busy) begin
		hd_cnt = hd_cnt + 1;
		if (hd_cnt > SD_DELAY && hd_cnt <= SD_DELAY + 512) begin
			hd_strobe <= 1'b1;
			hd_addr <= hd_cnt - SD_DELAY - 1;
		end
		if (hd_cnt == SD_DELAY + 520) begin
			hd_busy <= 1'b0;
			hd_done <= 1'b1;
		end
	end
end
always @(posedge clk_bus)
	if (`SDTEST && sd_emu.xfer)
		$display("%t emu: got %h cs %b state %0d sent %h | master exch done -> %h", $time, sd_emu.tx, sd_emu.xfer_cs_n,
			sd_emu.state, sd_emu.sent, {m.spi_sr[6:0], spi_miso_tb});
wire spi_miso_tb = USE_SDEMU ? emu_miso : 1'b1;
kg_sd_emu #(.CACHE(0)) sd_emu(
	.clk(clk_bus), .reset(reset),
	.sclk(spi_sck), .mosi(spi_mosi), .cs_n(spi_cs_n), .miso(emu_miso),
	.img_mounted(img_mnt), .img_size(32'h04000000),
	.hd_rd(hd_rd), .hd_wr(hd_wr), .hd_lba(hd_lba), .hd_busy(hd_busy), .hd_done(hd_done), .hd_error(1'b0),
	.hd_byte_in_strobe(hd_strobe), .hd_byte_addr(hd_addr), .hd_byte_in_data(hd_lba[7:0] ^ hd_addr[7:0]), .hd_byte_out_data(hd_byte_out),
	.waiting(emu_wait)
);

wire m_a_req, m_a_we, m_b_req;
wire [22:0] m_a_addr, m_b_addr;
wire [7:0] m_a_din;
assign a_req = {3'b000, m_a_req} << BANK;
assign a_we = {3'b000, m_a_we} << BANK;
assign a_addr = {69'd0, m_a_addr} << (23 * BANK);
assign a_din = {24'd0, m_a_din} << (8 * BANK);
assign b_req = {3'b000, m_b_req} << BANK;
assign b_addr = {69'd0, m_b_addr} << (23 * BANK);

// the data bus of the interrupt acknowledge: every CPU clock of T2 (the T80 takes the IM2 vector there)
integer intacks = 0, intack_bad = 0;
always @(posedge clk_bus)
	if (!reset && m.cpu_cen && m.cpu_mc == 3'd1 && !m.cpu_intcycle_n && m.cpu_ts == 3'd2) begin
		intacks = intacks + 1;
		if (m.cpu_di !== 8'hFF || !m.cpu_wait_n) begin
			intack_bad = intack_bad + 1;
			if (intack_bad < 20)
				$display("%t intack: di %h wait_n %b", $time, m.cpu_di, m.cpu_wait_n);
		end
	end

// the margin of the CPU reads: clk_bus clocks between the answer of the SDRAM (a_busy falls) and the CPU clock that
// takes the data (end of T2); the smallest of the run
integer bus_clk = 0, ack_at = 0, margin_min = 1000, margin_sum = 0, margin_n = 0;
integer margin_hist [0:20];
integer mh;
initial for (mh = 0; mh <= 20; mh = mh + 1) margin_hist[mh] = 0;
reg busy_d = 1'b0;
always @(posedge clk_bus) begin
	bus_clk = bus_clk + 1;
	busy_d <= m.a_busy;
	if (busy_d && !m.a_busy)
		ack_at = bus_clk;
	if (!reset && m.cpu_cen && m.cpu_ts == 3'd2 && m.rd_cycle && m.cpu_wait_n) begin
		if (bus_clk - ack_at < margin_min)
			margin_min = bus_clk - ack_at;
		margin_hist[(bus_clk - ack_at) > 20 ? 20 : (bus_clk - ack_at)] = margin_hist[(bus_clk - ack_at) > 20 ? 20 : (bus_clk - ack_at)] + 1;
	end
end

// the opcode fetches
reg [15:0] last_pc = 16'd0;
integer fetches = 0;
always @(posedge clk_bus)
	if (m.cen_d && m.cpu_ts == 3'd1 && m.cpu_mc == 3'd1 && !reset) begin
		last_pc <= m.cpu_a;
		fetches = fetches + 1;
	end

// a read must return what the model holds: compare the data the CPU takes with the model
integer data_errors = 0;
integer checked = 0;
reg [22:0] chk_addr;
reg [15:0] word;
always @(posedge clk_bus)
	if (!reset && m.cpu_cen && m.cpu_ts == 3'd2 && m.cpu_wait_n && m.rd_cycle) begin
		chk_addr = m.a_addr;
		word = chip.mem[BOFS + chk_addr[22:1]];
		checked = checked + 1;
		// the byte the CPU takes (cpu_di, after the data mux), not only the one of the SDRAM
		if ((chk_addr[0] ? word[15:8] : word[7:0]) !== m.cpu_di) begin
			data_errors = data_errors + 1;
			if (data_errors < 10)
				$display("%t read %h: cpu got %h, model has %h", $time, chk_addr, m.cpu_di, chk_addr[0] ? word[15:8] : word[7:0]);
		end
	end

// ISim has no $writememh
task dump;
	input [8*16-1:0] name;
	input integer start;
	integer f, n;
	begin
		f = $fopen(name, "w");
		for (n = 0; n < 3456; n = n + 1)
			$fdisplay(f, "%h", chip.mem[BOFS + start + n]);
		$fclose(f);
	end
endtask

integer frames_done = 0;
integer errors;
reg vc0_d = 1'b0;
always @(posedge clk_bus) begin
	vc0_d <= (vc == 9'd0);
	if (vc == 9'd0 && !vc0_d && !reset) begin
		frames_done = frames_done + 1;
		if (frames_done == `RESET_AT) begin
			warm <= 1'b1;
			warm_cnt = 0;
			$display("%t warm reset", $time);
		end
		$display("%t frame %0d: pc %h, fetches %0d, checked reads %0d, sdram r %0d w %0d rfsh %0d, model errors %0d, late %b, 7ffd %h",
			$time, frames_done, last_pc, fetches, checked, chip.reads, chip.writes, chip.refreshes,
			chip.errors, late, m.p7ffd);
		if (frames_done == FRAMES) begin
			if (`SDTEST) begin : sdt
				integer i;
				reg [7:0] b;
				$write("sdtest done %h:", chip.mem[BOFS + ('h9200 >> 1)][7:0]);
				for (i = 'h9000; i < 'h9160; i = i + 1) begin
					if (i % 16 == 0) $write("%c%h:", 8'd10, i[15:0]);
					b = i[0] ? chip.mem[BOFS + (('h08000 + (i - 'h8000)) >> 1)][15:8] : chip.mem[BOFS + (('h08000 + (i - 'h8000)) >> 1)][7:0];
					$write(" %h", b);
				end
				$write("%c", 8'd10);
			end
			dump("screen5.hex", 'hA000);
			dump("screen7.hex", 'hE000);
			errors = chip.errors + data_errors + (late ? 1 : 0) + (fetches < 1000 ? 1 : 0);
			$display("p7ffd %h border %h; DivMMC: rom fetches %0d, ram accesses %0d, spi exchanges %0d, e3 %b%b %h",
				m.p7ffd, m.border, dv_fetches, dv_ram, eb_xfers, m.dv_conmem, m.dv_mapram, m.dv_bank);
			if (DIVMMC && !`CUSTOM_ROM && (dv_fetches < 1000 || eb_xfers < 10))   // ESXDOS (not a test ROM)
				errors = errors + 1;
			$display("intack: %0d T2 clocks, %0d not FF; interrupts counted by the handler: %0d", intacks, intack_bad,
				{chip.mem[BOFS + (('h08000 + 'h1000) >> 1)]});
			errors = errors + intack_bad;
			if (`MEMTEST) begin : memtest_check
				reg [7:0] t0, t1;
				t0 = chip.mem[BOFS + ('h9000 >> 1)][7:0];
				t1 = chip.mem[BOFS + ('h9000 >> 1)][15:8];
				$display("memtest: bad pages %0d (0), end %h (77)", t0, t1);
				if (t0 != 0 || t1 != 8'h77)
					errors = errors + 1;
			end
			if (`TRDOS) begin : trdos_check
				reg [7:0] t [0:4];
				reg [7:0] t5, t6, t7;
				integer k;
				for (k = 0; k < 5; k = k + 1)
					t[k] = (k & 1) ? chip.mem[BOFS + (('h9000 + k) >> 1)][15:8] : chip.mem[BOFS + (('h9000 + k) >> 1)][7:0];
				t5 = chip.mem[BOFS + ('h9005 >> 1)][15:8];
				t6 = chip.mem[BOFS + ('h9006 >> 1)][7:0];
				t7 = chip.mem[BOFS + ('h9006 >> 1)][15:8];
				$display("trdos: back to back writes: sector %h (11), track %h (22); waits %0d clocks", t6, t7, fdc_wait_clocks);
				if (t6 != 8'h11 || t7 != 8'h22 || fdc_wait_clocks == 0)
					errors = errors + 1;
				$display("trdos: in TR-DOS #1F %h (0) %h; after #1F %h (0) %h; end %h", t[0], t[3], t[1], t[2], t[4]);
				$display("trdos: port #FF: %0d clocks written, %0d with another byte", ff_writes, ff_bad);
				$display("trdos: RESTORE: status %h, track %0d, %0d steps, motor %0d clocks, drive A %0d clocks",
					t5, fd_track, fd_steps, fd_motor_clocks, fd_ds0_clocks);
				// status after RESTORE with head load: ready (bit 7 = 0), head loaded (5), track 0 (2), no seek error (4), not busy (0)
				if (t5[7] || !t5[5] || t5[2] != 1'b1 || t5[4] || t5[0] || fd_track != 0 || fd_steps < 1 || fd_ds0_clocks == 0)
					errors = errors + 1;
				if (ff_writes == 0 || ff_bad != 0)
					errors = errors + 1;
				if (t[0] == 8'h00 || t[0] == 8'hFF || t[3] != 8'hAA || t[1] != 8'h00 || t[2] != 8'hF3 || t[4] != 8'h77)
					errors = errors + 1;
			end
			$write("read margin (clk_bus clocks from the answer to the CPU clock): min %0d; histogram", margin_min);
			for (mh = 0; mh <= 20; mh = mh + 1) $write(" %0d", margin_hist[mh]);
			$write("%c", 8'd10);
			$display("9000 / 9001 (AY R8 read back from chip 0 / 1): %02h %02h", chip.mem[BOFS + ('h9000 >> 1)][7:0], chip.mem[BOFS + ('h9000 >> 1)][15:8]);
			$display("tb_pentagon: %0d errors", errors);
			$finish;
		end
	end
end

endmodule
