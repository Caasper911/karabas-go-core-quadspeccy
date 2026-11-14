`timescale 1ns / 1ps
`default_nettype none

/*
 quadspeccy.v

 QuadSpeccy: up to four Pentagon 128 running side by side, each in its own SDRAM bank
 (docs/ARCHITECTURE.md); the quad view (video_out) after power on, Win + ` switches to the selected
 machine full screen and back. Everything of the core but the board: the tops karabas_go_top.v,
 karabas_mini_top.v, karabas_minig_top.v put its video, sound and the FT812 / MCU lines on their pins.

 Clocks (one PLL on CLK_50MHZ, VCO 925 MHz, phase 0, as TS-Conf):
   clk_sys 84.09 MHz (/11)  the SDRAM controller
   clk_bus 28.03 MHz (/33)  the machines, video, MCU link, OSD; clk_sys / 3, every edge of clk_bus
                            is an edge of clk_sys. An output: the net clk_bus of the ucf is the one of the top.
   clk_8    7.97 MHz (/116) the clock of the FT812 (FT_CLK_OUT of the Mini boards)

 Hotkeys (zx_kbd): Win + 1..4 the machine that has the keyboard, Win + arrows the machine next to it (2 x 2),
 Win + ` full screen / quad.
 OSD (core.json "osd", the "index" of the items): 0 joystick L, 1 joystick R, 2 pause, 3 reset of the
 selected machine (F12), 4 reset of all (Win+F12), 5 colour of the frame of the selected machine in the
 quad view (ZX colour, default 4 green), 6 NMI of the selected machine (F11), per machine n on its
 page "Core n+1": 7 + 2n DivMMC on (default on), 8 + 2n SD card: the card of the board / the image
 (default image), and the F item of the image, slot n of the file mounter.

 DivMMC and Z-Controller (docs/ARCHITECTURE.md): the SPI of machine n goes to the card of the board (SD_*) when it chose
 it and is the lowest such machine (one owner: the others see no card), else to kg_sd_emu n on the image
 of slot n (the file mounter of kg_mcu2, one request at a time for all four).

 ROM loader: the MCU address bits 17..16 are the machine, 15..0 the offset in its ROM area
 (16 KB per ROM: 0 the 128 editor, 1 48 BASIC); the bytes go through a FIFO to channel A of the
 bank while the machines are held in reset.

 MCU: link v2 (kg_mcu2 of modules, karabas-go-firmware docs/link_v2.md; core.json "link": 2), MCU_INT on the IO1
 line of the board (the pin of the burst ready of v1).
*/

module quadspeccy #(
	parameter NUM_MACHINES = 4,
	parameter ENABLE_FDC = 1        // TR-DOS and the Beta Disk on the floppy drive of the board (the Go only; 0: not built)
) (
	input wire CLK_50MHZ,

	output wire clk_bus,            // 28 MHz: video, sound and everything the top does with them
	output wire clk_8,              // 8 MHz for the FT812
	output wire v_clk,              // the clock of the VGA DAC of the Go (bus_ce)
	output wire areset,             // the PLL is not locked

	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

	// SRAM: the frame buffer of the quad view (quad_fb.v)
	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MRD_N,
	output wire [1:0] MWR_N,

	// the SD card of the board
	output wire sd_cs_n,
	output wire sd_clk,
	output wire sd_mosi,
	input wire sd_miso,

	// the MCU link
	input wire mcu_cs_n,
	input wire mcu_sck,
	input wire mcu_mosi,
	output wire mcu_miso,
	input wire mcu_ft_ss,           // the chip selects of the FT812 and SD2 from the MCU
	input wire mcu_sd2_ss,
	output wire mcu_int,            // link v2: the interrupt to the MCU (high active, the IO1 line)
	output wire dvi_only,           // HDMI without the data islands (no sound), set in the MCU

	// the FT812: the MCU only (its SPI passed through, the video of the Go)
	output wire ft_spi_on,
	output wire ft_vga_on,
	output wire ft_sck,
	output wire ft_mosi,
	output wire ft_cs_n,
	output wire ft_reset,
	input wire ft_miso,

	// the floppy drive (ENABLE_FDC)
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

	input wire tape_in,
	output wire tape_out,
	output wire beeper,

	// the picture with the OSD (clk_bus, 896 x 640 clocks, de = the 736 x 576 visible part), syncs low active
	output wire [7:0] video_r,
	output wire [7:0] video_g,
	output wire [7:0] video_b,
	output wire video_hs,
	output wire video_vs,
	output wire video_de,

	// the sound of the selected machine (clk_bus, signed)
	output reg [15:0] audio_l = 16'd0,
	output reg [15:0] audio_r = 16'd0
);

