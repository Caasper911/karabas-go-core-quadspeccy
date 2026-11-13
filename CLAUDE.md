# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Quad Speccy for the Karabas Go board (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST): up to four Pentagon 128 running
side by side, each in its own SDRAM bank, shown all four on one screen or the selected one full screen. Only the
idea comes from the ReVerSE-U16 Quad Speccy (`../quadspeccy`); the code is new. The board infrastructure follows
karabas-go-core-tsconf (`../karabas-go-core-tsconf`): the shared modules of the git submodule `modules/`
(karabas-go-modules: `kg_mcu`, `kg_pll`, `kg_osd_overlay`, `kg_soft_switches`, `kg_pcm5102`, memories), the
Makefile build, `core.json` in the kgo2 format. Its `modules/CLAUDE.md` has the rules for those modules (Verilog-2001
for XST, no coregen, tests).

Documentation (Russian) is part of the work: `docs/ARCHITECTURE.md` (clocks, SDRAM schedule and the latency budget,
memory map, video, keyboard), `docs/PLAN.md` (milestones with checkboxes, open questions), `README.md`. Update them
in the same change as the code they describe.

## Build

- `cd src && make go` (synthesis, implementation, bitstream, `quadspeccy.kg`); steps `go-xst`, `go-impl`, `go-core`;
  `go-report` utilization and timing of the last build. Every ISE step also writes to `src/karabas_<board>_build.log` (tee; the
  synthesis starts it, each step adds a `===` header with the time): the user follows it with `tail -f`. Only the Go board for now (`BOARDS`); Mini / Mini G later.
- Windows: MSYS2 make from Git Bash, ISE in `/c/Xilinx/14.7/ISE_DS` (nt64 binaries, 32-bit bitgen). That make passes
  no TEMP / TMP / XILINXD_LICENSE_FILE / USERPROFILE / APPDATA / LOCALAPPDATA to its recipes, the Makefile sets
  them (`ISE_ENV`, exports; without LOCALAPPDATA the Python install manager behind `python` installs a Python
  into `src/`); `$$$$PATH` in `XIL` because
  it is expanded twice (inside `define board`). Linux: sources `/opt/Xilinx/14.7/ISE_DS/settings64.sh`.
- `map` runs single-threaded (`-mt off` in `MAP_OPT`): with `-mt 2` it crashed in Global Placement without a message.
- XST `-opt_mode Area` (60 % slices against 66 % with Speed); `map -lc off`: `-lc area` packs worse (more slices).
  A change of the Makefile options does not rebuild: `touch karabas_go.ngc` before `make go`.
- Sources are listed in `src/karabas_go.prj` (the shared modules as `"../modules/rtl/..."`; `kg_mcu` needs all its
  `kg_mcu_*` decoders, `kg_osd_overlay` needs `kg_pix_doubler`).
- `make_core.py` comes from the sibling `../karabas-go-tools/make_core/`.
- Synthesis takes about 2 minutes, the whole build about 10. Check the `.syr` "Clock Information" (clk_sys, clk_bus,
  MCU_SCK only) and that there are no latches; `make go-report` for LUTs and "All constraints were met".

## Simulation

- `src/sim/run_sim.sh [frames]` (ISim of ISE 14.7, Windows or Linux): `tb_pentagon.v` = one machine, `sdram_ctrl`,
  `zx_timing` and `sdram_model.v` (a behavioural SDRAM that counts violations of tRCD, tRC, tRP, tRRD, tRFC, open /
  closed banks), the ROMs preloaded (`tools/rom2hex.py`). It checks every CPU read against the model, that no read
  needed wait states (`late`) and that the CPU runs; prints `tb_pentagon: 0 errors`; writes the screen pages 5 / 7 as
  `src/sim/work/screen.png` (`tools/render_screen.py`). About 40 s per frame; the 128 ROM sits in a delay loop for the
  first ~10 frames (PC 0004..0008, 11027 opcode fetches per frame = 71680 / 26 * 4).
- Options of `run_sim.sh` (environment): `RESET_AT=<frame>` a warm reset of the machine; `SDEMU=1` `kg_sd_emu` on
  the SPI of the DivMMC with a model of `img_sdc` (a 64 MB image, sector bytes = lba ^ index); `SDTEST=1` puts
  `src/sim/sdtest.asm` (sjasmplus) in the place of the ESXDOS ROM: it sends CMD0/8/55/41/58/17 through the DivMMC
  ports and keeps the answers in RAM, the testbench prints them (2 frames are enough). ESXDOS itself reaches the card
  only after ~23 frames (it clears 5 RAM banks first).
  `TESTROM=<name>` assembles `src/sim/<name>.asm` into that place (`im2test`: IM 2 with a vector table, the
  testbench counts the interrupts its handler saw). The testbench compares every byte the CPU takes (`cpu_di`) with
  the model.
