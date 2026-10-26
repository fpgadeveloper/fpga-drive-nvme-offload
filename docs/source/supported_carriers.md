# Supported carrier boards

## List of supported boards

{% set unique_boards = {} %}
{% for design in data.designs %}
    {% if design.publish %}
        {% if design.board not in unique_boards %}
            {% set _ = unique_boards.update({design.board: {"group": design.group, "link": design.link, "designs": []}}) %}
        {% endif %}
        {% set _ = unique_boards[design.board]["designs"].append(design) %}
    {% endif %}
{% endfor %}

{% for group in data.groups %}
    {% set boards_in_group = [] %}
    {% for name, board in unique_boards.items() %}
        {% if board.group == group.label %}
            {% set _ = boards_in_group.append(board) %}
        {% endif %}
    {% endfor %}
    {% if boards_in_group | length > 0 %}
### {{ group.name }} boards

| Carrier board | Target design | FMC connector | M.2 slots (PCIe lanes) |
|---------------|---------------|---------------|------------------------|
{% for name,board in unique_boards.items() %}{% if board.group == group.label %}{% for design in board.designs %}| [{{ name }}]({{ board.link }}) | `{{ design.label }}` | {{ design.connector }} | {% for l in design.lanes %}SSD{{ loop.index }} {{ l }}{{ ", " if not loop.last else "" }}{% endfor %} |
{% endfor %}{% endif %}{% endfor %}
{% endif %}
{% endfor %}

All three targets use two independent 4-lane PCIe root ports (one per M.2 slot) and the same
NVMe offload datapath: `nvrec_core`, the AMD NVMe Host Accelerator with one hardware queue
per SSD, the same register addresses (`nvrec_core` at 0x4_2001_0000, Host Accelerator
registers at 0x4_2002_0000) and the same queue window as seen by the SSDs (0x9000_0000). The
width of the fabric datapath and the ring's memories differ: on `zcu106_hpc0` and
`vck190_fmcp1` the ring of a RAID0 recording is split over PS DDR and a second memory that the
CPU does not use, `uzev` has a single ring in PS DDR:

| target | fabric datapath | ring's memories | fabric-only ceiling, recording / playback | hardware status in this revision |
|---|---|---|---|---|
| `uzev` | 256 bits at 250 MHz (8 GB/s) | single ring in PS DDR through `S_AXI_HP2_FPD`, 128 bits at 327.77 MHz (5.24 GB/s peak) | not measured | built (XSA and Linux image), not tested on hardware |
| `vck190_fmcp1` | 512 bits at 250 MHz (16 GB/s) | split ring: DDR4 (PS DDR) and the on-board LPDDR4, each through a 512-bit NoC port of its own; one more NoC port per PCIe Root Port | 14 750 / 15 000 MB/s (whole-chunk stripes, the default; 15 750 / 16 000 MB/s with 4 KB stripes) | tested with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230 1TB |
| `zcu106_hpc0` | 256 bits at 250 MHz (8 GB/s) | split ring: PS DDR4 through `S_AXI_HP2_FPD` (128 bits at 322.19 MHz, 5.16 GB/s peak) and the soldered PL DDR4 through a DDR4 controller in the PL | 6000 / 6250 MB/s (whole-chunk stripes, the default; 7000 / 6750 MB/s with 4 KB stripes) | tested with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230 1TB |

The fabric-only ceiling is the highest rate at which data reaches DDR from the fabric (and comes
back for playback) without any SSD; what the SSDs then sustain is lower and is listed per target
and drive pair on the [Benchmarks](benchmarks) page, with every ceiling and how to get past it.

**License required:** every target needs a license (purchased or evaluation) for the AMD NVMe
Host Accelerator IP. The `vck190_fmcp1` target additionally needs a Vivado **Enterprise**
license for its device.

What a carrier needs for this design:

* An FMC connector with the gigabit transceivers for the M.2 slots: four lanes per slot for
  a x4 link, eight for two x4 slots (an HPC or FMC+ connector, depending on the board's
  routing). The design needs both slots.
* A processor that runs Linux (Zynq UltraScale+ or Versal), with enough DDR memory below
  4 GB for the CMA pool that holds the recording ring (see the board notes below).
