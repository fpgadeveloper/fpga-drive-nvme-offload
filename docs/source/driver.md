# Kernel driver

The `nvrec` kernel module (`sw/nvrec-driver/`) connects the hardware to Linux. It is one
module with three faces:

* a **platform driver** for the `compatible = "opsero,nvrec"` device-tree node, which
  covers both `nvrec_core` (the recorder RTL) and the AMD NVMe Host Accelerator
  (`nvmeha`, PG328) — it owns their registers and interrupts;
* a **PCI driver** (`nvrec-nvme`) that claims the NVMe SSDs behind the design's PCIe root
  ports **instead of the stock `nvme` driver**, brings each controller up and creates its
  I/O queues inside the IP;
* the user interfaces: a **block device per SSD**, `/dev/nvrecXn1`, whose I/O goes through
  the IP (so filesystems, `mdadm`, `blkdiscard` and `scp` work), and the **control
  device** `/dev/nvrec` for the hardware recorder and player.

The image built by the Yocto flow loads the module at boot. The ioctl ABI is
[`include/nvrec_uapi.h`](https://github.com/fpgadeveloper/fpga-drive-nvme-offload/blob/main/include/nvrec_uapi.h),
the register map
[`include/nvrec_regs.h`](https://github.com/fpgadeveloper/fpga-drive-nvme-offload/blob/main/include/nvrec_regs.h)
(see [Register map](register_map)).

| file | role |
|---|---|
| `nvrec_main.c` | platform driver, `/dev/nvrec`, ring, geometry, run control, sysfs |
| `nvrec_ring.h` | the ring address function and the PRP lists built from it (pure code, unit-tested on the host: `tests/`) |
| `nvrec_hw.c` | **every** register access (nvrec_core and nvmeha registers) |
| `nvrec_nvme.c` | PCI driver: controller reset/enable, admin queue, Identify, I/O queue creation |
| `nvrec_blk.c` | blk-mq block devices |

This page describes driver version 1.2 (`modinfo nvrec`, ioctl API 4), which goes with
register map 1.3. It also runs register map 1.2 (single ring, 2048 slots) and 1.1 bitstreams
(128-bit datapath, no fabric-only mode). The probe message names everything that matters:

```
nvrec 420010000.nvrec: /dev/nvrec: driver 1.2, nvrec_core v1.3, src_clk 249999756 Hz, dp_clk 249999756 Hz, beat 64 bytes, FIFO 4096/4096 beats (ingest/egress), 4096 ring slots, DRY, ring ports 2, mem1 0x60000000000 1024 MB, default ring split, stripe chunk; nvmeha: 2 SSDs x 1 queues (...)
```

## Beats and words

The fabric datapath is 256 bits wide on the Zynq UltraScale+ targets and 512 bits wide on
`vck190_fmcp1` (the `DATA_WIDTH` parameter of `nvrec_core` and the `fdrec_*` modules; 128 is
the other supported width). At probe the driver reads the **beat size** from the
`BEAT_BYTES` register (register map 1.2): 32 bytes on a 256-bit datapath, 64 on 512 bits,
16 on 128 bits. On register map 1.0 and
1.1, whose datapath is 128 bits, the register reads 0 and the driver uses 16. Any other
value makes the probe fail (`unsupported nvrec_core BEAT_BYTES`). The driver reports the
beat size in `nvrec_info.beat_bytes`, in the `beat_bytes` sysfs attribute and in its probe
message, and uses it for the conversion between bytes/s and the generator and sink rate
registers:

    rate (bytes/s) = RATE_INC / 2^31 x SRC_CLK_HZ x BEAT_BYTES

so the generator's maximum is `src_clk × beat_bytes`: 250 MHz × 32 B = 8000 MB/s on the
256-bit targets, 250 MHz × 64 B = 16 000 MB/s on `vck190_fmcp1` (3200 MB/s on the 128-bit
revision). A larger rate is clamped to it.

Two units appear in the counters:

* **Beats** (fabric beats of `beat_bytes` bytes): `drop_count`, `ing_drop_count`,
  `beats_in`, `beats_out`, the `chk_*` counts (`chk_errors` counts a beat once, whatever
  number of its words is bad), the FIFO depths and high-water marks.
* **Words** (16-byte test-pattern words): `seq_next` (`TPG_SEQ_NEXT`), `chk_last_seq`
  (`CHK_LAST_SEQ`) and `nvrec_start.first_seq`. A 32-byte beat carries two consecutive
  words (a 64-byte beat four), so the sequence number of its word 0 advances by two (four)
  per beat. Recordings are
  therefore byte-identical whatever the datapath width (see [File format](apps.md#file-format)).

`bytes` is in bytes (beats × `beat_bytes`); chunk sizes, LBAs and the ring are unchanged by
the width: a chunk (64 KB or more) and an LBA (512 bytes or more) are always whole beats.

## Split ring: one ring in two memories

Every byte of a recording or a playback crosses the ring's memory twice: the fabric writes it
and an SSD reads it (playback: an SSD writes it, the fabric reads it). With the ring in PS DDR
alone, that DDR controller is the ceiling of the design at the top rates. Register map 1.3
adds a **second ring port** (`RING_PORTS` = 2) to a **second memory** that the CPU does not use
— the soldered PL DDR4 on `zcu106_hpc0` (through a DDR4 controller in the PL), the on-board
LPDDR4 on `vck190_fmcp1` — so the ring can be split over the two memories and each carries
half of the traffic. `uzev` has one ring port (single ring only).

**Layouts** (`nvrec_ring.flags`, apps `--ring`):

| layout | where the ring is |
|---|---|
| `single` | all in memory 0 (PS DDR, the CMA allocation): as driver 1.1 |
| `split` | striped over memory 0 and memory 1 in stripes of 2^S bytes (`stripe_shift` S, 12 … log2(chunk)) |
| `mem1` | all in memory 1 (diagnostics: measures the second memory alone) |

**Address function** (register map 1.3, `nvrec_ring.h`): byte *g* of the ring (*g* = slot ×
chunk + offset) is in stripe *i* = *g* >> S, stripe *i* lives in memory *i* mod 2 at
((*i* >> 1) << S) + (*g* mod 2^S) from that memory's ring base. With S = 12 the memories
alternate every 4 KB (every AXI burst), so both carry half the stream at any time and each SSD
reads and writes both memories within one command. With S = log2(chunk) whole slots alternate
(slot *s* in memory *s* mod 2). Memory 0 holds ⌈stripes / 2⌉ stripes, memory 1 the rest:
exactly half each, because with whole-chunk stripes the driver always uses an **even slot
count** — an odd count from SET_RING is rounded down by one (never below 2; `nvrec_ring.slots`
returns the count used, and the kernel log says so once:
`split ring with whole-chunk stripes: N slots rounded down to N-1`). The reason is the
**SSD ↔ memory pairing**: chunk *c* of a run is in slot *c* mod slots, so with an even count
its memory is *c* mod 2, while its stripe member is (`start_chunk` + *c*) mod 2 — member *m*
always writes (and reads) memory *m* XOR (`start_chunk` mod 2). Both are fixed for a run, so
with whole-chunk stripes **each SSD touches one memory only** (which one depends on the
parity of the file's first chunk). An odd count would put one more slot in memory 0 and swap
the pairing at every wrap of the ring. The hardware puts
ADDR(slot × chunk) in PRP1; the driver writes every other 4 KB page of the slot, at its
ADDR, into the slot's PRP list (the lists themselves stay in memory 0), so the SSDs follow
the same function.

**Default stripe: the whole chunk on both boards** (device tree `opsero,ring-stripe-chunk`;
`opsero,ring-stripe-kb = <KB>` for another board default; the whole chunk without either),
overridden by the module parameter `stripe_kb` or the app's `--stripe`, and capped at the
chunk. With whole chunks each SSD reads and writes one memory only (see the pairing above),
which is what wins once SSDs are in the loop:

* `zcu106_hpc0`: **the whole chunk**. The ring writer and reader stream in order, so they
  alternate between the two ports — HP2 (~5.15 GB/s) and the PL DDR4 (~7.8 GB/s) — and any
  large stripe sits near the harmonic mean of the two, 2 / (1/5.15 + 1/7.8) ≈ 6.2 GB/s (4 KB
  stripes overlap the ports best in the fabric alone: 7000 MB/s record, 6750 playback, against
  6000-6250 for whole chunks). With the SSDs in the loop whole chunks win: each NVMe command
  stays in one memory, and a Sabrent RAID0 pair plays back and records 6000 MB/s with them at
  the default MaxPayload of 256 bytes (5500 MB/s recording with 4 KB stripes) with less of the
  ring in use (at 128 bytes it plays back 5250 MB/s with whole chunks or 4 KB stripes); 64 KB was the worst layout in every
  SSD test. **With 512 KB chunks whole-chunk stripes are essential**: with 4 KB stripes each
  512 KB command of a Samsung 980 PRO switches memory 128 times, and the 980 PRO pair plays
  back only ~3.8-4.0 GB/s (6.3 ms read latency at MaxPayload 128) instead of 5750 MB/s
  (5250 MB/s at 128). Whole chunks cap the fabric at about 6.2-6.4 GB/s (the chunk alternation), above what
  either pair needs.
* `vck190_fmcp1`: **the whole chunk**. Two Samsung 980 PRO in RAID0 (40 GiB playbacks, 32 GB
  recordings; see [Benchmarks](benchmarks.md#stripe-whole-chunk-4-kb-or-64-kb)):

  | | whole chunk (default) | 4 KB stripes |
  |---|---|---|
  | playback, MaxPayload 256 (the image's default) | **11 000 MB/s** (3 of 3 on the release image; 8 of 9 in the measurement session) | 10 500 MB/s |
  | playback, MaxPayload 128 | **10 750 MB/s** | 10 250 MB/s |
  | SSD command latency during the playback, average | 0.20 ms | 1.7-1.85 ms |
  | recording | 10 000 MB/s (the drives' write rate) | 10 000 MB/s |
  | fabric only: recording / ring-resident playback | 14 750 / 15 000 MB/s | 15 750 / 16 000 MB/s |

  Two Sabrent Rocket 2230, whose drives read more slowly than either layout takes, play back
  9250 MB/s with both.

  With 4 KB stripes every SSD command alternates between the DDR4 and the LPDDR4, and the NoC
  orders each Root Port's writes strictly, so every switch costs a round trip. With whole
  chunks each SSD writes one memory; the ring reader's skid FIFOs keep fetching from the other
  memory, so the switch from one memory to the next at a chunk boundary costs the reader
  little. 4 KB stripes win only without SSDs.

**Memory 1** is a `no-map` reserved-memory region the device tree hands to the nvrec node
(`memory-region`, see [Device tree](#device-tree)): 1 GB at the start of the second memory on
both reference designs. The kernel never maps or allocates it; ring B (the memory-1 part of a
split ring, or a `mem1` ring) simply starts at its base — nothing is allocated, nothing to
free. Ring A (the memory-0 part) comes from CMA as before, so a split ring takes only half
its size from CMA: the default split ring of 1 GB is 512 MB of CMA + 512 MB of the region,
the same CMA as the 512 MB single ring of driver 1.1. The "fabric view = SSD view" check of
SET_RING covers both memories.

`STATE.MEM1_READY` says memory 1 is usable (the PL DDR4 controller calibrated on
`zcu106_hpc0`; always 1 on `vck190_fmcp1`). While it is 0 the driver refuses `split` and `mem1`
rings (SET_RING `-EIO`, START `-EIO`), reports `NVREC_STATUS_MEM1_DOWN` and the default
layout falls back to `single`; sysfs `mem1_ready` reads it live.

**Default layout** (SET_RING with `flags = 0`, apps `--ring auto`): module parameter
`ring_split` — `auto` (default): `split` when the design can (two ring ports, a memory-1
region, memory 1 ready), except for runs over a single SSD, which stay `single`; `0`: always
`single`; `1`: `split` whenever the design can, single-SSD runs too. `nvrec_info.ring_default`
tells the apps the result for 2-member/fabric-only runs and for 1-member runs. A single SSD
stays on the single ring because it gains nothing from the split (its own link is the limit)
and loses on it: one Sabrent on `zcu106_hpc0` plays back about 13 % slower on the split ring
(its writes alternate between the memories), records the same; **one 980 PRO on
`zcu106_hpc0` plays back only ~1.44 GB/s on the split ring** (12 ms read latency) against
3000 MB/s on the single ring; one 980 PRO on `vck190_fmcp1` 5750 MB/s on a 4 KB-striped split
ring against 6250 MB/s. Keep `ring_split=auto` (or 0) for single-SSD work: `ring_split=1`
forces the split on one SSD too.

**Which memory limits a run:** register map 1.3 counts, per ring port, the `dp_clk` cycles the
ring writer's head beat waited for that port (`WR_PORT_STALL`, record) and the cycles the
ring reader waited for read data of that port while the egress FIFO had room
(`RD_PORT_WAIT`, playback), since START. They are in `nvrec_stats.wr_port_stall[]` /
`rd_port_wait[]`, the sysfs `wr_port_stall0/1` and `rd_port_wait0/1`, and the apps' summaries
and RESULT lines (in ms). The counters are **not zero in a clean run**: every memory makes
the head beat wait a little, and the wait grows with the bytes moved through that port (on
both boards the memory-1 port's writer stall is about 4.2 ms per GiB written to it at any
rate below its limit; on `zcu106_hpc0` it is a fixed wait of about 4 `dp_clk` cycles per 4 KB
burst into the PL DDR4 path, 2^26 cycles per 64 GiB, so a non-zero memory-1 count alone does
not mean that memory 1 limits). Read them by comparison — between the two ports, and against the run
time (`seconds` of the RESULT line): a port whose stall or wait approaches the duration of the
run is the one that limits it; a non-zero value alone means nothing. The counters are 32 bits
wide and saturate at 2^32 − 1 cycles, **17 179.886 ms** at 250 MHz: a run longer than about
17 s can show that value without meaning anything about the memory (compare shorter runs, or
the rate of growth in the sysfs counters while the run goes).

## Why the stock nvme driver is kept off the SSDs

An NVMe controller has exactly one owner. Whoever sets `CC.EN` creates the admin queue in its
own memory, negotiates the number of I/O queues and creates them, and resets the controller
whenever it decides to (error recovery, suspend, module unload) — which silently deletes every
I/O queue. The NVMe Host Accelerator needs I/O queues whose memory is **its own queue window**
(the SQ/CQ entries live in the IP; the SSD reads SQEs from and writes CQEs to the IP's
`S_AXI_SSD` port through the root port bridge). The stock driver has no way to "create a queue
somewhere else and leave it alone", so `nvrec` owns the controller and gives Linux a block
device *through* the IP instead.

How the stock driver is kept away:

1. **`CONFIG_BLK_DEV_NVME=m`** (`meta-nvrec` `nvrec.cfg`, the target's `bsp.cfg`): a built-in
   `nvme` would bind the SSDs during boot, before `nvrec.ko` is loaded.
2. **`blacklist nvme`** in `/etc/modprobe.d/nvrec-blacklist-nvme.conf` (installed by the
   `nvrec-mod` recipe): udev never autoloads it. `modprobe nvme` by hand still works.
3. **`nvrec` binds by device-tree topology**, not by vendor/device ID: its `pci_driver`
   matches every device of class `PCI_CLASS_STORAGE_EXPRESS`, and its probe accepts only
   devices whose host bridge (root port) is listed in the node's `opsero,ssd-ports`. Any other
   NVMe device gets `-ENODEV` and stays available to the stock driver.

### Using the stock nvme driver (reference tests)

The same image can run reference measurements (`fio`, `nvme-cli`, the dd `speed-tests`) with
the stock driver on the same SSD:

```
lspci -D | grep -i "non-volatile"                      # PCI address of the SSD, e.g. 0001:01:00.0
echo 0001:01:00.0 > /sys/bus/pci/drivers/nvrec-nvme/unbind
modprobe nvme                                          # binds every NVMe device no driver holds
nvme list
```

and back to the design's driver:

```
echo 0001:01:00.0 > /sys/bus/pci/drivers/nvme/unbind
echo 0001:01:00.0 > /sys/bus/pci/drivers/nvrec-nvme/bind
```

`nvrec` resets the controller and recreates its queues on bind, so the order of the steps is
all that matters. Do not leave both modules competing for an unbound device.

## Controller bring-up

For each SSD (`nvrec_nvme.c`, NVMe Base Specification 2.0 §3.5.1):

1. `CAP`: doorbell stride must be 4 bytes (the IP computes the doorbell offsets itself and
   assumes `DSTRD = 0`), minimum page size 4 KB, NVM command set.
2. `CC.EN = 0`, wait `CSTS.RDY = 0`.
3. Admin SQ/CQ (32 entries) in DMA-coherent DDR; `AQA`, `ASQ`, `ACQ`; `CC = EN | NVM | 4 KB
   pages | IOSQES 6 | IOCQES 4`; wait `CSTS.RDY = 1`. The admin queue is **polled**: admin
   commands are rare, and the driver uses no MSI vector of the root port at all.
4. Identify Controller: model, serial, firmware, MDTS, volatile write cache, Dataset
   Management support. Identify Namespace 1: size and the LBA format **in use** (the driver
   does not reformat a drive: 512-byte and 4 KB LBAs are both supported; namespaces with
   metadata are refused).
5. Set Features *Number of Queues* asking for the one I/O queue the IP holds for this SSD.
   A drive whose `CAP.DSTRD` is not 0 is refused (the IP computes the doorbell offsets with
   a 4-byte stride).
   A drive whose BAR0 lies at or above 4 GB (AXI or PCIe bus address) is refused as well: the
   IP's doorbell master (`M_AXI_SSD`) has 32 address bits, so such a drive could never receive
   its doorbells (`BAR0 at ... is at or above 4 GB` in the kernel log). This can happen when
   the root port puts a prefetchable BAR into its 64-bit window (VCK190).
6. The SSD's BAR0 (the address the CPU uses) is written into the IP
   (`NVMEHA_SSD_PCIE_BASE`): the IP adds 0x1000 itself and rings QID 1's SQ-tail / CQ-head
   doorbells at BAR0 + 0x1008 / + 0x100C.
7. Create I/O CQ (QID 1, physically contiguous, **interrupts disabled** — the IP watches its
   own CQ memory) and Create I/O SQ (QID 1, CQID 1), 64 entries, both at the IP's queue window
   `NVREC_QWIN_SQ_BASE/CQ_BASE + ssd × 4 KB`.
8. That SSD's credit counter in `nvrec_core` is reloaded (`CTRL` bit 6/7, per SSD: the other
   SSD's commands in flight are not affected).
9. Autonomous Power State Transitions (APST, see below) are logged and, by default, switched
   off; the composite temperature is logged; the block device is added.

At platform probe (before any SSD), the driver programs `NVMEHA_SQ1_BASE`/`CQ1_BASE` with the
queue window, cross-checks the read-back bases of all other queues against the documented
4 KB stride (a warning names the first mismatch), sets the IP's response-timeout interval and
enables its interrupts.

### Power states (APST) and temperature

An NVMe drive with **Autonomous Power State Transitions** enabled drops into a deep idle
power state after some idle time, and waking from it takes tens of milliseconds (a Sabrent
Rocket 2230 reports 44 ms for its PS4; the fpga-drive-recorder benchmarks saw a 60–64 ms
write stall shortly after the start of a recording on idle drives with APST on, and none
with it off). The first chunks of a recording then wait in the ring: a 512 MB ring lasts
64 ms at 8 GB/s, so a fast recording that starts on an idle drive can drop. The
stock Linux driver enables APST; `nvrec` never did, so each drive kept its own power-on
setting. Driver 1.1 reads the setting at probe (Get Features 0x0C) and logs it per SSD:

```
nvrec-nvme 0000:01:00.0: SSD0: APST enabled by the drive -> disabled (module parameter apst=0)
nvrec-nvme 0000:01:00.0: SSD0: composite temperature 34 C (warning 82 C, critical 85 C; 0 = not reported)
```

With the module parameter **`apst=0`** (the default) it switches APST off (Set Features
APSTE = 0, not saved: the drive's own setting returns at its next power-up); with
**`apst=1`** it leaves the drive's setting alone. A drive without APST support is logged as
such. `/sys/block/nvrecXn1/nvrec/apst` reads the current state (`on`, `off` or
`unsupported`). To change the parameter, add `options nvrec apst=1` to a file in
`/etc/modprobe.d/` and reboot (the module is loaded at boot, before the SSDs are claimed).

The drive's **composite temperature** comes from its SMART / Health Information log (Get
Log Page 02h through the admin queue, which is independent of the recording path), read
when `/sys/block/nvrecXn1/nvrec/temperature` is read, at most once a second. The stock
`nvme smart-log` cannot reach these drives (they have no `/dev/nvmeX`), so this attribute is
how a script watches the drives during long recordings (`nvbench-suite.sh` stops a run above
70 °C). `temperature_warn` and `temperature_crit` are the drive's warning and critical
composite temperature thresholds (Identify Controller WCTEMP / CCTEMP; 0 = not reported).

### PCIe MaxPayload

The driver leaves the PCIe MaxPayload as the kernel set it at enumeration (128 bytes on these
boards). The board's value is set from user space after boot by `nvrec-pcie-mps.service`
(`nvrec-mps`, see [Apps](apps.md#nvrec-mps)): 256 bytes on `vck190_fmcp1` and `zcu106_hpc0`,
128 on `uzev`. A
board policy belongs there — visible (`nvrec-mps status`), reversible without a reboot, set
per image — rather than in the driver, and the kernel's own `pci=pcie_bus_perf` would also
lower MaxReadReq and choose the largest value both ends support rather than the measured one.
The `mps` key of the apps' `RESULT` lines records the value in force for every run.

### Queue strategy

The design's IP is built with **hardware-only queues** (register map 1.0 rev b): each SSD has
one hardware SQ/CQ pair of 64 entries, which is NVMe QID 1 on every drive — so drives that
grant a single I/O queue work too. There is no software queue window (`S_AXI`). The command
builder (recording/playback) and the **CPU command injector** of `nvrec_core` share that queue:
the CPU writes one SQE into registers (`NVREC_INJ_*`), the injector pushes it onto the hardware
SQ arbitrated with the command builder (CID bit 15 forced to 1), and the CQE comes back in a
16-deep FIFO with an interrupt. Every CPU I/O — block device, filesystem — takes this path, at
most 16 commands outstanding in total. `cat /sys/block/nvrec0n1/nvrec/io_path` shows
`injector`.

```{note}
"Only one I/O queue" is often what Linux's stock driver *reports* on boards whose PCIe root
port has a single MSI vector (`1/0/0 default/read/poll queues`): that is the interrupt
limit, not the drive's. `nvrec` asks the drive itself (Set Features) and logs the number
granted at probe.
```

## Block devices `/dev/nvrecXn1`

`X` is the SSD index in the IP (0 = SSD1 on the first root port). blk-mq, one hardware
context:

* **Read/Write** with PRPs (one 4 KB PRP list per request, allocated once per tag; up to
  1 MB or MDTS per request; the queue's `virt_boundary_mask` makes every request PRP-mappable),
  **FUA** and **Flush** when the drive has a volatile write cache, **Discard** as Dataset
  Management/Deallocate (one range per request) when the drive supports it — so `blkdiscard`
  and `fstrim` work.
* Queue depth 8 per SSD: the injector's CQE FIFO (16 entries) is shared by both SSDs and
  must never hold more than 16 outstanding commands.
* Command IDs are blk-mq tags; injector CIDs have bit 15 set (the hardware forces it), so
  they never collide with the command builder's slot CIDs on the hardware queue.
* A timed-out command (30 s) disables the controller (`CC.EN = 0`, IP queues flushed) and
  fails every outstanding request: there is no per-command abort through the IP. Unbind/bind
  the PCI device to bring it back.

`/sys/block/nvrecXn1/nvrec/` holds `ssd_index`, `model`, `serial`, `firmware`, `nsid`,
`io_path` (`injector`), `nr_io_queues`, `mdts_bytes`, `inflight_cmds`, `pci`,
`dead`, and (driver 1.1) `temperature` (composite, °C, read from the drive),
`temperature_warn`, `temperature_crit` (°C, 0 = not reported) and `apst` (`on`, `off`,
`unsupported`).

## Control device `/dev/nvrec`

One process at a time may open it (`-EBUSY` otherwise). The run model:

1. **`NVREC_IOC_SET_RING`** — the ring of `bytes / chunk` slots, 2 to `max_slots` slots (the
   hardware slot table: 4096 on the register map 1.3 designs, 2048 on 1.2, 1024 on 1.1), in
   the layout of `flags` (`NVREC_RING_SINGLE`, `NVREC_RING_SPLIT` with `stripe_shift`,
   `NVREC_RING_MEM1`; 0 = the driver's default, see [Split ring](#split-ring-one-ring-in-two-memories)).
   A single or `mem1` ring is at most 1 GB, a split ring at most 2 GB with at most 1 GB in
   each memory and its memory-1 part within the memory-1 region. The apps default to 512 MB
   single (512 MB / chunk slots within 256…4096: 2048 × 256 KB, 1024 × 512 KB, 512 × 1 MB)
   and 1 GB split (4096 × 256 KB, 2048 × 512 KB, 1024 × 1 MB). The CMA it takes is the
   memory-0 part plus one PRP list per slot (4 KB each up to a 2 MB chunk, 8 KB for 4 MB); see
   [ring size and CMA](apps.md#ring-size-and-cma). On return `flags` holds the layout used,
   `stripe_shift` the stripe (0 unless split), `slots` the slot count used (`bytes / chunk`,
   rounded down to even for a whole-chunk split ring), `dma_addr` / `dma_addr1` the bus
   addresses of the two parts. Since `bytes` is a multiple of 2 MB, chunks below 2 MB always
   give an even count; the rounding only shows with 2 MB and 4 MB chunks.
   The hardware addresses slot *s* at `RING_BASE + s × chunk`, so the ring must be **one
   physically contiguous region**: with `addr = 0` the driver allocates it from CMA
   (`dma_alloc_attrs`, no kernel mapping — the CPU never touches sample data). An app may
   instead pass a 2 MB-hugepage mapping (the fpga-drive-recorder way); it is pinned and
   accepted only if the pages are physically contiguous (a single ring only). The driver then
   builds one PRP list per slot (pages 1…P−1 of the slot, each at the address the layout gives
   it; lists longer than 512 entries chain) in DMA-coherent memory. The chunk is a power of
   two, 64 KB–4 MB. **One chunk is one NVMe command**, so the
   chunk must not exceed any member SSD's MDTS (maximum data transfer size, e.g. 512 KB on the
   Samsung 980 PRO): `NVREC_IOC_SET_GEOMETRY` refuses a larger chunk with `-EINVAL` and logs
   `chunk of N bytes exceeds the maximum transfer size (MDTS) of nvrecXn1 (M bytes)`.
2. **`NVREC_IOC_SET_GEOMETRY`** — stripe members (SSD, NSID, base LBA), the array chunk index
   of the first chunk (`start_chunk`), the run length in chunks, the per-SSD queue depth of
   the command builder (1–63, default 32), FUA. Array chunk *A* goes to member `A mod N` at
   `base_lba + (A div N) × chunk/LBA` — the Linux md RAID0 layout (see
   [Filesystem](filesystem)). The driver checks that the run stays inside every namespace and
   that all members share one LBA size. A geometry with **no member** (`nr_members = 0`)
   is accepted for fabric-only runs only (below).
3. **`NVREC_IOC_RECORD_START`** (`NVREC_START_TPG`: reset and enable the test pattern
   generator after the recorder is armed) or **`NVREC_IOC_PLAY_START`** (`NVREC_START_CHECK`:
   reset and enable the checker); `NVREC_START_DRY` makes either a fabric-only run. Before
   starting, the page cache of the member block devices is written back and invalidated (the
   hardware writes behind the block layer); it is invalidated again when the run ends.
4. **`NVREC_IOC_WAIT`** / `poll()` until the run has ended (the `nvrec_core` DONE / ABORTED
   interrupt wakes the waiter), **`NVREC_IOC_GET_STATS`** any time, **`NVREC_IOC_STOP`**
   (record: the open chunk is padded to a whole LBA, every command completes) or
   **`NVREC_IOC_ABORT`**.
5. `close()` aborts a run that is still going and frees the ring.

If the commands in flight do not complete within `stop_timeout_ms` (5 s) after a stop or
abort, the member SSDs are disabled (`CC.EN = 0`) before the ring can be freed — an SSD that
keeps a command could otherwise DMA into memory that was given back.

Playback with the checker: the sink is enabled only after the ring has been filled (or
`play_prefill_ms` has passed). The run clock starts when the sink is enabled, so
`elapsed_ns` is the streaming time; the prefill is reported separately in `prefill_ns`.

### Fabric-only runs (DRY)

With **`NVREC_START_DRY`** (register map 1.2, capability `NVREC_CAP_DRY`) the driver sets
`CONFIG.DRY` at START and the hardware runs the fabric side alone: no NVMe command is built,
no SSD and no Host Accelerator register is touched (the CPU command injector keeps working,
so the block devices stay usable).

* **Record:** the source fills the ring slot by slot through the ingest FIFO and the ring
  writer, and every slot is released as soon as it is filled. `bytes` is what was written
  into the ring, `drop_count` the beats the fabric path could not take: the
  source → ingest FIFO → ring writer → DDR path, measured without any SSD
  (`nvrec --no-write`).
* **Playback:** every chunk counts as completed at START, and the ring reader streams chunks
  0 … `length_chunks − 1` from slot `c mod slots` into the egress FIFO and the sink. With the
  checker the sink is enabled once the egress FIFO is half full (there is no SSD prefill).
  Right after a DRY record of `length_chunks = slots`, a DRY playback of `length_chunks =
  slots` with the same ring plays that recording back: every slot once, in order, sequence
  numbers continuous — the **ring-resident test** of the ring → egress FIFO → sink path
  (`nvplay --ring-only`). A longer playback wraps over the same slots and the checker sees
  the sequence restart.

A DRY run takes a geometry with `nr_members = 0` and a ring set up without any live SSD (such
a ring serves DRY runs only), and a dead Host Accelerator does not stop it. A DRY start on a
register map 1.1 bitstream fails with `-EOPNOTSUPP`.

### When the Host Accelerator stops (evaluation license)

An evaluation-licensed `nvmeha` core stops 183–184 minutes (about 3 hours) after the
bitstream was loaded. Its register slave then never answers; the hardware's timeout guard
(see [Register map](register_map)) completes such accesses with all-ones and raises
`nvrec_core` `STATE.HA_DEAD` / `IRQ_STATUS.HA_DEAD` (also found by the guard's own heartbeat
when nothing touches the IP). The driver:

* never reads `nvmeha` registers in a periodic or statistics path (the statistics come from
  `nvrec_core`; the `ha_*` fields of `struct nvrec_ssd_stats` stay 0, sysfs `ha_counters`
  reads the IP on request);
* on `HA_DEAD` (interrupt, or found while checking a run / an all-ones register value) logs
  once *"Host Accelerator stopped responding (evaluation license expired?): NVMe I/O stopped;
  reload the bitstream (power-cycle the board) to continue"*, stops touching the IP, disables
  every SSD write-only (`CC.EN = 0`, no BAR read) so their DMA stops and pending block I/O
  fails at once with an I/O error, and ends a running recording/playback as
  `NVREC_RUN_FAILED` with `NVREC_STATS_HA_DEAD` in `stats.flags`;
* reports the state in `nvrec_info.status` (`NVREC_STATUS_HA_DEAD`) and sysfs `ha_dead`;
  starting a run then fails with `-ENOLINK` (fabric-only runs still work), and an SSD that
  probes after the expiry is not brought up.

The system stays up (console, SSH, other devices); only a bitstream reload (power cycle)
brings the Host Accelerator back. Plan evaluation sessions for less than ~2 h 45 min after
power-on. A bitstream without the guard (register map 1.0) is accepted with a warning, but an
expired core then hangs the CPU.

Statistics (`struct nvrec_stats`; units in [Beats and words](#beats-and-words)): run
state, `drop_count` = **RUN_DROP_COUNT** (beats dropped while the record run accepted data: a recording is valid when it is 0;
`ing_drop_count` is the ingest FIFO's sticky counter, which keeps counting while the source
runs on after the run), ingest beats/FIFO high-water, chunks
filled, commands issued/completed, NVMe errors (with the last failing status/CID),
bytes stored, ring fill and high-water, cycles the writer waited for a free slot, completion
latency min/avg/max and a 16-bin log2 histogram (dp_clk cycles), and per SSD: commands in
flight and high-water, credits, issued/completed/error counters (`nvrec_core`), plus the
checker counters for playback. `fifo_hwm` is the ingest FIFO high-water mark **during the
run** (`RUN_FIFO_HWM`); `ing_fifo_hwm` is the raw `ING_FIFO_HWM`, which also counts the FIFO
filling up after the run when the source keeps running. `flags` carries
`NVREC_STATS_HA_DEAD`, `prefill_ns` the playback prefill time, `wr_port_stall[2]` /
`rd_port_wait[2]` (API 4) the ring ports' wait cycles (register map 1.3; 0 before).

### Cache coherency

Neither the ring writer (`S_AXI_HP` port) nor the SSDs (root port AXI master) are cache
coherent with the APU. The CMA ring is cleaned and invalidated by the DMA API at allocation
and never touched by the CPU afterwards; memory 1 is never mapped by the CPU at all (no-map,
outside the memory Linux uses); a user hugepage ring is mapped with
`dma_map_sgtable(DMA_BIDIRECTIONAL)` (clean + invalidate), and the app must not touch it while
it is registered. The PRP lists live in `dma_alloc_coherent` memory (non-cacheable here) and
are ordered before the ring registers by a `wmb()`. Block-device I/O uses the standard
streaming DMA API (`dma_map_sg`) against the SSD's PCI device.

## Device tree

```
&amba_pl {
   nvrec: nvrec@420010000 {
      compatible = "opsero,nvrec";
      reg = <0x4 0x20010000 0x0 0x1000>,     /* nvrec_core */
            <0x4 0x20020000 0x0 0x10000>;    /* nvmeha S_AXI_LITE */
      reg-names = "core", "ha-lite";
      interrupt-parent = <&gic>;
      interrupts = <0 95 4>, <0 96 4>;
      interrupt-names = "core", "ha";
      opsero,ssd-ports = <&xdma_0>, <&xdma_1>;   /* root ports in SSD order */
      opsero,ha-sw-queues = <0>;                 /* hardware-only queues */
      memory-region = <&nvrec_ring1>;            /* split ring: memory 1 (1.3) */
      opsero,ring-stripe-chunk;                  /* default stripe: the whole chunk */
   };
};

/ {
   reserved-memory {
      #address-cells = <2>;
      #size-cells = <2>;
      ranges;
      nvrec_ring1: nvrec-ring1@2000000000 {      /* zcu106_hpc0: PL DDR4 */
         reg = <0x20 0x00000000 0x0 0x40000000>; /* 1 GB */
         no-map;
      };
   };
};
```

`memory-region` (register map 1.3, optional) names the memory-1 region for ring B: a
reserved-memory node with `reg` and `no-map` at an address the second ring port and the root
ports reach and Linux does not use as RAM — `0x20_0000_0000` (PL DDR4) on `zcu106_hpc0`,
`0x600_0000_0000` (LPDDR4, the NoC's `DDR_CH2` region) on `vck190_fmcp1`, 1 GB each, 2 MB
aligned (the driver keeps every ring address 64 bits wide). Should a kernel refuse
such a region, `opsero,ring1 = <base size>` (two 64-bit values) gives the same without a
reserved-memory node. Without either, or on a design with one ring port, the driver uses a
single ring. The board's default split-ring stripe is `opsero,ring-stripe-chunk` (a boolean:
the whole chunk, on both reference designs) or `opsero,ring-stripe-kb = <KB>` (a power of
two ≥ 4); `opsero,ring-stripe-chunk` wins when both are given, and without either the default
is the whole chunk.

Optional properties override the IP build parameters compiled in from `nvrec_regs.h`:
`opsero,ha-num-ssd`, `opsero,ha-num-sq`, `opsero,ha-sw-queues` and `opsero,ha-hw-queues` (one
value per SSD, or one for all), `opsero,ha-sq-depth`, `opsero,ha-sq-base` and
`opsero,ha-cq-base` (64-bit, the queue window as the SSDs see it), `opsero,ha-bar-offset`
(added to an SSD's BAR CPU address to get the address the IP's `M_AXI_SSD` uses; 0 when, as
in this design, both see the root port BAR windows at the same AXI address).

## sysfs and module parameters

`/sys/class/misc/nvrec/`: `state`, `hw_state`, `drop_count`, `beats_in`, `beats_out`,
`seq_next`, `chunks_filled`, `cmds_issued`, `cmds_done`, `cmd_errors`, `unexpected_cqes`,
`bytes`, `err_last_status`, `ring_fill`, `ring_hwm`, `ring_full_cycles`, `fifo_hwm`,
`fifo_depth`, `overflow`, `ha_dead`, `lat_min_cycles`, `lat_max_cycles`, `lat_avg_cycles`, `lat_hist`
(16 bins), `lat_bin0_log2` (bin 0 < 2^this `dp_clk` cycles, bin i = [2^(b0+i-1), 2^(b0+i)); 10),
`ssd0_inflight_hwm`, `ssd1_inflight_hwm` (per SSD: most commands in flight, of the running
or the last run, cleared for every SSD slot when a run starts; one file per SSD slot of the IP), `ha_counters` (per SSD: issued, completed, errors of the IP), `src_clk_hz`,
`dp_clk_hz`, `beat_bytes` (bytes per fabric beat), `egr_fifo_depth` (egress FIFO, beats),
`version` (register map), `ring_slots`, `chunk_bytes`, `max_slots` (hardware slot table),
the split ring (driver 1.2): `ring_ports` (1 or 2), `ring1_base` / `ring1_bytes` (the
memory-1 region, 0 = none), `mem1_ready` (live `STATE.MEM1_READY`), `ring_split` (the layout
of the ring set up now: `single`, `split`, `mem1`, or `none`), `ring_stripe_kb` (its stripe
in KB, the effective value after the cap at the chunk; 0 unless split),
`ring_stripe_default` (the default stripe: `chunk` or the KB), `wr_port_stall0/1` and
`rd_port_wait0/1` (`dp_clk` cycles, the running or
last run), and the writable `rate_bps` (test
pattern generator rate, bytes/s) and `tpg_enable`. `fifo_depth` is the ingest FIFO depth in
beats (256 KB: 8192 × 32 B on the 256-bit targets, 4096 × 64 B on `vck190_fmcp1`;
`egr_fifo_depth` is 4096 beats on both, 128 KB and 256 KB). The driver version is
`/sys/module/nvrec/version`.

| parameter | default | meaning |
|---|---|---|
| `ha_timeout_ms` | 2000 | IP response-timeout status interval |
| `stop_timeout_ms` | 5000 | time allowed for commands in flight at stop/abort |
| `play_prefill_ms` | 2000 | playback with the checker: the longest wait for the ring to fill before the sink is enabled (0 = no prefill) |
| `admin_timeout_ms` | 5000 | admin command timeout |
| `apst` | 0 | NVMe Autonomous Power State Transitions: 0 = switch them off on every SSD at probe, 1 = leave the drive's setting (read-only at run time: set it in `/etc/modprobe.d/`) |
| `ring_split` | `auto` | the ring layout of a SET_RING without one (apps `--ring auto`): `auto` = split over both memories when the design can, single for single-SSD runs; `0` = single ring; `1` = split, single-SSD runs too. Writable at run time (`/sys/module/nvrec/parameters/ring_split`) |
| `stripe_kb` | `auto` | default split-ring stripe: `auto` (or `0`) = the board's (`opsero,ring-stripe-chunk` / `opsero,ring-stripe-kb`, else the whole chunk), `chunk` = the whole chunk, or KB (power of two, 4…4096, capped at the chunk). Writable at run time; `nvrec_info.stripe_shift` reports it (`NVREC_STRIPE_SHIFT_CHUNK` = the whole chunk) |

## Building the module by hand

```
make -C sw/nvrec-driver KERNEL_SRC=<kernel build dir>
```

The Yocto recipe (`meta-nvrec/recipes-kernel/nvrec-mod`) does the same. The module is
dual-licensed MIT / GPL-2.0.

`make -C sw/nvrec-driver/tests` builds and runs the host unit test of `nvrec_ring.h` on any
Linux PC: for 64 KB … 4 MB chunks, 1 GB rings, odd slot counts, 4 KB / 64 KB / chunk stripes
and all three layouts, every page the ring writer stores must land inside the parts the
driver allocates, and an SSD following PRP1 and the driver's (chained) PRP lists must reach
exactly the pages of its slot, in order.
