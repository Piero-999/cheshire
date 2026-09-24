# ila_capture.tcl - one-shot ReckOn debug capture, fully headless.
#   1. connect to hw_server / open target
#   2. (optional) program the device
#   3. (optional) clean VIO reset (boot_mode=0, uart_sel=0, pulse reset)
#   4. arm the ILA on the chosen trigger  (non-blocking)
#   5. run the test via OpenOCD+GDB        (exec, blocks ~15-25 s)
#   6. collect the capture -> CSV + .ila in $OUT_DIR
#
# Run via debug.sh, or: vivado -mode batch -source ila_capture.tcl
# NOTE: close the Vivado GUI Hardware Manager first (it owns the JTAG target).
proc env_or {k d} { return [expr {[info exists ::env($k)] ? $::env($k) : $d}] }

# Repo root: taken from the environment (config.sh exports it), else derived
# from this script's own location -- util/reckon/<script>.tcl -> two levels up.
set REPO         [env_or REPO [file normalize [file join [file dirname [info script]] .. ..]]]
set URL          [env_or HW_SERVER_URL "localhost:3121"]
set DEVICE       [env_or DEVICE       "xczu9_0"]
set ILA_CELL     [env_or ILA_CELL     "i_ila"]
set BIT          [env_or BIT          "$REPO/target/xilinx/out/cheshire.zcu102.bit"]
set LTX          [env_or LTX          "$REPO/target/xilinx/out/cheshire.zcu102.ltx"]
set RUN_TEST     [env_or RUN_TEST     "$REPO/util/reckon/run_test.sh"]
set OUT_DIR      [env_or OUT_DIR      "$REPO/util/reckon/out"]
set TRIG_PROBE   [env_or TRIG_PROBE   "reckon_axi_top_0/new_batch_fsm"]
set TRIG_VALUE   [env_or TRIG_VALUE   "eq1'b1"]
set TRIG_POS     [env_or TRIG_POS     "1024"]
set DO_PROGRAM   [env_or DO_PROGRAM   "0"]
set DO_VIO_RESET [env_or DO_VIO_RESET "1"]
file mkdir $OUT_DIR

# ---------------------------------------------------------------- connect ----
open_hw_manager
if {[catch {connect_hw_server -url $URL} e]} { puts "connect_hw_server: $e (already connected?)" }
if {[catch {open_hw_target} e]}             { puts "open_hw_target: $e -- is the Vivado GUI Hardware Manager open? Close it." ; exit 1 }
current_hw_device [get_hw_devices $DEVICE]
# Associate probe definitions (.ltx) FIRST so probe names resolve even when we
# are not programming (otherwise get_hw_probes returns nothing).
set_property PROBES.FILE      $LTX [current_hw_device]
set_property FULL_PROBES.FILE $LTX [current_hw_device]

# ---------------------------------------------------------------- program ----
if {$DO_PROGRAM} {
  puts "== Programming device =="
  set_property PROGRAM.FILE $BIT [current_hw_device]
  program_hw_devices [current_hw_device]
}
refresh_hw_device [current_hw_device]
if {$DO_PROGRAM} {
  puts "== waiting for DDR4/MIG calibration =="
  after 5000
  refresh_hw_device [current_hw_device]
}

# ------------------------------------------------------------- VIO reset -----
# probe_out0=vio_reset  out1=vio_boot_mode  out2=vio_boot_mode_sel  out3=vio_uart_sel
# (suffix pattern match tolerates the hierarchical prefix in the probe name.)
if {$DO_VIO_RESET} {
  if {[catch {
    set vio [lindex [get_hw_vios -of_objects [current_hw_device]] 0]
    proc vset {vio suf val} {
      set p [get_hw_probes -of_objects $vio -filter "NAME =~ *$suf"]
      set_property OUTPUT_VALUE $val $p
      commit_hw_vio $p
    }
    vset $vio vio_0_probe_out2_1 0   ;# boot_mode_sel = 0
    vset $vio vio_0_probe_out1_1 0   ;# boot_mode     = 0 (bootrom idle, no SPI before our bring-up)
    vset $vio vio_0_probe_out3_1 0   ;# uart_sel      = 0
    vset $vio vio_0_probe_out0_1 1   ;# reset asserted
    after 200
    vset $vio vio_0_probe_out0_1 0   ;# reset released
    puts "== VIO clean reset done (boot_mode=0, uart_sel=0, RST pulse) =="
  } e]} { puts "!! VIO reset skipped ($e) -- controlla i nomi probe_out con: get_hw_probes -of_objects \[get_hw_vios\]" }
}

# ---------------------------------------------------------------- arm ILA ----
set ila [get_hw_ilas -of_objects [get_hw_devices $DEVICE] -filter "CELL_NAME=~\"$ILA_CELL\""]
# Clear every probe's trigger compare to don't-care, then set only the chosen one.
catch {
  foreach p [get_hw_probes -of_objects $ila] {
    set w [get_property WIDTH $p]
    set_property TRIGGER_COMPARE_VALUE "eq${w}'b[string repeat X $w]" $p
  }
}
set_property CONTROL.TRIGGER_POSITION $TRIG_POS $ila
set_property TRIGGER_COMPARE_VALUE $TRIG_VALUE [get_hw_probes $TRIG_PROBE -of_objects $ila]
run_hw_ila $ila
puts "== ILA armed: trigger '$TRIG_PROBE' $TRIG_VALUE  (pos $TRIG_POS) =="

# ------------------------------------------------------------- run test ------
puts "== Launching test (OpenOCD + GDB) =="
if {[catch {exec -ignorestderr bash $RUN_TEST} out]} { puts $out } else { puts $out }

# --------------------------------------------------------------- collect -----
after 1000
set st [get_property STATUS.CORE_STATUS $ila]
puts "== ILA STATUS.CORE_STATUS after run: $st =="
# A completed capture reports IDLE on some Vivado versions and FULL on others; only
# a status still mentioning WAIT/ARM means the trigger never fired.
if {![string match -nocase "*wait*" $st] && ![string match -nocase "*arm*" $st]} {
  set d [upload_hw_ila_data $ila]
  set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
  set csv   "$OUT_DIR/capture_$stamp.csv"
  set ilaf  "$OUT_DIR/capture_$stamp.ila"
  write_hw_ila_data -csv_file $csv $d
  write_hw_ila_data $ilaf $d
  puts "== Capture saved =="
  puts "CSV_PATH=$csv"
  puts "ILA_PATH=$ilaf"
} else {
  puts "########################################################################"
  puts "## TRIGGER DID NOT FIRE (status=$st)."
  puts "## The event '$TRIG_PROBE $TRIG_VALUE' did NOT happen during the run."
  puts "## That is itself a finding: that signal never asserted."
  puts "########################################################################"
}
close_hw_target
disconnect_hw_server
