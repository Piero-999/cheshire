// stream_ctrl_fsm — DDR4->BRAM->ReckOn streaming control, v1 (one batch = whole BRAM).
//
// Superseded by stream_ctrl_fsm2 (kept in the repo, out of the synthesis sources).
// Here a batch spans both BRAM halves, so ReckOn enters a half at two points: the
// lower one at END_B (a handshake) and the upper one mid-sweep (no handshake). The
// upper entry needs its own gate, stall_read_o.
//
// Ports of note:
//   fill_tgl_i     single toggle; the CVA6 inverts it after each filled half
//   exhausted_i    monotone level, DDR4 data is over
//   new_batch_o    1-cycle pulse: release END_B
//   stall_read_o   freeze aer_decoder reads until the requested half is ready
//   status_o       status word crossing to soc_clk (see the SW contract)
//
// No timescale directive, like the modules next to it: elaborate with
// xelab -timescale 1ns/1ps.

module stream_ctrl_fsm #(
  parameter int unsigned ADDR_WIDTH = 16,
  parameter logic [7:0]  VERSION    = 8'hA5
) (
  // soc_clk domain (CVA6 / register file side)
  input  logic                  soc_clk_i,
  input  logic                  soc_rst_ni,
  input  logic                  fill_tgl_i,    // out_reg[7][1]: CVA6 inverts after each filled half
  input  logic                  exhausted_i,   // out_reg[7][2]: monotone level, DDR4 data is over
  output logic [31:0]           status_o,      // in_reg[3]

  // acc_clk = clk15 domain (ReckOn / aer_decoder side)
  input  logic                  acc_clk_i,
  input  logic                  acc_rst_ni,
  input  logic                  batch_done_i,  // level from aer_decoder (high in END_B)
  input  logic [ADDR_WIDTH-1:0] ram_addr_i,    // aer_decoder read address
  output logic                  new_batch_o,   // 1-cycle pulse: release END_B
  output logic                  stall_read_o,  // freeze aer_decoder BRAM reads
  output logic                  data_exhausted_o
);

  localparam int unsigned HALF_BIT = ADDR_WIDTH - 1;

  // soc_clk -> acc_clk: one toggle and one level, one bit each.
  (* ASYNC_REG = "TRUE" *) logic fill_tgl_s1, fill_tgl_s2;
                           logic fill_tgl_s3;
  (* ASYNC_REG = "TRUE" *) logic exh_s1, exh_s2;

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      fill_tgl_s1 <= 1'b0;
      fill_tgl_s2 <= 1'b0;
      fill_tgl_s3 <= 1'b0;
      exh_s1      <= 1'b0;
      exh_s2      <= 1'b0;
    end else begin
      fill_tgl_s1 <= fill_tgl_i;
      fill_tgl_s2 <= fill_tgl_s1;
      fill_tgl_s3 <= fill_tgl_s2;   // delayed copy for the edge detector
      exh_s1      <= exhausted_i;
      exh_s2      <= exh_s1;
    end
  end

  // One fill_tgl transition = one filled half. Both edges count.
  logic fill_pulse;
  assign fill_pulse = fill_tgl_s2 ^ fill_tgl_s3;

  // Events from ReckOn (native to acc_clk: no CDC).
  logic half_q, bdone_q;
  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      half_q  <= 1'b0;
      bdone_q <= 1'b0;
    end else begin
      half_q  <= ram_addr_i[HALF_BIT];
      bdone_q <= batch_done_i;
    end
  end

  logic cross_up;    // ReckOn left the lower half and enters the upper one
  logic bdone_rise;  // ReckOn reached END_B: it leaves the upper half
  assign cross_up   =  ram_addr_i[HALF_BIT] & ~half_q;
  assign bdone_rise =  batch_done_i         & ~bdone_q;

  // Half ownership.
  logic [1:0] owner_q;    // 1 = ReckOn may read, 0 = free for the CVA6
  logic       fill_ptr_q; // which half the CVA6 must fill now

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      owner_q    <= 2'b00;
      fill_ptr_q <= 1'b0;
    end else begin
      // Release: ReckOn finished with the half.
      if (cross_up)   owner_q[0] <= 1'b0;
      if (bdone_rise) owner_q[1] <= 1'b0;
      // Grant: the CVA6 filled it. If it falls in the same cycle as a release of the
      // same half, the grant wins (it is the later assignment): the freshly written
      // data is the good one.
      if (fill_pulse) begin
        owner_q[fill_ptr_q] <= 1'b1;
        fill_ptr_q          <= ~fill_ptr_q;
      end
    end
  end

  // The two gates.

  // (1) Entry into the lower half: release END_B only if the lower half is ready.
  //     nb_sent_q guarantees a single pulse per stay in END_B.
  logic nb_sent_q, new_batch_q;
  logic grant_lower;
  assign grant_lower = batch_done_i & owner_q[0] & ~nb_sent_q;

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      nb_sent_q   <= 1'b0;
      new_batch_q <= 1'b0;
    end else begin
      new_batch_q <= grant_lower;
      nb_sent_q   <= batch_done_i ? (nb_sent_q | grant_lower) : 1'b0;
    end
  end
  assign new_batch_o = new_batch_q;

  // (2) Entry into the upper half: freeze reads until it is ready. Do not stall when
  //     data is over, otherwise we would deadlock instead of reaching END_E (see
  //     misalign_q below).
  assign stall_read_o = ram_addr_i[HALF_BIT] & ~owner_q[1] & ~exh_s2;

  // End of data: only when no granted half is left to consume.
  assign data_exhausted_o = exh_s2 & ~owner_q[0];

  // Sticky diagnostics and counters.
  logic       underrun_q;  // ReckOn had to wait: the CVA6 is not keeping up
  logic       misalign_q;  // exhausted declared with unpaired halves: SW contract broken
  logic [7:0] consumed_q;  // halves consumed by ReckOn (free-running, wraps)
  logic [7:0] fill_cnt_q;  // fill toggles seen (free-running, wraps)

  logic wait_lower;
  assign wait_lower = batch_done_i & ~owner_q[0] & ~exh_s2;

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      underrun_q <= 1'b0;
      misalign_q <= 1'b0;
      consumed_q <= 8'h0;
      fill_cnt_q <= 8'h0;
    end else begin
      if (wait_lower || stall_read_o) underrun_q <= 1'b1;
      if (exh_s2 & ram_addr_i[HALF_BIT] & ~owner_q[1]) misalign_q <= 1'b1;
      if (cross_up || bdone_rise) consumed_q <= consumed_q + 8'd1;
      if (fill_pulse)             fill_cnt_q <= fill_cnt_q + 8'd1;
    end
  end

  // Status word: assembled in acc_clk, crosses once toward soc_clk.
  logic need_fill;
  assign need_fill = ~owner_q[fill_ptr_q];

  logic [31:0] status_acc;
  assign status_acc = { VERSION,                  // [31:24] sanity marker
                        fill_cnt_q,               // [23:16]
                        consumed_q,               // [15:8]
                        1'b0,                     // [7]  reserved
                        misalign_q,               // [6]
                        underrun_q,               // [5]
                        need_fill,                // [4]
                        fill_ptr_q,               // [3]  which half to fill
                        ram_addr_i[HALF_BIT],     // [2]  which half ReckOn reads
                        owner_q };                // [1:0]

  // Toggle handshake: freeze the data, then invert the toggle only on the next cycle.
  // When the soc side sees the toggle (>= 2 of its cycles later) the data has been
  // stable for at least one acc period: no bit can be captured in flight.
  logic [31:0] status_hold_q;
  logic        status_tgl_q, pending_q;

  always_ff @(posedge acc_clk_i or negedge acc_rst_ni) begin
    if (!acc_rst_ni) begin
      status_hold_q <= {VERSION, 24'h0};
      status_tgl_q  <= 1'b0;
      pending_q     <= 1'b0;
    end else if (pending_q) begin
      status_tgl_q  <= ~status_tgl_q;   // data has been frozen for one cycle already
      pending_q     <= 1'b0;
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
    fill_pulse |-> !owner_q[fill_ptr_q])
    else $error("stream_ctrl_fsm: fill_tgl on a half still owned by ReckOn");

  // new_batch_o is a one-cycle pulse.
  assert property (@(posedge acc_clk_i) disable iff (!acc_rst_ni)
    new_batch_o |=> !new_batch_o)
    else $error("stream_ctrl_fsm: new_batch_o wider than one cycle");
`endif

endmodule
