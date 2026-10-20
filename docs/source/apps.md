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
| `nvverify` | check a test-pattern recording beat by beat in software |
| `nvbench.sh` | sustained recording rate sweep |
| `nvbench-suite.sh` | the whole benchmark matrix of the [Benchmarks](benchmarks) page, resumable across power cycles |
| `nvregs` | register dump (support and debugging) |

Exit codes of `nvrec`: **0** = complete, no dropped beats, no NVMe error; **2** = complete but
beats were dropped (the recording is not valid); **1** = error (NVMe error, stall, setup);
**5** = the NVMe Host Accelerator stopped responding — with an evaluation license the IP stops
183-184 minutes (about 3 hours) after the bitstream was loaded; the apps print *"Host Accelerator stopped
responding (evaluation license expired?): reload the bitstream (power-cycle the board) to
record again"*. `nvplay` uses the same codes (2 = checker problem).

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
```

| option | default | |
|---|---|---|
| `--size` | (required) | data to record; K/M/G/T = 1024ⁿ, KB/MB/GB/TB = 1000ⁿ |
| `--rate` | as is | test pattern generator rate, bytes/s |
| `--chunk` | 1 MB or the MDTS | bytes per NVMe command: 1 MB or the drives' MDTS, whichever is smaller; must equal the md chunk (taken from the md array when not given); a chunk above the MDTS is refused (one NVMe command per chunk) |
| `--buffers` | 256 MB of slots | ring slots of one chunk in DDR (driver-allocated, CMA), 2–1024. Default: 256 MB / chunk, within 256…1024 slots: 1024 × 256 KB, 512 × 512 KB, 256 × 1 MB (the ring of fpga-drive-recorder is 32 × 8 MB = 256 MB). See [ring size and CMA](#ring-size-and-cma) |
| `--qd` | 32 | NVMe writes in flight per SSD, 1–63 |
| `--no-tpg` | | leave the data source alone (your own source in `user_data_source`) |
| `--fua` | | Force Unit Access on every write |
| `--force` | | overwrite an existing file |
| `--raw`, `--offset` | | record raw LBAs of an unmounted nvrec disk or md array |
| `--timeout` | 10 s | abort when no command completes for this long |
| `--stats` | 1 s | live stats interval (0 = off) |
| `--device`, `--target` | `/dev/nvrec`, machine | control device; name stored in the header |

What it does in file mode: preallocate the file (kernel exFAT, contiguous), unmount the
volume, locate the file's cluster run on the raw device, program the ring and the md RAID0
geometry, start the hardware (and the test pattern generator), wait, write the header and
the exFAT *ValidDataLength*, remount, truncate the file to the recorded length. Ctrl-C stops
the run cleanly: the open chunk is padded and completed, the file keeps what was recorded.

Live line (stderr): elapsed time, MB stored, current MB/s, progress, commands in flight,
ring fill/high-water, dropped beats, NVMe errors. The start line (stderr) and the summary
both give the ring (`ring 1024 slots x 262144 bytes = 256 MB`). A 10 GB recording at
1000 MB/s on one Sabrent Rocket 2230 (UltraZed-EV, `nvsetup-raid0.sh -y --single
/dev/nvrec0n1`; the `RESULT` line is one line, wrapped here):

```
$ sudo nvrec --rate 1000MB --size 10G /mnt/rec/hwtest.dat
nvrec: note: chunk clamped from 1048576 to the SSDs' maximum transfer size 262144
nvrec: /mnt/rec/hwtest.dat: 40960 x 262144-byte chunks from array chunk 66 over 1 member(s), ring 1024 slots (256 MB), qd 32
nvrec: 10737418240 bytes in 10.74 s, 999.8 MB/s; 40960 commands, 0 errors, max 32 in flight per SSD
nvrec: command latency min 90 / avg 264 / max 20490 us; ring high-water 80 slots, writer waited 0.000 ms for a free slot
nvrec: dropped beats 0, FIFO high-water during the run 259 of 4096 beats; file header + padding before the data
nvrec: ring 1024 slots x 262144 bytes = 256 MB, high-water 80 slots
RESULT bytes=10737418240 seconds=10.739 rate_bps=999999999 drops=0 fifo_hwm=259 fifo_depth=4096
  error=0 nvme_errors=0 chunk=262144 qd=32 members=1 ring_hwm=80 lat_avg_us=264 lat_max_us=20490
  data_offset=262144 lat_min_us=90 lat_count=40960 inflight_hwm=32,1 ring_wait_ms=0.000
  lat_hist=0,0,0,0,0,39301,130,207,200,111,651,104,95,161,0,0 lat_bin0_log2=10
  ring_slots=1024 ring_bytes=268435456
