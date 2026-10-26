// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_rd -- ring reader (playback) of the NVMe-offload recorder (dp_clk)
//
// Streams the chunks that the SSDs have read into the ring (NVMe Read
// commands completed IN ORDER: chunk c is ready when c < cmp_cnt) out as a
// DATA_WIDTH-bit AXI-Stream (128, 256 or 512) into the egress FIFO
// (fdrec_egress), with TLAST on the last beat of each chunk. AXI4 INCR read
// bursts of up to 4 KB (4096 / BEAT_BYTES beats), never crossing 4 KB. A burst is only issued when the egress FIFO has room for it
// (fifo depth - level - beats already requested >= burst length), so the R
// channel is normally never stalled (rready still follows the stream ready).
//
// Ring addresses (register map 1.3, nvrec_ring_addr): as the ring writer
// (single ring at ring_base, memory 1 only, or split over both memories).
// With N_RING_PORTS = 2, a burst is requested on the port of its memory
// (arvalid[p]); the R queue remembers the port of every burst and the R
// channel takes data only from the port of the oldest outstanding burst, so
// the stream stays in ring order. A registered copy of the head burst's port
// drives the R mux.
// Per-port skid FIFOs (SKID_DEPTH beats each, N_RING_PORTS = 2 and
// SKID_DEPTH > 0): each port's R channel drains into its own FIFO whatever
// the head port is (rready = FIFO not full), and the R mux pops the head
// port's FIFO. Without them the port that is not the head is held with
// rready = 0: when the ring switches memory (every stripe, i.e. at every
// chunk boundary with chunk-sized stripes) the next port's interconnect
// buffers fill, it stops taking read requests, and its data for the next
// chunk is only fetched once the switch has happened (a gap of one read
// latency per switch). With the FIFOs the next port keeps fetching up to
// SKID_DEPTH beats ahead. The FIFO contents count as requested-not-yet-
// streamed beats (pend_r), so the egress-FIFO space reservation is unchanged.
// SKID_DEPTH = 0 keeps the direct R mux (rready of the other port = 0).
//
// rd_cnt counts chunks completely pushed into the egress FIFO: their slots are
// free again (the command builder may issue the next Read into them).
// done (level) = length_chunks chunks streamed.
// abort: no new burst; bursts already issued complete (their data is still
// streamed); done stays 0, idle reports when nothing is outstanding.

