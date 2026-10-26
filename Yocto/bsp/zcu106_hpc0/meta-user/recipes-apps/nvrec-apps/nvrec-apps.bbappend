# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# zcu106_hpc0: PCIe MaxPayload 256 bytes on both root ports and both SSDs at
# boot (nvrec-pcie-mps.service, nvrec-mps). Measured on this board with the
# split ring (Gen3 x4): RAID0 playback 6000 MB/s sustained at 256 bytes vs
# 5250 at 128 with two Sabrent Rocket 2230, 5750 vs 5250 with two Samsung
# 980 PRO, recording 6000 vs 5250 (Sabrent), clean 3 of 3, no AER error
# (docs/source/benchmarks.md, "MaxPayload 256"). MaxReadReq stays 512.
# "nvrec-mps 128" switches back until the next boot; NVREC_MPS = "128" here
# keeps the kernel's setting.
NVREC_MPS = "256"
