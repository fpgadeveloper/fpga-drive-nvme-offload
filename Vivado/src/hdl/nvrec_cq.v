// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_cq -- completion router of the NVMe-offload recorder (dp_clk domain)
//
// Consumes the NVMe Host Accelerator's hardware completion stream (M_AXIS:
// 128-bit CQE per beat, tuser = {credit[15:5], ssd[4:0]}, PG328 Figure 7):
//
//   * every CQE: credit return + per-SSD completed / error counters
//   * CID[15] = 1: injector CQE -> pushed into the injector CQE FIFO
//   * CID[15] = 0: builder CQE, slot = CID[SLOT_W-1:0]:
//       - slot in flight: mark it done, latency = now - submit time,
//         status != 0 -> error counters, last-error latch
//       - otherwise: "unexpected" (counted and ignored)
//   * in-order completion pointer: cmp_cnt advances over consecutive done
//     slots (one per cycle), so completions that arrive out of order are
//     released in ring order.
//
// CQE layout (NVMe): DW0 command specific, DW2 = {SQID, SQHD},
// DW3 = {status[15:1], phase, CID}; status field = tdata[127:113].
//
// Latency histogram: bin 0 < 2^10 cycles, bin i = [2^(9+i), 2^(10+i)) for
// i = 1..14, bin 15 >= 2^24 cycles.

