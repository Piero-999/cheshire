
module reckon_axi_top #(
    parameter ADDR_WIDTH = 16
) (
    input wire clk_i,
    input wire rst_i,

    output wire SPI_EN_CONF,
    // output wire EPOCH_DONE,
    // input  wire STOP,
    // input  wire TEST,
    // input  wire NEW_BATCH,
    // input  wire NEW_EPOCH,
    // output wire BATCH_DONE,
    output wire [31:0] reckon_ctrl_o_0,
    output wire [31:0] reckon_ctrl_o_1,
    
    input wire  [31:0] reckon_ctrl_i_0,
    input wire  [31:0] reckon_ctrl_i_1,
    input wire  [31:0] reckon_ctrl_i_2,
    input wire  [31:0] reckon_ctrl_i_3,

    output wire spi_miso_wire,
    input wire spi_mosi_wire,
    input wire spi_sck_wire,

    input wire  [ADDR_WIDTH+1:0] BRAM_PORTA_addr,
    input wire                   BRAM_PORTA_clk,
    input wire  [31:0]           BRAM_PORTA_din,
    input wire                   BRAM_PORTA_en,
    input wire                   BRAM_PORTA_rst,
    input wire  [3:0]            BRAM_PORTA_we,
    output wire [31:0]           BRAM_PORTA_dout,

    output wire [11:0] infer_count_o,

    input wire [11:0] batch_size_i,
    input wire [11:0] n_samples_i,
     input wire [11:0] n_epochs_i,
    input wire [2:0 ] do_eprop_i

);

wire [31:0] SPI_CYCLES_PER_TICK;
(* dont_touch = "yes" *) (* mark_debug = "true" *) wire [11:0] SPI_LABEL_DELAY, SPI_INFER_ACC_DELAY;
wire        SPI_TIMING;

wire BATCH_DONE_wire, EPOCH_DONE_wire;

wire [ADDR_WIDTH-1:0] AXI_BRAM_ADDR;
wire [31:0] BRAM_PORTA_dout_a, BRAM_PORTA_dout_b;

wire AERIN_TAR_EN;
wire TIME_TICK;
wire INFER_ACC;
wire TIMING_ERROR_RDY;

wire [31:0] DIN, DIN_TRAIN, DIN_VAL;
wire CS, CS_T, CS_V;
wire [ADDR_WIDTH-1:0] RAM_ADDR;

assign AXI_BRAM_ADDR = BRAM_PORTA_addr[ADDR_WIDTH+1:2];

wire [7:0] OUT_DATA, AERIN_ADDR;

(* ASYNC_REG = "TRUE" *) reg STOP_reg, TEST_reg, NEW_BATCH_reg, NEW_EPOCH_reg;
(* ASYNC_REG = "TRUE" *) reg STOP_sync, TEST_sync, NEW_BATCH_sync, NEW_EPOCH_sync, STOP_sync2, NEW_BATCH_sync2, NEW_EPOCH_sync2;
(* ASYNC_REG = "TRUE" *) reg STOP_strb, NEW_BATCH_strb, NEW_EPOCH_strb;
(* ASYNC_REG = "TRUE" *)
always @(posedge clk_i) begin
  STOP_reg        <= reckon_ctrl_i_3[0];
  TEST_reg        <= reckon_ctrl_i_2[0];
  NEW_BATCH_reg   <= reckon_ctrl_i_1[0];
  NEW_EPOCH_reg   <= reckon_ctrl_i_0[0];

  STOP_sync       <= STOP_reg;
  NEW_BATCH_sync  <= NEW_BATCH_reg;
  NEW_EPOCH_sync  <= NEW_EPOCH_reg;
  TEST_sync       <= TEST_reg;

  STOP_sync2      <= STOP_sync;
  NEW_BATCH_sync2 <= NEW_BATCH_sync;
  NEW_EPOCH_sync2 <= NEW_EPOCH_sync;

  STOP_strb       <= ~STOP_sync2      & STOP_sync;
  NEW_BATCH_strb  <= ~NEW_BATCH_sync2 & NEW_BATCH_sync;
  NEW_EPOCH_strb  <= ~NEW_EPOCH_sync2 & NEW_EPOCH_sync;
end

(* dont_touch = "yes" *) (* mark_debug = "true" *) wire [11:0] N_SAMPLES, BATCH_SIZE, N_EPOCHS;
(* dont_touch = "yes" *) (* mark_debug = "true" *) wire [2:0 ] DO_EPROP;

