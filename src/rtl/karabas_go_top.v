`timescale 1ns / 1ps
`default_nettype none

/*
 karabas_go_top.v

 Quad Speccy for Karabas Go: up to four Pentagon 128 running side by side, each in its own SDRAM
 bank (docs/ARCHITECTURE.md). NUM_MACHINES = 4; the quad view (video_out) after power on,
 Win + ` switches to the selected machine full screen and back.

 Clocks (one PLL on CLK_50MHZ, VCO 925 MHz, phase 0, as TS-Conf):
   clk_sys 84.09 MHz (/11)  the SDRAM controller
   clk_bus 28.03 MHz (/33)  the machines, video, MCU link, OSD; clk_sys / 3, every edge of clk_bus
                            is an edge of clk_sys

 Hotkeys (zx_kbd): Win + 1..4 the machine that has the keyboard, Win + ` full screen / quad.
 OSD (core.json "osd", the "index" of the items): 0 joystick L, 1 joystick R, 2 pause, 3 reset of the
 selected machine (Win+F12), 4 reset of all (F12), 5 colour of the frame of the selected machine in the
 quad view (ZX colour, default 4 green), 6 NMI of the selected machine (Win+F11), per machine n on its
 page "Core n+1": 7 + 2n DivMMC on (default on), 8 + 2n SD card: the card of the board / the image
 (default image), and the F item of the image, slot n of the file mounter.

 DivMMC (docs/ARCHITECTURE.md): the SPI of machine n goes to the card of the board (SD_*) when it chose
 it and is the lowest such machine (one owner: the others see no card), else to kg_sd_emu n on the image
 of slot n (img_sdc, one request at a time for all four).

 ROM loader: the MCU address bits 17..16 are the machine, 15..0 the offset in its ROM area
 (16 KB per ROM: 0 the 128 editor, 1 48 BASIC); the bytes go through a FIFO to channel A of the
 bank while the machines are held in reset.
*/

module karabas_go_top #(
	parameter NUM_MACHINES = 4
) (
	input wire CLK_50MHZ,

	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

	output wire SD_CS_N,
	output wire SD_CLK,
	inout wire SD_DI,
	inout wire SD_DO,
	input wire SD_DET_N,

	output wire [7:0] VGA_R,
	output wire [7:0] VGA_G,
	output wire [7:0] VGA_B,
	output wire VGA_HS,
	output wire VGA_VS,
	output wire V_CLK,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	output wire FT_OE_N,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,

	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire BEEPER,

	output wire DAC_LRCK,
	output wire DAC_DAT,
	output wire DAC_BCK,
	output wire DAC_MUTE,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	input wire MCU_SPI_FT_CS_N,
	input wire MCU_SPI_SD2_CS_N,
	inout wire [1:0] MCU_SPI_IO,

	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,

	output wire FLASH_CS_N,
	input wire FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N
);

// ---------------------------------------------------------------------------------------------
// unused parts of the board: idle

assign UART_RX = 1'bZ;
assign UART_TX = 1'bZ;
assign UART_CTS = 1'bZ;
assign ESP_RESET_N = 1'bZ;
assign ESP_BOOT_N = 1'bZ;

assign MA = 21'd0;
assign MD = 16'bZZZZZZZZZZZZZZZZ;
assign MWR_N = 2'b11;
assign MRD_N = 2'b11;

assign SD_DO = 1'bZ;     // MISO of the card (SD_DI is MOSI, SD_CLK, SD_CS_N: the DivMMC section)

assign WA = 3'd0;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bZZZZZZZZZZZZZZZZ;

assign FDC_DRIVE = 2'b11;
assign FDC_MOTOR = 1'b1;
assign FDC_DIR = 1'b1;
assign FDC_STEP = 1'b1;
assign FDC_WDATA = 1'b1;
assign FDC_WGATE = 1'b1;
assign FDC_SIDE_N = 1'b1;

assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b0;
assign MIDI_RESET_N = 1'b0;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

// ---------------------------------------------------------------------------------------------
// clocks

wire clk_sys, clk_bus, locked;
wire [5:0] pll_clk;

// VCO 50 * 37 / 2 = 925 MHz: clk_sys 84.09 MHz (/11), clk_bus 28.03 MHz (/33)
kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(33),
	.BUFG_MASK(6'b000001)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(locked)
);
assign clk_sys = pll_clk[0];
// the BUFG here: the net clk_bus of the ucf
BUFG bufg_clk_bus(.I(pll_clk[1]), .O(clk_bus));

wire areset = ~locked;

