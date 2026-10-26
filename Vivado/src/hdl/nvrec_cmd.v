// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_cmd -- NVMe command builder + submission arbiter (dp_clk domain)
//
// Builds one 64-byte NVMe Write (record) or Read (playback) SQE per ring chunk
// and pushes it to the NVMe Host Accelerator hardware interface (S_AXIS,
// 512-bit, one SQE per beat, tuser = {2'b0, ssd[4:0], 3'b0, sq[5:0]}, PG328
// Figure 8). SQEs from the CPU command injector (nvrec_inj) are arbitrated
// onto the same stream (round robin when both wait).
//
// Chunk c of the run (slot = c % num_chunks), array chunk A = start_chunk + c:
//   member m = A % N (N = 1 or 2), row = A / N
//   SLBA     = member_lba[m] + (row << (chunk_shift - lba_shift))
//   PRP1     = ADDR(slot << chunk_shift)
//   PRP2     = len > 2 pages : prp_base + (slot << prp_shift)
//              len = 2 pages : ADDR((slot << chunk_shift) + 4096)
//              len = 1 page  : 0
//   ADDR(g)  = ring address function (nvrec_ring_addr, register map 1.3):
//              ring_base + g (1.2), ring_base1 + g (mem1), or the split ring
//              (page 1 of a slot may be in the other memory than page 0)
//   NLB-1    = (len >> lba_shift) - 1, FUA = fua (writes only)
//   CID      = {0, slot}  (bit 15 = 0; injector CIDs have bit 15 = 1)
//
// Eligibility of chunk c:
//   record   : c < filled_cnt (the ring writer has finished the chunk)
//   playback : c < length_chunks and c - rel_cnt < num_chunks (free slot)
// and, at the arbiter, the member's SSD has credit > 0 and fewer than
// max_inflight builder commands in flight. The injector only needs credit.
//
// Credits (PG328 "credit based mechanism"): one counter per SSD for the
// hardware interface, loaded with credit_init by credit_rst, -1 per SQE
// pushed, + tuser credit (or +1 with credit_per_cqe) per CQE of that SSD. An
// SQE is never pushed without credit, so the IP never discards one.