```

`RESULT` keys of `nvrec` (one line, `key=value`, for scripts such as `nvbench.sh`):

| key | meaning |
|---|---|
| `bytes`, `seconds`, `rate_bps` | data recorded, run time, generator rate set (0 = left as is) |
| `drops` | dropped beats (`RUN_DROP_COUNT`); 0 for a valid recording |
| `fifo_hwm`, `fifo_depth` | ingest FIFO high-water mark during the run, and its depth (beats) |
| `error`, `nvme_errors` | run result (0 = OK, negative errno otherwise), NVMe completions with an error status |
| `chunk`, `qd`, `members` | chunk bytes, commands in flight allowed per SSD, stripe members |
| `ring_hwm` | most ring slots in use at once |
| `lat_avg_us`, `lat_max_us`, `lat_min_us`, `lat_count` | command latency (submit to completion, µs, no decimals) and the number of commands measured |
| `inflight_hwm=<ssd0>,<ssd1>` | most commands in flight at once, one value per SSD slot |
| `ring_wait_ms` | time the ring writer waited for a free slot (ms, 3 decimals); 0 in a clean recording |
| `lat_hist=<b0>,...,<b15>`, `lat_bin0_log2` | 16-bin log2 latency histogram (commands per bin) and the log2 of the first bin's upper edge in `dp_clk` cycles |
| `data_offset` | header + padding in front of the data in the file |
| `ring_slots`, `ring_bytes` | the ring the driver set up: slots, and bytes (slots × chunk, rounded up to 2 MB); the last keys of the line |

When the Host Accelerator stops during a run, the `RESULT` line ends with `ha_dead=1` and
carries the same statistics keys. `--json` additionally prints the same keys as one JSON
object on the line after `RESULT` (the comma lists become arrays). `nvrec --print-target`
prints the default target name built into the app (`NVREC_TARGET`, written into the file
header) and exits with code 0. The same figures are in sysfs (`lat_hist`, `lat_bin0_log2`,
`ssd0_inflight_hwm`, `ssd1_inflight_hwm`, see [Kernel driver](driver.md#sysfs-and-module-parameters)).

### Ring size and CMA

The ring and its PRP lists are allocated from the kernel's CMA pool (`cma=`, `NVREC_CMA` in
`Yocto/bsp/<target>/conf/local.conf.append`: 1536 MB on `zcu106_hpc0` and `vck190_fmcp1`,
1024 MB on `uzev`) when a run starts and freed when it ends. CMA needed = ring (slots × chunk,
rounded up to 2 MB) + PRP lists (one per slot: 4 KB for chunks up to 2 MB, 16 KB for 4 MB;
none for chunks of 8 KB or less):

| ring | ring | PRP lists | CMA needed | fits 1536 MB | fits 1024 MB |
|---|---|---|---|---|---|
| default, 256 KB chunk | 1024 × 256 KB = 256 MB | 4 MB | 260 MB | yes | yes |
| default, 512 KB chunk | 512 × 512 KB = 256 MB | 2 MB | 258 MB | yes | yes |
| default, 1 MB chunk | 256 × 1 MB = 256 MB | 1 MB | 257 MB | yes | yes |
| `--buffers 1024 --chunk 1M` | 1024 MB (the 1 GB maximum) | 4 MB | 1028 MB | yes | **no** |

The hardware slot table has 1024 entries (`MAX_SLOTS`, a 10-bit slot number) and the driver
accepts at most 1 GB of ring. A ring that needs more CMA than the pool holds is refused before
anything starts (`ring of 1024 x 1048576 bytes needs 1028 MB of CMA (ring 1024 MB + PRP lists
4096 KB) but the kernel's CMA pool is only 1024 MB`); one that fits the pool but not its free,
contiguous part fails with `cannot allocate the ring: ... CMA free N of M MB`. Use fewer
`--buffers` or raise `NVREC_CMA`.

### File format

