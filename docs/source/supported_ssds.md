# Supported SSDs

## Compatibility

The [FPGA Drive FMC Gen4] and [M.2 M-key Stack FMC] support M.2 M-key NVMe SSDs of PCIe
Gen1 to Gen4. An SSD that supports a higher PCIe generation than the design links at the
design's speed (Gen3 on the Zynq UltraScale+ targets, Gen4 on the VCK190).

Unlike [fpga-drive-recorder](https://recorder.fpgadrive.com), this design does not use the
stock Linux NVMe driver: its own `nvrec` driver brings each SSD up and gives the NVMe Host
Accelerator one I/O queue on it. That puts a few requirements on the SSD that a standard
driver does not have. The driver checks every one of them when it probes an SSD and
refuses a drive that does not meet them, with a message in the kernel log:

| Requirement | Why | What the driver does otherwise |
|---|---|---|
| **`CAP.DSTRD` = 0** (4-byte doorbell stride) | The Host Accelerator computes the doorbell addresses itself, with a 4-byte stride | Refuses the SSD |
| **BAR0 below 4 GB** (AXI and PCIe bus address) | The Host Accelerator's doorbell master has 32 address bits | Refuses the SSD (`BAR0 at ... is at or above 4 GB`) |
| **Queues of at least 64 entries** (`CAP.MQES` ≥ 63) | The Host Accelerator's queue for each SSD has 64 entries | Refuses the SSD |
| **Namespace 1 with 512-byte or 4 KB LBAs, no metadata** | The design records to namespace 1 and the command builder computes LBAs from byte offsets; the driver does not reformat a drive | Refuses the SSD |

On the Zynq UltraScale+ targets the root ports only have BAR windows below 4 GB, so the
BAR requirement is always met. On the VCK190, a non-prefetchable BAR0 (the usual case) is
placed below 4 GB, but an SSD with a *prefetchable* BAR0 would be placed in the 64-bit
window above 4 GB and cannot be used (see [supported carriers](supported_carriers.md#vck190)).

The design uses exactly one I/O queue per SSD (NVMe queue ID 1), which the CPU's own I/O
shares through the command injector, so an SSD that grants a single I/O queue works (with
fpga-drive-recorder, the Samsung 970 EVO 250GB was set up with a single I/O queue).

### Maximum data transfer size (MDTS)

One recording chunk is one NVMe command, and an NVMe command cannot move more than the
drive's **maximum data transfer size** (MDTS, from Identify Controller). The chunk is
therefore **1 MB or the drive's MDTS, whichever is smaller**; with two SSDs, the smaller
MDTS of the two. `nvsetup-raid0.sh` reads the MDTS of the drives and sets the md chunk
accordingly, `nvrec` follows the md chunk, and the driver refuses a larger chunk. The MDTS
of each SSD is printed when it probes and can be read at any time:

```
cat /sys/block/nvrec0n1/nvrec/mdts_bytes
```

The Samsung 980 PRO has an MDTS of 512 KB, so its recordings use 512 KB chunks; the Sabrent
Rocket 2230 has an MDTS of 256 KB (256 KB chunks).

## SSDs tested with this design

| SSD (brand and model) | Capacity | Firmware | MDTS | I/O queues used | Tested in this revision |
|-----------------------|----------|----------|------|-----------------|--------|
| Samsung 980 PRO       | 1 TB     | 5B2QGXA7 | 512 KB | 1 | `zcu106_hpc0` (Gen3 x4) and `vck190_fmcp1` (Gen4 x4), FPGA Drive FMC Gen4: single drive and RAID0 pair, recording, playback, `nvverify` |
| Sabrent Rocket 2230 (SB-2130-1TB) | 1 TB | R21B47.1 | 256 KB | 1 | `zcu106_hpc0` (Gen3 x4) and `vck190_fmcp1` (Gen4 x4), M.2 M-key Stack FMC: single drive and RAID0 pair, recording, playback, `nvverify` |

The Samsung 950 PRO 256GB and Samsung 970 EVO 250GB, used for the
[fpga-drive-recorder](https://recorder.fpgadrive.com) benchmarks, have not been tested with
this design.

The measured rates are on the [Benchmarks](benchmarks) page. Both drive models came up with
NVMe APST disabled; the driver switches it off in any case (module parameter `apst`, see
[Kernel driver](driver.md#power-states-apst-and-temperature)).

### Observations with the tested drives

* **The Samsung 980 PRO pair reaches the DDR ceiling on `vck190_fmcp1`.** Two 980 PROs on Gen4 x4
  record 9250 MB/s and play back 8750 MB/s in RAID0, the limit of the VCK190's single DDR4
  controller (every recorded byte crosses it twice), not of the drives: each writes ~4.95 GB/s
  in its cache and reads ~6.3 GB/s (~7 GB/s at MaxPayload 256 bytes). Past its cache one 980 PRO
  writes ~1.77 GB/s with this design as with fpga-drive-recorder (1750 MB/s over 200 GiB on
  both boards).
* **One Sabrent Rocket writes ~5 % slower with this design than with fpga-drive-recorder**, on
  both link generations: in its SLC cache 2.75-2.83 against 2.88-2.95 GB/s at the first failing
  step on `zcu106_hpc0` (Gen3 x4) and 4.24-4.31 against 4.57-4.65 GB/s on `vck190_fmcp1` (Gen4
  x4), and past it ~1.73 against ~1.80 GB/s on both boards (the pair ~3.39-3.45 against ~3.6
  GB/s). Its past-cache figures here are therefore one 250 MB/s step lower (1500 MB/s over
  200 GiB against 1750 MB/s). More commands in flight do not help one Sabrent: at `--qd 63` it
  writes the same in its cache (2.74 GB/s) and 1.74 GB/s past it. This is an open observation:
  the cause, perhaps the drive's response to 256 KB commands with PRP lists on a single
  hardware queue, has not been isolated, nor separated from the drives' wear (about 9.7 TB were
  written to the pair in the two days of measurements); see [Comparison](comparison).
* **The Sabrent Rocket 2230 1TB slowed down over a night of benchmarks.** After about 4.9 TB had
  been written to the pair in one night (each recording on freshly deallocated drives, the
  drives at most 59 °C, APST off), both drives wrote 3-5 % slower than at the start of the
  night with the same image: one drive 4.12-4.21 GB/s instead of 4.24-4.31 GB/s at the same
  step, the pair 6.45-6.56 GB/s instead of 6.69-6.76 GB/s. How much idle time the drives need
  to recover was not measured. Rates near a drive's limit can therefore differ by one 250 MB/s
  step between sessions: the one-drive figure of `vck190_fmcp1` on the
  [Benchmarks](benchmarks) page (4000 MB/s) was measured after this slowdown, late that night
  and again the next day. With the pair, more commands in flight now cost one step (7500 MB/s
  at `--qd 63` against 7750 MB/s at 32, with write-latency maxima of 31-45 ms against ~21 ms),
  where on the first night they had helped.
* **The Sabrent pair needs the 512 MB ring at high RAID0 rates.** Its write stalls (20-32 ms)
  used up to 369 MB of the ring at 5000 MB/s on `zcu106_hpc0`, and a 256 MB ring dropped data
  there and at 7750 MB/s on `vck190_fmcp1`; keep the default ring (see
  [Benchmarks](benchmarks.md#ring-size)).
* **Short playback underflows with the Sabrent pair on `vck190_fmcp1`.** Above 7500 MB/s a RAID0
  playback of a long file sees short underflows (up to ~1.6 ms in total per file) at the
  requested rate, with the ring full and the drives' read latency at most 3.1 ms: a 40 GiB file
  plays clean at 7500 MB/s, a 10 GiB file at 8750 MB/s. The 980 PRO pair does not show them on
  the same image; the cause has not been isolated.

## Choosing SSDs for recording

Compatibility is rarely the issue; the **sustained write rate** is. A recorder writes at a
constant rate for as long as the recording lasts, and the SSD must keep up the whole time,
or beats are dropped. The rate printed on an SSD's datasheet is usually not that rate:

* **SLC write cache.** Most consumer SSDs with TLC or QLC flash write into a fast
  pseudo-SLC cache first and fold the data into the slower flash later. While the cache
  lasts, the SSD writes at its datasheet rate; once it is full, the rate drops, sometimes
  to a fraction. The size of the cache depends on the model, the capacity and how full the
  drive is. With fpga-drive-recorder, the cache of a 970 EVO 250GB lasted about 14 GB on an
  empty, trimmed drive, after which the write rate fell to about 330 MB/s.
* **Size your test to your recordings.** A short test (a few GB) measures the cache. Use
  `nvbench.sh` with a recording size at least as long as your longest recording (default
  32 GB per step) to find the rate you can sustain.
* **Free space and trim.** An SSD with little free space, or one that has not been
  trimmed, has less room for its cache and for garbage collection. Keep the recording
  volume empty enough, and trim the drives between benchmark campaigns
  (`nvsetup-raid0.sh --trim` deallocates the whole drives before it formats them).
* **RAID0.** Two SSDs striped as RAID0 add up their rates, but every chunk of the stripe
  goes to both drives in turn, so the array is limited by the slower drive: twice the
  slower drive's sustained rate. Use two identical SSDs (their MDTS also sets the chunk).
* **Heat.** Long recordings at high rates heat the SSD controller, and many SSDs throttle
  when they get hot. Give the SSDs airflow, or a heatsink, for long recordings. The driver
  reads each SSD's composite temperature and its warning and critical thresholds
  (`/sys/block/nvrecXn1/nvrec/temperature`), and `nvbench-suite.sh` stops a run above 70 °C;
  in the benchmarks the drives stayed at or below 64 °C. (The full `nvme smart-log` needs the
  stock driver; see [Kernel driver](driver.md#using-the-stock-nvme-driver-reference-tests).)

Drives designed for sustained writes (SLC or MLC flash, enterprise and industrial drives,
or simply larger capacities with a bigger cache) give higher sustained rates.

You can help us maintain this list by communicating [your experiences] to us or by
contributing to the documentation on our [Github repo].

[your experiences]: https://opsero.com/contact-us
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[Github repo]: https://github.com/fpgadeveloper/fpga-drive-nvme-offload
