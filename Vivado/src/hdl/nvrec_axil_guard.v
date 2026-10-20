// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// nvrec_axil_guard -- AXI4-Lite timeout guard in front of the AMD NVMe Host
// Accelerator's S_AXI_LITE register slave (block-design module reference)
//
// Why: the evaluation license of the nvmeha IP stops the core ~3 h after the
// bitstream was loaded. From then on its AXI-Lite slave never answers (no
// SLVERR, no RVALID), so the next CPU read of an nvmeha register stalls the
// APU interconnect and the whole Linux system hangs. This guard forwards one
// transaction at a time and, if the slave does not answer within
// TIMEOUT_CYCLES, completes the transaction itself and latches DEAD:
//
//   * reads return DEAD_RDATA (all ones) with DEAD_RESP, writes DEAD_RESP;
//   * from then on every access is answered immediately by the guard, the
//     downstream slave is no longer driven (BREADY/RREADY stay high to swallow
//     a response that might still come);
//   * `dead` stays set until the next reset of this clock domain (bitstream
//     reload / power cycle -- the only thing that restarts an expired core).
//
// DEAD_RESP defaults to OKAY on purpose: on Zynq UltraScale+ an SLVERR/DECERR
// on a CPU load from the PL arrives at the Cortex-A53 as an SError, which
// Linux turns into a kernel panic -- the very system loss this guard exists
// to prevent. The driver detects the dead IP through nvrec_core
// (STATE.HA_DEAD / IRQ_STATUS.HA_DEAD, fed from `dead`), never from the data.
// Set DEAD_RESP = 2'b10 to get SLVERR on a bus master that handles it.
//
// Heartbeat: every 2^HB_PERIOD_LOG2 clocks with no CPU access in progress the
// guard reads offset HB_ADDR (default 0x8114, the IP's timeout configuration
// register: a plain register without read side effects) so that an expired
// core is detected even when software never touches the IP. The heartbeat
// starts after the first CPU access that the slave answered, and uses the
// upper address bits (above bit 15) of the last CPU access, so it hits the
// same 64 KB window as the CPU, whatever the interconnect passes on.
// HB_PERIOD_LOG2 = 0 disables it.
//
// Single outstanding transaction, AW and W accepted together. AXI4-Lite only.

