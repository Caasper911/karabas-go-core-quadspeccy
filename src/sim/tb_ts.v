`timescale 1ns / 1ps
// tb_ts.v: turbosound (one generator for the eight AY of the four machines, src/sim/run_ts.sh). The machines are
// modelled by their 32 register copies (read with ay_ra as pentagon.v; a write also pulses m_we, for R13).
// A channel with tone and noise off is a constant level (volume 15: FF). ABC: left 2A + B, right 2C + B; ACB: left
// 2A + C, right 2B + C. Checks: the chips of machine 0 alone and together, machine 1 heard or not (aud), ACB, the
// tone (toggles) and envelope (its sequence of values) of machine 0 chip 0 against ay_psg.
// Prints "tb_ts: <n> errors". NETLIST=1 (run_ts.sh): the same against the netlist of XST.
module tb_ts;
reg clk = 0;
always #17.8 clk = ~clk;

reg [3:0] aud = 4'b0001, acb = 4'd0;
reg [3:0] m_we = 4'd0;
reg [4*5-1:0] m_wa = 0;
wire [4:0] ay_ra;
reg [7:0] copy [0:127];
wire [4*8-1:0] m_rd = {copy[{2'd3, ay_ra}], copy[{2'd2, ay_ra}], copy[{2'd1, ay_ra}], copy[{2'd0, ay_ra}]};
wire [12:0] ay_l, ay_r;

turbosound dut(.clk(clk), .aud(aud), .acb(acb), .m_we(m_we), .m_wa(m_wa), .ay_ra(ay_ra), .m_rd(m_rd),
	.ay_l(ay_l), .ay_r(ay_r));

// the reference: ay_psg with the writes of machine 0 chip 0
reg r_we = 0;
reg [3:0] r_wa = 0;
reg [7:0] r_wd = 0;
wire [7:0] r_a, r_b, r_c;
ay_psg ref0(.clk(clk), .we(r_we), .wa(r_wa), .wd(r_wd), .ch_a(r_a), .ch_b(r_b), .ch_c(r_c));

integer i, errors = 0;
initial for (i = 0; i < 128; i = i + 1) copy[i] = 8'd0;

task w(input [1:0] m, input c, input [3:0] r, input [7:0] v);
	begin
		@(posedge clk) begin
			m_we <= 4'd1 << m;
			m_wa[m*5 +: 5] <= {c, r};
			copy[{m, c, r}] <= v;
			if (m == 0 && c == 0) begin r_we <= 1'b1; r_wa <= r; r_wd <= v; end
		end
		@(posedge clk) begin m_we <= 4'd0; r_we <= 1'b0; end
	end
endtask

reg [12:0] mx_l, mx_r;
task expect_lr(input [12:0] l, input [12:0] r, input [8*28-1:0] what);
	begin
		repeat (600) @(posedge clk);   // through a frame of the generator and the output of the next
		mx_l = 0; mx_r = 0;
		repeat (4000) begin
			@(posedge clk);
			if (ay_l > mx_l) mx_l = ay_l;
			if (ay_r > mx_r) mx_r = ay_r;
		end
		$display("%0s: max left %0d right %0d (expect %0d %0d)", what, mx_l, mx_r, l, r);
		if (mx_l != l || mx_r != r) errors = errors + 1;
	end
endtask

`ifndef NETLIST
// tone A of machine 0 chip 0: toggles of the generator and of ay_psg
integer tg_d, tg_r;
reg pd, pr;
task count_tone(input integer n);
	begin
		tg_d = 0; tg_r = 0; pd = dut.tone[0][12]; pr = ref0.to_a;
		repeat (n) begin
			@(posedge clk);
			if (dut.tone[0][12] != pd) begin tg_d = tg_d + 1; pd = dut.tone[0][12]; end
			if (ref0.to_a != pr) begin tg_r = tg_r + 1; pr = ref0.to_a; end
		end
		$display("tone toggles: %0d, ay_psg %0d", tg_d, tg_r);
		if (tg_d > tg_r + 1 || tg_r > tg_d + 1) errors = errors + 1;
	end
