# program.tcl - program the ZCU102 with the current bitstream + probes (.ltx).
# Run headless: vivado -mode batch -source program.tcl
# NOTE: close the Vivado GUI Hardware Manager first (it owns the JTAG target).
proc env_or {k d} { return [expr {[info exists ::env($k)] ? $::env($k) : $d}] }
set URL    [env_or HW_SERVER_URL "localhost:3121"]
set DEVICE [env_or DEVICE        "xczu9_0"]
set BIT    [env_or BIT "/home/bevilacqua/pierochs/cheshire/target/xilinx/out/cheshire.zcu102.bit"]
set LTX    [env_or LTX "/home/bevilacqua/pierochs/cheshire/target/xilinx/out/cheshire.zcu102.ltx"]

open_hw_manager
if {[catch {connect_hw_server -url $URL} e]} { puts "connect_hw_server: $e" }
if {[catch {open_hw_target} e]}             { puts "open_hw_target: $e -- GUI HW Manager aperto? Chiudilo." ; exit 1 }
current_hw_device [get_hw_devices $DEVICE]

puts "== Programming $DEVICE with $BIT =="
set_property PROGRAM.FILE      $BIT [current_hw_device]
set_property PROBES.FILE       $LTX [current_hw_device]
set_property FULL_PROBES.FILE  $LTX [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device  [current_hw_device]
puts "== Programmed. =="
close_hw_target
disconnect_hw_server
