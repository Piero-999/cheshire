# Copyright 2018 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Florian Zaruba <zarubaf@iis.ee.ethz.ch>
# Nils Wistoff <nwistoff@iis.ee.ethz.ch>
# Cyril Koenig <cykoenig@iis.ee.ethz.ch>
# Paul Scheffler <cykoenig@iis.ee.ethz.ch>

# Initialize implementation
set xilinx_root [file dirname [file dirname [file normalize [info script]]]]
source ${xilinx_root}/scripts/common.tcl
init_impl $xilinx_root $argc $argv

# Addtional args provide IPs
read_ip [exec realpath {*}[lrange $argv 2 end]]

# Load constraints
import_files -fileset constrs_1 -norecurse ${xilinx_root}/constraints/${proj}.xdc
import_files -fileset constrs_1 -norecurse ${xilinx_root}/constraints/${board}.xdc

# Load RTL sources
source ${xilinx_root}/scripts/add_sources.${board}.tcl

# Set top module
if {${board} == "zcu102"} {
    set_property top cheshire_top_xilinx [current_fileset]
} else {
    set_property top ${proj}_top_xilinx [current_fileset]
}
update_compile_order -fileset sources_1

# Add block design
if {[file exists "${xilinx_root}/scripts/chs-bd-${board}.tcl"]} {
    source ${xilinx_root}/scripts/chs-bd-${board}.tcl
    set_property synth_checkpoint_mode None [get_files  ${project_root}/${proj}.srcs/sources_1/bd/${board}_mpsoc/${board}_mpsoc.bd]
    generate_target all [get_files ${project_root}/${proj}.srcs/sources_1/bd/${board}_mpsoc/${board}_mpsoc.bd]
} else {
    puts "Warning: ${xilinx_root}/scripts/chs-bd-${board}.tcl not found -- skipping block design for ${board}."
}

# export_ip_user_files -of_objects [get_files /home/michelangelo/cheshire/target/xilinx/build/zcu102.cheshire/cheshire.srcs/sources_1/bd/zcu102_mpsoc/zcu102_mpsoc.bd] -no_script -sync -force -quiet
# create_ip_run [get_files -of_objects [get_fileset sources_1] /home/michelangelo/cheshire/target/xilinx/build/zcu102.cheshire/cheshire.srcs/sources_1/bd/zcu102_mpsoc/zcu102_mpsoc.bd]
# launch_runs zcu102_mpsoc_axi_bram_ctrl_0_0_synth_1 zcu102_mpsoc_clk_wiz_0_0_synth_1 zcu102_mpsoc_proc_sys_reset_0_0_synth_1 zcu102_mpsoc_smartconnect_0_0_synth_1 zcu102_mpsoc_vio_0_0_synth_1 zcu102_mpsoc_zynq_ultra_ps_e_0_0_synth_1

# Set synthesis propertiesl
# TODO: investigate resource-affordable retiming
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
#set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

# Elaborate and open design to explore all clocks

#set_param general.maxThreads 8

# rtl_1 disabled: it kept the whole elaborated design (~32 GB) in the Vivado master
# for the entire synth/impl and caused OOM on the 31 GB VM. It only fed clocks.rpt;
# regenerate on demand with: open_run synth_1; report_clocks.
#synth_design -rtl -name rtl_1
#report_clocks -file ${project_root}/clocks.rpt


# FLATTEN_HIERARCHY left at the default 'rebuilt': 'none' (an anti-OOM leftover) blocked
# cross-boundary optimization and hurt timing/area. Memory is no longer the constraint.
#set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]

# Synthesis
launch_runs -jobs $num_jobs synth_1
wait_on_run synth_1
open_run synth_1

# Generate synthesis reports
gen_reports ${project_root}/reports.synth

# Instantiate debug core and ILAs
# TODO: debug this
#insert_ilas {soc_clk}

# Set implementation properties
# Extra timing effort for the real board (opt/place/route + phys_opt targeting timing).
# Roughly doubles impl time but improves slack margin and robustness.
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]

# Implementation
launch_runs -jobs $num_jobs impl_1 -to_step write_bitstream
wait_on_run impl_1
open_run impl_1

# Generate implementation reports
gen_reports ${project_root}/reports.impl

# Check timing constraints
set trep [report_timing_summary -no_header -no_detailed_paths -return_string]
if { ![string match -nocase {*timing constraints are met*} $trep] } {
    puts "Error: Timing constraints not met for ${proj} on ${board}."
    return -code error
}

# Copy out final bitstream
file mkdir ${xilinx_root}/out
file copy -force ${project_root}/${proj}.runs/impl_1/cheshire_top_xilinx.bit \
    ${xilinx_root}/out/${proj}.${board}.bit
file copy -force ${project_root}/${proj}.runs/impl_1/cheshire_top_xilinx.ltx \
    ${xilinx_root}/out/${proj}.${board}.ltx
