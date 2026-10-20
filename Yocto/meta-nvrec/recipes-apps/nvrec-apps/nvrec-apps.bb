# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Drive NVMe-offload recorder apps: nvrec, nvplay, nvverify, nvregs, nvbench.sh, nvbench-suite.sh, nvsetup-raid0.sh"
DESCRIPTION = "nvrec records the fabric data stream to a contiguous file on an \
exFAT volume (single SSD or md RAID0) with the hardware NVMe command path, \
nvplay plays a recording back into the fabric checker the same way, nvverify \
checks a recording beat by beat, nvbench.sh sweeps the sustained recording \
rate and nvsetup-raid0.sh prepares the recording volume."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-drive-nvme-offload"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Sources come straight from this repository: sw/nvrec-apps plus the shared
# headers in include/ (NVREC_REPO_ROOT is set by the layer's layer.conf).
FILESEXTRAPATHS:prepend := "${NVREC_REPO_ROOT}:"
SRC_URI = "file://sw/nvrec-apps \
           file://include \
          "
S = "${WORKDIR}/sw/nvrec-apps"

# Default target name written into recording headers: the generated MACHINE
# is "<bd_name>-<target>" = "nvrec-<target>" (Yocto/scripts/configure-build.sh).
NVREC_TARGET ?= "${@d.getVar('MACHINE').replace('nvrec-', '', 1)}"

# CC, CFLAGS and LDFLAGS come from the environment bitbake exports. The
# Makefile's default NVREC_INCLUDE (../../include) resolves to ${WORKDIR}/include.
EXTRA_OEMAKE = "NVREC_TARGET='${NVREC_TARGET}'"

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} PREFIX=${prefix} BINDIR=${bindir}
}

# The machine name is compiled in, so the package is machine specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# nvsetup-raid0.sh: mdadm, mkfs.exfat, blkdiscard, wipefs, lsblk, mountpoint
RDEPENDS:${PN} = "mdadm exfatprogs util-linux-blkdiscard util-linux-wipefs \
                  util-linux-lsblk util-linux-mountpoint util-linux-mount util-linux-umount"

# nvbench-suite.sh (installed by the Makefile's SCRIPTS): the benchmark matrix
# of docs/source/benchmarks.md (bash, flock, findmnt, fsck.exfat; results in
# /var/lib/nvbench)
RDEPENDS:${PN} += "bash util-linux-flock util-linux-findmnt exfatprogs"
