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

sdram_model #(.ROWS(256)) chip(
	.clk(sdr_clk), .ba(sdr_ba), .a(sdr_a), .dqm(sdr_dqm),
	.ras_n(sdr_ras_n), .cas_n(sdr_cas_n), .we_n(sdr_we_n), .dq(sdr_dq)
);

initial $readmemh("roms.hex", chip.mem, 'h10000, 'h13FFF);

wire ce7, ce_cpu, ce14, int_n, vga_half;
wire [8:0] hc, vc, vga_x;
wire [4:0] frame;

reg reset = 1'b1;
always @(posedge clk_bus)
	reset <= ~ready;

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
	.keys(40'd0), .kempston(8'd0), .tape_in(1'b0), .beeper(beeper), .mic(mic),
	.a_req(a_req[0]), .a_we(a_we[0]), .a_addr(a_addr[22:0]), .a_din(a_din[7:0]), .a_ack(a_ack[0]), .a_q(a_q[7:0]),
	.b_req(b_req[0]), .b_addr(b_addr[22:0]), .b_ack(b_ack[0]), .b_q(b_q[7:0]),
	.pix(pix), .late(late)
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
		$display("%t frame %0d: pc %h, fetches %0d, checked reads %0d, sdram r %0d w %0d rfsh %0d, model errors %0d, late %b, 7ffd %h",
			$time, frames_done, last_pc, fetches, checked, chip.reads, chip.writes, chip.refreshes,
			chip.errors, late, m.p7ffd);
		if (frames_done == FRAMES) begin
			dump("screen5.hex", 'hA000);
			dump("screen7.hex", 'hE000);
			errors = chip.errors + data_errors + (late ? 1 : 0) + (fetches < 1000 ? 1 : 0);
			$display("p7ffd %h border %h", m.p7ffd, m.border);
			$display("tb_pentagon: %0d errors", errors);
			$finish;
		end
	end
end

endmodule
