# meta-nvrec

Yocto layer for the FPGA Drive NVMe-offload recorder. It is layered on top of the AMD EDF
build together with the target's `bsp/<target>/meta-user` layer (priority 6, below
`meta-user` at 7, so a target can override anything here).

Contents:

* `conf/layer.conf` -- the layer definition (scarthgap). It also sets `NVREC_REPO_ROOT`, the
  repository root, from which the recipes take their sources.
* `recipes-kernel/nvrec-mod/` -- the out-of-tree `nvrec` kernel module (`module.bbclass`;
  sources `sw/nvrec-driver/` and `include/`), auto-loaded at boot. It binds the
  `opsero,nvrec` node (nvrec_core + NVMe Host Accelerator), claims the NVMe SSDs behind the
  design's PCIe root ports, exposes `/dev/nvrecXn1` block devices and `/dev/nvrec`. The
  recipe also installs `/etc/modprobe.d/nvrec-blacklist-nvme.conf`, which keeps udev from
  autoloading the stock `nvme` driver (still loadable by hand for reference tests).
* `recipes-apps/nvrec-apps/` -- `nvrec`, `nvplay`, `nvverify`, `nvbench.sh` and
  `nvsetup-raid0.sh` (sources `sw/nvrec-apps/` and `include/`). The default target name
  written into recording headers is derived from the generated MACHINE (`nvrec-<target>`).
* `recipes-apps/speed-tests/` -- the base FPGA Drive FMC design's dd speed tests
  (copied verbatim from `fpga-drive-aximm-pcie`), for reference figures.
* `recipes-kernel/linux/` -- kernel config fragment `nvrec.cfg`: the stock NVMe driver as a
  module (`CONFIG_BLK_DEV_NVME=m`), CMA, hugetlbfs, md RAID0, exFAT + NLS UTF-8.
* `recipes-core/images/` -- image additions: the module, the apps, `mdadm`, `exfatprogs`,
  `nvme-cli`, `fio`, util-linux tools, `speed-tests`, and the bench tools (SSH server,
  `devmem2`, `i2c-tools`, `ethtool`, `iproute2`, `iperf3`, `phytool`, `pciutils`).

Target-specific parts stay in the target's bsp, because they depend on the XSA:

* the `opsero,nvrec` device-tree node (`bsp/<target>/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`),
* the CMA size on the kernel command line (`NVREC_CMA` -> `BSP_EXTRA_BOOTARGS` in
  `bsp/<target>/conf/local.conf.append`).

`Yocto/scripts/configure-build.sh` adds a target's extra layers from
`bsp/<target>/bblayers-extra.txt` (one repo-root-relative layer path per line), so this
layer is enabled for a target by listing `Yocto/meta-nvrec` there.

The layer depends on `meta-filesystems` (exfatprogs), which the EDF manifest includes.
