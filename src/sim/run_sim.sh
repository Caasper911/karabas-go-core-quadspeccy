#!/bin/bash
# ISim (ISE 14.7) simulation of one Pentagon 128 on the SDRAM controller and the SDRAM model.
#   ./run_sim.sh [frames]     (default 4); prints "tb_pentagon: <n> errors", writes screen.png
# Windows (Git Bash / MSYS2): ISE in /c/Xilinx/14.7/ISE_DS (XILINX_DIR=); Linux: /opt/Xilinx/14.7/ISE_DS.
set -e -o pipefail
cd "$(dirname "$0")"
FRAMES=${1:-4}
PY=${PYTHON:-python3}

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work/tmp
	export TEMP="$(cygpath -m "$PWD")/work/tmp" TMP="$(cygpath -m "$PWD")/work/tmp"
	EXE=./tb_pentagon.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_pentagon ;;
esac

mkdir -p work
printf '\377%.0s' $(seq 16384) > work/ff16k.bin
# SDTEST=1: the SD test program (sdtest.asm) in the place of the ESXDOS ROM
ESX=../roms/esxdos089.bin
if [ "${SDTEST:-0}" = 1 ]; then sjasmplus --nologo sdtest.asm > /dev/null && ESX=work/sdtest.bin; fi
# TESTROM=<name>: <name>.asm in the place of the ESXDOS ROM
if [ -n "${TESTROM:-}" ]; then sjasmplus --nologo $TESTROM.asm > /dev/null && ESX=work/$TESTROM.bin; fi
$PY ../../tools/rom2hex.py ../roms/128.rom ../roms/48.rom work/ff16k.bin $ESX work/roms.hex

cat > work/tb.prj <<PRJ
vhdl work "../../rtl/t80/T80_Pack.vhd"
vhdl work "../../rtl/t80/T80_ALU.vhd"
vhdl work "../../rtl/t80/T80_MCode.vhd"
vhdl work "../../rtl/t80/T80_Reg.vhd"
vhdl work "../../rtl/t80/T80.vhd"
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80_reg.v"
verilog work "../../rtl/tv80/tv80_core.v"
verilog work "../../rtl/tv80/tv80q_reg.v"
verilog work "../../rtl/tv80/tv80q_core.v"
verilog work "../../rtl/tv80/tv80_quad.v"
verilog work "../../rtl/sdram/sdram_ctrl.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/zx/pentagon.v"
verilog work "../../rtl/sd/kg_sd_emu.v"
verilog work "../../../modules/rtl/mem/kg_tdpram.v"
verilog work "../sdram_model.v"
verilog work "../tb_pentagon.v"
verilog work "$(cygpath -m "$XILINX" 2>/dev/null || echo "$XILINX")/verilog/src/glbl.v"
PRJ

cd work
fuse -intstyle silent -incremental -lib unisims_ver -prj tb.prj -o $EXE -timeprecision_vhdl 1ps \
	-d FRAMES=$FRAMES -d RESET_AT=${RESET_AT:-0} -d SDEMU=${SDEMU:-0} -d SDTEST=${SDTEST:-0} -d BANK=${BANK:-0} -d QUAD=${QUAD:-0} -d CUSTOM_ROM=$([ "$ESX" = ../roms/esxdos089.bin ] && echo 0 || echo 1) work.tb_pentagon work.glbl > fuse.log 2>&1 || { tail -30 fuse.log; exit 1; }
echo "run all" > run.tcl
echo "quit" >> run.tcl
$EXE -intstyle silent -tclbatch run.tcl -testplusarg FRAMES=$FRAMES | tee sim.log | grep -vE "^(ISim|This is a|Time resolution|Simulator is doing|Finished circuit|WARNING: A WEBPACK)" || true
cd ..
$PY ../../tools/render_screen.py work/screen5.hex work/screen7.hex work/screen.png || true
grep -q "tb_pentagon: 0 errors" work/sim.log
