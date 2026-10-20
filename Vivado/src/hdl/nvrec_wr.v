// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_wr -- ring writer of the NVMe-offload recorder (dp_clk domain)
//
// Writes the ingested stream (first-word-fall-through read port of the
// fdrec_ingest FIFO) into a ring of num_chunks chunks of 2^chunk_shift bytes at
// ring_base in memory, with AXI4 INCR write bursts of up to 256 x 128-bit beats
// (4 KB, never crossing a 4 KB boundary).
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
  parameter integer SLOT_W = 10,       // log2(max slots)
  parameter integer CNT_W  = 13,       // ingest FIFO count width
  parameter integer ADDR_W = 64
) (
  input  wire               clk,
  input  wire               rst,          // synchronous, active high

  // Run control (pulses) and configuration (stable during a run)
  input  wire               start,
  input  wire               stop,
  input  wire               abort,
  input  wire [ADDR_W-1:0]  ring_base,
  input  wire [4:0]         chunk_shift,  // log2(chunk bytes), 16..22
  input  wire [SLOT_W:0]    num_chunks,   // 1 .. 2^SLOT_W
  input  wire [3:0]         lba_shift,    // 9 or 12
  input  wire [31:0]        length_chunks,// 0 = until stop
  input  wire [31:0]        rel_cnt,      // chunks released (slot reusable)

  // Ingest FIFO read port (FWFT)
  input  wire [127:0]       fifo_tdata,
  input  wire               fifo_tvalid,
  output wire               fifo_tready,
  input  wire [CNT_W-1:0]   fifo_count,

  // AXI4 write master (AW/W/B)
  output reg  [ADDR_W-1:0]  m_axi_awaddr,
  output reg  [7:0]         m_axi_awlen,
  output reg                m_axi_awvalid,
  input  wire               m_axi_awready,
  output wire [127:0]       m_axi_wdata,
  output wire               m_axi_wlast,
  output wire               m_axi_wvalid,
  input  wire               m_axi_wready,
  input  wire [1:0]         m_axi_bresp,
  input  wire               m_axi_bvalid,
  output wire               m_axi_bready,

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
  output reg  [31:0]        bresp_errs
);

  localparam integer WQ_D = 8;    // W queue (bursts issued, data not yet sent)
  localparam integer BQ_D = 16;   // B queue (bursts issued, response pending)

  // ---------------------------------------------------------------------------
  // Run state
  // ---------------------------------------------------------------------------
  reg         act;         // run active (taking data)
  reg         flushing;    // stop seen: taking flush_rem more beats, then pad
  reg  [CNT_W:0] flush_rem;
  reg         closing;     // no more bursts will be issued (finish when drained)
  reg  [SLOT_W-1:0] slot;
  reg  [18:0] off_beats;   // beat offset in the open chunk (chunk <= 4 MB)
  reg  [ADDR_W-1:0] chunk_addr;
  reg         close_partial; // the open (partial) chunk must be closed as final
  reg         close_req;     // 1-cycle request from the issue block
  reg  [22:0] close_bytes;
  reg  [11:0] pend_w;      // data beats committed to issued bursts, not yet sent

  wire [18:0] chunk_beats = 19'd1 << (chunk_shift - 5'd4);
  wire [8:0]  lba_beats   = 9'd1 << (lba_shift - 4'd4);
  wire [8:0]  to4k        = 9'd256 - {1'b0, off_beats[7:0]};
  wire        at_chunk_start = (off_beats == 19'd0);
  wire        lba_aligned = ((off_beats[8:0] & (lba_beats - 9'd1)) == 9'd0);
  wire        ring_space  = ((opened_cnt - rel_cnt) < {{(31-SLOT_W){1'b0}}, num_chunks});
  wire        length_hit  = (length_chunks != 32'd0) && (opened_cnt == length_chunks);

  // beats in the FIFO that are not yet committed to a burst
  wire signed [CNT_W+1:0] avail = $signed({2'b00, fifo_count}) - $signed({{(CNT_W-10){1'b0}}, pend_w});

  // ---------------------------------------------------------------------------
  // Queues
  // ---------------------------------------------------------------------------
  // W queue entry: {pad, len-1}
  reg  [8:0]  wq_mem [0:WQ_D-1];
  reg  [3:0]  wq_wr, wq_rd;
  wire [3:0]  wq_cnt  = wq_wr - wq_rd;
  wire        wq_full = (wq_cnt == WQ_D);
  wire        wq_empty = (wq_cnt == 4'd0);
  // B queue entry: ends_chunk (the burst completes a full chunk)
  reg         bq_mem [0:BQ_D-1];
  reg  [4:0]  bq_wr, bq_rd;
  wire [4:0]  bq_cnt  = bq_wr - bq_rd;
  wire        bq_full = (bq_cnt == BQ_D);
  wire        bq_empty = (bq_cnt == 5'd0);

  // ---------------------------------------------------------------------------
  // Burst decision: a 4-phase pipeline (timing). The state that a decision
  // depends on (offset, slot, flush/close flags) only changes in phase 3, so
  // the candidate computed in phases 0-2 is consistent when phase 3 issues
  // it. The inputs that change on their own (FIFO count, released slots)
  // only ever become more permissive between phase 0 and phase 3. One burst
  // per 4 cycles is far more than the W channel can drain (256 beats).
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
  reg  [ADDR_W-1:0] c_addr;

  wire aw_free = !m_axi_awvalid || m_axi_awready;
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
          c_addr     <= chunk_addr + {{(ADDR_W-23){1'b0}}, off_beats, 4'd0};
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
      m_axi_awvalid <= 1'b0;
      m_axi_awaddr  <= {ADDR_W{1'b0}};
      m_axi_awlen   <= 8'd0;
      act           <= 1'b0;
      flushing      <= 1'b0;
      flush_rem     <= {(CNT_W+1){1'b0}};
      closing       <= 1'b0;
      slot          <= {SLOT_W{1'b0}};
      off_beats     <= 19'd0;
      chunk_addr    <= {ADDR_W{1'b0}};
      opened_cnt    <= 32'd0;
      pad_bytes     <= 32'd0;
      full_cycles   <= 64'd0;
      close_bytes   <= 23'd0;
      close_req     <= 1'b0;
      stop_pend     <= 1'b0;
      abort_pend    <= 1'b0;
      wq_wr         <= 4'd0;
      bq_wr         <= 5'd0;
    end else begin
      if (m_axi_awvalid && m_axi_awready)
        m_axi_awvalid <= 1'b0;
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
        chunk_addr <= {ring_base[ADDR_W-1:12], 12'd0};
        opened_cnt <= 32'd0;
        pad_bytes  <= 32'd0;
        full_cycles <= 64'd0;
      end else begin
        if (abort && act) abort_pend <= 1'b1;
        if (stop && act)  stop_pend  <= 1'b1;

        if (act && !closing && need_slot && !ring_space && !flushing &&
            (avail >= 256))
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
              close_bytes <= {off_beats, 4'd0};
            end
          end
          // length reached at a chunk boundary
          if (act && !closing && at_chunk_start && length_hit && !iss)
            closing <= 1'b1;
        end

        if (iss) begin
          m_axi_awvalid <= 1'b1;
          m_axi_awaddr  <= c_addr;
          m_axi_awlen   <= iss_len[7:0] - 8'd1;
          wq_mem[wq_wr[2:0]] <= {iss_pad, iss_len[7:0] - 8'd1};
          wq_wr <= wq_wr + 4'd1;
          bq_mem[bq_wr[3:0]] <= c_ends;
          bq_wr <= bq_wr + 5'd1;
          if (at_chunk_start)
            opened_cnt <= opened_cnt + 32'd1;
          if (flushing && !iss_pad)
            flush_rem <= flush_rem - {{(CNT_W-8){1'b0}}, iss_len};
          if (iss_pad)
            pad_bytes <= pad_bytes + {19'd0, iss_len, 4'd0};
          if (c_ends) begin
            off_beats <= 19'd0;
            if ({1'b0, slot} == num_chunks - 1'b1) begin
              slot       <= {SLOT_W{1'b0}};
              chunk_addr <= {ring_base[ADDR_W-1:12], 12'd0};
            end else begin
              slot       <= slot + 1'b1;
              chunk_addr <= chunk_addr + ({{(ADDR_W-1){1'b0}}, 1'b1} << chunk_shift);
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
  wire [8:0] wq_head = wq_mem[wq_rd[2:0]];
  wire       w_pad   = wq_head[8];
  wire [7:0] w_lenm1 = wq_head[7:0];

  assign m_axi_wvalid = !wq_empty && (w_pad || fifo_tvalid);
  assign m_axi_wdata  = w_pad ? 128'd0 : fifo_tdata;
  assign m_axi_wlast  = (wbeat == w_lenm1);
  assign fifo_tready  = !wq_empty && !w_pad && m_axi_wready;
  wire   w_fire       = m_axi_wvalid && m_axi_wready;
  assign w_fire_data  = w_fire && !w_pad;

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
  assign m_axi_bready = 1'b1;
  wire bq_head = bq_mem[bq_rd[3:0]];

  always @(posedge clk) begin
    if (rst) begin
      bq_rd         <= 5'd0;
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
      if (m_axi_bvalid && !bq_empty) begin
        bq_rd <= bq_rd + 5'd1;
        if (m_axi_bresp != 2'b00)
          bresp_errs <= bresp_errs + 32'd1;
        if (bq_head)
          filled_cnt <= filled_cnt + 32'd1;
      end else if (close_partial && bq_empty && !m_axi_awvalid && wq_empty) begin
        // every burst of the partial chunk has been acknowledged
        filled_cnt    <= filled_cnt + 32'd1;
        final_partial <= 1'b1;
        last_bytes    <= close_bytes;
        close_partial <= 1'b0;
      end
      // the stop-path close request is raised by the issue block (one cycle
      // after 'closing'), so 'done' also waits for close_partial to clear
      if (act && closing && !m_axi_awvalid && wq_empty && bq_empty &&
          !close_partial && !close_req)
        done <= 1'b1;
    end
  end

  assign busy      = !bq_empty || m_axi_awvalid;
  assign accepting = act && !closing && !flushing;
  assign ring_full = act && !closing && need_slot && !ring_space && !flushing;

endmodule
