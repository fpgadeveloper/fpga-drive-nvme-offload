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
width of the fabric datapath and the path of the ring into DDR differ:

| target | fabric datapath | ring's path into DDR | fabric-only ceiling, recording / playback | hardware status in this revision |
|---|---|---|---|---|
| `uzev` | 256 bits at 250 MHz (8 GB/s) | `S_AXI_HP2_FPD`, 128 bits at 327.77 MHz (5.24 GB/s peak) | not measured | built (XSA and Linux image), not tested on hardware |
| `vck190_fmcp1` | 512 bits at 250 MHz (16 GB/s) | its own NoC port, 512 bits; one more NoC port per PCIe Root Port | 14 500 / 13 750 MB/s | tested with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230 1TB |
| `zcu106_hpc0` | 256 bits at 250 MHz (8 GB/s) | `S_AXI_HP2_FPD`, 128 bits at 322.19 MHz (5.16 GB/s peak) | 5000 / 5000 MB/s | tested with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230 1TB |

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
* A device supported by the NVMe Host Accelerator IP (Zynq UltraScale+, Versal), and fabric
  resources for the FIFOs (block RAM) and the IP; the
  [resource usage](architecture.md#resource-usage) of the first target gives an idea.

## Board specific notes

### UltraZed-EV Carrier

* The carrier has one HPC FMC connector, which supports two SSDs, each with an independent
  4-lane PCIe Gen3 interface (XDMA Root Ports). The block design is the ZCU106 one, with the
  same address map and interrupts.
* Status: built (XSA and Linux image) but **not tested on hardware in this revision**. The
  target shares the ZCU106 block design (256-bit datapath, ring on `S_AXI_HP2_FPD`, here at
  327.77 MHz: 5.24 GB/s peak), so the `zcu106_hpc0` results are the best guide to what it does.
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
* Datapath: 256 bits, `src_clk` = `dp_clk` = 250 MHz; the ring reaches DDR through
  `S_AXI_HP2_FPD`, 128 bits at `pl_clk3` = 322.19 MHz (333 MHz requested): 5.16 GB/s peak.
  That port is the recording ceiling: 5000 MB/s with or without SSDs (RAID0 of either pair).
  RAID0 playback holds 4250 MB/s with the 980 PRO pair and 4500 MB/s with the Sabrent pair (the
  SSDs writing DDR and the ring reader reading it share the DDR); one drive is bound by its Gen3 x4 slot (~3.0 GB/s write for the
  980 PRO, ~2.8 GB/s for the Sabrent, ~3.2 GB/s read for both).
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
  an egress FIFO of 256 KB. The ring reaches DDR through its own NoC port (512 bits, QoS
  request 14 000 MB/s per direction), and each PCIe Root Port's DMA through a NoC port of its
  own (`S08_AXI` and `S10_AXI`, 7000 MB/s each), instead of the one port that both Root Ports
  share in the base design. Without SSDs the datapath records 14 500 MB/s and plays back
  13 750 MB/s. The 980 PRO pair records 9250 MB/s over 32 GB and plays back 8750 MB/s for any
  length: the limit of the single DDR4-3200 controller, which every byte crosses twice
  (~18-19 GB/s of mixed traffic). The Sabrent pair records 7750 MB/s over 32 GB and plays back
  7500 MB/s sustained (40 GiB; 8750 MB/s for a 10 GiB file). A 256-bit build with the shared port stopped at 6750 MB/s (RAID0 recording) and
  7750 / 7500 MB/s (fabric); see [Benchmarks](benchmarks.md#versal-vck190_fmcp1).
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
