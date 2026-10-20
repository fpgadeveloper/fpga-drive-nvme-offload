# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Kernel options the NVMe-offload recorder needs on top of the board's bsp.cfg
# (PL PCIe root ports). Notably the stock NVMe driver becomes a MODULE so the
# nvrec driver can own the SSDs (see nvrec.cfg).
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://nvrec.cfg"
KERNEL_FEATURES:append = " nvrec.cfg"
