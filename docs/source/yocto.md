# Yocto

The Linux image of this design is built with the AMD Yocto / Embedded Development Framework
(EDF) flow, the announced successor to PetaLinux. There is no PetaLinux flow. The build is
driven by the cross-platform `build.py` runner at the root of the repository.

## Requirements

To build the Yocto image you need a physical or virtual machine running one of the
[supported Linux distributions], with Vivado and Vitis 2025.2 installed — the flow uses
`xsct`/`sdtgen` (which ship with Vitis) to generate a System Device Tree from the Vivado XSA.
You also need [Google's repo tool](https://gerrit.googlesource.com/git-repo/) on your `PATH`.
The host packages are listed in `Yocto/README.md`.

Plan for the disk space and time of a full Yocto build: the first build downloads several GB
of sources and runs bitbake from scratch, and the workspace occupies 40–60 GB.

```{attention}
You cannot build the Yocto image in the Windows operating system. Windows users are advised
to use a Linux virtual machine. On Windows the build runner can still build the Vivado
project and XSA, and prints the command to run on the Linux machine.
```

```{attention}
This design contains the AMD **NVMe Host Accelerator**, a licensed IP. Building the XSA
(synthesis, implementation, bitstream) needs an `nvmeha` license (purchased or evaluation)
installed on the build machine; without it the Vivado stage, and therefore the Yocto image,
cannot be built. An evaluation license produces a bitstream whose IP stops 183-184 minutes
after the bitstream is loaded; reload the bitstream (power-cycle) to start again (see
[Known limitations](limitations.md#evaluation-license-timeout)).
```

To test the image you need:

* the target board, with its USB-UART cable and a micro-SD card (8 GB or larger),
* the [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC] and one or two M.2 NVMe SSDs,
* optionally, an Ethernet cable from the board's RJ45 port to your network (DHCP).

## How to build

The build runner locates and sources the Vivado and Vitis settings itself, so there is no
need to source them by hand.

1. Clone the repository and `cd` into it:
   ```
   git clone https://github.com/fpgadeveloper/fpga-drive-nvme-offload.git
   cd fpga-drive-nvme-offload
   ```
2. Build the Yocto image for your target, replacing `<target>` with one of the target
   design labels listed in the [build instructions](build_instructions.md#build-yocto):
   ```
   ./build.sh yocto --target <target>
   ```

This builds the Vivado project and XSA first if they do not exist yet. Subsequent builds are
incremental. See [build instructions](build_instructions.md#yocto-offline-build) to build
against a local sstate-cache mirror. The output products are gathered into
`Yocto/<target>/images/linux/`:

| File | Description |
| --- | --- |
| `rootfs.wic.xz` + `rootfs.wic.bmap` | Full SD-card disk image — this is what you flash |
| `BOOT.BIN` | Boot image (Zynq UltraScale+: FSBL + PMU firmware + bitstream + ATF + U-Boot; Versal: PLM + PSM firmware + PDI + ATF + U-Boot) |
| `boot.scr` | U-Boot boot script |
| `Image` | Linux kernel |
| `system.dtb` | Linux device tree |
| `rootfs.tar.gz` | Root filesystem tarball |

`./build.sh all --target <target>` (or `./build.sh package --target <target>` after the Yocto
stage) also packs the flashable files into
`bootimages/fpga-drive-nvme-offload_<target>_yocto-2025-2.zip`.

```{note}
The Yocto stage is skipped when the gathered images already exist. After you change the
driver or the apps in `sw/`, delete `Yocto/<target>/images/linux/` so that the next
`./build.sh yocto` rebuilds the image with your change (incrementally: the workspace is
kept).
```

## How the image is put together

The flow generates a custom Yocto MACHINE (`nvrec-<target>`) directly from the Vivado XSA
(`sdtgen` → System Device Tree → `gen-machineconf parse-sdt`), so the PS configuration and
the PL hardware in the device tree — the XDMA PCIe root ports in particular — come from the
design itself. The bitstream is embedded in `BOOT.BIN` and programmed by the FSBL at boot.

On top of the EDF defaults, two layers are added:

* **`Yocto/bsp/<target>/meta-user`** — target-specific: the `system-user.dtsi` device-tree
  fixups (UARTs, Ethernet PHY and the fixed bench MAC address) and the **`nvrec`
  device-tree node** (`compatible = "opsero,nvrec"`: the nvrec_core and NVMe Host
  Accelerator register windows, their two interrupts, and `opsero,ssd-ports` = the PL root
  ports in SSD order, see [Kernel driver](driver.md#device-tree)), the kernel options of the
  base design (PL PCIe root port; the stock NVMe driver as a **module**), the base design's
  packages, and the kernel command line (`BSP_EXTRA_BOOTARGS`).
* **`Yocto/meta-nvrec`** — the recorder layer, enabled for a target by listing it in
  `Yocto/bsp/<target>/bblayers-extra.txt`:

  | Recipe / file | What it adds |
  |---------------|--------------|
  | `recipes-kernel/nvrec-mod` | the `nvrec.ko` kernel module, built from `sw/nvrec-driver` and `include/`, loaded at boot; `/etc/modprobe.d/nvrec-blacklist-nvme.conf` (`blacklist nvme`) |
  | `recipes-apps/nvrec-apps` | `nvrec`, `nvplay`, `nvverify`, `nvregs`, `nvbench.sh`, `nvbench-suite.sh`, `nvsetup-raid0.sh`, built from `sw/nvrec-apps` |
  | `recipes-apps/speed-tests` | the base design's dd speed tests |
  | `recipes-kernel/linux/linux-xlnx_%.bbappend` + `nvrec.cfg` | kernel options: `CONFIG_BLK_DEV_NVME=m` (+ `NVME_CORE=m`), `CONFIG_DMA_CMA`, `CONFIG_HUGETLBFS`, `CONFIG_MD_RAID0` (+ `CONFIG_BLK_DEV_MD`), `CONFIG_EXFAT_FS`, `CONFIG_NLS_UTF8` |
  | `recipes-core/images/edf-linux-disk-image.bbappend` | image packages: the module and apps, `mdadm`, `exfatprogs`, `nvme-cli`, `fio`, util-linux tools, and bench tools (`devmem2`, `i2c-tools`, `ethtool`, `iproute2`, `iperf3`, `phytool`, `pciutils`, SSH server) |

  The recipes take their sources straight from the repository (`file://sw/...` and
  `file://include` relative to the repository root), so a change to the driver or the apps
  is picked up by the next `./build.sh yocto`.

### Why the stock nvme driver is a blacklisted module

The SSDs belong to the `nvrec` driver: it brings the controllers up and creates their I/O
queues inside the NVMe Host Accelerator (see [Kernel driver](driver.md#why-the-stock-nvme-driver-is-kept-off-the-ssds)).
A built-in `nvme` driver would claim them at boot, before `nvrec.ko` loads, so it is built as
a module and blacklisted. It remains on the image for reference measurements: unbind an SSD
from `nvrec-nvme`, `modprobe nvme`, and the stock driver takes it.

### Kernel command line

The kernel command line is built by the EDF `boot.scr`. On `zcu106_hpc0` it is:

```
earlycon console=ttyPS0,115200 clk_ignore_unused init_fatal_sh=1 root=/dev/mmcblk0p3 ro rootwait
uio_pdrv_genirq.of_id=generic-uio cma=1536M
```

On `uzev` the root filesystem is `/dev/mmcblk1p3` (the SOM's eMMC is `mmcblk0`), and the
CMA pool is 1024M; on `vck190_fmcp1` it is 1536M, as on `zcu106_hpc0`.

The target-specific arguments come from `BSP_EXTRA_BOOTARGS` in
`Yocto/bsp/<target>/conf/local.conf.append`. `cma=` sizes the contiguous memory pool from
which the driver allocates the recording ring (one physically contiguous region; by default
256 MB of chunks of 1 MB or the MDTS, plus 4 KB of PRP list per chunk; at most 1024 chunks
and 1 GB): variable `NVREC_CMA` (1536M on `zcu106_hpc0`
and `vck190_fmcp1`, 1024M on `uzev`). `NVREC_HUGEPAGES` (default 0) adds
`hugepagesz=2M hugepages=N` for apps that bring their own ring.

## Boot from SD card

The build produces a **full SD-card disk image** (`rootfs.wic.xz`) with all partitions:
`esp` (FAT, for `BOOT.BIN`), `boot` (ext4: `boot.scr`, kernel, device tree) and `root`
(ext4).

```{warning}
Flashing writes directly to a raw block device and cannot be undone. Be absolutely certain
you have identified the SD card's device node before running the commands below.
```

1. Identify the SD card device: run `lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT` with the card
   unplugged and again with it plugged in; the new entry (`/dev/sdX`, `RM=1`) is the card.
2. Unmount anything the desktop auto-mounted:
   ```
   for p in /dev/sdX?*; do sudo umount "$p" 2>/dev/null; done
   ```
3. Flash the image:
   ```
   sudo bmaptool copy --bmap Yocto/<target>/images/linux/rootfs.wic.bmap \
                            Yocto/<target>/images/linux/rootfs.wic.xz /dev/sdX
   ```
   or, slower: `xzcat Yocto/<target>/images/linux/rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`
4. Copy `BOOT.BIN` onto the `esp` partition (the EDF image leaves it empty, and the BootROM
   loads `BOOT.BIN` from the first FAT partition):
   ```
   sudo partprobe /dev/sdX
   sudo mkdir -p /mnt/sd_esp && sudo mount /dev/sdX1 /mnt/sd_esp
   sudo cp Yocto/<target>/images/linux/BOOT.BIN /mnt/sd_esp/ && sync
   sudo umount /mnt/sd_esp && sudo rmdir /mnt/sd_esp
   ```
5. Eject the card: `sudo eject /dev/sdX`.

Then boot:

1. Plug the SD card into the carrier and set the board's boot mode to SD (see the
   [board specific notes](supported_carriers.md#board-specific-notes) for the switch
   settings).
2. Connect one or two M.2 NVMe SSDs to the mezzanine card, and the card to the FMC
   connector of the carrier that the target design is built for (see the
   [target designs](build_instructions.md#target-designs)).
3. Connect the USB-UART to your PC and open a terminal at 115200 baud (8N1).
4. Optionally connect the board's Ethernet port to your network.
5. Power up the board.

On the VCK190, U-Boot first prints `FPGA Drive FMC: enabling VADJ (1.5V) via IR38164`
(see [supported carriers](supported_carriers.md#vck190)). During boot, look for the PCIe
links, the recorder driver and one line per SSD (ZCU106 with two Samsung 980 PRO; values
depend on the drives):

```none
xilinx-xdma-pcie 400000000.axi-pcie: PCIe Link is UP
xilinx-xdma-pcie 500000000.axi-pcie: PCIe Link is UP
nvrec 420010000.nvrec: /dev/nvrec: nvrec_core v1.1, src_clk 199980011 Hz, dp_clk 249975006 Hz, FIFO 4096 beats; nvmeha: 2 SSDs x 1 queues (SQ window 0x90000000, CQ window 0x90008000), hardware queues, CPU I/O via the injector
nvrec-nvme 0000:01:00.0: SSD0: Samsung SSD 980 PRO 1TB (<serial>, fw 5B2QGXA7): 1953525168 x 512-byte LBAs (1000 GB), MDTS 512 KB, DSTRD 0, 1 I/O queues granted, 0 SW + 1 HW queues in the IP, block I/O via the CPU command injector -> /dev/nvrec0n1
nvrec-nvme 0001:01:00.0: SSD1: Samsung SSD 980 PRO 1TB (<serial>, fw 5B2QGXA7): ... -> /dev/nvrec1n1
```

No `nvme0n1` appears: the stock driver is not loaded (see above).

## Log in

The console shows a login prompt with the hostname `<board>-nvrec-2025-2`
(`zcu106-nvrec-2025-2`, `uzev-nvrec-2025-2`, `vck190-nvrec-2025-2`). Log in as
**`amd-edf`**; on the first login you must choose a password. The `amd-edf` user can run
commands as root with `sudo`. The image includes an SSH server, and the board's Ethernet
port comes up with DHCP, so once the password is set you can also log in over the network
(`ip -br addr` on the board shows the address).

## Next steps

Work through [Test the design in Linux](linux_test), or in short (see [Apps](apps)):

```
sudo nvsetup-raid0.sh -y
sudo nvrec --rate 1GB --size 10G /mnt/rec/test.dat
sudo nvverify /mnt/rec/test.dat
```

[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[supported Linux distributions]: https://docs.amd.com/r/en-US/ug1144-petalinux-tools-reference-guide/Setting-Up-Your-Environment
