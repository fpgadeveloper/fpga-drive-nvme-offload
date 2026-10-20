# Build instructions

## Source code

The source code for the reference design is managed on this Github repository:

* [https://github.com/fpgadeveloper/fpga-drive-nvme-offload](https://github.com/fpgadeveloper/fpga-drive-nvme-offload)

To get the code, clone the repository with:
```
git clone https://github.com/fpgadeveloper/fpga-drive-nvme-offload.git
```

## License requirements

```{important}
**Every target of this design needs a license for the AMD NVMe Host Accelerator IP**
(`nvmeha`), purchased or evaluation. Vivado checks it at synthesis, implementation and
bitstream generation; without it the XSA, and therefore the Linux image, cannot be built.
This is the only FPGA Drive reference design that needs an IP license.
```

Before you build:

1. Get a license for the NVMe Host Accelerator from AMD: a purchased one, or a free
   evaluation license from the AMD licensing site,
   [https://www.xilinx.com/getlicense](https://www.xilinx.com/getlicense): search for the
   **NVMe Host Accelerator** IP and generate an evaluation license. See
   [Requirements](requirements.md#nvme-host-accelerator-license) for what an evaluation
   license implies (the Host Accelerator in an evaluation bitstream stops 183-184 minutes
   after the bitstream is loaded, and a power cycle restarts it).
2. Install it like any Vivado license (for example in `~/.Xilinx/`, or point
   `XILINXD_LICENSE_FILE` at it) and check in the Vivado License Manager that the
   `nvmeha` / `nvmehc` features are listed.
3. During the build, Vivado reports
   `IP license key 'nvmehc@2019.04' is enabled with a Hardware_Evaluation license` when it
   uses an evaluation license. That message is expected. Without a valid license for the
   IP, Vivado cannot synthesize it and the build fails.

Apart from the IP license, the Zynq UltraScale+ targets build with the free Vivado ML
Standard Edition; the targets marked "Enterprise" in the Vivado Edition column below target
a device that the Standard Edition does not support (the XCVC1902 of the VCK190) and also
need a Vivado Enterprise license.

## Target designs

The table below lists the target design name, the M.2 slots supported by the design and the
FMC connector on which to connect the mezzanine card.

{% for group in data.groups %}
    {% set designs_in_group = [] %}
    {% for design in data.designs %}
        {% if design.group == group.label and design.publish %}
            {% set _ = designs_in_group.append(design.label) %}
        {% endif %}
    {% endfor %}
    {% if designs_in_group | length > 0 %}
### {{ group.name }} designs

| Target board        | Target design     | M.2 Slot 1<br>PCIe Lanes  | M.2 Slot 2<br>PCIe Lanes  | FMC Slot    | Vivado<br> Edition | IP<br>License |
|---------------------|-------------------|---------------------------|---------------------------|-------------|-----|-----|
{% for design in data.designs %}{% if design.group == group.label and design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.lanes[0] }} | {{ design.lanes[1] | default("-") }} | {{ design.connector }} | {{ "Enterprise" if design.license else "Standard 🆓" }} | {{ "Required (nvmeha)" if design.ip_license else "-" }} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

## Which machine can build what

| Build stage | Native Linux | Windows (git bash, Command Prompt or PowerShell) | WSL |
|---|---|---|---|
| Vivado project, bitstream and XSA | ✅ | ✅ | ❌ |
| Yocto / EDF Linux image | ✅ | ❌ | ❌ |

On Windows you can build the XSA, then build the Linux image on a Linux machine; the runner
prints the exact command to run there. WSL is not supported for either stage.

## Cross-platform build runner

All builds are driven by the `build.py` runner at the root of the repository. Each command
builds whatever it depends on automatically, skips anything that is already built, and
locates the AMD tools itself, so there is no need to source the settings scripts beforehand.

On Linux and on Windows (git bash), commands are run with the `build.sh` shim, which finds a
suitable Python 3 automatically (including the interpreter bundled with the AMD tools).
Windows users who prefer not to use git bash can run the same commands from Command Prompt or
PowerShell using `build.bat` instead (for example `build.bat xsa --target zcu106_hpc0`).

To see the available targets and the state of a build:

```
./build.sh list                       # list the targets and their attributes (ip = IP license needed)
./build.sh status --target <target>   # show the per-stage artifact state
./build.sh clean --target <target>    # delete a target's generated outputs
```

### Build Vivado project

This single command creates the Vivado project, generates the bitstream and exports the
hardware to an XSA file:

```
./build.sh xsa --target <target>
```

Valid targets are:
{% for design in data.designs if design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

To get the Vivado project and block design without generating a bitstream — for example to
explore or modify the design in the Vivado GUI — run `./build.sh project --target <target>`
instead, then open the project from `Vivado/<target>/`.

### Build Yocto

This builds the Yocto / EDF Linux image (AMD's Embedded Development Framework) with the
`gen-machineconf` / `parse-sdt` flow, including the `nvrec` kernel driver and the apps. It
requires a native Linux machine with
[Google's `repo` tool](https://gerrit.googlesource.com/git-repo/) on the `PATH`; the
`xsct`/`sdtgen` tools come from Vitis, which the runner locates and sources itself. The
Vivado XSA is built first if it does not already exist:

```
./build.sh yocto --target <target>
```

Valid targets for Yocto are:
{% for design in data.designs if design.yocto and design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

The first build of a target runs `repo sync` (several GB of git history) and bitbake from
scratch, so it takes a while and its workspace occupies 40–60 GB; subsequent builds are
incremental. The output products (`BOOT.BIN`, `Image`, `boot.scr`, `system.dtb`,
`rootfs.wic.xz`, `rootfs.tar.gz`) are gathered into `Yocto/<target>/images/linux/`. See
[Yocto](yocto) for how the image is put together, how to flash it and how to boot it.

#### Yocto offline build

To build offline (or simply faster), point the build at a locally extracted AMD sstate-cache
mirror.

1. Download the sstate-cache artefacts ("sstate-cache & Downloads - 2025.2") from the AMD
   Embedded Design Tools download page and extract them to a single location, for example
   `/home/user/yocto-sstate`, leaving this directory structure:
   ```
   /home/user/yocto-sstate
                          +---  aarch64       (Zynq UltraScale+ and Versal)
                          +---  microblaze    (PMU firmware)
                          +---  downloads
   ```
2. Create a text file called `offline.txt` in the `Yocto` directory of the repository
   containing a single line with that path, written with NO TRAILING FORWARD SLASH:
   ```
   /home/user/yocto-sstate
   ```

The Yocto build then auto-detects which architecture sub-directories are present and
configures the build to use the mirror.

### Build everything

This builds everything the target supports — the Vivado project and XSA, then the Yocto
image — and gathers the boot images into `bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all      # every target in the repo
```

On Windows, `all` builds everything the host can build and reports the Yocto stage as
`BLOCKED` rather than failing.

```{note}
**The prebuilt boot images offered with the releases of this design (the same zips) are built with the
evaluation license.** The Host Accelerator in them stops 183-184 minutes (about 3 hours)
after the board is powered on, and a power cycle restarts it. Use them to evaluate the design; for longer
operation, build the design yourself with a purchased license.
```

### Build the driver and apps outside Yocto

The kernel module and the apps are ordinary Makefile projects, so you can rebuild them
without the Yocto flow:

```
make -C sw/nvrec-driver KERNEL_SRC=<configured kernel tree for the board's kernel>
make -C sw/nvrec-apps                # no library dependencies
make -C sw/nvrec-apps CC=aarch64-linux-gnu-gcc   # cross-compile for the board
```

`nvverify` also builds and runs on a PC, to check a recording copied off the board. See
[Applications](apps) and [Kernel driver](driver).

### Simulate the custom RTL

The custom RTL in `Vivado/src/hdl/` (`nvrec_core` with its ring writer, command builder,
completion router, ring reader, command injector and register blocks, the AXI-Lite timeout
guard `nvrec_axil_guard`, and the reused `fdrec_tpg` / `fdrec_check`) has self-checking
testbenches in `Vivado/src/sim/`. Run them in the Vivado simulator (xsim) with:

```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
```

Each testbench prints `PASS` or `FAIL`. The testbenches use a behavioural model of the
Host Accelerator and an SSD, so they run without the IP license. Run them after you change
the RTL; `Vivado/src/sim/README.md` lists what each one checks.