// V_CLK of the video DAC (TS-Conf bus_ce)
wire ce_28m, v_clk;
bus_ce bus_ce(.clk_sys(clk_sys), .clk_bus(clk_bus), .ce(ce_28m), .v_clk(v_clk));

// ---------------------------------------------------------------------------------------------
// MCU

wire [7:0] kb_status, kb_dat0, kb_dat1, kb_dat2, kb_dat3, kb_dat4, kb_dat5;
wire [12:0] joy_l, joy_r;
wire [1:0] hw_btn;
wire [15:0] softsw_command, osd_command;
wire loader_act;
wire [31:0] loader_addr;
wire [7:0] loader_data;
wire loader_wr;
wire mcu_busy;
wire mcu_ft_spi_on, mcu_ft_vga_on, mcu_ft_sck, mcu_ft_mosi, mcu_ft_cs_n;
wire mcu_burst_ready;
// the file mounter (the images of the emulated SD cards, slot n = machine n)
wire [7:0] img_mounted;
wire [63:0] img_size;
wire img_data_wr, img_result_wr, img_q_wr, img_q_ack;
wire [8:0] img_data_addr;
wire [7:0] img_data, img_result;
wire [15:0] img_sum;
wire [23:0] img_q_di;

assign MCU_SPI_IO[0] = mcu_burst_ready;
assign MCU_SPI_IO[1] = 1'bZ;

kg_mcu #(
	.BURST_MAX_MHZ(0),
	.CS_FILTER(3),
	.ENABLE_RTC(0),
	.ENABLE_UART(0),
	.ENABLE_MATRIX(0),
	.ENABLE_DEBUG(0),
	.ENABLE_IMG(1),
	.ENABLE_FILE(0),
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu (
	.CLK(clk_bus),
	.N_RESET(~areset),

	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SCK(MCU_SCK),
	.MCU_SS(MCU_CS_N),
	.MCU_SPI_FT_SS(MCU_SPI_FT_CS_N),
	.MCU_SPI_SD2_SS(MCU_SPI_SD2_CS_N),
	// burst transfers: firmware IO0 = MCU_SPI_IO[1] (M11), IO1 = MCU_SPI_IO[0] (N9)
	.MCU_BURST_CS_N(MCU_SPI_IO[1]),
	.MCU_BURST_READY(mcu_burst_ready),

	.MS_X(), .MS_Y(), .MS_Z(), .MS_B(), .MS_UPD(),

	.KB_STATUS(kb_status),
	.KB_DAT0(kb_dat0),
	.KB_DAT1(kb_dat1),
	.KB_DAT2(kb_dat2),
	.KB_DAT3(kb_dat3),
	.KB_DAT4(kb_dat4),
	.KB_DAT5(kb_dat5),
	.KB_SCANCODE(), .KB_SCANCODE_UPD(),
	.XT_SCANCODE(), .XT_SCANCODE_UPD(),
	.PS2_COMMAND(16'd0), .PS2_COMMAND_WR(1'b0),

	.JOY_L(joy_l),
	.JOY_R(joy_r),
	.BTNS(hw_btn),

	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_DO(), .RTC_CS(1'b0), .RTC_WR_N(1'b1),

	.UART_RX_DATA(), .UART_RX_IDX(),
	.UART_TX_DATA(8'd0), .UART_TX_WR(1'b0), .UART_TX_MODE(1'b0),
	.UART_DLM(8'd0), .UART_DLL(8'd0), .UART_DLM_WR(1'b0), .UART_DLL_WR(1'b0),

	.SOFTSW_COMMAND(softsw_command),
	.OSD_COMMAND(osd_command),

	.ROMLOADER_ACTIVE(loader_act),
	.ROMLOAD_ADDR(loader_addr),
	.ROMLOAD_DATA(loader_data),
	.ROMLOAD_WR(loader_wr),
	.IOCTL_ACTIVE(),
	.FILELOAD_RESET(), .FILELOAD_ACTIVE(), .FILELOAD_SIZE(), .FILELOAD_ADDR(), .FILELOAD_DATA(),
	.FILELOAD_WR(),

	.FT_SPI_ON(mcu_ft_spi_on),
	.FT_VGA_ON(mcu_ft_vga_on),
	.FT_RESET(),
	.FT_SCK(mcu_ft_sck),
	.FT_MOSI(mcu_ft_mosi),
	.FT_MISO(FT_SPI_MISO),
	.FT_CS_N(mcu_ft_cs_n),

	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N(),

	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0),
	.DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),

	.HWID(), .DVI_ONLY(), .CORE_BUILD(), .FW_BUILD(),

	.IMG_MOUNTED(img_mounted), .IMG_SIZE(img_size), .IMG_DATA_WR(img_data_wr), .IMG_DATA_ADDR(img_data_addr),
	.IMG_DATA(img_data), .IMG_RESULT_WR(img_result_wr), .IMG_RESULT(img_result), .IMG_SUM(img_sum),
	.IMG_Q_WR(img_q_wr), .IMG_Q_DI(img_q_di), .IMG_Q_ACK(img_q_ack), .IMG_PHYS_WR(),
	.IMG_PHYS(), .IMG_FLUSH(), .IMG_WP(),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .FDD_CHNG_WR(), .FDD_CHNG(),

	.ESP_UART_TX_DATA(), .ESP_UART_TX_WR(), .ESP_UART_RX_DATA(8'd0), .ESP_UART_RX_WR(1'b0),
	.FLASHBOOT_START(1'b0), .FLASHBOOT_COREID(5'd0),
	.PRN_DATA(8'd0), .PRN_WR(1'b0),

	.BUSY(mcu_busy)
);

