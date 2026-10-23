# Revision History

## v1.1 (2025.2), October 2026

The source/sink datapath is widened so that rates above the 3.2 GB/s of the first release
can be recorded and played back, and the improvements made to
[fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder) since this
design was derived from it are applied where they fit.

* **Wider datapath, register map 1.2.** `nvrec_core`, the ring writer and reader, the test
  pattern generator and the checker take a `DATA_WIDTH` parameter (128, 256 or 512 bits;
  `"data_width"` of a target in `config/data.json`, default 256), with `src_clk` and `dp_clk`
  at 250 MHz. The Zynq UltraScale+ targets (`zcu106_hpc0`, `uzev`) are built at 256 bits:
  8 GB/s from the source and into the sink; `vck190_fmcp1` at 512 bits: 16 GB/s (3.2 GB/s
  before, at 128 bits). The test pattern is defined on 16-byte words, so recordings
  are byte-identical at every width. New register `BEAT_BYTES` (0x0BC), `VERSION`
  0x0001_0002; every beat counter and FIFO level is in fabric beats.
* **Fabric-only mode** (`CONFIG.DRY`): a record run fills the ring and releases each slot at
  once, a playback streams the ring, with no NVMe command — `nvrec --no-write` and
  `nvplay --ring-only` measure the fabric and DDR path without any SSD.
* **Bigger FIFOs and ring.** Ingest FIFO 256 KB (8192 beats of 32 bytes; 4096 of 64 bytes on
  `vck190_fmcp1`), egress FIFO 4096 beats: 128 KB on the 256-bit targets, 256 KB on
  `vck190_fmcp1` (at 512 bits the ring reader keeps up to 128 KB of reads in flight). The
  hardware slot table has 2048 entries (1024 before), and the default ring is 512 MB
  (512 MB / chunk slots, 256 to 2048): 64 ms of buffering at 8 GB/s.
* **Memory paths.** Zynq UltraScale+: the ring port `S_AXI_HP2_FPD` (128 bits) runs on its own
  clock, `pl_clk3` (333 MHz requested, 322.19 MHz on the ZCU106): 5.16 GB/s peak instead of
  4.0. Versal: the ring's NoC port is 512 bits wide with QoS 14 000 MB/s per direction, and
  each of the two QDMA bridges (PCIe Root Ports) has its own NoC port (S08 and S10, 7000 MB/s
  per direction each) instead of the one port (S08) they shared.
