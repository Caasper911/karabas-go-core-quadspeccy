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
  offsets 120 / 72 fit). The quad view (milestone 3) is planned as a VGA-timed fetch per machine, not a frame buffer.
- `rtl/hid/zx_kbd.v`: HID report to the ZX matrix, Win+1..4 / Win+` hotkeys.
- `karabas_go_top.v`: `NUM_MACHINES` (1 now), ROM loader FIFO (MCU address bits 17..16 = machine, 15..0 = offset in
  the ROM area at 0x20000 of its bank), soft switches in the order of `core.json` "osd".
- `rtl/tv80`: the CPU (tv80 of karabas_go_v6z80p, with its X / Y flag fixes of CPI / CPD), `pentagon` `CPU = 1`; its
  `mc` / `ts` are one-hot, the wrapper turns them into T80 numbers. `rtl/t80`: T80 (version 351 of TS-Conf),
  `CPU = 0`, kept as the reference.