// FT812: only the MCU uses it
assign FT_SPI_CS_N = mcu_ft_spi_on ? mcu_ft_cs_n : 1'b1;
assign FT_SPI_SCK = mcu_ft_spi_on ? mcu_ft_sck : 1'b0;
assign FT_SPI_MOSI = mcu_ft_spi_on ? mcu_ft_mosi : 1'b0;
assign FT_OE_N = mcu_ft_vga_on ? 1'b0 : 1'b1;

// ---------------------------------------------------------------------------------------------
// soft switches

// 7..14: per machine n: 7 + 2n DivMMC on, 8 + 2n SD card (0 the card of the board, 1 the image)
wire [19*8-1:0] softsw;
kg_soft_switches #(.N(19), .INIT(152'h00_00_00_00_01_01_01_01_01_01_01_01_00_04_00_00_00_01_00)) soft_switches(
	.clk(clk_bus),
	.command(softsw_command),
	.regs(softsw),
	.upd()
);

wire [2:0] joy_type_l = softsw[2:0];
wire [2:0] joy_type_r = softsw[10:8];
wire sw_pause = softsw[16];
wire sw_reset = softsw[24];
wire sw_reset_all = softsw[32];
wire [2:0] sw_frame_col = softsw[42:40];
wire sw_nmi = softsw[48];
wire [3:0] sw_divmmc = {softsw[13*8], softsw[11*8], softsw[9*8], softsw[7*8]};
wire [3:0] sw_sd_img = {softsw[14*8], softsw[12*8], softsw[10*8], softsw[8*8]};
wire [3:0] sw_acb = {softsw[18*8], softsw[17*8], softsw[16*8], softsw[15*8]};   // AY mix of machine n: 0 ABC, 1 ACB

// ---------------------------------------------------------------------------------------------
// keyboard

wire [39:0] kbd_keys;
wire [7:0] kbd_kempston;
wire [1:0] kbd_sel;
wire kbd_full_tgl;

zx_kbd kbd(
	.clk(clk_bus),
	.reset(areset),
	.kb_status(kb_status),
	.kb_dat0(kb_dat0),
	.kb_dat1(kb_dat1),
	.kb_dat2(kb_dat2),
	.kb_dat3(kb_dat3),
	.kb_dat4(kb_dat4),
	.kb_dat5(kb_dat5),
	.joy_type_l(joy_type_l),
	.joy_type_r(joy_type_r),
	.joy_l(joy_l),
	.joy_r(joy_r),
	.keys(kbd_keys),
	.kempston(kbd_kempston),
	.sel(kbd_sel),
	.full_tgl(kbd_full_tgl)
);

// the machine with the keyboard (machines that are not built are not selected)
wire [1:0] sel = (kbd_sel < NUM_MACHINES) ? kbd_sel : 2'd0;

// full screen of the selected machine / quad view (Win + `); the quad view after power on
reg full = 1'b0;
always @(posedge clk_bus)
	if (kbd_full_tgl)
		full <= ~full;

// ---------------------------------------------------------------------------------------------
// SDRAM

wire sdram_ready;
wire [3:0] a_req, a_ack, a_we, b_req, b_ack;
wire [4*23-1:0] a_addr, b_addr;
wire [4*8-1:0] a_din, a_q, b_q;

sdram_ctrl sdram(
	.clk(clk_sys),
	.clk_bus(clk_bus),
	.a_req(a_req), .a_ack(a_ack), .a_we(a_we), .a_addr(a_addr), .a_din(a_din), .a_q(a_q),
	.b_req(b_req), .b_ack(b_ack), .b_addr(b_addr), .b_q(b_q),
	.ready(sdram_ready),
	.SDR_CLK(SDR_CLK),
	.SDR_BA(SDR_BA),
	.SDR_A(SDR_A),
	.SDR_DQM(SDR_DQM),
	.SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N),
	.SDR_WE_N(SDR_WE_N),
	.SDR_DQ(SDR_DQ)
);