endtask

// envelope of machine 0 chip 0: the sequence of its values (each change), against ay_psg
wire [3:0] sh = copy[13];
wire [21:0] e0 = dut.env[0];
wire [3:0] d_env = e0[21] ? {4{sh[3] & (sh[2] ^ sh[1])}} : ((sh[2] ^ e0[20]) ? e0[19:16] : ~e0[19:16]);
reg [3:0] seq_d [0:63], seq_r [0:63];
integer nd, nr;
reg [3:0] ld, lr;
task env_seq(input [3:0] shape, input integer n);
	begin
		// ay_psg restarts with the write, the generator at the envelope step of the voice (env_rst cleared): each
		// sequence from its restart
		w(0, 0, 13, shape);
		@(posedge clk);
		@(posedge clk);   // env_rst of ay_psg, then its state
		nd = 0; nr = 1; lr = ref0.env; seq_r[0] = lr;
		repeat (n) begin
			@(posedge clk);
			if (nd == 0 && !dut.env_rst[0]) begin ld = d_env; seq_d[0] = ld; nd = 1; end
			else if (nd != 0 && d_env != ld && nd < 64) begin ld = d_env; seq_d[nd] = ld; nd = nd + 1; end
			if (ref0.env != lr && nr < 64) begin lr = ref0.env; seq_r[nr] = lr; nr = nr + 1; end
		end
		$write("envelope %b:", shape);
		for (i = 0; i < nd && i < 24; i = i + 1) $write(" %0d", seq_d[i]);
		$write("%c", 8'd10);
		if (nd < nr - 1 || nd > nr + 1) errors = errors + 1;
		for (i = 0; i < nd && i < nr; i = i + 1)
			if (seq_d[i] !== seq_r[i]) begin
				if (errors < 100) $display("  envelope value %0d: %0d, ay_psg %0d", i, seq_d[i], seq_r[i]);
				errors = errors + 1;
			end
	end
endtask
`endif

initial begin
	repeat (100) @(posedge clk);
	w(0, 0, 7, 8'h3F); w(0, 0, 8, 8'd15);
	expect_lr(510, 0, "m0 chip 0: A");
	w(0, 1, 7, 8'h3F); w(0, 1, 8, 8'd15);
	expect_lr(1020, 0, "m0 chips 0 + 1: A");
	w(1, 0, 7, 8'h3F); w(1, 0, 9, 8'd15);
	expect_lr(1020, 0, "m1 B, not heard");
	aud = 4'b0011;
	expect_lr(1275, 255, "m1 B heard (ABC)");
	acb = 4'b0010;
	expect_lr(1020, 510, "m1 B heard (ACB)");
	aud = 4'b0010;
	expect_lr(0, 510, "only m1 heard");
	aud = 4'b0001;
`ifndef NETLIST
	// tone A of m0 chip 0, period 5 and 300
	w(0, 0, 7, 8'h3E); w(0, 0, 0, 8'd5); w(0, 0, 1, 8'd0);
	count_tone(64000);
	w(0, 0, 0, 8'h2C); w(0, 0, 1, 8'h01);
	count_tone(400000);
	// envelope period 1 and 3, shapes \/\/, \___, /|/|, /\/\ ..
	w(0, 0, 8, 8'h10); w(0, 0, 11, 8'd1); w(0, 0, 12, 8'd0);
	env_seq(4'b1010, 12000);
	env_seq(4'b0000, 8000);
	env_seq(4'b1101, 8000);
	w(0, 0, 11, 8'd3);
	env_seq(4'b1110, 30000);
	env_seq(4'b1011, 20000);
`endif
	$display("tb_ts: %0d errors", errors);
	$finish;
end
endmodule
