// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Nicole Narr <narrn@student.ethz.ch>
// Christopher Reinwardt <creinwar@student.ethz.ch>
// Cyril Koenig <cykoenig@iis.ee.ethz.ch>
// Yann Picod <ypicod@ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>

`include "cheshire/typedef.svh"
`include "phy_definitions.svh"

// TODO: Expose more IO: unused SPI CS, Serial Link, etc.

module cheshire_top_xilinx import cheshire_pkg::*; #(
  localparam int unsigned Ddr4CsNWidth = 1,
  localparam int unsigned Ddr4DmDbiNWidth = 2,
  localparam int unsigned Ddr4DqWidth = 16,
  localparam int unsigned Ddr4DqsWidth = 2
)(
  input  logic  sys_clk_p,
  input  logic  sys_clk_n,

`ifdef USE_RESET
  input  logic  sys_reset,
`endif
// `ifdef USE_RESETN
//   input  logic  sys_resetn,
// `endif

// `ifdef USE_SWITCHES
//   input logic       test_mode_i,
//   input logic [1:0] boot_mode_i,
// `endif

`ifdef USE_NUM_LED
  output logic [`USE_NUM_LED-1:0] led_o,
`endif

`ifdef USE_JTAG
  input  logic  jtag_tck_i,
  input  logic  jtag_tms_i,
  input  logic  jtag_tdi_i,
  output logic  jtag_tdo_o,
`ifdef USE_JTAG_TRSTN
  input  logic  jtag_trst_ni,
`endif
`ifdef USE_JTAG_VDDGND
  output logic  jtag_vdd_o,
  output logic  jtag_gnd_o,
`endif
`endif

// `ifdef USE_I2C
//   inout  wire   i2c_scl_io,
//   inout  wire   i2c_sda_io,
// `endif

// `ifdef USE_SD
//   input  logic        sd_cd_i,
//   output logic        sd_cmd_o,
//   inout  wire  [3:0]  sd_d_io,
//   output logic        sd_reset_o,
//   output logic        sd_sclk_o,
// `endif

// `ifdef USE_FAN
//   input  logic [3:0]  fan_sw,
//   output logic        fan_pwm,
// `endif

// `ifdef USE_VGA
//   // VGA Colour signals
//   output logic        vga_hsync_o,
//   output logic        vga_vsync_o,
//   output logic [4:0]  vga_red_o,
//   output logic [5:0]  vga_green_o,
//   output logic [4:0]  vga_blue_o,
// `endif

`ifdef USE_DDR4
  `DDR4_INTF(Ddr4CsNWidth, Ddr4DmDbiNWidth, Ddr4DqWidth, Ddr4DqsWidth)
`endif
`ifdef USE_DDR3
  `DDR3_INTF
`endif

// `ifdef USE_USB
//   inout  wire [UsbNumPorts-1:0] usb_dm_io,
//   inout  wire [UsbNumPorts-1:0] usb_dp_io,
// `endif

  output logic  uart_tx_o_cp2108,
  output logic  uart_tx_o_gpio,

  input  logic  uart_rx_i_cp2108,
  input  logic  uart_rx_i_gpio
);

  logic       vio_reset, vio_boot_mode_sel, vio_uart_sel;
  logic [1:0] boot_mode, vio_boot_mode;
  logic       sys_rst;

  ///////////////////////
  //  Cheshire Config  //
  ///////////////////////

  import cheshire_pkg::*;

  // Use default config as far as possible
  function automatic cheshire_cfg_t gen_cheshire_xilinx_cfg();
    cheshire_cfg_t ret  = DefaultCfg;
    ret.RtcFreq         = 1000000;
    //ret.AxiExtNumSlv    = 1;

    // LLC in bypass, DDR4 connessa direttamente
    ret.LlcNotBypass      = 0;   // <-- bypass LLC (default è 1)
    ret.LlcOutConnect     = 1;   // <-- mantieni la porta output verso DRAM
    ret.LlcOutRegionStart = 'h8000_0000;
    ret.LlcOutRegionEnd   = 64'h1_0000_0000;
    // 2 porte slave esterne:
    //   [0] = axi_layer (register file, controllo ReckOn)
    //   [1] = BRAM bridge (accesso dati BRAM 256KB via AXI)
    //
    ret.AxiExtNumSlv    = 2;
    ret.AxiExtNumRules  = 2;

    // Porta 0: axi_layer registri — 64 KB @ 0x4000_0000
    ret.AxiExtRegionIdx  [0] = 0;
    ret.AxiExtRegionStart[0] = 64'h4000_0000;
    ret.AxiExtRegionEnd  [0] = 64'h4001_0000;

    // Porta 1: BRAM ReckOn — 256 KB @ 0x4800_0000
    // BRAM ha ADDR_WIDTH=16 → 2^16 = 65536 words × 4 byte = 256 KB
    ret.AxiExtRegionIdx  [1] = 1;
    ret.AxiExtRegionStart[1] = 64'h4800_0000;
    ret.AxiExtRegionEnd  [1] = 64'h4804_0000;
    // Enable one external AXI master ingress (PS -> Cheshire).
    ret.AxiExtNumMst    = 1;
    `ifdef USE_USB
      ret.Usb = 1;
    `else
      ret.Usb = 0;
    `endif
    `ifdef USE_CFG_REGS
      ret.RegExtNumSlv   = 1;
      ret.RegExtNumRules = 1;
      // Mirror the address map of the internal configuration registers.
      // * 256K @ AXI: 0x4000_0000
      // * 4K   @ AXI: 0x4100_0000
      // * 256K @ Reg: 0x4200_0000
      // * 4K   @ Reg: 0x4300_0000
      ret.RegExtRegionIdx   [0] = 0;
      ret.RegExtRegionStart [0] = 32'h4300_0000;
      ret.RegExtRegionEnd   [0] = 32'h4300_1000;
    `endif
    `ifdef USE_VCLIC
      ret.Clic = 1;
      ret.ClicVsclic = 1;
      ret.ClicVsprio = 1;
      ret.ClicNumVsctxts = 4;
      ret.ClicPrioWidth = 1;
    `endif
    ret.BusErr          = 0;
    ret.SerialLink      = 0;
    ret.SpiHost         = 1;
    ret.Vga             = 0;
    ret.I2c             = 0;
    ret.Gpio            = 1;

    return ret;
  endfunction

  // Vivado 2020.2 does not support chained function-call + field access
  // (e.g. gen_axi_in(cfg).num_in). Use a wrapper that stores the result first.
  function automatic int unsigned get_num_axi_in(cheshire_cfg_t cfg);
    automatic axi_in_t tmp = gen_axi_in(cfg);
    return int'(tmp.num_in);
  endfunction

  localparam AxiRegsNin  = 4;   // era 3 — aggiunto in_reg[3] per status streaming
  localparam AxiRegsNout = 8;
  localparam UseAxiGPIO  = 1;

  // Configure cheshire for FPGA mapping
  localparam cheshire_cfg_t FPGACfg = gen_cheshire_xilinx_cfg();
  `CHESHIRE_TYPEDEF_ALL(, FPGACfg)

  // Explicit localparams: Vivado 2020.2 cannot resolve struct member accesses
  // (e.g. FPGACfg.AddrWidth) directly inside typedef/signal dimension expressions.
  localparam int unsigned CfgAddrWidth     = FPGACfg.AddrWidth;
  localparam int unsigned CfgAxiDataWidth  = FPGACfg.AxiDataWidth;
  localparam int unsigned CfgAxiUserWidth  = FPGACfg.AxiUserWidth;
   localparam int unsigned CfgAxiExtNumMst  = FPGACfg.AxiExtNumMst;
  localparam int unsigned CfgAxiMstIdWidth = FPGACfg.AxiMstIdWidth;
  localparam int unsigned CfgAxiExtNumSlv  = FPGACfg.AxiExtNumSlv;
  localparam int unsigned CfgNumAxiIn      = get_num_axi_in(FPGACfg);

  // Narrow (32-bit) AXI types for the BRAM side of the DW converter
  localparam int unsigned BramDataWidth = 32;
  localparam int unsigned BramStrbWidth = BramDataWidth / 8;  // 4
  localparam int unsigned AxiSlvIdWidth = CfgAxiMstIdWidth + $clog2(CfgNumAxiIn);
  typedef logic [CfgAddrWidth-1:0]    bram_addr_t;
  typedef logic [AxiSlvIdWidth-1:0]   bram_id_t;
  typedef logic [BramDataWidth-1:0]   bram_data_t;
  typedef logic [BramStrbWidth-1:0]   bram_strb_t;
  typedef logic [CfgAxiUserWidth-1:0] bram_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_bram, axi_bram_req_t, axi_bram_rsp_t, \
      bram_addr_t, bram_id_t, bram_data_t, bram_strb_t, bram_user_t)
