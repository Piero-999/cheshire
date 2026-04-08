// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz <tbenz@iis.ee.ethz.ch>

/// This package contains parameters used in the simulation environment
package tb_cheshire_pkg;

    import cheshire_pkg::*;

    // A dedicated RT config
    function automatic cheshire_cfg_t gen_cheshire_rt_cfg();
      cheshire_cfg_t ret = DefaultCfg;
      ret.AxiRt = 1;
      return ret;
    endfunction

    // A dedicated CLIC config
    function automatic cheshire_cfg_t gen_cheshire_clic_cfg();
      cheshire_cfg_t ret = DefaultCfg;
      ret.Clic = 1;
      return ret;
    endfunction

    // A dedicated vCLIC config
    function automatic cheshire_cfg_t gen_cheshire_vclic_cfg();
      cheshire_cfg_t ret = DefaultCfg;
      ret.Clic = 1;
      ret.ClicVsclic = 1;
      ret.ClicVsprio = 1;
      ret.ClicNumVsctxts = 4;
      ret.ClicPrioWidth = 1;
      return ret;
    endfunction

    // A dedicated config with LLC bypass and an external BRAM window.
    function automatic cheshire_cfg_t gen_cheshire_ext_bram_cfg();
      cheshire_cfg_t ret = DefaultCfg;
      ret.LlcNotBypass = 1;
      ret.AxiExtNumSlv = 1;
      ret.AxiExtNumRules = 1;
      ret.AxiExtRegionIdx[0] = 0;
      ret.AxiExtRegionStart[0] = 64'h4800_0000;
      ret.AxiExtRegionEnd[0] = 64'h4804_0000; // 256 KiB
      return ret;
    endfunction

    // Number of Cheshire configurations
    localparam int unsigned NumCheshireConfigs = 32'd5;

    // Assemble a configuration array indexed by a numeric parameter
    localparam cheshire_cfg_t [NumCheshireConfigs-1:0] TbCheshireConfigs = {
      gen_cheshire_ext_bram_cfg(), // 4: External BRAM window @0x4800_0000
      gen_cheshire_vclic_cfg(), // 3: vCLIC-enabled configuration
      gen_cheshire_clic_cfg(),  // 2: CLIC-enabled configuration
      gen_cheshire_rt_cfg(),    // 1: RT-enabled configuration
      DefaultCfg                // 0: Default configuration
    };

endpackage
