/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec_regs.h -- register map of the FPGA Drive NVMe-offload recorder.
 *
 * Three register windows are involved:
 *
 *   1. nvrec_core (this design's RTL): ONE 4 KB AXI-Lite register block.
 *      Offsets 0x000-0x0BF are the fpga-drive-recorder (fdrec) registers of
 *      the test pattern generator (fdrec_tpg), the ingest FIFO (fdrec_ingest),
 *      the playback checker (fdrec_check) and the egress FIFO (fdrec_egress),
 *      at the SAME offsets and with the same semantics as fdrec_regs.h, so a
 *      customer's source/sink code carries over. The packetizer (PKT_*) does
 *      not exist here: offsets 0x040/0x044 are reserved, 0x048/0x04C count the
 *      beats the ring writer took from the ingest FIFO. The NVMe offload
 *      registers start at 0x100 (NVREC_*).
 *   2. AMD NVMe Host Accelerator (nvmeha, PG328) S_AXI_LITE registers
 *      (NVMEHA_* below, from PG328 v1.0 Table 9).
 *   (The IP's software queue interface S_AXI is NOT built in: hardware-only
 *   queues, see below. All CPU I/O uses the nvrec command injector.)
 *
 * This header is shared by the RTL documentation, the Linux kernel driver and
 * the user-space apps, so it is plain C (macros only, no includes) and must
 * stay in sync with docs/source/register_map.md and Vivado/src/hdl.
 *
 * Access types: RO = read-only, RW = read/write, W1C = write 1 to clear,
 * SC = self-clearing (write 1 to trigger, reads 0 unless stated).
 * Unmapped offsets read 0 and ignore writes.
 *
 * 64-bit values are split in a _LO and a _HI register. For COUNTERS, reading
 * _LO latches the matching HI half; read _LO first, then _HI. 64-bit CONFIG
 * registers (addresses, LBAs) are plain RW pairs.
 *
 * Changelog:
 *   1.0 (2026-10-16) first version.
 *   1.0 rev b (2026-10-16, before any bitstream): Host Accelerator built with
 *       HARDWARE-ONLY queues (1 HW SQ per SSD = NVMe QID 1, no SW interface,
 *       S_AXI window removed, MEMBER_SEL SQ reset 0, CREDIT_INIT = 63 per
 *       SSD); CTRL bits 6/7 per-SSD credit reset; RUN_DROP_COUNT (0x250).
 *   1.1 (2026-10-17, backwards compatible): AXI-Lite timeout guard in front
 *       of the nvmeha S_AXI_LITE (an expired evaluation core no longer hangs
 *       the CPU; reads of a dead IP return 0xFFFF_FFFF with OKAY): STATE
 *       bit 12 HA_DEAD, IRQ_STATUS/IRQ_ENABLE bit 6 HA_DEAD; RUN_FIFO_HWM
 *       (0x258); SSD_ISSUED and INJ_SUBMITTED are now cleared by SOFT_RST like
 *       SSD_COMPLETED / SSD_ERRORS / INJ_COMPLETED (they used to survive it).
 */

#ifndef NVREC_REGS_H
#define NVREC_REGS_H

/* ===========================================================================
 * Platform constants (zcu106_hpc0 / Zynq UltraScale+ build). Linux takes the
 * nvrec_core and nvmeha bases from the device tree; they are listed here for
 * bare-metal code, devmem and the docs.
 * ========================================================================= */

#define NVREC_CORE_BASE_ZYNQMP          0x420010000ULL  /* nvrec_core, 4 KB  */
#define NVREC_NVMEHA_LITE_BASE_ZYNQMP   0x420020000ULL  /* nvmeha S_AXI_LITE (behind the 1.1 timeout guard), 64 KB */
#define NVREC_PCIE0_BAR_WIN_ZYNQMP      0xA0000000ULL   /* xdma_0 BAR window (SSD1), 256 MB */
#define NVREC_PCIE1_BAR_WIN_ZYNQMP      0xB0000000ULL   /* xdma_1 BAR window (SSD2), 256 MB */

/*
 * Queue window: the nvmeha S_AXI_SSD slave as the SSDs see it (PCIe bus
 * address = AXI address on the root ports' M_AXI_B side; the root ports do
 * not translate inbound addresses). The SQ/CQ memory lives INSIDE the IP.
 * Use these values in Create I/O SQ / Create I/O CQ (PRP1, PC=1) and program
 * the same values into NVMEHA_SQ1_BASE / NVMEHA_CQ1_BASE.
 *
 *   SQ(n) = NVREC_QWIN_SQ_BASE + n * 4 KB      (NVMe I/O SQ, QID 1)
 *   CQ(n) = NVREC_QWIN_CQ_BASE + n * 4 KB      (NVMe I/O CQ, QID 1)
 *
 * n = nvmeha SSD index (0 = SSD1 on xdma_0, 1 = SSD2 on xdma_1).
 * General form (PG328): queue m of SSD n at base + (n * C_NUM_SQ + m) * 4 KB,
 * an SSD's software queues numbered before its hardware queues (PG328 v1.0
 * Ch.3 "Product Specification"). This build has ONE hardware queue and no
 * software queue per SSD, so the hardware SQ/CQ pair is NVMe QID 1 on every
 * drive, including drives that grant a single I/O queue. Queue size 64
 * entries (QSIZE field = 63). Create the CQ with interrupts disabled (IEN=0):
 * the IP consumes the completions itself.
 */
#define NVREC_QWIN_BASE                 0x90000000u
#define NVREC_QWIN_SIZE                 0x00010000u
#define NVREC_QWIN_SQ_BASE              0x90000000u
#define NVREC_QWIN_CQ_BASE              0x90008000u
#define NVREC_QWIN_QUEUE_STRIDE         0x1000u

/* nvmeha build parameters of this design */
#define NVREC_NVMEHA_NUM_SSD            2       /* C_NUM_SSD */
#define NVREC_NVMEHA_NUM_SQ             1       /* C_NUM_SQ: queues per SSD */
#define NVREC_NVMEHA_NUM_SW_SQ          0       /* C_EN_SW_IF = 0: no software queues */
#define NVREC_NVMEHA_NUM_HW_SQ          1
#define NVREC_NVMEHA_HW_QIDX            0       /* queue index inside the SSD (tuser SQ) */
#define NVREC_NVMEHA_HW_NVME_QID        1       /* NVMe queue ID of the HW SQ/CQ */
#define NVREC_NVMEHA_SQ_DEPTH           64
#define NVREC_NVMEHA_CREDIT_INIT        63      /* per SSD: nq * (depth - 1) */

/* PL-to-PS interrupts (Zynq UltraScale+: pl_ps_irq0[n] = GIC SPI 89 + n) */
#define NVREC_IRQ_CORE_PL_PS_BIT        6       /* nvrec_core irq   -> GIC SPI 95 */
#define NVREC_IRQ_NVMEHA_PL_PS_BIT      7       /* nvmeha ha_interrupt -> GIC SPI 96 */

/* ===========================================================================
 * nvrec_core register block
 * ========================================================================= */

#define NVREC_REG_SPAN                  0x1000

/* ---- Global (fdrec-compatible offsets) ---------------------------------- */

/* 0x000 VERSION (RO): nvrec register map version [31:16] major, [15:0] minor */
#define NVREC_VERSION                   0x000
#define NVREC_VERSION_1_0               0x00010000u
#define NVREC_VERSION_1_1               0x00010001u
#define NVREC_VERSION_EXPECTED          NVREC_VERSION_1_1   /* same major accepted */

/* 0x004 SRC_CLK_HZ (RO), 0x008 DP_CLK_HZ (RO): clock frequencies in Hz */
#define NVREC_SRC_CLK_HZ                0x004
#define NVREC_DP_CLK_HZ                 0x008

/* 0x00C GLOBAL_CTRL (RW)
 * SOFT_RST (SC, reads 1 while in progress, ~1 us): as in fdrec -- clears the
 * ingest FIFO, TPG sequence number, ingest/checker/egress counters, HWM and
 * sticky flags, disables TPG and checker, clears EGR_CTRL.FLUSH -- and in
 * addition resets the nvrec ring state (pointers, slot table) and every
 * NVREC statistics counter. Credits (NVREC_SSD_CREDITS) are NOT touched: they
 * mirror the IP's queue state (see NVREC_CTRL_CREDIT_RST). Only use SOFT_RST
 * while NVREC_STATE is IDLE/DONE/ABORTED; completions of commands still in
 * flight then arrive as "unexpected" CQEs. */
#define NVREC_GLOBAL_CTRL               0x00C
#define NVREC_GLOBAL_CTRL_SOFT_RST      (1u << 0)

/* ---- Test pattern generator (fdrec_tpg), identical to fdrec ------------- */
#define NVREC_TPG_CTRL                  0x010
#define NVREC_TPG_CTRL_ENABLE           (1u << 0)
#define NVREC_TPG_CTRL_SEQ_RST          (1u << 1)   /* SC: seq := 0 */
#define NVREC_TPG_RATE_INC              0x014       /* Q1.31 beats per src_clk */
#define NVREC_TPG_RATE_INC_ONE          0x80000000u
#define NVREC_TPG_SEQ_NEXT_LO           0x018
#define NVREC_TPG_SEQ_NEXT_HI           0x01C

/* ---- Ingest (fdrec_ingest), identical to fdrec ------------------------- */
#define NVREC_ING_STATUS                0x020
#define NVREC_ING_STATUS_OVERFLOW       (1u << 0)   /* sticky, W1C */
#define NVREC_ING_FIFO_HWM              0x024       /* any write clears */
#define NVREC_ING_DROP_COUNT_LO         0x028
#define NVREC_ING_DROP_COUNT_HI         0x02C
#define NVREC_ING_BEATS_IN_LO           0x030
#define NVREC_ING_BEATS_IN_HI           0x034
#define NVREC_ING_FIFO_DEPTH            0x038

/* 0x03C ID (RO): 0x4E56_5243 ("NVRC"), tells nvrec_core from fdrec_core */
#define NVREC_ID                        0x03C
#define NVREC_ID_VALUE                  0x4E565243u

/* 0x040, 0x044: reserved (fdrec PKT_CTRL / PKT_LEN; no packetizer here) */

/* 0x048/0x04C ING_BEATS_OUT (RO, 64-bit): beats the ring writer took out of
 * the ingest FIFO (fdrec: PKT_BEATS_OUT). Once the FIFO has drained,
 * BEATS_OUT = BEATS_IN - DROP_COUNT. */
#define NVREC_ING_BEATS_OUT_LO          0x048
#define NVREC_ING_BEATS_OUT_HI          0x04C

/* ---- Playback checker (fdrec_check), identical to fdrec ---------------- */
#define NVREC_CHK_CTRL                  0x060
#define NVREC_CHK_CTRL_ENABLE           (1u << 0)
#define NVREC_CHK_CTRL_RESET            (1u << 1)   /* SC, reads 1 while busy */
#define NVREC_CHK_RATE_INC              0x064       /* reset 0x8000_0000 */
#define NVREC_CHK_BEATS_LO              0x070
#define NVREC_CHK_BEATS_HI              0x074
#define NVREC_CHK_ERRORS_LO             0x078
#define NVREC_CHK_ERRORS_HI             0x07C
#define NVREC_CHK_GAPS_LO               0x080
#define NVREC_CHK_GAPS_HI               0x084
#define NVREC_CHK_GAP_BEATS_LO          0x088
#define NVREC_CHK_GAP_BEATS_HI          0x08C
#define NVREC_CHK_UNDERFLOWS_LO         0x090
#define NVREC_CHK_UNDERFLOWS_HI         0x094
#define NVREC_CHK_LAST_SEQ_LO           0x098
#define NVREC_CHK_LAST_SEQ_HI           0x09C

/* ---- Egress FIFO (fdrec_egress), identical to fdrec -------------------- */
/* The playback ring reader (nvrec_rd) feeds the egress FIFO instead of the
 * AXI DMA MM2S of fdrec; TLAST marks the end of each chunk. */
#define NVREC_EGR_CTRL                  0x0A0
#define NVREC_EGR_CTRL_FLUSH            (1u << 0)
#define NVREC_EGR_FIFO_DEPTH            0x0A4
#define NVREC_EGR_BEATS_IN_LO           0x0A8
#define NVREC_EGR_BEATS_IN_HI           0x0AC
#define NVREC_EGR_DISCARD_LO            0x0B0
#define NVREC_EGR_DISCARD_HI            0x0B4
#define NVREC_EGR_FIFO_LEVEL            0x0B8

/* 0x0BC-0x0FF: reserved */

/* ===========================================================================
 * NVMe offload engine (nvrec_wr ring writer, nvrec_cmd command builder,
 * nvrec_cq completion router, nvrec_rd ring reader, nvrec_inj injector)
 *
 * Model: a ring of NUM_CHUNKS slots of CHUNK_SIZE bytes at RING_BASE in PS
 * DDR. One chunk = one NVMe command. Array chunk index A = START_CHUNK + c
 * (c = 0, 1, ... counted from the start of the run) is stored in ring slot
 * c % NUM_CHUNKS and goes to stripe member m = A % N_MEMBERS at member LBA
 *     MEMBER_BASE_LBA[m] + (A / N_MEMBERS) * (CHUNK_SIZE >> LBA_SHIFT)
 * which is the Linux md RAID0 layout with md chunk size = CHUNK_SIZE
 * (MEMBER_BASE_LBA = md data offset of the member + any partition offset).
 *
 * SQE built by hardware (64 bytes, little-endian dwords):
 *   DW0  opcode (0x01 Write / 0x02 Read), FUSE=0, PSDT=0 (PRP), CID = slot
 *   DW1  NSID = MEMBER_NSID[m]
 *   DW2-5 0
 *   DW6-7 PRP1 = RING_BASE + slot * CHUNK_SIZE
 *   DW8-9 PRP2 = PRP_LIST_BASE + (slot << PRP_LIST_SHIFT)   (chunk > 2 pages)
 *              = PRP1 + 4096                                  (chunk == 2 pages)
 *              = 0                                            (chunk == 1 page)
 *   DW10-11 SLBA, DW12 NLB-1 [15:0] | FUA [30] (CONFIG.FUA), DW13-15 0
 * Software builds the PRP lists once (the ring is static): for slot s the
 * list at PRP_LIST_BASE + (s << PRP_LIST_SHIFT) holds the addresses of pages
 * 1..P-1 of the slot (P = CHUNK_SIZE / 4096; 4 KB memory page size, CC.MPS=0);
 * a list longer than 512 entries chains (last entry of a list page points to
 * the next page), so use PRP_LIST_SHIFT = 13 for 4 MB chunks.
 *
 * CID space: bit 15 = 0 for builder commands (CID[9:0] = slot), bit 15 = 1
 * for injector commands (the hardware forces bit 15 of an injected SQE to 1).
 * ========================================================================= */

/* 0x100 CTRL (W, SC; reads 0) */
#define NVREC_CTRL                      0x100
#define NVREC_CTRL_START                (1u << 0)   /* start a run (state IDLE/DONE/ABORTED) */
#define NVREC_CTRL_STOP                 (1u << 1)   /* finish: flush, pad, complete, -> DONE */
#define NVREC_CTRL_ABORT                (1u << 2)   /* stop issuing at once, wait in-flight -> ABORTED */
#define NVREC_CTRL_CREDIT_RST           (1u << 4)   /* both SSDs: credits := CREDIT_INIT, in-flight := 0 */
#define NVREC_CTRL_STATS_RST            (1u << 5)   /* clear CQ statistics + latency (not credits) */
#define NVREC_CTRL_CREDIT_RST_SSD(s)    (1u << (6 + (s)))  /* the same for SSD s (0, 1) only */

/*
 * START (record): clears the run counters (CHUNKS_*, CMDS_*, BYTES, RING_*,
 * errors, latency stats), the slot table and the ring pointers, latches the
 * configuration below and enters RUN. The ring writer takes beats from the
 * ingest FIFO into slot 0, 1, ...
 * STOP (record): the writer stores every beat that is in the ingest FIFO when
 * STOP is seen, pads the open chunk with zero beats up to a whole LBA, closes
 * it (its command then has a shorter NLB), waits until every command has
 * completed and enters DONE (IRQ DONE). Beats arriving after STOP stay in the
 * FIFO (stop the source first; SOFT_RST before the next run).
 * LENGTH_CHUNKS != 0 ends a record run by itself after that many chunks
 * (exactly LENGTH_CHUNKS * CHUNK_SIZE bytes, no padding) -> DONE.
 * Playback: START issues Read commands for chunks 0 .. LENGTH_CHUNKS-1 (must
 * be != 0) into the ring as slots become free, the ring reader streams the
 * completed chunks in order into the egress FIFO / user_data_sink; DONE when
 * the last chunk has been streamed. STOP in playback = ABORT.
 * ABORT: no new command is issued, the writer/reader stop at the next burst
 * boundary; in-flight commands are allowed to complete; then ABORTED.
 */

/* 0x104 CONFIG (RW, latched at START) */
#define NVREC_CONFIG                    0x104
#define NVREC_CONFIG_MODE_PLAY          (1u << 0)   /* 0 = record (Write), 1 = playback (Read) */
#define NVREC_CONFIG_FUA                (1u << 1)   /* set FUA in every Write */
#define NVREC_CONFIG_N_MEMBERS_SHIFT    4           /* [5:4] stripe members: 1 or 2 (0 = 1) */
#define NVREC_CONFIG_N_MEMBERS_MASK     (3u << 4)
#define NVREC_CONFIG_CREDIT_PER_CQE     (1u << 8)   /* 1 = ignore M_AXIS tuser credit, +1 per CQE */
#define NVREC_CONFIG_RESET              0x00000010u /* 1 member, record */

/* 0x108 STATE (RO) */
#define NVREC_STATE                     0x108
#define NVREC_STATE_MASK                0xFu
#define NVREC_STATE_IDLE                0
#define NVREC_STATE_RUN                 1
#define NVREC_STATE_DRAIN               2   /* STOP/LENGTH reached: finishing */
#define NVREC_STATE_DONE                3
#define NVREC_STATE_ABORTING            4
#define NVREC_STATE_ABORTED             5
#define NVREC_STATE_WR_BUSY             (1u << 8)   /* ring writer has bursts in flight */
#define NVREC_STATE_RD_BUSY             (1u << 9)   /* ring reader has bursts in flight */
#define NVREC_STATE_RING_FULL           (1u << 10)  /* writer waiting for a free slot (now) */
#define NVREC_STATE_INJ_BUSY            (1u << 11)  /* injector SQE not yet accepted */
#define NVREC_STATE_HA_DEAD             (1u << 12)  /* 1.1: the Host Accelerator register
                                                       interface stopped answering (evaluation
                                                       license expired); sticky until the
                                                       bitstream is reloaded */

/* 0x10C IRQ_STATUS (W1C except INJ_CQE which is a level) */
#define NVREC_IRQ_STATUS                0x10C
#define NVREC_IRQ_DONE                  (1u << 0)   /* run reached DONE */
#define NVREC_IRQ_CMD_ERROR             (1u << 1)   /* a builder CQE had status != 0 */
#define NVREC_IRQ_OVERFLOW              (1u << 2)   /* ingest dropped beats while the run accepted data */
#define NVREC_IRQ_INJ_CQE               (1u << 3)   /* level: injector CQE FIFO not empty */
#define NVREC_IRQ_UNEXPECTED_CQE        (1u << 4)   /* CQE for a slot that was not in flight */
#define NVREC_IRQ_ABORTED               (1u << 5)   /* run reached ABORTED */
#define NVREC_IRQ_HA_DEAD               (1u << 6)   /* 1.1: STATE.HA_DEAD went to 1 (set again
                                                       after SOFT_RST while still dead) */
