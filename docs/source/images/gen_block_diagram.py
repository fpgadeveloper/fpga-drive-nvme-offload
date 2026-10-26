#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the diagrams for the FPGA Drive NVMe Offload Recorder docs.

    nvrec-block-zynqmp.png     the whole design on a Zynq UltraScale+ target
                               (Vivado/src/bd/bd_zynqmp.tcl, xdma root ports)
    nvrec-block-versal.png     the whole design on a Versal target
                               (bd_versal.tcl as built for vck190_fmcp1, qdma root ports)
    nvrec-record-path.png      the recording path through nvrec_core and the
                               NVMe Host Accelerator, step by step
    nvrec-play-path.png        the playback path, step by step

Conventions shared with the other Opsero reference-design diagrams
(fpga-drive-recorder/docs/source/images/gen_block_diagram.py and
fpga-drive-aximm-pcie): same palette, helpers and fonts, left-to-right layout
with the processor and its DDR on the left and the FMC card on the right;
blue arrows = processor (and doorbell) access to registers and PCIe BARs,
green arrows = DMA traffic into or out of DDR memory and the queue window,
pale green arrows = AXI4-Stream.

The PNGs are written next to this script (i.e. into docs/source/images/).

Usage (from anywhere):
    python3 docs/source/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyArrowPatch, Circle
from matplotlib.lines import Line2D

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # soft logic (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # hard blocks: PCIe, GT (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_SLOT_FILL    = "#FFFFFF"                                # M.2 slots (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clocking (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # notes / control caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # DMA arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # host access + link arrows
C_REFCLK_LINE  = "#C8823C"                                # clocks (orange)
C_THIN         = "#8C8C8C"                                # sideband / interrupts
C_MUTED        = "#6E6E6E"
TXT = "#1A1A1A"
# recorder additions (same family of tints)
C_USER_FILL    = "#E2F0E4"; C_USER_EDGE    = "#7FB08A"   # user insertion points
C_DATA_LINE    = "#6E8F1E"                                # zero-copy data path (dark green)
C_CTRL_LINE    = "#4A7DB5"                                # control path (dark blue)
C_WARN         = "#A0522D"                                # contract annotations


def box(ax, x, y, w, h, fc, ec, label, fs=10, lw=1.2, weight="normal",
        txtcolor=None, ls="-", z=2):
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, ls=ls,
                               zorder=z))
    if label:
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fs, color=txtcolor or TXT, weight=weight,
                zorder=z + 1, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.4, ls="-", z=2):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw, ls=ls, z=z)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=z + 1,
            linespacing=1.15)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=z + 1, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=False, bh=1.1, hh=2.0,
           hl=1.6, fs=7.4, lw=1.0, lab_dy=2.9, lab_color=None, z=2):
    """Horizontal block arrow from x0 to x1 (head at x1; both ends if double)."""
    if double:
        lo, hi = min(x0, x1), max(x0, x1)
        pts = [(lo, yc), (lo + hl, yc + hh), (lo + hl, yc + bh),
               (hi - hl, yc + bh), (hi - hl, yc + hh), (hi, yc),
               (hi - hl, yc - hh), (hi - hl, yc - bh),
               (lo + hl, yc - bh), (lo + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0
        neck = x1 - s * hl
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=lab_color or TXT, zorder=z + 1, linespacing=1.15)


def vblock(ax, xc, y0, y1, fc, ec, bw=1.0, hw=1.9, hl=1.5, lw=1.0, double=True,
           z=2):
    """Vertical block arrow from y0 to y1 (head at y1; both ends if double)."""
    if double:
        lo, hi = min(y0, y1), max(y0, y1)
        pts = [(xc, lo), (xc + hw, lo + hl), (xc + bw, lo + hl),
               (xc + bw, hi - hl), (xc + hw, hi - hl), (xc, hi),
               (xc - hw, hi - hl), (xc - bw, hi - hl),
               (xc - bw, lo + hl), (xc - hw, lo + hl)]
    else:
        s = 1.0 if y1 >= y0 else -1.0
        neck = y1 - s * hl
        pts = [(xc + bw, y0), (xc + bw, neck), (xc + hw, neck), (xc, y1),
               (xc - hw, neck), (xc - bw, neck), (xc - bw, y0)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))


def route(ax, pts, color, lw=1.3, ls="-", z=3, ms=9):
    """Thin elbow arrow through the points in pts (head at the last point)."""
    xs, ys = zip(*pts[:-1])
    ax.add_line(Line2D(list(xs) + [pts[-2][0]], list(ys) + [pts[-2][1]],
                       color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt", solid_joinstyle="miter"))
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=ms, lw=lw, color=color,
                                 zorder=z, shrinkA=0, shrinkB=0))


