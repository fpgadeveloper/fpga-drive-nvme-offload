# Revision History

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
