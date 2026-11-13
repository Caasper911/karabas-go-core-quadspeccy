`timescale 1ns / 1ps
`default_nettype none

/*
 turbosound.v

 The TurboSound of all four machines: eight AY-3-8910 (machine m chip c = voice {m, c}) made by one generator that
 runs them one after another. The logic per voice is that of ay_psg.v (ym2149.v of MikeJ / Sorgelig: the counters
 count up, period 0 as 1; a 16-step envelope; the AY levels).

 Frame of 256 clocks of clk_bus (28 MHz): voice v = cnt[7:5], step s = cnt[4:0]. The AY clock is 1.75 MHz = clk / 16:
 a tone counter ticks every 128 clocks (two ticks a frame), noise and envelope every 256 (one a frame), as ay_psg.
 The registers are not kept here: ay_ra = {c, r} reads register r of chip c of every machine at once (the copies in
 pentagon.v, distributed RAM read in the same clock), m_rd of machine m. A write of R13 (m_we, m_wa) restarts the
 envelope of its voice at its next envelope step (within a frame, 9 us).

 Steps: 0..11 two tone ticks of A, B, C (an even step takes the low byte of the period, the odd one the high
 byte and ticks); 12 noise (R6); 13..15 envelope (R11, R12, R13); 16 R7 (mixer); 17..19 the level of A, B, C (R8..R10)
 added to the mix of the frame when the machine is heard (aud: the selected one, or Sound = Always): ABC left 2A + B,
 right 2C + B; ACB (acb) left 2A + C, right 2B + C. At the end of the frame the sums are the output (13 bits:
 up to 8 voices of 765, about 110 kHz).
*/

module turbosound (
	input wire clk,
	input wire [3:0] aud,           // machine m is heard
	input wire [3:0] acb,           // AY mix of machine m: 0 ABC, 1 ACB
	input wire [3:0] m_we,          // the register writes of the machines (for R13)
	input wire [4*5-1:0] m_wa,
	output wire [4:0] ay_ra,        // {chip, register} read in all machines
	input wire [4*8-1:0] m_rd,
	output reg [12:0] ay_l = 13'd0,
	output reg [12:0] ay_r = 13'd0
);

reg [7:0] cnt = 8'd0;
always @(posedge clk)
	cnt <= cnt + 1'd1;
wire [2:0] v = cnt[7:5];
wire [1:0] m = v[2:1];
wire c = v[0];
wire [4:0] s = cnt[4:0];

