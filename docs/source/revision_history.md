# Revision History

## v1.2 (2025.2), October 2026

One ring per SSD in two memories: on `zcu106_hpc0` and `vck190_fmcp1` the recording ring is
split over PS DDR and a second memory that the CPU does not use (the PL DDR4 on the ZCU106, the
LPDDR4 on the VCK190), in whole-chunk stripes, so that each SSD of a RAID0 pair writes and
reads one memory and each memory carries half of the traffic. Two Samsung 980 PRO on
`vck190_fmcp1` now record 10 000 MB/s (their write rate) and play back 11 000 MB/s sustained,
two Sabrent Rocket 2230 there 8250 and 9250 MB/s; on `zcu106_hpc0` both pairs record 6000 MB/s
and play back 5750-6000 MB/s at the default MaxPayload of 256 bytes (5250 MB/s at 128).

* **Register map 1.3: a second ring port.** `nvrec_core` has a second ring AXI master
  (`m_axi1`; `RING_PORTS` = 2, build parameter `N_RING_PORTS`), `RING_BASE1`, `CONFIG.SPLIT`
  (bit 3) and `CONFIG.MEM1` (bit 6, a single ring in memory 1), the run-time stripe
  `RING_STRIPE_SHIFT` (4 KB to one chunk), `STATE.MEM1_READY` (bit 13), and per-port counters
  `WR_PORT_STALL0/1` and `RD_PORT_WAIT0/1` (32-bit `dp_clk` cycles, saturating at about 17 s).
  The ring writer keeps one write stream, in issue order, over both ports and retires their
  write responses in order; PRP1 and PRP2 follow the same address function. The slot table
  has 4096 entries (`SLOT_W` 12), so 256 KB chunks also reach a 1 GB ring. `VERSION`
  0x0001_0003.
* **Ring reader skid FIFOs.** Each ring port's read data lands in a skid FIFO of 512 beats
  (32 KB at 512 bits, 16 KB at 256 bits), so the reader keeps fetching from one memory while
  the stream drains the other: a switch of memory at a chunk boundary costs little.
* **Memory paths.** `zcu106_hpc0`: ring B in the board's soldered 64-bit PL DDR4-2400 through
  a DDR4 controller in the PL (`ddr4_0`, 512 bits at 300 MHz) at `0x20_0000_0000`; ring A on
  `S_AXI_HP2_FPD` as before; both PCIe Root Ports reach both memories. `vck190_fmcp1`: ring B
  in the on-board LPDDR4 behind one LPDDR4 controller (a second NoC instance, `noc_lpddr4`, its
  two x32 channels interleaved every 256 bytes) at `0x600_0000_0000`. One controller, because
  interleaving ring B over the board's two LPDDR4 controllers every 128 bytes capped its writes
  at 1.8-2.0 GB/s per NoC master (the NoC orders writes strictly). NoC QoS requests: 14 000 MB/s
  per direction for each ring port, 7000 MB/s to the DDR4 and 4000 MB/s to the LPDDR4 for each
  Root Port; `report_noc_qos` meets them all. `uzev` keeps one ring port (its PL DDR4 is
  16 bits wide).