// ---------------------------------------------------------------------------------------------
// clocks

wire clk_sys, locked;
wire [5:0] pll_clk;

// VCO 50 * 37 / 2 = 925 MHz: clk_sys 84.09 MHz (/11), clk_bus 28.03 MHz (/33), clk_8 7.97 MHz (/116, as TS-Conf)
kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(33), .CLKOUT2_DIVIDE(116),
	.BUFG_MASK(6'b000101)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(locked)
);
assign clk_sys = pll_clk[0];
assign clk_8 = pll_clk[2];
BUFG bufg_clk_bus(.I(pll_clk[1]), .O(clk_bus));

assign areset = ~locked;

// V_CLK of the video DAC (TS-Conf bus_ce)
wire ce_28m;
bus_ce bus_ce(.clk_sys(clk_sys), .clk_bus(clk_bus), .ce(ce_28m), .v_clk(v_clk));

// ---------------------------------------------------------------------------------------------
// MCU

wire [7:0] kb_status, kb_dat0, kb_dat1, kb_dat2, kb_dat3, kb_dat4, kb_dat5;
wire [15:0] mcu_joy_l, mcu_joy_r;
wire [12:0] joy_l = mcu_joy_l[12:0];
wire [12:0] joy_r = mcu_joy_r[12:0];
wire [5:0] mcu_btns;
wire [1:0] hw_btn = mcu_btns[1:0];
wire mcu_busy;
// LOAD of the MCU: kind 0 the ROMs of core.json (the only kind of this core)
wire [1:0] ld_kind;
wire ld_active, ld_wr_mcu, ld_ready;
wire [31:0] ld_addr_mcu;
wire [7:0] ld_data_mcu;
wire loader_act = ld_active && ld_kind == 2'd0;
wire loader_wr = ld_wr_mcu && ld_kind == 2'd0;
// the file mounter (the images of the emulated SD cards, slot n = machine n): the sdc_* side of img_sdc
wire sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_byte_in_data, sdc_img_mounted, sdc_byte_out_data;
wire [63:0] sdc_img_size;
wire [3:0] hd_rd, hd_wr;
wire [31:0] sdc_sector;
// the bitmap OSD (kg_l2_osd_overlay)
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

// the USB mouse of the MCU (quad_mouse)
wire [7:0] ms_x, ms_y, ms_z, ms_b;
wire ms_wr;

// the OSD switches (core.json "osd", the "index" of the items): 32 registers of 8 bits, switch n = softsw[n*8 +: 8];
// 7..14: per machine n: 7 + 2n DivMMC on, 8 + 2n SD card (0 the card of the board, 1 the image); 24 + n Memory size.
// SW_INIT: the defaults of core.json until the MCU sends them.
wire [32*8-1:0] softsw;

