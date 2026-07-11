# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Nicole Narr <narrn@student.ethz.ch>
# Christopher Reinwardt <creinwar@student.ethz.ch>
# Cyril Koenig <cykoenig@iis.ee.ethz.ch>
# Paul Scheffler <paulsc@iis.ee.ethz.ch>
# Yvan Tortorella <yvan.tortorella@gmail.com>
# Mojtaba Rostami <m.rostami1989@gmail.com>

VIVADO ?= vivado

CHS_XILINX_DIR ?= $(CHS_ROOT)/target/xilinx

# Required to split stems
.SECONDEXPANSION:

###############
# Generate HW #
###############

# FPGA-level configuration registers
$(CHS_XILINX_DIR)/src/regs/chs_xilinx_reg_pkg.sv $(CHS_XILINX_DIR)/src/regs/chs_xilinx_reg_top.sv: $(CHS_XILINX_DIR)/src/regs/chs_xilinx_regs.hjson
	$(REGTOOL) -r $< --outdir $(dir $@)

CHS_XILINX_HW := $(CHS_XILINX_DIR)/src/regs/chs_xilinx_reg_pkg.sv $(CHS_XILINX_DIR)/src/regs/chs_xilinx_reg_top.sv

##############
# Xilinx IPs #
##############

.PRECIOUS: $(CHS_XILINX_DIR)/build/%/out.xci

# We split the stem into a board and an IP and resolve dependencies accordingly
$(CHS_XILINX_DIR)/build/%/out.xci: \
		$(CHS_XILINX_DIR)/scripts/impl_ip.tcl \
		$$(wildcard $(CHS_XILINX_DIR)/src/ips/$$*.prj)
	@mkdir -p $(CHS_XILINX_DIR)/build/$*/
	@rm -f $(CHS_XILINX_DIR)/build/$(*)*.log $(CHS_XILINX_DIR)/build/$(*)*.jou
	cd $(CHS_XILINX_DIR)/build/$*/ && $(VIVADO) -mode batch -log ../$*.log -jou ../$*.jou -source $< -tclargs $(subst ., ,$*)

##############
# Bitstreams #
##############

CHS_XILINX_BOARDS := genesys2 vcu128 vcu118 zcu102

CHS_XILINX_IPS_genesys2 := clkwiz vio mig7s
CHS_XILINX_IPS_vcu128   := clkwiz vio ddr4
CHS_XILINX_IPS_vcu118   := clkwiz vio ddr4
#CHS_XILINX_IPS_zcu102	:= clkwiz vio
CHS_XILINX_IPS_zcu102	:= ddr4


$(CHS_XILINX_DIR)/scripts/add_sources.%.tcl: $(CHS_ROOT)/Bender.yml $(CHS_XILINX_HW)
	$(BENDER) script vivado -t fpga -t $* $(CHS_BENDER_RTL_FLAGS) > $@

define chs_xilinx_bit_rule
$$(CHS_XILINX_DIR)/out/%.$(1).bit: \
		$$(CHS_XILINX_DIR)/scripts/impl_sys.tcl \
		$$(CHS_XILINX_DIR)/scripts/add_sources.$(1).tcl \
 		$$(CHS_XILINX_IPS_$(1):%=$(CHS_XILINX_DIR)/build/$(1).%/out.xci) \
		$$(CHS_HW_ALL)
	@mkdir -p $$(CHS_XILINX_DIR)/build/$(1).$$*/
	@rm -f $$(CHS_XILINX_DIR)/build/$$*.$(1)*.log $$(CHS_XILINX_DIR)/build/$$*.$(1)*.jou
	cd $$(CHS_XILINX_DIR)/build/$(1).$$*/ && $$(VIVADO) -mode batch -log ../$$*.$(1).log -jou ../$$*.$(1).jou -source $$< \
		-tclargs $(1) $$* $$(CHS_XILINX_IPS_$(1):%=$$(CHS_XILINX_DIR)/build/$(1).%/out.xci)

CHS_PHONY += chs-xilinx-$(1)
chs-xilinx-$(1): $$(CHS_XILINX_DIR)/out/cheshire.$(1).bit
endef

$(foreach board,$(CHS_XILINX_BOARDS),$(eval $(call chs_xilinx_bit_rule,$(board))))

# Builds bitstreams for all available boards
CHS_XILINX_ALL = $(foreach board,$(CHS_XILINX_BOARDS),$$(CHS_XILINX_DIR)/out/cheshire.$(board).bit)

#############
# Utilities #
#############

# Parameters for HW server (defaults are for a unique board @ localhost).
# `CHS_XILINX_HWS_PATH_$(board)` overrides the device path for each board (default *).
CHS_XILINX_HWS_URL ?= localhost:3121

