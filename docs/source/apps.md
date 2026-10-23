# Apps

The image installs these tools in `/usr/bin` (sources in `sw/nvrec-apps/`, built by
`meta-nvrec/recipes-apps/nvrec-apps`). They mirror the tools of
[fpga-drive-recorder](https://recorder.fpgadrive.com) — same options where they apply, same
`RESULT` lines and exit codes — so the two designs can be measured side by side.

| tool | does |
|---|---|
| `nvsetup-raid0.sh` | create the recording volume: md RAID0 over `/dev/nvrec0n1` + `/dev/nvrec1n1` (or one SSD), exFAT, mounted at `/mnt/rec` |
| `nvrec` | record the fabric stream into a file (hardware NVMe command path, no CPU in the data path) |
| `nvplay` | play a recording back into the fabric checker (hardware NVMe reads) |
| `nvverify` | check a test-pattern recording word by word in software |
| `nvbench.sh` | sustained recording rate sweep |
| `nvbench-suite.sh` | the whole benchmark matrix of the [Benchmarks](benchmarks) page, resumable across power cycles |
| `nvregs` | register dump (support and debugging) |

Exit codes of `nvrec`: **0** = complete, no dropped beats, no NVMe error; **2** = complete but
beats were dropped (the recording is not valid); **1** = error (NVMe error, stall, setup);
**5** = the NVMe Host Accelerator stopped responding — with an evaluation license the IP stops
183-184 minutes (about 3 hours) after the bitstream was loaded; the apps print *"Host Accelerator stopped
responding (evaluation license expired?): reload the bitstream (power-cycle the board) to
record again"*. `nvplay` uses the same codes (2 = checker problem).

This page describes the apps of version 1.1 (`nvrec-apps` package), which go with driver 1.1
and register map 1.2.

## Beats and words

The fabric datapath is 256 bits wide on the Zynq UltraScale+ targets (`zcu106_hpc0`, `uzev`):
one **beat** is 32 bytes. On `vck190_fmcp1` it is 512 bits wide: 64-byte beats (16 bytes on a
128-bit build; the driver reads the beat size from the hardware, see
[Kernel driver](driver.md#beats-and-words)). Every beat count the apps print — dropped beats,
FIFO depth and high-water, the checker's beats and gap beats — is in these beats, and the
`RESULT` lines carry `beat_bytes`. The test pattern, and so `nvverify`, works on 16-byte
**words**: a 32-byte beat holds two consecutive words, a 64-byte beat four. A recording is the
same byte stream whatever the width, so recordings made on a 128-bit design (16-byte beats)
play and verify on a 256-bit or 512-bit one. The generator's maximum rate is
`src_clk × beat_bytes`: 8000 MB/s at 250 MHz × 32 B, 16 000 MB/s at 250 MHz × 64 B.

## Quick start

```
sudo nvsetup-raid0.sh -y                     # both SSDs, RAID0 (chunk: 1 MB or the MDTS, whichever is smaller), exFAT on /mnt/rec
sudo nvrec --rate 2GB --size 10G /mnt/rec/test.dat
sudo nvverify /mnt/rec/test.dat
sudo nvplay --rate 2GB /mnt/rec/test.dat
```

From a PC: `scp amd-edf@<board>:/mnt/rec/test.dat .` (or `rsync`). Run the tools with
`sudo` as the `amd-edf` user; [Test the design in Linux](linux_test) walks through a first
session step by step.

```{important}
`nvrec` **unmounts the recording volume** while the hardware records and remounts it
afterwards (see [Filesystem](filesystem)). Keep no shell (`cd /mnt/rec`) or open file on
it, or the unmount fails and nothing is recorded.
```

## nvsetup-raid0.sh

```
nvsetup-raid0.sh [options] [<nvrec-dev> <nvrec-dev>]
```

Without arguments it uses the two nvrec namespaces in `/dev`. **All data on the drives is
destroyed.** Options: `--chunk <size>` (md chunk = `nvrec --chunk`, default 1M, or the drives' maximum transfer size (MDTS) when smaller — 512K on a Samsung 980 PRO; a larger `--chunk` is refused), `--cluster
<size>` (exFAT cluster, default = chunk), `--mount <dir>` (default `/mnt/rec`), `--single <dev>`
(one SSD, no md), `--trim` (`blkdiscard` the whole drives first — the reference starting point
for benchmarks), `--label`, `--teardown` (unmount, stop `/dev/md0`), `-y`.

After a reboot: `mdadm --assemble /dev/md0 /dev/nvrec0n1 /dev/nvrec1n1 && mount -o noatime
/dev/md0 /mnt/rec`.

## nvrec

```
nvrec [options] --size <bytes> <file>
nvrec [options] --size <bytes> --raw <blockdev> [--offset <bytes>]
nvrec [options] --size <bytes> --no-write
```

| option | default | |
|---|---|---|
| `--size` | (required) | data to record; K/M/G/T = 1024ⁿ, KB/MB/GB/TB = 1000ⁿ |
| `--rate` | as is | test pattern generator rate, bytes/s; at most `src_clk × beat_bytes` (8000 MB/s on the 256-bit Zynq UltraScale+ targets, 16 000 MB/s on the 512-bit `vck190_fmcp1`), a higher rate runs at the maximum |
| `--chunk` | 1 MB or the MDTS | bytes per NVMe command: 1 MB or the drives' MDTS, whichever is smaller; must equal the md chunk (taken from the md array when not given); a chunk above the MDTS is refused (one NVMe command per chunk) |
| `--buffers` | 512 MB of slots | ring slots of one chunk in DDR (driver-allocated, CMA), 2–2048 and at most the hardware slot table. Default: 512 MB / chunk, within 256…2048 slots: 2048 × 256 KB, 1024 × 512 KB, 512 × 1 MB. See [ring size and CMA](#ring-size-and-cma) |
| `--qd` | 32 | NVMe writes in flight per SSD, 1–63; a tuning knob for high-rate RAID0, see [queue depth](#queue-depth---qd) |
| `--no-tpg` | | leave the data source alone (your own source in `user_data_source`) |
| `--fua` | | Force Unit Access on every write |
| `--force` | | overwrite an existing file |
| `--raw`, `--offset` | | record raw LBAs of an unmounted nvrec disk or md array |
| `--no-write` | | fabric only: fill the ring and release every slot at once, no NVMe command, no file (see below) |
| `--timeout` | 10 s | abort when no command completes (`--no-write`: no data moves) for this long |
| `--stats` | 1 s | live stats interval (0 = off) |
| `--device`, `--target` | `/dev/nvrec`, machine | control device; name stored in the header |

What it does in file mode: preallocate the file (kernel exFAT, contiguous), unmount the
volume, locate the file's cluster run on the raw device, program the ring and the md RAID0
geometry, start the hardware (and the test pattern generator), wait, write the header and
the exFAT *ValidDataLength*, remount, truncate the file to the recorded length. Ctrl-C stops
the run cleanly: the open chunk is padded and completed, the file keeps what was recorded.

Live line (stderr): elapsed time, MB stored, current MB/s, progress, commands in flight,
ring fill/high-water, dropped beats, NVMe errors. The start line (stderr) and the summary
both give the ring (`ring 2048 slots x 262144 bytes = 512 MB`). A 10 GB recording at
1000 MB/s on one Samsung 980 PRO 1TB on `zcu106_hpc0` (MDTS 512 KB, `nvsetup-raid0.sh -y
--single /dev/nvrec0n1`; the `RESULT` line is one line, wrapped here):

```
$ sudo nvrec --rate 1000MB --size 10G /mnt/rec/hwtest.dat
nvrec: note: chunk clamped from 1048576 to the SSDs' maximum transfer size 524288
nvrec: /mnt/rec/hwtest.dat: 20480 x 524288-byte chunks from array chunk 20 over 1 member(s), ring 1024 slots (512 MB), qd 32
nvrec: 10737418240 bytes in 10.74 s, 1000.0 MB/s; 20480 commands, 0 errors, max 5 in flight per SSD
nvrec: command latency min 179 / avg 182 / max 2110 us; ring high-water 6 slots, writer waited 0.000 ms for a free slot
nvrec: dropped beats 0, FIFO high-water during the run 129 of 8192 beats; file header + padding before the data
nvrec: ring 1024 slots x 524288 bytes = 512 MB, high-water 6 slots
RESULT bytes=10737418240 seconds=10.738 rate_bps=999999997 drops=0 fifo_hwm=129 fifo_depth=8192
  error=0 nvme_errors=0 chunk=524288 qd=32 members=1 ring_hwm=6 lat_avg_us=182 lat_max_us=2110
  data_offset=524288 beat_bytes=32 no_write=0 lat_min_us=179 lat_count=20480 inflight_hwm=5,0
  ring_wait_ms=0.000 lat_hist=0,0,0,0,0,0,20425,8,15,31,1,0,0,0,0,0 lat_bin0_log2=10
  ring_slots=1024 ring_bytes=536870912
```

`RESULT` keys of `nvrec` (one line, `key=value`, for scripts such as `nvbench.sh`):

| key | meaning |
|---|---|
| `bytes`, `seconds`, `rate_bps` | data recorded, run time, generator rate set (0 = left as is) |
| `drops` | dropped beats (`RUN_DROP_COUNT`, beats of `beat_bytes`); 0 for a valid recording |
| `fifo_hwm`, `fifo_depth` | ingest FIFO high-water mark during the run, and its depth (beats) |
| `error`, `nvme_errors` | run result (0 = OK, negative errno otherwise), NVMe completions with an error status |
| `chunk`, `qd`, `members` | chunk bytes, commands in flight allowed per SSD, stripe members |
| `ring_hwm` | most ring slots in use at once |
| `lat_avg_us`, `lat_max_us`, `lat_min_us`, `lat_count` | command latency (submit to completion, µs, no decimals) and the number of commands measured |
| `inflight_hwm=<ssd0>,<ssd1>` | most commands in flight at once, one value per SSD slot |
| `ring_wait_ms` | time the ring writer waited for a free slot (ms, 3 decimals); 0 in a clean recording |
| `lat_hist=<b0>,...,<b15>`, `lat_bin0_log2` | 16-bin log2 latency histogram (commands per bin) and the log2 of the first bin's upper edge in `dp_clk` cycles |
| `data_offset` | header + padding in front of the data in the file |
| `beat_bytes` | bytes per fabric beat of the design (16, 32 or 64) |
| `no_write` | 1 for a fabric-only run (`--no-write`), 0 for a recording |
| `ring_slots`, `ring_bytes` | the ring the driver set up: slots, and bytes (slots × chunk, rounded up to 2 MB); the last keys of the line |

When the Host Accelerator stops during a run, the `RESULT` line ends with `ha_dead=1` and
carries the same statistics keys. `--json` additionally prints the same keys as one JSON
object on the line after `RESULT` (the comma lists become arrays). `nvrec --print-target`
prints the default target name built into the app (`NVREC_TARGET`, written into the file
header) and exits with code 0. The same figures are in sysfs (`lat_hist`, `lat_bin0_log2`,
`ssd0_inflight_hwm`, `ssd1_inflight_hwm`, see [Kernel driver](driver.md#sysfs-and-module-parameters)).

### Fabric only: `--no-write`

`nvrec --no-write --size <bytes> [--rate R] [--buffers N]` runs the recorder with the
hardware's fabric-only mode (`CONFIG.DRY`, register map 1.2): the source, the ingest FIFO
and the ring writer fill the ring in PS DDR through the HP port (Zynq UltraScale+) or the
NoC (Versal) exactly as in a recording, but no NVMe command is built and every slot is
released as soon as it is filled. No file is created (`nvrec` refuses a file name with
`--no-write`, so a forgotten name cannot be mistaken for a recording), no volume is
unmounted, and no SSD is needed. It measures the fabric → DDR path on its own — the highest
generator rate the board sustains before any SSD is involved:

```
sudo nvrec --no-write --rate 8000MB --size 64G
```

* `--size` counts the bytes written into the ring; `--chunk` and `--buffers` set the ring
  as for a recording; `--qd`, `--raw`, `--offset`, `--force` and `--fua` do not apply.
* The live stats, the stall watchdog (it watches the bytes moved) and the summary work as for
  a recording; the summary says `fabric only (DRY): no NVMe command`.
* The exit codes are the same: **0** = no beat dropped, **2** = beats were dropped (the path
  did not keep up with the source), **1** = error or stall. The `RESULT` line carries
  `no_write=1`, `members=0` and `qd=0`.
* It also works after the evaluation license of the Host Accelerator has expired (no NVMe
  path is involved). It needs a register map 1.2 bitstream.

### Queue depth (`--qd`)

`--qd` sets how many NVMe commands the hardware keeps in flight per SSD (`nvplay --qd`: Read
commands). The default, 32, is the right value for single drives and for most RAID0 rates.
For the highest RAID0 rates it is worth trying `--qd 63`: with more commands in flight per
drive, two drives can absorb more of each other's write latency, and on a build whose path
to memory is wide enough this can raise the highest clean rate. On other builds more
commands in flight only add latency and contention, and the clean rate drops, so measure
both values on your board and drives (`nvbench.sh --nvrec-args "--qd 63"`, or
`nvbench-suite.sh --qd 63`, which runs every recording and playback with it and keeps its
results apart, `/qd=63` in the run ids) before you change it.

Measured on `vck190_fmcp1` (32 GB RAID0 recordings, see
[Benchmarks](benchmarks.md#commands-in-flight-qd-32-and-63)): at 512 KB per command, two
Samsung 980 PRO 1TB record 9250 MB/s and play back 8750 MB/s at either value, because the DDR
controller, not their write latency, is their limit. At 256 KB per command, two Sabrent Rocket
2230 1TB are clean up to 7750 MB/s at `--qd 32` and only up to 7500 MB/s at `--qd 63` (3 of 3
each; at `--qd 63` the drives' write-latency maxima grow from ~21 to 31-45 ms); an earlier build,
with these drives less worn, had reached 8500 MB/s at `--qd 63`, which did not reproduce. On a
256-bit build of the same board, whose two PCIe Root Ports shared one NoC port, `--qd 63`
lowered what the Sabrent pair wrote at 7000 MB/s from 6.69-6.76 to 6.24 GB/s. On `zcu106_hpc0`
the Sabrent RAID0 records its 5000 MB/s top (the HP port) at either value. One drive gains
nothing from it (one Sabrent drops at the same rate with either value, in and past its SLC
cache). The default therefore stays 32.

### Ring size and CMA

The ring and its PRP lists are allocated from the kernel's CMA pool (`cma=`, `NVREC_CMA` in
`Yocto/bsp/<target>/conf/local.conf.append`: 1536 MB on `zcu106_hpc0` and `vck190_fmcp1`,
1024 MB on `uzev`) when a run starts and freed when it ends. CMA needed = ring (slots × chunk,
rounded up to 2 MB) + PRP lists (one per slot: 4 KB for chunks up to 2 MB, 16 KB for 4 MB;
none for chunks of 8 KB or less):

| ring | ring | PRP lists | CMA needed | fits 1536 MB | fits 1024 MB |
|---|---|---|---|---|---|
| default, 256 KB chunk | 2048 × 256 KB = 512 MB | 8 MB | 520 MB | yes | yes |
| default, 512 KB chunk | 1024 × 512 KB = 512 MB | 4 MB | 516 MB | yes | yes |
| default, 1 MB chunk | 512 × 1 MB = 512 MB | 2 MB | 514 MB | yes | yes |
| `--buffers 1024` (256 KB chunk) | 1024 × 256 KB = 256 MB (the 1.0 default) | 4 MB | 260 MB | yes | yes |
| `--buffers 1024 --chunk 1M` | 1024 MB (the 1 GB maximum) | 4 MB | 1028 MB | yes | **no** |

Why 512 MB: the ring is what absorbs an SSD's write stalls, and at this revision's rates it
drains fast — 512 MB lasts 64 ms at 8 GB/s, 256 MB only 32 ms, while a drive can
pause for tens of milliseconds (an idle drive waking from a deep power state takes about as
long, which is why the driver switches APST off, see
[Kernel driver](driver.md#power-states-apst-and-temperature)). The hardware slot table has
2048 entries on the register map 1.2 designs (`MAX_SLOTS`, an 11-bit slot number; 1024 on
1.1 bitstreams, where the default becomes 1024 × 256 KB = 256 MB) and the driver accepts at
most 1 GB of ring. A ring that needs more CMA than the pool holds is refused before
anything starts (`ring of 1024 x 1048576 bytes needs 1028 MB of CMA (ring 1024 MB + PRP lists
4096 KB) but the kernel's CMA pool is only 1024 MB`); one that fits the pool but not its free,
contiguous part fails with `cannot allocate the ring: ... CMA free N of M MB`. Use fewer
`--buffers` or raise `NVREC_CMA`.

### File format

A 4096-byte header (`struct nvrec_file_header`, `sw/nvrec-apps/nvrec_file.h`), zero padding
up to `header_size` (the first chunk boundary at least 4 KB into the file, normally one chunk),
then the data exactly as the fabric produced it: 16-byte test-pattern words, little-endian,
`beat_bytes` (the design's beat: 32 on the 256-bit targets, 64 on `vck190_fmcp1`) per beat. The first
fields are laid out like fpga-drive-recorder's header (magic `NVREC`, data offset in
`header_size`, data bytes, drop count, first sequence number, clocks, times, target, host);
the nvrec additions record the chunk, stripe members, start chunk, NVMe errors, queue depth
and command latency.

## nvplay

```
nvplay [options] <file>
nvplay [options] --raw <blockdev> --length <bytes> [--offset <bytes>]
nvplay [options] --ring-only [--fill-rate <bytes/s>] [--passes <n>]
```

Streams a recording into the fabric data sink with hardware NVMe reads (command builder in
read mode, ring reader → egress FIFO → `user_data_sink`). The volume stays mounted (nothing is
written; the file's location is read from the raw device after a `syncfs`). With the reference
design's checker (default; `--no-check` for your own sink), the result counts pattern errors,
sequence gaps and underflows (sink ready, no data: the SSDs could not keep up with the sink
rate, `--rate`). Only whole LBAs are played (a STOPped recording's last chunk is LBA-padded with
zeros). Options: `--rate` (at most `src_clk × beat_bytes`: 8000 MB/s on the 256-bit
targets, 16 000 MB/s on `vck190_fmcp1`), `--no-check`, `--buffers`, `--qd`, `--chunk` (raw mode), `--timeout`, `--stats`,
`--device`. With the checker, the recording must come from the test pattern generator (its
header says so); use `--no-check` for any other source.

The checker counts beats of this design; the recording's `drop_count` is in the beats of
the design that recorded it (`beat_bytes` in its header). `nvplay` compares the two as
missing 16-byte words, so a recording made with smaller beats (16 bytes on the 128-bit
revision, 32 on a 256-bit target) plays on a wider design: a clean one plays clean. One
whose drops left a gap that is not a whole number of the player's beats cannot be
represented in whole beats: the checker counts the beat that holds the gap as one
bad beat (an error) and truncates the gap count; `nvplay` prints a note when it starts such
a playback. It also checks that the first word at the sink is the header's `first_seq`.

Exit codes: 0 = complete and clean (errors = 0, underflows = 0, the gaps = the recording's
drop count), 2 = complete but the checker found a problem, 1 = error, 5 = Host Accelerator
stopped responding. `RESULT` keys as fpga-drive-recorder's `fdplay` (`bytes seconds
sink_rate_bps beats errors gaps gap_beats drop_count underflows`, then `beat_bytes` and
`file_beat_bytes`, the beat sizes of the design and of the recording) plus `nvme_errors`,
`prefill_seconds`, `ring_only` (0) and `passes` (1), followed by the statistics keys of
`nvrec` (`lat_avg_us lat_max_us ring_hwm lat_min_us lat_count inflight_hwm ring_wait_ms
lat_hist lat_bin0_log2`, for the Read commands) and `ring_slots ring_bytes`; `--buffers`
has the same default as `nvrec`; `--json` prints them as a JSON object too. Before the sink
is enabled the ring is filled from the SSDs (prefill, up to `play_prefill_ms`); `seconds`
is the streaming time without the prefill, which is printed separately.

Playing the recording above back at the same rate:

```
$ sudo nvplay --rate 1000MB /mnt/rec/hwtest.dat
nvplay: /mnt/rec/hwtest.dat: 20480 x 524288-byte chunks from array chunk 20 over 1 member(s), ring 1024 slots (512 MB), qd 32, 32-byte beats
nvplay: 10737418240 bytes in 10.74 s, 1000.0 MB/s; 20480 commands, 0 errors, max 32 in flight per SSD
nvplay: command latency min 174 / avg 430 / max 10170 us; ring high-water 1024 slots, writer waited 0.000 ms for a free slot
nvplay: ring 1024 slots x 524288 bytes = 512 MB, high-water 1024 slots
nvplay: ring prefill before the sink was enabled: 0.169 s (not in the time above)
nvplay: checker: 335544320 beats of 32 bytes (expected 335544320), 0 errors, 0 gaps (0 beats = 0 words missing; recording dropped 0 beats of 32 bytes = 0 words), 0 underflows
RESULT bytes=10737418240 seconds=10.737 sink_rate_bps=999999997 beats=335544320 errors=0 gaps=0
  gap_beats=0 drop_count=0 underflows=0 nvme_errors=0 complete=1 error=0 prefill_seconds=0.169
  beat_bytes=32 file_beat_bytes=32 ring_only=0 passes=1 lat_avg_us=430 lat_max_us=10170
  ring_hwm=1024 lat_min_us=174 lat_count=20480 inflight_hwm=32,0 ring_wait_ms=0.000
  lat_hist=0,0,0,0,0,0,19269,180,1,19,490,420,101,0,0,0 lat_bin0_log2=10
  ring_slots=1024 ring_bytes=536870912
```

In playback the ring high-water is the whole ring: the reader keeps every slot filled ahead of
the sink.

### Fabric only: `--ring-only`

`nvplay --ring-only --rate <R> [--fill-rate <F>] [--passes <n>] [--buffers N] [--chunk C]`
is the ring-resident playback test of the fabric path, without SSD and without file
(register map 1.2):

1. It sets up the ring (same default as a recording: 512 MB) and **fills it once** with a
   fabric-only record of exactly one ring of test pattern from the generator at
   `--fill-rate` (default 2000 MB/s): slot *s* then holds chunk *s*, the pattern starting at
   word 0. The fill must not drop a beat (`the ring fill dropped N beats ...: lower
   --fill-rate` otherwise).
2. It plays the ring back fabric-only `--passes` times (default 1): the ring reader streams
   every slot once, in order, through the egress FIFO into the checker at `--rate`. Each
   pass resets the checker, which must see every beat of the ring in sequence, without an
   error and without an underflow.

```
sudo nvplay --ring-only --rate 7500MB --passes 4
```

It prints one line per pass (bytes, time, rate, the checker's counts), a summary, and a
`RESULT` line with the keys of a playback summed over the passes, `ring_only=1`, `passes`,
`fill_rate_bps` and `fill_seconds`. The exit codes are those of a playback (2 = an
underflow, error or gap in any pass). A 512 MB ring lasts 64 ms at 8 GB/s, so a pass is
short; `--passes` repeats it. The generator rate stays at `--fill-rate` afterwards.

## nvverify

```
nvverify [options] <file>
nvverify [options] --raw --length <bytes> [--offset <bytes>] [--beat-bytes <n>] <blockdev>
```

The fpga-drive-recorder `fdverify`, extended: reads nvrec and fdrec files, and with `--raw` a
byte range of a device recorded by `nvrec --raw` (no header; the first word may have any
sequence number). It checks every 16-byte **word** of the test pattern, whatever the beat
size the recording was made with (the header's `beat_bytes`: 16, 32 or 64; fpga-drive-recorder
1.3 files have 32): `upper == ~lower`, `lower == previous + 1`. Gaps are reported in words;
a dropped beat leaves a gap of `beat_bytes / 16` words at a beat boundary, so the words
missing are compared with the header's `drop_count × beat_bytes / 16`. A gap that is not
whole beats at a beat boundary is reported as a `PROBLEM` (corruption, not a drop), as is
data that is not a whole number of beats. A header with any other beat size (0, 24, ...) is
refused. `RESULT PASS` / exit 0 only on a clean recording. Options: `--max-errors`,
`--header-only`, `--pattern`, `--beat-bytes` (raw mode: the recorder's beat, default 16 =
no beat-boundary check), `-q`.

```
$ sudo nvverify /mnt/rec/hwtest.dat
/mnt/rec/hwtest.dat:
  header          NVREC version 1, data at 524288, 32-byte beats
  flags           0x3 (test pattern, complete)
  design version  1.2
  target / host   zcu106_hpc0 / zcu106-nvrec-2025-2
  src_clk_hz      249975021
  rate_bps        999999997
  start           2026-10-23 04:02:28 UTC (1792728148578630775 ns)
  stop            2026-10-23 04:02:39 UTC (1792728159316284455 ns)
  data_bytes      10737418240
  drop_count      0 beats
  first_seq       0
  chunk / members 524288 bytes / 1, start chunk 20, qd 32
  NVMe            0 errors, latency avg 182 us, max 2110 us
  words           671088640 (10737418240 bytes, 335544320 beats of 32 bytes)
  first sequence  0
  last sequence   671088639
  discontinuities 0, words missing 0 (0 beats)
  corrupted words 0
RESULT PASS
```

A recording with drops lists each gap (`GAP at word 2097152 (file offset ...): expected
2097152, found 2105344, 8192 words missing`), sums them (`discontinuities 1, words missing
8192 (4096 beats)`) and ends with `note: missing words match the header drop_count exactly
(4096 beats x 2 words)` — and `RESULT FAIL`, since a recording with drops is not valid.

## nvbench.sh

The fpga-drive-recorder sweep with `nvrec`: records `--size` (default 32G, beyond the SLC cache
of small SSDs) at `--from`..`--to` MB/s in `--step` increments (default 500 … the generator
maximum, step 500), verifies every recording with `nvverify` and prints rate, result, drops,
FIFO high-water, average rate. The highest passing rate is the sustained recording rate. The
default top is `src_clk × beat_bytes` from sysfs, with the clock taken to the nearest MHz:
249.975 MHz × 32 B gives 8000 (and 199.98 MHz × 16 B 3200: version 1.0 truncated it to 3199
and never swept 3200); a rate a hair above the true maximum runs at the maximum. `--raw <dev>`
sweeps raw LBAs instead of files; `--nvrec-args "<...>"` passes options such as `--qd 16
--buffers 1024`; `--stop-on-fail` ends the sweep at the first failing rate.

## nvbench-suite.sh

Runs the benchmark matrix described on the [Benchmarks](benchmarks) page, with the method of
fpga-drive-recorder, and appends one JSON line per run to a results file
(`/var/lib/nvbench/results.jsonl`; per-run logs in `/var/lib/nvbench/logs/`). Run it as root.

```
nvbench-suite.sh [options] <command> [command options]
```

| command | does |
|---|---|
| `info` | print the fixture (drives, links, versions) as JSON |
| `status` | list the results file, per test and layout |
| `sustained` | 32 GB per step, 250 MB/s steps (`--from`/`--step`/`--to`), fresh trimmed volume + idle before every step, until `--stop-after` consecutive failing steps (default 1) |
| `glance` | 4000 MiB rate sweep + `--confirm` runs of the top clean step |
| `burst` | `--size` (10G) at `--rates a,b,..` or a sweep |
| `playback` | `nvplay` sweep of a 10 GB recording + confirmations; the recording (the playback source, made at 1000 MB/s on a fresh volume) is reused only while it is valid for the layout, the chunk and the design's beat size, and recorded again otherwise (`--source-fresh` forces it) |
| `fabric` | fabric only, no SSD, no `--layout`: `nvrec --no-write` sweep, `--size` (64G) per step |
| `fabricplay` | fabric only: `nvplay --ring-only` sweep (`--passes` playbacks of the ring per step) |
| `cpu` | record + play at `--rate` (1000 MB/s) x `--runs` (2), with CPU figures |
| `chunk` | chunk sizes 128K .. the drives' MDTS (max 4M) at a fixed rate |
| `inflight` | commands in flight per SSD (`--qds`, 1..63) at a fixed rate |
| `longrun` | the post-SLC-cache sustained rate: `--size` (default 200G) at `--rate 1500MB,1750MB,..`, each rate on a fresh trimmed volume after `--idle` seconds (default 600 here) so the drive can empty its SLC cache, then `nvverify`; records carry `"test":"longrun"` and `pre_idle_s` |
| `verify [file]` | `nvverify` a recording (default: the last one) |
| `all` | the whole matrix for `--layouts` |
| `gaps` | for results of suite version 1, whose sweeps ended at the last 250 MB/s step below the source maximum: per layout of `--layouts`, only the final step at the maximum of the sustained and 10 GB burst sweeps (1 run each) and of the playback sweep (+ 2 confirmations), where the sweep's last grid step passed |

Every command except `all`, `fabric` and `fabricplay` needs `--layout single1|single2|raid0`
(`/dev/nvrec0n1`, `/dev/nvrec1n1`, or the md RAID0 of both). **The tests that prepare a fresh
volume erase the drives.**

Requested rates are capped at the test-pattern generator's maximum: `src_clk × beat_bytes`,
from the driver's `src_clk_hz` taken to the nearest MHz and `beat_bytes` (8000 MB/s on the
256-bit targets, 16 000 on the 512-bit `vck190_fmcp1`, 3200 on a 128-bit build). Sweeps skip steps above it and end with one step at
the maximum when their grid misses it (`--to` lowers the end); an explicit rate above it runs
at the maximum and is stored with `rate_req_mbps` = the maximum and `"rate_capped":true`.
`sustained`, `glance`, `burst`, `playback`, `fabric` and `fabricplay` take `--rates a,b,..`
instead of a sweep: every listed rate runs once (no stop at a failure), plus `--confirm <n>`
repeats of each when `--confirm` is given.

Sweep options, for a shortened method that starts at a known floor:

| option | default | |
|---|---|---|
| `--from`, `--step`, `--to` | 250, 250, the maximum | the grid in MB/s; `all` uses them too (its 10 GB burst sweep starts at 500 otherwise) |
| `--stop-after <n>` | 1 | a sweep ends after *n* consecutive failing steps; with 2, one failing step followed by a passing one does not end it |
| `--confirm <n>` | 2 for `glance` and `playback`, 0 otherwise | extra runs at the top clean step (`/run=2`, `/run=3`, … in the ids) |
| `--confirm-fail <n>` | 0 | extra runs at the first failing step above the top clean step |
| `--buffers <n>` | the apps' 512 MB ring | ring slots, 2–2048; the ids get `/slots=<n>`, so ring A/B runs of the same steps do not collide |
| `--qd <n>` | 32 | NVMe commands in flight per SSD for every recording and playback of the call (not `inflight`, which sweeps `--qds`, and not the playback source, always 32); a value other than 32 is in the ids (`/qd=<n>`) and in each result's `qd` |
| `--tag <word>` | | appended to every id (`/tag=<word>`) and stored: A/B runs of the same steps (MaxPayload 256, APST on, …) |
| `--passes <n>` | 1 | `fabricplay`: playbacks of the ring per step |
| `--source-fresh` | | `playback`, `cpu`: record the playback source again (once per layout per call), even when the one on the volume is still valid |

For example, the RAID0 sweep from the 4500 MB/s floor in 500 MB/s steps, ending after two
failing steps, with 3 of 3 at the top and at the first failing step:

```
sudo nvbench-suite.sh --layout raid0 --from 4500 --step 500 --stop-after 2 \
     --confirm 2 --confirm-fail 2 --budget-min 150 sustained
```

**Drive temperature guard.** During every recording and playback the suite reads the member
drives' composite temperature (`/sys/block/nvrecXn1/nvrec/temperature`, driver 1.1) every
10 s. Above `--temp-max` (default 70 °C; 0 = off) it stops the run with SIGINT (a clean
stop), does not store it, waits until every member drive is at or below `--temp-resume`
(default 45 °C) and runs it again; a second over-temperature on the same run stops the suite
with exit code 4. A run also waits for the drives to cool to `--temp-resume` before it starts
when they are above `--temp-max`. Every result stores `temp_start_c`, `temp_end_c` and
`temp_max_c` (the hottest sample).

On 1 TB drives the 32 GB `sustained` sweep stays inside the SLC cache, so it gives the
in-cache figure; `longrun` is the measurement past the cache.

The suite is **resumable**: every run has an id (test, layout, drive serials, parameters),
and a run already in the results file is not repeated, so the same command continues where
an interrupted session stopped. With an evaluation license, `--budget-min <min>` (default
150) stops it cleanly before a run that would end later than that many minutes after the
bitstream load (`--t0-ago <sec>` tells it when the board was powered on; default: the
kernel's boot time). `--dry-run` prints the plan and an estimate without touching anything.

| exit code | meaning |
|---|---|
| 0 | everything asked for is in the results file |
| 3 | stopped for the time budget: power-cycle the board and run the same command again |
| 4 | a drive passed `--temp-max` twice in the same run: let the drives cool, then run the same command again |
| 5 | the Host Accelerator stopped responding: power-cycle and run again |
| 1 | error |
| 2 | usage error |

Each JSON line holds the fixture (target, kernel, register map `hw_version`, driver
`drv_version`, `src_clk_hz`, `dp_clk_hz`, `beat_bytes`, FIFO depths, the `apst` module
parameter, and per drive model, serial, firmware, MDTS, PCIe link, `apst` state and
temperature thresholds) and the run (rate requested and achieved, `beat_bytes`, drops or
underflows, FIFO and ring high-water, latency, ring, `nvverify` result with `words_missing`
and `beats_missing`, CPU load, temperatures, `tag`).

`nvbench-suite.sh --help` lists all options.

## nvregs

Support/debug tool (root): dumps the `nvrec_core` run, per-SSD, injector and doorbell-monitor
registers and the Host Accelerator's status and statistics registers through `/dev/mem`
(`nvregs`; the first lines give the beat size, the FIFO depths and the slot table; when
`nvrec_core` reports `HA_DEAD` the IP's registers are not read), or reads/writes one register (`nvregs rd core|ha <offset>`,
`nvregs wr core|ha <offset> <value>`). It works with or without the driver loaded. The
doorbell monitor lists the last 8 writes the IP made into the SSDs' BARs (expected:
`BAR0 + 0x1008` SQ tail, `BAR0 + 0x100C` CQ head).
