#!/usr/bin/env bash
# One-command ReckOn debug loop:
#   [build SW] -> [program] -> VIO clean reset -> arm ILA -> run test -> dump capture.
#
# Usage:
#   debug.sh [options]
#     --build              rebuild the SW ELF first
#     --program            reprogram the bitstream (clean state; slower)
#     --no-vio             skip the VIO reset
#     --trigger P V        ILA trigger probe + compare, e.g.
#                            --trigger reckon_axi_top_0/TIME_TICK  "eq1'b1"
#                            --trigger reckon_axi_top_0/CS         "eq1'b1"
#                          (default: new_batch_fsm eq1'b1)
#     --pos N              trigger position in the 16384-sample window (default 1024)
#
# Prereq: close the Vivado GUI Hardware Manager (it owns the JTAG target).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/config.sh"

BUILD=0
export DO_PROGRAM=0
export DO_VIO_RESET=1

while [ $# -gt 0 ]; do
  case "$1" in
    --build)    BUILD=1; shift ;;
    --program)  export DO_PROGRAM=1; shift ;;
    --no-vio)   export DO_VIO_RESET=0; shift ;;
    --trigger)  export TRIG_PROBE="$2"; export TRIG_VALUE="$3"; shift 3 ;;
    --pos)      export TRIG_POS="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

[ "$BUILD" = 1 ] && "$SCRIPT_DIR/build_sw.sh"

echo "== Vivado batch: program=$DO_PROGRAM vio_reset=$DO_VIO_RESET trigger='$TRIG_PROBE $TRIG_VALUE' =="
"$VIVADO" -mode batch -notrace \
  -source "$SCRIPT_DIR/ila_capture.tcl" \
  -log "$OUT_DIR/vivado.log" -journal "$OUT_DIR/vivado.jou" \
  | tee "$OUT_DIR/last_run.txt"

# Summarize the newest capture, if any.
CSV="$(ls -t "$OUT_DIR"/capture_*.csv 2>/dev/null | head -1 || true)"
if [ -n "${CSV:-}" ]; then
  echo
  "$SCRIPT_DIR/summarize.sh" "$CSV"
fi
