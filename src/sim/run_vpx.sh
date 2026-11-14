#!/bin/bash
# The picture of video_out: tb_vpx.v (zx_timing, quad_fb + sram_ctrl, video_out, models of the machines and the SRAM). ISim of ISE 14.7.
set -e
cd "$(dirname "$0")"
if [ -d /c/Xilinx/14.7/ISE_DS/ISE ]; then
	export XILINX=/c/Xilinx/14.7/ISE_DS/ISE
	export PATH=$XILINX/bin/nt64:$XILINX/lib/nt64:$PATH
else
	source /opt/Xilinx/14.7/ISE_DS/settings64.sh > /dev/null
fi
mkdir -p work_vpx
cd work_vpx
cat > vpx.prj <<PRJ
verilog work "../../../modules/rtl/mem/kg_sdpram.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/zx/raster_delay.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/video/quad_fb.v"

verilog work "../../rtl/video/video_out.v"

verilog work "../tb_vpx.v"
PRJ
fuse -prj vpx.prj -top tb_vpx -o tb_vpx.exe > fuse.log 2>&1 || { grep -E "ERROR|WARNING:HDLCompiler" fuse.log; exit 1; }
printf 'run all\nquit\n' > run.tcl
./tb_vpx.exe -tclbatch run.tcl > sim.log 2>&1
grep -E "tb_vpx|row|frame|ERROR" sim.log | head -30
