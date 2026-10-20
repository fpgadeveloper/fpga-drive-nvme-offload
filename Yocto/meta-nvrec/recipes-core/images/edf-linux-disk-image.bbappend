# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# FPGA Drive NVMe-offload recorder additions to the EDF disk image (on top of
# the target's bsp/<target>/meta-user image bbappend).

# The recorder: kernel driver (auto-loaded, stock nvme blacklisted) + apps,
# and what the apps use. nvme-cli and fio are for reference measurements with
# the stock nvme driver (modprobe nvme after unbinding an SSD from nvrec).
NVREC_PACKAGES = " \
    nvrec-mod \
    nvrec-apps \
    mdadm \
    exfatprogs \
    nvme-cli \
    fio \
    util-linux-lsblk \
    util-linux-wipefs \
    util-linux-blkdiscard \
    speed-tests \
"

# Bench tools for bring-up and the autonomous test loop (register access,
# I2C, Ethernet; the in-kernel packet generator pktgen is built in by the base
# kernel config). sshd comes from the ssh-server-openssh image feature. No key
# or password is installed by this layer: provisioning is done over the UART.
NVREC_BENCH_PACKAGES = " \
    devmem2 \
    i2c-tools \
    ethtool \
    iproute2 \
    iperf3 \
    phytool \
    pciutils \
"

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " ${NVREC_PACKAGES} ${NVREC_BENCH_PACKAGES}"
