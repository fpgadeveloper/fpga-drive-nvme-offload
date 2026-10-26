# Testbenches

Self-checking testbenches for the RTL in `../hdl/`, run in the Vivado simulator (xsim)
by `Vivado/scripts/sim.tcl` without a Vivado project:

```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs <name>   # tb_<name>.sv
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all      # every tb_*.sv
```

The script also runs under a plain `tclsh` once Vivado's `settings64.sh` has been
sourced: `tclsh scripts/sim.tcl all`.

Testbenches:

| Testbench | What it checks |
|---|---|
| `tb_nvrec_wr` | ring writer: burst rules (4 KB, INCR), chunk data, ring wrap and flow control, LENGTH, STOP with padding (512 B and 4 KB LBAs), abort; with two ring ports (different B latencies, random stalls and pauses) the same tests for a single ring, the split ring with 4 KB and 64 KB stripes and memory 1 only |
| `tb_nvrec_core` | whole `nvrec_core` with a Host Accelerator + SSD model: SQE fields for 1- and 2-member stripes, out-of-order completions with in-order slot release, injector arbitration, playback into `fdrec_check`, error / unexpected CQEs, IRQs, a ring-full stress test, counter clear rules (issue and completion counters cleared together by `SOFT_RST`), `RUN_FIFO_HWM`, the `HA_DEAD` status/IRQ, `CONFIG.DRY` fabric-only record (no SSD command, slots released as filled) and ring-resident playback, `BEAT_BYTES` / `BYTES` units; register map 1.3 with a two-port memory model (different latencies, random stalls and pauses): split record / playback / DRY ring-resident runs at `RING_STRIPE_SHIFT` 12, 16 and chunk with an odd `START_CHUNK`, an odd ring and a 2-page last chunk (PRP2 in the other memory), `CONFIG.MEM1`, the per-port stall / wait counters, `MEM1_READY`; chunk-sized stripes with NoC-like ports (read latencies 0.8 / 1.0 us, a small read-response buffer per port) at a full-rate sink: reader waits and writer stalls booked to chunk boundaries, no egress starvation (A/B against the reader without skid FIFOs with `-generic_top RD_SKID_DEPTH=0`); and with `N_RING_PORTS` 1 that `SPLIT` / `MEM1` are ignored |
| `tb_nvrec_axil_guard` | the AXI-Lite timeout guard: pass-through to a live slave (data, strobes, SLVERR), a slave that stops answering (read completes after the timeout with all-ones / OKAY, later accesses answered at once, slave no longer driven), heartbeat-only detection |
| `tb_fdrec_tpg` | the reused fpga-drive-recorder test pattern generator (the checker is exercised by `tb_nvrec_core` tests 3 and 8; its own testbench needs fdrec_core and stays in fpga-drive-recorder) |

`tb_fdrec_tpg`, `tb_nvrec_wr` and `tb_nvrec_core` run once per datapath width (128, 256
and 512 bits): a line `// sim_runs: DATA_WIDTH=128 DATA_WIDTH=256 DATA_WIDTH=512` in the
testbench makes `sim.tcl` elaborate it with each top-level parameter override and report
each run separately (`tb_nvrec_core[DATA_WIDTH=512]`). `tb_nvrec_wr` and `tb_nvrec_core`
add a fourth run with one ring port (`DATA_WIDTH=256,N_RING_PORTS=1`).

Contract for a testbench:

* File `tb_<name>.sv` (or `.v`) whose top module is `tb_<name>`.
* It compiles together with every file in `../hdl/` (XPM macros come from Vivado's
  precompiled `xpm` library).
* It checks its own results, prints a line containing `PASS` when everything is
  correct or a line containing `FAIL` (plus the reason) on any error, then calls
  `$finish`. It must always terminate (use a watchdog that prints `FAIL` on timeout).

A testbench passes only if its output contains `PASS` and no `FAIL`. `sim.tcl` exits
with status 1 if any testbench fails. Work files and logs go to `Vivado/sim/<tb>/`
(`Vivado/sim/<tb>_<run>/` for the per-width runs; gitignored).
