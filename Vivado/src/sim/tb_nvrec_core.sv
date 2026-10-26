// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_nvrec_core -- self-checking testbench for nvrec_core: ring writer,
// command builder (nvrec_cmd), completion router (nvrec_cq), ring reader
// (nvrec_rd), command injector (nvrec_inj), registers.
//
// Runs for DATA_WIDTH 128, 256 and 512 with two ring ports (N_RING_PORTS 2,
// register map 1.3) and once at 256 bits with N_RING_PORTS 1 (the 1.2
// single-ring engine; sim.tcl, see the sim_runs line below). The memory
// model keeps 16-byte words (any beat width), the FIFOs are 64 KB deep at
// every width and the TPG / checker rates are scaled so that the byte rates
// are the same in every run.
//
//   fdrec_tpg (src_clk 200 MHz) -> nvrec_core -> two AXI4 memory ports (dp_clk 250 MHz)
//   nvrec_core m_axis_sqe -> NVMe Host Accelerator + SSD behavioural model
//                            -> s_axis_cqe (completions, random delay, OUT OF ORDER)
//   nvrec_core m_axis_snk -> fdrec_check (playback)
//
// The SSD model checks every SQE field against the expected value for the
// chunk (opcode, NSID, CID = slot, PRP1, PRP2 / PRP list, SLBA for 1- and
// 2-member md RAID0 stripes, NLB, FUA, tuser SSD/SQ), gathers the data
// through PRP1 + the PRP list at COMPLETION time (so a slot that the ring
// writer overwrote before its in-order release would be caught) and keeps
// it as the "disk"; Read commands scatter the disk data into DDR. The DDR
// model also flags any write into a slot whose command has not completed.
//
// Memory model: one sparse memory (the bus address space), two AXI4 slave
// ports with DIFFERENT latencies (port 0: R 8 / B 4 cycles, port 1: R 64 / B
// 32 cycles), random ready/valid stalls and random pauses of 50-300 cycles,
// so the two ports answer out of order relative to each other. Every burst
// is checked against the reference ring address function (port = memory of
// the address, inside that memory's part of the ring, never across 4 KB);
// the SSD model checks PRP1 / PRP2 / PRP lists against the same function.
//
// Tests:
//   0. register identification / reset values
//   1. record, 1 member, LENGTH_CHUNKS = 24, 8-slot ring, OOO completions
//   2. record, 2-member stripe, START_CHUNK = 3, STOP with partial chunk,
//      injector SQEs to both SSDs interleaved with the builder
//   3. playback of test 1's recording into fdrec_check (no errors / gaps)
//   4. CQE error status + unexpected CQE + IRQ
//   5. ring stress: slow SSDs (long, out-of-order completions), 4-slot ring
//      kept full, ingest drops -- the DDR model proves no slot is rewritten
//      before its command completed (in-order release)
//   6. counter clear rules: SSD_ISSUED / SSD_COMPLETED and INJ_SUBMITTED /
//      INJ_COMPLETED are cleared together by SOFT_RST (regression: the issue
//      counters used to survive it), RUN_FIFO_HWM vs ING_FIFO_HWM
//   7. HA_DEAD input: STATE bit 12, IRQ_STATUS bit 6 (W1C), irq output
//   8. CONFIG.DRY (fabric-only): record until STOP over a wrapping ring with
//      no SSD command (slots released as filled, BYTES = TPG words x 16),
//      then a DRY record of exactly NUM_CHUNKS chunks played back from the
//      ring (ring-resident) into fdrec_check: no Read command, no error/gap
//   Split ring (1.3, N_RING_PORTS = 2), 128 KB chunks, 7-slot ring (odd: at
//   S = chunk memory 0 holds one slot more), for RING_STRIPE_SHIFT 12, 16 and
//   17 (= chunk):
//   9. split record, 2-member stripe, START_CHUNK 5 (odd), OOO completions,
//      STOP with a 2-page partial last chunk (PRP2 = ADDR(slot, 4096));
//      per-port WR_PORT_STALL counters
//  10. split playback of that recording (LAST_CHUNK_BYTES = 2 pages) into
//      fdrec_check; RD_PORT_WAIT counters
//  11. split DRY record of NUM_CHUNKS chunks + ring-resident playback, ring
//      memory compared word by word with the reference address function
//  12. CONFIG.MEM1: single ring at RING_BASE1, all bursts on port 1
//  13. (N_RING_PORTS = 1) RING_PORTS = 1, SPLIT / MEM1 ignored: single ring at
//      RING_BASE on port 0, STATE.MEM1_READY = 0
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).
//
//  14. (N_RING_PORTS = 2) chunk-sized stripes with NoC-like ports (read
//      latency 200 / 250 dp_clk cycles = 0.8 / 1.0 us, a read-response buffer
//      of 4 bursts per port, 95 % ready / R valid): DRY record at the source
//      maximum (one beat per src_clk) and ring-resident playback
//      into a full-rate checker; the reader's waits and the writer's stalls are
//      booked to chunk boundaries vs the rest, and the sink must never starve
//      (with the reader's skid FIFOs; RD_SKID_DEPTH=0 reproduces the 1.3
//      first-build reader for A/B runs, reported but not checked)
//
// sim_runs: DATA_WIDTH=128 DATA_WIDTH=256 DATA_WIDTH=512 DATA_WIDTH=256,N_RING_PORTS=1

