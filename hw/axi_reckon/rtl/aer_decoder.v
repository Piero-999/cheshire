module aer_decoder #(
  parameter ADDR_WIDTH = 13
)(

  input wire CLK,

  input wire RST,
  
  input wire  STOP_i,
  input wire  TEST_i,
  input wire  NEW_BATCH_i,
  input wire  NEW_EPOCH_i,
  output wire BATCH_DONE,
  output wire EPOCH_DONE,

  output wire [7:0] AERIN_ADDR,
  output wire       AERIN_REQ,
  output wire       AERIN_TAR_EN,
  input  wire       AERIN_ACK,
  output wire       TIME_TICK,

  input wire [31:0] SPI_CYCLES_PER_TICK,
  input wire SPI_TIMING,
  input wire [11:0] N_EPOCHS_i,
  input wire [11:0] N_SAMPLES_i,
  input wire [11:0] BATCH_SIZE_i,
  input wire [11:0] SPI_LABEL_DELAY,
  input wire [11:0] SPI_INFER_ACC_DELAY,

  input  wire TIMING_ERROR_RDY,
  output wire SAMPLE,
  output wire TARGET_VALID,
  output wire INFER_ACC,

  input  wire [7:0] OUT_DATA,
  input  wire       OUT_REQ,
  output wire       OUT_ACK,

  output wire                   CS,
  input  wire [31:0]            DIN,
  output wire [ADDR_WIDTH-1:0]  RAM_ADDR,

  output wire [11:0] infer_count_o
);

  reg [11:0] data_aer_in_reg, tick_aer_in_reg;
  reg [3:0]  code_aer_in_reg;

  reg [2:0] next_state;
  reg [2:0] curr_state;

  reg aer_enable;

  wire [3:0] code_aer_in;
  wire [11:0] data_aer_in, tick_aer_in;
  reg [7:0] LABEL_IN;

  reg  [11:0] infer_count_reg;

  reg LABEL_EN, target_enable, sample_end, label_enable;

  assign code_aer_in = DIN[27:24];
  assign data_aer_in = DIN[23:12];
  assign tick_aer_in = DIN[11:0];

  reg [1:0] mem_c_state;
  reg [1:0] mem_n_state;

  reg [1:0] ends_c_state;
  reg [1:0] ends_n_state;

  reg [1:0] label_c_state;
  reg [1:0] label_n_state;

  reg TICK_EN;
  reg tick_rst, OUT_ACK_rst, RST_sync, READ, ADD_REG_EN, data_ram_valid, TAR_EN, OUT_REQ_sync, AERIN_ACK_sync;

  reg [11:0] cnt_sample_epoch, cnt_sample_batch, curr_tick;

  wire [11:0] epochs_target;
  
  reg  [11:0] cnt_epochs_reg;
  wire [11:0] cnt_epochs;

  reg [31:0] tick_delay_cnt;

  wire TIMING_ERROR;
  
  wire COMP_TICK;
  wire [11:0] target_tick;

  reg [11:0] BATCH_SIZE_sync, N_SAMPLES_sync, N_EPOCHS_sync, SPI_LABEL_DELAY_sync, SPI_INFER_ACC_DELAY_sync;

  // reg TEST_sync, TEST_sync2;

  wire [11:0] BATCH_SIZE, N_SAMPLES, N_EPOCHS;

  /*******************************/
  /************DEFINES************/
  /*******************************/

  localparam IDLE  = 3'b000;
  localparam READM = 3'b001;
  localparam END_S = 3'b010;
  localparam END_E = 3'b100;
  localparam SPIKE = 3'b111;
  localparam END_B = 3'b110;
  localparam LABEL = 3'b101;
  localparam TICK  = 3'b011;

  localparam MEM_IDLE  = 2'b00;
  localparam MEM_READ1 = 2'b01;
  localparam MEM_READ2 = 2'b10;
  localparam MEM_WRITE = 3'b11;

  localparam END_S_IDLE = 2'b00;
  localparam END_S_TICK = 2'b01;
  localparam END_S_SAMP = 2'b10;
  localparam END_S_DONE = 2'b11;

  localparam LABEL_IDLE = 2'b00;
  localparam LABEL_REQ  = 2'b01;
  localparam LABEL_ACK  = 2'b10;
  localparam LABEL_DONE = 2'b11;

  /*******************************/
  /***********REGISTERS***********/
  /*******************************/

  reg        OUT_ACK_reg;
  reg        AERIN_REQ_reg;
  reg [ 7:0] AERIN_ADDR_reg;
  reg        AERIN_TAR_EN_reg;
  reg        TIME_TICK_reg;
  reg        SAMPLE_reg;
  reg        TARGET_VALID_reg;
  reg        INFER_ACC_reg;
  reg [ADDR_WIDTH-1:0] RAM_ADDR_reg;
  reg        EPOCH_DONE_reg;
  reg        CS_reg;
  reg        BATCH_DONE_reg;

  assign OUT_ACK              = OUT_ACK_reg;
  assign AERIN_REQ            = AERIN_REQ_reg;
  assign AERIN_ADDR           = AERIN_ADDR_reg;
  assign AERIN_TAR_EN         = AERIN_TAR_EN_reg;
  assign SAMPLE               = SAMPLE_reg;
  assign TARGET_VALID         = TARGET_VALID_reg;
  assign INFER_ACC            = INFER_ACC_reg;
  assign RAM_ADDR             = RAM_ADDR_reg;
  assign EPOCH_DONE           = EPOCH_DONE_reg;
  assign infer_count_o        = infer_count_reg;
  assign CS                   = CS_reg;
  assign BATCH_DONE           = BATCH_DONE_reg;
  assign cnt_epochs           = cnt_epochs_reg;

  // reg NEW_EPOCH_sync, STOP_sync, NEW_BATCH_sync;
  // reg NEW_EPOCH_sync2, STOP_sync2, NEW_BATCH_sync2;
  reg tick_sync1, tick_sync2;
  wire tick_op;

  // always @(posedge CLK) begin
  //   NEW_EPOCH_sync  <= NEW_EPOCH_i;
  //   NEW_EPOCH_sync2 <= NEW_EPOCH_sync;
  // end

  // always @(posedge CLK) begin
  //   STOP_sync   <= STOP_i;
  //   STOP_sync2  <= STOP_sync;
  // end

  // always @(posedge CLK) begin
  //   NEW_BATCH_sync  <= NEW_BATCH_i;
  //   NEW_BATCH_sync2 <= NEW_BATCH_sync;
  // end

  always @(posedge CLK) begin
    // BATCH_SIZE_sync          <= BATCH_SIZE;
    // N_SAMPLES_sync           <= N_SAMPLES;
    // N_EPOCHS_sync            <= N_EPOCHS;
    SPI_LABEL_DELAY_sync     <= SPI_LABEL_DELAY;
    SPI_INFER_ACC_DELAY_sync <= SPI_INFER_ACC_DELAY;
    // TEST_sync                <= TEST_i;
    // TEST_sync2               <= TEST_sync;
  end

  /*******************************/
  /********TICK GENERATOR*********/
  /*******************************/

  // FSM control inputs mirrored as local wires.
  wire NEW_EPOCH, NEW_BATCH, STOP, TEST;
  
  assign TIMING_ERROR = ~(SPI_TIMING ^ TIMING_ERROR_RDY);
  assign target_tick  = (curr_state == LABEL) ? SPI_LABEL_DELAY_sync : tick_aer_in_reg;
  assign COMP_TICK    = (curr_tick == target_tick);
  assign epochs_target     = TEST ? 12'd1 : N_EPOCHS;

  always @(posedge CLK) begin
    tick_sync1 <= TIME_TICK;
    tick_sync2 <= tick_sync1;

    if      (tick_rst || tick_op)                        tick_delay_cnt <= 32'd1;
    else if (TICK_EN && ~tick_op)                        tick_delay_cnt <= tick_delay_cnt + 32'd1;

    if      ( (ends_c_state == END_S_DONE) || tick_rst)  curr_tick <= 12'b0;
    else if (tick_sync2)                                 curr_tick <= curr_tick + 12'd1;  
  end

  assign TIME_TICK = (tick_delay_cnt == SPI_CYCLES_PER_TICK) ? 1'b1 : 1'b0;
  assign tick_op   = (TIME_TICK | tick_sync1 | tick_sync2);

  /*******************************/
  /***************FSM*************/
  /*******************************/

  /////INPUT SIGNALS
  assign NEW_EPOCH = NEW_EPOCH_i;
  assign NEW_BATCH = NEW_BATCH_i;
  assign STOP = STOP_i;
  assign TEST = TEST_i;

  ///////  INPUT PARAMS

  assign N_EPOCHS   = N_EPOCHS_i;
  assign N_SAMPLES  = N_SAMPLES_i;
  assign BATCH_SIZE = BATCH_SIZE_i;

  always @(*) begin
    case (curr_state)
      IDLE:    next_state <= NEW_EPOCH ? READM : IDLE;
      READM: begin
        if (data_ram_valid) begin
          case (code_aer_in)
            4'h3:    next_state <= TICK;
            4'h2:    next_state <= LABEL;
            4'h1:    next_state <= END_S;
            default: next_state <= READM;
          endcase
        end else next_state <= READM;
      end
      TICK:    next_state <= (curr_tick == target_tick) ? ( (code_aer_in_reg == 4'h3) ? SPIKE : IDLE) : TICK;
      SPIKE:   next_state <= AERIN_ACK ? READM : SPIKE;
      LABEL:   next_state <= (TEST || target_enable) ? READM : LABEL;
      END_S:   next_state <= sample_end                                ? (cnt_sample_batch == BATCH_SIZE ? END_B  : READM) : END_S;
      END_B:   next_state <= (cnt_sample_epoch == N_SAMPLES)  ? END_E                      : (NEW_BATCH ? READM : END_B);
      END_E:   next_state <= (cnt_epochs_reg   == epochs_target)            ? (STOP ? IDLE : END_E) : (NEW_EPOCH ? READM : END_E);
      default: next_state <= IDLE;
    endcase
  end

  always @(posedge CLK, posedge RST) begin
    if (RST) begin
      curr_state    <= IDLE;
      mem_c_state   <= MEM_IDLE;
      ends_c_state  <= END_S_IDLE;
      label_c_state <= LABEL_IDLE;
    end else if (CLK) begin
      curr_state    <= next_state;
      mem_c_state   <= mem_n_state;
      ends_c_state  <= ends_n_state;
      label_c_state <= label_n_state;
    end
  end

  always @(posedge CLK, posedge RST_sync) begin
    if (RST_sync) begin
      code_aer_in_reg   <= 'b0;
      data_aer_in_reg   <= 'b0;
      tick_aer_in_reg   <= 'b0;
      LABEL_IN          <= 'b0;
    end else if (CLK) begin
      if (data_ram_valid) begin
          code_aer_in_reg <= code_aer_in;
          data_aer_in_reg <= data_aer_in;
          tick_aer_in_reg <= tick_aer_in;
      end
      if (LABEL_EN) LABEL_IN <= data_aer_in[7:0];
    end
  end

  always @(*) begin  //Mealy
    case (curr_state)
      IDLE: begin
        aer_enable      <= 1'b0;
        READ            <= 1'b0;
        TICK_EN         <= 1'b0;
        EPOCH_DONE_reg  <= 1'b0;
        tick_rst        <= 1'b1;
        LABEL_EN        <= 1'b0;
        RST_sync        <= 1'b1;
        BATCH_DONE_reg  <= 1'b0;
      end

      READM: begin
        aer_enable      <= 1'b0;
        READ            <= 1'b1;
        TICK_EN         <= 1'b0;
        EPOCH_DONE_reg  <= 1'b0;
        tick_rst        <= 1'b0;
        LABEL_EN        <= 1'b0;
        RST_sync        <= 1'b0;
        BATCH_DONE_reg  <= 1'b0;
      end

      TICK: begin
        aer_enable      <= 1'b0;
        READ            <= 1'b0;
        TICK_EN         <=  (TIMING_ERROR || COMP_TICK) ? 1'b0 : 1'b1;
        EPOCH_DONE_reg  <=  1'b0;
        tick_rst        <=  1'b0;
        LABEL_EN        <=  1'b0;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b0;
      end

      SPIKE: begin
        aer_enable      <=  1'b1;
        READ            <=  1'b0;
        TICK_EN         <=  1'b0;
        EPOCH_DONE_reg  <=  1'b0;
        tick_rst        <=  1'b0;
        LABEL_EN        <=  1'b0;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b0;
      end

      LABEL: begin
        aer_enable      <=  1'b0;
        READ            <=  1'b0;
        TICK_EN         <=  (TIMING_ERROR || COMP_TICK) ? 1'b0 : 1'b1;
        EPOCH_DONE_reg  <=  1'b0;
        tick_rst        <=  1'b0;
        LABEL_EN        <=  (TEST || (curr_tick == SPI_LABEL_DELAY_sync) ) ? 1'b1 : 1'b0 ;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b0;
      end

      END_S: begin
        aer_enable      <=  1'b0;
        READ            <=  1'b0;
        TICK_EN         <=  (TIMING_ERROR || COMP_TICK) ? 1'b0 : 1'b1;
        EPOCH_DONE_reg  <=  1'b0;
        tick_rst        <=  1'b0;
        LABEL_EN        <=  1'b0;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b0;
      end

      END_B: begin
        aer_enable      <=  1'b0;
        READ            <=  1'b0;
        TICK_EN         <=  1'b0;
        EPOCH_DONE_reg  <=  1'b0;
        tick_rst        <=  1'b1;
        LABEL_EN        <=  1'b0;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b1;
      end

      END_E: begin
        aer_enable      <=  1'b0;
        READ            <=  1'b0;
        TICK_EN         <=  1'b0;
        EPOCH_DONE_reg  <=  1'b1;
        tick_rst        <=  1'b1;
        LABEL_EN        <=  1'b0;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b0;
      end

      default: begin
        aer_enable      <=  1'b0;
        READ            <=  1'b0;
        TICK_EN         <=  1'b0;
        EPOCH_DONE_reg  <=  1'b0;
        tick_rst        <=  1'b0;
        LABEL_EN        <=  1'b0;
        RST_sync        <=  1'b0;
        BATCH_DONE_reg  <=  1'b0;
      end
    endcase
  end

  always @(ends_c_state, RST_sync, curr_state, curr_tick, OUT_REQ_sync, OUT_REQ) begin
    if (RST_sync) ends_n_state <=  END_S_IDLE;
    else case(ends_c_state)
      END_S_IDLE: ends_n_state <=  curr_state == END_S                 ? END_S_TICK : END_S_IDLE;
      END_S_TICK: ends_n_state <=  curr_tick == (target_tick - 12'd1)  ? END_S_SAMP : END_S_TICK;
      END_S_SAMP: ends_n_state <=  (OUT_REQ_sync && ~OUT_REQ)          ? END_S_DONE : END_S_SAMP;
      END_S_DONE: ends_n_state <=                                        END_S_IDLE             ;
    endcase // ends_c_state
  end

  always @(ends_c_state) begin
    case (ends_c_state)
      END_S_IDLE: begin
        sample_end <=  1'b0;
      end
      END_S_TICK: begin
        sample_end <=  1'b0;
      end
      END_S_SAMP: begin
        sample_end <=  1'b0;
      end
      END_S_DONE: begin
        sample_end <=  1'b1;
      end
    endcase
  end

  always @(posedge CLK, posedge RST_sync) begin
    if (sample_end || RST_sync) begin
                                                          TARGET_VALID_reg <= 1'b0;
                                                          INFER_ACC_reg    <= 1'b0;
    end else begin
      if (target_enable)                                       TARGET_VALID_reg <= TEST ? 1'b0 : 1'b1;  
      if (tick_sync2 && curr_tick == SPI_INFER_ACC_DELAY_sync) INFER_ACC_reg    <= 1'b1;
    end
  end

  always @(posedge CLK) begin
    if      (curr_state == IDLE)                                            SAMPLE_reg <= 1'b0;
    else if (curr_tick == 0 && (curr_state == TICK || curr_state == LABEL)) SAMPLE_reg <= 1'b1;
    else if ( (ends_c_state == END_S_SAMP) && TICK_EN )                     SAMPLE_reg <= 1'b0;
  end

  always @(label_c_state, RST_sync, LABEL_EN, AERIN_ACK) begin
    if (RST_sync) label_n_state <=  LABEL_IDLE;
    else case (label_c_state)
      LABEL_IDLE: label_n_state <=  LABEL_EN ? ( TEST ? LABEL_DONE : LABEL_REQ ) : LABEL_IDLE;
      LABEL_REQ:  label_n_state <=  AERIN_ACK ? LABEL_ACK : LABEL_REQ;
      LABEL_ACK:  label_n_state <=  ~AERIN_ACK ? LABEL_DONE : LABEL_ACK;
      LABEL_DONE: label_n_state <=  LABEL_IDLE;
      default:    label_n_state <=  LABEL_IDLE;
    endcase
  end

  always @(label_c_state) begin
    case (label_c_state)
      LABEL_IDLE: begin
        label_enable  <=  1'b0;
        target_enable <=  1'b0;
        AERIN_TAR_EN_reg <=  1'b0;
      end
      LABEL_REQ: begin
        label_enable  <=  1'b1;
        target_enable <=  1'b0;
        AERIN_TAR_EN_reg  <=  1'b1;
      end
      LABEL_ACK: begin
        label_enable  <=  1'b0;
        target_enable <=  1'b0;
        AERIN_TAR_EN_reg <=  1'b1;
      end
      LABEL_DONE: begin
        label_enable  <=  1'b0;
        target_enable <=  1'b1;
        AERIN_TAR_EN_reg <=  1'b0;
      end
      default: begin
        label_enable  <=  1'b0;
        target_enable <=  1'b0;
        AERIN_TAR_EN_reg <=  1'b0;
      end
    endcase
  end

  /*******************************/
  /***************AER*************/
  /*******************************/

  always @(posedge CLK, posedge RST_sync) begin
    if (RST_sync) begin
      AERIN_REQ_reg     <= 1'b0;
      AERIN_ADDR_reg    <= 8'b0;       
    end else if ( (aer_enable || label_enable) && ~AERIN_ACK) begin
      AERIN_ADDR_reg    <= data_aer_in_reg[7:0];
      AERIN_REQ_reg     <= 1'b1;
    end else if (AERIN_REQ && AERIN_ACK)
      AERIN_REQ_reg     <= 1'b0;
  end

  always @(posedge CLK)
    AERIN_ACK_sync <= AERIN_ACK;

  always @(posedge CLK) begin
    if      ((curr_state == IDLE) || (curr_state == END_E))  cnt_sample_epoch <= 12'b0;
    else if (curr_state == READM && next_state == END_S)     cnt_sample_epoch <= cnt_sample_epoch + 12'd1;
    //else if (sample_end)                                      cnt_sample_epoch <= cnt_sample_epoch + 12'd1;
  end

  always @(posedge CLK) begin
    if      ((curr_state == IDLE) || (curr_state == END_B))  cnt_sample_batch <= 12'b0;
    else if (curr_state == READM && next_state == END_S)     cnt_sample_batch <= cnt_sample_batch + 12'd1;
    //else if (sample_end)                                      cnt_sample_batch <= cnt_sample_batch + 12'd1;
  end

  always @(posedge CLK) begin
    if            (curr_state == IDLE) begin
                                              cnt_epochs_reg          <= 12'b0;
//                                              best_infer_accuracy_reg <= 12'b0;
    end else if ( (curr_state == END_B) && (next_state == END_E) ) begin
                                              cnt_epochs_reg          <= cnt_epochs_reg + 12'd1;
//      if (infer_count > best_infer_accuracy)  best_infer_accuracy_reg <= infer_count;
    end
  end

  always @(posedge CLK, posedge RST_sync) begin
    if      (RST_sync)            OUT_ACK_reg <= 1'b0;
    else if (OUT_REQ_sync)        OUT_ACK_reg <= 1'b1;
    else if (~OUT_REQ && OUT_ACK) OUT_ACK_reg <= 1'b0;
  end

  always @(posedge CLK) begin
    if      ( (curr_state == IDLE) || (curr_state == END_E && next_state != END_E) )    infer_count_reg <= 12'b0;
    else if (~OUT_REQ_sync && OUT_REQ) if (OUT_DATA == LABEL_IN) infer_count_reg <= infer_count_reg + 12'd1; 
  end

  always @(posedge CLK)
    OUT_REQ_sync <= OUT_REQ;

  /*******************************/
  /*******MEMORY INTERFACE********/
  /*******************************/

  always @(mem_c_state, READ, RST_sync) begin
    case (mem_c_state)
      MEM_IDLE: begin
        mem_n_state <=  READ ? MEM_READ1 : MEM_IDLE;
      end
      MEM_READ1: begin
        mem_n_state <=  MEM_READ2;
      end
      MEM_READ2: begin
        mem_n_state <=  MEM_IDLE;
      end
      default: begin
        mem_n_state <=  MEM_IDLE;
      end
    endcase
  end

  always @(mem_c_state) begin
    case (mem_c_state)
      MEM_IDLE: begin
        CS_reg <=  1'b0;
        ADD_REG_EN <=  1'b0;
        data_ram_valid <=  1'b0;
      end
      MEM_READ1: begin
        CS_reg <=  1'b1;
        ADD_REG_EN <=  1'b0;
        data_ram_valid <=  1'b0;
      end
      MEM_READ2: begin
        CS_reg <=  1'b0;
        ADD_REG_EN <=  1'b1;
        data_ram_valid <=  1'b1;
      end
      default: begin
        CS_reg <=  1'b0;
        ADD_REG_EN <=  1'b0;
        data_ram_valid <=  1'b0;
      end
    endcase
  end

  always @(posedge CLK) begin
    if ( (curr_state == IDLE) || (curr_state == END_E) || (curr_state == END_B) ) RAM_ADDR_reg <= {ADDR_WIDTH{1'b0}};
    else if (ADD_REG_EN)                                                          RAM_ADDR_reg <= RAM_ADDR + {{ADDR_WIDTH-2{1'b0}}, 1'd1};
  end

  /*******************************/
  /******DEBUG UNIT - AXI RF******/
  /*******************************/
  
  // wire infer_count_dbg;
  // wire cnt_epochs_dbg;
  // wire ram_addr_o_dbg;
  
  // reg [11:0] infer_count_o_reg, cnt_epochs_o_reg;
  // reg [11:0] samples_batch_o_reg, samples_epoch_o_reg;
  // reg [ADDR_WIDTH-1:0] ram_addr_o_reg;
  
  // assign infer_count_dbg = (ends_c_state == END_S_DONE) && (ends_n_state == END_S_IDLE);
  // assign cnt_epochs_dbg  = (curr_state == END_E);
  // assign ram_addr_dbg  = (mem_c_state == MEM_READ2) && (mem_n_state == MEM_IDLE);

  // always @(posedge CLK) begin
  //   if (RST_sync) begin
  //     infer_count_o_reg <= 12'b0;
  //     cnt_epochs_o_reg  <= 12'b0;
  //   end else begin
  //     if (infer_count_dbg) infer_count_o_reg <= infer_count;
  //     if (cnt_epochs_dbg)  cnt_epochs_o_reg  <= cnt_epochs;
  //     if (ram_addr_dbg)    ram_addr_o_reg    <= RAM_ADDR;
  //     samples_batch_o_reg <= BATCH_SIZE_sync;
  //     samples_epoch_o_reg <= N_SAMPLES_sync;
  //   end
  // end 

  // // assign infer_count_o = infer_count_o_reg;
  // assign cnt_epochs_o  = cnt_epochs_o_reg;
  // assign batch_size_o  = samples_batch_o_reg;
  // assign n_samples_o   = samples_epoch_o_reg;
  // assign ram_addr_o    = ram_addr_o_reg;


endmodule