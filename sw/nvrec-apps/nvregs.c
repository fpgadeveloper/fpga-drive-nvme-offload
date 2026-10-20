// SPDX-License-Identifier: MIT
/*
 * nvregs -- debug dump of the nvrec_core and nvmeha registers through
 * /dev/mem (root). Bring-up / support tool; the driver need not be loaded.
 *
 *   nvregs                 dump the run, per-SSD, injector, doorbell monitor
 *                          and nvmeha status registers
 *   nvregs rd core|ha OFF  read one 32-bit register
 *   nvregs wr core|ha OFF VAL  write one (careful: live hardware)
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "nvrec_regs.h"

static volatile uint32_t *core, *ha;

static uint32_t rc(uint32_t o) { return core[o / 4]; }
static int ha_dead;
/* nvmeha register: not touched once nvrec_core reports it dead (with the
 * 1.1 guard a read would only return 0xFFFFFFFF, without it the CPU hangs) */
static uint32_t rh(uint32_t o) { return ha_dead ? 0xFFFFFFFFu : ha[o / 4]; }
static uint64_t rc64(uint32_t lo) { uint32_t l = rc(lo); return ((uint64_t)rc(lo + 4) << 32) | l; }

static volatile uint32_t *map(int fd, uint64_t base, size_t len)
{
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)base);

	if (p == MAP_FAILED) {
		fprintf(stderr, "nvregs: mmap 0x%" PRIx64 ": %s\n", base, strerror(errno));
		exit(1);
	}
	return p;
}

#define C(n) printf("  %-22s 0x%08x\n", #n, rc(NVREC_##n))
#define C64(n) printf("  %-22s %" PRIu64 "\n", #n, rc64(NVREC_##n##_LO))

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	unsigned int s, i;

	if (fd < 0) {
		perror("nvregs: /dev/mem");
		return 1;
	}
	core = map(fd, NVREC_CORE_BASE_ZYNQMP, NVREC_REG_SPAN);
	ha = map(fd, NVREC_NVMEHA_LITE_BASE_ZYNQMP, 0x10000);

	if (argc >= 4 && (!strcmp(argv[1], "rd") || !strcmp(argv[1], "wr"))) {
		volatile uint32_t *b = !strcmp(argv[2], "ha") ? ha : core;
		uint32_t off = strtoul(argv[3], NULL, 0);

		if (argv[1][0] == 'w' && argc >= 5)
			b[off / 4] = strtoul(argv[4], NULL, 0);
		printf("0x%08x\n", b[off / 4]);
		return 0;
	}
	if (argc > 1) {
		fprintf(stderr, "usage: nvregs | nvregs rd core|ha OFF | nvregs wr core|ha OFF VAL\n");
		return 2;
	}
	printf("nvrec_core ID 0x%08x VERSION 0x%08x\n", rc(NVREC_ID), rc(NVREC_VERSION));
	ha_dead = rc(NVREC_VERSION) >= NVREC_VERSION_1_1 && (rc(NVREC_STATE) & NVREC_STATE_HA_DEAD);
	if (ha_dead)
		printf("Host Accelerator: NOT RESPONDING (STATE.HA_DEAD; evaluation license expired?) -- its registers are not read\n");
	C(STATE); C(RUN_FIFO_HWM); C(ING_FIFO_HWM); C(CONFIG); C(IRQ_STATUS); C(IRQ_ENABLE); C(TPG_CTRL); C(ING_STATUS);
	C64(ING_DROP_COUNT); C64(RUN_DROP_COUNT); C64(ING_BEATS_IN); C64(ING_BEATS_OUT);
	C(RING_BASE_LO); C(RING_BASE_HI); C(NUM_CHUNKS); C(CHUNK_SIZE); C(PRP_LIST_BASE_LO);
	C(PRP_LIST_SHIFT); C(LBA_SHIFT); C(LENGTH_CHUNKS); C(CREDIT_INIT);
	C64(CHUNKS_FILLED); C64(CMDS_ISSUED); C64(CMDS_DONE); C(CMD_ERRORS); C(UNEXPECTED_CQES);
	C64(BYTES); C(RING_FILL); C(RING_HWM); C(ERR_LAST_STATUS); C(ERR_LAST_CID);
	C64(CHUNKS_RELEASED); C(LAT_MIN); C(LAT_MAX); C(LAT_COUNT);
	C64(CHK_BEATS); C64(CHK_ERRORS); C64(CHK_UNDERFLOWS);
	for (i = 0; i < 2; i++)
		printf("  member%u nsid %u sel 0x%x base_lba %" PRIu64 "\n", i,
		       rc(NVREC_MEMBER_NSID(i)), rc(NVREC_MEMBER_SEL(i)),
		       ((uint64_t)rc(NVREC_MEMBER_BASE_LBA_HI(i)) << 32) | rc(NVREC_MEMBER_BASE_LBA_LO(i)));
	for (s = 0; s < NVREC_NVMEHA_NUM_SSD; s++)
		printf("  SSD%u maxinf %u inflight %u hwm %u credits %u issued %u completed %u errors %u | HA base 0x%08x_%08x SQ 0x%08x CQ 0x%08x issued %u compl %u err %u qstatus 0x%08x\n",
		       s, rc(NVREC_SSD_MAX_INFLIGHT(s)), rc(NVREC_SSD_INFLIGHT(s)),
		       rc(NVREC_SSD_INFLIGHT_HWM(s)), rc(NVREC_SSD_CREDITS(s)), rc(NVREC_SSD_ISSUED(s)),
		       rc(NVREC_SSD_COMPLETED(s)), rc(NVREC_SSD_ERRORS(s)),
		       rh(NVMEHA_SSD_PCIE_BASE_HI(s)), rh(NVMEHA_SSD_PCIE_BASE_LO(s)),
		       rh(NVMEHA_SQ_BASE_RB(s, 0)), rh(NVMEHA_CQ_BASE_RB(s, 0)),
		       rh(NVMEHA_SSD_ISSUED(s)), rh(NVMEHA_SSD_COMPLETED(s)), rh(NVMEHA_SSD_ERR_COMPL(s)),
		       rh(NVMEHA_QSTATUS(s, 0)));
	printf("injector: status 0x%08x submitted %u completed %u\n", rc(NVREC_INJ_STATUS),
	       rc(NVREC_INJ_SUBMITTED), rc(NVREC_INJ_COMPLETED));
	printf("nvmeha: int_en 0x%08x int_st 0x%08x cmd_err %u timeout %u\n", rh(NVMEHA_INT_ENABLE),
	       rh(NVMEHA_INT_STATUS), rh(NVMEHA_CMD_ERR_COUNT), rh(NVMEHA_TIMEOUT));
	printf("doorbells: count %u next %u\n", rc(NVREC_DB_COUNT), rc(NVREC_DB_NEXT));
	for (i = 0; i < NVREC_DB_ENTRIES; i++) {
		unsigned int k = (rc(NVREC_DB_NEXT) + i) % NVREC_DB_ENTRIES;

		printf("  [%u] addr 0x%08x data 0x%08x\n", k, rc(NVREC_DB_ADDR(k)), rc(NVREC_DB_DATA(k)));
	}
	return 0;
}