/* 0x110 IRQ_ENABLE (RW): same bits; irq output = |(STATUS & ENABLE) */
#define NVREC_IRQ_ENABLE                0x110

/* 0x118/0x11C TIMESTAMP (RO, 64-bit): free-running dp_clk cycle counter */
#define NVREC_TIMESTAMP_LO              0x118
#define NVREC_TIMESTAMP_HI              0x11C

/* ---- Ring / command configuration (RW, latched at START) --------------- */
#define NVREC_RING_BASE_LO              0x120   /* 4 KB aligned ([11:0] ignored) */
#define NVREC_RING_BASE_HI              0x124
#define NVREC_NUM_CHUNKS                0x128   /* 1 .. MAX_SLOTS, reset 256 */
#define NVREC_CHUNK_SIZE                0x12C   /* bytes, power of 2, 64 KB .. 4 MB, reset 1 MB */
#define NVREC_PRP_LIST_BASE_LO          0x130   /* 4 KB aligned */
#define NVREC_PRP_LIST_BASE_HI          0x134
#define NVREC_PRP_LIST_SHIFT            0x138   /* per-slot list stride = 1 << shift, 12..16, reset 12 */
#define NVREC_LBA_SHIFT                 0x13C   /* log2(LBA size): 9 or 12, reset 9 */
#define NVREC_START_CHUNK_LO            0x140   /* array chunk index of the first chunk */
#define NVREC_START_CHUNK_HI            0x144
#define NVREC_LENGTH_CHUNKS             0x148   /* 0 = until STOP (record only) */
#define NVREC_LAST_CHUNK_BYTES          0x14C   /* playback: bytes of the last chunk, 0 = full;
                                                   multiple of the LBA size */
