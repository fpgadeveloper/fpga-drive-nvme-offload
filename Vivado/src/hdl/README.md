# Custom RTL (module references)

Verilog sources for the recorder's custom logic. The `fdrec_*` modules are reused unchanged
from [fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder) (test
pattern generator, checker, ingest and egress FIFOs); the `nvrec_*` modules are the NVMe
offload engine of this design.

| Module | Purpose |
|---|---|
| `nvrec_core` | top of the block-design module reference: register decode, run control, clock-domain crossings, instantiates everything below |
| `nvrec_regs` | AXI4-Lite slave front end of the register block |
| `nvrec_wr` | ring writer: ingest FIFO -> AXI4 write bursts into the ring of chunks (one or two ring ports, write responses retired in issue order) |
| `nvrec_ring_addr` | ring address function (register map 1.3): single ring, memory 1 only, or the split ring striped over two memories; 2-stage pipeline shared by `nvrec_wr`, `nvrec_rd` and `nvrec_cmd` (PRP1 / PRP2) |
| `nvrec_cmd` | NVMe command builder (Write / Read SQEs) + submission arbiter (builder / injector), credits |
| `nvrec_cq` | completion router: slot release in ring order, statistics, latency histogram |
| `nvrec_rd` | ring reader (playback): AXI4 read bursts -> egress FIFO (one or two ring ports, R data taken from the port of the oldest burst) |
| `nvrec_inj` | CPU command injector (software SQEs onto the hardware SQ, CQE FIFO) |
| `nvrec_dbmon` | doorbell monitor (debug log of the Host Accelerator's doorbell writes) |
| `nvrec_axil_guard` | separate module reference (`nvmeha_guard`) in front of the Host Accelerator's `S_AXI_LITE`: AXI-Lite timeout guard, so an expired evaluation core answers with all-ones instead of hanging the CPU; its `dead` output feeds `nvrec_core` `STATE.HA_DEAD` |
| `fdrec_tpg`, `fdrec_check`, `fdrec_ingest`, `fdrec_egress` | from fpga-drive-recorder (`DATA_WIDTH` version), width guards extended to 512 bits |

Datapath width: `nvrec_core`, `nvrec_wr`, `nvrec_rd` and the `fdrec_*` modules take a
`DATA_WIDTH` parameter of 128, 256 or 512 bits (one beat = `DATA_WIDTH / 8` bytes,
register `BEAT_BYTES` at 0x0BC). The block designs set it from the target's
`data_width` in `config/data.json` (default 256; see `Vivado/src/bd/nvrec_params.tcl`),
with the ingest / egress FIFOs sized by bytes (256 KB / 128 KB) at every width.

Ring ports (register map 1.3): `nvrec_core` has a second ring AXI4 master `m_axi1` and a
parameter `N_RING_PORTS` (1 or 2). With 2 the ring can be split over two memories
(`CONFIG.SPLIT`, `RING_BASE1`, `RING_STRIPE_SHIFT`); with 1 `m_axi1` stays idle and the
engine is cycle-for-cycle the 1.2 engine. The block designs set it from the target's
`ring_mem` in `config/data.json` (`nvrec_params.tcl`).

* `Vivado/scripts/build.tcl` adds every `*.v` and `*.sv` file in this folder to the
  project's `sources_1` fileset (and `*.vh` / `*.svh` as include headers) *before*
  the block design script runs, so the block design can instantiate the modules with
  `create_bd_cell -type module -reference <module_name>`.
* Keep the top module of each module reference in a Verilog (`.v`) file.
* One module per file, file name = module name.
* Testbenches are in `../sim/` (see `../sim/README.md`).
* The register map implemented here is defined in `include/nvrec_regs.h` and
  documented in `docs/source/register_map.md`; keep all three in sync.
