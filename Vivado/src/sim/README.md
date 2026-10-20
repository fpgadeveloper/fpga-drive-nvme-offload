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
| `tb_nvrec_wr` | ring writer: burst rules (4 KB, INCR), chunk data, ring wrap and flow control, LENGTH, STOP with padding (512 B and 4 KB LBAs), abort |
| `tb_nvrec_core` | whole `nvrec_core` with a Host Accelerator + SSD model: SQE fields for 1- and 2-member stripes, out-of-order completions with in-order slot release, injector arbitration, playback into `fdrec_check`, error / unexpected CQEs, IRQs, a ring-full stress test, counter clear rules (issue and completion counters cleared together by `SOFT_RST`), `RUN_FIFO_HWM`, the `HA_DEAD` status/IRQ |
| `tb_nvrec_axil_guard` | the AXI-Lite timeout guard: pass-through to a live slave (data, strobes, SLVERR), a slave that stops answering (read completes after the timeout with all-ones / OKAY, later accesses answered at once, slave no longer driven), heartbeat-only detection |
| `tb_fdrec_tpg` | the reused fpga-drive-recorder test pattern generator (the checker is exercised by `tb_nvrec_core` test 3; its own testbench needs fdrec_core and stays in fpga-drive-recorder) |

Contract for a testbench:

* File `tb_<name>.sv` (or `.v`) whose top module is `tb_<name>`.
* It compiles together with every file in `../hdl/` (XPM macros come from Vivado's
  precompiled `xpm` library).
* It checks its own results, prints a line containing `PASS` when everything is
  correct or a line containing `FAIL` (plus the reason) on any error, then calls
  `$finish`. It must always terminate (use a watchdog that prints `FAIL` on timeout).

A testbench passes only if its output contains `PASS` and no `FAIL`. `sim.tcl` exits
with status 1 if any testbench fails. Work files and logs go to `Vivado/sim/<tb>/`
(gitignored).
