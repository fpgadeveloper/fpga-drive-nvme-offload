# Test the design in Linux

Once the board has booted the Linux image (see [Yocto](yocto)) and you are logged in, work
through the steps below: check that the SSDs and the recorder are there, prepare the
recording volume, make a recording, verify it, copy it off the board and play it back.

Most commands need root privileges: prefix them with `sudo` (the `amd-edf` user may use
it). The outputs below come from a ZCU106 (`zcu106_hpc0`) with two Samsung 980 PRO 1TB on
the FPGA Drive FMC Gen4, with the image's defaults; the numbers on your board depend on the
target, the SSDs and the rate you choose.

```{note}
With an **evaluation license** for the NVMe Host Accelerator, the IP stops 183-184 minutes
after the bitstream was loaded, i.e. after the board was powered on. Power-cycle the board
before a long test session and plan it to end within about 2 h 45 min; see
[step 8](#8-when-the-host-accelerator-stops-evaluation-license).
```

## 1. Check the PCIe links and the SSDs

The kernel reports each Root Port as it probes it, then the design's driver reports each
SSD it takes over:

```
dmesg | grep -E "PCIe Link|nvrec"
```

Example output (ZCU106, two Samsung 980 PRO; the `nvrec 420010000.nvrec` line is one line,
wrapped here):

```none
xilinx-xdma-pcie 400000000.axi-pcie: PCIe Link is UP
xilinx-xdma-pcie 500000000.axi-pcie: PCIe Link is UP
nvrec 420010000.nvrec: /dev/nvrec: driver 1.2, nvrec_core v1.3, src_clk 249975021 Hz, dp_clk 249975021 Hz,
  beat 32 bytes, FIFO 8192/4096 beats (ingest/egress), 4096 ring slots, DRY, ring ports 2,
  mem1 0x2000000000 1024 MB, default ring split, stripe chunk; nvmeha: 2 SSDs x 1 queues
  (SQ window 0x90000000, CQ window 0x90008000), hardware queues, CPU I/O via the injector
nvrec-nvme 0000:01:00.0: SSD0: APST disabled (the drive's setting)
nvrec-nvme 0000:01:00.0: SSD0: Samsung SSD 980 PRO 1TB (<serial>, fw 5B2QGXA7): 1953525168 x 512-byte LBAs (1000 GB), MDTS 512 KB, DSTRD 0, 1 I/O queues granted, 0 SW + 1 HW queues in the IP, block I/O via the CPU command injector -> /dev/nvrec0n1
nvrec-nvme 0000:01:00.0: SSD0: composite temperature 32 C (warning 82 C, critical 85 C; 0 = not reported)
nvrec-nvme 0001:01:00.0: SSD1: APST disabled (the drive's setting)
nvrec-nvme 0001:01:00.0: SSD1: Samsung SSD 980 PRO 1TB (<serial>, fw 5B2QGXA7): 1953525168 x 512-byte LBAs (1000 GB), MDTS 512 KB, DSTRD 0, 1 I/O queues granted, 0 SW + 1 HW queues in the IP, block I/O via the CPU command injector -> /dev/nvrec1n1
nvrec-nvme 0001:01:00.0: SSD1: composite temperature 35 C (warning 82 C, critical 85 C; 0 = not reported)
nvrec-mps: NVREC_MPS 256 (/etc/default/nvrec-mps): setting it on the nvrec SSDs and their root ports
nvrec-mps: root port 0000:00:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
nvrec-mps: SSD       0000:01:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
nvrec-mps: root port 0001:00:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
nvrec-mps: SSD       0001:01:00.0: MaxPayload 128 -> 256 (MaxReadReq 512 unchanged)
```

What the lines tell you:

