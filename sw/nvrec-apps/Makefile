# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# FPGA Drive NVMe-offload recorder apps: nvrec, nvplay, nvverify, nvregs,
# nvbench.sh, nvbench-suite.sh, nvsetup-raid0.sh, nvrec-mps.
#
#   make                         build with the system compiler
#   make CC=aarch64-linux-gnu-gcc
#   make install DESTDIR=<root> [PREFIX=/usr]
#
# No library dependencies. NVREC_TARGET sets the default target name written
# into recording headers.

CC ?= gcc
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
NVREC_INCLUDE ?= ../../include
NVREC_TARGET ?= unknown

CFLAGS ?= -O2 -g
# Kept apart from CFLAGS so that a CFLAGS given by a build system (Yocto)
# does not drop the include path.
NVREC_CFLAGS = -Wall -Wextra -std=gnu11 -I$(NVREC_INCLUDE) -DNVREC_TARGET='"$(NVREC_TARGET)"'

PROGS = nvrec nvplay nvverify nvregs
SCRIPTS = nvbench.sh nvbench-suite.sh nvsetup-raid0.sh nvrec-mps
HEADERS = nvrec_common.h nvrec_file.h nvrec_vol.h nvrec_ctl.h $(NVREC_INCLUDE)/nvrec_uapi.h
LIBSRC = nvrec_vol.c nvrec_ctl.c

all: $(PROGS)

nvrec: nvrec.c $(LIBSRC) $(HEADERS)
	$(CC) $(CPPFLAGS) $(NVREC_CFLAGS) $(CFLAGS) -o $@ nvrec.c $(LIBSRC) $(LDFLAGS)

nvplay: nvplay.c $(LIBSRC) $(HEADERS)
	$(CC) $(CPPFLAGS) $(NVREC_CFLAGS) $(CFLAGS) -o $@ nvplay.c $(LIBSRC) $(LDFLAGS)

nvregs: nvregs.c $(NVREC_INCLUDE)/nvrec_regs.h
	$(CC) $(CPPFLAGS) $(NVREC_CFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

nvverify: nvverify.c nvrec_common.h nvrec_file.h
	$(CC) $(CPPFLAGS) $(NVREC_CFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: all
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(PROGS) $(DESTDIR)$(BINDIR)/
	install -m 0755 $(SCRIPTS) $(DESTDIR)$(BINDIR)/

clean:
	rm -f $(PROGS)

.PHONY: all install clean
