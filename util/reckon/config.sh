#!/usr/bin/env bash
# Configuration for the ILA and Vivado scripts, which are bash and tcl.
# What the flow also uses comes from config.py; the rest is only needed here.
# The tcl scripts read these through $::env(...).
eval "$(python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/config.py" --sh)"

export VIVADO="${VIVADO:-/tools/XilEnt/Vivado/2024.2/bin/vivado}"
export HW_SERVER_URL="${HW_SERVER_URL:-localhost:3121}"
export DEVICE="${DEVICE:-xczu9_0}"
export ILA_CELL="${ILA_CELL:-i_ila}"
export LTX="${LTX:-$REPO/target/xilinx/out/cheshire.zcu102.ltx}"

# Defaults of a run started from here, not from the flow.
export ELF="${ELF:-$ELF_IDMA}"
export RUN_SLEEP_MS="${RUN_SLEEP_MS:-8000}"
export RUN_TEST="${RUN_TEST:-$SCRIPT_DIR/run_test.sh}"

# ILA trigger defaults (debug.sh overrides them on its command line).
# TRIG_VALUE contains a single quote, Vivado's compare syntax: setting it in
# two steps avoids the quoting pitfall in a ${:-} default.
export TRIG_PROBE="${TRIG_PROBE:-reckon_axi_top_0/new_batch_fsm}"
[ -n "${TRIG_VALUE:-}" ] || TRIG_VALUE="eq1'b1"
export TRIG_VALUE
export TRIG_POS="${TRIG_POS:-1024}"