`timescale 1ns / 1ps

module tb_nvrec_core #(
  parameter integer DATA_WIDTH = 256,
  parameter integer N_RING_PORTS = 2,
  parameter integer RD_SKID_DEPTH = 512,  // ring reader skid FIFO per port (0 = none, for A/B runs)
  parameter integer RD_RQ_DEPTH = 0,      // ring reader bursts in flight (0 = RTL default)
  parameter integer EGR_KB = 64           // egress FIFO size (the reference designs: 128 / 256)
);

  localparam integer BB         = DATA_WIDTH / 8;      // bytes per beat
  localparam integer WPB        = DATA_WIDTH / 128;    // pattern words per beat
  localparam integer BEAT_SHIFT = (DATA_WIDTH == 512) ? 6 : (DATA_WIDTH == 256) ? 5 : 4;
  localparam integer FDEPTH     = 65536 / BB;          // ingest FIFO, 64 KB
  localparam integer EDEPTH     = EGR_KB * 1024 / BB;  // egress FIFO, 64 KB by default
  localparam integer SLOT_W     = 12;
  localparam integer TWO        = (N_RING_PORTS == 2);

  // TPG / checker rate for the same byte rate at every width (r = 128-bit value)
  function automatic [31:0] rate(input [31:0] r);
    return r / WPB;
  endfunction

  // ---------------------------------------------------------------------------
  // Clocks / resets
  // ---------------------------------------------------------------------------
  reg src_clk = 1'b0, dp_clk = 1'b0;
  reg src_resetn = 1'b0, dp_resetn = 1'b0;
  always #2.5 src_clk = ~src_clk;
  initial begin #1.3; forever #2.0 dp_clk = ~dp_clk; end

  integer errors = 0;
  task automatic fail(input string msg);
    begin
      $display("FAIL: %s (t=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // DUT + source + sink
  // ---------------------------------------------------------------------------
  wire [DATA_WIDTH-1:0] src_tdata;   wire src_tvalid, src_tready;
  wire tpg_enable, tpg_seq_rst; wire [31:0] tpg_rate_inc; wire [63:0] tpg_seq_next;
  wire [DATA_WIDTH-1:0] snk_tdata;   wire snk_tlast, snk_tvalid, snk_tready;
  wire chk_enable, chk_reset; wire [31:0] chk_rate_inc;
  wire [63:0] chk_beats, chk_errors, chk_gaps, chk_gap_beats, chk_underflows, chk_last_seq;

  fdrec_tpg #(.DATA_WIDTH(DATA_WIDTH)) tpg (.src_clk(src_clk), .src_resetn(src_resetn), .tpg_enable(tpg_enable),
    .tpg_seq_rst(tpg_seq_rst), .tpg_rate_inc(tpg_rate_inc), .tpg_seq_next(tpg_seq_next),
    .m_axis_tdata(src_tdata), .m_axis_tvalid(src_tvalid), .m_axis_tready(src_tready));

  fdrec_check #(.DATA_WIDTH(DATA_WIDTH)) chk (.snk_clk(src_clk), .snk_resetn(src_resetn), .chk_enable(chk_enable),
    .chk_reset(chk_reset), .chk_rate_inc(chk_rate_inc), .chk_beats(chk_beats),
    .chk_errors(chk_errors), .chk_gaps(chk_gaps), .chk_gap_beats(chk_gap_beats),
    .chk_underflows(chk_underflows), .chk_last_seq(chk_last_seq),
    .s_axis_tdata(snk_tdata), .s_axis_tlast(snk_tlast), .s_axis_tvalid(snk_tvalid),
    .s_axis_tready(snk_tready));

  // AXI-Lite
  reg  [11:0] l_awaddr = 0, l_araddr = 0;
  reg         l_awvalid = 0, l_wvalid = 0, l_bready = 0, l_arvalid = 0, l_rready = 0;
  reg  [31:0] l_wdata = 0;
  wire        l_awready, l_wready, l_bvalid, l_arready, l_rvalid;
  wire [1:0]  l_bresp, l_rresp;
  wire [31:0] l_rdata;

  // AXI4 ring ports p = 0 (m_axi) and 1 (m_axi1), as arrays for the model
  wire [63:0] awaddr [0:1], araddr [0:1];
  wire [7:0]  awlen [0:1], arlen [0:1];
  wire [2:0]  awsize [0:1], arsize [0:1], awprot [0:1], arprot [0:1];
  wire [1:0]  awburst [0:1], arburst [0:1];
  wire [3:0]  awcache [0:1], arcache [0:1];
  wire        awvalid [0:1], wvalid [0:1], wlast [0:1], bready [0:1], arvalid [0:1], rready [0:1];
  reg         awready [0:1], wready [0:1], bvalid [0:1], arready [0:1], rvalid [0:1], rlast [0:1];
  wire [DATA_WIDTH-1:0] wdata [0:1];
  wire [BB-1:0] wstrb [0:1];
  reg  [DATA_WIDTH-1:0] rdata [0:1];
  reg  [1:0]  bresp [0:1], rresp [0:1];
  reg         mem1_ready_in = 1'b1;
  initial begin
    for (int p = 0; p < 2; p++) begin
      awready[p] = 0; wready[p] = 0; bvalid[p] = 0; arready[p] = 0; rvalid[p] = 0; rlast[p] = 0;
      rdata[p] = 0; bresp[p] = 0; rresp[p] = 0;
    end
  end

  // SQ / CQ streams
  wire [511:0] sqe_tdata; wire [63:0] sqe_tkeep; wire [15:0] sqe_tuser; wire sqe_tvalid;
  reg          sqe_tready = 0;
  reg  [127:0] cqe_tdata = 0; reg [15:0] cqe_tuser = 0; reg cqe_tvalid = 0;
  wire         cqe_tready;
  wire         irq;
  reg          ha_dead_in = 1'b0;

  nvrec_core #(.DATA_WIDTH(DATA_WIDTH), .SRC_CLK_HZ(200000000), .DP_CLK_HZ(250000000),
               .FIFO_DEPTH(FDEPTH), .EGR_FIFO_DEPTH(EDEPTH), .SLOT_W(SLOT_W),
               .N_RING_PORTS(N_RING_PORTS), .RD_SKID_DEPTH(RD_SKID_DEPTH), .RD_RQ_DEPTH(RD_RQ_DEPTH)) dut (
    .src_clk(src_clk), .src_resetn(src_resetn), .dp_clk(dp_clk), .dp_resetn(dp_resetn),
    .s_axis_tdata(src_tdata), .s_axis_tvalid(src_tvalid), .s_axis_tready(src_tready),
    .m_axis_snk_tdata(snk_tdata), .m_axis_snk_tlast(snk_tlast), .m_axis_snk_tvalid(snk_tvalid),
    .m_axis_snk_tready(snk_tready),
    .s_axi_awaddr(l_awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(l_awvalid), .s_axi_awready(l_awready),
    .s_axi_wdata(l_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(l_wvalid), .s_axi_wready(l_wready),
    .s_axi_bresp(l_bresp), .s_axi_bvalid(l_bvalid), .s_axi_bready(l_bready),
    .s_axi_araddr(l_araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(l_arvalid), .s_axi_arready(l_arready),
    .s_axi_rdata(l_rdata), .s_axi_rresp(l_rresp), .s_axi_rvalid(l_rvalid), .s_axi_rready(l_rready),
    .m_axi_awaddr(awaddr[0]), .m_axi_awlen(awlen[0]), .m_axi_awsize(awsize[0]), .m_axi_awburst(awburst[0]),
    .m_axi_awcache(awcache[0]), .m_axi_awprot(awprot[0]), .m_axi_awvalid(awvalid[0]), .m_axi_awready(awready[0]),
    .m_axi_wdata(wdata[0]), .m_axi_wstrb(wstrb[0]), .m_axi_wlast(wlast[0]), .m_axi_wvalid(wvalid[0]),
    .m_axi_wready(wready[0]), .m_axi_bresp(bresp[0]), .m_axi_bvalid(bvalid[0]), .m_axi_bready(bready[0]),
    .m_axi_araddr(araddr[0]), .m_axi_arlen(arlen[0]), .m_axi_arsize(arsize[0]), .m_axi_arburst(arburst[0]),
    .m_axi_arcache(arcache[0]), .m_axi_arprot(arprot[0]), .m_axi_arvalid(arvalid[0]), .m_axi_arready(arready[0]),
    .m_axi_rdata(rdata[0]), .m_axi_rresp(rresp[0]), .m_axi_rlast(rlast[0]), .m_axi_rvalid(rvalid[0]),
    .m_axi_rready(rready[0]),
    .m_axi1_awaddr(awaddr[1]), .m_axi1_awlen(awlen[1]), .m_axi1_awsize(awsize[1]), .m_axi1_awburst(awburst[1]),
    .m_axi1_awcache(awcache[1]), .m_axi1_awprot(awprot[1]), .m_axi1_awvalid(awvalid[1]), .m_axi1_awready(awready[1]),
    .m_axi1_wdata(wdata[1]), .m_axi1_wstrb(wstrb[1]), .m_axi1_wlast(wlast[1]), .m_axi1_wvalid(wvalid[1]),
    .m_axi1_wready(wready[1]), .m_axi1_bresp(bresp[1]), .m_axi1_bvalid(bvalid[1]), .m_axi1_bready(bready[1]),
    .m_axi1_araddr(araddr[1]), .m_axi1_arlen(arlen[1]), .m_axi1_arsize(arsize[1]), .m_axi1_arburst(arburst[1]),
    .m_axi1_arcache(arcache[1]), .m_axi1_arprot(arprot[1]), .m_axi1_arvalid(arvalid[1]), .m_axi1_arready(arready[1]),
    .m_axi1_rdata(rdata[1]), .m_axi1_rresp(rresp[1]), .m_axi1_rlast(rlast[1]), .m_axi1_rvalid(rvalid[1]),
    .m_axi1_rready(rready[1]),
    .mem1_ready(mem1_ready_in),
    .m_axis_sqe_tdata(sqe_tdata), .m_axis_sqe_tkeep(sqe_tkeep), .m_axis_sqe_tuser(sqe_tuser),
    .m_axis_sqe_tvalid(sqe_tvalid), .m_axis_sqe_tready(sqe_tready),
    .s_axis_cqe_tdata(cqe_tdata), .s_axis_cqe_tkeep(16'hFFFF), .s_axis_cqe_tuser(cqe_tuser),
    .s_axis_cqe_tvalid(cqe_tvalid), .s_axis_cqe_tready(cqe_tready),
    .s_axi_db_awid(1'b0), .s_axi_db_awaddr(32'd0), .s_axi_db_awlen(8'd0), .s_axi_db_awsize(3'd2),
    .s_axi_db_awburst(2'd1), .s_axi_db_awlock(1'b0), .s_axi_db_awcache(4'd0), .s_axi_db_awprot(3'd0),
    .s_axi_db_awvalid(1'b0), .s_axi_db_awready(), .s_axi_db_wdata(32'd0), .s_axi_db_wstrb(4'hF),
    .s_axi_db_wlast(1'b1), .s_axi_db_wvalid(1'b0), .s_axi_db_wready(), .s_axi_db_bid(),
    .s_axi_db_bresp(), .s_axi_db_bvalid(), .s_axi_db_bready(1'b1), .s_axi_db_arid(1'b0),
    .s_axi_db_araddr(32'd0), .s_axi_db_arlen(8'd0), .s_axi_db_arsize(3'd2), .s_axi_db_arburst(2'd1),
    .s_axi_db_arlock(1'b0), .s_axi_db_arcache(4'd0), .s_axi_db_arprot(3'd0), .s_axi_db_arvalid(1'b0),
    .s_axi_db_arready(), .s_axi_db_rid(), .s_axi_db_rdata(), .s_axi_db_rresp(), .s_axi_db_rlast(),
    .s_axi_db_rvalid(), .s_axi_db_rready(1'b1),
    .m_axi_db_awid(), .m_axi_db_awaddr(), .m_axi_db_awlen(), .m_axi_db_awsize(), .m_axi_db_awburst(),
    .m_axi_db_awlock(), .m_axi_db_awcache(), .m_axi_db_awprot(), .m_axi_db_awvalid(),
    .m_axi_db_awready(1'b1), .m_axi_db_wdata(), .m_axi_db_wstrb(), .m_axi_db_wlast(),
    .m_axi_db_wvalid(), .m_axi_db_wready(1'b1), .m_axi_db_bid(1'b0), .m_axi_db_bresp(2'd0),
    .m_axi_db_bvalid(1'b0), .m_axi_db_bready(), .m_axi_db_arid(), .m_axi_db_araddr(),
    .m_axi_db_arlen(), .m_axi_db_arsize(), .m_axi_db_arburst(), .m_axi_db_arlock(),
    .m_axi_db_arcache(), .m_axi_db_arprot(), .m_axi_db_arvalid(), .m_axi_db_arready(1'b1),
    .m_axi_db_rid(1'b0), .m_axi_db_rdata(32'd0), .m_axi_db_rresp(2'd0), .m_axi_db_rlast(1'b0),
    .m_axi_db_rvalid(1'b0), .m_axi_db_rready(),
    .irq(irq),
    .tpg_enable(tpg_enable), .tpg_seq_rst(tpg_seq_rst), .tpg_rate_inc(tpg_rate_inc),
    .tpg_seq_next(tpg_seq_next),
    .chk_enable(chk_enable), .chk_reset(chk_reset), .chk_rate_inc(chk_rate_inc),
    .chk_beats(chk_beats), .chk_errors(chk_errors), .chk_gaps(chk_gaps),
    .chk_gap_beats(chk_gap_beats), .chk_underflows(chk_underflows), .chk_last_seq(chk_last_seq),
    .ha_dead(ha_dead_in));

  // ---------------------------------------------------------------------------
  // AXI-Lite BFM
  // ---------------------------------------------------------------------------
  task automatic wr32(input [11:0] a, input [31:0] d);
    begin
      @(posedge dp_clk);
      l_awaddr <= a; l_awvalid <= 1; l_wdata <= d; l_wvalid <= 1; l_bready <= 1;
      @(posedge dp_clk);
      while (!(l_awready && l_wready)) @(posedge dp_clk);
      l_awvalid <= 0; l_wvalid <= 0;
      while (!l_bvalid) @(posedge dp_clk);
      @(posedge dp_clk);
      l_bready <= 0;
    end
  endtask

  task automatic rd32(input [11:0] a, output [31:0] d);
    begin
      @(posedge dp_clk);
      l_araddr <= a; l_arvalid <= 1; l_rready <= 1;
      @(posedge dp_clk);
      while (!l_arready) @(posedge dp_clk);
      l_arvalid <= 0;
      while (!l_rvalid) @(posedge dp_clk);
      d = l_rdata;
      @(posedge dp_clk);
      l_rready <= 0;
    end
  endtask

  task automatic rd64(input [11:0] a, output [63:0] d);
    reg [31:0] lo, hi;
    begin
      rd32(a, lo); rd32(a + 12'h4, hi); d = {hi, lo};
    end
  endtask

  task automatic expect32(input [11:0] a, input [31:0] e, input string what);
    reg [31:0] v;
    begin
      rd32(a, v);
      if (v !== e) fail($sformatf("%s: reg 0x%03h = 0x%08h, expected 0x%08h", what, a, v, e));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test configuration shared with the models
  // ---------------------------------------------------------------------------
  longint cfg_ring_base, cfg_prp_base, cfg_start_chunk;
  longint cfg_ring_base1 = 64'h0000_0020_0001_3000;
  int     cfg_chunk_shift, cfg_lba_shift, cfg_num_chunks, cfg_prp_shift, cfg_two;
  int     cfg_play, cfg_fua, cfg_dry = 0;
  int     cfg_split = 0, cfg_mem1 = 0, cfg_stripe = 12;   // 1.3
  int     n_2page = 0;         // builder SQEs of exactly 2 pages seen by the SSD model
  int     n_aw [2] = '{0, 0}, n_ar [2] = '{0, 0};          // bursts per ring port
  longint cfg_lba [2];
  int     cfg_nsid [2];
  int     cfg_ssd [2];
  int     cfg_sq [2];
  bit     allow_pad = 0;       // the last write of a run may be zero padded
  bit     seq_check = 1;       // compare written data with the TPG sequence
  int     err_at_chunk = -1;   // chunk whose CQE gets an error status
  int     dmin = 20, dmax = 3000;
  int     exp_c = 0;           // next expected builder chunk (run index)
  longint seq_base = 0;        // TPG sequence number of chunk 0's first beat

  // ---------------------------------------------------------------------------
  // Reference ring address function (include/nvrec_regs.h "Ring addresses")
  // ---------------------------------------------------------------------------
  function automatic bit split_eff();
    return TWO && (cfg_split != 0);
  endfunction
  function automatic int mem1_eff();
    return (TWO && (cfg_mem1 != 0) && (cfg_split == 0)) ? 1 : 0;
  endfunction
  function automatic int stripe_eff();      // as latched: 12 .. chunk_shift
    return (cfg_stripe < 12) ? 12 : ((cfg_stripe > cfg_chunk_shift) ? cfg_chunk_shift : cfg_stripe);
  endfunction
  function automatic longint base_of(int r);
    longint b;
    b = r ? cfg_ring_base1 : cfg_ring_base;
    return {b[63:12], 12'd0};
  endfunction
  function automatic longint ring_bytes();
    return longint'(cfg_num_chunks) << cfg_chunk_shift;
  endfunction
  // bytes of the ring in memory r
  function automatic longint half_bytes(int r);
    longint st; int S;
    S = stripe_eff();
    st = ring_bytes() >> S;
    return ((st + 1 - r) >> 1) << S;
  endfunction
  function automatic longint ring_addr(longint g);
    longint i; int S;
    if (split_eff()) begin
      S = stripe_eff();
      i = g >> S;
      return base_of(int'(i & 1)) + ((i >> 1) << S) + (g & ((longint'(1) << S) - 1));
    end
    return base_of(mem1_eff()) + g;
  endfunction
  // ring byte offset of bus address a on port p; -1 if a burst of nb bytes
  // there is not inside port p's part of the ring
  function automatic longint ring_g(int p, longint a, longint nb);
    longint off; int S;
    if (a < base_of(p)) return -1;
    off = a - base_of(p);
    if (split_eff()) begin
      S = stripe_eff();
      if (off + nb > half_bytes(p)) return -1;
      return ((((off >> S) << 1) | p) << S) | (off & ((longint'(1) << S) - 1));
    end
    if (p != mem1_eff()) return -1;
    if (off + nb > ring_bytes()) return -1;
    return off;
  endfunction

  // ---------------------------------------------------------------------------
  // Memory model: two AXI4 slave ports on one sparse memory
  // ---------------------------------------------------------------------------
  reg [127:0] mem [longint];    // 16-byte words, keyed by byte address
  bit slot_busy [1 << SLOT_W];   // write command in flight on this slot
  longint cyc = 0;
  always @(posedge dp_clk) cyc <= cyc + 1;

  typedef struct { longint addr; int len; longint t; } burst_t;

  // Memory model mode: 0 = stress model of tests 0-13 (fixed latencies 8 / 64
  // and 4 / 32 cycles, ready 1/2 .. 5/6, pauses of 50-300 cycles); 1 = NoC-like
  // model of test 14, shaped like a NoC master port: up to 32 read bursts
  // accepted (tracker), but a burst is only fetched from memory (read latency
  // mm_lat_r from then on) while fewer than mm_rrob bursts are fetched and not
  // yet returned (a read-response buffer that frees only when the data leaves
  // on R), so a port whose R channel is held fetches at most mm_rrob bursts
  // ahead; B after mm_lat_b; ready / R-valid probabilities mm_rdy_pct /
  // mm_rv_pct %; no pauses.
  int mm_mode = 0;
  int mm_lat_r [2] = '{200, 250};
  int mm_lat_b [2] = '{100, 120};
  int mm_rdy_pct = 95, mm_rv_pct = 95, mm_rrob = 4;

  genvar gp;
  generate for (gp = 0; gp < 2; gp++) begin : g_mem
    int LAT_R, LAT_B;                           // cycles from AR to the first R beat / WLAST to B
    burst_t awq [$], arq [$];
    reg [DATA_WIDTH:0] wbq [$];
    longint bq_t [$];
    longint wa; int wb, wl; bit wact = 0;
    longint ra; int rb, rl; bit ract = 0;
    int pause = 0;
    int nfetch = 0;                             // mm_mode: bursts at the head of arq already fetched

    always @(posedge dp_clk) begin
      LAT_R = mm_mode ? mm_lat_r[gp] : (gp ? 64 : 8);
      LAT_B = mm_mode ? mm_lat_b[gp] : (gp ? 32 : 4);
      if (mm_mode) begin
        pause = 0;
        awready[gp] <= ($urandom_range(99) < mm_rdy_pct);
        wready[gp]  <= ($urandom_range(99) < mm_rdy_pct);
        arready[gp] <= ($urandom_range(99) < mm_rdy_pct) &&
                       (arq.size() < 32 - (arvalid[gp] && arready[gp] ? 1 : 0));
      end else begin
      if (pause > 0) pause--;
      else if ($urandom_range(gp ? 400 : 1500) == 0) pause = $urandom_range(300, 50);
      awready[gp] <= (pause == 0) && ($urandom_range(3) >= gp + 1);   // 3/4, 1/2
      wready[gp]  <= (pause == 0) && ($urandom_range(5) >= gp + 1);   // 5/6, 2/3
      arready[gp] <= (pause == 0) && ($urandom_range(2) != 0);
      end
      if (awvalid[gp] && awready[gp]) begin
        burst_t b; longint g;
        b.addr = awaddr[gp]; b.len = awlen[gp] + 1; b.t = 0;
        if (awburst[gp] != 2'b01 || awsize[gp] != BEAT_SHIFT) fail("AW not INCR / BEAT_BYTES");
        if ((awaddr[gp][11:0] + b.len * BB) > 4096) fail("AW crosses 4 KB");
        g = ring_g(gp, b.addr, b.len * BB);
        if (g < 0)
          fail($sformatf("AW port %0d addr %h len %0d outside the port's part of the ring", gp, b.addr, b.len));
        else if (slot_busy[g >> cfg_chunk_shift])
          fail($sformatf("ring writer overwrote slot %0d before its command completed", g >> cfg_chunk_shift));
        awq.push_back(b);
        n_aw[gp]++;
      end
      if (wvalid[gp] && wready[gp]) begin
        if (wstrb[gp] != {BB{1'b1}}) fail("WSTRB");
        wbq.push_back({wlast[gp], wdata[gp]});
      end
      while (wbq.size() > 0 && (wact || awq.size() > 0)) begin
        if (!wact) begin wa = awq[0].addr; wl = awq[0].len; wb = 0; wact = 1; void'(awq.pop_front()); end
        for (int w = 0; w < WPB; w++) mem[wa + wb * BB + w * 16] = wbq[0][128*w +: 128];
        if (wbq[0][DATA_WIDTH] != (wb == wl - 1)) fail($sformatf("WLAST port %0d", gp));
        wb++;
        if (wbq[0][DATA_WIDTH]) begin wact = 0; bq_t.push_back(cyc + LAT_B); end
        void'(wbq.pop_front());
      end
      if (bvalid[gp] && bready[gp]) bvalid[gp] <= 0;
      else if (!bvalid[gp] && bq_t.size() > 0 && bq_t[0] <= cyc && pause == 0 && $urandom_range(2) == 0) begin
        bvalid[gp] <= 1; void'(bq_t.pop_front());
      end
      // reads
      if (arvalid[gp] && arready[gp]) begin
        burst_t b;
        b.addr = araddr[gp]; b.len = arlen[gp] + 1; b.t = mm_mode ? -1 : cyc + LAT_R;
        if (arburst[gp] != 2'b01 || arsize[gp] != BEAT_SHIFT) fail("AR not INCR / BEAT_BYTES");
        if ((araddr[gp][11:0] + b.len * BB) > 4096) fail("AR crosses 4 KB");
        if (ring_g(gp, b.addr, b.len * BB) < 0)
          fail($sformatf("AR port %0d addr %h len %0d outside the port's part of the ring", gp, b.addr, b.len));
        arq.push_back(b);
        n_ar[gp]++;
      end
      if (mm_mode) begin
        // fetch while the read-response buffer has room
        while (nfetch < arq.size() && (nfetch + (ract ? 1 : 0)) < mm_rrob) begin
          arq[nfetch].t = cyc + LAT_R;
          nfetch++;
        end
      end else begin
        nfetch = 0;
      end
      if (rvalid[gp] && rready[gp]) begin
        rb++;
        if (rb == rl) ract = 0;
      end
      if (!ract && arq.size() > 0 && arq[0].t >= 0 && arq[0].t <= cyc) begin
        ra = arq[0].addr; rl = arq[0].len; rb = 0; ract = 1; void'(arq.pop_front());
        if (nfetch > 0) nfetch--;
      end
      if (ract && (!rvalid[gp] || rready[gp]) && pause == 0 &&
          (mm_mode ? ($urandom_range(99) < mm_rv_pct) : ($urandom_range(3) >= gp + 1))) begin
        rvalid[gp] <= 1;
        for (int w = 0; w < WPB; w++)
          rdata[gp][128*w +: 128] <= mem.exists(ra + rb * BB + w * 16) ? mem[ra + rb * BB + w * 16] : 128'hDEAD;
        rlast[gp]  <= (rb == rl - 1);
        rresp[gp]  <= 0;
      end else if (rvalid[gp] && rready[gp]) begin
        rvalid[gp] <= 0;
      end
    end
  end endgenerate

  // ---------------------------------------------------------------------------
  // NVMe Host Accelerator + SSD model
  // ---------------------------------------------------------------------------
  typedef struct {
    bit      inj;
    int      ssd;
    int      cid;
    int      opc;
    int      nsid;
    longint  prp1, prp2, slba;
    int      nbytes;
    int      chunk;
    int      delay;
    int      status;
  } cmd_t;
  cmd_t pend [$];
  reg [127:0] disk [string];    // key "ssd:nsid:lba:beat"
  int outstanding [2] = '{0, 0};
  int n_bld_sqe = 0, n_inj_sqe = 0, n_cqe = 0, n_inj_cqe_model = 0;
  bit send_bogus = 0;

  function automatic string dkey(int ssd, int nsid, longint lba, int beat);
    return $sformatf("%0d:%0d:%0d:%0d", ssd, nsid, lba, beat);
  endfunction

  function automatic longint page_addr(cmd_t c, int p);   // address of page p of the command
    longint ent; reg [127:0] w; longint la;
    if (p == 0) return c.prp1;
    if (c.nbytes <= 8192) return c.prp2;                    // 2 pages: PRP2 = page 1
    la = c.prp2 + (p - 1) * 8;                              // list entry (no chaining in the tests)
    w  = mem.exists({la[63:4], 4'd0}) ? mem[{la[63:4], 4'd0}] : 128'd0;
    ent = la[3] ? w[127:64] : w[63:0];
    return ent;
  endfunction

  // check an SQE from the builder against the expected values of chunk exp_c
  task automatic check_bld_sqe(cmd_t c, int tuser_ssd, int tuser_sq);
    longint a, m, row, exp_lba, exp_prp1, exp_prp2; int slot, len, pages;
    begin
      a     = cfg_start_chunk + exp_c;
      m     = cfg_two ? (a % 2) : 0;
      row   = cfg_two ? (a / 2) : a;
      slot  = exp_c % cfg_num_chunks;
      exp_lba  = cfg_lba[m] + (row << (cfg_chunk_shift - cfg_lba_shift));
      exp_prp1 = ring_addr(longint'(slot) << cfg_chunk_shift);
      len   = c.nbytes;
      pages = (len + 4095) / 4096;
      exp_prp2 = (pages > 2) ? ({cfg_prp_base[63:12], 12'd0} + (longint'(slot) << cfg_prp_shift)) :
                 (pages == 2) ? ring_addr((longint'(slot) << cfg_chunk_shift) + 4096) : 0;
      if (pages == 2) n_2page++;
      if (c.opc != (cfg_play ? 2 : 1)) fail($sformatf("chunk %0d opcode %0d", exp_c, c.opc));
      if (c.cid != slot) fail($sformatf("chunk %0d CID %0d expected slot %0d", exp_c, c.cid, slot));
      if (c.nsid != cfg_nsid[m]) fail($sformatf("chunk %0d NSID %0d", exp_c, c.nsid));
      if (tuser_ssd != cfg_ssd[m] || tuser_sq != cfg_sq[m])
        fail($sformatf("chunk %0d tuser ssd %0d sq %0d", exp_c, tuser_ssd, tuser_sq));
      if (c.prp1 != exp_prp1) fail($sformatf("chunk %0d PRP1 %h exp %h", exp_c, c.prp1, exp_prp1));
      if (c.prp2 != exp_prp2) fail($sformatf("chunk %0d PRP2 %h exp %h", exp_c, c.prp2, exp_prp2));
      if (c.slba != exp_lba) fail($sformatf("chunk %0d SLBA %0d exp %0d", exp_c, c.slba, exp_lba));
      if (!allow_pad && len != (1 << cfg_chunk_shift))
        fail($sformatf("chunk %0d length %0d", exp_c, len));
      if (len % (1 << cfg_lba_shift) != 0) fail("length not a whole LBA");
    end
  endtask

  // data movement at completion time
  task automatic complete_data(cmd_t c);
    int nb, k, p; longint a, s; reg [127:0] d; bit padding;
    begin
      nb = c.nbytes / 16;
      padding = 0;
      for (k = 0; k < nb; k++) begin
        p = k / 256;
        a = page_addr(c, p) + (k % 256) * 16;
        if (c.opc == 1) begin
          d = mem.exists(a) ? mem[a] : 128'hX;
          s = seq_base + longint'(c.chunk) * ((1 << cfg_chunk_shift) / 16) + k;
          if (!seq_check) begin
            // data not predictable (drops): only the slot-overwrite check applies
          end else if (!padding && d !== {~s[63:0], s[63:0]}) begin
            if (allow_pad && d === 128'd0) padding = 1;
            else begin
              fail($sformatf("write chunk %0d beat %0d: data %h exp seq %0d", c.chunk, k, d, s));
              break;
            end
          end else if (padding && d !== 128'd0) begin
            fail($sformatf("write chunk %0d beat %0d: nonzero after padding", c.chunk, k));
            break;
          end
          disk[dkey(c.ssd, c.nsid, c.slba, k)] = d;
        end else if (c.opc == 2) begin
          string key; key = dkey(c.ssd, c.nsid, c.slba, k);
          // the disk is stored per command start LBA and beat (same geometry in the tests)
          if (!disk.exists(key)) begin fail($sformatf("read of unwritten data %s", key)); break; end
          mem[a] = disk[key];
        end
      end
    end
  endtask

  int pick;
  always @(posedge dp_clk) begin
    sqe_tready <= ($urandom_range(3) != 0);
    // SQE intake
    if (sqe_tvalid && sqe_tready) begin
      cmd_t c; int tssd, tsq;
      if (sqe_tkeep != {64{1'b1}}) fail("SQE tkeep");
      tssd = sqe_tuser[13:9]; tsq = sqe_tuser[5:0];
      if (sqe_tuser[15:14] != 0 || sqe_tuser[8:6] != 0) fail("SQE tuser reserved bits");
      c.opc  = sqe_tdata[7:0];
      c.cid  = sqe_tdata[31:16];
      c.nsid = sqe_tdata[63:32];
      c.prp1 = sqe_tdata[255:192];
      c.prp2 = sqe_tdata[319:256];
      c.slba = sqe_tdata[383:320];
      c.nbytes = (sqe_tdata[399:384] + 1) << cfg_lba_shift;
      c.ssd  = tssd;
      c.inj  = sqe_tdata[31];
      c.status = 0;
      c.delay = $urandom_range(dmax, dmin);
      if (sqe_tdata[15:8] != 0) fail("SQE FUSE/PSDT not 0");
      if (sqe_tdata[191:64] != 0 || sqe_tdata[511:416] != 0) fail("SQE reserved dwords not 0");
      if (!c.inj && (sqe_tdata[414] != (cfg_fua && !cfg_play))) fail("FUA bit");
      outstanding[tssd & 1]++;
      if (outstanding[tssd & 1] > 63) fail("SQE pushed without credit (IP would discard it)");
      if (c.inj) begin
        n_inj_sqe++;
        c.chunk = -1;
      end else begin
        check_bld_sqe(c, tssd, tsq);
        c.chunk = exp_c;
        if (exp_c == err_at_chunk) c.status = 15'h0281;   // e.g. SCT 2 (media), SC 0x81
        exp_c++;
        n_bld_sqe++;
        if (c.opc == 1) slot_busy[c.cid] = 1;
      end
      pend.push_back(c);
    end
    // completion: pick a random expired command (out of order)
    foreach (pend[i]) if (pend[i].delay > 0) pend[i].delay--;
    if (cqe_tvalid && cqe_tready) cqe_tvalid <= 0;
    if (!cqe_tvalid || cqe_tready) begin
      int cands [$];
      cands = {};
      foreach (pend[i]) if (pend[i].delay == 0) cands.push_back(i);
      if (send_bogus) begin
        send_bogus = 0;
        cqe_tvalid <= 1;
        cqe_tdata  <= {15'd0, 1'b1, 16'd5, 16'd2, 16'd0, 64'd0};   // CID 5: not in flight
        cqe_tuser  <= {11'd0, 5'd0};
      end else if (cands.size() > 0 && $urandom_range(1) == 0) begin
        cmd_t c;
        pick = cands[$urandom_range(cands.size() - 1)];
        c = pend[pick];
        pend.delete(pick);
        if (!c.inj) complete_data(c);
        if (!c.inj && c.opc == 1) slot_busy[c.cid] = 0;
        outstanding[c.ssd & 1]--;
        cqe_tvalid <= 1;
        cqe_tdata  <= {c.status[14:0], 1'b1, c.cid[15:0], 16'd2, 16'd0, 64'd0};
        cqe_tuser  <= {11'd1, c.ssd[4:0]};
        n_cqe++;
        if (c.inj) n_inj_cqe_model++;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic soft_reset();
    reg [31:0] v;
    begin
      wr32(12'h00C, 1);
      v = 1;
      while (v[0]) rd32(12'h00C, v);
    end
  endtask

  // PRP lists for every slot: entries = pages 1..P-1 of the slot
  task automatic build_prp_lists();
    int s, p, P; longint la, pa; reg [127:0] w;
    begin
      P = (1 << cfg_chunk_shift) / 4096;
      for (s = 0; s < cfg_num_chunks; s++)
        for (p = 1; p < P; p++) begin
          la = {cfg_prp_base[63:12], 12'd0} + (longint'(s) << cfg_prp_shift) + (p - 1) * 8;
          pa = ring_addr((longint'(s) << cfg_chunk_shift) + p * 4096);
          w = mem.exists({la[63:4], 4'd0}) ? mem[{la[63:4], 4'd0}] : 128'd0;
          if (la[3]) w[127:64] = pa; else w[63:0] = pa;
          mem[{la[63:4], 4'd0}] = w;
        end
    end
  endtask

  task automatic configure(input int play);
    begin
      cfg_play = play;
      wr32(12'h104, (play ? 1 : 0) | (cfg_fua ? 2 : 0) | (cfg_dry ? 4 : 0) | ((cfg_two ? 2 : 1) << 4) |
                    (cfg_split ? 8 : 0) | (cfg_mem1 ? 32'h40 : 0));
      wr32(12'h120, cfg_ring_base[31:0]);   wr32(12'h124, cfg_ring_base[63:32]);
      wr32(12'h158, cfg_ring_base1[31:0]);  wr32(12'h15C, cfg_ring_base1[63:32]);
      wr32(12'h160, cfg_stripe);
      wr32(12'h128, cfg_num_chunks);
      wr32(12'h12C, 1 << cfg_chunk_shift);
      wr32(12'h130, cfg_prp_base[31:0]);    wr32(12'h134, cfg_prp_base[63:32]);
      wr32(12'h138, cfg_prp_shift);
      wr32(12'h13C, cfg_lba_shift);
      wr32(12'h140, cfg_start_chunk[31:0]); wr32(12'h144, cfg_start_chunk[63:32]);
      wr32(12'h180, cfg_nsid[0]); wr32(12'h184, cfg_ssd[0] | (cfg_sq[0] << 8));
      wr32(12'h188, cfg_lba[0][31:0]); wr32(12'h18C, cfg_lba[0][63:32]);
      wr32(12'h1A0, cfg_nsid[1]); wr32(12'h1A4, cfg_ssd[1] | (cfg_sq[1] << 8));
      wr32(12'h1A8, cfg_lba[1][31:0]); wr32(12'h1AC, cfg_lba[1][63:32]);
      build_prp_lists();
    end
  endtask

  task automatic wait_state(input int st, input int maxus);
    reg [31:0] v; int n;
    begin
      n = 0; v = 0;
      rd32(12'h108, v);
      while ((v[3:0] != st) && n < maxus) begin
        #1000; rd32(12'h108, v); n++;
      end
      if (v[3:0] != st) fail($sformatf("timeout waiting for state %0d (state %0d)", st, v[3:0]));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Split-ring tests (1.3)
  // ---------------------------------------------------------------------------
  // the 16-byte words of the ring, compared with the TPG sequence from seq 0
  task automatic check_ring_mem(input longint nbytes, input string what);
    longint g, a; reg [127:0] d; longint n;
    begin
      for (g = 0; g < nbytes; g += 16) begin
        a = ring_addr(g);
        n = g / 16;
        d = mem.exists(a) ? mem[a] : 128'hX;
        if (d !== {~n[63:0], n[63:0]}) begin
          fail($sformatf("%s: ring byte %0d at %h holds %h, expected word %0d", what, g, a, d, n));
          break;
        end
      end
    end
  endtask

  // poll the TPG word counter until >= words, at most maxus us
  task automatic wait_words(input longint words, input int maxus);
    reg [63:0] w; int n;
    begin
      n = 0; rd64(12'h018, w);
      while (w < words && n < maxus * 10) begin #100; rd64(12'h018, w); n++; end
      if (w < words) fail($sformatf("TPG did not reach %0d words (%0d)", words, w));
    end
  endtask

  task automatic split_tests(input int S);
    reg [31:0] v, v2; reg [63:0] v64, words;
    longint chunk, total, rem, last;
    int nfull, n2_before, aw0, aw1;
    begin
      $display("Test 9 (S = %0d): split record, 2 members, START_CHUNK 5, 7-slot ring, STOP -> 2-page last chunk", S);
      soft_reset();
      wr32(12'h10C, 32'h7F);
      cfg_split = 1; cfg_mem1 = 0; cfg_stripe = S; cfg_dry = 0;
      cfg_two = 1; cfg_fua = 0; cfg_start_chunk = 5; cfg_num_chunks = 7;
      cfg_chunk_shift = 17; cfg_lba_shift = 9; cfg_prp_shift = 12;
      cfg_ring_base  = 64'h0000_0008_0040_0000;
      cfg_ring_base1 = 64'h0000_0020_0001_3000;
      cfg_prp_base   = 64'h0000_0000_5000_0000;
      cfg_lba[0] = 64'h2_0000; cfg_lba[1] = 64'h4_0800; cfg_nsid[0] = 1; cfg_nsid[1] = 2;
      cfg_ssd[0] = 0; cfg_ssd[1] = 1; cfg_sq[0] = 0; cfg_sq[1] = 0;
      allow_pad = 1; seq_check = 1; exp_c = 0; seq_base = 0; dmin = 20; dmax = 2500; err_at_chunk = -1;
      chunk = longint'(1) << cfg_chunk_shift;
      n2_before = n_2page; aw0 = n_aw[0]; aw1 = n_aw[1];
      configure(0);
      rd32(12'h104, v); if (!v[3]) fail("T9 CONFIG.SPLIT readback");
      wr32(12'h148, 0);                           // until STOP
      wr32(12'h1C0, 4); wr32(12'h1E0, 4);
      wr32(12'h014, rate(32'h4000_0000));         // 1.6 GB/s
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      // 10 full chunks + ~6.3 KB: slow down near the end, then stop the source
      wait_words((10 * chunk + 6144 - 16384) / 16, 3000);
      wr32(12'h014, rate(32'h0800_0000));         // 0.2 GB/s
      wait_words((10 * chunk + 6144 + 256) / 16, 3000);
      wr32(12'h010, 0);
      #3000;
      wr32(12'h100, 2);                           // STOP
      wait_state(3, 6000);
      rd64(12'h018, words);
      total = words * 16;
      nfull = total / chunk; rem = total % chunk;
      $display("  T9: %0d bytes = %0d chunks + %0d bytes", total, nfull, rem);
      if (nfull != 10 || rem <= 4096 || rem > 8192) fail($sformatf("T9 last chunk not 2 pages (%0d chunks + %0d)", nfull, rem));
      rd64(12'h220, v64); if (v64 != total) fail($sformatf("T9 BYTES %0d != TPG %0d", v64, total));
      rd64(12'h200, v64); if (v64 != nfull + 1) fail($sformatf("T9 CHUNKS_FILLED %0d", v64));
      rd64(12'h210, v64); if (v64 != nfull + 1) fail($sformatf("T9 CMDS_DONE %0d", v64));
      if (exp_c != nfull + 1) fail($sformatf("T9 model saw %0d builder SQEs", exp_c));
      if (n_2page == n2_before) fail("T9 no 2-page SQE (PRP2 path not exercised)");
      rd64(12'h028, v64); if (v64 != 0) fail($sformatf("T9 drops %0d", v64));
      expect32(12'h218, 0, "T9 CMD_ERRORS");
      expect32(12'h21C, 0, "T9 UNEXPECTED");
      rd32(12'h260, v); rd32(12'h264, v2);
      $display("  T9: WR_PORT_STALL0 %0d WR_PORT_STALL1 %0d, AW bursts port0 %0d port1 %0d",
               v, v2, n_aw[0] - aw0, n_aw[1] - aw1);
      if (v == 0 || v2 == 0) fail("T9 split: both WR_PORT_STALL counters must count");
      if (n_aw[0] == aw0 || n_aw[1] == aw1) fail("T9 split: both ports must be written");
      expect32(12'h1C4, 0, "T9 SSD0 INFLIGHT"); expect32(12'h1E4, 0, "T9 SSD1 INFLIGHT");
      rem = (rem / 512) * 512;                    // whole LBAs of data (no padding)
      last = rem;

      $display("Test 10 (S = %0d): split playback of the test 9 recording (2-page last chunk)", S);
      soft_reset();
      allow_pad = 1; exp_c = 0; dmin = 50; dmax = 2000;
      n2_before = n_2page;
      configure(1);
      wr32(12'h148, nfull + 1);
      wr32(12'h14C, last);
      wr32(12'h1C0, 6); wr32(12'h1E0, 6);
      wr32(12'h064, rate(32'h8000_0000));         // sink at full rate
      wr32(12'h060, 2);
      #2000;
      wr32(12'h100, 1);
      #20000;
      wr32(12'h060, 1);
      wait_state(3, 8000);
      #50000;
      total = nfull * chunk + last;
      rd64(12'h070, v64); if (v64 != total / BB) fail($sformatf("T10 CHK_BEATS %0d exp %0d", v64, total / BB));
      rd64(12'h078, v64); if (v64 != 0) fail($sformatf("T10 CHK_ERRORS %0d", v64));
      rd64(12'h080, v64); if (v64 != 0) fail($sformatf("T10 CHK_GAPS %0d", v64));
      rd64(12'h098, v64); if (v64 != total / 16 - WPB) fail($sformatf("T10 CHK_LAST_SEQ %0d", v64));
      rd64(12'h220, v64); if (v64 != total) fail($sformatf("T10 BYTES %0d", v64));
      if (n_2page == n2_before) fail("T10 no 2-page Read SQE");
      rd32(12'h268, v); rd32(12'h26C, v2);
      $display("  T10: RD_PORT_WAIT0 %0d RD_PORT_WAIT1 %0d", v, v2);
      if (v2 == 0) fail("T10 split: RD_PORT_WAIT1 (slow port) must count");
      wr32(12'h060, 0);

      $display("Test 11 (S = %0d): split DRY record of NUM_CHUNKS chunks + ring-resident playback", S);
      soft_reset();
      cfg_dry = 1; cfg_start_chunk = 0;
      configure(0);
      wr32(12'h148, cfg_num_chunks);
      // 1.2 GB/s: the slow port model (port 1: WREADY 2/3, pauses ~30 % of the
      // time) moves < 1.9 GB/s at 128 bits and the W channel is head-of-line
      wr32(12'h014, rate(32'h3000_0000));
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      wait_state(3, 4000);
      wr32(12'h010, 0);
      rd64(12'h200, v64); if (v64 != cfg_num_chunks) fail($sformatf("T11 CHUNKS_FILLED %0d", v64));
      rd64(12'h250, v64); if (v64 != 0) fail($sformatf("T11 RUN_DROP_COUNT %0d", v64));
      check_ring_mem(ring_bytes(), $sformatf("T11 S=%0d", S));
      configure(1);
      wr32(12'h148, cfg_num_chunks);
      wr32(12'h14C, 0);
      wr32(12'h064, rate(32'h8000_0000));
      wr32(12'h060, 2);
      #2000;
      wr32(12'h100, 1);
      #5000;
      wr32(12'h060, 1);
      wait_state(3, 4000);
      #20000;
      total = ring_bytes();
      rd64(12'h070, v64); if (v64 != total / BB) fail($sformatf("T11 CHK_BEATS %0d", v64));
      rd64(12'h078, v64); if (v64 != 0) fail($sformatf("T11 CHK_ERRORS %0d", v64));
      rd64(12'h080, v64); if (v64 != 0) fail($sformatf("T11 CHK_GAPS %0d", v64));
      rd64(12'h098, v64); if (v64 != total / 16 - WPB) fail($sformatf("T11 CHK_LAST_SEQ %0d", v64));
      wr32(12'h060, 0);
      cfg_dry = 0;
    end
  endtask

  task automatic test_mem1();
    reg [31:0] v, v2; reg [63:0] v64; int aw0, ar0, aw1, ar1;
    begin
      $display("Test 12: CONFIG.MEM1: single ring at RING_BASE1 (port 1), DRY record + playback");
      soft_reset();
      cfg_split = 0; cfg_mem1 = 1; cfg_dry = 1; cfg_two = 0; cfg_start_chunk = 0; cfg_num_chunks = 5;
      cfg_chunk_shift = 16; cfg_ring_base1 = 64'h0000_0020_0100_0000;
      aw0 = n_aw[0]; ar0 = n_ar[0]; aw1 = n_aw[1]; ar1 = n_ar[1];
      configure(0);
      wr32(12'h148, cfg_num_chunks);
      wr32(12'h014, rate(32'h3000_0000));         // 1.2 GB/s (slow port model)
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      wait_state(3, 4000);
      wr32(12'h010, 0);
      rd64(12'h250, v64); if (v64 != 0) fail($sformatf("T12 RUN_DROP_COUNT %0d", v64));
      check_ring_mem(ring_bytes(), "T12 MEM1");
      configure(1);
      wr32(12'h148, cfg_num_chunks);
      wr32(12'h14C, 0);
      wr32(12'h060, 2);
      #2000;
      wr32(12'h100, 1);
      #5000;
      wr32(12'h060, 1);
      wait_state(3, 4000);
      #20000;
      rd64(12'h070, v64); if (v64 != ring_bytes() / BB) fail($sformatf("T12 CHK_BEATS %0d", v64));
      rd64(12'h078, v64); if (v64 != 0) fail($sformatf("T12 CHK_ERRORS %0d", v64));
      if (n_aw[0] != aw0 || n_ar[0] != ar0) fail("T12 MEM1: traffic on ring port 0");
      if (n_aw[1] == aw1 || n_ar[1] == ar1) fail("T12 MEM1: no traffic on ring port 1");
      rd32(12'h268, v); rd32(12'h26C, v2);
      if (v != 0 || v2 == 0) fail($sformatf("T12 RD_PORT_WAIT0/1 %0d/%0d", v, v2));
      wr32(12'h060, 0);
      cfg_mem1 = 0; cfg_dry = 0;
    end
  endtask

  task automatic test_one_port();
    reg [31:0] v; reg [63:0] v64;
    begin
      $display("Test 13: N_RING_PORTS 1: SPLIT / MEM1 ignored, single ring on port 0");
      soft_reset();
      expect32(12'h164, 1, "T13 RING_PORTS");
      rd32(12'h108, v); if (v[13]) fail("T13 STATE.MEM1_READY with one ring port");
      // SPLIT set: must be ignored (the model's reference treats it as 0 too)
      cfg_split = 1; cfg_stripe = 12; cfg_dry = 1; cfg_two = 0; cfg_start_chunk = 0; cfg_num_chunks = 5;
      cfg_chunk_shift = 16; cfg_ring_base = 64'h0000_0000_6800_0000;
      configure(0);
      wr32(12'h148, cfg_num_chunks);
      wr32(12'h014, rate(32'h6000_0000));
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      wait_state(3, 4000);
      wr32(12'h010, 0);
      check_ring_mem(ring_bytes(), "T13 one port");
      if (n_aw[1] != 0 || n_ar[1] != 0) fail("T13 traffic on ring port 1");
      expect32(12'h264, 0, "T13 WR_PORT_STALL1");
      cfg_split = 0; cfg_dry = 0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test 14: memory switches at chunk boundaries (chunk-sized stripes)
  // ---------------------------------------------------------------------------
  // Monitors (dp_clk): the ring reader WAITS when a burst is outstanding, the
  // egress FIFO has room and no data is there; the ring writer STALLS when its
  // head W beat is valid and not accepted. Each cycle is booked to the first
  // mon_win beats of a chunk ("boundary") or to the rest of the chunk.
  // Sink monitor (src_clk): cycles the full-rate checker had no data between
  // the first and the last beat of the playback (= egress starvation).
  bit     mon_on = 0;
  longint mon_chunk_beats = 1, mon_win = 1;
  longint mon_rd_beats, mon_rd_wait_bnd, mon_rd_wait_mid, mon_wr_beats, mon_wr_stall_bnd, mon_wr_stall_mid;
  always @(posedge dp_clk) begin
    if (mon_on) begin
      if (!dut.u_rd.rq_empty && dut.u_rd.m_axis_tready && !dut.u_rd.m_axis_tvalid) begin
        if ((mon_rd_beats % mon_chunk_beats) < mon_win) mon_rd_wait_bnd++; else mon_rd_wait_mid++;
      end
      if (dut.u_rd.m_axis_tvalid && dut.u_rd.m_axis_tready) mon_rd_beats++;
      if (dut.u_wr.w_valid && !dut.u_wr.w_ready) begin
        if ((mon_wr_beats % mon_chunk_beats) < mon_win) mon_wr_stall_bnd++; else mon_wr_stall_mid++;
      end
      if (dut.u_wr.w_valid && dut.u_wr.w_ready) mon_wr_beats++;
    end
  end
  bit     snk_mon = 0;
  longint snk_beats, snk_starve, snk_total;
  always @(posedge src_clk) begin
    if (snk_mon) begin
      if (snk_tvalid && snk_tready) snk_beats++;
      else if (snk_tready && !snk_tvalid && snk_beats > 0 && snk_beats < snk_total) snk_starve++;
    end
  end

  task automatic t14_play(input int rrob, input bit strict);
    reg [31:0] v, v2; reg [63:0] v64; longint total; int nch;
    begin
      mm_rrob = rrob;
      nch = cfg_num_chunks;
      total = longint'(nch) << cfg_chunk_shift;
      configure(1);
      wr32(12'h148, nch);
      wr32(12'h14C, 0);
      wr32(12'h064, 32'h8000_0000);                // sink: one beat per src_clk (any width)
      wr32(12'h060, 2);
      #2000;
      mon_rd_beats = 0; mon_rd_wait_bnd = 0; mon_rd_wait_mid = 0;
      mon_wr_beats = 0; mon_wr_stall_bnd = 0; mon_wr_stall_mid = 0;
      snk_beats = 0; snk_starve = 0; snk_total = total / BB;
      wr32(12'h060, 1);                            // checker on before START: it waits for data
      mon_on = 1; snk_mon = 1;
      wr32(12'h100, 1);
      wait_state(3, 4000);
      #20000;
      mon_on = 0; snk_mon = 0;
      rd64(12'h070, v64); if (v64 != total / BB) fail($sformatf("T14 CHK_BEATS %0d", v64));
      rd64(12'h078, v64); if (v64 != 0) fail($sformatf("T14 CHK_ERRORS %0d", v64));
      rd64(12'h080, v64); if (v64 != 0) fail($sformatf("T14 CHK_GAPS %0d", v64));
      rd32(12'h268, v); rd32(12'h26C, v2);
      $display("  T14 playback (read buffer %0d bursts): reader waited %0d cycles in the first %0d beats of a chunk (%0d boundaries), %0d elsewhere; RD_PORT_WAIT0/1 %0d / %0d; sink starved %0d src_clk cycles of %0d beats",
               rrob, mon_rd_wait_bnd, mon_win, nch - 1, mon_rd_wait_mid, v, v2, snk_starve, snk_total);
      if (strict && RD_SKID_DEPTH > 0 && snk_starve != 0)
        fail($sformatf("T14 the full-rate sink starved %0d cycles at chunk-sized stripes", snk_starve));
      wr32(12'h060, 0);
      mm_rrob = 4;
    end
  endtask

  task automatic test_chunk_switch();
    reg [31:0] v, v2; reg [63:0] v64; longint total; int nch;
    begin
      $display("Test 14: chunk-sized stripes, NoC-like ports (R latency %0d / %0d cycles, B %0d / %0d, read buffer %0d bursts per port, ready %0d %%, R valid %0d %%), RD_SKID_DEPTH %0d",
               mm_lat_r[0], mm_lat_r[1], mm_lat_b[0], mm_lat_b[1], mm_rrob, mm_rdy_pct, mm_rv_pct, RD_SKID_DEPTH);
      soft_reset();
      wr32(12'h10C, 32'h7F);
      mm_mode = 1;
      cfg_split = 1; cfg_mem1 = 0; cfg_dry = 1; cfg_two = 0; cfg_start_chunk = 0;
      cfg_chunk_shift = 16; cfg_stripe = 16; cfg_num_chunks = 16; cfg_lba_shift = 9; cfg_prp_shift = 12;
      cfg_ring_base  = 64'h0000_0008_0080_0000;
      cfg_ring_base1 = 64'h0000_0020_0080_0000;
      cfg_prp_base   = 64'h0000_0000_5800_0000;
      nch = cfg_num_chunks;
      total = longint'(nch) << cfg_chunk_shift;
      mon_chunk_beats = (longint'(1) << cfg_chunk_shift) / BB;
      mon_win = 4 * (4096 / BB);                   // the first 4 bursts of a chunk
      // 14a: DRY record at the source maximum (writer side)
      mon_rd_beats = 0; mon_rd_wait_bnd = 0; mon_rd_wait_mid = 0;
      mon_wr_beats = 0; mon_wr_stall_bnd = 0; mon_wr_stall_mid = 0;
      configure(0);
      wr32(12'h148, nch);
      wr32(12'h014, 32'h8000_0000);                // one beat per src_clk (any width)
      mon_on = 1;
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      wait_state(3, 4000);
      wr32(12'h010, 0);
      mon_on = 0;
      rd64(12'h250, v64); if (v64 != 0) fail($sformatf("T14 record RUN_DROP_COUNT %0d", v64));
      rd32(12'h260, v); rd32(12'h264, v2);
      $display("  T14 record : %0d beats, writer W stall %0d cycles in the first %0d beats of a chunk (%0d boundaries), %0d elsewhere; WR_PORT_STALL0/1 %0d / %0d",
               mon_wr_beats, mon_wr_stall_bnd, mon_win, nch - 1, mon_wr_stall_mid, v, v2);
      check_ring_mem(total, "T14 record");
      // 14b: ring-resident playback into the full-rate checker (reader side),
      // ports able to feed the sink alone; 14c: ports slower than the sink
      // (read buffer 3 bursts): the reader is the limit, the starvation shows
      // how much of the two memories' bandwidth it uses
      t14_play(4, 1);
      t14_play(3, 0);
      mm_mode = 0; cfg_split = 0; cfg_dry = 0;
    end
  endtask

  // watchdog
  initial begin
    #250ms;
    $display("FAIL: watchdog timeout");
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  reg [31:0] v, v2; reg [63:0] v64;
  int  i, k, t1_chunks, n_inj, inj_done;

  initial begin
    repeat (20) @(posedge dp_clk);
    src_resetn = 1; dp_resetn = 1;
    repeat (50) @(posedge dp_clk);

    // ---- Test 0: identification / reset values
    $display("Test 0: identification and reset values");
    expect32(12'h000, 32'h0001_0003, "VERSION");
    expect32(12'h164, N_RING_PORTS, "RING_PORTS");
    expect32(12'h160, 12, "RING_STRIPE_SHIFT reset");
    expect32(12'h158, 0, "RING_BASE1_LO reset");
    expect32(12'h15C, 0, "RING_BASE1_HI reset");
    expect32(12'h260, 0, "WR_PORT_STALL0 reset"); expect32(12'h264, 0, "WR_PORT_STALL1 reset");
    expect32(12'h268, 0, "RD_PORT_WAIT0 reset");  expect32(12'h26C, 0, "RD_PORT_WAIT1 reset");
    expect32(12'h0BC, BB, "BEAT_BYTES");
    expect32(12'h038, FDEPTH, "ING_FIFO_DEPTH");
    expect32(12'h0A4, EDEPTH, "EGR_FIFO_DEPTH");
    expect32(12'h258, 0, "RUN_FIFO_HWM reset");
    expect32(12'h03C, 32'h4E56_5243, "ID");
    expect32(12'h150, 1 << SLOT_W, "MAX_SLOTS");
    expect32(12'h128, 256, "NUM_CHUNKS reset");
    expect32(12'h12C, 32'h0010_0000, "CHUNK_SIZE reset");
    expect32(12'h154, 63, "CREDIT_INIT reset");
    expect32(12'h184, 32'h0000_0000, "MEMBER_SEL(0) reset");
    expect32(12'h1A4, 32'h0000_0001, "MEMBER_SEL(1) reset");
    expect32(12'h1C0, 32, "SSD_MAX_INFLIGHT reset");
    expect32(12'h108, TWO ? 32'h2000 : 0, "STATE idle (MEM1_READY = 1 if 2 ring ports)");
    mem1_ready_in = 1'b0;
    #200;
    expect32(12'h108, 0, "STATE.MEM1_READY follows mem1_ready (0)");
    mem1_ready_in = 1'b1;
    #200;
    expect32(12'h108, TWO ? 32'h2000 : 0, "STATE.MEM1_READY follows mem1_ready (1)");

    soft_reset();
    wr32(12'h100, 32'h10);                      // CREDIT_RST
    expect32(12'h1C8, 63, "credits after CREDIT_RST");
    expect32(12'h1E8, 63, "credits(1) after CREDIT_RST");
    wr32(12'h110, 32'h3F);                      // all IRQs enabled

    // ---- Test 1: record, 1 member, LENGTH 24
    $display("Test 1: record, 1 member, 24 x 64 KB chunks, 8-slot ring, OOO completions");
    cfg_ring_base = 64'h0000_0008_0010_3000; cfg_prp_base = 64'h0000_0000_4000_0000;
    cfg_chunk_shift = 16; cfg_lba_shift = 9; cfg_num_chunks = 8; cfg_prp_shift = 12;
    cfg_two = 0; cfg_fua = 1; cfg_start_chunk = 0;
    cfg_lba[0] = 64'h1000; cfg_lba[1] = 0; cfg_nsid[0] = 1; cfg_nsid[1] = 7;
    cfg_ssd[0] = 0; cfg_ssd[1] = 1; cfg_sq[0] = 0; cfg_sq[1] = 0;
    allow_pad = 0; exp_c = 0; seq_base = 0; dmin = 50; dmax = 4000;
    configure(0);
    wr32(12'h148, 24);                          // LENGTH_CHUNKS
    wr32(12'h1C0, 4);                           // MAX_INFLIGHT ssd0
    wr32(12'h014, rate(32'h4000_0000));         // TPG 1.6 GB/s
    wr32(12'h100, 1);                           // START
    wr32(12'h010, 1);                           // TPG on
    wait_state(3, 4000);
    #100000;                                    // TPG still running after the run
    rd64(12'h028, v64); $display("  T1: ING_DROP_COUNT after the run %0d", v64);
    if (v64 == 0) fail("T1 expected drops after the run (TPG still on)");
    rd64(12'h250, v64); if (v64 != 0) fail($sformatf("T1 RUN_DROP_COUNT %0d", v64));
    rd32(12'h10C, v); if (v[2]) fail("T1 OVERFLOW IRQ set by drops after the run");
    rd32(12'h024, v); rd32(12'h258, v2);
    $display("  T1: ING_FIFO_HWM %0d (post-run fill), RUN_FIFO_HWM %0d", v, v2);
    if (v < FDEPTH) fail($sformatf("T1 ING_FIFO_HWM %0d, expected the post-run fill", v));
    if (v2 == 0 || v2 >= FDEPTH) fail($sformatf("T1 RUN_FIFO_HWM %0d", v2));
    expect32(12'h1CC, 24, "T1 SSD_ISSUED(0)");
    expect32(12'h1D0, 24, "T1 SSD_COMPLETED(0)");
    wr32(12'h010, 0);
    rd64(12'h200, v64); if (v64 != 24) fail($sformatf("T1 CHUNKS_FILLED %0d", v64));
    rd64(12'h208, v64); if (v64 != 24) fail($sformatf("T1 CMDS_ISSUED %0d", v64));
    rd64(12'h210, v64); if (v64 != 24) fail($sformatf("T1 CMDS_DONE %0d", v64));
    rd64(12'h220, v64); if (v64 != 24 * 65536) fail($sformatf("T1 BYTES %0d", v64));
    rd64(12'h048, v64); if (v64 != 24 * 65536 / BB) fail($sformatf("T1 ING_BEATS_OUT %0d", v64));
    expect32(12'h218, 0, "T1 CMD_ERRORS");
    expect32(12'h21C, 0, "T1 UNEXPECTED");
    rd32(12'h22C, v); if (v > 8 || v < 2) fail($sformatf("T1 RING_HWM %0d", v));
    rd32(12'h1D8, v); if (v > 4 || v == 0) fail($sformatf("T1 SSD0 INFLIGHT_HWM %0d (max 4)", v));
    rd32(12'h260, v); rd32(12'h264, v2);
    $display("  T1: WR_PORT_STALL0 %0d, WR_PORT_STALL1 %0d (single ring)", v, v2);
    if (v == 0 || v2 != 0) fail("T1 single ring: stall counters (port 0 > 0, port 1 = 0)");
    if (n_aw[1] != 0 || n_ar[1] != 0) fail("T1 single ring: traffic on ring port 1");
    expect32(12'h288, 24, "T1 LAT_COUNT");
    rd32(12'h10C, v); if (!v[0]) fail("T1 IRQ DONE not set");
    if (!irq) fail("T1 irq output low");
    wr32(12'h10C, 32'h3F);
    if (n_bld_sqe != 24) fail($sformatf("T1 model saw %0d SQEs", n_bld_sqe));
    expect32(12'h1C8, 63, "T1 credits back to 63");
    begin
      int hsum; hsum = 0;
      for (i = 0; i < 16; i++) begin rd32(12'h2C0 + i * 4, v); hsum += v; end
      if (hsum != 24) fail($sformatf("T1 histogram sum %0d", hsum));
    end
    t1_chunks = 24;

    // ---- Test 2: 2-member stripe, START_CHUNK 3, STOP with partial chunk + injector
    $display("Test 2: record, 2-member stripe, START_CHUNK 3, STOP, injector");
    soft_reset();
    cfg_two = 1; cfg_fua = 0; cfg_start_chunk = 3; cfg_num_chunks = 6;
    cfg_lba[0] = 64'h10_0000; cfg_lba[1] = 64'h20_0800; cfg_nsid[0] = 1; cfg_nsid[1] = 3;
    cfg_ssd[0] = 0; cfg_ssd[1] = 1; cfg_sq[0] = 0; cfg_sq[1] = 0;
    cfg_ring_base = 64'h0000_0000_2000_0000; cfg_prp_base = 64'h0000_0000_3000_0000;
    allow_pad = 1; exp_c = 0; seq_base = 0; dmin = 20; dmax = 2500;
    configure(0);
    wr32(12'h148, 0);                           // until STOP
    wr32(12'h1C0, 3); wr32(12'h1E0, 5);
    wr32(12'h014, rate(32'h5000_0000));
    wr32(12'h100, 1);
    wr32(12'h010, 1);
    // injector: 6 commands alternating SSDs while the builder runs
    n_inj = 0; inj_done = 0;
    for (k = 0; k < 6; k++) begin
      #20000;
      v = 1;
      while (v[0]) rd32(12'h344, v);
      wr32(12'h300, 32'h0000_0000 | (k << 16));   // Flush, CID = k (bit 15 forced)
      wr32(12'h304, 1);
      for (i = 2; i < 16; i++) wr32(12'h300 + i * 4, 0);
      wr32(12'h340, 1 | ((k % 2) << 8));
      n_inj++;
      // pop whatever CQEs arrived
      rd32(12'h344, v);
      while (v[1]) begin
        rd32(12'h35C, v2);
        if (!v2[15]) fail("injector CQE without CID bit 15");
        rd32(12'h34C, v2);
        inj_done++;
        wr32(12'h348, 0);
        rd32(12'h344, v);
      end
    end
    rd32(12'h200, v);
    if (v < 2) fail($sformatf("T2 only %0d chunks before STOP", v));
    wr32(12'h010, 0);                           // source off
    #3000;
    wr32(12'h100, 2);                           // STOP
    wait_state(3, 6000);
    // drain injector CQEs
    #20000;
    rd32(12'h344, v);
    while (v[1]) begin
      rd32(12'h35C, v2);
      if (!v2[15] || v2[14:0] > 5) fail($sformatf("injector CQE CID %h", v2[15:0]));
      inj_done++;
      wr32(12'h348, 0);
      rd32(12'h344, v);
    end
    if (inj_done != 6 || n_inj_sqe != 6) fail($sformatf("T2 injector %0d CQEs / %0d SQEs", inj_done, n_inj_sqe));
    expect32(12'h360, 6, "T2 INJ_SUBMITTED");
    expect32(12'h364, 6, "T2 INJ_COMPLETED");
    expect32(12'h218, 0, "T2 CMD_ERRORS");
    rd32(12'h240, v); $display("  T2: %0d chunks, %0d pad bytes", exp_c, v);
    rd64(12'h210, v64); if (v64 != exp_c) fail($sformatf("T2 CMDS_DONE %0d model %0d", v64, exp_c));
    rd64(12'h028, v64); if (v64 != 0) fail($sformatf("T2 drops %0d", v64));
    expect32(12'h1C4, 0, "T2 SSD0 INFLIGHT"); expect32(12'h1E4, 0, "T2 SSD1 INFLIGHT");
    rd32(12'h1CC, v); rd32(12'h1EC, v2);
    if (v == 0 || v2 == 0) fail("T2 both SSDs must have received commands");
    // issue and completion counters cleared by the same SOFT_RST (before T2)
    rd32(12'h1D0, k); if (v != k) fail($sformatf("T2 SSD_ISSUED(0) %0d != SSD_COMPLETED(0) %0d", v, k));
    rd32(12'h1F0, k); if (v2 != k) fail($sformatf("T2 SSD_ISSUED(1) %0d != SSD_COMPLETED(1) %0d", v2, k));

    // ---- Test 3: playback of test 1's recording
    $display("Test 3: playback of the test 1 recording into fdrec_check");
    soft_reset();
    cfg_two = 0; cfg_start_chunk = 0; cfg_num_chunks = 8; cfg_fua = 0;
    cfg_lba[0] = 64'h1000; cfg_nsid[0] = 1; cfg_ssd[0] = 0; cfg_sq[0] = 0;
    cfg_ring_base = 64'h0000_0008_0010_3000; cfg_prp_base = 64'h0000_0000_4000_0000;
    allow_pad = 0; exp_c = 0; dmin = 50; dmax = 2000;
    configure(1);
    wr32(12'h148, t1_chunks);
    wr32(12'h14C, 0);
    wr32(12'h1C0, 6);
    wr32(12'h064, rate(32'h4000_0000));         // sink 1.6 GB/s
    wr32(12'h060, 2);                           // checker reset
    #2000;
    wr32(12'h100, 1);
    #20000;                                     // let the egress FIFO fill
    wr32(12'h060, 1);                           // checker on
    wait_state(3, 6000);
    #50000;
    rd64(12'h070, v64); if (v64 != t1_chunks * 65536 / BB) fail($sformatf("T3 CHK_BEATS %0d", v64));
    rd64(12'h078, v64); if (v64 != 0) fail($sformatf("T3 CHK_ERRORS %0d", v64));
    rd64(12'h080, v64); if (v64 != 0) fail($sformatf("T3 CHK_GAPS %0d", v64));
    rd64(12'h098, v64); if (v64 != t1_chunks * 4096 - WPB) fail($sformatf("T3 CHK_LAST_SEQ %0d", v64));
    rd64(12'h220, v64); if (v64 != t1_chunks * 65536) fail($sformatf("T3 BYTES %0d", v64));
    wr32(12'h060, 0);

    // ---- Test 4: error status, unexpected CQE, IRQ
    $display("Test 4: CQE error status + unexpected CQE");
    soft_reset();
    wr32(12'h10C, 32'h3F);
    cfg_two = 0; cfg_start_chunk = 100; cfg_num_chunks = 4; cfg_lba[0] = 64'h50_0000;
    allow_pad = 0; exp_c = 0; err_at_chunk = 2; dmin = 20; dmax = 500;
    seq_base = 0;
    configure(0);
    wr32(12'h148, 5);
    wr32(12'h014, rate(32'h2000_0000));
    wr32(12'h100, 1);
    wr32(12'h010, 1);
    wait_state(3, 4000);
    wr32(12'h010, 0);
    expect32(12'h218, 1, "T4 CMD_ERRORS");
    expect32(12'h230, 32'h8000_0000 | 15'h0281, "T4 ERR_LAST_STATUS");
    expect32(12'h234, 32'h0002_0002, "T4 ERR_LAST_CID (sqid 2, cid = slot 2)");
    expect32(12'h1D4, 1, "T4 SSD0 errors");
    rd32(12'h10C, v); if (!v[1] || !v[0]) fail($sformatf("T4 IRQ_STATUS %h", v));
    send_bogus = 1;
    #2000;
    expect32(12'h21C, 1, "T4 UNEXPECTED_CQES");
    rd32(12'h10C, v); if (!v[4]) fail("T4 IRQ unexpected not set");
    wr32(12'h10C, 32'h3F);
    rd32(12'h10C, v); if (v != 0) fail($sformatf("T4 IRQ_STATUS after clear %h", v));
    if (irq) fail("T4 irq still high");
    expect32(12'h1C8, 63, "T4 credits");

    // ---- Test 5: ring stress
    $display("Test 5: ring stress: 4-slot ring full, slow out-of-order completions, drops");
    soft_reset();
    wr32(12'h10C, 32'h3F);
    cfg_two = 1; cfg_start_chunk = 0; cfg_num_chunks = 4; cfg_lba[0] = 64'h80_0000; cfg_lba[1] = 64'h80_0000;
    cfg_nsid[0] = 1; cfg_nsid[1] = 1; allow_pad = 0; exp_c = 0; err_at_chunk = -1;
    seq_check = 0; dmin = 2000; dmax = 30000;
    configure(0);
    wr32(12'h148, 40);
    wr32(12'h1C0, 4); wr32(12'h1E0, 4);
    wr32(12'h014, rate(32'h6000_0000));         // 2.4 GB/s
    wr32(12'h100, 1);
    wr32(12'h010, 1);
    wait_state(3, 20000);
    wr32(12'h010, 0);
    rd64(12'h210, v64); if (v64 != 40) fail($sformatf("T5 CMDS_DONE %0d", v64));
    expect32(12'h22C, 4, "T5 RING_HWM");
    rd64(12'h248, v64); if (v64 == 0) fail("T5 RING_FULL_CYCLES 0");
    rd64(12'h028, v64); if (v64 == 0) fail("T5 expected ingest drops");
    rd32(12'h10C, v); if (!v[2]) fail("T5 IRQ OVERFLOW not set");
    rd64(12'h250, v2); if (v2 == 0 || v2 > v64) fail($sformatf("T5 RUN_DROP_COUNT %0d", v2));
    // per-SSD credit reset
    wr32(12'h154, 10); wr32(12'h100, 32'h80);
    expect32(12'h1E8, 10, "T5 credits(1) after SSD1 reset"); expect32(12'h1C8, 63, "T5 credits(0) untouched");
    wr32(12'h154, 63); wr32(12'h100, 32'h80);
    $display("  T5: %0d beats dropped while the ring was full", v64);
    expect32(12'h218, 0, "T5 CMD_ERRORS");
    expect32(12'h1C8, 63, "T5 credits(0)"); expect32(12'h1E8, 63, "T5 credits(1)");

    // ---- Test 6: counter clear rules across SOFT_RST
    $display("Test 6: SOFT_RST clears issue and completion counters together");
    soft_reset();
    expect32(12'h360, 0, "T6 INJ_SUBMITTED after SOFT_RST");
    expect32(12'h364, 0, "T6 INJ_COMPLETED after SOFT_RST");
    for (k = 0; k < 2; k++) begin expect32(12'h1CC + k * 32, 0, "T6 SSD_ISSUED after SOFT_RST");
                                   expect32(12'h1D0 + k * 32, 0, "T6 SSD_COMPLETED after SOFT_RST"); end
    expect32(12'h258, 0, "T6 RUN_FIFO_HWM after SOFT_RST");
    dmin = 20; dmax = 200;
    for (k = 0; k < 3; k++) begin
      v = 1;
      while (v[0]) rd32(12'h344, v);
      wr32(12'h300, 32'h0000_0000 | ((k + 8) << 16));
      wr32(12'h304, 1);
      for (i = 2; i < 16; i++) wr32(12'h300 + i * 4, 0);
      wr32(12'h340, 1 | ((k % 2) << 8));
    end
    #20000;
    rd32(12'h344, v);
    while (v[1]) begin wr32(12'h348, 0); rd32(12'h344, v); end
    expect32(12'h360, 3, "T6 INJ_SUBMITTED");
    expect32(12'h364, 3, "T6 INJ_COMPLETED");
    expect32(12'h1CC, 2, "T6 SSD_ISSUED(0)"); expect32(12'h1D0, 2, "T6 SSD_COMPLETED(0)");
    expect32(12'h1EC, 1, "T6 SSD_ISSUED(1)"); expect32(12'h1F0, 1, "T6 SSD_COMPLETED(1)");

    // ---- Test 7: Host Accelerator dead input
    $display("Test 7: HA_DEAD status and interrupt");
    wr32(12'h10C, 32'h7F);
    wr32(12'h110, 32'h40);                      // only HA_DEAD enabled
    rd32(12'h108, v); if (v[12]) fail("T7 STATE.HA_DEAD set before the input");
    if (irq) fail("T7 irq high before HA_DEAD");
    ha_dead_in = 1'b1;
    #200;
    rd32(12'h108, v); if (!v[12]) fail("T7 STATE.HA_DEAD not set");
    rd32(12'h10C, v); if (!v[6]) fail("T7 IRQ_STATUS.HA_DEAD not set");
    #20; if (!irq) fail("T7 irq output low");
    wr32(12'h10C, 32'h40);
    rd32(12'h10C, v); if (v[6]) fail("T7 IRQ_STATUS.HA_DEAD not cleared by W1C");
    rd32(12'h108, v); if (!v[12]) fail("T7 STATE.HA_DEAD must stay while the input is high");
    #20; if (irq) fail("T7 irq still high after W1C");
    wr32(12'h110, 32'h3F);
    ha_dead_in = 1'b0;

    // ---- Test 8: DRY (fabric-only) record and ring-resident playback
    $display("Test 8: CONFIG.DRY record (STOP, ring wrap) and ring-resident playback");
    begin
      int sqe_before, nf;
      sqe_before = n_bld_sqe + n_inj_sqe;
      // 8a: DRY record until STOP, 8-slot ring wrapped more than twice
      soft_reset();
      wr32(12'h10C, 32'h7F);
      cfg_dry = 1; cfg_two = 0; cfg_fua = 0; cfg_start_chunk = 0; cfg_num_chunks = 8;
      cfg_chunk_shift = 16; cfg_lba_shift = 9; cfg_prp_shift = 12;
      cfg_ring_base = 64'h0000_0000_6000_0000; cfg_prp_base = 64'h0000_0000_7000_0000;
      configure(0);
      rd32(12'h104, v); if (!v[2]) fail("T8 CONFIG.DRY readback");
      wr32(12'h148, 0);                         // until STOP
      wr32(12'h014, rate(32'h4000_0000));       // 1.6 GB/s
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      nf = 0;
      while (nf < 20) begin #5000; rd32(12'h200, nf); end
      rd32(12'h228, v); if (v > 2) fail($sformatf("T8 RING_FILL %0d during a DRY record", v));
      wr32(12'h010, 0);                         // source off
      #3000;
      wr32(12'h100, 2);                         // STOP
      wait_state(3, 4000);
      rd64(12'h200, v64); rd64(12'h238, k);
      if (v64 != k) fail($sformatf("T8 CHUNKS_RELEASED %0d != CHUNKS_FILLED %0d", k, v64));
      rd64(12'h208, v64); if (v64 != 0) fail($sformatf("T8 CMDS_ISSUED %0d in DRY", v64));
      rd64(12'h210, v64); if (v64 != 0) fail($sformatf("T8 CMDS_DONE %0d in DRY", v64));
      rd64(12'h250, v64); if (v64 != 0) fail($sformatf("T8 RUN_DROP_COUNT %0d", v64));
      rd32(12'h22C, v); if (v > 2) fail($sformatf("T8 RING_HWM %0d in DRY", v));
      // BYTES (beats << BEAT_SHIFT) = every TPG word x 16 (no drops, no padding counted)
      rd64(12'h220, v64);
      begin
        reg [63:0] words;
        rd64(12'h018, words);
        if (v64 != words * 16) fail($sformatf("T8 BYTES %0d != TPG words %0d x 16", v64, words));
        $display("  T8: DRY record of %0d bytes (%0d words), %0d chunks", v64, words, k);
      end
      rd32(12'h10C, v); if (!v[0]) fail("T8 IRQ DONE not set (DRY record)");
      wr32(12'h10C, 32'h7F);
      // 8b: DRY record of exactly NUM_CHUNKS chunks from TPG seq 0
      soft_reset();
      configure(0);
      wr32(12'h148, 8);
      wr32(12'h014, rate(32'h6000_0000));       // 2.4 GB/s
      wr32(12'h100, 1);
      wr32(12'h010, 1);
      wait_state(3, 4000);
      wr32(12'h010, 0);
      rd64(12'h200, v64); if (v64 != 8) fail($sformatf("T8 CHUNKS_FILLED %0d (exp 8)", v64));
      rd64(12'h220, v64); if (v64 != 8 * 65536) fail($sformatf("T8 BYTES %0d (exp 8 chunks)", v64));
      rd64(12'h250, v64); if (v64 != 0) fail($sformatf("T8 RUN_DROP_COUNT %0d (8 chunks)", v64));
      // ring-resident playback of those 8 chunks
      configure(1);
      wr32(12'h148, 8);
      wr32(12'h14C, 0);
      wr32(12'h064, rate(32'h8000_0000));       // sink at full rate
      wr32(12'h060, 2);                         // checker reset
      #2000;
      wr32(12'h100, 1);
      #5000;
      wr32(12'h060, 1);                         // checker on
      wait_state(3, 4000);
      #20000;
      rd64(12'h070, v64); if (v64 != 8 * 65536 / BB) fail($sformatf("T8 CHK_BEATS %0d", v64));
      rd64(12'h078, v64); if (v64 != 0) fail($sformatf("T8 CHK_ERRORS %0d", v64));
      rd64(12'h080, v64); if (v64 != 0) fail($sformatf("T8 CHK_GAPS %0d", v64));
      rd64(12'h098, v64); if (v64 != 8 * 4096 - WPB) fail($sformatf("T8 CHK_LAST_SEQ %0d", v64));
      rd64(12'h220, v64); if (v64 != 8 * 65536) fail($sformatf("T8 playback BYTES %0d", v64));
      rd64(12'h238, v64); if (v64 != 8) fail($sformatf("T8 playback CHUNKS_RELEASED %0d", v64));
      rd64(12'h208, v64); if (v64 != 0) fail($sformatf("T8 playback CMDS_ISSUED %0d", v64));
      expect32(12'h22C, 0, "T8 playback RING_HWM");
      wr32(12'h060, 0);
      if (n_bld_sqe + n_inj_sqe != sqe_before)
        fail($sformatf("T8 %0d SQEs reached the Host Accelerator in DRY mode", n_bld_sqe + n_inj_sqe - sqe_before));
      cfg_dry = 0;
    end

    // ---- Tests 9-11: split ring for three stripe sizes
    if (TWO) begin
      int stripes [3] = '{12, 16, 17};
      for (int si = 0; si < 3; si++) split_tests(stripes[si]);
      test_mem1();
      test_chunk_switch();
    end else begin
      test_one_port();
    end

    if (errors == 0) $display("PASS: tb_nvrec_core N_RING_PORTS %0d (%0d builder SQEs, %0d injector SQEs, %0d CQEs, %0d 2-page SQEs, bursts port0 %0d/%0d port1 %0d/%0d W/R)",
                              N_RING_PORTS, n_bld_sqe, n_inj_sqe, n_cqe, n_2page, n_aw[0], n_ar[0], n_aw[1], n_ar[1]);
    else             $display("FAIL: tb_nvrec_core, %0d error(s)", errors);
    $finish;
  end

endmodule