* For the split ring, a second memory that the fabric and the PCIe Root Ports can reach and
  that is wide enough for half of the stream (a 64-bit PL DDR4 on the ZCU106, the LPDDR4 on the
  VCK190); without one the design keeps a single ring in PS DDR, as on `uzev`.
* A device supported by the NVMe Host Accelerator IP (Zynq UltraScale+, Versal), and fabric
  resources for the FIFOs (block RAM) and the IP; the
  [resource usage](architecture.md#resource-usage) of the first target gives an idea.

## Board specific notes

### UltraZed-EV Carrier

* The carrier has one HPC FMC connector, which supports two SSDs, each with an independent
  4-lane PCIe Gen3 interface (XDMA Root Ports). The block design is the ZCU106 one, with the
  same address map and interrupts.
* Status: built (XSA and Linux image) but **not tested on hardware in this revision**. The
  target has the ZCU106 block design without the second ring port (the SOM's PL DDR4 is
  16 bits wide, too narrow for half of the stream): a single ring on `S_AXI_HP2_FPD`, here at
  327.77 MHz (5.24 GB/s peak). The single-ring figures of `zcu106_hpc0` (`--ring single` on the
  [Benchmarks](benchmarks.md#zynq-ultrascale-zcu106_hpc0-uzev) page) are the best guide to what
  it does.
* Boot mode: to boot from the SD card, set DIP switch SW2 on the UltraZed-EV SOM to 1000
  (1=ON, 2=OFF, 3=OFF, 4=OFF).
* The Linux console is the PS UART 0 interface on the carrier's USB-UART, at 115200 baud.
* The eMMC on the SOM enumerates as `mmcblk0` and the SD card as `mmcblk1`; the Linux image
  boots its root filesystem from `/dev/mmcblk1p3`.
* The SOM has 4 GB of PS DDR4, 2 GB of it below 4 GB. The image reserves a 1 GB CMA pool
  (`NVREC_CMA` in `Yocto/bsp/uzev/conf/local.conf.append`) for the recording ring; the
  default ring (512 MB, 514-520 MB with its PRP lists) fits. Raise `NVREC_CMA` (e.g. to
  `1536M`, the ZCU106 value) before building if you need a larger ring: the ring (slots x chunk
  size) plus 4 KB of PRP list per slot must fit in the pool, so the largest ring
  (`--buffers 1024` with 1 MB chunks, 1028 MB) needs the larger pool.

### ZCU106

* The `zcu106_hpc0` design uses the HPC0 FMC connector, which supports two SSDs, each with an
  independent 4-lane PCIe Gen3 interface (XDMA Root Ports).
* Status: tested on hardware in this revision with two Samsung 980 PRO 1TB on the FPGA Drive
  FMC Gen4 and with two Sabrent Rocket 2230 1TB on the M.2 M-key Stack FMC (single drive and
  RAID0, recording, playback, verification); every SSD links at PCIe Gen3 x4.
* Datapath: 256 bits, `src_clk` = `dp_clk` = 250 MHz. The ring is split over two memories:
  ring A in PS DDR through `S_AXI_HP2_FPD`, 128 bits at `pl_clk3` = 322.19 MHz (333 MHz
  requested, 5.16 GB/s peak), ring B in the board's soldered 64-bit PL DDR4 through a DDR4
  controller in the PL (512 bits at 300 MHz), at `0x20_0000_0000`, where the device tree
  reserves 1 GB for it. Without SSDs the split ring records 6000 MB/s and plays back 6250 MB/s
  (whole-chunk stripes). With PCIe MaxPayload 256 bytes, which the image sets at boot
  (`nvrec-pcie-mps.service`), the 980 PRO pair plays back 5750 MB/s sustained and the Sabrent
  pair records and plays back 6000 MB/s; the 980 PRO pair records 6000 MB/s; at 128 bytes both
  pairs play back 5250 MB/s. One drive is bound by its Gen3 x4 slot and stays on a single ring
  (one 980 PRO records 3250 MB/s and plays back 3500 MB/s at 256 bytes, 3000 / 3000 MB/s at
  128). See
  [Benchmarks](benchmarks.md#zynq-ultrascale-zcu106_hpc0-uzev).
* The PL DDR4 controller calibrates when the bitstream is loaded; the driver uses the split
  ring only when it reports ready (`cat /sys/class/misc/nvrec/mem1_ready` reads 1) and falls
  back to a single ring in PS DDR otherwise.
* With the PL DDR4 controller and its I/O banks in use, the board's VCCAUX rail (1.8 V,
  regulator U6) carries about 0.54-0.55 A in steady state after boot, against about 0.145 A
  with Release 1.1 of this design, which did not use the PL DDR4.
* The device is supported by the free Vivado Standard Edition; only the NVMe Host Accelerator
  IP needs a license.
* The image reserves a 1.5 GB CMA pool for the recording ring (`NVREC_CMA`).

### VCK190

* The `vck190_fmcp1` design uses the FMCP1 connector (FMC+), which supports two SSDs, each
  with an independent 4-lane PCIe Gen4 interface (QDMA Root Ports in AXI bridge mode).
* Status: tested on hardware in this revision with two Samsung 980 PRO 1TB on the FPGA Drive
  FMC Gen4 and with two Sabrent Rocket 2230 1TB on the M.2 M-key Stack FMC (single drive and
  RAID0, recording, playback, verification); every SSD links at PCIe Gen4 x4.
* Datapath: 512 bits, `src_clk` = `dp_clk` = 250 MHz (16 GB/s), an ingest FIFO of 256 KB and
  an egress FIFO of 256 KB. The ring is split over two memories: ring A in the DDR4 (PS DDR)
  through a 512-bit NoC port of its own, ring B in the on-board LPDDR4 through a second NoC
  instance with one LPDDR4 controller (its two x32 channels interleaved), at
  `0x600_0000_0000`, where the device tree reserves 1 GB for it (Linux never maps the LPDDR4);
  QoS request 14 000 MB/s per direction for each ring port. Each PCIe Root Port's DMA has a NoC
  port of its own (`S08_AXI` and `S10_AXI`, 7000 MB/s to the DDR4 and 4000 MB/s to the LPDDR4)
  instead of the one port that both Root Ports share in the base design. Without SSDs the
  split ring records 14 750 MB/s and plays back 15 000 MB/s (whole-chunk stripes). The 980 PRO
  pair records 10 000 MB/s over 32 GB and plays back 11 000 MB/s sustained, the Sabrent pair
  8250 and 9250 MB/s (both record at their drives' write rate), with PCIe MaxPayload 256 bytes,
  which the image sets at boot (`nvrec-pcie-mps.service`). See [Benchmarks](benchmarks.md#versal-vck190_fmcp1).
* VADJ: the board's system controller normally sets the FMC VADJ supply from the FMC card's
  EEPROM. The Linux image does not depend on it: its U-Boot boot script enables VADJ at
  1.5 V (IR38164 regulator over I2C) before Linux starts, and prints
  `FPGA Drive FMC: enabling VADJ (1.5V) via IR38164` on the console. Without VADJ the SSDs
  never link up.
* The QDMA bridges translate no addresses: the SSD BARs are assigned in the 32-bit windows
  at 0xA800_0000 (SSD1) and 0xAC00_0000 (SSD2), which the Host Accelerator's 32-bit doorbell
  master reaches at the same addresses as the CPU. An SSD whose BAR 0 is prefetchable would
  be placed in the 64-bit windows above 4 GB instead and cannot be used with this design.
* The VCK190 has 2 GB of DDR4 at address 0 and 6 GB above 4 GB; the image reserves a 1.5 GB
  CMA pool for the recording ring (`NVREC_CMA`).
* Building the design needs a Vivado **Enterprise** license, because the XCVC1902 device is
  not supported by the free Standard Edition, in addition to the NVMe Host Accelerator IP
  license.

## Unlisted boards

If you need more information on whether the [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC]
is compatible with a carrier that is not listed above, please first check the
[compatibility list]. If the carrier is not listed there, please [contact Opsero],
provide us with the pinout of your carrier and we'll be happy to check compatibility. A
carrier that runs the [fpga-drive-recorder] design is a good candidate for this design.

[contact Opsero]: https://opsero.com/contact-us
[compatibility list]: https://www.fpgadrive.com/docs/fpga-drive-fmc-gen4/compatibility/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[fpga-drive-recorder]: https://github.com/fpgadeveloper/fpga-drive-recorder