`timescale 1ns / 1ps

module nvrec_cq #(
  parameter integer SLOT_W = 10
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               start,        // run start: clears slot table, pointer, stats
  input  wire               stats_rst,
  input  wire [SLOT_W:0]    num_chunks,

  // From the NVMe Host Accelerator M_AXIS
  input  wire [127:0]       s_axis_tdata,
  input  wire [15:0]        s_axis_tuser,
  input  wire               s_axis_tvalid,
  output wire               s_axis_tready,

  // Builder issue events (slot goes in flight, timestamp)
  input  wire               issue_we,
  input  wire [SLOT_W-1:0]  issue_slot,
  input  wire [31:0]        now,

  // Completion events to nvrec_cmd
  output reg                cq_valid,
  output reg  [4:0]         cq_ssd,
  output reg  [10:0]        cq_credit,
  output reg                cq_dec_bld,
  output reg                cq_dec_inj,

  // Injector CQE FIFO push
  output reg                inj_push,
  output reg  [127:0]       inj_cqe,
  output reg  [15:0]        inj_info,
  input  wire               inj_afull,     // at most one more entry fits

  // In-order completion
  output reg  [31:0]        cmp_cnt,

  // Statistics
  output reg  [63:0]        cmds_done,
  output reg  [31:0]        cmd_errors,
  output reg  [31:0]        unexpected,
  output reg  [31:0]        ssd_completed0,
  output reg  [31:0]        ssd_completed1,
  output reg  [31:0]        ssd_errors0,
  output reg  [31:0]        ssd_errors1,
  output reg  [31:0]        err_last_status,  // [31] valid, [20:16] ssd, [14:0] status
  output reg  [31:0]        err_last_cid,     // [31:16] sqid, [15:0] cid
  output reg                err_pulse,        // builder CQE with status != 0
  output reg                unexp_pulse,
  output reg  [31:0]        lat_min,
  output reg  [31:0]        lat_max,
  output reg  [31:0]        lat_cnt,
  output reg  [63:0]        lat_sum,
  output wire [16*32-1:0]   lat_hist
);

  localparam integer NSLOT = 1 << SLOT_W;

  // Stall the completion stream while the injector FIFO cannot take an entry
  // (one CQE may be in the pipeline already).
  assign s_axis_tready = !inj_afull;
  wire acc = s_axis_tvalid && s_axis_tready;

  // ---------------------------------------------------------------------------
  // Timestamp RAM (written at issue, read at completion)
  // ---------------------------------------------------------------------------
  (* ram_style = "block" *) reg [31:0] ts_ram [0:NSLOT-1];
  reg  [31:0] ts_rd;
  always @(posedge clk) begin
    if (issue_we)
      ts_ram[issue_slot] <= now;
  end
  always @(posedge clk) begin
    if (acc)
      ts_rd <= ts_ram[s_axis_tdata[96 +: SLOT_W]];
  end

  // ---------------------------------------------------------------------------
  // Stage 1: registered CQE
  // ---------------------------------------------------------------------------
  reg         v1;
  reg [127:0] d1;
  reg [15:0]  u1;
  reg         infl1;      // slot was in flight when the CQE arrived
  reg  [NSLOT-1:0]  infl_bits;
  always @(posedge clk) begin
    if (rst) begin
      v1 <= 1'b0;
    end else begin
      v1 <= acc;
      if (acc) begin
        d1    <= s_axis_tdata;
        u1    <= s_axis_tuser;
        infl1 <= infl_bits[s_axis_tdata[96 +: SLOT_W]];
      end
    end
  end

  wire [15:0]       cid1    = d1[111:96];
  wire [14:0]       status1 = d1[127:113];
  wire [15:0]       sqid1   = d1[95:80];
  wire              inj1    = cid1[15];
  wire [SLOT_W-1:0] slot1   = cid1[SLOT_W-1:0];
  wire              err1    = (status1 != 15'd0);
  wire [4:0]        ssd1    = u1[4:0];

  // ---------------------------------------------------------------------------
  // Slot table: in flight / done bits, in-order completion pointer
  // ---------------------------------------------------------------------------
  reg  [NSLOT-1:0]  done_bits;
  reg  [SLOT_W-1:0] cmp_slot;
  wire              bld_hit = v1 && !inj1 && infl1;
  // in-order release, 2-phase (timing): sample the done bit, then release
  reg               rel_ph, rel_bit;
  wire              rel     = rel_ph && rel_bit;

  always @(posedge clk) begin
    if (rst || start) begin
      infl_bits <= {NSLOT{1'b0}};
      done_bits <= {NSLOT{1'b0}};
      cmp_slot  <= {SLOT_W{1'b0}};
      cmp_cnt   <= 32'd0;
      rel_ph    <= 1'b0;
      rel_bit   <= 1'b0;
    end else begin
      rel_ph <= ~rel_ph;
      if (!rel_ph)
        rel_bit <= done_bits[cmp_slot];
      if (issue_we)
        infl_bits[issue_slot] <= 1'b1;
      if (bld_hit) begin
        infl_bits[slot1] <= 1'b0;
        done_bits[slot1] <= 1'b1;
      end
      if (rel) begin
        done_bits[cmp_slot] <= 1'b0;
        cmp_slot <= ({1'b0, cmp_slot} == num_chunks - 1'b1) ? {SLOT_W{1'b0}} : cmp_slot + 1'b1;
        cmp_cnt  <= cmp_cnt + 32'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Events, counters, error latch, injector push
  // ---------------------------------------------------------------------------
  reg         lv2;      // latency sample valid
  reg  [31:0] lat2;

  always @(posedge clk) begin
    if (rst) begin
      cq_valid   <= 1'b0;
      cq_dec_bld <= 1'b0;
      cq_dec_inj <= 1'b0;
      inj_push   <= 1'b0;
      err_pulse  <= 1'b0;
      unexp_pulse <= 1'b0;
      lv2        <= 1'b0;
      ssd_completed0 <= 32'd0;
      ssd_completed1 <= 32'd0;
      ssd_errors0    <= 32'd0;
      ssd_errors1    <= 32'd0;
      cmds_done   <= 64'd0;
      cmd_errors  <= 32'd0;
      unexpected  <= 32'd0;
      err_last_status <= 32'd0;
      err_last_cid    <= 32'd0;
    end else begin
      cq_valid    <= v1;
      cq_ssd      <= ssd1;
      cq_credit   <= u1[15:5];
      cq_dec_bld  <= bld_hit;
      cq_dec_inj  <= v1 && inj1;
      inj_push    <= v1 && inj1;
      inj_cqe     <= d1;
      inj_info    <= u1;
      err_pulse   <= bld_hit && err1;
      unexp_pulse <= v1 && !inj1 && !infl1;
      lv2         <= bld_hit;
      lat2        <= now - ts_rd;

      if (v1) begin
        if (ssd1[0]) ssd_completed1 <= ssd_completed1 + 32'd1;
        else         ssd_completed0 <= ssd_completed0 + 32'd1;
        if (err1) begin
          if (ssd1[0]) ssd_errors1 <= ssd_errors1 + 32'd1;
          else         ssd_errors0 <= ssd_errors0 + 32'd1;
        end
      end

      if (start || stats_rst) begin
        cmds_done       <= 64'd0;
        cmd_errors      <= 32'd0;
        unexpected      <= 32'd0;
        err_last_status <= 32'd0;
        err_last_cid    <= 32'd0;
      end else begin
        if (bld_hit)
          cmds_done <= cmds_done + 64'd1;
        if (bld_hit && err1) begin
          cmd_errors      <= cmd_errors + 32'd1;
          err_last_status <= {1'b1, 10'd0, ssd1, 1'b0, status1};
          err_last_cid    <= {sqid1, cid1};
        end
        if (v1 && !inj1 && !infl1)
          unexpected <= unexpected + 32'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Latency statistics (two more pipeline stages)
  // ---------------------------------------------------------------------------
  function [3:0] lat_bin;
    input [31:0] v;
    integer b;
    reg [5:0] msb;
    begin
      msb = 6'd0;
      for (b = 0; b < 32; b = b + 1)
        if (v[b]) msb = b[5:0];
      if (msb < 6'd10)       lat_bin = 4'd0;
      else if (msb >= 6'd24) lat_bin = 4'd15;
      else                   lat_bin = msb[3:0] - 4'd9;   // msb 10..23 -> 1..14
    end
  endfunction

  reg        lv3;
  reg [3:0]  bin3;
  reg [31:0] hist [0:15];
  integer h;

  always @(posedge clk) begin
    if (rst || start || stats_rst) begin
      lv3     <= 1'b0;
      lat_min <= 32'hFFFF_FFFF;
      lat_max <= 32'd0;
      lat_cnt <= 32'd0;
      lat_sum <= 64'd0;
      for (h = 0; h < 16; h = h + 1)
        hist[h] <= 32'd0;
    end else begin
      lv3  <= lv2;
      bin3 <= lat_bin(lat2);
      if (lv2) begin
        if (lat2 < lat_min) lat_min <= lat2;
        if (lat2 > lat_max) lat_max <= lat2;
        lat_cnt <= lat_cnt + 32'd1;
        lat_sum <= lat_sum + {32'd0, lat2};
      end
      if (lv3)
        hist[bin3] <= hist[bin3] + 32'd1;
    end
  end

  genvar g;
  generate
    for (g = 0; g < 16; g = g + 1) begin : g_hist
      assign lat_hist[g*32 +: 32] = hist[g];
    end
  endgenerate

endmodule