reg sdram_ready_b = 1'b0;
always @(posedge clk_bus)
	sdram_ready_b <= sdram_ready;

// ---------------------------------------------------------------------------------------------
// ROM loader: MCU -> FIFO -> channel A of the bank (machines in reset)
// Channel A of a bank is shared by toggles: the controller sees cpu_req ^ ld_req, each side sees
// the ack through the other's toggle (only one of them is active at a time).

wire [3:0] cpu_req, cpu_we;
wire [4*23-1:0] cpu_addr;
wire [4*8-1:0] cpu_din;
reg [3:0] ld_req = 4'b0000;
reg [22:0] ld_addr = 23'd0;
reg [7:0] ld_din = 8'd0;
reg [1:0] ld_bank = 2'd0;

wire ld_fifo_empty;
wire [25:0] ld_fifo_q;
reg ld_fifo_rd = 1'b0;
reg [1:0] ld_st = 2'd0;

// 256 words (one RAMB8; with 512 in a RAMB16 map crashed in its global placement): the MCU sends in bursts and has no flow control; a byte that finds the FIFO full is lost
// (ld_ovf, sticky: square 2 of the diagnostics red). With 16 words the ESXDOS ROM of machine 4, the last file, came
// broken after the ports of sdram_ctrl went to clk_bus (a longer loop per byte).
wire ld_fifo_full;
reg ld_ovf = 1'b0;
kg_fifo #(.DW(26), .AW(8)) ld_fifo(
	.clk(clk_bus),
	.reset(areset),
	.wr(loader_wr && loader_act && loader_addr[31:18] == 14'd0),
	.din({loader_addr[17:0], loader_data}),
	.full(ld_fifo_full),
	.rd(ld_fifo_rd),
	.dout(ld_fifo_q),
	.empty(ld_fifo_empty),
	.count()
);

// a bank is busy while the controller has not answered its request (the loader's, or the CPU's: one side only)
wire [3:0] ld_busy = ld_req ^ a_ack ^ cpu_req;
always @(posedge clk_bus)
	if (loader_wr && loader_act && ld_fifo_full)
		ld_ovf <= 1'b1;
// the loader's own requests in flight: ld_busy alone also holds the CPU's requests, so ld_hold on it would
// reset the machine at its first memory read (found on the board: the machine never ran)
reg [3:0] ld_out = 4'b0000;

always @(posedge clk_bus) begin
	ld_fifo_rd <= 1'b0;
	ld_out <= ld_out & ld_busy;
	case (ld_st)
		2'd0: if (!ld_fifo_empty && sdram_ready_b) begin
			ld_fifo_rd <= 1'b1;
			ld_st <= 2'd1;
		end
		2'd1: ld_st <= 2'd2;   // dout is valid in the clock after rd
		default: begin
			ld_bank <= ld_fifo_q[25:24];
			ld_addr <= {5'd0, 2'b10, ld_fifo_q[23:8]};
			ld_din <= ld_fifo_q[7:0];
			if (!ld_busy[ld_fifo_q[25:24]]) begin
				ld_req[ld_fifo_q[25:24]] <= ~ld_req[ld_fifo_q[25:24]];
				ld_out[ld_fifo_q[25:24]] <= 1'b1;
				ld_st <= 2'd0;
			end
		end
	endcase
end

