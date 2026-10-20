// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_inj -- CPU command injector of the NVMe-offload recorder (dp_clk)
//
// Holds one 64-byte SQE written by software (INJ_SQE[0..15]); a write of
// INJ_CTRL.SUBMIT presents it (with the SSD / SQ given in INJ_CTRL) to the
// submission arbiter in nvrec_cmd, which forces CID bit 15 to 1 and pushes it
// on the NVMe Host Accelerator's hardware SQ stream. BUSY stays 1 until the
// arbiter has taken it.
//
// Completions with CID bit 15 = 1 are routed here by nvrec_cq and kept in a
// 16-entry FIFO; software reads the head entry (INJ_CQE[0..3], INJ_CQ_INFO)
// and pops it with a write to INJ_CQ_POP. irq = FIFO not empty.
//
// Register window (byte offsets from NVREC_INJ_SQE(0) = 0x300), word index:
//   0..15 INJ_SQE, 16 INJ_CTRL, 17 INJ_STATUS, 18 INJ_CQ_POP, 19 INJ_CQ_INFO,
//   20..23 INJ_CQE, 24 INJ_SUBMITTED, 25 INJ_COMPLETED.

`timescale 1ns / 1ps

module nvrec_inj #(
  parameter integer FIFO_D = 16   // power of 2
) (
  input  wire          clk,
  input  wire          rst,

  // register bus (word index inside the 0x300-0x37F window)
  input  wire          wr_en,
  input  wire [4:0]    wr_word,
  input  wire [31:0]   wr_data,
  input  wire [4:0]    rd_word,
  output reg  [31:0]   rd_data,       // combinational

  // to the submission arbiter
  output reg           inj_valid,
  output wire [511:0]  inj_sqe,
  output reg  [4:0]    inj_ssd,
  output reg  [5:0]    inj_sq,
  input  wire          inj_accept,
  input  wire [31:0]   inj_submitted,

  // completions from nvrec_cq
  input  wire          push,
  input  wire [127:0]  push_cqe,
  input  wire [15:0]   push_info,
  output wire          afull,
  output wire          irq
);

  localparam integer PW = $clog2(FIFO_D);

  reg [31:0] sqe [0:15];
  genvar g;
  generate
    for (g = 0; g < 16; g = g + 1) begin : g_sqe
      assign inj_sqe[g*32 +: 32] = sqe[g];
    end
  endgenerate

  // CQE FIFO
  reg  [143:0] fifo [0:FIFO_D-1];
  reg  [PW:0]  wp, rp;
  wire [PW:0]  cnt   = wp - rp;
  wire         empty = (cnt == 0);
  assign afull = (cnt >= FIFO_D - 1);
  assign irq   = !empty;
  wire [143:0] head  = fifo[rp[PW-1:0]];

  reg  [31:0]  completed;
  integer i;

  always @(posedge clk) begin
    if (rst) begin
      inj_valid <= 1'b0;
      inj_ssd   <= 5'd0;
      inj_sq    <= 6'd0;
      wp        <= {(PW+1){1'b0}};
      rp        <= {(PW+1){1'b0}};
      completed <= 32'd0;
      for (i = 0; i < 16; i = i + 1)
        sqe[i] <= 32'd0;
    end else begin
      if (inj_accept)
        inj_valid <= 1'b0;
      if (wr_en) begin
        if (wr_word < 5'd16)
          sqe[wr_word[3:0]] <= wr_data;
        else if ((wr_word == 5'd16) && wr_data[0] && !inj_valid) begin
          inj_valid <= 1'b1;
          inj_ssd   <= wr_data[12:8];
          inj_sq    <= wr_data[21:16];
        end else if ((wr_word == 5'd18) && !empty)
          rp <= rp + 1'b1;
      end
      if (push && (cnt != FIFO_D)) begin
        fifo[wp[PW-1:0]] <= {push_info, push_cqe};
        wp <= wp + 1'b1;
        completed <= completed + 32'd1;
      end
    end
  end

  always @(*) begin
    rd_data = 32'd0;
    if (rd_word < 5'd16)
      rd_data = sqe[rd_word[3:0]];
    else case (rd_word)
      5'd16: rd_data = {31'd0, inj_valid};
      5'd17: rd_data = {{(32-PW-9){1'b0}}, cnt, 6'd0, !empty, inj_valid};
      5'd19: rd_data = empty ? 32'd0 : {16'd0, head[143:128]};
      5'd20: rd_data = empty ? 32'd0 : head[31:0];
      5'd21: rd_data = empty ? 32'd0 : head[63:32];
      5'd22: rd_data = empty ? 32'd0 : head[95:64];
      5'd23: rd_data = empty ? 32'd0 : head[127:96];
      5'd24: rd_data = inj_submitted;
      5'd25: rd_data = completed;
      default: rd_data = 32'd0;
    endcase
  end

endmodule
