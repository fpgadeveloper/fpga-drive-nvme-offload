# Benchmarks

This page explains how the NVMe-offload recorder is measured and lists the results per target
and SSD. The method is the one of the sibling design
[fpga-drive-recorder](https://recorder.fpgadrive.com/en/latest/benchmarks.html) (Linux and
io_uring issue the NVMe commands there; here the fabric does), with the same SSDs, sizes and
rate steps, so that the two designs can be compared line by line: see
[Comparison with fpga-drive-recorder](comparison). Every figure was measured on hardware; the
target, the SSDs, their firmware and the date are given with each table.

```{note}
The result tables on this page are generated from the benchmark results files
(`nvbench-suite.sh`, below).
```

## Method

### Recording

Each measurement is one `nvrec` recording of test-pattern data at a fixed generator rate,
followed by `nvverify` on the file. A rate **passes** when `nvrec` exits 0 (zero dropped beats
and zero NVMe errors) and `nvverify` reports a clean file. Because the generator cannot be
stalled, a pass means the whole chain (ring writer, DDR, command builder, Host Accelerator,
PCIe, SSD) kept up with the rate for the entire recording.

* A **burst** figure comes from a recording that is short enough to fit in the SSD's SLC write
  cache (10 GB, and the 4000 MiB rate sweep).
* The **sustained recording rate** is the highest passing rate over a recording long enough to
  exhaust the cache: 32 GB per step in 250 MB/s steps up to the 3200 MB/s source maximum (the
  last step is the maximum itself: .., 2750, 3000, 3200), stopping at the first failing step,
  as on the recorder page.

The sweeps use the same ranges as the recorder's benchmarks: the 4000 MiB sweep runs 250 ..
3000 MB/s (the recorder's at-a-glance sweep never reaches 3200); the 32 GB sweep, the 10 GB
bursts and the playback sweep run in 250 MB/s steps up to 3000 MB/s and then at 3200 MB/s, the
generator's maximum (our 10 GB burst sweep starts at 500 MB/s and the playback sweep at
250 MB/s, the recorder's both at 1000 MB/s: the extra low steps would only end a sweep early
if one of them failed). Every fixture's matrix was first measured with sweeps that stopped at
3000 MB/s; the final 3200 MB/s steps (32 GB, 10 GB and playback, per layout, wherever the
3000 MB/s step had passed) were added with `nvbench-suite.sh gaps` on 2026-10-19, on freshly
trimmed drives like every other step, so the tables below cover the same range as the
recorder's.

```
sudo nvsetup-raid0.sh -y --trim --single /dev/nvrec0n1   # or: sudo nvsetup-raid0.sh -y --trim  (RAID0)
sudo nvrec --rate 1000MB --size 10G /mnt/rec/t.dat; echo rc=$?
sudo nvverify /mnt/rec/t.dat
sudo nvbench.sh --size 32G --from 250 --step 250 --stop-on-fail   # sustained-rate sweep
```

What is the same as on the recorder page, and what differs:

| | fpga-drive-recorder | this design |
|---|---|---|
| test data | `fdrec_tpg`, 128-bit beats, 3.2 GB/s maximum (200 MHz × 16 bytes) | the same generator and pattern |
| pass/fail | `fdrec` exit 0 (drop count 0) + `fdverify` PASS | `nvrec` exit 0 (`RUN_DROP_COUNT` 0 **and no NVMe error**) + `nvverify` PASS |
| drop counter | ingest FIFO drop count | `RUN_DROP_COUNT`: beats dropped while the run accepted data (the ingest counter keeps counting after a run that stops at its length while the generator runs on) |
| I/O size | 8 MB buffers, split by Linux into MDTS-sized NVMe commands | one NVMe command per chunk: 1 MB or the drive's MDTS, whichever is smaller (512 KB on a Samsung 980 PRO) |
| commands in flight | io_uring queue depth 8 (8 MB requests) | up to 32 per SSD (`SSD_MAX_INFLIGHT`, 1 … 63), issued by the fabric |
| buffer ring | 32 × 8 MB (256 MB; 16 × 8 MB in the older `uzev` rows) | 256 MB: 256 MB / chunk slots within 256…1024 (512 × 512 KB, 1024 × 256 KB); runs before this default used 256 slots (128 MB at 512 KB, 64 MB at 256 KB): every run records its ring (`ring_slots`, `ring_bytes`) |
| filesystem | XFS | exFAT, contiguous preallocated file (see [Filesystem](filesystem)) |
| trim before a step | `rm` + `fstrim /mnt/rec`, then 60 s idle | `nvsetup-raid0.sh --trim`: `blkdiscard` of the whole drives, new md array, new exFAT, then 60 s idle |
| CPU in the data path | io_uring submissions + DMA ioctls per 8 MB buffer | none: the CPU sets the run up and waits for its end |

**Trim on exFAT.** On the recorder page every step deletes the previous file and runs `fstrim`
on the XFS volume, which deallocates all free space: since the volume holds nothing else, the
drives start every step fully deallocated. The exFAT equivalent used here is a deallocation of
the **whole** drives (`blkdiscard`, NVMe Dataset Management / Deallocate through the driver)
followed by a new md array and a new exFAT volume — the same drive state, and every step also
starts from an identical, empty volume. The drives are then left idle for 60 s before the
recording, as on the recorder page (see the recorder's
[fstrim finding](https://recorder.fpgadrive.com/en/latest/benchmarks.html#the-fstrim-finding-and-the-ring-size):
an SSD still busy with discards can stall the first writes).

The **4000 MiB rate sweep** (the "highest clean" cells of the at-a-glance comparison) does not
trim between steps, like the recorder's: the previous file is deleted and the recording starts
10 s later; the top clean step is then repeated twice (3 runs in total).

### Playback

Each measurement is one `nvplay` of a test-pattern recording at a fixed sink rate (`--rate`),
into the reference design's checker. A rate is **clean** when `nvplay` exits 0: 0 underflows,
0 checker errors, gap beats equal to the recording's drop count, every beat delivered, no NVMe
error. The highest clean rate is the fastest constant-rate stream that the SSDs deliver into the
fabric. Each playback sweep plays a 10 GB recording made at 1000 MB/s with 0 drops, from
250 MB/s in 250 MB/s steps up to the 3200 MB/s source maximum (the last step is the maximum
itself: .., 3000, 3200) or the first rate with underflows; the highest clean step is then
played twice more.

`nvplay` fills the ring from the SSDs before it enables the sink (the recorder's `fdplay` does
the same with its buffers), so the ring absorbs read stalls up to its length at the sink rate.
The reported time and rate are the streaming time; the prefill time is reported separately.

### CPU load

Measured the way the recorder page measures it in its comparison section, over the whole
transfer:

* the **total CPU** from `/proc/stat` deltas, as a share of all the target's cores (user /
  system / IRQ + softirq / I/O wait), and the busy time **summed over the cores** in % of one
  core (this includes interrupt handlers and kernel threads that are not charged to the
  process);
* the **transfer process**: its (user + system) time over its real time from `time -p`, as a
  share of one core. "MB/s per % core" is the achieved rate divided by this figure.

Each figure is the median of two 10 GB transfers at 1000 MB/s (record, then playback of the
10 GB playback recording), as in the recorder's CPU-load measurement on `vck190_fmcp1` and
`zcu106_hpc0`. The CPU time of `nvrec` includes the preallocation and the exFAT updates before
and after the run; during the run the process sleeps until the hardware reports the end.

### Chunk size and commands in flight

