// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_ring_addr -- ring address function of the NVMe-offload recorder
// (register map 1.3, include/nvrec_regs.h "Ring addresses"), shared by the
// ring writer (nvrec_wr), the ring reader (nvrec_rd) and the command builder
// (nvrec_cmd, PRP1 / PRP2).
//
// Byte g of the ring (g = slot << chunk_shift | offset) is stored at
//   split = 0, mem1 = 0 : port 0, base0 + g                     (1.2 ring)
//   split = 0, mem1 = 1 : port 1, base1 + g                     (memory 1 only)
//   split = 1           : i = g >> S, r = i[0],
//                         port r, base_r + ((i >> 1) << S) + (g & (2^S - 1))
// with S = stripe_shift (12 .. chunk_shift, clamped by the caller). The
// in-memory offset of the split ring is g with bit S removed:
//   off = ((g >> 1) & ~(2^S - 1)) | (g & (2^S - 1)).
// Bases are 4 KB aligned ([11:0] ignored), so the 64-bit add only covers
// [ADDR_W-1:12].
//
// Two register stages (latency 2): g at cycle t -> {port, addr} valid at
// t + 2. The configuration inputs are static during a run. N_RING_PORTS = 1
// folds the function to port 0, {base0[ADDR_W-1:12], 12'd0} + g (1.2).

`timescale 1ns / 1ps

module nvrec_ring_addr #(
  parameter integer N_RING_PORTS = 2,  // 1 or 2
  parameter integer G_W    = 35,       // ring byte offset width
  parameter integer ADDR_W = 64
) (
  input  wire              clk,
  // static configuration (latched at START)
  input  wire              split,
  input  wire              mem1,
  input  wire [4:0]        stripe_shift, // 12 .. 22
  input  wire [ADDR_W-1:0] base0,
  input  wire [ADDR_W-1:0] base1,
  // ring byte offset
  input  wire [G_W-1:0]    g,
  // result, two cycles later
  output reg               port,
  output reg  [ADDR_W-1:0] addr
);

  generate
    if (N_RING_PORTS != 1 && N_RING_PORTS != 2) begin : g_bad_ports
      N_RING_PORTS_must_be_1_or_2 u_param_error ();
    end
  endgenerate

  wire          two     = (N_RING_PORTS == 2);
  wire          s_split = two & split;
  wire          s_mem1  = two & mem1 & ~split;
  // low mask of the stripe: 2^S - 1 (S >= 12)
  wire [G_W-1:0] lo_mask = ~({G_W{1'b1}} << stripe_shift);

  reg            r1;
  reg  [G_W-1:0] off1;

  always @(posedge clk) begin
    // stage 1: memory and offset inside it
    r1   <= s_split ? g[stripe_shift] : s_mem1;
    off1 <= s_split ? (({1'b0, g[G_W-1:1]} & ~lo_mask) | (g & lo_mask)) : g;
    // stage 2: base + offset (4 KB aligned bases)
    port <= r1;
    addr <= {((r1 ? base1[ADDR_W-1:12] : base0[ADDR_W-1:12]) +
              {{(ADDR_W-G_W){1'b0}}, off1[G_W-1:12]}), off1[11:0]};
  end

endmodule
