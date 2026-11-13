#!/bin/bash
# turbosound: tb_ts.v (ISim of ISE 14.7), prints "tb_ts: 0 errors".
# NETLIST=1: against the netlist XST makes of turbosound (netgen -sim), to see what the synthesis did to the generator
# (the levels only: the tone and envelope checks look into the RTL).
set -e
cd "$(dirname "$0")"
if [ -d /c/Xilinx/14.7/ISE_DS/ISE ]; then
	export XILINX=/c/Xilinx/14.7/ISE_DS/ISE
	export PATH=$XILINX/bin/nt64:$XILINX/lib/nt64:$PATH
	mkdir -p work_ts/tmp
	export TEMP="$(cygpath -m "$PWD")/work_ts/tmp" TMP="$(cygpath -m "$PWD")/work_ts/tmp"
else
	source /opt/Xilinx/14.7/ISE_DS/settings64.sh > /dev/null
fi
mkdir -p work_ts
cd work_ts
if [ "${NETLIST:-0}" = 1 ]; then
	printf 'verilog work "../../rtl/sound/ay_psg.v"\nverilog work "../../rtl/sound/turbosound.v"\n' > syn.prj
	mkdir -p xst/projnav.tmp
	cat > syn.xst <<XST
set -tmpdir "xst/projnav.tmp"
set -xsthdpdir "xst"
run
-ifn syn.prj
-ofn turbosound
-ofmt NGC
-p xc6slx25-2-ftg256
-top turbosound
-opt_mode Area
-opt_level 2
-iobuf NO
-keep_hierarchy No
-ram_extract Yes
-rom_extract Yes
-rom_style Auto
-auto_bram_packing YES
-register_balancing Yes
XST
	xst -ifn syn.xst -ofn syn.syr > xst.log 2>&1 || { grep ERROR xst.log syn.syr; exit 1; }
	netgen -sim -ofmt verilog -w turbosound.ngc ts_net.v > netgen.log 2>&1 || { grep ERROR netgen.log; exit 1; }
	printf 'verilog work "ts_net.v"\nverilog work "../tb_ts.v"\nverilog work "%s/verilog/src/glbl.v"\n' "$(cygpath -m "$XILINX" 2>/dev/null || echo "$XILINX")" > t.prj
	fuse -prj t.prj -d NETLIST -top tb_ts -top glbl -L unisims_ver -o tb_ts.exe > fuse.log 2>&1 || { grep ERROR fuse.log; exit 1; }
else
	printf 'verilog work "../../rtl/sound/ay_psg.v"\nverilog work "../../rtl/sound/turbosound.v"\nverilog work "../tb_ts.v"\n' > t.prj
	fuse -prj t.prj -top tb_ts -o tb_ts.exe > fuse.log 2>&1 || { grep ERROR fuse.log; exit 1; }
fi
printf 'run all\nquit\n' > run.tcl
./tb_ts.exe -tclbatch run.tcl 2>&1 | grep -E "ERROR|max left|tone|envelope|tb_ts:"