`ifdef USE_MPSOC
  // PS HPM0 AXI parameters (fixed by Zynq UltraScale+ PS).
  localparam int unsigned PsAxiAddrWidth = 40;
  localparam int unsigned PsAxiDataWidth = 128;
  localparam int unsigned PsAxiIdWidth   = 16;

  typedef logic [CfgAddrWidth-1:0]         ps_axi_addr_t;
  typedef logic [PsAxiIdWidth-1:0]         ps_axi_id_t;
  typedef logic [PsAxiDataWidth-1:0]       ps_axi_data_t;
  typedef logic [PsAxiDataWidth/8-1:0]     ps_axi_strb_t;
  typedef logic [CfgAxiUserWidth-1:0]      ps_axi_user_t;
  `AXI_TYPEDEF_ALL_CT(ps_axi, ps_axi_req_t, ps_axi_rsp_t, \
      ps_axi_addr_t, ps_axi_id_t, ps_axi_data_t, ps_axi_strb_t, ps_axi_user_t)

  typedef logic [CfgAxiDataWidth-1:0]      ps_axi_dw_data_t;
  typedef logic [CfgAxiDataWidth/8-1:0]    ps_axi_dw_strb_t;
  `AXI_TYPEDEF_ALL_CT(ps_axi_dw, ps_axi_dw_req_t, ps_axi_dw_rsp_t, \
      ps_axi_addr_t, ps_axi_id_t, ps_axi_dw_data_t, ps_axi_dw_strb_t, ps_axi_user_t)

  // Flattened PS AXI interface from block design wrapper.
  logic [PsAxiIdWidth-1:0]     ps_m_axi_hpm0_awid;
  logic [PsAxiAddrWidth-1:0]   ps_m_axi_hpm0_awaddr;
  logic [7:0]                  ps_m_axi_hpm0_awlen;
  logic [2:0]                  ps_m_axi_hpm0_awsize;
  logic [1:0]                  ps_m_axi_hpm0_awburst;
  logic                        ps_m_axi_hpm0_awlock;
  logic [3:0]                  ps_m_axi_hpm0_awcache;
  logic [2:0]                  ps_m_axi_hpm0_awprot;
  logic [3:0]                  ps_m_axi_hpm0_awqos;
  logic [15:0]                 ps_m_axi_hpm0_awuser;
  logic                        ps_m_axi_hpm0_awvalid;
  logic                        ps_m_axi_hpm0_awready;

  logic [PsAxiDataWidth-1:0]   ps_m_axi_hpm0_wdata;
  logic [PsAxiDataWidth/8-1:0] ps_m_axi_hpm0_wstrb;
  logic                        ps_m_axi_hpm0_wlast;
  logic                        ps_m_axi_hpm0_wvalid;
  logic                        ps_m_axi_hpm0_wready;

  logic [PsAxiIdWidth-1:0]     ps_m_axi_hpm0_bid;
  logic [1:0]                  ps_m_axi_hpm0_bresp;
  logic                        ps_m_axi_hpm0_bvalid;
  logic                        ps_m_axi_hpm0_bready;

  logic [PsAxiIdWidth-1:0]     ps_m_axi_hpm0_arid;
  logic [PsAxiAddrWidth-1:0]   ps_m_axi_hpm0_araddr;
  logic [7:0]                  ps_m_axi_hpm0_arlen;
  logic [2:0]                  ps_m_axi_hpm0_arsize;
  logic [1:0]                  ps_m_axi_hpm0_arburst;
  logic                        ps_m_axi_hpm0_arlock;
  logic [3:0]                  ps_m_axi_hpm0_arcache;
  logic [2:0]                  ps_m_axi_hpm0_arprot;
  logic [3:0]                  ps_m_axi_hpm0_arqos;
  logic [15:0]                 ps_m_axi_hpm0_aruser;
  logic                        ps_m_axi_hpm0_arvalid;
  logic                        ps_m_axi_hpm0_arready;

  logic [PsAxiIdWidth-1:0]     ps_m_axi_hpm0_rid;
  logic [PsAxiDataWidth-1:0]   ps_m_axi_hpm0_rdata;
  logic [1:0]                  ps_m_axi_hpm0_rresp;
  logic                        ps_m_axi_hpm0_rlast;
  logic                        ps_m_axi_hpm0_rvalid;
  logic                        ps_m_axi_hpm0_rready;

  ps_axi_req_t                 ps_axi_req;
  ps_axi_rsp_t                 ps_axi_rsp;
  ps_axi_dw_req_t              ps_axi_dw_req;
  ps_axi_dw_rsp_t              ps_axi_dw_rsp;
  axi_mst_req_t                ps_axi_mst_req;
  axi_mst_rsp_t                ps_axi_mst_rsp;
`endif

  /////////////////////
  //  System Inputs  //
  /////////////////////

  // Select SoC reset