#define NVREC_MAX_SLOTS                 0x150   /* RO: slot table size (RTL parameter, 1024) */
#define NVREC_CREDIT_INIT               0x154   /* RW: initial credits per SSD, reset 63 */

/* ---- Stripe members m = 0, 1 (RW, latched at START) -------------------- */
#define NVREC_MEMBER_BASE(m)            (0x180 + (m) * 0x20)
#define NVREC_MEMBER_NSID(m)            (NVREC_MEMBER_BASE(m) + 0x00)  /* reset 1 */
#define NVREC_MEMBER_SEL(m)             (NVREC_MEMBER_BASE(m) + 0x04)
#define NVREC_MEMBER_SEL_SSD_SHIFT      0       /* [4:0] nvmeha SSD index (tuser[13:9]) */
#define NVREC_MEMBER_SEL_SSD_MASK       0x1Fu
#define NVREC_MEMBER_SEL_SQ_SHIFT       8       /* [13:8] nvmeha SQ number (tuser[5:0]) */
#define NVREC_MEMBER_SEL_SQ_MASK        (0x3Fu << 8)
/* reset: member 0 = SSD 0, member 1 = SSD 1; SQ = NVREC_NVMEHA_HW_QIDX (0).
 * The SQ field is ignored by the IP (QoS off) but is driven anyway. */
