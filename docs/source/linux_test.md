# Test the design in Linux

Once the board has booted the Linux image (see [Yocto](yocto)) and you are logged in, work
through the steps below: check that the SSDs and the recorder are there, prepare the
recording volume, make a recording, verify it, copy it off the board and play it back.

Most commands need root privileges: prefix them with `sudo` (the `amd-edf` user may use
it). The outputs below come from a ZCU106 (`zcu106_hpc0`) with two Samsung 980 PRO 1TB;
the numbers on your board depend on the target, the SSDs and the rate you choose.

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

Example output (ZCU106, two 980 PRO):

```none
xilinx-xdma-pcie 400000000.axi-pcie: PCIe Link is UP
xilinx-xdma-pcie 500000000.axi-pcie: PCIe Link is UP
nvrec 420010000.nvrec: /dev/nvrec: nvrec_core v1.1, src_clk 199980011 Hz, dp_clk 249975006 Hz, FIFO 4096 beats; nvmeha: 2 SSDs x 1 queues (SQ window 0x90000000, CQ window 0x90008000), hardware queues, CPU I/O via the injector
nvrec-nvme 0000:01:00.0: SSD0: Samsung SSD 980 PRO 1TB (<serial>, fw 5B2QGXA7): 1953525168 x 512-byte LBAs (1000 GB), MDTS 512 KB, DSTRD 0, 1 I/O queues granted, 0 SW + 1 HW queues in the IP, block I/O via the CPU command injector -> /dev/nvrec0n1
nvrec-nvme 0001:01:00.0: SSD1: Samsung SSD 980 PRO 1TB (<serial>, fw 5B2QGXA7): 1953525168 x 512-byte LBAs (1000 GB), MDTS 512 KB, DSTRD 0, 1 I/O queues granted, 0 SW + 1 HW queues in the IP, block I/O via the CPU command injector -> /dev/nvrec1n1
```

What the lines tell you:

* `nvrec_core v1.1` is the register map version of the hardware (1.1 has the Host
  Accelerator timeout guard); `src_clk` and `dp_clk` are the measured source and datapath
  clocks; `2 SSDs x 1 queues` is the Host Accelerator's configuration: one hardware queue
  per SSD, whose memory (`SQ window`, `CQ window`) the SSDs reach at 0x9000_0000.
* One `SSD<n>` line per drive: model, serial, firmware, capacity and LBA size, the
  **MDTS** (which sets the recording chunk, see [supported SSDs](supported_ssds)), the
  doorbell stride (`DSTRD 0` is required), and the block device the drive is reachable at.

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
cat /sys/class/misc/nvrec/version          # 1.1
cat /sys/class/misc/nvrec/ha_dead          # 0 = the Host Accelerator is working
grep Cma /proc/meminfo                     # CmaTotal: the pool for the recording ring
```

The recording ring (256 MB by default: 256 × 1 MB, 512 × the 980 PRO's 512 KB chunks or
1024 × 256 KB) and its PRP lists are allocated from the CMA pool
when a run starts; the image reserves 1 GB (`uzev`) or 1.5 GB (`zcu106_hpc0`,
`vck190_fmcp1`).

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
on the 980 PRO. `--trim` deallocates the whole drives first (the reference starting point
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

Example output (ZCU106, RAID0 of two 980 PRO, freshly trimmed; the `RESULT` line is one line,
wrapped here):

```none
nvrec: /mnt/rec/test.dat: 20480 x 524288-byte chunks from array chunk 35 over 2 member(s), ring 512 slots (256 MB), qd 32
nvrec: 10737418240 bytes in 10.74 s, 1000.0 MB/s; 20480 commands, 0 errors, max 1 in flight per SSD
nvrec: command latency min 179 / avg 179 / max 243 us; ring high-water 2 slots, writer waited 0.000 ms for a free slot
nvrec: dropped beats 0, FIFO high-water during the run 259 of 4096 beats; file header + padding before the data
nvrec: ring 512 slots x 524288 bytes = 256 MB, high-water 2 slots
RESULT bytes=10737418240 seconds=10.738 rate_bps=999999999 drops=0 fifo_hwm=259 fifo_depth=4096
  error=0 nvme_errors=0 chunk=524288 qd=32 members=2 ring_hwm=2 lat_avg_us=179 lat_max_us=243
  data_offset=524288 lat_min_us=179 lat_count=20480 inflight_hwm=1,1 ring_wait_ms=0.000
  lat_hist=0,0,0,0,0,0,20480,0,0,0,0,0,0,0,0,0 lat_bin0_log2=10 ring_slots=512 ring_bytes=268435456
