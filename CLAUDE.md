# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

QuadSpeccy for the Karabas Go board (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST): up to four Pentagon 128 running
side by side, each in its own SDRAM bank, shown all four on one screen or the selected one full screen. Only the
idea comes from the ReVerSE-U16 QuadSpeccy (`../quadspeccy`); the code is new. The board infrastructure follows
karabas-go-core-tsconf (`../karabas-go-core-tsconf`): the shared modules of the git submodule `modules/`
(karabas-go-modules: `kg_mcu2` of MCU link v2, `kg_pll`, `kg_l2_osd_overlay`, `kg_pcm5102`, memories), the
Makefile build, `core.json` in the kgo2 format. Its `modules/CLAUDE.md` has the rules for those modules (Verilog-2001
for XST, no coregen, tests).

Documentation (Russian) is part of the work: `docs/ARCHITECTURE.md` (clocks, SDRAM schedule and the latency budget,
memory map, video, keyboard), `docs/PLAN.md` (milestones with checkboxes, open questions), `README.md`. Update them
in the same change as the code they describe.

## Build

- `cd src && make go` (synthesis, implementation, bitstream, `quadspeccy.kg`); steps `go-xst`, `go-impl`, `go-core`;
  `go-report` utilization and timing of the last build. Every ISE step also writes to `src/karabas_<board>_build.log` (tee; the
  synthesis starts it, each step adds a `===` header with the time): the user follows it with `tail -f`. Boards (`BOARDS`): go, mini, minig; `make` builds all
  three into `quadspeccy.kg`, `make mini` one of them.
- Windows: MSYS2 make from Git Bash, ISE in `/c/Xilinx/14.7/ISE_DS` (nt64 binaries, 32-bit bitgen). That make passes
  no TEMP / TMP / XILINXD_LICENSE_FILE / USERPROFILE / APPDATA / LOCALAPPDATA to its recipes, the Makefile sets
  them (`ISE_ENV`, exports; without LOCALAPPDATA the Python install manager behind `python` installs a Python
  into `src/`); `$$$$PATH` in `XIL` because
  it is expanded twice (inside `define board`). Linux: sources `/opt/Xilinx/14.7/ISE_DS/settings64.sh`.
- `map` runs single-threaded (`-mt off` in `MAP_OPT`): with `-mt 2` it crashed in Global Placement without a message.
  It still can for one cost table: then change `MAP_T_<board>` (Mini G is on 3).
- XST `-opt_mode Area` (60 % slices against 66 % with Speed); `map -lc off`: `-lc area` packs worse (more slices).
  A change of the Makefile options does not rebuild: `touch karabas_go.ngc` before `make go`.
