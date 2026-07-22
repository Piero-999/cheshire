# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# OpenOCD script for Cheshire through Olimex ARM-USB-OCD-H adapter.
# On this ZCU102 setup the RISC-V debug TAP is wired to the Olimex, while the
# Digilent HS2 is used by Vivado/hw_server to program the FPGA fabric.

adapter_khz 1000
interface ftdi
ftdi_vid_pid 0x15ba 0x002b
ftdi_layout_init 0x0808 0x0a1b
ftdi_layout_signal nSRST -oe 0x0200
ftdi_layout_signal nTRST -data 0x0100 -oe 0x0100
ftdi_channel 0
set irlen 5

source [file dirname [info script]]/openocd.common.tcl
