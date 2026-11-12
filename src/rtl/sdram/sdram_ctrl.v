`timescale 1ns / 1ps
`default_nettype none

/*
 sdram_ctrl.v

 SDRAM controller of the quad core: one SDRAM bank per machine, the four banks served in turn in
 a fixed schedule (docs/ARCHITECTURE.md, "SDRAM").

 clk = clk_sys, 84.09 MHz (11.9 ns). A round is 16 clocks; bank i owns the window of clocks
 4i..4i+3 of each round:

   cnt  4i    ACTIVE   bank i, row
        4i+2  READ     with auto precharge (tRCD 2 clocks = 23.8 ns), or
        4i+3  WRITE    with auto precharge, the data driven for this clock only (acked at 4i already)
        4i+5  the read data is taken on the falling clock in the middle of this period (2.5 clocks
              after READ, CAS latency 2), copied at its end (no logic: half a clock)
        4i+6  its byte into q (ack with it)

 So a bank is opened every 16 clocks (tRC <= 6 clocks), ACTIVE commands of two banks are 4 clocks
 apart (tRRD), the data bus carries one word per window, and a write drives DQ at least a clock
 after the read data of the bank before it has gone. CAS latency 2 with the negative SDRAM clock
 and the read on the falling clock: the timing of the SDRAM of the General Sound of the TS-Conf
 core (rtl/ram/sdram.vhd of karabas-go-core-tsconf), proven on this board.

 Each bank has two channels: A (the CPU, or the ROM loader while the machines are in reset) and B
 (the video fetcher). At the start of its window a bank takes A if A has a request, else B.
 A request is a toggle: the client changes req (with addr, we, din held), the controller changes
 ack when the access is done (q valid for a read). The clients run on clk_bus = clk_sys / 3 from
 the same PLL with phase 0, no synchronisers are needed.

 The ports of the clients are registers on clk_bus here, in both directions (the requests in, the
 acks and data out): the paths from and to the machines across the chip have a period of clk_bus
 (35.7 ns), only the short ones between these registers and the controller have a period of
 clk_sys (11.9 ns). With the four machines (94 % of the slices) the direct paths of 11.9 ns had
 0.03 ns of slack. It costs a clk_bus clock each way (docs/OPTIMIZATION.md, step 0).

 Every REFRESH_ROUNDS rounds one round has no accesses and an AUTO REFRESH at clock 6 (the
 precharge of the last access of the round before ends by clock 3, tRFC < 6 clocks).
 32 rounds = 512 clocks = 6.1 us < 7.8 us (8192 rows in 64 ms).

 Address of a client: byte address in its bank, 23 bits (8 MB): row = addr[22:10], column =
 addr[9:1], addr[0] the byte of the 16-bit word.
*/

module sdram_ctrl #(
	parameter REFRESH_ROUNDS = 32,
	parameter INIT_WAIT = 16'd20000      // clocks before the init sequence (238 us > 100 us)
) (
	input wire clk,
	input wire clk_bus,           // the clients: clk / 3, the same PLL, phase 0

	// channel A, bank i = bits of client i
	input wire [3:0] a_req,
	output reg [3:0] a_ack = 4'b0000,     // clk_bus
	input wire [3:0] a_we,
	input wire [4*23-1:0] a_addr,
	input wire [4*8-1:0] a_din,
	output reg [4*8-1:0] a_q = 32'd0,      // clk_bus

	// channel B (read only)
	input wire [3:0] b_req,
	output reg [3:0] b_ack = 4'b0000,     // clk_bus
	input wire [4*23-1:0] b_addr,
	output reg [4*8-1:0] b_q = 32'd0,      // clk_bus

	output reg ready = 1'b0,

	// SDRAM (no chip select pin on the board: always selected)
	output wire SDR_CLK,
	output reg [1:0] SDR_BA = 2'b00,
	output reg [12:0] SDR_A = 13'd0,
	output reg [1:0] SDR_DQM = 2'b11,
	output wire SDR_RAS_N,
	output wire SDR_CAS_N,
	output wire SDR_WE_N,
	inout wire [15:0] SDR_DQ
);

// commands {RAS_n, CAS_n, WE_n}
localparam CMD_NOP     = 3'b111;
localparam CMD_ACTIVE  = 3'b011;
localparam CMD_READ    = 3'b101;
localparam CMD_WRITE   = 3'b100;
localparam CMD_PRECHG  = 3'b010;
localparam CMD_REFRESH = 3'b001;
localparam CMD_MODE    = 3'b000;

