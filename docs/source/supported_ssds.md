# Supported SSDs

## Compatibility

The [FPGA Drive FMC Gen4] and [M.2 M-key Stack FMC] support M.2 M-key NVMe SSDs of PCIe
Gen1 to Gen4. An SSD that supports a higher PCIe generation than the design links at the
design's speed (Gen3 on the Zynq UltraScale+ targets, Gen4 on the VCK190). The WD_BLACK
SN8100, a PCIe Gen5 drive, links at Gen4 x4 on the FPGA Drive FMC Gen4 on the VCK190 (`lspci`:
`Speed 16GT/s (downgraded)`), so every rate it reaches with this design is a Gen4 x4 rate, not
its Gen5 rating.

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
Rocket 2230 has an MDTS of 256 KB (256 KB chunks); the WD_BLACK SN8100 has an MDTS of 1 MB
(1 MB chunks, the largest the apps use by default: the 1 GB split ring is 1024 × 1 MB).

## SSDs tested with this design

| SSD (brand and model) | Capacity | Firmware | MDTS | I/O queues used | Tested in this revision |
|-----------------------|----------|----------|------|-----------------|--------|
| Samsung 980 PRO       | 1 TB     | 5B2QGXA7 | 512 KB | 1 | `vck190_fmcp1` (Gen4 x4) and `zcu106_hpc0` (Gen3 x4), FPGA Drive FMC Gen4: single drive and RAID0 pair, recording, playback, `nvverify` |
| Sabrent Rocket 2230 (SB-2130-1TB) | 1 TB | R21B47.1 | 256 KB | 1 | `vck190_fmcp1` (Gen4 x4) and `zcu106_hpc0` (Gen3 x4), M.2 M-key Stack FMC: single drive and RAID0 pair, recording, playback, `nvverify` |
| WD_BLACK SN8100 HS 1000GB (PCIe Gen5) | 1 TB | 830ZRR0A | 1 MB | 1 | `vck190_fmcp1` (Gen4 x4: a Gen5 drive at the Root Ports' Gen4), FPGA Drive FMC Gen4: single drive and RAID0 pair, recording, playback, `nvverify` |

The Samsung 950 PRO 256GB and Samsung 970 EVO 250GB, used for the
[fpga-drive-recorder](https://recorder.fpgadrive.com) benchmarks, have not been tested with
this design.

The measured rates are on the [Benchmarks](benchmarks) page. The 980 PRO and the Sabrent came
up with NVMe APST disabled; the driver switches it off on every drive in any case (module
parameter `apst`, see [Kernel driver](driver.md#power-states-apst-and-temperature)). The
SN8100 grants 254 I/O queues; the design uses one, as with the other drives.

### Observations with the tested drives

* **Both pairs record at their drives' write rate on `vck190_fmcp1`.** In its SLC cache one
  980 PRO writes ~4.95 GB/s on Gen4 x4 and one Sabrent ~4.0-4.2 GB/s, so the 980 PRO pair
  records 10 000 MB/s over 32 GB and the Sabrent pair 8250 MB/s, both with the ring's help. In
  playback the Sabrent pair is the limit too (9250 MB/s, 2 × ~4.63 GB/s read, at MaxPayload 128
  or 256), the 980 PRO pair is not (11 000 MB/s, its commands complete in 0.2 ms). One drive
  plays back 6250 MB/s (980 PRO, MaxPayload 128) or 4500 MB/s (Sabrent). Past the cache both
  pairs hold 3250 MB/s over 350 GiB.
* **Two WD_BLACK SN8100 on `vck190_fmcp1` are bound by their Gen4 x4 links.** Each drive
  writes ~6.75 GB/s and reads ~7.16 GB/s through its link, so the pair records 13 750 MB/s over
  32 GB (with the whole 1 GB ring's help; 12 500 MB/s at MaxPayload 128) and one drive
  6750 MB/s. With the default whole-chunk stripes the pair plays back 11 000 MB/s, the limit of
  the memory being read, not of the drives; **with `--stripe 4` it plays back 14 250 MB/s**, its
  links' read rate (2 × 7.16 GB/s). One drive plays back 7000 MB/s. The SLC cache of an empty
  drive holds ~340 GB, so the pair records the first 683.7 GB (~51 s) at 13 500 MB/s; past the
  cache it holds 2000 MB/s over 800 GiB, with a thin margin (see
  [The SLC cache](benchmarks.md#the-slc-cache)). The drives stayed at or below 42 °C (see
  [Benchmarks](benchmarks.md#stripe-whole-chunk-4-kb-or-64-kb)).
* **On the Gen3 x4 slots of `zcu106_hpc0`** one 980 PRO writes ~3.04 GB/s and one Sabrent
  2.76-2.78 GB/s; both read ~3.2 GB/s (at MaxPayload 128); at 256 bytes one 980 PRO records
  3250 MB/s and plays back 3500 MB/s. At the default MaxPayload of 256 bytes the 980 PRO pair
  plays back 5750 MB/s and the Sabrent pair 6000 MB/s, at 128 bytes both 5250 MB/s; both record
  6000 MB/s, the split ring's writer being the limit (the Sabrent pair records 5250 MB/s at
  128 bytes, its drives' rate). Past the cache the 980 PRO pair holds 3500 MB/s, the Sabrent
  pair 3250 MB/s.
* **One Sabrent Rocket writes slower with this design than with fpga-drive-recorder**: in its
  SLC cache 2.76-2.78 against 2.88-2.95 GB/s at the first failing step on `zcu106_hpc0` (Gen3
  x4), and 4.21-4.23 against 4.57-4.65 GB/s on `vck190_fmcp1` (Gen4 x4). This is an open
  observation: the cause, perhaps the drive's response to 256 KB commands with PRP lists on a
  single hardware queue, has not been isolated, nor separated from the drives' wear (more than
  14 TB had been written to the pair by the end of the measurements); see
  [Comparison](comparison).
* **MaxPayload 256 bytes helps on the Gen3 x4 slots**, which is why both split-ring boards set
  it at boot. On `zcu106_hpc0` the Sabrent pair records and plays back 6000 MB/s at 256 bytes
  against 5250 MB/s at 128, the 980 PRO pair plays back 5750 MB/s against 5250 MB/s, and one
  980 PRO records 3250 and plays back 3500 MB/s against 3000 / 3000 MB/s (see
  [Benchmarks](benchmarks.md#maxpayload-256)). On `vck190_fmcp1` it changes nothing for the
  Sabrent pair, and lifts the SN8100 pair's recording from 12 500 to 13 750 MB/s (its links
  carry more data per packet).
* **The ring size needed depends on the pair.** The Sabrent pair on `vck190_fmcp1` needs the
  whole 1 GB default ring at 8250 MB/s (512 MB holds 8000 MB/s), the SN8100 pair more than
  512 MB at 13 750 MB/s; the 980 PRO pair on
  `vck190_fmcp1` and the Sabrent pair on `zcu106_hpc0` need at least 512 MB at their tops; the
  980 PRO pair on `zcu106_hpc0` hardly uses the ring in its cache but used 567 MB past it. A
  256 MB ring dropped data with every pair but that one; keep the default (see
  [Benchmarks](benchmarks.md#ring-size)).
* **The SLC cache needs idle time to recover.** A 40 GiB recording at 8000 MB/s started
  3 minutes after a 350 GiB recording dropped with the Sabrent pair (it wrote only 7.45 GB/s);
  9 minutes later it passed. Two SN8100 had their whole cache back 60 s after a deallocate
  (`blkdiscard`), ~222 of ~340 GB per drive after 10 s.
* **The Sabrents run warm.** They reached 65 °C in the 350 GiB RAID0 recordings on both boards,
  close to the benchmark suite's 70 °C guard; the 980 PROs at most 51 °C.

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
  (`nvsetup-raid0.sh --trim` deallocates the whole drives before it formats them). Before a
  long recording, deallocate the drives and leave them idle: two SN8100 had their whole cache
  back 60 s after a deallocate, while a Sabrent pair still fell short 3 minutes after a
  350 GiB recording (see [Observations](#observations-with-the-tested-drives)).
* **RAID0.** Two SSDs striped as RAID0 add up their rates, but every chunk of the stripe
  goes to both drives in turn, so the array is limited by the slower drive: twice the
  slower drive's sustained rate. Use two identical SSDs (their MDTS also sets the chunk).
* **Heat.** Long recordings at high rates heat the SSD controller, and many SSDs throttle
  when they get hot. Give the SSDs airflow, or a heatsink, for long recordings. The driver
  reads each SSD's composite temperature and its warning and critical thresholds
  (`/sys/block/nvrecXn1/nvrec/temperature`), and `nvbench-suite.sh` stops a run above 70 °C;
  in the benchmarks the drives stayed at or below 65 °C. (The full `nvme smart-log` needs the
  stock driver; see [Kernel driver](driver.md#using-the-stock-nvme-driver-reference-tests).)

Drives designed for sustained writes (SLC or MLC flash, enterprise and industrial drives,
or simply larger capacities with a bigger cache) give higher sustained rates.

You can help us maintain this list by communicating [your experiences] to us or by
contributing to the documentation on our [Github repo].

[your experiences]: https://opsero.com/contact-us
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[Github repo]: https://github.com/fpgadeveloper/fpga-drive-nvme-offload
