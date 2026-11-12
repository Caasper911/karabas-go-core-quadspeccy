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
`ifndef DIVMMC
`define DIVMMC 1
`endif
parameter DIVMMC = `DIVMMC;
`ifndef SDEMU
`define SDEMU 0
`endif
parameter USE_SDEMU = `SDEMU;
`ifndef SDTEST
`define SDTEST 0
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
	.a_req(a_req), .a_ack(a_ack), .a_we(a_we), .a_addr(a_addr), .a_din(a_din), .a_q(a_q),
	.b_req(b_req), .b_ack(b_ack), .b_addr(b_addr), .b_q(b_q),
	.ready(ready),
	.SDR_CLK(sdr_clk), .SDR_BA(sdr_ba), .SDR_A(sdr_a), .SDR_DQM(sdr_dqm),
	.SDR_RAS_N(sdr_ras_n), .SDR_CAS_N(sdr_cas_n), .SDR_WE_N(sdr_we_n), .SDR_DQ(sdr_dq)
);

sdram_model #(.ROWS(1024), .RB(10)) chip(
	.clk(sdr_clk), .ba(sdr_ba), .a(sdr_a), .dqm(sdr_dqm),
	.ras_n(sdr_ras_n), .cas_n(sdr_cas_n), .we_n(sdr_we_n), .dq(sdr_dq)
);

// 128, 48, TR-DOS (FF), ESXDOS from 0x20000 (word 0x10000)
initial $readmemh("roms.hex", chip.mem, 'h10000, 'h16FFF);

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

pentagon m(
	.clk(clk_bus), .reset(reset), .pause(1'b0),
	.ce7(ce7), .ce_cpu(ce_cpu), .hc(hc), .vc(vc), .int_n(int_n), .frame(frame),
	.keys(40'd0), .kempston(8'd0), .tape_in(1'b0), .beeper(beeper), .mic(mic), .nmi(1'b0), .areset(~ready),
	.divmmc_en(DIVMMC != 0), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
	.spi_miso(USE_SDEMU ? emu_miso : 1'b1), .sd_wait(USE_SDEMU ? emu_wait : 1'b0),
	.a_req(a_req[0]), .a_we(a_we[0]), .a_addr(a_addr[22:0]), .a_din(a_din[7:0]), .a_ack(a_ack[0]), .a_q(a_q[7:0]),
	.b_req(b_req[0]), .b_addr(b_addr[22:0]), .b_ack(b_ack[0]), .b_q(b_q[7:0]),
	.pix(pix), .quad(1'b0), .q_go(1'b0), .q_vc(8'd0), .q_buf(1'b0), .q_addr(6'd0), .q_word(),
	.q_brd_addr(9'd0), .q_brd(), .late(late), .nz()
);

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

assign a_req[3:1] = 3'b000;
assign a_we[3:1] = 3'b000;
assign a_addr[4*23-1:23] = 0;
assign a_din[4*8-1:8] = 0;
assign b_req[3:1] = 3'b000;
assign b_addr[4*23-1:23] = 0;

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
		word = chip.mem[chk_addr[22:1]];
		checked = checked + 1;
		if ((chk_addr[0] ? word[15:8] : word[7:0]) !== m.a_q) begin
			data_errors = data_errors + 1;
			if (data_errors < 10)
				$display("%t read %h: cpu got %h, model has %h", $time, chk_addr, m.a_q, chk_addr[0] ? word[15:8] : word[7:0]);
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
			$fdisplay(f, "%h", chip.mem[start + n]);
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
				$write("sdtest done %h:", chip.mem['h9200 >> 1][7:0]);
				for (i = 'h9000; i < 'h9160; i = i + 1) begin
					if (i % 16 == 0) $write("%c%h:", 8'd10, i[15:0]);
					b = i[0] ? chip.mem[('h08000 + (i - 'h8000)) >> 1][15:8] : chip.mem[('h08000 + (i - 'h8000)) >> 1][7:0];
					$write(" %h", b);
				end
				$write("%c", 8'd10);
			end
			dump("screen5.hex", 'hA000);
			dump("screen7.hex", 'hE000);
			errors = chip.errors + data_errors + (late ? 1 : 0) + (fetches < 1000 ? 1 : 0);
			$display("p7ffd %h border %h; DivMMC: rom fetches %0d, ram accesses %0d, spi exchanges %0d, e3 %b%b %h",
				m.p7ffd, m.border, dv_fetches, dv_ram, eb_xfers, m.dv_conmem, m.dv_mapram, m.dv_bank);
			if (DIVMMC && (dv_fetches < 1000 || eb_xfers < 10))
				errors = errors + 1;
			$display("tb_pentagon: %0d errors", errors);
			$finish;
		end
	end
end

endmodule