`ifdef USE_RESET
  logic sys_resetn;
  assign sys_resetn = ~sys_reset;
`elsif USE_RESETN
  logic sys_reset;
  assign sys_reset  = ~sys_resetn;
`endif

  // Tie off inputs of no switches
`ifndef USE_SWITCHES
  logic       test_mode_i;
  logic [1:0] boot_mode_i;
  assign test_mode_i = '0;
  assign boot_mode_i = '0;
`endif

  ////////////
  //  JTAG  //
  ////////////

`ifdef USE_JTAG_VDDGND
  assign jtag_vdd_o = 1'b1;
  assign jtag_gnd_o = 1'b0;
`endif
`ifndef USE_JTAG_TRSTN
  logic jtag_trst_ni;
  assign jtag_trst_ni = 1'b1;
`endif

//   //////////////////
//   // I2C Adaption //
//   //////////////////

//   logic i2c_sda_soc_out;
//   logic i2c_sda_soc_in;
//   logic i2c_scl_soc_out;
//   logic i2c_scl_soc_in;
//   logic i2c_sda_en;
//   logic i2c_scl_en;

//`ifdef USE_I2C
//  IOBUF #(
//    .DRIVE        ( 12        ),
//    .IBUF_LOW_PWR ( "FALSE"   ),
//    .IOSTANDARD   ( "DEFAULT" ),
//    .SLEW         ( "FAST"    )
//  ) i_scl_iobuf (
//    .O  ( i2c_scl_soc_in  ),
//    .IO ( i2c_scl_io      ),
//    .I  ( i2c_scl_soc_out ),
//    .T  ( ~i2c_scl_en     )
//  );
//
//  IOBUF #(
//    .DRIVE        ( 12        ),
//    .IBUF_LOW_PWR ( "FALSE"   ),
//    .IOSTANDARD   ( "DEFAULT" ),
//    .SLEW         ( "FAST"    )
//  ) i_sda_iobuf (
//    .O  ( i2c_sda_soc_in  ),
//    .IO ( i2c_sda_io      ),
//    .I  ( i2c_sda_soc_out ),
//    .T  ( ~i2c_sda_en     )
//  );
//`endif

  ///////////////
  // SPI to SD //
  ///////////////

  logic spi_sck_soc;
  logic [1:0] spi_cs_soc;
  logic [3:0] spi_sd_soc_out;
  logic [3:0] spi_sd_soc_in;
  // Multiplex between SPI SD mode and QSPI proper
  logic [3:0] spi_sd_sd_in, spi_sd_spih_in;

  // Choose SoC input based on chip select
  assign spi_sd_soc_in =
    ({4{~spi_cs_soc[0]}} & spi_sd_sd_in) | ({4{~spi_cs_soc[1]}} & spi_sd_spih_in);

  logic spi_sck_en;
  logic [1:0] spi_cs_en;
  logic [3:0] spi_sd_en;

  logic reckon_spi_miso;

  assign spi_sd_soc_in[0] = 1'b0;
  assign spi_sd_soc_in[1] = reckon_spi_miso;
  assign spi_sd_soc_in[2] = 1'b0;
  assign spi_sd_soc_in[3] = 1'b0;

  //////////////////
  // I2C Adaption //
  //////////////////

  logic i2c_sda_soc_out;
  logic i2c_sda_soc_in;
  logic i2c_scl_soc_out;
  logic i2c_scl_soc_in;
  logic i2c_sda_en;
  logic i2c_scl_en;
//
//`ifdef USE_QSPI
//`ifndef USE_STARTUPE3
//`ifndef USE_STARTUPE2
//  // If a STARTUPE2 is present, this is wired there.
//  output wire        spih_sck_o,
//`endif
//  output wire        spih_csb_o,
//  inout  wire  [3:0] spih_sd_io,
//`endif
//`endif
//
//// On VCU128/VCU118/ZCU102, SPI ports are not directly available
//`ifdef USE_STARTUPE3
//  STARTUPE3 #(
//    .PROG_USR("FALSE"),
//    .SIM_CCLK_FREQ(0.0)
//  ) i_startupe3 (
//    .CFGCLK     ( ),
//    .CFGMCLK    ( ),
//    .DI         ( qspi_dqi ),
//    .EOS        ( ),
//    .PREQ       ( ),
//    .DO         ( qspi_dqo ),
//    .DTS        ( qspi_dqo_ts ),
//    .FCSBO      ( qspi_cs_b[1] ),
//    .FCSBTS     ( qspi_cs_b_ts[1] ),
//    .GSR        ( 1'b0 ),
//    .GTS        ( 1'b0 ),
//    .KEYCLEARB  ( 1'b1 ),
//    .PACK       ( 1'b0 ),
//    .USRCCLKO   ( qspi_clk ),
//    .USRCCLKTS  ( qspi_clk_ts ),
//    .USRDONEO   ( 1'b1 ),
//    .USRDONETS  ( 1'b1 )
//  );
//`else
//`ifdef USE_STARTUPE2
//  (*keep="TRUE"*)
//  STARTUPE2 #(
//    .PROG_USR("FALSE"),
//    .SIM_CCLK_FREQ(0.0)
//    ) i_startupe2 (
//    .CFGCLK     ( ),
//    .CFGMCLK    ( ),
//    .EOS        ( ),
//    .PREQ       ( ),
//    .CLK        ( 1'b0 ),
//    .GSR        ( 1'b0 ),
//    .GTS        ( 1'b0 ),
//    .KEYCLEARB  ( 1'b0 ),
//    .PACK       ( 1'b0 ),
//    .USRCCLKO   ( spi_sck_soc ),
//    .USRCCLKTS  ( 1'b0 ),
//    .USRDONEO   ( 1'b0 ),
//    .USRDONETS  ( 1'b0 )
//  );
//`else
//  IOBUF #(
//    .DRIVE        ( 12        ),
//    .IBUF_LOW_PWR ( "FALSE"   ),
//    .IOSTANDARD   ( "DEFAULT" ),
//    .SLEW         ( "FAST"    )
//  ) i_spih_sck_iobuf (
//    .O  (  ),
//    .IO ( spih_sck_o  ),
//    .I  ( spi_sck_soc ),
//    .T  ( ~spi_sck_en )
//  );
//`endif
//
//IOBUF #(
//  .DRIVE        ( 12        ),
//  .IBUF_LOW_PWR ( "FALSE"   ),
//  .IOSTANDARD   ( "DEFAULT" ),
//  .SLEW         ( "FAST"    )
//) i_spih_csb_iobuf (
//  .O  (  ),
//  .IO ( spih_csb_o ),
//  .I  ( spi_cs_soc [1] ),
//  .T  ( ~spi_cs_en [1] )
//);
//
//  for (genvar i = 0; i < 4; ++i) begin : gen_qspi_iobufs
//    IOBUF #(
//      .DRIVE        ( 12        ),
//      .IBUF_LOW_PWR ( "FALSE"   ),
//      .IOSTANDARD   ( "DEFAULT" ),
//      .SLEW         ( "FAST"    )
//    ) i_spih_sd_iobuf (
//      .O  ( spi_sd_spih_in [i] ),
//      .IO ( spih_sd_io     [i] ),
//      .I  ( spi_sd_soc_out [i] ),
//      .T  ( ~spi_sd_en     [i] )
//    );
//  end
//`endif


  /////////////////////////
  // "RTC" Clock Divider //
  /////////////////////////

  logic rtc_clk_d, rtc_clk_q;
  logic [15:0] counter_d, counter_q;

  // Divide soc_clk (50 MHz) by 50 => 1 MHz RTC Clock
  always_comb begin
    counter_d = counter_q + 1;
    rtc_clk_d = rtc_clk_q;

    if(counter_q == 24) begin
      counter_d = '0;
      rtc_clk_d = ~rtc_clk_q;
    end
  end

  always_ff @(posedge soc_clk, negedge rst_n) begin
    if(~rst_n) begin
      counter_q <= '0;
      rtc_clk_q <= 0;
    end else begin
      counter_q <= counter_d;
      rtc_clk_q <= rtc_clk_d;
    end
  end

  //////////////
  // DRAM MIG //
  //////////////

  axi_llc_req_t axi_llc_mst_req, axi_dram_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp, axi_dram_mst_rsp;