Two sweeps that have no recorder equivalent, both 10 GB recordings on freshly trimmed drives at
a fixed rate (the layout's highest clean 10 GB rate, at most 3000 MB/s):

* **Chunk size** (= the size of every NVMe Write command): 128 KB up to 1 MB or the drives'
  MDTS. The md chunk and the exFAT cluster follow the chunk; the ring is kept at 256 MB
  (`--ring-mb`; `--buffers` = 256 MB / chunk, at most 1024 slots; 128 MB in runs before the
  256 MB default).
* **Commands in flight** (`nvrec --qd` = `SSD_MAX_INFLIGHT` per SSD): 1, 2, 4, 8, 16, 32 and 63
  (the register's maximum).

### Completion latency

`nvrec_core` times every command of a run from its submission to its completion entry, in
`dp_clk` cycles (250 MHz), and keeps the minimum, maximum, sum and a 16-bin log2 histogram
(bin 0 below 2^10 cycles = 4.1 µs, bin *i* from 2^(9+i) to 2^(10+i) cycles, the last bin
2^24 cycles = 67 ms and more). `nvrec` prints the minimum, average and maximum; the histogram
is in `/sys/class/misc/nvrec/lat_hist` after the run (see [Register map](register_map)). The
ring high-water mark (slots in use) and the highest number of commands in flight per SSD
(`SSD_INFLIGHT_HWM`) are reported for every run. The "max in flight" columns give the high-water of
the run's own drives (the `inflight_hwm` value of each member slot); the `nvrec` summary line of
the images used for these benchmarks took the maximum over both SSD slots, which on a
single-drive run included the idle slot's value from an earlier run (the driver now clears
both slots at the start of every run).

### Evaluation-license sessions

The Host Accelerator in the published bitstreams is an **evaluation** core: it stops
183-184 minutes after the bitstream was loaded (see [Kernel driver](driver)). Every benchmark
session therefore starts with a power cycle (which reloads the bitstream) and ends within
150 minutes; no run may cross that limit. A run's result does not depend on the session it was
measured in; the results file keeps the uptime of every run.

### Units

All rates are MB/s (10⁶ bytes/s), as reported by `nvrec` and `nvplay`. Sizes follow the apps'
suffixes: 10G = 10 GiB, 32G = 32 GiB, 4000M = 4000 MiB, as with `fdrec` on the recorder page
(which also writes "10 GB" for `--size 10G`).

### Running the benchmarks

`nvbench-suite.sh` (in the image, `sw/nvrec-apps/`) runs the whole matrix of this page on the
board and appends one JSON line per run to `/var/lib/nvbench/results.jsonl`: the fixture (target,
SSD models, serial numbers, firmware, PCIe link, MDTS), the layout, the run's parameters and
every figure above (rates, drops, NVMe errors, FIFO and ring high-water marks, commands in
flight, latency and histogram, `nvverify` result and first gap, CPU).

```
sudo nvbench-suite.sh --dry-run all             # the plan and its estimated time
sudo nvbench-suite.sh all                       # SSD1, SSD2, RAID0: everything on this page
sudo nvbench-suite.sh --layout raid0 sustained  # one test: sustained|glance|burst|playback|cpu|chunk|inflight
sudo nvbench-suite.sh gaps                      # only the 3200 MB/s steps missing from older results
sudo nvbench-suite.sh status                    # what is in the results file
```

`gaps` is for results files written before the sweeps ended at the source maximum: per layout
it runs only the final 3200 MB/s step of the 32 GB sustained sweep and of the 10 GB burst sweep
(one run each, trimmed volume) and of the playback sweep (plus its two confirmations), and
only where the sweep's 3000 MB/s step is in the results and passed — exactly the runs that
`all` adds to such a file, a few minutes per layout.

A run already in the results file is not repeated, so the suite can be stopped and started
again with the same command; with `--budget-min` (default 150) it stops cleanly before a run
that would end later than that many minutes after the bitstream load (exit code 3), and when
the Host Accelerator stops it exits with code 5: power-cycle the board and run the same command
again. **The suite erases the SSDs.**

## Fixture

<!-- nvbench:fixture:begin -->
| target | drive | SSD | firmware | PCIe link | MDTS | I/O queues granted | nvrec_core | measured |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 16.0 GT/s PCIe x4 | 256 KB | 8 | 1.1 | 2026-10-18, 2026-10-19 |
| `vck190_fmcp1` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 16.0 GT/s PCIe x4 | 256 KB | 8 | 1.1 | 2026-10-18, 2026-10-19 |
| `zcu106_hpc0` | nvrec0n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 8.0 GT/s PCIe x4 | 512 KB | 1 | 1.1 | 2026-10-18, 2026-10-19 |
| `zcu106_hpc0` | nvrec1n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 8.0 GT/s PCIe x4 | 512 KB | 1 | 1.1 | 2026-10-18, 2026-10-19 |
| `vck190_fmcp1` | nvrec0n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 16.0 GT/s PCIe x4 | 512 KB | 1 | 1.1 | 2026-10-18, 2026-10-19 |
| `vck190_fmcp1` | nvrec1n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 16.0 GT/s PCIe x4 | 512 KB | 1 | 1.1 | 2026-10-18, 2026-10-19 |
| `zcu106_hpc0` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.1 | 2026-10-18, 2026-10-19 |
| `zcu106_hpc0` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.1 | 2026-10-18, 2026-10-19 |
| `uzev` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.1 | 2026-10-19 |
| `uzev` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.1 | 2026-10-19 |
<!-- nvbench:fixture:end -->

## Results

### Sustained recording rate

`nvrec` 32 GB per step, 250 MB/s steps from 250 MB/s up to the first failing step or the
3200 MB/s source maximum (.., 3000, 3200), trimmed
drives + new exFAT volume + 60 s idle before every step; queue depth 32 per SSD, 256 MB ring (the default).
The 4000 MiB, 10 GB and 40 GB columns come from the sweeps and recordings below.

<!-- nvbench:sustained:begin -->
| target | SSD | layout | sustained rate (32 GB) | highest clean, 4000 MiB (clean runs) | highest clean, 10 GB | highest clean, 40 GB |
|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2500 MB/s** | 3000 MB/s (3/3) | 2750 MB/s | 2750 MB/s |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **2750 MB/s** | 3000 MB/s (3/3) | 2750 MB/s | 2750 MB/s |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200 MB/s** | 3000 MB/s (3/3) | 3200 MB/s | 3200 MB/s (source max) |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2750 MB/s** | 2750 MB/s (3/3) | 2750 MB/s | 2750 MB/s |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **2750 MB/s** | 3000 MB/s (3/3) | 2750 MB/s | 2750 MB/s |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3000 MB/s** | 3000 MB/s (3/3) | 3000 MB/s | 3000 MB/s |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3000 MB/s** | 3000 MB/s (3/3) | 3000 MB/s | 3000 MB/s |
<!-- nvbench:sustained:end -->

Every step of the 32 GB sweeps ("first gap" is the file offset of the first discontinuity
reported by `nvverify`; "avg MB/s" is the data written divided by the recording time):

<!-- nvbench:sweep:begin -->
| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (of 4096) | ring high-water (slots) | avg MB/s | nvverify | first gap |
|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | pass | 0 | 256 | 5 / 1024 | 250.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | pass | 0 | 257 | 12 / 1024 | 500.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | pass | 0 | 258 | 19 / 1024 | 750.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | pass | 0 | 259 | 35 / 1024 | 1000.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | pass | 0 | 260 | 73 / 1024 | 1250.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | pass | 0 | 261 | 119 / 1024 | 1500.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | pass | 0 | 262 | 169 / 1024 | 1750.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | pass | 0 | 263 | 245 / 1024 | 1999.8 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | pass | 0 | 264 | 339 / 1024 | 2250.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | pass | 0 | 265 | 410 / 1024 | 2500.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | pass | 0 | 266 | 431 / 1024 | 2749.9 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 | pass | 0 | 267 | 640 / 1024 | 3000.1 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200** | pass | 0 | 264 | 251 / 1024 | 3199.8 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | pass | 0 | 256 | 20 / 1024 | 250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | pass | 0 | 257 | 39 / 1024 | 500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | pass | 0 | 258 | 60 / 1024 | 750.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | pass | 0 | 259 | 80 / 1024 | 999.5 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | pass | 0 | 260 | 100 / 1024 | 1250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | pass | 0 | 261 | 121 / 1024 | 1500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | pass | 0 | 262 | 172 / 1024 | 1750.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | pass | 0 | 263 | 159 / 1024 | 1999.9 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | pass | 0 | 264 | 422 / 1024 | 2250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2500** | pass | 0 | 265 | 745 / 1024 | 2500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | drops | 29 800 096 | full | 1 024 / 1024 | 2700.6 | gaps | 14.95 GB |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | pass | 0 | 256 | 20 / 1024 | 250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | pass | 0 | 257 | 39 / 1024 | 500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | pass | 0 | 258 | 59 / 1024 | 750.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | pass | 0 | 259 | 79 / 1024 | 1000.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | pass | 0 | 260 | 99 / 1024 | 1250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | pass | 0 | 261 | 118 / 1024 | 1500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | pass | 0 | 262 | 153 / 1024 | 1750.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | pass | 0 | 263 | 160 / 1024 | 2000.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | pass | 0 | 264 | 181 / 1024 | 2250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | pass | 0 | 265 | 197 / 1024 | 2498.9 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **2750** | pass | 0 | 266 | 312 / 1024 | 2747.9 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 | drops | 111 497 568 | full | 1 024 / 1024 | 2830.5 | gaps | 4.94 GB |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 258 | 2 / 512 | 750.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 259 | 3 / 512 | 1000.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 260 | 6 / 512 | 1250.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 261 | 8 / 512 | 1500.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 262 | 9 / 512 | 1750.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 262 | 12 / 512 | 2000.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 264 | 13 / 512 | 2250.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 264 | 18 / 512 | 2500.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 266 | 17 / 512 | 2749.9 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 267 | 21 / 512 | 3000.1 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 265 | 24 / 512 | 3199.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | pass | 0 | 256 | 5 / 1024 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | pass | 0 | 257 | 12 / 1024 | 500.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | pass | 0 | 258 | 94 / 1024 | 750.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | pass | 0 | 259 | 50 / 1024 | 1000.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | pass | 0 | 260 | 72 / 1024 | 1250.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | pass | 0 | 261 | 210 / 1024 | 1500.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | pass | 0 | 262 | 205 / 1024 | 1750.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | pass | 0 | 263 | 244 / 1024 | 2000.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | pass | 0 | 264 | 308 / 1024 | 2250.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | pass | 0 | 265 | 399 / 1024 | 2500.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | pass | 0 | 266 | 552 / 1024 | 2749.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 | pass | 0 | 267 | 503 / 1024 | 3000.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200** | pass | 0 | 265 | 416 / 1024 | 3199.8 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | pass | 0 | 256 | 7 / 1024 | 250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | pass | 0 | 257 | 40 / 1024 | 500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | pass | 0 | 258 | 70 / 1024 | 750.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | pass | 0 | 259 | 190 / 1024 | 1000.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | pass | 0 | 260 | 272 / 1024 | 1250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | pass | 0 | 261 | 272 / 1024 | 1500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | pass | 0 | 262 | 371 / 1024 | 1750.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | pass | 0 | 263 | 443 / 1024 | 2000.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | pass | 0 | 264 | 515 / 1024 | 2250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | pass | 0 | 265 | 622 / 1024 | 2499.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | pass | 0 | 266 | 685 / 1024 | 2749.9 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | pass | 0 | 267 | 724 / 1024 | 2996.7 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3200** | pass | 0 | 267 | 260 / 1024 | 3199.8 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | pass | 0 | 256 | 20 / 1024 | 250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | pass | 0 | 257 | 45 / 1024 | 500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | pass | 0 | 258 | 107 / 1024 | 750.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | pass | 0 | 259 | 193 / 1024 | 1000.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | pass | 0 | 260 | 249 / 1024 | 1250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | pass | 0 | 261 | 272 / 1024 | 1500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | pass | 0 | 262 | 342 / 1024 | 1750.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | pass | 0 | 263 | 443 / 1024 | 2000.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | pass | 0 | 264 | 477 / 1024 | 2250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | pass | 0 | 265 | 582 / 1024 | 2500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | pass | 0 | 266 | 679 / 1024 | 2749.9 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 | pass | 0 | 267 | 731 / 1024 | 2998.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3200** | pass | 0 | 265 | 927 / 1024 | 3199.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 750 | pass | 0 | 258 | 5 / 512 | 750.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1000 | pass | 0 | 259 | 7 / 512 | 1000.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1250 | pass | 0 | 260 | 9 / 512 | 1250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1500 | pass | 0 | 261 | 11 / 512 | 1500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1750 | pass | 0 | 262 | 13 / 512 | 1750.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2000 | pass | 0 | 263 | 16 / 512 | 2000.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2250 | pass | 0 | 264 | 19 / 512 | 2250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2500 | pass | 0 | 265 | 30 / 512 | 2500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2750 | pass | 0 | 266 | 25 / 512 | 2749.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 | pass | 0 | 267 | 26 / 512 | 3000.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3200** | pass | 0 | 265 | 27 / 512 | 3199.5 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 750 | pass | 0 | 258 | 4 / 512 | 750.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1000 | pass | 0 | 259 | 7 / 512 | 1000.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1250 | pass | 0 | 260 | 9 / 512 | 1250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1500 | pass | 0 | 261 | 11 / 512 | 1500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1750 | pass | 0 | 262 | 14 / 512 | 1750.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2000 | pass | 0 | 263 | 15 / 512 | 2000.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2250 | pass | 0 | 264 | 20 / 512 | 2250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2500 | pass | 0 | 265 | 21 / 512 | 2500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2750 | pass | 0 | 266 | 24 / 512 | 2749.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 | pass | 0 | 267 | 27 / 512 | 3000.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3200** | pass | 0 | 266 | 26 / 512 | 3199.8 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 258 | 2 / 512 | 750.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 259 | 3 / 512 | 1000.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 260 | 4 / 512 | 1250.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 261 | 7 / 512 | 1500.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 262 | 9 / 512 | 1749.9 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 263 | 13 / 512 | 2000.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 264 | 15 / 512 | 2250.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 265 | 16 / 512 | 2500.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 266 | 18 / 512 | 2749.9 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 267 | 22 / 512 | 2999.8 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 264 | 21 / 512 | 3199.5 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | pass | 0 | 256 | 17 / 1024 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | pass | 0 | 257 | 37 / 1024 | 500.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | pass | 0 | 258 | 57 / 1024 | 750.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | pass | 0 | 259 | 77 / 1024 | 1000.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | pass | 0 | 260 | 96 / 1024 | 1250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | pass | 0 | 261 | 116 / 1024 | 1500.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | pass | 0 | 262 | 179 / 1024 | 1750.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | pass | 0 | 263 | 327 / 1024 | 2000.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | pass | 0 | 264 | 418 / 1024 | 2250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | pass | 0 | 265 | 416 / 1024 | 2500.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | pass | 0 | 266 | 493 / 1024 | 2749.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 | pass | 0 | 267 | 574 / 1024 | 2999.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200** | pass | 0 | 265 | 447 / 1024 | 3198.6 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | pass | 0 | 256 | 20 / 1024 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | pass | 0 | 257 | 39 / 1024 | 500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | pass | 0 | 258 | 59 / 1024 | 750.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | pass | 0 | 259 | 79 / 1024 | 1000.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | pass | 0 | 260 | 99 / 1024 | 1250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | pass | 0 | 261 | 120 / 1024 | 1498.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | pass | 0 | 262 | 140 / 1024 | 1749.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | pass | 0 | 263 | 161 / 1024 | 2000.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | pass | 0 | 264 | 178 / 1024 | 2250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | pass | 0 | 265 | 73 / 1024 | 2499.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2750** | pass | 0 | 266 | 347 / 1024 | 2744.2 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | drops | 118 129 856 | full | 1 024 / 1024 | 2821.9 | gaps | 4.67 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | pass | 0 | 256 | 19 / 1024 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | pass | 0 | 257 | 39 / 1024 | 500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | pass | 0 | 258 | 22 / 1024 | 750.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | pass | 0 | 259 | 78 / 1024 | 1000.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | pass | 0 | 260 | 98 / 1024 | 1250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | pass | 0 | 261 | 118 / 1024 | 1500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | pass | 0 | 262 | 138 / 1024 | 1749.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | pass | 0 | 263 | 157 / 1024 | 2000.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | pass | 0 | 264 | 67 / 1024 | 2250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | pass | 0 | 265 | 197 / 1024 | 2499.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **2750** | pass | 0 | 316 | 81 / 1024 | 2749.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 | drops | 112 356 462 | full | 1 024 / 1024 | 2828.4 | gaps | 4.59 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 750 | pass | 0 | 258 | 5 / 512 | 750.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1000 | pass | 0 | 259 | 7 / 512 | 1000.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1250 | pass | 0 | 260 | 9 / 512 | 1250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1500 | pass | 0 | 261 | 11 / 512 | 1500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1750 | pass | 0 | 262 | 14 / 512 | 1749.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2000 | pass | 0 | 263 | 17 / 512 | 2000.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2250 | pass | 0 | 264 | 19 / 512 | 2250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2500 | pass | 0 | 265 | 28 / 512 | 2500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2750 | pass | 0 | 266 | 24 / 512 | 2749.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3000** | pass | 0 | 267 | 36 / 512 | 2999.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 | drops | 96 424 169 | full | 512 / 512 | 3038.3 | gaps | 5.56 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 750 | pass | 0 | 258 | 4 / 512 | 750.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1000 | pass | 0 | 259 | 6 / 512 | 1000.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1250 | pass | 0 | 260 | 8 / 512 | 1250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1500 | pass | 0 | 261 | 12 / 512 | 1500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1750 | pass | 0 | 262 | 14 / 512 | 1749.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2000 | pass | 0 | 263 | 18 / 512 | 2000.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2250 | pass | 0 | 264 | 17 / 512 | 2249.6 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2500 | pass | 0 | 265 | 20 / 512 | 2500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2750 | pass | 0 | 266 | 24 / 512 | 2749.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3000** | pass | 0 | 267 | 35 / 512 | 2999.5 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 | drops | 96 315 914 | full | 512 / 512 | 3038.8 | gaps | 5.56 GB |
<!-- nvbench:sweep:end -->

### 4000 MiB rate sweep

The recorder's at-a-glance method: 4000 MiB per step without trimming in between, 250 MB/s
steps up to the first failing step or 3000 MB/s (the recorder's range), then two more runs of
the highest clean step.

<!-- nvbench:glance:begin -->
| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (of 4096) | ring high-water (slots) | avg MB/s | nvverify | first gap |
|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | pass | 0 | 256 | 5 / 1024 | 250.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | pass | 0 | 257 | 12 / 1024 | 500.0 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | pass | 0 | 258 | 18 / 1024 | 750.1 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | pass | 0 | 259 | 25 / 1024 | 1000.1 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | pass | 0 | 260 | 51 / 1024 | 1249.8 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | pass | 0 | 261 | 40 / 1024 | 1500.1 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | pass | 0 | 262 | 72 / 1024 | 1749.8 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | pass | 0 | 263 | 55 / 1024 | 2000.1 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | pass | 0 | 264 | 60 / 1024 | 2250.2 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | pass | 0 | 265 | 68 / 1024 | 2499.6 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | pass | 0 | 266 | 75 / 1024 | 2750.4 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3000** | pass | 0 | 267 | 85 / 1024 | 3000.2 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 2) | pass | 0 | 267 | 85 / 1024 | 2998.1 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 3) | pass | 0 | 267 | 82 / 1024 | 3000.2 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | pass | 0 | 256 | 7 / 1024 | 250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | pass | 0 | 257 | 13 / 1024 | 500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | pass | 0 | 258 | 20 / 1024 | 749.9 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | pass | 0 | 259 | 27 / 1024 | 1000.1 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | pass | 0 | 260 | 36 / 1024 | 1249.8 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | pass | 0 | 261 | 143 / 1024 | 1500.1 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | pass | 0 | 262 | 49 / 1024 | 1749.8 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | pass | 0 | 263 | 55 / 1024 | 2000.1 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | pass | 0 | 264 | 62 / 1024 | 2245.3 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | pass | 0 | 265 | 68 / 1024 | 2499.6 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | pass | 0 | 266 | 81 / 1024 | 2745.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3000** | pass | 0 | 267 | 989 / 1024 | 2820.6 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 2) | pass | 0 | 267 | 926 / 1024 | 2820.6 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 3) | pass | 0 | 267 | 933 / 1024 | 2834.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | pass | 0 | 256 | 19 / 1024 | 250.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | pass | 0 | 257 | 39 / 1024 | 500.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | pass | 0 | 258 | 59 / 1024 | 749.9 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | pass | 0 | 259 | 79 / 1024 | 1000.1 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | pass | 0 | 260 | 99 / 1024 | 1249.8 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | pass | 0 | 261 | 119 / 1024 | 1500.1 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | pass | 0 | 262 | 138 / 1024 | 1746.9 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | pass | 0 | 263 | 54 / 1024 | 2000.1 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | pass | 0 | 264 | 62 / 1024 | 2250.2 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | pass | 0 | 265 | 72 / 1024 | 2499.6 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | pass | 0 | 266 | 78 / 1024 | 2739.6 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3000** | pass | 0 | 267 | 906 / 1024 | 2834.0 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 2) | pass | 0 | 267 | 977 / 1024 | 2824.4 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 3) | pass | 0 | 267 | 935 / 1024 | 2832.1 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 258 | 2 / 512 | 749.9 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 259 | 5 / 512 | 1000.1 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 260 | 3 / 512 | 1249.8 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 261 | 12 / 512 | 1500.1 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 262 | 15 / 512 | 1749.8 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 262 | 9 / 512 | 2000.1 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 264 | 22 / 512 | 2250.2 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 264 | 14 / 512 | 2499.6 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 266 | 23 / 512 | 2750.4 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3000** | pass | 0 | 266 | 32 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 2) | pass | 0 | 266 | 25 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 3) | pass | 0 | 266 | 33 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | pass | 0 | 256 | 4 / 1024 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | pass | 0 | 257 | 11 / 1024 | 500.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | pass | 0 | 258 | 30 / 1024 | 750.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | pass | 0 | 259 | 25 / 1024 | 1000.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | pass | 0 | 260 | 32 / 1024 | 1249.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | pass | 0 | 261 | 39 / 1024 | 1500.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | pass | 0 | 262 | 47 / 1024 | 1749.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | pass | 0 | 263 | 53 / 1024 | 2000.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | pass | 0 | 264 | 59 / 1024 | 2249.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | pass | 0 | 265 | 68 / 1024 | 2499.6 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | pass | 0 | 266 | 73 / 1024 | 2750.4 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3000** | pass | 0 | 267 | 82 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 2) | pass | 0 | 267 | 85 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 3) | pass | 0 | 267 | 127 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | pass | 0 | 256 | 7 / 1024 | 250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | pass | 0 | 257 | 13 / 1024 | 500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | pass | 0 | 258 | 20 / 1024 | 749.9 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | pass | 0 | 259 | 27 / 1024 | 1000.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | pass | 0 | 260 | 36 / 1024 | 1249.8 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | pass | 0 | 261 | 41 / 1024 | 1500.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | pass | 0 | 262 | 48 / 1024 | 1749.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | pass | 0 | 263 | 160 / 1024 | 2000.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | pass | 0 | 264 | 180 / 1024 | 2249.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | pass | 0 | 265 | 68 / 1024 | 2499.6 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | pass | 0 | 266 | 220 / 1024 | 2750.4 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3000** | pass | 0 | 267 | 83 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 2) | pass | 0 | 267 | 83 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 3) | pass | 0 | 267 | 86 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | pass | 0 | 256 | 19 / 1024 | 250.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | pass | 0 | 257 | 39 / 1024 | 500.0 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | pass | 0 | 258 | 59 / 1024 | 749.9 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | pass | 0 | 259 | 77 / 1024 | 1000.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | pass | 0 | 260 | 36 / 1024 | 1249.8 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | pass | 0 | 261 | 42 / 1024 | 1500.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | pass | 0 | 262 | 49 / 1024 | 1749.8 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | pass | 0 | 263 | 54 / 1024 | 1999.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | pass | 0 | 264 | 62 / 1024 | 2250.2 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | pass | 0 | 265 | 75 / 1024 | 2499.6 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | pass | 0 | 266 | 79 / 1024 | 2750.4 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3000** | pass | 0 | 267 | 83 / 1024 | 2998.1 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 2) | pass | 0 | 267 | 85 / 1024 | 2995.9 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 3) | pass | 0 | 267 | 84 / 1024 | 3000.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 750 | pass | 0 | 258 | 7 / 512 | 749.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1000 | pass | 0 | 259 | 9 / 512 | 1000.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1250 | pass | 0 | 260 | 13 / 512 | 1249.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1500 | pass | 0 | 261 | 14 / 512 | 1500.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1750 | pass | 0 | 262 | 17 / 512 | 1749.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2000 | pass | 0 | 263 | 24 / 512 | 2000.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2250 | pass | 0 | 264 | 25 / 512 | 2246.5 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2500 | pass | 0 | 265 | 25 / 512 | 2499.6 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2750 | pass | 0 | 266 | 28 / 512 | 2750.4 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3000** | pass | 0 | 267 | 38 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 2) | pass | 0 | 267 | 37 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 3) | pass | 0 | 267 | 37 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 750 | pass | 0 | 258 | 7 / 512 | 749.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1000 | pass | 0 | 259 | 8 / 512 | 1000.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1250 | pass | 0 | 260 | 11 / 512 | 1249.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1500 | pass | 0 | 261 | 17 / 512 | 1500.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1750 | pass | 0 | 262 | 20 / 512 | 1749.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2000 | pass | 0 | 263 | 20 / 512 | 2000.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2250 | pass | 0 | 264 | 27 / 512 | 2250.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2500 | pass | 0 | 265 | 29 / 512 | 2499.6 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2750 | pass | 0 | 266 | 34 / 512 | 2750.4 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3000** | pass | 0 | 267 | 38 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 2) | pass | 0 | 267 | 31 / 512 | 3000.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 3) | pass | 0 | 267 | 37 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 257 | 2 / 512 | 500.0 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 258 | 2 / 512 | 749.9 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 259 | 3 / 512 | 999.8 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 260 | 8 / 512 | 1249.8 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 261 | 12 / 512 | 1500.1 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 262 | 7 / 512 | 1749.8 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 263 | 19 / 512 | 2000.1 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 264 | 22 / 512 | 2250.2 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 265 | 14 / 512 | 2499.6 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 266 | 29 / 512 | 2750.4 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3000** | pass | 0 | 267 | 33 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 2) | pass | 0 | 267 | 19 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 3) | pass | 0 | 267 | 33 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | pass | 0 | 256 | 5 / 1024 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | pass | 0 | 257 | 19 / 1024 | 500.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | pass | 0 | 258 | 19 / 1024 | 749.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | pass | 0 | 259 | 26 / 1024 | 999.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | pass | 0 | 260 | 33 / 1024 | 1249.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | pass | 0 | 261 | 40 / 1024 | 1500.1 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | pass | 0 | 262 | 47 / 1024 | 1749.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | pass | 0 | 263 | 53 / 1024 | 2000.1 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | pass | 0 | 264 | 59 / 1024 | 2250.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | pass | 0 | 265 | 66 / 1024 | 2499.6 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | pass | 0 | 266 | 114 / 1024 | 2750.4 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3000** | pass | 0 | 267 | 87 / 1024 | 3000.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 2) | pass | 0 | 267 | 81 / 1024 | 3000.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 3) | pass | 0 | 267 | 80 / 1024 | 3000.2 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | pass | 0 | 256 | 6 / 1024 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | pass | 0 | 257 | 13 / 1024 | 500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | pass | 0 | 258 | 59 / 1024 | 749.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | pass | 0 | 259 | 79 / 1024 | 1000.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | pass | 0 | 260 | 101 / 1024 | 1249.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | pass | 0 | 261 | 119 / 1024 | 1500.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | pass | 0 | 262 | 139 / 1024 | 1749.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | pass | 0 | 263 | 158 / 1024 | 2000.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | pass | 0 | 264 | 184 / 1024 | 2247.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | pass | 0 | 265 | 73 / 1024 | 2499.6 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2750** | pass | 0 | 266 | 80 / 1024 | 2743.2 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 (run 2) | pass | 0 | 266 | 78 / 1024 | 2748.6 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 (run 3) | pass | 0 | 266 | 229 / 1024 | 2750.4 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | drops | 1 413 280 | full | 1 024 / 1024 | 2786.9 | gaps | 3.69 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | pass | 0 | 256 | 19 / 1024 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | pass | 0 | 257 | 40 / 1024 | 500.0 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | pass | 0 | 258 | 59 / 1024 | 749.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | pass | 0 | 259 | 80 / 1024 | 1000.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | pass | 0 | 260 | 34 / 1024 | 1249.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | pass | 0 | 261 | 118 / 1024 | 1500.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | pass | 0 | 262 | 139 / 1024 | 1749.8 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | pass | 0 | 263 | 158 / 1024 | 2000.1 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | pass | 0 | 264 | 63 / 1024 | 2250.2 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | pass | 0 | 265 | 68 / 1024 | 2499.6 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | pass | 0 | 266 | 77 / 1024 | 2750.4 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3000** | pass | 0 | 267 | 924 / 1024 | 2830.2 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 2) | pass | 0 | 267 | 864 / 1024 | 2816.9 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 3) | pass | 0 | 267 | 840 / 1024 | 2845.5 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 500 | pass | 0 | 257 | 3 / 512 | 500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 750 | pass | 0 | 258 | 7 / 512 | 749.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1000 | pass | 0 | 259 | 10 / 512 | 999.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1250 | pass | 0 | 260 | 14 / 512 | 1249.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1500 | pass | 0 | 261 | 17 / 512 | 1500.1 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1750 | pass | 0 | 262 | 20 / 512 | 1749.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2000 | pass | 0 | 263 | 24 / 512 | 2000.1 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2250 | pass | 0 | 264 | 27 / 512 | 2250.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2500 | pass | 0 | 265 | 31 / 512 | 2499.6 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2750 | pass | 0 | 266 | 34 / 512 | 2750.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3000** | pass | 0 | 267 | 38 / 512 | 2993.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 2) | pass | 0 | 267 | 38 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 3) | pass | 0 | 267 | 38 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 250 | pass | 0 | 256 | 2 / 512 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 500 | pass | 0 | 257 | 3 / 512 | 500.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 750 | pass | 0 | 258 | 7 / 512 | 749.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1000 | pass | 0 | 259 | 10 / 512 | 999.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1250 | pass | 0 | 260 | 14 / 512 | 1249.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1500 | pass | 0 | 261 | 17 / 512 | 1500.1 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1750 | pass | 0 | 262 | 20 / 512 | 1749.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2000 | pass | 0 | 263 | 24 / 512 | 2000.1 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2250 | pass | 0 | 264 | 27 / 512 | 2250.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2500 | pass | 0 | 265 | 30 / 512 | 2499.6 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2750 | pass | 0 | 266 | 34 / 512 | 2750.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3000** | pass | 0 | 267 | 38 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 2) | pass | 0 | 267 | 37 / 512 | 3000.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 3) | pass | 0 | 267 | 38 / 512 | 2998.1 | pass | - |
<!-- nvbench:glance:end -->

