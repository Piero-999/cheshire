`define N 256
`define M 8

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
    input wire [2:0 ] do_eprop_i,

    // ═══ Streaming DDR4→BRAM: nuovi segnali ═══
    output wire ram_addr_half_o,     // quale metà sta leggendo aer_decoder
    input  wire fill_done_i,         // da Cheshire: metà libera riempita via DMA
    input  wire data_exhausted_i     // da Cheshire: dati DDR4 finiti

);

wire [31:0] SPI_CYCLES_PER_TICK;
wire [11:0] SPI_N_EPOCHS, SPI_N_SAMPLES, SPI_BATCH_SIZE;
wire [11:0] N_SAMPLES, BATCH_SIZE;
reg  [11:0] N_SAMPLES_reg, BATCH_SIZE_reg;
wire [11:0] SPI_LABEL_DELAY, SPI_INFER_ACC_DELAY;
wire        SPI_TIMING;

wire [2:0 ] DO_EPROP;
reg  [2:0 ] DO_EPROP_reg;

wire [ADDR_WIDTH-1:0] AXI_BRAM_ADDR;

wire AERIN_TAR_EN;
wire TIME_TICK;
wire INFER_ACC;
wire TIMING_ERROR_RDY;

wire [31:0] DIN;
wire CS;
wire [ADDR_WIDTH-1:0] RAM_ADDR;

assign AXI_BRAM_ADDR = BRAM_PORTA_addr[ADDR_WIDTH+1:2];

wire [7:0] OUT_DATA, AERIN_ADDR;

always @(posedge clk_i) begin
    N_SAMPLES_reg  <= n_samples_i;
    BATCH_SIZE_reg <= batch_size_i;
    DO_EPROP_reg   <= do_eprop_i;
end

assign N_SAMPLES = N_SAMPLES_reg;
assign BATCH_SIZE = BATCH_SIZE_reg;
assign DO_EPROP = DO_EPROP_reg;

wire NEW_BATCH, NEW_EPOCH, TEST, STOP, EPOCH_DONE_wire, BATCH_DONE_wire;
reg  NEW_BATCH_sync, NEW_EPOCH_sync, TEST_sync, STOP_sync, EPOCH_DONE_reg, BATCH_DONE_reg;

always @(posedge clk_i) begin
    NEW_BATCH_sync <= NEW_BATCH;
    NEW_EPOCH_sync <= NEW_EPOCH;
    TEST_sync      <= TEST;
    STOP_sync      <= STOP;
    EPOCH_DONE_reg <= EPOCH_DONE_wire;
    BATCH_DONE_reg <= BATCH_DONE_wire;
end

assign reckon_ctrl_o_0[0] = EPOCH_DONE_reg;
assign reckon_ctrl_o_1[0] = BATCH_DONE_reg;

assign NEW_EPOCH      = reckon_ctrl_i_0[0];
assign NEW_BATCH      = reckon_ctrl_i_1[0];
assign TEST           = reckon_ctrl_i_2[0];
assign STOP           = reckon_ctrl_i_3[0];

/////////////////////////////////////////////////
//  Streaming DDR4→BRAM: CDC + Auto-NEW_BATCH  //
/////////////////////////////////////////////////

// --- CDC: fill_done (soc_clk → clk_i = clk15) ---
reg fill_done_sync1, fill_done_sync2;
always @(posedge clk_i) begin
    if (rst_i) begin
        fill_done_sync1 <= 1'b0;
        fill_done_sync2 <= 1'b0;
    end else begin
        fill_done_sync1 <= fill_done_i;
        fill_done_sync2 <= fill_done_sync1;
    end
end
wire fill_done_sync = fill_done_sync2;

// --- CDC: data_exhausted (soc_clk → clk_i = clk15) ---
reg data_exhausted_sync1, data_exhausted_sync2;
always @(posedge clk_i) begin
    if (rst_i) begin
        data_exhausted_sync1 <= 1'b0;
        data_exhausted_sync2 <= 1'b0;
    end else begin
        data_exhausted_sync1 <= data_exhausted_i;
        data_exhausted_sync2 <= data_exhausted_sync1;
    end
end

// --- Edge detector su BATCH_DONE (genera pulse di 1 ciclo) ---
reg batch_done_prev;
wire batch_done_rising;
always @(posedge clk_i) begin
    if (rst_i) batch_done_prev <= 1'b0;
    else       batch_done_prev <= BATCH_DONE_wire;
end
assign batch_done_rising = BATCH_DONE_wire & ~batch_done_prev;

// --- Auto-NEW_BATCH: pulse quando BATCH_DONE sale E fill_done è 1 ---
// Questo viene OR-ato con il NEW_BATCH manuale da Cheshire.
// Se data_exhausted è attivo, NON generare auto_new_batch (ReckOn si ferma).
reg auto_new_batch;
always @(posedge clk_i) begin
    if (rst_i)
        auto_new_batch <= 1'b0;
    else if (batch_done_rising && fill_done_sync && !data_exhausted_sync2)
        auto_new_batch <= 1'b1;
    else
        auto_new_batch <= 1'b0;  // pulse di 1 ciclo
end

// NEW_BATCH combinato: manuale (da SW) OR automatico (da HW) // 
wire NEW_BATCH_combined = NEW_BATCH_sync | auto_new_batch;

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
    .SPI_N_EPOCHS(SPI_N_EPOCHS),
    .SPI_N_SAMPLES(SPI_N_SAMPLES),
    .SPI_BATCH_SIZE(SPI_BATCH_SIZE),
    .SPI_LABEL_DELAY(SPI_LABEL_DELAY),
    .SPI_INFER_ACC_DELAY(SPI_INFER_ACC_DELAY),
    .OUT_REQ(OUT_REQ),
    .OUT_ACK(OUT_ACK),
    .OUT_DATA(OUT_DATA),
    .infer_count(infer_count_o),
    .SPI_EN_CONF(SPI_EN_CONF),
    .DO_EPROP(DO_EPROP)
);

aer_decoder #(
    .ADDR_WIDTH(ADDR_WIDTH)
) aer_decoder_0 (

    .CLK(clk_i),

    .STOP(STOP_sync),
    .RST(rst_i),

    .TEST(TEST_sync),

    .AERIN_ADDR(AERIN_ADDR),
    .AERIN_REQ(AERIN_REQ),
    .AERIN_TAR_EN(AERIN_TAR_EN),
    .AERIN_ACK(AERIN_ACK),
    .TIME_TICK(TIME_TICK),
    .SPI_CYCLES_PER_TICK(SPI_CYCLES_PER_TICK),

    .SPI_TIMING(SPI_TIMING_MODE),
    .SPI_N_EPOCHS(SPI_N_EPOCHS),
    .N_SAMPLES(N_SAMPLES),
    .BATCH_SIZE(BATCH_SIZE),
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

    .NEW_BATCH(NEW_BATCH_combined),   
    .NEW_EPOCH(NEW_EPOCH_sync),
    .BATCH_DONE(BATCH_DONE_wire),
    .EPOCH_DONE(EPOCH_DONE_wire),

    .infer_count_o(infer_count_o),

    
    .ram_addr_half_o(ram_addr_half_o),
    .data_exhausted_i(data_exhausted_sync2)
);

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
