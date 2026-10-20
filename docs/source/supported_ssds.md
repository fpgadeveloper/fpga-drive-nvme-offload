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

| SSD (brand and model) | Capacity | Firmware | MDTS | I/O queues used | Tested |
|-----------------------|----------|----------|------|-----------------|--------|
| Samsung 980 PRO       | 1 TB     | 5B2QGXA7 | 512 KB | 1 | `zcu106_hpc0` (Gen3 x4), `vck190_fmcp1` (Gen4 x4): single drive and RAID0 pair, recording, playback, `nvverify` on the board and on a PC |
| Sabrent Rocket 2230 (SB-2130-1TB) | 1 TB | R21B47.1 | 256 KB | 1 | `uzev` (Gen3 x4), `zcu106_hpc0` (Gen3 x4), `vck190_fmcp1` (Gen4 x4): single drive and RAID0 pair, recording, playback, `nvverify` |

The Samsung 950 PRO 256GB and Samsung 970 EVO 250GB, used for the
[fpga-drive-recorder](https://recorder.fpgadrive.com) benchmarks, have not been tested with
this design.

The measured rates are on the [Benchmarks](benchmarks) page.

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
  when they get hot. Give the SSDs airflow, or a heatsink, for long recordings. (`nvme
  smart-log` needs the stock driver; see [Kernel driver](driver.md#using-the-stock-nvme-driver-reference-tests).)

Drives designed for sustained writes (SLC or MLC flash, enterprise and industrial drives,
or simply larger capacities with a bigger cache) give higher sustained rates.

You can help us maintain this list by communicating [your experiences] to us or by
contributing to the documentation on our [Github repo].

[your experiences]: https://opsero.com/contact-us
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[Github repo]: https://github.com/fpgadeveloper/fpga-drive-nvme-offload