### Burst and 40 GB recordings

"Burst" rows are 10 GB recordings (a sweep from 500 MB/s up to the first failing step or the
3200 MB/s source maximum: .., 3000, 3200); the
40 GB rows record at the sustained rate and one step above it. Trimmed drives, new volume and
60 s idle before every recording.

<!-- nvbench:burst:begin -->
| target | SSD | layout | recording | rate (MB/s) | result | FIFO high-water (of 4096 beats) | ring high-water (slots) | max in flight per SSD | latency avg (µs) | latency max (µs) |
|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 500 | pass | 257 | 12 / 1024 | 6 | 95 | 5383 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 750 | pass | 258 | 19 / 1024 | 9 | 101 | 6166 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1000 | pass | 259 | 26 / 1024 | 13 | 107 | 6477 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1250 | pass | 260 | 36 / 1024 | 18 | 114 | 7232 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1500 | pass | 261 | 40 / 1024 | 20 | 121 | 6738 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1750 | pass | 262 | 48 / 1024 | 24 | 128 | 6984 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2000 | pass | 263 | 55 / 1024 | 27 | 141 | 7011 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2250 | pass | 264 | 65 / 1024 | 32 | 155 | 7357 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2500 | pass | 265 | 70 / 1024 | 32 | 166 | 7212 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2750 | pass | 266 | 82 / 1024 | 32 | 183 | 7716 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 3000 | pass | 267 | 83 / 1024 | 32 | 194 | 7120 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 3200 | pass | 265 | 355 / 1024 | 32 | 270 | 15497 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GB | 3000 | pass | 267 | 86 / 1024 | 32 | 193 | 7387 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GB | 3200 (source max) | pass | 264 | 297 / 1024 | 32 | 219 | 24218 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 500 | pass | 257 | 14 / 1024 | 13 | 107 | 6654 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 750 | pass | 258 | 20 / 1024 | 19 | 121 | 6590 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1000 | pass | 259 | 29 / 1024 | 28 | 143 | 7172 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1250 | pass | 260 | 39 / 1024 | 32 | 165 | 7767 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1500 | pass | 261 | 44 / 1024 | 32 | 192 | 7376 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1750 | pass | 262 | 58 / 1024 | 32 | 244 | 8526 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2000 | pass | 263 | 64 / 1024 | 32 | 301 | 8180 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2250 | pass | 264 | 66 / 1024 | 32 | 404 | 7491 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2500 | pass | 265 | 71 / 1024 | 32 | 627 | 7245 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2750 | pass | 266 | 91 / 1024 | 32 | 1463 | 8516 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2969 | 10031 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GB | 2500 | pass | 265 | 197 / 1024 | 32 | 580 | 20500 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GB | 2750 | pass | 266 | 218 / 1024 | 32 | 1535 | 20593 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 500 | pass | 257 | 14 / 1024 | 13 | 107 | 6425 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 750 | pass | 258 | 20 / 1024 | 20 | 118 | 6643 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1000 | pass | 259 | 78 / 1024 | 32 | 152 | 20151 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1250 | pass | 260 | 98 / 1024 | 32 | 180 | 20299 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1500 | pass | 261 | 43 / 1024 | 32 | 195 | 7261 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1750 | pass | 262 | 139 / 1024 | 32 | 258 | 20562 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2000 | pass | 263 | 158 / 1024 | 32 | 306 | 20457 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2250 | pass | 264 | 65 / 1024 | 32 | 390 | 7394 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2500 | pass | 265 | 76 / 1024 | 32 | 568 | 7767 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2750 | pass | 266 | 85 / 1024 | 32 | 1522 | 7949 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2940 | 11113 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 40 GB | 2750 | pass | 266 | 216 / 1024 | 32 | 1490 | 20404 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 40 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2940 | 10092 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 500 | pass | 257 | 2 / 512 | 1 | 114 | 232 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 750 | pass | 258 | 2 / 512 | 1 | 114 | 233 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000 | pass | 259 | 2 / 512 | 1 | 114 | 232 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1250 | pass | 260 | 4 / 512 | 2 | 114 | 1020 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1500 | pass | 261 | 6 / 512 | 3 | 115 | 1619 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1750 | pass | 262 | 8 / 512 | 4 | 116 | 2086 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2000 | pass | 262 | 11 / 512 | 5 | 118 | 2431 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2250 | pass | 264 | 13 / 512 | 6 | 119 | 2618 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2500 | pass | 265 | 18 / 512 | 9 | 121 | 3379 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2750 | pass | 266 | 17 / 512 | 8 | 122 | 3016 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 3000 | pass | 267 | 21 / 512 | 10 | 124 | 3487 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 3200 | pass | 266 | 24 / 512 | 12 | 125 | 3757 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 3000 | pass | 266 | 22 / 512 | 11 | 124 | 3556 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 3200 (source max) | pass | 265 | 23 / 512 | 11 | 126 | 3589 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 500 | pass | 257 | 12 / 1024 | 6 | 52 | 5645 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 750 | pass | 258 | 19 / 1024 | 9 | 57 | 6034 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1000 | pass | 259 | 26 / 1024 | 13 | 63 | 6349 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1250 | pass | 260 | 34 / 1024 | 17 | 70 | 6866 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1500 | pass | 261 | 41 / 1024 | 20 | 76 | 6861 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1750 | pass | 262 | 46 / 1024 | 23 | 80 | 6675 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2000 | pass | 263 | 54 / 1024 | 27 | 94 | 6932 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2250 | pass | 264 | 65 / 1024 | 32 | 104 | 7359 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2500 | pass | 265 | 69 / 1024 | 32 | 114 | 7030 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2750 | pass | 266 | 87 / 1024 | 32 | 123 | 8197 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 3000 | pass | 267 | 82 / 1024 | 32 | 126 | 7052 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 3200 | pass | 265 | 394 / 1024 | 32 | 280 | 20974 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GB | 3000 | pass | 267 | 275 / 1024 | 32 | 136 | 23895 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GB | 3200 (source max) | pass | 265 | 93 / 1024 | 32 | 138 | 7484 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 500 | pass | 257 | 14 / 1024 | 13 | 63 | 6602 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 750 | pass | 258 | 20 / 1024 | 19 | 75 | 6534 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1000 | pass | 259 | 78 / 1024 | 32 | 114 | 20152 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1250 | pass | 260 | 35 / 1024 | 32 | 109 | 6972 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1500 | pass | 261 | 118 / 1024 | 32 | 145 | 20372 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1750 | pass | 262 | 48 / 1024 | 32 | 150 | 6910 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2000 | pass | 263 | 159 / 1024 | 32 | 187 | 20669 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2250 | pass | 264 | 177 / 1024 | 32 | 237 | 20435 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2500 | pass | 265 | 73 / 1024 | 32 | 235 | 7519 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2750 | pass | 266 | 80 / 1024 | 32 | 281 | 7445 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 3000 | pass | 267 | 84 / 1024 | 32 | 351 | 7228 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 3200 | pass | 267 | 271 / 1024 | 32 | 604 | 22111 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GB | 3000 | pass | 267 | 96 / 1024 | 32 | 347 | 8248 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GB | 3200 (source max) | pass | 266 | 95 / 1024 | 32 | 419 | 7658 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 500 | pass | 257 | 14 / 1024 | 13 | 63 | 6669 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 750 | pass | 258 | 20 / 1024 | 19 | 76 | 6635 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1000 | pass | 259 | 29 / 1024 | 28 | 90 | 7252 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1250 | pass | 260 | 34 / 1024 | 32 | 105 | 6909 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1500 | pass | 261 | 43 / 1024 | 32 | 126 | 7254 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1750 | pass | 262 | 49 / 1024 | 32 | 148 | 7191 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2000 | pass | 263 | 56 / 1024 | 32 | 167 | 7185 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2250 | pass | 264 | 65 / 1024 | 32 | 190 | 7390 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2500 | pass | 265 | 72 / 1024 | 32 | 211 | 7376 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2750 | pass | 266 | 82 / 1024 | 32 | 277 | 7649 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 3000 | pass | 267 | 83 / 1024 | 32 | 351 | 7152 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 3200 | pass | 265 | 730 / 1024 | 32 | 614 | 19023 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 40 GB | 3000 | pass | 267 | 91 / 1024 | 32 | 354 | 7854 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 40 GB | 3200 (source max) | pass | 266 | 328 / 1024 | 32 | 438 | 25542 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 500 | pass | 257 | 2 / 512 | 1 | 114 | 230 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 750 | pass | 258 | 4 / 512 | 3 | 115 | 1692 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1000 | pass | 259 | 5 / 512 | 4 | 116 | 2021 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1250 | pass | 260 | 9 / 512 | 8 | 119 | 2996 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1500 | pass | 261 | 10 / 512 | 9 | 124 | 3016 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1750 | pass | 262 | 14 / 512 | 13 | 129 | 3769 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2000 | pass | 263 | 17 / 512 | 16 | 132 | 4005 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2250 | pass | 264 | 17 / 512 | 16 | 137 | 3563 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2500 | pass | 265 | 19 / 512 | 18 | 144 | 3723 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2750 | pass | 266 | 21 / 512 | 20 | 153 | 3806 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 3000 | pass | 267 | 24 / 512 | 23 | 165 | 3933 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 3200 | pass | 266 | 25 / 512 | 24 | 177 | 3924 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GB | 3000 | pass | 268 | 41 / 512 | 32 | 171 | 6920 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GB | 3200 (source max) | pass | 265 | 27 / 512 | 26 | 177 | 4258 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 500 | pass | 257 | 2 / 512 | 1 | 114 | 210 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 750 | pass | 258 | 5 / 512 | 4 | 115 | 2193 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1000 | pass | 259 | 6 / 512 | 5 | 116 | 2241 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1250 | pass | 260 | 8 / 512 | 7 | 119 | 2801 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1500 | pass | 261 | 11 / 512 | 10 | 124 | 3276 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1750 | pass | 262 | 13 / 512 | 12 | 129 | 3522 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2000 | pass | 263 | 15 / 512 | 14 | 133 | 3459 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2250 | pass | 264 | 17 / 512 | 16 | 135 | 3612 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2500 | pass | 265 | 19 / 512 | 18 | 144 | 3683 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2750 | pass | 266 | 24 / 512 | 23 | 154 | 4222 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 3000 | pass | 267 | 26 / 512 | 25 | 166 | 4203 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 3200 | pass | 266 | 25 / 512 | 24 | 174 | 3906 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 40 GB | 3000 | pass | 267 | 26 / 512 | 25 | 168 | 4324 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 40 GB | 3200 (source max) | pass | 266 | 30 / 512 | 29 | 177 | 4598 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 500 | pass | 257 | 2 / 512 | 1 | 179 | 243 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 750 | pass | 258 | 2 / 512 | 1 | 179 | 243 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000 | pass | 259 | 2 / 512 | 1 | 179 | 243 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1250 | pass | 260 | 4 / 512 | 2 | 179 | 947 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1500 | pass | 261 | 6 / 512 | 3 | 180 | 1680 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1750 | pass | 262 | 8 / 512 | 4 | 181 | 2024 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2000 | pass | 263 | 11 / 512 | 5 | 183 | 2456 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2250 | pass | 264 | 13 / 512 | 6 | 184 | 2644 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2500 | pass | 265 | 17 / 512 | 8 | 186 | 3347 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 2750 | pass | 266 | 17 / 512 | 8 | 189 | 3046 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 3000 | pass | 383 | 20 / 512 | 10 | 191 | 3149 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 3200 | pass | 265 | 21 / 512 | 10 | 194 | 3239 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 3000 | pass | 267 | 23 / 512 | 11 | 191 | 3823 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 3200 (source max) | pass | 264 | 22 / 512 | 11 | 194 | 3330 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 500 | pass | 257 | 12 / 1024 | 6 | 96 | 5476 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 750 | pass | 258 | 19 / 1024 | 9 | 101 | 6197 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1000 | pass | 259 | 26 / 1024 | 13 | 106 | 6445 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1250 | pass | 260 | 34 / 1024 | 17 | 114 | 6742 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1500 | pass | 261 | 54 / 1024 | 27 | 124 | 9175 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 1750 | pass | 262 | 48 / 1024 | 24 | 129 | 6984 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2000 | pass | 263 | 55 / 1024 | 27 | 140 | 7024 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2250 | pass | 264 | 65 / 1024 | 32 | 149 | 7362 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2500 | pass | 265 | 68 / 1024 | 32 | 166 | 6966 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 2750 | pass | 266 | 93 / 1024 | 32 | 184 | 8739 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 3000 | pass | 267 | 82 / 1024 | 32 | 195 | 7059 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 10 GB | 3200 | pass | 264 | 387 / 1024 | 32 | 288 | 20238 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GB | 3000 | pass | 267 | 85 / 1024 | 32 | 198 | 7339 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 40 GB | 3200 (source max) | pass | 264 | 91 / 1024 | 32 | 206 | 7312 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 500 | pass | 257 | 14 / 1024 | 13 | 107 | 6638 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 750 | pass | 258 | 60 / 1024 | 32 | 160 | 20421 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1000 | pass | 259 | 79 / 1024 | 32 | 185 | 20233 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1250 | pass | 260 | 99 / 1024 | 32 | 182 | 20427 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1500 | pass | 261 | 43 / 1024 | 32 | 193 | 7297 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 1750 | pass | 262 | 139 / 1024 | 32 | 464 | 20543 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2000 | pass | 263 | 56 / 1024 | 32 | 296 | 7206 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2250 | pass | 264 | 65 / 1024 | 32 | 390 | 7427 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2500 | pass | 265 | 79 / 1024 | 32 | 594 | 8093 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 2750 | pass | 266 | 86 / 1024 | 32 | 1488 | 8028 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 10 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2958 | 23407 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GB | 2750 | pass | 266 | 354 / 1024 | 32 | 1946 | 23361 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 40 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2981 | 23525 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 500 | pass | 257 | 14 / 1024 | 13 | 105 | 6319 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 750 | pass | 258 | 21 / 1024 | 20 | 121 | 6922 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1000 | pass | 259 | 28 / 1024 | 27 | 139 | 6921 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1250 | pass | 260 | 36 / 1024 | 32 | 162 | 7229 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1500 | pass | 261 | 43 / 1024 | 32 | 187 | 7261 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 1750 | pass | 262 | 52 / 1024 | 32 | 234 | 7578 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2000 | pass | 263 | 158 / 1024 | 32 | 410 | 20521 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2250 | pass | 264 | 179 / 1024 | 32 | 596 | 20739 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2500 | pass | 265 | 197 / 1024 | 32 | 638 | 20519 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 2750 | pass | 266 | 209 / 1024 | 32 | 1555 | 19746 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 10 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2992 | 23136 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 40 GB | 2750 | pass | 266 | 488 / 1024 | 32 | 1807 | 23124 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 40 GB | 3000 | drops | full | 1 024 / 1024 | 32 | 2967 | 23324 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 500 | pass | 257 | 2 / 512 | 1 | 179 | 558 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 750 | pass | 258 | 4 / 512 | 3 | 180 | 1724 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1000 | pass | 259 | 6 / 512 | 5 | 182 | 2240 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1250 | pass | 260 | 8 / 512 | 7 | 186 | 2841 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1500 | pass | 261 | 10 / 512 | 9 | 192 | 3074 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 1750 | pass | 262 | 13 / 512 | 12 | 199 | 3397 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2000 | pass | 263 | 16 / 512 | 15 | 212 | 3901 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2250 | pass | 264 | 17 / 512 | 16 | 226 | 3621 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2500 | pass | 265 | 20 / 512 | 19 | 258 | 3798 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 2750 | pass | 266 | 22 / 512 | 21 | 342 | 3883 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 3000 | pass | 267 | 30 / 512 | 29 | 1080 | 5040 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 10 GB | 3200 | drops | full | 512 / 512 | 32 | 5436 | 9559 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GB | 3000 | pass | 267 | 39 / 512 | 32 | 1098 | 6503 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 40 GB | 3200 (source max) | drops | full | 512 / 512 | 32 | 5504 | 9753 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 500 | pass | 257 | 2 / 512 | 1 | 179 | 217 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 750 | pass | 258 | 5 / 512 | 4 | 180 | 2288 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1000 | pass | 259 | 7 / 512 | 6 | 182 | 2681 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1250 | pass | 260 | 8 / 512 | 7 | 185 | 2660 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1500 | pass | 261 | 10 / 512 | 9 | 191 | 3050 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 1750 | pass | 262 | 13 / 512 | 12 | 199 | 3298 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2000 | pass | 263 | 15 / 512 | 14 | 210 | 3521 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2250 | pass | 264 | 17 / 512 | 16 | 225 | 3671 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2500 | pass | 265 | 20 / 512 | 19 | 257 | 3803 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 2750 | pass | 266 | 22 / 512 | 21 | 324 | 3897 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 3000 | pass | 267 | 24 / 512 | 23 | 1019 | 3992 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 10 GB | 3200 | drops | full | 512 / 512 | 32 | 5439 | 9452 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 40 GB | 3000 | pass | 267 | 31 / 512 | 30 | 1064 | 5069 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 40 GB | 3200 (source max) | drops | full | 512 / 512 | 32 | 5499 | 9648 |
<!-- nvbench:burst:end -->