`ifdef USE_DDR
  dram_wrapper_xilinx #(
    .axi_soc_aw_chan_t ( axi_llc_aw_chan_t ),
    .axi_soc_w_chan_t  ( axi_llc_w_chan_t  ),
    .axi_soc_b_chan_t  ( axi_llc_b_chan_t  ),
    .axi_soc_ar_chan_t ( axi_llc_ar_chan_t ),
    .axi_soc_r_chan_t  ( axi_llc_r_chan_t  ),
    .axi_soc_req_t     ( axi_llc_req_t     ),
    .axi_soc_resp_t    ( axi_llc_rsp_t     ),
    .Ddr4CsNWidth      ( Ddr4CsNWidth      ),
    .Ddr4DmDbiNWidth   ( Ddr4DmDbiNWidth   ),
    .Ddr4DqWidth       ( Ddr4DqWidth       ),
    .Ddr4DqsWidth      ( Ddr4DqsWidth      )
  ) i_dram_wrapper (
    .sys_rst_i    ( sys_rst ),
    .soc_resetn_i ( rst_n   ),
    .soc_clk_i    ( soc_clk ),
    .dram_clk_i   ( dram_ref_clk ),
    .soc_req_i    ( axi_dram_mst_req ),
    .soc_rsp_o    ( axi_dram_mst_rsp ),
    .*
  );
`endif

  ////////////////
  // DRAM Delay //
  ////////////////

`ifdef USE_RAM_DELAY
  axi_fifo_delay_dyn #(
    .aw_chan_t  ( axi_llc_aw_chan_t ),
    .w_chan_t   ( axi_llc_w_chan_t  ),
    .b_chan_t   ( axi_llc_b_chan_t  ),
    .ar_chan_t  ( axi_llc_ar_chan_t ),
    .r_chan_t   ( axi_llc_r_chan_t  ),
    .axi_req_t  ( axi_llc_req_t     ),
    .axi_resp_t ( axi_llc_rsp_t     ),
    .DepthAR    ( 32 ), // Power of two
    .DepthAW    ( 32 ), // Power of two
    .DepthR     ( 32 ), // Power of two
    .DepthW     ( 32 ), // Power of two
    .DepthB     ( 32 ), // Power of two
    .MaxDelay   ( 2**15-1 ) // This is a bit backwards, but defines 16-bit delay timers.
  ) i_axi_fifo_delay_dyn (
    .clk_i      ( soc_clk ),
    .rst_ni     ( rst_n   ),
    .aw_delay_i ( reg2hw.dram_aw_delay ),
    .w_delay_i  ( reg2hw.dram_w_delay  ),
    .b_delay_i  ( reg2hw.dram_b_delay  ),
    .ar_delay_i ( reg2hw.dram_ar_delay ),
    .r_delay_i  ( reg2hw.dram_r_delay  ),
    .slv_req_i  ( axi_llc_mst_req ),
    .slv_resp_o ( axi_llc_mst_rsp ),
    .mst_req_o  ( axi_dram_mst_req ),
    .mst_resp_i ( axi_dram_mst_rsp )
  );
`else
  assign axi_dram_mst_req = axi_llc_mst_req;
  assign axi_llc_mst_rsp  = axi_dram_mst_rsp;