// the loader owns channel A while it has work (and the machines are in reset for it)
wire ld_hold = loader_act | mcu_busy | ~ld_fifo_empty | (ld_st != 2'd0) | (|ld_out) | ~sdram_ready_b;

genvar gi;
generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_cha
		assign a_req[gi] = cpu_req[gi] ^ ld_req[gi];
		assign a_we[gi] = ld_hold ? 1'b1 : cpu_we[gi];
		assign a_addr[gi*23 +: 23] = ld_hold ? ld_addr : cpu_addr[gi*23 +: 23];
		assign a_din[gi*8 +: 8] = ld_hold ? ld_din : cpu_din[gi*8 +: 8];
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// machines

wire ce7, ce_cpu, ce14, int_n, vga_half;
wire [8:0] hc, vc, vga_x;
wire [9:0] vga_p, vga_l;
wire [4:0] frame;

zx_timing timing(
	.clk(clk_bus),
	.reset(areset),
	.ce7(ce7),
	.ce_cpu(ce_cpu),
	.ce14(ce14),
	.hc(hc),
	.vc(vc),
	.int_n(int_n),
	.frame(frame),
	.vga_x(vga_x),
	.vga_half(vga_half),
	.vga_p(vga_p),
	.vga_l(vga_l)
);

// quad view: line requests from video_out, the line buffers and border memories of the machines
wire [1:0] q_go;
wire [7:0] q_vc;
wire q_buf;
wire [5:0] q_addr;
wire [8:0] q_brd_addr;
wire [4*16-1:0] q_words;
wire [4*3-1:0] q_brds;

wire [3:0] m_beeper, m_mic, m_late, m_nz;
wire [3:0] m_ay_we;
wire [4*5-1:0] m_ay_wa;
wire [4*8-1:0] m_ay_wd, m_ay_rd;
wire [4:0] ay_ra;

// ---------------------------------------------------------------------------------------------
// the CPUs: one tv80_quad for the four machines (docs/ARCHITECTURE.md). Slot cs of the 8 clocks of a T-state: machine
// k has the cen of its CPU in slot 2k (machine 0 in the clock of ce_cpu), the peek of it in 2k+1.

// the raster of each machine, 2k clocks after the one of zx_timing as its CPU (raster_delay.v)
wire [3:0] r_ce7, r_int_n;
wire [4*9-1:0] r_hc, r_vc;
wire [4*5-1:0] r_frame;
generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_rd
		raster_delay #(.D(2 * gi)) rd (
			.clk(clk_bus), .ce7_i(ce7), .hc_i(hc), .vc_i(vc), .int_n_i(int_n), .frame_i(frame),
			.ce7(r_ce7[gi]), .hc(r_hc[gi*9 +: 9]), .vc(r_vc[gi*9 +: 9]), .int_n(r_int_n[gi]), .frame(r_frame[gi*5 +: 5])
		);
	end
endgenerate

reg [2:0] cslot = 3'd0;
always @(posedge clk_bus)
	cslot <= ce_cpu ? 3'd1 : cslot + 1'd1;
wire [3:0] ce_m = {cslot == 3'd6, cslot == 3'd4, cslot == 3'd2, cslot == 3'd0};

wire [4*16-1:0] q_a;
wire [4*8-1:0] q_do, q_dinst, q_di;
wire [4*7-1:0] q_mc, q_ts;
wire [3:0] q_iorq, q_noread, q_write, q_intcycle_n;
wire [3:0] q_cen, q_wait_n, q_reset_n, q_nmi_n;

tv80_quad #(.Mode(0), .IOWait(1)) cpus (
	.clk(clk_bus),
	.slot(cslot),
	.reset_n(q_reset_n),
	.cen(q_cen),
	.wait_n(q_wait_n),
	.int_n(r_int_n),
	.nmi_n(q_nmi_n),
	.dinst(q_dinst),
	.di(q_di),
	.A(q_a),
	.dout(q_do),
	.mc(q_mc),
	.ts(q_ts),
	.m1_n(),
	.iorq(q_iorq),
	.no_read(q_noread),
	.write(q_write),
	.intcycle_n(q_intcycle_n),
	.halt_n()
);

// ---------------------------------------------------------------------------------------------
// DivMMC: the SD cards

wire [3:0] spi_sck, spi_mosi, spi_cs_n, spi_miso, sd_wait, emu_miso, emu_wait, hd_rd, hd_wr;
wire [4*32-1:0] hd_lba;
wire [4*8-1:0] hd_byte_out;

// the card of the board: the lowest machine with the DivMMC on and the SD card "Real"
wire [3:0] want_real = sw_divmmc & ~sw_sd_img;
wire [1:0] real_owner = want_real[0] ? 2'd0 : want_real[1] ? 2'd1 : want_real[2] ? 2'd2 : 2'd3;
wire real_on = |want_real;

reg sd_miso_r = 1'b1;
always @(posedge clk_bus)
	sd_miso_r <= SD_DO;

assign SD_CLK = real_on ? spi_sck[real_owner] : 1'b0;
assign SD_DI = real_on ? spi_mosi[real_owner] : 1'b1;
assign SD_CS_N = real_on ? spi_cs_n[real_owner] : 1'b1;

generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_sd
		// the image: the emulated card; the card of the board: its owner gets it, the others no card (FF)
		assign spi_miso[gi] = sw_sd_img[gi] ? emu_miso[gi] : (real_on && real_owner == gi) ? sd_miso_r : 1'b1;
		assign sd_wait[gi] = sw_sd_img[gi] & emu_wait[gi];
	end
endgenerate

// the file mounter: one request at a time, the lowest slot first (img_sdc takes the sector with it)
wire sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_byte_in_data, sdc_img_mounted;
wire [63:0] sdc_img_size;
wire [3:0] hd_req = hd_rd | hd_wr;
wire [1:0] hd_first = hd_req[0] ? 2'd0 : hd_req[1] ? 2'd1 : hd_req[2] ? 2'd2 : 2'd3;

