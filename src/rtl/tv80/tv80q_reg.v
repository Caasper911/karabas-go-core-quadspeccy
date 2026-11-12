// tv80q_reg: the register file of tv80_reg (BC, DE, HL, IX, IY and their alternates) for four CPUs: CPU th uses the
// entries {th, n}. One write port (A), three read ports (A, B, C) as tv80_reg, 32 entries instead of 8.
// For tv80q_core (tools/mkquad.py).
module tv80q_reg (
  input  [1:0] th,
  input        clk,
  input        CEN,
  input        WEH,
  input        WEL,
  input  [2:0] AddrA,
  input  [2:0] AddrB,
  input  [2:0] AddrC,
  input  [7:0] DIH,
  input  [7:0] DIL,
  output [7:0] DOAH,
  output [7:0] DOAL,
  output [7:0] DOBH,
  output [7:0] DOBL,
  output [7:0] DOCH,
  output [7:0] DOCL
  );

  reg [7:0] RegsH [0:31];
  reg [7:0] RegsL [0:31];

  always @(posedge clk)
    if (CEN) begin
      if (WEH) RegsH[{th, AddrA}] <= DIH;
      if (WEL) RegsL[{th, AddrA}] <= DIL;
    end

  assign DOAH = RegsH[{th, AddrA}];
  assign DOAL = RegsL[{th, AddrA}];
  assign DOBH = RegsH[{th, AddrB}];
  assign DOBL = RegsL[{th, AddrB}];
  assign DOCH = RegsH[{th, AddrC}];
  assign DOCL = RegsL[{th, AddrC}];

endmodule
