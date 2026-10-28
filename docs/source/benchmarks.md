# Benchmarks

This page explains how the NVMe-offload recorder is measured and lists the results per target
and SSD pair. The method is the one of the sibling design
[fpga-drive-recorder](https://recorder.fpgadrive.com/en/latest/benchmarks.html) (Linux and
io_uring issue the NVMe commands there; here the fabric does), with the same SSDs, sizes and
pass criteria, so that the two designs can be compared line by line: see
[Comparison with fpga-drive-recorder](comparison). Every figure was measured on hardware; the
target, the SSDs, their firmware and the date are given in [Setups](#setups).
[Ceilings at a glance](#ceilings-at-a-glance) lists every limit that was found, per device
family, with its measured figure, what sets it and how to get past it.

In this revision the recording ring of `zcu106_hpc0` and `vck190_fmcp1` is **split over two
memories**: PS DDR and a second memory that the CPU does not use (the PL DDR4 on the ZCU106,
the LPDDR4 on the VCK190), in whole-chunk stripes, so that each SSD of a RAID0 pair writes and
reads one memory (see [Kernel driver](driver.md#split-ring-one-ring-in-two-memories)). Unless
a row says otherwise, every figure is for the images' defaults: a 1 GB split ring for RAID0 and
fabric-only runs, a 512 MB single ring for one SSD, 32 commands in flight per SSD, and PCIe
MaxPayload 256 bytes, which both boards' images set at boot. Most `zcu106_hpc0` runs were made
at 128 bytes (the kernel's setting, `sudo nvrec-mps 128`); every `zcu106_hpc0` figure says
which MaxPayload it was measured at.

```{note}
The per-run tables on this page are generated from the results files that `nvbench-suite.sh`
writes on the board (one JSON line per run, see [Running the benchmarks](#running-the-benchmarks))
and from the apps' `RESULT` lines.
```

## At a glance

MB/s, highest rate clean in 3 of 3 runs, with the image defaults (MaxPayload 256 bytes; a cell
measured at 128 bytes says so); Release 1.1 had a single 512 MB ring in PS DDR and MaxPayload
128 on both boards (its figures are also in [Revision history](revision_history)). "-": not
measured.

| fixture | measurement | Release 1.1 | this revision |
|---|---|---|---|
| `vck190_fmcp1`, 2x Samsung 980 PRO 1TB | RAID0 recording, 32 GB | 9250 | **10 000** (the drives' write rate) |
| | RAID0 bursts, 10 GB / 40 GB | 9250 / 9250 | **10 250 / 10 000** |
| | RAID0 sustained playback (40 GiB file) | 8750 | **11 000** (3 of 3 clean on the release image; 8 of 9 in the measurement session; 10 750 at MaxPayload 128) |
| | RAID0 past the SLC cache (350 GiB) | 3250 | 3250 |
| | one drive: recording 32 GB / sustained playback | 5000 / 6000 | 5000 / 6250 |
| | CPU at the RAID0 tops: `nvrec` / `nvplay`, % of one core | 2.8 / 5.2 | 2.3 / 6.3 |
| `vck190_fmcp1`, 2x Sabrent Rocket 2230 1TB | RAID0 recording, 32 GB | 7750 | **8250** (the drives' write rate, with the 1 GB ring) |
| | RAID0 bursts, 10 GB / 40 GB | 8000 or more / 7500 | **8500 or more / 8000** |
| | RAID0 sustained playback (40 GiB file) | 7500 | **9250** (at MaxPayload 256 and 128 alike) |
| | RAID0 past the SLC cache (350 GiB) | 3250 | 3250 |
| | one drive: recording 32 GB / sustained playback | 4000 / 4500 | 4000 / 4500 |
| | CPU at the RAID0 tops: `nvrec` / `nvplay`, % of one core | 2.8 / 5.1 | 2.9 / - |
| `vck190_fmcp1`, 2x WD_BLACK SN8100 HS 1000GB | RAID0 recording, 32 GB | - | **13 750** (the drives' Gen4 x4 links) |
| | RAID0 bursts, 10 GB / 40 GB | - | **14 000 or more / 13 750** |
| | RAID0 sustained playback (40 GiB file) | - | **11 000** (whole-chunk stripes, the default: 8 of 9 runs clean on three recordings; 10 750 at MaxPayload 128) |
| | RAID0 sustained playback with `--stripe 4` (tuned) | - | **14 250** (the drives' Gen4 x4 links; recording unchanged at 13 750) |
| | RAID0 past the SLC cache (800 GiB; 350 GiB stays inside this pair's cache) | - | 2000 (2250 drops from 819.3 GB; 13 500 holds for the first 683.7 GB, the two drives' ~340 GB caches) |
| | one drive: recording 32 GB / sustained playback | - | 6750 / 7000 |
| | CPU at the RAID0 tops: `nvrec` / `nvplay`, % of one core | - | 3.3 / 6.4 (4 KB stripes: 3.7 / 8.1) |
| `vck190_fmcp1`, fabric only (no SSD, the same with either pair) | recording / ring-resident playback | 14 500 / 13 750 | 14 750 / **15 000** (4 KB stripes: 15 750 / 16 000) |
| `zcu106_hpc0`, 2x Sabrent Rocket 2230 1TB | RAID0 recording, 32 GB | 5000 | **6000** (the whole-chunk ring writer; 5250 at MaxPayload 128) |
| | RAID0 bursts, 10 GB / 40 GB | 5000 / 5000 | - / **6000** (at MaxPayload 128: 5500 / 5250) |
| | RAID0 sustained playback (40 GiB file) | 4500 | **6000** (5250 at MaxPayload 128) |
| | RAID0 past the SLC cache (350 GiB) | 3250 | 3250 (at MaxPayload 128) |
| | one drive: recording 32 GB / sustained playback | 2750 / 3000 | 2750 / 3000 (at MaxPayload 128) |
| | CPU at the RAID0 tops: `nvrec` / `nvplay`, % of one core | 2.9 / 4.6 | 3.2 / 5.5 (at MaxPayload 128) |
| `zcu106_hpc0`, 2x Samsung 980 PRO 1TB | RAID0 recording, 32 GB | 5000 | **6000** (the whole-chunk ring writer; the same at MaxPayload 128) |
| | RAID0 bursts, 10 GB / 40 GB | 5000 / 5000 | **6000 / 6000** (the 40 GB one at MaxPayload 128) |
| | RAID0 sustained playback (40 GiB file) | 4250 | **5750** (5250 at MaxPayload 128) |
| | RAID0 past the SLC cache (350 GiB) | 3500 | 3500 (at MaxPayload 128) |
| | one drive: recording 32 GB / sustained playback | 3000 / 3000 | **3250 / 3500** (one run each; 3000 / 3000 at MaxPayload 128) |
| | CPU at the RAID0 tops: `nvrec` / `nvplay`, % of one core | 2.5 / 4.9 | 3.0 / 5.5 (at MaxPayload 128) |
| `zcu106_hpc0`, fabric only (no SSD, the same with either pair) | recording / ring-resident playback | 5000 / 5000 | **6000 / 6250** (4 KB stripes: 7000 / 6750) |

* **`vck190_fmcp1`**: the split ring takes RAID0 recording up to what the drives write with
  all three pairs: the 980 PRO and Sabrent pairs' own write rate (2 × ~4.95 GB/s, 2 × ~4.0-4.1
  GB/s), and with two WD_BLACK SN8100, PCIe Gen5 drives that link at Gen4 x4 here, the Gen4 x4
  links (2 × ~6.75 GB/s: **13 750 MB/s**). The SN8100 pair records the first 683.7 GB (~51 s at
  13 500 MB/s) in its drives' SLC caches, ~340 GB each, and holds 2000 MB/s past them over
  800 GiB. RAID0 playback rises from 8750 to 11 000 MB/s with
  the 980 PRO pair and from 7500 to 9250 MB/s with the Sabrent pair, whose drives then set the
  limit (2 × ~4.63 GB/s read); the short underflows that the Sabrent pair showed above
  7500 MB/s with Release 1.1 are gone. **With whole-chunk stripes (the default) about 12 GB/s
  of playback is not reached**, with the 980 PRO pair or the SN8100 pair: at 12 000 MB/s and
  above the stream delivers 11.84-11.95 GB/s, and from 11 000 MB/s up runs fail intermittently
  with short underflows. The limit is the memory being read: it carries the stream and half of
  the SSDs' writes at the same time, ~18 GB/s of mixed traffic (see
  [Ceilings at a glance](#versal-vck190_fmcp1)). **With 4 KB stripes the SN8100 pair plays back
  14 250 MB/s**, its drives' Gen4 x4 read rate (2 × 7.16 GB/s); the 980 PRO pair loses with
  4 KB stripes (10 500 MB/s), so the stripe is a choice per pair (see
  [Stripe](#stripe-whole-chunk-4-kb-or-64-kb)).
* **`zcu106_hpc0`**: the second ring port into the PL DDR4 lifts the fabric past the
  `S_AXI_HP2_FPD` limit of the single ring (5155 MB/s). Both pairs record 6000 MB/s, the limit
  of the whole-chunk ring writer (the Sabrent pair records 5250 MB/s at MaxPayload 128, its
  drives' rate). At MaxPayload 256 bytes, the image default, the pairs play back 5750 MB/s
  (980 PRO) and 6000 MB/s (Sabrent) sustained; at 128 bytes both play back 5250 MB/s. One
  980 PRO records 3250 MB/s and plays back 3500 MB/s at 256 bytes, the figures Release 1.1
  measured at 256 bytes (3000 / 3000 MB/s at 128).
* One SSD gains nothing from a split ring (its PCIe link is its limit) and stays on the single
  ring by default; forced onto the split ring, one 980 PRO on `zcu106_hpc0` plays back only
  ~1.44 GB/s (see [Stripe](#stripe-whole-chunk-4-kb-or-64-kb)).

## Method

### Recording

Each measurement is one `nvrec` recording of test-pattern data at a fixed generator rate,
followed by `nvverify` of the whole file. A rate **passes** when `nvrec` exits 0 (zero dropped
beats and zero NVMe errors) and `nvverify` reports a clean file. Because the generator cannot
be stalled, a pass means the whole chain (ring writer, both memories, command builder, Host
Accelerator, PCIe, SSD) kept up with the rate for the entire recording. Rates are measured in
steps, so a "highest clean step" means that the limit lies between that step and the next one.

The fabric datapath is **256 bits** wide on the Zynq UltraScale+ targets (32-byte beats; the
generator and the checker run at up to 8000 MB/s = 250 MHz × 32 bytes) and **512 bits** wide on
the Versal target (64-byte beats, up to 16 000 MB/s); see [Architecture](architecture).

* **Fabric only (no SSD).** `nvrec --no-write` runs the generator, the ingest FIFO and the ring
  writer into the ring exactly as a recording does, but builds no NVMe command and releases every
  ring slot as soon as it is filled (the hardware's fabric-only mode, `CONFIG.DRY`). For the
  playback direction `nvplay --ring-only` fills the ring once and then streams it to the checker
  several times, so the stream reads the ring's memories only. Together they measure the datapath
  ceiling of a target: the fastest rate at which data reaches the memories and comes back,
  before any SSD is involved. 64 GiB per recording step; per playback step 20 passes of the ring
  on `zcu106_hpc0` and 3 passes on `vck190_fmcp1` (20 passes once at the top). Each ring layout
  is measured on its own: the split ring with 4 KB, 64 KB and whole-chunk stripes, ring A alone
  (`--ring single`, PS DDR) and ring B alone (`--ring mem1`, the second memory). No SSD is
  involved, so these knees belong to the target: they were measured once per board (with the
  980 PRO pair fitted on `vck190_fmcp1`, with the Sabrent pair on `zcu106_hpc0`). The ring slot
  is the fitted drives' chunk, so the whole-chunk split ring of `vck190_fmcp1` was measured again
  with the SN8100 pair's 1 MB slots (see [Fabric only](#fabric-only-no-ssd)).
* **Sanity check.** Each layout (one SSD, RAID0) first records 10 GiB at 1000 MB/s, verifies
  the file and plays it back at 1000 MB/s (the design's hardware test). Every one passed.
* **32 GB sweep.** `nvrec` 32 GiB per step, in **250 MB/s steps** from a floor at or near the
  fixture's Release 1.1 top (from 7500 MB/s for the SN8100 pair, which Release 1.1 did not
  measure). Before every step the drives are deallocated whole (`blkdiscard`),
  a new md array (RAID0) and a new exFAT volume are created and the drives are left idle for
  60 s. The highest clean step and the first failing step are each run 3 times, so both are
  decided by 3 runs; the sweep ends at the first failing step (on `vck190_fmcp1` one step
  later). 32 GB stays inside the SLC cache of the 1 TB drives below, so the sweep gives an
  *in-cache* rate.
* **Burst and 40 GB recordings**: one 10 GiB and one 40 GiB recording at the highest clean step
  of the sweep and at the next step, each on a freshly deallocated volume after 60 s of idle
  time.
* **Long recordings past the SLC cache**: 350 GiB on RAID0, 1.5 to 2.7 times the pair's cache, on
  a freshly deallocated volume after **300 s** of idle time, at the Release 1.1 past-cache top
  of each pair (3250 MB/s; 3500 MB/s with the 980 PRO pair on `zcu106_hpc0`, where 3250 MB/s
  was run as well). The SN8100 pair ran 3250 MB/s and 13 500 MB/s, one step below its in-cache
  top; 350 GiB (~188 GB per drive) stays inside its cache, so its past-cache rate was measured
  with **800 GiB** (859.0 GB, ~430 GB per drive) in the same way, at 13 500, 3250, 2250 and
  2000 MB/s (3 runs at 2000 MB/s), after its cache had been measured drive by drive (see
  [The SLC cache](#the-slc-cache)).
* **A/B runs** at the tops, marked as such: the stripe (4 KB, 64 KB, whole chunk), the ring
  size (512 MB and 256 MB at the RAID0 recording top), `--qd 63`, the single ring, and the
  other MaxPayload (`nvrec-mps`, see [MaxPayload 256](#maxpayload-256)).
* **Defaults.** The split ring of the apps, 1 GB with half in each memory (4096 × 256 KB with
  the Sabrent Rocket, whose MDTS is 256 KB; 2048 × 512 KB with the Samsung 980 PRO; 1024 × 1 MB
  with the WD_BLACK SN8100, whose MDTS is 1 MB) in
  whole-chunk stripes, for RAID0; the single 512 MB ring in PS DDR for one SSD; **32 commands in
  flight per SSD** (`--qd 32`), NVMe APST off (the driver's default), MaxReadReq 512 bytes and
  **MaxPayload 256 bytes** (set at boot by `nvrec-pcie-mps.service` on both boards). On
  `zcu106_hpc0` most runs were made at MaxPayload 128 (`sudo nvrec-mps 128`) and the runs at
  256 bytes as the A/B; the tables say which.

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
| sweep | 500 MB/s steps from the floor, stop after two consecutive failing steps, 3 runs at the top and at the first failing step | 250 MB/s steps from a higher floor, 3 runs at the top and at the first failing step |
| I/O size | 8 MB buffers, split by Linux into MDTS-sized NVMe commands | one NVMe command per chunk = the drive's MDTS (512 KB on the Samsung 980 PRO, 256 KB on the Sabrent Rocket, 1 MB on the WD_BLACK SN8100) |
| commands in flight | io_uring queue depth 8 (8 MB requests) | 32 per SSD (`--qd`, 1 … 63), issued by the fabric |
| buffer ring | 32 × 8 MB (256 MB) | 1 GB of chunk-sized slots, half in each of two memories (RAID0) |
| filesystem | XFS, created once per layout | exFAT, contiguous preallocated file (see [Filesystem](filesystem)), created anew for every step |
| before a step | `rm` + `fstrim` of the free space, 60 s idle | `blkdiscard` of the whole drives, new md array, new exFAT, 60 s idle |
| playback figure | the highest clean step for a 10 GB file | the highest clean rate for a 40 GiB file (see [Playback](#playback)) |
| NVMe APST | the kernel's default (enabled) | off (the driver's default, module parameter `apst`) |
| CPU in the data path | io_uring submissions and DMA ioctls per 8 MB buffer | none: the CPU sets the run up and waits for its end |

### Playback

Each measurement is one `nvplay` of a test-pattern recording at a fixed sink rate (`--rate`),
into the reference design's checker. A rate is **clean** when `nvplay` exits 0: 0 underflows,
0 checker errors, gaps equal to the recording's drop count, every beat delivered, no NVMe error.
The sweep plays a 10 GiB recording made at 1000 MB/s with 0 drops on a freshly deallocated
volume (the page cache is dropped before every run), in 250 MB/s steps, with 3 runs at the
highest clean and at the first failing step. The Sabrent pair on `vck190_fmcp1` and the
980 PRO pair on `zcu106_hpc0` were measured with 40 GiB files only (no 10 GiB sweep).

`nvplay` fills the whole ring from the SSDs before it enables the sink (the prefill, given
separately), so the ring absorbs read stalls; the reported time and rate are the streaming time.
The prefilled ring also covers a small deficit: the 1 GB split ring holds about 10 % of a
10 GiB file, so a 10 GiB playback stays clean up to about 10 % above what the SSDs deliver.

**The sustained playback rate comes from a 40 GiB file**, of which the prefilled ring is
2.5 %. A 40 GiB recording (made at 1000 MB/s, 0 drops, verified) is played 3 times per rate,
the page cache dropped before every run, and a failing run ends the rate; with the 980 PRO and
SN8100 pairs on `vck190_fmcp1` the top rates were also played from a second and a third,
independently recorded 40 GiB file. Where the recordings disagree at a rate, the page gives
every set of three runs (for example "8 of 9 runs clean on three recordings"). **This 40 GiB
figure is the one published as the sustained playback rate**, for every layout; a 10 GiB step
above it is **ring-assisted**.

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
70 °C (`--temp-max`). The guard never fired. The highest temperatures were reached in the
350 GiB RAID0 recordings: **65 °C** with the Sabrent pair on both boards (33-47 °C in every
other run on `vck190_fmcp1`), 51 °C with the 980 PRO pair on `zcu106_hpc0` and 44 °C on
`vck190_fmcp1`. The SN8100 pair stayed at 21-42 °C throughout its measurements (at most 32 °C during
a run of the suite, 31 °C in its 350 GiB recordings, 37 °C in its 800 GiB recordings and 42 °C in
the 900 GB single-drive writes of its [SLC-cache measurement](#the-slc-cache)). 65 °C is close to the guard: give the Sabrents airflow for long recordings.
Every run stores its highest sample.

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
it overflowed. "Ring high-water" is the most ring slots (chunks) in use at once. An "underflow
tick" is one cycle of the 250 MHz sink clock (4 ns) in which the sink found no data. The ring
port waits ("reader waited for memory 0 / 1") are the register map 1.3 counters `RD_PORT_WAIT0/1`
and `WR_PORT_STALL0/1` in ms; they are not zero in a clean run (see
[Kernel driver](driver.md#split-ring-one-ring-in-two-memories)).

### Running the benchmarks

`nvbench-suite.sh` (in the image, `sw/nvrec-apps/`) runs every measurement on this page on the
board and appends one JSON line per run to `/var/lib/nvbench/results.jsonl`: the fixture
(target, SSD models, serial numbers, firmware, PCIe link and MaxPayload, MDTS, datapath width,
ring ports), the layout, the run's parameters (ring, stripe, `qd`, tag) and every figure (rates,
drops, NVMe errors, FIFO and ring high-water marks, ring port waits, commands in flight, latency
and histogram, `nvverify` result and first gap, CPU, drive temperatures). The method above, for
the RAID0 of `zcu106_hpc0`:

```
sudo nvbench-suite.sh fabric     --from 5000 --step 250 --confirm 2 --confirm-fail 2 --ring split --stripe 4,64,chunk
sudo nvbench-suite.sh fabricplay --from 5000 --step 250 --confirm 2 --confirm-fail 2 --passes 20 --ring single,mem1
sudo nvbench-suite.sh sustained --layout raid0 --size 32G --from 5000 --step 250 --confirm 2 --confirm-fail 2
sudo nvbench-suite.sh sustained --layout raid0 --size 32G --rates 5250 --confirm 2 --buffers 2048   # a 512 MB ring
sudo nvbench-suite.sh burst     --layout raid0 --size 10G --rates 5250,5500     # and --size 40G
sudo nvbench-suite.sh longrun   --layout raid0 --size 350G --rates 3250 --idle 300
sudo nvbench-suite.sh playback  --layout raid0 --from 4500 --step 250 --confirm 2 --confirm-fail 2
sudo nvrec-mps 128; sudo nvbench-suite.sh playback --layout raid0 --rates 5250 --confirm 2 --tag mps128; sudo nvrec-mps 256
sudo nvbench-suite.sh status                                                    # what is in the results file
```

A run already in the results file is not repeated, so the suite can be stopped and started
again with the same command; with `--budget-min` (default 150) it stops cleanly before a run
that would end later than that many minutes after the bitstream load (exit code 3), and when
the Host Accelerator stops it exits with code 5: power-cycle the board and run the same command
again. `--ring`, `--stripe`, `--buffers`, `--qd` and `--tag <word>` keep A/B runs of the same
steps apart in the run ids (`/ring=split/stripe=4K`, `/slots=2048`, `/qd=63`, `/tag=mps128`), and
every result records the MaxPayload in force (`mps`). The 40 GiB playback confirmations are
plain `nvrec --size 40G` + `nvverify` + `nvplay` runs. **The suite erases the SSDs.** See
[Applications](apps.md#nvbench-suitesh) for every option.

## Setups

| SSDs | target | FMC card, connector | PCIe link per SSD | datapath and ring memories | measured |
|---|---|---|---|---|---|
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` (VCK190, two Cortex-A72 at 1.4 GHz) | FPGA Drive FMC Gen4 (OP063), FMCP1 | **Gen4 x4** (16 GT/s) | 512 bits, `src_clk` = `dp_clk` = 249.9998 MHz; ring A in the DDR4-3200 x64 (PS DDR) through its own NoC port, ring B in the on-board LPDDR4 behind one LPDDR4 controller (second NoC instance); one NoC port per PCIe Root Port; egress FIFO 256 KB; 1 GB split ring = 2048 × 512 KB | 2026-10-24 |
| 2x Sabrent Rocket 2230 1TB (SB-2130-1TB) | `zcu106_hpc0` (ZCU106, four Cortex-A53 at 1.2 GHz) | M.2 M-key Stack FMC (OP073), HPC0 | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 256 bits, `src_clk` = `dp_clk` = 249.975 MHz; ring A in the PS DDR4-2133 x64 through `S_AXI_HP2_FPD` (128 bits at 322.19 MHz), ring B in the soldered PL DDR4-2400 x64 through a DDR4 controller in the PL (512 bits at 300 MHz); 1 GB split ring = 4096 × 256 KB | 2026-10-23/24 |
| 2x Sabrent Rocket 2230 1TB (SB-2130-1TB) | `vck190_fmcp1` | M.2 M-key Stack FMC (OP073), FMCP1 | **Gen4 x4** (16 GT/s) | as the 980 PRO pair on this board; 1 GB split ring = 4096 × 256 KB | 2026-10-24 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | FPGA Drive FMC Gen4 (OP063), HPC0 | Gen3 x4 (`8GT/s (downgraded)`) | as the Sabrent pair on this board; 1 GB split ring = 2048 × 512 KB | 2026-10-24 |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | FPGA Drive FMC Gen4 (OP063), FMCP1 | **Gen4 x4** (`16GT/s (downgraded)`: PCIe Gen5 drives, 32 GT/s x4 capable, on Gen4 Root Ports) | as the 980 PRO pair on this board; 1 GB split ring = 1024 × 1 MB | 2026-10-28 |

| target | drive | SSD | firmware | PCIe link | MDTS | I/O queues granted | nvrec_core | measured |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | nvrec0n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 16.0 GT/s PCIe x4 | 512 KB | 1 | 1.3 | 2026-10-24 |
| `vck190_fmcp1` | nvrec1n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 16.0 GT/s PCIe x4 | 512 KB | 1 | 1.3 | 2026-10-24 |
| `vck190_fmcp1` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 16.0 GT/s PCIe x4 | 256 KB | 8 | 1.3 | 2026-10-24 |
| `vck190_fmcp1` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 16.0 GT/s PCIe x4 | 256 KB | 8 | 1.3 | 2026-10-24 |
| `zcu106_hpc0` | nvrec0n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.3 | 2026-10-23/24 |
| `zcu106_hpc0` | nvrec1n1 | Sabrent SB-2130-1TB | R21B47.1 | 8.0 GT/s PCIe x4 | 256 KB | 8 | 1.3 | 2026-10-23/24 |
| `zcu106_hpc0` | nvrec0n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 8.0 GT/s PCIe x4 | 512 KB | 1 | 1.3 | 2026-10-24 |
| `zcu106_hpc0` | nvrec1n1 | Samsung 980 PRO 1TB | 5B2QGXA7 | 8.0 GT/s PCIe x4 | 512 KB | 1 | 1.3 | 2026-10-24 |
| `vck190_fmcp1` | nvrec0n1 | WD_BLACK SN8100 HS 1000GB | 830ZRR0A | 16.0 GT/s PCIe x4 | 1024 KB | 254 | 1.3 | 2026-10-28 |
| `vck190_fmcp1` | nvrec1n1 | WD_BLACK SN8100 HS 1000GB | 830ZRR0A | 16.0 GT/s PCIe x4 | 1024 KB | 254 | 1.3 | 2026-10-28 |

Every figure was measured with the images of this repository (register map 1.3, driver and
apps 1.2, an ingest FIFO of 256 KB, an egress FIFO of 128 KB on `zcu106_hpc0` and 256 KB on
`vck190_fmcp1`, the ring reader's per-port skid FIFOs of 512 beats). The `vck190_fmcp1`
bitstream is the published one; its device tree still defaulted to 4 KB stripes when it was
measured, so its whole-chunk runs passed `--stripe chunk` (the default of the published image).
The **release image** (the published images: the same bitstreams, the `vck190_fmcp1` device tree
with the whole-chunk default, the apps' note on the ring size) was confirmed at the tops with its
defaults after the measurements: on `vck190_fmcp1` a 40 GiB RAID0 playback at 11 000 MB/s clean
in 3 of 3 runs (0 underflow ticks) and a 32 GB RAID0 recording at 10 000 MB/s, on `zcu106_hpc0`
a 40 GiB RAID0 playback and a 32 GB RAID0 recording at 5250 MB/s, both clean. The Sabrent pair
on `vck190_fmcp1` and the 980 PRO pair on `zcu106_hpc0` were measured last, on the release
image itself (the 980 PRO pair at MaxPayload 128, then its tops again at 256 bytes, the
default), and the WD_BLACK SN8100 pair on `vck190_fmcp1` after the release, on the same release
image with unchanged hardware and software. The per-run tables list these runs with build "release image".
Rows marked **earlier build** were measured on an
earlier build of this revision, which had the
same ring writer, memories and NoC configuration but not yet the ring reader's skid FIFOs (and,
on `zcu106_hpc0`, a 64 KB stripe default, given in each row): recordings, one SSD and the
long recording do not depend on that change; playback figures from it are marked where they
appear. APST was off on every drive (the 980 PRO and the Sabrent come up with it disabled; the
driver switches it off on every drive), MaxReadReq 512 bytes on every Root Port and SSD
(DevCap: Root Ports 1024 bytes, 980 PRO 256, Sabrent and SN8100 512). `uzev` is
built but was not tested on hardware in this revision: there are no figures for it on this page.
The same two drives of each model were used on both boards; the 980 PRO pair had more than
15 TB written to it by the end of the measurements, the Sabrent pair more than 14 TB (both
including the Release 1.1 measurements). The SN8100 pair, used on `vck190_fmcp1` only, had about
3.6 TB written to it in its measurements.

## Ceilings at a glance

Why doesn't a recording reach the 8 or 16 GB/s of the fabric, or the SSDs' rated speeds? These
tables list every ceiling that was measured, per device family, with what sets it and how to get
past it where there is a way. The numbers are the measurements on this page; the reasoning
applies to every target of the family.

### Zynq UltraScale+ (`zcu106_hpc0`, `uzev`)

Measured on `zcu106_hpc0` with two Sabrent Rocket 2230 1TB and with two Samsung 980 PRO 1TB. `uzev` has one ring port (its
PL DDR4 is 16 bits wide, too narrow for half of the stream): its ring stays in PS DDR through
`S_AXI_HP2_FPD` at 327.77 MHz (5244 MB/s peak), as the single ring of `zcu106_hpc0` below, and
it was not measured in this revision.

| ceiling | measured | what sets it | how to get past it |
|---|---|---|---|
| `S_AXI_HP2_FPD`, ring A's port into PS DDR | **5155 MB/s** peak (128 bits × 322.19 MHz). Ring A alone (`--ring single`, no SSD) records and plays back **5000 MB/s** (3 of 3) and fails at 5250 MB/s, where the writer delivers 5154.9 MB/s and the reader 5026.9 MB/s. A RAID0 recording on the single ring drops at 5250 MB/s with this signature (5148.3 MB/s written, the ingest FIFO full while the ring is not) | a 128-bit PS-PL port, clocked at most 333 MHz | the split ring (the default for RAID0): HP2 then carries half of the stream |
| The PL DDR4 ring port (ring B) | ring B alone (`--ring mem1`, no SSD) records and plays back **7750 MB/s** (3 of 3); at 8000 MB/s it writes 7816.1 MB/s and streams 7930.1 MB/s | a fixed wait of about 4 `dp_clk` cycles per 4 KB burst on the way into the DDR4 controller (7999 MB/s × 128/132 = 7.76 GB/s), not the DDR4 itself (512 bits × 300 MHz = 19.2 GB/s) | not needed: the source is 8000 MB/s |
| The split ring: one stream, in order, over two ports | without an SSD, whole-chunk stripes (the default): recording **6000 MB/s** (6250 MB/s writes 6224.0 MB/s), ring-resident playback **6250 MB/s** (20 passes; 6500 MB/s streams 6431.5 MB/s). 4 KB stripes: **7000 / 6750 MB/s**; 64 KB stripes: 6250 / 6000 MB/s (earlier build) | the ring writer sends its data in issue order and the reader returns it in ring order, so the stream alternates between HP2 (~5.15 GB/s) and the PL DDR4 port (~7.8 GB/s). With large stripes it approaches the harmonic mean of the two, 2 / (1/5.15 + 1/7.8) ≈ 6.2 GB/s; 4 KB stripes keep both ports busy and overlap them better. At every failing step memory 0 (HP2) carries the wait | 4 KB stripes for the fabric alone (the SSDs need whole chunks: with 4 KB stripes the 980 PRO pair plays back only ~3.8 GB/s, see [Stripe](#stripe-whole-chunk-4-kb-or-64-kb)); a faster ring-A port. A follow-up idea, neither implemented nor measured: stripes weighted toward the faster memory, so that the in-order stream spends less of its time on HP2 |
| RAID0 playback with the SSDs | sustained (40 GiB) at **MaxPayload 256** (the default): **6000 MB/s** with the Sabrents (3 of 3; 6250 MB/s 2 of 3, the other run short of data for 0.05 ms), **5750 MB/s** with the 980 PROs (3 of 3; 6000 MB/s 2 of 6, the others short of data for 0.7 µs-0.2 ms; 6250 MB/s a steady 6.17 GB/s). At MaxPayload 128: **5250 MB/s** with either pair (Sabrent: 3 of 3 on two recordings and again on the release image, 5500 MB/s 0 of 6 at 5.47-5.50 GB/s; 980 PRO: 3 of 3, 5500 MB/s a steady 5.47 GB/s) | at MaxPayload 128 the drives and their links: their read latency is 1.67 ms (Sabrent) and 3.4 ms (980 PRO) at 5500 MB/s, every queue full, while each pair delivers ~5.47-5.53 GB/s. At MaxPayload 256 they answer in 0.22-0.28 ms, and the split ring's chunk alternation (the row above) is the limit: at 6250 MB/s the reader waits 1.59 s per run for memory 0 (HP2) and not at all for memory 1. The reader waits mostly for memory 0 at every rate (~1.5-1.7 s per 7-8 s run, against at most 1.1 s for memory 1): PS DDR, where the SSDs' writes and the ring-A reads share the controller | MaxPayload 256 bytes, the image default (see [MaxPayload 256](#maxpayload-256)) |
| RAID0 recording with the SSDs | **6000 MB/s** over 32 GB with both pairs at MaxPayload 256, the default: the 980 PRO pair 3 of 3 (and 3 of 3 at 128, also with a 512 MB or 256 MB ring; 6250 MB/s drops from 25-26 MB writing 6.21 GB/s at 256 bytes, 6.02 GB/s at 128, with the ring nearly empty), the Sabrent pair 3 of 3 with whole-chunk stripes and a 40 GiB recording (earlier build). At MaxPayload 128 the Sabrent pair records **5250 MB/s** (3 of 3 with every stripe and with a 512 MB ring): 5500 MB/s drops while the pair writes 5.20-5.33 GB/s with the ring full | the whole-chunk ring writer at 6000 MB/s, not MaxPayload (without SSDs it delivers 6224.0 MB/s at 6250 MB/s): the 6250 MB/s runs drop early with the ingest FIFO full and the ring not full, the writer waiting for memory 0 (HP2: 1180 ms per run, against 56 ms for memory 1). The Sabrents' own write rate at MaxPayload 128 | a faster ring-A port. 4 KB stripes have more fabric headroom, but the SSDs read a 4 KB-striped ring more slowly (the Sabrents 5500 MB/s at MaxPayload 256) |
| One PCIe Gen3 x4 slot | at MaxPayload 256 bytes (the default) one 980 PRO records **3250 MB/s** over 32 GB and plays back **3500 MB/s** over 40 GiB (one run each; one Sabrent was not measured at 256). At 128 bytes one 980 PRO writes ~3.04 GB/s and reads ~3.23 GB/s, one Sabrent writes 2.76-2.78 GB/s and reads ~3.19 GB/s: one drive records **3000 MB/s** (980 PRO; 3250 MB/s writes 3038.0-3038.5 MB/s) or **2750 MB/s** (Sabrent; 3000 MB/s writes 2761.6-2777.2 MB/s, earlier build) over 32 GB, and plays back **3000 MB/s** sustained with either (40 GiB; 3250 MB/s streams 3228 and 3224 MB/s) | the XDMA Root Ports are Gen3 x4 (a Gen4 drive links at 8 GT/s), and the TLP overhead of 128-byte payloads on them | RAID0 across both slots. **One SSD must stay on the single ring** (the default): forced onto the split ring (`--ring split`) one 980 PRO plays back ~1.44 GB/s (12 ms read latency) and one Sabrent ~13 % slower (~2.78 against ~3.19 GB/s), because its writes alternate between the memories |
| The SSD after its SLC cache | the 980 PRO pair **3500 MB/s** over 350 GiB (and 3250 MB/s), the Sabrent pair **3250 MB/s** (earlier build) | the drives' TLC flash (see [The SLC cache](#the-slc-cache)) | drives without an SLC cliff, larger drives |
| Write stalls against the ring | not a ceiling with the 1 GB default. The Sabrent pair needs more than 256 MB of it at 5250 MB/s: up to 1840 of 4096 slots (460 MB) with whole-chunk stripes, 3289 (822 MB) with 4 KB stripes; a 512 MB ring is clean 3 of 3 there, a 256 MB ring drops in 3 of 3 runs, 8-16 GB into the recording. The 980 PRO pair uses at most 81 slots (41 MB) at 6000 MB/s (a 256 MB ring is as clean), but **1134 slots (567 MB) past the cache** at 3500 MB/s | the drives' write-latency spikes (Sabrent up to 25 ms in the cache, 980 PRO up to 46 ms past it) | keep the 1 GB default, at least 512 MB in the cache ([Ring size](#ring-size)) |
| The source and the sink | 8000 MB/s (250 MHz × 32 bytes) | `src_clk` × 256 bits | not reached |
| The CPU | not a ceiling: `nvrec` 2.8-3.2 %, `nvplay` 5.1-6.0 % of one Cortex-A53 core at the RAID0 tops | no software in the data path | - |

### Versal (`vck190_fmcp1`)

Measured with two Samsung 980 PRO 1TB, with two Sabrent Rocket 2230 1TB and with two WD_BLACK
SN8100 HS 1000GB (PCIe Gen5 drives), each drive linked at PCIe Gen4 x4. The design is 512 bits
wide; ring A has its own NoC port into the DDR4, ring B its own into the LPDDR4 (a second NoC
instance with one LPDDR4 controller), and each PCIe Root Port has a NoC port of its own to both
memories (see [Architecture](architecture)).

| ceiling | measured | what sets it | how to get past it |
|---|---|---|---|
| The SSDs, recording | **980 PRO**: RAID0 records **10 000 MB/s** over 32 GB (3 of 3, again on the release image, also with a 512 MB ring and at `--qd 63`); at 10 250 MB/s the pair writes 9.89-9.91 GB/s and the ring fills to its last slot before the drop (0 of 3). One drive records **5000 MB/s** (3 of 3, ring-assisted; 5250 MB/s writes 4.95 GB/s; earlier build) **Sabrent**: RAID0 records **8250 MB/s** (3 of 3, with the 1 GB ring; 8500 MB/s 0 of 3 writing 7.86-8.18 GB/s, the ring full); one drive **4000 MB/s** (4250 MB/s 2 of 3, 4500 MB/s 0 of 3 writing 4.21-4.23 GB/s) | the drives' in-cache write rate: ~4.95 GB/s per 980 PRO, ~4.0-4.2 GB/s per Sabrent | faster drives |
| The SSDs' Gen4 x4 links, recording | **SN8100**: RAID0 records **13 750 MB/s** over 32 GB (3 of 3, ring-assisted: 527-596 of 1024 slots), with whole-chunk or 4 KB stripes alike; at 14 000 MB/s the pair writes 13.50-13.54 GB/s and the ring fills (0 of 3). One drive records **6750 MB/s** (7000 MB/s writes 6.74 GB/s). At MaxPayload 128 the pair writes 12.21-12.23 GB/s (12 500 MB/s top) | the PCIe Gen4 x4 link of each drive, ~6.75 GB/s of writes (Gen5 drives on Gen4 Root Ports): the pair writes the same 13.50-13.54 GB/s whatever the stripe, the ring size or `--qd`, one drive exactly half of it, and MaxPayload 128 costs 9.5 % (ratio 0.905), the TLP overhead of the smaller payloads, which a flash limit would not show. The fabric records 14 750 MB/s without SSDs | - (the Root Ports are Gen4) |
| The memory being read, whole-chunk playback | RAID0 plays back **11 000 MB/s** sustained with whole-chunk stripes (40 GiB, MaxPayload 256) with both the 980 PRO pair (3 of 3 with no underflow on the release image, 8 of 9 runs clean on two recordings in the measurement session; **10 750 MB/s** at MaxPayload 128) and the SN8100 pair (8 of 9 runs clean on three recordings; **10 750 MB/s** at MaxPayload 128). Above it runs are clean in some runs only; at a 12 000 MB/s sink the 980 PRO pair's stream delivers **11.84 GB/s**, at 12 000-14 000 MB/s the SN8100 pair's **11.90-11.95 GB/s**: about 12 GB/s is not reached. Near the top a run fails by **short, intermittent underflows** (980 PRO: 3000-34 000 ticks over a 40 GiB file, 12-134 µs in all; SN8100 at 11 000-11 250 MB/s: 47-2855 ticks, 0.2-11 µs), not by a steady shortfall | not the SSDs: with whole-chunk stripes each SSD writes one memory and its commands complete in 0.20 ms (980 PRO) or 0.27 ms (SN8100) on average, and the SN8100s read 14.32 GB/s from the same files with 4 KB stripes. The ring reader drains one memory at a time at the full stream rate *R* while that memory also takes one SSD's writes, *R*/2: 1.5 × 11.9 ≈ **18 GB/s of mixed traffic** on the memory being read. The single-memory rings, which put all reads and all writes (2 *R*) on one memory, stop at the same level: 8750 MB/s (980 PRO, DDR4), 8250 MB/s (SN8100, DDR4, `--ring single`) and 8500 MB/s (SN8100, LPDDR4, `--ring mem1`), 16.5-17.5 GB/s mixed. Neither side alone is the limit: without SSDs the reader streams 14.64-15.12 GB/s and the writer 14.90-14.93 GB/s | **4 KB stripes** (`--stripe 4`) with drives that take them: each memory then carries *R*/2 of reads and *R*/2 of writes, and the SN8100 pair plays back 14 250 MB/s (the row below). Not with the 980 PRO (the 4 KB-striped ring row) |
| The SSDs' Gen4 x4 links, playback | **SN8100** with 4 KB (or 64 KB) stripes: RAID0 plays back **14 250 MB/s** sustained (40 GiB, 3 of 3, clean at every step from 10 250 MB/s over two recordings; 10 GiB: 15 250 MB/s, ring-assisted); at 14 500-16 000 MB/s the pair streams 14.31-14.32 GB/s. One drive plays back **7000 MB/s** (7250 MB/s streams 7.16 GB/s) | the drives' Gen4 x4 links, ~7.16 GB/s of reads per drive: the 4 KB stream is exactly two of them, and the command latency rises from 0.27-0.30 ms to 2.8-3.9 ms at 14 000-14 250 MB/s | - (the Root Ports are Gen4) |
| The SSDs, playback (Sabrent) | RAID0 plays back **9250 MB/s** sustained (40 GiB, 3 of 3, 0 underflow ticks at every step from 8000 MB/s) at MaxPayload 256 and 128 alike, with whole-chunk or 4 KB stripes alike; at 9500 MB/s the stream delivers a steady 9.27-9.29 GB/s. One drive plays back **4500 MB/s** (4750 MB/s streams 4.59 GB/s) | the drives' read rate, ~2 × 4.63 GB/s: their command latency rises from 0.23 ms at 8000 MB/s to 1.4-1.5 ms at 9250 MB/s, while the ring reader waits for each memory about 1 s of a 4.6 s run at every rate | faster drives |
| SSD writes into a 4 KB-striped ring | with 4 KB stripes the 980 PRO pair plays back **10 500 MB/s** sustained (MaxPayload 256; 10 250 MB/s at 128, earlier build), with average command latencies of 1.7-1.85 ms; at 10 750-12 000 MB/s the stream delivers 10.58-10.67 GB/s | the NoC orders each Root Port's writes strictly, so every switch between the DDR4 and the LPDDR4 inside an SSD's command costs a round trip. One SSD shows it too: 5750 MB/s on a 4 KB-striped split ring against 6250 MB/s on the single ring (earlier build). The Sabrent pair, which reads more slowly than either layout takes, plays 9250 MB/s with both. **The SN8100 pair does not pay it**: its 1 MB commands into a 4 KB-striped ring complete in 0.27-0.30 ms up to 13 750 MB/s, as with whole chunks (measured, the reason not isolated) | whole-chunk stripes (the default) for the 980 PRO; for the SN8100 pair 4 KB stripes are the faster layout |
| LPDDR4 (ring B) | ring B alone (`--ring mem1`, no SSD) records **15 000 MB/s** (15 250 MB/s writes 15.03 GB/s) and plays back **13 250 MB/s** ring-resident (13 500 MB/s streams 13.42 GB/s); earlier build | the ring writer and reader on the LPDDR4 NoC port. Interleaving ring B over the board's two LPDDR4 controllers every 128 bytes capped its writes at 1.8-2.0 GB/s per NoC master (strict write ordering: one 128-byte piece per round trip), so ring B sits behind one controller, whose two x32 channels interleave every 256 bytes inside it | - |
| PS DDR (one DDR4-3200 x64 controller), single ring | ring A alone, no SSD: **14 500 MB/s** recording (14 750 MB/s writes 14.69 GB/s), **15 000 MB/s** ring-resident playback (earlier build). RAID0 on the single ring (`--ring single`): playback **8750 MB/s** sustained (40 GiB, 3 of 3, MaxPayload 256); recording at 9250 MB/s drops in 3 of 3 runs (32-86 k beats, 9.24-9.25 GB/s written) | every byte crosses the DDR4 twice. The single ring records with less margin than the Release 1.1 build did at 9250 MB/s; the NoC bandwidth requests and MaxPayload were ruled out, the cause was not isolated | the split ring (the default) |
| The fabric datapath | without an SSD the split ring records **14 750 MB/s** with whole-chunk stripes (earlier build; 15 000 MB/s writes 14.93 GB/s) and **15 750 MB/s** with 4 KB stripes (16 000 MB/s writes 15.75 GB/s), and plays back ring-resident **15 000 MB/s** (whole chunk; 15 250 MB/s streams 15.12 GB/s) and **16 000 MB/s** (4 KB: the sink's maximum), 20 passes clean at both tops | the 16 000 MB/s source and sink (512 bits × 250 MHz); with whole-chunk stripes the ring writer, which fills one memory at a time | not reached by the SSD pair |
| Each Root Port's NoC port | not reached: 256 bits at 250 MHz, QoS requests of 7000 MB/s to the DDR4 and 4000 MB/s to the LPDDR4 per direction; one 980 PRO plays back 6250 MB/s sustained through its Gen4 x4 link (single ring, MaxPayload 128; 6750 MB/s streams 6.50-6.52 GB/s from a 10 GiB file; earlier build) | - | - |
| Write stalls against the ring | not a ceiling with the 1 GB default, but every pair needs a large part of it at its RAID0 recording top. The **SN8100 pair at 13 750 MB/s** used up to 596 of 1024 slots (596 MB), and drops in 3 of 3 runs with a 512 MB or a 256 MB ring (from 33.6 GB and from 15.7-17.1 GB). The **Sabrent pair at 8250 MB/s** used up to 3836 of 4096 slots (959 MB), and drops in 3 of 3 runs with a 512 MB or a 256 MB ring (from 9-18 GB); a 512 MB ring holds 8000 MB/s. The **980 PRO pair at 10 000 MB/s** used up to 715 of 2048 slots (358 MB): a 512 MB ring is clean 3 of 3, a 256 MB ring drops in 3 of 3 runs, 23-28 GB into the recording (earlier build) | what the drives fall short of the rate over 32 GB (the 980 PRO pair ~0.1 GB/s, ~340 MB), and the Sabrents' write stalls | keep the 1 GB default ([Ring size](#ring-size)) |
| The SSD after its SLC cache | the 980 PRO and Sabrent pairs **3250 MB/s** over 350 GiB (the Sabrents reached 65 °C). The SN8100 pair, whose caches hold ~340 GB per drive (350 GiB stays inside them), **2000 MB/s** over 800 GiB (3 of 3, the ring at up to 846 of 1024 slots; 2250 MB/s drops from 819.3 GB, where the first drive steps down from ~1.96 to ~1.12 GB/s); at 13 500 MB/s it records 683.7 GB before its caches run out | the drives' TLC flash (see [The SLC cache](#the-slc-cache)) | drives without an SLC cliff, larger drives |
| The CPU | not a ceiling: `nvrec` 2.3-3.7 %, `nvplay` 6.3-8.1 % of one Cortex-A72 core at the RAID0 tops | no software in the data path | - |

## Results

Targets `vck190_fmcp1` (Versal) and `zcu106_hpc0` (Zynq UltraScale+) with the SSD pairs of
[Setups](#setups). RAID0 = both drives of a pair, with the drives' MDTS as the chunk (512 KB on
the Samsung 980 PRO, 256 KB on the Sabrent Rocket, 1 MB on the WD_BLACK SN8100); "single" = SSD1
(`/dev/nvrec0n1`). The
images' defaults (1 GB split ring in whole-chunk stripes for RAID0, 512 MB single ring for one
SSD, 32 commands in flight per SSD, MaxPayload 256 bytes) unless a row says otherwise; most
`zcu106_hpc0` rows were measured at MaxPayload 128 and say so. The "build" column of the per-run tables says
whether a run was made on the release image (the confirmation runs, and every run of the
Sabrent and SN8100 pairs on `vck190_fmcp1` and of the 980 PRO pair on `zcu106_hpc0`), on the published
bitstream in the measurement session ("final") or on the earlier build described in
[Setups](#setups).

### Fabric only (no SSD)

The path from the fabric into the ring's memories and back, with no SSD involved (see
[Recording](#recording)), for each ring layout. These knees do not depend on the SSD pair
fitted, except through the slot size, which is the drives' chunk (they were measured with the
980 PRO pair, 512 KB slots, on `vck190_fmcp1` and the Sabrent pair, 256 KB slots, on
`zcu106_hpc0`; the SN8100 pair's 1 MB slots below the table):

| target | ring | recording (`nvrec --no-write`), highest clean | ring-resident playback (`nvplay --ring-only`), highest clean | first failing step: recording / playback | build |
|---|---|---|---|---|---|
| `vck190_fmcp1` | split, whole-chunk stripes (default) | **14 750 MB/s** (earlier build; 13 750 MB/s clean on the final one) | **15 000 MB/s** (3 of 3; 20 passes clean) | 15 000 MB/s (0 of 3 on both builds, 14.93 GB/s written) / 15 250 MB/s (0 of 3, 275-277 k ticks, 15.12 GB/s streamed) | final |
| `vck190_fmcp1` | split, 4 KB stripes | **15 750 MB/s** | **16 000 MB/s** (3 of 3; 20 passes clean): the sink's maximum | 16 000 MB/s (0 of 3, 15.75 GB/s written) / - | final |
| `vck190_fmcp1` | split, 64 KB stripes | 15 000 MB/s | 14 250 MB/s | 15 250 MB/s (15.23 GB/s written) / 14 500 MB/s | earlier |
| `vck190_fmcp1` | ring A alone (`--ring single`, DDR4) | 14 500 MB/s | 15 000 MB/s | 14 750 MB/s (14.69 GB/s written) / 15 250 MB/s (15.05 GB/s streamed) | earlier |
| `vck190_fmcp1` | ring B alone (`--ring mem1`, LPDDR4) | 15 000 MB/s | 13 250 MB/s (`--fill-rate 1000`) | 15 250 MB/s (15.03 GB/s written) / 13 500 MB/s (13.42 GB/s streamed) | earlier |
| `zcu106_hpc0` | split, whole-chunk stripes (default) | **6000 MB/s** (3 of 3 on the earlier build, again on the final one) | **6250 MB/s** (20 passes; 6000 MB/s on the earlier build) | 6250 MB/s (8.92 M beats dropped, 6224.0 MB/s written) / 6500 MB/s (6.87 M ticks, 6431.5 MB/s streamed) | final |
| `zcu106_hpc0` | split, 4 KB stripes | **7000 MB/s** | **6750 MB/s** | 7250 MB/s (7065.5 MB/s written) / 7000 MB/s (6949.8 MB/s streamed) | earlier |
| `zcu106_hpc0` | split, 64 KB stripes | 6250 MB/s | 6000 MB/s | 6500 MB/s (6259.7 MB/s) / 6250 MB/s (6197.6 MB/s) | earlier |
| `zcu106_hpc0` | ring A alone (`--ring single`, PS DDR via `S_AXI_HP2_FPD`) | 5000 MB/s | 5000 MB/s | 5250 MB/s (5154.9 MB/s) / 5250 MB/s (5026.9 MB/s) | earlier |
| `zcu106_hpc0` | ring B alone (`--ring mem1`, PL DDR4) | 7750 MB/s | 7750 MB/s | 8000 MB/s (7816.1 MB/s) / 8000 MB/s (7930.1 MB/s) | earlier |

* On `zcu106_hpc0` the split ring lands between its two ports, best with 4 KB stripes. With
  64 KB or whole-chunk stripes the writer moves one stripe at a time to one port, so the stream
  averages the two ports' rates (2 / (1/5.15 + 1/7.8) ≈ 6.2 GB/s); at every failing step the
  writer waits mostly for memory 0 (HP2: 1101-2350 ms per 64 GiB, against 34-100 ms for the
  PL DDR4). The PL DDR4 port's writer wait is a constant of the path, about 4 `dp_clk` cycles
  per 4 KB burst (2^26 cycles, 268.4 ms, per 64 GiB written to it, at every rate below its
  limit): a non-zero memory-1 writer wait on this board means nothing by itself.
* On `vck190_fmcp1` the 4 KB-striped ring reaches the source and sink maximum in both
  directions; with whole-chunk stripes the ring writer fills one memory at a time and stops at
  14.93 GB/s, and the reader at 15.12 GB/s. Either is well above what the SSD pair delivers.
* The table's `vck190_fmcp1` rows have 512 KB slots (the 980 PRO's chunk). With the SN8100
  pair's 1 MB slots, on the release image, the whole-chunk split ring records **14 750 MB/s**
  (3 of 3; 15 000 MB/s 0 of 3, 14.90 GB/s written), but its ring-resident playback fails at
  15 000 MB/s (0 of 3, 3 passes, 14.64 GB/s streamed; 15 250 MB/s the same); no lower rate was
  run. A whole-chunk stripe keeps the reader on one memory twice as long with 1 MB slots, which
  may explain it; it was not compared with 512 KB slots on the same boot. 4 KB and 64 KB stripes
  were not measured with 1 MB slots. Neither figure limits the SSD pair (see
  [Ceilings at a glance](#versal-vck190_fmcp1)).
* The data was intact in every playback (0 checker errors, 0 gaps); underflows are cycles in
  which the sink found no data. The fabric-only runs take a fixed set-up time of CPU (0.1-1.5 %
  of one core for `nvrec --no-write`, up to 10 % for the short `nvplay --ring-only` runs): no
  software in the data path.

### Sustained recording rate

32 GiB per step as in the [recording method](#recording): 250 MB/s steps, a freshly deallocated
volume and 60 s of idle time before every step, 3 runs at the highest clean and at the first
failing step. The 10 GB and 40 GB columns come from the
[burst recordings](#burst-and-40-gb-recordings), the last column from the
[long recordings](#long-recordings-past-the-slc-cache): 32 GB stays inside the SLC cache of
these drives.

| target | SSD | layout | 32 GB sweep: highest clean step (in the cache) | highest clean, 10 GB | highest clean, 40 GB | sustained past the SLC cache |
|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **10 000 MB/s** (3 of 3, and again on the release image; 10 250 MB/s 0 of 3, the pair writing 9.89-9.91 GB/s with the ring full: the drives); also 3 of 3 with a 512 MB ring, and at `--qd 63` (4 KB stripes, earlier build) | 10 250 MB/s or more (10 000 and 10 250 MB/s pass; not run higher) | 10 000 MB/s (10 250 MB/s drops from 31.81 GB) | **3250 MB/s** over 350 GiB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **5000 MB/s** (3 of 3, ring-assisted: up to 656 of 1024 slots; 5250 and 5500 MB/s 0 of 3 writing 4.95-4.96 GB/s; earlier build) | - | - | - |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **8250 MB/s** (3 of 3, ring-assisted: up to 3836 of 4096 slots; 8500 MB/s 0 of 3 writing 7.86-8.18 GB/s with the ring full: the drives; `--qd 63`: 8250 MB/s 2 of 3) | 8500 MB/s or more (8250 and 8500 MB/s pass; not run higher) | 8000 MB/s (8250 MB/s drops from 32.20 GB) | **3250 MB/s** over 350 GiB |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **4000 MB/s** (3 of 3, ring-assisted: up to 1019 of 2048 slots; 4250 MB/s 2 of 3, 4500 MB/s 0 of 3 writing 4.21-4.23 GB/s) | - | - | - |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk | **13 750 MB/s** (3 of 3, ring-assisted: up to 596 of 1024 slots; 14 000 MB/s 0 of 3 writing 13.50 GB/s with the ring full: the drives' Gen4 x4 links); the same with 4 KB stripes; `--qd 63`: 13 750 MB/s 2 of 3; MaxPayload 128: 12 500 MB/s (12 750 MB/s 0 of 3 writing 12.22 GB/s) | 14 000 MB/s or more (13 750 and 14 000 MB/s pass; not run higher) | 13 750 MB/s (14 000 MB/s drops from 30.58 GB) | **2000 MB/s** over 800 GiB (3 of 3; 2250 MB/s drops from 819.3 GB, where the first drive leaves its ~1.96 GB/s phase; 13 500 MB/s holds for 683.7 GB; over 350 GiB 13 500 MB/s passes, inside the cache) |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1), 1M chunk | **6750 MB/s** (3 of 3, ring-assisted: up to 284 of 512 slots; 7000 MB/s 0 of 3 writing 6.74 GB/s: the drive's Gen4 x4 link) | - | - | - |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk | **6000 MB/s** at MaxPayload 256, the default (whole-chunk stripes, 3 of 3; 6250 MB/s drops from 38.5 MB: the ring writer; earlier build); **5250 MB/s** at MaxPayload 128 (3 of 3 on the final and the earlier build, again on the release image, also with 4 KB and 64 KB stripes; 5500 MB/s drops writing 5.20-5.33 GB/s with the ring full: the drives) | 5500 MB/s at MaxPayload 128 (5447.7 MB/s average; 64 KB stripes, earlier build) | 6000 MB/s at MaxPayload 256; 5250 MB/s at 128 (5500 MB/s drops from 32.84 GB, writing 5318.8 MB/s; 64 KB stripes, earlier build) | **3250 MB/s** over 350 GiB (MaxPayload 128) |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | **2750 MB/s** at MaxPayload 128 (3 of 3; 3000 MB/s drops writing 2761.6-2777.2 MB/s: the drive on its Gen3 x4 link; earlier build) | - | - | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **6000 MB/s** at MaxPayload 256 (3 of 3; 6250 MB/s drops from 25 MB writing 6210.0 MB/s with the ring nearly empty: the whole-chunk ring writer) and at 128 (3 of 3, also with a 512 MB and a 256 MB ring; 6250 MB/s 0 of 3, writing 6020.6-6022.7 MB/s) | 6000 MB/s at 256 and at 128 (6250 MB/s drops from 25 MB at 128) | 6000 MB/s at 128 (6250 MB/s drops from 25 MB) | **3500 MB/s** over 350 GiB at 128 (3250 MB/s too) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | **3250 MB/s** at MaxPayload 256 (one run; not run higher); **3000 MB/s** at 128 (3 of 3; 3250 MB/s 0 of 3 writing 3038.0-3038.5 MB/s: the Gen3 x4 link) | - | - | - |

* **`vck190_fmcp1`, 980 PRO RAID0: 10 000 MB/s** (3 of 3), ring-assisted: the pair writes
  ~9.9 GB/s in its cache and the ring absorbs the rest of a 32 GB recording (636-715 of 2048
  slots; 655 on the release image). At 10 250 MB/s the ring fills to its last slot after about 31 GB and the recording
  drops. The ring writer waits 84-98 ms for memory 0 and 67-79 ms for memory 1 in a run of
  about 3.4 s: neither memory limits a recording.
* **`vck190_fmcp1`, one 980 PRO: 5000 MB/s** (3 of 3), ring-assisted: the drive writes
  4.95 GB/s in its cache and the 512 MB single ring absorbs the deficit of a 32 GB recording
  (579-656 slots). 4750 MB/s is the full-rate step (ring high-water 45).
* **`vck190_fmcp1`, Sabrent RAID0: 8250 MB/s** (3 of 3): the drives write ~7.9-8.2 GB/s
  together in their cache, so 8250 MB/s is ring-assisted (the third run used 3836 of 4096
  slots) and needs the 1 GB default ring: with 512 MB or 256 MB it drops in 3 of 3 runs (a
  512 MB ring holds 8000 MB/s). The ring writer waits 84 / 67 ms for the two memories at every
  rate: no memory limit. `--qd 63` does not help (8250 MB/s 2 of 3; write latency maxima of
  33-47 ms instead of ~20 ms).
* **`vck190_fmcp1`, one Sabrent: 4000 MB/s** (3 of 3, with the ring at 951-1019 of 2048
  slots); 4250 MB/s 2 of 3, 4500 MB/s 0 of 3 writing 4.21-4.23 GB/s.
* **`vck190_fmcp1`, SN8100 RAID0: 13 750 MB/s** (3 of 3), ring-assisted: the pair writes
  13.50-13.54 GB/s and the 1 GB ring absorbs the rest of a 32 GB recording (527-596 of 1024
  slots). Every step from 7500 to 13 500 MB/s was clean. The limit is the drives' PCIe Gen4 x4
  links, ~6.75 GB/s of writes per drive (PCIe Gen5 drives on Gen4 Root Ports): every failing
  run writes the same 13.50-13.54 GB/s, with whole-chunk or 4 KB stripes, a 1 GB, 512 MB or
  256 MB ring, `--qd 32` or 63; one drive writes 6.74-6.75 GB/s, exactly half; and at
  MaxPayload 128 the pair writes 12.21-12.23 GB/s (ratio 0.905), the TLP overhead of 128-byte
  payloads, which a flash or controller limit would not show. The memories are not the limit:
  the ring writer waits 81-116 ms for memory 0 and 65-90 ms for memory 1 per run (under 5 % of
  it), and without SSDs the ring records 14 750 MB/s. 4 KB stripes record the same 13 750 MB/s
  (14 000 MB/s 0 of 3 at 13.54 GB/s).
* **`vck190_fmcp1`, one SN8100: 6750 MB/s** (3 of 3, ring-assisted: 256-284 of 512 slots);
  7000 MB/s 0 of 3 writing 6.74 GB/s, its Gen4 x4 link.
* **`zcu106_hpc0`, Sabrent RAID0: 6000 MB/s** at MaxPayload 256, the default (3 of 3, and a
  40 GiB recording): the chunk-stripe ring writer is the limit, as without SSDs (6250 MB/s
  drops from 38.5 MB with the ring not full). At MaxPayload 128 the pair records **5250 MB/s**
  (3 of 3): there the drives are the limit, writing 5.20-5.33 GB/s with the ring full at every
  failing step, at `--qd 32` or 63.
* **`zcu106_hpc0`, one Sabrent: 2750 MB/s** (3 of 3, ring high-water 569-655 slots). 3000 MB/s
  drops in 3 of 3 runs while the drive writes 2761.6-2777.2 MB/s: the drive on its Gen3 x4 link
  at MaxPayload 128.
* **`zcu106_hpc0`, 980 PRO RAID0: 6000 MB/s** (3 of 3 at MaxPayload 256 and at 128): the split ring takes HP2 out of the way
  of the drives, and the whole-chunk ring writer is the limit, as without SSDs: 6250 MB/s drops
  26 MB into the recording with the ingest FIFO full, the writer waiting for memory 0 (HP2:
  1180 ms per run, against 56-61 ms for memory 1). At MaxPayload 128 the drives are close
  behind (ring filling, 3.2 ms latency); at 256 they write 6.21 GB/s at 6250 MB/s with the ring
  nearly empty, so MaxPayload does not move the top. The pair uses at most 81 of 2048 slots
  (41 MB) at 6000 MB/s.
* **`zcu106_hpc0`, one 980 PRO: 3250 MB/s** at MaxPayload 256 (one run, ring high-water 30
  slots), as Release 1.1 measured at 256 bytes. At 128 bytes 3000 MB/s (3 of 3, ring
  high-water 27-36 slots); 3250 MB/s drops while the drive writes 3038.0-3038.5 MB/s: its
  Gen3 x4 link.
* `nvverify` found every failing recording's missing words equal to its drop count (2 words per
  32-byte beat, 4 per 64-byte beat), with 0 corrupted words; 0 NVMe errors in every run.

Every 32 GB recording at and around the tops ("first gap" is the file offset of the first
discontinuity reported by `nvverify`; "avg MB/s" is the data written divided by the recording
time, which includes writing out what the ring holds when the source stops):

| target | SSD | layout | ring | MaxPayload | size | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | ring high-water (slots) | avg MB/s | nvverify | first gap | build |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10000 | pass | 0 | 102 | 655 / 2048 | 9896.2 | pass | - | release image |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10000 | pass | 0 | 95 | 636 / 2048 | 9907.7 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10000 (#2) | pass | 0 | 97 | 715 / 2048 | 9893.4 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10000 (#3) | pass | 0 | 198 | 649 / 2048 | 9896.2 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10250 | drops | 2 405 112 | full | 2048 / 2048 | 9893.4 | gaps | 30.85 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10250 (#2) | drops | 806 295 | full | 2048 / 2048 | 9899.1 | gaps | 33.03 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10250 (#3) | drops | 1 579 671 | full | 2048 / 2048 | 9907.7 | gaps | 31.26 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 10500 | drops | 14 563 596 | full | 2048 / 2048 | 9893.4 | gaps | 19.25 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 10000 | pass | 0 | 96 | 650 / 1024 | 9904.8 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 10000 (#2) | pass | 0 | 104 | 691 / 1024 | 9899.1 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 10000 (#3) | pass | 0 | 238 | 707 / 1024 | 9893.4 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, 4 KB, 512 × 512 KB (256 MB) | 128 | 32 GiB | 10000 | drops | 1 459 417 | full | 512 / 512 | 9896.2 | gaps | 27.48 GB | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, 4 KB, 512 × 512 KB (256 MB) | 128 | 32 GiB | 10000 (#2) | drops | 1 418 365 | full | 512 / 512 | 9899.1 | gaps | 23.40 GB | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, 4 KB, 512 × 512 KB (256 MB) | 128 | 32 GiB | 10000 (#3) | drops | 1 353 155 | full | 512 / 512 | 9893.4 | gaps | 25.69 GB | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | single, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 9250 | drops | 85 568 | full | 97 / 1024 | 9243.9 | gaps | 1.72 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | single, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 9250 (#2) | drops | 64 048 | full | 110 / 1024 | 9236.5 | gaps | 6.15 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | single, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 9250 (#3) | drops | 32 511 | full | 84 / 1024 | 9248.9 | gaps | 2.08 GB | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, `--qd 63` | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 10000 | pass | 0 | 73 | 692 / 2048 | 9899.1 | pass | - | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, `--qd 63` | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 10000 (#2) | pass | 0 | 73 | 605 / 2048 | 9910.5 | pass | - | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, `--qd 63` | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 10000 (#3) | pass | 0 | 73 | 647 / 2048 | 9907.7 | pass | - | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, `--qd 63` | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 10250 | drops | 1 873 865 | full | 2048 / 2048 | 9901.9 | gaps | 31.76 GB | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, `--qd 63` | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 10250 (#2) | drops | 1 797 336 | full | 2048 / 2048 | 9901.9 | gaps | 32.01 GB | earlier |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, `--qd 63` | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 10250 (#3) | drops | 1 809 362 | full | 2048 / 2048 | 9901.9 | gaps | 31.59 GB | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 4750 | pass | 0 | 68 | 45 / 1024 | 4748.4 | pass | - | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5000 | pass | 0 | 68 | 579 / 1024 | 4958.1 | pass | - | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5000 (#2) | pass | 0 | 68 | 639 / 1024 | 4951.0 | pass | - | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5000 (#3) | pass | 0 | 68 | 656 / 1024 | 4952.4 | pass | - | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5250 | drops | 23 735 909 | full | 1024 / 1024 | 4951.0 | gaps | 9.29 GB | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5250 (#2) | drops | 23 774 316 | full | 1024 / 1024 | 4950.3 | gaps | 9.24 GB | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5250 (#3) | drops | 23 250 383 | full | 1024 / 1024 | 4952.4 | gaps | 9.50 GB | earlier |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 5500 | drops | 49 512 145 | full | 1024 / 1024 | 4955.3 | gaps | 5.39 GB | earlier |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 7500 | pass | 0 | 71 | 241 / 4096 | 7495.6 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 7750 | pass | 0 | 73 | 1096 / 4096 | 7749.2 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8000 | pass | 0 | 71 | 1752 / 4096 | 7922.5 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8250 | pass | 0 | 84 | 1796 / 4096 | 8177.0 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8250 (#2) | pass | 0 | 71 | 2519 / 4096 | 8111.4 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8250 (#3) | pass | 0 | 71 | 3836 / 4096 | 8031.7 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8500 | drops | 4 496 878 | full | 4096 / 4096 | 8177.0 | gaps | 27.40 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8500 (#2) | drops | 9 632 430 | full | 4096 / 4096 | 7992.5 | gaps | 23.58 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8500 (#3) | drops | 27 044 336 | full | 4096 / 4096 | 7862.6 | gaps | 19.69 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8750 | drops | 21 953 162 | full | 4096 / 4096 | 8067.6 | gaps | 14.38 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 8000 | pass | 0 | 94 | 418 / 2048 | 7985.1 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 8000 (#2) | pass | 0 | 71 | 447 / 2048 | 7996.2 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 8000 (#3) | pass | 0 | 71 | 433 / 2048 | 7996.2 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 8250 | drops | 13 542 877 | full | 2048 / 2048 | 7953.6 | gaps | 16.95 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 8250 (#2) | drops | 11 367 182 | full | 2048 / 2048 | 7913.3 | gaps | 13.09 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 8250 (#3) | drops | 15 981 437 | full | 2048 / 2048 | 7907.9 | gaps | 17.55 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 1024 × 256 KB (256 MB) | 256 | 32 GiB | 8250 | drops | 13 453 176 | full | 1024 / 1024 | 8001.8 | gaps | 13.43 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 1024 × 256 KB (256 MB) | 256 | 32 GiB | 8250 (#2) | drops | 21 432 392 | full | 1024 / 1024 | 7878.9 | gaps | 9.58 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 1024 × 256 KB (256 MB) | 256 | 32 GiB | 8250 (#3) | drops | 24 403 550 | full | 1024 / 1024 | 7842.9 | gaps | 9.02 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, `--qd 63` | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8250 | drops | 5 234 872 | full | 4096 / 4096 | 7961.0 | gaps | 24.23 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, `--qd 63` | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8250 (#2) | pass | 0 | 71 | 3511 / 4096 | 7970.2 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, `--qd 63` | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 8250 (#3) | pass | 0 | 71 | 2673 / 4096 | 8126.7 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 4000 | pass | 0 | 67 | 1013 / 4096 | 3997.6 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 3750 | pass | 0 | 67 | 945 / 2048 | 3749.4 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4000 | pass | 0 | 67 | 987 / 2048 | 3997.2 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4000 (#2) | pass | 0 | 67 | 951 / 2048 | 3981.9 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4000 (#3) | pass | 0 | 67 | 1019 / 2048 | 3999.0 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4250 | pass | 0 | 67 | 1808 / 2048 | 4196.9 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4250 (#2) | drops | 1 530 366 | full | 2048 / 2048 | 4154.7 | gaps | 28.19 GB | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4250 (#3) | pass | 0 | 67 | 1063 / 2048 | 4232.0 | pass | - | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4500 | drops | 25 604 557 | full | 2048 / 2048 | 4231.0 | gaps | 9.70 GB | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4500 (#2) | drops | 25 395 849 | full | 2048 / 2048 | 4233.6 | gaps | 11.02 GB | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4500 (#3) | drops | 28 790 229 | full | 2048 / 2048 | 4206.6 | gaps | 7.90 GB | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 32 GiB | 4750 | drops | 59 176 492 | full | 2048 / 2048 | 4214.9 | gaps | 5.85 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13000 | pass | 0 | 208 | 12 / 1024 | 13000.3 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13250 | pass | 0 | 570 | 34 / 1024 | 13251.0 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13500 | pass | 0 | 422 | 34 / 1024 | 13500.9 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 | pass | 0 | 2496 | 596 / 1024 | 13500.9 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 (#2) | pass | 0 | 610 | 529 / 1024 | 13532.8 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 (#3) | pass | 0 | 862 | 527 / 1024 | 13532.8 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14000 | drops | 2 720 642 | full | 1024 / 1024 | 13495.6 | gaps | 30.50 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14000 (#2) | drops | 2 776 305 | full | 1024 / 1024 | 13495.6 | gaps | 30.60 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14000 (#3) | drops | 2 682 645 | full | 1024 / 1024 | 13495.6 | gaps | 30.61 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14250 | drops | 15 789 132 | full | 1024 / 1024 | 13416.5 | gaps | 18.97 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 512 × 1 MB (512 MB) | 256 | 32 GiB | 13750 | drops | 357 160 | full | 512 / 512 | 13527.5 | gaps | 33.64 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 512 × 1 MB (512 MB) | 256 | 32 GiB | 13750 (#2) | drops | 358 502 | full | 512 / 512 | 13527.5 | gaps | 33.64 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 512 × 1 MB (512 MB) | 256 | 32 GiB | 13750 (#3) | drops | 369 975 | full | 512 / 512 | 13527.5 | gaps | 33.57 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 256 × 1 MB (256 MB) | 256 | 32 GiB | 13750 | drops | 7 811 220 | full | 256 / 256 | 13448.0 | gaps | 16.77 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 256 × 1 MB (256 MB) | 256 | 32 GiB | 13750 (#2) | drops | 7 388 699 | full | 256 / 256 | 13458.6 | gaps | 17.13 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 256 × 1 MB (256 MB) | 256 | 32 GiB | 13750 (#3) | drops | 8 027 336 | full | 256 / 256 | 13442.8 | gaps | 15.67 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12250 | pass | 0 | 173 | 78 / 1024 | 12223.3 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12500 | pass | 0 | 185 | 732 / 1024 | 12219.0 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12500 (#2) | pass | 0 | 180 | 730 / 1024 | 12223.3 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12500 (#3) | pass | 0 | 361 | 720 / 1024 | 12223.3 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12750 | drops | 5 778 650 | full | 1024 / 1024 | 12219.0 | gaps | 25.76 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12750 (#2) | drops | 5 786 304 | full | 1024 / 1024 | 12219.0 | gaps | 25.76 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 12750 (#3) | drops | 5 427 394 | full | 1024 / 1024 | 12227.7 | gaps | 26.21 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13000 | drops | 16 597 704 | full | 1024 / 1024 | 12214.6 | gaps | 18.05 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13000 (#2) | drops | 16 411 671 | full | 1024 / 1024 | 12219.0 | gaps | 18.04 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13000 (#3) | drops | 16 537 307 | full | 1024 / 1024 | 12219.0 | gaps | 17.65 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13250 | drops | 27 075 672 | full | 1024 / 1024 | 12219.0 | gaps | 13.62 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13250 (#2) | drops | 26 702 306 | full | 1024 / 1024 | 12227.7 | gaps | 13.92 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13250 (#3) | drops | 26 703 711 | full | 1024 / 1024 | 12227.7 | gaps | 13.93 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 32 GiB | 13500 | drops | 37 673 740 | full | 1024 / 1024 | 12223.3 | gaps | 11.38 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 | pass | 0 | 82 | 515 / 1024 | 13532.8 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 (#2) | pass | 0 | 78 | 501 / 1024 | 13543.5 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 (#3) | pass | 0 | 78 | 524 / 1024 | 13532.8 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14000 | drops | 1 049 442 | full | 1024 / 1024 | 13538.1 | gaps | 32.62 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14000 (#2) | drops | 979 670 | full | 1024 / 1024 | 13538.1 | gaps | 32.74 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 14000 (#3) | drops | 842 945 | full | 1024 / 1024 | 13543.5 | gaps | 32.73 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 | pass | 0 | 359 | 514 / 1024 | 13532.8 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 (#2) | pass | 0 | 363 | 522 / 1024 | 13532.8 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 32 GiB | 13750 (#3) | drops | 1 020 790 | full | 1024 / 1024 | 13286.8 | gaps | 33.06 GB | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 6250 | pass | 0 | 69 | 16 / 512 | 6249.5 | pass | - | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 6500 | pass | 0 | 70 | 17 / 512 | 6500.1 | pass | - | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 6750 | pass | 0 | 71 | 256 / 512 | 6697.8 | pass | - | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 6750 (#2) | pass | 0 | 70 | 280 / 512 | 6692.6 | pass | - | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 6750 (#3) | pass | 0 | 70 | 284 / 512 | 6692.6 | pass | - | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 7000 | drops | 11 761 167 | full | 512 / 512 | 6743.8 | gaps | 16.23 GB | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 7000 (#2) | drops | 12 296 109 | full | 512 / 512 | 6735.9 | gaps | 16.28 GB | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 7000 (#3) | drops | 12 210 280 | full | 512 / 512 | 6737.2 | gaps | 16.18 GB | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 7250 | drops | 30 752 505 | full | 512 / 512 | 6750.4 | gaps | 8.11 GB | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 32 GiB | 8000 | drops | 89 425 908 | full | 512 / 512 | 6750.4 | gaps | 3.50 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 4750 | pass | 0 | 150 | 39 / 2048 | 4749.8 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 5000 | pass | 0 | 145 | 41 / 2048 | 5000.0 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 5250 | pass | 0 | 481 | 42 / 2048 | 5249.8 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 5500 | pass | 0 | 1331 | 74 / 2048 | 5499.3 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 5750 | pass | 0 | 2116 | 81 / 2048 | 5749.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 6000 | pass | 0 | 2956 | 74 / 2048 | 5997.5 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 6000 (#2) | pass | 0 | 2843 | 55 / 2048 | 5995.4 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 6000 (#3) | pass | 0 | 2875 | 49 / 2048 | 5996.5 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 6250 | drops | 6 514 046 | 8191 | 1994 / 2048 | 6022.7 | gaps | 0.03 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 6250 (#2) | drops | 6 518 424 | full | 2039 / 2048 | 6022.7 | gaps | 0.03 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 32 GiB | 6250 (#3) | drops | 6 710 395 | full | 2048 / 2048 | 6020.6 | gaps | 0.03 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 6000 | pass | 0 | 2866 | 48 / 2048 | 5999.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 6000 (#2) | pass | 0 | 2870 | 52 / 2048 | 5999.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 6000 (#3) | pass | 0 | 2853 | 51 / 2048 | 5999.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 32 GiB | 6250 | drops | 6 877 790 | 8188 | 51 / 2048 | 6210.0 | gaps | 0.03 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 6000 | pass | 0 | 3624 | 66 / 1024 | 5997.5 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 6000 (#2) | pass | 0 | 2853 | 68 / 1024 | 5996.5 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 6000 (#3) | pass | 0 | 2841 | 63 / 1024 | 5995.4 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 512 × 512 KB (256 MB) | 128 | 32 GiB | 6000 | pass | 0 | 3212 | 53 / 512 | 5996.5 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 512 × 512 KB (256 MB) | 128 | 32 GiB | 6000 (#2) | pass | 0 | 3330 | 52 / 512 | 5999.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 512 × 512 KB (256 MB) | 128 | 32 GiB | 6000 (#3) | pass | 0 | 3411 | 54 / 512 | 5999.6 | pass | - | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 2750 | pass | 0 | 132 | 32 / 1024 | 2749.9 | pass | - | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 3000 | pass | 0 | 132 | 27 / 1024 | 2999.0 | pass | - | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 3000 (#2) | pass | 0 | 211 | 27 / 1024 | 2999.8 | pass | - | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 3000 (#3) | pass | 0 | 132 | 36 / 1024 | 2999.5 | pass | - | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 3250 | drops | 57 030 897 | full | 1024 / 1024 | 3038.3 | gaps | 8.31 GB | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 3250 (#2) | drops | 56 828 579 | full | 1024 / 1024 | 3038.0 | gaps | 8.27 GB | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 128 | 32 GiB | 3250 (#3) | drops | 56 944 406 | full | 1024 / 1024 | 3038.5 | gaps | 8.31 GB | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 3000 | pass | 0 | 133 | 26 / 1024 | 2999.3 | pass | - | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1) | single, 1024 × 512 KB (512 MB) | 256 | 32 GiB | 3250 | pass | 0 | 227 | 30 / 1024 | 3249.8 | pass | - | release image |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 | pass | 0 | 341 | 964 / 4096 | 5249.8 | pass | - | release image |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 | pass | 0 | 334 | 806 / 4096 | 5248.2 | pass | - | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#2) | pass | 0 | 483 | 1208 / 4096 | 5226.6 | pass | - | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#3) | pass | 0 | 829 | 1069 / 4096 | 5249.8 | pass | - | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 | pass | 0 | 500 | 1439 / 4096 | 5249.0 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#2) | pass | 0 | 424 | 1710 / 4096 | 5203.7 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#3) | pass | 0 | 335 | 1840 / 4096 | 5235.4 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5500 | drops | 3 580 765 | full | 4096 / 4096 | 5325.4 | gaps | 33.49 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 | pass | 0 | 840 | 435 / 4096 | 5500.2 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 (#2) | pass | 0 | 966 | 154 / 4096 | 5494.0 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 (#3) | pass | 0 | 1096 | 161 / 4096 | 5497.6 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5750 | pass | 0 | 1191 | 696 / 4096 | 5719.9 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5750 (#2) | pass | 0 | 1214 | 2884 / 4096 | 5638.3 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5750 (#3) | pass | 0 | 1135 | 2339 / 4096 | 5725.7 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 6000 | pass | 0 | 1535 | 2326 / 4096 | 5894.6 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 6000 (#2) | pass | 0 | 1572 | 2196 / 4096 | 5925.1 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 6000 (#3) | pass | 0 | 1582 | 212 / 4096 | 5993.3 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 6250 | drops | 5 866 873 | full | 3695 / 4096 | 6045.0 | gaps | 0.04 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 | pass | 0 | 137 | 2198 / 4096 | 5198.1 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#2) | pass | 0 | 137 | 3289 / 4096 | 5132.9 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#3) | pass | 0 | 137 | 2084 / 4096 | 5186.4 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5500 | drops | 27 352 981 | full | 4096 / 4096 | 5204.4 | gaps | 20.61 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 | pass | 0 | 137 | 3156 / 4096 | 5373.7 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 (#2) | pass | 0 | 137 | 3160 / 4096 | 5367.9 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 (#3) | pass | 0 | 137 | 3696 / 4096 | 5351.2 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5750 | drops | 55 403 182 | full | 4096 / 4096 | 5288.6 | gaps | 12.09 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5000 | pass | 0 | 1538 | 504 / 4096 | 4998.5 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 | pass | 0 | 1725 | 1909 / 4096 | 5240.2 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#2) | pass | 0 | 1799 | 1950 / 4096 | 5207.6 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5250 (#3) | pass | 0 | 1785 | 1642 / 4096 | 5249.8 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5500 | drops | 19 137 610 | full | 4096 / 4096 | 5245.8 | gaps | 20.18 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5500 (#2) | drops | 15 007 333 | full | 4096 / 4096 | 5269.9 | gaps | 26.76 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5500 (#3) | drops | 1 059 672 | full | 4096 / 4096 | 5332.1 | gaps | 29.49 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5250 | drops | 31 582 838 | full | 4096 / 4096 | 5100.2 | gaps | 3.15 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5250 (#2) | pass | 0 | 1715 | 164 / 4096 | 5248.2 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5250 (#3) | pass | 0 | 1718 | 180 / 4096 | 5249.8 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 | drops | 34 098 | full | 1265 / 4096 | 5498.4 | gaps | 0.33 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 (#2) | drops | 47 942 | full | 1193 / 4096 | 5483.5 | gaps | 1.91 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 256 | 32 GiB | 5500 (#3) | drops | 43 531 | full | 1127 / 4096 | 5477.4 | gaps | 6.25 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 5250 | pass | 0 | 1708 | 1634 / 2048 | 5217.1 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 5250 (#2) | pass | 0 | 1745 | 1462 / 2048 | 5245.0 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 5250 (#3) | pass | 0 | 1693 | 1813 / 2048 | 5196.6 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 1024 × 256 KB (256 MB) | 128 | 32 GiB | 5250 | drops | 8 019 994 | full | 1024 / 1024 | 5210.0 | gaps | 15.81 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 1024 × 256 KB (256 MB) | 128 | 32 GiB | 5250 (#2) | drops | 13 209 423 | full | 1024 / 1024 | 5183.2 | gaps | 11.93 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 1024 × 256 KB (256 MB) | 128 | 32 GiB | 5250 (#3) | drops | 15 301 450 | full | 1024 / 1024 | 5151.4 | gaps | 8.09 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 5250 | drops | 20 141 670 | full | 1556 / 2048 | 5148.3 | gaps | 0.01 GB | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, `--qd 63` | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 5500 | drops | 5 649 526 | full | 4096 / 4096 | 5314.7 | gaps | 32.74 GB | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 2750 | pass | 0 | 132 | 802 / 4096 | 2745.7 | pass | - | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 32 GiB | 3000 | drops | 55 601 672 | full | 4096 / 4096 | 2747.7 | gaps | 14.23 GB | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 2750 | pass | 0 | 132 | 569 / 2048 | 2749.2 | pass | - | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 2750 (#2) | pass | 0 | 132 | 655 / 2048 | 2747.0 | pass | - | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 2750 (#3) | pass | 0 | 132 | 601 / 2048 | 2747.5 | pass | - | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 3000 | drops | 69 358 020 | full | 2048 / 2048 | 2761.6 | gaps | 7.57 GB | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 3000 (#2) | drops | 68 186 662 | full | 2048 / 2048 | 2777.2 | gaps | 7.46 GB | earlier |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 128 | 32 GiB | 3000 (#3) | drops | 70 289 239 | full | 2048 / 2048 | 2773.4 | gaps | 6.91 GB | earlier |

### Ring size

The ring absorbs the time an SSD takes to complete its writes: a recording drops beats when the
drives fall behind by more than the ring holds. The default is **1 GB for a split ring** (half
in each memory: 2048 × 512 KB with the 980 PRO, 4096 × 256 KB with the Sabrent, 1024 × 1 MB
with the SN8100; the hardware has 4096 slots) and 512 MB for a single ring. Measured at the RAID0 recording tops:

| SSD | target | layout | ring | rate (MB/s) | recordings with drops | ring high-water (slots) | build |
|---|---|---|---|---|---|---|---|
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 2048 × 512 KB (1 GB, default) | 10000 | 0 of 1 | 655 of 2048 | release image |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 2048 × 512 KB (1 GB, default) | 10000 | 0 of 3 | 636 / 715 / 649 of 2048 | final |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 1024 × 512 KB (512 MB) | 10000 | 0 of 3 | 650 / 691 / 707 of 1024 | final |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 32 GB, 4 KB stripes, MaxPayload 128 | 512 × 512 KB (256 MB) | 10000 | **3 of 3** (first gaps 27.48 / 23.40 / 25.69 GB) | 512 of 512 | earlier |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0, 350 GiB past the cache | 2048 × 512 KB (1 GB, default) | 3250 | 0 of 1 | 316 of 2048 | final |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 4096 × 256 KB (1 GB, default) | 8250 | 0 of 3 | 1796 / 2519 / 3836 of 4096 | release image |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 2048 × 256 KB (512 MB) | 8250 | **3 of 3** (first gaps 16.95 / 13.09 / 17.55 GB) | 2048 of 2048 | release image |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 1024 × 256 KB (256 MB) | 8250 | **3 of 3** (first gaps 13.43 / 9.58 / 9.02 GB) | 1024 of 1024 | release image |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 2048 × 256 KB (512 MB) | 8000 | 0 of 3 | 418 / 447 / 433 of 2048 | release image |
| 2x Sabrent SB-2130-1TB | `vck190_fmcp1` | RAID0, 350 GiB past the cache | 4096 × 256 KB (1 GB, default) | 3250 | 0 of 1 | 670 of 4096 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 1024 × 1 MB (1 GB, default) | 13750 | 0 of 3 | 596 / 529 / 527 of 1024 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 512 × 1 MB (512 MB) | 13750 | **3 of 3** (first gaps 33.64 / 33.64 / 33.57 GB) | 512 of 512 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 32 GB, whole-chunk stripes | 256 × 1 MB (256 MB) | 13750 | **3 of 3** (first gaps 16.77 / 17.13 / 15.67 GB) | 256 of 256 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 32 GB, 4 KB stripes | 1024 × 1 MB (1 GB, default) | 13750 | 0 of 3 | 515 / 501 / 524 of 1024 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 350 GiB (in the cache) | 1024 × 1 MB (1 GB, default) | 13500 | 0 of 1 | 91 of 1024 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 800 GiB past the cache | 1024 × 1 MB (1 GB, default) | 2000 | 0 of 3 | 843 / 843 / 846 of 1024 | release image |
| 2x WD_BLACK SN8100 HS 1000GB | `vck190_fmcp1` | RAID0, 800 GiB past the cache | 1024 × 1 MB (1 GB, default) | 2250 | **1 of 1** (first gap 819.3 GB) | 1024 of 1024 | release image |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, whole-chunk stripes | 4096 × 256 KB (1 GB, default) | 5250 | 0 of 1 | 964 of 4096 | release image |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, whole-chunk stripes | 4096 × 256 KB (1 GB, default) | 5250 | 0 of 3 | 806 / 1208 / 1069 of 4096 | final |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, whole-chunk stripes | 4096 × 256 KB (1 GB, default) | 5250 | 0 of 3 | 1439 / 1710 / 1840 of 4096 | earlier |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, 4 KB stripes | 4096 × 256 KB (1 GB, default) | 5250 | 0 of 3 | 2198 / 3289 / 2084 of 4096 | earlier |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, 64 KB stripes | 2048 × 256 KB (512 MB) | 5250 | 0 of 3 | 1634 / 1462 / 1813 of 2048 | earlier |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, 64 KB stripes | 1024 × 256 KB (256 MB) | 5250 | **3 of 3** (first gaps 15.81 / 11.93 / 8.09 GB) | 1024 of 1024 | earlier |
| 2x Sabrent SB-2130-1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 350 GiB past the cache, 64 KB stripes | 4096 × 256 KB (1 GB, default) | 3250 | 0 of 1 | 799 of 4096 | earlier |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0, 32 GB, whole-chunk stripes (MaxPayload 256) | 2048 × 512 KB (1 GB, default) | 6000 | 0 of 3 | 48 / 52 / 51 of 2048 | release image |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, whole-chunk stripes | 2048 × 512 KB (1 GB, default) | 6000 | 0 of 3 | 74 / 55 / 49 of 2048 | release image |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, whole-chunk stripes | 1024 × 512 KB (512 MB) | 6000 | 0 of 3 | 66 / 68 / 63 of 1024 | release image |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 32 GB, whole-chunk stripes | 512 × 512 KB (256 MB) | 6000 | 0 of 3 | 53 / 52 / 54 of 512 | release image |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 350 GiB past the cache | 2048 × 512 KB (1 GB, default) | 3250 | 0 of 1 | 231 of 2048 | release image |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | MaxPayload 128, RAID0, 350 GiB past the cache | 2048 × 512 KB (1 GB, default) | 3500 | 0 of 1 | **1134 of 2048 (567 MB)** | release image |

**Keep the 1 GB default.** How much of it a RAID0 recording needs depends on the pair:

* the **Sabrent pair on `vck190_fmcp1`** needs all of it at its 8250 MB/s top (up to 3836 of
  4096 slots): with 512 MB or 256 MB it drops in 3 of 3 runs; a 512 MB ring holds 8000 MB/s;
* the **SN8100 pair on `vck190_fmcp1`** needs more than 512 MB at its 13 750 MB/s top (up to
  596 of 1024 slots of 1 MB): with 512 MB it drops in 3 of 3 runs at 33.6 GB, with 256 MB at
  15.7-17.1 GB. The pair writes ~0.22 GB/s less than 13 750 MB/s (~550-600 MB over 32 GB); smaller
  rings were not measured below 13 750 MB/s. Past its cache, at 2000 MB/s over 800 GiB, it used
  up to 846 slots (846 MB) where the first drive enters its slowest phase, and at 2250 MB/s the
  whole ring (drops from 819.3 GB);
* the **980 PRO pair on `vck190_fmcp1`** at 10 000 MB/s and the **Sabrent pair on
  `zcu106_hpc0`** at 5250 MB/s (MaxPayload 128) need more than 256 MB: a 512 MB ring is clean 3 of 3, a 256 MB
  ring drops in 3 of 3 runs, late in the 32 GB recording. The 980 PRO pair writes ~0.1 GB/s
  less than 10 000 MB/s (~340 MB over 32 GB), the Sabrents have write-latency spikes of up to
  25 ms, and 4 KB stripes use more of the ring than whole chunks (up to 822 MB);
* the **980 PRO pair on `zcu106_hpc0`** (MaxPayload 128) barely uses the ring at its 6000 MB/s top (at most
  81 slots, 41 MB; a 256 MB ring is as clean), but **past the cache, at 3500 MB/s, it used
  567 MB**, more than a 512 MB ring holds.

A single ring (one SSD) stays at 512 MB; see [Ring size and CMA](apps.md#ring-size-and-cma) for
the CMA each ring needs.

**The ring is sized in 2 MB units.** The driver's interface takes the ring in multiples of
2 MB, so `nvrec` and `nvplay` round `--buffers` **up** to a multiple of 2 MB / chunk slots:
8 slots of 256 KB, 4 slots of 512 KB, 2 slots of 1 MB. On the bench `--buffers 255` gave 256 slots of 256 KB on
`zcu106_hpc0` (1023 gave 1024, 300 gave 304), and 3 / 5 / 255 / 257 gave 4 / 8 / 256 / 260
slots of 512 KB on `vck190_fmcp1`, with any stripe. The count is therefore always even below
2 MB chunks, as a split ring with whole-chunk stripes needs (each SSD then writes one memory);
the driver's own rounding of an odd count down only applies to 2 MB and 4 MB chunks or to
programs that call `NVREC_IOC_SET_RING` directly. The apps print a note on stderr when the slots
used differ from `--buffers` (`note: N ring slots asked for, M used`), and `RESULT` `ring_slots`
is the count used.

### Burst and 40 GB recordings

Single recordings at a fixed rate on a freshly deallocated volume after 60 s of idle time:
10 GiB and 40 GiB at the highest clean step of the 32 GB sweep and at the next step. The
40 GiB recordings are still inside the SLC caches of these drives.

| target | SSD | layout | ring | MaxPayload | size | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | ring high-water (slots) | avg MB/s | nvverify | first gap | build |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 10 GiB | 10000 | pass | 0 | 171 | 215 / 2048 | 9914.5 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 10 GiB | 10250 | pass | 0 | 98 | 705 / 2048 | 9896.2 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 40 GiB | 10000 | pass | 0 | 107 | 833 / 2048 | 9903.1 | pass | - | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 40 GiB | 10250 | drops | 6 299 619 | full | 2048 / 2048 | 9905.4 | gaps | 31.81 GB | final |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 10 GiB | 8250 | pass | 0 | 71 | 1712 / 4096 | 7912.6 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 10 GiB | 8500 | pass | 0 | 71 | 2616 / 4096 | 8019.0 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 40 GiB | 8000 | drops | 49 267 974 | full | 4096 / 4096 | 7448.8 | gaps | 1.82 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 40 GiB | 8000 (#2) | pass | 0 | 71 | 423 / 4096 | 7990.6 | pass | - | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 40 GiB | 8250 | drops | 7 678 767 | full | 4096 / 4096 | 7911.2 | gaps | 32.20 GB | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 40 GiB | 8500 | drops | 23 859 090 | full | 4096 / 4096 | 7961.0 | gaps | 22.63 GB | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10 GiB | 13750 | pass | 0 | 264 | 279 / 1024 | 13388.3 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10 GiB | 14000 | pass | 0 | 658 | 360 / 1024 | 13523.2 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 40 GiB | 13750 | pass | 0 | 536 | 654 / 1024 | 13523.2 | pass | - | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 40 GiB | 14000 | drops | 8 876 353 | full | 1024 / 1024 | 13472.3 | gaps | 30.58 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10 GiB | 6000 | pass | 0 | 2955 | 49 / 2048 | 5998.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10 GiB | 6250 | drops | 2 034 249 | 8187 | 643 / 2048 | 6022.1 | gaps | 0.03 GB | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 10 GiB | 6000 | pass | 0 | 2861 | 46 / 2048 | 5998.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 40 GiB | 6000 | pass | 0 | 3021 | 50 / 2048 | 5998.6 | pass | - | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 40 GiB | 6250 | drops | 16 681 925 | full | 2048 / 2048 | 6018.7 | gaps | 0.03 GB | release image |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 10 GiB | 5250 | pass | 0 | 1744 | 172 / 4096 | 5248.0 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 10 GiB | 5500 | pass | 0 | 2367 | 425 / 4096 | 5447.7 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 40 GiB | 6000 | pass | 0 | 1773 | 2930 / 4096 | 5869.0 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 40 GiB | 5250 | pass | 0 | 1725 | 1559 / 4096 | 5241.6 | pass | - | earlier |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0 | split, 64 KB, 4096 × 256 KB (1024 MB) | 128 | 40 GiB | 5500 | drops | 12 919 496 | full | 4096 / 4096 | 5318.8 | gaps | 32.84 GB | earlier |

The 1 GB ring carries a 10 GiB recording one step above the 32 GB top where the drives are the
limit (the deficit of 10 GiB fits in it), not with the 980 PRO pair on `zcu106_hpc0`, whose
6250 MB/s runs drop 25 MB in (the ring writer). Over 40 GiB the tops are those of the 32 GB
sweep, except for the Sabrent pair on `vck190_fmcp1`, whose ring-assisted 8250 MB/s does not
last 40 GiB (drops from 32.20 GB): 8000 MB/s.

**The SLC cache needs idle time to recover.** The first 40 GiB recording at 8000 MB/s with the
Sabrent pair on `vck190_fmcp1` started 3 minutes after the 350 GiB recording and dropped from
1.82 GB, the pair writing only 7.45 GB/s: the drives had not emptied their cache yet. Run again
9 minutes later (after three 32 GB recordings), it passed (`8000 (#2)` above). Leave the drives
idle for some minutes after a recording that went past their cache.

### Long recordings past the SLC cache

A 32 GB or 40 GB recording stays inside the SLC cache of these 1 TB drives, so the rate that
holds for a long recording was measured with one recording of 350 GiB on RAID0, 1.5 times the
980 PRO pair's cache and 2.7 times the Sabrent pair's (see [The SLC cache](#the-slc-cache)), on
a freshly deallocated volume after 300 s of idle time, `nvverify` of the whole file, at the
Release 1.1 past-cache top of each pair (the SN8100 pair, new in this revision, at 3250 MB/s and
at 13 500 MB/s). 350 GiB stays inside the SN8100 pair's cache, so that pair was recorded again
with 800 GiB in the same way, from 13 500 MB/s down to 2000 MB/s (`nvverify` of the third
2000 MB/s run; the others are judged by `nvrec`'s own check: 0 dropped beats, 0 NVMe errors).

| target | SSD | layout | size | pre-idle (s) | rate (MB/s) | result | drops (beats) | NVMe errors | ring high-water (slots) | latency avg / max (µs) | nvverify | max drive temp. (°C) | build |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, whole-chunk stripes, MaxPayload 256 | 350 GiB | 300 | 3250 | pass | 0 | 0 | 316 / 2048 | 651 / 38 646 | pass | 44 | final |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, whole-chunk stripes, MaxPayload 256 | 350 GiB | 300 | 3250 | pass | 0 | 0 | 670 / 4096 | 1134 / 23 305 | pass | 65 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 350 GiB | 300 | 3250 | pass | 0 | 0 | 11 / 1024 | 160 / 3 059 | pass | 30 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 350 GiB | 300 | 13500 | pass | 0 | 0 | 91 / 1024 | 1 059 / 5 560 | pass | 31 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 800 GiB | 300 | 2000 | pass | 0 | 0 | 843 / 1024 | 620 / 74 820 | - | 37 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 800 GiB | 300 | 2000 (#2) | pass | 0 | 0 | 843 / 1024 | 609 / 74 050 | - | 36 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 800 GiB | 300 | 2000 (#3) | pass | 0 | 0 | 846 / 1024 | 609 / 74 175 | pass | 36 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 800 GiB | 300 | 2250 | drops (from 819.3 GB) | 17 057 169 | 0 | 1024 / 1024 | 834 / 74 507 | - | 36 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 800 GiB | 300 | 3250 | drops (from 817.9 GB) | 309 706 715 | 0 | 1024 / 1024 | 986 / 74 582 | - | 37 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 800 GiB | 300 | 13500 | drops (from 683.7 GB) | 8 628 271 552 | 0 | 1024 / 1024 | 4376 / 74 698 | - | 36 | release image |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, 64 KB stripes, MaxPayload 128 | 350 GiB | 300 | 3250 | pass | 0 | 0 | 799 / 4096 | 1111 / 27 879 | pass | 65 | earlier |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, whole-chunk stripes, MaxPayload 128 | 350 GiB | 300 | 3250 | pass | 0 | 0 | 231 / 2048 | 733 / 36 991 | pass | 51 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, whole-chunk stripes, MaxPayload 128 | 350 GiB | 300 | 3500 | pass | 0 | 0 | 1134 / 2048 | 1765 / 45 946 | pass | 51 | release image |

Every pair that Release 1.1 measured holds its past-cache rate: 3250 MB/s, and 3500 MB/s with the 980 PRO
pair on `zcu106_hpc0` (3494.1 MB/s written over 107.6 s). **The SN8100 pair shows no SLC
cliff in 350 GiB**: it records 350 GiB at 13 500 MB/s (175 GiB per drive at 6.75 GB/s, the
drives' Gen4 x4 links) with the ring never above 91 of 1024 slots and the write latency at
most 5.6 ms: 350 GiB (~188 GB per drive) stays inside its ~340 GB cache per drive. **Over
800 GiB it holds 2000 MB/s** (3 of 3), the ring at up to 843-846 of 1024 slots (~82 %) near
818 GB, where the first drive steps down from ~1.96 to ~1.12 GB/s (see
[The SLC cache](#the-slc-cache)). 2250 MB/s drops from 819.3 GB and 3250 MB/s from 817.9 GB,
both at that step; after it the pair writes ~2.23 GB/s on average, in a 3 s sawtooth. At
13 500 MB/s the pair records **683.7 GB (~51 s)** clean, its two drives' caches, then drops.
The margin at 2000 MB/s is thin: a longer recording, or fuller drives, need a lower rate. Past
the cache the drives' flash is the limit, whatever the ring; the 980 PRO and Sabrent pairs were
not run at higher rates in this revision. A run this
long accumulates more than 17 s of ring writer wait on memory 0 (`WR_PORT_STALL0` saturates at
17 179.886 ms): read the counters of long runs by their growth, not by their final value.

### Playback

A 10 GiB recording made at 1000 MB/s with 0 drops, `nvplay` in 250 MB/s steps as in the
[playback method](#playback), then the top confirmed with a 40 GiB file. **The last column, the
40 GiB figure, is the sustained playback rate**; a 10 GiB step above it is ring-assisted.

| target | SSD | layout | highest clean step, 10 GiB file | first failing step (0 of 3), 10 GiB | sustained playback rate (40 GiB file) |
|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, whole-chunk stripes, MaxPayload 256 | **11 000 MB/s** (1 run; 11 250-11 750 MB/s 2 of 3 each) | 12 000 MB/s (0 of 3; 11.85 GB/s streamed) | **11 000 MB/s** (3 of 3 on the release image, 0 underflow ticks; 8 of 9 runs clean on two recordings in the measurement session; 11 250 MB/s 1 of 2, 11 500 MB/s 1 of 1; at 12 000 MB/s 11.84 GB/s streamed) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | the same at MaxPayload 128 | - | - | **10 750 MB/s** (3 of 3 on two recordings; 11 000 MB/s 4 of 6, 11 250 MB/s 1 of 2) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk, single ring, MaxPayload 128 | 6250 MB/s (3 of 3; 6500 MB/s 2 of 3) | 6750 MB/s (0 of 3; 6.50-6.52 GB/s) | **6250 MB/s** (3 of 3; earlier build) |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, whole-chunk stripes, MaxPayload 256 | - | - | **9250 MB/s** (3 of 3, 0 underflow ticks at every step from 8000 MB/s; 9500 MB/s 0 of 1, 9.27 GB/s streamed) |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | the same at MaxPayload 128 | - | - | **9250 MB/s** (3 of 3; 9500 MB/s 0 of 1, 9.29 GB/s streamed) |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk, single ring, MaxPayload 256 | - | - | **4500 MB/s** (3 of 3; 4750 MB/s 0 of 1, 4.59 GB/s streamed) |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, whole-chunk stripes, MaxPayload 256 | 11 500 MB/s | 11 750 MB/s (0 of 3; 12 000 MB/s 0 of 1, 11.92 GB/s streamed) | **11 000 MB/s** (8 of 9 runs clean on three recordings: 3 of 3 on two, 2 of 3 on the third, whose failing run was short of data for 0.19 µs; 10 750 MB/s 3 of 3 on both recordings it was played from; 11 500 MB/s 3 of 3 on one; at 12 000-14 000 MB/s 11.90-11.95 GB/s streamed: the memory side) |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, **4 KB stripes** (`--stripe 4`), MaxPayload 256 | 15 250 MB/s | 15 500 MB/s (0 of 3, 15.43-15.47 GB/s) | **14 250 MB/s** (3 of 3, clean at every step from 10 250 MB/s over two recordings; 14 500 MB/s 0 of 1, 14.32 GB/s streamed: the drives' Gen4 x4 links) |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | the same, whole-chunk stripes, at MaxPayload 128 | - | - | **10 750 MB/s** (3 of 3; 11 000 MB/s 1 of 2) |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1), 1M chunk, single ring, MaxPayload 256 | 7250 MB/s | 7500 MB/s (0 of 3, 7.44 GB/s) | **7000 MB/s** (3 of 3; 7250 MB/s 0 of 1, 7.16 GB/s streamed) |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, whole-chunk stripes, MaxPayload 256 (the default) | 5750 MB/s (3 of 3; 6000 MB/s 2 of 3; earlier build) | 6250 MB/s (0 of 3; 6115-6118 MB/s) | **6000 MB/s** (3 of 3; 6250 MB/s 2 of 3, one run short of data for 0.05 ms) |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | the same at MaxPayload 128 (`nvrec-mps 128`) | 5750 MB/s (3 of 3, ring-assisted; earlier build) | 6000 MB/s (0 of 3; 5988.5 MB/s streamed) | **5250 MB/s** (3 of 3 on two recordings, clean again on the release image; 5500 MB/s 0 of 6, 5.47-5.50 GB/s streamed; 5750 MB/s 5.53 GB/s) |
| `zcu106_hpc0` | Sabrent SB-2130-1TB | single (SSD1), 256K chunk, single ring, MaxPayload 128 | 3250 MB/s (3 of 3, ring-assisted) | 3500 MB/s (0 of 3; 3332-3351 MB/s) | **3000 MB/s** (3 of 3; 3250 MB/s 0 of 3, 3224.2 MB/s streamed; earlier build) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, whole-chunk stripes, MaxPayload 256 (the default) | - | - | **5750 MB/s** (3 of 3 on two recordings, 0 underflow ticks; 6000 MB/s 2 of 6, the others short of data for 0.7 µs-0.2 ms; 6250 MB/s 0 of 3, a steady 6.17 GB/s) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | the same at MaxPayload 128 (`nvrec-mps 128`) | 5500 MB/s (3 of 3, ring-assisted; not run higher) | - | **5250 MB/s** (3 of 3; 5500 MB/s 0 of 3, a steady 5.47 GB/s; 5750 MB/s 5.50 GB/s) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk, single ring, MaxPayload 256 (the default) | - | - | **3500 MB/s** (one run; 3000 MB/s clean too; not run higher) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), 512K chunk, single ring, MaxPayload 128 | 3000 MB/s (3 of 3; not run higher) | - | **3000 MB/s** (3 of 3; 3250 MB/s 0 of 3, 3228 MB/s streamed) |

The 40 GiB playbacks on the published bitstreams (40 GiB recorded at 1000 MB/s with 0 drops and
verified, then played 3 times per rate, the page cache dropped before every run; "source" is
the recording: with the 980 PRO pair on `vck190_fmcp1` and the Sabrent pair on `zcu106_hpc0`
two independent ones in the measurement session and a third one for the release image's
confirmation; three with the SN8100 pair, all on the release image; one recording for each of
the other two pairs, and one for each single drive. The SN8100 pair's 4 KB-striped runs below
12 000 MB/s, clean at every step from 10 250 MB/s on source 1, are not listed):

| target | SSD | layout, source | ring | MaxPayload | rate (MB/s) | result | underflow ticks | streaming MB/s | read latency avg / max (µs) | reader waited for memory 0 / 1 (ms) | build |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 3 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 | clean | 0 | 10999.8 | 202 / 2 893 | 589.1 / 631.0 | release image |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 3 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10999.7 | 202 / 2 737 | 589.0 / 631.1 | release image |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 3 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#3) | clean | 0 | 10999.7 | 200 / 2 766 | 588.8 / 631.4 | release image |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 10750 | clean | 0 | 10749.8 | 205 / 4 479 | 648.7 / 662.2 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 10750 (#2) | clean | 0 | 10749.8 | 202 / 3 538 | 648.8 / 662.2 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 10750 (#3) | clean | 0 | 10749.8 | 202 / 4 334 | 648.7 / 662.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 | clean | 0 | 10999.8 | 203 / 3 717 | 589.7 / 630.5 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10999.8 | 203 / 2 962 | 588.8 / 631.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#3) | underflows | 3 026 | 10999.7 | 202 / 2 984 | 592.9 / 627.2 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#4) | clean | 0 | 10999.8 | 205 / 3 295 | 588.2 / 632.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#5) | clean | 0 | 10999.9 | 203 / 3 195 | 588.7 / 631.5 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#6) | clean | 0 | 10999.8 | 206 / 3 181 | 590.0 / 630.1 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 | clean | 0 | 10999.8 | 204 / 3 044 | 588.4 / 631.7 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10999.9 | 204 / 3 163 | 589.7 / 630.4 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11000 (#3) | clean | 0 | 10999.9 | 203 / 3 018 | 589.8 / 630.4 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11250 | clean | 0 | 11249.9 | 206 / 2 973 | 506.1 / 627.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11250 (#2) | underflows | 33 554 | 11249.3 | 204 / 3 032 | 512.6 / 620.9 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 11500 | clean | 0 | 11499.8 | 215 / 2 978 | 425.4 / 625.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 12000 | underflows | 9 165 740 | 11838.2 | 217 / 3 050 | 410.0 / 533.6 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10250 | clean | 0 | 10249.8 | 844 / 5 017 | 749.8 / 756.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10250 (#2) | clean | 0 | 10249.8 | 636 / 5 152 | 753.2 / 752.6 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10250 (#3) | clean | 0 | 10249.9 | 384 / 4 978 | 752.3 / 753.6 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10500 | clean | 0 | 10499.8 | 212 / 3 556 | 699.0 / 707.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10500 (#2) | clean | 0 | 10499.8 | 230 / 4 692 | 701.8 / 704.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10500 (#3) | clean | 0 | 10499.8 | 222 / 4 630 | 698.8 / 707.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10750 | clean | 0 | 10749.8 | 212 / 4 276 | 645.8 / 665.1 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10750 (#2) | clean | 0 | 10749.9 | 207 / 3 382 | 645.1 / 665.9 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10750 (#3) | clean | 0 | 10749.8 | 208 / 3 638 | 643.8 / 667.2 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11000 | clean | 0 | 10999.9 | 208 / 3 505 | 575.8 / 644.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11000 (#2) | clean | 0 | 10999.8 | 209 / 3 693 | 574.2 / 646.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11000 (#3) | underflows | 5 231 | 10999.8 | 209 / 3 443 | 575.2 / 645.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10750 | clean | 0 | 10749.8 | 208 / 3 616 | 643.7 / 667.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10750 (#2) | clean | 0 | 10749.8 | 208 / 3 760 | 645.5 / 665.5 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 10750 (#3) | clean | 0 | 10749.9 | 208 / 3 874 | 644.7 / 666.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11000 | clean | 0 | 10999.8 | 209 / 3 777 | 574.0 / 646.1 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11000 (#2) | clean | 0 | 10999.8 | 208 / 3 707 | 574.3 / 645.9 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11000 (#3) | underflows | 6 695 | 10999.8 | 210 / 3 732 | 575.5 / 644.7 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11250 | clean | 0 | 11249.8 | 211 / 3 577 | 491.6 / 641.8 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 11250 (#2) | underflows | 28 191 | 11249.4 | 210 / 3 596 | 493.9 / 639.6 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10500 | clean | 0 | 10499.9 | 1630 / 5 540 | 654.0 / 752.1 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10500 (#2) | clean | 0 | 10499.9 | 209 / 5 011 | 658.9 / 747.2 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10500 (#3) | clean | 0 | 10499.9 | 192 / 4 853 | 658.7 / 747.4 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10750 | underflows | 4 960 965 | 10671.0 | 1851 / 5 225 | 596.2 / 703.3 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10500 | clean | 0 | 10499.9 | 1779 / 5 527 | 653.0 / 753.1 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10500 (#2) | clean | 0 | 10499.9 | 1718 / 5 576 | 649.3 / 756.8 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10500 (#3) | clean | 0 | 10499.9 | 1712 / 5 589 | 651.1 / 754.9 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 10750 | underflows | 11 019 950 | 10576.2 | 1804 / 5 575 | 588.7 / 695.2 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 11000 | underflows | 22 383 809 | 10644.8 | 1816 / 5 688 | 535.7 / 633.9 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 12000 | underflows | 85 840 935 | 10639.0 | 1825 / 5 635 | 344.3 / 420.5 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | single, 1024 × 512 KB (512 MB) | 256 | 8750 | clean | 0 | 8749.9 | 187 / 2 758 | 2200.0 / 0.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | single, 1024 × 512 KB (512 MB) | 256 | 8750 (#2) | clean | 0 | 8749.9 | 187 / 2 965 | 2199.9 / 0.0 | final |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | single, 1024 × 512 KB (512 MB) | 256 | 8750 (#3) | clean | 0 | 8749.9 | 188 / 2 928 | 2200.0 / 0.0 | final |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8000 | clean | 0 | 7999.9 | 231 / 2 472 | 1107.0 / 1167.0 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8000 (#2) | clean | 0 | 7999.9 | 230 / 2 568 | 1107.0 / 1167.0 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8000 (#3) | clean | 0 | 7999.9 | 231 / 2 571 | 1106.7 / 1167.0 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8250 | clean | 0 | 8249.9 | 236 / 2 655 | 1090.7 / 1139.9 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8250 (#2) | clean | 0 | 8249.9 | 238 / 2 566 | 1090.8 / 1139.8 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8250 (#3) | clean | 0 | 8249.9 | 240 / 2 578 | 1090.5 / 1140.0 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8500 | clean | 0 | 8499.9 | 270 / 2 593 | 1072.4 / 1108.3 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8500 (#2) | clean | 0 | 8499.9 | 271 / 2 460 | 1072.5 / 1108.1 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8500 (#3) | clean | 0 | 8499.9 | 273 / 2 591 | 1074.8 / 1108.1 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8750 | clean | 0 | 8749.9 | 373 / 2 623 | 1048.4 / 1070.6 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8750 (#2) | clean | 0 | 8749.9 | 376 / 2 520 | 1050.2 / 1070.5 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 8750 (#3) | clean | 0 | 8749.9 | 377 / 2 449 | 1048.7 / 1070.5 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9000 | clean | 0 | 8999.9 | 646 / 2 654 | 1014.8 / 1026.5 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9000 (#2) | clean | 0 | 8999.9 | 651 / 2 453 | 1014.7 / 1026.4 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9000 (#3) | clean | 0 | 8999.9 | 675 / 2 581 | 1013.7 / 1026.8 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9250 | clean | 0 | 9249.9 | 1482 / 2 712 | 969.8 / 975.9 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9250 (#2) | clean | 0 | 9249.9 | 1411 / 2 750 | 969.8 / 975.9 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9250 (#3) | clean | 0 | 9249.9 | 1382 / 2 733 | 969.8 / 975.9 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9250 (#4) | clean | 0 | 9249.9 | 1509 / 2 967 | 969.1 / 976.3 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9250 (#5) | clean | 0 | 9249.9 | 1432 / 2 788 | 969.1 / 976.3 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9250 (#6) | clean | 0 | 9249.9 | 1512 / 2 794 | 969.1 / 976.3 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 9500 | underflows | 16 633 216 | 9270.1 | 1484 / 2 683 | 887.1 / 894.4 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 8750 | clean | 0 | 8749.9 | 373 / 2 552 | 1056.1 / 1082.4 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 8750 (#2) | clean | 0 | 8749.9 | 375 / 2 566 | 1055.5 / 1082.6 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 8750 (#3) | clean | 0 | 8749.9 | 376 / 2 567 | 1056.0 / 1082.4 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9000 | clean | 0 | 8999.9 | 671 / 2 632 | 1018.0 / 1032.5 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9000 (#2) | clean | 0 | 8999.9 | 646 / 2 567 | 1019.1 / 1032.0 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9000 (#3) | clean | 0 | 8999.9 | 647 / 2 563 | 1018.0 / 1032.4 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9250 | clean | 0 | 9249.9 | 1370 / 2 707 | 971.0 / 977.9 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9250 (#2) | clean | 0 | 9249.9 | 1468 / 2 681 | 970.4 / 978.3 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9250 (#3) | clean | 0 | 9249.9 | 1514 / 2 742 | 971.1 / 977.8 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 9500 | underflows | 15 404 391 | 9286.7 | 1469 / 2 661 | 887.4 / 896.7 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 9250 | clean | 0 | 9249.9 | 1444 / 2 715 | 924.8 / 1020.3 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 9250 (#2) | clean | 0 | 9249.9 | 1526 / 2 763 | 913.7 / 1030.8 | release image |
| `vck190_fmcp1` | 2x Sabrent SB-2130-1TB | RAID0 | split, 4 KB, 4096 × 256 KB (1024 MB) | 256 | 9250 (#3) | clean | 0 | 9249.9 | 1475 / 2 768 | 914.0 / 1030.6 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 4500 | clean | 0 | 4500.0 | 642 / 2 590 | 1175.7 / 1276.5 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4250 | clean | 0 | 4250.0 | 253 / 2 759 | 2514.1 / 0.0 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4250 (#2) | clean | 0 | 4250.0 | 251 / 2 447 | 2503.8 / 0.0 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4250 (#3) | clean | 0 | 4250.0 | 250 / 2 481 | 2506.3 / 0.0 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4500 | clean | 0 | 4500.0 | 603 / 2 477 | 2525.7 / 0.0 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4500 (#2) | clean | 0 | 4500.0 | 623 / 2 529 | 2514.9 / 0.0 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4500 (#3) | clean | 0 | 4500.0 | 632 / 2 512 | 2517.7 / 0.0 | release image |
| `vck190_fmcp1` | Sabrent SB-2130-1TB | single (SSD1) | single, 2048 × 256 KB (512 MB) | 256 | 4750 | underflows | 22 938 592 | 4593.0 | 1846 / 2 905 | 2405.6 / 0.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 | clean | 0 | 10998.6 | 267 / 4 852 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10998.6 | 266 / 4 881 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#3) | clean | 0 | 10998.6 | 266 / 4 840 | 609.6 / 610.5 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11250 | underflows | 2 855 | 11249.3 | 267 / 4 849 | 567.3 / 566.1 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 12000 | underflows | 5 330 486 | 11904.0 | 268 / 4 851 | 392.1 / 531.1 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 13000 | underflows | 60 270 877 | 11927.2 | 267 / 4 876 | 388.8 / 527.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 14000 | underflows | 115 071 533 | 11950.4 | 267 / 4 848 | 384.4 / 525.1 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10750 | clean | 0 | 10750.9 | 267 / 4 832 | 655.7 / 655.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10750 (#2) | clean | 0 | 10750.9 | 266 / 4 830 | 655.1 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10750 (#3) | clean | 0 | 10750.9 | 266 / 4 836 | 655.1 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 | clean | 0 | 10998.6 | 267 / 4 836 | 609.6 / 610.5 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10998.6 | 266 / 4 834 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#3) | clean | 0 | 10998.6 | 266 / 4 835 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11250 | clean | 0 | 11249.3 | 268 / 4 835 | 565.8 / 567.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11250 (#2) | clean | 0 | 11249.3 | 268 / 4 834 | 566.3 / 567.1 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11250 (#3) | clean | 0 | 11249.3 | 266 / 4 830 | 566.1 / 567.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11500 | clean | 0 | 11499.2 | 267 / 4 837 | 486.2 / 564.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11500 (#2) | clean | 0 | 11499.2 | 266 / 4 837 | 486.4 / 564.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11500 (#3) | clean | 0 | 11499.2 | 266 / 4 839 | 486.4 / 564.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 2 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11750 | underflows | 485 580 | 11741.3 | 267 / 4 832 | 402.0 / 571.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10750 | clean | 0 | 10750.9 | 267 / 4 838 | 655.1 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10750 (#2) | clean | 0 | 10750.9 | 266 / 4 840 | 655.1 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 10750 (#3) | clean | 0 | 10750.9 | 266 / 4 844 | 655.0 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 | clean | 0 | 10998.6 | 266 / 4 856 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10998.6 | 267 / 4 842 | 609.5 / 610.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#3) | underflows | 47 | 10998.6 | 266 / 4 837 | 610.5 / 609.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 10500 | clean | 0 | 10498.6 | 297 / 5 378 | 702.7 / 703.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 10500 (#2) | clean | 0 | 10498.6 | 296 / 5 368 | 702.7 / 703.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 10500 (#3) | clean | 0 | 10498.6 | 296 / 5 417 | 702.7 / 703.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 10750 | clean | 0 | 10750.9 | 297 / 5 362 | 655.0 / 656.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 10750 (#2) | clean | 0 | 10750.9 | 297 / 5 372 | 655.1 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 10750 (#3) | clean | 0 | 10750.9 | 296 / 5 378 | 655.1 / 655.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 11000 | clean | 0 | 10998.6 | 296 / 5 388 | 609.5 / 610.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, whole chunk, 1024 × 1 MB (1024 MB) | 128 | 11000 (#2) | underflows | 15 892 | 10998.6 | 297 / 5 370 | 612.7 / 607.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 | clean | 0 | 10998.6 | 371 / 9 474 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#2) | clean | 0 | 10998.6 | 371 / 9 484 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11000 (#3) | clean | 0 | 10998.6 | 371 / 9 487 | 609.6 / 610.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1, `--qd 63` | split, whole chunk, 1024 × 1 MB (1024 MB) | 256 | 11250 | underflows | 32 818 | 11249.3 | 371 / 9 473 | 567.2 / 566.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12000 | clean | 0 | 12000.5 | 284 / 4 856 | 418.0 / 476.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12000 (#2) | clean | 0 | 12000.5 | 288 / 4 860 | 416.6 / 478.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12000 (#3) | clean | 0 | 12000.5 | 282 / 4 852 | 421.3 / 473.5 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12250 | clean | 0 | 12250.3 | 283 / 4 860 | 388.7 / 433.1 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12250 (#2) | clean | 0 | 12250.3 | 291 / 4 853 | 384.6 / 437.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12250 (#3) | clean | 0 | 12250.3 | 291 / 4 877 | 384.7 / 437.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12500 | clean | 0 | 12499.9 | 292 / 4 862 | 353.7 / 397.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12500 (#2) | clean | 0 | 12499.9 | 290 / 4 861 | 353.8 / 397.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12500 (#3) | clean | 0 | 12499.9 | 291 / 4 860 | 353.6 / 398.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12750 | clean | 0 | 12748.5 | 290 / 4 857 | 321.3 / 363.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12750 (#2) | clean | 0 | 12748.5 | 291 / 4 864 | 321.1 / 363.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 12750 (#3) | clean | 0 | 12748.5 | 294 / 4 858 | 320.9 / 363.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13000 | clean | 0 | 12999.3 | 294 / 4 851 | 289.9 / 329.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13000 (#2) | clean | 0 | 12999.3 | 294 / 4 847 | 289.7 / 329.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13000 (#3) | clean | 0 | 12999.3 | 294 / 4 860 | 290.8 / 328.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13250 | clean | 0 | 13247.9 | 295 / 4 845 | 266.4 / 290.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13250 (#2) | clean | 0 | 13247.9 | 294 / 4 850 | 261.4 / 295.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13250 (#3) | clean | 0 | 13247.9 | 294 / 4 852 | 261.2 / 295.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13500 | clean | 0 | 13497.7 | 298 / 4 854 | 236.4 / 260.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13500 (#2) | clean | 0 | 13497.7 | 295 / 4 851 | 236.4 / 260.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13500 (#3) | clean | 0 | 13497.7 | 298 / 4 848 | 236.1 / 261.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13750 | clean | 0 | 13748.3 | 296 / 4 844 | 213.0 / 226.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13750 (#2) | clean | 0 | 13748.3 | 296 / 4 857 | 212.7 / 226.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 13750 (#3) | clean | 0 | 13748.3 | 304 / 4 842 | 212.5 / 226.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 | clean | 0 | 13999.2 | 2875 / 4 913 | 182.2 / 201.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 (#2) | clean | 0 | 13999.2 | 3370 / 4 918 | 188.2 / 195.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 (#3) | clean | 0 | 13999.2 | 3238 / 4 895 | 187.2 / 196.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14250 | clean | 0 | 14250.1 | 3884 / 4 998 | 158.3 / 171.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14250 (#2) | clean | 0 | 14250.1 | 2769 / 4 974 | 155.3 / 174.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14250 (#3) | clean | 0 | 14250.1 | 3823 / 4 953 | 162.9 / 166.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14500 | underflows | 8 656 326 | 14316.6 | 4635 / 4 904 | 92.8 / 93.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 (#4) | clean | 0 | 13999.2 | 2878 / 5 049 | 183.2 / 200.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 15000 | underflows | 31 766 737 | 14321.3 | 3401 / 5 126 | 36.9 / 31.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 256 | 16000 | underflows | 79 244 621 | 14311.8 | 4139 / 4 905 | 5.2 / 0.2 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 128 | 12500 | clean | 0 | 12499.9 | 2911 / 5 714 | 351.8 / 399.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 128 | 12500 (#2) | clean | 0 | 12499.9 | 2890 / 5 653 | 353.0 / 398.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 128 | 12500 (#3) | underflows | 1 133 104 | 12478.1 | 2884 / 5 695 | 339.9 / 386.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 128 | 12750 | underflows | 14 305 381 | 12485.4 | 2947 / 5 693 | 237.2 / 267.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 128 | 13000 | underflows | 25 911 420 | 12518.1 | 2940 / 5 822 | 178.8 / 200.5 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 4 KB, 1024 × 1 MB (1024 MB) | 128 | 13250 | underflows | 40 763 558 | 12492.6 | 3106 / 5 726 | 141.9 / 152.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13250 | clean | 0 | 13247.9 | 293 / 4 858 | 237.1 / 320.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13250 (#2) | clean | 0 | 13247.9 | 294 / 4 851 | 236.8 / 320.3 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13250 (#3) | clean | 0 | 13247.9 | 293 / 4 847 | 236.7 / 320.4 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13500 | clean | 0 | 13497.7 | 294 / 4 845 | 209.3 / 287.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13500 (#2) | clean | 0 | 13497.7 | 294 / 4 846 | 209.2 / 287.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13500 (#3) | clean | 0 | 13497.7 | 295 / 4 852 | 209.4 / 287.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13750 | clean | 0 | 13748.3 | 302 / 4 851 | 193.3 / 245.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13750 (#2) | clean | 0 | 13748.3 | 295 / 4 854 | 193.7 / 245.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 13750 (#3) | clean | 0 | 13748.3 | 295 / 4 847 | 193.7 / 245.5 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 | clean | 0 | 13999.2 | 2166 / 4 902 | 164.7 / 218.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 (#2) | clean | 0 | 13999.2 | 2307 / 4 884 | 162.6 / 220.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14000 (#3) | clean | 0 | 13999.2 | 2250 / 4 875 | 164.5 / 219.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14250 | clean | 0 | 14250.1 | 3904 / 4 999 | 144.9 / 184.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14250 (#2) | clean | 0 | 14250.1 | 4146 / 5 070 | 144.7 / 185.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14250 (#3) | clean | 0 | 14250.1 | 3821 / 4 903 | 145.1 / 184.5 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 3 | split, 64 KB, 1024 × 1 MB (1024 MB) | 256 | 14500 | underflows | 8 407 703 | 14321.3 | 2940 / 4 956 | 98.6 / 104.6 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | single, 512 × 1 MB (512 MB) | 256 | 8250 | clean | 0 | 8250.0 | 213 / 4 863 | 2355.5 / 0.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | single, 512 × 1 MB (512 MB) | 256 | 8250 (#2) | clean | 0 | 8250.0 | 213 / 4 855 | 2355.6 / 0.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | single, 512 × 1 MB (512 MB) | 256 | 8250 (#3) | clean | 0 | 8250.0 | 213 / 4 855 | 2355.5 / 0.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | single, 512 × 1 MB (512 MB) | 256 | 8500 | underflows | 27 435 | 8499.8 | 210 / 4 855 | 2278.3 / 0.0 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8250 | clean | 0 | 8250.0 | 209 / 4 843 | 0.0 / 2440.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8250 (#2) | clean | 0 | 8250.0 | 209 / 4 846 | 0.0 / 2440.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8250 (#3) | clean | 0 | 8250.0 | 209 / 4 844 | 0.0 / 2440.9 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8500 | clean | 0 | 8499.8 | 208 / 4 844 | 0.0 / 2324.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8500 (#2) | clean | 0 | 8499.8 | 209 / 4 813 | 0.0 / 2324.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8500 (#3) | clean | 0 | 8499.8 | 209 / 4 850 | 0.0 / 2324.8 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8750 | clean | 0 | 8749.2 | 209 / 4 849 | 0.0 / 2208.7 | release image |
| `vck190_fmcp1` | 2x WD_BLACK SN8100 HS 1000GB | RAID0, source 1 | mem1, 512 × 1 MB (512 MB) | 256 | 8750 (#2) | underflows | 2 078 | 8749.2 | 209 / 4 850 | 0.0 / 2208.8 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 6500 | clean | 0 | 6499.6 | 235 / 4 817 | 2542.6 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 6500 (#2) | clean | 0 | 6499.6 | 234 / 4 817 | 2543.1 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 6500 (#3) | clean | 0 | 6499.6 | 234 / 4 818 | 2542.1 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 6750 | clean | 0 | 6749.9 | 235 / 4 820 | 2530.0 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 6750 (#2) | clean | 0 | 6749.9 | 241 / 4 815 | 2538.6 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 6750 (#3) | clean | 0 | 6749.9 | 233 / 4 820 | 2527.0 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 7000 | clean | 0 | 6999.6 | 240 / 4 818 | 2542.5 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 7000 (#2) | clean | 0 | 6999.6 | 240 / 4 819 | 2527.5 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 7000 (#3) | clean | 0 | 6999.6 | 254 / 4 819 | 2528.7 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 7000 (#4) | clean | 0 | 6999.6 | 239 / 4 816 | 2524.7 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 7250 | underflows | 8 789 074 | 7155.9 | 4687 / 5 028 | 2034.4 / 0.0 | release image |
| `vck190_fmcp1` | WD_BLACK SN8100 HS 1000GB | single (SSD1) | single, 512 × 1 MB (512 MB) | 256 | 8000 | underflows | 79 343 956 | 7153.5 | 4733 / 4 977 | 1441.3 / 0.0 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 5750 | clean | 0 | 5749.9 | 277 / 8 137 | 1643.8 / 453.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 5750 (#2) | clean | 0 | 5749.9 | 278 / 8 277 | 1643.9 / 453.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 5750 (#3) | clean | 0 | 5749.9 | 277 / 8 428 | 1643.8 / 453.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6000 | underflows | 247 | 5999.9 | 279 / 8 871 | 1645.5 / 143.5 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6000 (#2) | underflows | 174 | 5999.9 | 274 / 8 710 | 1645.7 / 143.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6000 (#3) | clean | 0 | 5999.9 | 279 / 8 400 | 1645.7 / 143.4 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6000 (#4) | underflows | 53 834 | 5999.7 | 279 / 10 101 | 1646.9 / 142.5 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6000 (#5) | underflows | 475 | 5999.9 | 278 / 10 022 | 1645.5 / 143.5 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6000 (#6) | clean | 0 | 5999.9 | 277 / 9 414 | 1645.7 / 143.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6250 | underflows | 16 124 816 | 6175.7 | 280 / 8 614 | 1585.3 / 0.0 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6250 (#2) | underflows | 17 326 229 | 6170.2 | 279 / 8 411 | 1591.4 / 0.0 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 6250 (#3) | underflows | 17 347 767 | 6170.1 | 276 / 8 820 | 1591.5 / 0.0 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 5750 (#4) | clean | 0 | 5749.9 | 278 / 8 010 | 1643.9 / 453.2 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 5750 (#5) | clean | 0 | 5749.9 | 279 / 8 689 | 1643.9 / 453.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 2 | split, whole chunk, 2048 × 512 KB (1024 MB) | 256 | 5750 (#6) | clean | 0 | 5749.9 | 278 / 8 819 | 1643.7 / 453.5 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5250 | clean | 0 | 5249.9 | 297 / 10 386 | 1664.0 / 1096.9 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5250 (#2) | clean | 0 | 5249.9 | 301 / 10 576 | 1663.8 / 1097.1 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5250 (#3) | clean | 0 | 5249.9 | 295 / 10 480 | 1664.0 / 1096.9 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5500 | underflows | 6 667 086 | 5472.7 | 3406 / 12 034 | 1676.3 / 760.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5500 (#2) | underflows | 6 616 628 | 5472.9 | 3397 / 11 939 | 1677.3 / 759.6 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5500 (#3) | underflows | 6 603 169 | 5473.0 | 3393 / 12 033 | 1676.4 / 760.8 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5750 | underflows | 61 868 510 | 5496.5 | 3365 / 11 642 | 1677.2 / 413.4 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5750 (#2) | underflows | 61 814 226 | 5496.8 | 3359 / 11 890 | 1677.7 / 412.6 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5750 (#3) | underflows | 61 717 794 | 5497.1 | 3364 / 11 479 | 1676.0 / 414.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1, `--qd 63` | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5250 | clean | 0 | 5249.9 | 400 / 16 666 | 1651.7 / 1108.7 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1, `--qd 63` | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 5500 | underflows | 6 919 723 | 5471.7 | 6430 / 18 169 | 1674.5 / 762.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 5750 | underflows | 577 588 072 | 4020.0 | 5366 / 17 183 | 1718.3 / 190.2 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 5750 (#2) | underflows | 576 122 765 | 4023.1 | 6988 / 18 205 | 1715.1 / 179.1 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 256 | 5750 (#3) | underflows | 576 168 867 | 4022.9 | 5608 / 17 137 | 1717.3 / 190.0 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 5250 | underflows | 516 206 007 | 3791.7 | 6280 / 18 415 | 2299.9 / 253.0 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 5250 (#2) | underflows | 515 330 255 | 3793.4 | 6357 / 18 213 | 2299.9 / 254.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 5250 (#3) | underflows | 517 020 503 | 3790.0 | 6309 / 18 235 | 2294.8 / 254.8 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 5500 | underflows | 591 500 632 | 3817.5 | 7579 / 18 498 | 2028.7 / 187.4 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 5500 (#2) | underflows | 591 323 724 | 3817.9 | 7711 / 18 235 | 2024.0 / 187.3 | release image |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, source 1 | split, 4 KB, 2048 × 512 KB (1024 MB) | 128 | 5500 (#3) | underflows | 590 800 903 | 3818.9 | 6539 / 18 172 | 2021.8 / 192.8 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | split, whole chunk, 2048 × 512 KB (1024 MB) | 128 | 3000 | underflows | 1 458 514 159 | 1437.7 | 11961 / 26 648 | 2725.8 / 1030.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 2 | single, 1024 × 512 KB (512 MB) | 256 | 3000 | clean | 0 | 3000.0 | 225 / 8 011 | 5772.9 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 2 | single, 1024 × 512 KB (512 MB) | 256 | 3500 | clean | 0 | 3500.0 | 233 / 8 569 | 5767.7 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | single, 1024 × 512 KB (512 MB) | 128 | 3000 | clean | 0 | 3000.0 | 238 / 9 202 | 5776.2 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | single, 1024 × 512 KB (512 MB) | 128 | 3000 (#2) | clean | 0 | 3000.0 | 238 / 11 103 | 5782.5 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | single, 1024 × 512 KB (512 MB) | 128 | 3000 (#3) | clean | 0 | 3000.0 | 238 / 9 746 | 5785.7 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | single, 1024 × 512 KB (512 MB) | 128 | 3250 | underflows | 8 997 619 | 3228.3 | 5248 / 9 250 | 5832.9 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | single, 1024 × 512 KB (512 MB) | 128 | 3250 (#2) | underflows | 8 971 352 | 3228.4 | 5248 / 9 229 | 5832.0 / 0.0 | release image |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single (SSD1), source 1 | single, 1024 × 512 KB (512 MB) | 128 | 3250 (#3) | underflows | 8 997 260 | 3228.3 | 5248 / 9 167 | 5833.9 / 0.0 | release image |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 3 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5250 | clean | 0 | 5250.0 | 226 / 3 406 | 1650.6 / 1105.5 | release image |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 5750 | clean | 0 | 5749.8 | 215 / 3 015 | 1648.9 / 448.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 5750 (#2) | clean | 0 | 5749.8 | 215 / 3 130 | 1648.9 / 448.5 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 5750 (#3) | clean | 0 | 5749.9 | 215 / 3 059 | 1648.9 / 448.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 6000 | clean | 0 | 5999.9 | 219 / 2 968 | 1652.0 / 137.1 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 6000 (#2) | clean | 0 | 5999.9 | 216 / 3 137 | 1651.9 / 137.1 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 6000 (#3) | clean | 0 | 5999.9 | 219 / 3 053 | 1652.0 / 137.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 6250 | underflows | 12 453 | 6249.8 | 232 / 3 074 | 1502.8 / 0.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 6250 (#2) | clean | 0 | 6249.9 | 232 / 3 127 | 1502.7 / 0.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 256 | 6250 (#3) | clean | 0 | 6249.9 | 232 / 2 947 | 1502.7 / 0.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5500 | underflows | 183 159 | 5499.2 | 1665 / 4 265 | 1659.1 / 778.7 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5500 (#2) | underflows | 222 575 | 5499.0 | 1665 / 4 136 | 1659.0 / 778.8 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5500 (#3) | underflows | 169 256 | 5499.3 | 1666 / 4 197 | 1659.2 / 778.8 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5750 | underflows | 53 859 893 | 5528.1 | 1665 / 4 134 | 1637.5 / 393.6 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5750 (#2) | underflows | 53 677 911 | 5528.8 | 1665 / 4 195 | 1637.6 / 393.5 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5750 (#3) | underflows | 53 682 703 | 5528.7 | 1664 / 4 105 | 1637.0 / 392.1 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 6000 | underflows | 106 284 109 | 5559.6 | 1658 / 4 165 | 1597.8 / 102.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 2 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5250 | clean | 0 | 5249.9 | 512 / 16 792 | 1656.4 / 1099.9 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 2 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5250 (#2) | clean | 0 | 5249.9 | 407 / 16 462 | 1655.6 / 1100.6 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 2 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5250 (#3) | clean | 0 | 5249.9 | 226 / 3 455 | 1655.0 / 1101.2 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 2 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5500 | underflows | 5 499 077 | 5477.5 | 1678 / 18 882 | 1661.6 / 769.6 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 2 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5500 (#2) | underflows | 5 138 097 | 5478.9 | 1678 / 18 584 | 1660.8 / 767.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 2 | split, whole chunk, 4096 × 256 KB (1024 MB) | 128 | 5500 (#3) | underflows | 6 189 404 | 5474.7 | 1675 / 19 136 | 1661.4 / 769.3 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 5250 | clean | 0 | 5249.9 | 290 / 3 736 | 1989.5 / 791.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 5250 (#2) | clean | 0 | 5249.9 | 288 / 3 816 | 1990.5 / 790.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 5250 (#3) | clean | 0 | 5249.9 | 290 / 3 685 | 1989.2 / 791.7 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 5500 | underflows | 20 021 590 | 5419.1 | 2158 / 4 215 | 1717.2 / 677.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 5500 (#2) | underflows | 20 530 447 | 5417.1 | 2061 / 4 162 | 1720.9 / 670.4 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | split, 4 KB, 4096 × 256 KB (1024 MB) | 128 | 5500 (#3) | underflows | 19 665 762 | 5420.5 | 2951 / 4 307 | 1731.7 / 663.3 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | single, 2048 × 256 KB (512 MB) | 128 | 4250 | clean | 0 | 4249.9 | 191 / 3 291 | 4736.6 / 0.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | single, 2048 × 256 KB (512 MB) | 128 | 4250 (#2) | clean | 0 | 4249.9 | 191 / 3 366 | 4736.6 / 0.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | single, 2048 × 256 KB (512 MB) | 128 | 4500 | clean | 0 | 4499.9 | 192 / 3 225 | 4175.1 / 0.0 | final |
| `zcu106_hpc0` | 2x Sabrent SB-2130-1TB | RAID0, source 1 | single, 2048 × 256 KB (512 MB) | 128 | 4500 (#2) | clean | 0 | 4499.9 | 192 / 3 125 | 4175.1 / 0.0 | final |

* **`vck190_fmcp1`, 980 PRO RAID0: 11 000 MB/s** sustained with the image defaults
  (whole-chunk stripes, MaxPayload 256): 3 of 3 with no underflow on the release image, and in
  the measurement session 3 of 3 on the second recording and in the second set of three on the
  first; the one run in nine that failed was short of data for 12 µs in all (3026 ticks). The SSDs' commands complete in 0.20 ms on average at every rate, and the ring
  reader waits for each memory 13-16 % of the run, so the limit is on the reader and memory
  side, not in the SSDs (see [Ceilings at a glance](#versal-vck190_fmcp1): the memory being
  read also takes one SSD's writes, as the SN8100 pair confirms). **Near the top the failures are short and intermittent**: 11 250-11 750 MB/s
  are clean in some runs and short of data for 12 µs to 2.4 ms in all in others; only at
  12 000 MB/s is there a steady shortfall (11.84 GB/s delivered). `--qd 63` does not change
  it (11 000 MB/s: 3739 ticks in its one run). With 4 KB stripes the pair plays 10 500 MB/s,
  with command latencies of 1.7-1.85 ms.
* **`vck190_fmcp1`, SN8100 RAID0: 11 000 MB/s** sustained with the image defaults
  (whole-chunk stripes, MaxPayload 256): 3 of 3 on the first and the second recording (the
  second clean up to 11 500 MB/s), 2 of 3 on the third, whose failing run was short of data for
  0.19 µs in all (47 ticks); 10 750 MB/s is 3 of 3 on both recordings it was played from. As
  with the 980 PRO pair, the SSDs answer in 0.27 ms on average at every rate and the limit is
  the memory being read: at sinks of 12 000, 13 000 and 14 000 MB/s the stream delivers 11.90,
  11.93 and 11.95 GB/s, and at 11 000 MB/s the reader waits about 610 ms of the 3.9 s run for
  each memory. At MaxPayload 128: 10 750 MB/s (11 000 MB/s 1 of 2); `--qd 63`: 11 000 MB/s
  (11 250 MB/s 0 of 1).
* **With `--stripe 4` the SN8100 pair plays back 14 250 MB/s** sustained (3 of 3, clean at
  every step from 10 250 MB/s over two recordings), its drives' Gen4 x4 read rate: at
  14 500 MB/s and with 15 000 and 16 000 MB/s sinks the stream holds a steady 14.31-14.32 GB/s,
  2 × 7.16 GB/s, what one drive reads alone. The command latency stays at 0.27-0.30 ms up to
  13 750 MB/s and rises to 2.8-3.9 ms at 14 000-14 250 MB/s, where the drives are saturated;
  13 750 MB/s leaves a margin. 64 KB stripes give the same 14 250 MB/s. At MaxPayload 128 the
  4 KB layout streams 12.49-12.52 GB/s, and 12 500 MB/s was clean in 2 of 3 runs (no lower
  rate was run). On one memory: 8250 MB/s with `--ring single` (DDR4), 8500 MB/s with
  `--ring mem1` (LPDDR4).
* **`vck190_fmcp1`, one SN8100: 7000 MB/s** sustained on the single ring (7250 MB/s streams
  7.16 GB/s, its Gen4 x4 link); 7250 MB/s for a 10 GiB file with the help of the ring.
* **`vck190_fmcp1`, one 980 PRO: 6250 MB/s** sustained on the single ring at MaxPayload 128:
  its Gen4 x4 link (6.5 GB/s delivered at 6750 MB/s). On a 4 KB-striped split ring it plays only
  5750 MB/s, which is why one SSD stays on the single ring.
* **`vck190_fmcp1`, Sabrent RAID0: 9250 MB/s** sustained, 0 underflow ticks at every clean
  rate from 8000 MB/s on (the short underflows of Release 1.1 above 7500 MB/s are gone). The
  drives are the limit: their command latency rises from 0.23 ms at 8000 MB/s to 1.4-1.5 ms at
  9250 MB/s, and at 9500 MB/s the stream falls steadily to 9.27-9.29 GB/s (2 × ~4.63 GB/s
  read), with the ring reader waiting for each memory about 0.9 s of the 4.6 s run. MaxPayload
  128 or 256 and whole-chunk or 4 KB stripes give the same 9250 MB/s.
* **`vck190_fmcp1`, one Sabrent: 4500 MB/s** sustained (4750 MB/s streams 4.59 GB/s); on the
  split ring (`--ring split`, one run) it played 4500 MB/s as well.
* **`zcu106_hpc0`, Sabrent RAID0: 6000 MB/s** sustained at MaxPayload 256, the default: the
  drives answer in 0.22 ms, and the split ring's chunk alternation is the limit (6250 MB/s
  clean in 2 of 3 runs). At MaxPayload 128 the pair plays back **5250 MB/s**, with whole-chunk
  or 4 KB stripes alike: the drives answer in 1.67 ms at 5500 MB/s, every command queue full,
  and deliver 5.47-5.50 GB/s. The ring reader waits mostly for memory 0 (PS DDR) at every rate.
* **`zcu106_hpc0`, one Sabrent: 3000 MB/s** sustained at MaxPayload 128, its Gen3 x4 link (~3.19 GB/s); 3250 MB/s
  for a 10 GiB file with the help of the ring. On the split ring it would play ~13 % slower.
* **`zcu106_hpc0`, 980 PRO RAID0: 5750 MB/s** sustained at MaxPayload 256, the default (read
  latency 0.28 ms): 6000 MB/s is clean in 2 of 6 runs, the others short of data for 0.7 µs to
  0.2 ms; at 6250 MB/s the stream falls steadily to 6.17 GB/s while the reader waits 1.59 s per
  run for memory 0 (HP2) and not at all for memory 1: the HP2 side limits. At MaxPayload 128
  the pair plays back **5250 MB/s**, as the Sabrent pair: at 5500 MB/s the same 6.6 M underflow
  ticks in every run, a steady 5.47 GB/s, with every queue full (3.4 ms read latency) and the
  reader waiting mostly for memory 0 (1.68 s against 0.76 s per run); `--qd 63` does not lift
  it (5500 MB/s fails as at 32). **With 4 KB stripes the pair collapses** to ~3.8 GB/s
  (5250 MB/s at MaxPayload 128: 516 M underflow ticks, 6.3 ms read latency; 5750 MB/s at 256:
  4.02 GB/s): whole-chunk stripes are essential with 512 KB chunks (see
  [Stripe](#stripe-whole-chunk-4-kb-or-64-kb)).
* **`zcu106_hpc0`, one 980 PRO: 3500 MB/s** sustained at MaxPayload 256 (one run), as Release
  1.1 measured at 256 bytes; 3000 MB/s at 128 bytes, its Gen3 x4 link (~3.23 GB/s). **On the split ring it plays only ~1.44 GB/s** (`--ring split`: 3000 MB/s over 40 GiB took 29.9 s,
  read latency 12 ms): one SSD must stay on the single ring, as the default does.
* A 10 GiB file is about 10 % covered by the prefilled 1 GB ring; the 40 GiB figure is the
  sustained one. The data was intact in every playback (0 checker errors, 0 gaps, 0 NVMe
  errors).

### Stripe: whole chunk, 4 KB or 64 KB

A split ring is cut into stripes of 4 KB up to one chunk that alternate between the two
memories (register `RING_STRIPE_SHIFT`; `--stripe` in the apps, the driver's module parameter
`stripe_kb`, the device tree's `opsero,ring-stripe-chunk` or `opsero,ring-stripe-kb`). **The
default is the whole chunk on both boards**: whole chunks alternate, and each SSD of a RAID0
pair then writes and reads one memory only (see
[Kernel driver](driver.md#split-ring-one-ring-in-two-memories)). With 4 KB stripes every
4 KB burst changes memory, so each SSD's commands span both memories.

| measurement (`vck190_fmcp1`, 2x 980 PRO) | whole chunk (default) | 4 KB | 64 KB |
|---|---|---|---|
| RAID0 playback, 40 GiB, MaxPayload 256 (the default) | **11 000 MB/s** (3 of 3 on the release image; 8 of 9 in the measurement session) | 10 500 MB/s (10 750 MB/s 0 of 2) | 10 500 MB/s (earlier build) |
| RAID0 playback, 40 GiB, MaxPayload 128 | **10 750 MB/s** | 10 250 MB/s (earlier build) | 10 250 MB/s (earlier build) |
| SSD command latency during the playback, average | 0.20 ms | 1.7-1.85 ms | 1.9 ms (earlier build) |
| RAID0 recording, 32 GB | 10 000 MB/s | 10 000 MB/s (earlier build) | 10 000 MB/s (earlier build) |
| fabric only: recording / ring-resident playback | 14 750 (earlier build) / 15 000 MB/s | **15 750 / 16 000 MB/s** | 15 000 / 14 250 MB/s (earlier build) |

| measurement (`vck190_fmcp1`, 2x Sabrent) | whole chunk (default) | 4 KB |
|---|---|---|
| RAID0 playback, 40 GiB, MaxPayload 256, at 9250 MB/s | clean 3 of 3 (6 of 6) | clean 3 of 3 |
| SSD command latency at 9250 MB/s, average | 1.38-1.51 ms | 1.44-1.53 ms |

| measurement (`vck190_fmcp1`, 2x WD_BLACK SN8100) | whole chunk (default) | 4 KB | 64 KB |
|---|---|---|---|
| RAID0 playback, 40 GiB, MaxPayload 256 (the default) | 11 000 MB/s (8 of 9 runs clean on three recordings; 10 750 MB/s 3 of 3) | **14 250 MB/s** (3 of 3; 14 500 MB/s 0 of 1, 14.32 GB/s streamed) | 14 250 MB/s (3 of 3; 14 500 MB/s 0 of 1) |
| RAID0 playback, 40 GiB, MaxPayload 128 | 10 750 MB/s (11 000 MB/s 1 of 2) | about 12 500 MB/s (2 of 3; 12.49-12.52 GB/s streamed at 12 750-13 250 MB/s; no lower rate run) | - |
| SSD command latency during the playback, average | 0.27 ms | 0.27-0.30 ms up to 13 750 MB/s (2.8-3.9 ms at 14 000-14 250 MB/s) | 0.29-0.30 ms up to 13 750 MB/s |
| RAID0 recording, 32 GB | 13 750 MB/s | 13 750 MB/s | - |

| measurement (`zcu106_hpc0`, 2x Sabrent) | whole chunk (default) | 4 KB | 64 KB |
|---|---|---|---|
| RAID0 playback, 40 GiB, MaxPayload 256 (the default) | **6000 MB/s** (6250 MB/s 2 of 3) | 6000 MB/s (earlier build; 6250 MB/s 0 of 3) | 5500 MB/s (earlier build) |
| RAID0 playback, 40 GiB, MaxPayload 128 | **5250 MB/s** (5500 MB/s 0 of 6) | 5250 MB/s (5500 MB/s 0 of 3) | 5250 MB/s (earlier build) |
| RAID0 recording, 32 GB, MaxPayload 256 (the default) | **6000 MB/s** (earlier build) | 5500 MB/s (earlier build) | 5250 MB/s 2 of 3 (earlier build) |
| RAID0 recording, 32 GB, MaxPayload 128 | 5250 MB/s | 5250 MB/s (earlier build) | 5250 MB/s (earlier build) |
| ring high-water at 5250 MB/s (MaxPayload 128), of 4096 slots | 806-1840 | 2084-3289 | 1642-1950 |
| fabric only: recording / ring-resident playback | 6000 / 6250 MB/s | **7000 / 6750 MB/s** (earlier build) | 6250 / 6000 MB/s (earlier build) |

| measurement (`zcu106_hpc0`, 2x 980 PRO) | whole chunk (default) | 4 KB |
|---|---|---|
| RAID0 playback, 40 GiB, MaxPayload 256 (the default) | **5750 MB/s** (3 of 3) | **~4.0 GB/s**: 5750 MB/s 0 of 3 (4.02 GB/s streamed) |
| RAID0 playback, 40 GiB, MaxPayload 128 | **5250 MB/s** (3 of 3) | **~3.8 GB/s**: 5250 MB/s 0 of 3 (516 M underflow ticks, 3.79 GB/s streamed), 5500 MB/s 3.82 GB/s |
| SSD read latency at 5250 MB/s (MaxPayload 128), average | 0.30 ms | 6.3 ms |

**Why whole chunks by default.** With the SSDs in the loop, keeping each NVMe command in one
memory wins with the 980 PRO and Sabrent pairs, and with 512 KB chunks it is essential; the
SN8100 pair on `vck190_fmcp1` is the exception:

* On `vck190_fmcp1` the NoC orders each Root Port's writes strictly, so a 980 PRO whose
  512 KB command alternates between DDR4 and LPDDR4 every 4 KB (or 64 KB) pays a round trip at
  every switch: its commands take 1.7-1.9 ms instead of 0.2 ms and the pair plays back
  500 MB/s less, at either MaxPayload. The Sabrent pair, whose drives read more slowly than
  either layout takes them, plays back 9250 MB/s with both.
* On `zcu106_hpc0` an SSD's writes that alternate between its PS port and the PL DDR4 path cost
  as well, and **with 512 KB chunks 4 KB stripes collapse the playback**: the 980 PRO pair
  plays only ~3.8 GB/s (read latency 6.3 ms, each 512 KB command switching memory 128 times),
  at MaxPayload 128 and 256 alike. With the Sabrents' 256 KB chunks 4 KB ties with whole chunks
  in playback but records 500 MB/s less at MaxPayload 256 and needs up to twice the ring;
  64 KB stripes are the worst layout in every Sabrent test.
* **With two WD_BLACK SN8100 on `vck190_fmcp1`, play back with `--stripe 4`**: 14 250 MB/s
  sustained against 11 000 MB/s with whole chunks; recording is the same with either stripe
  (13 750 MB/s, the drives' links). With whole chunks the reader drains one memory at a time at
  the full stream rate while that memory also takes one SSD's writes, and the stream stops at
  ~11.9 GB/s, the mixed limit of one memory (~18 GB/s; see
  [Ceilings at a glance](#versal-vck190_fmcp1)). 4 KB stripes put half of the reads and half of
  the writes on each memory, so the limit moves to the drives: 14.32 GB/s, 2 × 7.16 GB/s.
  **It helps this pair and not the 980 PRO pair because of the write ordering**: a 980 PRO's
  commands into a 4 KB-striped ring take 1.7-1.85 ms instead of 0.20 ms (every switch of memory
  inside a command costs a round trip on the NoC), and the pair falls to 10 500 MB/s; the
  SN8100's 1 MB commands complete in 0.27-0.30 ms with either stripe up to 13 750 MB/s, so the
  balance of the memories wins. Why the SN8100 does not pay the ordering penalty was not
  isolated. The image default stays the whole chunk; pass `--stripe 4` to `nvrec` and `nvplay`
  (or `stripe_kb=4` to the driver) for this pair.
* **4 KB stripes win without the SSDs**: they overlap the two memories best (the fabric
  reaches 16 000 MB/s on `vck190_fmcp1` and 7000 MB/s on `zcu106_hpc0`). With the SSDs only the
  SN8100 pair gains from them. Do not change the stripe for a recording or a playback without
  measuring it with your drives.
* **Caveat**: near its top a whole-chunk layout fails by short, intermittent underflows, not by
  a steady shortfall (on `vck190_fmcp1` 11 000 MB/s was clean with the 980 PRO pair in 3 of 3
  runs on the release image and in 8 of 9 in the measurement session, where the ninth was short
  of data for 12 µs, and with the SN8100 pair in 8 of 9 runs on three recordings, the ninth
  short of data for 0.19 µs). Allow a margin below the published rate, or confirm your rate over
  several long runs.

### MaxPayload 256

PCIe **MaxPayload** is the largest payload a PCIe packet carries; a Root Port and its SSD must
use the same value. Linux programs 128 bytes at boot. `nvrec-mps` (see
[Apps](apps.md#nvrec-mps)) shows and sets it on the SSDs the design's driver owns and on their
Root Ports, with `setpci` (the Root Ports first when raising it, MaxReadReq left at 512 bytes);
it refuses to change anything while a recording or playback runs:

```
sudo nvrec-mps status      # per SSD and Root Port: MaxPayload in force, the largest supported, MaxReadReq
sudo nvrec-mps 128         # until the next boot; sudo nvrec-mps 256 goes back
```

`nvrec-mps status` needs root to read the configuration space; without it, it prints
`MaxPayload ?`. **Both split-ring boards boot with 256 bytes; `uzev` keeps the kernel's 128.**

* On `vck190_fmcp1` and `zcu106_hpc0` `nvrec-pcie-mps.service` reads `NVREC_MPS=256` from
  `/etc/default/nvrec-mps` and sets it once the driver has claimed the SSDs; the kernel log
  shows it (`dmesg | grep nvrec-mps`, here on `vck190_fmcp1`):

  ```none
  nvrec-mps: NVREC_MPS 256 (/etc/default/nvrec-mps): setting it on the nvrec SSDs and their root ports
  nvrec-mps: root port 0000:00:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
  nvrec-mps: SSD       0000:01:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
  nvrec-mps: root port 0001:00:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
  nvrec-mps: SSD       0001:01:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
  ```

  and `sudo nvrec-mps status` lists 256 on both Root Ports (which support 1024) and both SSDs
  (the 980 PRO supports 256, the Sabrent and the SN8100 512).
* Every figure of `vck190_fmcp1` on this page is at 256 bytes unless a row says MaxPayload 128.
  On `zcu106_hpc0` most runs were made at 128 bytes and the runs at 256 bytes as the A/B; every
  `zcu106_hpc0` figure says which. With the split ring 256 bytes helps both pairs there (below),
  clean 3 of 3 at 5750 MB/s with both, without any error, which is why the image sets it.
  Release 1.1 had found the opposite for the 980 PRO RAID0 playback on its single ring, where
  the SSDs' writes and the ring reader shared one DDR controller; with the split ring, where
  each SSD writes its own memory, the same pair gains 500 MB/s at 256 bytes.
* **To change the value** for a session: `sudo nvrec-mps 128` (or 256). To make it permanent on
  a board, set `NVREC_MPS` in `/etc/default/nvrec-mps` (128 keeps the kernel's setting) and
  `sudo systemctl enable nvrec-pcie-mps.service`; in the image, set `NVREC_MPS` for the target
  (see [Yocto](yocto)). Every `RESULT` line carries the value in force (`mps=`), and so does
  every `nvbench-suite.sh` result.

| measurement | MaxPayload 128 | MaxPayload 256 (the default) |
|---|---|---|
| `vck190_fmcp1`, 980 PRO RAID0, 40 GiB playback, whole-chunk stripes | 10 750 MB/s (3 of 3; 11 000 MB/s 4 of 6) | **11 000 MB/s** (3 of 3 on the release image; 8 of 9 in the measurement session) |
| `vck190_fmcp1`, the same with 4 KB stripes | 10 250 MB/s (earlier build) | 10 500 MB/s (3 of 3; 10 750 MB/s 0 of 2) |
| `vck190_fmcp1`, the same on the single ring (`--ring single`) | 8250-8750 MB/s, 1-2 of 3 runs clean at each rate (earlier build) | **8750 MB/s** (3 of 3) |
| `vck190_fmcp1`, 980 PRO RAID0, 32 GB recording | 10 000 MB/s (4 KB stripes, earlier build) | 10 000 MB/s (whole chunk): no change for writes |
| `vck190_fmcp1`, Sabrent RAID0, 40 GiB playback, whole-chunk stripes | 9250 MB/s (3 of 3; 9500 MB/s 0 of 1, 9.29 GB/s) | 9250 MB/s (3 of 3; 9500 MB/s 0 of 1, 9.27 GB/s): no change, the drives' read rate |
| `vck190_fmcp1`, SN8100 RAID0, 40 GiB playback, whole-chunk stripes | 10 750 MB/s (3 of 3; 11 000 MB/s 1 of 2) | **11 000 MB/s** (8 of 9 runs clean on three recordings) |
| `vck190_fmcp1`, the same with 4 KB stripes | about 12 500 MB/s (2 of 3; 12.49-12.52 GB/s streamed) | **14 250 MB/s** (3 of 3) |
| `vck190_fmcp1`, SN8100 RAID0, 32 GB recording | 12 500 MB/s (3 of 3; 12 750 MB/s 0 of 3 writing 12.22 GB/s) | **13 750 MB/s** (3 of 3; 13.50 GB/s written at 14 000 MB/s): the links' TLP overhead, ratio 0.905 |
| `zcu106_hpc0`, Sabrent RAID0, 40 GiB playback, whole-chunk stripes | 5250 MB/s (3 of 3; 5500 MB/s 0 of 6), read latency 1.67 ms at 5500 MB/s | **6000 MB/s** (3 of 3; 6250 MB/s 2 of 3), read latency 0.22 ms |
| `zcu106_hpc0`, the same with 4 KB stripes | 5250 MB/s (3 of 3; 5500 MB/s 0 of 3) | 6000 MB/s (earlier build) |
| `zcu106_hpc0`, Sabrent RAID0, 32 GB recording | 5250 MB/s (every stripe) | **6000 MB/s** with whole-chunk stripes (3 of 3, and a 40 GiB recording), 5500 MB/s with 4 KB stripes (earlier build) |
| `zcu106_hpc0`, 980 PRO RAID0, 40 GiB playback, whole-chunk stripes | 5250 MB/s (3 of 3; 5500 MB/s 0 of 3, a steady 5.47 GB/s), read latency 3.4 ms at 5500 MB/s | **5750 MB/s** (3 of 3; 6000 MB/s 2 of 6; 6250 MB/s a steady 6.17 GB/s), read latency 0.28 ms |
| `zcu106_hpc0`, 980 PRO RAID0, 32 GB recording | 6000 MB/s (3 of 3; 6250 MB/s writes 6.02 GB/s) | 6000 MB/s (3 of 3; 6250 MB/s writes 6.21 GB/s with the ring nearly empty): the ring writer, not MaxPayload, sets the top |
| `zcu106_hpc0`, one 980 PRO, 32 GB recording | 3000 MB/s (3 of 3; 3250 MB/s writes 3.04 GB/s) | **3250 MB/s** (one run) |
| `zcu106_hpc0`, one 980 PRO, 40 GiB playback | 3000 MB/s (3 of 3; 3250 MB/s streams 3.23 GB/s) | **3500 MB/s** (one run) |

At 256 bytes each TLP carries twice the data for the same header, so the SSDs read and write
faster where their links were the limit: on `zcu106_hpc0` the RAID0 playback gains 500 MB/s with
the 980 PRO pair and 750 MB/s with the Sabrent pair, which also records 750 MB/s faster; on
`vck190_fmcp1` the 980 PRO pair gains 250 MB/s in playback (with whole-chunk stripes the drives
are not the limit there) and the Sabrent pair nothing (its drives' own read rate is the limit).
The SN8100 pair, whose Gen4 x4 links are its limit, gains most: it writes 13.50 instead of
12.22 GB/s and records 13 750 instead of 12 500 MB/s, and with 4 KB stripes it streams
14.32 instead of 12.49-12.52 GB/s.
**Neither board logged a PCIe (AER) or NVMe error, or any kernel message, at 256 bytes**, in
about 30 runs at 256 bytes on `zcu106_hpc0` with the two pairs and on every boot of
`vck190_fmcp1`; the tops at 256 bytes are clean 3 of 3 (on `vck190_fmcp1` with the 980 PRO
pair on the release image; 8 of 9 runs over three sets of three in the measurement session).
One 980 PRO on the Gen3 x4 slots of `zcu106_hpc0` records 3250 MB/s and plays back 3500 MB/s at
256 bytes, one 250 MB/s and one 500 MB/s step above 128 bytes: the single-drive figures that
Release 1.1 measured at 256 bytes. Whether it helps depends on the drives
and the ring layout, so measure it for your setup (`nvrec-mps 128` or `256`, and
`nvbench-suite.sh --tag <word>` to keep the runs apart).

### Commands in flight (qd 32 and 63)

`nvrec --qd` sets how many NVMe commands the hardware keeps in flight per SSD (1 … 63, default
32), `nvplay --qd` the same for reads:

| measurement | `--qd 32` (default) | `--qd 63` |
|---|---|---|
| `vck190_fmcp1`, 980 PRO RAID0 (512 KB commands), 32 GB recording, 4 KB stripes, MaxPayload 128 (earlier build) | 10 000 MB/s 3 of 3, 10 250 MB/s 0 of 3 (9.89-9.90 GB/s written); average latency 2.3-2.4 ms | 10 000 MB/s 3 of 3, 10 250 MB/s 0 of 3 (9.90 GB/s written); average latency 5.1-5.2 ms |
| `vck190_fmcp1`, 980 PRO RAID0, 40 GiB playback at 11 000 MB/s, whole-chunk stripes | 3 of 3 clean on the release image, 8 of 9 in the measurement session | 0 of 1 (3739 underflow ticks) |
| `vck190_fmcp1`, Sabrent RAID0 (256 KB commands), 32 GB recording at 8250 MB/s | 3 of 3, write latency maxima ~20 ms | 2 of 3 (the failing run writing 7.96 GB/s), write latency maxima 33-47 ms |
| `vck190_fmcp1`, SN8100 RAID0 (1 MB commands), 32 GB recording at 13 750 MB/s | 3 of 3, write latency average 3.1-4.3 ms, maxima 5.6-5.8 ms | 2 of 3 (the failing run writing 13.29 GB/s), average 5.9-7.9 ms, maxima 10.3-13.7 ms |
| `vck190_fmcp1`, SN8100 RAID0, 40 GiB playback at 11 000 MB/s, whole-chunk stripes | 3 of 3 (source 1, which the `--qd 63` runs played too) | 3 of 3 (11 250 MB/s 0 of 1) |
| `zcu106_hpc0`, Sabrent RAID0 (256 KB commands), 32 GB recording at 5500 MB/s, 64 KB stripes, MaxPayload 128 (earlier build) | 0 of 3 (5.25-5.33 GB/s written), average latency 2.2 ms | 0 of 1 (5.31 GB/s written), average latency 4.0 ms |
| `zcu106_hpc0`, 980 PRO RAID0, 40 GiB playback at 5250 / 5500 MB/s, MaxPayload 128 | 3 of 3 / 0 of 3 (6.6 M underflow ticks) | clean (1 run) / 0 of 1 (6.9 M ticks) |

With every pair, more commands in flight only add latency: `--qd 63` lifts no top, and with the
Sabrent and SN8100 pairs on `vck190_fmcp1` it costs a run at the recording top. **The default stays 32**; measure both values with your own
drives before changing it (see [Queue depth](apps.md#queue-depth---qd)).

### CPU load

The runs at the top rates (medians of 3 runs unless stated); method as described
[above](#cpu-load). The figures are the apps' fixed set-up time per run, the same on every
build and at either MaxPayload (the `zcu106_hpc0` runs were made at 128 bytes).

| target | transfer | SSD | layout | cores | total CPU % of all cores (usr / sys / irq / iowait) | busy, summed over the cores (% of one core) | process % of one core | MB/s per % core | runs |
|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | `nvrec`, 10 000 MB/s, 32 GB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, split ring | 2 | 0.74 / 2.94 / 0.11 / 5.68 | 8.2 | 2.34 (2.33-2.96) | 4 274 | 3 |
| `vck190_fmcp1` | `nvrec`, 3250 MB/s, 350 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, split ring | 2 | 1.39 / 0.60 / 0.00 / 0.46 | 4.0 | 0.15 | 21 667 | 1 |
| `vck190_fmcp1` | `nvplay`, 11 250 MB/s, 10 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, split ring | 2 | 0.84 / 5.72 / 0.00 / 1.06 | 13.1 | 6.31 | 1 783 | 2 |
| `vck190_fmcp1` | `nvrec`, 5000 MB/s, 32 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 0.56 / 1.19 / 0.00 / 0.42 | 3.5 | 1.26 (1.11-1.26) | 3 968 | 3 |
| `vck190_fmcp1` | `nvplay`, 6250 MB/s, 10 GiB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 2 | 0.26 / 2.83 / 0.00 / 0.77 | 6.2 | 3.72 | 1 680 | 3 |
| `vck190_fmcp1` | `nvrec`, 8250 MB/s, 32 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, split ring | 2 | 0.77 / 2.42 / 0.22 / 0.44 | 6.8 | 2.90 (2.48-2.92) | 2 845 | 3 |
| `vck190_fmcp1` | `nvrec`, 3250 MB/s, 350 GiB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, split ring | 2 | 0.92 / 0.49 / 0.00 / 0.07 | 2.8 | 0.22 | 14 773 | 1 |
| `vck190_fmcp1` | `nvrec`, 4000 MB/s, 32 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 2 | 0.23 / 0.85 / 0.00 / 0.17 | 2.2 | 1.25 (1.14-1.25) | 3 200 | 3 |
| `vck190_fmcp1` | `nvrec`, 13 750 MB/s, 32 GB | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring | 2 | 1.09 / 3.78 / 0.18 / 0.36 | 9.9 | 3.32 (3.27-3.75) | 4 140 | 3 |
| `vck190_fmcp1` | `nvrec`, 13 750 MB/s, 32 GB | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring, 4 KB stripes | 2 | 0.58 / 3.46 / 0.00 / 0.36 | 8.7 | 3.72 (2.93-3.73) | 3 700 | 3 |
| `vck190_fmcp1` | `nvrec`, 12 500 MB/s, 32 GB, MaxPayload 128 | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring | 2 | 0.66 / 3.31 / 0.14 / 0.17 | 8.3 | 3.03 (2.62-3.36) | 4 130 | 3 |
| `vck190_fmcp1` | `nvrec`, 3250 MB/s, 350 GiB | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring | 2 | 0.12 / 0.25 / 0.00 / 0.03 | 0.8 | 0.12 | 27 080 | 1 |
| `vck190_fmcp1` | `nvrec`, 13 500 MB/s, 350 GiB | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring | 2 | 0.07 / 0.42 / 0.04 / 0.07 | 1.1 | 0.46 | 29 350 | 1 |
| `vck190_fmcp1` | `nvplay`, 11 500 MB/s, 10 GiB | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring | 2 | 0.43 / 5.65 / 0.00 / 0.87 | 12.9 | 6.42 (6.42-6.42) | 1 790 | 3 |
| `vck190_fmcp1` | `nvplay`, 15 250 MB/s, 10 GiB | 2x WD_BLACK SN8100 HS 1000GB | RAID0, 1M chunk, split ring, 4 KB stripes | 2 | 1.60 / 7.45 / 0.00 / 1.07 | 18.2 | 8.14 (8.14-8.14) | 1 870 | 3 |
| `vck190_fmcp1` | `nvrec`, 6750 MB/s, 32 GB | WD_BLACK SN8100 HS 1000GB | single (SSD1), 1M chunk | 2 | 0.28 / 1.31 / 0.08 / 1.18 | 3.4 | 1.52 (1.39-1.53) | 4 440 | 3 |
| `vck190_fmcp1` | `nvplay`, 7250 MB/s, 10 GiB | WD_BLACK SN8100 HS 1000GB | single (SSD1), 1M chunk | 2 | 0.00 / 3.56 / 0.00 / 0.59 | 7.7 | 4.29 (4.27-4.29) | 1 690 | 3 |
| `zcu106_hpc0` | `nvrec`, 5250 MB/s, 32 GB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, split ring | 4 | - | 5.1-6.8 | 3.20 (3.01-3.21) | 1 641 | 9 |
| `zcu106_hpc0` | `nvrec`, 3250 MB/s, 350 GiB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, split ring | 4 | 0.49 / 0.25 / 0.0 / 0.02 | 2.95 | 0.34 | 9 559 | 1 |
| `zcu106_hpc0` | `nvplay`, 5250 MB/s, 10 GiB | 2x Sabrent SB-2130-1TB | RAID0, 256K chunk, split ring | 4 | - | 9-12 | 5.49 (5.46-5.53) | 956 | 9 |
| `zcu106_hpc0` | `nvrec`, 2750 MB/s, 32 GB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | - | 2.3-2.6 | 1.41 (1.41-1.42) | 1 950 | 3 |
| `zcu106_hpc0` | `nvplay`, 3250 MB/s, 10 GiB | Sabrent SB-2130-1TB | single (SSD1), 256K chunk | 4 | - | 5.7-9.6 | 3.61 (3.33-3.61) | 900 | 3 |
| `zcu106_hpc0` | `nvrec`, 6000 MB/s, 32 GB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, split ring | 4 | 0.41 / 1.56 / 0.08 / 0.29 | 8.1-8.6 | 2.99 (2.83-3.00) | 2 007 | 3 |
| `zcu106_hpc0` | `nvrec`, 3500 MB/s, 350 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, split ring | 4 | 0.03 / 0.15 / 0.0 / 0.03 | 0.71 | 0.26 | 13 462 | 1 |
| `zcu106_hpc0` | `nvplay`, 5250 MB/s, 10 GiB | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk, split ring | 4 | 0.21 / 2.06 / 0.0 / 0.21 | 8.6-11.5 | 5.53 (5.11-5.53) | 949 | 3 |
| `zcu106_hpc0` | `nvrec`, 3000 MB/s, 32 GB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 0.13 / 0.45 / 0.0 / 0.11 | 2.2-2.4 | 1.28 (1.20-1.28) | 2 344 | 3 |
| `zcu106_hpc0` | `nvplay`, 3000 MB/s, 10 GiB | Samsung 980 PRO 1TB | single (SSD1), 512K chunk | 4 | 0.13 / 1.27 / 0.0 / 0.13 | 4.6-5.8 | 3.35 (3.09-3.35) | 896 | 3 |

The process figures are a fixed 0.06-0.4 s of CPU time per run (ring and PRP lists, unmounting
and remounting the volume, the statistics), independent of the rate and of the ring layout:
0.06 s over the 1 s of a 10 GiB playback at 11 250 MB/s is 6.3 %, 0.17 s over the 2 minutes
of a 350 GiB recording 0.15 %. During the transfer the CPU does nothing for it.
"Busy, summed over the cores" also counts the benchmark host's SSH polls of the board and the
suite's temperature sampling. ("-": the split of the total CPU was not kept for these runs.)
`nvplay`'s CPU was not sampled with the Sabrent pair on `vck190_fmcp1` (its playbacks were direct
`nvplay` runs, not suite runs).

## The SLC cache

Most consumer SSDs write into a fast pseudo-SLC cache first and move the data to their TLC
flash later; once the cache is full, the write rate drops. A recorder writes at a constant rate
for as long as the recording lasts, so the rate after the cache is the one that counts. The
cache of an empty, trimmed 1 TB drive is larger than 32 GB, so the 32 GB sweep measures an
in-cache rate for these drives, and only the [long recordings](#long-recordings-past-the-slc-cache)
give the sustained one.

The cache sizes and rates of the 980 PRO and the Sabrent below were not measured with this
design: they are cited from
fpga-drive-recorder's [SLC cache](https://recorder.fpgadrive.com/en/latest/benchmarks.html#the-slc-cache)
measurements of the same drives (one sequential fio write, queue depth 8, 8 MB blocks,
`O_DIRECT`, on a fresh XFS after 60 s of idle time). The WD_BLACK SN8100 row was measured with
this design (the recorder did not measure that drive), each drive on its own: `nvrec --raw
/dev/nvrecXn1` writes 900 GB from LBA 0 in 1 MB commands, 32 in flight, through a 512 MB
single ring, with the generator at 8000 MB/s, above what a Gen4 x4 link takes, so that the
ring stays full and `nvrec`'s 1 s rate samples are the drive's own write rate. Before it the
drive is deallocated whole (`blkdiscard`) and left idle for 300 s. The cache sizes come from
the 1 s samples (±7 GB at 6.7 GB/s); GB = 10⁹ bytes.

| SSD | SLC cache, empty and trimmed drive | write rate inside the cache | write rate after the cache |
|---|---|---|---|
| Samsung 980 PRO 1TB | ~115-125 GB per drive; ~245 GB for a RAID0 pair | ~3.0 GB/s on a Gen3 x4 link (the link), ~4.94-4.98 GB/s on Gen4 x4 | ~1.77 GB/s (median 1765-1766 MB/s); a pair ~3.46-3.49 GB/s |
| Sabrent Rocket 2230 1TB (SB-2130-1TB) | ~66-75 GB per drive; ~140 GB for a RAID0 pair | ~2.9 GB/s on a Gen3 x4 link (the link), ~4.6 GB/s on Gen4 x4 | ~1.8 GB/s (median 1799-1806 MB/s); a pair ~3.6 GB/s |
| WD_BLACK SN8100 HS 1000GB | ~340 GB per drive; ~684 GB for a RAID0 pair (13 500 MB/s clean to 683.7 GB) | ~6.72-6.74 GB/s on a Gen4 x4 link (the link) | ~1.96-1.98 GB/s for the next 63-90 GB, then ~1.12-1.13 GB/s (a 3 s sawtooth, 0.63-1.72 GB/s); a pair ~3.9, then ~2.23 GB/s |

The SN8100 writes in three phases, measured on each drive of the pair (900 GB from an empty
drive):

| phase | SSD1 | SSD2 |
|---|---|---|
| 1: the SLC cache, at the Gen4 x4 link's rate | 0 to ~340 GB at 6736 MB/s (median of the 1 s samples) | 0 to ~340 GB at 6717 MB/s |
| 2: right after the cache, steady | ~340 to ~403 GB (~63 GB) at ~1960 MB/s | ~340 to ~430 GB (~90 GB) at ~1980 MB/s |
| 3: to the end of the 900 GB write, no further change | ~403 to 900 GB at ~1120 MB/s on average, a 3 s sawtooth between 630 and 1710 MB/s | ~430 to 900 GB at ~1130 MB/s, 640-1720 MB/s |
| the whole 900 GB | 1717 MB/s on average (524 s) | 1761 MB/s (511 s) |

A RAID0 pair writes ~3.9 GB/s in phase 2 and ~2.23 GB/s on average in phase 3. The 800 GiB
recordings (~430 GB per drive) end shortly after the first drive enters phase 3, and at
2000 MB/s, the rate that holds over them, the ring reaches ~82 % at that step: **a longer
recording, or fuller drives, need a lower rate**.

**The cache comes back within a minute of a deallocate.** After a write past the cache, both
drives were deallocated whole (`blkdiscard`) and left idle, then written as a RAID0 pair (raw
on the md array, 1M chunk, the generator at 14 000 MB/s, 760 GB; the 300 s point is the
800 GiB recording at 13 500 MB/s on a new exFAT volume):

| idle after the deallocate | written at full speed, pair (per drive) | then |
|---|---|---|
| 10 s | ~444 GB (~222 GB) | ~3960 MB/s (phase 2) |
| 60 s | ~673 GB (~336 GB: the whole cache) | ~3913 MB/s |
| 300 s | 683.7 GB (~342 GB) | ~3920 MB/s, then phase 3 from ~800 GB |
| 900 s | ~672 GB (~336 GB) | ~3920 MB/s |

The SN8100's cache is dynamic, and smaller on a fuller drive. The sizes above are for empty,
deallocated drives; a fuller drive was not measured, nor the recovery without a deallocate.

With this design's commands the 980 PRO and Sabrent pairs hold 3250 MB/s over 350 GiB on both
boards, the 980 PRO pair 3500 MB/s on `zcu106_hpc0`, and the SN8100 pair 2000 MB/s over
800 GiB; at 13 500 MB/s it records 683.7 GB before its caches run out (see
[Long recordings](#long-recordings-past-the-slc-cache)). The cache refills only while the
drive is idle, so back-to-back recordings may not each get a full cache: a 40 GiB recording at
8000 MB/s started 3 minutes after a 350 GiB one dropped with the Sabrent pair (see
[Burst and 40 GB recordings](#burst-and-40-gb-recordings)). Size the rate for the
longest recording you need: a short burst test overstates what a drive sustains.
