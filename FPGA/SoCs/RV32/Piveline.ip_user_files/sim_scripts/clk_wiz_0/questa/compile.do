vlib questa_lib/work
vlib questa_lib/msim

vlib questa_lib/msim/xpm
vlib questa_lib/msim/xil_defaultlib

vmap xpm questa_lib/msim/xpm
vmap xil_defaultlib questa_lib/msim/xil_defaultlib

vlog -work xpm -64 -incr -mfcu  -sv "+incdir+../../../../../../../../../tools/Xilinx/2025.2/data/rsb/busdef" "+incdir+../../../../Piveline.gen/sources_1/ip/clk_wiz_0" \
"/tools/Xilinx/2025.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \

vlog -work xil_defaultlib -64 -incr -mfcu  "+incdir+../../../../../../../../../tools/Xilinx/2025.2/data/rsb/busdef" "+incdir+../../../../Piveline.gen/sources_1/ip/clk_wiz_0" \
"../../../../Piveline.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_sim_netlist.v" \


vlog -work xil_defaultlib \
"glbl.v"