(* ASYNC_REG = "TRUE" *) reg  [11:0] N_SAMPLES_reg, BATCH_SIZE_reg, N_EPOCHS_reg, N_SAMPLES_sync, BATCH_SIZE_sync, N_EPOCHS_sync;
(* ASYNC_REG = "TRUE" *) reg  [2:0 ] DO_EPROP_reg, DO_EPROP_sync, DO_EPROP_sync2;
(* ASYNC_REG = "TRUE" *) reg  [11:0] N_SAMPLES_sync2, BATCH_SIZE_sync2, N_EPOCHS_sync2;

(* ASYNC_REG = "TRUE" *)
always @(posedge clk_i) begin
    N_SAMPLES_reg  <= n_samples_i;
    BATCH_SIZE_reg <= batch_size_i;
    N_EPOCHS_reg   <= n_epochs_i;
    DO_EPROP_reg   <= do_eprop_i;

    N_SAMPLES_sync  <= N_SAMPLES_reg;
    BATCH_SIZE_sync <= BATCH_SIZE_reg;
    N_EPOCHS_sync   <= N_EPOCHS_reg;
    DO_EPROP_sync   <= DO_EPROP_reg;

    N_SAMPLES_sync2  <= N_SAMPLES_sync;
    BATCH_SIZE_sync2 <= BATCH_SIZE_sync;
    N_EPOCHS_sync2   <= N_EPOCHS_sync;
    DO_EPROP_sync2   <= DO_EPROP_sync;

end