exit code 0
```

What the summary tells you:

* **the first line**: 10 GiB is 20480 chunks of 512 KB (the 980 PRO's MDTS), striped over the
  two drives starting at chunk 35 of the array, through a ring of 512 slots (256 MB).
* **20480 commands, 0 errors**: one NVMe Write command per chunk, all issued and completed in
  hardware; `max 1 in flight per SSD` is the deepest each SSD's queue got (the limit is
  `--qd`, default 32). At 1 GB/s a 980 PRO completes every 512 KB command before the next
  chunk is full; at higher rates or during write stalls more commands queue up.
* **command latency**: from the moment the command builder hands a command to the Host
  Accelerator to its completion, measured in hardware.
* **ring high-water**: the most chunks that were waiting for the SSDs at any time, out of
  the ring's 512. It shows how much of the ring the SSDs' write stalls used; `writer waited`
  is the time the ring was full (it must stay 0 for a clean recording).
* **dropped beats 0**: no data was lost. `FIFO high-water` is the fill of the 4096-beat
  ingest FIFO during the run.
* `RESULT` is one machine-readable line for scripts (`nvbench.sh` uses it); its first keys
  follow the `fdrec` tool of fpga-drive-recorder, the others are listed in
  [Applications](apps.md#nvrec).

| `nvrec` exit code | Meaning |
|---|---|
| 0 | Recording complete: zero dropped beats, zero NVMe errors |
| 2 | Beats were dropped: the SSDs could not keep up with the rate; the recording is not valid |
| 1 | Error: an NVMe error, a stall (nothing completed for `--timeout` seconds, default 10), or a setup problem (the message says which) |
| 5 | The NVMe Host Accelerator stopped responding (evaluation license expired?); see [step 8](#8-when-the-host-accelerator-stops-evaluation-license) |

## 5. Verify

Verify every beat of the recording:

```
sudo nvverify /mnt/rec/test.dat; echo "exit code $?"
```

`nvverify` prints the file header, then checks the data and ends with `RESULT PASS` and
exit code 0 for a clean recording:

Example output (the recording above):

```none
/mnt/rec/test.dat:
  header          NVREC version 1, data at 524288, 16-byte beats
  flags           0x3 (test pattern, complete)
  design version  1.1
  target / host   zcu106_hpc0 / zcu106-nvrec-2025-2
  src_clk_hz      199980011
  rate_bps        999999999
  ...
  data_bytes      10737418240
  drop_count      0
  first_seq       0
  chunk / members 524288 bytes / 2, start chunk 35, qd 32
  NVMe            0 errors, latency avg 179 us, max 243 us
  beats           671088640 (10737418240 bytes)
  first sequence  0
  last sequence   671088639
  discontinuities 0, beats missing 0
  corrupted beats 0
RESULT PASS
exit code 0
```

`data at 524288` is the header and padding in front of the data: the data starts on a
chunk boundary of the array, so that every hardware command writes one whole chunk.

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
errors, 0 gaps ..., 0 underflows`) and its `RESULT` line. Example, the recording above played
at 3000 MB/s (the prefill and `RESULT` lines; the `RESULT` line is one line, wrapped here):

```none
nvplay: ring prefill before the sink was enabled: 0.047 s (not in the time above)
RESULT bytes=10737418240 seconds=3.579 sink_rate_bps=2999999998 beats=671088640 errors=0 gaps=0
  gap_beats=0 drop_count=0 underflows=0 nvme_errors=0 complete=1 error=0 prefill_seconds=0.047
  lat_avg_us=283 lat_max_us=10527 ring_hwm=512 lat_min_us=174 lat_count=20480 inflight_hwm=32,32
  ring_wait_ms=0.000 lat_hist=0,0,0,0,0,0,19970,66,81,40,140,161,22,0,0,0 lat_bin0_log2=10
  ring_slots=512 ring_bytes=268435456
exit code 0
```

Before the checker is enabled, the ring is filled from the SSDs (`prefill`), so that the
sink does not starve while the first read commands complete. During playback the ring is
normally full (`ring_hwm=512` of 512 slots) and every SSD has its full `--qd` of reads in
flight (`inflight_hwm=32,32`): the SSDs read ahead of the sink.

| `nvplay` exit code | Meaning |
|---|---|
| 0 | Playback complete, and the checker saw every beat with no errors, no underflows, and gap beats equal to the recording's drop count |
| 2 | Playback complete, but the checker found a problem (for example underflows: the SSDs could not deliver the data as fast as `--rate`) |
| 1 | Error or incomplete playback (Ctrl-C, NVMe error, stall) |
| 5 | The NVMe Host Accelerator stopped responding (evaluation license expired?) |

```{note}
Without `--rate`, `nvplay` leaves the sink rate as it is; its default is one beat per
`src_clk` cycle (3.2 GB/s). Give `nvplay` a `--rate` below the read rate of your SSDs.
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
evaluation license. See [Benchmarks](benchmarks) for the method and for results.