The 40 GB step above 3000 MB/s is the data generator's maximum, 3200 MB/s (source clock ×
16 bytes) on every board, so it is labelled "3200 (source max)" (and the 40 GB "highest clean"
in the summary "3200 MB/s (source max)"): the suite asked for 3250 MB/s, which the apps clamp to
the generator maximum; the suite now caps the rate itself. The 10 GB sweep ends at the same
3200 MB/s.

On the Gen3 x4 boards (`zcu106_hpc0`, `uzev`) one drive does not keep up with the source
maximum. One Samsung 980 PRO on `zcu106_hpc0` drops beats at 3200 MB/s over 10 GB, 32 GB and
40 GB with the ring full, at 3037-3039 MB/s achieved: a single 980 PRO tops out at about
3.04 GB/s on this path. One Sabrent Rocket tops out lower, at about 2.8 GB/s (its 3000 MB/s
steps average 2787-2846 MB/s), so its highest clean 10 GB and 40 GB step is 2750 MB/s on both
Gen3 boards. The RAID0 of either pair records 10 GB and 40 GB at 3200 MB/s with 0 drops. On
`vck190_fmcp1`, where the same drives link at PCIe Gen4 x4, every layout of both drive types
records 10 GB and 40 GB at 3200 MB/s with 0 drops (one 980 PRO: ring high-water 25-30 slots,
latency maximum 3.9-4.6 ms): the per-drive limits above are the Gen3 x4 links, not the drives.

### Post-cache sustained recording

On the 1 TB drives (Samsung 980 PRO 1TB, Sabrent Rocket) the SLC cache of an empty, trimmed
drive is larger than 32 GB, so the 32 GB sweep above measures an **in-cache** rate there. The
post-cache figure comes from long recordings (`nvbench-suite.sh longrun`: 200 GB by default,
trimmed drives, new volume, then a pre-idle) at the candidate rate found by the recorder's
characterisation of the drive and at one 250 MB/s step above it: the highest clean rate is the
rate the drive sustains after its cache is full. The cache sizes and post-cache (TLC) rates
below are cited from that characterisation, not measured on this design.

| SSD | SLC cache, empty and trimmed drive | post-cache (TLC) write rate | candidate rate for `longrun` | source |
|---|---|---|---|---|
| Samsung 980 PRO 1TB (ZCU106, Gen3 x4) | single: ~115-120 GB at ~3.0 GB/s (the Gen3 x4 link); RAID0 (2 drives): ~247 GB | single: ~1.77 GB/s (measured out to 322 GB); RAID0: ~3.26 GB/s (partly fio-bound) | single: 1500, 1750 and 3000 MB/s, 200 GB; RAID0: 2250, 2500 and 3000 MB/s, 350 GB (300 s pre-idle) | fpga-drive-recorder characterisation on the ZCU106, 2026-10-19 (fio QD8, 8 MB, O_DIRECT, fresh XFS); the recorder's own post-cache recordings passed at 1750 MB/s single (200 GiB; 2000 MB/s dropped at 127 GB, past the cache) and 2500 MB/s RAID0 (350 GiB; 2750-3200 MB/s lost 846-14 934 beats each in FIFO overflows) |
| Samsung 980 PRO 1TB (VCK190, Gen4 x4) | single: ~115-120 GB; RAID0 (2 drives): ~235-250 GB; both at ~4.7 GB/s | single: ~1.77 GB/s (measured out to 322 GB); RAID0: ~3.47 GB/s | the `zcu106_hpc0` parameters: single 1500, 1750 and 3000 MB/s, 200 GB; RAID0 2250, 2500 and 3000 MB/s, 350 GB (300 s pre-idle) | fpga-drive-recorder characterisation on the VCK190, 2026-10-18 (fio QD8, 8 MB, O_DIRECT, fresh XFS); the recorder's own post-cache recordings passed at 1750 MB/s single (240 GiB; 2000 MB/s dropped at the cache end) and 2000 MB/s RAID0 (480 GiB; 2250-3200 MB/s lost a few thousand beats each in isolated FIFO overflows) |
| Sabrent Rocket 2230 1TB (VCK190) | single: ~75 GB at ~4.5 GB/s; RAID0 (2 drives): ~140 GB at ~4.45 GB/s | single: ~1.80 GB/s (measured out to 320 GB); RAID0: ~3.6 GB/s | single: 1000 MB/s, 143 GiB; RAID0: 2750 MB/s, 240 GiB (300 s pre-idle) | fpga-drive-recorder characterisation on the VCK190, 2026-10-17 (fio QD8, 8 MB, O_DIRECT, fresh XFS); the recorder's own post-cache recordings at these rates and sizes passed |
| Sabrent Rocket 2230 1TB (ZCU106, Gen3 x4) | single: ~70-73 GB at ~2.9 GB/s (the Gen3 x4 link); RAID0: not visible to one fio job (~3.2 GB/s flat over 537 GB) | single: ~1.8 GB/s (median 1798 MB/s); RAID0: above ~3.2 GB/s | first the VCK190 parameters (single: 1000 and 1250 MB/s, 143 GiB; RAID0: 2750 and 3000 MB/s, 240 GiB), then the recorder's sizes (single: 1500, 1750 and 2000 MB/s, 200 GiB; RAID0: 3000 MB/s, 350 GiB); 300 s pre-idle | fpga-drive-recorder characterisation on the ZCU106, 2026-10-18/19 (fio QD8, 8 MB, O_DIRECT, fresh XFS); the recorder's own post-cache recordings passed at 1750 MB/s single (200 GiB; 2000 MB/s dropped at 96 GB) and 2250 MB/s RAID0 (350 GiB; 2500-3200 MB/s lost 1226-10 150 beats each in FIFO overflows) |

<!-- nvbench:longrun:begin -->
| target | SSD | layout | size | pre-idle (s) | rate (MB/s) | result | drops (beats) | NVMe errors | ring high-water (slots) | latency avg / max (µs) | nvverify | first gap |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 240 GiB | 300 | 2750 | pass | 0 | 0 | 458 / 1024 | 301 / 24356 | pass | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 240 GiB | 300 | 3000 | pass | 0 | 0 | 732 / 1024 | 563 / 29411 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 143 GiB | 300 | 1000 | pass | 0 | 0 | 160 / 1024 | 179 / 19119 | pass | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 143 GiB | 300 | 1250 | pass | 0 | 0 | 59 / 1024 | 232 / 12032 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 350 GB | 300 | 2250 | pass | 0 | 0 | 136 / 512 | 220 / 31362 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 350 GB | 300 | 2500 | pass | 0 | 0 | 156 / 512 | 255 / 32482 | pass | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 350 GB | 300 | 3000 | pass | 0 | 0 | 196 / 512 | 373 / 34005 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 240 GiB | 300 | 2750 | pass | 0 | 0 | 517 / 1024 | 233 / 19281 | pass | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 240 GiB | 300 | 3000 | pass | 0 | 0 | 677 / 1024 | 388 / 26121 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 143 GiB | 300 | 1000 | pass | 0 | 0 | 134 / 1024 | 143 / 25451 | pass | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 143 GiB | 300 | 1250 | pass | 0 | 0 | 100 / 1024 | 195 / 20689 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GB | 300 | 1500 | pass | 0 | 0 | 89 / 512 | 447 / 30757 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GB | 300 | 1750 | pass | 0 | 0 | 172 / 512 | 2106 / 43219 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GB | 300 | 3000 | drops | 3 241 893 172 | 0 | 512 / 512 | 3783 / 44178 | gaps | 1.22 GB |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 350 GB | 300 | 2250 | pass | 0 | 0 | 128 / 512 | 279 / 29563 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 350 GB | 300 | 2500 | pass | 0 | 0 | 157 / 512 | 318 / 32584 | pass | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 350 GB | 300 | 3000 | pass | 0 | 0 | 174 / 512 | 434 / 30150 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 240 GiB | 300 | 2750 | pass | 0 | 0 | 473 / 1024 | 282 / 19334 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 240 GiB | 300 | 3000 | pass | 0 | 0 | 653 / 1024 | 446 / 23436 | pass | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 350 GiB | 300 | 3000 | pass | 0 | 0 | 674 / 1024 | 564 / 31149 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 143 GiB | 300 | 1000 | pass | 0 | 0 | 108 / 1024 | 175 / 19724 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 143 GiB | 300 | 1250 | pass | 0 | 0 | 267 / 1024 | 274 / 29465 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 200 GiB | 300 | 1500 | pass | 0 | 0 | 204 / 1024 | 537 / 26542 | pass | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 200 GiB | 300 | 1750 | drops | 94 218 213 | 0 | 1 024 / 1024 | 3405 / 23322 | gaps | 86.82 GB |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 200 GiB | 300 | 2000 | drops | 1 434 686 058 | 0 | 1 024 / 1024 | 3418 / 25176 | gaps | 71.39 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GB | 300 | 1500 | pass | 0 | 0 | 88 / 512 | 498 / 30400 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GB | 300 | 1750 | pass | 0 | 0 | 175 / 512 | 2005 / 42871 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 200 GB | 300 | 3000 | drops | 3 161 651 259 | 0 | 512 / 512 | 4692 / 45142 | gaps | 1.13 GB |
<!-- nvbench:longrun:end -->

#### The ring-size finding

The ring absorbs the time an SSD takes to complete a write: a recording drops beats when a write
stall lasts longer than the ring holds data at the recording rate. The first `vck190_fmcp1`
measurements (2026-10-17) used the apps' previous default of 256 slots, whatever the chunk.
The Sabrent Rocket 2230 has an MDTS of 256 KB, so its chunk is 256 KB and that ring held only
64 MB, about 20 ms of data at 3000 MB/s, while the drive stalls a write for 20-30 ms now and then
(latency maximum in the tables). At high rates the ring filled and beats were dropped: every
failure of those runs was a full ring (256 of 256 slots) during such a stall, in the SLC cache
as well as after it, not a drive that was too slow. The same post-cache recordings with
`nvrec --buffers 1024` (1024 × 256 KB = 256 MB, the size of the recorder's 32 × 8 MB) recorded
with 0 drops. `nvrec` and `nvplay` therefore size the ring by bytes: 256 MB / chunk slots, 256 to
1024 (see [Ring size and CMA](apps)). The tables above are the re-run with that default; the
64 MB results are kept as the finding:

| `vck190_fmcp1`, 2x / 1x Sabrent SB-2130-1TB | 64 MB ring (256 × 256 KB) | 256 MB ring (1024 × 256 KB, default) |
|---|---|---|
| longrun RAID0, 240 GiB @ 2750 MB/s | drops: 811 295 beats, first gap at 137.25 GB (end of the ~140 GB cache), ring 256 / 256, latency max 22 652 µs | pass: 0 drops, ring 517 / 1024 (129 MB), latency max 19 281 µs |
| longrun RAID0, 240 GiB @ 3000 MB/s | drops: 49 397 143 beats, first gap at 10.15 GB, ring 256 / 256, latency max 31 210 µs | pass: 0 drops, ring 677 / 1024 (169 MB), latency max 26 121 µs |
| longrun single (SSD1), 143 GiB @ 1000 / 1250 MB/s | pass / pass (ring 108 / 160 of 256) | pass / pass (ring 134 / 100 of 1024) |
| 32 GB sweep, highest clean step (SSD1 / SSD2 / RAID0) | 1750 / 2500 / 1750 MB/s | 3200 / 3200 / 3200 MB/s (the source max) |
| 40 GB, highest clean (SSD1 / SSD2 / RAID0) | 2000 / 2750 / 2000 MB/s | 3200 / 3200 / 3200 MB/s (the source max) |
| 10 GB and 4000 MiB, highest clean; playback | 3000 MB/s (the top step of the sweeps then); playback 3000 MB/s clean | 10 GB 3200 MB/s, 4000 MiB 3000 MB/s (its top step); playback 3200 MB/s clean |

A manual check with `--buffers 1024` on the 64 MB image (same drives, same parameters) gave the
same result as the default: 2750 and 3000 MB/s over 240 GiB with 0 drops, ring 634 and 835
slots. The highest ring high-water mark of this fixture's 256 MB matrix is 927 slots (232 MB,
32 GB at 3200 MB/s on SSD2; SSD1 260 slots, the RAID0 416): at the source maximum one Sabrent
on Gen4 x4 is clean, but with little ring to spare. A drive with a small MDTS needs the ring in
bytes, not in slots.