# We build the dependency file $(2) only if it does not exist; it must not be up to date.
# We add PHONYs for each board as despite the implicit rule, these should be explicit.
define chs_xilinx_util_rule
CHS_PHONY += $(foreach board,$(CHS_XILINX_BOARDS),chs-xilinx-$(1)-$(board))
$(foreach board,$(CHS_XILINX_BOARDS),chs-xilinx-$(1)-$(board)): chs-xilinx-$(1)-%: \
		$$(CHS_XILINX_DIR)/scripts/util/$(1).tcl
	[ -e $(subst %,$$*,$(2)) ] || $$(MAKE) $(subst %,$$*,$(2))
	@mkdir -p $$(CHS_XILINX_DIR)/build/$$*.$(1)/
	@rm -f $$(CHS_XILINX_DIR)/build/$$(*)*.$(1).log $$(CHS_XILINX_DIR)/build/$$(*)*.$(1).jou
	cd $$(CHS_XILINX_DIR)/build/$$*.$(1)/ && $$(VIVADO) -mode batch -log ../$$(*).$(1).log -jou ../$$(*).$(1).jou -source $$< \
		-tclargs $$(CHS_XILINX_HWS_URL) $$(or $$(CHS_XILINX_HWS_PATH_$$*),{*}) $$* $(subst %,$$*,$(2)) 0
endef

# Program bitstream onto board
$(eval $(call chs_xilinx_util_rule,program,$(CHS_XILINX_DIR)/out/cheshire.%.bit))

# Flash onboard memory with the file `CHS_XILINX_FLASH_IMG` (only selected boards).
# `%` is substituted with the board name. The default is the Linux disk image for that board.
CHS_XILINX_FLASH_IMG ?= $(CHS_SW_DIR)/boot/linux.%.gpt.bin
$(eval $(call chs_xilinx_util_rule,flash,$(CHS_XILINX_FLASH_IMG)))

chs-xilinx-clean:
	@echo "Cleaning Xilinx build files for board '$*'..."
	rm -rf $(CHS_XILINX_DIR)/build/$*/

# Split / Out-Of-Context synthesis (ReckOn).
# Splits the full-top synthesis (which OOMs on the 31 GB VM) in two:
#   1) reckon_axi_top synthesized OOC -> reckon_axi_top.dcp
#   2) top with ReckOn as a black-box (impl_sys_ooc.tcl)
# Does not affect the standard flow: `make chs-xilinx-zcu102` is unchanged.

CHS_RECKON_OOC_DIR := $(CHS_XILINX_DIR)/build/reckon_ooc
CHS_RECKON_OOC_DCP := $(CHS_RECKON_OOC_DIR)/reckon_axi_top.dcp

# Stage 1: ReckOn OOC checkpoint
$(CHS_RECKON_OOC_DCP): $(CHS_XILINX_DIR)/scripts/synth_reckon_ooc.tcl $(CHS_HW_ALL)
	@mkdir -p $(CHS_RECKON_OOC_DIR)
	cd $(CHS_ROOT) && $(VIVADO) -mode batch \
		-source  $(CHS_XILINX_DIR)/scripts/synth_reckon_ooc.tcl \
		-log     $(CHS_RECKON_OOC_DIR)/vivado.log \
		-journal $(CHS_RECKON_OOC_DIR)/vivado.jou

CHS_PHONY += chs-xilinx-reckon-ooc
chs-xilinx-reckon-ooc: $(CHS_RECKON_OOC_DCP)

# Stage 2: split top (ReckOn black-box), zcu102 only.
# Same invocation scheme as the standard flow, but with impl_sys_ooc.tcl.
CHS_PHONY += chs-xilinx-zcu102-split
chs-xilinx-zcu102-split: \
		$(CHS_XILINX_DIR)/scripts/impl_sys_ooc.tcl \
		$(CHS_XILINX_DIR)/scripts/add_sources.zcu102.tcl \
		$(CHS_RECKON_OOC_DCP) \
		$(CHS_XILINX_IPS_zcu102:%=$(CHS_XILINX_DIR)/build/zcu102.%/out.xci) \
		$(CHS_HW_ALL)
	@mkdir -p $(CHS_XILINX_DIR)/build/zcu102.cheshire/
	@rm -f $(CHS_XILINX_DIR)/build/cheshire.zcu102*.log $(CHS_XILINX_DIR)/build/cheshire.zcu102*.jou
	cd $(CHS_XILINX_DIR)/build/zcu102.cheshire/ && $(VIVADO) -mode batch \
		-log ../cheshire.zcu102.log -jou ../cheshire.zcu102.jou \
		-source $(CHS_XILINX_DIR)/scripts/impl_sys_ooc.tcl \
		-tclargs zcu102 cheshire $(CHS_XILINX_IPS_zcu102:%=$(CHS_XILINX_DIR)/build/zcu102.%/out.xci)