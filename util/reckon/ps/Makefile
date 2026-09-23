# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# reckon_feed - PS-side (aarch64) producer. Two ways to build it:
#
#   on the board :  make                       (native gcc, the usual case)
#   on the host  :  make CC=aarch64-linux-gnu-gcc
#
# util/reckon/reckon.py sync ships this directory flat, so reckon_ps_mbox.h is
# looked up both next to the source and in its home under sw/include/reckon.

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
CPPFLAGS += -I. -I../../../sw/include/reckon

BIN := reckon_feed

all: $(BIN)

$(BIN): reckon_feed.c reckon_ps_mbox.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $<

# When built in-tree the header still lives under sw/include/reckon; the -I above
# finds it, and this rule keeps the prerequisite satisfiable in both layouts.
reckon_ps_mbox.h:
	@test -f ../../../sw/include/reckon/reckon_ps_mbox.h || \
	  { echo "reckon_ps_mbox.h not found - ship it next to reckon_feed.c"; exit 1; }

clean:
	rm -f $(BIN)

.PHONY: all clean