#### Samsung 980 PRO on `zcu106_hpc0`

In the SLC cache one 980 PRO is clean to 3000 MB/s over 4000 MiB, 10 GB, 32 GB and 40 GB, and
drops beats at 3200 MB/s on every size (ring full, 3037-3039 MB/s achieved, first gap at
5.6 GB over 32 GB): the Gen3 x4 link. The RAID0 of two is clean at 3200 MB/s, the source
maximum, over 10 GB, 32 GB (ring high-water 21 slots, latency maximum 3.3 ms) and 40 GB.

Post-cache, one 980 PRO recorded 200 GB at 1500 and at 1750 MB/s with 0 drops (ring high-water
88 and 175 slots, latency maximum 30 and 43 ms). The RAID0 of two recorded 350 GB at 2250, 2500
and 3000 MB/s with 0 drops (ring high-water 128, 157 and 174 slots, at most 87 MB). The
recorder's post-cache recordings on the same board and drives pass at 1750 MB/s (single, the
drive's TLC rate) and 2500 MB/s (RAID0, where 2750-3200 MB/s lose beats in FIFO overflows when
a DMA restart is late). 200 GB at 3000 MB/s on one drive failed (average
2389 MB/s, ring full, first gap at 1.13 GB, run straight after the 1750 MB/s run on the same
drive with trim + 300 s idle in between); a single 980 PRO's post-cache rate on this path lies
between 1750 and 3000 MB/s (not narrowed further), while 40 GB at 3000 MB/s inside the cache
is clean.

Ring size on this drive: the 980 PRO has an MDTS of 512 KB, so the earlier default of 256 slots
was already 128 MB, and that run was clean to 3000 MB/s, the top step of the sweeps at the time,
on every layout too. The 256 MB re-run changed no pass or fail anywhere in the matrix; the clean runs used at
most 39 slots (20 MB) of the ring. Only the runs that fail by design drop fewer beats, because
the ring takes longer to fill: 40 GB at 3200 MB/s on one drive 125.7 M beats (128 MB ring:
133.7-134.3 M), `SSD_MAX_INFLIGHT` = 1 at 3000 MB/s 6.2-6.9 M beats (15.5 M).

#### Samsung 980 PRO on `vck190_fmcp1`

The same two drives on the VCK190 link at PCIe Gen4 x4 (16 GT/s) instead of Gen3 x4. The whole
matrix is clean (222 runs, 0 drops, 0 NVMe errors): 32 GB, 10 GB and 40 GB at the 3200 MB/s
source maximum on SSD1, SSD2 and the RAID0, 4000 MiB at 3000 MB/s (its top step), and playback
at 3200 MB/s on every layout, the single drives included. The 512 KB-chunk recordings used at
most 41 of the 512 ring slots (21 MB); at 3200 MB/s at most 27.

Post-cache the picture is the one of `zcu106_hpc0`, because there the drive's TLC rate is the
limit, not the link. One 980 PRO recorded 200 GB at 1500 and at 1750 MB/s with 0 drops (ring
high-water 89 and 172 slots, latency maximum 31 and 43 ms) and dropped beats at 3000 MB/s
(average 2378 MB/s, ring full, first gap at 1.22 GB). At 1750 MB/s the average command latency
rises to 2.1 ms (0.45 ms at 1500 MB/s): the drive works close to its post-cache rate, ~1.77 GB/s
in the recorder's characterisation, so 1750 MB/s is the single-drive post-cache rate with little
margin. The 3000 MB/s run followed the 1750 MB/s run on the same drive with trim + 300 s idle in
between; a first gap at 1.22 GB, well inside the ~115-120 GB cache of a rested drive, suggests
the drive had not finished moving the previous 200 GB out of its cache (a rested drive records
40 GB at 3200 MB/s). The RAID0 of two recorded 350 GB at 2250, 2500 and 3000 MB/s with 0 drops
(ring high-water 136, 156 and 196 slots, at most 98 MB; latency maximum 31-34 ms), below the
pair's post-cache rate of ~3.47 GB/s.

#### Sabrent Rocket on `zcu106_hpc0`

The two Sabrent Rocket 2230 1TB drives of the VCK190 measurements, on the M.2 M-key Stack FMC
on HPC0 of the ZCU106: both link at 8 GT/s x4 (PCIe Gen3, the board's limit; the drives are
Gen4), MaxPayload 128 bytes, MDTS 256 KB, so the chunk is 256 KB and the default ring
1024 × 256 KB = 256 MB.

One Sabrent records 2750 MB/s with 0 drops on every single-drive test (32 GB sweep, 10 GB, 40 GB,
4000 MiB 3/3) and fails at 3000 MB/s: the ring fills and the runs average 2787-2828 MB/s
(32 GB: first gap at 4.6-4.7 GB). A single Sabrent therefore tops out at about 2.8 GB/s on this
path, below the 980 PRO's ~3.04 GB/s on the same link. The 4000 MiB sweep of SSD2 shows
"3000 MB/s (3/3)" and that of SSD1 2750 MB/s, for the same drive model: a 4000 MiB recording at
3000 MB/s is short enough for the 256 MB ring to absorb the deficit (SSD2's three runs averaged
2817-2846 MB/s of drive throughput with the ring at 840-924 of 1024 slots), so its 3000 MB/s
is a ring effect, not a drive rate; 2750 MB/s is the rate one Sabrent holds on this path. `SSD_MAX_INFLIGHT` = 1 at 2750 MB/s
drops beats (2646-2670 MB/s); 2 commands in flight and more are clean.

The RAID0 of the two is clean at every step: 3200 MB/s (the source max) on the 32 GB sweep
(ring high-water 447 slots, latency maximum 20.6 ms), over 10 GB (387 slots) and 40 GB,
3000 MB/s over 4000 MiB (3/3), at 1 to 63 commands in flight and with 128 KB chunks. Playback
is clean to 3200 MB/s on all three layouts, one drive included: reading, one Sabrent keeps up
with the source maximum on this link.

Post-cache, with the parameters of the `vck190_fmcp1` run, one drive recorded 143 GiB at 1000
and 1250 MB/s with 0 drops (ring high-water 108 and 267 slots, latency maximum 20 and 29 ms) and
the RAID0 240 GiB at 2750 and 3000 MB/s with 0 drops (ring high-water 473 and 653 slots = 118
and 163 MB, latency maximum 19 and 23 ms), the same results as on `vck190_fmcp1` (Gen4 x4), with
similar ring use (VCK190: 517 and 677 slots for the RAID0). At the recorder's sizes, one drive
recorded 200 GiB at 1500 MB/s with 0 drops (ring high-water 204 slots, latency maximum 26.5 ms)
and dropped beats at 1750 MB/s (1735.9 MB/s achieved, ring full, first gap at 86.8 GB) and at
2000 MB/s (1804.7 MB/s achieved, first gap at 71.4 GB): the first gaps lie at the end of the
~72 GB SLC cache, after which the drive writes ~1.74-1.80 GB/s, right at the 1750 MB/s step.
The RAID0 recorded 350 GiB at 3000 MB/s with 0 drops (ring high-water 674 slots, latency maximum
31.1 ms). `nvverify` passed every clean recording and found gaps but no corrupt data in the failing
1750 MB/s one;
0 NVMe errors in the whole matrix. The recorder on the same board and drives recorded one drive
at 1750 MB/s over 200 GiB without a drop, where this design's 1750 MB/s run dropped beats; its
RAID0 is clean at 2250 MB/s over 350 GiB (2500-3200 MB/s lose beats in FIFO overflows at
buffer boundaries), where this design records 3000 MB/s over the same 350 GiB. The highest ring
high-water mark of a clean run is 924 slots (231 MB, 4000 MiB at 3000 MB/s on one drive, see
above); 838 slots with 128 KB chunks at 2750 MB/s.

#### Sabrent Rocket on `uzev`

The same two Sabrent Rocket 2230 1TB drives on the M.2 M-key Stack FMC on the HPC connector of
the UltraZed-EV carrier, the first hardware run of the `uzev` target: both link at 8 GT/s x4
(PCIe Gen3, the XDMA root ports' limit), MaxPayload 128 bytes, MaxReadReq 512 bytes, MDTS
256 KB, so the chunk is 256 KB and the default ring 1024 × 256 KB = 256 MB, which fits the 1 GB
CMA pool of this image. The results are those of `zcu106_hpc0`, whose block design this target
shares: 200 runs, 0 NVMe errors.

One Sabrent records 2750 MB/s with 0 drops on 10 GB, 40 GB and with 2 to 63 commands in flight,
and fails at 3000 MB/s: the ring fills and the runs average 2796-2839 MB/s, the same ~2.8 GB/s
per drive as on the ZCU106. On the 32 GB sweep, SSD2 is clean to 2750 MB/s as on the ZCU106;
SSD1 is clean to 2500 MB/s and drops beats at 2750 MB/s (average 2700.6 MB/s, first gap at
14.9 GB), close to the drive's limit on this path: the 2500 MB/s step already used 745 of the
1024 ring slots. As on the ZCU106, the 4000 MiB runs at 3000 MB/s count as clean (3/3) only
because the ring absorbed the deficit (2821-2834 MB/s of drive throughput, ring at 906-989
slots), and `SSD_MAX_INFLIGHT` = 1 at 2750 MB/s is at the edge (SSD2 dropped beats at
2663 MB/s; SSD1 was clean at 2694 MB/s with the ring at 879 slots).

The RAID0 of the two is clean at every step: 3200 MB/s (the source max) on the 32 GB sweep
(ring high-water 640 slots at 3000 MB/s, 251 at 3200 MB/s with a latency maximum of 20.4 ms),
over 10 GB (355 slots) and 40 GB (297 slots), 3000 MB/s over 4000 MiB (3/3), at 1 to 63 commands
in flight and with 128 KB chunks. Playback is clean to 3200 MB/s on all three layouts, the
single drives included (0 underflows).

Post-cache, with the parameters of the other Sabrent runs, one drive recorded 143 GiB at 1000
and 1250 MB/s with 0 drops (ring high-water 160 and 59 slots, latency maximum 19 and 12 ms) and
the RAID0 240 GiB at 2750 and 3000 MB/s with 0 drops (ring high-water 458 and 732 slots = 115
and 183 MB, latency maximum 24 and 29 ms); `nvverify` passed all four. `nvrec` used 1.0 % of
a Cortex-A53 core at 1000 MB/s on one drive and 1.3 % on the RAID0, 0.14-0.34 % during the
long recordings; `nvplay` 0.64 %. The 15.1 % "busy, summed over the cores" of the RAID0
playback row is the median of 0.6 % and 29.5 %: the second run coincided with the benchmark
host's periodic SSH poll of the board (user time on one core, none of it `nvplay`'s).

### Playback

10 GB recording made at 1000 MB/s with 0 drops, `nvplay` from 250 MB/s in 250 MB/s steps up to
the 3200 MB/s source maximum (.., 3000, 3200),
queue depth 32 per SSD, 256 MB ring (the default).

<!-- nvbench:playback:begin -->
| target | SSD | layout | highest clean playback rate | clean runs | first rate with underflows | top step tried |
|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | **3200 MB/s** | 3/3 | none up to the top step | 3200 MB/s |
<!-- nvbench:playback:end -->

Every playback step:

<!-- nvbench:playback-steps:begin -->
| target | SSD | layout | rate (MB/s) | result | underflow ticks | checker errors | streaming MB/s | prefill (s) | ring high-water | read latency avg (µs) | read latency max (µs) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.043 | 1 024 / 1024 | 217 | 3100 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.042 | 1 024 / 1024 | 216 | 3202 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.043 | 1 024 / 1024 | 217 | 3179 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | clean | 0 | 0 | 1000.0 | 0.043 | 1 024 / 1024 | 216 | 3157 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.043 | 1 024 / 1024 | 216 | 3285 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.042 | 1 024 / 1024 | 217 | 3156 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.043 | 1 024 / 1024 | 217 | 3205 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.043 | 1 024 / 1024 | 217 | 3324 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.042 | 1 024 / 1024 | 217 | 3137 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.042 | 1 024 / 1024 | 217 | 3243 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.043 | 1 024 / 1024 | 217 | 3104 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.042 | 1 024 / 1024 | 217 | 3235 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.042 | 1 024 / 1024 | 217 | 3189 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.042 | 1 024 / 1024 | 217 | 3289 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.043 | 1 024 / 1024 | 217 | 3212 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.043 | 1 024 / 1024 | 217 | 3142 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.043 | 1 024 / 1024 | 217 | 3295 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.085 | 1 024 / 1024 | 219 | 3217 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.085 | 1 024 / 1024 | 218 | 3319 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.085 | 1 024 / 1024 | 219 | 3264 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | clean | 0 | 0 | 1000.0 | 0.085 | 1 024 / 1024 | 219 | 3197 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.085 | 1 024 / 1024 | 219 | 3170 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.085 | 1 024 / 1024 | 219 | 3279 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.085 | 1 024 / 1024 | 221 | 3352 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.085 | 1 024 / 1024 | 221 | 3490 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.085 | 1 024 / 1024 | 222 | 3291 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.084 | 1 024 / 1024 | 225 | 3127 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.085 | 1 024 / 1024 | 231 | 3186 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.084 | 1 024 / 1024 | 246 | 3206 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 246 | 3364 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 245 | 3224 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.085 | 1 024 / 1024 | 2494 | 3538 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3200.4 | 0.085 | 1 024 / 1024 | 2467 | 3467 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3200.4 | 0.084 | 1 024 / 1024 | 2469 | 3515 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.084 | 1 024 / 1024 | 218 | 3260 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.084 | 1 024 / 1024 | 218 | 3178 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.084 | 1 024 / 1024 | 218 | 3150 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | clean | 0 | 0 | 1000.0 | 0.084 | 1 024 / 1024 | 218 | 3315 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.085 | 1 024 / 1024 | 219 | 3215 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.085 | 1 024 / 1024 | 219 | 3407 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.085 | 1 024 / 1024 | 221 | 3297 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.084 | 1 024 / 1024 | 221 | 3168 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.084 | 1 024 / 1024 | 222 | 3486 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.084 | 1 024 / 1024 | 225 | 3240 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.085 | 1 024 / 1024 | 230 | 3289 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 247 | 3383 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.084 | 1 024 / 1024 | 245 | 3268 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 246 | 3157 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.085 | 1 024 / 1024 | 2479 | 3528 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3200.4 | 0.085 | 1 024 / 1024 | 2471 | 3437 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3200.4 | 0.084 | 1 024 / 1024 | 2492 | 3451 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 250 | clean | 0 | 0 | 250.0 | 0.034 | 512 / 512 | 245 | 7546 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 500 | clean | 0 | 0 | 500.0 | 0.034 | 512 / 512 | 243 | 6935 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 750 | clean | 0 | 0 | 750.0 | 0.034 | 512 / 512 | 240 | 8589 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1000 | clean | 0 | 0 | 1000.0 | 0.034 | 512 / 512 | 243 | 6922 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.034 | 512 / 512 | 244 | 7356 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.034 | 512 / 512 | 244 | 7355 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.034 | 512 / 512 | 248 | 8091 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.034 | 512 / 512 | 244 | 7320 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.034 | 512 / 512 | 245 | 7712 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.034 | 512 / 512 | 240 | 6584 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.034 | 512 / 512 | 243 | 6800 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.034 | 512 / 512 | 243 | 7318 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.035 | 512 / 512 | 244 | 6943 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.035 | 512 / 512 | 247 | 7896 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.034 | 512 / 512 | 249 | 7240 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.034 | 512 / 512 | 251 | 8264 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.034 | 512 / 512 | 246 | 8310 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.034 | 1 024 / 1024 | 194 | 2627 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.034 | 1 024 / 1024 | 194 | 3001 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.034 | 1 024 / 1024 | 194 | 2630 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | clean | 0 | 0 | 1000.0 | 0.034 | 1 024 / 1024 | 194 | 2625 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.034 | 1 024 / 1024 | 194 | 2671 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.034 | 1 024 / 1024 | 193 | 2955 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.034 | 1 024 / 1024 | 193 | 3079 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.034 | 1 024 / 1024 | 194 | 2629 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.034 | 1 024 / 1024 | 193 | 3090 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.034 | 1 024 / 1024 | 193 | 2725 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.034 | 1 024 / 1024 | 194 | 2628 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.034 | 1 024 / 1024 | 194 | 2664 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.034 | 1 024 / 1024 | 193 | 2666 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.034 | 1 024 / 1024 | 194 | 2867 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.034 | 1 024 / 1024 | 194 | 2582 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.034 | 1 024 / 1024 | 193 | 2613 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.034 | 1 024 / 1024 | 194 | 2528 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.059 | 1 024 / 1024 | 188 | 2620 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.059 | 1 024 / 1024 | 188 | 2434 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.059 | 1 024 / 1024 | 188 | 2451 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | clean | 0 | 0 | 1000.0 | 0.059 | 1 024 / 1024 | 188 | 2401 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.059 | 1 024 / 1024 | 188 | 2379 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.059 | 1 024 / 1024 | 188 | 2413 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.059 | 1 024 / 1024 | 188 | 2429 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.059 | 1 024 / 1024 | 189 | 2675 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.059 | 1 024 / 1024 | 191 | 2320 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.059 | 1 024 / 1024 | 192 | 2619 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.059 | 1 024 / 1024 | 193 | 2372 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.060 | 1 024 / 1024 | 197 | 2431 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.059 | 1 024 / 1024 | 197 | 2655 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.059 | 1 024 / 1024 | 197 | 2407 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.060 | 1 024 / 1024 | 211 | 2641 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.060 | 1 024 / 1024 | 212 | 2424 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.060 | 1 024 / 1024 | 211 | 2586 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.060 | 1 024 / 1024 | 189 | 2453 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.059 | 1 024 / 1024 | 188 | 2444 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.059 | 1 024 / 1024 | 189 | 2467 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.060 | 1 024 / 1024 | 189 | 2445 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.060 | 1 024 / 1024 | 189 | 2454 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.059 | 1 024 / 1024 | 188 | 2528 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.060 | 1 024 / 1024 | 189 | 2454 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.060 | 1 024 / 1024 | 190 | 2453 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.059 | 1 024 / 1024 | 191 | 2454 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.060 | 1 024 / 1024 | 192 | 2521 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.060 | 1 024 / 1024 | 194 | 2490 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.060 | 1 024 / 1024 | 197 | 2704 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.059 | 1 024 / 1024 | 198 | 2484 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.059 | 1 024 / 1024 | 198 | 2531 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.059 | 1 024 / 1024 | 211 | 2456 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.059 | 1 024 / 1024 | 211 | 2636 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.059 | 1 024 / 1024 | 211 | 2603 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 250 | clean | 0 | 0 | 250.0 | 0.043 | 512 / 512 | 213 | 3480 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 500 | clean | 0 | 0 | 500.0 | 0.043 | 512 / 512 | 211 | 3432 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 750 | clean | 0 | 0 | 750.0 | 0.043 | 512 / 512 | 210 | 3433 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.043 | 512 / 512 | 210 | 3560 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.043 | 512 / 512 | 210 | 3394 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.043 | 512 / 512 | 210 | 3513 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.043 | 512 / 512 | 210 | 3434 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.043 | 512 / 512 | 210 | 3469 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.043 | 512 / 512 | 210 | 3540 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.043 | 512 / 512 | 210 | 3578 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.043 | 512 / 512 | 210 | 3405 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 210 | 3442 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 210 | 3458 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 210 | 3440 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 | clean | 0 | 0 | 3200.4 | 0.043 | 512 / 512 | 213 | 3292 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 213 | 3373 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 (run 3) | clean | 0 | 0 | 3200.4 | 0.043 | 512 / 512 | 213 | 3491 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 250 | clean | 0 | 0 | 250.0 | 0.043 | 512 / 512 | 213 | 3388 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 500 | clean | 0 | 0 | 500.0 | 0.043 | 512 / 512 | 210 | 3434 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 750 | clean | 0 | 0 | 750.0 | 0.043 | 512 / 512 | 210 | 3370 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.043 | 512 / 512 | 210 | 3554 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.043 | 512 / 512 | 210 | 3515 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.043 | 512 / 512 | 210 | 3577 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.042 | 512 / 512 | 210 | 3295 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.043 | 512 / 512 | 210 | 3568 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.043 | 512 / 512 | 211 | 3818 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.043 | 512 / 512 | 210 | 3438 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.043 | 512 / 512 | 210 | 3520 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 210 | 3283 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 210 | 3670 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 210 | 3437 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 214 | 3598 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 213 | 3556 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 218 | 3918 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 250 | clean | 0 | 0 | 250.0 | 0.043 | 512 / 512 | 293 | 10619 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 500 | clean | 0 | 0 | 500.0 | 0.043 | 512 / 512 | 294 | 10969 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 750 | clean | 0 | 0 | 750.0 | 0.043 | 512 / 512 | 292 | 9649 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.043 | 512 / 512 | 294 | 10819 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.043 | 512 / 512 | 291 | 11149 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.043 | 512 / 512 | 291 | 10616 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.043 | 512 / 512 | 295 | 10597 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.043 | 512 / 512 | 293 | 9819 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.043 | 512 / 512 | 295 | 9376 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.043 | 512 / 512 | 295 | 9723 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.043 | 512 / 512 | 297 | 8776 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 295 | 9917 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 296 | 11154 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.043 | 512 / 512 | 297 | 9727 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 301 | 9685 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 293 | 11143 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.043 | 512 / 512 | 296 | 9260 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.042 | 1 024 / 1024 | 217 | 3195 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.043 | 1 024 / 1024 | 216 | 3270 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.043 | 1 024 / 1024 | 216 | 3194 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.043 | 1 024 / 1024 | 217 | 3149 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.042 | 1 024 / 1024 | 217 | 3374 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.043 | 1 024 / 1024 | 216 | 3333 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.043 | 1 024 / 1024 | 217 | 3192 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.043 | 1 024 / 1024 | 217 | 3217 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.042 | 1 024 / 1024 | 217 | 3264 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.042 | 1 024 / 1024 | 217 | 3322 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.043 | 1 024 / 1024 | 217 | 3243 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.043 | 1 024 / 1024 | 217 | 3243 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.043 | 1 024 / 1024 | 217 | 3212 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.043 | 1 024 / 1024 | 217 | 3445 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.043 | 1 024 / 1024 | 217 | 3466 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.042 | 1 024 / 1024 | 217 | 3187 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.043 | 1 024 / 1024 | 217 | 3169 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.085 | 1 024 / 1024 | 218 | 3262 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.084 | 1 024 / 1024 | 218 | 3097 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.085 | 1 024 / 1024 | 218 | 3247 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.085 | 1 024 / 1024 | 218 | 3219 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.085 | 1 024 / 1024 | 218 | 3490 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.085 | 1 024 / 1024 | 218 | 3236 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.085 | 1 024 / 1024 | 221 | 3172 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.085 | 1 024 / 1024 | 221 | 3240 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.085 | 1 024 / 1024 | 222 | 3274 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.085 | 1 024 / 1024 | 225 | 3263 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.084 | 1 024 / 1024 | 230 | 3309 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 246 | 3201 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.084 | 1 024 / 1024 | 245 | 3420 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 245 | 3310 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.084 | 1 024 / 1024 | 2461 | 3440 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.084 | 1 024 / 1024 | 2450 | 3543 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.085 | 1 024 / 1024 | 2451 | 3506 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 250 | clean | 0 | 0 | 250.0 | 0.085 | 1 024 / 1024 | 219 | 3248 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 500 | clean | 0 | 0 | 500.0 | 0.084 | 1 024 / 1024 | 218 | 3219 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 750 | clean | 0 | 0 | 750.0 | 0.085 | 1 024 / 1024 | 219 | 3226 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.085 | 1 024 / 1024 | 219 | 3646 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.084 | 1 024 / 1024 | 220 | 3199 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.085 | 1 024 / 1024 | 219 | 3167 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.085 | 1 024 / 1024 | 221 | 3305 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.085 | 1 024 / 1024 | 221 | 3094 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.084 | 1 024 / 1024 | 223 | 3156 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.085 | 1 024 / 1024 | 225 | 3192 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.084 | 1 024 / 1024 | 231 | 3251 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 247 | 3260 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 246 | 3187 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.085 | 1 024 / 1024 | 246 | 3282 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.085 | 1 024 / 1024 | 2448 | 3540 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.085 | 1 024 / 1024 | 2448 | 3538 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.085 | 1 024 / 1024 | 2447 | 3477 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 250 | clean | 0 | 0 | 250.0 | 0.085 | 512 / 512 | 303 | 11414 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 500 | clean | 0 | 0 | 500.0 | 0.085 | 512 / 512 | 301 | 9258 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 750 | clean | 0 | 0 | 750.0 | 0.085 | 512 / 512 | 301 | 9734 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.085 | 512 / 512 | 301 | 9329 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.085 | 512 / 512 | 301 | 11277 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.085 | 512 / 512 | 301 | 9528 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.085 | 512 / 512 | 300 | 9495 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.085 | 512 / 512 | 301 | 10916 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.085 | 512 / 512 | 301 | 10035 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.085 | 512 / 512 | 300 | 8644 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.085 | 512 / 512 | 301 | 9469 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.085 | 512 / 512 | 301 | 9536 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.085 | 512 / 512 | 301 | 9962 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.085 | 512 / 512 | 301 | 10825 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.085 | 512 / 512 | 4840 | 10152 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.085 | 512 / 512 | 4852 | 10308 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.085 | 512 / 512 | 4807 | 11429 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 250 | clean | 0 | 0 | 250.0 | 0.085 | 512 / 512 | 303 | 9315 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 500 | clean | 0 | 0 | 500.0 | 0.085 | 512 / 512 | 301 | 8643 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 750 | clean | 0 | 0 | 750.0 | 0.085 | 512 / 512 | 301 | 9805 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1000 | clean | 0 | 0 | 999.9 | 0.085 | 512 / 512 | 301 | 9301 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1250 | clean | 0 | 0 | 1250.0 | 0.085 | 512 / 512 | 301 | 9780 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1500 | clean | 0 | 0 | 1500.1 | 0.085 | 512 / 512 | 301 | 9474 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1750 | clean | 0 | 0 | 1749.9 | 0.085 | 512 / 512 | 301 | 10750 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2000 | clean | 0 | 0 | 1999.9 | 0.085 | 512 / 512 | 301 | 11117 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2250 | clean | 0 | 0 | 2250.1 | 0.085 | 512 / 512 | 301 | 10577 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2500 | clean | 0 | 0 | 2500.0 | 0.085 | 512 / 512 | 301 | 8649 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2750 | clean | 0 | 0 | 2749.7 | 0.085 | 512 / 512 | 301 | 8815 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 | clean | 0 | 0 | 3000.1 | 0.085 | 512 / 512 | 301 | 8902 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 2) | clean | 0 | 0 | 3000.1 | 0.085 | 512 / 512 | 301 | 10326 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3000 (run 3) | clean | 0 | 0 | 3000.1 | 0.085 | 512 / 512 | 301 | 9888 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 | clean | 0 | 0 | 3199.5 | 0.085 | 512 / 512 | 4806 | 10068 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 (run 2) | clean | 0 | 0 | 3199.5 | 0.085 | 512 / 512 | 4876 | 10039 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 3200 (run 3) | clean | 0 | 0 | 3199.5 | 0.085 | 512 / 512 | 4821 | 10313 |
<!-- nvbench:playback-steps:end -->

**Playback right after a long recording.** Right after a large recording the drives are still
moving it out of their SLC cache, which can slow their reads. Measured here on the RAID0 of two
980 PROs on `zcu106_hpc0`: a 10 GB recording at 1000 MB/s, 300 s idle, then
350 GB at 3000 MB/s (0 drops, ring high-water 240 of 512 slots), then `nvplay` of the 10 GB
file at 1500, 2000, 2500, 3000 and 3200 MB/s starting the moment the 350 GB recording ended
(t + 0-21 s), and the same sweep again after 10 minutes of idle (t + 605-626 s). Every step of
both sweeps played with 0 underflows and 0 checker errors (read latency maximum 8.3-10.5 ms right
after, 9.4-10.1 ms after the idle); the 350 GB recording then passed `nvverify`. With 32 reads
in flight per drive and a 256 MB ring prefilled before the sink starts, a playback needs no
idle time after a recording.

### CPU load

