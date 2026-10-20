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
| `nvrec_hw.c` | **every** register access (nvrec_core and nvmeha registers) |
| `nvrec_nvme.c` | PCI driver: controller reset/enable, admin queue, Identify, I/O queue creation |
| `nvrec_blk.c` | blk-mq block devices |

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
   SSD's commands in flight are not affected), and the block device is added.

At platform probe (before any SSD), the driver programs `NVMEHA_SQ1_BASE`/`CQ1_BASE` with the
queue window, cross-checks the read-back bases of all other queues against the documented
4 KB stride (a warning names the first mismatch), sets the IP's response-timeout interval and
enables its interrupts.

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
`dead`.

## Control device `/dev/nvrec`

One process at a time may open it (`-EBUSY` otherwise). The run model:

1. **`NVREC_IOC_SET_RING`** — the ring of `bytes / chunk` slots in PS DDR, 2 to `max_slots`
   (1024) slots and at most 1 GB (the apps default to 256 MB: 256 MB / chunk slots within
   256…1024, i.e. 1024 × 256 KB, 512 × 512 KB, 256 × 1 MB). The CMA it takes is the ring plus
   one PRP list per slot (4 KB each up to a 2 MB chunk); see
   [ring size and CMA](apps.md#ring-size-and-cma).
   The hardware addresses slot *s* at `RING_BASE + s × chunk`, so the ring must be **one
   physically contiguous region**: with `addr = 0` the driver allocates it from CMA
   (`dma_alloc_attrs`, no kernel mapping — the CPU never touches sample data). An app may
   instead pass a 2 MB-hugepage mapping (the fpga-drive-recorder way); it is pinned and
   accepted only if the pages are physically contiguous. The driver then builds one PRP list
   per slot (pages 1…P−1 of the slot; lists longer than 512 entries chain) in DMA-coherent
   memory. The chunk is a power of two, 64 KB–4 MB. **One chunk is one NVMe command**, so the
   chunk must not exceed any member SSD's MDTS (maximum data transfer size, e.g. 512 KB on the
   Samsung 980 PRO): `NVREC_IOC_SET_GEOMETRY` refuses a larger chunk with `-EINVAL` and logs
   `chunk of N bytes exceeds the maximum transfer size (MDTS) of nvrecXn1 (M bytes)`.
2. **`NVREC_IOC_SET_GEOMETRY`** — stripe members (SSD, NSID, base LBA), the array chunk index
   of the first chunk (`start_chunk`), the run length in chunks, the per-SSD queue depth of
   the command builder (1–63, default 32), FUA. Array chunk *A* goes to member `A mod N` at
   `base_lba + (A div N) × chunk/LBA` — the Linux md RAID0 layout (see
   [Filesystem](filesystem)). The driver checks that the run stays inside every namespace and
   that all members share one LBA size.
3. **`NVREC_IOC_RECORD_START`** (`NVREC_START_TPG`: reset and enable the test pattern
   generator after the recorder is armed) or **`NVREC_IOC_PLAY_START`** (`NVREC_START_CHECK`:
   reset and enable the checker). Before starting, the page cache of the member block devices
   is written back and invalidated (the hardware writes behind the block layer); it is
   invalidated again when the run ends.
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
  starting a run then fails with `-ENOLINK`, and an SSD that probes after the expiry is not
  brought up.

The system stays up (console, SSH, other devices); only a bitstream reload (power cycle)
brings the Host Accelerator back. Plan evaluation sessions for less than ~2 h 45 min after
power-on. A bitstream without the guard (register map 1.0) is accepted with a warning, but an
expired core then hangs the CPU.

Statistics (`struct nvrec_stats`): run state, `drop_count` = **RUN_DROP_COUNT** (beats
dropped while the record run accepted data: a recording is valid when it is 0;
`ing_drop_count` is the ingest FIFO's sticky counter, which keeps counting while the source
runs on after the run), ingest beats/FIFO high-water, chunks
filled, commands issued/completed, NVMe errors (with the last failing status/CID),
bytes stored, ring fill and high-water, cycles the writer waited for a free slot, completion
latency min/avg/max and a 16-bin log2 histogram (dp_clk cycles), and per SSD: commands in
flight and high-water, credits, issued/completed/error counters (`nvrec_core`), plus the
checker counters for playback. `fifo_hwm` is the ingest FIFO high-water mark **during the
run** (`RUN_FIFO_HWM`); `ing_fifo_hwm` is the raw `ING_FIFO_HWM`, which also counts the FIFO
filling up after the run when the source keeps running. `flags` carries
`NVREC_STATS_HA_DEAD`, `prefill_ns` the playback prefill time.

### Cache coherency

Neither the ring writer (`S_AXI_HP` port) nor the SSDs (root port AXI master) are cache
coherent with the APU. The CMA ring is cleaned and invalidated by the DMA API at allocation
and never touched by the CPU afterwards; a user hugepage ring is mapped with
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
   };
};
```

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
`dp_clk_hz`, `version`, `ring_slots`, `chunk_bytes`, and the writable `rate_bps` (test pattern
generator rate) and `tpg_enable`.

| parameter | default | meaning |
|---|---|---|
| `ha_timeout_ms` | 2000 | IP response-timeout status interval |
| `stop_timeout_ms` | 5000 | time allowed for commands in flight at stop/abort |
| `play_prefill_ms` | 2000 | playback with the checker: the longest wait for the ring to fill before the sink is enabled (0 = no prefill) |
| `admin_timeout_ms` | 5000 | admin command timeout |

## Building the module by hand

```
make -C sw/nvrec-driver KERNEL_SRC=<kernel build dir>
```

The Yocto recipe (`meta-nvrec/recipes-kernel/nvrec-mod`) does the same. The module is
dual-licensed MIT / GPL-2.0.
