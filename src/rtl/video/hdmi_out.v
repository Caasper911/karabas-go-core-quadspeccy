`timescale 1ns / 1ps
`default_nettype none

/*
 hdmi_out.v

 HDMI of the Mini / Mini G: the picture of the core (clk_bus, 28.03 MHz, the 896 x 640 raster of video_out,
 de its 736 x 576 visible part, both syncs low active) with the sound, as karabas_mini_osca_top of karabas_go_v6z80p.

 The pixel clock is clk_bus itself; a DCM (kg_dcm, CLK0 feedback: CLKFX aligned with clk_bus) makes the 5x serial
 clock (140 MHz) and its inverse for the serialisers of hdmi_tx. INPUT_REG = 1: the output of kg_osd_overlay is
 combinational, hdmi_tx registers it before the TMDS encoders.

 Audio: 48 kHz (an accumulator of clk_bus: + 48 a clock, modulo 28030), the sample of the core taken with the strobe.
 dvi_only (kg_mcu) is a register of clk_bus: DVI, no data islands.
*/

module hdmi_out (
	input wire clk_bus,
	input wire reset,

	input wire [23:0] rgb,
	input wire hs,
	input wire vs,
	input wire de,

	input wire dvi_only,
	input wire [15:0] audio_l,   // signed
	input wire [15:0] audio_r,

	output wire [3:0] tmds_p,
	output wire [3:0] tmds_n
);

wire clk_hdmi, clk_hdmi_n, locked;
kg_dcm #(.CLKIN_PERIOD(35.677), .CLKFX_MULTIPLY(5), .CLKFX_DIVIDE(1)) dcm(
	.clk_in(clk_bus),
	.rst(reset),
	.clk_fx(clk_hdmi),
	.clk_fx180(clk_hdmi_n),
	.clk_0(),
	.locked(locked)
);

reg [14:0] aud_acc = 15'd0;
reg aud_stb = 1'b0;
reg [23:0] hdmi_l = 24'd0, hdmi_r = 24'd0;
always @(posedge clk_bus) begin
	aud_stb <= 1'b0;
	if (aud_acc >= 15'd27982) begin
		aud_acc <= aud_acc + 15'd48 - 15'd28030;
		aud_stb <= 1'b1;
		hdmi_l <= {audio_l, 8'd0};
		hdmi_r <= {audio_r, 8'd0};
	end else
		aud_acc <= aud_acc + 15'd48;
end

hdmi_tx #(.SAMPLE_FREQ(48000), .INPUT_REG(1)) tx(
	.clk(clk_bus),
	.sclk(clk_hdmi),
	.sclk_n(clk_hdmi_n),
	.reset(reset | ~locked),
	.rgb(rgb),
	.vsync(vs),
	.hsync(hs),
	.de(de),
	.audio_en(~dvi_only),
	.audio_l(hdmi_l),
	.audio_r(hdmi_r),
	.audio_clk(aud_stb),
	.tx_clk_n(tmds_n[3]),
	.tx_clk_p(tmds_p[3]),
	.tx_d_n(tmds_n[2:0]),
	.tx_d_p(tmds_p[2:0])
);

endmodule
