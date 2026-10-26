// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_wr -- ring writer of the NVMe-offload recorder (dp_clk domain)
//
// Writes the ingested stream (first-word-fall-through read port of the
// fdrec_ingest FIFO) into a ring of num_chunks chunks of 2^chunk_shift bytes,
// with AXI4 INCR write bursts of up to 4 KB (4096 / BEAT_BYTES beats: 256 x
// 128-bit, 128 x 256-bit, 64 x 512-bit), never crossing a 4 KB boundary.
// DATA_WIDTH = 128, 256 or 512 bits per beat.
//
// Ring addresses (register map 1.3, nvrec_ring_addr): ring byte g goes to
// ring_base + g (1.2), or, with N_RING_PORTS = 2, to memory 1 at ring_base1
// (mem1) or striped over both memories (split, stripes of 2^stripe_shift
// bytes >= 4 KB, so a burst never spans two memories). Port p of the AXI4
// master pair (index [p] of the valid/ready vectors) reaches memory p:
//   * AW: one address register, awvalid[p] for the burst's port.
//   * W : the data is broadcast to both ports, wvalid[p] / wready[p] of the
//     port of the head burst of the W queue (bursts are sent in issue order,
//     head-of-line as with one port).
//   * B : each port answers in its own order; per-port counters of
//     acknowledged bursts let the B queue retire bursts strictly in issue
//     order (the head burst retires once its port has an unconsumed
//     response), so filled_cnt stays in chunk order.
// N_RING_PORTS = 1 folds all of this to the 1.2 single-port writer.
//
//   * A burst is only issued when its data is already in the FIFO
//     (fifo_count - beats committed to earlier bursts >= burst length), so the
//     W channel never waits for the source.
//   * A new chunk (slot) is only opened when the ring has room:
//     opened_cnt - rel_cnt < num_chunks (rel_cnt = chunks released by the
//     completion side). Otherwise the writer waits; the ingest FIFO then fills
//     and the ingest block drops and counts beats.
//   * A chunk is "filled" when every burst of it has received its write
//     response; filled_cnt counts filled chunks (chunk c is in slot
//     c % num_chunks). The builder issues one NVMe command per filled chunk.
//   * stop: every beat that is in the FIFO when stop is seen (fifo_count snapshot)
//     is written, then the open chunk is padded with zero beats to a whole LBA
//     and closed (final chunk, final_partial / last_bytes report its size).
//   * length_chunks != 0: the writer closes after exactly that many chunks.
//   * abort: no new burst is issued; bursts already issued complete.
//   * done (level) = run finished and every write response received; it is set
//     in the cycle after the last filled_cnt update.
//
// filled_cnt, final_partial and last_bytes change in the same cycle, so a
// consumer that sees chunk c < filled_cnt also sees its correct length.

