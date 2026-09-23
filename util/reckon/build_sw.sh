#!/usr/bin/env bash
# Rebuild the streaming ELFs — now a view onto reckon.py.
#
# The flow is driven from Python; this name survives because debug.sh and
# deploy.sh rebuild through it before a capture, and those are left as they were.
#
# Usage: build_sw.sh [elf-path]   — unchanged.
HERE="$(dirname "$(readlink -f "$0")")"
[ $# -ge 1 ] && exec "$HERE/reckon.py" build --elf "$1"
exec "$HERE/reckon.py" build
