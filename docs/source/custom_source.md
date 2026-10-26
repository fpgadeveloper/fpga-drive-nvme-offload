# Replacing the test pattern generator with your own data source

The reference design records data from a test pattern generator (`fdrec_tpg`). For a real
application you replace it with your own ADC, sensor or processing logic. Everything you
need to change is inside one block design hierarchy, `user_data_source`. The rest of the
design (`nvrec_core`, the NVMe Host Accelerator, the driver and the apps) stays the same.
For the playback direction, see [Replacing the checker with your own data sink](custom_sink).

The insertion point, its pins and the stream contract are identical to those of
[fpga-drive-recorder](https://recorder.fpgadrive.com/en/latest/custom_source.html), so a
source written for one design drops into the other unchanged.

## The insertion point

The `user_data_source` hierarchy has these pins:

| Pin | Direction | Width | Description |
|---|---|---|---|
| `src_clk` | in | 1 | Source clock. PS `pl_clk2` (250 MHz) on Zynq UltraScale+, CIPS `pl2_ref_clk` (250 MHz) on Versal. |
| `src_resetn` | in | 1 | Active-low reset, synchronous to `src_clk` (from `rst_src_clk`). |
| `M_AXIS` | out | AXI4-Stream | `TDATA[255:0]` on the Zynq UltraScale+ targets, `TDATA[511:0]` on `vck190_fmcp1` (the datapath width, see [Data width](#data-width)), `TVALID`, `TREADY` (see below). No `TLAST`, `TKEEP` or `TUSER`. |
| `tpg_enable` | in | 1 | `TPG_CTRL.ENABLE`, already synchronised to `src_clk`. Optional. |
| `tpg_seq_rst` | in | 1 | `TPG_CTRL.SEQ_RST` pulse (also held high during a soft reset), synchronous to `src_clk`. Optional. |
| `tpg_rate_inc` | in | 32 | `TPG_RATE_INC`, synchronous to `src_clk`. Optional. |
| `tpg_seq_next` | out | 64 | Read back as `TPG_SEQ_NEXT` (the test pattern generator's next word number), sampled in the `src_clk` domain. Tie to 0 if unused. |

`M_AXIS` and all the `tpg_*` signals are in the `src_clk` domain. `nvrec_core` does every
clock-domain crossing, so your logic only has to deal with `src_clk`.

### The no-backpressure contract

The recorder assumes your source **cannot be stalled**, like an ADC:

* Drive `TVALID` high for one `src_clk` cycle for every beat (256 bits on the Zynq
  UltraScale+ targets, 512 bits on `vck190_fmcp1`) you produce.
* `TREADY` is always 1. You can leave it unconnected. Do not wait for it.
* If the ingest FIFO is full, `nvrec_core` drops the beat and counts it (`RUN_DROP_COUNT`
  while a recording runs). The data is never delayed and never corrupted. A beat is either
  recorded or counted as dropped. A recording is only valid if the drop count is 0, and
  `nvrec` exits with code 2 if it is not.
* Data is recorded byte-for-byte as it appears on `TDATA`, little-endian: `TDATA[7:0]` is the
  first byte of each beat (32 or 64 bytes) in the file.
* There is no framing on the source side. The ring writer cuts the stream into chunks
  itself, downstream of the drop point. If you need markers in the data (frame starts,
  timestamps, channel numbers), put them in `TDATA`.

## Clocking

You can use any clock for `src_clk`. At the top level of the block design, remove the
`src_clk` net's connection to the PS clock (`pl_clk2` on Zynq UltraScale+, `pl2_ref_clk` on
Versal) and connect your own clock (for example an ADC data clock, or the output of a
clocking wizard). Connect `rst_src_clk/slowest_sync_clk` to the same clock, so that
`src_resetn` stays synchronous to it. The same net also clocks `nvrec_core`'s source side
and the `user_data_sink` hierarchy (`snk_clk`): the playback sink always runs on `src_clk`.
Then set the `SRC_CLK_HZ` parameter of `nvrec_core_0` to the real frequency, so that
software can compute rates from it. The block design script sets it from the PS clock with:

```tcl
set_property -dict [list CONFIG.SRC_CLK_HZ $src_clk_hz ...] [get_bd_cells nvrec_core_0]
```

The clock is asynchronous to `dp_clk`, and needs no extra constraints for the recorder (the
crossings use XPM macros). Your own clock still needs its usual `create_clock` constraint if
it comes from a pin.

**Rate limits.** The average input rate must stay below what the rest of the chain can
sustain, otherwise beats are dropped:

* The source interface: one beat per `src_clk` cycle, 250 MHz × 32 B = **8 GB/s** on the
  Zynq UltraScale+ targets, 250 MHz × 64 B = **16 GB/s** on `vck190_fmcp1`.
* The fabric datapath: `dp_clk` × the beat, the same 8 or 16 GB/s (250 MHz `dp_clk`).
  `src_clk` and `dp_clk` run at the same frequency, so a source at one beat every cycle
  leaves the ingest FIFO no time to drain after a pause of the ring writer.
* The path into memory: on `zcu106_hpc0` and `vck190_fmcp1` the ring of a RAID0 or
  fabric-only run is split over two memories, each with its own ring port. On Versal a 512-bit
  NoC port into the DDR4 and one into the LPDDR4 (QoS 14 000 MB/s per direction each; the two
  PCIe Root Ports each have their own NoC ports). On the ZCU106 the `S_AXI_HP2_FPD` port into
  PS DDR (128 bits at 322.19 MHz, 5.16 GB/s peak; 333 MHz requested) and a port into the PL
  DDR4 through a DDR4 controller in the PL; the ring writer streams in order through both, so
  their mix, not the fabric, sets the ceiling. The UltraZed-EV has the HP port only
  (327.77 MHz, 5.24 GB/s peak). `nvrec --no-write` measures this path on its own, without an
  SSD (see [Applications](apps.md#fabric-only---no-write)).
* The SSDs read the ring from the same DDR, so a recording crosses DDR twice; and the SSD
  (or the RAID0 array) sustained write rate is usually lower still. Use `nvbench.sh` or
  `nvbench-suite.sh` to measure it for your board and SSDs.

Measured without an SSD (`nvrec --no-write`, see
[Benchmarks](benchmarks.md#fabric-only-no-ssd)), the fabric fills the ring without a dropped
beat up to **6000 MB/s on `zcu106_hpc0`** with the default whole-chunk stripes (7000 MB/s with
4 KB stripes; a single ring in PS DDR stops at 5000 MB/s, where the HP port delivers 5155 MB/s)
and up to **14 750 MB/s on `vck190_fmcp1`**, whose datapath is 512 bits wide (15 750 MB/s with
4 KB stripes, just below the 16 000 MB/s source maximum). `uzev` was not measured (its HP port
peaks at 5.24 GB/s). A source whose average stays below these rates loses no beat on its way
into the ring; whether the SSDs keep up is the next question (see
[Benchmarks](benchmarks.md#ceilings-at-a-glance)).

The ingest FIFO (256 KB: 8192 beats of 32 bytes on the Zynq UltraScale+ targets, 4096 beats
of 64 bytes on `vck190_fmcp1`) only absorbs short bursts and the ring writer's 4 KB burst
cadence (32 µs at 8 GB/s, 16 µs at 16 GB/s); the ring (1 GB by default when split over two
memories, 512 MB otherwise) absorbs
the SSDs' write stalls. If your source is bursty, its average over a few milliseconds is
what matters. You can make the FIFO deeper with the `FIFO_DEPTH` parameter of
`nvrec_core_0` (a power of 2, in beats, block RAM); the block-design scripts size it at
256 KB for every width (`nvrec_ing_fifo_depth` in `Vivado/src/bd/nvrec_params.tcl`).

## Data width

The stream is 256 bits (32 bytes) wide on the Zynq UltraScale+ targets (`zcu106_hpc0`,
`uzev`) and 512 bits (64 bytes) on the Versal target (`vck190_fmcp1`). The width is the
`DATA_WIDTH` parameter of `nvrec_core` and of the `fdrec_tpg` / `fdrec_check` modules: 128,
256 or 512. The block-design scripts set it from one variable, `nvrec_data_width`, which
`Vivado/src/bd/nvrec_params.tcl` reads from the target's `"data_width"` entry in
`config/data.json` (default 256; 512 for `vck190_fmcp1`); a `set nvrec_data_width <n>` in the
Tcl console before the block design is built overrides it. The FIFO depths follow: the
ingest FIFO is 256 KB at every width, the egress FIFO 128 KB at 128 and 256 bits and 256 KB
at 512 bits (`"egress_fifo_kb"` overrides it). Software adapts by itself: the driver reads the
beat size from the `BEAT_BYTES` register (see [Kernel driver](driver.md#beats-and-words)) and
the file header records it. If your source produces words of the build's width, connect it
directly.

If your source is narrower, pack its samples into beats of the build's width before
`M_AXIS`. There are two common ways:

* **AXI4-Stream Data Width Converter** (`axis_dwidth_converter`). Put it in
  `user_data_source` between your source and `M_AXIS`, with the slave side at your width
  (for example 4 bytes, or 16 bytes for a source written for the 128-bit interface of the
  previous revision) and the master side at the beat size (32 bytes, or 64 on
  `vck190_fmcp1`). At 32 bytes it collects 8 × 32-bit words (or 2 × 128-bit words) into one
  beat, the first one in the lowest bits. The converter has a `TREADY` input, but
  `nvrec_core` always drives it high, so the converter never stalls your source.
* **Your own packing logic.** A shift register that collects N samples and pulses `TVALID`
  every Nth sample. This is a few lines of RTL and costs almost nothing.

In both cases the first sample ends up in the lowest bits (`TDATA[W-1:0]`), so it is the first
in the file. If you stop with a partly filled beat, those samples are not recorded.

A source that delivers 128-bit words at up to one per `src_clk` cycle (4 GB/s at 250 MHz)
can also keep a 128-bit interface: build the design with `"data_width": 128`. A 256-bit beat
per cycle is needed only above 4 GB/s, a 512-bit one above 8 GB/s.

If your source is wider than the build's datapath, or faster than one beat per `src_clk`
cycle, use a faster `src_clk` and a width converter, or split the data into beats yourself;
the fabric datapath (8 GB/s at 256 bits, 16 GB/s at 512) and the memory path above still
bound the average rate (a 512-bit build doubles the fabric datapath, not the memory path of
the Zynq UltraScale+ targets).

## What about the TPG controls?

The `tpg_*` pins exist so that the built-in test pattern generator can be controlled from
software. Your source can use them however you like, or not at all:

* Use `tpg_enable` as a run/stop control, so that `nvrec` can start and stop your source
  through the driver's `tpg_enable` sysfs attribute
  (`/sys/class/misc/nvrec/tpg_enable`). Otherwise run `nvrec --no-tpg`, so that it leaves
  the TPG registers alone.
* Leave `tpg_seq_rst` and `tpg_rate_inc` unconnected if they mean nothing to your source.
* Tie `tpg_seq_next` to 0 if you do not have a sample counter. Software only uses it to fill
  in `first_seq` in the file header for TPG recordings.

Note that `nvverify` checks the TPG pattern (16-byte words, each a sequence number in the
low half and its complement in the high half; a 32-byte beat holds two consecutive words).
It cannot verify recordings from your own source. Use
your own tools to check them, and use the drop count (`nvrec` summary, file header
`drop_count`) to know that no data was lost.

## Step by step

1. In the block-design script of your target's device family
   (`Vivado/src/bd/bd_zynqmp.tcl` for Zynq UltraScale+, `Vivado/src/bd/bd_versal.tcl` for
   Versal), find the `user_data_source` hierarchy. Replace
   `create_bd_cell -type module -reference fdrec_tpg user_data_source/fdrec_tpg_0` and
   its connections with your own IP or module reference. Keep the hierarchy pins as they are.
2. Put your RTL in `Vivado/src/hdl/`. `build.tcl` adds every `.v` / `.sv` file there to the
   project. The top module of a module reference must be in a Verilog (`.v`) or VHDL file.
   Vivado 2025.2 does not accept a SystemVerilog file as a module-reference top
   (`[filemgmt 56-195]`), but SystemVerilog submodules are fine.
3. If you change `src_clk`, update its source and `SRC_CLK_HZ` as described above.
   Leave the `tpg_*` pins that your logic does not use unconnected inside the hierarchy,
   and tie `tpg_seq_next` to 0 (an `xlconstant` of width 64) if you have no counter.
4. Rebuild with `./build.sh xsa --target <target>` and check timing, then rebuild the
   Linux image with `./build.sh yocto --target <target>` (the bitstream is in `BOOT.BIN`).
   The driver and the apps need no change. The build needs the NVMe Host Accelerator
   license, as for the reference design.
5. Record with `nvrec --no-tpg --size <bytes> <file>` and check that the exit code is 0
   (drop count 0, no NVMe errors). If your source is not producing data, no chunk fills
   and `nvrec` stops after `--timeout` seconds (default 10) with exit code 1 instead of
   waiting forever; the file keeps what was recorded.

You can also make the change interactively: build the project with
`./build.sh project --target <target>`, open it from `Vivado/<target>/` in the Vivado GUI,
edit the `user_data_source` hierarchy, then copy the change back into the Tcl script so
that it survives a rebuild.