// the register of the step: steps 0..11 R(2 ch) / R(2 ch + 1), ch = (s / 2) mod 3
wire [2:0] sh = s[3:1];
wire [1:0] tch = (sh >= 3'd3) ? sh[1:0] - 2'd3 : sh[1:0];
reg [3:0] r;
always @* begin
	if (s < 5'd12)
		r = {1'b0, tch, s[0]};
	else case (s)
		5'd12: r = 4'd6;
		5'd13: r = 4'd11;
		5'd14: r = 4'd12;
		5'd15: r = 4'd13;
		5'd16: r = 4'd7;
		5'd17: r = 4'd8;
		5'd18: r = 4'd9;
		default: r = 4'd10;
	endcase
end
assign ay_ra = {c, r};
wire [7:0] d = m_rd[m*8 +: 8];

// the channel of a tone or level step
wire [1:0] ch = (s < 5'd12) ? tch : (s == 5'd17) ? 2'd0 : (s == 5'd18) ? 2'd1 : 2'd2;

// state: tone counters and outputs per {voice, channel}; noise and envelope per voice
reg [12:0] tone [0:31];         // {output, counter}
reg [21:0] nz [0:7];            // {lfsr, counter}
reg [21:0] env [0:7];           // {hold, par, step, counter}
integer i;
initial begin
	for (i = 0; i < 32; i = i + 1) tone[i] = 13'd0;
	for (i = 0; i < 8; i = i + 1) begin nz[i] = {17'd1, 5'd0}; env[i] = 22'd0; end
end
wire [4:0] ti = {v, ch};
wire [12:0] t_q = tone[ti];
wire [21:0] n_q = nz[v];
wire [21:0] e_q = env[v];

// envelope restarts (R13 written), cleared at the envelope step of the voice
reg [7:0] env_rst = 8'd0;
reg [7:0] tmp = 8'd0, tmp2 = 8'd0;
reg [7:0] mixr = 8'd0;
reg [3:0] shape = 4'd0;
reg [12:0] acc_l = 13'd0, acc_r = 13'd0;

// the level of the channel of a level step
wire [3:0] es = e_q[19:16];
wire eh = e_q[21], ep = e_q[20];
wire [3:0] e_val = eh ? {4{shape[3] & (shape[2] ^ shape[1])}} : ((shape[2] ^ ep) ? es : ~es);
wire [2:0] nch = {1'b0, ch} + 3'd3;
wire on = (mixr[ch] | t_q[12]) & (mixr[nch] | n_q[5]);
function [7:0] level;
	input [3:0] x;
	case (x)
		4'd0: level = 8'h00;  4'd1: level = 8'h03;  4'd2: level = 8'h04;  4'd3: level = 8'h06;
		4'd4: level = 8'h0A;  4'd5: level = 8'h0F;  4'd6: level = 8'h15;  4'd7: level = 8'h22;
		4'd8: level = 8'h28;  4'd9: level = 8'h41;  4'd10: level = 8'h5B; 4'd11: level = 8'h72;
		4'd12: level = 8'h90; 4'd13: level = 8'hB5; 4'd14: level = 8'hD7; default: level = 8'hFF;
	endcase
endfunction
wire [7:0] lev = on ? level(d[4] ? e_val : d[3:0]) : 8'd0;
// weights of the channel: left 2 for A, 1 for B (ABC) / C (ACB); right 2 for C (ABC) / B (ACB), 1 for the other
wire x_acb = acb[m];
wire [1:0] mid = x_acb ? 2'd2 : 2'd1;      // the channel in both sides
wire [1:0] rgt = x_acb ? 2'd1 : 2'd2;      // the channel of the right side
wire [8:0] add_l = (ch == 2'd0) ? {lev, 1'b0} : (ch == mid) ? {1'b0, lev} : 9'd0;
wire [8:0] add_r = (ch == rgt) ? {lev, 1'b0} : (ch == mid) ? {1'b0, lev} : 9'd0;

// tone tick: period {d[3:0], tmp}
wire [11:0] tp = {d[3:0], tmp};
wire [11:0] tc1 = t_q[11:0] + 1'd1;
// noise tick
wire [4:0] nc1 = n_q[4:0] + 1'd1;
// envelope tick: period {tmp2, tmp}, shape d
wire [15:0] ec1 = e_q[15:0] + 1'd1;

reg [7:0] rst_set;
always @* begin
	rst_set = 8'd0;
	for (i = 0; i < 4; i = i + 1)
		if (m_we[i] && m_wa[i*5 +: 4] == 4'd13)
			rst_set[i * 2 + m_wa[i*5 + 4]] = 1'b1;
end

always @(posedge clk) begin
	env_rst <= env_rst | rst_set;
	if (s < 5'd12) begin
		if (!s[0])
			tmp <= d;
		else if (tc1 >= tp)
			tone[ti] <= {~t_q[12], 12'd0};
		else
			tone[ti] <= {t_q[12], tc1};
	end
	if (s == 5'd12) begin
		if (nc1 >= d[4:0])
			nz[v] <= {n_q[5] ^ n_q[8], n_q[21:6], 5'd0};
		else
			nz[v] <= {n_q[21:5], nc1};
	end
	if (s == 5'd13)
		tmp <= d;
	if (s == 5'd14)
		tmp2 <= d;
	if (s == 5'd15) begin
		shape <= d[3:0];
		if (env_rst[v]) begin
			env[v] <= 22'd0;
			env_rst[v] <= rst_set[v];
		end else if (ec1 >= {tmp2, tmp}) begin
			if (!eh) begin
				if (es == 4'd15) begin
					if (!d[3] || d[0])
						env[v] <= {1'b1, ep, es + 1'd1, 16'd0};
					else
						env[v] <= {1'b0, ep ^ d[1], es + 1'd1, 16'd0};
				end else
					env[v] <= {1'b0, ep, es + 1'd1, 16'd0};
			end else
				env[v] <= {e_q[21:16], 16'd0};
		end else
			env[v] <= {e_q[21:16], ec1};
	end
	if (s == 5'd16)
		mixr <= d;
	if (cnt == 8'd255) begin
		ay_l <= acc_l;
		ay_r <= acc_r;
		acc_l <= 13'd0;
		acc_r <= 13'd0;
	end else if (s >= 5'd17 && s <= 5'd19 && aud[m]) begin
		acc_l <= acc_l + add_l;
		acc_r <= acc_r + add_r;
	end
end

endmodule
