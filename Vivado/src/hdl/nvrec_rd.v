// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_rd -- ring reader (playback) of the NVMe-offload recorder (dp_clk)
//
// Streams the chunks that the SSDs have read into the ring (NVMe Read
// commands completed IN ORDER: chunk c is ready when c < cmp_cnt) out as a
// 128-bit AXI-Stream into the egress FIFO (fdrec_egress), with TLAST on the
// last beat of each chunk. AXI4 INCR read bursts of up to 256 beats, never
// crossing 4 KB. A burst is only issued when the egress FIFO has room for it
// (fifo depth - level - beats already requested >= burst length), so the R
// channel is normally never stalled (rready still follows the stream ready).
//
// rd_cnt counts chunks completely pushed into the egress FIFO: their slots are
// free again (the command builder may issue the next Read into them).
// done (level) = length_chunks chunks streamed.
// abort: no new burst; bursts already issued complete (their data is still
// streamed); done stays 0, idle reports when nothing is outstanding.

`timescale 1ns / 1ps

module nvrec_rd #(
  parameter integer SLOT_W   = 10,
  parameter integer ADDR_W   = 64,
  parameter integer EGR_DEPTH = 4096,
  parameter integer EGR_CNT_W = 13
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               start,         // only when playing
  input  wire               abort,
  input  wire [ADDR_W-1:0]  ring_base,
  input  wire [4:0]         chunk_shift,
  input  wire [SLOT_W:0]    num_chunks,
  input  wire [31:0]        length_chunks,
  input  wire [22:0]        last_chunk_bytes,
  input  wire [31:0]        cmp_cnt,

  // AXI4 read master (AR/R)
  output reg  [ADDR_W-1:0]  m_axi_araddr,
  output reg  [7:0]         m_axi_arlen,
  output reg                m_axi_arvalid,
  input  wire               m_axi_arready,
  input  wire [127:0]       m_axi_rdata,
  input  wire [1:0]         m_axi_rresp,
  input  wire               m_axi_rlast,
  input  wire               m_axi_rvalid,
  output wire               m_axi_rready,

  // Stream to the egress FIFO
  output wire [127:0]       m_axis_tdata,
  output wire               m_axis_tlast,
  output wire               m_axis_tvalid,
  input  wire               m_axis_tready,
  input  wire [EGR_CNT_W-1:0] egr_level,

  // Status
  output reg  [31:0]        rd_cnt,        // chunks streamed (slots released)
  output reg                done,
  output wire               busy,
  output reg  [63:0]        bytes,
  output reg  [31:0]        rresp_errs
);

  localparam integer RQ_D = 16;

  reg         act;
  reg         closing;
  reg  [31:0] cidx;          // chunk being requested
  reg  [SLOT_W-1:0] slot;
  reg  [18:0] off_beats;
  reg  [ADDR_W-1:0] chunk_addr;
  reg  [12:0] pend_r;        // beats requested, not yet received

  wire [18:0] chunk_beats_full = 19'd1 << (chunk_shift - 5'd4);

  // R queue: ends_chunk per burst
  reg         rq_mem [0:RQ_D-1];
  reg  [4:0]  rq_wr, rq_rd;
  wire [4:0]  rq_cnt   = rq_wr - rq_rd;
  wire        rq_full  = (rq_cnt == RQ_D);
  wire        rq_empty = (rq_cnt == 5'd0);

  wire signed [19:0] space = $signed(EGR_DEPTH) - $signed({1'b0, egr_level}) - $signed({1'b0, pend_r});

  // Burst decision: 4-phase pipeline (timing); state changes only in phase 3,
  // the egress space and cmp_cnt only become more permissive meanwhile.
  reg  [1:0]  ph;
  reg         a_last, a_ready;
  reg  [18:0] b_chunk_beats;
  reg  [8:0]  b_to4k;
  reg         b_ready;
  reg  [8:0]  c_blen;
  reg         c_ok, c_ends;
  reg  [18:0] c_off_next;
  reg  [ADDR_W-1:0] c_addr;

  always @(posedge clk) begin
    if (rst || start) begin
      ph   <= 2'd0;
      c_ok <= 1'b0;
    end else begin
      ph <= ph + 2'd1;
      case (ph)
        2'd0: begin
          a_last  <= (cidx == length_chunks - 32'd1);
          a_ready <= (cidx < length_chunks) && (cidx < cmp_cnt);
        end
        2'd1: begin
          b_chunk_beats <= (a_last && (last_chunk_bytes != 23'd0)) ? last_chunk_bytes[22:4] : chunk_beats_full;
          b_to4k        <= 9'd256 - {1'b0, off_beats[7:0]};
          b_ready       <= a_ready;
        end
        2'd2: begin
          c_blen     <= ({10'd0, b_to4k} < (b_chunk_beats - off_beats)) ? b_to4k : (b_chunk_beats[8:0] - off_beats[8:0]);
          c_off_next <= off_beats + {10'd0, (({10'd0, b_to4k} < (b_chunk_beats - off_beats)) ? b_to4k : (b_chunk_beats[8:0] - off_beats[8:0]))};
          c_ends     <= !({10'd0, b_to4k} < (b_chunk_beats - off_beats));
          c_addr     <= chunk_addr + {{(ADDR_W-23){1'b0}}, off_beats, 4'd0};
          c_ok       <= b_ready;
        end
        default: ;
      endcase
    end
  end

  wire [8:0]  blen = c_blen;
  wire ar_free = !m_axi_arvalid || m_axi_arready;
  wire iss = (ph == 2'd3) && c_ok && act && !closing && ar_free && !rq_full && !start &&
             (space >= $signed({1'b0, c_blen}));
  wire [18:0] off_next = c_off_next;
  wire ends_chunk = c_ends;

  wire r_fire = m_axi_rvalid && m_axi_rready;

  always @(posedge clk) begin
    if (rst) begin
      act           <= 1'b0;
      closing       <= 1'b0;
      cidx          <= 32'd0;
      slot          <= {SLOT_W{1'b0}};
      off_beats     <= 19'd0;
      chunk_addr    <= {ADDR_W{1'b0}};
      m_axi_arvalid <= 1'b0;
      m_axi_araddr  <= {ADDR_W{1'b0}};
      m_axi_arlen   <= 8'd0;
      rq_wr         <= 5'd0;
    end else begin
      if (m_axi_arvalid && m_axi_arready)
        m_axi_arvalid <= 1'b0;
      if (start) begin
        act        <= 1'b1;
        closing    <= 1'b0;
        cidx       <= 32'd0;
        slot       <= {SLOT_W{1'b0}};
        off_beats  <= 19'd0;
        chunk_addr <= {ring_base[ADDR_W-1:12], 12'd0};
      end else begin
        if (abort && act)
          closing <= 1'b1;
        if (iss) begin
          m_axi_arvalid <= 1'b1;
          m_axi_araddr  <= c_addr;
          m_axi_arlen   <= blen[7:0] - 8'd1;
          rq_mem[rq_wr[3:0]] <= ends_chunk;
          rq_wr <= rq_wr + 5'd1;
          if (ends_chunk) begin
            off_beats <= 19'd0;
            cidx      <= cidx + 32'd1;
            if ({1'b0, slot} == num_chunks - 1'b1) begin
              slot       <= {SLOT_W{1'b0}};
              chunk_addr <= {ring_base[ADDR_W-1:12], 12'd0};
            end else begin
              slot       <= slot + 1'b1;
              chunk_addr <= chunk_addr + ({{(ADDR_W-1){1'b0}}, 1'b1} << chunk_shift);
            end
          end else begin
            off_beats <= off_next;
          end
        end
      end
    end
  end

  always @(posedge clk) begin
    if (rst || start)
      pend_r <= 13'd0;
    else
      pend_r <= pend_r + (iss ? {4'd0, blen} : 13'd0) - (r_fire ? 13'd1 : 13'd0);
  end

  // R channel -> stream
  wire rq_head = rq_mem[rq_rd[3:0]];
  assign m_axis_tdata  = m_axi_rdata;
  assign m_axis_tvalid = m_axi_rvalid;
  assign m_axis_tlast  = m_axi_rlast && rq_head;
  assign m_axi_rready  = m_axis_tready;

  always @(posedge clk) begin
    if (rst) begin
      rq_rd      <= 5'd0;
      rd_cnt     <= 32'd0;
      done       <= 1'b0;
      bytes      <= 64'd0;
      rresp_errs <= 32'd0;
    end else if (start) begin
      rd_cnt     <= 32'd0;
      done       <= 1'b0;
      bytes      <= 64'd0;
      rresp_errs <= 32'd0;
    end else begin
      if (r_fire) begin
        bytes <= bytes + 64'd16;
        if (m_axi_rresp != 2'b00)
          rresp_errs <= rresp_errs + 32'd1;
        if (m_axi_rlast) begin
          rq_rd <= rq_rd + 5'd1;
          if (rq_head)
            rd_cnt <= rd_cnt + 32'd1;
        end
      end
      if (act && !closing && (rd_cnt == length_chunks) && (length_chunks != 32'd0))
        done <= 1'b1;
    end
  end

  assign busy = !rq_empty || m_axi_arvalid;

endmodule