10 GB at 1000 MB/s, two runs each, medians; method as described [above](#cpu-load).

<!-- nvbench:cpu:begin -->
| target | transfer | SSD | layout | cores | total CPU % of all cores (usr / sys / irq / iowait) | busy, summed over the cores (% of one core) | process % of one core | MB/s per % core | runs (median) |
|---|---|---|---|---|---|---|---|---|---|
| `uzev` | `nvrec`, 1000 MB/s, 10 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 0.1 / 0.4 / 0.0 / 0.8 | 1.9 | 1.33 | 749 | 2 |
| `uzev` | `nvplay`, 1000 MB/s, 10 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 3.0 / 0.9 / 0.0 / 0.8 | 15.1 | 0.64 | 1 562 | 2 |
| `uzev` | `nvrec`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 0.0 / 0.3 / 0.0 / 0.1 | 1.3 | 1.01 | 990 | 2 |
| `uzev` | `nvplay`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.1 | 0.8 | 0.64 | 1 562 | 2 |
| `uzev` | `nvrec`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 0.0 / 0.3 / 0.0 / 0.6 | 1.2 | 0.95 | 1 058 | 2 |
| `uzev` | `nvplay`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.1 | 0.8 | 0.64 | 1 562 | 2 |
| `vck190_fmcp1` | `nvrec`, 1000 MB/s, 10 GB | 2x 980 PRO 1TB | RAID0, 512K chunk | 2 | 0.1 / 0.5 / 0.0 / 2.5 | 1.2 | 0.53 | 1 887 | 2 |
| `vck190_fmcp1` | `nvplay`, 1000 MB/s, 10 GB | 2x 980 PRO 1TB | RAID0, 512K chunk | 2 | 0.0 / 0.2 / 0.0 / 0.1 | 0.4 | 0.33 | 3 077 | 2 |
| `vck190_fmcp1` | `nvrec`, 1000 MB/s, 10 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 0.1 / 0.6 / 0.0 / 2.5 | 1.5 | 0.79 | 1 266 | 2 |
| `vck190_fmcp1` | `nvplay`, 1000 MB/s, 10 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 0.0 / 0.2 / 0.0 / 0.8 | 0.4 | 0.33 | 3 077 | 2 |
| `vck190_fmcp1` | `nvrec`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 0.3 / 0.6 / 0.0 / 0.2 | 1.9 | 0.55 | 1 818 | 2 |
| `vck190_fmcp1` | `nvplay`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 0.0 / 0.2 / 0.0 / 0.1 | 0.4 | 0.33 | 3 077 | 2 |
| `vck190_fmcp1` | `nvrec`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | 0.0 / 0.3 / 0.0 / 0.2 | 0.9 | 0.55 | 1 818 | 2 |
| `vck190_fmcp1` | `nvplay`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | 0.0 / 0.2 / 0.0 / 0.1 | 0.5 | 0.28 | 3 571 | 2 |
| `vck190_fmcp1` | `nvrec`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 0.0 / 0.3 / 0.0 / 0.3 | 0.6 | 0.46 | 2 174 | 2 |
| `vck190_fmcp1` | `nvplay`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 0.0 / 0.2 / 0.0 / 0.1 | 0.5 | 0.37 | 2 702 | 2 |
| `vck190_fmcp1` | `nvrec`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2 | 0.1 / 0.3 / 0.0 / 1.9 | 0.6 | 0.42 | 2 353 | 2 |
| `vck190_fmcp1` | `nvplay`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2 | 0.0 / 0.2 / 0.0 / 0.1 | 0.4 | 0.28 | 3 571 | 2 |
| `zcu106_hpc0` | `nvrec`, 1000 MB/s, 10 GB | 2x 980 PRO 1TB | RAID0, 512K chunk | 4 | 0.1 / 0.4 / 0.0 / 0.2 | 2.0 | 1.01 | 990 | 2 |
| `zcu106_hpc0` | `nvplay`, 1000 MB/s, 10 GB | 2x 980 PRO 1TB | RAID0, 512K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.0 | 0.7 | 0.55 | 1 818 | 2 |
| `zcu106_hpc0` | `nvrec`, 1000 MB/s, 10 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 0.1 / 0.5 / 0.0 / 0.2 | 2.3 | 1.23 | 810 | 2 |
| `zcu106_hpc0` | `nvplay`, 1000 MB/s, 10 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.0 | 0.8 | 0.60 | 1 666 | 2 |
| `zcu106_hpc0` | `nvrec`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.1 | 1.2 | 0.97 | 1 036 | 2 |
| `zcu106_hpc0` | `nvplay`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.0 | 0.7 | 0.59 | 1 681 | 2 |
| `zcu106_hpc0` | `nvrec`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 0.0 / 0.3 / 0.0 / 0.1 | 1.3 | 0.97 | 1 036 | 2 |
| `zcu106_hpc0` | `nvplay`, 1000 MB/s, 10 GB | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.0 | 0.7 | 0.59 | 1 681 | 2 |
| `zcu106_hpc0` | `nvrec`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 0.1 / 0.2 / 0.0 / 0.2 | 1.3 | 0.83 | 1 205 | 2 |
| `zcu106_hpc0` | `nvplay`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.0 | 0.9 | 0.59 | 1 681 | 2 |
| `zcu106_hpc0` | `nvrec`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 4 | 0.0 / 0.3 / 0.0 / 0.2 | 1.1 | 0.73 | 1 360 | 2 |
| `zcu106_hpc0` | `nvplay`, 1000 MB/s, 10 GB | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 4 | 0.0 / 0.2 / 0.0 / 0.0 | 0.9 | 0.55 | 1 818 | 2 |
<!-- nvbench:cpu:end -->

With the 256 MB ring the process figures are a few tenths of a percent higher than with the
earlier 128 MB / 64 MB rings (`zcu106_hpc0`: record 0.73-0.83 % single and 1.01 % RAID0 against
0.55 % and 0.73 %; playback 0.55-0.59 % against 0.28-0.33 %): allocating and mapping the larger
ring and its PRP lists is a one-off setup cost, spread over a 10 s transfer. During the
transfer the CPU is still idle.

### Chunk size

<!-- nvbench:chunk:begin -->
| target | SSD | layout | chunk (= NVMe command) | ring | rate (MB/s) | result | avg MB/s | latency min / avg / max (µs) | max in flight per SSD | ring high-water |
|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0 | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 47 / 122 / 7037 | 32 | 163 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0 | 256 KB | 1024 x 256 KB | 3000 | pass | 2996.8 | 90 / 195 / 7215 | 32 | 84 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1) | 128 KB | 1024 x 128 KB | 2750 | pass | 2749.0 | 47 / 893 / 7985 | 32 | 169 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1) | 256 KB | 1024 x 256 KB | 2750 | pass | 2749.7 | 90 / 1487 / 7894 | 32 | 84 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2) | 128 KB | 1024 x 128 KB | 2750 | pass | 2749.7 | 47 / 925 / 16983 | 32 | 471 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2) | 256 KB | 1024 x 256 KB | 2750 | pass | 2749.0 | 90 / 1636 / 17521 | 32 | 219 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0 | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 34 / 43 / 3144 | 32 | 73 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0 | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 61 / 70 / 3332 | 20 | 40 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0 | 512 KB | 512 x 512 KB | 3000 | pass | 3000.1 | 114 / 123 / 3018 | 9 | 19 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 25 / 88 / 6990 | 32 | 161 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 46 / 127 / 7167 | 32 | 84 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | 128 KB | 1024 x 128 KB | 3000 | pass | 2999.3 | 25 / 218 / 9220 | 32 | 213 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 46 / 347 / 9012 | 32 | 105 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2) | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 25 / 202 / 7606 | 32 | 176 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2) | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 46 / 349 / 7427 | 32 | 86 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 34 / 63 / 3824 | 32 | 89 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 60 / 109 / 4433 | 32 | 52 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | 512 KB | 512 x 512 KB | 3000 | pass | 3000.1 | 114 / 165 / 3912 | 23 | 24 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2) | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 34 / 62 / 3936 | 32 | 92 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2) | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 61 / 107 / 4246 | 32 | 50 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2) | 512 KB | 512 x 512 KB | 3000 | pass | 3000.1 | 114 / 167 / 3913 | 23 | 24 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0 | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 51 / 62 / 2857 | 32 | 67 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0 | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 93 / 105 / 3075 | 18 | 37 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0 | 512 KB | 512 x 512 KB | 3000 | pass | 3000.1 | 179 / 191 / 3150 | 10 | 20 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | 128 KB | 1024 x 128 KB | 3000 | pass | 3000.1 | 47 / 124 / 7432 | 32 | 172 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 90 / 195 / 7178 | 32 | 84 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | 128 KB | 1024 x 128 KB | 2750 | pass | 2728.7 | 47 / 1408 / 22860 | 32 | 838 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | 256 KB | 1024 x 256 KB | 2750 | pass | 2741.2 | 90 / 2427 / 23420 | 32 | 312 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2) | 128 KB | 1024 x 128 KB | 2750 | pass | 2745.4 | 47 / 851 / 7672 | 32 | 162 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2) | 256 KB | 1024 x 256 KB | 2750 | pass | 2749.7 | 90 / 1577 / 16588 | 32 | 242 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | 128 KB | 1024 x 128 KB | 3000 | pass | 2998.4 | 78 / 588 / 3913 | 32 | 91 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | 256 KB | 1024 x 256 KB | 3000 | pass | 2997.6 | 147 / 933 / 4004 | 32 | 47 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | 512 KB | 512 x 512 KB | 3000 | pass | 2997.6 | 185 / 1042 / 4565 | 27 | 28 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2) | 128 KB | 1024 x 128 KB | 3000 | pass | 2996.8 | 79 / 564 / 4088 | 32 | 95 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2) | 256 KB | 1024 x 256 KB | 3000 | pass | 3000.1 | 146 / 898 / 4250 | 32 | 50 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2) | 512 KB | 512 x 512 KB | 3000 | pass | 3000.1 | 184 / 1180 / 5448 | 32 | 33 |
<!-- nvbench:chunk:end -->

### Commands in flight

<!-- nvbench:inflight:begin -->
| target | SSD | layout | SSD_MAX_INFLIGHT | rate (MB/s) | result | avg MB/s | latency min / avg / max (µs) | max in flight seen | ring high-water (slots) | FIFO high-water |
|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1 | 3000 | pass | 3000.1 | 90 / 95 / 7090 | 1 | 83 / 1024 | 267 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 3000 | pass | 3000.1 | 90 / 105 / 7610 | 2 | 89 / 1024 | 267 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 3000 | pass | 3000.1 | 90 / 121 / 7141 | 4 | 87 / 1024 | 267 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8 | 3000 | pass | 3000.1 | 90 / 144 / 7086 | 8 | 83 / 1024 | 267 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 16 | 3000 | pass | 2996.8 | 90 / 168 / 7114 | 16 | 83 / 1024 | 267 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 32 | 3000 | pass | 3000.1 | 90 / 195 / 7385 | 32 | 86 / 1024 | 267 |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 63 | 3000 | pass | 3000.1 | 90 / 200 / 7358 | 43 | 86 / 1024 | 267 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1 | 2750 | pass | 2693.8 | 90 / 97 / 7493 | 1 | 879 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 2750 | pass | 2749.0 | 90 / 159 / 7205 | 2 | 82 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 2750 | pass | 2746.1 | 90 / 279 / 7496 | 4 | 80 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 8 | 2750 | pass | 2749.7 | 90 / 503 / 7513 | 8 | 95 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 16 | 2750 | pass | 2749.7 | 90 / 902 / 8050 | 16 | 86 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 32 | 2750 | pass | 2749.7 | 90 / 1453 / 8060 | 32 | 86 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 63 | 2750 | pass | 2747.5 | 90 / 1822 / 8474 | 63 | 90 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1 | 2750 | drops | 2663.1 | 90 / 98 / 20578 | 1 | 1 024 / 1024 | full |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | 2750 | pass | 2749.7 | 90 / 157 / 7636 | 2 | 90 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 2750 | pass | 2749.7 | 90 / 275 / 7492 | 4 | 107 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 8 | 2750 | pass | 2748.3 | 90 / 476 / 7596 | 8 | 93 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 16 | 2750 | pass | 2746.1 | 90 / 826 / 8147 | 16 | 87 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 32 | 2750 | pass | 2749.7 | 90 / 1287 / 7742 | 32 | 83 / 1024 | 266 |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 63 | 2750 | pass | 2749.0 | 90 / 1662 / 7434 | 63 | 79 / 1024 | 266 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1 | 3000 | pass | 3000.1 | 114 / 116 / 3088 | 1 | 19 / 512 | 267 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2 | 3000 | pass | 3000.1 | 114 / 118 / 2989 | 2 | 19 / 512 | 266 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 4 | 3000 | pass | 3000.1 | 114 / 121 / 3120 | 4 | 19 / 512 | 266 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 8 | 3000 | pass | 3000.1 | 114 / 123 / 2951 | 8 | 18 / 512 | 266 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 16 | 3000 | pass | 3000.1 | 114 / 123 / 3015 | 9 | 19 / 512 | 266 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 32 | 3000 | pass | 3000.1 | 114 / 123 / 3160 | 10 | 20 / 512 | 267 |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 63 | 3000 | pass | 3000.1 | 114 / 123 / 3655 | 11 | 22 / 512 | 266 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1 | 3000 | pass | 3000.1 | 46 / 54 / 7266 | 1 | 85 / 1024 | 267 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 3000 | pass | 3000.1 | 46 / 61 / 7307 | 2 | 88 / 1024 | 267 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 3000 | pass | 3000.1 | 46 / 73 / 7102 | 4 | 83 / 1024 | 267 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8 | 3000 | pass | 3000.1 | 46 / 90 / 7143 | 8 | 83 / 1024 | 267 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 16 | 3000 | pass | 3000.1 | 46 / 110 / 7458 | 16 | 87 / 1024 | 267 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 32 | 3000 | pass | 3000.1 | 46 / 136 / 7485 | 32 | 87 / 1024 | 267 |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 63 | 3000 | pass | 3000.1 | 46 / 133 / 7366 | 43 | 86 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1 | 3000 | pass | 2997.6 | 46 / 56 / 7525 | 1 | 99 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 3000 | pass | 3000.1 | 46 / 74 / 7221 | 2 | 84 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 3000 | pass | 3000.1 | 46 / 110 / 7551 | 4 | 111 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 8 | 3000 | pass | 3000.1 | 46 / 166 / 7831 | 8 | 91 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 16 | 3000 | pass | 2998.4 | 46 / 267 / 7515 | 16 | 88 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 32 | 3000 | pass | 3000.1 | 46 / 359 / 7284 | 32 | 85 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 63 | 3000 | pass | 3000.1 | 46 / 410 / 7536 | 63 | 88 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1 | 3000 | pass | 3000.1 | 46 / 56 / 7591 | 1 | 106 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | 3000 | pass | 3000.1 | 46 / 73 / 8074 | 2 | 101 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 3000 | pass | 2996.8 | 46 / 105 / 7416 | 4 | 87 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 8 | 3000 | pass | 3000.1 | 46 / 157 / 7084 | 8 | 83 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 16 | 3000 | pass | 3000.1 | 46 / 238 / 9548 | 16 | 111 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 32 | 3000 | pass | 3000.1 | 46 / 328 / 7143 | 32 | 83 / 1024 | 267 |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 63 | 3000 | pass | 3000.1 | 46 / 419 / 7442 | 63 | 87 / 1024 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1 | 3000 | pass | 3000.1 | 114 / 116 / 3844 | 1 | 23 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 3000 | pass | 3000.1 | 113 / 120 / 4302 | 2 | 26 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 3000 | pass | 3000.1 | 114 / 128 / 3897 | 4 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 8 | 3000 | pass | 3000.1 | 114 / 143 / 4522 | 8 | 27 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 16 | 3000 | pass | 3000.1 | 114 / 161 / 3922 | 16 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 32 | 3000 | pass | 3000.1 | 114 / 164 / 3858 | 23 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 63 | 3000 | pass | 3000.1 | 114 / 163 / 3858 | 23 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1 | 3000 | pass | 3000.1 | 114 / 116 / 3871 | 1 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2 | 3000 | pass | 3000.1 | 114 / 120 / 3852 | 2 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 4 | 3000 | pass | 3000.1 | 114 / 128 / 4527 | 4 | 27 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 8 | 3000 | pass | 3000.1 | 114 / 142 / 3889 | 8 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 16 | 3000 | pass | 3000.1 | 114 / 162 / 3902 | 16 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 32 | 3000 | pass | 3000.1 | 114 / 165 / 3868 | 23 | 24 / 512 | 267 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 63 | 3000 | pass | 3000.1 | 114 / 165 / 3984 | 23 | 24 / 512 | 266 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1 | 3000 | pass | 3000.1 | 179 / 180 / 3129 | 1 | 19 / 512 | 267 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2 | 3000 | pass | 3000.1 | 179 / 183 / 3010 | 2 | 19 / 512 | 267 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 4 | 3000 | pass | 3000.1 | 179 / 187 / 3366 | 4 | 21 / 512 | 267 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 8 | 3000 | pass | 3000.1 | 179 / 190 / 3052 | 8 | 19 / 512 | 267 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 16 | 3000 | pass | 3000.1 | 179 / 190 / 3120 | 9 | 19 / 512 | 267 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 32 | 3000 | pass | 3000.1 | 179 / 191 / 3217 | 10 | 20 / 512 | 267 |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 63 | 3000 | pass | 3000.1 | 179 / 190 / 3006 | 9 | 19 / 512 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1 | 3000 | pass | 3000.1 | 90 / 95 / 7103 | 1 | 85 / 1024 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 3000 | pass | 3000.1 | 90 / 104 / 7189 | 2 | 85 / 1024 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 3000 | pass | 3000.1 | 90 / 121 / 7134 | 4 | 83 / 1024 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8 | 3000 | pass | 3000.1 | 90 / 140 / 7349 | 8 | 86 / 1024 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 16 | 3000 | pass | 3000.1 | 90 / 171 / 7042 | 16 | 82 / 1024 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 32 | 3000 | pass | 3000.1 | 90 / 198 / 7337 | 32 | 85 / 1024 | 267 |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 63 | 3000 | pass | 3000.1 | 90 / 194 / 7115 | 41 | 83 / 1024 | 267 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1 | 2750 | drops | 2646.0 | 90 / 99 / 20719 | 1 | 1 024 / 1024 | full |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 2750 | pass | 2745.4 | 90 / 175 / 20756 | 2 | 274 / 1024 | 308 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 2750 | pass | 2748.3 | 90 / 319 / 20974 | 4 | 294 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 8 | 2750 | pass | 2749.7 | 90 / 512 / 7761 | 8 | 97 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 16 | 2750 | pass | 2749.0 | 90 / 877 / 8268 | 16 | 88 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 32 | 2750 | pass | 2746.8 | 90 / 1586 / 8508 | 32 | 95 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 63 | 2750 | pass | 2749.0 | 90 / 2101 / 7913 | 63 | 85 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1 | 2750 | drops | 2670.3 | 90 / 98 / 20566 | 1 | 1 024 / 1024 | full |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | 2750 | pass | 2748.3 | 90 / 158 / 7657 | 2 | 82 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 2750 | pass | 2747.5 | 90 / 265 / 7408 | 4 | 84 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 8 | 2750 | pass | 2749.7 | 90 / 480 / 7692 | 8 | 82 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 16 | 2750 | pass | 2749.0 | 90 / 884 / 20491 | 16 | 216 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 32 | 2750 | pass | 2749.7 | 90 / 1344 / 7971 | 32 | 85 / 1024 | 266 |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 63 | 2750 | pass | 2745.4 | 90 / 2142 / 20436 | 63 | 216 / 1024 | 266 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1 | 3000 | drops | 2895.7 | 179 / 181 / 3921 | 1 | 512 / 512 | full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 3000 | pass | 3000.1 | 184 / 312 / 4003 | 2 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 3000 | pass | 3000.1 | 185 / 416 / 4332 | 4 | 30 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 8 | 3000 | pass | 3000.1 | 185 / 641 / 3997 | 8 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 16 | 3000 | pass | 3000.1 | 185 / 954 / 4073 | 16 | 25 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 32 | 3000 | pass | 3000.1 | 185 / 1094 / 4392 | 26 | 27 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 63 | 3000 | pass | 3000.1 | 185 / 1017 / 3991 | 23 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1 | 3000 | drops | 2895.7 | 179 / 181 / 4029 | 1 | 512 / 512 | full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2 | 3000 | pass | 2999.3 | 185 / 324 / 3983 | 2 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 4 | 3000 | pass | 3000.1 | 184 / 415 / 3989 | 4 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 8 | 3000 | pass | 3000.1 | 185 / 639 / 3977 | 8 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 16 | 3000 | pass | 3000.1 | 185 / 937 / 3958 | 16 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 32 | 3000 | pass | 3000.1 | 185 / 1013 / 3979 | 23 | 24 / 512 | 267 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 63 | 3000 | pass | 2999.3 | 184 / 1045 / 4451 | 26 | 27 / 512 | 267 |
<!-- nvbench:inflight:end -->

