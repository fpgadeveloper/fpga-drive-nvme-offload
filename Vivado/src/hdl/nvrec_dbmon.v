// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_dbmon -- doorbell monitor (debug), dp_clk domain
//
// Pure pass-through of the NVMe Host Accelerator's M_AXI_SSD master (the
// doorbell writes it makes into the SSDs' BAR space). Each completed write
// (AW address + the data of its last W beat) is counted and the last
// ENTRIES are kept in a small circular log that software reads back through
// the nvrec_core registers (NVREC_DB_*). It adds no logic in the data path.

`timescale 1ns / 1ps

module nvrec_dbmon #(
  parameter integer ENTRIES = 8      // power of 2
) (
  input  wire          clk,
  input  wire          rst,

  // snoop of the AW / W handshakes
  input  wire [31:0]   awaddr,
  input  wire          aw_fire,
  input  wire [31:0]   wdata,
  input  wire          w_last_fire,

  output reg  [31:0]   db_count,
  output reg  [$clog2(ENTRIES)-1:0] db_next,
  output wire [ENTRIES*32-1:0] db_addr,
  output wire [ENTRIES*32-1:0] db_data
);

  localparam integer EW = $clog2(ENTRIES);

  // AW addresses waiting for their data (the IP has at most 2 writes open)
  reg  [31:0] aq [0:3];
  reg  [2:0]  aq_wr, aq_rd;
  wire        aq_empty = (aq_wr == aq_rd);

  reg  [31:0] la [0:ENTRIES-1];
  reg  [31:0] ld [0:ENTRIES-1];
  integer i;

  always @(posedge clk) begin
    if (rst) begin
      aq_wr    <= 3'd0;
      aq_rd    <= 3'd0;
      db_count <= 32'd0;
      db_next  <= {EW{1'b0}};
      for (i = 0; i < ENTRIES; i = i + 1) begin
        la[i] <= 32'd0;
        ld[i] <= 32'd0;
      end
    end else begin
      // log the AW address unless it is consumed in this very cycle
      if (aw_fire && !(w_last_fire && aq_empty)) begin
        aq[aq_wr[1:0]] <= awaddr;
        aq_wr <= aq_wr + 3'd1;
      end
      if (w_last_fire) begin
        // W may arrive before its AW is logged: use the incoming address then
        la[db_next] <= aq_empty ? awaddr : aq[aq_rd[1:0]];
        ld[db_next] <= wdata;
        if (!aq_empty)
          aq_rd <= aq_rd + 3'd1;
        db_next  <= db_next + 1'b1;
        db_count <= db_count + 32'd1;
      end
    end
  end

  genvar g;
  generate
    for (g = 0; g < ENTRIES; g = g + 1) begin : g_log
      assign db_addr[g*32 +: 32] = la[g];
      assign db_data[g*32 +: 32] = ld[g];
    end
  endgenerate

endmodule
