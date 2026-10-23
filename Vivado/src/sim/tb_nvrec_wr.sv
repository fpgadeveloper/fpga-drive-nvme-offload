// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_nvrec_wr -- self-checking testbench for nvrec_wr (ring writer)
//
// Runs for DATA_WIDTH 128, 256 and 512 (sim.tcl, see the sim_runs line below).
//
// A FWFT FIFO model (64 KB deep, backpressured source: never drops) feeds the
// writer with beats of the fdrec test pattern (16-byte words {~n, n}, word n
// of the stream carries n); an AXI4 write slave model with random
// AW/W/B delays stores the bursts in a sparse memory. The testbench plays
// the completion side: it releases filled chunks (rel_cnt) after a random
// delay, always in order.
//
// Checks:
//   1. every burst: INCR, len <= 4 KB / BEAT_BYTES, never crosses 4 KB, inside the slot of
//      the chunk being written, address = slot base + offset (ring wrap)
//   2. every filled chunk c: memory of slot c % N holds beats
//      c*CB .. c*CB+CB-1 at the moment filled_cnt counts it
//   3. ring flow control: never more than num_chunks chunks opened and not
//      released (no slot overwritten before its release), ring_full seen
//   4. length_chunks: exactly that many chunks, done, no partial
//   5. stop: the FIFO content at stop is written, the open chunk is padded
//      with zeros to a whole LBA (512 B and 4 KB), final_partial/last_bytes,
//      pad_bytes, done
//   6. abort: issued bursts complete, no more bursts, done
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).
//
// sim_runs: DATA_WIDTH=128 DATA_WIDTH=256 DATA_WIDTH=512

