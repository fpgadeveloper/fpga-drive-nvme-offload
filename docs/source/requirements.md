# Requirements

In order to build this design and test it on hardware, you will need the following:

* Vivado 2025.2 (the free Standard Edition for the Zynq UltraScale+ targets; the targets
  marked "Enterprise" in the [target table](build_instructions.md#target-designs), such as
  the VCK190, need a Vivado Enterprise license for the device)
* **A license for the AMD NVMe Host Accelerator IP**, purchased or evaluation (see
  [below](#nvme-host-accelerator-license)): needed for every target
* Vitis 2025.2 (it provides `sdtgen` / `xsct`, which the Yocto flow uses to turn the Vivado
  XSA into a System Device Tree)
* A native Linux machine for the Yocto / EDF build, with
  [Google's repo tool](https://gerrit.googlesource.com/git-repo/) and the host packages
  listed in `Yocto/README.md`; the Vivado part also builds on Windows
* 1x [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC]
* One or two M.2 NVMe PCIe SSDs (see [supported SSDs](supported_ssds)); for RAID0
  recording, two SSDs
* One of the supported carrier boards listed below, with its USB-UART cable
* A micro-SD card of 8 GB or larger
* An Ethernet connection from the board to your network, to log in over SSH and copy
  recordings off the board with `scp` (optional, but the practical way to get recordings
  out)

There is no PetaLinux flow (PetaLinux is being retired) and no standalone (baremetal)
application in this design.

## NVMe Host Accelerator license

The NVMe offload is done by the AMD [NVMe Host Accelerator] (`nvmeha` v1.0, product guide
PG328), an IP core that is licensed separately from Vivado. Vivado checks for its license
at synthesis, implementation and bitstream generation, so **no target of this design can be
built without it**. This is different from every other FPGA Drive reference design, none of
which needs an IP license.

Two kinds of license work:

* **Evaluation license**: free from AMD, from the AMD licensing site (steps below). It is
  valid for a limited period, and it produces a bitstream with a
  **hardware-evaluation core**: the Host Accelerator stops working after about 3 hours of
  operation (183-184 minutes after the bitstream was loaded, measured on the ZCU106).
  Reloading the bitstream, which for these SD-card images means power-cycling the board,
  restarts it. The design detects the stop and turns it into a clean error instead of a
  system hang (see [When the Host Accelerator stops](limitations.md#evaluation-license-timeout)).
  Vivado reports `IP license key 'nvmehc@2019.04' is enabled with a Hardware_Evaluation
  license` during the build.
* **Purchased license** from AMD: no time limit.

To get and install an evaluation license:

1. Go to the AMD licensing site, [https://www.xilinx.com/getlicense](https://www.xilinx.com/getlicense),
   and sign in.
2. Search for the **NVMe Host Accelerator** IP and generate an evaluation license for it.
3. Install the license file like any Vivado license, for example in `~/.Xilinx/`, or point
   `XILINXD_LICENSE_FILE` at it.
4. Check in the Vivado License Manager that the `nvmeha` / `nvmehc` features are listed.

Any boot image built with an evaluation license carries this limit.

```{note}
**The prebuilt boot images offered with the releases of this design are built with the
evaluation license.** The Host Accelerator in them stops 183-184 minutes (about 3 hours)
after the board is powered on, and a power cycle restarts it. Use them to evaluate the design; for longer
operation, build the design yourself with a purchased license.
```

## List of supported boards

{% set unique_boards = {} %}
{% for design in data.designs %}
	{% if design.publish %}
	    {% if design.board not in unique_boards %}
	        {% set _ = unique_boards.update({design.board: {"group": design.group, "link": design.link, "connectors": []}}) %}
	    {% endif %}
	    {% if design.connector not in unique_boards[design.board]["connectors"] %}
	    	{% set _ = unique_boards[design.board]["connectors"].append(design.connector) %}
	    {% endif %}
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

| Carrier board        | Supported FMC connector(s)    |
|---------------------|--------------|
{% for name,board in unique_boards.items() %}{% if board.group == group.label %}| [{{ name }}]({{ board.link }}) | {% for connector in board.connectors %}{{ connector }} {% endfor %} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

For the list of target designs with the number of M.2 slots and PCIe lanes of each, refer
to the [build instructions](build_instructions.md#target-designs), and for the board
specific notes (CMA size, VADJ, boot switches) to [supported carriers](supported_carriers).

[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[NVMe Host Accelerator]: https://docs.amd.com/r/en-US/pg328-nvme-host-accelerator
