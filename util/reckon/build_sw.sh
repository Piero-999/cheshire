#!/usr/bin/env bash
# Rebuild the streaming ELFs, through reckon.py build. debug.sh and deploy.sh
# call it before a capture.
#
# Usage: build_sw.sh [elf-path]
HERE="$(dirname "$(readlink -f "$0")")"
[ $# -ge 1 ] && exec "$HERE/reckon.py" build --elf "$1"
exec "$HERE/reckon.py" build
