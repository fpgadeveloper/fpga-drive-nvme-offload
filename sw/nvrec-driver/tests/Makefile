# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# Host unit tests of the nvrec driver's pure code (not built by Kbuild):
#   make -C sw/nvrec-driver/tests            build + run
NVREC_INCLUDE ?= ../../../include
CC ?= gcc
CFLAGS ?= -O2 -g
TEST_CFLAGS = -Wall -Wextra -Wshadow -std=gnu11 -I$(NVREC_INCLUDE)

all: run

ring_test: ring_test.c ../nvrec_ring.h $(NVREC_INCLUDE)/nvrec_regs.h $(NVREC_INCLUDE)/nvrec_uapi.h
	$(CC) $(TEST_CFLAGS) $(CFLAGS) -o $@ $<

run: ring_test
	./ring_test

clean:
	rm -f ring_test

.PHONY: all run clean
