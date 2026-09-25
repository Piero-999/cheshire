#!/usr/bin/env bash
# One-command deploy: build SW -> program bitstream -> run the test + readback.
# (No ILA arming; use debug.sh for instrumented runs.)
#
# Usage: deploy.sh [--no-build] [--no-run]
# Needs the JTAG target free: see util/reckon/README.md.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/config.sh"

BUILD=1; RUN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --no-run)   RUN=0; shift ;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

[ "$BUILD" = 1 ] && "$SCRIPT_DIR/build_sw.sh"

echo "== Programming bitstream =="
"$VIVADO" -mode batch -notrace \
  -source "$SCRIPT_DIR/program.tcl" \
  -log "$OUT_DIR/vivado_program.log" -journal "$OUT_DIR/vivado_program.jou"

if [ "$RUN" = 1 ]; then
  echo "== Running test =="
  "$SCRIPT_DIR/run_test.sh"
fi
echo "== Deploy done =="