`timescale 1ns / 1ps

module nvrec_rd #(
  parameter integer DATA_WIDTH = 256,  // 128, 256 or 512
  parameter integer SLOT_W   = 12,
  parameter integer ADDR_W   = 64,
  parameter integer EGR_DEPTH = 4096,
  parameter integer EGR_CNT_W = 13,
  parameter integer N_RING_PORTS = 2,  // 1 or 2 ring AXI4 ports
  parameter integer SKID_DEPTH = 512,  // per-port R skid FIFO, beats (0 = none; 2 ports only);
                                       // >= 4096 beats in UltraRAM, else block RAM
  parameter integer RQ_DEPTH = 0       // bursts in flight (0 = 16, 32 at 512 bits); a power of 2
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               start,         // only when playing
  input  wire               cnt_clr,       // clear wait0/1 (every run start)
  input  wire               abort,
  input  wire [ADDR_W-1:0]  ring_base,
  input  wire [ADDR_W-1:0]  ring_base1,
  input  wire               split,
  input  wire               mem1,
  input  wire [4:0]         stripe_shift,
  input  wire [4:0]         chunk_shift,
  input  wire [SLOT_W:0]    num_chunks,
  input  wire [31:0]        length_chunks,
  input  wire [22:0]        last_chunk_bytes,
  input  wire [31:0]        cmp_cnt,

  // AXI4 read masters (AR/R), port p = index [p]; address and length shared
  output reg  [ADDR_W-1:0]  m_axi_araddr,
  output reg  [7:0]         m_axi_arlen,
  output wire [1:0]         m_axi_arvalid,
  input  wire [1:0]         m_axi_arready,
  input  wire [2*DATA_WIDTH-1:0] m_axi_rdata,   // {port 1, port 0}
  input  wire [3:0]         m_axi_rresp,
  input  wire [1:0]         m_axi_rlast,
  input  wire [1:0]         m_axi_rvalid,
  output wire [1:0]         m_axi_rready,

  // Stream to the egress FIFO
  output wire [DATA_WIDTH-1:0] m_axis_tdata,
  output wire               m_axis_tlast,
  output wire               m_axis_tvalid,
  input  wire               m_axis_tready,
  input  wire [EGR_CNT_W-1:0] egr_level,

  // Status
  output reg  [31:0]        rd_cnt,        // chunks streamed (slots released)
  output reg                done,
  output wire               busy,
  output reg  [63:0]        bytes,
  output reg  [31:0]        rresp_errs,
  output reg  [31:0]        wait0,         // cycles the R mux waited for port 0 data
  output reg  [31:0]        wait1          // ... port 1 (egress had room; saturating)
);

  localparam integer BEAT_BYTES = DATA_WIDTH / 8;
  localparam integer BEAT_SHIFT = (DATA_WIDTH == 512) ? 6 : (DATA_WIDTH == 256) ? 5 : 4;
  localparam integer BURST      = 4096 / BEAT_BYTES;          // beats per 4 KB
  localparam [8:0]   BURST_M1   = BURST - 1;
  // R queue: 16 bursts x 4 KB outstanding, 32 at 512 bits
  localparam integer RQ_D  = (RQ_DEPTH > 0) ? RQ_DEPTH : ((DATA_WIDTH == 512) ? 32 : 16);
  localparam integer RQ_AW = $clog2(RQ_D);

  localparam integer G_W = SLOT_W + 23;     // ring byte offset width
  localparam         TWO = (N_RING_PORTS == 2);

  generate
    if (DATA_WIDTH != 128 && DATA_WIDTH != 256 && DATA_WIDTH != 512) begin : g_bad_width
      DATA_WIDTH_must_be_128_256_or_512 u_param_error ();
    end
    if (N_RING_PORTS != 1 && N_RING_PORTS != 2) begin : g_bad_ports
      N_RING_PORTS_must_be_1_or_2 u_param_error ();
    end
  endgenerate

  reg         act;
  reg         closing;
  reg  [31:0] cidx;          // chunk being requested
  reg  [SLOT_W-1:0] slot;
  reg  [18:0] off_beats;
  reg  [G_W-1:0] chunk_g;    // ring byte offset of the chunk = slot << chunk_shift
  reg         ar_v;          // AR register valid
  reg         ar_port;       // its port
  reg  [14:0] pend_r;        // beats requested, not yet streamed into the egress FIFO

  wire [18:0] chunk_beats_full = 19'd1 << (chunk_shift - BEAT_SHIFT);

  // R queue: ends_chunk and port per burst (two arrays, both indexed alike)
  reg         rq_mem  [0:RQ_D-1];
  reg         rq_pmem [0:RQ_D-1];
  reg  [RQ_AW:0] rq_wr, rq_rd;
  wire [RQ_AW:0] rq_cnt   = rq_wr - rq_rd;
  wire        rq_full  = (rq_cnt == RQ_D);
  wire        rq_empty = (rq_cnt == {(RQ_AW+1){1'b0}});

  wire signed [19:0] space = $signed(EGR_DEPTH) - $signed({1'b0, egr_level}) - $signed({1'b0, pend_r});
  generate
    if (RQ_D < 2 || (RQ_D & (RQ_D - 1)) != 0 || RQ_D * 4096 / BEAT_BYTES > 16384) begin : g_bad_rq
      RQ_DEPTH_must_be_a_power_of_2_and_at_most_64_KB_x_BEAT_BYTES u_param_error ();
    end
  endgenerate

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

  // burst address through the 2-stage address function (valid in phase 3)
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
          // last_chunk_bytes is a whole number of LBAs (>= 512 B) = whole beats
          b_chunk_beats <= (a_last && (last_chunk_bytes != 23'd0)) ? (last_chunk_bytes >> BEAT_SHIFT) : chunk_beats_full;
          b_to4k        <= (BURST_M1 + 9'd1) - (off_beats[8:0] & BURST_M1);
          b_ready       <= a_ready;
        end
        2'd2: begin
          c_blen     <= ({10'd0, b_to4k} < (b_chunk_beats - off_beats)) ? b_to4k : (b_chunk_beats[8:0] - off_beats[8:0]);
          c_off_next <= off_beats + {10'd0, (({10'd0, b_to4k} < (b_chunk_beats - off_beats)) ? b_to4k : (b_chunk_beats[8:0] - off_beats[8:0]))};
          c_ends     <= !({10'd0, b_to4k} < (b_chunk_beats - off_beats));
          c_ok       <= b_ready;
        end
        default: ;
      endcase
    end
  end

  wire [8:0]  blen = c_blen;
  wire ar_rdy  = ar_port ? m_axi_arready[1] : m_axi_arready[0];
  wire ar_free = !ar_v || ar_rdy;
  assign m_axi_arvalid = {ar_v & ar_port, ar_v & ~ar_port};
  wire iss = (ph == 2'd3) && c_ok && act && !closing && ar_free && !rq_full && !start &&
             (space >= $signed({1'b0, c_blen}));
  wire [18:0] off_next = c_off_next;
  wire ends_chunk = c_ends;

  wire r_fire;

  always @(posedge clk) begin
    if (rst) begin
      act           <= 1'b0;
      closing       <= 1'b0;
      cidx          <= 32'd0;
      slot          <= {SLOT_W{1'b0}};
      off_beats     <= 19'd0;
      chunk_g       <= {G_W{1'b0}};
      ar_v          <= 1'b0;
      ar_port       <= 1'b0;
      m_axi_araddr  <= {ADDR_W{1'b0}};
      m_axi_arlen   <= 8'd0;
      rq_wr         <= {(RQ_AW+1){1'b0}};
    end else begin
      if (ar_v && ar_rdy)
        ar_v <= 1'b0;
      if (start) begin
        act        <= 1'b1;
        closing    <= 1'b0;
        cidx       <= 32'd0;
        slot       <= {SLOT_W{1'b0}};
        off_beats  <= 19'd0;
        chunk_g    <= {G_W{1'b0}};
      end else begin
        if (abort && act)
          closing <= 1'b1;
        if (iss) begin
          ar_v          <= 1'b1;
          ar_port       <= c_port;
          m_axi_araddr  <= c_addr;
          m_axi_arlen   <= blen[7:0] - 8'd1;
          rq_mem[rq_wr[RQ_AW-1:0]]  <= ends_chunk;
          rq_pmem[rq_wr[RQ_AW-1:0]] <= c_port;
          rq_wr <= rq_wr + 1'b1;
          if (ends_chunk) begin
            off_beats <= 19'd0;
            cidx      <= cidx + 32'd1;
            if ({1'b0, slot} == num_chunks - 1'b1) begin
              slot       <= {SLOT_W{1'b0}};
              chunk_g    <= {G_W{1'b0}};
            end else begin
              slot       <= slot + 1'b1;
              chunk_g    <= chunk_g + ({{(G_W-1){1'b0}}, 1'b1} << chunk_shift);
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
      pend_r <= 15'd0;
    else
      pend_r <= pend_r + (iss ? {6'd0, blen} : 15'd0) - (r_fire ? 15'd1 : 15'd0);
  end

  // R channel -> stream. rq_hp = port of the oldest outstanding burst (a
  // register: it selects the DATA_WIDTH-bit R mux). After this cycle's pop
  // (last beat of the head burst) the head is entry rq_rd + pop; when the
  // queue was empty, a burst pushed now becomes the head.
  wire rq_head = rq_mem[rq_rd[RQ_AW-1:0]];
  (* max_fanout = 64 *) reg rq_hp;
  wire hp = TWO ? rq_hp : 1'b0;
  wire [DATA_WIDTH-1:0] r_data;
  wire                  r_valid, r_last;
  wire [1:0]            r_resp;

  generate
    if (TWO && SKID_DEPTH > 0) begin : g_skid
      if (SKID_DEPTH < 16 || (SKID_DEPTH & (SKID_DEPTH - 1)) != 0) begin : g_bad_skid
        SKID_DEPTH_must_be_0_or_a_power_of_2_of_at_least_16 u_param_error ();
      end
      // {last, resp, data} per port, first-word-fall-through
      wire [DATA_WIDTH+2:0] s_dout [0:1];
      wire [1:0]            s_empty, s_full, s_wbusy, s_rbusy;
      wire [1:0]            s_pop = {r_valid & m_axis_tready & hp, r_valid & m_axis_tready & ~hp};
      genvar sp;
      for (sp = 0; sp < 2; sp = sp + 1) begin : g_port
        xpm_fifo_sync #(
          .FIFO_MEMORY_TYPE    ((SKID_DEPTH >= 4096) ? "ultra" : "block"),
          .FIFO_WRITE_DEPTH    (SKID_DEPTH),
          .WRITE_DATA_WIDTH    (DATA_WIDTH + 3),
          .READ_DATA_WIDTH     (DATA_WIDTH + 3),
          .READ_MODE           ("fwft"),
          .FIFO_READ_LATENCY   (0),
          .ECC_MODE            ("no_ecc"),
          .FULL_RESET_VALUE    (1),
          .USE_ADV_FEATURES    ("0000"),
          .PROG_FULL_THRESH    (10),
          .PROG_EMPTY_THRESH   (10),
          .DOUT_RESET_VALUE    ("0"),
          .WAKEUP_TIME         (0),
          .SIM_ASSERT_CHK      (0)
        ) u_skid (
          .rst           (rst),
          .wr_clk        (clk),
          .wr_en         (m_axi_rvalid[sp] && m_axi_rready[sp]),
          .din           ({m_axi_rlast[sp], m_axi_rresp[2*sp +: 2], m_axi_rdata[DATA_WIDTH*sp +: DATA_WIDTH]}),
          .full          (s_full[sp]),
          .wr_rst_busy   (s_wbusy[sp]),
          .rd_en         (s_pop[sp]),
          .dout          (s_dout[sp]),
          .empty         (s_empty[sp]),
          .rd_rst_busy   (s_rbusy[sp]),
          .sleep         (1'b0),
          .injectsbiterr (1'b0),
          .injectdbiterr (1'b0),
          .overflow      (),
          .prog_full     (),
          .wr_data_count (),
          .almost_full   (),
          .wr_ack        (),
          .underflow     (),
          .prog_empty    (),
          .rd_data_count (),
          .almost_empty  (),
          .data_valid    (),
          .sbiterr       (),
          .dbiterr       ()
        );
        assign m_axi_rready[sp] = !s_full[sp] && !s_wbusy[sp];
      end
      wire [DATA_WIDTH+2:0] h_dout = hp ? s_dout[1] : s_dout[0];
      assign r_valid = hp ? (!s_empty[1] && !s_rbusy[1]) : (!s_empty[0] && !s_rbusy[0]);
      assign r_last  = h_dout[DATA_WIDTH+2];
      assign r_resp  = h_dout[DATA_WIDTH +: 2];
      assign r_data  = h_dout[DATA_WIDTH-1:0];
    end else begin : g_direct
      assign r_data  = hp ? m_axi_rdata[DATA_WIDTH +: DATA_WIDTH] : m_axi_rdata[0 +: DATA_WIDTH];
      assign r_valid = hp ? m_axi_rvalid[1] : m_axi_rvalid[0];
      assign r_last  = hp ? m_axi_rlast[1]  : m_axi_rlast[0];
      assign r_resp  = hp ? m_axi_rresp[3:2] : m_axi_rresp[1:0];
      assign m_axi_rready = {m_axis_tready & hp, m_axis_tready & ~hp};
    end
  endgenerate

  assign m_axis_tdata  = r_data;
  assign m_axis_tvalid = r_valid;
  assign m_axis_tlast  = r_last && rq_head;
  assign r_fire        = r_valid && m_axis_tready;

  wire           r_pop    = r_fire && r_last;
  wire [RQ_AW:0] rq_rd_p1 = rq_rd + 1'b1;
  wire           hp_cur   = rq_pmem[rq_rd[RQ_AW-1:0]];
  wire           hp_nxt   = rq_pmem[rq_rd_p1[RQ_AW-1:0]];
  always @(posedge clk) begin
    if (rst || start)
      rq_hp <= 1'b0;
    else if (iss && ((r_pop ? rq_rd_p1 : rq_rd) == rq_wr))
      rq_hp <= c_port;                 // queue empty after the pop: the new burst
    else
      rq_hp <= r_pop ? hp_nxt : hp_cur;
  end

  // per-port wait counters (saturating, cleared at every run start)
  always @(posedge clk) begin
    if (rst || start || cnt_clr) begin
      wait0 <= 32'd0;
      wait1 <= 32'd0;
    end else if (!rq_empty && m_axis_tready && !r_valid) begin
      if (!hp && (wait0 != 32'hFFFF_FFFF)) wait0 <= wait0 + 32'd1;
      if ( hp && (wait1 != 32'hFFFF_FFFF)) wait1 <= wait1 + 32'd1;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      rq_rd      <= {(RQ_AW+1){1'b0}};
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
        bytes <= bytes + BEAT_BYTES;
        if (r_resp != 2'b00)
          rresp_errs <= rresp_errs + 32'd1;
        if (r_last) begin
          rq_rd <= rq_rd + 1'b1;
          if (rq_head)
            rd_cnt <= rd_cnt + 32'd1;
        end
      end
      if (act && !closing && (rd_cnt == length_chunks) && (length_chunks != 32'd0))
        done <= 1'b1;
    end
  end

  assign busy = !rq_empty || ar_v;

endmodule
