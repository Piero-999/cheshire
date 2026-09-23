#!/usr/bin/env bash
# Run both streaming transports back to back and print the two read-backs.
#
# Order matters: the iDMA run goes FIRST. underrun_q/overrun_q in
# stream_ctrl_fsm2 are sticky and cleared only by acc_rst_ni, which nothing in
# this flow drives (util/openocd.common.tcl has `reset_config none`). The
# firmware reports the flags as a delta against the baseline it latches at
# bring-up, so a second run is still readable - but running the clean transport
# first keeps the absolute readings meaningful too.
#
# The UART step announcements (BRING UP RECKON / PREPARE DATA IN DDR4 /
# START STREAM / END STREAM) come out on /dev/ttyUSB2; watch them in whatever
# terminal already has that port open. This script deliberately does not touch
# the serial device.
#
# Usage: run_both.sh [sleep_ms]
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/config.sh"

SLEEP_MS="${1:-$RUN_SLEEP_MS}"

for elf in "$ELF_IDMA" "$ELF_CVA6"; do
  echo
  echo "################################################################"
  echo "##  $(basename "$elf")"
  echo "################################################################"
  "$RUN_TEST" "$elf" "$SLEEP_MS" || echo "!! run failed: $elf"
done