// mode register: single write, CAS latency 2, sequential, burst length 1
localparam [12:0] MODE = 13'b000_1_00_010_0_000;

reg [2:0] cmd = CMD_NOP;
assign {SDR_RAS_N, SDR_CAS_N, SDR_WE_N} = cmd;

// the write data and its output enable: a register per pin, in the IOB (OFF / TFF), so every bit leaves the FPGA
// with the same delay as the command (the outputs of SDR_A, BA, RAS / CAS / WE, DQM are in the IOB too). Without
// the attribute XST kept one dq_oe for 16 pins and dq_out in the fabric: their delay to the pins followed the
// placement (machine 4 hung on the board after the placement changed).
// equivalent_register_removal off: the 16 bits of dq_t are equal (and dq_out[i] = dq_out[i+8]), XST merged them into
// one register, which cannot go into 16 IOBs
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] dq_out = 16'd0;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] dq_t = 16'hFFFF;   // 1: Z
genvar gd;
generate
	for (gd = 0; gd < 16; gd = gd + 1) begin : g_dq
		assign SDR_DQ[gd] = dq_t[gd] ? 1'bZ : dq_out[gd];
	end
endgenerate

// the negative clock of the SDRAM: it rises in the middle of a clk period
ODDR2 #(.DDR_ALIGNMENT("NONE"), .INIT(1'b0), .SRTYPE("SYNC")) u_sdr_clk (
	.Q(SDR_CLK), .C0(clk), .C1(~clk), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0)
);

// ---------------------------------------------------------------------------------------------
// init: wait, PRECHARGE ALL, 2 x AUTO REFRESH, LOAD MODE

reg [15:0] init_cnt = 16'd0;
reg [4:0] init_step = 5'd0;

// ---------------------------------------------------------------------------------------------
// schedule

reg [3:0] cnt = 4'd0;
wire [1:0] cbank = cnt[3:2];
wire [1:0] cphase = cnt[1:0];

reg [4:0] rnd = 5'd0;
reg rfsh_round = 1'b0;

// the access of the current window
reg op_valid = 1'b0;
reg op_ch = 1'b0;        // 0 A, 1 B
reg op_we = 1'b0;
reg [8:0] op_col = 9'd0;
reg op_byte = 1'b0;
reg [7:0] op_din = 8'd0;

// a read in flight: READ leaves its register at the rising clock E0 (rd_sr[0] high after it), DQ
// is taken on the falling clock E2.5 (rd_sr[2] high in E2..E3), copied at E3 (dq_r), its byte into q at E4
reg [3:0] rd_sr = 4'b0000;
reg [15:0] dq_r = 16'd0;
reg [1:0] rd_bank = 2'd0;
reg rd_ch = 1'b0;
reg rd_byte = 1'b0;
reg [15:0] dq_in = 16'd0;

always @(negedge clk)
	if (rd_sr[2])
		dq_in <= SDR_DQ;

reg [7:0] aq0 = 8'd0, aq1 = 8'd0, aq2 = 8'd0, aq3 = 8'd0;
reg [7:0] bq0 = 8'd0, bq1 = 8'd0, bq2 = 8'd0, bq3 = 8'd0;
reg [3:0] a_ack_s = 4'b0000, b_ack_s = 4'b0000;   // the acks on clk_sys

// the ports on clk_bus: requests in, answers out
reg [3:0] a_req_r = 4'b0000, a_we_r = 4'b0000, b_req_r = 4'b0000;
reg [4*23-1:0] a_addr_r = 0, b_addr_r = 0;
reg [4*8-1:0] a_din_r = 0;
always @(posedge clk_bus) begin
	a_req_r <= a_req;
	a_we_r <= a_we;
	a_addr_r <= a_addr;
	a_din_r <= a_din;
	b_req_r <= b_req;
	b_addr_r <= b_addr;
	a_ack <= a_ack_s;
	b_ack <= b_ack_s;
	a_q <= {aq3, aq2, aq1, aq0};
	b_q <= {bq3, bq2, bq1, bq0};
end

