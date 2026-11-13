#!/bin/bash
# quad_mouse: tb_mouse.v (ISim of ISE 14.7), prints "tb_mouse: 0 errors".
set -e
cd "$(dirname "$0")"
if [ -d /c/Xilinx/14.7/ISE_DS/ISE ]; then
	export XILINX=/c/Xilinx/14.7/ISE_DS/ISE
	export PATH=$XILINX/bin/nt64:$XILINX/lib/nt64:$PATH
else
	source /opt/Xilinx/14.7/ISE_DS/settings64.sh > /dev/null
fi
mkdir -p work_ms
cd work_ms
printf 'verilog work "../../rtl/hid/quad_mouse.v"\nverilog work "../tb_mouse.v"\n' > m.prj
fuse -prj m.prj -top tb_mouse -o tb_mouse.exe > fuse.log 2>&1 || { grep ERROR fuse.log; exit 1; }
printf 'run all\nquit\n' > run.tcl
./tb_mouse.exe -tclbatch run.tcl 2>&1 | grep -E "ERROR|tb_mouse:"
