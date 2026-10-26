# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# vck190_fmcp1: PCIe MaxPayload 256 bytes on both root ports and both SSDs at
# boot (nvrec-pcie-mps.service, nvrec-mps). Measured on this board with the
# split ring (2x Samsung 980 PRO, Gen4 x4): RAID0 playback 10750 MB/s
# sustained at 256 bytes vs 10250 at 128, clean 3 of 3 at the top, no AER
# error (docs/source/benchmarks.md, "MaxPayload 256"). MaxReadReq stays 512.
# "nvrec-mps 128" switches back until the next boot; NVREC_MPS = "128" here
# keeps the kernel's setting.
NVREC_MPS = "256"