`timescale 1ns / 1ps

module nvrec_cmd #(
  parameter integer SLOT_W = 12,
  parameter integer ADDR_W = 64,
  parameter integer N_RING_PORTS = 2
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               cnt_rst,          // clears ssd_issued*/inj_submitted (SOFT_RST)

  // Run control
  input  wire               start,
  input  wire               abort,

  // Configuration (stable during a run)
  input  wire               mode_play,
  input  wire               fua,
  input  wire               two_members,
  input  wire [3:0]         lba_shift,
  input  wire [4:0]         chunk_shift,
  input  wire [SLOT_W:0]    num_chunks,
  input  wire [ADDR_W-1:0]  ring_base,
  input  wire [ADDR_W-1:0]  ring_base1,
  input  wire               split,
  input  wire               mem1,
  input  wire [4:0]         stripe_shift,
  input  wire [ADDR_W-1:0]  prp_base,
  input  wire [4:0]         prp_shift,
  input  wire [63:0]        start_chunk,
  input  wire [31:0]        length_chunks,
  input  wire [22:0]        last_chunk_bytes,  // playback, 0 = full
  input  wire [31:0]        m0_nsid,
  input  wire [31:0]        m1_nsid,
  input  wire [4:0]         m0_ssd,
  input  wire [4:0]         m1_ssd,
  input  wire [5:0]         m0_sq,
  input  wire [5:0]         m1_sq,
  input  wire [63:0]        m0_lba,
  input  wire [63:0]        m1_lba,
  input  wire [6:0]         max_inflight0,
  input  wire [6:0]         max_inflight1,
  input  wire [10:0]        credit_init,
  input  wire [1:0]         credit_rst,       // per SSD: load credit_init, clear in-flight
  input  wire               credit_per_cqe,

  // Ring writer (record) / reader side (playback)
  input  wire [31:0]        filled_cnt,
  input  wire               final_partial,
  input  wire [22:0]        last_bytes,
  input  wire               wr_done,
  input  wire [31:0]        rel_cnt,

  // Injector
  input  wire               inj_valid,
  input  wire [511:0]       inj_sqe,
  input  wire [4:0]         inj_ssd,
  input  wire [5:0]         inj_sq,
  output wire               inj_accept,       // injector SQE taken (this cycle)

  // Completion events (from nvrec_cq)
  input  wire               cq_valid,         // any CQE
  input  wire [4:0]         cq_ssd,
  input  wire [10:0]        cq_credit,
  input  wire               cq_dec_bld,       // a builder command completed
  input  wire               cq_dec_inj,       // an injector command completed

  // To the NVMe Host Accelerator S_AXIS
  output reg  [511:0]       m_axis_tdata,
  output wire [63:0]        m_axis_tkeep,
  output reg  [15:0]        m_axis_tuser,
  output reg                m_axis_tvalid,
  input  wire               m_axis_tready,

  // Builder issue event (for the slot table / timestamps)
  output reg                bld_issue,
  output reg  [SLOT_W-1:0]  bld_slot,

  // Status
  output reg  [31:0]        issued_cnt,       // builder commands pushed
  output wire               all_issued,
  output reg  [11:0]        credits0,
  output reg  [11:0]        credits1,
  output reg  [7:0]         inflight0,        // builder + injector
  output reg  [7:0]         inflight1,
  output reg  [7:0]         inflight_hwm0,
  output reg  [7:0]         inflight_hwm1,
  input  wire               hwm_clr0,
  input  wire               hwm_clr1,
  output reg  [31:0]        ssd_issued0,      // SQEs accepted by the IP
  output reg  [31:0]        ssd_issued1,
  output reg  [31:0]        inj_submitted
);

  assign m_axis_tkeep = {64{1'b1}};

  // ---------------------------------------------------------------------------
  // Builder
  // ---------------------------------------------------------------------------
  localparam [2:0] B_IDLE = 3'd0, B_WAIT = 3'd1, B_C1 = 3'd2, B_C2 = 3'd3,
                   B_C3 = 3'd4, B_RDY = 3'd5, B_C1B = 3'd6;
  reg  [2:0]  bst;
  reg         bact;
  reg  [63:0] arr_chunk;              // A
  reg  [SLOT_W-1:0] slot;

  // stage 1
  reg         s_m;
  reg  [63:0] s_row;
  reg  [22:0] s_len;
  reg  [ADDR_W-1:0] s_slot_off;
  reg  [ADDR_W-1:0] s_prp_off;
  // stage 2
  reg  [63:0] s_lba;
  reg  [ADDR_W-1:0] s_prp_list;
  reg  [15:0] s_nlbm1;
  reg  [1:0]  s_pages;                // 1, 2, 3 (= more than 2)
  // presented SQE
  reg  [511:0] b_sqe;
  reg  [4:0]  b_ssd;
  reg  [5:0]  b_sq;

  wire [4:0]  spc_shift = chunk_shift - {1'b0, lba_shift};

  // PRP1 / 2-page PRP2 through the ring address function: s_slot_off is set
  // in B_C1, the 2-stage function result is valid in B_C3 (as s_prp1 was)
  localparam integer G_W = SLOT_W + 23;
  wire [G_W-1:0]    g_pg0 = s_slot_off[G_W-1:0];
  wire [G_W-1:0]    g_pg1 = s_slot_off[G_W-1:0] + {{(G_W-13){1'b0}}, 13'd4096};
  wire [ADDR_W-1:0] a_pg0, a_pg1;

  nvrec_ring_addr #(.N_RING_PORTS(N_RING_PORTS), .G_W(G_W), .ADDR_W(ADDR_W)) u_ra0 (
    .clk(clk), .split(split), .mem1(mem1), .stripe_shift(stripe_shift),
    .base0(ring_base), .base1(ring_base1), .g(g_pg0), .port(), .addr(a_pg0));
  nvrec_ring_addr #(.N_RING_PORTS(N_RING_PORTS), .G_W(G_W), .ADDR_W(ADDR_W)) u_ra1 (
    .clk(clk), .split(split), .mem1(mem1), .stripe_shift(stripe_shift),
    .base0(ring_base), .base1(ring_base1), .g(g_pg1), .port(), .addr(a_pg1));

  wire rec_avail  = (issued_cnt < filled_cnt);
  wire play_avail = (issued_cnt < length_chunks) &&
                    ((issued_cnt - rel_cnt) < {{(31-SLOT_W){1'b0}}, num_chunks});
  wire avail      = mode_play ? play_avail : rec_avail;

  assign all_issued = mode_play ? (issued_cnt == length_chunks)
                                : (wr_done && (issued_cnt == filled_cnt));

  wire [22:0] chunk_bytes = 23'd1 << chunk_shift;

  // arbiter grant to the builder (defined below)
  wire bld_grant;

  always @(posedge clk) begin
    if (rst) begin
      bst        <= B_IDLE;
      bact       <= 1'b0;
      arr_chunk  <= 64'd0;
      slot       <= {SLOT_W{1'b0}};
      issued_cnt <= 32'd0;
      bld_issue  <= 1'b0;
      bld_slot   <= {SLOT_W{1'b0}};
    end else begin
      bld_issue <= 1'b0;
      if (start) begin
        bact       <= 1'b1;
        bst        <= B_WAIT;
        arr_chunk  <= start_chunk;
        slot       <= {SLOT_W{1'b0}};
        issued_cnt <= 32'd0;
      end else if (abort) begin
        bact <= 1'b0;
        bst  <= B_IDLE;
      end else begin
        case (bst)
          B_WAIT: if (bact && avail) bst <= B_C1;
          B_C1: begin
            s_m   <= two_members & arr_chunk[0];
            s_row <= two_members ? {1'b0, arr_chunk[63:1]} : arr_chunk;
            if (mode_play)
              s_len <= ((issued_cnt == length_chunks - 32'd1) && (last_chunk_bytes != 23'd0))
                       ? last_chunk_bytes : chunk_bytes;
            else
              s_len <= (final_partial && (issued_cnt == filled_cnt - 32'd1))
                       ? last_bytes : chunk_bytes;
            s_slot_off <= {{(ADDR_W-SLOT_W){1'b0}}, slot} << chunk_shift;
            s_prp_off  <= {{(ADDR_W-SLOT_W){1'b0}}, slot} << prp_shift;
            bst <= B_C1B;
          end
          B_C1B: begin
            s_row <= s_row << spc_shift;      // row offset in LBAs
            bst <= B_C2;
          end
          B_C2: begin
            s_lba      <= (s_m ? m1_lba : m0_lba) + s_row;
            s_prp_list <= {prp_base[ADDR_W-1:12], 12'd0} + s_prp_off;
            s_nlbm1    <= (s_len >> lba_shift) - 23'd1;
            s_pages    <= (s_len > 23'd8192) ? 2'd3 : ((s_len > 23'd4096) ? 2'd2 : 2'd1);
            bst <= B_C3;
          end
          B_C3: begin
            // DW0: opcode, FUSE=0, PSDT=0 (PRP), CID = slot
            b_sqe[31:0]    <= {{(16-SLOT_W){1'b0}}, slot, 2'b00, 4'd0, 2'b00,
                               (mode_play ? 8'h02 : 8'h01)};
            b_sqe[63:32]   <= s_m ? m1_nsid : m0_nsid;          // DW1 NSID
            b_sqe[191:64]  <= 128'd0;                           // DW2-5
            b_sqe[255:192] <= a_pg0;                            // DW6-7 PRP1
            b_sqe[319:256] <= (s_pages == 2'd3) ? s_prp_list :
                              (s_pages == 2'd2) ? a_pg1 : 64'd0; // DW8-9
            b_sqe[383:320] <= s_lba;                            // DW10-11 SLBA
            b_sqe[415:384] <= {1'b0, (fua & ~mode_play), 14'd0, s_nlbm1}; // DW12
            b_sqe[511:416] <= 96'd0;                            // DW13-15
            b_ssd <= s_m ? m1_ssd : m0_ssd;
            b_sq  <= s_m ? m1_sq  : m0_sq;
            bst   <= B_RDY;
          end
          B_RDY: if (bld_grant) begin
            bld_issue  <= 1'b1;
            bld_slot   <= slot;
            issued_cnt <= issued_cnt + 32'd1;
            arr_chunk  <= arr_chunk + 64'd1;
            slot       <= ({1'b0, slot} == num_chunks - 1'b1) ? {SLOT_W{1'b0}} : slot + 1'b1;
            bst        <= B_WAIT;
          end
          default: ;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Credits and in-flight counters (per SSD, index = ssd[0])
  // ---------------------------------------------------------------------------
  reg  [7:0] bld_infl0, bld_infl1;   // builder commands in flight

  wire out_free = !m_axis_tvalid || m_axis_tready;
  wire b_credit = b_ssd[0] ? (credits1 != 12'd0) : (credits0 != 12'd0);
  wire b_room   = b_ssd[0] ? (bld_infl1 < {1'b0, max_inflight1})
                           : (bld_infl0 < {1'b0, max_inflight0});
  wire b_req    = (bst == B_RDY) && bact && b_credit && b_room;
  wire i_credit = inj_ssd[0] ? (credits1 != 12'd0) : (credits0 != 12'd0);
  wire i_req    = inj_valid && i_credit;

  reg  last_inj;   // round robin
  wire pick_inj = i_req && (!b_req || !last_inj);
  wire pick_bld = b_req && !pick_inj;
  assign bld_grant = out_free && pick_bld;
  wire inj_grant   = out_free && pick_inj;
  assign inj_accept = inj_grant;
  wire sel         = bld_grant || inj_grant;
  wire sel_ssd1    = bld_grant ? b_ssd[0] : inj_ssd[0];

  wire [10:0] ret = credit_per_cqe ? 11'd1 : cq_credit;

  always @(posedge clk) begin
    if (rst) begin
      m_axis_tvalid <= 1'b0;
      m_axis_tdata  <= 512'd0;
      m_axis_tuser  <= 16'd0;
      last_inj      <= 1'b0;
      credits0      <= 12'd0;
      credits1      <= 12'd0;
      inflight0     <= 8'd0;
      inflight1     <= 8'd0;
      bld_infl0     <= 8'd0;
      bld_infl1     <= 8'd0;
      inflight_hwm0 <= 8'd0;
      inflight_hwm1 <= 8'd0;
      ssd_issued0   <= 32'd0;
      ssd_issued1   <= 32'd0;
      inj_submitted <= 32'd0;
    end else begin
      if (m_axis_tvalid && m_axis_tready) begin
        m_axis_tvalid <= 1'b0;
        if (m_axis_tuser[9]) ssd_issued1 <= ssd_issued1 + 32'd1;
        else                 ssd_issued0 <= ssd_issued0 + 32'd1;
      end
      if (sel) begin
        m_axis_tvalid <= 1'b1;
        if (bld_grant) begin
          m_axis_tdata <= b_sqe;
          m_axis_tuser <= {2'b00, b_ssd, 3'b000, b_sq};
          last_inj     <= 1'b0;
        end else begin
          m_axis_tdata <= {inj_sqe[511:32], 1'b1, inj_sqe[30:0]};   // CID[15] = 1
          m_axis_tuser <= {2'b00, inj_ssd, 3'b000, inj_sq};
          last_inj     <= 1'b1;
          inj_submitted <= inj_submitted + 32'd1;
        end
      end

      // credits
      credits0 <= credit_rst[0] ? {1'b0, credit_init} :
                  credits0 - ((sel && !sel_ssd1) ? 12'd1 : 12'd0)
                           + ((cq_valid && !cq_ssd[0]) ? {1'b0, ret} : 12'd0);
      credits1 <= credit_rst[1] ? {1'b0, credit_init} :
                  credits1 - ((sel &&  sel_ssd1) ? 12'd1 : 12'd0)
                           + ((cq_valid &&  cq_ssd[0]) ? {1'b0, ret} : 12'd0);

      // in flight (total and builder); a per-SSD credit reset clears them
      inflight0 <= credit_rst[0] ? 8'd0 :
                   inflight0 + ((sel && !sel_ssd1) ? 8'd1 : 8'd0)
                             - (((cq_dec_bld || cq_dec_inj) && !cq_ssd[0] && inflight0 != 8'd0) ? 8'd1 : 8'd0);
      inflight1 <= credit_rst[1] ? 8'd0 :
                   inflight1 + ((sel &&  sel_ssd1) ? 8'd1 : 8'd0)
                             - (((cq_dec_bld || cq_dec_inj) &&  cq_ssd[0] && inflight1 != 8'd0) ? 8'd1 : 8'd0);
      bld_infl0 <= credit_rst[0] ? 8'd0 :
                   bld_infl0 + ((bld_grant && !b_ssd[0]) ? 8'd1 : 8'd0)
                             - ((cq_dec_bld && !cq_ssd[0] && bld_infl0 != 8'd0) ? 8'd1 : 8'd0);
      bld_infl1 <= credit_rst[1] ? 8'd0 :
                   bld_infl1 + ((bld_grant &&  b_ssd[0]) ? 8'd1 : 8'd0)
                             - ((cq_dec_bld &&  cq_ssd[0] && bld_infl1 != 8'd0) ? 8'd1 : 8'd0);
      if (hwm_clr0)                    inflight_hwm0 <= 8'd0;
      else if (inflight0 > inflight_hwm0) inflight_hwm0 <= inflight0;
      if (hwm_clr1)                    inflight_hwm1 <= 8'd0;
      else if (inflight1 > inflight_hwm1) inflight_hwm1 <= inflight1;
      // the issue counters clear together with nvrec_cq's completion
      // counters and the injector's completion counter (SOFT_RST), so
      // ISSUED - COMPLETED is the number of commands in flight
      if (cnt_rst) begin
        ssd_issued0   <= 32'd0;
        ssd_issued1   <= 32'd0;
        inj_submitted <= 32'd0;
      end
    end
  end

endmodule
