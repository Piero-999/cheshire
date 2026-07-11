
#
# impl_sys_ooc.tcl -- split-synthesis variant of impl_sys.tcl.
# Same as impl_sys.tcl, but synthesizes the top with reckon_axi_top as a BLACK BOX,
# linking the pre-built OOC checkpoint (build/reckon_ooc/reckon_axi_top.dcp), so the
# top's synth_1 does not elaborate ReckOn and the memory peak stays low.
#
# Prerequisite: the .dcp must exist (run `make chs-xilinx-reckon-ooc` first, or
# vivado -source scripts/synth_reckon_ooc.tcl).
#
# Does not replace impl_sys.tcl: alternative path selected from the Makefile with
# `make chs-xilinx-zcu102-split`. Same args as impl_sys.tcl: <board> <proj> <ip.xci ...>

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

# OOC: drop ReckOn's internal RTL and link the pre-synthesized checkpoint. The top
# keeps xilinx_zcu102_reckon_chs_top.sv, axi_layer.sv and axi_rf.sv; the 13 files
# internal to reckon_axi_top are removed and supplied by the .dcp as a black-box netlist.
set repo_root [file dirname [file dirname $xilinx_root]]
set rrtl      ${repo_root}/hw/axi_reckon/rtl
set reckon_rtl [list \
    ${rrtl}/BRAM_2ports_we.v \
    ${rrtl}/BRAM_1port_we.v \
    ${rrtl}/RAM_wrapper_new.v \
    ${rrtl}/aer_decoder.v \
    ${rrtl}/reckon_axi_top.v \
    ${rrtl}/reckon/lfsr_neur_stochround.v \
    ${rrtl}/reckon/lfsr_noise_neur.v \
    ${rrtl}/reckon/lfsr_oneur_stochround.v \
    ${rrtl}/reckon/lfsr_winp_wrec.v \
    ${rrtl}/reckon/lfsr_wout.v \
    ${rrtl}/reckon/reckon.v \
    ${rrtl}/reckon/spi_slave.v \
    ${rrtl}/reckon/srnn.v \
]
foreach f $reckon_rtl {
    set obj [get_files -quiet $f]
    if {[llength $obj]} {
        remove_files $obj
        puts "OOC: removed from fileset -> $f"
    } else {
        puts "OOC: (not in fileset, skipping) -> $f"
    }
}

set reckon_dcp ${xilinx_root}/build/reckon_ooc/reckon_axi_top.dcp
if {![file exists $reckon_dcp]} {
    error "OOC: missing checkpoint: $reckon_dcp -- run 'make chs-xilinx-reckon-ooc' first."
}
add_files -norecurse $reckon_dcp
puts "OOC: added black-box checkpoint -> $reckon_dcp"

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

# Set synthesis properties
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

# rtl_1 disabled: it kept the whole elaborated design (~32 GB) in the Vivado master
# for the entire synth/impl and caused OOM. Regenerate clocks.rpt post-synth with:
# open_run synth_1; report_clocks.

set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]

# Synthesis (ReckOn is a black-box: the peak does not include elaborating ReckOn)
launch_runs -jobs $num_jobs synth_1
wait_on_run synth_1
open_run synth_1

# Generate synthesis reports
gen_reports ${project_root}/reports.synth

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
