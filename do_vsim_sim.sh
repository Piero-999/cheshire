export MTI_VCO_MODE=64;
vsim  -c -do "source target/sim/vsim/compile.cheshire_soc.tcl;"
vsim  -c -do "source target/sim/vsim/start.cheshire_soc.tcl"
#vcd file waves.vcd
#vcd add -r /tb_cheshire_soc/*
#run -all
#vcd flush
