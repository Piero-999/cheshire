#!/usr/bin/env bash
# One run over JTAG — now a view onto reckon.py.
#
# The flow is driven from Python; this name survives because the Vivado scripts
# (ila_capture.tcl, snapshot.tcl) start a run with `exec bash $RUN_TEST` while
# the ILA is armed, and they are deliberately left as they were. The defaults
# are the ones those scripts expect — the self-contained iDMA test and an 8 s
# window — and not the ones the PS flow uses.
#
# Usage: run_test.sh [elf] [sleep_ms]   — unchanged.
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/config.sh"
exec "$HERE/reckon.py" start --elf "${1:-$ELF}" --sleep-ms "${2:-$RUN_SLEEP_MS}"
