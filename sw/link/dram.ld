/* Copyright 2022 ETH Zurich and University of Bologna. */
/* Licensed under the Apache License, Version 2.0, see LICENSE for details. */
/* SPDX-License-Identifier: Apache-2.0 */

/* Nicole Narr <narrn@student.ethz.ch> */
/* Christopher Reinwardt <creinwar@student.ethz.ch> */
/* Paul Scheffler <paulsc@iis.ee.ethz.ch> */

INCLUDE common.ldh

SECTIONS {
  __stack_pointer$  = ORIGIN(dram) + LENGTH(dram) - 8;

  .text : {
    *(.text._start)
    *(.text)
    *(.text.*)
  } > dram

  .misc : ALIGN(16) {
    *(.rodata)
    *(.rodata.*)
    *(.data)
    *(.data.*)
    *(.srodata)
    *(.srodata.*)
    *(.sdata)
    *(.sdata.*)
  } > dram

  /* Define the bounds INSIDE the output section. Assigning them from the location
     counter outside it does not track a section allocated via `> dram`: both symbols
     collapsed to the same address, so _start's zeroing loop cleared 0 bytes and every
     .bss variable came up holding whatever the previous run left in DRAM. */
  .bss : ALIGN(32) {
    __bss_start = .;
    *(.bss)
    *(.bss.*)
    *(.sbss)
    *(.sbss.*)
    . = ALIGN(32);
    __bss_end = .;
  } > dram

  .bulk : ALIGN(16) {
    *(.bulk)
    *(.bulk.*)
  } > dram
}
