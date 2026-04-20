`include "cheshire/typedef.svh"
`include "include/axi_macros.svh"

module axi_layer import cheshire_pkg::*; #
(
  parameter cheshire_cfg_t Cfg = '0,
  parameter int unsigned AxiRegsNin  = 32,
  parameter int unsigned AxiRegsNout = 8,
  parameter type axi_ext_slv_req_t  = logic,
  parameter type axi_ext_slv_rsp_t  = logic,
  parameter int UseAxiGPIO = 1
)(
  input  logic clk_i,
  input  logic rst_ni,
  // use the canonical Cheshire packed AXI types on the module ports
  input  axi_ext_slv_req_t  axi_ext_slv_req_s,
  output axi_ext_slv_rsp_t  axi_ext_slv_rsp_s,

  output logic [31:0] axi_reg_o [AxiRegsNout-1:0],
  input  logic [31:0] axi_reg_i [AxiRegsNin-1:0],
  output logic [31:0] axi_gpio_o,
  input  logic [31:0] axi_gpio_i
);

  localparam N1 = AxiRegsNin  == 0 ? 1 : AxiRegsNin;
  localparam N2 = AxiRegsNout == 0 ? 1 : AxiRegsNout;

  // clock / reset locals
  logic axi_aclk;
  logic axi_aresetn;

  // flattened AXI-Lite signals (created below by AXI_S_PORT)
  // full AXI signals used internally
  logic [Cfg.AddrWidth+2-1 : 0] 		axi_awaddr;
  logic [2 : 0] 						axi_awprot;
  logic  								axi_awvalid;
  logic  								axi_awready;
  logic [Cfg.AxiDataWidth-1 : 0] 		axi_wdata;
  logic [(Cfg.AxiDataWidth/8)-1 : 0] 	axi_wstrb;
  logic  								axi_wvalid;
  logic  								axi_wready;
  logic [1 : 0] 						axi_bresp;
  logic  								axi_bvalid;
  logic  								axi_bready;
  logic [Cfg.AddrWidth+2-1 : 0] 		axi_araddr;
  logic [2 : 0] 						axi_arprot;
  logic  								axi_arvalid;
  logic  								axi_arready;
  logic [Cfg.AxiDataWidth-1 : 0] 		axi_rdata;
  logic [1 : 0] 						axi_rresp;
  logic  								axi_rvalid;
  logic  								axi_rready;

  // Create Cheshire AXI typedefs (produces addr_t, axi_data_t, axi_strb_t, axi_user_t, axi_slv_req_t, etc.)
  `CHESHIRE_TYPEDEF_ALL(, Cfg)

  // Create AXI-Lite typedefs (lite_req_t / lite_resp_t)
  // typedef logic [Cfg.AddrWidth-1:0]       lite_addr_t;
  // typedef logic [Cfg.AxiDataWidth-1:0]    lite_data_t;
  // typedef logic [Cfg.AxiDataWidth/8-1:0]  lite_strb_t;
  `AXI_LITE_TYPEDEF_ALL(lite, addr_t, axi_data_t, axi_strb_t)

  // convenient aliases for third-party converter
  typedef axi_slv_req_t   full_req_t;
  typedef axi_slv_rsp_t   full_resp_t;

  // packed bus variables used with converter
  full_req_t  full_req;
  full_resp_t full_resp;
  lite_req_t  lite_req;
  lite_resp_t lite_resp;

  // RF-side packed slave port signals (adapter between external RF and internal packed view)
  axi_slv_req_t  axi_slv_rf_i;
  axi_slv_rsp_t  axi_slv_rf_o;

  // Generate flattened AXI-Lite ports/signals with sizes from CHESHIRE typedefs.
  // last five args are user types — pass axi_user_t for all channels