#define NVREC_MEMBER_BASE_LBA_LO(m)     (NVREC_MEMBER_BASE(m) + 0x08)
#define NVREC_MEMBER_BASE_LBA_HI(m)     (NVREC_MEMBER_BASE(m) + 0x0C)

/* ---- Per nvmeha SSD s = 0, 1 ------------------------------------------- */
#define NVREC_SSD_BASE(s)               (0x1C0 + (s) * 0x20)
#define NVREC_SSD_MAX_INFLIGHT(s)       (NVREC_SSD_BASE(s) + 0x00) /* RW, reset 32; builder
                                           commands in flight on this SSD, 1..63 */
#define NVREC_SSD_INFLIGHT(s)           (NVREC_SSD_BASE(s) + 0x04) /* RO: builder + injector */
#define NVREC_SSD_CREDITS(s)            (NVREC_SSD_BASE(s) + 0x08) /* RO: HW-interface credits */
/* SSD_ISSUED / SSD_COMPLETED / SSD_ERRORS (and INJ_SUBMITTED / INJ_COMPLETED)
 * count since the last SOFT_RST (or power-on); all five clear together, so
 * ISSUED - COMPLETED = commands in flight. */
#define NVREC_SSD_ISSUED(s)             (NVREC_SSD_BASE(s) + 0x0C) /* RO: SQEs accepted by the IP */
#define NVREC_SSD_COMPLETED(s)          (NVREC_SSD_BASE(s) + 0x10) /* RO: CQEs received */
#define NVREC_SSD_ERRORS(s)             (NVREC_SSD_BASE(s) + 0x14) /* RO: CQEs with status != 0 */
#define NVREC_SSD_INFLIGHT_HWM(s)       (NVREC_SSD_BASE(s) + 0x18) /* RO; any write clears */
/* A SQE is only pushed to the IP when the SSD's credit counter is > 0, so the
 * IP never discards a hardware SQE (PG328 interrupt status bit 4). Credits
 * come back with every CQE (M_AXIS tuser[15:5], or +1 per CQE when
 * CONFIG.CREDIT_PER_CQE = 1). */

