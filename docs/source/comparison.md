# Comparison with fpga-drive-recorder

[fpga-drive-recorder](https://recorder.fpgadrive.com) and this design record the same fabric
data stream (the same test-pattern generator, 128-bit beats, the same checker for playback)
to the same SSDs on the same boards and FMC cards. They differ in **who issues the NVMe
commands**:

* **fpga-drive-recorder**: an AXI DMA fills buffers in DDR; Linux owns the SSDs (stock `nvme`
  driver, XFS or ext4, md RAID0) and `fdrec` writes the buffers with `O_DIRECT` io_uring
  requests, 8 in flight. The CPU handles every buffer.
* **This design**: the fabric fills a ring in DDR and builds an NVMe Write command for every
  chunk itself; the AMD NVMe Host Accelerator queues the commands and rings the SSDs'
  doorbells, and the SSDs read the data straight from the ring. The CPU sets the run up and
  waits for its end (see [Architecture](architecture)).

Both designs are measured with the same method (see [Benchmarks](benchmarks) and the
recorder's [Benchmarks](https://recorder.fpgadrive.com/en/latest/benchmarks.html)): the same
SSDs on the same boards and FMC cards, the same sizes (4000 MiB, 10 GB, 32 GB, 40 GB), the same
250 MB/s rate steps over the same ranges, the same pass criterion (no dropped beat over the
whole recording, verified beat by beat), the same CPU accounting.

## At a glance

All figures in MB/s (10⁶ bytes/s). The recorder figures come from its benchmarks page and its
benchmark records for the same two Samsung 980 PRO 1TB and the same two Sabrent Rocket 2230
1TB (Sabrent SB-2130-1TB) drives: on `zcu106_hpc0` measured 2026-10-18/19 with the recorder's
current block design (`S_AXI_HP0/HP1` at 250 MHz, see below), on `vck190_fmcp1` measured
2026-10-17 (Sabrent) and 2026-10-18 (980 PRO). The sweeps of both designs cover the same
ranges: the 4000 MiB sweep 250 to 3000 MB/s; the 32 GB sweep, the 10 GB bursts and the playback
sweep in 250 MB/s steps up to 3000 MB/s and then at the 3200 MB/s source maximum. The recorder
was not measured with these drives on `uzev`; its `uzev` and other figures for the Samsung
970 EVO 250GB and 950 PRO 256GB are on its own page (this design was not measured with those
drives).

"Highest clean write" is the highest 250 MB/s step clean over 4000 MiB in three runs;
"sustained" is the highest clean step of the 32 GB sweep (inside the SLC cache of these 1 TB
drives); "burst" the highest clean step of the 10 GB sweep; "post-cache sustained" the highest
clean rate of the long recordings made past the drive's SLC cache, with their size in the
unit the run used (GiB or 10⁹-byte GB; where no higher rate was recorded, the figure is a lower
bound: see the text);
"playback" the highest clean step of the playback of a 10 GB recording made at 1000 MB/s. The
recorder cells are for its default 32 × 8 MB buffers, with its 16-buffer result in brackets
where that differs, and "n of 3" where its top step was clean in fewer than three runs. This
design's single-drive cells are SSD1 (SSD2 is on the [Benchmarks](benchmarks) page).

<!-- nvbench:comparison:begin -->
| target / config | highest clean write, 4000 MiB (MB/s): recorder / offload | sustained write, 32 GB (MB/s): recorder / offload | highest clean burst, 10 GB (MB/s): recorder / offload | post-cache sustained write, long recording (MB/s): recorder / offload | highest clean playback, 10 GB (MB/s): recorder / offload |
|---|---|---|---|---|---|
| `vck190_fmcp1`: Sabrent SB-2130-1TB | 3000 / 3000 | 1000 / 3200 | 3200 / 3200 | 1000 (143 GiB) / 1250 (143 GiB) | 3200 / 3200 |
| `vck190_fmcp1`: RAID0 (2x Sabrent SB-2130-1TB) | 3000 (16 buffers: 2000) / 3000 | 2750 / 3200 | 3200 / 3200 | 2750 (240 GiB) / 3000 (240 GiB) | 3200 (2 of 3; 16 buffers: 3000) / 3200 |
| `vck190_fmcp1`: 980 PRO 1TB | 3000 / 3000 | 3200 / 3200 | 3200 / 3200 | 1750 (240 GiB) / 1750 (200 GB) | 3000 (3200: clean in 3 of 4 runs) / 3200 |
| `vck190_fmcp1`: RAID0 (2x 980 PRO 1TB) | 3000 / 3000 | 3200 / 3200 | 3200 / 3200 | 2000 (480 GiB) / 3000 (350 GB) | 3200 in the sweep, 1 of 3 (16 buffers: 3200) / 3200 |
| `zcu106_hpc0`: Sabrent SB-2130-1TB | 2000 (16 buffers: 2750) / 2750 | 2750 / 2750 | 2750 / 2750 | 1750 (200 GiB) / 1500 (200 GiB) | 2250 / 3200 |
| `zcu106_hpc0`: RAID0 (2x Sabrent SB-2130-1TB) | 3000 (16 buffers: 1750) / 3000 | 3200 / 3200 | 3200 / 3200 | 2250 (350 GiB) / 3000 (350 GiB) | 2250 (2 of 3; 16 buffers: 2500) / 3200 |
| `zcu106_hpc0`: 980 PRO 1TB | 3000 / 3000 | 3000 / 3000 | 3000 / 3000 | 1750 (200 GiB) / 1750 (200 GB) | 2250 / 3200 |
| `zcu106_hpc0`: RAID0 (2x 980 PRO 1TB) | 3000 / 3000 | 3000 / 3200 | 2750 / 3200 | 2500 (350 GiB) / 3000 (350 GB) | 2250 (2 of 3; 16 buffers: 3200, 2 of 3) / 3200 |
| `uzev`: RAID0 (2x Sabrent SB-2130-1TB) | *not measured* / 3000 | *not measured* / 3200 | *not measured* / 3200 | *not measured* / 3000 (240 GiB) | *not measured* / 3200 |
| `uzev`: Sabrent SB-2130-1TB | *not measured* / 3000 | *not measured* / 2500 | *not measured* / 2750 | *not measured* / 1250 (143 GiB) | *not measured* / 3200 |
<!-- nvbench:comparison:end -->

The recorder as first published clocked the PS `S_AXI_HP0/HP1` ports, which carry the SSDs'
DMA to DDR on the Zynq UltraScale+ boards, from `pl_clk0` (~100 MHz at 128 bits, 1.6 GB/s per
port), which held each drive to ~1.59 GB/s (its single 980 PRO 1TB stopped at 1500 MB/s on
`zcu106_hpc0`). This design clocks those ports at 250 MHz (`dp_clk`, 4 GB/s per port), and the
recorder has since adopted the same one-line clock change; the `zcu106_hpc0` recorder figures
above are those of the changed design. On `vck190_fmcp1` the root ports reach DDR through the
NoC, and the recorder's figures there were never affected.

**`zcu106_hpc0`, Samsung 980 PRO 1TB (Gen3 x4).** Inside the SLC cache the two designs are
level wherever one drive's link is the limit: one 980 PRO records 3000 MB/s over 4000 MiB,
10 GB, 32 GB and 40 GB in both, and both drop beats at 3200 MB/s while writing ~3.04 GB/s
(3037 MB/s through the recorder, 3038 MB/s here). Past the cache one drive holds 1750 MB/s in
both designs over 200 GB / 200 GiB, the drive's TLC rate (~1.77 GB/s). The RAID0 differs: this
design records 32 GB and 10 GB at 3200 MB/s with 0 drops (ring high-water 21 slots), where the
recorder's 3200 MB/s 32 GB step lost 430 beats and its 3000 MB/s 10 GB burst 1167 beats, and
350 GB past the cache at 3000 MB/s with 0 drops, where the recorder's long recordings are clean
at 2500 MB/s (2750-3200 MB/s lost 846-14 934 beats each). In both cases the recorder's losses
are FIFO overflows at an 8 MiB buffer boundary when the CPU restarts the DMA late. Playback of
the 10 GB recording is clean at 3200 MB/s on one drive and on the RAID0 here; the recorder plays
back at 2250 MB/s (one drive: 2500 and 2750 MB/s under-run in almost every run, for a reason
its page leaves open; RAID0 2250 MB/s with 32 buffers in 2 of 3 runs, 3200 MB/s with 16 buffers
in 2 of 3).

**`zcu106_hpc0`, Sabrent Rocket 2230 1TB (Gen3 x4).** One Sabrent is clean to 2750 MB/s on the
32 GB sweep, over 10 GB and over 40 GB in both designs; at 3000 MB/s it writes ~2.95 GB/s
through the recorder and ~2.8 GB/s here (both fail). Over 4000 MiB the recorder is clean to
2000 MB/s with 32 buffers (2250 MB/s lost 1154 beats once at a buffer boundary) and 2750 MB/s
with 16, this design 2750 MB/s. The RAID0 is clean at 3200 MB/s over 32 GB, 10 GB and 40 GB in
both. Past the cache the recorder holds 1750 MB/s on one drive over 200 GiB, the drive's TLC
rate (~1.8 GB/s); this design recorded the same 200 GiB clean at 1500 MB/s and dropped beats
at 1750 MB/s (1736 MB/s achieved, first gap at 86.8 GB) and 2000 MB/s (first gap at 71.4 GB).
Both first gaps lie at the end of the drive's ~72 GB SLC cache, and the drive's post-cache rate
(~1.74-1.80 GB/s) sits right at the 1750 MB/s step: the recorder's run stayed clean at
1750 MB/s, this design's did not. The RAID0 records 3000 MB/s over 350 GiB here with 0 drops
(ring high-water 674 of 1024 slots), the recorder 2250 MB/s over 350 GiB
(2500-3200 MB/s lost 1226-10 150 beats each, FIFO overflows at buffer boundaries). Playback is
clean at 3200 MB/s on every layout here; the recorder plays back at 2250 MB/s (RAID0: 2 of 3
runs with 32 buffers, 2500 MB/s with 16).

**`uzev`, Sabrent Rocket 2230 1TB (Gen3 x4).** The recorder was not measured with these drives
on the UltraZed-EV. This design gives the `zcu106_hpc0` results there, whose block design the
target shares: one drive tops out at ~2.8 GB/s (2750 MB/s clean over 10 GB and 40 GB, 2500 and
2750 MB/s on the 32 GB sweeps of SSD1 and SSD2), the RAID0 records 3200 MB/s over 32 GB, 10 GB
and 40 GB and 3000 MB/s over 240 GiB past the cache, playback is clean at 3200 MB/s on every
layout, and `nvrec` takes 1.0-1.3 % of a Cortex-A53 core at 1000 MB/s.

**`vck190_fmcp1` (Gen4 x4).** Neither design has a host-path limit below the drives here. Both
record 3000 MB/s over 4000 MiB (the sweep's top step) and burst 10 GB at 3200 MB/s on every
layout of both drive types. On the 32 GB sweep both are clean to 3200 MB/s with the 980 PROs;
with the Sabrents this design is clean to 3200 MB/s on every layout, the recorder to 1000 MB/s
on one drive (750 and 1250 MB/s each lost beats once on a ~0.65 s write stall) and 2750 MB/s
on the RAID0. Past the cache one 980 PRO holds 1750 MB/s in both designs, the drive's TLC rate
(~1.77 GB/s); the 980 PRO RAID0 records 3000 MB/s over 350 GB with 0 drops here, the recorder
2000 MB/s over 480 GiB (2250-3200 MB/s lost 3.9-16.6 k beats each in isolated FIFO overflows).
With the Sabrents this design records 1250 MB/s on one drive and 3000 MB/s on the RAID0 over
143 / 240 GiB, the highest rates it ran there (lower bounds), the recorder 1000 and 2750 MB/s. Playback is clean
at 3200 MB/s on every layout here; the recorder reaches 3200 MB/s with one Sabrent, 3000 MB/s
with one 980 PRO, and 3200 MB/s on the RAID0 pairs with read stalls in about one run in three.
At 1000 MB/s `fdrec` takes 15.5-16.6 % of a Cortex-A72 core, `nvrec` 0.46-0.79 %.

Across the four fixtures measured with both designs there is one configuration where the
recorder recorded clean at a rate at which this design failed: one Sabrent past the cache on
`zcu106_hpc0`, 1750 MB/s over 200 GiB (clean in the recorder; 1736 MB/s achieved and beats
dropped here, 1500 MB/s clean). That step is at the drive's own post-cache rate. Everywhere
else this design's clean rate is the same as the recorder's or higher.

### CPU

"% of one core" is the transfer process's (user + system) / real time from `time -p`; "busy,
summed over the cores" adds everything else the CPUs did during the transfer (interrupts,
kernel threads), from `/proc/stat`. "MB/s per % core" is the rate divided by the process
figure: how much data one percent of a core moves. The recorder's 1000 MB/s figures are the
"transfer process" column of its CPU-load tables (10 GB, two runs; a range where the two runs
differ); its highest-clean figures come from its 4000 MiB at-a-glance table, as this design's.
`nvrec`'s figure over 4000 MiB is mostly the setup of the volume, the file and the ring: during
the long recordings it took 0.14-0.34 % of a core. At 3200 MB/s (RAID0 of two Sabrents, 32 GB)
`fdrec` takes ~78 % of a Cortex-A53 core.

<!-- nvbench:comparison-cpu:begin -->
| target / config | record at 1000 MB/s, process % of one core: recorder / offload | playback at 1000 MB/s, process % of one core: recorder / offload | offload, busy summed over the cores, % of one core: record / play | recorder, highest clean write: MB/s / % core / MB/s per % core | offload, highest clean write: MB/s / % core / MB/s per % core |
|---|---|---|---|---|---|
| `vck190_fmcp1`: Sabrent SB-2130-1TB | 16.1-16.3 / 0.55 | 12.4 / 0.33 | 1.9 / 0.4 | 2984 / 37 % / 81 | 3000 / 3.02 % / 993 |
| `vck190_fmcp1`: RAID0 (2x Sabrent SB-2130-1TB) | 16.6 / 0.79 | 11.9 / 0.33 | 1.5 / 0.4 | 2984 / 51 % / 59 | 3000 / 5.66 % / 530 |
| `vck190_fmcp1`: 980 PRO 1TB | 15.5 / 0.46 | 11.8 / 0.37 | 0.6 / 0.5 | 2983 / 46 % / 64 | 3000 / 3.27 % / 917 |
| `vck190_fmcp1`: RAID0 (2x 980 PRO 1TB) | 16.2 / 0.53 | 12.4 / 0.33 | 1.2 / 0.4 | 2985 / 48 % / 62 | 3000 / 3.82 % / 785 |
| `zcu106_hpc0`: Sabrent SB-2130-1TB | 24.5 / 0.97 | 19 / 0.59 | 1.2 / 0.7 | 1990 / 49 % / 38 | 2749 / 5.99 % / 459 |
| `zcu106_hpc0`: RAID0 (2x Sabrent SB-2130-1TB) | 25.6-25.7 / 1.23 | 18.6-18.8 / 0.60 | 2.3 / 0.8 | 2980 / 75 % / 37 | 3000 / 8.07 % / 372 |
| `zcu106_hpc0`: 980 PRO 1TB | 23.5-23.6 / 0.83 | 16.4-16.6 / 0.59 | 1.3 / 0.9 | 2980 / 68 % / 44 | 3000 / 5.81 % / 516 |
| `zcu106_hpc0`: RAID0 (2x 980 PRO 1TB) | 24.9-25 / 1.01 | 19.9-22 / 0.55 | 2.0 / 0.7 | 2982 / 74 % / 40 | 3000 / 6.92 % / 434 |
| `uzev`: RAID0 (2x Sabrent SB-2130-1TB) | *not measured* / 1.33 | *not measured* / 0.64 | 1.9 / 15.1 | *not measured* | 3000 / 8.59 % / 349 |
| `uzev`: Sabrent SB-2130-1TB | *not measured* / 1.01 | *not measured* / 0.64 | 1.3 / 0.8 | *not measured* | 2821 / 5.12 % / 551 |
<!-- nvbench:comparison-cpu:end -->

## What differs, and why it matters

| | fpga-drive-recorder | this design |
|---|---|---|
| NVMe commands issued by | Linux `nvme` driver (io_uring → block layer → md → nvme) | the fabric (command builder) and the Host Accelerator IP |
| commands in flight | 8 requests of 8 MB (Linux splits each into MDTS-sized commands) | up to 32 per SSD (1 … 63), one command per chunk |
| command size | MDTS-limited pieces of 8 MB requests | 1 MB or the drive's MDTS, whichever is smaller |
| CPU work per buffer | io_uring submission, completion, DMA ioctl, cache maintenance | none during the run |
| buffer ring | 32 × 8 MB hugepages (256 MB) | 256 MB from CMA (512 chunks at 512 KB, 1024 at 256 KB, 256 at 1 MB) |
| filesystem | XFS (or ext4), preallocated file | exFAT, contiguous preallocated file, unmounted during the run |
| trim between steps | `fstrim` of the free space | `blkdiscard` of the whole drives + new volume |
| drops counted | ingest FIFO overflow | the same, during the run only (`RUN_DROP_COUNT`) |
| also a failure | — | any NVMe completion with an error status |
| license | none (all IP free) | NVMe Host Accelerator (AMD, licensed; evaluation bitstreams stop after 183-184 min) |

What to expect from these differences:

* **SSD-bound figures should match.** Where the drive itself is the limit (the post-cache write
  rate that sets the sustained figures, a drive's maximum write rate), both designs record at
  the same rate: neither the CPU nor the command path is the bottleneck there.
* **Short stalls are absorbed differently.** A recording fails when the drive stalls for
  longer than the ring lasts at the recording rate. Both rings hold 256 MB (this design's
  default since the ring was sized by bytes rather than by 256 slots; earlier measurements
  used 256 slots, 128 MB at 512 KB chunks); this design keeps more commands in flight per drive.
* **CPU.** The recorder's CPU cost grows with the rate (about 2.3-2.6 % of a Cortex-A53 core
  per 100 MB/s on `zcu106_hpc0`, 1.2-1.7 % of a Cortex-A72 core on `vck190_fmcp1`); here the
  CPU does not take part in the data transfer.
* **Buffer boundaries.** The recorder's DMA stops at the end of every 8 MB buffer until the CPU
  restarts it; when that restart is late, the 64 KB ingest FIFO overflows. This design's ring
  writer runs continuously, so that failure mode does not exist.
* **Reads (playback).** The recorder reads through the Linux block layer and its CPU; this
  design's reads are NVMe commands issued by the fabric into the ring, 32 per drive in flight.

## Discussion

What the offload buys is the CPU and the time between data and SSD. With the commands built in
the fabric, recording at 1000 MB/s costs `nvrec` 0.5-1.3 % of one core against 15-26 % for
`fdrec`, and the cost does not grow with the rate (`fdrec`: 37-75 % at 3000 MB/s, ~78 % at
3200 MB/s on a Cortex-A53). Because no buffer waits for the CPU, the failure that limits the
recorder's long RAID0 recordings, a FIFO overflow when a DMA restart at a buffer boundary is
late, does not occur: every long RAID0 recording of this design, 240 GiB to 350 GiB at up to
3000 MB/s on all three boards, finished with 0 drops, where the recorder's clean post-cache
RAID0 rates are 2000-2750 MB/s. Playback reached the 3200 MB/s source maximum on every layout
of every fixture, single Gen3 drives included, where the recorder plays back at 2250 MB/s on
`zcu106_hpc0`.

What it does not change are the limits of the drives and the links. On a PCIe Gen3 x4 slot one
drive writes at most ~3.04 GB/s (980 PRO 1TB) or ~2.8-2.95 GB/s (Sabrent Rocket 2230 1TB) in
either design, so both stop at 3000 or 2750 MB/s on one drive; the SLC cache sizes (~72-75 GB
and ~115-120 GB per drive) and the post-cache TLC rates (~1.74-1.80 and ~1.77 GB/s) belong to
the drive. Where these limits decide (the in-cache bursts and sweeps of one drive on a Gen3 x4
slot, one drive past its cache) the two designs measure the same, or one 250 MB/s step apart:
one 980 PRO holds 1750 MB/s past its cache in both designs; one Sabrent on `zcu106_hpc0` held
1750 MB/s over 200 GiB in the recorder and 1500 MB/s here (its 1750 MB/s run here achieved
1736 MB/s).

The price is on the integration side. The NVMe Host Accelerator is a licensed AMD IP: the
evaluation bitstreams stop after 183-184 minutes, a product needs a purchased license. The SSDs
belong to this design's own driver and the IP's queues, not to the Linux `nvme` driver, and a
recording is one contiguous preallocated file on an exFAT volume that is unmounted during the
run. The recorder uses free IP, the stock Linux NVMe driver, md RAID0 and XFS, and any file
layout.

Choose this design when the CPU must stay free during a recording, when long recordings must
run clean above the recorder's post-cache RAID0 rates, or when playback must run at the source
rate. Choose fpga-drive-recorder when its measured clean rates cover the application, when a
standard Linux storage stack matters, or when an IP license is not an option. With one drive on
a Gen3 x4 slot both designs record at the same maximum rate.
