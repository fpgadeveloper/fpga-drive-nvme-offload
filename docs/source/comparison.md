# Comparison with fpga-drive-recorder

[fpga-drive-recorder](https://recorder.fpgadrive.com) and this design record the same fabric
data stream (the same test-pattern generator and the same checker for playback) to the same
SSDs on the same boards and FMC cards. They differ in **who issues the NVMe commands**:

* **fpga-drive-recorder**: an AXI DMA fills buffers in DDR; Linux owns the SSDs (stock `nvme`
  driver, XFS or ext4, md RAID0) and `fdrec` writes the buffers with `O_DIRECT` io_uring
  requests, 8 in flight. The CPU handles every buffer.
* **This design**: the fabric fills a ring in DDR and builds an NVMe Write command for every
  chunk itself; the AMD NVMe Host Accelerator queues the commands and rings the SSDs'
  doorbells, and the SSDs read the data straight from the ring. The CPU sets the run up and
  waits for its end (see [Architecture](architecture)).

Both designs were measured in October 2026 with the same method (see [Benchmarks](benchmarks)
and the recorder's [Benchmarks](https://recorder.fpgadrive.com/en/latest/benchmarks.html)):
the same two Samsung 980 PRO 1TB and the same two Sabrent Rocket 2230 1TB on the same two boards
and FMC cards, the same sizes (10 GB, 32 GB, 40 GB, long recordings of 200 to 480 GiB),
500 MB/s steps from a floor with an early stop after two consecutive failing steps and 3 runs at
the top and at the first failing step, the same pass criterion (no dropped beat over the whole
recording, verified word by word). This design adds the 250 MB/s step at the knee and confirms
its playback tops with a 40 GiB file. The recorder's figures below are those of its 256-bit
datapath on every target (register map 1.2, driver 1.3), as published on its Benchmarks page;
this design's are those of this repository, 256 bits on `zcu106_hpc0` and 512 bits on
`vck190_fmcp1`.

## At a glance

All figures in MB/s (10⁶ bytes/s), recorder / offload, for the four fixtures measured with both
designs. "32 GB" is the highest clean step of the 32 GB sweep (inside the SLC cache of these
1 TB drives); "10 GB" and "40 GB" the highest clean burst recordings; "past the cache" the
highest clean rate of the long recordings, with their size; "playback": the recorder's highest
clean step for a 10 GB recording, and this design's sustained rate from a 40 GiB recording (its
10 GiB step in brackets where it is higher). The recorder cells are for its default ring of
32 × 8 MB buffers unless stated; this design's for its default 512 MB ring and 32 commands in
flight per SSD. "Single" is one drive of the pair.

| target / config | 32 GB | 10 GB | 40 GB | past the cache | playback |
|---|---|---|---|---|---|
| `vck190_fmcp1`: Sabrent SB-2130-1TB, single | 4500 / 4000 | 4500 (3 of 4) / 4250 or more | 4500 / 4000 | 1750 / 1500 (200 GiB) | 4500 / 4500 (10 GiB: 4750) |
| `vck190_fmcp1`: RAID0 (2x Sabrent SB-2130-1TB) | 4000 (7000 with 32 × 16 MB buffers) / **7750** | 4000 / **8000** or more | 4000 / **7500** | 3500 / 3250 (350 GiB) | 5500 / **7500** (10 GiB: 8750) |
| `vck190_fmcp1`: Samsung 980 PRO 1TB, single | 4500 (5000 in 3 of 7) / 5000 | 5000 / 5000 | 5000 / 5000 | 1750 (240 GiB) / 1750 (200 GiB) | 6000 / 6000 (10 GiB: 6250) |
| `vck190_fmcp1`: RAID0 (2x Samsung 980 PRO 1TB) | 6500 (7000 with 32 × 16 MB buffers) / **9250** | 6000 / **9250** | 6000 / **9250** | 3250 (480 GiB) / 3250 (350 GiB) | 6000 / **8750** |
| `zcu106_hpc0`: Sabrent SB-2130-1TB, single | 2500 (on its 500 MB/s grid) / 2750 | 2500 (3 of 4) / 2750 | 2500 / 2750 | 1750 / 1500 (200 GiB) | 3000 / 3000 (10 GiB: 3250) |
| `zcu106_hpc0`: RAID0 (2x Sabrent SB-2130-1TB) | 3500 (4500 with 64 × 8 MB buffers) / **5000** | 4000 / **5000** | 3500 / **5000** | 3000 / **3250** (350 GiB) | 3500 / **4500** |
| `zcu106_hpc0`: Samsung 980 PRO 1TB, single | 3000 / 3000 | 3000 (3 of 4) / 3000 | 3000 / 3000 | 1750 / 1750 (200 GiB) | 3000 / 3000 (10 GiB: 3250) |
| `zcu106_hpc0`: RAID0 (2x Samsung 980 PRO 1TB) | 4500 (5000 with 64 × 8 MB buffers; 5 of 7 with 32) / **5000** | 5000 / 5000 | 5000 / 5000 | 3250 / **3500** (350 GiB) | 4000 / **4250** (10 GiB: 4750) |

Without any SSD, the datapath of each design from the fabric into DDR and back (`fdrec
--no-write` / `nvrec --no-write`, and playback of a recording held in the ring):

| target | recorder (256 bits): recording / playback | this design: recording / playback |
|---|---|---|
| `vck190_fmcp1` | 7750 / 7500 | **14 500 / 13 750** (512 bits) |
| `zcu106_hpc0` | 5000 / 5000 | 5000 / 5000 (256 bits; `S_AXI_HP2_FPD` in both) |

### CPU

"% of one core" is the transfer process's (user + system) / real time, at the top rate of each
layout (32 GB recordings, 10 GB playbacks; the recorder's figures from its CPU-load section).
`nvrec` and `nvplay` spend a fixed 0.06-0.4 s of CPU time per run on its set-up, so their
percentage is higher for short transfers and lower for long ones (0.1-0.4 % over a 2-minute
recording); `fdrec` and `fdplay` spend CPU time on every buffer, so theirs grows with the rate.

| target / config | recording: recorder | recording: offload | playback: recorder | playback: offload |
|---|---|---|---|---|
| `vck190_fmcp1`: Sabrent SB-2130-1TB, single | `fdrec` 70 % at 4500 | `nvrec` 1.2 % at 4000 | `fdplay` 63 % at 4500 | `nvplay` 2.9 % at 4750 |
| `vck190_fmcp1`: RAID0 (2x Sabrent) | `fdrec` 65 % at 4000; 117-119 % at 7000 (16 MB buffers) | `nvrec` 2.8 % at 7750 | `fdplay` 94 % at 5500 | `nvplay` 5.1 % at 8750 |
| `vck190_fmcp1`: Samsung 980 PRO 1TB, single | `fdrec` 72-75 % at 5000 | `nvrec` 1.3 % at 5000 | `fdplay` 83 % at 6000 | `nvplay` 3.2 % at 6250 |
| `vck190_fmcp1`: RAID0 (2x 980 PRO) | `fdrec` 97-98 % at 6500; ~111 % at ~7.3 GB/s | `nvrec` 2.8 % at 9250 | `fdplay` 91 % at 6000 | `nvplay` 5.2 % at 8750 |
| `zcu106_hpc0`: Sabrent SB-2130-1TB, single | `fdrec` 58 % at 2500 | `nvrec` 1.3 % at 2750 | `fdplay` 63 % at 3000 | `nvplay` 3.4 % at 3000 |
| `zcu106_hpc0`: RAID0 (2x Sabrent) | `fdrec` 88 % at 3500; 113-115 % at 4500 (64 × 8 MB) | `nvrec` 2.9 % at 5000 | `fdplay` 87 % at 3500 | `nvplay` 4.6 % at 4500 |
| `zcu106_hpc0`: Samsung 980 PRO 1TB, single | `fdrec` 67 % at 3000 | `nvrec` 1.3 % at 3000 | `fdplay` 60 % at 3000 | `nvplay` 3.1 % at 3000 |
| `zcu106_hpc0`: RAID0 (2x 980 PRO) | `fdrec` 100 % at 4500; 116-117 % at 5000 (64 × 8 MB) | `nvrec` 2.5 % at 5000 | `fdplay` 94.5 % at 4000 | `nvplay` 4.9 % at 4750 |

At 1000 MB/s `fdrec` takes 15-17 % of a Cortex-A72 core and 23-26 % of a Cortex-A53 core,
`fdplay` 12 % and 16-21 %.

## Why the figures differ

**CPU: 1-5 % against 60-120 % of one core.** This design has no software in the data path:
the CPU prepares the file and the ring, starts the hardware and reads statistics until the end.
The recorder's `fdrec` submits every 8 MB buffer to io_uring, takes the DMA interrupt, does the
cache maintenance and waits for the completion: about 1.5-1.7 % of a Cortex-A72 core and
2.3-2.6 % of a Cortex-A53 core per 100 MB/s, about one core or more at its RAID0 tops (with
io_uring workers on the other cores). `fdplay` reads with one thread, which sets the recorder's
RAID0 playback limit.

**RAID0 recording tops.** On `zcu106_hpc0` both designs stop at the same port,
`S_AXI_HP2_FPD` (5155 MB/s peak), and this design records 5000 MB/s with both pairs and its
default 512 MB ring. The recorder reaches 5000 MB/s with the 980 PROs in 3 of 3 runs only with
64 × 8 MB buffers (5 of 7 with its default 256 MB ring: write-latency spikes and the slow first
writes after the idle time outlast the ring), and 3500 MB/s with the Sabrents (4500 MB/s with
64 × 8 MB; at 5000 MB/s its host writes only ~4.8-4.9 GB/s). This design keeps up to 32
commands in flight per drive and switches APST off, so the first writes after the idle time do
not wait for the drives to wake up; the Sabrent pair still needs the whole 512 MB ring at
5000 MB/s (up to 369 MB in use, a 256 MB ring drops). On `vck190_fmcp1` the recorder's writes
are bound above ~7.1-7.3 GB/s by the PCIe path that both Root Ports share (likely their one NoC
port: fio writes 7.17-7.33 GB/s with the Sabrents and ~7.6 GB/s with the 980 PROs through it)
and by `fdrec`'s CPU, and its default ring loses one gap at 0.27 GB when the Sabrent drives
wake from APST power state 4 (clean at 4000 MB/s; 4500-6000 MB/s with APST off, 7000 MB/s with
16 MB buffers). This design's Versal build has a 512-bit datapath and one NoC port per Root
Port, so the Sabrent pair records up to its drives' own rate (7750 MB/s; 63 commands in flight
per drive do not help it) and the 980 PRO pair up to the DDR controller, 9250 MB/s: every byte crosses the single DDR4-3200 controller twice, ~18.5 GB/s of
mixed traffic.

**RAID0 playback tops.** The recorder's single `fdplay` thread is the limit on both boards
(94.5 % of a Cortex-A53 core at 4000 MB/s with the 980 PROs, 87 % at 3500 MB/s with the
Sabrents; 91-94 % of a Cortex-A72 core at 6000 and 5500 MB/s), although fio reads the pairs at
5.1-6.4 GB/s on `zcu106_hpc0` and 7.8-7.9 GB/s on `vck190_fmcp1`. Here the fabric issues the
reads, 32 per drive: on `zcu106_hpc0` either pair and the ring reader deliver ~4.63-4.69 GB/s
together while the SSDs write DDR and the reader reads it (for any length 4250 MB/s with the
980 PROs, 4500 MB/s with the Sabrents); on `vck190_fmcp1` the 980 PRO pair plays 8750 MB/s for
any length (the DDR controller again, now with the SSDs writing and the ring reader reading),
the Sabrent pair 7500 MB/s over a 40 GiB file and 8750 MB/s over a 10 GiB one (above 7500 MB/s
short underflows appear over long files with this pair, for a reason not isolated).

**One drive and past the cache: drive-bound, mostly equal.** Where the drive or its link is the
limit, both designs measure the same with the 980 PRO: one drive records 3000 MB/s on
`zcu106_hpc0` (both write ~3.04 GB/s at 3500 MB/s) and holds 1750 MB/s past its cache on both
boards (its TLC rate, ~1.77 GB/s); on `vck190_fmcp1` it writes ~4.95 GB/s in its cache in both
designs, and its 5000 MB/s here (3 of 3, against 3 of 7 in the recorder) is this design's larger
ring covering the deficit over 32 GB. It plays back 3000 MB/s (`zcu106_hpc0`) and 6000 MB/s
(`vck190_fmcp1`) for any length in both. The 980 PRO pair holds 3250 MB/s past the cache on
`vck190_fmcp1` in both, and 3500 MB/s here on `zcu106_hpc0`, which the recorder did not run (its
3250 MB/s run was clean, its 4500 MB/s run dropped where the cache ends); at 3500 MB/s this
design's ring peaked at 287 MB, more than the recorder's 256 MB ring holds. A 10 GiB playback
runs one 250 MB/s step higher here than its sustained figure without a faster read: the drives
read at the same rate in both designs, and this design's prefilled 512 MB ring covers the
deficit of a 10 GiB file.

**One Sabrent writes ~5 % slower with `nvrec`.** On both link generations: in its cache one
Sabrent wrote 2.75-2.83 GB/s with this design at the first failing step on `zcu106_hpc0`
(Gen3 x4; median 2776 MB/s) against 2.88-2.95 GB/s with the recorder (median 2944 MB/s), and
4.24-4.31 GB/s on `vck190_fmcp1` (Gen4 x4, the 256-bit build early in the night) against
4.57-4.65 GB/s; past the cache ~1.73 GB/s against ~1.80 GB/s on both boards. So one drive holds
1500 MB/s past the cache here against 1750 MB/s in the recorder. In the cache the 250 MB/s grid
of this design still records 2750 MB/s on `zcu106_hpc0`, above the recorder's 2500 MB/s on its
500 MB/s grid, but on `vck190_fmcp1` it records 4000 MB/s against 4500 MB/s (after both drives
had become 3-5 % slower, see [Supported SSDs](supported_ssds); 4000 MB/s on two days). The
Sabrent pair past the cache: 3250 MB/s on both boards here (~3.39-3.45 GB/s after the cache),
against the recorder's 3500 MB/s on `vck190_fmcp1` and 3000 MB/s on `zcu106_hpc0`, where its
3500 MB/s run lost one ~0.2 s stall with its 256 MB ring. More commands in flight (`--qd 63`) do
not help one Sabrent, in or past its cache. A plausible cause is the drive's response to this
design's command stream (256 KB commands with PRP lists on one hardware queue per drive) rather
than Linux's (8 MB requests split into 256 KB commands over several queues); it was not
isolated, nor separated from wear (the pair had about 9.7 TB written in the two days of
measurements).

**Fabric.** On `zcu106_hpc0` both designs have the same 256-bit datapath and the same port
into DDR, so the same knees (5000 MB/s, with 5153-5155 MB/s delivered above them). On
`vck190_fmcp1` the recorder's 256-bit datapath stops at 7750 / 7500 MB/s because `src_clk` =
`dp_clk` leaves the ingest FIFO no time to drain; this design's 512-bit datapath reaches
14 500 / 13 750 MB/s.

## What differs, and why it matters

| | fpga-drive-recorder | this design |
|---|---|---|
| NVMe commands issued by | Linux `nvme` driver (io_uring → block layer → md → nvme) | the fabric (command builder) and the Host Accelerator IP |
| commands in flight | 8 requests of 8 MB (Linux splits each into MDTS-sized commands) | up to 32 per SSD (1 … 63), one command per chunk |
| command size | MDTS-sized pieces of 8 MB requests | the drive's MDTS (512 KB on the 980 PRO, 256 KB on the Sabrent) |
| fabric datapath | 256 bits on every target (8 GB/s) | 256 bits on Zynq UltraScale+ (8 GB/s), 512 bits on Versal (16 GB/s) |
| Versal PCIe path into DDR | both Root Ports through one NoC port | one NoC port per Root Port |
| CPU work per buffer | io_uring submission, completion, DMA interrupt, cache maintenance | none during the run |
| buffer ring | 32 × 8 MB hugepages (256 MB) | 512 MB from CMA (1024 × 512 KB, 2048 × 256 KB) |
| filesystem | XFS (or ext4), any file layout | exFAT, contiguous preallocated file, unmounted during the run |
| NVMe APST | the kernel's default (enabled) | off (driver default) |
| also a failure | — | any NVMe completion with an error status |
| license | none (all IP free) | NVMe Host Accelerator (AMD, licensed; evaluation bitstreams stop after 183-184 min) |

## Discussion

What the offload buys is the CPU and, where the host path was the limit, the rate. With the
commands built in the fabric, a recording at the top rate costs `nvrec` 1-3 % of one core
against 60-120 % for `fdrec`, and the cost does not grow with the rate. RAID0 recording on
`vck190_fmcp1` reaches the DDR controller with the 980 PRO pair, 9250 MB/s against the
recorder's 6500 MB/s (7000 MB/s with 16 MB buffers), and the drives' own rate with the Sabrent
pair, 7750 MB/s against 4000 MB/s (7000 MB/s with 16 MB buffers); sustained RAID0 playback runs
at 8750 and 7500 MB/s on `vck190_fmcp1` and at 4250-4500 MB/s on `zcu106_hpc0`, where the
recorder's single reader thread stops at 5500-6000 and 3500-4000 MB/s.
On `zcu106_hpc0` both designs record RAID0 up to the same HP port, 5000 MB/s, this design with
its default ring and with either pair.

What it does not change are the limits of the drives and the links. On a PCIe Gen3 x4 slot one
980 PRO writes at most ~3.04 GB/s in either design; the SLC cache sizes and the post-cache
rates belong to the drive. Where these limits decide, the two designs measure the same, or one
250 MB/s step apart: this design's larger ring buys one step on 10 GiB playbacks and on a
980 PRO's 32 GB in-cache recording, and it writes one Sabrent ~5 % slower than the recorder
does, which costs one step past the cache.

The price is on the integration side. The NVMe Host Accelerator is a licensed AMD IP: the
evaluation bitstreams stop after 183-184 minutes, a product needs a purchased license. The SSDs
belong to this design's own driver and the IP's queues, not to the Linux `nvme` driver, and a
recording is one contiguous preallocated file on an exFAT volume that is unmounted during the
run. The recorder uses free IP, the stock Linux NVMe driver, md RAID0 and XFS, and any file
layout.

Choose this design when the CPU must stay free during a recording, or when RAID0 recording or
playback must run above what the recorder's host path sustains (above ~4-7 GB/s on Versal,
above 3500-4000 MB/s on Zynq UltraScale+ with the default rings). Choose fpga-drive-recorder
when its measured rates cover the application, when a standard Linux storage stack matters, or
when an IP license is not an option. With one drive both designs record at about the same
maximum rate.