/* ---- Run statistics (RO; cleared by START, STATS_RST, SOFT_RST) -------- */
#define NVREC_CHUNKS_FILLED_LO          0x200   /* chunks fully written into the ring */
#define NVREC_CHUNKS_FILLED_HI          0x204
#define NVREC_CMDS_ISSUED_LO            0x208   /* builder SQEs accepted by the IP */
#define NVREC_CMDS_ISSUED_HI            0x20C
#define NVREC_CMDS_DONE_LO              0x210   /* builder CQEs received */
#define NVREC_CMDS_DONE_HI              0x214
#define NVREC_CMD_ERRORS                0x218   /* builder CQEs with status != 0 */
#define NVREC_UNEXPECTED_CQES           0x21C   /* CQEs for a slot not in flight */
#define NVREC_BYTES_LO                  0x220   /* record: data bytes stored (without padding);
                                                   playback: bytes streamed to the sink */
#define NVREC_BYTES_HI                  0x224
#define NVREC_RING_FILL                 0x228   /* slots in use now */
#define NVREC_RING_HWM                  0x22C   /* max RING_FILL; any write clears */
#define NVREC_ERR_LAST_STATUS           0x230   /* [14:0] CQE status (DW3[31:17]), [20:16] SSD,
                                                   [31] valid */