* `driver 1.2` is the kernel driver version and `nvrec_core v1.3` the register map version
  of the hardware (1.3: the split ring over two memories; 1.2: the configurable datapath
  width and the fabric-only mode; 1.1 added the Host Accelerator timeout guard); `src_clk`
  and `dp_clk` are the measured source and
  datapath clocks; `beat 32 bytes` is the 256-bit fabric datapath of the Zynq UltraScale+
  targets (`vck190_fmcp1`, 512 bits, shows `beat 64 bytes, FIFO 4096/4096 beats`; see
  [Kernel driver](driver.md#beats-and-words)), with an ingest FIFO of 8192 beats (256 KB)
  and an egress FIFO of 4096 beats (128 KB); `4096 ring slots` is the hardware slot table;
  `DRY` says the fabric-only mode is there. `ring ports 2, mem1 0x2000000000 1024 MB` is the
  split ring: a second ring port and the 1 GB of the second memory (here the PL DDR4) the
  device tree reserves for it; the default ring of a RAID0 or fabric-only run is split over
  both memories in whole-chunk stripes (`stripe chunk`, on `vck190_fmcp1` too; see
  [Kernel driver](driver.md#split-ring-one-ring-in-two-memories); `NOT READY` after the
  address would mean the PL DDR4 controller did not calibrate; `uzev` shows `ring ports 1,
  single ring`). `2 SSDs x 1 queues` is the Host Accelerator's
  configuration: one hardware queue per SSD, whose memory (`SQ window`, `CQ window`) the
  SSDs reach at 0x9000_0000.
* Per drive: the APST state the drive came up with and what the driver did with it (see
  [Kernel driver](driver.md#power-states-apst-and-temperature)); model, serial, firmware,
  capacity and LBA size, the **MDTS** (which sets the recording chunk, see
  [supported SSDs](supported_ssds)), the doorbell stride (`DSTRD 0` is required), and the
  block device the drive is reachable at; its temperature and thresholds. A drive may grant
  more I/O queues than the one the design uses (a Sabrent Rocket 2230 grants 8).
* The `nvrec-mps` lines: `nvrec-pcie-mps.service` raises the PCIe MaxPayload from the kernel's
  128 bytes to 256 bytes on both Root Ports and both SSDs, the image's setting on
  `zcu106_hpc0` and `vck190_fmcp1` (`uzev` keeps 128 bytes and shows no such lines; see
  [Apps](apps.md#nvrec-mps)).

The SSDs are **not** `/dev/nvme0n1` / `/dev/nvme1n1` in this design: they belong to the
`nvrec-nvme` driver, which creates their I/O queues inside the Host Accelerator (see
[Kernel driver](driver.md#why-the-stock-nvme-driver-is-kept-off-the-ssds)). Check the
binding and the link speed with `lspci`:

```
lspci -k | grep -A3 -i "non-volatile"      # "Kernel driver in use: nvrec-nvme"
sudo lspci -vv | grep -E "^[0-9a-f]|LnkSta:"
ls -l /dev/nvrec /dev/nvrec*n1
```

The Zynq UltraScale+ targets link at Gen3 x4 (8 GT/s); a Gen4 SSD reports its link as
`(downgraded)` there, which is expected. The VCK190 links at Gen4 x4 (16 GT/s).

If a link does not come up or an SSD is missing, see [Troubleshooting](troubleshooting).

## 2. Check the recorder driver

```
cat /sys/module/nvrec/version              # 1.2: the driver
cat /sys/class/misc/nvrec/version          # 1.3: the register map of the hardware
cat /sys/class/misc/nvrec/beat_bytes       # 32: a 256-bit datapath (64 on vck190_fmcp1)
cat /sys/class/misc/nvrec/ha_dead          # 0 = the Host Accelerator is working
cat /sys/block/nvrec0n1/nvrec/temperature  # composite temperature of SSD0, degrees C
cat /sys/block/nvrec0n1/nvrec/apst         # off (the driver's default)
grep Cma /proc/meminfo                     # CmaTotal: the pool for the recording ring
sudo nvrec-mps status                      # PCIe MaxPayload of the SSDs and their Root Ports
```

`sudo nvrec-mps status` on `zcu106_hpc0` (256 bytes on all four; `uzev` shows 128):

```none
  0000:01:00.0  SSD      : MaxPayload 256 (supports 256), MaxReadReq 512
  0000:00:00.0  root port: MaxPayload 256 (supports 1024), MaxReadReq 512
  0001:01:00.0  SSD      : MaxPayload 256 (supports 256), MaxReadReq 512
  0001:00:00.0  root port: MaxPayload 256 (supports 1024), MaxReadReq 512
```

The recording ring and its PRP lists are allocated when a run starts. A RAID0 or fabric-only
run on `zcu106_hpc0` and `vck190_fmcp1` uses a 1 GB ring split over PS DDR and the second
memory, half in each, in whole-chunk stripes (4096 × the Sabrent's 256 KB chunks, 2048 × the
980 PRO's 512 KB); a run on one SSD, and every run on `uzev`, a 512 MB ring in PS DDR. The
PS DDR part comes from the CMA pool, of which the image reserves 1 GB (`uzev`) or 1.5 GB
(`zcu106_hpc0`, `vck190_fmcp1`); the second memory's part is the 1 GB region the device tree
reserves there. `cat /sys/class/misc/nvrec/ring_ports /sys/class/misc/nvrec/mem1_ready` shows
`2` and `1` on the split-ring designs.

## 3. Prepare the recording volume

```{warning}
`nvsetup-raid0.sh` erases the SSDs it uses. Make sure they hold no data you need.
```

With two SSDs, make an md RAID0 array of both, formatted exFAT and mounted at `/mnt/rec`:

```
sudo nvsetup-raid0.sh
```

With one SSD (or to use one SSD of two):

```
sudo nvsetup-raid0.sh --single /dev/nvrec0n1
```

The script shows what it is about to erase and asks you to type `yes` (`-y` skips the
question). It reads the drives' MDTS and picks the chunk, then prints the layout:

```none
nvsetup-raid0: chunk 512K (the drives' maximum transfer size)
nvsetup-raid0: about to ERASE: /dev/nvrec0n1 /dev/nvrec1n1
  layout: RAID0 /dev/md0, chunk 512K, exFAT (cluster 512K), mounted at /mnt/rec
Type 'yes' to continue: yes
...
nvsetup-raid0: /dev/md0 (exFAT) mounted at /mnt/rec
```

The chunk is 1 MB, or the drives' maximum transfer size (MDTS) when that is smaller — 512 KB
on the 980 PRO, 256 KB on the Sabrent Rocket 2230. `--trim` deallocates the whole drives first (the reference starting point
for benchmarks), `--mount <dir>` mounts somewhere else. See
[Applications](apps.md#nvsetup-raid0sh) for all options.

The array and the mount are not restored at boot. After a reboot or power cycle:

```
sudo mdadm --assemble /dev/md0 /dev/nvrec0n1 /dev/nvrec1n1
sudo mount -o noatime /dev/md0 /mnt/rec
```

If the board was switched off or lost power while the volume was mounted, run
`sudo fsck.exfat -y /dev/md0` before you mount it.

## 4. Record

Record 10 GB of the test pattern at 1 GB/s:

```
sudo nvrec --rate 1000MB --size 10G /mnt/rec/test.dat; echo "exit code $?"
```

```{important}
`nvrec` **unmounts `/mnt/rec`** while the hardware records and mounts it again
afterwards (see [Filesystem and striping](filesystem)). Do not run it from a shell whose
current directory is on `/mnt/rec`, and keep no file on it open, or the unmount fails and
nothing is recorded.
```

While it runs, `nvrec` prints a live statistics line every second (elapsed time, data
stored, rate, progress, commands in flight, ring fill, dropped beats, NVMe errors), then a
summary:

Example output (ZCU106, RAID0 of two 980 PRO, freshly trimmed; the design's hardware test,
which records to `/mnt/rec/hwtest.dat`; the `RESULT` line is one line, wrapped here):

```none
nvrec: /mnt/rec/hwtest.dat: 20480 x 524288-byte chunks from array chunk 35 over 2 member(s), ring 2048 slots (1024 MB, split over 2 memories, whole-chunk stripes (512 KB)), qd 32
nvrec: 10737418240 bytes in 10.74 s, 1000.0 MB/s; 20480 commands, 0 errors, max 2 in flight per SSD
nvrec: command latency min 162 / avg 163 / max 1954 us; ring high-water 5 slots, writer waited 0.000 ms for a free slot
nvrec: ring ports (memory 0 / 1): writer waited 193.537 / 20.974 ms, reader waited 0.000 / 0.000 ms
nvrec: dropped beats 0, FIFO high-water during the run 129 of 8192 beats; file header + padding before the data
nvrec: ring 2048 slots x 524288 bytes = 1024 MB, split over 2 memories, whole-chunk stripes (512 KB), high-water 5 slots
RESULT bytes=10737418240 seconds=10.738 rate_bps=999999997 drops=0 fifo_hwm=129 fifo_depth=8192
  error=0 nvme_errors=0 chunk=524288 qd=32 members=2 ring_hwm=5 lat_avg_us=163 lat_max_us=1954
  data_offset=524288 beat_bytes=32 no_write=0 lat_min_us=162 lat_count=20480 inflight_hwm=2,1
  ring_wait_ms=0.000 lat_hist=0,0,0,0,0,0,20474,0,2,4,0,0,0,0,0,0 lat_bin0_log2=10
  wr_port_stall_ms=193.537,20.974 rd_port_wait_ms=0.000,0.000 mps=256 ring_slots=2048
  ring_bytes=1073741824 ring=split stripe_kb=512 ring_mem1_bytes=536870912
exit code 0
```

What the summary tells you:

* **the first line**: 10 GiB is 20480 chunks of 512 KB (the 980 PRO's MDTS), striped over the
  two drives starting at chunk 35 of the array, through a ring of 2048 slots (1 GB) split over
  PS DDR and the PL DDR4 in whole-chunk stripes: each drive writes from one of the two memories.
* **20480 commands, 0 errors**: one NVMe Write command per chunk, all issued and completed in
  hardware; `max 2 in flight per SSD` is the deepest each SSD's queue got (the limit is
  `--qd`, default 32). At 1 GB/s a 980 PRO completes nearly every 512 KB command before the
  next chunk is full; at higher rates or during write stalls more commands queue up.
* **command latency**: from the moment the command builder hands a command to the Host
  Accelerator to its completion, measured in hardware.
* **ring high-water**: the most chunks that were waiting for the SSDs at any time, out of
  the ring's 2048. It shows how much of the ring the SSDs' write stalls used; `writer waited`
  is the time the ring was full (it must stay 0 for a clean recording).
* **ring ports**: how long the ring writer waited for each of the two memories. Some wait is
  normal in every run; a memory whose wait approaches the duration of the recording is the one
  that held it up (see [Applications](apps.md#ring-layout---ring-and---stripe)).
* **dropped beats 0**: no data was lost. `FIFO high-water` is the fill of the 8192-beat
  (256 KB) ingest FIFO during the run; beats are 32 bytes on this design (`beat_bytes=32`).
* `RESULT` is one machine-readable line for scripts (`nvbench.sh` uses it); its first keys
  follow the `fdrec` tool of fpga-drive-recorder, the others are listed in
  [Applications](apps.md#nvrec). `mps=256` is the PCIe MaxPayload in force.

| `nvrec` exit code | Meaning |
|---|---|
| 0 | Recording complete: zero dropped beats, zero NVMe errors |
| 2 | Beats were dropped: the SSDs could not keep up with the rate; the recording is not valid |
| 1 | Error: an NVMe error, a stall (nothing completed for `--timeout` seconds, default 10), or a setup problem (the message says which) |
| 5 | The NVMe Host Accelerator stopped responding (evaluation license expired?); see [step 8](#8-when-the-host-accelerator-stops-evaluation-license) |

## 5. Verify

Verify every word of the recording:

```
sudo nvverify /mnt/rec/test.dat; echo "exit code $?"
```

`nvverify` prints the file header, then checks the data and ends with `RESULT PASS` and
exit code 0 for a clean recording:

Example output (the recording above):

```none
/mnt/rec/hwtest.dat:
  header          NVREC version 1, data at 524288, 32-byte beats
  flags           0x3 (test pattern, complete)
  design version  1.3
  target / host   zcu106_hpc0 / zcu106-nvrec-2025-2
  src_clk_hz      249975021
  rate_bps        999999997
  ...
  data_bytes      10737418240
  drop_count      0 beats
  first_seq       0
  chunk / members 524288 bytes / 2, start chunk 35, qd 32
  NVMe            0 errors, latency avg 163 us, max 1954 us
  words           671088640 (10737418240 bytes, 335544320 beats of 32 bytes)
  first sequence  0
  last sequence   671088639
  discontinuities 0, words missing 0 (0 beats)
  corrupted words 0
RESULT PASS
exit code 0
```

`data at 524288` is the header and padding in front of the data: the data starts on a
chunk boundary of the array, so that every hardware command writes one whole chunk.
`nvverify` checks the test pattern per 16-byte word (a 32-byte beat holds two), so it reads
recordings of any datapath width.

## 6. Copy the recording off the board

The recording is an ordinary exFAT file. Copy it to a PC over the network:

```
scp amd-edf@<board-ip>:/mnt/rec/test.dat .
```

(`ip -br addr` on the board shows its address.) `scp` is limited by the encryption on the
board's processor (about 70 MB/s on the ZCU106), so a 10 GB file takes a few minutes. On
the PC, build `nvverify` from `sw/nvrec-apps` (`make -C sw/nvrec-apps`) and check the copy:
`./nvverify test.dat` must print `RESULT PASS` as on the board.

You can also move the SSDs to a Linux PC: a single drive mounts directly (exFAT), and a
RAID0 pair assembles with `mdadm --assemble --scan`, because the hardware writes exactly
the md RAID0 layout.

## 7. Play back

Play the recording back into the fabric, where the hardware checker consumes it at 3 GB/s
(the playback rate does not depend on the rate the file was recorded at) and checks every
beat:

```
sudo nvplay --rate 3000MB /mnt/rec/test.dat; echo "exit code $?"
```

`nvplay` prints the same summary lines as `nvrec` (see [Applications](apps.md#nvplay) for a
complete example), then the prefill time, the checker's counts (`nvplay: checker: ... 0
errors, 0 gaps ..., 0 underflows`) and its `RESULT` line. Example, a 40 GiB recording of the
same kind on the same RAID0 of two 980 PROs, played at 5750 MB/s (the prefill and `RESULT`
lines; the `RESULT` line is one line, wrapped here):

```none
nvplay: ring prefill before the sink was enabled: 0.153 s (not in the time above)
RESULT bytes=42949672960 seconds=7.470 sink_rate_bps=5749999999 beats=1342177280 errors=0 gaps=0
  gap_beats=0 drop_count=0 underflows=0 nvme_errors=0 complete=1 error=0 prefill_seconds=0.153
  beat_bytes=32 file_beat_bytes=32 ring_only=0 passes=1 lat_avg_us=278 lat_max_us=8010
  ring_hwm=2048 lat_min_us=167 lat_count=81920 inflight_hwm=32,32 ring_wait_ms=0.000
  lat_hist=0,0,0,0,0,0,79872,2,4,357,593,1092,0,0,0,0 lat_bin0_log2=10
  wr_port_stall_ms=0.000,0.000 rd_port_wait_ms=1643.923,453.218 mps=256 ring_slots=2048
  ring_bytes=1073741824 ring=split stripe_kb=512 ring_mem1_bytes=536870912
exit code 0
```

Before the checker is enabled, the ring is filled from the SSDs (`prefill`), so that the
sink does not starve while the first read commands complete. During playback the ring is
normally full (`ring_hwm=2048` of 2048 slots) and every SSD has its full `--qd` of reads in
flight (`inflight_hwm=32,32`): the SSDs read ahead of the sink. `beats` counts the 32-byte
beats the checker took; `rd_port_wait_ms` is how long the ring reader waited for each memory.

| `nvplay` exit code | Meaning |
|---|---|
| 0 | Playback complete, and the checker saw every beat with no errors, no underflows, and gaps equal to the recording's drop count |
| 2 | Playback complete, but the checker found a problem (for example underflows: the SSDs could not deliver the data as fast as `--rate`) |
| 1 | Error or incomplete playback (Ctrl-C, NVMe error, stall) |
| 5 | The NVMe Host Accelerator stopped responding (evaluation license expired?) |

```{note}
Without `--rate`, `nvplay` leaves the sink rate as it is; its default is one beat per
`src_clk` cycle (8 GB/s on the 256-bit Zynq UltraScale+ targets, 16 GB/s on the 512-bit
`vck190_fmcp1`). Give `nvplay` a `--rate` below the read rate
of your SSDs.
```

## 8. When the Host Accelerator stops (evaluation license)

A bitstream built with an evaluation license stops the NVMe Host Accelerator 183-184
minutes after it was loaded. The design detects it, and the system stays up (console and
SSH keep working). The kernel log shows one line:

```none
nvrec 420010000.nvrec: Host Accelerator stopped responding (evaluation license expired?): NVMe I/O stopped; reload the bitstream (power-cycle the board) to continue
```

From then on, `cat /sys/class/misc/nvrec/ha_dead` reads 1, `nvrec` and `nvplay` exit with
code 5 and the message
`Host Accelerator stopped responding (evaluation license expired?): reload the bitstream (power-cycle the board) to record again`,
and any I/O to `/dev/nvrecXn1` or the mounted volume fails with an I/O error. To continue,
power-cycle the board (a soft reboot does not reload the bitstream), then re-assemble and
check the volume as in [step 3](#3-prepare-the-recording-volume) (`fsck.exfat -y` first).
With a purchased license this never happens.

## 9. Find the sustained recording rate

`nvbench.sh` sweeps the rate with 32 GB per step, verifies every recording, and prints the
highest rate that recorded cleanly. It takes a while (32 GB at every step):

```
sudo nvbench.sh
```

Run it once on a single SSD and once on RAID0, within one power-on session if you use an
evaluation license. It sweeps from 500 MB/s to the generator maximum (8000 MB/s on the
256-bit targets, 16 000 MB/s on `vck190_fmcp1`) in 500 MB/s steps; `--from`, `--step` and `--to` change that. See
[Benchmarks](benchmarks) for the method and for results.

## 10. Check the fabric path alone (no SSD)

The fabric-only mode (register map 1.2) runs the recorder and the player without any NVMe
command, so it shows what the fabric and the DDR path sustain on their own — the ceiling no
SSD can raise. It needs no recording volume and does not touch the SSDs:

```
sudo nvrec --no-write --rate 8000MB --size 64G; echo "exit code $?"
sudo nvplay --ring-only --rate 8000MB --passes 4; echo "exit code $?"
```

`nvrec --no-write` fills the ring at `--rate` and releases every slot at once: exit code 0
means no beat was dropped at that rate. `nvplay --ring-only` fills the ring once from the
generator, then streams it to the checker at `--rate`: exit code 0 means every beat arrived
in order and the sink never ran dry. Lower the rate in steps to find the highest clean one.
See [Applications](apps.md#fabric-only---no-write) for the details.