With `SSD_MAX_INFLIGHT` = 1 a drive has one command at a time, so its write rate is the chunk
divided by the command latency. On a single Samsung 980 PRO on `zcu106_hpc0` (PCIe Gen3 x4)
that is 512 KB / ~181 µs = ~2.9 GB/s: both drives recorded at 2895.7 MB/s and dropped beats at
3000 MB/s, while two or more commands in flight were clean. On `vck190_fmcp1` (Gen4 x4) the same
drives complete a 512 KB write in ~116 µs (minimum 114 µs), 512 KB / 116 µs = ~4.5 GB/s, so one
command at a time is clean at 3000 MB/s there. The Sabrent Rocket's 256 KB commands take
~97 µs on the Gen3 x4 boards, 256 KB / 97 µs = ~2.7 GB/s: at qd 1 one Sabrent drops beats at
2750 MB/s on `zcu106_hpc0` (2646-2670 MB/s) and with SSD2 on `uzev` (2663 MB/s), while SSD1 on
`uzev` stayed clean at 2694 MB/s only because the ring took the deficit (879 of 1024 slots). On
`vck190_fmcp1` the same command takes ~56 µs (~4.7 GB/s) and qd 1 is clean at 3000 MB/s. A
RAID0 of two drives has two commands in flight even at qd 1 and stays clean. Keep the default
of 32.

Completion-latency histogram of the same runs:

<!-- nvbench:latency-histogram:begin -->
| target | SSD | layout | SSD_MAX_INFLIGHT | 32.8 µs – 65.5 µs | 65.5 µs – 131 µs | 131 µs – 262 µs | 262 µs – 524 µs | 524 µs – 1.04858 ms | 1.04858 ms – 2.09715 ms | 2.09715 ms – 4.19431 ms | 4.19431 ms – 8.38862 ms | 8.38862 ms – 16.7772 ms | 16.7772 ms – 33.5545 ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1 | - | 99.4 % | 36 cmds | 0.2 % | 0.3 % | 6 cmds | - | 14 cmds | - | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | - | 94.1 % | 5.0 % | 0.3 % | 0.5 % | 24 cmds | - | 30 cmds | - | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | - | 93.7 % | 0.7 % | 4.3 % | 0.8 % | 0.3 % | - | 0.1 % | - | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8 | - | 93.6 % | 0.6 % | 1.2 % | 3.8 % | 0.5 % | 8 cmds | 0.3 % | - | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 16 | - | 94.0 % | 0.6 % | 1.2 % | 1.5 % | 2.2 % | 7 cmds | 0.6 % | - | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 32 | - | 94.5 % | 0.7 % | 1.2 % | 1.1 % | 0.6 % | 0.9 % | 1.1 % | - | - |
| `uzev` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 63 | - | 94.6 % | 0.7 % | 1.1 % | 1.1 % | 0.5 % | 0.9 % | 1.2 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1 | - | 99.0 % | 0.3 % | 0.2 % | 0.4 % | 36 cmds | - | 15 cmds | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | - | 31.3 % | 67.0 % | 0.6 % | 0.8 % | 0.2 % | - | 30 cmds | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | - | 32.4 % | 3.8 % | 61.5 % | 1.3 % | 0.9 % | 4 cmds | 0.1 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 8 | - | 31.1 % | 3.5 % | 6.4 % | 56.2 % | 2.3 % | 0.2 % | 0.3 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 16 | - | 28.5 % | 3.2 % | 6.2 % | 11.1 % | 47.9 % | 2.4 % | 0.6 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 32 | - | 28.2 % | 3.3 % | 6.1 % | 11.0 % | 14.4 % | 35.1 % | 1.9 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 63 | - | 32.0 % | 3.6 % | 6.3 % | 11.6 % | 12.4 % | 16.3 % | 17.9 % | 10 cmds | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1 | - | 99.1 % | 0.2 % | 0.2 % | 0.4 % | 39 cmds | - | 12 cmds | - | 3 cmds |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | - | 32.7 % | 65.7 % | 0.5 % | 0.8 % | 0.2 % | - | 28 cmds | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | - | 33.4 % | 3.8 % | 60.5 % | 1.2 % | 0.8 % | 4 cmds | 0.1 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 8 | - | 34.8 % | 3.5 % | 7.1 % | 52.1 % | 2.1 % | 0.1 % | 0.3 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 16 | - | 33.4 % | 3.7 % | 6.5 % | 10.9 % | 42.9 % | 2.0 % | 0.6 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 32 | - | 33.9 % | 3.5 % | 6.3 % | 11.3 % | 13.2 % | 29.8 % | 1.9 % | - | - |
| `uzev` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 63 | - | 33.9 % | 3.4 % | 6.8 % | 12.1 % | 13.8 % | 14.2 % | 15.7 % | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1 | - | 98.7 % | 1.2 % | - | - | - | 10 cmds | - | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2 | - | 98.8 % | 0.6 % | 0.5 % | 2 cmds | - | 20 cmds | - | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 4 | - | 98.9 % | 0.4 % | 0.2 % | 0.2 % | - | 0.2 % | - | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 8 | - | 99.2 % | 0.2 % | 16 cmds | 0.1 % | 0.2 % | 0.2 % | - | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 16 | - | 99.2 % | 0.2 % | 16 cmds | 0.1 % | 0.2 % | 0.2 % | - | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 32 | - | 99.2 % | 0.2 % | 17 cmds | 0.1 % | 0.2 % | 0.2 % | - | - | - |
| `vck190_fmcp1` | 2x 980 PRO 1TB | RAID0, 512K chunk | 63 | - | 99.2 % | 0.2 % | 15 cmds | 0.1 % | 0.2 % | 0.2 % | - | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1 | 91.0 % | 8.3 % | 0.3 % | 0.2 % | 0.3 % | 9 cmds | - | 15 cmds | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | 91.5 % | 4.1 % | 3.4 % | 0.4 % | 0.4 % | 17 cmds | - | 30 cmds | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | 92.0 % | 3.1 % | 0.9 % | 3.1 % | 0.6 % | 0.2 % | - | 0.1 % | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8 | 92.3 % | 2.7 % | 0.5 % | 1.3 % | 2.7 % | 0.2 % | - | 0.3 % | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 16 | 93.0 % | 2.2 % | 0.5 % | 0.9 % | 1.6 % | 1.2 % | - | 0.5 % | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 32 | 93.4 % | 1.7 % | 0.5 % | 1.0 % | 1.3 % | 0.9 % | 0.2 % | 0.9 % | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 63 | 94.4 % | 1.2 % | 0.7 % | 0.9 % | 0.9 % | 0.4 % | 0.6 % | 0.9 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1 | 97.9 % | 0.9 % | 0.4 % | 0.2 % | 0.5 % | 28 cmds | - | 15 cmds | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 77.9 % | 19.4 % | 0.8 % | 0.8 % | 0.9 % | 0.1 % | - | 28 cmds | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | 76.7 % | 1.4 % | 18.1 % | 1.6 % | 1.2 % | 0.8 % | 5 cmds | 0.1 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 8 | 77.4 % | 1.4 % | 1.7 % | 14.5 % | 2.9 % | 1.8 % | 21 cmds | 0.3 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 16 | 76.1 % | 1.5 % | 1.7 % | 2.8 % | 13.3 % | 3.4 % | 0.7 % | 0.6 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 32 | 76.3 % | 1.3 % | 1.6 % | 2.9 % | 5.1 % | 10.3 % | 1.4 % | 1.1 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 63 | 78.1 % | 1.4 % | 1.7 % | 2.8 % | 5.0 % | 5.1 % | 3.7 % | 2.2 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1 | 98.0 % | 0.8 % | 0.4 % | 0.2 % | 0.5 % | 33 cmds | - | 15 cmds | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | 78.1 % | 19.3 % | 0.9 % | 0.6 % | 0.9 % | 0.1 % | 2 cmds | 30 cmds | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | 78.5 % | 1.4 % | 16.5 % | 1.6 % | 1.3 % | 0.6 % | 4 cmds | 0.1 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 8 | 78.9 % | 1.4 % | 1.6 % | 13.3 % | 2.9 % | 1.6 % | 8 cmds | 0.3 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 16 | 78.4 % | 1.4 % | 1.7 % | 2.8 % | 12.2 % | 2.9 % | 37 cmds | 0.5 % | 16 cmds | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 32 | 78.4 % | 1.3 % | 1.6 % | 2.8 % | 4.7 % | 9.3 % | 0.7 % | 1.2 % | - | - |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 63 | 78.0 % | 1.3 % | 1.5 % | 2.9 % | 5.0 % | 5.3 % | 3.7 % | 2.3 % | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1 | - | 99.9 % | 18 cmds | - | - | - | 10 cmds | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | - | 97.3 % | 2.6 % | 9 cmds | - | - | 18 cmds | 2 cmds | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | - | 97.4 % | 18 cmds | 2.3 % | - | - | 0.2 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 8 | - | 97.3 % | 19 cmds | 0.2 % | 2.0 % | 2 cmds | 0.4 % | 7 cmds | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 16 | - | 97.3 % | 19 cmds | 0.2 % | 0.4 % | 1.2 % | 0.8 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 32 | - | 97.4 % | 17 cmds | 0.2 % | 0.4 % | 0.7 % | 1.3 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 63 | - | 97.4 % | 20 cmds | 0.2 % | 0.4 % | 0.7 % | 1.2 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1 | - | 99.9 % | 15 cmds | - | 1 cmds | - | 11 cmds | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2 | - | 97.4 % | 2.5 % | 9 cmds | - | - | 20 cmds | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 4 | - | 97.4 % | 19 cmds | 2.3 % | - | - | 0.2 % | 4 cmds | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 8 | - | 97.4 % | 0.1 % | 0.2 % | 2.0 % | 1 cmds | 0.4 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 16 | - | 97.2 % | 0.1 % | 0.2 % | 0.4 % | 1.3 % | 0.8 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 32 | - | 97.2 % | 0.1 % | 0.2 % | 0.4 % | 0.8 % | 1.3 % | - | - | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 63 | - | 97.3 % | 18 cmds | 0.2 % | 0.4 % | 0.7 % | 1.3 % | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 1 | - | - | 100.0 % | - | - | - | 10 cmds | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 2 | - | - | 99.2 % | 0.7 % | 6 cmds | - | 20 cmds | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 4 | - | - | 99.2 % | 14 cmds | 0.5 % | - | 0.2 % | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 8 | - | - | 99.3 % | 12 cmds | 0.1 % | 0.3 % | 0.2 % | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 16 | - | - | 99.2 % | 18 cmds | 0.2 % | 0.3 % | 0.3 % | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 32 | - | - | 99.2 % | 15 cmds | 0.1 % | 0.3 % | 0.3 % | - | - | - |
| `zcu106_hpc0` | 2x 980 PRO 1TB | RAID0, 512K chunk | 63 | - | - | 99.3 % | 11 cmds | 0.1 % | 0.3 % | 0.2 % | - | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 1 | - | 99.4 % | 32 cmds | 0.2 % | 0.3 % | 5 cmds | - | 15 cmds | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 2 | - | 94.3 % | 4.8 % | 0.3 % | 0.5 % | 24 cmds | - | 28 cmds | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 4 | - | 93.8 % | 0.6 % | 4.3 % | 0.8 % | 0.3 % | - | 0.1 % | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 8 | - | 93.8 % | 0.6 % | 1.3 % | 3.6 % | 0.3 % | - | 0.3 % | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 16 | - | 93.7 % | 0.6 % | 1.2 % | 1.7 % | 2.3 % | 6 cmds | 0.6 % | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 32 | - | 94.5 % | 0.6 % | 1.1 % | 1.1 % | 0.6 % | 0.9 % | 1.2 % | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | 63 | - | 94.5 % | 0.7 % | 1.2 % | 1.2 % | 0.5 % | 0.8 % | 1.1 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 1 | - | 99.0 % | 0.3 % | 0.2 % | 0.4 % | 27 cmds | - | 10 cmds | - | 5 cmds |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | - | 15.5 % | 82.7 % | 0.6 % | 0.8 % | 0.2 % | - | 22 cmds | - | 8 cmds |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | - | 19.8 % | 2.2 % | 75.7 % | 1.2 % | 1.1 % | 8 cmds | 0.1 % | - | 12 cmds |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 8 | - | 30.1 % | 3.4 % | 6.0 % | 57.7 % | 2.3 % | 0.2 % | 0.3 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 16 | - | 30.2 % | 3.5 % | 6.3 % | 10.5 % | 46.6 % | 2.2 % | 0.6 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 32 | - | 24.0 % | 3.0 % | 5.6 % | 11.2 % | 14.7 % | 39.1 % | 2.3 % | 14 cmds | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 63 | - | 25.5 % | 3.0 % | 5.8 % | 11.4 % | 14.9 % | 16.7 % | 22.6 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 1 | - | 99.1 % | 0.2 % | 0.2 % | 0.4 % | 30 cmds | - | 13 cmds | 2 cmds | 1 cmds |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 2 | - | 32.4 % | 66.0 % | 0.5 % | 0.9 % | 0.2 % | - | 30 cmds | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 4 | - | 36.9 % | 3.8 % | 57.2 % | 1.3 % | 0.7 % | 2 cmds | 0.1 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 8 | - | 34.2 % | 3.8 % | 6.6 % | 52.8 % | 2.1 % | 0.2 % | 0.3 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 16 | - | 30.8 % | 3.1 % | 5.8 % | 10.1 % | 47.6 % | 2.0 % | 0.5 % | - | 16 cmds |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 32 | - | 32.0 % | 3.5 % | 6.5 % | 11.2 % | 13.2 % | 31.8 % | 1.9 % | - | - |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD2), 256K chunk | 63 | - | 29.2 % | 3.2 % | 5.8 % | 10.7 % | 13.0 % | 13.3 % | 24.4 % | 0.2 % | 0.2 % |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 1 | - | - | 100.0 % | - | - | - | 10 cmds | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | - | - | 23.1 % | 76.9 % | - | - | 18 cmds | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | - | - | 52.2 % | 4.4 % | 43.2 % | - | 0.2 % | 4 cmds | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 8 | - | - | 55.1 % | 4.4 % | 6.3 % | 33.9 % | 0.4 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 16 | - | - | 54.7 % | 4.4 % | 6.3 % | 12.6 % | 22.1 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 32 | - | - | 51.5 % | 4.4 % | 6.7 % | 13.8 % | 23.3 % | 0.2 % | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 63 | - | - | 55.1 % | 4.4 % | 6.3 % | 12.6 % | 21.7 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 1 | - | - | 100.0 % | - | - | - | 10 cmds | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 2 | - | - | 15.7 % | 84.2 % | - | - | 20 cmds | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 4 | - | - | 52.1 % | 4.8 % | 42.8 % | - | 0.2 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 8 | - | - | 55.2 % | 4.4 % | 6.3 % | 33.7 % | 0.4 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 16 | - | - | 55.3 % | 4.4 % | 6.3 % | 12.6 % | 21.4 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 32 | - | - | 55.2 % | 4.4 % | 6.3 % | 12.6 % | 21.6 % | - | - | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD2), 512K chunk | 63 | - | - | 54.5 % | 4.2 % | 6.3 % | 12.6 % | 22.1 % | 0.3 % | - | - |

Share of the recording's NVMe Write commands per completion-latency bin (submit to CQE, `nvrec_core` histogram, dp_clk cycles converted to µs); bins below 0.1 % give the number of commands.
<!-- nvbench:latency-histogram:end -->

## The SLC cache

Most consumer SSDs write into a fast pseudo-SLC cache first and move the data to their TLC
flash later; once the cache is full, the write rate drops. A recorder writes at a constant rate
for as long as the recording lasts, so the rate after the cache is the one that counts. The
32 GB steps are the recorder page's choice: they exhaust the cache of the small drives measured
there (970 EVO 250GB: ~14 GB). Larger drives can have caches well beyond 32 GB when they are
empty and trimmed, as they are at the start of every step here; for those the 40 GB rows, and
the first-gap offsets of the failing steps, show where the cache ends. Size the rate for the
longest recording you need: a short burst test overstates what a drive sustains.