img_sdc #(.OUT_LATENCY(3), .TIMEOUT(24'd5600000)) sdc(
	.clk(clk_bus),
	.reset(1'b0),
	.img_mounted(img_mounted), .img_size(img_size), .img_data_wr(img_data_wr), .img_data_addr(img_data_addr),
	.img_data(img_data), .img_result_wr(img_result_wr), .img_result(img_result), .img_sum(img_sum),
	.img_q_wr(img_q_wr), .img_q_di(img_q_di), .img_q_ack(img_q_ack),
	.sdc_img_mounted(sdc_img_mounted), .sdc_img_size(sdc_img_size),
	.sdc_rd({4'd0, hd_rd}), .sdc_wr({4'd0, hd_wr}),
	.sdc_sector(hd_lba[hd_first*32 +: 32]),
	.sdc_busy(sdc_busy), .sdc_done(sdc_done), .sdc_error(sdc_error), .sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_byte_in_strobe), .sdc_byte_addr(sdc_byte_addr), .sdc_byte_in_data(sdc_byte_in_data),
	.sdc_byte_out_data(hd_byte_out[sdc_slot[1:0]*8 +: 8]),
	.active()
);
wire [4*4-1:0] m_pix;

generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_m
		if (gi < NUM_MACHINES) begin : g_on
			reg m_reset = 1'b1;
			always @(posedge clk_bus)
				m_reset <= areset | ld_hold | sw_reset_all | hw_btn[1] | ((sw_reset | hw_btn[0]) && sel == gi);

			pentagon #(.CPU(2)) m(
				.clk(clk_bus),
				.reset(m_reset),
				.pause(sw_pause),
				.ce7(r_ce7[gi]),
				.ce_cpu(ce_m[gi]),
				.hc(r_hc[gi*9 +: 9]),
				.vc(r_vc[gi*9 +: 9]),
				.int_n(r_int_n[gi]),
				.frame(r_frame[gi*5 +: 5]),
				.keys(sel == gi ? kbd_keys : 40'd0),
				.kempston(sel == gi ? kbd_kempston : 8'd0),
				.tape_in(TAPE_IN),
				.nmi(sw_nmi && sel == gi),
				// power on for the DivMMC (a reset keeps its state): the start of the core and the ROM loading
				.areset(areset | ld_hold),
				.divmmc_en(sw_divmmc[gi]),
				.spi_sck(spi_sck[gi]),
				.spi_mosi(spi_mosi[gi]),
				.spi_cs_n(spi_cs_n[gi]),
				.spi_miso(spi_miso[gi]),
				.sd_wait(sd_wait[gi]),
				.ay_we(m_ay_we[gi]),
				.ay_wa(m_ay_wa[gi*5 +: 5]),
				.ay_wd(m_ay_wd[gi*8 +: 8]),
				.ay_ra(ay_ra),
				.ay_rd(m_ay_rd[gi*8 +: 8]),
				.beeper(m_beeper[gi]),
				.mic(m_mic[gi]),
				.a_req(cpu_req[gi]),
				.a_we(cpu_we[gi]),
				.a_addr(cpu_addr[gi*23 +: 23]),
				.a_din(cpu_din[gi*8 +: 8]),
				.a_ack(a_ack[gi] ^ ld_req[gi]),
				.a_q(a_q[gi*8 +: 8]),
				.b_req(b_req[gi]),
				.b_addr(b_addr[gi*23 +: 23]),
				.b_ack(b_ack[gi]),
				.b_q(b_q[gi*8 +: 8]),
				.pix(m_pix[gi*4 +: 4]),
				.quad(~full),
				.q_go(q_go[gi / 2]),
				.q_vc(q_vc),
				.q_buf(q_buf),
				.q_addr(q_addr),
				.q_word(q_words[gi*16 +: 16]),
				.q_brd_addr(q_brd_addr),
				.q_brd(q_brds[gi*3 +: 3]),
				.x_a(q_a[gi*16 +: 16]),
				.x_do(q_do[gi*8 +: 8]),
				.x_mc(q_mc[gi*7 +: 7]),
				.x_ts(q_ts[gi*7 +: 7]),
				.x_iorq(q_iorq[gi]),
				.x_noread(q_noread[gi]),
				.x_write(q_write[gi]),
				.x_intcycle_n(q_intcycle_n[gi]),
				.x_cen(q_cen[gi]),
				.x_wait_n(q_wait_n[gi]),
				.x_reset_n(q_reset_n[gi]),
				.x_nmi_n(q_nmi_n[gi]),
				.x_dinst(q_dinst[gi*8 +: 8]),
				.x_di(q_di[gi*8 +: 8]),
				.late(m_late[gi]),
				.nz(m_nz[gi])
			);

			// the emulated card on the image of slot gi; reset with the machine and while the DivMMC is off
			kg_sd_emu #(.CACHE(0)) sd_emu(
				.clk(clk_bus),
				.reset(m_reset | ~sw_divmmc[gi]),
				.sclk(spi_sck[gi]),
				.mosi(spi_mosi[gi]),
				.cs_n(spi_cs_n[gi] | ~sw_sd_img[gi]),
				.miso(emu_miso[gi]),
				.img_mounted(sdc_img_mounted[gi]),
				.img_size(|sdc_img_size[63:32] ? 32'hFFFFFE00 : sdc_img_size[31:0]),
				.hd_rd(hd_rd[gi]),
				.hd_wr(hd_wr[gi]),
				.hd_lba(hd_lba[gi*32 +: 32]),
				.hd_busy(sdc_busy && sdc_slot == gi),
				.hd_done(sdc_done && sdc_slot == gi),
				.hd_error(sdc_error),
				.hd_byte_in_strobe(sdc_byte_in_strobe && sdc_slot == gi),
				.hd_byte_addr(sdc_byte_addr),
				.hd_byte_in_data(sdc_byte_in_data),
				.hd_byte_out_data(hd_byte_out[gi*8 +: 8]),
				.waiting(emu_wait[gi])
			);
		end else begin : g_off
			assign cpu_req[gi] = 1'b0;
			assign cpu_we[gi] = 1'b0;
			assign cpu_addr[gi*23 +: 23] = 23'd0;
			assign cpu_din[gi*8 +: 8] = 8'd0;
			assign b_req[gi] = 1'b0;
			assign b_addr[gi*23 +: 23] = 23'd0;
			assign m_beeper[gi] = 1'b0;
			assign m_ay_we[gi] = 1'b0;
			assign m_ay_wa[gi*5 +: 5] = 5'd0;
			assign m_ay_wd[gi*8 +: 8] = 8'd0;
			assign m_ay_rd[gi*8 +: 8] = 8'd0;
			assign m_mic[gi] = 1'b0;
			assign m_late[gi] = 1'b0;
			assign m_nz[gi] = 1'b0;
			assign q_cen[gi] = 1'b0;
			assign q_wait_n[gi] = 1'b1;
			assign q_reset_n[gi] = 1'b0;
			assign q_nmi_n[gi] = 1'b1;
			assign q_dinst[gi*8 +: 8] = 8'hFF;
			assign q_di[gi*8 +: 8] = 8'hFF;
			assign spi_sck[gi] = 1'b0;
			assign spi_mosi[gi] = 1'b1;
			assign spi_cs_n[gi] = 1'b1;
			assign emu_miso[gi] = 1'b1;
			assign emu_wait[gi] = 1'b0;
			assign hd_rd[gi] = 1'b0;
			assign hd_wr[gi] = 1'b0;
			assign hd_lba[gi*32 +: 32] = 32'd0;
			assign hd_byte_out[gi*8 +: 8] = 8'd0;
			assign m_pix[gi*4 +: 4] = 4'd0;
			assign q_words[gi*16 +: 16] = 16'd0;
			assign q_brds[gi*3 +: 3] = 3'd0;
		end
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// video

wire [7:0] video_r, video_g, video_b, osd_r, osd_g, osd_b;
wire video_hs, video_vs;

video_out #(.NUM_MACHINES(NUM_MACHINES)) video(
	.clk(clk_bus),
	.ce7(ce7),
	.hc(hc),
	.vc(vc),
	// the line buffer of the full screen is written on the raster of the selected machine
	.w_ce7(r_ce7[sel]),
	.w_hc(r_hc[sel*9 +: 9]),
	.w_vc(r_vc[sel*9 +: 9]),
	.vga_x(vga_x),
	.vga_p(vga_p),
	.vga_l(vga_l),
	.flash(frame[4]),
	.full(full),
	.sel(sel),
	.rim_col(sw_frame_col),
	.pix(m_pix[sel*4 +: 4]),
	.q_go(q_go),
	.q_vc(q_vc),
	.q_buf(q_buf),
	.q_addr(q_addr),
	.q_words(q_words),
	.q_brd_addr(q_brd_addr),
	.q_brds(q_brds),
	// diagnostics of the selected machine (docs/PLAN.md): SDRAM ready, ROM loader done, reads non-zero, no late
	.diag_en(1'b1),
	.diag_ok({~m_late[sel], m_nz[sel], ~ld_hold & ~ld_ovf, sdram_ready_b}),
	.diag_blink(frame[4]),
	.r(video_r),
	.g(video_g),
	.b(video_b),
	.hs(video_hs),
	.vs(video_vs)
);

kg_osd_overlay #(.H_OFFSET(120), .V_OFFSET(72)) overlay(
	.clk(clk_bus),
	.rgb_i({video_r, video_g, video_b}),
	.rgb_o({osd_r, osd_g, osd_b}),
	.hsync_i(video_hs),
	.vsync_i(video_vs),
	.v_offset(11'd0),
	.h_offset(11'd0),
	.osd_command(osd_command)
);

assign VGA_R = osd_r;
assign VGA_G = osd_g;
assign VGA_B = osd_b;
assign VGA_HS = video_hs;
assign VGA_VS = video_vs;
assign V_CLK = v_clk;

// ---------------------------------------------------------------------------------------------
// sound: the beeper, MIC, tape input and TurboSound of the selected machine

// TurboSound: two AY generators for the selected machine only. They get its register writes; when another machine
// becomes selected (and at the start) they are loaded with its 32 register copies (ay_ra, one a clock; a write of
// the machine goes first). The other machines keep their registers and are silent.
reg [1:0] ay_sel = 2'd0;
reg [5:0] ay_ld = 6'd32;
wire s_ay_we = m_ay_we[sel];
reg g_we = 1'b0;
reg [4:0] g_wa = 5'd0;
reg [7:0] g_wd = 8'd0;
assign ay_ra = ay_ld[4:0] - 1'd1;
always @(posedge clk_bus) begin
	g_we <= 1'b0;
	if (ay_sel != sel) begin
		ay_sel <= sel;
		ay_ld <= 6'd32;
	end else if (s_ay_we) begin
		g_we <= 1'b1;
		g_wa <= m_ay_wa[sel*5 +: 5];
		g_wd <= m_ay_wd[sel*8 +: 8];
	end else if (ay_ld != 6'd0) begin
		ay_ld <= ay_ld - 1'd1;
		g_we <= 1'b1;
		g_wa <= ay_ra;
		g_wd <= m_ay_rd[sel*8 +: 8];
	end
end

wire [7:0] ay0_a, ay0_b, ay0_c, ay1_a, ay1_b, ay1_c;
ay_psg ay0(.clk(clk_bus), .we(g_we & ~g_wa[4]), .wa(g_wa[3:0]), .wd(g_wd), .ch_a(ay0_a), .ch_b(ay0_b), .ch_c(ay0_c));
ay_psg ay1(.clk(clk_bus), .we(g_we & g_wa[4]), .wa(g_wa[3:0]), .wd(g_wd), .ch_a(ay1_a), .ch_b(ay1_b), .ch_c(ay1_c));

// ABC: left A + B / 2, right C + B / 2; ACB: left A + C / 2, right B + C / 2 (as 2A + B, 11 bits for the two chips)
wire s_acb = sw_acb[sel];
wire [9:0] l0 = {ay0_a, 1'b0} + (s_acb ? ay0_c : ay0_b);
wire [9:0] r0 = {s_acb ? ay0_b : ay0_c, 1'b0} + (s_acb ? ay0_c : ay0_b);
wire [9:0] l1 = {ay1_a, 1'b0} + (s_acb ? ay1_c : ay1_b);
wire [9:0] r1 = {s_acb ? ay1_b : ay1_c, 1'b0} + (s_acb ? ay1_c : ay1_b);
reg [10:0] ay_l = 11'd0, ay_r = 11'd0;
always @(posedge clk_bus) begin
	ay_l <= l0 + l1;
	ay_r <= r0 + r1;
end

wire s_beep = m_beeper[sel];
wire s_mic = m_mic[sel];
wire [15:0] beep = (s_beep ? 16'h2000 : 16'd0) + (s_mic ? 16'h0800 : 16'd0) + (TAPE_IN ? 16'h0400 : 16'd0);
reg [15:0] audio_l = 16'd0, audio_r = 16'd0;
always @(posedge clk_bus) begin
	audio_l <= beep + {2'b00, ay_l, 3'b000};
	audio_r <= beep + {2'b00, ay_r, 3'b000};
end

assign BEEPER = s_beep;
assign TAPE_OUT = s_mic;

kg_pcm5102 #(.DIV_BITS(1)) pcm5102(
	.clk(clk_bus),
	.reset(areset),
	.left(audio_l),
	.right(audio_r),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_LRCK)
);
assign DAC_MUTE = 1'b1;   // 1 = unmuted

endmodule