kg_mcu2 #(
	.CAPS(16'h0010),             // bit 4: LD_READY (the ROM loader FIFO)
	.SW_N(32),
	.SW_INIT(256'h00_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00_00_01_01_01_01_01_01_01_01_00_04_00_00_00_01_00),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),
	.IMG_OUT_LATENCY(3),
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu (
	.CLK(clk_bus),
	.N_RESET(~areset),

	.MCU_SCK(mcu_sck),
	.MCU_MOSI(mcu_mosi),
	.MCU_MISO(mcu_miso),
	.MCU_SS(mcu_cs_n),
	.MCU_INT(mcu_int),
	.MCU_SPI_FT_SS(mcu_ft_ss),
	.MCU_SPI_SD2_SS(mcu_sd2_ss),

	.SW(softsw), .SW_WR(), .SW_INDEX(), .SW_VALUE(),
	.HW_ID(), .DVI_ONLY(dvi_only), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(mcu_busy),
	.BTNS(mcu_btns),
	.RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

	// the USB report (modifiers, 6 key codes) as KB_STATUS, KB_DAT0..5 of v1, now changed whole
	.KBD({kb_dat5, kb_dat4, kb_dat3, kb_dat2, kb_dat1, kb_dat0, kb_status}), .KBD_WR(),
	.PS2_CODE(), .PS2_KIND(), .PS2_WR(),
	.MS_X(ms_x), .MS_Y(ms_y), .MS_Z(ms_z), .MS_B(ms_b), .MS_WR(ms_wr),
	.JOY_L(mcu_joy_l), .JOY_R(mcu_joy_r), .JOY_WR(),
	.PS2_CMD(16'd0), .PS2_CMD_WR(1'b0),

	.LD_KIND(ld_kind), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(ld_active), .LD_END(),
	.LD_ADDR(ld_addr_mcu), .LD_DATA(ld_data_mcu), .LD_WR(ld_wr_mcu), .LD_READY(ld_ready),

	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha),
	.OSD_PX(osd_px), .OSD_PY(osd_py), .OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(sdc_img_mounted), .SDC_IMG_SIZE(sdc_img_size),
	.SDC_RD({4'd0, hd_rd}), .SDC_WR({4'd0, hd_wr}), .SDC_SECTOR(sdc_sector),
	.SDC_BUSY(sdc_busy), .SDC_DONE(sdc_done), .SDC_ERROR(sdc_error), .SDC_SLOT(sdc_slot),
	.SDC_BYTE_IN_STROBE(sdc_byte_in_strobe), .SDC_BYTE_ADDR(sdc_byte_addr), .SDC_BYTE_IN_DATA(sdc_byte_in_data),
	.SDC_BYTE_OUT_DATA(sdc_byte_out_data),
	.IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
	.BK_MOUNT(1'b0), .BK_FLUSHED(1'b0), .BK_SLOT(3'd0), .BK_SIZE(32'd0), .BK_KIND(8'd0), .BK_RESULT(8'd0),
	.IMG_ACTIVE(),

	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0),
	.PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0), .PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(), .PORT_STAT_WR(),

	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .RTC_DO(),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),

	.FT_SPI_ON(ft_spi_on), .FT_VGA_ON(ft_vga_on), .FT_RESET(ft_reset),
	.FT_SCK(ft_sck), .FT_MOSI(ft_mosi), .FT_MISO(ft_miso), .FT_CS_N(ft_cs_n),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
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
wire sw_tape_all = softsw[19*8];          // Tape in: 0 Board (all machines hear TAPE_IN), 1 Core (from the Tape out core)
wire [1:0] sw_tape_core = softsw[20*8 +: 2];   // Tape out: the machine on TAPE_OUT (Core 1..4)
wire sw_keys_all = softsw[21*8];          // Keys to: 0 Selected, 1 All (the quad view only)
wire [1:0] sw_fdd_core = softsw[23*8 +: 2];    // FDD: the machine with TR-DOS and the floppy drive (Core 1..4)
// Memory size of machine n (24 + n): 0 128K, 1 1024K (Profi, #DFFD)
wire [3:0] sw_mem1024 = {softsw[27*8], softsw[26*8], softsw[25*8], softsw[24*8]};
// Sound of machine n (28 + n): 0 only when it is selected, 1 always
wire [3:0] sw_snd_all = {softsw[31*8], softsw[30*8], softsw[29*8], softsw[28*8]};
// 22: not used (was Mouse middle; the middle button always goes back to the quad view)

// ---------------------------------------------------------------------------------------------
// keyboard

wire [39:0] kbd_keys;
wire [7:0] kbd_kempston;
wire [1:0] kbd_sel;
wire kbd_full_tgl;
wire ms_sel_we;        // the mouse chose a machine in the quad view (quad_mouse)
wire [1:0] ms_sel_in;

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
	.sel_we(ms_sel_we),
	.sel_in(ms_sel_in),
	.sel(kbd_sel),
	.full_tgl(kbd_full_tgl)
);

// the machine with the keyboard (machines that are not built are not selected)
wire [1:0] sel = (kbd_sel < NUM_MACHINES) ? kbd_sel : 2'd0;