* **Timing and resources.** Every target meets timing: `zcu106_hpc0` WNS +0.040 ns, 115 240
  LUTs (50.0 %), 207 block RAMs (66.3 %; two pblocks keep the DDR4 controller's write-data
  registers next to their banks); `uzev` WNS +0.071 ns, 79 470 LUTs (34.5 %), 173.5 block RAMs;
  `vck190_fmcp1` WNS +0.052 ns, 100 036 LUTs (11.1 %), 222 block RAMs (23.0 %), 24 UltraRAMs
  (see [Architecture](architecture.md#resource-usage)). On the ZCU106 the PL DDR4 controller and
  its I/O banks raise the steady VCCAUX current from about 0.145 A to 0.54-0.55 A.
* **Driver 1.2 (ioctl API 4).** Split ring: ring A (the PS DDR part) from CMA, ring B at the
  start of a 1 GB `no-map` region of the second memory that the device tree hands to the
  driver (`memory-region`); layouts `single`, `split` (stripes of 4 KB … one chunk, run-time
  `RING_STRIPE_SHIFT`) and `mem1`; the PRP list of every slot follows the register map 1.3
  address function page by page; a split or `mem1` ring is refused while the second memory
  is not ready (`STATE.MEM1_READY`). Module parameters `ring_split` (`auto` / 0 / 1: the
  default layout; `auto` splits RAID0 and fabric-only runs, not single-SSD runs, which play
  back ~13 % slower on a split ring) and `stripe_kb` (`auto`, `chunk` or KB; default: the
  board's device tree, `opsero,ring-stripe-chunk` = whole chunks on `zcu106_hpc0` and
  `vck190_fmcp1`, measured best on both). Slot table up to
  4096 entries; a split ring up to 2 GB (1 GB per memory).
  Ring-port wait counters (`WR_PORT_STALL`, `RD_PORT_WAIT`) in the statistics and sysfs;
  sysfs `ring_ports`, `ring1_base`, `ring1_bytes`, `mem1_ready`, `ring_split`,
  `ring_stripe_kb`, `ring_stripe_default`, `max_slots`. A host unit test (`sw/nvrec-driver/tests`) checks the
  address function and the PRP lists against a model of the hardware.
* **Apps 1.2.** `nvrec` / `nvplay` `--ring auto|single|split|mem1` and `--stripe <KB>|chunk`;
  the default ring is 1 GB when split (512 MB in each memory) and 512 MB otherwise; only the
  PS DDR part counts against CMA. The summaries and `RESULT` lines give the layout (`ring`,
  `stripe_kb`, `ring_mem1_bytes`) and, with two ring ports, the time the ring writer and
  reader waited for each memory (`wr_port_stall_ms`, `rd_port_wait_ms`). `nvbench-suite.sh`
  (version 3) passes `--ring` / `--stripe` to every run, keeps them in the run ids
  (`/ring=split/stripe=4K`) and runs comma lists of them as an A/B in one call. `nvregs`
  shows the register map 1.3 registers. The file format and `nvverify` are unchanged.
* **PCIe MaxPayload 256 on `zcu106_hpc0` and `vck190_fmcp1` by default.** `nvrec-mps` (apps)
  shows and sets the MaxPayload of the SSDs and their root ports (`setpci`, MaxReadReq
  untouched); `nvrec-pcie-mps.service` sets the board's value at boot (`NVREC_MPS`: 256 on
  `zcu106_hpc0` and `vck190_fmcp1`, 128 on `uzev`). The RAID0 playback gains without PCIe
  errors: 11 000 instead of 10 750 MB/s sustained with two Samsung 980 PRO on `vck190_fmcp1`;
  on `zcu106_hpc0` 6000 instead of 5250 MB/s with two Sabrent Rocket 2230 (which also record
  6000 instead of 5250 MB/s) and 5750 instead of 5250 MB/s with two 980 PRO, whose single
  drive records 3250 and plays back 3500 MB/s instead of 3000 / 3000 MB/s. Release 1.1 had
  found RAID0 playback worse at 256 bytes on `zcu106_hpc0`, with its single ring, where the
  SSDs' writes and the ring reader shared one DDR controller; the split ring changed that.
  Every `RESULT` line and suite result records the `mps` in force.
* **Even slot count for whole-chunk stripes.** A split ring with whole-chunk stripes always
  has an even number of slots, so each SSD writes and reads one memory only (member *m* ↔
  memory *m* XOR the parity of the first chunk). The apps size every ring in whole 2 MB, which
  gives an even count below 2 MB chunks; the driver rounds an odd request down by one (2 MB and
  4 MB chunks, or a program's own `SET_RING`). `nvrec` and `nvplay` print a note when the slots
  used differ from `--buffers`.
* **Yocto.** `nvrec-mod` and `nvrec-apps` 1.2; the 1 GB carve-out and the default stripe in
  the device trees of `zcu106_hpc0` (PL DDR4, `0x20_0000_0000`) and `vck190_fmcp1` (LPDDR4,
  `0x600_0000_0000`); `cma=` unchanged (1536M); `nvrec-pcie-mps.service` enabled with
  `NVREC_MPS=256` on `zcu106_hpc0` and `vck190_fmcp1`. `uzev` keeps a single ring and
  MaxPayload 128.
* `uzev` is built (XSA and image) but not tested on hardware in this revision.
* **Measured results** (see [Benchmarks](benchmarks) and [Comparison](comparison)), with two
  Samsung 980 PRO 1TB and two Sabrent Rocket 2230 1TB on each tested board (Release 1.1 in
  brackets). `vck190_fmcp1`: the 980 PRO pair records RAID0 at 10 000 MB/s over 32 GB (9250;
  the drives' write rate), 10 250 / 10 000 MB/s for 10 / 40 GB, and plays back 11 000 MB/s
  sustained at MaxPayload 256 (8750; 10 750 MB/s at 128); about 12 GB/s is not reached
  (11.84 GB/s at a 12 000 MB/s sink, short intermittent underflows at 11 000-11 750 MB/s in some
  runs; the limit is on the ring reader and memory side, not isolated). The Sabrent pair
  records 8250 MB/s (7750; with the 1 GB ring) and plays back 9250 MB/s (7500) at MaxPayload
  256 and 128 alike, its drives' rates; Release 1.1's short underflows above 7500 MB/s are
  gone. Without an SSD 14 750 / 15 000 MB/s (15 750 / 16 000 MB/s with 4 KB stripes).
  `zcu106_hpc0`, at the default MaxPayload of 256 bytes: the 980 PRO pair plays back 5750 MB/s
  (4250) and records 6000 MB/s (5000; the split ring's writer, at 128 bytes too); the
  Sabrent pair records and plays back 6000 MB/s (5000 / 4500); at 128 bytes both pairs play
  back 5250 MB/s and the Sabrent pair records 5250 MB/s; without an SSD 6000 /
  6250 MB/s (5000 / 5000, the HP port), limited by the in-order stream alternating between the
  HP port and the PL DDR4 port. Past the SLC cache every pair holds its 1.1 rate over 350 GiB
  (3250 MB/s; 3500 MB/s with the 980 PROs on `zcu106_hpc0`); one drive records / plays back as
  with 1.1: 980 PRO 5000 / 6250 MB/s on `vck190_fmcp1` and 3250 / 3500 MB/s at 256 bytes on
  `zcu106_hpc0` (3000 / 3000 at 128, Release 1.1's default), Sabrent 4000 / 4500 and
  2750 / 3000 MB/s (at 128 bytes on `zcu106_hpc0`). Whole-chunk stripes beat 4 KB stripes by 500 MB/s of playback with the 980 PROs on
  `vck190_fmcp1` (SSD command latency 0.2 against 1.7-1.85 ms), and with 512 KB chunks they are
  essential: with 4 KB stripes the 980 PRO pair on `zcu106_hpc0` plays back only ~3.8 GB/s. One
  SSD forced onto the split ring plays back far slower (one 980 PRO on `zcu106_hpc0`
  ~1.44 GB/s), so single-SSD runs stay on the single ring. MaxPayload 256 is clean (no AER) with
  both pairs on both boards. The ring size needed at the recording tops ranges from 41 MB to
  the whole 1 GB default (the Sabrent pair on `vck190_fmcp1`); a 256 MB ring drops with three of
  the four pairs. `nvrec` and `nvplay` use 2-6 % of one core. The Sabrents reached 65 °C in the
  350 GiB recordings.

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
