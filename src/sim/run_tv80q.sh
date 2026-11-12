#!/bin/bash
# The equivalence test of tv80_quad with four tv80_core (ISim): ./run_tv80q.sh [clocks]
# Regenerates rtl/tv80/tv80q_core.v from tv80_core.v first (tools/mkquad.py).
set -e -o pipefail
cd "$(dirname "$0")"
CLOCKS=${1:-2000000}
PY=${PYTHON:-python3}
$PY ../../tools/mkquad.py ../rtl/tv80/tv80_core.v ../rtl/tv80/tv80q_core.v
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_q/tmp
	export TEMP="$(cygpath -m "$PWD")/work_q/tmp" TMP="$(cygpath -m "$PWD")/work_q/tmp"
	EXE=./tb_tv80q.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_tv80q ;;
esac
mkdir -p work_q
cat > work_q/tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80_reg.v"
verilog work "../../rtl/tv80/tv80_core.v"
verilog work "../../rtl/tv80/tv80q_reg.v"
verilog work "../../rtl/tv80/tv80q_core.v"
verilog work "../../rtl/tv80/tv80_quad.v"
verilog work "../tb_tv80q.v"
PRJ
cd work_q
fuse -intstyle silent -incremental -prj tb.prj -o $EXE -d CLOCKS=$CLOCKS work.tb_tv80q > fuse.log 2>&1 || { tail -30 fuse.log; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -E "tb_tv80q|differs|quad A|ERROR" || true
grep -q "tb_tv80q: 0 errors" sim.log