`timescale 1ns / 1ps

module tb_nvrec_wr #(
  parameter integer DATA_WIDTH = 256
);

  localparam integer BB     = DATA_WIDTH / 8;          // bytes per beat
  localparam integer WPB    = DATA_WIDTH / 128;        // pattern words per beat
  localparam integer BURST  = 4096 / BB;               // max burst length
  localparam integer SLOT_W = 11;
  localparam integer FDEPTH = 65536 / BB;              // 64 KB
  localparam integer CNT_W  = $clog2(FDEPTH) + 1;

  // beat k of the stream: words k*WPB .. k*WPB+WPB-1
  function automatic [DATA_WIDTH-1:0] beat_of(input longint k);
    longint n;
    begin
      for (int w = 0; w < WPB; w++) begin
        n = k * WPB + w;
        beat_of[128*w +: 128] = {~n[63:0], n[63:0]};
      end
    end
  endfunction

  reg clk = 1'b0;
  always #2.0 clk = ~clk;   // 250 MHz
  reg rst = 1'b1;

  // configuration
  reg         start = 0, stop = 0, abort = 0;
  reg  [63:0] ring_base = 64'h0000_0008_1234_5000;   // 4 KB aligned, not chunk aligned
  reg  [4:0]  chunk_shift = 5'd16;
  reg  [SLOT_W:0] num_chunks = 4;
  reg  [3:0]  lba_shift = 4'd9;
  reg  [31:0] length_chunks = 0;
  reg  [31:0] rel_cnt = 0;

  // FIFO model
  reg  [63:0] q [$];
  reg  [63:0] src_k = 0;            // next beat to generate
  reg         src_en = 0;
  integer     src_rate = 100;       // % of cycles a beat is pushed
  reg  [DATA_WIDTH-1:0] fifo_tdata = {DATA_WIDTH{1'b0}};
  reg          fifo_tvalid = 1'b0;
  wire         fifo_tready;
  reg  [CNT_W-1:0] fifo_count = 0;
  // FIFO outputs follow the queue (updated after every change)
  task automatic q_update();
    begin
      fifo_tvalid = (q.size() > 0);
      fifo_tdata  = (q.size() > 0) ? beat_of(q[0]) : {DATA_WIDTH{1'b0}};
      fifo_count  = (q.size() > FDEPTH) ? FDEPTH : q.size();
    end
  endtask

  // AXI
  wire [63:0]  awaddr;
  wire [7:0]   awlen;
  wire         awvalid;
  reg          awready = 0;
  wire [DATA_WIDTH-1:0] wdata;
  wire         wlast, wvalid;
  reg          wready = 0;
  reg  [1:0]   bresp = 0;
  reg          bvalid = 0;
  wire         bready;

  wire [31:0] opened_cnt, filled_cnt, pad_bytes, bresp_errs;
  wire        final_partial, done, busy, ring_full;
  wire [22:0] last_bytes;
  wire [63:0] beats_out, run_beats, full_cycles;

  nvrec_wr #(.DATA_WIDTH(DATA_WIDTH), .SLOT_W(SLOT_W), .CNT_W(CNT_W), .ADDR_W(64)) dut (
    .clk(clk), .rst(rst), .start(start), .stop(stop), .abort(abort),
    .ring_base(ring_base), .chunk_shift(chunk_shift), .num_chunks(num_chunks),
    .lba_shift(lba_shift), .length_chunks(length_chunks), .rel_cnt(rel_cnt),
    .fifo_tdata(fifo_tdata), .fifo_tvalid(fifo_tvalid), .fifo_tready(fifo_tready),
    .fifo_count(fifo_count),
    .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .opened_cnt(opened_cnt), .filled_cnt(filled_cnt), .final_partial(final_partial),
    .last_bytes(last_bytes), .done(done), .busy(busy), .ring_full(ring_full),
    .beats_out(beats_out), .run_beats(run_beats), .pad_bytes(pad_bytes),
    .full_cycles(full_cycles), .bresp_errs(bresp_errs));

  integer errors = 0;
  task automatic fail(input string msg);
    begin
      $display("FAIL: %s (t=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Source: push beats while enabled and the FIFO has room; FIFO pop
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (fifo_tvalid && fifo_tready)
      void'(q.pop_front());
    if (src_en && (q.size() < FDEPTH) && ($urandom_range(99) < src_rate)) begin
      q.push_back(src_k);
      src_k = src_k + 1;
    end
    q_update();
  end

  // ---------------------------------------------------------------------------
  // AXI write slave model
  // ---------------------------------------------------------------------------
  reg [DATA_WIDTH-1:0] mem [longint];
  typedef struct { longint addr; int len; } aw_t;
  aw_t awq [$];
  reg [DATA_WIDTH:0] wbq [$];
  int  bpend = 0;
  longint cur_addr; int cur_beat; int cur_len; bit cur_act = 0;
  int  aw_bursts = 0;

  // expected chunk of the burst being issued: tracked by a shadow of the writer
  always @(posedge clk) begin
    awready <= ($urandom_range(3) != 0);
    wready  <= ($urandom_range(4) != 0);
    if (awvalid && awready) begin
      aw_t a;
      a.addr = awaddr; a.len = awlen + 1;
      if ((awaddr[11:0] + (awlen + 1) * BB) > 4096)
        fail($sformatf("burst crosses 4 KB: addr %h len %0d", awaddr, awlen + 1));
      if (awlen + 1 > BURST) fail($sformatf("burst longer than 4 KB: len %0d", awlen + 1));
      if (awaddr % BB != 0) fail("unaligned burst address");
      awq.push_back(a);
      aw_bursts++;
    end
    if (wvalid && wready) begin
      wbq.push_back({wlast, wdata});
    end
    // match W beats (possibly sent before their AW) with AW bursts
    while (wbq.size() > 0 && (cur_act || awq.size() > 0)) begin
      if (!cur_act) begin
        cur_addr = awq[0].addr; cur_len = awq[0].len; cur_beat = 0; cur_act = 1;
        void'(awq.pop_front());
      end
      mem[cur_addr + cur_beat * BB] = wbq[0][DATA_WIDTH-1:0];
      if (wbq[0][DATA_WIDTH] != (cur_beat == cur_len - 1)) fail("WLAST mismatch");
      cur_beat++;
      if (wbq[0][DATA_WIDTH]) begin
        cur_act = 0;
        bpend++;
      end
      void'(wbq.pop_front());
    end
    if (bvalid && bready) begin
      bvalid <= 1'b0;
    end else if (!bvalid && bpend > 0 && $urandom_range(3) == 0) begin
      bvalid <= 1'b1;
      bpend--;
    end
  end

  // ---------------------------------------------------------------------------
  // Checker: filled chunks, ring flow control, release
  // ---------------------------------------------------------------------------
  longint chunk_bytes;
  int     chk_filled = 0;     // chunks checked
  int     rel_delay  = 20;    // max cycles before releasing a checked chunk
  bit     rel_hold   = 0;     // stop releasing
  int     rel_pending [$];
  bit     saw_ring_full = 0;
  longint first_beat = 0;     // beat index of chunk 0 of the run

  task automatic check_chunk(input int c, input longint nbytes, input longint pad);
    longint base, k, kk;
    int slot;
    begin
      slot = c % num_chunks;
      base = {ring_base[63:12], 12'd0} + slot * chunk_bytes;
      for (k = 0; k < (nbytes - pad) / BB; k++) begin
        kk = first_beat + c * (chunk_bytes / BB) + k;
        if (!mem.exists(base + k * BB) || mem[base + k * BB] !== beat_of(kk)) begin
          fail($sformatf("chunk %0d beat %0d: got %h exp %h", c, k,
                         mem.exists(base + k*BB) ? mem[base + k*BB] : {DATA_WIDTH{1'bx}}, beat_of(kk)));
          break;
        end
      end
      for (k = (nbytes - pad) / BB; k < nbytes / BB; k++)
        if (!mem.exists(base + k * BB) || mem[base + k * BB] !== {DATA_WIDTH{1'b0}}) begin
          fail($sformatf("chunk %0d pad beat %0d not zero", c, k));
          break;
        end
    end
  endtask

  bit run_on = 0;
  always @(posedge clk) begin
    if (!rst && run_on) begin
      if (ring_full) saw_ring_full = 1;
      if ((opened_cnt - rel_cnt) > num_chunks)
        fail("more chunks open than the ring holds");
      if (filled_cnt > chk_filled) begin
        // full chunks are checked here; the final partial one by the test
        if (!(final_partial && filled_cnt == chk_filled + 1)) begin
          check_chunk(chk_filled, chunk_bytes, 0);
        end
        rel_pending.push_back($urandom_range(rel_delay));
        chk_filled++;
      end
      if (!rel_hold && rel_pending.size() > 0) begin
        if (rel_pending[0] == 0) begin
          void'(rel_pending.pop_front());
          rel_cnt <= rel_cnt + 1;
        end else
          rel_pending[0] = rel_pending[0] - 1;
      end
    end
  end

  task automatic do_start();
    begin
      run_on = 0;
      @(posedge clk);
      first_beat = src_k - q.size();
      chk_filled = 0;
      rel_cnt <= 0;
      rel_pending.delete();
      start <= 1; @(posedge clk); start <= 0;
      @(posedge clk); run_on = 1;
    end
  endtask

  task automatic wait_done(input int maxcyc);
    int n;
    begin
      n = 0;
      while (!done && n < maxcyc) begin @(posedge clk); n++; end
      if (!done) fail("timeout waiting for done");
      repeat (5) @(posedge clk);
    end
  endtask

  // drain the FIFO model between tests (writer idle)
  task automatic flush_src();
    begin
      src_en = 0;
      @(posedge clk);
      q.delete();
      q_update();
    end
  endtask

  // watchdog
  initial begin
    #20ms;
    $display("FAIL: watchdog timeout");
    $finish;
  end

  longint exp_bytes, exp_pad, nb;
  int     n_before;

  initial begin
    chunk_bytes = 1 << 16;
    repeat (10) @(posedge clk);
    rst <= 0;
    repeat (5) @(posedge clk);

    // ---- Test 1: LENGTH_CHUNKS = 10, ring of 4, 64 KB chunks, slow release
    $display("Test 1: length 10 chunks, 4-slot ring, ring wrap, out-of-order-free release");
    length_chunks = 10; num_chunks = 4; rel_delay = 40000; src_en = 1; src_rate = 100;
    do_start();
    wait_done(800000);
    if (filled_cnt != 10) fail($sformatf("test1 filled %0d", filled_cnt));
    if (final_partial)    fail("test1 final_partial set");
    if (!saw_ring_full)   fail("test1 ring_full never seen (release too fast?)");
    if (run_beats != 10 * chunk_bytes / BB) fail($sformatf("test1 run_beats %0d", run_beats));
    if (pad_bytes != 0) fail("test1 pad");
    flush_src();

    // ---- Test 2: stop with a partial chunk, 512 B LBA, throttled source
    $display("Test 2: stop -> partial chunk padded to 512 B");
    length_chunks = 0; num_chunks = 8; rel_delay = 50; src_en = 1; src_rate = 60;
    lba_shift = 9;
    do_start();
    // run until ~2.3 chunks written, then stop the source and the writer
    wait (run_beats > (2 * chunk_bytes / BB) + 300 / WPB);
    src_en = 0;
    repeat (3) @(posedge clk);
    // stop: everything in the FIFO model must be written
    nb = src_k - first_beat;      // total beats generated in this run
    stop <= 1; @(posedge clk); stop <= 0;
    wait_done(100000);
    exp_bytes = nb * BB - 2 * chunk_bytes;
    exp_pad   = ((exp_bytes + 511) / 512) * 512 - exp_bytes;
    if (filled_cnt != 3) fail($sformatf("test2 filled %0d (exp 3)", filled_cnt));
    if (!final_partial) fail("test2 final_partial not set");
    if (last_bytes != exp_bytes + exp_pad)
      fail($sformatf("test2 last_bytes %0d exp %0d", last_bytes, exp_bytes + exp_pad));
    if (pad_bytes != exp_pad) fail($sformatf("test2 pad %0d exp %0d", pad_bytes, exp_pad));
    if (run_beats != nb) fail($sformatf("test2 run_beats %0d exp %0d", run_beats, nb));
    check_chunk(2, exp_bytes + exp_pad, exp_pad);
    flush_src();

    // ---- Test 3: stop with 4 KB LBA, 128 KB chunks
    $display("Test 3: stop -> partial chunk padded to 4 KB, 128 KB chunks");
    chunk_shift = 17; chunk_bytes = 1 << 17; lba_shift = 12; num_chunks = 3; rel_delay = 10;
    src_en = 1; src_rate = 100;
    do_start();
    wait (run_beats > (chunk_bytes / BB) + 1000 / WPB);
    src_en = 0;
    repeat (3) @(posedge clk);
    nb = src_k - first_beat;
    stop <= 1; @(posedge clk); stop <= 0;
    wait_done(100000);
    exp_bytes = nb * BB - chunk_bytes;
    exp_pad   = ((exp_bytes + 4095) / 4096) * 4096 - exp_bytes;
    if (filled_cnt != 2) fail($sformatf("test3 filled %0d", filled_cnt));
    if (last_bytes != exp_bytes + exp_pad) fail($sformatf("test3 last_bytes %0d", last_bytes));
    check_chunk(1, exp_bytes + exp_pad, exp_pad);
    flush_src();

    // ---- Test 4: stop exactly at a chunk boundary (no partial chunk)
    $display("Test 4: stop at a chunk boundary");
    chunk_shift = 16; chunk_bytes = 1 << 16; lba_shift = 9; num_chunks = 4;
    src_en = 0;
    do_start();
    // push exactly 2 chunks of beats
    begin
      longint target;
      target = first_beat + 2 * chunk_bytes / BB;
      while (src_k < target) begin
        @(posedge clk);
        if (q.size() < FDEPTH) begin q.push_back(src_k); src_k++; q_update(); end
      end
    end
    wait (run_beats == 2 * chunk_bytes / BB);
    repeat (20) @(posedge clk);
    stop <= 1; @(posedge clk); stop <= 0;
    wait_done(100000);
    if (filled_cnt != 2 || final_partial || pad_bytes != 0)
      fail($sformatf("test4 filled %0d partial %0d pad %0d", filled_cnt, final_partial, pad_bytes));
    flush_src();

    // ---- Test 5: abort while the ring is full
    $display("Test 5: abort");
    num_chunks = 2; rel_hold = 1; src_en = 1; src_rate = 100; length_chunks = 0;
    do_start();
    wait (ring_full);
    repeat (5000) @(posedge clk);
    n_before = aw_bursts;
    abort <= 1; @(posedge clk); abort <= 0;
    wait_done(10000);
    repeat (100) @(posedge clk);
    if (aw_bursts != n_before) fail("bursts issued after abort while ring full");
    if (filled_cnt != 2) fail($sformatf("test5 filled %0d", filled_cnt));
    if (full_cycles == 0) fail("test5 full_cycles 0");
    rel_hold = 0;
    flush_src();

    if (bresp_errs != 0) fail("bresp errors");
    if (errors == 0) $display("PASS: tb_nvrec_wr DATA_WIDTH %0d (%0d bursts)", DATA_WIDTH, aw_bursts);
    else             $display("FAIL: tb_nvrec_wr, %0d error(s)", errors);
    $finish;
  end

endmodule