- Sources are listed in `src/karabas_go.prj` (the shared modules as `"../modules/rtl/..."`; `kg_mcu2` needs `kg_l2_link`
  and the targets `kg_l2_sys`, `_hid`, `_load`, `_osd`, `_img`; nothing of link v1: no `kg_mcu*`).
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
  ports and keeps the answers in RAM, the testbench prints them (2 frames are enough; with `ZC=1` through the
  Z-Controller ports #57 / #77). ESXDOS itself reaches the card
  only after ~23 frames (it clears 5 RAM banks first).
  `MEMTEST=1`: `src/sim/memtest.asm` as ROM 0 (DivMMC off) checks the 1024 KB of Profi (64 page markers, #DFFD
  bits 7..3 written as 1). The SDRAM model has 2 MB per bank (`BOFS = BANK << 20`).
  `TESTROM=<name>` assembles `src/sim/<name>.asm` into that place (`im2test`: IM 2 with a vector table, the
  testbench counts the interrupts its handler saw). The testbench compares every byte the CPU takes (`cpu_di`) with
  the model.
  `SNA=<file>`: a 128K snapshot (`src/sim/sna2sim.py`: its RAM preloaded, ROM 0 and 1 a loader of its registers,
  DivMMC off; e.g. `examples/RageEnd1.sna`, saved where the border effect runs). `BRD_TRACE=<frame>`: every
  change of the border with `vc` / `hc`, and the frame after it as the machine draws it (`work/raster.hex`, run
  FRAMES >= BRD_TRACE + 3; `tools/render_raster.py` makes a PNG of the whole raster). `CPUSEL=0` T80 instead of tv80.
  `SDIMG=1` (with `SDEMU=1`): the card is an 8 MB FAT16 image of `SDFILES` (`src/sim/mkfat.py`: directories / files
  in its root, `NAME=PATH` renames, no spaces in paths; e.g. the `SYS` / `BIN` of an ESXDOS card), reads from it,
  writes into it. `NMI_AT=<frame>` / `NMI2_AT=<frame>`: NMI as F11. Traces: `CPU_SPI=<frame>` every OUT of #EB / #E7
  and IN of #EB other than FF with the PC (what the CPU really gets), `XFER_FROM=<frame>` every byte of `kg_sd_emu`
  (its "master" column is one bit off); with `SDEMU` every command the card takes and its state each frame.
  ESXDOS 0.8.9 uses only CMD17; it boots with an image in ~100 frames (it probes the absent second card, E7 = F5,
  with 6.5-frame timeouts, then waits ~90 frames at 00F6).
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
- `rtl/video/video_out.v`: scan doubler to 896 x 640 at 28 MHz (the 50 Hz VGA raster of TS-Conf), blanking as 720 x
  576p50: visible 736 x 576, back porch 80 clocks (16 lit the picture on some monitors: black level clamp); the OSD
  (`kg_l2_osd_overlay`, bitmap 256 x 128) centres itself on `de` at scale 2, high active syncs (inverted around it),
  2 clocks latency for picture, syncs and de. Quad view: quadrants 368 x 288 from a frame buffer in the SRAM (`quad_fb.v`,
  `rtl/mem/sram_ctrl.v`, 2M x 16 on all three boards): every machine writes its `pix` on its raster (4 pixels a word),
  `video_out` reads a word every 4 clocks (`fb_rd` 2 clocks ahead); two frames per machine (`fb` flips at line 256,
  read `~fb`: no tear, as the rasters are in lock step); `pentagon` always fetches on its raster.
  `src/sim/run_vpx.sh` checks every pixel (with an SRAM model), quad and full screen.
  The left border of a picture row is the pixels 392..447 of the native line before (the beam draws them before the
  paper of the next line): `video_out` reads it from line `dl - 1` in the row that starts in `vga_half` 0, `quad_fb`
  writes it into the row of `vc + 1` (a border change in the blank, Rage, was a step at the left of the paper).
  (Scale 4/3 at 21 MHz was tried on the board: looked bad, removed.)
- 1024 KB RAM as Profi in every `pentagon` (OSD Memory size 128K / 1024K per machine, soft switch 24 + n, `mem1024`;
  128K: #DFFD not decoded, AY ports as Pentagon): #DFFD (full address) 2..0 = page bits 5..3 of C000, the other bits
  ignored; pages 0..7 at p * 16 KB, 8..63 at 0x100000 + p * 16 KB of the bank; the AY ports need A13 = 1.
- Z-Controller in every `pentagon` (always on): #57 = the SPI data as #EB of the DivMMC, #77 bit 1 the card select
  (#E7 bit 0 for the DivMMC), read #77 = FC; the same SPI master and card (OSD SD card works with the DivMMC off).
- `rtl/hid/zx_kbd.v`: HID report to the ZX matrix, Win+1..4 / Win+arrows (2 x 2 neighbour) / Win+` hotkeys (and `sel_we` from the mouse).
- `rtl/hid/quad_mouse.v`: the USB mouse; full screen: Kempston mouse of the selected machine (a position per machine,
  ports `#FADF` / `#FBDF` / `#FFDF` in `pentagon`); quad view: a 16 x 16 cursor (`video_out`), a left press selects the
  quadrant's machine, a double click (20 vsyncs) makes it full screen; the middle button in the full screen goes back
  to the quad view (always: the OSD item Mouse middle was removed, soft switch 22 unused); hidden after 244 VGA vsyncs without a report.
  `src/sim/run_mouse.sh`.
- TurboSound (AY only, no YM): each `pentagon` keeps the 32 registers of its two AY (distributed RAM, ports
  `#FFFD` / `#BFFD`, chip select by writing `FF` / `FE` to `#FFFD`). One time-multiplexed generator for the eight AY
  (`rtl/sound/turbosound.v`, the logic of `ay_psg.v`): a frame of 256 clocks, 32 per voice {machine, chip}; it reads
  the registers from the copies of all machines at once (`ay_ra`, async distributed RAM), its state in distributed
  RAM; a write of R13 restarts the envelope at the voice's next envelope step. Heard: the selected machine and those
  with OSD Sound = Always (soft switches 28..31); AY mix ABC / ACB per machine (15..18); the sum limited to 0x7FFF.
  `src/sim/run_ts.sh` (`tb_ts.v`: the mix, aud, ACB, tone and envelope against `ay_psg`; `NETLIST=1` the levels on the
  XST netlist); `src/sim/tb_ay.v` checks `ay_psg` (the reference); `run_sim.sh TESTROM=tstest`: chip select and
  writes / reads of both chips by a machine (the testbench prints the AY writes).
- OSD hotkeys are matched by the MCU firmware in the order of `core.json` "osd", and an item without a modifier matches
  with any modifier held: an item with a modifier must come before the one with the same key without it ("Reset All"
  Menu+F12 above "Reset" F12).
- TR-DOS / Beta Disk (Go only, `ENABLE_FDC` of `quadspeccy`; 0 on Mini / Mini G: not built): one `hrdy_fdc` (VG93 model
  `rtl/vg93/` copied from karabas-go-core-tsconf, on clk_bus) on the bus of the machine of OSD FDD (soft switch 23) if
  its DivMMC is off; `pentagon` `dos` as Pentagon (3Dxx with ROM 48, off on a fetch from RAM), ROM 2 = TR-DOS,
  ports #1F/#3F/#5F/#7F, #FF in TR-DOS. Drive pins active high as the tsconf Go core. `run_sim.sh` with `TRDOS=1`.
- Boards: the whole core is `rtl/quadspeccy.v` (parameters `NUM_MACHINES`, `ENABLE_FDC`, `MCU_BURST_MAX_MHZ`; outputs
  `clk_bus`, so the net of the ucf has that name in the top, `clk_8`, video with `de`, `audio_l/r`); the board tops
  `karabas_{go,mini,minig}_top.v` put it on the pins (as `kg_osca_system` of karabas_go_v6z80p). Pins of the Mini /
  Mini G ucf from karabas-go-core-tsconf, the timing block the same in the three. Go: VGA + PCM5102 + FDC. Mini:
  HDMI (`rtl/video/hdmi_out.v`: pixel clock = clk_bus, `kg_dcm` x5, `hdmi_tx` INPUT_REG 1, 48 kHz), sigma-delta,
  FT_CLK_OUT 8 MHz (the FT812 needs it). Mini G: PCM5102 with `DIV_BITS` 2 (55 kHz as tsconf; 1 as Go is silent), MCU_SCK IBUFG + BUFG (32 MHz), FT_SPI_SCK from
  before the BUFG. OSD "FDD" has `"boards": ["go"]`.
- `quadspeccy.v`: `NUM_MACHINES` (4), ROM loader FIFO (MCU address bits 17..16 = machine, 15..0 = offset in
  the ROM area at 0x20000 of its bank; 1024 words, `LD_READY` while 512 are free, CAPS bit 4), soft switches `SW`
  of `kg_mcu2` (`SW_INIT` = the defaults of `core.json` "osd").
- MCU link v2 (`kg_mcu2`, karabas-go-firmware `docs/link_v2.md`, `modules/docs/link_v2_migration.md`; `core.json`
  `"link": 2`, firmware 26111315 or later): `MCU_INT` on the IO1 line (Go `MCU_SPI_IO[0]`, Mini / Mini G
  `MCU_IO[1]`, the pins of the v1 burst READY), IO0 an input; `KBD` whole report = the old `kb_status` / `kb_dat0..5`,
  `MS_WR` a clock per mouse report (`quad_mouse`), the file mounter on `SDC_*` (the `sdc_*` of `img_sdc`).
- `rtl/tv80`: the CPU, tv80 of karabas_go_v6z80p (with its X / Y flag fixes of CPI / CPD). One for the four machines:
  `tv80_quad.v` around `tv80q_core.v`, which `tools/mkquad.py` GENERATES from `tv80_core.v` (every register a memory of
  4 indexed by the CPU of the clock; never edit `tv80q_core.v`, change the generator or `tv80_core.v` and run
  `src/sim/run_tv80q.sh`, which regenerates and runs the equivalence test against four `tv80_core`). Slot 2k of the 8
  clocks of a T-state is the cen of machine k, 2k+1 its peek (outputs live, then kept). `pentagon` `CPU = 2` (outside
  CPU, ports `x_*`); `CPU = 1` its own tv80, `CPU = 0` T80 (version 351 of TS-Conf), kept as references. tv80 gives
  `mc` / `ts` one-hot, the wrapper turns them into T80 numbers.