`endif

  //////////////////
  // Cheshire SoC //
  //////////////////
  axi_mst_req_t [iomsb(CfgAxiExtNumMst):0] axi_ext_mst_req;
  axi_mst_rsp_t [iomsb(CfgAxiExtNumMst):0] axi_ext_mst_rsp;

`ifdef USE_MPSOC
  // Bridge PS AXI into Cheshire typed AXI records.
  always_comb begin
    ps_axi_req = '0;

    ps_axi_req.aw.id     = ps_m_axi_hpm0_awid;
    ps_axi_req.aw.addr   = {{(CfgAddrWidth-PsAxiAddrWidth){1'b0}}, ps_m_axi_hpm0_awaddr};
    ps_axi_req.aw.len    = ps_m_axi_hpm0_awlen;
    ps_axi_req.aw.size   = ps_m_axi_hpm0_awsize;
    ps_axi_req.aw.burst  = ps_m_axi_hpm0_awburst;
    ps_axi_req.aw.lock   = ps_m_axi_hpm0_awlock;
    ps_axi_req.aw.cache  = ps_m_axi_hpm0_awcache;
    ps_axi_req.aw.prot   = ps_m_axi_hpm0_awprot;
    ps_axi_req.aw.qos    = ps_m_axi_hpm0_awqos;
    ps_axi_req.aw.region = '0;
    ps_axi_req.aw.atop   = '0;
    ps_axi_req.aw.user   = '0;
    ps_axi_req.aw_valid  = ps_m_axi_hpm0_awvalid;

    ps_axi_req.w.data    = ps_m_axi_hpm0_wdata;
    ps_axi_req.w.strb    = ps_m_axi_hpm0_wstrb;
    ps_axi_req.w.last    = ps_m_axi_hpm0_wlast;
    ps_axi_req.w.user    = '0;
    ps_axi_req.w_valid   = ps_m_axi_hpm0_wvalid;

    ps_axi_req.b_ready   = ps_m_axi_hpm0_bready;

    ps_axi_req.ar.id     = ps_m_axi_hpm0_arid;
    ps_axi_req.ar.addr   = {{(CfgAddrWidth-PsAxiAddrWidth){1'b0}}, ps_m_axi_hpm0_araddr};
    ps_axi_req.ar.len    = ps_m_axi_hpm0_arlen;
    ps_axi_req.ar.size   = ps_m_axi_hpm0_arsize;
    ps_axi_req.ar.burst  = ps_m_axi_hpm0_arburst;
    ps_axi_req.ar.lock   = ps_m_axi_hpm0_arlock;
    ps_axi_req.ar.cache  = ps_m_axi_hpm0_arcache;
    ps_axi_req.ar.prot   = ps_m_axi_hpm0_arprot;
    ps_axi_req.ar.qos    = ps_m_axi_hpm0_arqos;
    ps_axi_req.ar.region = '0;
    ps_axi_req.ar.user   = '0;
    ps_axi_req.ar_valid  = ps_m_axi_hpm0_arvalid;

    ps_axi_req.r_ready   = ps_m_axi_hpm0_rready;
  end

  assign ps_m_axi_hpm0_awready = ps_axi_rsp.aw_ready;
  assign ps_m_axi_hpm0_wready  = ps_axi_rsp.w_ready;
  assign ps_m_axi_hpm0_bid     = ps_axi_rsp.b.id;
  assign ps_m_axi_hpm0_bresp   = ps_axi_rsp.b.resp;
  assign ps_m_axi_hpm0_bvalid  = ps_axi_rsp.b_valid;
  assign ps_m_axi_hpm0_arready = ps_axi_rsp.ar_ready;
  assign ps_m_axi_hpm0_rid     = ps_axi_rsp.r.id;
  assign ps_m_axi_hpm0_rdata   = ps_axi_rsp.r.data;
  assign ps_m_axi_hpm0_rresp   = ps_axi_rsp.r.resp;
  assign ps_m_axi_hpm0_rlast   = ps_axi_rsp.r.last;
  assign ps_m_axi_hpm0_rvalid  = ps_axi_rsp.r_valid;

  axi_dw_converter #(
    .AxiMaxReads          ( 8 ),
    .AxiSlvPortDataWidth  ( PsAxiDataWidth ),
    .AxiMstPortDataWidth  ( CfgAxiDataWidth ),
    .AxiAddrWidth         ( CfgAddrWidth ),
    .AxiIdWidth           ( PsAxiIdWidth ),
    // Common AW, AR, B
    .aw_chan_t            ( ps_axi_aw_chan_t ),
    .b_chan_t             ( ps_axi_b_chan_t  ),
    .ar_chan_t            ( ps_axi_ar_chan_t ),
    // Master-side (64-bit) W, R
    .mst_w_chan_t         ( ps_axi_dw_w_chan_t ),
    .mst_r_chan_t         ( ps_axi_dw_r_chan_t ),
    .axi_mst_req_t        ( ps_axi_dw_req_t ),
    .axi_mst_resp_t       ( ps_axi_dw_rsp_t ),
    // Slave-side (128-bit) W, R
    .slv_w_chan_t         ( ps_axi_w_chan_t ),
    .slv_r_chan_t         ( ps_axi_r_chan_t ),
    .axi_slv_req_t        ( ps_axi_req_t ),
    .axi_slv_resp_t       ( ps_axi_rsp_t )
  ) i_ps_axi_dw_converter (
    .clk_i      ( soc_clk ),
    .rst_ni     ( rst_n ),
    .slv_req_i  ( ps_axi_req ),
    .slv_resp_o ( ps_axi_rsp ),
    .mst_req_o  ( ps_axi_dw_req ),
    .mst_resp_i ( ps_axi_dw_rsp )
  );

  axi_iw_converter #(
    .AxiAddrWidth           ( CfgAddrWidth ),
    .AxiDataWidth           ( CfgAxiDataWidth ),
    .AxiUserWidth           ( CfgAxiUserWidth ),
    .AxiSlvPortIdWidth      ( PsAxiIdWidth ),
    .AxiSlvPortMaxUniqIds   ( 16 ),
    .AxiSlvPortMaxTxnsPerId ( 8 ),
    .AxiSlvPortMaxTxns      ( 16 ),
    .AxiMstPortIdWidth      ( CfgAxiMstIdWidth ),
    .AxiMstPortMaxUniqIds   ( 2 ** CfgAxiMstIdWidth ),
    .AxiMstPortMaxTxnsPerId ( 8 ),
    .slv_req_t              ( ps_axi_dw_req_t ),
    .slv_resp_t             ( ps_axi_dw_rsp_t ),
    .mst_req_t              ( axi_mst_req_t ),
    .mst_resp_t             ( axi_mst_rsp_t )
  ) i_ps_axi_iw_converter (
    .clk_i      ( soc_clk ),
    .rst_ni     ( rst_n ),
    .slv_req_i  ( ps_axi_dw_req ),
    .slv_resp_o ( ps_axi_dw_rsp ),
    .mst_req_o  ( ps_axi_mst_req ),
    .mst_resp_i ( ps_axi_mst_rsp )
  );

  assign axi_ext_mst_req[0] = ps_axi_mst_req;
  assign ps_axi_mst_rsp     = axi_ext_mst_rsp[0];
`else
  assign axi_ext_mst_req = '0;
`endif

  axi_slv_req_t [(CfgAxiExtNumSlv-1):0] axi_slv_i;
  axi_slv_rsp_t [(CfgAxiExtNumSlv-1):0] axi_slv_o;
  cheshire_soc #(
    .Cfg                ( FPGACfg ),
    .ExtHartinfo        ( '0 ),
    .axi_ext_llc_req_t  ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( axi_mst_rsp_t ),
    .axi_ext_slv_req_t  ( axi_slv_req_t ),
    .axi_ext_slv_rsp_t  ( axi_slv_rsp_t ),
    .reg_ext_req_t      ( reg_req_t ),
    .reg_ext_rsp_t      ( reg_rsp_t )
  ) i_cheshire_soc (
    .clk_i              ( soc_clk ),
    .rst_ni             ( rst_n   ),
    .test_mode_i        ( test_mode_i ),
    .boot_mode_i        ( boot_mode   ),
    .rtc_i              ( rtc_clk_q       ),
    .axi_llc_mst_req_o  ( axi_llc_mst_req ),
    .axi_llc_mst_rsp_i  ( axi_llc_mst_rsp ),
    .axi_ext_mst_req_i  ( axi_ext_mst_req ),
    .axi_ext_mst_rsp_o  ( axi_ext_mst_rsp ),
    .axi_ext_slv_req_o  ( axi_slv_i ),
    .axi_ext_slv_rsp_i  ( axi_slv_o ),
`ifdef USE_CFG_REGS
    .reg_ext_slv_req_o  ( cfg_reg_req ),
    .reg_ext_slv_rsp_i  ( cfg_reg_rsp ),
`else
    .reg_ext_slv_req_o  ( ),
    .reg_ext_slv_rsp_i  ( '0 ),
`endif
    .intr_ext_i         ( '0 ),
    .intr_ext_o         ( ),
    .xeip_ext_o         ( ),
    .mtip_ext_o         ( ),
    .msip_ext_o         ( ),
    .dbg_active_o       ( ),
    .dbg_ext_req_o      ( ),
    .dbg_ext_unavail_i  ( '0 ),
    .slink_rcv_clk_i    ( 1'b1 ),
    .slink_rcv_clk_o    ( ),
    .slink_i            ( '0 ),
    .slink_o            ( ),
`ifdef USE_JTAG
    .jtag_tck_i,
    .jtag_trst_ni,
    .jtag_tms_i,
    .jtag_tdi_i,
    .jtag_tdo_o,
    // TODO: connect to the tdo pad
    .jtag_tdo_oe_o      ( ),
`endif
    .i2c_sda_o          ( i2c_sda_soc_out ),
    .i2c_sda_i          ( i2c_sda_soc_in  ),
    .i2c_sda_en_o       ( i2c_sda_en      ),
    .i2c_scl_o          ( i2c_scl_soc_out ),
    .i2c_scl_i          ( i2c_scl_soc_in  ),
    .i2c_scl_en_o       ( i2c_scl_en      ),
    .spih_sck_o         ( spi_sck_soc     ),
    .spih_sck_en_o      ( spi_sck_en      ),
    .spih_csb_o         ( spi_cs_soc      ),
    .spih_csb_en_o      ( spi_cs_en       ),
    .spih_sd_o          ( spi_sd_soc_out  ),
    .spih_sd_en_o       ( spi_sd_en       ),
    .spih_sd_i          ( spi_sd_soc_in   ),
`ifdef USE_VGA
    .vga_hsync_o,
    .vga_vsync_o,
    .vga_red_o,
    .vga_green_o,
    .vga_blue_o,
`endif
    .uart_tx_o,
    .uart_rx_i, 
    .usb_clk_i          ( usb_clk ),
    .usb_rst_ni         ( rst_n ), // Technically should sync to `usb_clk`, but pulse is long enough
    .usb_dm_i (),
    .usb_dm_o (),
    .usb_dm_oe_o (),
    .usb_dp_i (),
    .usb_dp_o (),
    .usb_dp_oe_o ()
  );

  // logic [31:0] axi_gpio_i, axi_gpio_o, axi_gpio_en;

  // logic START_wire, STOP_wire, TEST_wire, NEW_BATCH_wire, NEW_EPOCH_wire, SPI_EN_CONF;

  // assign NEW_EPOCH_wire  = axi_gpio_o[0];
  // assign STOP_wire       = axi_gpio_o[1];
  // assign TEST_wire       = axi_gpio_o[2];
  // assign NEW_BATCH_wire  = axi_gpio_o[3];

  // assign axi_gpio_i[4]       = batch_done;
  // assign axi_gpio_i[5]       = epoch_done;

  logic [31:0] axi_batch_size, axi_n_samples, axi_do_eprop, infer_count,axi_n_epochs ;
  logic [11:0] infer_count_12b;
  // logic [31:0] reckon_ctrl   [5:0];
  logic [31:0] reckon_ctrl_i [3:0];
  logic [31:0] reckon_ctrl_o [1:0];
  
  logic [17:0] AERAM_add;
  logic        AERAM_clk;
  logic [31:0] AERAM_din;
  logic [31:0] AERAM_dout;
  logic        AERAM_cs;
  logic        AERAM_rst;
  logic [3:0]  AERAM_we;

  logic [31:0] axi_reg_o [AxiRegsNout-1:0];
  logic [31:0] axi_reg_i [AxiRegsNin-1:0 ];

  logic debug_axi;

  assign axi_batch_size   = axi_reg_o[0];
  assign axi_n_samples    = axi_reg_o[2];
  assign axi_n_epochs     = axi_reg_o[1];
  assign axi_do_eprop     = axi_reg_o[3];
  assign reckon_ctrl_i[0] = axi_reg_o[4];
  assign reckon_ctrl_i[1] = axi_reg_o[5];
  assign reckon_ctrl_i[2] = axi_reg_o[6];
  assign reckon_ctrl_i[3] = axi_reg_o[7];

  assign debug_axi        = |axi_do_eprop;
  assign led_o[0]         = debug_axi;

  assign axi_reg_i[0]   = {20'h0, infer_count_12b};


  assign axi_reg_i[1]   = reckon_ctrl_o[0];
  assign axi_reg_i[2]   = reckon_ctrl_o[1];
  assign axi_reg_i[3]   = 32'hDEADBEEF;

  reckon_axi_top #(
    .ADDR_WIDTH(16)
  ) reckon_axi_top_0 (
    .clk_i (clk15),
    .rst_i (~rst_n),
    .SPI_EN_CONF(SPI_EN_CONF),

    .reckon_ctrl_i_0(reckon_ctrl_i[0]),
    .reckon_ctrl_i_1(reckon_ctrl_i[1]),
    .reckon_ctrl_i_2(reckon_ctrl_i[2]),
    .reckon_ctrl_i_3(reckon_ctrl_i[3]),
    .reckon_ctrl_o_0(reckon_ctrl_o[0]),
    .reckon_ctrl_o_1(reckon_ctrl_o[1]),
    .spi_sck_wire    ( spi_sck_soc       ),
    .spi_mosi_wire   ( spi_sd_soc_out[0] ),
    .spi_miso_wire   ( reckon_spi_miso  ),
    .BRAM_PORTA_addr(AERAM_add),
    .BRAM_PORTA_clk(AERAM_clk),
    .BRAM_PORTA_din(AERAM_din),
    .BRAM_PORTA_en(AERAM_cs),
    .BRAM_PORTA_rst(AERAM_rst),
    .BRAM_PORTA_we(AERAM_we),
    .BRAM_PORTA_dout(AERAM_dout),
    .infer_count_o(infer_count_12b),
    .batch_size_i(axi_batch_size[11:0]),
    .n_samples_i(axi_n_samples[11:0]),
    .do_eprop_i(axi_do_eprop[2:0])
  );



  axi_layer #(
    .Cfg               ( FPGACfg ),
    .AxiRegsNin        ( AxiRegsNin ),
    .AxiRegsNout       ( AxiRegsNout ),
    .UseAxiGPIO        ( UseAxiGPIO ),
    .axi_ext_slv_req_t ( axi_slv_req_t ),
    .axi_ext_slv_rsp_t ( axi_slv_rsp_t )
  ) axi_layer_0 (
    .clk_i             ( soc_clk ),
    .rst_ni            ( rst_n ),
    .axi_ext_slv_req_s ( axi_slv_i),
    .axi_ext_slv_rsp_s ( axi_slv_o),
    .axi_reg_o         ( axi_reg_o ),
    .axi_reg_i         ( axi_reg_i ),
    .axi_gpio_o        ( ),
    .axi_gpio_i        ( '0 )
  );

  ///////////////////////////////////
  // AXI DW Converter 64→32 + BRAM //
  ///////////////////////////////////

  // Segnali tra DW converter (master, 32-bit) e axi_to_mem
  axi_bram_req_t axi_bram_req;
  axi_bram_rsp_t axi_bram_rsp;
  axi_bram_req_t axi_bram_req_cut;
  axi_bram_rsp_t axi_bram_rsp_cut;

  axi_dw_converter #(
    .AxiMaxReads          ( 4 ),
    .AxiSlvPortDataWidth  ( CfgAxiDataWidth ),  // 64
    .AxiMstPortDataWidth  ( BramDataWidth ),     // 32
    .AxiAddrWidth         ( CfgAddrWidth ),
    .AxiIdWidth           ( AxiSlvIdWidth ),
    // Common channels (AW, AR, B keep the same types)
    .aw_chan_t            ( axi_slv_aw_chan_t ),
    .ar_chan_t            ( axi_slv_ar_chan_t ),
    .b_chan_t             ( axi_slv_b_chan_t  ),
    // Master-side (32-bit) W & R channels
    .mst_w_chan_t         ( axi_bram_w_chan_t ),
    .mst_r_chan_t         ( axi_bram_r_chan_t ),
    .axi_mst_req_t        ( axi_bram_req_t ),
    .axi_mst_resp_t       ( axi_bram_rsp_t ),
    // Slave-side (64-bit) W & R channels
    .slv_w_chan_t         ( axi_slv_w_chan_t ),
    .slv_r_chan_t         ( axi_slv_r_chan_t ),
    .axi_slv_req_t        ( axi_slv_req_t ),
    .axi_slv_resp_t       ( axi_slv_rsp_t )
  ) i_bram_dw_conv (
    .clk_i      ( soc_clk ),
    .rst_ni     ( rst_n ),
    .slv_req_i  ( axi_slv_i[1] ),
    .slv_resp_o ( axi_slv_o[1] ),
    .mst_req_o  ( axi_bram_req ),
    .mst_resp_i ( axi_bram_rsp )
  );

  axi_cut #(
    .Bypass     ( 1'b0 ),
    .aw_chan_t  ( axi_bram_aw_chan_t ),
    .w_chan_t   ( axi_bram_w_chan_t  ),
    .b_chan_t   ( axi_bram_b_chan_t  ),
    .ar_chan_t  ( axi_bram_ar_chan_t ),
    .r_chan_t   ( axi_bram_r_chan_t  ),
    .axi_req_t  ( axi_bram_req_t ),
    .axi_resp_t ( axi_bram_rsp_t )
  ) i_bram_axi_cut (
    .clk_i      ( soc_clk ),
    .rst_ni     ( rst_n ),
    .slv_req_i  ( axi_bram_req ),
    .slv_resp_o ( axi_bram_rsp ),
    .mst_req_o  ( axi_bram_req_cut ),
    .mst_resp_i ( axi_bram_rsp_cut )
  );

  // Segnali SRAM interface (ora a 32-bit)
  logic        bram_req, bram_we, bram_rvalid;
  logic [CfgAddrWidth-1:0] bram_addr_full;
  logic [BramDataWidth-1:0]     bram_wdata, bram_rdata;
  logic [BramStrbWidth-1:0]     bram_strb;

  axi_to_mem #(
    .axi_req_t  ( axi_bram_req_t ),
    .axi_resp_t ( axi_bram_rsp_t ),
    .AddrWidth  ( CfgAddrWidth ),
    .DataWidth  ( BramDataWidth ),       // 32
    .IdWidth    ( AxiSlvIdWidth ),
    .NumBanks   ( 1 ),
    .BufDepth   ( 4 )
  ) i_bram_axi_to_mem (
    .clk_i       ( soc_clk ),
    .rst_ni      ( rst_n ),
    .busy_o      ( ),
    .axi_req_i   ( axi_bram_req_cut ),
    .axi_resp_o  ( axi_bram_rsp_cut ),
    .mem_req_o   ( bram_req ),
    .mem_gnt_i   ( 1'b1 ),              // BRAM sempre pronta
    .mem_addr_o  ( bram_addr_full ),
    .mem_wdata_o ( bram_wdata ),
    .mem_strb_o  ( bram_strb ),
    .mem_atop_o  ( ),
    .mem_we_o    ( bram_we ),
    .mem_rvalid_i( bram_rvalid ),
    .mem_rdata_i ( bram_rdata )
  );

  // read valid 1 ciclo dopo la request (come fa cheshire_soc per debug mem)
  always_ff @(posedge soc_clk or negedge rst_n) begin
    if (!rst_n) bram_rvalid <= 1'b0;
    else        bram_rvalid <= bram_req;
  end

  // Connessione alla BRAM port A (tutto a 32-bit, nessun troncamento)
  assign AERAM_clk = soc_clk;
  assign AERAM_rst = ~rst_n;
  assign AERAM_cs  = bram_req;
  assign AERAM_add = bram_addr_full[17:0];
  assign AERAM_din = bram_wdata;
  assign AERAM_we  = bram_we ? bram_strb : 4'b0;
  assign bram_rdata = AERAM_dout;

  //////////////////
  //  Reset Sync  //
  //////////////////

  logic rst_n;

  rstgen i_rstgen (
    .clk_i        ( soc_clk     ),
    .rst_ni       ( ~sys_rst    ),
    .test_mode_i  ( test_mode_i ),
    .rst_no       ( rst_n       ),
    .init_no      ( )
  );

  logic uart_tx_o, uart_rx_i;

`ifdef USE_RESET
  assign sys_rst = sys_reset | vio_reset;
`elsif USE_RESETN
  assign sys_rst = ~sys_resetn | vio_reset;
`endif
  assign boot_mode = vio_boot_mode_sel ? vio_boot_mode : boot_mode_i;

  assign uart_tx_o_cp2108 = vio_uart_sel ? uart_tx_o : '0;
  assign uart_tx_o_gpio   = vio_uart_sel ? '0 : uart_tx_o;
  assign uart_rx_i        = vio_uart_sel ? uart_rx_i_cp2108 : uart_rx_i_gpio;

`ifdef USE_MPSOC
  IBUFDS #(
    .IBUF_LOW_PWR ("FALSE")
  ) i_bufds_dram_ref_clk (
    .I  ( sys_clk_p     ),
    .IB ( sys_clk_n     ),
    .O  ( dram_ref_clk  )
  );

  zcu102_mpsoc_wrapper MPSoC_controller_0 (
    .clk_50   ( soc_clk  ),
    .clk_15   ( clk15),
    .CLK_IN1_D_clk_n(sys_clk_n),
    .CLK_IN1_D_clk_p(sys_clk_p),
    .probe_out0 ( vio_reset         ),
    .probe_out1 ( vio_boot_mode     ),
    .probe_out2 ( vio_boot_mode_sel ),
    .probe_out3 ( vio_uart_sel  ),
    .probe_in0  ( SPI_EN_CONF   ),
    .probe_in1  ( debug_axi     ),
    .M_AXI_HPM0_FPD_araddr  ( ps_m_axi_hpm0_araddr ),
    .M_AXI_HPM0_FPD_arburst ( ps_m_axi_hpm0_arburst ),
    .M_AXI_HPM0_FPD_arcache ( ps_m_axi_hpm0_arcache ),
    .M_AXI_HPM0_FPD_arid    ( ps_m_axi_hpm0_arid ),
    .M_AXI_HPM0_FPD_arlen   ( ps_m_axi_hpm0_arlen ),
    .M_AXI_HPM0_FPD_arlock  ( ps_m_axi_hpm0_arlock ),
    .M_AXI_HPM0_FPD_arprot  ( ps_m_axi_hpm0_arprot ),
    .M_AXI_HPM0_FPD_arqos   ( ps_m_axi_hpm0_arqos ),
    .M_AXI_HPM0_FPD_arready ( ps_m_axi_hpm0_arready ),
    .M_AXI_HPM0_FPD_arsize  ( ps_m_axi_hpm0_arsize ),
    .M_AXI_HPM0_FPD_aruser  ( ps_m_axi_hpm0_aruser ),
    .M_AXI_HPM0_FPD_arvalid ( ps_m_axi_hpm0_arvalid ),
    .M_AXI_HPM0_FPD_awaddr  ( ps_m_axi_hpm0_awaddr ),
    .M_AXI_HPM0_FPD_awburst ( ps_m_axi_hpm0_awburst ),
    .M_AXI_HPM0_FPD_awcache ( ps_m_axi_hpm0_awcache ),
    .M_AXI_HPM0_FPD_awid    ( ps_m_axi_hpm0_awid ),
    .M_AXI_HPM0_FPD_awlen   ( ps_m_axi_hpm0_awlen ),
    .M_AXI_HPM0_FPD_awlock  ( ps_m_axi_hpm0_awlock ),
    .M_AXI_HPM0_FPD_awprot  ( ps_m_axi_hpm0_awprot ),
    .M_AXI_HPM0_FPD_awqos   ( ps_m_axi_hpm0_awqos ),
    .M_AXI_HPM0_FPD_awready ( ps_m_axi_hpm0_awready ),
    .M_AXI_HPM0_FPD_awsize  ( ps_m_axi_hpm0_awsize ),
    .M_AXI_HPM0_FPD_awuser  ( ps_m_axi_hpm0_awuser ),
    .M_AXI_HPM0_FPD_awvalid ( ps_m_axi_hpm0_awvalid ),
    .M_AXI_HPM0_FPD_bid     ( ps_m_axi_hpm0_bid ),
    .M_AXI_HPM0_FPD_bready  ( ps_m_axi_hpm0_bready ),
    .M_AXI_HPM0_FPD_bresp   ( ps_m_axi_hpm0_bresp ),
    .M_AXI_HPM0_FPD_bvalid  ( ps_m_axi_hpm0_bvalid ),
    .M_AXI_HPM0_FPD_rdata   ( ps_m_axi_hpm0_rdata ),
    .M_AXI_HPM0_FPD_rid     ( ps_m_axi_hpm0_rid ),
    .M_AXI_HPM0_FPD_rlast   ( ps_m_axi_hpm0_rlast ),
    .M_AXI_HPM0_FPD_rready  ( ps_m_axi_hpm0_rready ),
    .M_AXI_HPM0_FPD_rresp   ( ps_m_axi_hpm0_rresp ),
    .M_AXI_HPM0_FPD_rvalid  ( ps_m_axi_hpm0_rvalid ),
    .M_AXI_HPM0_FPD_wdata   ( ps_m_axi_hpm0_wdata ),
    .M_AXI_HPM0_FPD_wlast   ( ps_m_axi_hpm0_wlast ),
    .M_AXI_HPM0_FPD_wready  ( ps_m_axi_hpm0_wready ),
    .M_AXI_HPM0_FPD_wstrb   ( ps_m_axi_hpm0_wstrb ),
    .M_AXI_HPM0_FPD_wvalid  ( ps_m_axi_hpm0_wvalid )
  );
`else
  IBUFDS #(
    .IBUF_LOW_PWR ("FALSE")
  ) i_bufds_sys_clk (
    .I  ( sys_clk_p ),
    .IB ( sys_clk_n ),
    .O  ( sys_clk   )
  );

  assign dram_ref_clk = sys_clk;

  clkwiz i_clkwiz (
    .clk_in1  ( sys_clk ),
    .reset    ( '0 ),
    .locked   ( ),    
    .clk_48  ( ),
    .clk_50   ( soc_clk  ),
    .clk_20   ( ),
    .clk_15   ( clk15)
  );
  `ifdef USE_VIO
    vio i_vio (
      .clk        ( soc_clk ),
      .probe_out0 ( vio_reset         ),
      .probe_out1 ( vio_boot_mode     ),
      .probe_out2 ( vio_boot_mode_sel ),
      .probe_out3 ( vio_uart_sel  ),
      .probe_in0  ( SPI_EN_CONF   )
    );

  `else
    assign vio_reset          = '0;
    assign vio_boot_mode      = '0;
    assign vio_boot_mode_sel  = '0;
    assign vio_uart_out_sel   = '0;
  `endif
`endif

endmodule