assign reckon_ctrl_o_0 = {31'b0, BATCH_DONE_wire};
assign reckon_ctrl_o_1 = {31'b0, EPOCH_DONE_wire};

assign DO_EPROP   = DO_EPROP_sync2;
assign N_SAMPLES  = N_SAMPLES_sync2;
assign BATCH_SIZE = BATCH_SIZE_sync2;
assign N_EPOCHS   = N_EPOCHS_sync2;


reckon #(
    .N(256),
    .M(8)
) reckon_0 (
    // Global inputs   -------------------------------
    .CLK_EXT(clk_i),
    .CLK_INT_EN('b0),
    .RST(rst_i),

    // SPI slave       -------------------------------
    .SCK (spi_sck_wire),
    .MOSI(spi_mosi_wire),
    .MISO(spi_miso_wire),

    // Input bus and control inputs ------------------
    .AERIN_ADDR(AERIN_ADDR),
    .AERIN_REQ(AERIN_REQ),
    .AERIN_ACK(AERIN_ACK),
    .AERIN_TAR_EN(AERIN_TAR_EN),
    .SAMPLE(SAMPLE),
    .TIME_TICK(TIME_TICK),
    .TARGET_VALID(TARGET_VALID),
    .INFER_ACC(INFER_ACC),

    // Output bus and control outputs ----------------
    .SPI_RDY(SPI_RDY),
    .TIMING_ERROR_RDY(TIMING_ERROR_RDY),
    .SPI_TIMING_MODE(SPI_TIMING_MODE),
    .SPI_CYCLES_PER_TICK(SPI_CYCLES_PER_TICK),
    //.SPI_N_EPOCHS(SPI_N_EPOCHS),
    //.SPI_N_SAMPLES(SPI_N_SAMPLES),
    //.SPI_BATCH_SIZE(SPI_BATCH_SIZE),
    .SPI_LABEL_DELAY(SPI_LABEL_DELAY),
    .SPI_INFER_ACC_DELAY(SPI_INFER_ACC_DELAY),
    .OUT_REQ(OUT_REQ),
    .OUT_ACK(OUT_ACK),
    .OUT_DATA(OUT_DATA),
    .infer_count(infer_count_o),
    .SPI_EN_CONF(SPI_EN_CONF),
    .DO_EPROP(DO_EPROP)
);

//assign DIN  = TEST_sync ? DIN_VAL : DIN_TRAIN;  
//assign CS_V = TEST_sync ? CS : 1'b0;
//assign CS_T = TEST_sync ? 1'b0 : CS;
//assign BRAM_PORTA_dout = TEST_sync ? BRAM_PORTA_dout_a : BRAM_PORTA_dout_b;


aer_decoder #(
    .ADDR_WIDTH(ADDR_WIDTH)
) aer_decoder_0 (

    .CLK(clk_i),

    .RST(rst_i),

    .AERIN_ADDR(AERIN_ADDR),
    .AERIN_REQ(AERIN_REQ),
    .AERIN_TAR_EN(AERIN_TAR_EN),
    .AERIN_ACK(AERIN_ACK),
    .TIME_TICK(TIME_TICK),
    .SPI_CYCLES_PER_TICK(SPI_CYCLES_PER_TICK),

    .SPI_TIMING(SPI_TIMING_MODE),
    
    // AXI PARAMS ///////////////////
    .N_EPOCHS_i(N_EPOCHS),
    .N_SAMPLES_i(N_SAMPLES),
    .BATCH_SIZE_i(BATCH_SIZE),
    /////////////////////////////////
    .SPI_LABEL_DELAY(SPI_LABEL_DELAY),
    .SPI_INFER_ACC_DELAY(SPI_INFER_ACC_DELAY),

    .TIMING_ERROR_RDY(TIMING_ERROR_RDY),
    .SAMPLE(SAMPLE),
    .TARGET_VALID(TARGET_VALID),
    .INFER_ACC(INFER_ACC),

    .OUT_DATA(OUT_DATA),
    .OUT_REQ(OUT_REQ),
    .OUT_ACK(OUT_ACK),

    .CS(CS),
    .DIN(DIN),
    .RAM_ADDR(RAM_ADDR),

    .TEST_i(TEST_sync),
    .STOP_i(STOP_strb),
    .NEW_BATCH_i(NEW_BATCH_strb),
    .NEW_EPOCH_i(NEW_EPOCH_strb),
    .BATCH_DONE(BATCH_DONE),
    .EPOCH_DONE(EPOCH_DONE),


    .infer_count_o(infer_count_o)
);

//BRAM2_we_inst #(
//    .NB_COL(4),
//    .COL_WIDTH(8),
//    .RAM_WIDTH(32),
//    .RAM_DEPTH((2**(ADDR_WIDTH-2))),
//    .INIT_FILE("t200_v200/aer_train_ds_wlabels.mem")
//) BRAM_AERDATA_TRAIN_0 (
//    .ADDRA(AXI_BRAM_ADDR),
//    .ADDRB(RAM_ADDR),
//    .DINA (BRAM_PORTA_din),
//    .DINB ('d0),
//    .CLKA (BRAM_PORTA_clk),
//    .CLKB (clk_i),
//    .WEA  (BRAM_PORTA_we),
//    .WEB  (4'b0),
//    .CSA  (BRAM_PORTA_en),
//    .CSB  (CS_T),
//    .RSTA      (BRAM_PORTA_rst),
//    .REGENA    (),
//    .RSTB      (),
//    .REGENB    (),
//    .DOUTA(BRAM_PORTA_dout_b),
//    .DOUTB(DIN_TRAIN)
//);
//
//BRAM2_we_inst #(
//    .NB_COL(4),
//    .COL_WIDTH(8),
//    .RAM_WIDTH(32),
//    .RAM_DEPTH((2**(ADDR_WIDTH-2))),
//    .INIT_FILE("t200_v200/aer_val_ds_wlabels.mem")
//) BRAM_AERDATA_VAL_0 (
//    .ADDRA(AXI_BRAM_ADDR),
//    .ADDRB(RAM_ADDR),
//    .DINA (BRAM_PORTA_din),
//    .DINB ('d0),
//    .CLKA (BRAM_PORTA_clk),
//    .CLKB (clk_i),
//    .WEA  (BRAM_PORTA_we),
//    .WEB  (4'b0),
//    .CSA  (BRAM_PORTA_en),
//    .CSB  (CS_V),
//    .RSTA      (BRAM_PORTA_rst),
//    .REGENA    (),
//    .RSTB      (),
//    .REGENB    (),
//    .DOUTA(BRAM_PORTA_dout_a),
//    .DOUTB(DIN_VAL)
//);


BRAM2_we_inst #(
    .NB_COL(4),
    .COL_WIDTH(8),
    .RAM_WIDTH(32),
    .RAM_DEPTH((2**(ADDR_WIDTH))),
    .INIT_FILE("")
) BRAM_AERDATA_0 (
    .ADDRA(AXI_BRAM_ADDR),
    .ADDRB(RAM_ADDR),
    .DINA (BRAM_PORTA_din),
    .DINB ('d0),
    .CLKA (BRAM_PORTA_clk),
    .CLKB (clk_i),
    .WEA  (BRAM_PORTA_we),
    .WEB  (4'b0),
    .CSA  (BRAM_PORTA_en),
    .CSB  (CS),
    .RSTA      (BRAM_PORTA_rst),
    .REGENA    (),
    .RSTB      (),
    .REGENB    (),
    .DOUTA(BRAM_PORTA_dout),
    .DOUTB(DIN)
);
endmodule