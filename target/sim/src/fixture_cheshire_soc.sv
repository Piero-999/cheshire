// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Nicole Narr <narrn@student.ethz.ch>
// Christopher Reinwardt <creinwar@student.ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>

module fixture_cheshire_soc #(
  /// The selected simulation configuration from the `tb_cheshire_pkg`.
  parameter int unsigned SelectedCfg = 32'd0,
  parameter bit          UseDramSys  = 1'b0
);

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;
  import tb_cheshire_pkg::*;

  localparam cheshire_cfg_t DutCfg = TbCheshireConfigs[SelectedCfg];
  localparam longint unsigned SimBramBase  = 64'h4800_0000;
  localparam int unsigned     SimBramBytes = 256 * 1024;

  `CHESHIRE_TYPEDEF_ALL(, DutCfg)

  ///////////
  //  DUT  //
  ///////////

  logic       clk;
  logic       rst_n;
  logic       test_mode;
  logic [1:0] boot_mode;
  logic       rtc;

  axi_llc_req_t axi_llc_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_tx;
  logic uart_rx;

  logic i2c_sda_o;
  logic i2c_sda_i;
  logic i2c_sda_en;
  logic i2c_scl_o;
  logic i2c_scl_i;
  logic i2c_scl_en;

  logic                 spih_sck_o;
  logic                 spih_sck_en;
  logic [SpihNumCs-1:0] spih_csb_o;
  logic [SpihNumCs-1:0] spih_csb_en;
  logic [ 3:0]          spih_sd_o;
  logic [ 3:0]          spih_sd_i;
  logic [ 3:0]          spih_sd_en;

  logic [SlinkNumChan-1:0]                    slink_rcv_clk_i;
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_o;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_i;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o;

  axi_slv_req_t [iomsb(DutCfg.AxiExtNumSlv):0] axi_ext_slv_req;
  axi_slv_rsp_t [iomsb(DutCfg.AxiExtNumSlv):0] axi_ext_slv_rsp;

  cheshire_soc #(
    .Cfg                ( DutCfg ),
    .ExtHartinfo        ( '0 ),
    .axi_ext_llc_req_t  ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( axi_mst_rsp_t ),
    .axi_ext_slv_req_t  ( axi_slv_req_t ),
    .axi_ext_slv_rsp_t  ( axi_slv_rsp_t ),
    .reg_ext_req_t      ( reg_req_t ),
    .reg_ext_rsp_t      ( reg_rsp_t )
  ) dut (
    .clk_i              ( clk       ),
    .rst_ni             ( rst_n     ),
    .test_mode_i        ( test_mode ),
    .boot_mode_i        ( boot_mode ),
    .rtc_i              ( rtc       ),
    .axi_llc_mst_req_o  ( axi_llc_mst_req ),
    .axi_llc_mst_rsp_i  ( axi_llc_mst_rsp ),
    .axi_ext_mst_req_i  ( '0 ),
    .axi_ext_mst_rsp_o  ( ),
    .axi_ext_slv_req_o  ( axi_ext_slv_req ),
    .axi_ext_slv_rsp_i  ( axi_ext_slv_rsp ),
    .reg_ext_slv_req_o  ( ),
    .reg_ext_slv_rsp_i  ( '0 ),
    .intr_ext_i         ( '0 ),
    .intr_ext_o         ( ),
    .xeip_ext_o         ( ),
    .mtip_ext_o         ( ),
    .msip_ext_o         ( ),
    .dbg_active_o       ( ),
    .dbg_ext_req_o      ( ),
    .dbg_ext_unavail_i  ( '0 ),
    .jtag_tck_i         ( jtag_tck    ),
    .jtag_trst_ni       ( jtag_trst_n ),
    .jtag_tms_i         ( jtag_tms    ),
    .jtag_tdi_i         ( jtag_tdi    ),
    .jtag_tdo_o         ( jtag_tdo    ),
    .jtag_tdo_oe_o      ( ),
    .uart_tx_o          ( uart_tx ),
    .uart_rx_i          ( uart_rx ),
    .uart_rts_no        ( ),
    .uart_dtr_no        ( ),
    .uart_cts_ni        ( 1'b0 ),
    .uart_dsr_ni        ( 1'b0 ),
    .uart_dcd_ni        ( 1'b0 ),
    .uart_rin_ni        ( 1'b0 ),
    .i2c_sda_o          ( i2c_sda_o  ),
    .i2c_sda_i          ( i2c_sda_i  ),
    .i2c_sda_en_o       ( i2c_sda_en ),
    .i2c_scl_o          ( i2c_scl_o  ),
    .i2c_scl_i          ( i2c_scl_i  ),
    .i2c_scl_en_o       ( i2c_scl_en ),
    .spih_sck_o         ( spih_sck_o  ),
    .spih_sck_en_o      ( spih_sck_en ),
    .spih_csb_o         ( spih_csb_o  ),
    .spih_csb_en_o      ( spih_csb_en ),
    .spih_sd_o          ( spih_sd_o   ),
    .spih_sd_en_o       ( spih_sd_en  ),
    .spih_sd_i          ( spih_sd_i   ),
    .gpio_i             ( '0 ),
    .gpio_o             ( ),
    .gpio_en_o          ( ),
    .slink_rcv_clk_i    ( slink_rcv_clk_i ),
    .slink_rcv_clk_o    ( slink_rcv_clk_o ),
    .slink_i            ( slink_i ),
    .slink_o            ( slink_o ),
    .vga_hsync_o        ( ),
    .vga_vsync_o        ( ),
    .vga_red_o          ( ),
    .vga_green_o        ( ),
    .vga_blue_o         ( ),
    .usb_clk_i          ( 1'b0 ),
    .usb_rst_ni         ( 1'b1 ),
    .usb_dm_i           ( '0 ),
    .usb_dm_o           ( ),
    .usb_dm_oe_o        ( ),
    .usb_dp_i           ( '0 ),
    .usb_dp_o           ( ),
    .usb_dp_oe_o        ( )
  );

  ////////////////////////
  //  Tristate Adapter  //
  ////////////////////////

  wire i2c_sda;
  wire i2c_scl;

  wire                 spih_sck;
  wire [SpihNumCs-1:0] spih_csb;
  wire [ 3:0]          spih_sd;

  vip_cheshire_soc_tristate vip_tristate (.*);

  ///////////
  //  VIP  //
  ///////////

  axi_mst_req_t axi_slink_mst_req;
  axi_mst_rsp_t axi_slink_mst_rsp;

  assign axi_slink_mst_req = '0;

  vip_cheshire_soc #(
    .DutCfg            ( DutCfg ),
    .UseDramSys        ( UseDramSys ),
    .axi_ext_llc_req_t ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t ( axi_mst_rsp_t )
  ) vip (.*);

  ////////////////
  //  Ext BRAM  //
  ////////////////

  if (DutCfg.AxiExtNumSlv > 0) begin : gen_ext_bram
    localparam int unsigned SimBramWordBytes = DutCfg.AxiDataWidth / 8;
    localparam int unsigned SimBramNumWords  = SimBramBytes / SimBramWordBytes;
    localparam int unsigned SimBramIdxWidth  = $clog2(SimBramNumWords);
    // Keep these as plain literals for Questa parser/vopt compatibility.
    localparam int unsigned SimExtIdWidth    = 8;

    logic [0:0] bram_req;
    logic [0:0] bram_we;
    logic [0:0] bram_rvalid;
    logic [0:0][DutCfg.AddrWidth-1:0] bram_addr;
    logic [0:0][DutCfg.AxiDataWidth-1:0] bram_wdata;
    logic [0:0][DutCfg.AxiDataWidth/8-1:0] bram_strb;
    logic [0:0][DutCfg.AxiDataWidth-1:0] bram_rdata;
    logic [DutCfg.AxiDataWidth-1:0] bram_mem [0:SimBramNumWords-1];

    axi_to_mem #(
      .axi_req_t  ( axi_slv_req_t ),
      .axi_resp_t ( axi_slv_rsp_t ),
      .AddrWidth  ( DutCfg.AddrWidth ),
      .DataWidth  ( DutCfg.AxiDataWidth ),
      .IdWidth    ( SimExtIdWidth ),
      .NumBanks   ( 1 ),
      .BufDepth   ( 1 )
    ) i_ext_bram_axi_to_mem (
      .clk_i       ( clk ),
      .rst_ni     ( rst_n ),
      .busy_o       ( ),
      .axi_req_i    ( axi_ext_slv_req[0] ),
      .axi_resp_o   ( axi_ext_slv_rsp[0] ),
      .mem_req_o    ( bram_req ),
      .mem_gnt_i    ( bram_req ),
      .mem_addr_o   ( bram_addr ),
      .mem_wdata_o  ( bram_wdata ),
      .mem_strb_o   ( bram_strb ),
      .mem_atop_o   ( ),
      .mem_we_o     ( bram_we ),
      .mem_rvalid_i ( bram_rvalid ),
      .mem_rdata_i  ( bram_rdata )
    );

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        bram_rvalid[0] <= 1'b0;
        bram_rdata[0]  <= '0;
      end else begin
        // `axi_to_mem` expects one response-valid pulse per granted request,
        // including writes (B-channel completion depends on this).
        bram_rvalid[0] <= bram_req[0];
        if (bram_req[0]) begin
          logic [DutCfg.AddrWidth-1:0] rel_addr;
          logic [SimBramIdxWidth-1:0] word_idx;
          rel_addr = bram_addr[0] - DutCfg.AddrWidth'(SimBramBase);
          word_idx = rel_addr[$clog2(SimBramBytes)-1:$clog2(SimBramWordBytes)];
          if (bram_we[0]) begin
            for (int unsigned b = 0; b < SimBramWordBytes; ++b) begin
              if (bram_strb[0][b]) bram_mem[word_idx][8*b +: 8] <= bram_wdata[0][8*b +: 8];
            end
          end else begin
            bram_rdata[0] <= bram_mem[word_idx];
          end
        end
      end
    end

    if (DutCfg.AxiExtNumSlv > 1) begin : gen_ext_bram_unused_rsp
      for (genvar i = 1; i <= iomsb(DutCfg.AxiExtNumSlv); ++i) begin : gen_zero_rsp
        assign axi_ext_slv_rsp[i] = '0;
      end
    end
  end else begin : gen_no_ext_bram
    assign axi_ext_slv_rsp = '0;
  end

endmodule