`timescale 1ns / 1ps

module nvrec_axil_guard #(
  parameter integer ADDR_W         = 32,
  parameter integer TIMEOUT_CYCLES = 16384,          // 164 us at 100 MHz
  parameter integer HB_PERIOD_LOG2 = 24,             // 168 ms at 100 MHz, 0 = off
  parameter [15:0]  HB_ADDR        = 16'h8114,        // offset in the 64 KB window
  parameter [31:0]  DEAD_RDATA     = 32'hFFFF_FFFF,
  parameter [1:0]   DEAD_RESP      = 2'b00
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET aresetn" *)
  input  wire              aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire              aresetn,

  // from the interconnect (CPU)
  input  wire [ADDR_W-1:0] s_axi_awaddr,
  input  wire [2:0]        s_axi_awprot,
  input  wire              s_axi_awvalid,
  output wire              s_axi_awready,
  input  wire [31:0]       s_axi_wdata,
  input  wire [3:0]        s_axi_wstrb,
  input  wire              s_axi_wvalid,
  output wire              s_axi_wready,
  output reg  [1:0]        s_axi_bresp,
  output reg               s_axi_bvalid,
  input  wire              s_axi_bready,
  input  wire [ADDR_W-1:0] s_axi_araddr,
  input  wire [2:0]        s_axi_arprot,
  input  wire              s_axi_arvalid,
  output wire              s_axi_arready,
  output reg  [31:0]       s_axi_rdata,
  output reg  [1:0]        s_axi_rresp,
  output reg               s_axi_rvalid,
  input  wire              s_axi_rready,

  // to the Host Accelerator S_AXI_LITE
  output reg  [ADDR_W-1:0] m_axi_awaddr,
  output reg  [2:0]        m_axi_awprot,
  output reg               m_axi_awvalid,
  input  wire              m_axi_awready,
  output reg  [31:0]       m_axi_wdata,
  output reg  [3:0]        m_axi_wstrb,
  output reg               m_axi_wvalid,
  input  wire              m_axi_wready,
  input  wire [1:0]        m_axi_bresp,
  input  wire              m_axi_bvalid,
  output wire              m_axi_bready,
  output reg  [ADDR_W-1:0] m_axi_araddr,
  output reg  [2:0]        m_axi_arprot,
  output reg               m_axi_arvalid,
  input  wire              m_axi_arready,
  input  wire [31:0]       m_axi_rdata,
  input  wire [1:0]        m_axi_rresp,
  input  wire              m_axi_rvalid,
  output wire              m_axi_rready,

  // status (aclk domain, sticky until reset)
  output reg               dead,
  output reg  [15:0]       timeouts        // transactions completed by the guard on a timeout
);

  localparam [2:0] S_IDLE = 3'd0, S_WR = 3'd1, S_RD = 3'd2, S_HB = 3'd3,
                   S_BRESP = 3'd4, S_RRESP = 3'd5;
  localparam integer TW = $clog2(TIMEOUT_CYCLES + 1);
  localparam integer HW = (HB_PERIOD_LOG2 > 0) ? HB_PERIOD_LOG2 : 1;

  reg [2:0]    state;
  reg [TW-1:0] timer;
  reg          hb_due, hb_armed;
  reg [ADDR_W-1:0] hb_base;
  reg [HW-1:0] hb_cnt;

  wire wr_go = (state == S_IDLE) && s_axi_awvalid && s_axi_wvalid;
  wire rd_go = (state == S_IDLE) && !wr_go && s_axi_arvalid;
  wire hb_go = (state == S_IDLE) && !wr_go && !rd_go && hb_due && hb_armed && !dead;

  assign s_axi_awready = wr_go;
  assign s_axi_wready  = wr_go;
  assign s_axi_arready = rd_go;
  // accept responses whenever a transaction is open downstream, and always
  // once dead (a late response from the dead slave is swallowed)
  assign m_axi_bready  = dead || (state == S_WR);
  assign m_axi_rready  = dead || (state == S_RD) || (state == S_HB);

  wire timed_out = (timer == TIMEOUT_CYCLES[TW-1:0]);

  always @(posedge aclk) begin
    if (!aresetn) begin
      state         <= S_IDLE;
      timer         <= {TW{1'b0}};
      dead          <= 1'b0;
      timeouts      <= 16'd0;
      hb_due        <= 1'b0;
      hb_armed      <= 1'b0;
      hb_base       <= {ADDR_W{1'b0}};
      hb_cnt        <= {HW{1'b0}};
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      s_axi_rvalid  <= 1'b0;
      s_axi_rresp   <= 2'b00;
      s_axi_rdata   <= 32'd0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid  <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_awaddr  <= {ADDR_W{1'b0}};
      m_axi_awprot  <= 3'd0;
      m_axi_wdata   <= 32'd0;
      m_axi_wstrb   <= 4'd0;
      m_axi_araddr  <= {ADDR_W{1'b0}};
      m_axi_arprot  <= 3'd0;
    end else begin
      // heartbeat timer
      if (HB_PERIOD_LOG2 > 0) begin
        hb_cnt <= hb_cnt + 1'b1;
        if (&hb_cnt)
          hb_due <= 1'b1;
      end
      if (hb_go)
        hb_due <= 1'b0;

      timer <= (state == S_WR || state == S_RD || state == S_HB) ? timer + 1'b1 : {TW{1'b0}};

      case (state)
        S_IDLE: begin
          if (wr_go) begin
            if (dead) begin
              s_axi_bresp  <= DEAD_RESP;
              s_axi_bvalid <= 1'b1;
              state        <= S_BRESP;
            end else begin
              m_axi_awaddr  <= s_axi_awaddr;
              hb_base       <= s_axi_awaddr & ~{{(ADDR_W-16){1'b0}}, 16'hFFFF};
              m_axi_awprot  <= s_axi_awprot;
              m_axi_wdata   <= s_axi_wdata;
              m_axi_wstrb   <= s_axi_wstrb;
              m_axi_awvalid <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              state         <= S_WR;
            end
          end else if (rd_go) begin
            if (dead) begin
              s_axi_rdata  <= DEAD_RDATA;
              s_axi_rresp  <= DEAD_RESP;
              s_axi_rvalid <= 1'b1;
              state        <= S_RRESP;
            end else begin
              m_axi_araddr  <= s_axi_araddr;
              hb_base       <= s_axi_araddr & ~{{(ADDR_W-16){1'b0}}, 16'hFFFF};
              m_axi_arprot  <= s_axi_arprot;
              m_axi_arvalid <= 1'b1;
              state         <= S_RD;
            end
          end else if (hb_go) begin
            m_axi_araddr  <= hb_base | {{(ADDR_W-16){1'b0}}, HB_ADDR[15:0]};
            m_axi_arprot  <= 3'd0;
            m_axi_arvalid <= 1'b1;
            state         <= S_HB;
          end
        end

        S_WR: begin
          if (m_axi_awready) m_axi_awvalid <= 1'b0;
          if (m_axi_wready)  m_axi_wvalid  <= 1'b0;
          if (m_axi_bvalid) begin
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            s_axi_bresp   <= m_axi_bresp;
            s_axi_bvalid  <= 1'b1;
            hb_armed      <= 1'b1;
            state         <= S_BRESP;
          end else if (timed_out) begin
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            dead          <= 1'b1;
            timeouts      <= timeouts + 16'd1;
            s_axi_bresp   <= DEAD_RESP;
            s_axi_bvalid  <= 1'b1;
            state         <= S_BRESP;
          end
        end

        S_RD, S_HB: begin
          if (m_axi_arready) m_axi_arvalid <= 1'b0;
          if (m_axi_rvalid) begin
            m_axi_arvalid <= 1'b0;
            if (state == S_RD) begin
              s_axi_rdata  <= m_axi_rdata;
              s_axi_rresp  <= m_axi_rresp;
              s_axi_rvalid <= 1'b1;
              hb_armed     <= 1'b1;
              state        <= S_RRESP;
            end else
              state        <= S_IDLE;
          end else if (timed_out) begin
            m_axi_arvalid <= 1'b0;
            dead          <= 1'b1;
            timeouts      <= timeouts + 16'd1;
            if (state == S_RD) begin
              s_axi_rdata  <= DEAD_RDATA;
              s_axi_rresp  <= DEAD_RESP;
              s_axi_rvalid <= 1'b1;
              state        <= S_RRESP;
            end else
              state        <= S_IDLE;
          end
        end

        S_BRESP: if (s_axi_bready) begin
          s_axi_bvalid <= 1'b0;
          state        <= S_IDLE;
        end

        S_RRESP: if (s_axi_rready) begin
          s_axi_rvalid <= 1'b0;
          state        <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
