transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

vlib work
vlib riviera/xpm
vlib riviera/xil_defaultlib

vmap xpm riviera/xpm
vmap xil_defaultlib riviera/xil_defaultlib

vlog -work xpm  -incr "+incdir+../../../../../../../../../tools/Xilinx/2025.2/data/rsb/busdef" -l xpm -l xil_defaultlib \
"/tools/Xilinx/2025.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \

vlog -work xil_defaultlib  -incr -v2k5 "+incdir+../../../../../../../../../tools/Xilinx/2025.2/data/rsb/busdef" -l xpm -l xil_defaultlib \
"../../../../Piveline.gen/sources_1/ip/rgb2dvi_0/rgb2dvi_0_sim_netlist.v" \


vlog -work xil_defaultlib \
"glbl.v"

