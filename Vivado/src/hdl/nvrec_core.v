// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_core -- FPGA Drive NVMe-offload recorder core (block-design module
// reference)
//
// Record path (no CPU in the data path):
//   s_axis (src_clk) -> fdrec_ingest (async FIFO, drop + count)
//     -> nvrec_wr (ring writer, AXI4 write bursts into the ring in PS DDR)
//     -> nvrec_cmd (one NVMe Write SQE per filled chunk, to the AMD NVMe Host
//        Accelerator hardware interface, m_axis_sqe)
//     <- nvrec_cq (CQEs from the Host Accelerator, s_axis_cqe: slot release
//        in ring order, statistics, latency)
// Playback path:
//   nvrec_cmd (NVMe Read SQEs into free slots) -> nvrec_cq (in-order
//   completion) -> nvrec_rd (ring reader, AXI4 read bursts) -> fdrec_egress
//   (async FIFO, lossless) -> m_axis_snk (src_clk) -> user data sink
// CPU command injector (nvrec_inj): software SQEs onto the same HW SQ.
// Doorbell monitor (nvrec_dbmon): s_axi_db -> m_axi_db pass-through of the
//   Host Accelerator's M_AXI_SSD with a log of the last doorbell writes.
//
// One AXI4-Lite register block (s_axi, dp_clk), map in include/nvrec_regs.h.
// Offsets 0x000-0x0BF are the fdrec (fpga-drive-recorder) TPG / ingest /
// checker / egress registers with the same semantics; the clock-domain
// crossings for the TPG and checker controls/counters are the ones of
// fdrec_core (XPM CDC macros only, no XDC needed).
//
// The test pattern generator (fdrec_tpg) and the checker (fdrec_check) live
// OUTSIDE this module (user_data_source / user_data_sink hierarchies).