A 4096-byte header (`struct nvrec_file_header`, `sw/nvrec-apps/nvrec_file.h`), zero padding
up to `header_size` (the first chunk boundary at least 4 KB into the file, normally one chunk),
then the beats exactly as the fabric produced them (16 bytes each, little-endian). The first
fields are laid out like fpga-drive-recorder's header (magic `NVREC`, data offset in
`header_size`, data bytes, drop count, first sequence number, clocks, times, target, host);
the nvrec additions record the chunk, stripe members, start chunk, NVMe errors, queue depth
and command latency.

## nvplay

```
nvplay [options] <file>
nvplay [options] --raw <blockdev> --length <bytes> [--offset <bytes>]
```

Streams a recording into the fabric data sink with hardware NVMe reads (command builder in
read mode, ring reader → egress FIFO → `user_data_sink`). The volume stays mounted (nothing is
written; the file's location is read from the raw device after a `syncfs`). With the reference
design's checker (default; `--no-check` for your own sink), the result counts pattern errors,
sequence gaps and underflows (sink ready, no data: the SSDs could not keep up with the sink
rate, `--rate`). Only whole LBAs are played (a STOPped recording's last chunk is LBA-padded with
zeros). Options: `--rate`, `--no-check`, `--buffers`, `--qd`, `--chunk` (raw mode),
`--timeout`, `--stats`, `--device`.

Exit codes: 0 = complete and clean (errors = 0, underflows = 0, gap beats = the recording's
drop count), 2 = complete but the checker found a problem, 1 = error, 5 = Host Accelerator
stopped responding. `RESULT` keys as fpga-drive-recorder's `fdplay` (`bytes seconds
sink_rate_bps beats errors gaps gap_beats drop_count underflows`) plus `nvme_errors` and
`prefill_seconds`, followed by the statistics keys of `nvrec` (`lat_avg_us lat_max_us ring_hwm
lat_min_us lat_count inflight_hwm ring_wait_ms lat_hist lat_bin0_log2`, for the Read commands)
and `ring_slots ring_bytes`; `--buffers` has the same default as `nvrec`;
`--json` prints them as a JSON object too. Before the sink is enabled the ring is filled from the SSDs (prefill, up to
`play_prefill_ms`); `seconds` is the streaming time without the prefill, which is printed
separately.

Playing the recording above back at the same rate:

```
$ sudo nvplay --rate 1000MB /mnt/rec/hwtest.dat
nvplay: /mnt/rec/hwtest.dat: 40960 x 262144-byte chunks from array chunk 66 over 1 member(s), ring 1024 slots (256 MB), qd 32
nvplay: 10737418240 bytes in 10.74 s, 1000.0 MB/s; 40960 commands, 0 errors, max 32 in flight per SSD
nvplay: command latency min 149 / avg 218 / max 3368 us; ring high-water 1024 slots, writer waited 0.000 ms for a free slot
nvplay: ring 1024 slots x 262144 bytes = 256 MB, high-water 1024 slots
nvplay: ring prefill before the sink was enabled: 0.085 s (not in the time above)
nvplay: checker: 671088640 beats, 0 errors, 0 gaps (0 beats missing, recording dropped 0), 0 underflows
RESULT bytes=10737418240 seconds=10.737 sink_rate_bps=999999999 beats=671088640 errors=0 gaps=0
  gap_beats=0 drop_count=0 underflows=0 nvme_errors=0 complete=1 error=0 prefill_seconds=0.085
  lat_avg_us=218 lat_max_us=3368 ring_hwm=1024 lat_min_us=149 lat_count=40960 inflight_hwm=32,1
  ring_wait_ms=0.000 lat_hist=0,0,0,0,0,0,39927,12,6,10,1005,0,0,0,0,0 lat_bin0_log2=10
  ring_slots=1024 ring_bytes=268435456
```

In playback the ring high-water is the whole ring: the reader keeps every slot filled ahead of
the sink.

## nvverify

```
nvverify [options] <file>
nvverify [options] --raw --length <bytes> [--offset <bytes>] <blockdev>
```

The fpga-drive-recorder `fdverify`, extended: reads nvrec and fdrec files, and with `--raw` a
byte range of a device recorded by `nvrec --raw` (no header; the first beat may have any
sequence number). Every 16-byte beat must hold `upper == ~lower`, `lower == previous + 1`;
gaps are reported and compared with the header's drop count. `RESULT PASS` / exit 0 only on a
clean recording. Options: `--max-errors`, `--header-only`, `--pattern`, `-q`.

```
$ sudo nvverify /mnt/rec/hwtest.dat
/mnt/rec/hwtest.dat:
  header          NVREC version 1, data at 262144, 16-byte beats
  flags           0x3 (test pattern, complete)
  design version  1.1
  target / host   uzev / uzev-nvrec-2025-2
  src_clk_hz      199998001
  rate_bps        999999999
  start           2026-10-19 11:49:49 UTC (1792410589054664584 ns)
  stop            2026-10-19 11:49:59 UTC (1792410599793721460 ns)
  data_bytes      10737418240
  drop_count      0
  first_seq       0
  chunk / members 262144 bytes / 1, start chunk 66, qd 32
  NVMe            0 errors, latency avg 264 us, max 20490 us
  beats           671088640 (10737418240 bytes)
  first sequence  0
  last sequence   671088639
  discontinuities 0, beats missing 0
  corrupted beats 0
RESULT PASS
```

## nvbench.sh

The fpga-drive-recorder sweep with `nvrec`: records `--size` (default 32G, beyond the SLC cache
of small SSDs) at `--from`..`--to` MB/s in `--step` increments, verifies every recording with
`nvverify` and prints rate, result, drops, FIFO high-water, average rate. The highest passing
rate is the sustained recording rate. `--raw <dev>` sweeps raw LBAs instead of files;
`--nvrec-args "<...>"` passes options such as `--qd 16 --buffers 512`.

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
| `sustained` | 32 GB per step, 250 MB/s steps (`--from`/`--step`/`--to`), fresh trimmed volume + idle before every step, until the first failure |
| `glance` | 4000 MiB rate sweep, 250 .. 3000 MB/s (unless `--to`), + `--confirm` runs of the top clean step |
| `burst` | `--size` (10G) at `--rates a,b,..` or a sweep |
| `playback` | `nvplay` sweep of a 10 GB recording + confirmations |
| `cpu` | record + play at `--rate` (1000 MB/s) x `--runs` (2), with CPU figures |
| `chunk` | chunk sizes 128K .. the drives' MDTS (max 4M) at a fixed rate |
| `inflight` | commands in flight per SSD (`--qds`, 1..63) at a fixed rate |
| `longrun` | the post-SLC-cache sustained rate: `--size` (default 200G) at `--rate 1500MB,1750MB,..`, each rate on a fresh trimmed volume after `--idle` seconds (default 600 here) so the drive can empty its SLC cache, then `nvverify`; records carry `"test":"longrun"` and `pre_idle_s` |
| `verify [file]` | `nvverify` a recording (default: the last one) |
| `all` | the whole matrix for `--layouts` |
| `gaps` | for results written before the sweeps ended at the source maximum: per layout of `--layouts`, only the final 3200 MB/s step of the sustained and 10 GB burst sweeps (1 run each) and of the playback sweep (+ 2 confirmations), where the sweep's 3000 MB/s step passed |

Every command except `all` needs `--layout single1|single2|raid0` (`/dev/nvrec0n1`,
`/dev/nvrec1n1`, or the md RAID0 of both). **The tests that prepare a fresh volume erase
the drives.**

Requested rates are capped at the test-pattern generator's maximum (src_clk × 16 bytes =
3200 MB/s, from the driver's `src_clk_hz`): sweeps skip steps above it and end with one step at
the maximum when their grid misses it (250, 500, .., 3000, 3200; `--to` lowers the end), an
explicit rate above it runs at the maximum and is stored with `rate_req_mbps` = the maximum
and `"rate_capped":true`. `sustained`, `glance`, `burst` and `playback` take `--rates a,b,..`
instead of a sweep: every listed rate runs once (no stop at a failure), plus `--confirm <n>`
repeats of each when `--confirm` is given.

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
| 5 | the Host Accelerator stopped responding: power-cycle and run again |
| 1 | error |
| 2 | usage error |

`nvbench-suite.sh --help` lists all options.

## nvregs

Support/debug tool (root): dumps the `nvrec_core` run, per-SSD, injector and doorbell-monitor
registers and the Host Accelerator's status and statistics registers through `/dev/mem`
(`nvregs`; when `nvrec_core` reports `HA_DEAD` the IP's registers are not read), or reads/writes one register (`nvregs rd core|ha <offset>`,
`nvregs wr core|ha <offset> <value>`). It works with or without the driver loaded. The
doorbell monitor lists the last 8 writes the IP made into the SSDs' BARs (expected:
`BAR0 + 0x1008` SQ tail, `BAR0 + 0x100C` CQ head).