#define NVREC_ERR_LAST_CID              0x234   /* [15:0] CID, [31:16] SQID of the last error */
#define NVREC_CHUNKS_RELEASED_LO        0x238   /* slots completed + released in order */
#define NVREC_CHUNKS_RELEASED_HI        0x23C
#define NVREC_PAD_BYTES                 0x240   /* zero bytes added to the last chunk at STOP */
#define NVREC_RING_FULL_CYCLES_LO       0x248   /* dp_clk cycles the writer waited for a slot */
#define NVREC_RING_FULL_CYCLES_HI       0x24C
/* RUN_DROP_COUNT (64-bit): ingest drops while the record run was ACCEPTING
 * data (from START until STOP is seen / LENGTH_CHUNKS reached / ABORT).
 * ING_DROP_COUNT keeps counting while the source runs after that; a
 * recording is valid when RUN_DROP_COUNT = 0. (Taken from the ingest
 * snapshot: drops in the last ~0.5 us before the end may be missed.) */
#define NVREC_RUN_DROP_COUNT_LO         0x250
#define NVREC_RUN_DROP_COUNT_HI         0x254
/* 1.1: RUN_FIFO_HWM: ingest FIFO high-water mark (beats) while the record run
 * was accepting data; cleared at START / SOFT_RST. ING_FIFO_HWM also sees the
 * FIFO fill up after the run when the source keeps running. */
#define NVREC_RUN_FIFO_HWM              0x258

