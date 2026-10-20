# Register map

The design has two register windows:

| Window | What | Base (all targets) | Size |
|---|---|---|---|
| `nvrec_core` | this design's recorder engine (ring writer, command builder, completion router, ring reader, command injector) plus the fdrec test pattern generator, ingest FIFO, checker and egress FIFO registers | `0x4_2001_0000` | 4 KB |
| `nvmeha` `S_AXI_LITE` | AMD NVMe Host Accelerator registers (PG328), behind the AXI-Lite timeout guard | `0x4_2002_0000` | 64 KB |

All offsets, bit fields and platform constants are defined for software in
[`include/nvrec_regs.h`](https://github.com/fpgadeveloper/fpga-drive-nvme-offload/blob/main/include/nvrec_regs.h),
which is shared by the kernel driver and the apps. Keep this page, the header and the RTL
(`Vivado/src/hdl/nvrec_regs.v`) in sync.

## Conventions

* Registers are 32 bits wide; offsets are byte offsets from the block's base address.
* **RO** read-only, **RW** read/write, **W1C** write 1 to clear, **SC** self-clearing
  (write 1 to trigger; reads 0 unless stated). Unmapped offsets read 0 and ignore writes.
* One HI latch is shared by all 64-bit counters: read `*_LO` immediately followed by its
  `*_HI` (no other `*_LO` read in between).
* **64-bit counters** are split into `*_LO` / `*_HI`. Reading `*_LO` latches the matching
  high half; read `*_LO` first, then `*_HI`. 64-bit configuration registers (addresses,
  LBAs) are plain RW pairs.
* "Latched at START" means the engine copies the register when a run starts; writing it
  during a run has no effect on that run.

## nvrec_core: fdrec-compatible registers (0x000-0x0BF)

These offsets and their behaviour are identical to the
[fpga-drive-recorder register map](https://recorder.fpgadrive.com/register_map.html), so
code written for a custom data source or sink carries over. Differences:

* `VERSION` reads the **nvrec** register map version (`0x0001_0001` = 1.1), and the new
  `ID` register at `0x03C` reads `0x4E56_5243` ("NVRC").
* There is no packetizer: `0x040` / `0x044` (`PKT_CTRL`, `PKT_LEN`) are reserved. The ring
  writer frames the data itself. `0x048` / `0x04C` are `ING_BEATS_OUT`: beats the ring
  writer took from the ingest FIFO (fdrec's `PKT_BEATS_OUT`).
* The egress FIFO is fed by the ring reader (`nvrec_rd`) instead of an AXI DMA; `TLAST`
  marks the end of each chunk.
* `GLOBAL_CTRL.SOFT_RST` additionally resets the nvrec ring state and every nvrec
  statistics counter (not the credit counters).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | `VERSION` | RO | `0x0001_0001` | [31:16] major, [15:0] minor |
| 0x004 | `SRC_CLK_HZ` | RO | parameter | `src_clk` frequency in Hz |
| 0x008 | `DP_CLK_HZ` | RO | parameter | `dp_clk` frequency in Hz |
| 0x00C | `GLOBAL_CTRL` | RW | 0 | bit0 `SOFT_RST` (SC, reads 1 while in progress) |
| 0x010 | `TPG_CTRL` | RW | 0 | bit0 `ENABLE`, bit1 `SEQ_RST` (SC) |
| 0x014 | `TPG_RATE_INC` | RW | 0 | Q1.31 beats per `src_clk` (`0x8000_0000` = 1 beat/clock) |
| 0x018/0x01C | `TPG_SEQ_NEXT` | RO | 0 | next sequence number (64-bit) |
| 0x020 | `ING_STATUS` | RW | 0 | bit0 `OVERFLOW` (sticky, W1C) |
| 0x024 | `ING_FIFO_HWM` | RW | 0 | FIFO high-water mark in beats; any write clears. Also counts the fill after a run when the source keeps running: use `RUN_FIFO_HWM` (0x258) for a recording |
| 0x028/0x02C | `ING_DROP_COUNT` | RO | 0 | beats dropped (64-bit) |
| 0x030/0x034 | `ING_BEATS_IN` | RO | 0 | beats offered by the source (64-bit) |
| 0x038 | `ING_FIFO_DEPTH` | RO | parameter | ingest FIFO depth in beats |
| 0x03C | `ID` | RO | `0x4E56_5243` | "NVRC" |
| 0x048/0x04C | `ING_BEATS_OUT` | RO | 0 | beats taken by the ring writer (64-bit) |
| 0x060 | `CHK_CTRL` | RW | 0 | bit0 `ENABLE`, bit1 `RESET` (SC, reads 1 while busy) |
| 0x064 | `CHK_RATE_INC` | RW | `0x8000_0000` | sink rate, Q1.31 beats per `src_clk` |
| 0x070-0x09C | `CHK_BEATS`, `CHK_ERRORS`, `CHK_GAPS`, `CHK_GAP_BEATS`, `CHK_UNDERFLOWS`, `CHK_LAST_SEQ` | RO | 0 | checker counters (64-bit each), as fdrec |
| 0x0A0 | `EGR_CTRL` | RW | 0 | bit0 `FLUSH` |
| 0x0A4 | `EGR_FIFO_DEPTH` | RO | parameter | egress FIFO depth in beats |
| 0x0A8/0x0AC | `EGR_BEATS_IN` | RO | 0 | beats written into the egress FIFO |
| 0x0B0/0x0B4 | `EGR_DISCARD` | RO | 0 | beats discarded while `FLUSH` = 1 |
| 0x0B8 | `EGR_FIFO_LEVEL` | RO | 0 | egress FIFO fill level |

## nvrec_core: the NVMe offload engine (0x100-0x3FF)

### How a run works

The recording lives in a **ring** of `NUM_CHUNKS` slots of `CHUNK_SIZE` bytes at
`RING_BASE` in PS DDR. One chunk is one NVMe command. The chunk with run index `c`
(0, 1, 2, ... from the start of the run) uses ring slot `c % NUM_CHUNKS`. Its **array chunk
index** is `A = START_CHUNK + c`; it goes to stripe member `m = A % N_MEMBERS` at member LBA

```
MEMBER_BASE_LBA[m] + (A / N_MEMBERS) * (CHUNK_SIZE >> LBA_SHIFT)
```

This is the Linux md RAID0 layout with an md chunk size equal to `CHUNK_SIZE`, so a
recording striped over two SSDs can be assembled with `mdadm` (`MEMBER_BASE_LBA` = the md
data offset of the member plus any partition offset). With one member it is a plain
contiguous LBA range.

**Record**: the ring writer (`nvrec_wr`) writes the ingested stream into the slots in
order with 4 KB AXI bursts (`S_AXI_HP2_FPD`). When a slot is full and every burst has been
acknowledged, the command builder (`nvrec_cmd`) pushes one 64-byte NVMe Write SQE to the
Host Accelerator's hardware interface, the Host Accelerator rings the SSD's doorbell, the SSD
reads the data from DDR itself, and the completion comes back on the Host Accelerator's
`M_AXIS`. The completion router (`nvrec_cq`) matches it by CID to the slot and releases
slots **in order**, so completions that arrive out of order are handled. If no slot is free
(the SSDs are not keeping up), the writer waits, the ingest FIFO fills and beats are dropped
and counted (`ING_DROP_COUNT`) -- the only failure mode, as in fdrec.

**Playback**: the builder issues NVMe Read commands for chunks `0 .. LENGTH_CHUNKS-1` into
free slots; the ring reader (`nvrec_rd`) streams completed chunks in order into the egress
FIFO and `user_data_sink`.

The SQE built by the hardware (little-endian dwords):

| Dword | Content |
|---|---|
| DW0 | opcode `0x01` (Write) or `0x02` (Read), FUSE = 0, PSDT = 0 (PRP), CID = slot number (bit 15 = 0) |
| DW1 | NSID = `MEMBER_NSID[m]` |
| DW2-DW5 | 0 |
| DW6-DW7 | PRP1 = `RING_BASE + slot * CHUNK_SIZE` |
| DW8-DW9 | PRP2: `PRP_LIST_BASE + (slot << PRP_LIST_SHIFT)` if the command spans more than 2 pages, `PRP1 + 4096` if it spans 2 pages, 0 for 1 page |
| DW10-DW11 | SLBA |
| DW12 | [15:0] NLB - 1, [30] FUA (`CONFIG.FUA`) |
| DW13-DW15 | 0 |

Software builds the PRP lists once, because the ring never moves: the list of slot `s`
(at `PRP_LIST_BASE + (s << PRP_LIST_SHIFT)`) holds the addresses of pages 1 .. P-1 of the
slot (P = `CHUNK_SIZE` / 4096, memory page size 4 KB). A list of more than 512 entries
chains to a second page (NVMe rule: the last entry of a full list page points to the next
list page), so 4 MB chunks need `PRP_LIST_SHIFT` = 13.

Command IDs: builder commands use CID = slot (bit 15 = 0); commands from the CPU command
injector always have CID bit 15 = 1 (the hardware forces it).

### Control and status

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x100 | `CTRL` | W, SC | 0 | bit0 `START`, bit1 `STOP`, bit2 `ABORT`, bit4 `CREDIT_RST` (both SSDs: credits := `CREDIT_INIT`, in-flight counters := 0), bit5 `STATS_RST` (clear the completion statistics and latency), bit6 / bit7 `CREDIT_RST` for SSD 0 / SSD 1 only |
| 0x104 | `CONFIG` | RW | `0x10` | bit0 `MODE_PLAY` (0 record, 1 playback), bit1 `FUA`, [5:4] `N_MEMBERS` (1 or 2; 0 = 1), bit8 `CREDIT_PER_CQE` (ignore the credit in `M_AXIS` tuser, +1 per CQE). Latched at START |
| 0x108 | `STATE` | RO | 0 | [3:0] 0 `IDLE`, 1 `RUN`, 2 `DRAIN`, 3 `DONE`, 4 `ABORTING`, 5 `ABORTED`; bit8 writer busy, bit9 reader busy, bit10 ring full now, bit11 injector busy, bit12 `HA_DEAD` (the Host Accelerator register interface stopped answering, see [below](#host-accelerator-timeout-guard); sticky until the bitstream is reloaded) |
| 0x10C | `IRQ_STATUS` | W1C | 0 | bit0 `DONE`, bit1 `CMD_ERROR`, bit2 `OVERFLOW` (ingest drop while the run accepted data), bit3 `INJ_CQE` (level: injector CQE FIFO not empty, not W1C), bit4 `UNEXPECTED_CQE`, bit5 `ABORTED`, bit6 `HA_DEAD` (set when `STATE.HA_DEAD` goes to 1, and again after a `SOFT_RST` while it is 1) |
| 0x110 | `IRQ_ENABLE` | RW | 0 | same bits; the `irq` output is `|(IRQ_STATUS & IRQ_ENABLE)` (level, active high) |
| 0x118/0x11C | `TIMESTAMP` | RO | 0 | free-running `dp_clk` cycle counter (64-bit) |

* **START** (from `IDLE`, `DONE` or `ABORTED`): clears the run counters, the slot table and
  the ring pointers, latches the configuration and enters `RUN`.
* **STOP** (record): the writer stores every beat that is in the ingest FIFO when STOP is
  seen, pads the open chunk with zero beats to a whole LBA (`PAD_BYTES`), closes it (its
  command has a shorter NLB), waits until every command has completed and enters `DONE`.
  Stop the data source before STOP; beats arriving later stay in the FIFO (use `SOFT_RST`
  before the next run).
* **LENGTH_CHUNKS** != 0 ends a record run by itself after exactly that many chunks.
* **Playback**: `LENGTH_CHUNKS` must be != 0; `LAST_CHUNK_BYTES` (0 = full chunk) sets the
  size of the last chunk. `DONE` when the last chunk has been streamed into the egress
  FIFO. STOP in playback acts as ABORT.
* **ABORT**: no new command is issued, the writer / reader stop at the next burst boundary,
  in-flight commands complete, then `ABORTED`.
* A record run is good when `RUN_DROP_COUNT` = 0 and `CMD_ERRORS` = 0. (`ING_DROP_COUNT`
  keeps counting while the source runs on after the run stopped taking data.)

### Ring and command configuration (latched at START)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x120/0x124 | `RING_BASE` | RW | 0 | ring address in PS DDR (64-bit, 4 KB aligned) |
| 0x128 | `NUM_CHUNKS` | RW | 256 | slots in the ring, 1 .. `MAX_SLOTS` |
| 0x12C | `CHUNK_SIZE` | RW | `0x0010_0000` | bytes per chunk, power of 2, 64 KB .. 4 MB; must not exceed the SSD's MDTS |
| 0x130/0x134 | `PRP_LIST_BASE` | RW | 0 | PRP list table (64-bit, 4 KB aligned) |
| 0x138 | `PRP_LIST_SHIFT` | RW | 12 | log2 of the per-slot PRP list stride (12 .. 16) |
| 0x13C | `LBA_SHIFT` | RW | 9 | log2 of the LBA size (9 = 512 B, 12 = 4 KB) |
| 0x140/0x144 | `START_CHUNK` | RW | 0 | array chunk index of the first chunk of the run (64-bit) |
| 0x148 | `LENGTH_CHUNKS` | RW | 0 | chunks to record (0 = until STOP) or to play |
| 0x14C | `LAST_CHUNK_BYTES` | RW | 0 | playback: bytes in the last chunk (0 = full), multiple of the LBA size |
| 0x150 | `MAX_SLOTS` | RO | parameter | slot table size (1024) |
| 0x154 | `CREDIT_INIT` | RW | 63 | initial credit per SSD (number of HW SQs x (depth - 1)) |

### Stripe members (m = 0, 1; latched at START)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x180 + m*0x20 | `MEMBER_NSID` | RW | 1 | namespace ID |
| 0x184 + m*0x20 | `MEMBER_SEL` | RW | m, SQ 0 | [4:0] Host Accelerator SSD index (`S_AXIS` tuser[13:9]), [13:8] SQ number (tuser[5:0]; ignored by the IP with QoS off) |
| 0x188/0x18C + m*0x20 | `MEMBER_BASE_LBA` | RW | 0 | first LBA of the member's data area (64-bit) |

### Per Host Accelerator SSD (s = 0, 1)

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x1C0 + s*0x20 | `SSD_MAX_INFLIGHT` | RW | 32 | builder commands in flight on this SSD (1 .. 63) |
| 0x1C4 + s*0x20 | `SSD_INFLIGHT` | RO | 0 | commands in flight now (builder + injector) |
| 0x1C8 + s*0x20 | `SSD_CREDITS` | RO | 0 | hardware-interface credits; load with `CTRL.CREDIT_RST` |
| 0x1CC + s*0x20 | `SSD_ISSUED` | RO | 0 | SQEs accepted by the IP (32-bit, wraps) |
| 0x1D0 + s*0x20 | `SSD_COMPLETED` | RO | 0 | CQEs received |
| 0x1D4 + s*0x20 | `SSD_ERRORS` | RO | 0 | CQEs with status != 0 |
| 0x1D8 + s*0x20 | `SSD_INFLIGHT_HWM` | RO | 0 | highest `SSD_INFLIGHT`; any write clears |

`SSD_ISSUED`, `SSD_COMPLETED`, `SSD_ERRORS`, `INJ_SUBMITTED` and `INJ_COMPLETED` count since
the last `SOFT_RST` (or power-on) and are cleared together, so `SSD_ISSUED - SSD_COMPLETED` is
the number of commands in flight. (Before 1.1, `SSD_ISSUED` and `INJ_SUBMITTED` survived a
`SOFT_RST` while the completion counters did not.)

A SQE (builder or injector) is pushed to the Host Accelerator only while the SSD's credit
counter is above 0, so the IP never discards a hardware SQE (PG328: interrupt status
bit 4). Every CQE returns credit (`M_AXIS` tuser[15:5], or +1 per CQE with
`CONFIG.CREDIT_PER_CQE`). After the driver has created the I/O queues it writes
`CTRL.CREDIT_RST` once.

### Run statistics (RO; cleared by START, `CTRL.STATS_RST` and `SOFT_RST`)

| Offset | Name | Description |
|---|---|---|
| 0x200/0x204 | `CHUNKS_FILLED` | chunks completely written into the ring |
| 0x208/0x20C | `CMDS_ISSUED` | builder SQEs accepted by the IP |
| 0x210/0x214 | `CMDS_DONE` | builder CQEs received |
| 0x218 | `CMD_ERRORS` | builder CQEs with status != 0 |
| 0x21C | `UNEXPECTED_CQES` | CQEs whose slot was not in flight |
| 0x220/0x224 | `BYTES` | record: data bytes stored (without padding); playback: bytes streamed |
| 0x228 | `RING_FILL` | slots in use now |
| 0x22C | `RING_HWM` | highest `RING_FILL`; any write clears |
| 0x230 | `ERR_LAST_STATUS` | last error: [14:0] CQE status field (DW3[31:17]), [20:16] SSD, [31] valid |
| 0x234 | `ERR_LAST_CID` | last error: [15:0] CID, [31:16] SQID |
| 0x238/0x23C | `CHUNKS_RELEASED` | slots completed and released in order |
| 0x240 | `PAD_BYTES` | zero bytes appended to the last chunk at STOP |
| 0x248/0x24C | `RING_FULL_CYCLES` | `dp_clk` cycles the writer waited for a free slot |
| 0x250/0x254 | `RUN_DROP_COUNT` | ingest drops while the record run was accepting data (START until STOP seen / `LENGTH_CHUNKS` reached / ABORT); taken from the ingest snapshot, so drops in the last ~0.5 us may be missed |
| 0x258 | `RUN_FIFO_HWM` | ingest FIFO high-water mark (beats) while the record run was accepting data (same window as `RUN_DROP_COUNT`); the figure to report for a recording |

### Completion latency (builder commands, `dp_clk` cycles from SQE accepted to CQE)

| Offset | Name | Description |
|---|---|---|
| 0x280 | `LAT_MIN` | minimum (`0xFFFF_FFFF` = no sample) |
| 0x284 | `LAT_MAX` | maximum |
| 0x288 | `LAT_COUNT` | samples |
| 0x290/0x294 | `LAT_SUM` | sum of all samples (64-bit) |
| 0x2C0 + i*4 | `LAT_HIST[i]` | i = 0..15: bin 0 < 2^10 cycles, bin i = [2^(9+i), 2^(10+i)), bin 15 >= 2^24 cycles (4.1 us ... 67 ms at 250 MHz) |

### CPU command injector

Software can push its own 64-byte SQE onto the **hardware** SQ of the Host Accelerator,
arbitrated (round robin) with the command builder. The Host Accelerator is built without
software queues, so this is the only CPU path to the I/O queues: the Linux driver uses it
for all block-device / filesystem I/O. Several injected commands may be outstanding at once
(distinct CIDs, at most 16).

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x300 + i*4 | `INJ_SQE[i]` | RW | SQE dword i = 0..15 (CID bit 15 is forced to 1 on submit) |
| 0x340 | `INJ_CTRL` | W / R | write: bit0 `SUBMIT`, [12:8] SSD (tuser[13:9]), [21:16] SQ (tuser[5:0], use 0); read: bit0 = busy |
| 0x344 | `INJ_STATUS` | RO | bit0 busy (waiting for credit / the IP), bit1 CQE valid, [12:8] CQE FIFO count |
| 0x348 | `INJ_CQ_POP` | W | any write pops the head CQE |
| 0x34C | `INJ_CQ_INFO` | RO | head CQE sideband: [4:0] SSD, [15:5] credit |
| 0x350 + i*4 | `INJ_CQE[i]` | RO | head CQE dword i = 0..3 |
| 0x360 | `INJ_SUBMITTED` | RO | injected SQEs accepted by the IP |
| 0x364 | `INJ_COMPLETED` | RO | injector CQEs received |

Sequence: wait for `INJ_STATUS.busy` = 0, write `INJ_SQE[0..15]`, write `INJ_CTRL`. When
`IRQ_STATUS.INJ_CQE` is set, read `INJ_CQE[0..3]` and `INJ_CQ_INFO`, then write
`INJ_CQ_POP`. The injector CQE FIFO holds 16 entries; keep at most 16 injected commands
outstanding (a full FIFO stalls the IP's completion stream for both sources).

### Doorbell monitor (debug)

| Offset | Name | Description |
|---|---|---|
| 0x380 | `DB_COUNT` | doorbell writes made by the IP on `M_AXI_SSD` |
| 0x384 | `DB_NEXT` | index of the entry written next |
| 0x3C0 + i*8 | `DB_ADDR[i]` | i = 0..7: address of a recent doorbell write (as driven by the IP) |
| 0x3C4 + i*8 | `DB_DATA[i]` | its data |

## AMD NVMe Host Accelerator (`nvmeha`)

Configuration in this design: 2 SSDs (`SSD 0` = SSD1 on `xdma_0`, `SSD 1` = SSD2 on
`xdma_1`), **one hardware queue per SSD and no software queues** (`C_NUM_SQ` = 1,
`C_EN_SW_IF` = 0), depth 64, full 64-byte commands, QoS off, statistics registers on,
CQ FIFO depth 64. `clk_core` = `dp_clk` (250 MHz), `clk_axi_lite` = `pl_clk0` (100 MHz).

Why hardware-only: PG328 (Ch. 3, Product Specification) numbers an SSD's software queues
before its hardware queues. With one software and one hardware queue per SSD, the hardware
queue would be NVMe queue ID 2, which a drive that grants a single I/O queue cannot create.
Without software queues the hardware SQ/CQ pair is **NVMe QID 1** on every drive, and the
CPU reaches it through the command injector.

### Queue window

The SQ and CQ memories are inside the IP. The SSDs reach them through the root ports'
`M_AXI_B` masters at the **queue window** `0x9000_0000` (64 KB). The root ports do not
translate inbound addresses, so this is also the PCIe bus address to use in the Create I/O
Completion / Submission Queue admin commands (QID 1, QSIZE 63, physically contiguous,
CQ interrupts disabled):

| Queue | SSD view (= `PRP1` of the Create command) |
|---|---|
| SQ of SSD n | `0x9000_0000 + n * 0x1000` |
| CQ of SSD n | `0x9000_8000 + n * 0x1000` |

Program `0x9000_0000` into `SQ1_BASE` (0x100) and `0x9000_8000` into `CQ1_BASE` (0x104).
The doorbells are written by the IP itself (`M_AXI_SSD` -> doorbell monitor -> root port
`S_AXI_B`) at the PCIe address programmed into `SSDn PCIe base` plus the standard NVMe
doorbell offsets: program the SSD's **BAR0** bus address; the IP adds the 0x1000 doorbell
offset itself and assumes a doorbell stride of 4 bytes (`CAP.DSTRD` = 0), so the QID 1
doorbells land at BAR0 + 0x1008 (SQ tail) and BAR0 + 0x100C (CQ head). (Verified in a
simulation of the encrypted IP with this configuration: SQ tail doorbell of SSD 1 written to
`0xB000_1008`, CQ head to `0xB000_100C`; the SQE including its CID is passed to the SSD
unchanged, the CQE is passed to `M_AXIS` unchanged, tuser credit = 1 per CQE.) The IP sees
the BAR windows at the same AXI addresses as the CPU (`0xA000_0000` / `0xB000_0000`).

### S_AXI_LITE registers (PG328 v1.0, Table 9)

| Offset | Register |
|---|---|
| 0x0000 + n*8 / 0x0004 + n*8 | SSDn PCIe base address lower / upper (the SSD's BAR0 bus address) |
| 0x0100 | SSD0 SQ1 base address [31:12] |
| 0x0104 | SSD0 CQ1 base address [31:12] |
| 0x0100 / 0x0104 + n*16 | SSDn SQ / CQ base address (RO, derived) |
| 0x0108 + n*16 | SSDn SQ flush (bit0) |
| 0x010C + n*16 | SSDn SQ flush done (bit0) |
| 0x8104 | interrupt enable: bit0 CQ available, 1 address error, 2 SW credit error, 3 SW read without CQ, 4 HW SQE without credit, 5 SSD timeout (bits 1, 4, 5 apply here) |
| 0x8108 | interrupt status (same bits; write 1 to bit0 to clear) |
| 0x8110 | command error count |
| 0x8114 | timeout in `clk_core` cycles (reset `0x9C4`) |
| 0x8200 / 0x8204 / 0x8208 + n*16 | SSDn issued / error / completed commands |
| 0x8400 + n*4 | SSDn SQ/CQ status: bit0 SQ full, 1 SQ empty, 2 CQ full, 3 CQ empty, [12:4] SQ free entries, 13 timeout |

All base registers must be programmed before the first I/O and must not change at run time.

## Host Accelerator timeout guard

The evaluation license of the `nvmeha` IP stops the core about 3 hours (183-184 min measured
on the ZCU106) after the bitstream was loaded. From then on its `S_AXI_LITE` slave never
answers: no `RVALID`, no error. Without protection the next CPU read of an `nvmeha` register
stalls the APU interconnect and the whole system hangs (no console, no SSH).

`nvrec_axil_guard` (`Vivado/src/hdl/nvrec_axil_guard.v`, cell `nvmeha_guard`) sits between the
PS interconnect and `S_AXI_LITE` on `pl_clk0`:

* It forwards one transaction at a time. If the slave has not answered after 16384 clocks
  (164 us), the guard completes the transaction itself: reads return `0xFFFF_FFFF`, writes
  are dropped, the response is **OKAY**. It then latches `dead`, answers every later access
  within two clocks without touching the IP, and keeps `BREADY`/`RREADY` high to absorb a
  response that might still come.
* `dead` drives `nvrec_core` `STATE.HA_DEAD` and `IRQ_STATUS.HA_DEAD`. Software detects the
  dead IP there (the `nvrec_core` registers keep working), never from the data.
* A heartbeat read of offset `0x8114` (the IP's timeout register, no read side effects) every
  2^24 clocks (168 ms) detects the expiry even when software does not touch the IP. It starts
  after the first CPU access the IP answered.
* `dead` stays set until the PL is reset (bitstream reload / power cycle), which is also the
  only thing that restarts an expired evaluation core.

Why OKAY and not SLVERR: on Zynq UltraScale+ an SLVERR on a CPU load from the PL reaches the
Cortex-A53 as an SError, which Linux turns into a kernel panic -- the same loss of the system
the guard is there to prevent. This is also why the Vivado AXI Firewall (`axi_firewall`, which
answers a hung slave with SLVERR and needs its own control interface to unblock) is not used.

The Linux driver never reads `nvmeha` registers in a periodic or statistics path; it reads
them only during bring-up, error interrupts and explicit debug requests (sysfs
`ha_counters`, `nvregs`).

## Interrupts (Zynq UltraScale+)

| `pl_ps_irq0` bit | Source | GIC SPI |
|---|---|---|
| 0-5 | XDMA root ports (as in the base design) | 89-94 |
| 6 | `nvrec_core/irq` | 95 |
| 7 | `nvmeha/ha_interrupt` | 96 |

## Changelog

* 1.0 (2026-10-16): first version.
* 1.0 rev b (2026-10-16, before the first bitstream): Host Accelerator with hardware-only
  queues (QID 1, no `S_AXI` window), `MEMBER_SEL` SQ reset 0, per-SSD credit reset
  (`CTRL` bits 6/7), `RUN_DROP_COUNT`, injector documented as multi-outstanding.
* 1.1 (2026-10-17, backwards compatible): Host Accelerator timeout guard with
  `STATE.HA_DEAD` / `IRQ_STATUS.HA_DEAD` (bit 6); `RUN_FIFO_HWM` (0x258); `SSD_ISSUED` and
  `INJ_SUBMITTED` cleared by `SOFT_RST` like the completion counters.
