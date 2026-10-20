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
registers at 0x4_2002_0000) and the same queue window as seen by the SSDs (0x9000_0000).

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
* Status: tested on hardware with two Sabrent Rocket 2230 1TB on the M.2 M-key Stack FMC
  (single drive and RAID0, recording, playback, verification); both SSDs link at PCIe Gen3 x4.
* Boot mode: to boot from the SD card, set DIP switch SW2 on the UltraZed-EV SOM to 1000
  (1=ON, 2=OFF, 3=OFF, 4=OFF).
* The Linux console is the PS UART 0 interface on the carrier's USB-UART, at 115200 baud.
* The eMMC on the SOM enumerates as `mmcblk0` and the SD card as `mmcblk1`; the Linux image
  boots its root filesystem from `/dev/mmcblk1p3`.
* The SOM has 4 GB of PS DDR4, 2 GB of it below 4 GB. The image reserves a 1 GB CMA pool
  (`NVREC_CMA` in `Yocto/bsp/uzev/conf/local.conf.append`) for the recording ring; the
  default ring (256 MB, about 260 MB with its PRP lists) fits with room to spare. Raise
  `NVREC_CMA` (e.g. to `1536M`, the ZCU106 value) before building if you need a larger ring:
  the ring (slots x chunk size) plus 4 KB of PRP list per slot must fit in the pool, so the
  largest ring (`--buffers 1024` with 1 MB chunks, 1028 MB) needs the larger pool.

### ZCU106

* The `zcu106_hpc0` design uses the HPC0 FMC connector, which supports two SSDs, each with an
  independent 4-lane PCIe Gen3 interface (XDMA Root Ports).
* Status: tested on hardware with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230
  1TB (single drive and RAID0, recording, playback, verification).
* The device is supported by the free Vivado Standard Edition; only the NVMe Host Accelerator
  IP needs a license.
* The image reserves a 1.5 GB CMA pool for the recording ring (`NVREC_CMA`).

### VCK190

* The `vck190_fmcp1` design uses the FMCP1 connector (FMC+), which supports two SSDs, each
  with an independent 4-lane PCIe Gen4 interface (QDMA Root Ports in AXI bridge mode).
* Status: tested on hardware with two Samsung 980 PRO 1TB and with two Sabrent Rocket 2230
  1TB (single drive and RAID0, recording, playback, verification); both SSDs link at PCIe
  Gen4 x4.
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