* **Driver 1.1.** Reads the beat size from the hardware (16, 32 or 64 bytes; a register map
  1.1 bitstream still works, with 16), fabric-only runs (`NVREC_START_DRY`), API 3 (ring of
  up to 2048 slots). NVMe APST is switched off on every SSD at probe (module parameter
  `apst`; a drive waking from a deep idle state stalled the start of fast recordings in
  fpga-drive-recorder's benchmarks), and each SSD's composite temperature is readable in
  sysfs (SMART log), with its warning and critical thresholds. sysfs `beat_bytes`,
  `egr_fifo_depth`.
* **Apps 1.1.** `nvrec --no-write`, `nvplay --ring-only`; `nvverify` checks every 16-byte
  word and reads nvrec and fdrec recordings of any beat size (fpga-drive-recorder 1.3 files
  have 32-byte beats), comparing gaps with the drop count in words; `nvplay` compares the
  checker's gaps with the recording's drop count the same way. `nvbench.sh` sweeps 500 MB/s
  steps to `src_clk × beat_bytes` (it used to truncate the 3.2 GB/s maximum to 3199 MB/s and
  never sweep it). `nvbench-suite.sh` 2: the source maximum from the beat size,
  `--stop-after`, `--confirm-fail`, `--tag`, `--qd`, `--source-fresh`, `fabric` and
  `fabricplay` commands, and a drive temperature guard (a run is stopped above 70 °C).
  `RESULT` lines carry `beat_bytes`.
* **Build runner.** `build.py` is the canonical runner whose Yocto freshness stamp hashes
  every repository source the recipes fetch (`sw/` and `include/`), so a change to the
  shared headers alone rebuilds the image.
* `uzev` is built (XSA and image) but not tested on hardware in this revision.
* **Measured results** (see [Benchmarks](benchmarks) and [Comparison](comparison)), with two
  Samsung 980 PRO 1TB and two Sabrent Rocket 2230 1TB on each tested board. Without an SSD the
  datapath records and plays back 5000 MB/s on `zcu106_hpc0` (the HP port's limit) and
  14 500 / 13 750 MB/s on the 512-bit `vck190_fmcp1`. On `zcu106_hpc0` both pairs record RAID0
  at 5000 MB/s over 32 GB and play back 4250 MB/s (980 PRO) or 4500 MB/s (Sabrent); past the SLC cache the 980 PROs record
  3500 MB/s (RAID0, 350 GiB) and 1750 MB/s (one drive, 200 GiB), the Sabrents 3250 and
  1500 MB/s; one drive records 3000 MB/s (980 PRO) or 2750 MB/s (Sabrent) and plays back
  3000 MB/s. On `vck190_fmcp1` the 980 PRO pair records RAID0 at 9250 MB/s and plays back
  8750 MB/s, the limit of the single DDR4 controller; the Sabrent pair records 7750 MB/s and
  plays back 7500 MB/s sustained (8750 MB/s for a 10 GiB file); one 980 PRO records 5000 MB/s and
  plays back 6000 MB/s (6750 MB/s at MaxPayload 256 bytes). `nvrec` and `nvplay` use 1-5 % of
  one core at these rates. Playback tops are confirmed with 40 GiB files. Both drive types came
  up with APST disabled, so no APST A/B was needed; a 256 MB ring was as clean as the 512 MB
  default at the RAID0 top with the 980 PRO pairs, but dropped with the Sabrent pair on both
  boards, and a 980 PRO RAID0 recording past the cache used 287 MB of the ring.
  MaxPayload 256 bytes (`setpci`) lifts one drive's playback (and a Gen3 x4 drive's recording)
  and makes RAID0 playback worse on `zcu106_hpc0`. `--qd 63` helps neither pair on
  `vck190_fmcp1` (no change at the 980 PRO's 512 KB commands, one step less at the Sabrent's
  256 KB commands); the default stays 32. The figures of
  the previous revision, capped by its 3.2 GB/s source, are in the git history.
* **Timing and resources.** Every target meets timing. `zcu106_hpc0` (256 bits, HP2 at
  322.19 MHz): WNS +0.386 ns, 29.9 % of the LUTs, 55 % of the block RAM; `uzev` (HP2 at
  327.77 MHz): WNS +0.096 ns, the same resources (see
  [Architecture](architecture.md#resource-usage)); `vck190_fmcp1` (512 bits, egress FIFO
  256 KB): WNS +0.036 ns, 91 240 LUTs (10.1 %), 132 068 registers (7.3 %), 205 of 967 block
  RAMs (21.2 %), 24 UltraRAMs; the NoC compiler meets every bandwidth request (the ring's port
  14 000 MB/s, each Root Port's port 7000 MB/s per direction).

## v1.0 (2025.2), October 2026

Initial release of the FPGA Drive NVMe Offload Recorder, built with Vivado / Vitis 2025.2
and the Yocto / EDF 2025.2 flow (no PetaLinux flow, no standalone application). Targets:
`zcu106_hpc0` (ZCU106, HPC0), `uzev` (UltraZed-EV Carrier, HPC) and `vck190_fmcp1`
(VCK190, FMCP1), all three tested on hardware, on the PCIe Root Port platform of
[fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie) and with the
data source and sink of [fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder).

The design was developed in phases:

* **Feasibility on `zcu106_hpc0`.** `nvrec_core` (ingest FIFO, ring writer, NVMe command
  builder with the md RAID0 stripe, completion router with in-order slot release and
  latency statistics, ring reader, egress FIFO, CPU command injector, doorbell monitor,
  register map 1.0) and the AMD NVMe Host Accelerator (`nvmeha` v1.0) with one hardware
  queue per SSD, so that drives granting a single I/O queue work; self-checking
  testbenches with a Host Accelerator + SSD model.
* **Linux.** The `nvrec` kernel driver (owns the SSDs instead of the stock `nvme` driver:
  admin bring-up, I/O queues in the Host Accelerator, block devices `/dev/nvrecXn1` through
  the command injector, control device `/dev/nvrec` with a CMA ring), and the `nvrec`,
  `nvplay`, `nvverify`, `nvbench.sh`, `nvsetup-raid0.sh` and `nvregs` tools in the
  `meta-nvrec` Yocto layer; exFAT recordings in one contiguous preallocated file, md
  RAID0-compatible striping over two SSDs.
* **Hardware bring-up on `zcu106_hpc0`** with two Samsung 980 PRO: single drive and RAID0
  recording up to the source's 3.2 GB/s, playback, verification on the board and on a PC.
  Chunk = 1 MB or the drive's MDTS, whichever is smaller; playback prefill before the sink
  is enabled. The evaluation-license timeout of the Host Accelerator was measured
  (183-184 minutes after the bitstream load).
* **Register map 1.1.** AXI-Lite timeout guard (`nvmeha_guard`) in front of the Host
  Accelerator, so that an expired evaluation core is reported (`STATE.HA_DEAD`, exit
  code 5) instead of hanging the system; `RUN_FIFO_HWM`; issue counters cleared at
  `SOFT_RST` with the completion counters. Driver: a chunk above the MDTS and an SSD BAR0
  at or above 4 GB are refused.
* **Ports.** `uzev` (same block design as `zcu106_hpc0`) and `vck190_fmcp1` (Versal, QDMA
  Root Ports, VADJ enabled by U-Boot), with their Yocto BSPs.
* **Ring and rate defaults.** The recording ring defaults to 256 MB whatever the chunk
  (256 MB / chunk slots, 256 to 1024: 1024 × 256 KB, 512 × 512 KB, 256 × 1 MB); the apps
  check the CMA pool before a run and report the ring in their `RESULT` lines (`ring_slots`,
  `ring_bytes`). The benchmark suite caps every rate at the test pattern generator's maximum
  (3200 MB/s at 200 MHz).
* **Hardware testing** of all three targets, single drive and RAID0, recording, playback and
  verification: `zcu106_hpc0` with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230
  1TB, `vck190_fmcp1` with the same two pairs, `uzev` with the two Sabrent Rocket 2230.
* **Documentation** (this site) and the benchmarks, measured with the method of
  fpga-drive-recorder so that the two designs can be compared.