def line(ax, pts, color, lw=1.1, ls="-", z=3):
    xs, ys = zip(*pts)
    ax.add_line(Line2D(xs, ys, color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt"))


def clk_tag(ax, x, y, text, fs=7.2, ha="center"):
    """An orange clock-domain label."""
    ax.text(x, y, text, ha=ha, va="center", fontsize=fs, color=C_REFCLK_LINE,
            weight="bold", zorder=6, linespacing=1.15)


def marker(ax, x, y, n, color=C_CTRL_LINE, r=1.25, fs=7.5):
    """A numbered circle (step marker)."""
    ax.add_patch(Circle((x, y), r, fc="white", ec=color, lw=1.3, zorder=7))
    ax.text(x, y, str(n), ha="center", va="center", fontsize=fs, weight="bold",
            color=color, zorder=8)


def new_fig(w=17.0, h=10.6, xmax=170, ymax=106):
    fig, ax = plt.subplots(figsize=(w, h), dpi=120)
    ax.set_xlim(0, xmax)
    ax.set_ylim(0, ymax)
    ax.axis("off")
    return fig, ax


def save(fig, name):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    plt.close(fig)
    print("wrote", out)


def legend(ax, x, y, data_bits=256):
    """Arrow-colour key used by the block diagrams."""
    harrow(ax, x, x + 6.0, y, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5,
           hl=1.2)
    ax.text(x + 7.5, y, "processor and doorbell access (registers, PCIe BAR / ECAM)",
            ha="left", va="center", fontsize=7.0, color=TXT)
    harrow(ax, x, x + 6.0, y - 3.6, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.8,
           hh=1.5, hl=1.2)
    ax.text(x + 7.5, y - 3.6, "DMA into / out of DDR and the queue window",
            ha="left", va="center", fontsize=7.0, color=TXT)
    harrow(ax, x, x + 6.0, y - 7.2, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5,
           hl=1.2)
    ax.text(x + 7.5, y - 7.2, "AXI4-Stream (data %d bit, SQE 512, CQE 128)" % data_bits,
            ha="left", va="center", fontsize=7.0, color=TXT)


# -----------------------------------------------------------------------------
# 1. Whole design, per device family.
#
# Every string of the zynqmp entry comes from Vivado/src/bd/bd_zynqmp.tcl (cell
# and port names, clocks, interrupts, address map); the versal entry likewise
# from bd_versal.tcl (vck190_fmcp1, the only Versal target).
# -----------------------------------------------------------------------------
FAMILIES = {
    "zynqmp": dict(
        out="nvrec-block-zynqmp.png",
        title="FPGA Drive NVMe Offload Recorder  —  Zynq UltraScale+ designs",
        proc_title="Zynq\nUltraScale+\nPS",
        proc_body="Arm Cortex-A53\n\nLinux (Yocto / EDF)\nnvrec driver\nnvrec / nvplay\n\n"
                  "SSD bring-up,\nrun set-up and\nstatistics only\n\n"
                  "pl_clk0  100 MHz\npl_clk1  250 MHz\n(dp_clk)\npl_clk2  250 MHz\n(src_clk)\n"
                  "pl_clk3  322 / 328 MHz\n(HP2)",
        ddr="PS DDR4",
        ddr_body="ring (CMA, 512 MB default)\nPRP lists, admin queues",
        ctl_lbl="M_AXI_HPM0_FPD →\nperiph_intercon_0  (AXI-Lite)",
        smc="axi_smc_dma\n256 → 128\nbit\n\nto PS port\nS_AXI_HP2_FPD\n@ pl_clk3,\nnon-\ncoherent",
        data_bits=256,
        ing_body="async, 256 KB\nfull → drop + count",
        egr_body="async, 128 KB,\nlossless",
        dp_clk="dp_clk  250 MHz (pl_clk1)",
        src_clk="src_clk  250 MHz (pl_clk2)",
        lite_clk="pl_clk0  100 MHz",
        nvmeha_clk="clk_core = dp_clk,  clk_axi_lite = pl_clk0 (100 MHz)",
        smc_db="smc_db",
        db_lbl="",
        smc_q="smc_q",
        q_lbl="",
        bar_box=("smc_bar_0", "smc_bar_1"),
        ssd_box=("smc_ssd_0", "smc_ssd_1"),
        host_lbl=("M_AXI_HPM0_FPD →\nperiph_intercon_0", "M_AXI_HPM1_FPD →\nperiph_intercon_1"),
        nvme_lbl=("S_AXI_HP0_FPD", "S_AXI_HP1_FPD"),
        rp_title=("xdma_0", "xdma_1"),
        rp_body=("DMA/Bridge Subsystem for PCIe\nAXI Bridge, Root Port, Gen3\n\n"
                 "S_AXI_B: BAR0 window 0xA000_0000\nM_AXI_B: the SSD's DMA",
                 "DMA/Bridge Subsystem for PCIe\nAXI Bridge, Root Port, Gen3\n\n"
                 "S_AXI_B: BAR0 window 0xB000_0000\nM_AXI_B: the SSD's DMA"),
        pcie_clk="axi_aclk  250 MHz (PCIe)",
        gt_body="GTH / GTY\nx4",
        link=("x4 @ 8 GT/s\nFMC DP0–3", "x4 @ 8 GT/s\nFMC DP4–7"),
        irq="xdma interrupt_out + MSI → pl_ps_irq0[5:0];  nvrec_core_0/irq → pl_ps_irq0[6] (SPI 95);  "
            "nvmeha_0/ha_interrupt → pl_ps_irq0[7] (SPI 96)",
        notes="SSD DMA: xdma_N/M_AXI_B → smc_ssd_N → S_AXI_HPN_FPD (ring data, PRP lists, admin queues)  or  → smc_q → "
              "nvmeha_0/S_AXI_SSD (I/O SQ / CQ, 0x9000_0000).\n"
              "Doorbells: nvmeha_0/M_AXI_SSD → doorbell monitor → smc_db → smc_bar_N → xdma_N/S_AXI_B (the SSD's BAR0).  "
              "periph_intercon_N also reaches xdma_N/S_AXI_LITE (ECAM).\n"
              "The PCIe part (root ports, reference clocks, PERST#, SSD2 power) is the design of fpga-drive-aximm-pcie.\n"
              "Split ring (map 1.3, zcu106_hpc0): ring port 1 nvrec_core_0/m_axi1 and smc_ssd_N (3rd master) → smc_mig → ddr4_0 "
              "(soldered 2 GB PL DDR4, 0x20_0000_0000, not mapped to the PS); uzev: single ring.",
    ),
    "versal": dict(
        out="nvrec-block-versal.png",
        title="FPGA Drive NVMe Offload Recorder  —  Versal designs  (vck190_fmcp1)",
        proc_title="Versal\nCIPS",
        proc_body="versal_cips_0\nArm Cortex-A72\n\nLinux (Yocto / EDF)\nnvrec driver\nnvrec / nvplay\n\n"
                  "SSD bring-up,\nrun set-up and\nstatistics only\n\n"
                  "pl0_ref_clk 250 MHz\npl1_ref_clk 250 MHz\n(dp_clk)\npl2_ref_clk 250 MHz\n(src_clk)\n"
                  "pl3_ref_clk 100 MHz",
        ddr="DDR4 via NoC",
        ddr_body="axi_noc_0 ring A: S09_AXI\n512 bit, 14000 MB/s → MC_2\nSSD1: S08 → MC_1\nSSD2: S10 → MC_3",
        ctl_lbl="M_AXI_FPD →\nsmc_m_axi_fpd  (AXI-Lite)",
        smc="axi_smc_dma\n\nto NoC port\nS09_AXI\n512 bit\n(MC_2),\nnon-\ncoherent",
        data_bits=512,
        ing_body="async, 256 KB\nfull → drop + count",
        egr_body="async, 256 KB,\nlossless",
        dp_clk="dp_clk  250 MHz (pl1_ref_clk)",
        src_clk="src_clk  250 MHz (pl2_ref_clk)",
        lite_clk="pl3_ref_clk  100 MHz",
        nvmeha_clk="clk_core = dp_clk,  clk_axi_lite = pl3_ref_clk (100 MHz)",
        smc_db=None,
        db_lbl="m_axi_db → smc_m_axi_fpd",
        smc_q="smc_q",
        q_lbl="",
        bar_box=("smc_m_axi\n_fpd", "smc_m_axi\n_fpd"),
        ssd_box=("smc_m_axi\n_bridge", "smc_m_axi\n_bridge_1"),
        host_lbl=("M_AXI_FPD →\nsmc_m_axi_fpd", "M_AXI_FPD →\nsmc_m_axi_fpd"),
        nvme_lbl=("NoC S08_AXI (MC_1)", "NoC S10_AXI (MC_3)"),
        rp_title=("qdma_0  +  qdma_0_support", "qdma_1  +  qdma_1_support"),
        rp_body=("QDMA Subsystem for PCIe\nAXI Bridge, Root Port, Gen4\n\n"
                 "S_AXI_BRIDGE: BAR0 window 0xA800_0000\nM_AXI_BRIDGE: the SSD's DMA",
                 "QDMA Subsystem for PCIe\nAXI Bridge, Root Port, Gen4\n\n"
                 "S_AXI_BRIDGE: BAR0 window 0xAC00_0000\nM_AXI_BRIDGE: the SSD's DMA"),
        pcie_clk="QDMA axi_aclk (PCIe)",
        gt_body="GTY\nx4",
        link=("x4 @ 16 GT/s\nFMCP1 DP0–3", "x4 @ 16 GT/s\nFMCP1 DP4–7"),
        irq="QDMA irq → pl_ps_irq0–5 (SPI 84–89);  nvrec_core_0/irq → pl_ps_irq6 (SPI 90);  "
            "nvmeha_0/ha_interrupt → pl_ps_irq7 (SPI 91)",
        notes="Same nvrec_core_0, nvmeha_0 and nvmeha_guard as the Zynq UltraScale+ designs, 512-bit datapath.  smc_m_axi_fpd is ONE "
              "SmartConnect shared by both root ports.\n"
              "SSD DMA: qdma_0 → smc_m_axi_bridge → NoC S08_AXI (MC_1), qdma_1 → smc_m_axi_bridge_1 → NoC S10_AXI (MC_3), 7000 MB/s each, "
              "or → smc_q → nvmeha_0/S_AXI_SSD (queue window 0x9000_0000).  QDMA control: M_AXI_LPD → smc_m_axi_lpd.\n"
              "Split ring (map 1.3): ring port 1 nvrec_core_0/m_axi1 → axi_smc_dma1 → noc_lpddr4/S00_AXI (MC_0, 14000 MB/s); S08 / S10 → "
              "M00 / M01_INI → noc_lpddr4 (MC_1 / MC_2, 4000 MB/s each); LPDDR4 (one controller, 4 GB) at 0x600_0000_0000, not mapped to the PS.\n"
              "Doorbells: nvmeha_0/M_AXI_SSD → doorbell monitor → smc_m_axi_fpd (second slave port) → qdma_N/S_AXI_BRIDGE "
              "(BAR0 only).  The PCIe part is the Versal design of fpga-drive-aximm-pcie.",
    ),
}


def draw_block(fam):
    s = FAMILIES[fam]
    fig, ax = new_fig(17.0, 12.4, 170, 124)

    # ---- processor column -----------------------------------------------------
    ps_x0, ps_w = 2.0, 19.0
    ps_r = ps_x0 + ps_w
    titled_box(ax, ps_x0, 98.0, ps_w, 14.0, C_PS_FILL, C_PS_EDGE, s["ddr"],
               s["ddr_body"], title_fs=9.6, body_fs=6.6, title_dy=2.6, lw=1.3)
    vblock(ax, ps_x0 + ps_w / 2, 94.0, 98.0, C_AXARR_FILL, C_AXARR_EDGE,
           bw=0.9, hw=1.7, hl=1.2)
    box(ax, ps_x0, 14.0, ps_w, 80.0, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    ax.text(ps_x0 + ps_w / 2, 87.0, s["proc_title"], ha="center", va="center",
            fontsize=11.0, weight="bold", color=TXT, linespacing=1.2)
    ax.text(ps_x0 + ps_w / 2, 52.0, s["proc_body"], ha="center", va="center",
            fontsize=7.2, color=TXT, linespacing=1.35)

    # ---- fabric container -----------------------------------------------------
    fab_x0, fab_x1 = 25.0, 131.0
    ax.add_patch(plt.Rectangle((fab_x0, 12.0), fab_x1 - fab_x0, 102.0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 115.0, "Programmable logic and hard PCIe / GT blocks",
            ha="center", va="bottom", fontsize=11.5, weight="bold", color=TXT)

    # ---- upper band: nvrec_core datapath -----------------------------------------
    smc_x, smc_w = 28.0, 9.0
    core_x0, core_x1, core_y0, core_y1 = 41.0, 107.0, 72.0, 106.0
    usr_x, usr_w = 111.0, 18.0
    rec_y, ply_y = 98.0, 88.0             # stream rows: record (upper), playback
    fifo_x, fifo_w = 83.0, 16.0
    rw_x, rw_w = 43.0, 20.0

    titled_box(ax, smc_x, 84.0, smc_w, 18.0, C_MAC_FILL, C_MAC_EDGE, "", s["smc"],
               body_fs=6.0)

    box(ax, core_x0, core_y0, core_x1 - core_x0, core_y1 - core_y0, "#FAFAFD",
        C_MAC_EDGE, "", lw=1.3)
    ax.text((core_x0 + rw_x + rw_w + 20.0) / 2, core_y1 - 2.2, "nvrec_core_0",
            ha="center", va="center", fontsize=9.6, weight="bold", color=TXT)
    titled_box(ax, rw_x, rec_y - 4.0, rw_w, 8.0, C_MAC_FILL, C_MAC_EDGE,
               "ring writer", "4 KB AXI4 write bursts\ninto free slots",
               title_fs=7.8, body_fs=6.1, title_dy=1.9, z=3)
    titled_box(ax, rw_x, ply_y - 4.0, rw_w, 8.0, C_MAC_FILL, C_MAC_EDGE,
               "ring reader", "4 KB AXI4 read bursts\nof completed chunks",
               title_fs=7.8, body_fs=6.1, title_dy=1.9, z=3)
    titled_box(ax, fifo_x, rec_y - 4.0, fifo_w, 8.0, C_MAC_FILL, C_MAC_EDGE,
               "ingest FIFO", s["ing_body"],
               title_fs=7.8, body_fs=6.1, title_dy=1.9, z=3)
    titled_box(ax, fifo_x, ply_y - 4.0, fifo_w, 8.0, C_MAC_FILL, C_MAC_EDGE,
               "egress FIFO", s["egr_body"],
               title_fs=7.8, body_fs=6.1, title_dy=1.9, z=3)
    harrow(ax, fifo_x, rw_x + rw_w, rec_y, "", C_USER_FILL, C_USER_EDGE,
           bh=0.6, hh=1.2, hl=0.8, z=4)
    harrow(ax, rw_x + rw_w, fifo_x, ply_y, "", C_USER_FILL, C_USER_EDGE,
           bh=0.6, hh=1.2, hl=0.8, z=4)

    # command row inside nvrec_core
    cmd_y0, cmd_h = 74.0, 8.0
    titled_box(ax, 43.0, cmd_y0, 13.0, cmd_h, C_CTRL_FILL, C_CTRL_EDGE,
               "registers", "AXI-Lite (4 KB)\n+ CPU injector", title_fs=7.2,
               body_fs=5.9, title_dy=1.8, z=3)
    titled_box(ax, 57.5, cmd_y0, 12.0, cmd_h, C_MAC_FILL, C_MAC_EDGE,
               "doorbell\nmonitor", "", title_fs=7.0, title_dy=4.0, z=3)
    titled_box(ax, 71.0, cmd_y0, 15.0, cmd_h, C_MAC_FILL, C_MAC_EDGE,
               "CQE router", "slot release\nin ring order", title_fs=7.6,
               body_fs=5.9, title_dy=1.8, z=3)
    titled_box(ax, 87.5, cmd_y0, 18.0, cmd_h, C_MAC_FILL, C_MAC_EDGE,
               "command builder", "NVMe Write / Read SQE\nper chunk, md RAID0",
               title_fs=7.6, body_fs=5.9, title_dy=1.8, z=3)

    # user hierarchies
    titled_box(ax, usr_x, rec_y - 4.5, usr_w, 9.0, C_USER_FILL, C_USER_EDGE,
               "user_data_source", "default: fdrec_tpg\n(test pattern)",
               title_fs=8.0, body_fs=6.3, title_dy=2.0, lw=1.3)
    titled_box(ax, usr_x, ply_y - 4.5, usr_w, 9.0, C_USER_FILL, C_USER_EDGE,
               "user_data_sink", "default: fdrec_check\n(checker, rate throttle)",
               title_fs=8.0, body_fs=6.3, title_dy=2.0, lw=1.3)
    harrow(ax, usr_x, fifo_x + fifo_w, rec_y, "", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.3)
    harrow(ax, fifo_x + fifo_w, usr_x, ply_y, "", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.3)

    # ring writer / reader <-> SmartConnect <-> DDR (green)
    harrow(ax, rw_x, smc_x + smc_w, rec_y, "", C_AXARR_FILL, C_AXARR_EDGE,
           bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, smc_x + smc_w, rw_x, ply_y, "", C_AXARR_FILL, C_AXARR_EDGE,
           bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, smc_x, ps_r, rec_y, "write", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=6.0, lab_dy=3.2)
    harrow(ax, ps_r, smc_x, ply_y, "read", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=6.0, lab_dy=-3.2)

    # clock domains (orange): dashed boundary through the FIFOs
    cdc_lx = fifo_x + 9.0
    clk_y = 108.0
    line(ax, [(cdc_lx, ply_y - 4.5), (cdc_lx, core_y1)], C_REFCLK_LINE, lw=1.2,
         ls=(0, (3, 2)), z=2.5)
    clk_tag(ax, 74.0, clk_y + 2.0, s["dp_clk"])
    clk_tag(ax, (cdc_lx + usr_x + usr_w) / 2, clk_y + 2.0, s["src_clk"])
    line(ax, [(smc_x, clk_y), (cdc_lx, clk_y)], C_REFCLK_LINE, lw=1.0)
    line(ax, [(cdc_lx, clk_y), (usr_x + usr_w, clk_y)], C_REFCLK_LINE, lw=1.0,
         ls=(0, (3, 2)))
    line(ax, [(cdc_lx, clk_y), (cdc_lx, core_y1)], C_REFCLK_LINE, lw=1.0,
         ls=(0, (3, 2)))

    # "no CPU" annotation
    ax.text(fab_x0 + 1.5, 111.0,
            "no CPU in the data path: the fabric\ncommands the SSDs, the SSDs DMA the ring",
            ha="left", va="center", fontsize=6.8, color=C_DATA_LINE, weight="bold",
            linespacing=1.2)

    # ---- middle band: NVMe Host Accelerator -------------------------------------
    ha_x0, ha_x1, ha_y0, ha_y1 = 64.0, 106.0, 51.5, 67.0
    titled_box(ax, ha_x0, ha_y0, ha_x1 - ha_x0, ha_y1 - ha_y0, C_GT_FILL, C_GT_EDGE,
               "nvmeha_0  (AMD NVMe Host Accelerator, PG328)",
               "S_AXI_SSD: I/O SQ + CQ memory = queue window 0x9000_0000\n"
               "one hardware queue per SSD (NVMe QID 1), depth 64, credits\n"
               "M_AXI_SSD: SQ tail / CQ head doorbell writes\n" + s["nvmeha_clk"],
               title_fs=8.2, body_fs=6.1, title_dy=2.2, lw=1.3)
    # SQE / CQE streams between the builder / router and the IP
    vblock(ax, 96.5, cmd_y0, ha_y1, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7,
           hl=1.1, double=False)
    ax.text(98.6, (cmd_y0 + ha_y1) / 2, "SQE 512b (S_AXIS)", ha="left", va="center",
            fontsize=5.8, color=TXT)
    vblock(ax, 78.5, ha_y1, cmd_y0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7,
           hl=1.1, double=False)
    ax.text(80.6, (cmd_y0 + ha_y1) / 2, "CQE 128b (M_AXIS)", ha="left", va="center",
            fontsize=5.8, color=TXT)
    # doorbells: M_AXI_SSD -> doorbell monitor -> (smc_db) -> root port BARs
    route(ax, [(67.0, ha_y1), (67.0, cmd_y0)], C_CTRL_LINE, lw=1.2)
    ax.text(67.6, (cmd_y0 + ha_y1) / 2 - 0.6, "M_AXI_SSD", ha="left", va="center",
            fontsize=5.6, color=C_CTRL_LINE)
    db_bus_x = 51.0
    if s["smc_db"]:
        box(ax, 45.0, 68.0, 10.0, 3.6, C_MAC_FILL, C_MAC_EDGE, s["smc_db"], fs=6.2)
        route(ax, [(60.0, cmd_y0), (60.0, 69.8), (55.0, 69.8)], C_CTRL_LINE, lw=1.2)
        line(ax, [(db_bus_x, 68.0), (db_bus_x, 51.0)], C_CTRL_LINE, lw=1.2)
    else:
        line(ax, [(60.0, cmd_y0), (60.0, 69.8), (db_bus_x, 69.8), (db_bus_x, 51.0)],
             C_CTRL_LINE, lw=1.2)
        ax.text(db_bus_x - 0.8, 71.0, s["db_lbl"], ha="right", va="center",
                fontsize=5.6, color=C_CTRL_LINE)
    ax.text(db_bus_x - 0.6, 58.0, "doorbells", ha="right", va="center",
            fontsize=5.8, color=C_CTRL_LINE, rotation=90)

    # PS AXI-Lite: nvrec registers and (through the guard) nvmeha S_AXI_LITE
    ctl_y = 78.0
    harrow(ax, ps_r, 27.0, ctl_y, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1)
    route(ax, [(27.0, ctl_y), (43.0, ctl_y)], C_CTRL_LINE, lw=1.2)
    ax.text(ps_r + 1.0, 81.2, s["ctl_lbl"], ha="left", va="center", fontsize=5.8,
            color=C_CTRL_LINE, linespacing=1.15)
    route(ax, [(31.0, ctl_y), (31.0, 67.5)], C_CTRL_LINE, lw=1.2)
    titled_box(ax, 26.5, 60.0, 11.0, 7.5, C_CTRL_FILL, C_CTRL_EDGE, "nvmeha_guard",
               "AXI-Lite\ntimeout guard", title_fs=6.4, body_fs=5.8, title_dy=1.7)
    harrow(ax, 37.5, ha_x0, 63.75, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1)
    ax.text(ha_x0 - 1.5, 65.8, "S_AXI_LITE", ha="right", va="center", fontsize=5.6,
            color=TXT)
    clk_tag(ax, 32.0, 58.4, s["lite_clk"], fs=6.0)

    # queue window: root ports -> (smc_q) -> nvmeha S_AXI_SSD (green)
    q_bus_x, q_y = 53.5, 54.5
    if s["smc_q"]:
        box(ax, 55.5, 52.5, 6.5, 4.0, C_MAC_FILL, C_MAC_EDGE, s["smc_q"], fs=6.2)
        route(ax, [(q_bus_x, 31.5), (q_bus_x, q_y), (55.5, q_y)], C_DATA_LINE, lw=1.4)
        route(ax, [(62.0, q_y), (ha_x0, q_y)], C_DATA_LINE, lw=1.4)
    else:
        route(ax, [(q_bus_x, 31.5), (q_bus_x, q_y), (ha_x0, q_y)], C_DATA_LINE, lw=1.4)
        ax.text(54.2, q_y + 1.3, s["q_lbl"], ha="left", va="center", fontsize=5.4,
                color=C_DATA_LINE)

    # ---- lower half: PCIe root ports ---------------------------------------------
    col_x, col_w = 38.0, 10.0
    rp_x, rp_w = 56.0, 28.0
    gt_x, gt_w = 92.0, 10.0
    rows = [(35.0, 14.0), (17.0, 14.0)]      # (y0, height)
    for i, (y0, rh) in enumerate(rows):
        yc = y0 + rh / 2
        box(ax, col_x, yc + 0.5, col_w, rh / 2 - 0.5, C_MAC_FILL, C_MAC_EDGE,
            s["bar_box"][i], fs=5.9)
        box(ax, col_x, y0, col_w, rh / 2 - 0.5, C_MAC_FILL, C_MAC_EDGE,
            s["ssd_box"][i], fs=5.9)
        harrow(ax, ps_r, col_x, yc + 3.25, s["host_lbl"][i], C_LINKARR_FILL,
               C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=5.6, lab_dy=2.9)
        harrow(ax, col_x, ps_r, yc - 3.25, s["nvme_lbl"][i], C_AXARR_FILL,
               C_AXARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=5.6, lab_dy=-2.3)
        harrow(ax, col_x + col_w, rp_x, yc + 3.25, "", C_LINKARR_FILL,
               C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1)
        harrow(ax, rp_x, col_x + col_w, yc - 3.25, "", C_AXARR_FILL,
               C_AXARR_EDGE, bh=0.8, hh=1.5, hl=1.1)
        titled_box(ax, rp_x, y0, rp_w, rh, C_GT_FILL, C_GT_EDGE, s["rp_title"][i],
                   s["rp_body"][i], title_fs=8.4, body_fs=6.0, title_dy=2.1, lw=1.3)
        titled_box(ax, gt_x, y0 + 2.0, gt_w, rh - 4.0, C_GT_FILL, C_GT_EDGE, "GT",
                   s["gt_body"], title_fs=7.8, body_fs=6.2, title_dy=1.8)
        harrow(ax, rp_x + rp_w, gt_x, yc, "", C_GT_FILL, C_GT_EDGE, double=True,
               bh=0.9, hh=1.7, hl=1.1)
        # doorbell bus into the BAR-side SmartConnect (from the top)
        route(ax, [(db_bus_x, y0 + rh + 2.0), (col_x + 5.0, y0 + rh + 2.0),
                   (col_x + 5.0, y0 + rh)], C_CTRL_LINE, lw=1.2, ms=7)
        # SSD DMA tap into the queue-window bus (from the bottom)
        line(ax, [(col_x + 7.5, y0), (col_x + 7.5, y0 - 1.3), (q_bus_x, y0 - 1.3)],
             C_DATA_LINE, lw=1.4)
    # the doorbell bus runs down to the lower row; the queue bus up from it
    line(ax, [(db_bus_x, 51.0), (db_bus_x, rows[1][0] + rows[1][1] + 2.0)],
         C_CTRL_LINE, lw=1.2)
    line(ax, [(q_bus_x, rows[1][0] - 1.3), (q_bus_x, 31.5)], C_DATA_LINE, lw=1.4)
    clk_tag(ax, rp_x + rp_w / 2, 50.4, s["pcie_clk"], fs=6.4)

    # ---- external: FMC with the M.2 slots --------------------------------------
    fmc_x0, fmc_x1 = 136.0, 168.0
    ax.add_patch(plt.Rectangle((fmc_x0, 13.0), fmc_x1 - fmc_x0, 43.0,
                               fc=C_FMC_FILL, ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((fmc_x0 + fmc_x1) / 2, 53.0,
            "FPGA Drive FMC Gen4 (OP063)\nor M.2 M-key Stack FMC (OP073)",
            ha="center", va="center", fontsize=7.4, weight="bold", color=TXT,
            linespacing=1.2)
    for i, (y0, rh) in enumerate(rows):
        yc = y0 + rh / 2
        titled_box(ax, fmc_x0 + 9.0, y0 + 0.5, 21.0, rh - 1.0, C_SLOT_FILL,
                   C_FMC_EDGE, "M.2 slot  SSD%d" % (i + 1),
                   "NVMe SSD\n(md RAID0 member %d)" % i,
                   title_fs=7.8, body_fs=6.4, title_dy=2.0)
        harrow(ax, gt_x + gt_w, fmc_x0 + 9.0, yc, "", C_LINKARR_FILL,
               C_LINKARR_EDGE, double=True, bh=1.0, hh=1.9, hl=1.2)
        ax.text((gt_x + gt_w + fmc_x0 + 9.0) / 2, yc + 3.6, s["link"][i],
                ha="center", va="center", fontsize=6.0, color=TXT, linespacing=1.15)
    ax.text((fmc_x0 + fmc_x1) / 2, 80.0,
            "External to the FPGA\n\n(your own ADC / DAC\nconnects to the user\nhierarchies through\nany free FPGA I/O)",
            ha="center", va="center", fontsize=7.2, color=C_MUTED, linespacing=1.25)

    legend(ax, 136.0, 110.0, s["data_bits"])

    # ---- interrupts and notes strip --------------------------------------------
    titled_box(ax, 2.0, 0.0, 166.0, 11.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Interrupts: " + s["irq"], s["notes"], title_fs=7.6, body_fs=6.5,
               title_dy=1.8)
    ax.text(85.0, 121.0, s["title"], ha="center", va="center", fontsize=13.0,
            weight="bold", color=TXT)
    save(fig, s["out"])


# -----------------------------------------------------------------------------
# 2. / 3. Record and playback paths, step by step (Zynq UltraScale+ cell names
# from Vivado/src/bd/bd_zynqmp.tcl; behaviour from the headers of
# Vivado/src/hdl/nvrec_wr.v, nvrec_rd.v, nvrec_cmd.v and nvrec_cq.v).
# -----------------------------------------------------------------------------
def path_frame(ax, title, ps_body, data_up):
    """PS, DDR, root ports / SSDs and the Host Accelerator, shared by both paths.

    data_up = True when the SSD writes DDR (playback), False when it reads it.
    """
    titled_box(ax, 2.0, 70.0, 20.0, 16.0, C_PS_FILL, C_PS_EDGE, "Zynq\nUltraScale+ PS",
               ps_body, title_fs=8.8, body_fs=6.0, title_dy=3.2, lw=1.3)
    vblock(ax, 12.0, 64.0, 70.0, C_LINKARR_FILL, C_LINKARR_EDGE, bw=0.9, hw=1.7,
           hl=1.1)
    titled_box(ax, 2.0, 36.0, 20.0, 28.0, C_PS_FILL, C_PS_EDGE, "PS DDR",
               "ring: NUM_CHUNKS slots\nof CHUNK_SIZE bytes\n(one CMA region,\n512 MB by default;\n"
               "chunk = 1 MB or the\nSSDs' MDTS)\n\nPRP list per slot\n(written once by\nthe driver)",
               title_fs=9.2, body_fs=6.1, title_dy=2.6, lw=1.3)

    # root ports and SSDs (bottom left)
    titled_box(ax, 2.0, 12.0, 15.0, 18.0, C_GT_FILL, C_GT_EDGE, "xdma_0\nxdma_1",
               "PCIe root\nports, Gen3 x4", title_fs=7.8, body_fs=6.0, title_dy=3.4)
    titled_box(ax, 22.0, 12.0, 16.0, 18.0, C_FMC_FILL, C_FMC_EDGE, "NVMe SSD1\nNVMe SSD2",
               "on the FMC card\n(md RAID0\nmembers 0 / 1)", title_fs=7.8, body_fs=6.0,
               title_dy=3.4)
    harrow(ax, 17.0, 22.0, 21.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.0)
    # SSD DMA to / from DDR
    vblock(ax, 9.5, 36.0 if not data_up else 30.0, 30.0 if not data_up else 36.0,
           C_AXARR_FILL, C_AXARR_EDGE, bw=1.0, hw=1.9, hl=1.2, double=False)
    ax.text(12.0, 33.0, "M_AXI_B → smc_ssd_N → S_AXI_HP0/1_FPD",
            ha="left", va="center", fontsize=5.6, color=C_DATA_LINE)

    # NVMe Host Accelerator (bottom middle)
    titled_box(ax, 46.0, 12.0, 58.0, 16.0, C_GT_FILL, C_GT_EDGE,
               "nvmeha_0  (AMD NVMe Host Accelerator)",
               "stores each SQE in the SSD's hardware SQ (queue window, S_AXI_SSD)\n"
               "and rings the SSD's SQ tail doorbell (M_AXI_SSD);\n"
               "passes each CQE the SSD writes to the fabric and rings the CQ head doorbell",
               title_fs=8.4, body_fs=6.1, title_dy=2.2, lw=1.3)
    harrow(ax, 38.0, 46.0, 16.5, "", C_AXARR_FILL, C_AXARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.1)
    ax.text(42.0, 13.4, "queue\nwindow", ha="center", va="center", fontsize=5.4,
            color=C_DATA_LINE, linespacing=1.05)
    harrow(ax, 46.0, 38.0, 24.0, "doorbells", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1, fs=5.6, lab_dy=-2.6)

    ax.text(85.0, 93.0, title, ha="center", va="center", fontsize=12.5,
            weight="bold", color=TXT)


def core_frame(ax, cdc, side_lbl):
    """nvrec_core box, register strip and the clock domains (both paths)."""
    box(ax, 42.0, 34.0, 84.0, 46.0, "#FAFAFD", C_MAC_EDGE, "", lw=1.3)
    ax.text(84.0, 77.5, "nvrec_core_0", ha="center", va="center", fontsize=9.8,
            weight="bold", color=TXT)
    box(ax, 46.0, 68.5, 62.0, 5.0, C_CTRL_FILL, C_CTRL_EDGE,
        "AXI-Lite register block (nvrec_regs.h): RING_*, CHUNK_SIZE, MEMBER_*, SSD_*, CTRL, statistics",
        fs=6.1, z=3)
    # control (blue) from the PS
    harrow(ax, 22.0, 30.0, 71.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5,
           hl=1.1)
    route(ax, [(30.0, 71.0), (46.0, 71.0)], C_CTRL_LINE, lw=1.2)
    ax.text(23.0, 74.6, "M_AXI_HPM0_FPD →\nperiph_intercon_0", ha="left",
            va="center", fontsize=5.6, color=C_CTRL_LINE, linespacing=1.1)
    # clock domains
    line(ax, [(cdc, 66.0), (cdc, 82.0)], C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)), z=2.5)
    clk_tag(ax, (27.0 + cdc) / 2, 83.6, "dp_clk  250 MHz  (ring, commands, nvmeha clk_core)")
    clk_tag(ax, (cdc + 168.0) / 2, 83.6, "src_clk  250 MHz  (%s side)" % side_lbl)
    line(ax, [(27.0, 82.0), (cdc, 82.0)], C_REFCLK_LINE, lw=1.0)
    line(ax, [(cdc, 82.0), (168.0, 82.0)], C_REFCLK_LINE, lw=1.0, ls=(0, (3, 2)))


def draw_record_path():
    fig, ax = new_fig(17.0, 9.6, 170, 96)
    path_frame(ax, "Recording path: user_data_source → nvrec_core → DDR ring → NVMe Write → SSD",
               "Linux, nvrec driver:\nsets the run up,\nreads statistics;\nirq: pl_ps_irq0[6]",
               data_up=False)
    core_frame(ax, 112.0, "source")

    titled_box(ax, 27.0, 50.0, 10.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "axi_smc\n_dma",
               "Smart-\nConnect\n\n256 → 128\nbit, to\npl_clk3", title_fs=7.0, body_fs=6.0, title_dy=3.0)
    harrow(ax, 27.0, 22.0, 58.0, "S_AXI_HP2_FPD\nwrite", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=5.6, lab_dy=4.0)
    harrow(ax, 46.0, 37.0, 58.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.9, hh=1.7, hl=1.1)

    titled_box(ax, 46.0, 50.0, 26.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "ring writer",
               "4 KB AXI4 write bursts, only when\nthe data is already in the FIFO\n"
               "opens a slot only when it is free\nchunk filled = all write\nresponses back",
               title_fs=8.2, body_fs=6.0, title_dy=2.2, z=3)
    titled_box(ax, 96.0, 50.0, 26.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "ingest FIFO",
               "xpm_fifo_async\n8192 x 256 bit (256 KB)\n\nTREADY held at 1: when full,\n"
               "the beat is dropped and\ncounted (RUN_DROP_COUNT)",
               title_fs=8.2, body_fs=6.0, title_dy=2.2, z=3)
    harrow(ax, 96.0, 72.0, 58.0, "AXIS 256b", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7,
           hl=1.1, fs=5.8, lab_dy=2.6)

    titled_box(ax, 46.0, 37.0, 26.0, 10.5, C_MAC_FILL, C_MAC_EDGE, "command builder",
               "1 NVMe Write per filled chunk\nSLBA by the md RAID0 stripe rule\n"
               "PRP1 = slot, PRP2 = its PRP list, CID = slot",
               title_fs=7.8, body_fs=5.8, title_dy=1.9, z=3)
    titled_box(ax, 76.0, 37.0, 30.0, 10.5, C_MAC_FILL, C_MAC_EDGE, "CQE router",
               "CQE → slot by CID; errors, latency\nslots released strictly in ring order\n"
               "(completions may arrive in any order)",
               title_fs=7.8, body_fs=5.8, title_dy=1.9, z=3)
    route(ax, [(59.0, 50.0), (59.0, 47.5)], C_THIN, lw=1.1, ms=7)
    ax.text(60.0, 48.75, "chunk filled", ha="left", va="center", fontsize=5.6,
            color=C_MUTED)
    route(ax, [(86.0, 47.5), (86.0, 53.0), (72.0, 53.0)], C_THIN, lw=1.1, ms=7)
    ax.text(86.8, 50.2, "slot\nreleased", ha="left", va="center", fontsize=5.6,
            color=C_MUTED, linespacing=1.05)
    # SQE down, CQE up
    vblock(ax, 59.0, 37.0, 28.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7, hl=1.1,
           double=False)
    ax.text(61.0, 31.6, "SQE 512b (S_AXIS)", ha="left", va="center", fontsize=5.8,
            color=TXT)
    vblock(ax, 91.0, 28.0, 37.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7, hl=1.1,
           double=False)
    ax.text(93.0, 31.6, "CQE 128b (M_AXIS)", ha="left", va="center", fontsize=5.8,
            color=TXT)

    # source
    titled_box(ax, 140.0, 50.0, 28.0, 16.0, C_USER_FILL, C_USER_EDGE,
               "user_data_source", "fdrec_tpg (default)\n\n16-byte word k of a beat:\n"
               "[63:0] = seq + k\n[127:64] = ~(seq + k)\n"
               "rate: TPG_RATE_INC", title_fs=8.4, body_fs=6.2, title_dy=2.4, lw=1.3)
    harrow(ax, 140.0, 122.0, 58.0, "AXIS 256b", C_USER_FILL, C_USER_EDGE, bh=1.0,
           hh=1.9, hl=1.2, fs=6.0, lab_dy=3.0)
    ax.text(131.0, 53.0, "TREADY = 1\n(ignored)", ha="center", va="center",
            fontsize=5.9, color=C_WARN, linespacing=1.1)
    route(ax, [(108.0, 71.0), (154.0, 71.0), (154.0, 66.0)], C_THIN, lw=1.0)
    ax.text(128.5, 72.6, "tpg_enable, tpg_seq_rst, tpg_rate_inc", ha="left",
            va="center", fontsize=5.8, color=C_MUTED)

    # steps
    marker(ax, 125.2, 62.0, 1)
    marker(ax, 41.5, 62.5, 2)
    marker(ax, 56.0, 31.6, 3)
    marker(ax, 42.0, 27.4, 4)
    marker(ax, 6.0, 33.0, 5)
    marker(ax, 88.0, 31.6, 6)

    titled_box(ax, 2.0, 0.0, 166.0, 10.0, C_CTRL_FILL, C_CTRL_EDGE,
               "No CPU in the data path: the processor only sets the run up (ring, PRP lists, members) and reads the statistics.",
               "1 the stream crosses into dp_clk; a full FIFO drops and counts   2 the ring writer fills a free slot in DDR   "
               "3 the builder sends one Write SQE per filled chunk\n"
               "4 nvmeha stores it in the SQ and rings the SSD's doorbell   5 the SSD fetches the SQE from the queue window "
               "and reads the chunk from DDR   6 the CQE frees the slot\n"
               "If the SSDs fall behind, no slot is free: the writer waits, the ingest FIFO fills and beats are dropped and counted "
               "(RUN_DROP_COUNT), the only failure mode.",
               title_fs=7.4, body_fs=6.5, title_dy=1.8)
    save(fig, "nvrec-record-path.png")


def draw_play_path():
    fig, ax = new_fig(17.0, 9.6, 170, 96)
    path_frame(ax, "Playback path: SSD → NVMe Read → DDR ring → nvrec_core → user_data_sink",
               "Linux, nvrec driver:\nsets the run up,\nreads statistics;\nirq: pl_ps_irq0[6]",
               data_up=True)
    core_frame(ax, 112.0, "sink")

    titled_box(ax, 27.0, 50.0, 10.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "axi_smc\n_dma",
               "Smart-\nConnect\n\n256 → 128\nbit, to\npl_clk3", title_fs=7.0, body_fs=6.0, title_dy=3.0)
    harrow(ax, 22.0, 27.0, 58.0, "S_AXI_HP2_FPD\nread", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=5.6, lab_dy=4.0)
    harrow(ax, 37.0, 46.0, 58.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.9, hh=1.7, hl=1.1)

    titled_box(ax, 46.0, 50.0, 26.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "ring reader",
               "streams completed chunks in\nring order, 4 KB AXI4 read bursts,\n"
               "only when the egress FIFO has\nroom; TLAST on each chunk's\nlast beat",
               title_fs=8.2, body_fs=6.0, title_dy=2.2, z=3)
    titled_box(ax, 96.0, 50.0, 26.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "egress FIFO",
               "xpm_fifo_async, 128 KB\n(4096 x 256 bit + TLAST)\nlossless: when full, the\nreader waits\n"
               "EGR_CTRL.FLUSH: accept\nand discard (EGR_DISCARD)",
               title_fs=8.2, body_fs=6.0, title_dy=2.2, z=3)
    harrow(ax, 72.0, 96.0, 58.0, "AXIS 256b + TLAST", C_USER_FILL, C_USER_EDGE, bh=0.9,
           hh=1.7, hl=1.1, fs=5.8, lab_dy=2.6)

    titled_box(ax, 46.0, 37.0, 26.0, 10.5, C_MAC_FILL, C_MAC_EDGE, "command builder",
               "1 NVMe Read per chunk, into a free slot\nSLBA by the md RAID0 stripe rule\n"
               "PRP1 = slot, PRP2 = its PRP list, CID = slot",
               title_fs=7.8, body_fs=5.8, title_dy=1.9, z=3)
    titled_box(ax, 76.0, 37.0, 30.0, 10.5, C_MAC_FILL, C_MAC_EDGE, "CQE router",
               "CQE → slot by CID; errors, latency\nchunks handed on strictly in ring\n"
               "order (completions in any order)",
               title_fs=7.8, body_fs=5.8, title_dy=1.9, z=3)
    route(ax, [(59.0, 50.0), (59.0, 47.5)], C_THIN, lw=1.1, ms=7)
    ax.text(60.0, 48.75, "slot free again", ha="left", va="center", fontsize=5.6,
            color=C_MUTED)
    route(ax, [(86.0, 47.5), (86.0, 53.0), (72.0, 53.0)], C_THIN, lw=1.1, ms=7)
    ax.text(86.8, 50.2, "chunk\nready", ha="left", va="center", fontsize=5.6,
            color=C_MUTED, linespacing=1.05)
    vblock(ax, 59.0, 37.0, 28.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7, hl=1.1,
           double=False)
    ax.text(61.0, 31.6, "SQE 512b (S_AXIS)", ha="left", va="center", fontsize=5.8,
            color=TXT)
    vblock(ax, 91.0, 28.0, 37.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7, hl=1.1,
           double=False)
    ax.text(93.0, 31.6, "CQE 128b (M_AXIS)", ha="left", va="center", fontsize=5.8,
            color=TXT)

    # sink
    titled_box(ax, 140.0, 40.0, 28.0, 26.0, C_USER_FILL, C_USER_EDGE,
               "user_data_sink",
               "fdrec_check (default), models a DAC:\nTREADY on the ticks of a\nQ1.31 rate throttle (CHK_RATE_INC)\n\n"
               "checks the TPG pattern;\nCHK_ERRORS, CHK_GAPS,\nCHK_UNDERFLOWS",
               title_fs=8.4, body_fs=6.0, title_dy=2.4, lw=1.3)
    harrow(ax, 122.0, 140.0, 58.0, "AXIS 256b\n+ TLAST", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=6.0, lab_dy=4.0)
    route(ax, [(140.0, 53.0), (122.0, 53.0)], C_WARN, lw=1.2)
    ax.text(131.0, 51.4, "TREADY (rate)", ha="center", va="top", fontsize=5.9,
            color=C_WARN)
    route(ax, [(108.0, 71.0), (154.0, 71.0), (154.0, 66.0)], C_THIN, lw=1.0)
    ax.text(128.5, 72.6, "chk_enable, chk_reset, chk_rate_inc / chk_* counters",
            ha="left", va="center", fontsize=5.8, color=C_MUTED)

    marker(ax, 56.0, 31.6, 1)
    marker(ax, 42.0, 27.4, 2)
    marker(ax, 6.0, 33.0, 3)
    marker(ax, 88.0, 31.6, 4)
    marker(ax, 41.5, 62.5, 5)
    marker(ax, 125.2, 62.0, 6)

    titled_box(ax, 2.0, 0.0, 166.0, 10.0, C_CTRL_FILL, C_CTRL_EDGE,
               "The sink sets the playback rate; backpressure (TREADY low) flows back to the ring reader and nothing is lost.",
               "1 the builder sends one Read SQE per chunk into a free slot   2 nvmeha stores it in the SQ and rings the SSD's doorbell   "
               "3 the SSD fetches the SQE and writes the chunk into DDR\n"
               "4 the CQE marks the chunk ready (in ring order)   5 the ring reader streams it into the egress FIFO and frees the slot   "
               "6 the sink takes the data at its own rate\n"
               "If the SSDs cannot keep up with the sink, the egress FIFO runs empty and the sink counts underflows (CHK_UNDERFLOWS).",
               title_fs=7.4, body_fs=6.5, title_dy=1.8)
    save(fig, "nvrec-play-path.png")


def main():
    for fam in FAMILIES:
        draw_block(fam)
    draw_record_path()
    draw_play_path()


if __name__ == "__main__":
    main()
