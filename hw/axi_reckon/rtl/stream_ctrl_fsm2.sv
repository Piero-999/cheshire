// stream_ctrl_fsm2 — DDR4->BRAM->ReckOn streaming control (one batch = one BRAM half).
//
// Single owner of the streaming handshake state. The CVA6 fills a BRAM half and
// toggles fill_tgl[h]; ReckOn releases the half it was reading at END_B. The only
// gate is the exit from END_B (new_batch_o / data_exhausted_o). Pair with
// aer_decoder #(.HALF_BATCH(1)).
//
// Ports of note:
//   fill_tgl_i[h]  one toggle per half (carries the half identity)
//   exhausted_i    monotone level, DDR4 data is over
//   new_batch_o    1-cycle pulse: release END_B onto the next half
//   status_o       status word crossing to soc_clk (see the SW contract)
//
// No timescale directive, like the modules next to it: elaborate with
// xelab -timescale 1ns/1ps.

module stream_ctrl_fsm2 #(
  parameter int unsigned ADDR_WIDTH = 16,
  parameter logic [7:0]  VERSION    = 8'hA6
) (
  // soc_clk domain (CVA6 / register file side)
  input  logic                  soc_clk_i,
  input  logic                  soc_rst_ni,
  input  logic [1:0]            fill_tgl_i,    // one toggle per half: [h] = half h filled
  input  logic                  exhausted_i,   // monotone level, DDR4 data is over
  output logic [31:0]           status_o,

  // acc_clk = clk15 domain (ReckOn / aer_decoder side)
  input  logic                  acc_clk_i,
  input  logic                  acc_rst_ni,
  input  logic                  batch_done_i,  // level: high in END_B
  input  logic                  epoch_done_i,  // level: high in END_E
  input  logic                  cs_i,          // aer_decoder is reading ram_addr_i
  input  logic [ADDR_WIDTH-1:0] ram_addr_i,
  output logic                  new_batch_o,   // 1-cycle pulse: release END_B
  output logic                  data_exhausted_o
);

  localparam int unsigned HALF_BIT = ADDR_WIDTH - 1;
  localparam int unsigned LOCK     = 3;        // acc cycles the status word stays frozen

  // soc_clk -> acc_clk: two toggles and one level, one bit each.
  (* ASYNC_REG = "TRUE" *) logic [1:0] fill_s1, fill_s2;
                           logic [1:0] fill_s3;
  (* ASYNC_REG = "TRUE" *) logic       exh_s1, exh_s2;

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      fill_s1 <= 2'b00;
      fill_s2 <= 2'b00;
      fill_s3 <= 2'b00;
      exh_s1  <= 1'b0;
      exh_s2  <= 1'b0;
    end else begin
      fill_s1 <= fill_tgl_i;
      fill_s2 <= fill_s1;
      fill_s3 <= fill_s2;   // delayed copy for the edge detector
      exh_s1  <= exhausted_i;
      exh_s2  <= exh_s1;
    end
  end

  logic [1:0] fill_pulse;
  assign fill_pulse = fill_s2 ^ fill_s3;   // both edges count

  // Events from ReckOn (native to acc_clk: no CDC).
  logic bdone_q, epd_q;
  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      bdone_q <= 1'b0;
      epd_q   <= 1'b0;
    end else begin
      bdone_q <= batch_done_i;
      epd_q   <= epoch_done_i;
    end
  end

  logic bdone_rise, epd_rise;
  assign bdone_rise = batch_done_i & ~bdone_q;   // ReckOn finished the current half
  assign epd_rise   = epoch_done_i & ~epd_q;     // epoch end: restart from half 0

  // Half ownership and the half being read.
  logic [1:0] owner_q;     // 1 = ReckOn may read, 0 = free for the CVA6
  logic       read_half_q; // mirror of half_sel inside aer_decoder

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      owner_q     <= 2'b00;
      read_half_q <= 1'b0;
    end else begin
      // Release: ReckOn consumed the half it was working on and moves to the other.
      if (bdone_rise) begin
        owner_q[read_half_q] <= 1'b0;
        read_half_q          <= ~read_half_q;
      end
      // Epoch end: aer_decoder resets half_sel, both halves must be refilled.
      if (epd_rise) begin
        owner_q     <= 2'b00;
        read_half_q <= 1'b0;
      end
      // Grant: the CVA6 filled half h. Wins over the assignments above (it is last):
      // a fill in the same cycle as a release is fresh data.
      for (int unsigned h = 0; h < 2; h++) begin
        if (fill_pulse[h]) owner_q[h] <= 1'b1;
      end
    end
  end

  // The only gate: exit from END_B.
  // On the bdone_rise cycle read_half_q still points at the half just finished; wait
  // for the next cycle, when it points at the next half.
  logic grant, nb_sent_q, new_batch_q;
  assign grant = batch_done_i & ~bdone_rise & owner_q[read_half_q] & ~nb_sent_q;

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      nb_sent_q   <= 1'b0;
      new_batch_q <= 1'b0;
    end else begin
      new_batch_q <= grant;
      nb_sent_q   <= batch_done_i ? (nb_sent_q | grant) : 1'b0;
    end
  end
  assign new_batch_o = new_batch_q;

  // End of data: only if the half we would touch now was not granted. If it was,
  // grant consumes it, so the last filled half is never lost and the arrival order
  // of exhausted versus the last fill is irrelevant.
  assign data_exhausted_o = exh_s2 & ~bdone_rise & ~owner_q[read_half_q];

  // Sticky diagnostics and counters.
  logic       underrun_q;  // ReckOn had to wait: the CVA6 is not keeping up
  logic       overrun_q;   // a batch ran past its half: wrong data layout
  logic [7:0] consumed_q;  // halves consumed (free-running, wraps)
  logic [7:0] fill_cnt_q;  // fill toggles seen (free-running, wraps)

  logic waiting, overrun;
  assign waiting = batch_done_i & ~bdone_rise & ~owner_q[read_half_q] & ~exh_s2;
  // Every read must land in the half ReckOn owns. Gated by cs_i, not by ~batch_done_i:
  // after the last word of a half RAM_ADDR increments and already points at the other
  // half, but that address is never read.
  assign overrun = cs_i & (ram_addr_i[HALF_BIT] != read_half_q);

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      underrun_q <= 1'b0;
      overrun_q  <= 1'b0;
      consumed_q <= 8'h0;
      fill_cnt_q <= 8'h0;
    end else begin
      if (waiting)     underrun_q <= 1'b1;
      if (overrun)     overrun_q  <= 1'b1;
      if (bdone_rise)  consumed_q <= consumed_q + 8'd1;
      if (|fill_pulse) fill_cnt_q <= fill_cnt_q + 8'd1;
    end
  end

  // Status word: assembled in acc_clk, crosses once toward soc_clk.
  logic need_fill;
  assign need_fill = ~&owner_q;

  logic [31:0] status_acc;
  assign status_acc = { VERSION,                  // [31:24] sanity marker
                        fill_cnt_q,               // [23:16]
                        consumed_q,               // [15:8]
                        1'b0,                     // [7]  reserved
                        overrun_q,                // [6]
                        underrun_q,               // [5]
                        need_fill,                // [4]
                        1'b0,                     // [3]  reserved
                        read_half_q,              // [2]  half ReckOn is reading
                        owner_q };                // [1:0] 0 = fillable by the CVA6

  logic [31:0] status_hold_q;
  logic        status_tgl_q, pending_q;
  logic [1:0]  lock_q;               // LOCK = 3 fits in 2 bits

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      status_hold_q <= {VERSION, 24'h0};
      status_tgl_q  <= 1'b0;
      pending_q     <= 1'b0;
      lock_q        <= 2'd0;
    end else if (pending_q) begin
      status_tgl_q  <= ~status_tgl_q;   // data has been frozen for one cycle already
      pending_q     <= 1'b0;
      lock_q        <= 2'(LOCK);
    end else if (lock_q != 2'd0) begin
      lock_q        <= lock_q - 2'd1;   // hold the data while soc captures it
    end else if (status_acc != status_hold_q) begin
      status_hold_q <= status_acc;
      pending_q     <= 1'b1;
    end
  end

  (* ASYNC_REG = "TRUE" *) logic tgl_s1, tgl_s2;
                           logic tgl_s3;

  always_ff @(posedge soc_clk_i or negedge soc_rst_ni) begin
    if (!soc_rst_ni) begin
      tgl_s1   <= 1'b0;
      tgl_s2   <= 1'b0;
      tgl_s3   <= 1'b0;
      status_o <= {VERSION, 24'h0};
    end else begin
      tgl_s1 <= status_tgl_q;
      tgl_s2 <= tgl_s1;
      tgl_s3 <= tgl_s2;
      if (tgl_s2 ^ tgl_s3) status_o <= status_hold_q;
    end
  end

`ifndef SYNTHESIS
  // The CVA6 must never write a half ReckOn owns.
  assert property (@(posedge acc_clk_i) disable iff (!acc_rst_ni)
    fill_pulse[0] |-> !owner_q[0])
    else $error("stream_ctrl_fsm2: fill_tgl[0] on a half still owned by ReckOn");
  assert property (@(posedge acc_clk_i) disable iff (!acc_rst_ni)
    fill_pulse[1] |-> !owner_q[1])
    else $error("stream_ctrl_fsm2: fill_tgl[1] on a half still owned by ReckOn");

  // new_batch_o is a one-cycle pulse.
  assert property (@(posedge acc_clk_i) disable iff (!acc_rst_ni)
    new_batch_o |=> !new_batch_o)
    else $error("stream_ctrl_fsm2: new_batch_o wider than one cycle");

  // The two outputs toward aer_decoder are mutually exclusive by construction.
  assert property (@(posedge acc_clk_i) disable iff (!acc_rst_ni)
    !(new_batch_o && data_exhausted_o))
    else $error("stream_ctrl_fsm2: new_batch_o and data_exhausted_o together");
`endif

endmodule