`timescale 1ns / 1ps

module nvrec_core #(
  parameter integer SRC_CLK_HZ     = 200000000,
  parameter integer DP_CLK_HZ      = 250000000,
  parameter integer FIFO_DEPTH     = 4096,
  parameter integer EGR_FIFO_DEPTH = 4096,
  parameter integer SLOT_W         = 10
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 src_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis_snk, ASSOCIATED_RESET src_resetn" *)
  input  wire          src_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 src_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire          src_resetn,

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dp_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axi:m_axis_sqe:s_axis_cqe:s_axi_db:m_axi_db, ASSOCIATED_RESET dp_resetn" *)
  input  wire          dp_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dp_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire          dp_resetn,

  // Data source stream (src_clk); tready is always 1
  input  wire [127:0]  s_axis_tdata,
  input  wire          s_axis_tvalid,
  output wire          s_axis_tready,

  // Playback stream to the data sink (src_clk)
  output wire [127:0]  m_axis_snk_tdata,
  output wire          m_axis_snk_tlast,
  output wire          m_axis_snk_tvalid,
  input  wire          m_axis_snk_tready,

  // AXI4-Lite register interface (dp_clk)
  input  wire [11:0]   s_axi_awaddr,
  input  wire [2:0]    s_axi_awprot,
  input  wire          s_axi_awvalid,
  output wire          s_axi_awready,
  input  wire [31:0]   s_axi_wdata,
  input  wire [3:0]    s_axi_wstrb,
  input  wire          s_axi_wvalid,
  output wire          s_axi_wready,
  output wire [1:0]    s_axi_bresp,
  output wire          s_axi_bvalid,
  input  wire          s_axi_bready,
  input  wire [11:0]   s_axi_araddr,
  input  wire [2:0]    s_axi_arprot,
  input  wire          s_axi_arvalid,
  output wire          s_axi_arready,
  output wire [31:0]   s_axi_rdata,
  output wire [1:0]    s_axi_rresp,
  output wire          s_axi_rvalid,
  input  wire          s_axi_rready,

  // AXI4 master to PS DDR (ring writer AW/W/B, ring reader AR/R)
  output wire [63:0]   m_axi_awaddr,
  output wire [7:0]    m_axi_awlen,
  output wire [2:0]    m_axi_awsize,
  output wire [1:0]    m_axi_awburst,
  output wire [3:0]    m_axi_awcache,
  output wire [2:0]    m_axi_awprot,
  output wire          m_axi_awvalid,
  input  wire          m_axi_awready,
  output wire [127:0]  m_axi_wdata,
  output wire [15:0]   m_axi_wstrb,
  output wire          m_axi_wlast,
  output wire          m_axi_wvalid,
  input  wire          m_axi_wready,
  input  wire [1:0]    m_axi_bresp,
  input  wire          m_axi_bvalid,
  output wire          m_axi_bready,
  output wire [63:0]   m_axi_araddr,
  output wire [7:0]    m_axi_arlen,
  output wire [2:0]    m_axi_arsize,
  output wire [1:0]    m_axi_arburst,
  output wire [3:0]    m_axi_arcache,
  output wire [2:0]    m_axi_arprot,
  output wire          m_axi_arvalid,
  input  wire          m_axi_arready,
  input  wire [127:0]  m_axi_rdata,
  input  wire [1:0]    m_axi_rresp,
  input  wire          m_axi_rlast,
  input  wire          m_axi_rvalid,
  output wire          m_axi_rready,

  // SQEs to the NVMe Host Accelerator S_AXIS
  output wire [511:0]  m_axis_sqe_tdata,
  output wire [63:0]   m_axis_sqe_tkeep,
  output wire [15:0]   m_axis_sqe_tuser,
  output wire          m_axis_sqe_tvalid,
  input  wire          m_axis_sqe_tready,

  // CQEs from the NVMe Host Accelerator M_AXIS
  input  wire [127:0]  s_axis_cqe_tdata,
  input  wire [15:0]   s_axis_cqe_tkeep,
  input  wire [15:0]   s_axis_cqe_tuser,
  input  wire          s_axis_cqe_tvalid,
  output wire          s_axis_cqe_tready,

  // Doorbell monitor pass-through: from the Host Accelerator M_AXI_SSD ...
  input  wire [0:0]    s_axi_db_awid,
  input  wire [31:0]   s_axi_db_awaddr,
  input  wire [7:0]    s_axi_db_awlen,
  input  wire [2:0]    s_axi_db_awsize,
  input  wire [1:0]    s_axi_db_awburst,
  input  wire [0:0]    s_axi_db_awlock,
  input  wire [3:0]    s_axi_db_awcache,
  input  wire [2:0]    s_axi_db_awprot,
  input  wire          s_axi_db_awvalid,
  output wire          s_axi_db_awready,
  input  wire [31:0]   s_axi_db_wdata,
  input  wire [3:0]    s_axi_db_wstrb,
  input  wire          s_axi_db_wlast,
  input  wire          s_axi_db_wvalid,
  output wire          s_axi_db_wready,
  output wire [0:0]    s_axi_db_bid,
  output wire [1:0]    s_axi_db_bresp,
  output wire          s_axi_db_bvalid,
  input  wire          s_axi_db_bready,
  input  wire [0:0]    s_axi_db_arid,
  input  wire [31:0]   s_axi_db_araddr,
  input  wire [7:0]    s_axi_db_arlen,
  input  wire [2:0]    s_axi_db_arsize,
  input  wire [1:0]    s_axi_db_arburst,
  input  wire [0:0]    s_axi_db_arlock,
  input  wire [3:0]    s_axi_db_arcache,
  input  wire [2:0]    s_axi_db_arprot,
  input  wire          s_axi_db_arvalid,
  output wire          s_axi_db_arready,
  output wire [0:0]    s_axi_db_rid,
  output wire [31:0]   s_axi_db_rdata,
  output wire [1:0]    s_axi_db_rresp,
  output wire          s_axi_db_rlast,
  output wire          s_axi_db_rvalid,
  input  wire          s_axi_db_rready,
  // ... to the root ports' BAR windows
  output wire [0:0]    m_axi_db_awid,
  output wire [31:0]   m_axi_db_awaddr,
  output wire [7:0]    m_axi_db_awlen,
  output wire [2:0]    m_axi_db_awsize,
  output wire [1:0]    m_axi_db_awburst,
  output wire [0:0]    m_axi_db_awlock,
  output wire [3:0]    m_axi_db_awcache,
  output wire [2:0]    m_axi_db_awprot,
  output wire          m_axi_db_awvalid,
  input  wire          m_axi_db_awready,
  output wire [31:0]   m_axi_db_wdata,
  output wire [3:0]    m_axi_db_wstrb,
  output wire          m_axi_db_wlast,
  output wire          m_axi_db_wvalid,
  input  wire          m_axi_db_wready,
  input  wire [0:0]    m_axi_db_bid,
  input  wire [1:0]    m_axi_db_bresp,
  input  wire          m_axi_db_bvalid,
  output wire          m_axi_db_bready,
  output wire [0:0]    m_axi_db_arid,
  output wire [31:0]   m_axi_db_araddr,
  output wire [7:0]    m_axi_db_arlen,
  output wire [2:0]    m_axi_db_arsize,
  output wire [1:0]    m_axi_db_arburst,
  output wire [0:0]    m_axi_db_arlock,
  output wire [3:0]    m_axi_db_arcache,
  output wire [2:0]    m_axi_db_arprot,
  output wire          m_axi_db_arvalid,
  input  wire          m_axi_db_arready,
  input  wire [0:0]    m_axi_db_rid,
  input  wire [31:0]   m_axi_db_rdata,
  input  wire [1:0]    m_axi_db_rresp,
  input  wire          m_axi_db_rlast,
  input  wire          m_axi_db_rvalid,
  output wire          m_axi_db_rready,

  // Interrupt (level, active high, dp_clk)
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
  output reg           irq,

  // Test pattern generator control/status (src_clk domain)
  output wire          tpg_enable,
  output wire          tpg_seq_rst,
  output wire [31:0]   tpg_rate_inc,
  input  wire [63:0]   tpg_seq_next,

  // Playback checker control/status (src_clk domain)
  output wire          chk_enable,
  output wire          chk_reset,
  output wire [31:0]   chk_rate_inc,
  input  wire [63:0]   chk_beats,
  input  wire [63:0]   chk_errors,
  input  wire [63:0]   chk_gaps,
  input  wire [63:0]   chk_gap_beats,
  input  wire [63:0]   chk_underflows,
  input  wire [63:0]   chk_last_seq,

  // Host Accelerator register interface stopped answering (nvrec_axil_guard
  // `dead`, any clock domain; synchronised here)
  input  wire          ha_dead
);

  localparam integer CNT_W     = $clog2(FIFO_DEPTH) + 1;
  localparam integer EGR_CNT_W = $clog2(EGR_FIFO_DEPTH) + 1;
  localparam integer SYNC_FF   = 4;
  localparam [31:0]  VERSION   = 32'h0001_0001;   // register map 1.1
  localparam [31:0]  ID_VALUE  = 32'h4E56_5243;
  localparam integer MAX_SLOTS = 1 << SLOT_W;

  // ===========================================================================
  // Register bus
  // ===========================================================================
  wire        wr_req, rd_req;
  wire [11:0] wr_addr, rd_addr;
  wire [31:0] wr_data;
  wire [3:0]  wr_strb;
  reg  [31:0] rd_data;

  nvrec_regs u_regs (
    .clk           (dp_clk),
    .resetn        (dp_resetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .wr_req        (wr_req),
    .wr_addr       (wr_addr),
    .wr_data       (wr_data),
    .wr_strb       (wr_strb),
    .rd_req        (rd_req),
    .rd_addr       (rd_addr),
    .rd_data       (rd_data)
  );

  wire wr  = wr_req;                      // full 32-bit writes expected
  wire wr0 = wr_req & wr_strb[0];


  // ===========================================================================
  // Soft reset sequencer (fdrec semantics) -- dp_clk
  // ===========================================================================
  localparam integer SRST_MIN_CYCLES = 128;
  reg       srst, srst_pulse;
  reg [7:0] srst_cnt;
  wire      fifo_rst_busy, egr_wr_rst_busy;
  wire      srst_start = wr0 && (wr_addr == 12'h00C) && wr_data[0] && !srst;

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      srst       <= 1'b0;
      srst_pulse <= 1'b0;
      srst_cnt   <= 8'd0;
    end else begin
      srst_pulse <= srst_start;
      if (srst_start) begin
        srst     <= 1'b1;
        srst_cnt <= 8'd0;
      end else if (srst) begin
        if (srst_cnt != SRST_MIN_CYCLES[7:0] - 8'd1)
          srst_cnt <= srst_cnt + 8'd1;
        else if (!fifo_rst_busy && !egr_wr_rst_busy)
          srst <= 1'b0;
      end
    end
  end

  // engine reset: power-on or soft reset (credits survive a soft reset)
  wire eng_rst = !dp_resetn || srst;

  // Host Accelerator dead (evaluation license expired / register slave hung)
  wire ha_dead_s;
  xpm_cdc_single #(.DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0))
  u_cdc_ha_dead (.src_clk(1'b0), .src_in(ha_dead), .dest_clk(dp_clk), .dest_out(ha_dead_s));

  // ===========================================================================
  // fdrec-compatible control registers
  // ===========================================================================
  reg         tpg_en_r, tpg_seq_rst_r;
  reg  [31:0] tpg_rate_r;
  reg         chk_en_r, chk_rst_r;
  reg  [31:0] chk_rate_r;
  reg         egr_flush;
  reg  [8:0]  chk_rst_cnt;
  reg         chk_rst_busy;
  integer     bi;

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      tpg_en_r      <= 1'b0;
      tpg_seq_rst_r <= 1'b0;
      tpg_rate_r    <= 32'd0;
      chk_en_r      <= 1'b0;
      chk_rst_r     <= 1'b0;
      chk_rate_r    <= 32'h8000_0000;
      egr_flush     <= 1'b0;
    end else begin
      tpg_seq_rst_r <= 1'b0;
      chk_rst_r     <= 1'b0;
      if (srst_start) begin
        tpg_en_r  <= 1'b0;
        chk_en_r  <= 1'b0;
        egr_flush <= 1'b0;
      end else if (wr) begin
        case (wr_addr)
          12'h010: if (wr_strb[0]) begin
            tpg_en_r      <= wr_data[0];
            tpg_seq_rst_r <= wr_data[1];
          end
          12'h014: for (bi = 0; bi < 4; bi = bi + 1)
                     if (wr_strb[bi]) tpg_rate_r[8*bi +: 8] <= wr_data[8*bi +: 8];
          12'h060: if (wr_strb[0]) begin
            chk_en_r  <= wr_data[0];
            chk_rst_r <= wr_data[1] & ~chk_rst_busy;
          end
          12'h064: for (bi = 0; bi < 4; bi = bi + 1)
                     if (wr_strb[bi]) chk_rate_r[8*bi +: 8] <= wr_data[8*bi +: 8];
          12'h0A0: if (wr_strb[0]) egr_flush <= wr_data[0];
          default: ;
        endcase
      end
    end
  end

  // ===========================================================================
  // dp_clk -> src_clk control crossings (as fdrec_core)
  // ===========================================================================
  wire src_srst_pulse, src_seq_rst_pulse, src_tpg_enable, src_chk_enable, src_chk_rst_pulse;

  xpm_cdc_pulse #(.DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .REG_OUTPUT(1), .RST_USED(0), .SIM_ASSERT_CHK(0))
  u_cdc_srst (.src_clk(dp_clk), .src_pulse(srst_pulse), .src_rst(1'b0),
              .dest_clk(src_clk), .dest_rst(1'b0), .dest_pulse(src_srst_pulse));

  xpm_cdc_pulse #(.DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .REG_OUTPUT(1), .RST_USED(0), .SIM_ASSERT_CHK(0))
  u_cdc_seq_rst (.src_clk(dp_clk), .src_pulse(tpg_seq_rst_r), .src_rst(1'b0),
                 .dest_clk(src_clk), .dest_rst(1'b0), .dest_pulse(src_seq_rst_pulse));

  xpm_cdc_single #(.DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1))
  u_cdc_tpg_en (.src_clk(dp_clk), .src_in(tpg_en_r), .dest_clk(src_clk), .dest_out(src_tpg_enable));

  xpm_cdc_single #(.DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1))
  u_cdc_chk_en (.src_clk(dp_clk), .src_in(chk_en_r), .dest_clk(src_clk), .dest_out(src_chk_enable));

  xpm_cdc_pulse #(.DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .REG_OUTPUT(1), .RST_USED(0), .SIM_ASSERT_CHK(0))
  u_cdc_chk_rst (.src_clk(dp_clk), .src_pulse(chk_rst_r), .src_rst(1'b0),
                 .dest_clk(src_clk), .dest_rst(1'b0), .dest_pulse(src_chk_rst_pulse));

  // continuously re-sent coherent 32-bit words: TPG_RATE_INC, CHK_RATE_INC
  reg         rate_send, crate_send;
  reg  [31:0] rate_hold, crate_hold;
  wire        rate_rcv, crate_rcv, rate_req, crate_req;
  wire [31:0] rate_dest, crate_dest;
  reg  [31:0] src_rate_inc, src_chk_rate_inc;

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      rate_send  <= 1'b0; rate_hold  <= 32'd0;
      crate_send <= 1'b0; crate_hold <= 32'd0;
    end else begin
      if (!rate_send && !rate_rcv) begin
        rate_hold <= tpg_rate_r; rate_send <= 1'b1;
      end else if (rate_send && rate_rcv)
        rate_send <= 1'b0;
      if (!crate_send && !crate_rcv) begin
        crate_hold <= chk_rate_r; crate_send <= 1'b1;
      end else if (crate_send && crate_rcv)
        crate_send <= 1'b0;
    end
  end

  xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
                      .SRC_SYNC_FF(SYNC_FF), .WIDTH(32))
  u_cdc_rate (.src_clk(dp_clk), .src_in(rate_hold), .src_send(rate_send), .src_rcv(rate_rcv),
              .dest_clk(src_clk), .dest_req(rate_req), .dest_ack(1'b0), .dest_out(rate_dest));

  xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
                      .SRC_SYNC_FF(SYNC_FF), .WIDTH(32))
  u_cdc_chk_rate (.src_clk(dp_clk), .src_in(crate_hold), .src_send(crate_send), .src_rcv(crate_rcv),
                  .dest_clk(src_clk), .dest_req(crate_req), .dest_ack(1'b0), .dest_out(crate_dest));

  // ===========================================================================
  // src_clk domain
  // ===========================================================================
  reg  [5:0] srst_win_cnt;
  reg        src_srst;

  always @(posedge src_clk) begin
    if (!src_resetn || src_srst_pulse) begin
      src_srst     <= 1'b1;
      srst_win_cnt <= 6'd0;
    end else if (src_srst) begin
      srst_win_cnt <= srst_win_cnt + 6'd1;
      if (srst_win_cnt == 6'd63)
        src_srst <= 1'b0;
    end
  end

  always @(posedge src_clk) begin
    if (!src_resetn) begin
      src_rate_inc     <= 32'd0;
      src_chk_rate_inc <= 32'd0;
    end else begin
      if (rate_req)  src_rate_inc     <= rate_dest;
      if (crate_req) src_chk_rate_inc <= crate_dest;
    end
  end

  assign tpg_enable   = src_tpg_enable & ~src_srst;
  assign tpg_seq_rst  = src_seq_rst_pulse | src_srst;
  assign tpg_rate_inc = src_rate_inc;
  assign chk_enable   = src_chk_enable & ~src_srst;
  assign chk_reset    = src_chk_rst_pulse | src_srst;
  assign chk_rate_inc = src_chk_rate_inc;

  // Ingest FIFO
  wire [127:0]     fifo_tdata;
  wire             fifo_tvalid, fifo_tready;
  wire [63:0]      beats_in, drop_count;
  wire [CNT_W-1:0] fifo_count;

  fdrec_ingest #(.FIFO_DEPTH(FIFO_DEPTH)) u_ingest (
    .src_clk       (src_clk),
    .src_srst      (src_srst),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    .beats_in      (beats_in),
    .drop_count    (drop_count),
    .dp_clk        (dp_clk),
    .fifo_tdata    (fifo_tdata),
    .fifo_tvalid   (fifo_tvalid),
    .fifo_tready   (fifo_tready),
    .fifo_count    (fifo_count),
    .fifo_rst_busy (fifo_rst_busy)
  );

  // Snapshots src_clk -> dp_clk: {seq_next, beats_in, drop_count}, checker counters
  reg          snap_send, csnap_send;
  reg  [191:0] snap_hold;
  reg  [383:0] csnap_hold;
  wire         snap_rcv, csnap_rcv, snap_valid, chk_snap_valid;
  wire [191:0] snap_data;
  wire [383:0] chk_snap_data;

  always @(posedge src_clk) begin
    if (!src_resetn) begin
      snap_send  <= 1'b0; snap_hold  <= 192'd0;
      csnap_send <= 1'b0; csnap_hold <= 384'd0;
    end else begin
      if (!snap_send && !snap_rcv) begin
        snap_hold <= {tpg_seq_next, beats_in, drop_count}; snap_send <= 1'b1;
      end else if (snap_send && snap_rcv)
        snap_send <= 1'b0;
      if (!csnap_send && !csnap_rcv) begin
        csnap_hold <= {chk_beats, chk_errors, chk_gaps, chk_gap_beats, chk_underflows, chk_last_seq};
        csnap_send <= 1'b1;
      end else if (csnap_send && csnap_rcv)
        csnap_send <= 1'b0;
    end
  end

  xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
                      .SRC_SYNC_FF(SYNC_FF), .WIDTH(192))
  u_cdc_snap (.src_clk(src_clk), .src_in(snap_hold), .src_send(snap_send), .src_rcv(snap_rcv),
              .dest_clk(dp_clk), .dest_req(snap_valid), .dest_ack(1'b0), .dest_out(snap_data));

  xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(SYNC_FF), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
                      .SRC_SYNC_FF(SYNC_FF), .WIDTH(384))
  u_cdc_chk_snap (.src_clk(src_clk), .src_in(csnap_hold), .src_send(csnap_send), .src_rcv(csnap_rcv),
                  .dest_clk(dp_clk), .dest_req(chk_snap_valid), .dest_ack(1'b0), .dest_out(chk_snap_data));

  // ===========================================================================
  // dp_clk: ingest status (OVERFLOW, HWM), checker snapshot copies
  // ===========================================================================
  reg [63:0]      seq_next_q, beats_in_q, drop_q;
  reg             overflow;
  reg [CNT_W-1:0] hwm;
  wire ovf_set = snap_valid && !srst && (snap_data[63:0] != drop_q) && (snap_data[63:0] != 64'd0);

  always @(posedge dp_clk) begin
    if (!dp_resetn || srst_start) begin
      seq_next_q <= 64'd0; beats_in_q <= 64'd0; drop_q <= 64'd0;
      overflow   <= 1'b0;  hwm <= {CNT_W{1'b0}};
    end else begin
      if (snap_valid && !srst) begin
        seq_next_q <= snap_data[191:128];
        beats_in_q <= snap_data[127:64];
        drop_q     <= snap_data[63:0];
      end
      if (ovf_set)
        overflow <= 1'b1;
      else if (wr0 && (wr_addr == 12'h020) && wr_data[0])
        overflow <= 1'b0;
      if ((wr_req && (wr_addr == 12'h024)) || srst)
        hwm <= {CNT_W{1'b0}};
      else if (fifo_count > hwm)
        hwm <= fifo_count;
    end
  end

  reg [63:0] chk_q [0:5];   // beats, errors, gaps, gap_beats, underflows, last_seq
  integer ci;
  always @(posedge dp_clk) begin
    if (!dp_resetn || srst_start || chk_rst_r) begin
      chk_rst_busy <= chk_rst_r;
      chk_rst_cnt  <= 9'd0;
      for (ci = 0; ci < 6; ci = ci + 1) chk_q[ci] <= 64'd0;
    end else begin
      if (chk_rst_busy) begin
        chk_rst_cnt <= chk_rst_cnt + 9'd1;
        if (chk_rst_cnt == 9'd255)
          chk_rst_busy <= 1'b0;
      end
      if (chk_snap_valid && !srst && !chk_rst_busy) begin
        chk_q[0] <= chk_snap_data[383:320];
        chk_q[1] <= chk_snap_data[319:256];
        chk_q[2] <= chk_snap_data[255:192];
        chk_q[3] <= chk_snap_data[191:128];
        chk_q[4] <= chk_snap_data[127:64];
        chk_q[5] <= chk_snap_data[63:0];
      end
    end
  end

  // ===========================================================================
  // NVMe offload configuration registers
  // ===========================================================================
  reg  [7:0]  cfg_reg;            // CONFIG
  reg  [6:0]  irq_en;
  reg  [63:0] ring_base_r, prp_base_r, start_chunk_r;
  reg  [31:0] num_chunks_r, chunk_size_r, prp_shift_r, lba_shift_r;
  reg  [31:0] length_r, last_bytes_r, credit_init_r;
  reg  [31:0] m_nsid_r [0:1];
  reg  [13:0] m_sel_r  [0:1];
  reg  [63:0] m_lba_r  [0:1];
  reg  [6:0]  max_infl_r [0:1];

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      cfg_reg       <= 8'h10;
      irq_en        <= 7'd0;
      ring_base_r   <= 64'd0;
      prp_base_r    <= 64'd0;
      start_chunk_r <= 64'd0;
      num_chunks_r  <= 32'd256;
      chunk_size_r  <= 32'h0010_0000;
      prp_shift_r   <= 32'd12;
      lba_shift_r   <= 32'd9;
      length_r      <= 32'd0;
      last_bytes_r  <= 32'd0;
      credit_init_r <= 32'd63;
      m_nsid_r[0]   <= 32'd1;           m_nsid_r[1]   <= 32'd1;
      m_sel_r[0]    <= {6'd0, 3'd0, 5'd0}; m_sel_r[1] <= {6'd0, 3'd0, 5'd1};
      m_lba_r[0]    <= 64'd0;           m_lba_r[1]    <= 64'd0;
      max_infl_r[0] <= 7'd32;           max_infl_r[1] <= 7'd32;
    end else if (wr) begin
      case (wr_addr)
        12'h104: cfg_reg       <= wr_data[7:0];
        12'h110: irq_en        <= wr_data[6:0];
        12'h120: ring_base_r[31:0]   <= wr_data;
        12'h124: ring_base_r[63:32]  <= wr_data;
        12'h128: num_chunks_r  <= wr_data;
        12'h12C: chunk_size_r  <= wr_data;
        12'h130: prp_base_r[31:0]    <= wr_data;
        12'h134: prp_base_r[63:32]   <= wr_data;
        12'h138: prp_shift_r   <= wr_data;
        12'h13C: lba_shift_r   <= wr_data;
        12'h140: start_chunk_r[31:0]  <= wr_data;
        12'h144: start_chunk_r[63:32] <= wr_data;
        12'h148: length_r      <= wr_data;
        12'h14C: last_bytes_r  <= wr_data;
        12'h154: credit_init_r <= wr_data;
        12'h180: m_nsid_r[0]   <= wr_data;
        12'h184: m_sel_r[0]    <= {wr_data[13:8], 3'd0, wr_data[4:0]};
        12'h188: m_lba_r[0][31:0]  <= wr_data;
        12'h18C: m_lba_r[0][63:32] <= wr_data;
        12'h1A0: m_nsid_r[1]   <= wr_data;
        12'h1A4: m_sel_r[1]    <= {wr_data[13:8], 3'd0, wr_data[4:0]};
        12'h1A8: m_lba_r[1][31:0]  <= wr_data;
        12'h1AC: m_lba_r[1][63:32] <= wr_data;
        12'h1C0: max_infl_r[0] <= (wr_data[6:0] == 7'd0) ? 7'd1 : ((wr_data > 32'd63) ? 7'd63 : wr_data[6:0]);
        12'h1E0: max_infl_r[1] <= (wr_data[6:0] == 7'd0) ? 7'd1 : ((wr_data > 32'd63) ? 7'd63 : wr_data[6:0]);
        default: ;
      endcase
    end
  end

  // CONFIG bit 8 (CREDIT_PER_CQE) is kept separately (cfg_reg is 8 bits)
  reg credit_per_cqe_r;
  always @(posedge dp_clk) begin
    if (!dp_resetn)
      credit_per_cqe_r <= 1'b0;
    else if ((wr_req && (wr_addr == 12'h104)))
      credit_per_cqe_r <= wr_data[8];
  end

  // chunk_shift = log2(CHUNK_SIZE) clamped to 16..22
  function [4:0] log2_chunk;
    input [31:0] v;
    integer b;
    begin
      log2_chunk = 5'd16;
      for (b = 16; b <= 22; b = b + 1)
        if (v[b]) log2_chunk = b[4:0];
    end
  endfunction

  // ===========================================================================
  // Run control
  // ===========================================================================
  localparam [3:0] ST_IDLE = 4'd0, ST_RUN = 4'd1, ST_DRAIN = 4'd2, ST_DONE = 4'd3,
                   ST_ABORTING = 4'd4, ST_ABORTED = 4'd5;
  reg  [3:0]  state;
  reg         start_pend, run_start, run_stop, run_abort;
  reg  [1:0]  credit_rst;
  reg         stats_rst;

  // latched configuration
  reg         c_play, c_fua, c_two, c_cpc;
  reg  [3:0]  c_lba_shift;
  reg  [4:0]  c_chunk_shift, c_prp_shift;
  reg  [SLOT_W:0] c_num_chunks;
  reg  [63:0] c_ring_base, c_prp_base, c_start_chunk;
  reg  [31:0] c_length;
  reg  [22:0] c_last_bytes;
  reg  [31:0] c_nsid0, c_nsid1;
  reg  [4:0]  c_ssd0, c_ssd1;
  reg  [5:0]  c_sq0, c_sq1;
  reg  [63:0] c_lba0, c_lba1;

  wire ctrl_wr = (wr_req && (wr_addr == 12'h100));
  wire can_start = (state == ST_IDLE) || (state == ST_DONE) || (state == ST_ABORTED);

  // engine status
  wire        wr_done, wr_busy, wr_accepting, wr_ring_full, rd_done, rd_busy, all_issued;
  wire [31:0] filled_cnt, opened_cnt, issued_cnt, cmp_cnt, rd_cnt;
  wire [7:0]  inflight0, inflight1;
  reg         st_done_pulse, st_abort_pulse;

  always @(posedge dp_clk) begin
    if (eng_rst) begin
      state      <= ST_IDLE;
      start_pend <= 1'b0;
      run_start  <= 1'b0;
      run_stop   <= 1'b0;
      run_abort  <= 1'b0;
      st_done_pulse  <= 1'b0;
      st_abort_pulse <= 1'b0;
    end else begin
      run_start  <= start_pend;
      start_pend <= 1'b0;
      run_stop   <= 1'b0;
      run_abort  <= 1'b0;
      st_done_pulse  <= 1'b0;
      st_abort_pulse <= 1'b0;
      if (ctrl_wr && wr_data[0] && can_start && !start_pend) begin
        start_pend    <= 1'b1;
        c_play        <= cfg_reg[0];
        c_fua         <= cfg_reg[1];
        c_two         <= (cfg_reg[5:4] == 2'd2);
        c_cpc         <= credit_per_cqe_r;
        c_lba_shift   <= (lba_shift_r == 32'd12) ? 4'd12 : 4'd9;
        c_chunk_shift <= log2_chunk(chunk_size_r);
        c_prp_shift   <= (prp_shift_r < 32'd12) ? 5'd12 : ((prp_shift_r > 32'd16) ? 5'd16 : prp_shift_r[4:0]);
        c_num_chunks  <= (num_chunks_r == 32'd0) ? 1 :
                         ((num_chunks_r > MAX_SLOTS) ? MAX_SLOTS[SLOT_W:0] : num_chunks_r[SLOT_W:0]);
        c_ring_base   <= ring_base_r;
        c_prp_base    <= prp_base_r;
        c_start_chunk <= start_chunk_r;
        c_length      <= length_r;
        c_last_bytes  <= last_bytes_r[22:0];
        c_nsid0       <= m_nsid_r[0];
        c_nsid1       <= m_nsid_r[1];
        c_ssd0        <= m_sel_r[0][4:0];
        c_ssd1        <= m_sel_r[1][4:0];
        c_sq0         <= m_sel_r[0][13:8];
        c_sq1         <= m_sel_r[1][13:8];
        c_lba0        <= m_lba_r[0];
        c_lba1        <= m_lba_r[1];
      end
      if (run_start)
        state <= ST_RUN;
      case (state)
        ST_RUN: begin
          if (ctrl_wr && wr_data[2]) begin
            run_abort <= 1'b1; state <= ST_ABORTING;
          end else if (ctrl_wr && wr_data[1]) begin
            if (c_play) begin
              run_abort <= 1'b1; state <= ST_ABORTING;
            end else begin
              run_stop <= 1'b1; state <= ST_DRAIN;
            end
          end else if (!c_play && wr_done) begin
            state <= ST_DRAIN;           // LENGTH_CHUNKS reached
          end else if (c_play && rd_done) begin
            state <= ST_DONE; st_done_pulse <= 1'b1;
          end
        end
        ST_DRAIN: begin
          if (ctrl_wr && wr_data[2]) begin
            run_abort <= 1'b1; state <= ST_ABORTING;
          end else if (wr_done && all_issued && (cmp_cnt == issued_cnt)) begin
            state <= ST_DONE; st_done_pulse <= 1'b1;
          end
        end
        ST_ABORTING: begin
          if (!wr_busy && !rd_busy && (inflight0 == 8'd0) && (inflight1 == 8'd0)) begin
            state <= ST_ABORTED; st_abort_pulse <= 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      credit_rst <= 2'b00;
      stats_rst  <= 1'b0;
    end else begin
      // bit4: both SSDs, bit6: SSD 0 only, bit7: SSD 1 only
      credit_rst <= {2{ctrl_wr}} & ({2{wr_data[4]}} | wr_data[7:6]);
      stats_rst  <= ctrl_wr && wr_data[5];
    end
  end

  // RUN_DROP_COUNT: ingest drops while the record run was accepting data
  // (from START until the writer stops taking data: STOP seen, LENGTH reached
  // or ABORT). Drops after that (source still running while the run drains)
  // are not counted here.
  reg [63:0] drop_base, run_drops;
  reg        run_acc_q;
  always @(posedge dp_clk) begin
    if (eng_rst) begin
      drop_base <= 64'd0; run_drops <= 64'd0; run_acc_q <= 1'b0;
    end else begin
      run_acc_q <= wr_accepting;
      if (run_start) begin
        drop_base <= drop_q; run_drops <= 64'd0;
      end else if (wr_accepting || run_acc_q)
        run_drops <= drop_q - drop_base;
    end
  end

  // free-running timestamp
  reg [63:0] tstamp;
  always @(posedge dp_clk) begin
    if (!dp_resetn) tstamp <= 64'd0;
    else            tstamp <= tstamp + 64'd1;
  end

  // ===========================================================================
  // Engines
  // ===========================================================================
  wire        final_partial;
  wire [22:0] last_bytes;
  wire [63:0] wr_beats_out, wr_run_beats, wr_full_cycles;
  wire [31:0] wr_pad_bytes, wr_bresp_errs;

  nvrec_wr #(.SLOT_W(SLOT_W), .CNT_W(CNT_W), .ADDR_W(64)) u_wr (
    .clk           (dp_clk),
    .rst           (eng_rst),
    .start         (run_start && !c_play),
    .stop          (run_stop),
    .abort         (run_abort),
    .ring_base     (c_ring_base),
    .chunk_shift   (c_chunk_shift),
    .num_chunks    (c_num_chunks),
    .lba_shift     (c_lba_shift),
    .length_chunks (c_length),
    .rel_cnt       (cmp_cnt),
    .fifo_tdata    (fifo_tdata),
    .fifo_tvalid   (fifo_tvalid),
    .fifo_tready   (fifo_tready),
    .fifo_count    (fifo_count),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready),
    .opened_cnt    (opened_cnt),
    .filled_cnt    (filled_cnt),
    .final_partial (final_partial),
    .last_bytes    (last_bytes),
    .done          (wr_done),
    .busy          (wr_busy),
    .accepting     (wr_accepting),
    .ring_full     (wr_ring_full),
    .beats_out     (wr_beats_out),
    .run_beats     (wr_run_beats),
    .pad_bytes     (wr_pad_bytes),
    .full_cycles   (wr_full_cycles),
    .bresp_errs    (wr_bresp_errs)
  );

  assign m_axi_awsize  = 3'd4;        // 16 bytes per beat
  assign m_axi_awburst = 2'b01;       // INCR
  assign m_axi_awcache = 4'b0011;     // normal non-cacheable bufferable
  assign m_axi_awprot  = 3'b000;
  assign m_axi_wstrb   = 16'hFFFF;
  assign m_axi_arsize  = 3'd4;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;

  // Injector
  wire         inj_valid, inj_accept, inj_afull, inj_irq, inj_push;
  wire [511:0] inj_sqe;
  wire [4:0]   inj_ssd;
  wire [5:0]   inj_sq;
  wire [127:0] inj_cqe;
  wire [15:0]  inj_info;
  wire [31:0]  inj_rd_data, inj_submitted;

  nvrec_inj #(.FIFO_D(16)) u_inj (
    .clk           (dp_clk),
    .rst           (eng_rst),
    .wr_en         (wr_req && (wr_addr[11:7] == 5'b00110)),   // 0x300-0x37F
    .wr_word       (wr_addr[6:2]),
    .wr_data       (wr_data),
    .rd_word       (rd_addr[6:2]),
    .rd_data       (inj_rd_data),
    .inj_valid     (inj_valid),
    .inj_sqe       (inj_sqe),
    .inj_ssd       (inj_ssd),
    .inj_sq        (inj_sq),
    .inj_accept    (inj_accept),
    .inj_submitted (inj_submitted),
    .push          (inj_push),
    .push_cqe      (inj_cqe),
    .push_info     (inj_info),
    .afull         (inj_afull),
    .irq           (inj_irq)
  );

  // Command builder + arbiter
  wire        bld_issue;
  wire [SLOT_W-1:0] bld_slot;
  wire        cq_valid, cq_dec_bld, cq_dec_inj;
  wire [4:0]  cq_ssd;
  wire [10:0] cq_credit;
  wire [11:0] credits0, credits1;
  wire [7:0]  infl_hwm0, infl_hwm1;
  wire [31:0] ssd_issued0, ssd_issued1;

  nvrec_cmd #(.SLOT_W(SLOT_W), .ADDR_W(64)) u_cmd (
    .clk             (dp_clk),
    .rst             (!dp_resetn),
    .cnt_rst         (srst),
    .start           (run_start),
    .abort           (run_abort || srst),
    .mode_play       (c_play),
    .fua             (c_fua),
    .two_members     (c_two),
    .lba_shift       (c_lba_shift),
    .chunk_shift     (c_chunk_shift),
    .num_chunks      (c_num_chunks),
    .ring_base       (c_ring_base),
    .prp_base        (c_prp_base),
    .prp_shift       (c_prp_shift),
    .start_chunk     (c_start_chunk),
    .length_chunks   (c_length),
    .last_chunk_bytes(c_last_bytes),
    .m0_nsid         (c_nsid0),
    .m1_nsid         (c_nsid1),
    .m0_ssd          (c_ssd0),
    .m1_ssd          (c_ssd1),
    .m0_sq           (c_sq0),
    .m1_sq           (c_sq1),
    .m0_lba          (c_lba0),
    .m1_lba          (c_lba1),
    .max_inflight0   (max_infl_r[0]),
    .max_inflight1   (max_infl_r[1]),
    .credit_init     (credit_init_r[10:0]),
    .credit_rst      (credit_rst),
    .credit_per_cqe  (c_cpc),
    .filled_cnt      (filled_cnt),
    .final_partial   (final_partial),
    .last_bytes      (last_bytes),
    .wr_done         (wr_done),
    .rel_cnt         (rd_cnt),
    .inj_valid       (inj_valid),
    .inj_sqe         (inj_sqe),
    .inj_ssd         (inj_ssd),
    .inj_sq          (inj_sq),
    .inj_accept      (inj_accept),
    .cq_valid        (cq_valid),
    .cq_ssd          (cq_ssd),
    .cq_credit       (cq_credit),
    .cq_dec_bld      (cq_dec_bld),
    .cq_dec_inj      (cq_dec_inj),
    .m_axis_tdata    (m_axis_sqe_tdata),
    .m_axis_tkeep    (m_axis_sqe_tkeep),
    .m_axis_tuser    (m_axis_sqe_tuser),
    .m_axis_tvalid   (m_axis_sqe_tvalid),
    .m_axis_tready   (m_axis_sqe_tready),
    .bld_issue       (bld_issue),
    .bld_slot        (bld_slot),
    .issued_cnt      (issued_cnt),
    .all_issued      (all_issued),
    .credits0        (credits0),
    .credits1        (credits1),
    .inflight0       (inflight0),
    .inflight1       (inflight1),
    .inflight_hwm0   (infl_hwm0),
    .inflight_hwm1   (infl_hwm1),
    .hwm_clr0        ((wr_req && (wr_addr == 12'h1D8))),
    .hwm_clr1        ((wr_req && (wr_addr == 12'h1F8))),
    .ssd_issued0     (ssd_issued0),
    .ssd_issued1     (ssd_issued1),
    .inj_submitted   (inj_submitted)
  );

  // Completion router
  wire [63:0]  cmds_done, lat_sum;
  wire [31:0]  cmd_errors, unexpected, ssd_comp0, ssd_comp1, ssd_err0, ssd_err1;
  wire [31:0]  err_last_status, err_last_cid, lat_min, lat_max, lat_cnt;
  wire [511:0] lat_hist;
  wire         err_pulse, unexp_pulse;

  nvrec_cq #(.SLOT_W(SLOT_W)) u_cq (
    .clk             (dp_clk),
    .rst             (eng_rst),
    .start           (run_start),
    .stats_rst       (stats_rst),
    .num_chunks      (c_num_chunks),
    .s_axis_tdata    (s_axis_cqe_tdata),
    .s_axis_tuser    (s_axis_cqe_tuser),
    .s_axis_tvalid   (s_axis_cqe_tvalid),
    .s_axis_tready   (s_axis_cqe_tready),
    .issue_we        (bld_issue),
    .issue_slot      (bld_slot),
    .now             (tstamp[31:0]),
    .cq_valid        (cq_valid),
    .cq_ssd          (cq_ssd),
    .cq_credit       (cq_credit),
    .cq_dec_bld      (cq_dec_bld),
    .cq_dec_inj      (cq_dec_inj),
    .inj_push        (inj_push),
    .inj_cqe         (inj_cqe),
    .inj_info        (inj_info),
    .inj_afull       (inj_afull),
    .cmp_cnt         (cmp_cnt),
    .cmds_done       (cmds_done),
    .cmd_errors      (cmd_errors),
    .unexpected      (unexpected),
    .ssd_completed0  (ssd_comp0),
    .ssd_completed1  (ssd_comp1),
    .ssd_errors0     (ssd_err0),
    .ssd_errors1     (ssd_err1),
    .err_last_status (err_last_status),
    .err_last_cid    (err_last_cid),
    .err_pulse       (err_pulse),
    .unexp_pulse     (unexp_pulse),
    .lat_min         (lat_min),
    .lat_max         (lat_max),
    .lat_cnt         (lat_cnt),
    .lat_sum         (lat_sum),
    .lat_hist        (lat_hist)
  );

  // Ring reader (playback) -> egress FIFO
  wire [127:0]         rd_tdata;
  wire                 rd_tlast, rd_tvalid, rd_tready;
  wire [EGR_CNT_W-1:0] egr_level;
  wire [63:0]          rd_bytes, egr_beats_in, egr_discard;
  wire [31:0]          rd_rresp_errs;

  nvrec_rd #(.SLOT_W(SLOT_W), .ADDR_W(64), .EGR_DEPTH(EGR_FIFO_DEPTH), .EGR_CNT_W(EGR_CNT_W)) u_rd (
    .clk              (dp_clk),
    .rst              (eng_rst),
    .start            (run_start && c_play),
    .abort            (run_abort),
    .ring_base        (c_ring_base),
    .chunk_shift      (c_chunk_shift),
    .num_chunks       (c_num_chunks),
    .length_chunks    (c_length),
    .last_chunk_bytes (c_last_bytes),
    .cmp_cnt          (cmp_cnt),
    .m_axi_araddr     (m_axi_araddr),
    .m_axi_arlen      (m_axi_arlen),
    .m_axi_arvalid    (m_axi_arvalid),
    .m_axi_arready    (m_axi_arready),
    .m_axi_rdata      (m_axi_rdata),
    .m_axi_rresp      (m_axi_rresp),
    .m_axi_rlast      (m_axi_rlast),
    .m_axi_rvalid     (m_axi_rvalid),
    .m_axi_rready     (m_axi_rready),
    .m_axis_tdata     (rd_tdata),
    .m_axis_tlast     (rd_tlast),
    .m_axis_tvalid    (rd_tvalid),
    .m_axis_tready    (rd_tready),
    .egr_level        (egr_level),
    .rd_cnt           (rd_cnt),
    .done             (rd_done),
    .busy             (rd_busy),
    .bytes            (rd_bytes),
    .rresp_errs       (rd_rresp_errs)
  );

  // egress FIFO reset window (as fdrec_core)
  reg  [4:0] egr_rst_cnt;
  reg        egr_fifo_rst;
  always @(posedge dp_clk) begin
    if (!dp_resetn || srst_pulse) begin
      egr_fifo_rst <= 1'b1;
      egr_rst_cnt  <= 5'd0;
    end else if (egr_fifo_rst) begin
      egr_rst_cnt <= egr_rst_cnt + 5'd1;
      if (egr_rst_cnt == 5'd31)
        egr_fifo_rst <= 1'b0;
    end
  end

  fdrec_egress #(.FIFO_DEPTH(EGR_FIFO_DEPTH)) u_egress (
    .dp_clk        (dp_clk),
    .fifo_rst      (egr_fifo_rst),
    .srst          (!dp_resetn || srst),
    .flush         (egr_flush),
    .s_axis_tdata  (rd_tdata),
    .s_axis_tkeep  (16'hFFFF),
    .s_axis_tlast  (rd_tlast),
    .s_axis_tvalid (rd_tvalid),
    .s_axis_tready (rd_tready),
    .beats_in      (egr_beats_in),
    .discard_count (egr_discard),
    .fifo_level    (egr_level),
    .wr_rst_busy   (egr_wr_rst_busy),
    .src_clk       (src_clk),
    .m_axis_tdata  (m_axis_snk_tdata),
    .m_axis_tlast  (m_axis_snk_tlast),
    .m_axis_tvalid (m_axis_snk_tvalid),
    .m_axis_tready (m_axis_snk_tready)
  );

  // Doorbell monitor: pass-through + log
  assign m_axi_db_awid    = s_axi_db_awid;
  assign m_axi_db_awaddr  = s_axi_db_awaddr;
  assign m_axi_db_awlen   = s_axi_db_awlen;
  assign m_axi_db_awsize  = s_axi_db_awsize;
  assign m_axi_db_awburst = s_axi_db_awburst;
  assign m_axi_db_awlock  = s_axi_db_awlock;
  assign m_axi_db_awcache = s_axi_db_awcache;
  assign m_axi_db_awprot  = s_axi_db_awprot;
  assign m_axi_db_awvalid = s_axi_db_awvalid;
  assign s_axi_db_awready = m_axi_db_awready;
  assign m_axi_db_wdata   = s_axi_db_wdata;
  assign m_axi_db_wstrb   = s_axi_db_wstrb;
  assign m_axi_db_wlast   = s_axi_db_wlast;
  assign m_axi_db_wvalid  = s_axi_db_wvalid;
  assign s_axi_db_wready  = m_axi_db_wready;
  assign s_axi_db_bid     = m_axi_db_bid;
  assign s_axi_db_bresp   = m_axi_db_bresp;
  assign s_axi_db_bvalid  = m_axi_db_bvalid;
  assign m_axi_db_bready  = s_axi_db_bready;
  assign m_axi_db_arid    = s_axi_db_arid;
  assign m_axi_db_araddr  = s_axi_db_araddr;
  assign m_axi_db_arlen   = s_axi_db_arlen;
  assign m_axi_db_arsize  = s_axi_db_arsize;
  assign m_axi_db_arburst = s_axi_db_arburst;
  assign m_axi_db_arlock  = s_axi_db_arlock;
  assign m_axi_db_arcache = s_axi_db_arcache;
  assign m_axi_db_arprot  = s_axi_db_arprot;
  assign m_axi_db_arvalid = s_axi_db_arvalid;
  assign s_axi_db_arready = m_axi_db_arready;
  assign s_axi_db_rid     = m_axi_db_rid;
  assign s_axi_db_rdata   = m_axi_db_rdata;
  assign s_axi_db_rresp   = m_axi_db_rresp;
  assign s_axi_db_rlast   = m_axi_db_rlast;
  assign s_axi_db_rvalid  = m_axi_db_rvalid;
  assign m_axi_db_rready  = s_axi_db_rready;

  wire [31:0]  db_count;
  wire [2:0]   db_next;
  wire [255:0] db_addr, db_data;

  nvrec_dbmon #(.ENTRIES(8)) u_dbmon (
    .clk         (dp_clk),
    .rst         (eng_rst),
    .awaddr      (s_axi_db_awaddr),
    .aw_fire     (s_axi_db_awvalid && m_axi_db_awready),
    .wdata       (s_axi_db_wdata),
    .w_last_fire (s_axi_db_wvalid && m_axi_db_wready && s_axi_db_wlast),
    .db_count    (db_count),
    .db_next     (db_next),
    .db_addr     (db_addr),
    .db_data     (db_data)
  );

  // ===========================================================================
  // Ring fill / HWM, IRQ
  // ===========================================================================
  wire [31:0] ring_fill = c_play ? (issued_cnt - rd_cnt) : (opened_cnt - cmp_cnt);
  reg  [31:0] ring_hwm;
  always @(posedge dp_clk) begin
    if (eng_rst || run_start || (wr_req && (wr_addr == 12'h22C)))
      ring_hwm <= 32'd0;
    else if (((state == ST_RUN) || (state == ST_DRAIN)) && (ring_fill > ring_hwm))
      ring_hwm <= ring_fill;
  end

  // RUN_FIFO_HWM: ingest FIFO high-water mark while the record run accepted
  // data (ING_FIFO_HWM also sees the FIFO fill up after the run, when a
  // free-running source keeps sending); cleared at START and SOFT_RST
  reg [CNT_W-1:0] run_hwm;
  always @(posedge dp_clk) begin
    if (eng_rst || run_start)
      run_hwm <= {CNT_W{1'b0}};
    else if ((wr_accepting || run_acc_q) && (fifo_count > run_hwm))
      run_hwm <= fifo_count;
  end

  reg [6:0] irq_st;   // bit3 (INJ_CQE) is a level, not stored
  reg       ha_dead_q;
  always @(posedge dp_clk) begin
    if (eng_rst) begin
      irq_st    <= 7'd0;
      irq       <= 1'b0;
      ha_dead_q <= 1'b0;
    end else begin
      ha_dead_q <= ha_dead_s;
      if (st_done_pulse)  irq_st[0] <= 1'b1;
      if (err_pulse)      irq_st[1] <= 1'b1;
      if (ovf_set && wr_accepting) irq_st[2] <= 1'b1;
      if (unexp_pulse)    irq_st[4] <= 1'b1;
      if (st_abort_pulse) irq_st[5] <= 1'b1;
      if ((wr_req && (wr_addr == 12'h10C)))
        irq_st <= irq_st & ~(wr_data[6:0] & 7'b1110111);
      // HA_DEAD: set on the rising edge (and again after a SOFT_RST if the
      // IP is still dead), W1C
      if (ha_dead_s && !ha_dead_q) irq_st[6] <= 1'b1;
      irq <= |(({irq_st[6:4], inj_irq, irq_st[2:0]}) & irq_en);
    end
  end

  // ===========================================================================
  // Register read
  // ===========================================================================
  reg [31:0] hi_latch;      // shared HI latch: reading any *_LO latches its HI

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      rd_data  <= 32'd0;
      hi_latch <= 32'd0;
    end else if (rd_req) begin
      rd_data <= 32'd0;
      if (rd_addr[11:7] == 5'b00110) begin
        rd_data <= inj_rd_data;                                  // 0x300-0x37F
      end else if (rd_addr[11:6] == 6'b001011) begin             // 0x2C0-0x2FF
        rd_data <= lat_hist[rd_addr[5:2]*32 +: 32];
      end else if (rd_addr[11:6] == 6'b001111) begin             // 0x3C0-0x3FF
        rd_data <= rd_addr[2] ? db_data[rd_addr[5:3]*32 +: 32] : db_addr[rd_addr[5:3]*32 +: 32];
      end else begin
        case (rd_addr)
          12'h000: rd_data <= VERSION;
          12'h004: rd_data <= SRC_CLK_HZ;
          12'h008: rd_data <= DP_CLK_HZ;
          12'h00C: rd_data <= {31'd0, srst};
          12'h010: rd_data <= {31'd0, tpg_en_r};
          12'h014: rd_data <= tpg_rate_r;
          12'h018: begin rd_data <= seq_next_q[31:0]; hi_latch <= seq_next_q[63:32]; end
          12'h020: rd_data <= {31'd0, overflow};
          12'h024: rd_data <= hwm;
          12'h028: begin rd_data <= drop_q[31:0];     hi_latch <= drop_q[63:32]; end
          12'h030: begin rd_data <= beats_in_q[31:0]; hi_latch <= beats_in_q[63:32]; end
          12'h038: rd_data <= FIFO_DEPTH;
          12'h03C: rd_data <= ID_VALUE;
          12'h048: begin rd_data <= wr_beats_out[31:0]; hi_latch <= wr_beats_out[63:32]; end
          12'h060: rd_data <= {30'd0, chk_rst_busy, chk_en_r};
          12'h064: rd_data <= chk_rate_r;
          12'h070: begin rd_data <= chk_q[0][31:0]; hi_latch <= chk_q[0][63:32]; end
          12'h078: begin rd_data <= chk_q[1][31:0]; hi_latch <= chk_q[1][63:32]; end
          12'h080: begin rd_data <= chk_q[2][31:0]; hi_latch <= chk_q[2][63:32]; end
          12'h088: begin rd_data <= chk_q[3][31:0]; hi_latch <= chk_q[3][63:32]; end
          12'h090: begin rd_data <= chk_q[4][31:0]; hi_latch <= chk_q[4][63:32]; end
          12'h098: begin rd_data <= chk_q[5][31:0]; hi_latch <= chk_q[5][63:32]; end
          12'h0A0: rd_data <= {31'd0, egr_flush};
          12'h0A4: rd_data <= EGR_FIFO_DEPTH;
          12'h0A8: begin rd_data <= egr_beats_in[31:0]; hi_latch <= egr_beats_in[63:32]; end
          12'h0B0: begin rd_data <= egr_discard[31:0];  hi_latch <= egr_discard[63:32]; end
          12'h0B8: rd_data <= egr_level;
          // HI halves of the 64-bit counters: the value latched by the last *_LO read
          12'h01C, 12'h02C, 12'h034, 12'h04C, 12'h074, 12'h07C, 12'h084, 12'h08C,
          12'h094, 12'h09C, 12'h0AC, 12'h0B4,
          12'h11C, 12'h204, 12'h20C, 12'h214, 12'h224, 12'h23C, 12'h24C, 12'h254, 12'h294:
                   rd_data <= hi_latch;
          // NVMe offload
          12'h104: rd_data <= {23'd0, credit_per_cqe_r, cfg_reg};
          12'h108: rd_data <= {19'd0, ha_dead_s, inj_valid, wr_ring_full, rd_busy, wr_busy, 4'd0, state};
          12'h10C: rd_data <= {25'd0, irq_st[6:4], inj_irq, irq_st[2:0]};
          12'h110: rd_data <= {25'd0, irq_en};
          12'h118: begin rd_data <= tstamp[31:0]; hi_latch <= tstamp[63:32]; end
          12'h120: rd_data <= ring_base_r[31:0];
          12'h124: rd_data <= ring_base_r[63:32];
          12'h128: rd_data <= num_chunks_r;
          12'h12C: rd_data <= chunk_size_r;
          12'h130: rd_data <= prp_base_r[31:0];
          12'h134: rd_data <= prp_base_r[63:32];
          12'h138: rd_data <= prp_shift_r;
          12'h13C: rd_data <= lba_shift_r;
          12'h140: rd_data <= start_chunk_r[31:0];
          12'h144: rd_data <= start_chunk_r[63:32];
          12'h148: rd_data <= length_r;
          12'h14C: rd_data <= last_bytes_r;
          12'h150: rd_data <= MAX_SLOTS;
          12'h154: rd_data <= credit_init_r;
          12'h180: rd_data <= m_nsid_r[0];
          12'h184: rd_data <= {18'd0, m_sel_r[0][13:8], 3'd0, m_sel_r[0][4:0]};
          12'h188: rd_data <= m_lba_r[0][31:0];
          12'h18C: rd_data <= m_lba_r[0][63:32];
          12'h1A0: rd_data <= m_nsid_r[1];
          12'h1A4: rd_data <= {18'd0, m_sel_r[1][13:8], 3'd0, m_sel_r[1][4:0]};
          12'h1A8: rd_data <= m_lba_r[1][31:0];
          12'h1AC: rd_data <= m_lba_r[1][63:32];
          12'h1C0: rd_data <= {25'd0, max_infl_r[0]};
          12'h1C4: rd_data <= {24'd0, inflight0};
          12'h1C8: rd_data <= {20'd0, credits0};
          12'h1CC: rd_data <= ssd_issued0;
          12'h1D0: rd_data <= ssd_comp0;
          12'h1D4: rd_data <= ssd_err0;
          12'h1D8: rd_data <= {24'd0, infl_hwm0};
          12'h1E0: rd_data <= {25'd0, max_infl_r[1]};
          12'h1E4: rd_data <= {24'd0, inflight1};
          12'h1E8: rd_data <= {20'd0, credits1};
          12'h1EC: rd_data <= ssd_issued1;
          12'h1F0: rd_data <= ssd_comp1;
          12'h1F4: rd_data <= ssd_err1;
          12'h1F8: rd_data <= {24'd0, infl_hwm1};
          12'h200: begin rd_data <= filled_cnt;  hi_latch <= 32'd0; end
          12'h208: begin rd_data <= issued_cnt;  hi_latch <= 32'd0; end
          12'h210: begin rd_data <= cmds_done[31:0]; hi_latch <= cmds_done[63:32]; end
          12'h218: rd_data <= cmd_errors;
          12'h21C: rd_data <= unexpected;
          12'h220: begin
                     if (c_play) begin rd_data <= rd_bytes[31:0]; hi_latch <= rd_bytes[63:32]; end
                     else begin rd_data <= {wr_run_beats[27:0], 4'd0}; hi_latch <= wr_run_beats[59:28]; end
                   end
          12'h228: rd_data <= ring_fill;
          12'h22C: rd_data <= ring_hwm;
          12'h230: rd_data <= err_last_status;
          12'h234: rd_data <= err_last_cid;
          12'h238: begin rd_data <= c_play ? rd_cnt : cmp_cnt; hi_latch <= 32'd0; end
          12'h240: rd_data <= wr_pad_bytes;
          12'h248: begin rd_data <= wr_full_cycles[31:0]; hi_latch <= wr_full_cycles[63:32]; end
          12'h250: begin rd_data <= run_drops[31:0]; hi_latch <= run_drops[63:32]; end
          12'h258: rd_data <= run_hwm;
          12'h280: rd_data <= lat_min;
          12'h284: rd_data <= lat_max;
          12'h288: rd_data <= lat_cnt;
          12'h290: begin rd_data <= lat_sum[31:0]; hi_latch <= lat_sum[63:32]; end
          12'h380: rd_data <= db_count;
          12'h384: rd_data <= {29'd0, db_next};
          default: rd_data <= 32'd0;
        endcase
      end
    end
  end

endmodule
