vlib modelsim_lib/work
vlib modelsim_lib/msim

vlib modelsim_lib/msim/xpm
vlib modelsim_lib/msim/xil_defaultlib

vmap xpm modelsim_lib/msim/xpm
vmap xil_defaultlib modelsim_lib/msim/xil_defaultlib

vlog -work xpm -64 -incr -mfcu  -sv "+incdir+../../../../../../../../../tools/Xilinx/2025.2/data/rsb/busdef" \
"/tools/Xilinx/2025.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \

vlog -work xil_defaultlib -64 -incr -mfcu  "+incdir+../../../../../../../../../tools/Xilinx/2025.2/data/rsb/busdef" \
"../../../../Piveline.gen/sources_1/ip/rgb2dvi_0/rgb2dvi_0_sim_netlist.v" \


vlog -work xil_defaultlib \
"glbl.v"

