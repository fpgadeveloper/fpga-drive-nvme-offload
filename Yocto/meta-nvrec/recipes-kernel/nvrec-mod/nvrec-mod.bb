# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Drive NVMe-offload recorder kernel driver (nvrec.ko)"
DESCRIPTION = "Out-of-tree driver for nvrec_core and the AMD NVMe Host \
Accelerator: owns the NVMe SSDs behind the design's PCIe root ports (instead \
of the stock nvme driver), exposes them as /dev/nvrecXn1 block devices through \
the IP, and controls the hardware recorder/player through /dev/nvrec."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-drive-nvme-offload"
LICENSE = "GPL-2.0-only | MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6 \
                    file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit module

# Sources come straight from this repository (no fetch): sw/nvrec-driver and
# the shared headers in include/ (nvrec_regs.h, nvrec_uapi.h). Both unpack
# under ${WORKDIR} with their repo-relative paths, so the module's Kbuild
# finds ../../include exactly as in the repo.
FILESEXTRAPATHS:prepend := "${NVREC_REPO_ROOT}:${THISDIR}/files:"
SRC_URI = "file://sw/nvrec-driver \
           file://include \
           file://nvrec-blacklist-nvme.conf \
          "
S = "${WORKDIR}/sw/nvrec-driver"

# Load at boot: binds the "opsero,nvrec" node, then claims the SSDs.
KERNEL_MODULE_AUTOLOAD += "nvrec"

# Keep the stock nvme driver off the SSDs: it is built as a module
# (meta-nvrec's nvrec.cfg) and blacklisted, so udev never autoloads it.
# "modprobe nvme" still works by hand, after unbinding the SSD from nvrec
# (docs/source/driver.md, "Using the stock nvme driver").
do_install:append() {
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/nvrec-blacklist-nvme.conf ${D}${sysconfdir}/modprobe.d/
}
FILES:${PN} += "${sysconfdir}/modprobe.d/nvrec-blacklist-nvme.conf"
CONFFILES:${PN} += "${sysconfdir}/modprobe.d/nvrec-blacklist-nvme.conf"

RPROVIDES:${PN} += "kernel-module-nvrec"
