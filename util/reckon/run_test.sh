#!/usr/bin/env bash
# One run over JTAG, through reckon.py start.
#
# ila_capture.tcl and snapshot.tcl start a run with `exec bash $RUN_TEST` while
# the ILA is armed. The defaults are the ones those scripts expect: the
# self-contained iDMA test and an 8 s window.
#
# Usage: run_test.sh [elf] [sleep_ms]
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/config.sh"
exec "$HERE/reckon.py" start --elf "${1:-$ELF}" --sleep-ms "${2:-$RUN_SLEEP_MS}"
