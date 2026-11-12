#!/bin/bash
# T80 (reference) against tv80_core, clock for clock (ISim): ./run_t80cmp.sh [clocks]
set -e -o pipefail
cd "$(dirname "$0")"
CLOCKS=${1:-2000000}
PY=${PYTHON:-python3}
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_c/tmp
	export TEMP="$(cygpath -m "$PWD")/work_c/tmp" TMP="$(cygpath -m "$PWD")/work_c/tmp"
	EXE=./tb_t80cmp.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_t80cmp ;;
esac
mkdir -p work_c
cat > work_c/tb.prj <<PRJ
vhdl work "../../rtl/t80/T80_Pack.vhd"
vhdl work "../../rtl/t80/T80_ALU.vhd"
vhdl work "../../rtl/t80/T80_MCode.vhd"
vhdl work "../../rtl/t80/T80_Reg.vhd"
vhdl work "../../rtl/t80/T80.vhd"
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80_reg.v"
verilog work "../../rtl/tv80/tv80_core.v"
verilog work "../tb_t80cmp.v"
PRJ
cd work_c
fuse -intstyle silent -incremental -prj tb.prj -o $EXE -d CLOCKS=$CLOCKS work.tb_t80cmp > fuse.log 2>&1 || { tail -30 fuse.log; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -E "tb_t80cmp|differs|quad A|ERROR" || true
grep -q "tb_t80cmp: 0 errors" sim.log
