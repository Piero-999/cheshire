# snapshot.tcl - run the test, THEN immediate-capture the frozen post-run state
# of every ILA probe (trigger = all-don't-care => fires immediately on arm).
# Useful when the event triggers never fire: shows where the streaming froze.
#   source config.sh ; vivado -mode batch -source snapshot.tcl
proc env_or {k d} { return [expr {[info exists ::env($k)] ? $::env($k) : $d}] }
# Repo root: taken from the environment (config.sh exports it), else derived
# from this script's own location -- util/reckon/<script>.tcl -> two levels up.
set REPO     [env_or REPO [file normalize [file join [file dirname [info script]] .. ..]]]
set URL      [env_or HW_SERVER_URL "localhost:3121"]
set DEVICE   [env_or DEVICE       "xczu9_0"]
set ILA_CELL [env_or ILA_CELL     "i_ila"]
set LTX      [env_or LTX          "$REPO/target/xilinx/out/cheshire.zcu102.ltx"]
set RUN_TEST [env_or RUN_TEST     "$REPO/util/reckon/run_test.sh"]
set OUT_DIR  [env_or OUT_DIR      "$REPO/util/reckon/out"]
set DO_VIO_RESET [env_or DO_VIO_RESET "1"]
file mkdir $OUT_DIR

open_hw_manager
catch {connect_hw_server -url $URL}
if {[catch {open_hw_target} e]} { puts "open_hw_target: $e" ; exit 1 }
current_hw_device [get_hw_devices $DEVICE]
set_property PROBES.FILE      $LTX [current_hw_device]
set_property FULL_PROBES.FILE $LTX [current_hw_device]
refresh_hw_device [current_hw_device]

if {$DO_VIO_RESET} {
  catch {
    set vio [lindex [get_hw_vios -of_objects [current_hw_device]] 0]
    proc vset {vio suf val} { set p [get_hw_probes -of_objects $vio -filter "NAME =~ *$suf"]; set_property OUTPUT_VALUE $val $p; commit_hw_vio $p }
    vset $vio vio_0_probe_out2_1 0
    vset $vio vio_0_probe_out1_1 0
    vset $vio vio_0_probe_out3_1 0
    vset $vio vio_0_probe_out0_1 1
    after 200
    vset $vio vio_0_probe_out0_1 0
    puts "== VIO clean reset done =="
  }
}

puts "== Running test (will stall) =="
if {[catch {exec -ignorestderr bash $RUN_TEST} out]} { puts $out } else { puts $out }

# immediate capture of the frozen state
set ila [get_hw_ilas -of_objects [get_hw_devices $DEVICE] -filter "CELL_NAME=~\"$ILA_CELL\""]
catch { foreach p [get_hw_probes -of_objects $ila] { set w [get_property WIDTH $p]; set_property TRIGGER_COMPARE_VALUE "eq${w}'b[string repeat X $w]" $p } }
set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila $ila
after 800
set st [get_property STATUS.CORE_STATUS $ila]
puts "== snapshot status: $st =="
set d [upload_hw_ila_data $ila]
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set csv "$OUT_DIR/snapshot_$stamp.csv"
write_hw_ila_data -csv_file $csv $d
puts "CSV_PATH=$csv"
close_hw_target
disconnect_hw_server