`timescale 1ns / 1ps

module nvrec_wr #(
  parameter integer DATA_WIDTH = 256,  // 128, 256 or 512
  parameter integer SLOT_W = 12,       // log2(max slots)
  parameter integer CNT_W  = 14,       // ingest FIFO count width (>= 10)
  parameter integer ADDR_W = 64,
  parameter integer N_RING_PORTS = 2   // 1 or 2 ring AXI4 ports
) (
  input  wire               clk,
  input  wire               rst,          // synchronous, active high

  // Run control (pulses) and configuration (stable during a run)
  input  wire               start,
  input  wire               cnt_clr,      // clear stall0/1 (every run start)
  input  wire               stop,
  input  wire               abort,
  input  wire [ADDR_W-1:0]  ring_base,
  input  wire [ADDR_W-1:0]  ring_base1,   // memory 1 (split / mem1)
  input  wire               split,        // ring striped over both memories
  input  wire               mem1,         // single ring in memory 1 (split = 0)
  input  wire [4:0]         stripe_shift, // 12 .. chunk_shift
  input  wire [4:0]         chunk_shift,  // log2(chunk bytes), 16..22
  input  wire [SLOT_W:0]    num_chunks,   // 1 .. 2^SLOT_W
  input  wire [3:0]         lba_shift,    // 9 or 12
  input  wire [31:0]        length_chunks,// 0 = until stop
  input  wire [31:0]        rel_cnt,      // chunks released (slot reusable)

  // Ingest FIFO read port (FWFT)
  input  wire [DATA_WIDTH-1:0] fifo_tdata,
  input  wire               fifo_tvalid,
  output wire               fifo_tready,
  input  wire [CNT_W-1:0]   fifo_count,

  // AXI4 write masters (AW/W/B), port p = index [p]; address, length, data
  // and last are shared by both ports
  output reg  [ADDR_W-1:0]  m_axi_awaddr,
  output reg  [7:0]         m_axi_awlen,
  output wire [1:0]         m_axi_awvalid,
  input  wire [1:0]         m_axi_awready,
  output wire [DATA_WIDTH-1:0] m_axi_wdata,
  output wire               m_axi_wlast,
  output wire [1:0]         m_axi_wvalid,
  input  wire [1:0]         m_axi_wready,
  input  wire [3:0]         m_axi_bresp,   // {port 1, port 0}
  input  wire [1:0]         m_axi_bvalid,
  output wire [1:0]         m_axi_bready,

  // Status
  output reg  [31:0]        opened_cnt,   // chunks opened (first burst issued)
  output reg  [31:0]        filled_cnt,   // chunks completely written
  output reg                final_partial,// last filled chunk is shorter than a chunk
  output reg  [22:0]        last_bytes,   // its length in bytes (incl. padding)
  output reg                done,
  output wire               busy,         // bursts outstanding
  output wire               accepting,    // run active and still taking new data
  output wire               ring_full,    // waiting for a free slot right now
  output reg  [63:0]        beats_out,    // data beats taken from the FIFO (since rst)
  output reg  [63:0]        run_beats,    // data beats taken in this run
  output reg  [31:0]        pad_bytes,
  output reg  [63:0]        full_cycles,  // cycles waiting for a slot with data waiting
  output reg  [31:0]        bresp_errs,
  output reg  [31:0]        stall0,       // cycles the head W beat waited on wready[0]
  output reg  [31:0]        stall1        // ... on wready[1] (saturating, cleared at start)
);

  localparam integer BEAT_BYTES = DATA_WIDTH / 8;
  localparam integer BEAT_SHIFT = (DATA_WIDTH == 512) ? 6 : (DATA_WIDTH == 256) ? 5 : 4;
  localparam integer BURST      = 4096 / BEAT_BYTES;          // beats per 4 KB
  localparam [8:0]   BURST_M1   = BURST - 1;
  localparam integer WQ_D  = 8;    // W queue (bursts issued, data not yet sent)
  // B queue (bursts issued, response pending): 16 x 4 KB = 64 KB in flight,
  // 32 at 512 bits (4 us at 16 GB/s is thin for the NoC)
  localparam integer BQ_D  = (DATA_WIDTH == 512) ? 32 : 16;
  localparam integer BQ_AW = (DATA_WIDTH == 512) ? 5 : 4;     // log2(BQ_D)

  localparam integer G_W   = SLOT_W + 23;   // ring byte offset width (4 MB chunks)
  localparam         TWO   = (N_RING_PORTS == 2);

  generate
    if (DATA_WIDTH != 128 && DATA_WIDTH != 256 && DATA_WIDTH != 512) begin : g_bad_width
      DATA_WIDTH_must_be_128_256_or_512 u_param_error ();
    end
    if (N_RING_PORTS != 1 && N_RING_PORTS != 2) begin : g_bad_ports
      N_RING_PORTS_must_be_1_or_2 u_param_error ();
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Run state
  // ---------------------------------------------------------------------------
  reg         act;         // run active (taking data)
  reg         flushing;    // stop seen: taking flush_rem more beats, then pad
  reg  [CNT_W:0] flush_rem;
  reg         closing;     // no more bursts will be issued (finish when drained)
  reg  [SLOT_W-1:0] slot;
  reg  [18:0] off_beats;   // beat offset in the open chunk (chunk <= 4 MB)
  reg  [G_W-1:0] chunk_g;  // ring byte offset of the open chunk = slot << chunk_shift
  reg         aw_v;        // AW register valid
  reg         aw_port;     // its port
  reg         close_partial; // the open (partial) chunk must be closed as final
  reg         close_req;     // 1-cycle request from the issue block
  reg  [22:0] close_bytes;
  reg  [11:0] pend_w;      // data beats committed to issued bursts, not yet sent

  wire [18:0] chunk_beats = 19'd1 << (chunk_shift - BEAT_SHIFT);
  wire [8:0]  lba_beats   = 9'd1 << (lba_shift - BEAT_SHIFT);
  wire [8:0]  to4k        = (BURST_M1 + 9'd1) - (off_beats[8:0] & BURST_M1);
  wire        at_chunk_start = (off_beats == 19'd0);
  wire        lba_aligned = ((off_beats[8:0] & (lba_beats - 9'd1)) == 9'd0);
  wire        ring_space  = ((opened_cnt - rel_cnt) < {{(31-SLOT_W){1'b0}}, num_chunks});
  wire        length_hit  = (length_chunks != 32'd0) && (opened_cnt == length_chunks);

  // beats in the FIFO that are not yet committed to a burst
  wire signed [CNT_W+1:0] avail = $signed({2'b00, fifo_count}) - $signed({{(CNT_W-10){1'b0}}, pend_w});

  // ---------------------------------------------------------------------------
  // Queues
  // ---------------------------------------------------------------------------
  // W queue entry: {port, pad, len-1}
  reg  [9:0]  wq_mem [0:WQ_D-1];
  reg  [3:0]  wq_wr, wq_rd;
  wire [3:0]  wq_cnt  = wq_wr - wq_rd;
  wire        wq_full = (wq_cnt == WQ_D);
  wire        wq_empty = (wq_cnt == 4'd0);
  // B queue entry: {port, ends_chunk (the burst completes a full chunk)}
  reg  [1:0]  bq_mem [0:BQ_D-1];
  reg  [BQ_AW:0] bq_wr, bq_rd;
  wire [BQ_AW:0] bq_cnt  = bq_wr - bq_rd;
  wire        bq_full = (bq_cnt == BQ_D);
  wire        bq_empty = (bq_cnt == {(BQ_AW+1){1'b0}});

  // ---------------------------------------------------------------------------
  // Burst decision: a 4-phase pipeline (timing). The state that a decision
  // depends on (offset, slot, flush/close flags) only changes in phase 3, so
  // the candidate computed in phases 0-2 is consistent when phase 3 issues
  // it. The inputs that change on their own (FIFO count, released slots)
  // only ever become more permissive between phase 0 and phase 3. One burst
  // per 4 cycles is far more than the W channel can drain (>= 64 beats).
  // ---------------------------------------------------------------------------
  reg  [1:0]  ph;
  // phase 0 results
  reg  [8:0]  a_to4k, a_padlen;
  reg         a_start, a_aligned, a_slot_ok;
  reg  signed [CNT_W+1:0] a_avail;
  // phase 1 results
  reg         c_iss, c_pad;
  reg  [8:0]  c_len;
  // phase 2 results
  reg  [18:0] c_off_next;
  reg         c_ends;

  // burst address: ring byte offset of the next burst (from the state, which
  // only changes in phase 3) through the 2-stage address function -> valid
  // in phase 3
  reg  [G_W-1:0]    g_next;
  wire              c_port_ra;
  wire [ADDR_W-1:0] c_addr;
  always @(posedge clk)
    g_next <= chunk_g | ({{(G_W-19){1'b0}}, off_beats} << BEAT_SHIFT);

  nvrec_ring_addr #(.N_RING_PORTS(N_RING_PORTS), .G_W(G_W), .ADDR_W(ADDR_W)) u_ra (
    .clk          (clk),
    .split        (split),
    .mem1         (mem1),
    .stripe_shift (stripe_shift),
    .base0        (ring_base),
    .base1        (ring_base1),
    .g            (g_next),
    .port         (c_port_ra),
    .addr         (c_addr)
  );
  wire c_port = TWO ? c_port_ra : 1'b0;

  wire aw_rdy  = aw_port ? m_axi_awready[1] : m_axi_awready[0];
  wire aw_free = !aw_v || aw_rdy;
  assign m_axi_awvalid = {aw_v & aw_port, aw_v & ~aw_port};
  wire can_iss = act && !closing && aw_free && !wq_full && !bq_full;
  wire iss     = (ph == 2'd3) && c_iss && can_iss && !start;
  wire iss_pad = c_pad;
  wire [8:0] iss_len = c_len;
  wire need_slot = at_chunk_start;
  reg  stop_pend, abort_pend;

  always @(posedge clk) begin
    if (rst || start) begin
      ph    <= 2'd0;
      c_iss <= 1'b0;
    end else begin
      ph <= ph + 2'd1;
      case (ph)
        2'd0: begin
          a_to4k    <= to4k;
          a_padlen  <= lba_beats - (off_beats[8:0] & (lba_beats - 9'd1));
          a_start   <= at_chunk_start;
          a_aligned <= lba_aligned;
          a_slot_ok <= !at_chunk_start || (ring_space && !length_hit);
          a_avail   <= avail;
        end
        2'd1: begin
          c_iss <= 1'b0;
          c_pad <= 1'b0;
          c_len <= a_to4k;
          if (act && !closing) begin
            if (!flushing) begin
              if (a_slot_ok && (a_avail >= $signed({{(CNT_W-8){1'b0}}, a_to4k})))
                c_iss <= 1'b1;
            end else if (flush_rem != 0) begin
              if (a_slot_ok) begin
                c_iss <= 1'b1;
                c_len <= ({{(CNT_W-8){1'b0}}, a_to4k} < flush_rem) ? a_to4k : flush_rem[8:0];
              end
            end else if (!a_start && !a_aligned) begin
              // pad the open chunk to the next LBA boundary (never crosses 4 KB)
              c_iss <= 1'b1;
              c_pad <= 1'b1;
              c_len <= a_padlen;
            end
          end
        end
        2'd2: begin
          c_off_next <= off_beats + {10'd0, c_len};
          c_ends     <= ((off_beats + {10'd0, c_len}) == chunk_beats);
        end
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Issue side (state changes only in phase 3)
  // ---------------------------------------------------------------------------
  wire w_fire_data;    // data beat sent (from the FIFO)
  wire ph3 = (ph == 2'd3);

  always @(posedge clk) begin
    if (rst) begin
      aw_v          <= 1'b0;
      aw_port       <= 1'b0;
      m_axi_awaddr  <= {ADDR_W{1'b0}};
      m_axi_awlen   <= 8'd0;
      act           <= 1'b0;
      flushing      <= 1'b0;
      flush_rem     <= {(CNT_W+1){1'b0}};
      closing       <= 1'b0;
      slot          <= {SLOT_W{1'b0}};
      off_beats     <= 19'd0;
      chunk_g       <= {G_W{1'b0}};
      opened_cnt    <= 32'd0;
      pad_bytes     <= 32'd0;
      full_cycles   <= 64'd0;
      close_bytes   <= 23'd0;
      close_req     <= 1'b0;
      stop_pend     <= 1'b0;
      abort_pend    <= 1'b0;
      wq_wr         <= 4'd0;
      bq_wr         <= {(BQ_AW+1){1'b0}};
    end else begin
      if (aw_v && aw_rdy)
        aw_v <= 1'b0;
      close_req <= 1'b0;

      if (start) begin
        act        <= 1'b1;
        flushing   <= 1'b0;
        flush_rem  <= {(CNT_W+1){1'b0}};
        closing    <= 1'b0;
        stop_pend  <= 1'b0;
        abort_pend <= 1'b0;
        slot       <= {SLOT_W{1'b0}};
        off_beats  <= 19'd0;
        chunk_g    <= {G_W{1'b0}};
        opened_cnt <= 32'd0;
        pad_bytes  <= 32'd0;
        full_cycles <= 64'd0;
      end else begin
        if (abort && act) abort_pend <= 1'b1;
        if (stop && act)  stop_pend  <= 1'b1;

        if (act && !closing && need_slot && !ring_space && !flushing &&
            (avail >= BURST))
          full_cycles <= full_cycles + 64'd1;

        if (ph3) begin
          if (abort_pend) begin
            closing    <= 1'b1;
            abort_pend <= 1'b0;
          end
          if (stop_pend) begin
            stop_pend <= 1'b0;
            if (!flushing && !closing) begin
              // everything in the FIFO now that is not committed to a burst
              // (including the burst issued in this very cycle)
              flushing  <= 1'b1;
              flush_rem <= ((avail - ((iss && !iss_pad) ? $signed({{(CNT_W-8){1'b0}}, iss_len}) : 0)) > 0)
                           ? (avail[CNT_W:0] - ((iss && !iss_pad) ? {{(CNT_W-8){1'b0}}, iss_len} : {(CNT_W+1){1'b0}}))
                           : {(CNT_W+1){1'b0}};
            end
          end
          // after stop: nothing left to take and the open chunk is LBA
          // aligned: close the run; a non-empty open chunk becomes the final
          // (partial) one
          if (act && flushing && !closing && !abort_pend && (flush_rem == 0) &&
              (at_chunk_start || lba_aligned) && !iss && aw_free) begin
            closing <= 1'b1;
            if (!at_chunk_start) begin
              close_req   <= 1'b1;
              close_bytes <= off_beats << BEAT_SHIFT;
            end
          end
          // length reached at a chunk boundary
          if (act && !closing && at_chunk_start && length_hit && !iss)
            closing <= 1'b1;
        end

        if (iss) begin
          aw_v          <= 1'b1;
          aw_port       <= c_port;
          m_axi_awaddr  <= c_addr;
          m_axi_awlen   <= iss_len[7:0] - 8'd1;
          wq_mem[wq_wr[2:0]] <= {c_port, iss_pad, iss_len[7:0] - 8'd1};
          wq_wr <= wq_wr + 4'd1;
          bq_mem[bq_wr[BQ_AW-1:0]] <= {c_port, c_ends};
          bq_wr <= bq_wr + 1'b1;
          if (at_chunk_start)
            opened_cnt <= opened_cnt + 32'd1;
          if (flushing && !iss_pad)
            flush_rem <= flush_rem - {{(CNT_W-8){1'b0}}, iss_len};
          if (iss_pad)
            pad_bytes <= pad_bytes + ({23'd0, iss_len} << BEAT_SHIFT);
          if (c_ends) begin
            off_beats <= 19'd0;
            if ({1'b0, slot} == num_chunks - 1'b1) begin
              slot       <= {SLOT_W{1'b0}};
              chunk_g    <= {G_W{1'b0}};
            end else begin
              slot       <= slot + 1'b1;
              chunk_g    <= chunk_g + ({{(G_W-1){1'b0}}, 1'b1} << chunk_shift);
            end
          end else begin
            off_beats <= c_off_next;
          end
        end
      end
    end
  end

  // committed-but-unsent data beats
  always @(posedge clk) begin
    if (rst || start)
      pend_w <= 12'd0;
    else
      pend_w <= pend_w + ((iss && !iss_pad) ? {3'd0, iss_len} : 12'd0)
                       - (w_fire_data ? 12'd1 : 12'd0);
  end

  // ---------------------------------------------------------------------------
  // W channel
  // ---------------------------------------------------------------------------
  reg  [7:0] wbeat;
  wire [9:0] wq_head = wq_mem[wq_rd[2:0]];
  wire       w_port  = TWO ? wq_head[9] : 1'b0;
  wire       w_pad   = wq_head[8];
  wire [7:0] w_lenm1 = wq_head[7:0];

  wire   w_valid      = !wq_empty && (w_pad || fifo_tvalid);
  wire   w_ready      = w_port ? m_axi_wready[1] : m_axi_wready[0];
  assign m_axi_wvalid = {w_valid & w_port, w_valid & ~w_port};
  assign m_axi_wdata  = w_pad ? {DATA_WIDTH{1'b0}} : fifo_tdata;
  assign m_axi_wlast  = (wbeat == w_lenm1);
  assign fifo_tready  = !wq_empty && !w_pad && w_ready;
  wire   w_fire       = w_valid && w_ready;
  assign w_fire_data  = w_fire && !w_pad;

  // per-port W stall counters (saturating, cleared at every run start)
  always @(posedge clk) begin
    if (rst || start || cnt_clr) begin
      stall0 <= 32'd0;
      stall1 <= 32'd0;
    end else if (w_valid && !w_ready) begin
      if (!w_port && (stall0 != 32'hFFFF_FFFF)) stall0 <= stall0 + 32'd1;
      if ( w_port && (stall1 != 32'hFFFF_FFFF)) stall1 <= stall1 + 32'd1;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      wbeat     <= 8'd0;
      wq_rd     <= 4'd0;
      beats_out <= 64'd0;
      run_beats <= 64'd0;
    end else begin
      if (w_fire_data)
        beats_out <= beats_out + 64'd1;
      if (start)
        run_beats <= 64'd0;
      else if (w_fire_data)
        run_beats <= run_beats + 64'd1;
      if (w_fire) begin
        if (m_axi_wlast) begin
          wbeat <= 8'd0;
          wq_rd <= wq_rd + 4'd1;
        end else begin
          wbeat <= wbeat + 8'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // B channel: chunk completion
  // ---------------------------------------------------------------------------
  // Each port answers its bursts in its own issue order. ack0/ack1 count the
  // responses of a port that have not been retired yet; the head of the
  // (global, issue-ordered) B queue is the oldest unretired burst of its port,
  // so it is acknowledged when its port has an unconsumed response (or one
  // arrives now). One burst retires per cycle. With one port this is the 1.2
  // in-order B queue (the response retires the head in the same cycle).
  assign m_axi_bready = 2'b11;
  wire [1:0] bq_ent  = bq_mem[bq_rd[BQ_AW-1:0]];
  wire       bq_head = bq_ent[0];
  wire       bq_port = TWO ? bq_ent[1] : 1'b0;
  reg  [BQ_AW:0] ack0, ack1;
  wire       b_v0    = m_axi_bvalid[0];
  wire       b_v1    = TWO ? m_axi_bvalid[1] : 1'b0;
  wire       retire  = !bq_empty && (bq_port ? ((ack1 != 0) || b_v1) : ((ack0 != 0) || b_v0));
  wire       b_err0  = b_v0 && (m_axi_bresp[1:0] != 2'b00);
  wire       b_err1  = b_v1 && (m_axi_bresp[3:2] != 2'b00);

  always @(posedge clk) begin
    if (rst) begin
      ack0 <= {(BQ_AW+1){1'b0}};
      ack1 <= {(BQ_AW+1){1'b0}};
    end else begin
      ack0 <= ack0 + (b_v0 ? 1'b1 : 1'b0) - ((retire && !bq_port) ? 1'b1 : 1'b0);
      ack1 <= ack1 + (b_v1 ? 1'b1 : 1'b0) - ((retire &&  bq_port) ? 1'b1 : 1'b0);
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      bq_rd         <= {(BQ_AW+1){1'b0}};
      filled_cnt    <= 32'd0;
      final_partial <= 1'b0;
      last_bytes    <= 23'd0;
      done          <= 1'b0;
      bresp_errs    <= 32'd0;
      close_partial <= 1'b0;
    end else if (start) begin
      filled_cnt    <= 32'd0;
      final_partial <= 1'b0;
      last_bytes    <= 23'd0;
      done          <= 1'b0;
      bresp_errs    <= 32'd0;
      close_partial <= 1'b0;
    end else begin
      if (close_req)
        close_partial <= 1'b1;
      if (b_err0 || b_err1)
        bresp_errs <= bresp_errs + ((b_err0 && b_err1) ? 32'd2 : 32'd1);
      if (retire) begin
        bq_rd <= bq_rd + 1'b1;
        if (bq_head)
          filled_cnt <= filled_cnt + 32'd1;
      end else if (close_partial && bq_empty && !aw_v && wq_empty) begin
        // every burst of the partial chunk has been acknowledged
        filled_cnt    <= filled_cnt + 32'd1;
        final_partial <= 1'b1;
        last_bytes    <= close_bytes;
        close_partial <= 1'b0;
      end
      // the stop-path close request is raised by the issue block (one cycle
      // after 'closing'), so 'done' also waits for close_partial to clear
      if (act && closing && !aw_v && wq_empty && bq_empty &&
          !close_partial && !close_req)
        done <= 1'b1;
    end
  end

  assign busy      = !bq_empty || aw_v;
  assign accepting = act && !closing && !flushing;
  assign ring_full = act && !closing && need_slot && !ring_space && !flushing;

endmodule