// full screen of the selected machine / quad view (Win + `; the mouse: a double click in the quad view, the middle
// button in the full screen); the quad view after power on
wire ms_full_set, ms_quad_set;
reg full = 1'b0;
always @(posedge clk_bus)
	if (kbd_full_tgl)
		full <= ~full;
	else if (ms_full_set)
		full <= 1'b1;
	else if (ms_quad_set)
		full <= 1'b0;

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

// 1024 words: the MCU sends DATA packets of 512 bytes (a byte per 250 ns at most) and asks LOAD STATUS before each
// (caps bit 4): LD_READY while 512 words are free. A byte that still finds the FIFO full is lost (ld_ovf, sticky:
// square 2 of the diagnostics red). Link v1 had no flow control: 256 words (with 16 the ESXDOS ROM of machine 4, the
// last file, came broken after the ports of sdram_ctrl went to clk_bus, a longer loop per byte).
wire ld_fifo_full;
wire [10:0] ld_fifo_count;
reg ld_ovf = 1'b0;
kg_fifo #(.DW(26), .AW(10)) ld_fifo(
	.clk(clk_bus),
	.reset(areset),
	.wr(loader_wr && ld_addr_mcu[31:18] == 14'd0),
	.din({ld_addr_mcu[17:0], ld_data_mcu}),
	.full(ld_fifo_full),
	.rd(ld_fifo_rd),
	.dout(ld_fifo_q),
	.empty(ld_fifo_empty),
	.count(ld_fifo_count)
);
assign ld_ready = ld_fifo_count <= 11'd512;

// a bank is busy while the controller has not answered its request (the loader's, or the CPU's: one side only)
wire [3:0] ld_busy = ld_req ^ a_ack ^ cpu_req;
always @(posedge clk_bus)
	if (loader_wr && ld_fifo_full)
		ld_ovf <= 1'b1;
// the loader's own requests in flight: ld_busy alone also holds the CPU's requests, so ld_hold on it would
// reset the machine at its first memory read (found on the board: the machine never ran)
reg [3:0] ld_out = 4'b0000;