- `src/sim/run_t80cmp.sh [clocks]`: T80 (the reference) against tv80_core clock for clock (`tb_t80cmp.v`, made from
  `tb_tv80q.v`): opcode fetch starts, port writes, interrupt acknowledges (`MEMWR` also memory writes). Found the
  timing bugs of tv80 fixed in `tv80_core.v` / `tv80_mcode.v` (marked `karabas:`). A hierarchical reference from
  Verilog into the VHDL T80 crashes fuse.
- ISim 14.7 has no `$writememh` / `$clog2`; inputs of VHDL from Verilog all connected.

## Design (see docs/ARCHITECTURE.md)

- Clocks: one PLL, clk_sys 84.09 MHz (SDRAM), clk_bus 28.03 MHz = clk_sys / 3 (everything else). Requests between
  them are toggles without synchronisers, timed by the derived PERIOD.
- `rtl/sdram/sdram_ctrl.v`: bank i = machine i, 16-clock round, window 4i..4i+3 per bank (ACT, READ at +2 or WRITE
  at +3, auto precharge, CL2, read data on the falling clock), channel A (CPU / ROM loader) before B (video),
  a refresh round every 32. The timing relation (negative SDRAM clock, CL2, sample 2.5 clocks after READ) is that of
  the General Sound SDRAM of TS-Conf, proven on this board: do not change it without hardware tests.
- `rtl/zx/zx_timing.v`: one Pentagon raster for all machines (lock step). `rtl/zx/pentagon.v`: one machine: T80
  instantiated directly (the T80se bus logic is in the wrapper) so the SDRAM read starts at T1; WAIT_n is only a
  safety net (`late`). Video fetch through channel B at most 12 pixels ahead.
- `rtl/video/video_out.v`: scan doubler to 896 x 640 at 28 MHz (the 50 Hz VGA raster of TS-Conf, so the OSD
  offsets 120 / 72 fit). Quad view at scale 4/3: pixels of 21 MHz = clk_sys / 4; `video_out` makes the next VGA row on
  clk_bus (paper from the `qbuf` of the machines, a line fetched two rows ahead) into the row buffer of
  `rtl/video/video_px.v`, the last stage on clk_sys (`ce_px` = ce28 full screen / ce21 quad, `V_CLK`, the OSD with
  `CE_IN` of `kg_osd_overlay`: branch `osd-ce` of the submodule). `src/sim/run_vpx.sh` checks every pixel.
- `rtl/hid/zx_kbd.v`: HID report to the ZX matrix, Win+1..4 / Win+` hotkeys.
- TurboSound (AY only, no YM): each `pentagon` keeps the 32 registers of its two AY (distributed RAM, ports
  `#FFFD` / `#BFFD`, chip select by writing `FF` / `FE` to `#FFFD`); only two generators `rtl/sound/ay_psg.v` in the top,
  for the selected machine, loaded from its copies when the selection changes. OSD AY mix ABC / ACB per machine
  (soft switches 15..18). `src/sim/tb_ay.v` checks the generator (tone, envelope shapes).
- `karabas_go_top.v`: `NUM_MACHINES` (1 now), ROM loader FIFO (MCU address bits 17..16 = machine, 15..0 = offset in
  the ROM area at 0x20000 of its bank), soft switches in the order of `core.json` "osd".
- `rtl/tv80`: the CPU, tv80 of karabas_go_v6z80p (with its X / Y flag fixes of CPI / CPD). One for the four machines:
  `tv80_quad.v` around `tv80q_core.v`, which `tools/mkquad.py` GENERATES from `tv80_core.v` (every register a memory of
  4 indexed by the CPU of the clock; never edit `tv80q_core.v`, change the generator or `tv80_core.v` and run
  `src/sim/run_tv80q.sh`, which regenerates and runs the equivalence test against four `tv80_core`). Slot 2k of the 8
  clocks of a T-state is the cen of machine k, 2k+1 its peek (outputs live, then kept). `pentagon` `CPU = 2` (outside
  CPU, ports `x_*`); `CPU = 1` its own tv80, `CPU = 0` T80 (version 351 of TS-Conf), kept as references. tv80 gives
  `mc` / `ts` one-hot, the wrapper turns them into T80 numbers.
