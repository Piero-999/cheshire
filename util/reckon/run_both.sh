#!/usr/bin/env bash
# Run both streaming transports back to back and print the two read-backs.
#
# The iDMA run goes first: the sticky flags are reported relative to a baseline,
# but with the clean transport first the absolute readings stay meaningful too.
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