// Clearing of the DivMMC RAM: the first 128 KB (banks 0..15, 0x80000..0x9FFFF of each machine's SDRAM bank) of all
// machines, at the start of the core and at Reset All (OSD, Win+F12, or the button), through the loader: one offset
// in all banks at once, 128K steps of a write round each (about 50 ms). The loader FIFO goes first (the ROMs at the
// start); the machines are in reset (ld_hold) and their DivMMC state cleared (areset of pentagon) meanwhile.
localparam [3:0] M_MASK = (4'b0001 << NUM_MACHINES) - 4'b0001;
reg clr_act = 1'b1;
reg [16:0] clr_a = 17'd0;
reg rst_all_d = 1'b0;
wire rst_all = sw_reset_all | hw_btn[1];

always @(posedge clk_bus) begin
	ld_fifo_rd <= 1'b0;
	ld_out <= ld_out & ld_busy;
	rst_all_d <= rst_all;
	if (areset || (rst_all && !rst_all_d)) begin
		clr_act <= 1'b1;
		clr_a <= 17'd0;
	end
	case (ld_st)
		2'd0: if (!ld_fifo_empty && sdram_ready_b) begin
			ld_fifo_rd <= 1'b1;
			ld_st <= 2'd1;
		end else if (clr_act && sdram_ready_b && ld_out == 4'b0000 && (ld_busy & M_MASK) == 4'b0000 && !areset) begin
			ld_addr <= 23'h080000 | {6'd0, clr_a};
			ld_din <= 8'd0;
			ld_req <= ld_req ^ M_MASK;
			ld_out <= M_MASK;
			clr_a <= clr_a + 1'd1;
			if (clr_a == 17'h1FFFF)
				clr_act <= 1'b0;
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
wire ld_hold = loader_act | mcu_busy | ~ld_fifo_empty | (ld_st != 2'd0) | (|ld_out) | ~sdram_ready_b | clr_act;

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

// mouse: the Kempston mouse of the selected machine in the full screen, the cursor of the quad view (quad_mouse.v)
wire [7:0] vo_r, vo_g, vo_b;
wire vo_hs, vo_vs, vo_de;
wire [4*24-1:0] ms_q;
wire [9:0] cur_x, cur_y;
wire cur_on;
quad_mouse #(.NUM_MACHINES(NUM_MACHINES)) mouse(
	.clk(clk_bus),
	.ms_x(ms_x),
	.ms_y(ms_y),
	.ms_z(ms_z[3:0]),    // the 4 bits of the Kempston wheel
	.ms_b(ms_b[2:0]),
	.ms_wr(ms_wr),
	.full(full),
	.sel(sel),
	.vsync(vo_vs),
	.ms_q(ms_q),
	.cur_x(cur_x),
	.cur_y(cur_y),
	.cur_on(cur_on),
	.sel_we(ms_sel_we),
	.sel_in(ms_sel_in),
	.mid_quad(1'b1),
	.full_set(ms_full_set),
	.quad_set(ms_quad_set)
);

wire [3:0] m_beeper, m_mic, m_late, m_nz;

// TR-DOS / Beta Disk: one controller (hrdy_fdc, the VG93 model of TS-Conf) on the floppy drive of the board, for the
// machine of OSD FDD if its DivMMC is off (both take 3D00..3DFF); the other machines have no TR-DOS
wire [1:0] fdd_core = (sw_fdd_core < NUM_MACHINES) ? sw_fdd_core : 2'd0;
wire [3:0] m_trdos_en;
wire [3:0] m_fdc_cs, m_fdc_csff, m_fdc_rd, m_fdc_wr;
wire [7:0] fdc_q;
wire fdc_busy;
generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_trdos
		assign m_trdos_en[gi] = (ENABLE_FDC != 0) && fdd_core == gi && !sw_divmmc[gi];
	end
endgenerate

// tape: Tape in = Board: every machine hears TAPE_IN of the board; = Core: every machine but the Tape out one hears the
// MIC of that one (a SAVE there is a LOAD in the others), the Tape out one TAPE_IN. TAPE_OUT: MIC of the Tape out one.
wire [1:0] tape_core = (sw_tape_core < NUM_MACHINES) ? sw_tape_core : 2'd0;
wire [3:0] m_tape_in;
generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_tape
		assign m_tape_in[gi] = (sw_tape_all && tape_core != gi) ? m_mic[tape_core] : tape_in;
	end
endgenerate
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

wire [3:0] m_resets;
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

wire [3:0] spi_sck, spi_mosi, spi_cs_n, spi_miso, sd_wait, emu_miso, emu_wait;
wire [4*32-1:0] hd_lba;
wire [4*8-1:0] hd_byte_out;

// the card of the board: the lowest machine with the SD card "Real" (DivMMC and Z-Controller: the Z-Controller is
// always on, so the card is the machine's with the DivMMC off too)
wire [3:0] want_real = ~sw_sd_img;
wire [1:0] real_owner = want_real[0] ? 2'd0 : want_real[1] ? 2'd1 : want_real[2] ? 2'd2 : 2'd3;
wire real_on = |want_real;

reg sd_miso_r = 1'b1;
always @(posedge clk_bus)
	sd_miso_r <= sd_miso;

assign sd_clk = real_on ? spi_sck[real_owner] : 1'b0;
assign sd_mosi = real_on ? spi_mosi[real_owner] : 1'b1;
assign sd_cs_n = real_on ? spi_cs_n[real_owner] : 1'b1;

generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_sd
		// the image: the emulated card; the card of the board: its owner gets it, the others no card (FF)
		assign spi_miso[gi] = sw_sd_img[gi] ? emu_miso[gi] : (real_on && real_owner == gi) ? sd_miso_r : 1'b1;
		assign sd_wait[gi] = sw_sd_img[gi] & emu_wait[gi];
	end
endgenerate

// the file mounter (kg_mcu2, the sdc_* side of img_sdc): one request at a time, the lowest slot first (it takes the
// sector with it)
wire [3:0] hd_req = hd_rd | hd_wr;
wire [1:0] hd_first = hd_req[0] ? 2'd0 : hd_req[1] ? 2'd1 : hd_req[2] ? 2'd2 : 2'd3;
assign sdc_sector = hd_lba[hd_first*32 +: 32];
assign sdc_byte_out_data = hd_byte_out[sdc_slot[1:0]*8 +: 8];
wire [4*4-1:0] m_pix;

generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_m
		if (gi < NUM_MACHINES) begin : g_on
			reg m_reset = 1'b1;
			always @(posedge clk_bus)
				m_reset <= areset | ld_hold | sw_reset_all | hw_btn[1] | ((sw_reset | hw_btn[0]) && sel == gi);
			assign m_resets[gi] = m_reset;

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
				// keyboard and joysticks: the selected machine; in the quad view with Keys to = All every machine
				.keys((sel == gi || (sw_keys_all && !full)) ? kbd_keys : 40'd0),
				.kempston((sel == gi || (sw_keys_all && !full)) ? kbd_kempston : 8'd0),
				.mouse(ms_q[gi*24 +: 24]),
				.tape_in(m_tape_in[gi]),
				.nmi(sw_nmi && sel == gi),
				// power on for the DivMMC (a reset keeps its state): the start of the core and the ROM loading
				.areset(areset | ld_hold),
				.mem1024(sw_mem1024[gi]),
				.trdos_en(m_trdos_en[gi]),
				.fdc_cs(m_fdc_cs[gi]),
				.fdc_csff(m_fdc_csff[gi]),
				.fdc_rd(m_fdc_rd[gi]),
				.fdc_wr(m_fdc_wr[gi]),
				.fdc_q(fdc_q),
				.fdc_busy(fdc_busy),
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

			// the emulated card on the image of slot gi; reset with the machine
			kg_sd_emu #(.CACHE(0)) sd_emu(
				.clk(clk_bus),
				.reset(m_reset),
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
			assign m_fdc_cs[gi] = 1'b0;
			assign m_fdc_csff[gi] = 1'b0;
			assign m_fdc_rd[gi] = 1'b0;
			assign m_fdc_wr[gi] = 1'b0;
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
		end
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// floppy drive: hrdy_fdc on the bus of the machine fdd_core (ENABLE_FDC)

generate
	if (ENABLE_FDC != 0) begin : g_fdc
		wire [1:0] fdc_ds;
		wire fdc_side1;
		hrdy_fdc fdc(
			.clk(clk_bus),
			.ds80(1'b0),
			.reset(m_resets[fdd_core] | ~m_trdos_en[fdd_core]),
			.ena_cpu(ce_m[fdd_core]),
			.a(q_a[fdd_core*16 +: 16]),
			.d(q_do[fdd_core*8 +: 8]),
			.wr_n(~m_fdc_wr[fdd_core]),
			.rd_n(~m_fdc_rd[fdd_core]),
			.iorq_n(~(m_fdc_rd[fdd_core] | m_fdc_wr[fdd_core])),
			.cs_n(~m_fdc_cs[fdd_core]),
			.csff_n(~m_fdc_csff[fdd_core]),
			.oe_n(),
			.dout(fdc_q),
			.busy(fdc_busy),
			.intrq_o(),
			.drq_o(),
			.FDC_SIDE1(fdc_side1),
			.FDC_RDATA(FDC_RDATA),
			.FDC_WPRT(FDC_WPRT),
			.FDC_TR00(FDC_TR00),
			.FDC_INDEX(FDC_INDEX),
			.FDC_WG(FDC_WGATE),
			.FDC_WR_DATA(FDC_WDATA),
			.FDC_STEP(FDC_STEP),
			.FDC_DIR(FDC_DIR),
			.FDC_MOTOR(FDC_MOTOR),
			.FDC_DS(fdc_ds)
		);
		// as the Go core of TS-Conf: the drive outputs active high (the board drives the cable), side through SIDE_N
		assign FDC_DRIVE = fdc_ds;
		assign FDC_SIDE_N = fdc_side1;
	end else begin : g_no_fdc
		assign fdc_q = 8'hFF;
		assign fdc_busy = 1'b0;
		assign FDC_DRIVE = 2'b00;
		assign FDC_MOTOR = 1'b0;
		assign FDC_DIR = 1'b0;
		assign FDC_STEP = 1'b0;
		assign FDC_WDATA = 1'b0;
		assign FDC_WGATE = 1'b0;
		assign FDC_SIDE_N = 1'b1;
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// video

// the frame buffer of the quad view in the SRAM: every machine writes its picture on its raster, video_out reads it
wire fb_rd;
wire [17:0] fb_raddr;
wire [15:0] fb_word;

quad_fb fbuf(
	.clk(clk_bus),
	.clk_sys(clk_sys),
	.ce7(ce7),
	.hc(hc),
	.vc(vc),
	.m_ce7(r_ce7),
	.m_hc(r_hc),
	.m_vc(r_vc),
	.m_pix(m_pix),
	.rd(fb_rd),
	.rd_addr(fb_raddr),
	.word(fb_word),
	.MA(MA),
	.MD(MD),
	.MRD_N(MRD_N),
	.MWR_N(MWR_N)
);

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
	.full(full),
	.sel(sel),
	.rim_col(sw_frame_col),
	.cur_x(cur_x),
	.cur_y(cur_y),
	.cur_on(cur_on),
	.pix(m_pix[sel*4 +: 4]),
	.fb_rd(fb_rd),
	.fb_raddr(fb_raddr),
	.fb_word(fb_word),
	// diagnostics of the selected machine (docs/PLAN.md): SDRAM ready, ROM loader done, reads non-zero, no late
	.diag_en(1'b0),   // hidden (the squares of the bring-up)
	.diag_ok({~m_late[sel], m_nz[sel], ~ld_hold & ~ld_ovf, sdram_ready_b}),
	.diag_blink(frame[4]),
	.r(vo_r),
	.g(vo_g),
	.b(vo_b),
	.hs(vo_hs),
	.vs(vo_vs),
	.de(vo_de)
);

// the bitmap OSD of link v2, centred on de (736 x 576: scale 2, 512 x 256); the overlay takes high active syncs and
// delays the picture, the syncs and de by 2 clocks
wire ov_hs, ov_vs;
kg_l2_osd_overlay overlay(
	.wclk(clk_bus),
	.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha),
	.osd_px(osd_px), .osd_py(osd_py), .osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on(8'd0), .icon_act(8'd0),
	.clk(clk_bus),
	.rgb_i({vo_r, vo_g, vo_b}), .hs_i(~vo_hs), .vs_i(~vo_vs), .de_i(vo_de),
	.rgb_o({video_r, video_g, video_b}), .hs_o(ov_hs), .vs_o(ov_vs), .de_o(video_de)
);

assign video_hs = ~ov_hs;
assign video_vs = ~ov_vs;

// ---------------------------------------------------------------------------------------------
// sound: the beeper, MIC, tape input and TurboSound of the selected machine

// The machines heard: the selected one, and those with Sound = Always (OSD 28 + n)
wire [3:0] aud;
generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_aud
		assign aud[gi] = (sel == gi) || sw_snd_all[gi];
	end
endgenerate

// TurboSound of all machines: one generator for the eight AY (turbosound.v), the machines heard in the mix
wire [12:0] ay_l, ay_r;
turbosound ts(
	.clk(clk_bus),
	.aud(aud),
	.acb(sw_acb),
	.m_we(m_ay_we),
	.m_wa(m_ay_wa),
	.ay_ra(ay_ra),
	.m_rd(m_ay_rd),
	.ay_l(ay_l),
	.ay_r(ay_r)
);

// beeper, MIC and tape input of the machines heard (0x2000, 0x800, 0x400 each), the AY x 8 (as one machine before);
// the sum of several machines is limited to 0x7FFF
wire s_beep = m_beeper[sel];
reg [17:0] beeps = 18'd0;
always @(posedge clk_bus)
	beeps <= (aud[0] ? {m_beeper[0], 1'b0, m_mic[0], m_tape_in[0], 10'd0} : 14'd0)
	       + (aud[1] ? {m_beeper[1], 1'b0, m_mic[1], m_tape_in[1], 10'd0} : 14'd0)
	       + (aud[2] ? {m_beeper[2], 1'b0, m_mic[2], m_tape_in[2], 10'd0} : 14'd0)
	       + (aud[3] ? {m_beeper[3], 1'b0, m_mic[3], m_tape_in[3], 10'd0} : 14'd0);
wire [17:0] sum_l = beeps + {2'b00, ay_l, 3'b000};
wire [17:0] sum_r = beeps + {2'b00, ay_r, 3'b000};
always @(posedge clk_bus) begin
	audio_l <= (sum_l > 18'h07FFF) ? 16'h7FFF : sum_l[15:0];
	audio_r <= (sum_r > 18'h07FFF) ? 16'h7FFF : sum_r[15:0];
end

assign beeper = s_beep;
assign tape_out = m_mic[tape_core];

endmodule
