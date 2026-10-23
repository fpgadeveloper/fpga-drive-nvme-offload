# Benchmarks

This page explains how the NVMe-offload recorder is measured and lists the results per target
and SSD pair. The method is the one of the sibling design
[fpga-drive-recorder](https://recorder.fpgadrive.com/en/latest/benchmarks.html) (Linux and
io_uring issue the NVMe commands there; here the fabric does), with the same SSDs, sizes and
rate steps, so that the two designs can be compared line by line: see
[Comparison with fpga-drive-recorder](comparison). Every figure was measured on hardware; the
target, the SSDs, their firmware, the image and the date are given in [Setups](#setups).
[Ceilings at a glance](#ceilings-at-a-glance) lists every limit that was found, per device
family, with its measured figure, what sets it and how to get past it.

```{note}
The result tables on this page are generated from the results files that `nvbench-suite.sh`
writes on the board (one JSON line per run, see [Running the benchmarks](#running-the-benchmarks)).
```

## Method

### Recording

Each measurement is one `nvrec` recording of test-pattern data at a fixed generator rate,
followed by `nvverify` of the whole file. A rate **passes** when `nvrec` exits 0 (zero dropped
beats and zero NVMe errors) and `nvverify` reports a clean file. Because the generator cannot
be stalled, a pass means the whole chain (ring writer, DDR, command builder, Host Accelerator,
PCIe, SSD) kept up with the rate for the entire recording. Rates are measured in steps, so a
"highest clean step" means that the limit lies between that step and the next one.

The fabric datapath is **256 bits** wide on the Zynq UltraScale+ targets (32-byte beats; the
generator and the checker run at up to 8000 MB/s = 250 MHz × 32 bytes) and **512 bits** wide on
the Versal target (64-byte beats, up to 16 000 MB/s); see [Architecture](architecture).

* **Fabric only (no SSD).** `nvrec --no-write` runs the generator, the ingest FIFO and the ring
  writer into PS DDR exactly as a recording does, but builds no NVMe command and releases every
  ring slot as soon as it is filled (the hardware's fabric-only mode, `CONFIG.DRY`). For the
  playback direction `nvplay --ring-only` fills the ring once and then streams it to the checker
  several times, so the stream reads DDR only. Together they measure the datapath ceiling of a
  target: the fastest rate at which data reaches DDR and comes back, before any SSD is involved.
  64 GiB per recording step; per playback step 20 passes of the 512 MB ring on `zcu106_hpc0`
  (10 GiB) and 3 passes on `vck190_fmcp1` (1.5 GiB; 20 passes once at the top). The sweeps
  start at 4500 MB/s on `zcu106_hpc0` and at 14 000 MB/s on `vck190_fmcp1`, in 250 MB/s steps
  (on `vck190_fmcp1` the playback floor failed and the sweep stepped down to 13 750 MB/s).
* **Sanity check.** Each layout (one SSD, RAID0) first records 10 GiB at 1000 MB/s, verifies
  the file and plays it back at 1000 MB/s (the design's hardware test). Every one passed.
* **32 GB sweep.** `nvrec` 32 GiB per step, in 500 MB/s steps (250 MB/s with the Sabrent pair on
  `vck190_fmcp1`) from **the sweep floor** given in the table below. Rates below the floor are
  not swept. Before every step the drives are
  deallocated whole (`blkdiscard`), a new md array (RAID0) and a new exFAT volume are created and
  the drives are left idle for 60 s. **The sweep stops after two consecutive failing steps.**
  The highest clean step and the first failing step are then each run twice more, so both are
  decided by 3 runs. **Where they are 500 MB/s apart, the 250 MB/s step between them is run as
  well**, 3 times (once for RAID0 at 5250 MB/s on `zcu106_hpc0`, where the fabric alone already
  fails; not for one 980 PRO on `zcu106_hpc0`, whose 3500 MB/s runs wrote only 3038 MB/s). 32 GB
  stays inside the SLC cache of the 1 TB drives below, so the sweep gives an *in-cache* rate.
* **Burst and 40 GB recordings**: one 10 GiB and one 40 GiB recording at the highest clean step
  of the sweep and at its first failing step, each on a freshly deallocated volume after 60 s of
  idle time.
* **Long recordings past the SLC cache**: 200 GiB on one drive and 350 GiB on RAID0, 1.5 to 3
  times the cache, each on a freshly deallocated volume after **300 s** of idle time, at the
  recorder's past-cache rates and in 250 MB/s steps above or below them. They give the
  *sustained* recording rate.
* **Defaults.** The ring is the apps' default of **512 MB** (1024 × 512 KB with the Samsung
  980 PRO, 2048 × 256 KB with the Sabrent Rocket, whose MDTS is 256 KB), **32 commands in
  flight per SSD** (`--qd 32`), NVMe APST off (the driver's default) and PCIe MaxPayload 128 /
  MaxReadReq 512 bytes on every Root Port and SSD (the kernel's default). Extra runs, marked as
  such in the tables: a 256 MB ring at the RAID0 top, `--qd 63` at and above the RAID0 top, and
  MaxPayload 256 bytes (`setpci`, see [MaxPayload 256](#maxpayload-256)).

The floors, in MB/s (the recorder's highest clean steps on the same fixture, or close to them):

| fixture | 32 GB sweep: one drive / RAID0 | playback sweep: one drive / RAID0 |
|---|---|---|
| `vck190_fmcp1` + 2x Sabrent Rocket 2230 1TB | 4000 / 7500, in 250 MB/s steps | 4500 / 7750, in 250 MB/s steps |
| `vck190_fmcp1` + 2x Samsung 980 PRO 1TB | 4500 / 6500 | 6000 / 8000, in 250 MB/s steps |
| `zcu106_hpc0` + 2x Sabrent Rocket 2230 1TB | 2500 / 3500 | 3000 / 3500 |
| `zcu106_hpc0` + 2x Samsung 980 PRO 1TB | 3000 / 4500 | 3000 / 4000 |

```
sudo nvsetup-raid0.sh -y --trim --single /dev/nvrec0n1   # or: sudo nvsetup-raid0.sh -y --trim  (RAID0)
sudo nvrec --rate 1000MB --size 10G /mnt/rec/t.dat; echo rc=$?
sudo nvverify /mnt/rec/t.dat
sudo nvrec --no-write --rate 8000MB --size 64G; echo rc=$?   # fabric only: no SSD, no file
```

What is the same as on the recorder page, and what differs:

| | fpga-drive-recorder | this design |
|---|---|---|
| test data | `fdrec_tpg`, 256-bit beats, up to 8000 MB/s | the same generator and pattern (16-byte words); 512-bit beats and up to 16 000 MB/s on `vck190_fmcp1` |
| pass/fail | `fdrec` exit 0 (drop count 0) + `fdverify` PASS | `nvrec` exit 0 (`RUN_DROP_COUNT` 0 **and no NVMe error**) + `nvverify` PASS |
| sweep | 500 MB/s steps from the floor, stop after two consecutive failing steps, 3 runs at the top and at the first failing step | the same, from higher floors, plus the 250 MB/s step at the knee |
| I/O size | 8 MB buffers, split by Linux into MDTS-sized NVMe commands | one NVMe command per chunk = the drive's MDTS (512 KB on the Samsung 980 PRO, 256 KB on the Sabrent Rocket) |
| commands in flight | io_uring queue depth 8 (8 MB requests) | 32 per SSD (`--qd`, 1 … 63), issued by the fabric |
| buffer ring | 32 × 8 MB (256 MB) | 512 MB of chunk-sized slots |
| filesystem | XFS, created once per layout | exFAT, contiguous preallocated file (see [Filesystem](filesystem)), created anew for every step |
| before a step | `rm` + `fstrim` of the free space, 60 s idle | `blkdiscard` of the whole drives, new md array, new exFAT, 60 s idle |
| playback figure | the highest clean step for a 10 GB file | the highest clean step for a 40 GiB file (see [Playback](#playback)) |
| NVMe APST | the kernel's default (enabled) | off (the driver's default, module parameter `apst`) |
| CPU in the data path | io_uring submissions and DMA ioctls per 8 MB buffer | none: the CPU sets the run up and waits for its end |

### Playback

Each measurement is one `nvplay` of a test-pattern recording at a fixed sink rate (`--rate`),
into the reference design's checker. A rate is **clean** when `nvplay` exits 0: 0 underflows,
0 checker errors, gaps equal to the recording's drop count, every beat delivered, no NVMe error.
The sweep plays a 10 GiB recording made at 1000 MB/s with 0 drops on a freshly deallocated
volume (the page cache is dropped before every run), in 500 MB/s steps from the floor in the
table above. As for the recordings the sweep stops after two consecutive failing steps, the
highest clean and the first failing step are run 3 times, and the 250 MB/s step at the knee is
added (3 runs). Playbacks start at least 10 minutes after a long recording.

`nvplay` fills the whole ring from the SSDs before it enables the sink (the prefill, given
separately), so the ring absorbs read stalls; the reported time and rate are the streaming time.
The prefilled 512 MB ring also covers a small deficit: when the SSDs deliver less than the sink
rate, a 10 GiB playback stays clean as long as its shortfall over the whole file stays below
512 MB, i.e. up to about 5 % above what the SSDs deliver. When a step underflows, its "streaming
MB/s" (file size over streaming time) includes the prefilled ring, so the SSDs' own delivery
rate is 95 % of it: (10 GiB − 512 MB) / streaming time.

**The sustained playback rate comes from a 40 GiB file.** The highest clean 10 GiB step is
then played from a 40 GiB recording (made at 1000 MB/s, 0 drops, verified), where the
prefilled ring is only 1.2 % of the file, stepping down 250 MB/s until a rate plays clean
(1 run per rate with the Sabrents and 2-5 with the 980 PROs on `zcu106_hpc0`, 3-4 on
`vck190_fmcp1`). **This 40 GiB figure is the one published as the sustained playback rate**,
for every layout; a 10 GiB step above it is marked **ring-assisted** where the SSDs deliver
less than its rate.

### CPU load

Every run stores the CPU load over the transfer: from `/proc/stat` deltas the **total CPU** as a
share of all the target's cores (user / system / IRQ + softirq / I/O wait) and the busy time
**summed over the cores**, in % of one core (it includes interrupt handlers, kernel threads and
other processes); from `time -p` the **transfer process**: `nvrec`'s or `nvplay`'s (user +
system) time over its real time, as a share of one core. "MB/s per % core" is the rate divided
by the process figure. The table gives the runs at the top rates (medians of 3 runs unless
stated). The apps' CPU time is a fixed set-up cost per run (ring and PRP lists, unmounting and
remounting the volume, the statistics: 0.06-0.4 s), not a cost per byte, so its share falls as
a transfer gets longer.

### Drive temperature

The driver reads every SSD's composite temperature from its SMART log
(`/sys/block/nvrecXn1/nvrec/temperature`). `nvbench-suite.sh` samples it every 10 s during a
run and stops the run cleanly, and repeats it after the drives cooled down, when a drive passes
70 °C (`--temp-max`). The guard never fired: the 980 PROs reached at most 48 °C on
`zcu106_hpc0` and 63 °C on `vck190_fmcp1` (RAID0 at 10 000 MB/s with `--qd 63`), the Sabrents
59 °C on `vck190_fmcp1` and 64 °C on `zcu106_hpc0` (long RAID0 recordings); every run stores its
highest sample.

### Evaluation-license sessions

The Host Accelerator in the published bitstreams is an **evaluation** core: it stops
183-184 minutes after the bitstream was loaded (see [Kernel driver](driver)). Every benchmark
session therefore starts with a power cycle (which reloads the bitstream) and ends within
**150 minutes** (`nvbench-suite.sh --budget-min 150`); no run crosses that limit. A run's
result does not depend on the session it was measured in; the results file keeps the uptime of
every run.

### Units

All rates are MB/s (10⁶ bytes/s), as reported by `nvrec` and `nvplay`; GB = 10⁹ bytes. Sizes
follow the apps' suffixes: 10G = 10 GiB, 32G = 32 GiB (2³⁰ bytes), as with `fdrec` on the
recorder page (which also writes "10 GB" for `--size 10G`). "FIFO high-water" is the highest
fill of the ingest FIFO during a recording, in fabric beats: of 8192 beats of 32 bytes on
`zcu106_hpc0`, of 4096 beats of 64 bytes on `vck190_fmcp1` (256 KB on both); "full" means that
it overflowed. "Ring high-water" is the most ring slots (chunks) in use at once.

### Running the benchmarks

`nvbench-suite.sh` (in the image, `sw/nvrec-apps/`) runs every measurement on this page on the
board and appends one JSON line per run to `/var/lib/nvbench/results.jsonl`: the fixture
(target, SSD models, serial numbers, firmware, PCIe link, MDTS, datapath width), the layout, the
run's parameters and every figure (rates, drops, NVMe errors, FIFO and ring high-water marks,
commands in flight, latency and histogram, `nvverify` result and first gap, CPU, drive
temperatures). The method above, for a RAID0 on `zcu106_hpc0`:

```
sudo nvbench-suite.sh fabric     --from 4500 --step 250 --stop-after 2 --confirm 2 --confirm-fail 2
sudo nvbench-suite.sh fabricplay --from 4500 --step 250 --stop-after 2 --confirm 2 --confirm-fail 2 --passes 20
sudo nvbench-suite.sh sustained --layout raid0 --size 32G --from 4500 --step 500 --stop-after 2 --confirm 2 --confirm-fail 2
sudo nvbench-suite.sh sustained --layout raid0 --size 32G --rates 5000 --confirm 2 --qd 63   # the same step at --qd 63
sudo nvbench-suite.sh burst     --layout raid0 --size 10G --rates 5000,5500     # and --size 40G
sudo nvbench-suite.sh longrun   --layout raid0 --size 350G --rates 3500,3750 --idle 300
sudo nvbench-suite.sh playback  --layout raid0 --from 4000 --step 500 --stop-after 2 --confirm 2 --confirm-fail 2
sudo nvbench-suite.sh status                                                    # what is in the results file
```

A run already in the results file is not repeated, so the suite can be stopped and started
again with the same command; with `--budget-min` (default 150) it stops cleanly before a run
that would end later than that many minutes after the bitstream load (exit code 3), and when
the Host Accelerator stops it exits with code 5: power-cycle the board and run the same command
again. `--qd` and `--tag <word>` keep A/B runs of the same steps apart (`/qd=63` and, for the
MaxPayload 256 runs, `/tag=mps256` in the run ids), `--buffers` sets the ring of the ring A/B.
The 40 GiB playback confirmations are plain `nvrec --size 40G` + `nvverify` + `nvplay` runs.
**The suite erases the SSDs.** See [Applications](apps.md#nvbench-suitesh) for every option.

## Setups

| SSDs | target | FMC card, connector | PCIe link per SSD | datapath | measured |
|---|---|---|---|---|---|
| 2x Sabrent Rocket 2230 1TB (SB-2130-1TB) | `vck190_fmcp1` (VCK190, two Cortex-A72 at 1.4 GHz, DDR4-3200 x64) | M.2 M-key Stack FMC (OP073), FMCP1 | **Gen4 x4** (16 GT/s) | 512 bits, `src_clk` = `dp_clk` = 249.9998 MHz; ring on its own 512-bit NoC port, one NoC port per Root Port; egress FIFO 256 KB | 2026-10-23 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | FPGA Drive FMC Gen4 (OP063), FMCP1 | **Gen4 x4** (16 GT/s) | as above | 2026-10-23 |
| 2x Sabrent Rocket 2230 1TB (SB-2130-1TB) | `zcu106_hpc0` (ZCU106, four Cortex-A53 at 1.2 GHz, DDR4-2133 x64) | M.2 M-key Stack FMC (OP073), HPC0 | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 256 bits, `src_clk` = `dp_clk` = 249.975 MHz; ring on `S_AXI_HP2_FPD`, 128 bits at 322.19 MHz | 2026-10-23 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | FPGA Drive FMC Gen4 (OP063), HPC0 | Gen3 x4 (`8GT/s (downgraded)`) | as above | 2026-10-23 |

Every figure was measured with the images of this repository (register map 1.2, driver and
apps 1.1, an ingest FIFO of 256 KB: 8192 beats of 32 bytes on `zcu106_hpc0`, 4096 beats of 64
bytes on `vck190_fmcp1`; an egress FIFO of 128 KB on `zcu106_hpc0` and 256 KB on
`vck190_fmcp1`). The past-cache and MaxPayload rows of `vck190_fmcp1` + Sabrent were measured
the night before, on earlier builds of this design (the single-drive and past-cache paths are
the same on every build). `uzev` is built but was not tested on hardware in this revision: there
are no figures for it on this page.

| target | drive | SSD | firmware | PCIe link | MDTS | I/O queues granted | nvrec_core | measured |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 16.0 GT/s PCIe x4 | 256 KB | 8 | 1.2 | 2026-10-23 |
| `vck190_fmcp1` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 16.0 GT/s PCIe x4 | 256 KB | 8 | 1.2 | 2026-10-23 |
| `vck190_fmcp1` | nvrec0n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 16.0 GT/s PCIe x4 | 512 KB | 1 | 1.2 | 2026-10-23 |
| `vck190_fmcp1` | nvrec1n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 16.0 GT/s PCIe x4 | 512 KB | 1 | 1.2 | 2026-10-23 |
| `zcu106_hpc0` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.2 | 2026-10-23 |
| `zcu106_hpc0` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.2 | 2026-10-23 |
| `zcu106_hpc0` | nvrec0n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 8.0 GT/s PCIe x4 | 512 KB | 1 | 1.2 | 2026-10-23 |
| `zcu106_hpc0` | nvrec1n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 8.0 GT/s PCIe x4 | 512 KB | 1 | 1.2 | 2026-10-23 |

The same two drives of each model are used on both boards. APST was off on every drive (the 980
PROs and the Sabrents both come up with it disabled), MaxPayload 128 and MaxReadReq 512 bytes on
every Root Port and SSD (DevCap: Root Ports 1024 bytes, 980 PRO 256, Sabrent 512).

## Ceilings at a glance

Why doesn't a recording reach the 8 or 16 GB/s of the fabric, or the SSDs' rated speeds? These
tables list every ceiling that was measured, per device family, with what sets it and how to get
past it where there is a way. The numbers are the measurements on this page; the reasoning
applies to every target of the family.

### Zynq UltraScale+ (`zcu106_hpc0`, `uzev`)

Measured on `zcu106_hpc0` with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230 1TB.
`uzev` has the same block design with `S_AXI_HP2_FPD` at 327.77 MHz (5244 MB/s peak) and was
not measured in this revision.

| ceiling | measured | what sets it | how to get past it |
|---|---|---|---|
| `S_AXI_HP2_FPD`, the ring's port into DDR | **5155 MB/s** peak (128 bits × 322.19 MHz). Without an SSD, recording and ring-resident playback are clean at **5000 MB/s** (3 of 3) and fail at 5250 MB/s (3 of 3), where the ring writer delivers a flat 5154.5-5154.9 MB/s and the reader ~5027 MB/s (the same with either FMC card). With the SSDs, **both RAID0 pairs record 5000 MB/s** over 32 GB (3 of 3; the 980 PROs also with a 256 MB ring, the Sabrents also with `--qd 63`) and drop at 5250-6000 MB/s writing a flat 5090-5155 MB/s, from the first ring pass on | a 128-bit PS-PL port, clocked at most 333 MHz (requested; 322.19 MHz from the RPLL) | a second ring writer on another HP port (not implemented; the next limit would be the two Gen3 x4 slots, ~6 GB/s); a Versal target |
| Playback with the SSDs writing DDR | RAID0 playback sustained (40 GiB) at **4250 MB/s** with the 980 PRO pair (3 of 3; 4500 MB/s 2 of 5, short of data for at most 0.12 ms) and **4500 MB/s** with the Sabrent pair (4750 MB/s underflows); a 10 GiB file plays at 4750 MB/s with the 980 PROs (3 of 3, ring-assisted) and 4500 MB/s with the Sabrents (4750 MB/s 2 of 3). While the ring reader streams the ring, the SSDs deliver ~4.63 GB/s (980 PRO pair) and ~4.64-4.69 GB/s (Sabrent pair): a playback at 5000 MB/s streams 4871-4896 MB/s, from a 10 or a 40 GiB file. Without the reader the pairs fill the ring at ~6.3 GB/s (512 MB in 0.085 s), and the reader alone streams 5000 MB/s | the SSDs' writes into DDR (through `S_AXI_HP0/HP1_FPD`) and the ring reader's reads (through `S_AXI_HP2_FPD`) at the same time, ~9.3 GB/s of mixed traffic on the DDR4-2133 x64 controller (17.1 GB/s peak). The same with two different drive pairs, so not the drives. Not the shared DDR controller port: with the ring moved to `S_AXI_HP3_FPD`, which shares no port with HP0/HP1, the 980 PRO pair delivered the same (4878 MB/s streamed at 5000 MB/s). Not the total either: a recording moves 10 GB/s through DDR cleanly (the same two paths in the other direction). What limits the mix was not isolated | - (a Versal target plays back up to 8750 MB/s) |
| One PCIe Gen3 x4 slot | at MaxPayload 128 bytes one 980 PRO writes ~3.04 GB/s, one Sabrent ~2.75-2.83 GB/s with `nvrec`; both read ~3.19 GB/s: one drive records **3000 MB/s** (980 PRO; 3500 MB/s writes 3037.7-3038.3 MB/s) or **2750 MB/s** (Sabrent; 3000 MB/s writes 2752.7-2828.9 MB/s) over 32 GB and plays back **3000 MB/s** sustained (3250 MB/s for a 10 GiB file, ring-assisted). At MaxPayload 256 bytes the slot writes ~3.36 GB/s (980 PRO) or ~3.01 GB/s (Sabrent) and reads ~3.54-3.55 GB/s with either: **3250 / 3000 MB/s** recording, **3500 MB/s** playback (sustained: a 40 GiB file plays clean at 3500 MB/s with the 980 PRO) | the XDMA Root Ports are Gen3 x4 (a Gen4 drive links at 8 GT/s) and the kernel's default 128-byte MaxPayload | RAID0 across both slots; MaxPayload 256 bytes with `setpci` **for one drive only** (it makes the 980 PRO RAID0 playback worse: 4500 and 4750 MB/s clean 1 of 3 each); a Versal target with Gen4 x4 ([MaxPayload 256](#maxpayload-256)) |
| The SSD after its SLC cache | one 980 PRO **1750 MB/s** over 200 GiB, the 980 PRO pair **3500 MB/s** over 350 GiB (3750 MB/s drops from 253.59 GB, where the pair's ~245 GB cache ends); one Sabrent **1500 MB/s** over 200 GiB (1750 MB/s drops from 104.16 GB, writing 1735.2 MB/s), the Sabrent pair **3250 MB/s** over 350 GiB (3500 MB/s drops from 159.45 GB, writing 3453.6 MB/s) | the drive's TLC flash; with `nvrec`'s commands one Sabrent writes ~1.73 GB/s past its cache (fio: ~1.8 GB/s), see [Supported SSDs](supported_ssds.md#observations-with-the-tested-drives) | drives without an SLC cliff, larger drives ([The SLC cache](#the-slc-cache)) |
| Write stalls against the ring | not a ceiling with the 512 MB default, but **the Sabrent pair needs all of it**: RAID0 at 5000 MB/s used up to 1474 of 2048 slots (369 MB; write latencies up to 32 ms), and a 256 MB ring dropped in 3 of 3 runs (first gaps 12.3-29.3 GB). The 980 PRO pair used at most 43 slots (22 MB) at 5000 MB/s (clean with a 256 MB ring too), and past the cache, 350 GiB at 3500 MB/s, **573 slots (287 MB)** | the drives' write-latency spikes (up to 32 ms with the Sabrents in the cache, up to 46 ms with the 980 PROs past it) | keep the 512 MB default ring (with 256 KB chunks it is also the largest ring, 2048 slots) ([Ring size](#ring-size)) |
| The source and the sink | 8000 MB/s (250 MHz × 32 bytes) | `src_clk` × 256 bits | not reached: HP2 comes first |
| PS DDR | not reached by a recording: RAID0 at 5000 MB/s (10 GB/s of DDR traffic) is clean; see the playback row | every recorded byte crosses DDR twice | - |
| The CPU | not a ceiling: `nvrec` 1.3-2.9 %, `nvplay` 3.1-5.0 % of one Cortex-A53 core at the top rates | no software in the data path | - |

### Versal (`vck190_fmcp1`)

Measured with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230 1TB on this repository's
image (the Sabrent past-cache and MaxPayload figures on earlier builds, see [Setups](#setups));
every drive links at PCIe Gen4 x4. The design is 512 bits wide, with one
NoC port for the ring and one for each PCIe Root Port; why, is explained below the table.

| ceiling | measured | what sets it | how to get past it |
|---|---|---|---|
| PS DDR (one DDR4-3200 x64 controller, 25.6 GB/s peak) | **the ceiling with the 980 PRO pair, in both directions**: RAID0 records **9250 MB/s** over 32 GB (3 of 3 at `--qd 32` and at `--qd 63`; 9500 MB/s 0 of 3 at `--qd 32` and 1 of 3 at `--qd 63`, writing 9.48-9.50 GB/s) and plays back **8750 MB/s** sustained (a 40 GiB file 3 of 3; 9000 MB/s underflows, 8.92-8.98 GB/s streamed). At 9500 MB/s the ingest FIFO overflows while the ring holds only 102-124 of 1024 slots: the drives keep up, the ring writer does not get into DDR | every byte crosses DDR twice (ring write + SSD read when recording, SSD write + ring read when playing back): **~18-19 GB/s of mixed read/write traffic, 72-74 % of the controller's peak**. Not the drives (2 × ~4.95 GB/s write, 2 × ~6.3 GB/s read), not the NoC ports (the fabric alone moves 14.5 GB/s into DDR), not the commands in flight (`--qd 63` = `--qd 32`), not the CPU | a Versal device with two DDR controllers (ring and SSD DMA on different controllers); the margin at 9250 MB/s is thin (FIFO high-water up to 4021 of 4096 beats) |
| The SSD | **980 PRO**: in its cache one drive writes ~4.95 GB/s: one drive records **5000 MB/s** over 32 GB (3 of 3, ring-assisted: up to 657 of 1024 slots; 5250 and 5500 MB/s 0 of 3 writing 4.95-4.96 GB/s). After the cache (~120 GB per drive, ~245 GB for the pair): one drive **1750 MB/s** over 200 GiB, the pair **3250 MB/s** over 350 GiB (3500 MB/s drops from 324.32 GB, writing 3494.7 MB/s). **Sabrent**: in its cache one drive writes ~4.2 GB/s with `nvrec`'s commands and reads ~4.54 GB/s: one drive records **4000 MB/s** over 32 GB (3 of 3, ring-assisted: up to 1015 of 2048 slots; 4250 MB/s 2 of 3, 4500 MB/s 0 of 3 writing 4.19-4.24 GB/s) and plays back **4500 MB/s** sustained (40 GiB 3 of 3; 4750 MB/s for a 10 GiB file, ring-assisted). The pair records **7750 MB/s** over 32 GB (3 of 3; 8000 MB/s 2 of 3). At the start of the measurements, on the 256-bit build of this design (one drive's path is the same on every build), one drive recorded 4250 MB/s 3 of 3 and failed at 4500 MB/s writing 4.24-4.31 GB/s; after about 4.9 TB had been written to the pair, both drives wrote 3-5 % slower (about 9.7 TB were written to the pair over the two days). After the cache (~70-75 GB per drive, ~140 GB for the pair): one drive **1500 MB/s** over 200 GiB, the pair **3250 MB/s** over 350 GiB; on the 256-bit build 1750 MB/s (one drive) and 3500 MB/s (pair) dropped past the cache, writing 1729.7 and 3389.3 MB/s | the drive's in-cache write and read rates, then its TLC flash; `nvrec` writes one Sabrent ~5 % slower than fpga-drive-recorder does, in and past the cache (an open observation, see [Supported SSDs](supported_ssds.md#observations-with-the-tested-drives)) | faster drives (a Gen5 drive on Gen4 x4 can reach ~7 GB/s per link, but PS DDR comes first in RAID0); RAID0; drives without an SLC cliff |
| PCIe Gen4 x4 and MaxPayload | one **980 PRO** reads ~6.25-6.3 GB/s through its link at MaxPayload 128 bytes: playback **6000 MB/s** sustained (40 GiB; 6250 MB/s for a 10 GiB file, ring-assisted). At MaxPayload 256 bytes ~6.9-7.0 GB/s: **6750 MB/s** sustained (7000 MB/s for 10 GiB). Not a ceiling for the **Sabrent**: MaxPayload 256 bytes changed neither its recording (4250 / 4500 MB/s) nor its playback (4750 / 5000 MB/s), measured on the 256-bit build | TLP overhead of 128-byte payloads on Gen4 x4; the Sabrent reads its data at ~4.5 GB/s, below its link | MaxPayload 256 bytes with `setpci` for one drive that reads faster than ~6.3 GB/s (RAID0 gains no full step: 9000 MB/s 1 of 3 at MaxPayload 256, the DDR row) |
| Commands in flight per drive | not a ceiling. **980 PRO pair** (512 KB commands): the same tops at `--qd 32` and `--qd 63` (record 9250, playback 8750 MB/s; at 9500 MB/s 63 commands drop fewer beats, 580-870 against 214 k-452 k). **Sabrent pair** (256 KB commands): RAID0 at `--qd 32` **7750 MB/s** (3 of 3; 8000 MB/s 2 of 3, 8250 MB/s 0 of 1), at `--qd 63` only **7500 MB/s** (3 of 3; 7750 MB/s 1 of 3, 8000-8500 MB/s 0 of 3 writing 7.80-8.28 GB/s) | the 980 PROs are bound by DDR; with 63 commands per drive the Sabrents' write-latency maxima grow from ~21 to 31-45 ms | **the default 32**; `--qd 63` helps neither pair on this image ([Commands in flight](#commands-in-flight-qd-32-and-63)) |
| Playback from the ring into the fabric | the 980 PRO pair plays every step from 8000 to 8750 MB/s clean 3 of 3 (and a 40 GiB file at 8750 MB/s); 9000 MB/s is a steady rate shortfall (the DDR row). The **Sabrent pair** plays a 10 GiB file at **8750 MB/s** (3 of 3; 8250 MB/s 1 of 3) and a 40 GiB file at **7500 MB/s** (3 of 3; 7750-8750 MB/s 0-2 of 3): short underflows (2362-391 273 ticks of 4 ns) at the requested rate, with the ring full and the SSDs' read latency at most 3.1 ms; the steady deficit only starts at 9000-9250 MB/s (9099.5 MB/s streamed at 9250 MB/s) | not isolated: short stalls of the ring reader's DDR reads while the Sabrents write DDR (not seen with the 980 PRO pair, whose commands are 512 KB against the Sabrents' 256 KB). An earlier build with a 128 KB egress FIFO showed the same pattern from 8250 MB/s on a 10 GiB file | - |
| The fabric datapath | without an SSD, recording is clean up to **14 500 MB/s** (3 of 3; 14 750 MB/s drops, the ring writer delivers 14.68-14.69 GB/s) and ring-resident playback up to **13 750 MB/s** (3 of 3; 14 000 MB/s underflows 3 of 3, ~13.77 GB/s streamed; over 20 passes 13 750 MB/s with 256 KB ring chunks, 13 500 MB/s with 512 KB). The earlier image (egress FIFO 128 KB) played the ring clean at 14 000 MB/s | the ring's NoC port: 512 bits at `dp_clk`, NoC QoS request 14 000 MB/s per direction (16 000 MB/s per NMU and memory-controller port including packetization, the NoC compiler's limit) for recording; the ring reader with the 256 KB egress FIFO for playback (not isolated further) | not reached by any SSD pair |
| Each Root Port's NoC port | not reached: each 256 bits at 250 MHz with a QoS request of 7000 MB/s per direction; one 980 PRO reads at most ~7 GB/s through its Gen4 x4 link | - | - |
| Write stalls against the ring | not a ceiling with the 512 MB default, but **the Sabrent pair needs it**: up to 1207 of 2048 slots at 7750 MB/s, and a **256 MB ring drops at 7750 MB/s** (0 of 3, 7.54-7.60 GB/s written). The 980 PRO pair used at most 126 slots (63 MB) in the cache, and a 256 MB ring is clean 3 of 3 at 9250 MB/s; past the cache, 350 GiB at 3250 MB/s, 330 slots | Sabrent write stalls of 20 ms and more | keep the 512 MB default; with 256 KB chunks it is also the largest ring (2048 slots) |
| The source and the sink | 16 000 MB/s (250 MHz × 64 bytes) | `src_clk` × 512 bits | not reached |
| The CPU | not a ceiling: `nvrec` 1.2-2.8 %, `nvplay` 2.9-5.2 % of one Cortex-A72 core at the top rates | no software in the data path | - |

**Why 512 bits and one NoC port per Root Port.** This design was first built for
`vck190_fmcp1` at 256 bits, with both Root Ports' DMA (`M_AXI_BRIDGE` of the two QDMA bridges)
sharing the base design's NoC port `S08_AXI` (256 bits at 250 MHz, QoS request 7000 MB/s), and
measured with the Sabrent pair on the same night. Its limits were:

* **the fabric**: recording without an SSD clean up to 7750 MB/s (8000 MB/s drops, the ring
  writer delivering 7.82 GB/s) and ring-resident playback up to 7500 MB/s (7750 MB/s underflows):
  the same knees as fpga-drive-recorder's 256-bit datapath, because `src_clk` = `dp_clk` leaves a
  source at one beat per clock no time to drain the ingest FIFO after a pause of the ring writer;
* **the shared NoC port**: RAID0 recorded **6750 MB/s** over 32 GB (3 of 3) and dropped at 7000
  and 7500 MB/s while the pair wrote only 6.69-6.76 GB/s, each drive ~3.37 GB/s against 4.24 GB/s
  alone; `--qd 63` made it worse (6.24 GB/s at 7000 MB/s). The recorder's host-side reference on
  the same path, fio without any fabric traffic, writes 7.17-7.33 GB/s with this pair;
* RAID0 playback 7250 MB/s (7500 MB/s delivered 7.48 GB/s).

The 512-bit build with one NoC port per Root Port (`S08_AXI` and `S10_AXI`, each 7000 MB/s),
measured the same night with the same drives, lifted every one of them: fabric 14 500 MB/s
recording, RAID0 recording 7500 MB/s (+750), RAID0 playback of a 10 GiB file 8000 MB/s (+750),
bursts +750 MB/s. The design in this repository is that build with a 256 KB egress FIFO: with
the Sabrent pair it records 7750 MB/s and plays a 10 GiB file at 8750 MB/s, and with the
980 PRO pair it reaches the DDR controller's limit (9250 MB/s recording, 8750 MB/s playback).
One drive and the long recordings, which need far less than either build's ceilings, gave the
same results on both builds apart from the drives' slowdown described above.

## Results

Targets `vck190_fmcp1` (Versal) and `zcu106_hpc0` (Zynq UltraScale+) with the SSD pairs of
[Setups](#setups). RAID0 = both drives of a pair, with the drives' MDTS as the chunk (512 KB on
the Samsung 980 PRO, 256 KB on the Sabrent Rocket); "single" = SSD1 (`/dev/nvrec0n1`). Default
512 MB ring and 32 commands in flight per SSD unless a row says otherwise.

### Fabric only (no SSD)

The path from the fabric into DDR and back, with no SSD involved (see
[Recording](#recording)):

| target | datapath | recording (`nvrec --no-write`), highest clean | ring-resident playback (`nvplay --ring-only`), highest clean | first failing step | what limits it |
|---|---|---|---|---|---|
| `vck190_fmcp1` | 512 bits, `src_clk` = `dp_clk` = 249.9998 MHz; ring on its own NoC port, 512 bits, QoS 14 000 MB/s; egress FIFO 256 KB | **14 500 MB/s** (3 of 3) | **13 750 MB/s** (3 of 3, 3 passes; over 20 passes 13 750 MB/s with 256 KB ring chunks, 13 500 MB/s with 512 KB) | recording 14 750 MB/s (3 of 3 drop; the ring writer delivers 14.69 GB/s); playback 14 000 MB/s (3 of 3: 395 833-396 974 underflow ticks, ~13.77 GB/s streamed) | the ring's NoC port (recording); the ring reader (playback) |
| `zcu106_hpc0` | 256 bits, `src_clk` = `dp_clk` = 249.975 MHz; ring on `S_AXI_HP2_FPD`, 128 bits at 322.19 MHz | **5000 MB/s** (3 of 3) | **5000 MB/s** (3 of 3) | 5250 MB/s (3 of 3: the ring writer delivers 5154.5-5154.9 MB/s; 3 of 3 underflows, ~5027 MB/s streamed) | `S_AXI_HP2_FPD`: 128 bits × 322.19 MHz = 5155 MB/s |

* On `zcu106_hpc0` the record and playback knees are the same, and above them the ring writer
  moves a flat 5155 MB/s = 322.19 MHz × 16 bytes: the 128-bit HP port at its clock, not the
  8000 MB/s source, the 256-bit ingest FIFO and ring writer, or the DDR. These are the knees of
  fpga-drive-recorder on the same board (5000 / 5000 MB/s, 5153 MB/s delivered above them). With
  the M.2 M-key Stack FMC fitted instead of the FPGA Drive FMC Gen4 (one run each) the result is
  the same: 5000 MB/s clean, 5250 MB/s dropping at 5154.9 MB/s or underflowing at 5026.9 MB/s.
* On `vck190_fmcp1` the 512-bit datapath takes the ring writer to 14.7 GB/s, almost twice the
  256-bit knees (7750 MB/s recording, 7500 MB/s playback; see
  [Why 512 bits](#versal-vck190_fmcp1)), and well above what any SSD pair delivers. With the
  M.2 M-key Stack FMC fitted instead of the FPGA Drive FMC Gen4 (one run each) the result is the
  same: 14 500 MB/s recording and 13 750 MB/s ring-resident playback clean. The earlier
  image with the 128 KB egress FIFO, swept from 7000 MB/s in 500 MB/s steps, gave the same
  recording knee and played the ring clean at 14 000 MB/s (14 250 MB/s: 7-9.6 k underflow ticks):
  the 256 KB egress FIFO costs one 250 MB/s step of ring-resident playback, ~1.7 % of the reader's
  rate.
* The data was intact in every playback (0 checker errors, 0 gaps); underflows are cycles in
  which the sink found no data. `nvrec --no-write` takes 0.2-1.5 % of one core and
  `nvplay --ring-only` 4-16 % (a fixed set-up time over runs of 0.1-2.4 s: no software in the
  data path).
* The "delivered MB/s" of a clean fabric-only step can read up to 1.5 % above the generator
  rate: it is computed from the elapsed time of a 5-15 s run; the drop counter is the verdict.

Every step (`vck190_fmcp1`: this repository's image):

| target | test | rate (MB/s) | result | drops (beats) / underflow ticks | FIFO high-water (beats) | delivered MB/s |
|---|---|---|---|---|---|---|
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14000 | clean | 0 | 106 | 13998.7 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14250 | clean | 0 | 302 | 14251.2 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14500 | clean | 0 | 1805 | 14500.8 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14500 (#2) | clean | 0 | 129 | 14500.8 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14500 (#3) | clean | 0 | 115 | 14500.8 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14750 | drops | 4 460 816 | full | 14689.9 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14750 (#2) | drops | 4 458 933 | full | 14689.9 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 14750 (#3) | drops | 4 457 571 | full | 14689.9 |
| `vck190_fmcp1` | `nvrec --no-write`, 64 GiB | 15000 | drops | 22 917 274 | full | 14686.8 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 13750 | clean | 0 | - | 13765.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 13750 (#2) | clean | 0 | - | 13765.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 13750 (#3) | clean | 0 | - | 13765.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 14000 | underflows | 396 974 | - | 13765.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 14000 (#2) | underflows | 395 856 | - | 13765.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 14000 (#3) | underflows | 395 833 | - | 13765.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 3 x 512 MB | 14250 | underflows | 2 018 055 | - | 13201.7 |
| `vck190_fmcp1` | `nvplay --ring-only`, 20 x 512 MB | 13750 | underflows | 1 284 891 | - | 13608.9 |
| `vck190_fmcp1` | `nvplay --ring-only`, 20 x 512 MB | 14000 | underflows | 2 637 499 | - | 13765.9 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 4500 | clean | 0 | 211 | 4500.0 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 4750 | clean | 0 | 248 | 4750.1 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5000 | clean | 0 | 170 | 5000.0 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5000 (#2) | clean | 0 | 257 | 5000.0 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5000 (#3) | clean | 0 | 172 | 5000.0 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5250 | drops | 39 594 140 | full | 5154.5 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5250 (#2) | drops | 39 594 439 | full | 5154.9 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5250 (#3) | drops | 39 563 646 | full | 5154.9 |
| `zcu106_hpc0` | `nvrec --no-write`, 64 GiB | 5500 | drops | 143 708 146 | full | 5154.9 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 4500 | clean | 0 | - | 4498.3 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 4750 | clean | 0 | - | 4749.0 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5000 | clean | 0 | - | 4998.8 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5000 (#2) | clean | 0 | - | 4998.8 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5000 (#3) | clean | 0 | - | 4998.8 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5250 | underflows | 14 686 471 | - | 5026.9 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5250 (#2) | underflows | 14 683 064 | - | 5026.9 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5250 (#3) | underflows | 14 719 696 | - | 5026.9 |
| `zcu106_hpc0` | `nvplay --ring-only`, 20 x 512 MB | 5500 | underflows | 31 544 117 | - | 5024.5 |

### Sustained recording rate

32 GiB per step as in the [recording method](#recording): 500 MB/s steps from the sweep floor,
a freshly deallocated volume and 60 s of idle time before every step, early stop after two
consecutive failing steps, 3 runs at the highest clean and at the first failing step, and the
250 MB/s step at the knee. The 10 GB and 40 GB columns come from the
[burst recordings](#burst-and-40-gb-recordings), the last column from the
[long recordings](#long-recordings-past-the-slc-cache): 32 GB stays inside the SLC cache of
these drives.

| target | SSD | layout | 32 GB sweep: highest clean step (in the cache) | highest clean, 10 GB | highest clean, 40 GB | sustained past the SLC cache |
|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **7750 MB/s** (3 of 3; 8000 MB/s 2 of 3, the failing run writing 7.57 GB/s; 8250 MB/s 0 of 1); 7500 MB/s with `--qd 63` (3 of 3; 7750 MB/s 1 of 3, 8000-8500 MB/s 0 of 3, see [Commands in flight](#commands-in-flight-qd-32-and-63)) | 8000 MB/s or more (7750 and 8000 MB/s pass; not run higher) | 7500 MB/s (7750 MB/s drops from 39.01 GB, 8000 MB/s from 26.62 GB) | **3250 MB/s** over 350 GiB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **4000 MB/s** (3 of 3, ring-assisted: up to 1015 of 2048 slots; 4250 MB/s 2 of 3, 4500 MB/s 0 of 3 writing 4.19-4.24 GB/s) | 4250 MB/s or more (4000 and 4250 MB/s pass; not run higher) | 4000 MB/s (4250 MB/s drops from 27.22 GB) | **1500 MB/s** over 200 GiB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **9250 MB/s** (3 of 3 at `--qd 32` and at `--qd 63`; 9500 MB/s 0 of 3 at `--qd 32`, 1 of 3 at `--qd 63`, writing 9.48-9.50 GB/s: PS DDR) | 9250 MB/s (9500 MB/s drops from 1.94 GB) | 9250 MB/s (9500 MB/s drops from 2.33 GB) | **3250 MB/s** over 350 GiB (3500 MB/s drops from 324.32 GB) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **5000 MB/s** (3 of 3, ring-assisted; 5250 and 5500 MB/s 0 of 3, writing 4.95-4.96 GB/s) | 5000 MB/s (5250 MB/s drops from 9.74 GB) | 5000 MB/s (5250 MB/s drops from 9.32 GB) | **1750 MB/s** over 200 GiB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **5000 MB/s** (3 of 3, also with `--qd 63`; 5250-6000 MB/s exceed `S_AXI_HP2_FPD`, 5090-5155 MB/s written; with a 256 MB ring 5000 MB/s drops 3 of 3) | 5000 MB/s (5500 MB/s drops) | 5000 MB/s (5500 MB/s drops) | **3250 MB/s** over 350 GiB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2750 MB/s** (3 of 3; 3000 MB/s drops: the drive writes 2.75-2.83 GB/s on its Gen3 x4 link) | 2750 MB/s (3000 MB/s drops) | 2750 MB/s (3000 MB/s drops) | **1500 MB/s** over 200 GiB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **5000 MB/s** (3 of 3; 5250-6000 MB/s exceed `S_AXI_HP2_FPD`, 5153-5155 MB/s written) | 5000 MB/s (5500 MB/s drops) | 5000 MB/s (5500 MB/s drops) | **3500 MB/s** over 350 GiB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3000 MB/s** (3 of 3; 3500 MB/s drops: the Gen3 x4 slot writes ~3.04 GB/s) | 3000 MB/s (3500 MB/s drops) | 3000 MB/s (3500 MB/s drops) | **1750 MB/s** over 200 GiB |

* **`vck190_fmcp1`, 980 PRO RAID0: 9250 MB/s** (3 of 3) at `--qd 32` and at `--qd 63`, with the
  ring at no more than 88 slots and the ingest FIFO up to 2800-4021 of 4096 beats; 9500 MB/s
  drops 214 k-452 k beats (`--qd 32`) or 580-870 beats (`--qd 63`, 1 of 3 clean) while the ring
  holds no more than 124 slots: the ring writer's DDR writes, with both SSDs reading DDR, are the
  limit, not the drives. At 10 000 MB/s the pair falls behind as well (9.75-9.82 GB/s written).
* **`vck190_fmcp1`, one 980 PRO: 5000 MB/s** (3 of 3), ring-assisted: the drive writes
  4.95 GB/s in its cache (every 5250 and 5500 MB/s run: 4951-4957 MB/s), and the 512 MB ring
  absorbs the deficit of a 32 GB recording (up to 657 slots). 4500 MB/s is the full-rate step
  (ring high-water 43).
* **`vck190_fmcp1`, Sabrent RAID0: 7750 MB/s** (3 of 3) at the default 32 commands in flight
  per drive, with the ring up to 1207 of 2048 slots; 8000 MB/s 2 of 3 (the failing run writes
  7.57 GB/s from 3.47 GB), 8250 MB/s drops (7.69 GB/s). With `--qd 63` the pair records only
  7500 MB/s (3 of 3). There is no start-up gap (APST is off).
* **`vck190_fmcp1`, one Sabrent: 4000 MB/s** (3 of 3, with the ring at 954-1015 of 2048 slots:
  the drive barely keeps up); 4250 MB/s 2 of 3, 4500 MB/s 0 of 3 writing 4.19-4.24 GB/s. Both
  drives had become 3-5 % slower over the measurements; see
  [Ceilings at a glance](#versal-vck190_fmcp1).
* **`zcu106_hpc0`, Sabrent RAID0: 5000 MB/s** (3 of 3, also at `--qd 63`), the HP2 knee as with
  the 980 PRO pair; 5250-6000 MB/s drop with the HP2 signature (first gap 2.1-14.4 MB). The pair
  needs much of the default ring at this rate (up to 1474 of 2048 slots, write latencies up to
  32 ms), and a 256 MB ring drops; see [Ring size](#ring-size).
* **`zcu106_hpc0`, one Sabrent: 2750 MB/s** (3 of 3, ring high-water 615-682 slots, ~2.5 ms
  average latency with 32 commands in flight). 3000 MB/s drops in 3 of 3 runs while the drive
  writes 2752.7-2828.9 MB/s (first gaps at 6.56-9.37 GB): the drive on its Gen3 x4 link at
  MaxPayload 128, writing ~5 % slower than with fpga-drive-recorder (2879-2948 MB/s).
* **`zcu106_hpc0`, one 980 PRO: 3000 MB/s** (3 of 3, ring high-water 27-32 slots, latency
  ~1.06 ms on average with 26-31 commands in flight). 3500 MB/s drops in 3 of 3 runs while the
  drive writes 3037.7-3038.3 MB/s: the ring and the ingest FIFO fill at the ~460 MB/s deficit and
  the first gap lies at 4.05-4.10 GB. This is the drive's Gen3 x4 link.
* **`zcu106_hpc0`, 980 PRO RAID0: 5000 MB/s** (3 of 3) with the default 512 MB ring and with a
  256 MB ring. 5250, 5500 and 6000 MB/s drop while writing a flat 5152.9-5154.5 MB/s, with the
  signature of `S_AXI_HP2_FPD`: the first gap lies inside the first ring pass (14.44 MB at
  5250 MB/s, 4.64 MB at 5500 MB/s, 2.36 MB at 6000 MB/s: the 256 KB ingest FIFO filling at the
  excess over 5155 MB/s). The ring never held more than 42 slots (21 MB); two of the 5000 MB/s
  runs reached a FIFO high-water of 1886 and 880 beats (the fabric-only runs 170-257): HP2 at
  97 % of its peak while both SSDs read DDR, without a drop.
* `nvverify` found every failing recording's missing words equal to its drop count (2 words per
  32-byte beat, 4 per 64-byte beat), with 0 corrupted words; 0 NVMe errors in every run.

Every step of the 32 GB sweeps ("first gap" is the file offset of the first discontinuity
reported by `nvverify`; "avg MB/s" is the data written divided by the recording time, which
includes writing out what the ring holds when the source stops):

| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | ring high-water (slots) | avg MB/s | nvverify | first gap |
|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7500 | pass | 0 | 71 | 1054 / 2048 | 7479.3 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7750 | pass | 0 | 80 | 1207 / 2048 | 7716.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7750 (#2) | pass | 0 | 75 | 740 / 2048 | 7742.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7750 (#3) | pass | 0 | 77 | 780 / 2048 | 7747.4 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 | drops | 23 500 262 | full | 2048 / 2048 | 7571.6 | gaps | 3.47 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 (#2) | pass | 0 | 98 | 728 / 2048 | 7990.6 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 (#3) | pass | 0 | 93 | 394 / 2048 | 7996.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8250 | drops | 30 294 363 | full | 2048 / 2048 | 7685.0 | gaps | 5.43 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 7500 | pass | 0 | 140 | 1712 / 2048 | 7498.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 7500 (#2) | pass | 0 | 71 | 1725 / 2048 | 7485.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 7500 (#3) | pass | 0 | 71 | 1345 / 2048 | 7498.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 7750 | drops | 4 063 934 | full | 2048 / 2048 | 7595.0 | gaps | 22.62 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 7750 (#2) | pass | 0 | 75 | 2019 / 2048 | 7740.4 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 7750 (#3) | drops | 2 138 | full | 2048 / 2048 | 7698.8 | gaps | 7.73 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8000 | drops | 694 954 | full | 2048 / 2048 | 7884.3 | gaps | 15.37 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8000 (#2) | drops | 921 493 | full | 2048 / 2048 | 7864.4 | gaps | 11.53 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8000 (#3) | drops | 8 382 827 | full | 2048 / 2048 | 7801.9 | gaps | 26.48 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8250 | drops | 3 224 092 | full | 2048 / 2048 | 8122.9 | gaps | 28.38 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8250 (#2) | drops | 19 427 116 | full | 2048 / 2048 | 7830.4 | gaps | 11.41 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8250 (#3) | drops | 17 162 979 | full | 2048 / 2048 | 7907.9 | gaps | 7.60 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8500 | drops | 19 944 174 | full | 2048 / 2048 | 8078.9 | gaps | 15.26 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8500 (#2) | drops | 14 509 010 | full | 2048 / 2048 | 8169.2 | gaps | 11.38 GB |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 8500 (#3) | drops | 7 657 227 | full | 2048 / 2048 | 8275.5 | gaps | 19.15 GB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4000 | pass | 0 | 67 | 995 / 2048 | 3989.3 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4000 (#2) | pass | 0 | 67 | 1015 / 2048 | 3999.5 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4000 (#3) | pass | 0 | 67 | 954 / 2048 | 4000.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4250 | pass | 0 | 67 | 1720 / 2048 | 4209.7 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4250 (#2) | drops | 1 833 363 | full | 2048 / 2048 | 4179.5 | gaps | 31.15 GB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4250 (#3) | pass | 0 | 67 | 1885 / 2048 | 4206.6 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4500 | drops | 31 352 260 | full | 2048 / 2048 | 4186.1 | gaps | 8.31 GB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4500 (#2) | drops | 29 650 444 | full | 2048 / 2048 | 4199.4 | gaps | 8.17 GB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4500 (#3) | drops | 23 921 116 | full | 2048 / 2048 | 4241.9 | gaps | 7.98 GB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4750 | drops | 61 320 236 | full | 2048 / 2048 | 4201.0 | gaps | 3.04 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6500 | pass | 0 | 70 | 55 / 1024 | 6500.1 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7000 | pass | 0 | 70 | 59 / 1024 | 6999.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7500 | pass | 0 | 71 | 62 / 1024 | 7500.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8000 | pass | 0 | 91 | 69 / 1024 | 7999.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8500 | pass | 0 | 146 | 75 / 1024 | 8492.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9000 | pass | 0 | 870 | 106 / 1024 | 8999.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9000 (#2) | pass | 0 | 878 | 113 / 1024 | 8999.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9000 (#3) | pass | 0 | 836 | 123 / 1024 | 8999.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9250 | pass | 0 | 3050 | 88 / 1024 | 9243.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9250 (#2) | pass | 0 | 2800 | 84 / 1024 | 9248.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9250 (#3) | pass | 0 | 4021 | 86 / 1024 | 9248.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9500 | drops | 452 063 | full | 102 / 1024 | 9481.2 | gaps | 1.53 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9500 (#2) | drops | 314 991 | full | 120 / 1024 | 9491.6 | gaps | 0.50 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9500 (#3) | drops | 213 982 | full | 124 / 1024 | 9491.6 | gaps | 2.90 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10000 | drops | 4 827 150 | full | 1024 / 1024 | 9753.0 | gaps | 0.01 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 6500 | pass | 0 | 70 | 60 / 1024 | 6500.1 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 7000 | pass | 0 | 70 | 62 / 1024 | 6999.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 7500 | pass | 0 | 71 | 69 / 1024 | 7500.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8000 | pass | 0 | 87 | 75 / 1024 | 7999.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8500 | pass | 0 | 151 | 74 / 1024 | 8500.7 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9000 | pass | 0 | 450 | 76 / 1024 | 8999.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9000 (#2) | pass | 0 | 405 | 97 / 1024 | 8999.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9000 (#3) | pass | 0 | 405 | 85 / 1024 | 8994.7 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9250 | pass | 0 | 821 | 85 / 1024 | 9248.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9250 (#2) | pass | 0 | 850 | 77 / 1024 | 9248.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9250 (#3) | pass | 0 | 2452 | 89 / 1024 | 9243.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9500 | drops | 580 | full | 104 / 1024 | 9491.6 | gaps | 5.38 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9500 (#2) | drops | 870 | full | 124 / 1024 | 9499.5 | gaps | 21.45 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9500 (#3) | pass | 0 | 3937 | 85 / 1024 | 9499.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 10000 | drops | 1 731 081 | full | 1024 / 1024 | 9817.1 | gaps | 0.04 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4500 | pass | 0 | 68 | 43 / 1024 | 4499.7 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5000 | pass | 0 | 68 | 647 / 1024 | 4949.5 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5000 (#2) | pass | 0 | 68 | 657 / 1024 | 4951.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5000 (#3) | pass | 0 | 68 | 602 / 1024 | 4953.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5250 | drops | 23 676 307 | full | 1024 / 1024 | 4951.0 | gaps | 9.40 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5250 (#2) | drops | 23 013 161 | full | 1024 / 1024 | 4953.8 | gaps | 9.66 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5250 (#3) | drops | 23 015 090 | full | 1024 / 1024 | 4953.8 | gaps | 9.88 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5500 | drops | 49 802 510 | full | 1024 / 1024 | 4956.0 | gaps | 5.63 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5500 (#2) | drops | 49 961 647 | full | 1024 / 1024 | 4951.7 | gaps | 5.56 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 5500 (#3) | drops | 49 626 115 | full | 1024 / 1024 | 4957.4 | gaps | 5.57 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6000 | drops | 103 319 688 | full | 1024 / 1024 | 4954.5 | gaps | 3.00 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 | pass | 0 | 135 | 36 / 1024 | 4499.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 | pass | 0 | 160 | 42 / 1024 | 5000.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#2) | pass | 0 | 1886 | 42 / 1024 | 5000.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#3) | pass | 0 | 880 | 38 / 1024 | 5000.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5250 | drops | 19 778 436 | full | 41 / 1024 | 5154.5 | gaps | 14.44 MB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 | drops | 71 845 314 | full | 39 / 1024 | 5154.5 | gaps | 4.64 MB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 (#2) | drops | 72 248 315 | full | 39 / 1024 | 5152.9 | gaps | 4.64 MB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 (#3) | drops | 72 257 865 | full | 40 / 1024 | 5152.9 | gaps | 4.65 MB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6000 | drops | 175 990 470 | full | 39 / 1024 | 5154.5 | gaps | 2.36 MB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3500 | pass | 0 | 134 | 775 / 2048 | 3495.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4000 | pass | 0 | 207 | 753 / 2048 | 4000.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4500 | pass | 0 | 136 | 1078 / 2048 | 4497.3 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5000 | pass | 0 | 191 | 759 / 2048 | 4999.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5000 (#2) | pass | 0 | 154 | 1463 / 2048 | 4964.6 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5000 (#3) | pass | 0 | 499 | 981 / 2048 | 5000.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5250 | drops | 19 772 248 | full | 1301 / 2048 | 5146.8 | gaps | 14.38 MB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5500 | drops | 71 844 901 | full | 963 / 2048 | 5154.5 | gaps | 4.38 MB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5500 (#2) | drops | 71 844 523 | full | 1198 / 2048 | 5124.5 | gaps | 4.35 MB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5500 (#3) | drops | 71 844 536 | full | 1129 / 2048 | 5136.0 | gaps | 4.33 MB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 6000 | drops | 176 083 912 | full | 2048 / 2048 | 5090.3 | gaps | 2.10 MB |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 5000 | pass | 0 | 159 | 1016 / 2048 | 5000.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 5000 (#2) | pass | 0 | 158 | 1474 / 2048 | 4973.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, `--qd 63` | 5000 (#3) | pass | 0 | 173 | 1005 / 2048 | 4996.3 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | pass | 0 | 132 | 83 / 2048 | 2500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 (#2) | pass | 0 | 132 | 584 / 2048 | 2499.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 (#3) | pass | 0 | 132 | 585 / 2048 | 2500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | pass | 0 | 133 | 682 / 2048 | 2746.4 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 (#2) | pass | 0 | 133 | 661 / 2048 | 2749.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 (#3) | pass | 0 | 133 | 615 / 2048 | 2743.7 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | drops | 47 101 184 | full | 2048 / 2048 | 2828.9 | gaps | 9.37 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (#2) | drops | 68 956 219 | full | 2048 / 2048 | 2775.9 | gaps | 7.64 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (#3) | drops | 78 914 540 | full | 2048 / 2048 | 2752.7 | gaps | 6.56 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3500 | drops | 256 012 917 | full | 2048 / 2048 | 2783.7 | gaps | 2.75 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk, `--qd 63` | 3000 | drops | 82 707 260 | full | 2048 / 2048 | 2742.9 | gaps | 1.23 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 | pass | 0 | 138 | 32 / 1024 | 2999.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (#2) | pass | 0 | 133 | 27 / 1024 | 2999.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (#3) | pass | 0 | 139 | 32 / 1024 | 2999.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3500 | drops | 143 686 427 | full | 1024 / 1024 | 3038.3 | gaps | 4.10 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3500 (#2) | drops | 143 887 375 | full | 1024 / 1024 | 3037.7 | gaps | 4.10 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3500 (#3) | drops | 143 899 833 | full | 1024 / 1024 | 3037.7 | gaps | 4.05 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4000 | drops | 317 874 316 | full | 1024 / 1024 | 3037.5 | gaps | 2.26 GB |

### Ring size

The ring absorbs the time an SSD takes to complete its writes: a recording drops beats when the
drives fall behind by more than the ring holds. The default ring is 512 MB (512 MB / chunk slots,
at most the hardware's 2048: 1024 × 512 KB with the 980 PRO, 2048 × 256 KB with the Sabrent).

| SSD | target | layout | ring | rate (MB/s) | recordings with drops | FIFO high-water (beats) | ring high-water (slots) |
|---|---|---|---|---|---|---|---|
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB | 2048 × 256 KB (512 MB, default) | 7750 | 0 of 3 | 80 / 75 / 77 | 1207 / 740 / 780 of 2048 |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB | 1024 × 256 KB (256 MB) | 7750 | **3 of 3** (first gaps 9.30 / 11.34 / 7.49 GB; 9.5-12.1 M beats) | full | 1024 of 1024 |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB, `--qd 63` | 2048 × 256 KB (512 MB, default) | 7500 | 0 of 3 | 140 / 71 / 71 | 1712 / 1725 / 1345 of 2048 |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 350 GiB past the cache | 2048 × 256 KB (512 MB, default) | 3250 | 0 of 1 | 66 | 399 of 2048 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB | 1024 × 512 KB (512 MB, default) | 9250 | 0 of 3 | 3050 / 2800 / 4021 | 88 / 84 / 86 of 1024 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB | 512 × 512 KB (256 MB) | 9250 | 0 of 3 | 4072 / 3758 / 3552 | 86 / 110 / 82 of 512 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB, `--qd 63` | 1024 × 512 KB (512 MB, default) | 9250 | 0 of 3 | 821 / 850 / 2452 | 85 / 77 / 89 of 1024 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 350 GiB past the cache | 1024 × 512 KB (512 MB, default) | 3250 | 0 of 1 | 66 | 330 of 1024 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 350 GiB past the cache | 1024 × 512 KB (512 MB, default) | 3500 | 1 of 1 (from 324.32 GB) | full | 1024 of 1024 |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | RAID0, 32 GB | 2048 × 256 KB (512 MB, default) | 5000 | 0 of 3 | 191 / 154 / 499 | 759 / 1463 / 981 of 2048 |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | RAID0, 32 GB, `--qd 63` | 2048 × 256 KB (512 MB, default) | 5000 | 0 of 3 | 159 / 158 / 173 | 1016 / 1474 / 1005 of 2048 |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | RAID0, 32 GB | 1024 × 256 KB (256 MB) | 5000 | **3 of 3** (first gaps 12.31 / 20.09 / 29.29 GB; 2.1-4.4 M beats) | full | 1024 of 1024 |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | RAID0, 350 GiB past the cache | 2048 × 256 KB (512 MB, default) | 3250 | 0 of 1 | 203 | 477 of 2048 (646 at 3000 MB/s) |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0, 32 GB | 1024 × 512 KB (512 MB, default) | 5000 | 0 of 3 | 160 / 1886 / 880 | 42 / 42 / 38 of 1024 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0, 32 GB | 512 × 512 KB (256 MB) | 5000 | 0 of 3 | 195 / 160 / 166 | 43 / 40 / 38 of 512 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0, 350 GiB past the cache | 1024 × 512 KB (512 MB, default) | 3500 | 0 of 1 | 183 | **573 of 1024 (287 MB: more than a 256 MB ring holds)** |

The 980 PRO pairs need little ring inside their cache: a 256 MB ring is as clean as the 512 MB
default at the RAID0 top on both boards (at most 110 slots of 512 KB). **The Sabrent pair does
not**: on `zcu106_hpc0` it used up to 369 MB of the default ring at 5000 MB/s, and a 256 MB ring
dropped in 3 of 3 runs, late in the 32 GB recording (12-29 GB); on `vck190_fmcp1` it used up to
1207 of 2048 slots at 7750 MB/s (1725 at 7500 MB/s with `--qd 63`), and a 256 MB ring dropped in
3 of 3 runs at 7750 MB/s (first gaps 7.5-11.3 GB). Past the cache the 512 MB
ring is also what keeps the 980 PRO pair clean at 3500 MB/s on `zcu106_hpc0` (287 MB in use).
With 256 KB chunks the 512 MB default is also the largest ring the hardware's 2048 slots allow.
See [Ring size and CMA](apps.md#ring-size-and-cma).

### Burst and 40 GB recordings

Single recordings at a fixed rate on a freshly deallocated volume after 60 s of idle time:
10 GiB and 40 GiB at the highest clean step of the 32 GB sweep and once at its first failing step
(with the Sabrent pair on `vck190_fmcp1` the 40 GiB recording also one step lower, at
7500 MB/s). "Burst" rows are the 10 GiB recordings; the 40 GiB
rows are still inside the SLC caches of these drives.

| target | SSD | layout | recording | rate (MB/s) | result | FIFO high-water (beats) | ring high-water (slots) | max in flight per SSD | latency avg (µs) | latency max (µs) |
|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GiB | 7750 | pass | 71 | 1820 / 2048 | 32 | 1240 | 18876 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GiB | 8000 | pass | 95 | 362 / 2048 | 32 | 1036 | 9486 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GiB | 7500 | pass | 74 | 1840 / 2048 | 32 | 1007 | 19218 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GiB | 7750 | drops from 39.01 GB (1 063 503 beats) | full | 2048 / 2048 | 32 | 1253 | 21487 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GiB | 8000 | drops from 26.62 GB (2 144 134 beats) | full | 2048 / 2048 | 32 | 1366 | 23116 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GiB | 4000 | pass | 67 | 955 / 2048 | 32 | 1323 | 19418 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GiB | 4250 | pass | 67 | 675 / 2048 | 32 | 1539 | 18267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GiB | 4000 | pass | 67 | 986 / 2048 | 32 | 1343 | 20698 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GiB | 4250 | drops from 27.22 GB (4 778 715 beats) | full | 2048 / 2048 | 32 | 1980 | 22284 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GiB | 9250 | pass | 2286 | 80 / 1024 | 32 | 585 | 4458 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GiB | 9500 | drops from 1.94 GB (124 196 beats) | full | 89 / 1024 | 32 | 972 | 4284 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GiB | 9250 | pass | 3677 | 126 / 1024 | 32 | 631 | 7039 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GiB | 9500 | drops from 2.33 GB (472 382 beats) | full | 98 / 1024 | 32 | 1098 | 4573 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GiB | 5000 | pass | 68 | 185 / 1024 | 32 | 3047 | 7736 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GiB | 5250 | drops from 9.74 GB (942 184 beats) | full | 1024 / 1024 | 32 | 3317 | 7919 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GiB | 5000 | pass | 68 | 830 / 1024 | 32 | 3373 | 10293 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GiB | 5250 | drops from 9.32 GB (31 133 705 beats) | full | 1024 / 1024 | 32 | 3372 | 8071 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GiB | 5000 | pass | 151 | 37 / 1024 | 18 | 265 | 3690 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GiB | 5500 | drops from 4.65 MB (5147.4 MB/s written) | full | 39 / 1024 | 19 | 291 | 3818 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GiB | 5000 | pass | 187 | 40 / 1024 | 20 | 268 | 3995 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GiB | 5500 | drops from 4.44 MB (5154.8 MB/s written) | full | 40 / 1024 | 20 | 300 | 3913 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GiB | 5000 | pass | 159 | 716 / 2048 | 32 | 814 | 16056 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GiB | 5500 | drops from 4.39 MB (5098.5 MB/s written) | full | 899 / 2048 | 32 | 1292 | 15463 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GiB | 5000 | pass | 1317 | 1323 / 2048 | 32 | 1279 | 20781 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GiB | 5500 | drops from 4.39 MB (5134.4 MB/s written) | full | 1423 / 2048 | 32 | 1550 | 20476 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GiB | 2750 | pass | 133 | 470 / 2048 | 32 | 2167 | 19023 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GiB | 3000 | drops from 8.26 GB (2807.9 MB/s written) | full | 2048 / 2048 | 32 | 2952 | 20204 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GiB | 2750 | pass | 133 | 655 / 2048 | 32 | 2320 | 19447 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GiB | 3000 | drops from 8.32 GB (2782.4 MB/s written) | full | 2048 / 2048 | 32 | 3006 | 21495 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GiB | 3000 | pass | 133 | 32 / 1024 | 31 | 1154 | 5246 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GiB | 3500 | drops from 4.06 GB (3038.3 MB/s written) | full | 1024 / 1024 | 32 | 5489 | 9592 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GiB | 3000 | pass | 151 | 31 / 1024 | 30 | 1072 | 5173 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GiB | 3500 | drops from 4.10 GB (3038.1 MB/s written) | full | 1024 / 1024 | 32 | 5514 | 9900 |

* On `zcu106_hpc0` the bursts give the 32 GB results with both pairs: one 980 PRO 3000 MB/s
  (3500 MB/s writes 3038 MB/s), one Sabrent 2750 MB/s (3000 MB/s drops from 8.26-8.32 GB,
  writing 2782-2808 MB/s), RAID0 5000 MB/s (5500 MB/s drops from the first ring pass:
  `S_AXI_HP2_FPD`).
* On `vck190_fmcp1` the Sabrent RAID0 records 10 GiB at 8000 MB/s (2 of 3 over 32 GB) and
  40 GiB at 7500 MB/s, one step below its 32 GB top (7750 MB/s drops from 39.01 GB, 8000 MB/s
  from 26.62 GB); one Sabrent records 10 GiB at 4250 MB/s and 40 GiB at 4000 MB/s (4250 MB/s
  drops from 27.22 GB). The 980 PRO RAID0 gains nothing from a shorter
  recording: at 9500 MB/s the ingest FIFO overflows within the first 2-2.3 GB with the ring
  nearly empty (PS DDR). One 980 PRO records 10 and 40 GiB at 5000 MB/s, ring-assisted (40 GiB
  used 830 of 1024 slots); 5250 MB/s drops after 9.3-9.7 GB.

### Long recordings past the SLC cache

A 32 GB or 40 GB recording stays inside the SLC cache of these 1 TB drives, so the rate that
holds for a long recording was measured with single recordings of 1.5 to 3 times the cache
(see [The SLC cache](#the-slc-cache) for the drives' cache sizes and post-cache rates): 200 GiB
on one drive and 350 GiB on RAID0, on a freshly deallocated volume after 300 s of idle time,
`nvverify` of the whole file.

| target | SSD | layout | size | pre-idle (s) | rate (MB/s) | result | drops (beats) | NVMe errors | ring high-water (slots) | latency avg / max (µs) | nvverify | first gap | max drive temp. (°C) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 350 GiB | 300 | 3250 | pass | 0 | 0 | 399 / 2048 | 1087 / 26132 | pass | - | 58 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 200 GiB | 300 | 1500 | pass | 0 | 0 | 345 / 2048 | 489 / 26407 | pass | - | 54 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 300 | 3250 | pass | 0 | 0 | 330 / 1024 | 646 / 41144 | pass | - | 44 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 300 | 3500 | drops | 1 213 311 | 0 | 1024 / 1024 | 1850 / 69021 | gaps | 324.32 GB | 45 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GiB | 300 | 1750 | pass | 0 | 0 | 127 / 1024 | 2166 / 37595 | pass | - | 45 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 300 | 3250 | pass | 0 | 0 | 344 / 1024 | 739 / 40450 | pass | - | 47 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 300 | 3500 | pass | 0 | 0 | 573 / 1024 | 1971 / 45970 | pass | - | 47 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 300 | 3750 | drops | 262 588 557 | 0 | 1024 / 1024 | 2099 / 46032 | gaps | 253.59 GB | 48 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 350 GiB | 300 | 3000 | pass | 0 | 0 | 646 / 2048 | 585 / 29546 | pass | - | 61 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 350 GiB | 300 | 3250 | pass | 0 | 0 | 477 / 2048 | 1195 / 25379 | pass | - | 63 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 350 GiB | 300 | 3500 | drops | 141 782 930 | 0 | 2048 / 2048 | 2382 / 20679 | gaps | 159.45 GB | 64 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 200 GiB | 300 | 1500 | pass | 0 | 0 | 153 / 2048 | 449 / 26552 | pass | - | 57 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 200 GiB | 300 | 1750 | drops | 40 920 596 | 0 | 2048 / 2048 | 3427 / 24896 | gaps | 104.16 GB | 60 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk, `--qd 63` | 200 GiB | 300 | 1750 | drops | 15 886 005 | 0 | 2048 / 2048 | 6619 / 25145 | gaps | 150.14 GB | 60 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GiB | 300 | 1750 | pass | 0 | 0 | 180 / 1024 | 2499 / 42853 | pass | - | 45 |

* **One 980 PRO: 1750 MB/s** over 200 GiB on both boards (~1.8 times the ~120 GB cache), at the
  drive's post-cache rate of ~1.77 GB/s (about 1 % margin): ring high-water 127-180 slots,
  latency up to 37.6-42.9 ms past the cache.
* **980 PRO RAID0: 3500 MB/s** over 350 GiB on `zcu106_hpc0` (3250 MB/s as well; 3750 MB/s drops
  from 253.59 GB, where the pair's ~245 GB cache ends), **3250 MB/s** on `vck190_fmcp1`, where
  3500 MB/s held for ~80 GB past the cache and then ran out of ring at 324.32 GB (3494.7 MB/s
  written): the pair writes ~3.46-3.5 GB/s after its cache, so 3500 MB/s is its edge. At
  3500 MB/s on `zcu106_hpc0` the ring peaked at 573 slots (287 MB).
* **One Sabrent: 1500 MB/s** over 200 GiB on both boards; 1750 MB/s drops past the cache
  (first gaps at 104.16 GB on `zcu106_hpc0` and 94.9 GB on `vck190_fmcp1`, the latter on the
  256-bit build), writing 1735.2 and 1729.7 MB/s: past its cache one Sabrent writes ~1.73 GB/s
  with `nvrec`'s commands, on Gen3 x4 as on Gen4 x4, below the ~1.8 GB/s that fio measures on
  the same drives. 63 commands in flight do not lift it (1741.8 MB/s at `--qd 63`).
* **Sabrent RAID0: 3250 MB/s** over 350 GiB on both boards (3000 MB/s as well on
  `zcu106_hpc0`); 3500 MB/s drops from 159.45 GB (`zcu106_hpc0`, 3453.6 MB/s written) and from
  149.9 GB (`vck190_fmcp1`, 256-bit build, 3389.3 MB/s): the pair's ~140 GB cache has ended.
* `nvrec` took 0.11-0.37 % of one core over these 2-minute recordings.

### Playback

10 GiB recording made at 1000 MB/s with 0 drops, `nvplay` in 500 MB/s steps from the floor as in
the [playback method](#playback), then the top confirmed with a 40 GiB file. "The SSDs deliver"
is the SSDs' own rate at the first 10 GiB step with underflows: 95 % of its streaming rate (the
rest came from the prefilled 512 MB ring). **The last column, the 40 GiB figure, is the
sustained playback rate**; a 10 GiB step above it is ring-assisted.

| target | SSD | layout | highest clean step, 10 GiB file | clean runs | first step with underflows | the SSDs deliver | sustained playback rate (40 GiB file) |
|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **8750 MB/s** | 3/3 (every step from 7750 MB/s clean except 8250 MB/s: 1 of 3, short underflows) | 9000 MB/s (0 of 3; 2163-5365 ticks at 9000.4 MB/s, 1 064 463 at 8940.4) | ~8.6 GB/s at a 9250 MB/s sink (9099.5 MB/s streamed, 2.79 M ticks) | **7500 MB/s** (3 of 3; 7750-8750 MB/s 0-2 of 3, short underflows at the requested rate) |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4750 MB/s (ring-assisted) | 3/3 | 5000 MB/s (0 of 3; 7 689 560-8 287 509 ticks, 4764-4781 MB/s streamed) | ~4.54 GB/s | **4500 MB/s** (3 of 3; 4750 MB/s 0 of 4, 4590-4598 MB/s streamed) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **8750 MB/s** | 3/3 (every step from 8000 MB/s clean; the same at `--qd 63`) | 9000 MB/s (0 of 3; 8918-8978 MB/s streamed) | ~8.5 GB/s at a 9000 MB/s sink (PS DDR shared with the ring reader) | **8750 MB/s** (3 of 3) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6250 MB/s (ring-assisted) | 3/3 | 6500 MB/s (0 of 3; 6487.9 MB/s streamed) | ~6.2-6.3 GB/s | **6000 MB/s** (3 of 3; 6250 MB/s 2 of 3) |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **4500 MB/s** | 3/3 (4750 MB/s 2 of 3) | 5000 MB/s (0 of 3; 4885-4896 MB/s streamed) | ~4.64-4.65 GB/s | **4500 MB/s** (4750 MB/s: 22 390 ticks) |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3250 MB/s (ring-assisted) | 3/3 | 3500 MB/s (0 of 3; 3352.3 MB/s streamed) | ~3.185 GB/s | **3000 MB/s** (3250 MB/s underflows, 3225.6 MB/s) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4750 MB/s (ring-assisted) | 3/3 | 5000 MB/s (0 of 3; 4874.0 MB/s streamed) | ~4.63 GB/s | **4250 MB/s** (3 of 3; 4500 MB/s 2 of 5, 14 693-29 880 ticks; 4750 MB/s 0 of 2) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3250 MB/s (ring-assisted) | 3/3 | 3500 MB/s (0 of 3; 3352-3354 MB/s streamed) | ~3.19 GB/s | **3000 MB/s** (3 of 3; 3250 MB/s underflows 2 of 2, 3229.0-3229.2 MB/s) |

The 40 GiB confirmations (40 GiB recorded at 1000 MB/s with 0 drops and verified, then played
per rate; 1-5 runs per rate, the count is in the result column):

| target | SSD | layout | rate (MB/s) | result | underflow ticks | streaming MB/s | read latency avg / max (µs) |
|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8750 | clean 3 of 3 | 0 | 8749.2 | 193-196 / 3663-3896 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6250 | clean 2 of 3 | 232 138 (one run) | 6248.1-6249.9 | 2703-2705 / 4148-4199 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6000 | clean 3 of 3 | 0 | 6000.2 | 381-1037 / 3251-3556 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8750 | clean 0 of 3 | 142 216-391 273 | 8745.6-8747.4 | 360-370 / 2561-2689 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8500 | clean 2 of 3 | 177 864 (one run) | 8499.8 | 255-256 / 2552-2638 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8250 | clean 1 of 3 | 50 989 / 54 960 | 8250.0 | 222-223 / 2478-2771 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 | clean 2 of 3 | 29 076 (one run) | 7999.6 | 212 / 2333-2545 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7750 | clean 1 of 4 | 2362-4495 (three runs) | 7749.8 | 207 / 2415-2530 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7500 | clean 3 of 3 | 0 | 7499.5 | 202-203 / 2434-2529 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4750 | clean 0 of 4 | 22 281 402-23 385 543 | 4590.1-4597.5 | 1845-1848 / 2783-3485 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4500 | clean 3 of 3 | 0 | 4500.2 | 637-661 / 2493-2633 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4750 | underflows (1 run) | 22 390 | 4749.9 | 194 / 3313 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4500 | clean (1 run) | 0 | 4499.9 | 192 / 3293 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3250 | underflows (1 run) | 10 113 564 | 3225.6 | 2623 / 3603 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | clean (1 run) | 0 | 2999.9 | 215 / 3180 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 | underflows | 35 416 593 | 4871.4 | 238 / 10 492 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4750 | underflows 2 of 2 | 254 151-296 143 | 4749.0 | 238 / 8991-10 189 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 | clean 2 of 5 | 14 693-29 880 (three runs) | 4500.0 | 236-239 / 9130-11 071 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4250 | clean 3 of 3 | 0 | 4250.0 | 235-237 / 9737-10 819 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3250 | underflows 2 of 2 | 8 641 229 / 8 690 731 | 3229.0-3229.2 | 5238-5246 / 10 317-10 456 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 | clean 3 of 3 | 0 | 3000.0 | 238 / 9912-9982 |

* **`vck190_fmcp1`, 980 PRO RAID0: 8750 MB/s** for any length (40 GiB 3 of 3; 10 GiB 3 of 3 at
  `--qd 32` and `--qd 63`). At 9000 MB/s the stream falls to 8.92-8.98 GB/s: with the SSDs
  writing DDR while the ring reader streams it, the two share the DDR controller (not the links:
  2 × 6.3 GB/s; not the fabric: 13 750 MB/s ring-resident; `nvplay` 5.2 % of a core). **No short
  underflows with this pair**: every step from 8000 to 8750 MB/s was clean 3 of 3, and the first
  failing step is a steady rate deficit (1.2-1.6 M ticks).
* **`vck190_fmcp1`, one 980 PRO: 6000 MB/s** sustained, 6250 MB/s for a 10 GiB file: the Gen4 x4
  link at MaxPayload 128 bytes (~6.25-6.3 GB/s, read latency 2.7 ms with 32 × 512 KB in flight);
  6750 MB/s at MaxPayload 256 bytes ([MaxPayload 256](#maxpayload-256)).
* **`vck190_fmcp1`, Sabrent RAID0: 7500 MB/s** sustained (40 GiB 3 of 3), **8750 MB/s** for a
  10 GiB file (3 of 3). Between them the stream keeps the requested rate (8749.8 MB/s at
  8750 MB/s over 40 GiB) but short underflows (2362-391 273 ticks of 4 ns, i.e. 9 µs-1.6 ms in
  total per file) appear in some runs, more often the longer the file, with the ring full and the
  SSDs' read latency at most 3.1 ms. The 980 PRO pair does not show them on the same image; an
  earlier build with a 128 KB egress FIFO showed them with the Sabrents from 8250 MB/s on a
  10 GiB file. The cause was not isolated. The steady rate deficit starts at 9000-9250 MB/s.
* **`vck190_fmcp1`, one Sabrent: 4500 MB/s** sustained (40 GiB 3 of 3): one Sabrent reads its
  data at ~4.54 GB/s, so 4750 MB/s is clean only for a 10 GiB file, thanks to the prefilled ring
  (a 40 GiB file streams 4590-4598 MB/s at 4750 MB/s).
* **`zcu106_hpc0`, RAID0: 4250 MB/s** sustained with the 980 PRO pair (40 GiB 3 of 3; 4500 MB/s
  2 of 5, short of data for 0.06-0.12 ms in the failing runs) and **4500 MB/s** with the Sabrent
  pair (40 GiB, 1 run); for a 10 GiB file 4750 MB/s with the 980 PROs (3 of 3, ring-assisted) and
  4500 MB/s with the Sabrents (4750 MB/s 2 of 3). Both pairs deliver the same ~4.63-4.69 GB/s
  while the ring reader streams the ring, although they fill the ring at ~6.3 GB/s in the
  prefill: the limit is the mix of SSD writes and ring reads in DDR, not the drives (see
  [Ceilings at a glance](#zynq-ultrascale-zcu106_hpc0-uzev)). Not the fabric (ring-resident
  playback is clean at 5000 MB/s), not software (`nvplay` 4.6-5.0 % of a core).
* **`zcu106_hpc0`, one drive: 3000 MB/s** sustained with either drive: the Gen3 x4 slot reads
  ~3.19 GB/s at MaxPayload 128 bytes; 3250 MB/s is clean for a 10 GiB file because the deficit
  (~210 MB) fits in the prefilled ring, and a 40 GiB file underflows there. At MaxPayload 256
  bytes one drive plays 3500 MB/s, over 40 GiB too ([MaxPayload 256](#maxpayload-256)).
* Every playback had 0 checker errors and 0 gaps; read latency at most 8-11 ms (980 PRO) and
  2.9-3.6 ms (Sabrent) on `zcu106_hpc0`, 2.3-3.1 ms (Sabrent) and 3.6-6.8 ms (980 PRO, the
  higher figures at `--qd 63`) on `vck190_fmcp1`.

Every playback step (10 GiB file):

| target | SSD | layout | rate (MB/s) | result | underflow ticks | checker errors | streaming MB/s | prefill (s) | ring high-water (slots) | read latency avg (µs) | read latency max (µs) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 7750 | clean | 0 | 0 | 7747.1 | 0.062 | 2048 / 2048 | 281 | 2969 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 | clean | 0 | 0 | 8001.1 | 0.062 | 2048 / 2048 | 286 | 2386 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 (#2) | clean | 0 | 0 | 8001.1 | 0.06 | 2048 / 2048 | 270 | 2383 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8000 (#3) | clean | 0 | 0 | 8001.1 | 0.06 | 2048 / 2048 | 271 | 2595 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8250 | underflows | 63 769 | 0 | 8246.9 | 0.062 | 2048 / 2048 | 298 | 2638 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8250 (#2) | clean | 0 | 0 | 8246.9 | 0.06 | 2048 / 2048 | 277 | 2554 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8250 (#3) | underflows | 57 728 | 0 | 8246.9 | 0.06 | 2048 / 2048 | 281 | 2637 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8500 | clean | 0 | 0 | 8501.5 | 0.061 | 2048 / 2048 | 332 | 2362 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8500 (#2) | clean | 0 | 0 | 8501.5 | 0.06 | 2048 / 2048 | 309 | 2550 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8500 (#3) | clean | 0 | 0 | 8501.5 | 0.06 | 2048 / 2048 | 311 | 2779 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8750 | clean | 0 | 0 | 8751.0 | 0.062 | 2048 / 2048 | 430 | 2378 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8750 (#2) | clean | 0 | 0 | 8751.0 | 0.061 | 2048 / 2048 | 432 | 2289 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8750 (#3) | clean | 0 | 0 | 8751.0 | 0.062 | 2048 / 2048 | 427 | 3056 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 9000 | underflows | 5 365 | 0 | 9000.4 | 0.062 | 2048 / 2048 | 702 | 2693 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 9000 (#2) | underflows | 2 163 | 0 | 9000.4 | 0.062 | 2048 / 2048 | 744 | 2752 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 9000 (#3) | underflows | 1 064 463 | 0 | 8940.4 | 0.061 | 2048 / 2048 | 652 | 2441 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 9250 | underflows | 2 792 785 | 0 | 9099.5 | 0.062 | 2048 / 2048 | 1210 | 2714 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4500 | clean | 0 | 0 | 4500.2 | 0.118 | 2048 / 2048 | 679 | 2532 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4750 | clean | 0 | 0 | 4749.0 | 0.119 | 2048 / 2048 | 1839 | 2731 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4750 (#2) | clean | 0 | 0 | 4749.0 | 0.119 | 2048 / 2048 | 1837 | 2671 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4750 (#3) | clean | 0 | 0 | 4749.0 | 0.119 | 2048 / 2048 | 1842 | 2671 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 5000 | underflows | 7 834 289 | 0 | 4776.4 | 0.12 | 2048 / 2048 | 1842 | 2720 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 5000 (#2) | underflows | 7 689 560 | 0 | 4780.7 | 0.119 | 2048 / 2048 | 1840 | 2712 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 5000 (#3) | underflows | 8 287 509 | 0 | 4763.7 | 0.12 | 2048 / 2048 | 1847 | 2680 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 5250 | underflows | 16 907 090 | 0 | 4770.1 | 0.12 | 2048 / 2048 | 1847 | 2696 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8000 | clean | 0 | 0 | 8001.1 | 0.044 | 1024 / 1024 | 281 | 3891 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8250 | clean | 0 | 0 | 8246.9 | 0.044 | 1024 / 1024 | 276 | 3655 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8500 | clean | 0 | 0 | 8501.5 | 0.044 | 1024 / 1024 | 288 | 3569 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8750 | clean | 0 | 0 | 8751.0 | 0.044 | 1024 / 1024 | 284 | 3608 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8750 (#2) | clean | 0 | 0 | 8751.0 | 0.044 | 1024 / 1024 | 283 | 3832 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8750 (#3) | clean | 0 | 0 | 8751.0 | 0.044 | 1024 / 1024 | 281 | 3711 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9000 | underflows | 343 232 | 0 | 8977.8 | 0.044 | 1024 / 1024 | 1320 | 3856 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9000 (#2) | underflows | 1 531 905 | 0 | 8918.1 | 0.044 | 1024 / 1024 | 308 | 3611 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9000 (#3) | underflows | 1 491 444 | 0 | 8918.1 | 0.044 | 1024 / 1024 | 308 | 3732 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 9250 | underflows | 5 015 753 | 0 | 8977.8 | 0.044 | 1024 / 1024 | 949 | 3974 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8000 | clean | 0 | 0 | 8001.1 | 0.044 | 1024 / 1024 | 394 | 6316 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8250 | clean | 0 | 0 | 8246.9 | 0.044 | 1024 / 1024 | 403 | 6410 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8500 | clean | 0 | 0 | 8501.5 | 0.044 | 1024 / 1024 | 407 | 6399 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8750 | clean | 0 | 0 | 8751.0 | 0.044 | 1024 / 1024 | 404 | 6296 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8750 (#2) | clean | 0 | 0 | 8751.0 | 0.044 | 1024 / 1024 | 409 | 6494 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 8750 (#3) | clean | 0 | 0 | 8751.0 | 0.044 | 1024 / 1024 | 410 | 6736 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9000 | underflows | 1 412 192 | 0 | 8925.5 | 0.044 | 1024 / 1024 | 427 | 6815 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9000 (#2) | underflows | 1 588 498 | 0 | 8918.1 | 0.044 | 1024 / 1024 | 428 | 6668 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9000 (#3) | underflows | 1 202 586 | 0 | 8933.0 | 0.044 | 1024 / 1024 | 458 | 6470 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, `--qd 63` | 9250 | underflows | 5 753 199 | 0 | 8940.4 | 0.044 | 1024 / 1024 | 422 | 6642 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6000 | clean | 0 | 0 | 5998.6 | 0.085 | 1024 / 1024 | 317 | 3721 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6250 | clean | 0 | 0 | 6250.0 | 0.085 | 1024 / 1024 | 2662 | 4263 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6250 (#2) | clean | 0 | 0 | 6250.0 | 0.085 | 1024 / 1024 | 2665 | 4039 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6250 (#3) | clean | 0 | 0 | 6250.0 | 0.085 | 1024 / 1024 | 2671 | 4223 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6500 | underflows | 290 313 | 0 | 6487.9 | 0.085 | 1024 / 1024 | 2699 | 4152 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6500 (#2) | underflows | 314 959 | 0 | 6487.9 | 0.085 | 1024 / 1024 | 2701 | 4105 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6500 (#3) | underflows | 274 512 | 0 | 6487.9 | 0.085 | 1024 / 1024 | 2698 | 4081 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 6750 | underflows | 6 461 824 | 0 | 6499.6 | 0.085 | 1024 / 1024 | 2701 | 4038 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4000 | clean | 0 | 0 | 4000.5 | 0.085 | 1024 / 1024 | 424 | 10317 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 | clean | 0 | 0 | 4500.2 | 0.085 | 1024 / 1024 | 426 | 10478 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 (#2) | clean | 0 | 0 | 4500.2 | 0.085 | 1024 / 1024 | 425 | 9699 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 (#3) | clean | 0 | 0 | 4500.2 | 0.085 | 1024 / 1024 | 426 | 8910 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4750 | clean | 0 | 0 | 4749.0 | 0.085 | 1024 / 1024 | 423 | 10220 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4750 (#2) | clean | 0 | 0 | 4749.0 | 0.085 | 1024 / 1024 | 435 | 9422 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4750 (#3) | clean | 0 | 0 | 4749.0 | 0.085 | 1024 / 1024 | 436 | 9182 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 | underflows | 8 658 314 | 0 | 4874.0 | 0.085 | 1024 / 1024 | 421 | 10039 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#2) | underflows | 8 667 142 | 0 | 4874.0 | 0.085 | 1024 / 1024 | 416 | 11190 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#3) | underflows | 8 725 723 | 0 | 4874.0 | 0.085 | 1024 / 1024 | 420 | 11386 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 | underflows | 42 996 140 | 0 | 4876.2 | 0.085 | 1024 / 1024 | 419 | 9346 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3500 | clean | 0 | 0 | 3499.8 | 0.085 | 2048 / 2048 | 280 | 3288 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4000 | clean | 0 | 0 | 4000.5 | 0.085 | 2048 / 2048 | 281 | 3200 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4500 | clean | 0 | 0 | 4500.2 | 0.085 | 2048 / 2048 | 283 | 3180 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4500 (#2) | clean | 0 | 0 | 4500.2 | 0.085 | 2048 / 2048 | 283 | 3190 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4500 (#3) | clean | 0 | 0 | 4500.2 | 0.085 | 2048 / 2048 | 283 | 3347 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4750 | clean | 0 | 0 | 4749.0 | 0.085 | 2048 / 2048 | 284 | 3343 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4750 (#2) | clean | 0 | 0 | 4749.0 | 0.085 | 2048 / 2048 | 284 | 3190 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4750 (#3) | underflows | 164 005 | 0 | 4746.9 | 0.085 | 2048 / 2048 | 284 | 3189 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5000 | underflows | 7 943 563 | 0 | 4885.1 | 0.085 | 2048 / 2048 | 285 | 3354 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5000 (#2) | underflows | 7 053 604 | 0 | 4896.2 | 0.085 | 2048 / 2048 | 286 | 3327 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5000 (#3) | underflows | 7 067 966 | 0 | 4896.2 | 0.085 | 2048 / 2048 | 286 | 3236 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 5500 | underflows | 41 184 383 | 0 | 4898.5 | 0.085 | 2048 / 2048 | 285 | 3244 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.169 | 2048 / 2048 | 306 | 3145 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (#2) | clean | 0 | 0 | 3000.1 | 0.169 | 2048 / 2048 | 306 | 3325 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (#3) | clean | 0 | 0 | 3000.1 | 0.169 | 2048 / 2048 | 306 | 3278 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3250 | clean | 0 | 0 | 3249.8 | 0.169 | 2048 / 2048 | 2591 | 3579 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3250 (#2) | clean | 0 | 0 | 3249.8 | 0.169 | 2048 / 2048 | 2591 | 3553 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3250 (#3) | clean | 0 | 0 | 3249.8 | 0.169 | 2048 / 2048 | 2590 | 3534 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3500 | underflows | 14 742 185 | 0 | 3352.3 | 0.169 | 2048 / 2048 | 2623 | 3586 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3500 (#2) | underflows | 14 761 756 | 0 | 3352.3 | 0.169 | 2048 / 2048 | 2623 | 3474 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3500 (#3) | underflows | 14 760 567 | 0 | 3352.3 | 0.169 | 2048 / 2048 | 2623 | 3490 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4000 | underflows | 64 790 048 | 0 | 3352.3 | 0.169 | 2048 / 2048 | 2628 | 3570 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.169 | 1024 / 1024 | 431 | 10714 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (#2) | clean | 0 | 0 | 3000.1 | 0.169 | 1024 / 1024 | 430 | 10006 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (#3) | clean | 0 | 0 | 3000.1 | 0.169 | 1024 / 1024 | 430 | 10008 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3250 | clean | 0 | 0 | 3249.8 | 0.169 | 1024 / 1024 | 5210 | 11394 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3250 (#2) | clean | 0 | 0 | 3249.8 | 0.169 | 1024 / 1024 | 5208 | 9616 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3250 (#3) | clean | 0 | 0 | 3249.8 | 0.169 | 1024 / 1024 | 5210 | 9500 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3500 | underflows | 14 540 019 | 0 | 3354.4 | 0.169 | 1024 / 1024 | 5246 | 9674 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3500 (#2) | underflows | 14 807 309 | 0 | 3352.3 | 0.169 | 1024 / 1024 | 5247 | 10932 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3500 (#3) | underflows | 14 716 138 | 0 | 3353.3 | 0.169 | 1024 / 1024 | 5246 | 11043 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4000 | underflows | 64 721 426 | 0 | 3353.3 | 0.169 | 1024 / 1024 | 5252 | 9214 |

### MaxPayload 256

PCIe MaxPayload is 128 bytes on every Root Port and SSD by default (the kernel's setting). With
`setpci` it can be raised to 256 bytes on both Root Ports and both SSDs (Root Ports first, SSDs
first when lowering it again; MaxReadReq stays at 512 bytes), until the next reboot:

```
for d in $(lspci -D | awk '/PCI bridge/{print $1}') $(lspci -D | awk '/Non-Volatile/{print $1}'); do
    sudo setpci -s $d CAP_EXP+8.w=0020:00e0    # Device Control bits 7:5 = 001: MaxPayload 256 bytes
done
```

| measurement (`zcu106_hpc0`, Gen3 x4) | MaxPayload 128 (default) | MaxPayload 256 |
|---|---|---|
| one 980 PRO, 32 GB recording | 3000 MB/s (3 of 3; 3500 MB/s drops, writing 3038 MB/s) | **3250 MB/s** (3 of 3; 3500 MB/s drops, writing 3362.3 MB/s, first gap at 14.03 GB) |
| one 980 PRO, 10 GiB playback | 3000 MB/s sustained, 3250 MB/s ring-assisted (3500 MB/s underflows: ~3.19 GB/s delivered) | **3500 MB/s** (3 of 3; 3750 MB/s underflows, 3728.3 MB/s streamed: ~3.54 GB/s delivered) |
| one 980 PRO, 40 GiB playback (sustained) | 3000 MB/s (3 of 3; 3250 MB/s underflows) | **3500 MB/s** (clean, as 3000 and 3250 MB/s; 1-2 runs per rate) |
| 980 PRO RAID0, 10 GiB playback | 4500 and 4750 MB/s clean 3 of 3 | **worse**: 4500 MB/s clean 1 of 3 (7506 and 3103 underflow ticks), 4750 MB/s 1 of 3 (221 946 and 250 680 ticks) |
| one Sabrent, 32 GB recording | 2750 MB/s (3 of 3; 3000 MB/s drops, writing 2752.7-2828.9 MB/s) | **3000 MB/s** (3 of 3; 3250 MB/s drops, writing 3009.8 MB/s, first gap at 8.01 GB) |
| one Sabrent, 10 GiB playback | 3000 MB/s sustained, 3250 MB/s ring-assisted (3500 MB/s underflows: ~3.185 GB/s delivered) | **3500 MB/s** (3 of 3; 3750 MB/s underflows, 3732.2 MB/s streamed: ~3.55 GB/s delivered) |

| measurement (`vck190_fmcp1`, Gen4 x4, Samsung 980 PRO 1TB) | MaxPayload 128 (default) | MaxPayload 256 |
|---|---|---|
| one drive, 10 GiB playback | 6250 MB/s (3 of 3, ring-assisted; 6500 MB/s underflows, 6487.9 MB/s streamed) | **7000 MB/s** (3 of 3; 7250 MB/s underflows, 7225.7-7245.2 MB/s streamed) |
| one drive, 40 GiB playback (sustained) | 6000 MB/s (3 of 3; 6250 MB/s 2 of 3) | **6750 MB/s** (3 of 3; 7000 MB/s 0 of 3, 4.28-7.42 M ticks, 6923-6955 MB/s streamed) |
| RAID0, 10 GiB playback | 8750 MB/s (3 of 3); 9000 MB/s 0 of 3 (1.2-1.6 M underflow ticks) | 8750 MB/s clean (1 run); 9000 MB/s 1 of 3 (15 and 1916 ticks); 9250 MB/s underflows (2.6 M) |

On a Gen3 x4 slot MaxPayload 256 bytes lifts the write from ~3.04 to ~3.36 GB/s (980 PRO) or
from ~2.75-2.83 to ~3.01 GB/s (Sabrent), and the read from ~3.19 to ~3.54-3.55 GB/s with either
drive, as fpga-drive-recorder measured; it makes the 980 PRO RAID0 playback worse (bigger SSD
write packets into DDR next to the ring reader; RAID0 was not run at 256 bytes with the
Sabrents). On a Gen4 x4 link it lifts one 980 PRO's read from ~6.3 to ~6.9-7.0 GB/s (6750 MB/s
sustained playback instead of 6000 MB/s); the RAID0 playback, limited by DDR, gains no full
step. It changes nothing for one Sabrent on `vck190_fmcp1`, whose own read and write rates are
below its link (see [Ceilings at a glance](#versal-vck190_fmcp1)). **Use it for one drive
only.** Recording at 256 bytes was not measured on `vck190_fmcp1`. Every other figure on this
page is at the default of 128 bytes.

### Commands in flight (qd 32 and 63)

`nvrec --qd` sets how many NVMe writes the hardware keeps in flight per SSD (1 … 63, default 32).
RAID0 32 GB recordings on `vck190_fmcp1`, freshly deallocated volume per run, 512 MB ring; the
980 PRO pair writes 512 KB per command, the Sabrent pair 256 KB:

| rate (MB/s) | Sabrent pair, `--qd 32` (default) | Sabrent pair, `--qd 63` | 980 PRO pair, `--qd 32` (default) | 980 PRO pair, `--qd 63` |
|---|---|---|---|---|
| 7500 | clean (1 run, ring high-water 1054 of 2048) | clean 3 of 3 (ring high-water 1345-1725) | clean | clean |
| 7750 | **clean 3 of 3** (ring high-water 740-1207) | clean 1 of 3 (the others drop from 7.73 and 22.62 GB, writing 7.60-7.70 GB/s) | - | - |
| 8000 | clean 2 of 3 (the other drops from 3.47 GB, writing 7.57 GB/s) | 0 of 3 (writing 7.80-7.88 GB/s) | clean | clean |
| 8250 | 0 of 1 (writing 7.69 GB/s) | 0 of 3 (writing 7.83-8.12 GB/s) | - | - |
| 8500 | - | 0 of 3 (writing 8.08-8.28 GB/s) | clean | clean |
| 9000 | - | - | clean 3 of 3 (ring high-water 106-123 of 1024) | clean 3 of 3 (76-97) |
| 9250 | - | - | **clean 3 of 3** (FIFO high-water 2800-4021 of 4096) | **clean 3 of 3** (FIFO high-water 821-2452) |
| 9500 | - | - | 0 of 3 (213 982-452 063 beats dropped, writing 9.48-9.49 GB/s) | 1 of 3 (580 and 870 beats dropped) |
| 10 000 | - | - | 0 of 1 (9.75 GB/s written) | 0 of 1 (9.82 GB/s written) |
| playback, 10 GiB, 8750 / 9000 | - | - | 3 of 3 / 0 of 3 | 3 of 3 / 0 of 3 |

**At 512 KB per command (the 980 PRO pair) `--qd 63` changes nothing**: the pair records
9250 MB/s and plays back 8750 MB/s at either setting, bound by the DDR controller, and 63
commands only soften the drops at 9500 MB/s. **At 256 KB per command (the Sabrent pair) it now
costs one step**: 7500 MB/s at `--qd 63` against 7750 MB/s at 32, with the drives' write-latency
maxima growing from ~21 to 31-45 ms. On an earlier build of this design, with about 5 TB less
written to the same drives, `--qd 63` had reached 8500 MB/s with this pair; that did not
reproduce. One drive gains nothing (one Sabrent at 4500 MB/s on `vck190_fmcp1` drops writing
4216 MB/s at `--qd 63`, as at 32; on `zcu106_hpc0` 2742.9 MB/s at 3000 MB/s and 1741.8 MB/s past
the cache at 1750 MB/s, against 2752.7-2828.9 and 1735.2 MB/s at 32). On `zcu106_hpc0` the
Sabrent RAID0 records its 5000 MB/s top at `--qd 63` as at 32 (3 of 3 each; the HP port is the
limit there), and on the 256-bit build, where both Root Ports shared one NoC port, `--qd 63` made
RAID0 worse (6.24 GB/s written at 7000 MB/s against 6.69-6.76 GB/s at 32). **The default stays
32**; measure both values with your own drives before changing it (see
[Queue depth](apps.md#queue-depth---qd)).

### CPU load

The runs at the top rates (medians of 3 runs unless stated); method as described
[above](#cpu-load).

| target | transfer | SSD | layout | cores | total CPU % of all cores (usr / sys / irq / iowait) | busy, summed over the cores (% of one core) | process % of one core | MB/s per % core | runs |
|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | `nvrec`, 4000 MB/s, 32 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 0.11 / 0.96 / 0.05 / 0.43 | 2.2 | 1.19 (1.18-1.25) | 3 361 | 3 |
| `vck190_fmcp1` | `nvrec`, 7750 MB/s, 32 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 0.63 / 2.53 / 0.11 / 0.42 | 6.5 | 2.77 (2.76-2.77) | 2 798 | 3 |
| `vck190_fmcp1` | `nvrec`, 7500 MB/s, 32 GB, `--qd 63` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 0.41 / 3.15 / 0.10 / 0.72 | 7.1 | 2.67 (2.47-2.69) | 2 809 | 3 |
| `vck190_fmcp1` | `nvrec`, 3250 MB/s, 350 GiB (earlier build) | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 0.96 / 0.49 / 0.01 / 0.06 | 2.9 | 0.21 | 15 476 | 1 |
| `vck190_fmcp1` | `nvplay`, 4750 MB/s, 10 GiB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 0.2 / 2.39 / 0.0 / 0.4 | 5.2 | 2.85 | 1 667 | 3 |
| `vck190_fmcp1` | `nvplay`, 8750 MB/s, 10 GiB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 1.04 / 4.50 / 0.0 / 0.69 | 10.4 | 5.11 | 1 712 | 3 |
| `vck190_fmcp1` | `nvrec`, 5000 MB/s, 32 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 0.42 / 1.33 / 0.0 / 0.42 | 3.6 | 1.26 (1.12-1.26) | 3 968 | 3 |
| `vck190_fmcp1` | `nvrec`, 9250 MB/s, 32 GB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2 | 0.5 / 3.13 / 0.12 / 0.63 | 7.5 | 2.78 (2.53-2.78) | 3 327 | 3 |
| `vck190_fmcp1` | `nvrec`, 3250 MB/s, 350 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2 | 0.49 / 0.35 / 0.01 / 0.09 | 1.7 | 0.15 | 21 667 | 1 |
| `vck190_fmcp1` | `nvplay`, 6250 MB/s, 10 GiB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 0.26 / 3.1 / 0.0 / 0.77 | 6.7 | 3.19 (3.19-3.72) | 1 959 | 3 |
| `vck190_fmcp1` | `nvplay`, 8750 MB/s, 10 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2 | 0.35 / 4.59 / 0.0 / 1.06 | 10.6 | 5.19 | 1 686 | 3 |
| `zcu106_hpc0` | `nvrec`, 2750 MB/s, 32 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 0.12 / 0.51 / 0.0 / 0.06 | 2.4 | 1.34 (1.33-1.41) | 2 052 | 3 |
| `zcu106_hpc0` | `nvrec`, 5000 MB/s, 32 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 0.28 / 1.25 / 0.03 / 0.14 | 6.4 | 2.93 (2.78-2.94) | 1 706 | 3 |
| `zcu106_hpc0` | `nvrec`, 3250 MB/s, 350 GiB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 0.5 / 0.27 / 0.0 / 0.02 | 3.1 | 0.34 | 9 559 | 1 |
| `zcu106_hpc0` | `nvplay`, 3000 MB/s, 10 GiB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 0.13 / 1.2 / 0.0 / 0.13 | 5.1 | 3.35 (3.10-3.36) | 896 | 3 |
| `zcu106_hpc0` | `nvplay`, 4500 MB/s, 10 GiB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 0.19 / 1.96 / 0.0 / 0.19 | 8.9 | 4.62 (4.62-5.00) | 974 | 3 |
| `zcu106_hpc0` | `nvrec`, 3000 MB/s, 32 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 0.09 / 0.49 / 0.0 / 0.13 | 2.6 | 1.29 | 2 326 | 3 |
| `zcu106_hpc0` | `nvrec`, 5000 MB/s, 32 GB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4 | 1.22 / 1.53 / 0.0 / 0.24 | 11.5 (6.4-40.9) | 2.52 (2.38-2.52) | 1 984 | 3 |
| `zcu106_hpc0` | `nvrec`, 3500 MB/s, 350 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4 | 1.03 / 0.35 / 0.0 / 0.03 | 5.5 | 0.26 | 13 462 | 1 |
| `zcu106_hpc0` | `nvplay`, 3000 MB/s, 10 GiB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 0.13 / 1.14 / 0.0 / 0.13 | 5.3 | 3.10 | 968 | 3 |
| `zcu106_hpc0` | `nvplay`, 4750 MB/s, 10 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4 | 0.2 / 1.96 / 0.0 / 0.2 | 8.6 | 4.86 | 977 | 3 |

The process figures are a fixed 0.06-0.4 s of CPU time per run (ring and PRP lists, unmounting
and remounting the volume, the statistics), independent of the rate: 0.07 s over the 1.35 s of
a 10 GiB playback at 8750 MB/s is 5.2 %, 0.24 s over the 2 minutes of a 350 GiB recording 0.2 %.
During the transfer the CPU does nothing for it. "Busy, summed over the cores" also counts the
benchmark host's SSH polls of the board and the suite's temperature sampling (for example the
40.9 % of one `zcu106_hpc0` run).

## The SLC cache

Most consumer SSDs write into a fast pseudo-SLC cache first and move the data to their TLC
flash later; once the cache is full, the write rate drops. A recorder writes at a constant rate
for as long as the recording lasts, so the rate after the cache is the one that counts. The
cache of an empty, trimmed 1 TB drive is larger than 32 GB, so the 32 GB sweep measures an
in-cache rate for these drives, and only the [long recordings](#long-recordings-past-the-slc-cache)
give the sustained one.

The cache sizes and rates below were not measured again in this revision: they are cited from
fpga-drive-recorder's [SLC cache](https://recorder.fpgadrive.com/en/latest/benchmarks.html#the-slc-cache)
measurements of the same drives (one sequential fio write, queue depth 8, 8 MB blocks,
`O_DIRECT`, on a fresh XFS after 60 s of idle time).

| SSD | SLC cache, empty and trimmed drive | write rate inside the cache | write rate after the cache |
|---|---|---|---|
| Samsung 980 PRO 1TB | ~115-125 GB per drive; ~245 GB for a RAID0 pair | ~3.0 GB/s on a Gen3 x4 link (the link), ~4.94-4.98 GB/s on Gen4 x4 | ~1.77 GB/s (median 1765-1766 MB/s); a pair ~3.46-3.49 GB/s |
| Sabrent Rocket 2230 1TB (SB-2130-1TB) | ~66-75 GB per drive; ~140 GB for a RAID0 pair | ~2.9 GB/s on a Gen3 x4 link (the link), ~4.6 GB/s on Gen4 x4 | ~1.8 GB/s (median 1799-1806 MB/s); a pair ~3.6 GB/s |

With this design's commands the 980 PRO writes the same after its cache (1750 MB/s holds over
200 GiB on both boards), while one Sabrent writes ~1.73 GB/s and the Sabrent pair ~3.39-3.45 GB/s
(see [Long recordings](#long-recordings-past-the-slc-cache)). The cache refills only while the
drive is idle, so back-to-back recordings may not each get a full cache. Size the rate for the
longest recording you need: a short burst test overstates what a drive sustains.