wire a_pend = a_req_r[cbank] ^ a_ack_s[cbank];
wire b_pend = b_req_r[cbank] ^ b_ack_s[cbank];
wire [22:0] a_sel = a_addr_r[cbank*23 +: 23];
wire [22:0] b_sel = b_addr_r[cbank*23 +: 23];
wire [7:0] a_dsel = a_din_r[cbank*8 +: 8];

wire [7:0] rd_val = rd_byte ? dq_r[15:8] : dq_r[7:0];

always @(posedge clk) begin
	cmd <= CMD_NOP;
	dq_t <= 16'hFFFF;
	rd_sr <= {rd_sr[2:0], 1'b0};
	if (rd_sr[2])
		dq_r <= dq_in;

	if (!ready) begin
		// ---- init ----
		SDR_DQM <= 2'b11;
		if (init_cnt != INIT_WAIT)
			init_cnt <= init_cnt + 1'd1;
		else begin
			init_step <= init_step + 1'd1;
			case (init_step)
				5'd0: begin cmd <= CMD_PRECHG; SDR_A[10] <= 1'b1; end
				5'd4: cmd <= CMD_REFRESH;
				5'd12: cmd <= CMD_REFRESH;
				5'd20: begin cmd <= CMD_MODE; SDR_A <= MODE; SDR_BA <= 2'b00; end
				5'd24: begin ready <= 1'b1; cnt <= 4'd0; end
				default: ;
			endcase
		end
	end else begin
		// ---- operation ----
		cnt <= cnt + 1'd1;
		if (cnt == 4'd15) begin
			rnd <= (rnd == REFRESH_ROUNDS - 1) ? 5'd0 : rnd + 1'd1;
			rfsh_round <= (rnd == REFRESH_ROUNDS - 1);
		end

		if (rfsh_round) begin
			op_valid <= 1'b0;
			if (cnt == 4'd6)
				cmd <= CMD_REFRESH;
		end else begin
			case (cphase)
				2'd0: begin
					op_valid <= a_pend | b_pend;
					op_ch <= ~a_pend;
					op_we <= a_pend & a_we_r[cbank];
					op_col <= a_pend ? a_sel[9:1] : b_sel[9:1];
					op_byte <= a_pend ? a_sel[0] : b_sel[0];
					op_din <= a_dsel;
					// a write is acked when its window takes it (its address and data are in op_*): the client may
					// send the next request three clocks earlier than at WRITE (a read after a write of the CPU)
					if (a_pend && a_we_r[cbank])
						a_ack_s[cbank] <= ~a_ack_s[cbank];
					if (a_pend | b_pend) begin
						cmd <= CMD_ACTIVE;
						SDR_BA <= cbank;
						SDR_A <= a_pend ? a_sel[22:10] : b_sel[22:10];
					end
				end
				2'd2: begin
					if (op_valid && !op_we) begin
						cmd <= CMD_READ;
						SDR_A <= {4'b0010, op_col};   // A10: auto precharge
						SDR_DQM <= 2'b00;
						rd_sr[0] <= 1'b1;
						rd_bank <= cbank;
						rd_ch <= op_ch;
						rd_byte <= op_byte;
					end
				end
				2'd3: begin
					if (op_valid && op_we) begin
						cmd <= CMD_WRITE;
						SDR_A <= {4'b0010, op_col};
						SDR_DQM <= op_byte ? 2'b01 : 2'b10;
						dq_out <= {op_din, op_din};
						dq_t <= 16'h0000;
					end
				end
				default: ;
			endcase
		end

		// the read data, at cnt 4i+6 (phase 2 of the next bank: no write ack in the same clock; its READ
		// sets rd_bank / rd_ch / rd_byte in this clock, these are still the old ones)
		if (rd_sr[3]) begin
			if (!rd_ch) begin
				case (rd_bank)
					2'd0: aq0 <= rd_val;
					2'd1: aq1 <= rd_val;
					2'd2: aq2 <= rd_val;
					default: aq3 <= rd_val;
				endcase
				a_ack_s[rd_bank] <= ~a_ack_s[rd_bank];
			end else begin
				case (rd_bank)
					2'd0: bq0 <= rd_val;
					2'd1: bq1 <= rd_val;
					2'd2: bq2 <= rd_val;
					default: bq3 <= rd_val;
				endcase
				b_ack_s[rd_bank] <= ~b_ack_s[rd_bank];
			end
		end
	end
end

endmodule
