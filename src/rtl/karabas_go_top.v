`timescale 1ns / 1ps
`default_nettype none

/*
 karabas_go_top.v

 Quad Speccy for Karabas Go: up to four Pentagon 128 running side by side, each in its own SDRAM
 bank (docs/ARCHITECTURE.md). Milestone 1: NUM_MACHINES = 1, full screen VGA.

 Clocks (one PLL on CLK_50MHZ, VCO 925 MHz, phase 0, as TS-Conf):
   clk_sys 84.09 MHz (/11)  the SDRAM controller
   clk_bus 28.03 MHz (/33)  the machines, video, MCU link, OSD; clk_sys / 3, every edge of clk_bus
                            is an edge of clk_sys

 Hotkeys (zx_kbd): Win + 1..4 the machine that has the keyboard, Win + ` full screen / quad.
 OSD (core.json "osd", soft switch registers in this order): 0 joystick L, 1 joystick R, 2 pause,
 3 reset of the selected machine, 4 reset of all.

 ROM loader: the MCU address bits 17..16 are the machine, 15..0 the offset in its ROM area
 (16 KB per ROM: 0 the 128 editor, 1 48 BASIC); the bytes go through a FIFO to channel A of the
 bank while the machines are held in reset.
*/

module karabas_go_top #(
	parameter NUM_MACHINES = 1
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

assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;
assign SD_DI = 1'b1;
assign SD_DO = 1'bZ;

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

assign MCU_SPI_IO[0] = mcu_burst_ready;
assign MCU_SPI_IO[1] = 1'bZ;

kg_mcu #(
	.BURST_MAX_MHZ(0),
	.CS_FILTER(3),
	.ENABLE_RTC(0),
	.ENABLE_UART(0),
	.ENABLE_MATRIX(0),
	.ENABLE_DEBUG(0),
	.ENABLE_IMG(0),
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

	.IMG_MOUNTED(), .IMG_SIZE(), .IMG_DATA_WR(), .IMG_DATA_ADDR(), .IMG_DATA(), .IMG_RESULT_WR(),
	.IMG_RESULT(), .IMG_SUM(), .IMG_Q_WR(1'b0), .IMG_Q_DI(24'd0), .IMG_Q_ACK(), .IMG_PHYS_WR(),
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

wire [5*8-1:0] softsw;
kg_soft_switches #(.N(5)) soft_switches(
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

// full screen / quad view (Win + `): milestone 1 shows the selected machine full screen only, the
// quad view comes with the compositor (docs/PLAN.md)
reg full = 1'b1;
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

kg_fifo #(.DW(26), .AW(4)) ld_fifo(
	.clk(clk_bus),
	.reset(areset),
	.wr(loader_wr && loader_act && loader_addr[31:18] == 14'd0),
	.din({loader_addr[17:0], loader_data}),
	.full(),
	.rd(ld_fifo_rd),
	.dout(ld_fifo_q),
	.empty(ld_fifo_empty),
	.count()
);

// a bank is busy while the controller has not answered its request (the loader's, or the CPU's: one side only)
wire [3:0] ld_busy = ld_req ^ a_ack ^ cpu_req;
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
	.vga_half(vga_half)
);

wire [3:0] m_beeper, m_mic, m_late, m_nz;
wire [4*4-1:0] m_pix;

generate
	for (gi = 0; gi < 4; gi = gi + 1) begin : g_m
		if (gi < NUM_MACHINES) begin : g_on
			reg m_reset = 1'b1;
			always @(posedge clk_bus)
				m_reset <= areset | ld_hold | sw_reset_all | hw_btn[1] | ((sw_reset | hw_btn[0]) && sel == gi);

			pentagon m(
				.clk(clk_bus),
				.reset(m_reset),
				.pause(sw_pause),
				.ce7(ce7),
				.ce_cpu(ce_cpu),
				.hc(hc),
				.vc(vc),
				.int_n(int_n),
				.frame(frame),
				.keys(sel == gi ? kbd_keys : 40'd0),
				.kempston(sel == gi ? kbd_kempston : 8'd0),
				.tape_in(TAPE_IN),
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
				.late(m_late[gi]),
				.nz(m_nz[gi])
			);
		end else begin : g_off
			assign cpu_req[gi] = 1'b0;
			assign cpu_we[gi] = 1'b0;
			assign cpu_addr[gi*23 +: 23] = 23'd0;
			assign cpu_din[gi*8 +: 8] = 8'd0;
			assign b_req[gi] = 1'b0;
			assign b_addr[gi*23 +: 23] = 23'd0;
			assign m_beeper[gi] = 1'b0;
			assign m_mic[gi] = 1'b0;
			assign m_late[gi] = 1'b0;
			assign m_nz[gi] = 1'b0;
			assign m_pix[gi*4 +: 4] = 4'd0;
		end
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// video

wire [7:0] video_r, video_g, video_b, osd_r, osd_g, osd_b;
wire video_hs, video_vs;

video_out video(
	.clk(clk_bus),
	.ce7(ce7),
	.hc(hc),
	.vc(vc),
	.vga_x(vga_x),
	.pix(m_pix[sel*4 +: 4]),
	// diagnostics of the selected machine (docs/PLAN.md): SDRAM ready, ROM loader done, reads non-zero, no late
	.diag_en(1'b1),
	.diag_ok({~m_late[sel], m_nz[sel], ~ld_hold, sdram_ready_b}),
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
// sound: the beeper, MIC and tape input of the selected machine

wire s_beep = m_beeper[sel];
wire s_mic = m_mic[sel];
wire [15:0] audio = (s_beep ? 16'h2000 : 16'd0) + (s_mic ? 16'h0800 : 16'd0) + (TAPE_IN ? 16'h0400 : 16'd0);

assign BEEPER = s_beep;
assign TAPE_OUT = s_mic;

kg_pcm5102 #(.DIV_BITS(1)) pcm5102(
	.clk(clk_bus),
	.reset(areset),
	.left(audio),
	.right(audio),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_LRCK)
);
assign DAC_MUTE = 1'b1;   // 1 = unmuted

endmodule
