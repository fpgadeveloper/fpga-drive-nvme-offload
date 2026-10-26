# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Drive NVMe-offload recorder apps: nvrec, nvplay, nvverify, nvregs, nvbench.sh, nvbench-suite.sh, nvsetup-raid0.sh, nvrec-mps"
DESCRIPTION = "nvrec records the fabric data stream to a contiguous file on an \
exFAT volume (single SSD or md RAID0) with the hardware NVMe command path, \
nvplay plays a recording back into the fabric checker the same way, nvverify \
checks a recording word by word, nvbench.sh sweeps the sustained recording \
rate and nvsetup-raid0.sh prepares the recording volume."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-drive-nvme-offload"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Released together with the driver (nvrec-mod); 1.1: fabric beat size from
# the driver (16, 32 or 64 bytes), nvrec --no-write, nvplay --ring-only,
# nvverify per 16-byte word (nvrec and fdrec files), beat-aware benches.
# 1.2 (uapi API 4, driver 1.2): nvrec / nvplay --ring single|split|mem1 and
# --stripe, ring layout and port wait times in RESULT, nvbench-suite v3
# (--ring / --stripe A/B), nvregs with the register map 1.3 registers,
# nvrec-mps (PCIe MaxPayload) and its boot service.
PV = "1.2"

# Sources come straight from this repository: sw/nvrec-apps plus the shared
# headers in include/ (NVREC_REPO_ROOT is set by the layer's layer.conf);
# the systemd unit from files/.
FILESEXTRAPATHS:prepend := "${NVREC_REPO_ROOT}:${THISDIR}/files:"
SRC_URI = "file://sw/nvrec-apps \
           file://include \
           file://nvrec-pcie-mps.service \
          "
S = "${WORKDIR}/sw/nvrec-apps"

# PCIe MaxPayload (bytes) that nvrec-pcie-mps.service sets on the nvrec SSDs
# and their root ports at boot (nvrec-mps boot, /etc/default/nvrec-mps).
# 128 = the kernel's setting is kept and the service is not enabled; a
# target's bsp sets 256 where it was measured to help (vck190_fmcp1 and
# zcu106_hpc0: bsp/<target>/meta-user/recipes-apps/nvrec-apps/nvrec-apps.bbappend;
# uzev keeps 128).
NVREC_MPS ?= "128"

inherit systemd
SYSTEMD_SERVICE:${PN} = "nvrec-pcie-mps.service"
SYSTEMD_AUTO_ENABLE:${PN} = "${@'disable' if d.getVar('NVREC_MPS') == '128' else 'enable'}"

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
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/nvrec-pcie-mps.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/default
    printf '# PCIe MaxPayload for the nvrec SSDs at boot (nvrec-pcie-mps.service, nvrec-mps):\n# 128 = keep the kernel setting, 256 or 512 = set it (both ends must support it)\nNVREC_MPS=%s\n' \
        "${NVREC_MPS}" > ${D}${sysconfdir}/default/nvrec-mps
}
FILES:${PN} += "${systemd_system_unitdir}/nvrec-pcie-mps.service ${sysconfdir}/default/nvrec-mps"
CONFFILES:${PN} += "${sysconfdir}/default/nvrec-mps"

# The machine name is compiled in, so the package is machine specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# nvsetup-raid0.sh: mdadm, mkfs.exfat, blkdiscard, wipefs, lsblk, mountpoint
RDEPENDS:${PN} = "mdadm exfatprogs util-linux-blkdiscard util-linux-wipefs \
                  util-linux-lsblk util-linux-mountpoint util-linux-mount util-linux-umount"

# nvbench-suite.sh (installed by the Makefile's SCRIPTS): the benchmark matrix
# of docs/source/benchmarks.md (bash, flock, findmnt, fsck.exfat, pkill for
# the drive temperature guard; results in /var/lib/nvbench)
RDEPENDS:${PN} += "bash util-linux-flock util-linux-findmnt exfatprogs procps"

# nvrec-mps (and the suite's per-drive MaxPayload): setpci
RDEPENDS:${PN} += "pciutils"
