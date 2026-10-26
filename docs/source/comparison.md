# Comparison with fpga-drive-recorder

[fpga-drive-recorder](https://recorder.fpgadrive.com) and this design record the same fabric
data stream (the same test-pattern generator and the same checker for playback) to the same
SSDs on the same boards and FMC cards. They differ in **who issues the NVMe commands**:

* **fpga-drive-recorder**: an AXI DMA fills buffers in DDR; Linux owns the SSDs (stock `nvme`
  driver, XFS or ext4, md RAID0) and `fdrec` writes the buffers with `O_DIRECT` io_uring
  requests, 8 in flight. The CPU handles every buffer.
* **This design**: the fabric fills a ring in memory and builds an NVMe Write command for every
  chunk itself; the AMD NVMe Host Accelerator queues the commands and rings the SSDs'
  doorbells, and the SSDs read the data straight from the ring. The CPU sets the run up and
  waits for its end (see [Architecture](architecture)). On `zcu106_hpc0` and `vck190_fmcp1` the
  ring of a RAID0 recording is split over PS DDR and a second memory that the CPU does not use.

Both designs were measured in October 2026 with the same drives, boards, FMC cards, sizes
(10 GB, 32 GB, 40 GB, and long recordings past the SLC cache) and pass criterion (no dropped beat
over the whole recording, verified word by word), 3 runs at the top and at the first failing
step (see [Benchmarks](benchmarks) and the recorder's
[Benchmarks](https://recorder.fpgadrive.com/en/latest/benchmarks.html)). The recorder sweeps
in 500 MB/s steps; this design sweeps in 250 MB/s steps from higher floors and confirms its
playback tops with 40 GiB files. The recorder's figures below are those of its 256-bit datapath
(register map 1.2, driver 1.3), as published on its Benchmarks page; this design's are those of
this repository, 256 bits on `zcu106_hpc0` and 512 bits on `vck190_fmcp1`, for the four
fixtures: two Samsung 980 PRO 1TB and two Sabrent Rocket 2230 1TB on each board.

## At a glance

All figures in MB/s (10⁶ bytes/s), recorder / offload. "32 GB" is the highest clean step of
the 32 GB sweep (inside the SLC cache of these 1 TB drives); "10 GB" and "40 GB" the highest
clean burst recordings; "past the cache" the highest clean rate of the long recordings, with
their size; "playback": the recorder's highest clean step for a 10 GB recording, and this
design's sustained rate from a 40 GiB recording (its 10 GiB step in brackets where it is
higher). The recorder cells are for its default ring of 32 × 8 MB buffers unless stated; this
design's for its defaults (a 1 GB split ring for RAID0, a 512 MB single ring for one drive,
32 commands in flight per SSD, MaxPayload 256 bytes; the `zcu106_hpc0` cells measured at
128 bytes say so). "Single" is one drive of the pair; "-": not measured with this revision.

| target / config | 32 GB | 10 GB | 40 GB | past the cache | playback |
|---|---|---|---|---|---|
| `vck190_fmcp1`: Samsung 980 PRO 1TB, single | 4500 (5000 in 3 of 7) / 5000 | 5000 / - | 5000 / - | 1750 (240 GiB) / - | 6000 / 6250 |
| `vck190_fmcp1`: RAID0 (2x Samsung 980 PRO 1TB) | 6500 (7000 with 32 × 16 MB buffers) / **10 000** | 6000 / **10 250** | 6000 / **10 000** | 3250 (480 GiB) / 3250 (350 GiB) | 6000 / **11 000** |
| `vck190_fmcp1`: Sabrent SB-2130-1TB, single | 4500 / 4000 | 4500 (3 of 4) / - | 4500 / - | 1750 / - | 4500 / 4500 |
| `vck190_fmcp1`: RAID0 (2x Sabrent SB-2130-1TB) | 4000 (7000 with 32 × 16 MB buffers) / **8250** | 4000 / **8500** or more | 4000 / **8000** | 3500 / 3250 (350 GiB) | 5500 / **9250** |
| `zcu106_hpc0`: Sabrent SB-2130-1TB, single | 2500 (on its 500 MB/s grid) / 2750 (at MaxPayload 128) | 2500 (3 of 4) / - | 2500 / - | 1750 / - | 3000 / 3000 (at 128; 10 GiB: 3250) |
| `zcu106_hpc0`: RAID0 (2x Sabrent SB-2130-1TB) | 3500 (4500 with 64 × 8 MB buffers) / **6000** (5250 at MaxPayload 128) | 4000 / **5500** (at 128) | 3500 / **6000** (5250 at 128) | 3000 / **3250** (350 GiB, at 128) | 3500 / **6000** (5250 at 128) |
| `zcu106_hpc0`: Samsung 980 PRO 1TB, single | 3000 / **3250** (one run; 3000 at MaxPayload 128) | 3000 (3 of 4) / - | 3000 / - | 1750 / - | 3000 / **3500** (one run; 3000 at 128) |
| `zcu106_hpc0`: RAID0 (2x Samsung 980 PRO 1TB) | 4500 (5000 with 64 × 8 MB buffers; 5 of 7 with 32) / **6000** | 5000 / **6000** | 5000 / **6000** (at 128) | 3250 / **3500** (350 GiB, at 128) | 4000 / **5750** (5250 at 128; 10 GiB: 5500 at 128) |

Without any SSD, the datapath of each design from the fabric into memory and back (`fdrec
--no-write` / `nvrec --no-write`, and playback of a recording held in the ring):

| target | recorder (256 bits): recording / playback | this design: recording / playback |
|---|---|---|
| `vck190_fmcp1` | 7750 / 7500 | **14 750 / 15 000** (512 bits, split ring, whole-chunk stripes; 15 750 / 16 000 with 4 KB stripes) |
| `zcu106_hpc0` | 5000 / 5000 (`S_AXI_HP2_FPD`) | **6000 / 6250** (256 bits, split ring over `S_AXI_HP2_FPD` and the PL DDR4, whole-chunk stripes; 7000 / 6750 with 4 KB stripes) |

### CPU

"% of one core" is the transfer process's (user + system) / real time, at the top rate of each
layout (32 GB recordings, 10 GB playbacks; the recorder's figures from its CPU-load section).
`nvrec` and `nvplay` spend a fixed 0.06-0.4 s of CPU time per run on its set-up, so their
percentage is higher for short transfers and lower for long ones (0.15-0.34 % over a 2-minute
recording); `fdrec` and `fdplay` spend CPU time on every buffer, so theirs grows with the rate.

| target / config | recording: recorder | recording: offload | playback: recorder | playback: offload |
|---|---|---|---|---|
| `vck190_fmcp1`: Samsung 980 PRO 1TB, single | `fdrec` 72-75 % at 5000 | `nvrec` 1.3 % at 5000 | `fdplay` 83 % at 6000 | `nvplay` 3.7 % at 6250 |
| `vck190_fmcp1`: RAID0 (2x 980 PRO) | `fdrec` 97-98 % at 6500; ~111 % at ~7.3 GB/s | `nvrec` 2.3 % at 10 000 | `fdplay` 91 % at 6000 | `nvplay` 6.3 % at 11 250 |
| `vck190_fmcp1`: Sabrent SB-2130-1TB, single | `fdrec` 70 % at 4500 | `nvrec` 1.3 % at 4000 | `fdplay` 63 % at 4500 | - |
| `vck190_fmcp1`: RAID0 (2x Sabrent) | `fdrec` 65 % at 4000; 117-119 % at 7000 (16 MB buffers) | `nvrec` 2.9 % at 8250 | `fdplay` 94 % at 5500 | - |
| `zcu106_hpc0`: Sabrent SB-2130-1TB, single | `fdrec` 58 % at 2500 | `nvrec` 1.4 % at 2750 | `fdplay` 63 % at 3000 | `nvplay` 3.6 % at 3250 |
| `zcu106_hpc0`: RAID0 (2x Sabrent) | `fdrec` 88 % at 3500; 113-115 % at 4500 (64 × 8 MB) | `nvrec` 3.2 % at 5250 (MaxPayload 128) | `fdplay` 87 % at 3500 | `nvplay` 5.5 % at 5250 (MaxPayload 128) |
| `zcu106_hpc0`: Samsung 980 PRO 1TB, single | `fdrec` 67 % at 3000 | `nvrec` 1.3 % at 3000 | `fdplay` 60 % at 3000 | `nvplay` 3.4 % at 3000 |
| `zcu106_hpc0`: RAID0 (2x 980 PRO) | `fdrec` 100 % at 4500; 116-117 % at 5000 (64 × 8 MB) | `nvrec` 3.0 % at 6000 (MaxPayload 128) | `fdplay` 94.5 % at 4000 | `nvplay` 5.5 % at 5250 (MaxPayload 128) |

At 1000 MB/s `fdrec` takes 15-17 % of a Cortex-A72 core and 23-26 % of a Cortex-A53 core,
`fdplay` 12 % and 16-21 %. ("-": `nvplay`'s CPU was not sampled with the Sabrent pair on
`vck190_fmcp1`; with the 980 PRO pair on the same board it takes 6.3 % at 11 250 MB/s.)

## Why the figures differ

**CPU: 1-6 % against 60-120 % of one core.** This design has no software in the data path:
the CPU prepares the file and the ring, starts the hardware and reads statistics until the end.
The recorder's `fdrec` submits every 8 MB buffer to io_uring, takes the DMA interrupt, does the
cache maintenance and waits for the completion: about 1.5-1.7 % of a Cortex-A72 core and
2.3-2.6 % of a Cortex-A53 core per 100 MB/s, about one core or more at its RAID0 tops (with
io_uring workers on the other cores). `fdplay` reads with one thread, which sets the recorder's
RAID0 playback limit.

**RAID0 recording tops.** On `zcu106_hpc0` the recorder writes its buffers through one HP port
into PS DDR, as this design's single ring does (`S_AXI_HP2_FPD`, 5155 MB/s peak); it reaches
3500 MB/s with the Sabrents (4500 MB/s with 64 × 8 MB buffers; at 5000 MB/s its host writes only
~4.8-4.9 GB/s) and 4500 MB/s with the 980 PROs (5000 MB/s in 3 of 3 runs only with 64 × 8 MB
buffers: write-latency spikes and the slow first writes after the idle time outlast its default
ring). This design's split ring sends half of the stream to the PL DDR4 instead, with up to 32
commands in flight per drive and APST off, so the first writes after the idle time do not wait
for the drives to wake up: both pairs record 6000 MB/s at the default MaxPayload of 256 bytes,
where the split ring's writer is the limit (at 128 bytes the Sabrent pair records its drives'
own rate, 5250 MB/s). On `vck190_fmcp1` the recorder's writes are bound above ~7.1-7.3 GB/s by the PCIe
path that both Root Ports share (likely their one NoC port: fio writes 7.17-7.33 GB/s with the
Sabrents and ~7.6 GB/s with the 980 PROs through it) and by `fdrec`'s CPU, and its default ring
loses one gap at 0.27 GB when the Sabrent drives wake from APST power state 4 (clean at
4000 MB/s; 4500-6000 MB/s with APST off, 7000 MB/s with 16 MB buffers). This design's Versal
build has a 512-bit datapath, one NoC port per Root Port and the split ring over DDR4 and
LPDDR4, so both pairs record up to their drives' in-cache write rate: 10 000 MB/s with the
980 PROs (2 × ~4.95 GB/s), 8250 MB/s with the Sabrents (with the help of the 1 GB ring).

**RAID0 playback tops.** The recorder's single `fdplay` thread is the limit on both boards
(94.5 % of a Cortex-A53 core at 4000 MB/s with the 980 PROs, 87 % at 3500 MB/s with the
Sabrents; 91-94 % of a Cortex-A72 core at 6000 and 5500 MB/s), although fio reads the pairs
faster. Here the fabric issues the reads, 32 per drive. On `zcu106_hpc0` the pairs play back
5750 MB/s (980 PRO) and 6000 MB/s (Sabrent) sustained at the default MaxPayload of 256 bytes,
and 5250 MB/s, their drives' read rate on the split ring, at 128 bytes. On `vck190_fmcp1` the Sabrent pair
plays back 9250 MB/s, its drives' read rate (2 × ~4.63 GB/s), and the 980 PRO pair 11 000 MB/s,
where the ring reader and its memories, not the drives, set the limit (see
[Ceilings at a glance](benchmarks.md#ceilings-at-a-glance)).

**One drive: drive-bound, mostly equal.** Where the drive or its link is the limit, both designs
measure the same or one step apart. One 980 PRO writes ~4.95 GB/s in its cache on
`vck190_fmcp1` and, at the kernel's MaxPayload of 128 bytes, ~3.04 GB/s on the Gen3 x4 slots
of `zcu106_hpc0` in both designs; its 5000 MB/s on `vck190_fmcp1` (3 of 3, against 3 of 7 in
the recorder) is this design's larger ring covering the deficit over 32 GB. It plays back
6000-6250 MB/s and 3000 MB/s in both. With this design's default of 256 bytes on
`zcu106_hpc0` one 980 PRO records 3250 MB/s and plays back 3500 MB/s (one run each). **One
Sabrent writes slower with `nvrec`**: 2.76-2.78 GB/s at the first failing step on `zcu106_hpc0`
against 2.88-2.95 GB/s with the recorder (on its 250 MB/s grid this design still records
2750 MB/s, above the recorder's 2500 MB/s on its 500 MB/s grid), and 4.21-4.23 GB/s on
`vck190_fmcp1` against 4.57-4.65 GB/s (4000 MB/s here against 4500 MB/s); both designs play it
back at 3000 and 4500 MB/s. A plausible cause is the drive's response to this design's command
stream (256 KB commands with PRP lists on one hardware queue per drive) rather than Linux's
(8 MB requests split into 256 KB commands over several queues); it was not isolated, nor
separated from wear.

**Past the cache.** The 980 PRO pair holds 3250 MB/s on `vck190_fmcp1` in both designs, and
3500 MB/s here on `zcu106_hpc0`, which the recorder did not run (its 3250 MB/s run was clean, its
4500 MB/s run dropped where the cache ends); at 3500 MB/s this design's ring peaked at 567 MB,
more than the recorder's 256 MB ring holds. The Sabrent pair holds 3250 MB/s here on both
boards, against the recorder's 3500 MB/s on `vck190_fmcp1` and 3000 MB/s on `zcu106_hpc0`, where
its 3500 MB/s run lost one ~0.2 s stall with its 256 MB ring. Past the cache the drives' flash
is the limit in both designs.

**Fabric.** On `zcu106_hpc0` the recorder's datapath and this design's single ring stop at the
same HP port (5000 MB/s); the split ring adds the PL DDR4 port and reaches 6000-6250 MB/s with
whole-chunk stripes (7000 MB/s recording with 4 KB stripes). On `vck190_fmcp1` the recorder's
256-bit datapath stops at 7750 / 7500 MB/s because `src_clk` = `dp_clk` leaves the ingest FIFO
no time to drain; this design's 512-bit datapath reaches 14 750 / 15 000 MB/s with whole-chunk
stripes and the 16 000 MB/s source and sink maximum with 4 KB stripes.

## What differs, and why it matters

| | fpga-drive-recorder | this design |
|---|---|---|
| NVMe commands issued by | Linux `nvme` driver (io_uring → block layer → md → nvme) | the fabric (command builder) and the Host Accelerator IP |
| commands in flight | 8 requests of 8 MB (Linux splits each into MDTS-sized commands) | up to 32 per SSD (1 … 63), one command per chunk |
| command size | MDTS-sized pieces of 8 MB requests | the drive's MDTS (512 KB on the 980 PRO, 256 KB on the Sabrent) |
| fabric datapath | 256 bits on every target (8 GB/s) | 256 bits on Zynq UltraScale+ (8 GB/s), 512 bits on Versal (16 GB/s) |
| Versal PCIe path into memory | both Root Ports through one NoC port | one NoC port per Root Port |
| CPU work per buffer | io_uring submission, completion, DMA interrupt, cache maintenance | none during the run |
| buffer ring | 32 × 8 MB hugepages (256 MB) in PS DDR | RAID0: 1 GB split over PS DDR (from CMA) and a second memory the CPU does not use (PL DDR4 on the ZCU106, LPDDR4 on the VCK190), whole-chunk stripes; one drive: 512 MB in PS DDR |
| filesystem | XFS (or ext4), any file layout | exFAT, contiguous preallocated file, unmounted during the run |
| NVMe APST | the kernel's default (enabled) | off (driver default) |
| PCIe MaxPayload | the kernel's (128 bytes) | 256 bytes at boot on `vck190_fmcp1` and `zcu106_hpc0` (`nvrec-mps`), 128 bytes on `uzev` |
| also a failure | — | any NVMe completion with an error status |
| license | none (all IP free) | NVMe Host Accelerator (AMD, licensed; evaluation bitstreams stop after 183-184 min) |

## Discussion

What the offload buys is the CPU and, where the host path was the limit, the rate. With the
commands built in the fabric, a recording at the top rate costs `nvrec` 1-3 % of one core
against 60-120 % for `fdrec`, and the cost does not grow with the rate. RAID0 recording on
`vck190_fmcp1` reaches the drives' own write rate with both pairs, 10 000 MB/s (980 PRO) and
8250 MB/s (Sabrent) against the recorder's 6500 and 4000 MB/s (7000 MB/s with 16 MB buffers);
on `zcu106_hpc0` 6000 MB/s with both pairs against 4500 and 3500 MB/s (5000 and 4500 MB/s with
64 × 8 MB buffers). Sustained RAID0 playback runs at 11 000 and 9250 MB/s on `vck190_fmcp1` and
at 5750-6000 MB/s on `zcu106_hpc0` (5250 MB/s at MaxPayload 128), where the recorder's single
reader thread stops at 5500-6000 and 3500-4000 MB/s.

What it does not change are the limits of the drives and the links. On a PCIe Gen3 x4 slot at
the same MaxPayload one drive writes and reads no faster in either design (this design's
256-byte default on `zcu106_hpc0` lifts it, as `setpci` would for the recorder); the SLC cache
sizes and the post-cache rates belong to the drive. Where these limits decide, the two designs measure the same, or one
250 MB/s step apart: this design's larger ring buys one step on a 980 PRO's 32 GB in-cache
recording, and it writes one Sabrent 5-8 % slower than the recorder does, which costs one step
on `vck190_fmcp1`.

The price is on the integration side. The NVMe Host Accelerator is a licensed AMD IP: the
evaluation bitstreams stop after 183-184 minutes, a product needs a purchased license. The SSDs
belong to this design's own driver and the IP's queues, not to the Linux `nvme` driver, and a
recording is one contiguous preallocated file on an exFAT volume that is unmounted during the
run. The split ring needs a second memory next to the FPGA (a PL DDR4 on the ZCU106, which
raises the board's VCCAUX load). The recorder uses free IP, the stock Linux NVMe driver,
md RAID0 and XFS, and any file layout.

Choose this design when the CPU must stay free during a recording, or when RAID0 recording or
playback must run above what the recorder's host path sustains (above ~6-7 GB/s on Versal,
above 3500-4500 MB/s on Zynq UltraScale+ with the default rings). Choose fpga-drive-recorder
when its measured rates cover the application, when a standard Linux storage stack matters, or
when an IP license is not an option. With one drive both designs record at about the same
maximum rate.