/* ---- Completion latency of builder commands (dp_clk cycles, submit->CQE) */
#define NVREC_LAT_MIN                   0x280   /* 0xFFFF_FFFF if no sample */
#define NVREC_LAT_MAX                   0x284
#define NVREC_LAT_COUNT                 0x288
#define NVREC_LAT_SUM_LO                0x290
#define NVREC_LAT_SUM_HI                0x294
/* 16 log2 bins: bin 0 = latency < 2^10 cycles, bin i (1..14) = [2^(9+i), 2^(10+i)),
 * bin 15 = >= 2^24 cycles. At 250 MHz: 4.1 us, 8.2 us, ... 33.6 ms, 67 ms. */
#define NVREC_LAT_HIST(i)               (0x2C0 + (i) * 4)
#define NVREC_LAT_HIST_BINS             16
#define NVREC_LAT_HIST_BIN0_LOG2        10

/* ---- CPU command injector (nvrec_inj) ---------------------------------- */
/*
 * Lets software push its own 64-byte SQE onto the HARDWARE SQ of the IP
 * (S_AXIS), arbitrated with the command builder. It is the ONLY CPU path to
 * the I/O queues (no software queues in the IP). Several injected commands
 * may be outstanding (use distinct CIDs; up to NVREC_INJ_CQ_FIFO_DEPTH).
 * Usage:
 *   1. wait until INJ_STATUS.BUSY = 0
 *   2. write INJ_SQE(0..15) (DW0..DW15 of the SQE; CID bit 15 is forced to 1)
 *   3. write INJ_CTRL = SUBMIT | (ssd << 8)    (sq = 0)
 *   4. the CQE arrives in the injector CQE FIFO (IRQ INJ_CQE while not empty):
 *      read INJ_CQE(0..3) and INJ_CQ_INFO, then write INJ_CQ_POP.
 * The injector waits for an SSD credit like the builder. At most
 * NVREC_INJ_CQ_FIFO_DEPTH injected commands may be outstanding: when the CQE
 * FIFO is full, the IP's completion stream (for both sources) is stalled.
 */
#define NVREC_INJ_SQE(i)                (0x300 + (i) * 4)  /* RW, i = 0..15 */
#define NVREC_INJ_CTRL                  0x340
#define NVREC_INJ_CTRL_SUBMIT           (1u << 0)   /* W: submit; R: busy */
#define NVREC_INJ_CTRL_SSD_SHIFT        8           /* [12:8]  -> tuser[13:9] */
#define NVREC_INJ_CTRL_SSD_MASK         (0x1Fu << 8)
#define NVREC_INJ_CTRL_SQ_SHIFT         16          /* [21:16] -> tuser[5:0] */
#define NVREC_INJ_CTRL_SQ_MASK          (0x3Fu << 16)
#define NVREC_INJ_STATUS                0x344
#define NVREC_INJ_STATUS_BUSY           (1u << 0)   /* SQE waiting for credit / IP */
#define NVREC_INJ_STATUS_CQ_VALID       (1u << 1)   /* INJ_CQE holds an entry */
#define NVREC_INJ_STATUS_CQ_COUNT_SHIFT 8           /* [12:8] entries in the CQE FIFO */
#define NVREC_INJ_STATUS_CQ_COUNT_MASK  (0x1Fu << 8)
#define NVREC_INJ_CQ_POP                0x348       /* W: any write pops the head CQE */
#define NVREC_INJ_CQ_INFO               0x34C       /* head CQE: [4:0] SSD, [15:5] credit (tuser) */
#define NVREC_INJ_CQE(i)                (0x350 + (i) * 4)  /* RO, head CQE DW0..DW3 */
#define NVREC_INJ_SUBMITTED             0x360       /* RO counter */
#define NVREC_INJ_COMPLETED             0x364       /* RO counter */
#define NVREC_INJ_CQ_FIFO_DEPTH         16
#define NVREC_INJ_CID_TAG               0x8000u

/* ---- Doorbell monitor (debug) ------------------------------------------ */
/* Every write the IP makes on M_AXI_SSD (SQ tail / CQ head doorbells) is
 * counted and the last 8 are kept (address as the IP drove it, data). */
#define NVREC_DB_COUNT                  0x380       /* RO: total doorbell writes */
#define NVREC_DB_NEXT                   0x384       /* RO: index of the next entry to write */
#define NVREC_DB_ADDR(i)                (0x3C0 + (i) * 8)  /* i = 0..7 */
#define NVREC_DB_DATA(i)                (0x3C4 + (i) * 8)
#define NVREC_DB_ENTRIES                8

/* ---- Datapath constants ------------------------------------------------- */
#define NVREC_BEAT_BYTES                16          /* 128-bit AXI-Stream beat */
#define NVREC_PAGE_SIZE                 4096        /* NVMe MPS = 0 */