`AXI_LITE_S(lite_rf, addr_t, axi_data_t, axi_strb_t)

  // small register arrays used by the AXI4 RF slave IP
  logic [31:0] in_reg  [0:31];
  logic [31:0] out_reg [0:7];
  logic [31:0] gpio_o;
  logic [31:0] gpio_i;

  // map external arrays to local regs
  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : GEN_IN_REGS
      if (i < AxiRegsNin) begin : GEN_IN_REGS_MAP
        assign in_reg[i] = axi_reg_i[i];
      end else begin : GEN_IN_REGS_ZERO
        assign in_reg[i] = '0;
      end
    end
    for (i = 0; i < AxiRegsNout; i = i + 1) begin : GEN_OUT_REGS
      assign axi_reg_o[i] = out_reg[i];
    end
  endgenerate

  // AXI clock and reset
  assign axi_aclk    = clk_i;
  assign axi_aresetn = rst_ni;

  // --- External slave array -> single RF instance adapter (index 0 chosen here) ---
  // If multiple external slaves are present adapt this accordingly.
  generate
    if (Cfg.AxiExtNumSlv > 0) begin
      // connect first external slave to the RF adapter
      assign axi_slv_rf_i = axi_ext_slv_req_s;
      assign axi_ext_slv_rsp_s = axi_slv_rf_o;
    end else begin
      // tie off if none present
      assign axi_slv_rf_i = '0;
    end
  endgenerate

  // --- map flattened RF-side signals to internal full-AXI signals (packed view) ---
  // pack/unpack between flattened lite signals and lite_req / lite_resp

  // AW channel
  assign s_axi_lite_rf_awaddr  = lite_req.aw.addr;
  assign s_axi_lite_rf_awprot  = lite_req.aw.prot;
  assign s_axi_lite_rf_awvalid = lite_req.aw_valid;
  assign lite_resp.aw_ready    = s_axi_lite_rf_awready;

  // W channel
  assign s_axi_lite_rf_wdata  = lite_req.w.data;
  assign s_axi_lite_rf_wstrb  = lite_req.w.strb;
  assign s_axi_lite_rf_wvalid = lite_req.w_valid;
  assign lite_resp.w_ready    = s_axi_lite_rf_wready;

  // B channel (master -> slave / slave -> master mapping)
  assign s_axi_lite_rf_bready = lite_req.b_ready;
  assign lite_resp.b.resp     = s_axi_lite_rf_bresp;
  assign lite_resp.b_valid    = s_axi_lite_rf_bvalid;

  // AR channel
  assign s_axi_lite_rf_araddr  = lite_req.ar.addr;
  assign s_axi_lite_rf_arprot  = lite_req.ar.prot;
  assign s_axi_lite_rf_arvalid = lite_req.ar_valid;
  assign lite_resp.ar_ready    = s_axi_lite_rf_arready;

  // R channel (slave -> master)
  assign s_axi_lite_rf_rready = lite_req.r_ready;
  assign lite_resp.r.data     = s_axi_lite_rf_rdata;
  assign lite_resp.r.resp     = s_axi_lite_rf_rresp;
  assign lite_resp.r_valid    = s_axi_lite_rf_rvalid;

  // Map RF packed slave <-> converter packed full AXI types
  // full_req is driven from the RF packed view; full_resp drives RF packed response
  assign full_req  = axi_slv_rf_i;
  assign axi_slv_rf_o = full_resp;

  // Instantiate converter (full AXI -> AXI-Lite)
  axi_to_axi_lite #(
    .AxiAddrWidth    ( Cfg.AddrWidth     ),
    .AxiDataWidth    ( Cfg.AxiDataWidth  ),
    .AxiIdWidth      ( Cfg.AxiMstIdWidth ),
    .AxiUserWidth    ( Cfg.AxiUserWidth  ),
    .AxiMaxWriteTxns ( 4 ),
    .AxiMaxReadTxns  ( 4 ),
    .FallThrough     ( 1 ),
    .FullBW          ( 0 ),
    .full_req_t      ( full_req_t   ),
    .full_resp_t     ( full_resp_t  ),
    .lite_req_t      ( lite_req_t   ),
    .lite_resp_t     ( lite_resp_t  )
  ) i_axi_to_axi_lite (
    .clk_i      ( clk_i      ),
    .rst_ni     ( rst_ni     ),
    .test_i     ( 1'b0       ),
    // slave port full AXI4+ATOP (packed)
    .slv_req_i  ( full_req   ),
    .slv_resp_o ( full_resp  ),
    // master port AXI4-Lite (packed)
    .mst_req_o  ( lite_req   ),
    .mst_resp_i ( lite_resp  )
  );

  // Instantiate the AXI4 RF slave IP (AXI-Lite frontend)
  AXI4_RF_slave_lite_v1_0_S00_AXI # (
    .N1(N1),
    .N2(N2),
    .C_S_AXI_DATA_WIDTH(Cfg.AxiDataWidth),
    .C_S_AXI_ADDR_WIDTH(Cfg.AddrWidth)
  ) AXI4_RF_slave_lite_v1_0_S00_AXI_inst (
    .S_AXI_ACLK   (axi_aclk),
    .S_AXI_ARESETN(axi_aresetn),

    // AXI-Lite ports generated by `AXI_S_PORT(lite_rf, ...)`
    .S_AXI_AWADDR (s_axi_lite_rf_awaddr),
    .S_AXI_AWPROT (s_axi_lite_rf_awprot),
    .S_AXI_AWVALID(s_axi_lite_rf_awvalid),
    .S_AXI_AWREADY(s_axi_lite_rf_awready),

    .S_AXI_WDATA  (s_axi_lite_rf_wdata),
    .S_AXI_WSTRB  (s_axi_lite_rf_wstrb),
    .S_AXI_WVALID (s_axi_lite_rf_wvalid),
    .S_AXI_WREADY (s_axi_lite_rf_wready),

    .S_AXI_BRESP  (s_axi_lite_rf_bresp),
    .S_AXI_BVALID (s_axi_lite_rf_bvalid),
    .S_AXI_BREADY (s_axi_lite_rf_bready),

    .S_AXI_ARADDR (s_axi_lite_rf_araddr),
    .S_AXI_ARPROT (s_axi_lite_rf_arprot),
    .S_AXI_ARVALID(s_axi_lite_rf_arvalid),
    .S_AXI_ARREADY(s_axi_lite_rf_arready),

    .S_AXI_RDATA  (s_axi_lite_rf_rdata),
    .S_AXI_RRESP  (s_axi_lite_rf_rresp),
    .S_AXI_RVALID (s_axi_lite_rf_rvalid),
    .S_AXI_RREADY (s_axi_lite_rf_rready),

    // register / GPIO ports
    .in_reg0(in_reg[0]),   .in_reg1(in_reg[1]),   .in_reg2(in_reg[2]),   .in_reg3(in_reg[3]),
    .in_reg4(in_reg[4]),   .in_reg5(in_reg[5]),   .in_reg6(in_reg[6]),   .in_reg7(in_reg[7]),
    .in_reg8(in_reg[8]),   .in_reg9(in_reg[9]),   .in_reg10(in_reg[10]), .in_reg11(in_reg[11]),
    .in_reg12(in_reg[12]), .in_reg13(in_reg[13]), .in_reg14(in_reg[14]), .in_reg15(in_reg[15]),
    .in_reg16(in_reg[16]), .in_reg17(in_reg[17]), .in_reg18(in_reg[18]), .in_reg19(in_reg[19]),
    .in_reg20(in_reg[20]), .in_reg21(in_reg[21]), .in_reg22(in_reg[22]), .in_reg23(in_reg[23]),
    .in_reg24(in_reg[24]), .in_reg25(in_reg[25]), .in_reg26(in_reg[26]), .in_reg27(in_reg[27]),
    .in_reg28(in_reg[28]), .in_reg29(in_reg[29]), .in_reg30(in_reg[30]), .in_reg31(in_reg[31]),

    .out_reg0(out_reg[0]), .out_reg1(out_reg[1]), .out_reg2(out_reg[2]), .out_reg3(out_reg[3]),
    .out_reg4(out_reg[4]), .out_reg5(out_reg[5]), .out_reg6(out_reg[6]), .out_reg7(out_reg[7]),

    .gpio_o(gpio_o),
    .gpio_i(gpio_i)
  );

  // GPIO / register wiring
  generate
    if (UseAxiGPIO) begin
      assign axi_gpio_o = gpio_o;
      assign gpio_i     = axi_gpio_i;
    end else begin
      assign axi_gpio_o = '0;
      assign gpio_i     = '0;
    end
  endgenerate

endmodule

