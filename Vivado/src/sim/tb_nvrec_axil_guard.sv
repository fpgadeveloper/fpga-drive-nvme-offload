// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_nvrec_axil_guard -- self-checking testbench for the AXI4-Lite timeout
// guard in front of the nvmeha S_AXI_LITE slave.
//
//   1. a live slave: writes and reads pass through unchanged (data, strobes,
//      responses incl. a slave SLVERR), heartbeat reads reach the slave
//   2. the slave stops answering (as the evaluation-licensed IP does after
//      ~3 h): a CPU read completes after TIMEOUT_CYCLES with DEAD_RDATA /
//      OKAY and `dead` is set; later reads and writes complete within a few
//      cycles and never reach the slave
//   3. a second guard instance with a dead slave and no CPU traffic: the
//      heartbeat alone sets `dead`
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_nvrec_axil_guard;

  localparam integer TMO = 64;

  reg clk = 1'b0, resetn = 1'b0;
  always #5 clk = ~clk;

  integer errors = 0;
  task automatic fail(input string msg);
    begin
      $display("FAIL: %s (t=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask

  // CPU side
  reg  [31:0] s_awaddr = 0, s_araddr = 0, s_wdata = 0;
  reg  [3:0]  s_wstrb = 4'hF;
  reg         s_awvalid = 0, s_wvalid = 0, s_bready = 0, s_arvalid = 0, s_rready = 0;
  wire        s_awready, s_wready, s_bvalid, s_arready, s_rvalid;
  wire [1:0]  s_bresp, s_rresp;
  wire [31:0] s_rdata;

  // slave side
  wire [31:0] m_awaddr, m_araddr, m_wdata;
  wire [3:0]  m_wstrb;
  wire [2:0]  m_awprot, m_arprot;
  wire        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
  reg         m_awready = 0, m_wready = 0, m_bvalid = 0, m_arready = 0, m_rvalid = 0;
  reg  [1:0]  m_bresp = 0, m_rresp = 0;
  reg  [31:0] m_rdata = 0;
  wire        dead;
  wire [15:0] timeouts;

  nvrec_axil_guard #(.ADDR_W(32), .TIMEOUT_CYCLES(TMO), .HB_PERIOD_LOG2(9),
                     .HB_ADDR(16'h8114)) dut (
    .aclk(clk), .aresetn(resetn),
    .s_axi_awaddr(s_awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
    .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
    .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
    .s_axi_araddr(s_araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
    .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
    .m_axi_awaddr(m_awaddr), .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
    .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
    .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
    .m_axi_araddr(m_araddr), .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
    .dead(dead), .timeouts(timeouts));

  // ---------------------------------------------------------------------------
  // Slave model: a 16-word register file at 0x8100.. with random latency;
  // `slave_dead` = never answer again (no READY, no response)
  // ---------------------------------------------------------------------------
  reg  [31:0] regs [0:63];
  reg         slave_dead = 1'b0;
  integer     n_slave_rd = 0, n_slave_wr = 0, n_hb = 0;
  reg  [31:0] aw_q; reg aw_have = 0, w_have = 0; reg [31:0] w_q; reg [3:0] ws_q;
  integer     i;

  initial for (i = 0; i < 64; i++) regs[i] = 32'h1000_0000 + i;

  always @(posedge clk) begin
    m_awready <= 1'b0; m_wready <= 1'b0; m_arready <= 1'b0;
    if (!slave_dead) begin
      if (m_awvalid && !m_awready && !aw_have) begin m_awready <= 1'b1; aw_q <= m_awaddr; aw_have <= 1'b1; end
      if (m_wvalid && !m_wready && !w_have)    begin m_wready  <= 1'b1; w_q <= m_wdata; ws_q <= m_wstrb; w_have <= 1'b1; end
      if (aw_have && w_have && !m_bvalid) begin
        repeat ($urandom_range(0, 5)) @(posedge clk);
        for (i = 0; i < 4; i++) if (ws_q[i]) regs[aw_q[7:2]][8*i +: 8] <= w_q[8*i +: 8];
        m_bresp  <= (aw_q[15:0] == 16'hBAD0) ? 2'b10 : 2'b00;
        m_bvalid <= 1'b1; aw_have <= 1'b0; w_have <= 1'b0; n_slave_wr++;
      end
      if (m_bvalid && m_bready) m_bvalid <= 1'b0;
      if (m_arvalid && !m_arready && !m_rvalid) begin
        m_arready <= 1'b1;
        if (m_araddr[15:0] == 16'h8114) begin
          n_hb++;
          if (m_araddr[31:16] != 16'h2002) fail($sformatf("heartbeat address %h", m_araddr));
        end else n_slave_rd++;
        repeat ($urandom_range(1, 6)) @(posedge clk);
        m_rdata  <= regs[m_araddr[7:2]];
        m_rresp  <= (m_araddr[15:0] == 16'hBAD0) ? 2'b10 : 2'b00;
        m_rvalid <= 1'b1;
      end
      if (m_rvalid && m_rready) m_rvalid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // CPU BFM
  // ---------------------------------------------------------------------------
  task automatic cpu_wr(input [31:0] a, input [31:0] d, output [1:0] resp, output integer cycles);
    begin
      cycles = 0;
      @(posedge clk);
      s_awaddr <= a; s_wdata <= d; s_awvalid <= 1; s_wvalid <= 1; s_bready <= 1;
      @(posedge clk);
      while (!(s_awready && s_wready)) begin @(posedge clk); cycles++; end
      s_awvalid <= 0; s_wvalid <= 0;
      @(posedge clk);
      while (!s_bvalid) begin @(posedge clk); cycles++; end
      resp = s_bresp;
      s_bready <= 0;
    end
  endtask

  task automatic cpu_rd(input [31:0] a, output [31:0] d, output [1:0] resp, output integer cycles);
    begin
      cycles = 0;
      @(posedge clk);
      s_araddr <= a; s_arvalid <= 1; s_rready <= 1;
      @(posedge clk);
      while (!s_arready) begin @(posedge clk); cycles++; end
      s_arvalid <= 0;
      @(posedge clk);
      while (!s_rvalid) begin @(posedge clk); cycles++; end
      d = s_rdata; resp = s_rresp;
      s_rready <= 0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Guard 2: dead slave, heartbeat only (after one answered CPU access)
  // ---------------------------------------------------------------------------
  wire dead2; wire [15:0] to2; wire m2_arvalid, m2_rready, s2_arready, s2_rvalid;
  wire [31:0] m2_araddr;
  reg  s2_arvalid = 0, m2_arready = 0, m2_rvalid = 0, slave2_alive = 1;
  integer n2_rd = 0;
  nvrec_axil_guard #(.ADDR_W(32), .TIMEOUT_CYCLES(TMO), .HB_PERIOD_LOG2(8)) dut2 (
    .aclk(clk), .aresetn(resetn),
    .s_axi_awaddr(32'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(1'b0), .s_axi_awready(),
    .s_axi_wdata(32'd0), .s_axi_wstrb(4'hF), .s_axi_wvalid(1'b0), .s_axi_wready(),
    .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
    .s_axi_araddr(32'h2002_0000), .s_axi_arprot(3'd0), .s_axi_arvalid(s2_arvalid), .s_axi_arready(s2_arready),
    .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(s2_rvalid), .s_axi_rready(1'b1),
    .m_axi_awaddr(), .m_axi_awprot(), .m_axi_awvalid(), .m_axi_awready(1'b0),
    .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wvalid(), .m_axi_wready(1'b0),
    .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0), .m_axi_bready(),
    .m_axi_araddr(m2_araddr), .m_axi_arprot(), .m_axi_arvalid(m2_arvalid), .m_axi_arready(m2_arready),
    .m_axi_rdata(32'd0), .m_axi_rresp(2'b00), .m_axi_rvalid(m2_rvalid), .m_axi_rready(m2_rready),
    .dead(dead2), .timeouts(to2));

  // slave 2 answers the first read only, then dies (license expiry)
  always @(posedge clk) begin
    m2_arready <= 1'b0;
    if (m2_rvalid && m2_rready) begin m2_rvalid <= 1'b0; slave2_alive <= 1'b0; end
    if (slave2_alive && m2_arvalid && !m2_arready && !m2_rvalid) begin
      m2_arready <= 1'b1; m2_rvalid <= 1'b1; n2_rd++;
    end
  end
  // one CPU read on guard 2 at the start, never again
  initial begin
    @(posedge resetn); repeat (3) @(posedge clk);
    s2_arvalid <= 1'b1;
    @(posedge clk); while (!s2_arready) @(posedge clk);
    s2_arvalid <= 1'b0;
  end

  initial begin
    #2000000;
    $display("FAIL: watchdog timeout");
    $finish;
  end

  reg [31:0] d; reg [1:0] r; integer cyc, k, rd0, wr0;

  initial begin
    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (5) @(posedge clk);

    // ---- 1: live slave
    $display("Test 1: pass-through to a live slave");
    for (k = 0; k < 20; k++) begin
      cpu_wr(32'h2002_8100 + k * 4, 32'hA5A5_0000 + k, r, cyc);
      if (r != 2'b00) fail($sformatf("T1 write %0d resp %0d", k, r));
    end
    for (k = 0; k < 20; k++) begin
      cpu_rd(32'h2002_8100 + k * 4, d, r, cyc);
      if (d != regs[(32'h100 + k * 4) >> 2 & 63] || r != 2'b00)
        fail($sformatf("T1 read %0d: %h resp %0d", k, d, r));
    end
    cpu_rd(32'h2002_BAD0, d, r, cyc);
    if (r != 2'b10) fail("T1 slave SLVERR not passed through");
    s_wstrb = 4'b0010;
    cpu_wr(32'h2002_8100, 32'hFFFF_FFFF, r, cyc);
    s_wstrb = 4'hF;
    cpu_rd(32'h2002_8100, d, r, cyc);
    if (d != 32'hA5A5_FF00) fail($sformatf("T1 strobe write: %h", d));
    repeat (2000) @(posedge clk);
    if (n_hb < 2) fail($sformatf("T1 heartbeat reads %0d", n_hb));
    if (dead) fail("T1 dead with a live slave");
    $display("  T1: %0d heartbeat reads, %0d CPU reads at the slave", n_hb, n_slave_rd);

    // ---- 2: the slave dies
    $display("Test 2: slave stops answering");
    slave_dead = 1'b1;
    rd0 = n_slave_rd; wr0 = n_slave_wr;
    cpu_rd(32'h8108, d, r, cyc);
    $display("  T2: first read after death: %h resp %0d after %0d cycles, dead=%0d", d, r, cyc, dead);
    if (d != 32'hFFFF_FFFF || r != 2'b00) fail($sformatf("T2 read returned %h resp %0d", d, r));
    if (cyc > TMO + 20) fail($sformatf("T2 read took %0d cycles", cyc));
    // (the heartbeat may have found the dead slave first: then the read is fast)
    repeat (2) @(posedge clk);
    if (!dead) fail("T2 dead not set");
    for (k = 0; k < 5; k++) begin
      cpu_rd(32'h8200 + k * 4, d, r, cyc);
      if (d != 32'hFFFF_FFFF || r != 2'b00 || cyc > 4) fail($sformatf("T2 read %0d %h/%0d in %0d cycles", k, d, r, cyc));
      cpu_wr(32'h8104, 32'h1, r, cyc);
      if (r != 2'b00 || cyc > 4) fail($sformatf("T2 write %0d resp %0d in %0d cycles", k, r, cyc));
    end
    if (m_arvalid || m_awvalid || m_wvalid) fail("T2 guard still drives the dead slave");
    if (!m_bready || !m_rready) fail("T2 guard must swallow late responses");
    if (timeouts == 0) fail("T2 timeouts counter 0");

    // ---- 3: heartbeat alone
    $display("Test 3: heartbeat detects a dead slave without CPU traffic");
    if (n2_rd != 1) fail($sformatf("T3 slave 2 answered %0d reads", n2_rd));
    if (!dead2) begin
      repeat (2 * 256 + TMO + 10) @(posedge clk);
    end
    if (!dead2) fail("T3 heartbeat did not detect the dead slave");
    if (to2 != 1) fail($sformatf("T3 guard 2 timeouts %0d", to2));
    if (m2_arvalid) fail("T3 guard 2 still drives the dead slave");

    if (errors == 0) $display("PASS: tb_nvrec_axil_guard (%0d timeouts, %0d heartbeat reads)", timeouts, n_hb);
    else             $display("FAIL: tb_nvrec_axil_guard, %0d error(s)", errors);
    $finish;
  end

endmodule
