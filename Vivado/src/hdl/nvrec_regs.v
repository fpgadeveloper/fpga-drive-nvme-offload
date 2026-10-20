// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_regs -- AXI4-Lite slave front end of the nvrec_core register block
//
// Converts AXI4-Lite into a simple register bus; the register decode lives in
// nvrec_core (see include/nvrec_regs.h and docs/source/register_map.md).
//
//   write: wr_req (1 cycle) with wr_addr (word aligned), wr_data, wr_strb
//   read : rd_req (1 cycle) with rd_addr; the decoder returns rd_data in the
//          NEXT cycle (registered), which is then sent on the R channel.
//
// One transaction at a time per direction; BRESP/RRESP are always OKAY.

`timescale 1ns / 1ps

module nvrec_regs (
  input  wire          clk,
  input  wire          resetn,

  input  wire [11:0]   s_axi_awaddr,
  input  wire          s_axi_awvalid,
  output reg           s_axi_awready,
  input  wire [31:0]   s_axi_wdata,
  input  wire [3:0]    s_axi_wstrb,
  input  wire          s_axi_wvalid,
  output reg           s_axi_wready,
  output wire [1:0]    s_axi_bresp,
  output reg           s_axi_bvalid,
  input  wire          s_axi_bready,
  input  wire [11:0]   s_axi_araddr,
  input  wire          s_axi_arvalid,
  output reg           s_axi_arready,
  output reg  [31:0]   s_axi_rdata,
  output wire [1:0]    s_axi_rresp,
  output reg           s_axi_rvalid,
  input  wire          s_axi_rready,

  output reg           wr_req,
  output reg  [11:0]   wr_addr,
  output reg  [31:0]   wr_data,
  output reg  [3:0]    wr_strb,
  output reg           rd_req,
  output reg  [11:0]   rd_addr,
  input  wire [31:0]   rd_data
);

  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;

  wire wr_fire = s_axi_awready & s_axi_awvalid & s_axi_wready & s_axi_wvalid;

  always @(posedge clk) begin
    if (!resetn) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      wr_req        <= 1'b0;
      wr_addr       <= 12'd0;
      wr_data       <= 32'd0;
      wr_strb       <= 4'd0;
    end else begin
      wr_req <= wr_fire;
      if (wr_fire) begin
        wr_addr <= {s_axi_awaddr[11:2], 2'b00};
        wr_data <= s_axi_wdata;
        wr_strb <= s_axi_wstrb;
      end
      if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
      end else begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
      end
      if (wr_fire)
        s_axi_bvalid <= 1'b1;
      else if (s_axi_bready)
        s_axi_bvalid <= 1'b0;
    end
  end

  reg rd_wait;   // rd_req issued, rd_data due this cycle

  always @(posedge clk) begin
    if (!resetn) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= 32'd0;
      rd_req        <= 1'b0;
      rd_wait       <= 1'b0;
      rd_addr       <= 12'd0;
    end else begin
      rd_req  <= 1'b0;
      rd_wait <= rd_req;
      if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid && !rd_req && !rd_wait)
        s_axi_arready <= 1'b1;
      else
        s_axi_arready <= 1'b0;
      if (s_axi_arready && s_axi_arvalid) begin
        rd_req  <= 1'b1;
        rd_addr <= {s_axi_araddr[11:2], 2'b00};
      end
      if (rd_wait) begin
        s_axi_rvalid <= 1'b1;
        s_axi_rdata  <= rd_data;
      end else if (s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