/* ===========================================================================
 * AMD NVMe Host Accelerator S_AXI_LITE registers (PG328 v1.0 Table 9).
 * n = SSD index, m = queue index inside the SSD (SW first), C_MAX_SQ = 2.
 * Program all base registers before any I/O; they must not change at run time.
 * ========================================================================= */
/* SSD BAR0 bus address (as the CPU uses it). The IP writes the QID 1 doorbells
 * at BAR0 + 0x1008 (SQ tail) / + 0x100C (CQ head): it adds 0x1000 itself and
 * assumes CAP.DSTRD = 0 (verified in simulation of the encrypted IP). */
#define NVMEHA_SSD_PCIE_BASE_LO(n)      (0x0000 + (n) * 8)
#define NVMEHA_SSD_PCIE_BASE_HI(n)      (0x0004 + (n) * 8)
#define NVMEHA_SQ1_BASE                 0x0100  /* SSD0 SQ1 base [31:12], = NVREC_QWIN_SQ_BASE */
#define NVMEHA_CQ1_BASE                 0x0104  /* SSD0 CQ1 base [31:12], = NVREC_QWIN_CQ_BASE */
#define NVMEHA_SQ_BASE_RB(n, m)         (0x0100 + ((n) * NVREC_NVMEHA_NUM_SQ + (m)) * 16) /* RO */
#define NVMEHA_CQ_BASE_RB(n, m)         (0x0104 + ((n) * NVREC_NVMEHA_NUM_SQ + (m)) * 16) /* RO */
#define NVMEHA_SQ_FLUSH(n, m)           (0x0108 + ((n) * NVREC_NVMEHA_NUM_SQ + (m)) * 16)
#define NVMEHA_SQ_FLUSH_DONE(n, m)      (0x010C + ((n) * NVREC_NVMEHA_NUM_SQ + (m)) * 16)
/* With no software queues only bits 1, 4 and 5 are meaningful. */
#define NVMEHA_INT_ENABLE               0x8104
#define NVMEHA_INT_STATUS               0x8108  /* write 1 to bit 0 to clear CQ-available */
#define NVMEHA_INT_CQ_AVAIL             (1u << 0)
#define NVMEHA_INT_ADDR_ERR             (1u << 1)
#define NVMEHA_INT_SW_CREDIT_ERR        (1u << 2)
#define NVMEHA_INT_SW_RD_NO_CQ          (1u << 3)
#define NVMEHA_INT_HW_NO_CREDIT         (1u << 4)  /* HW SQE discarded */
#define NVMEHA_INT_TIMEOUT              (1u << 5)
#define NVMEHA_CQ_AVAIL_COUNT           0x810C  /* read once per interrupt */
#define NVMEHA_CMD_ERR_COUNT            0x8110
#define NVMEHA_TIMEOUT                  0x8114  /* clk_core cycles, reset 0x9C4 */
#define NVMEHA_SSD_ISSUED(n)            (0x8200 + (n) * 16)  /* STATISTICS_EN = 1 */
#define NVMEHA_SSD_ERR_COMPL(n)         (0x8204 + (n) * 16)
#define NVMEHA_SSD_COMPLETED(n)         (0x8208 + (n) * 16)
#define NVMEHA_QSTATUS(n, m)            (0x8400 + ((n) * NVREC_NVMEHA_NUM_SQ + (m)) * 4)
#define NVMEHA_QSTATUS_SQ_FULL          (1u << 0)
#define NVMEHA_QSTATUS_SQ_EMPTY         (1u << 1)
#define NVMEHA_QSTATUS_CQ_FULL          (1u << 2)
#define NVMEHA_QSTATUS_CQ_EMPTY         (1u << 3)
#define NVMEHA_QSTATUS_SQ_AVAIL_SHIFT   4       /* [12:4] */
#define NVMEHA_QSTATUS_SQ_AVAIL_MASK    (0x1FFu << 4)
#define NVMEHA_QSTATUS_TIMEOUT          (1u << 13)

/* nvmeha S_AXI (software queues): not present in this build (C_EN_SW_IF = 0).
 * PG328 / generated example design forms, for reference only: SQE push at
 * ssd * 0x1000 + sq * 0x40 (PG328 Table 1) or {ssd, sq, 6'b0} (example
 * design), CQE pop at 0x3_0000. */

/* Hardware stream sideband (for reference) */
#define NVMEHA_S_TUSER(ssd, sq)         ((((ssd) & 0x1Fu) << 9) | ((sq) & 0x3Fu))
#define NVMEHA_M_TUSER_SSD(t)           ((t) & 0x1Fu)
#define NVMEHA_M_TUSER_CREDIT(t)        (((t) >> 5) & 0x7FFu)

#endif /* NVREC_REGS_H */
