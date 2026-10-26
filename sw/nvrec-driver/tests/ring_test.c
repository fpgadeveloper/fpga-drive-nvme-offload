// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * ring_test.c -- host unit test of the split-ring address function and the
 * PRP lists the driver builds from it (../nvrec_ring.h, the code nvrec.ko
 * compiles), against an independent model of the hardware:
 *
 *   - the ring writer: every 4 KB page g of the ring goes to the address of
 *     the register-map formula, written here from its definition
 *       i = g >> S, r = i & 1, ADDR = BASE[r] + ((i >> 1) << S) + (g mod 2^S)
 *     The page must land inside the part of memory r the driver allocates
 *     (nvrec_ring_part_bytes), no page twice, every byte of both parts used;
 *   - an SSD: for every slot, PRP1 = ADDR(slot * chunk) (what nvrec_cmd puts
 *     in the SQE) and the PRP list walked by the NVMe rules (512 entries
 *     per 4 KB list page, the last one a pointer when more follow) must
 *     reach exactly the pages the writer filled for that slot, in order,
 *     every entry 4 KB aligned, the list inside the slot's stride.
 *
 * Rings: 64 KB .. 4 MB chunks, the full 1 GB rings of the reference designs
 * (4096 x 256 KB, 2048 x 512 KB, ...), odd and tiny slot counts; stripes
 * S = 12, 16 and log2(chunk); single, split and memory-1 layouts; memory 1
 * at the VCK190 (0x600_0000_0000, 43 bits) and ZCU106 (0x20_0000_0000) addresses,
 * memory 0 below and above 4 GB (VCK190's DDR4 also has 0x500_0000_0000).
 *
 *   make -C sw/nvrec-driver/tests && sw/nvrec-driver/tests/ring_test
 */
#include <endian.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvrec_regs.h"
#include "nvrec_uapi.h"         /* <linux/types.h>: __le64 */

/* what the kernel provides to nvrec_ring.h */
typedef uint32_t u32;
typedef uint64_t u64;
#define cpu_to_le64(x) ((__le64)htole64(x))
#define le64_to_cpu(x) ((u64)le64toh(x))

#include "../nvrec_ring.h"

#define PAGE 4096ull
#define NONE UINT64_MAX

static unsigned long checks, failures;

#define CHECK(cond, ...) do {						\
	checks++;							\
	if (!(cond)) {							\
		if (++failures <= 20) {					\
			fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
			fprintf(stderr, __VA_ARGS__);			\
			fputc('\n', stderr);				\
		}							\
		return -1;						\
	}								\
} while (0)

/* the register map's ADDR(g), from its definition (not the header macros) */
static u64 ref_addr(u32 layout, u64 b0, u64 b1, u32 s, u64 g)
{
	u64 i;

	if (layout == NVREC_RING_MEM1)
		return b1 + g;
	if (layout == NVREC_RING_SINGLE)
		return b0 + g;
	i = g >> s;
	return ((i & 1) ? b1 : b0) + ((i >> 1) << s) + (g & ((1ull << s) - 1));
}

struct mem {
	u64 base, bytes;
	u64 *tag;               /* per 4 KB page: ring page stored there */
};

/* address -> page tag slot, NULL when outside both allocations */
static u64 *tag_at(struct mem *m, u64 addr)
{
	int r;

	for (r = 0; r < 2; r++)
		if (m[r].bytes && addr >= m[r].base && addr < m[r].base + m[r].bytes)
			return &m[r].tag[(addr - m[r].base) / PAGE];
	return NULL;
}

static int run(u32 chunk, u32 slots, u32 layout, u32 s, u64 b0, u64 b1)
{
	u64 total = (u64)slots * chunk, pages = total / PAGE, p, part[2];
	u32 ppc = chunk / PAGE, shift = nvrec_prp_shift(chunk), per_list = 1u << shift;
	/* PRP lists in memory 0 (PS DDR), behind ring A: below 4 GB, or high */
	u64 list_base = b0 >> 32 ? b0 + 0x80000000ull : 0x10000000ull;
	struct nvrec_ring_map map = { .base0 = b0, .base1 = b1, .layout = layout, .shift = s };
	struct mem m[2];
	__le64 *lists;
	u32 slot, k, r;
	int ret = -1;

	memset(m, 0, sizeof(m));
	for (r = 0; r < 2; r++)
		part[r] = nvrec_ring_part_bytes(layout, total, s, r);
	lists = calloc((size_t)slots, per_list);
	if (!lists) {
		perror("calloc");
		exit(2);
	}

	/* the parts: both together the ring, split = NVREC_RING_HALF_BYTES,
	 * 4 KB multiples (one stripe more in memory 0 for an odd stripe count) */
	if (part[0] + part[1] != total || part[0] % PAGE || part[1] % PAGE) {
		fprintf(stderr, "FAIL parts %" PRIu64 " + %" PRIu64 " != %" PRIu64 "\n", part[0], part[1], total);
		failures++;
		goto out;
	}
	checks++;
	if (layout == NVREC_RING_SPLIT) {
		u64 stripes = total >> s;

		if (part[0] != NVREC_RING_HALF_BYTES(0ull, total, s) ||
		    part[1] != NVREC_RING_HALF_BYTES(1ull, total, s) ||
		    part[0] != ((stripes + 1) / 2) << s || part[1] != (stripes / 2) << s) {
			fprintf(stderr, "FAIL split parts %" PRIu64 "/%" PRIu64 "\n", part[0], part[1]);
			failures++;
			goto out;
		}
		checks++;
	}
	for (r = 0; r < 2; r++) {
		m[r].base = r ? b1 : b0;
		m[r].bytes = part[r];
		m[r].tag = malloc((part[r] / PAGE + 1) * sizeof(u64));
		if (!m[r].tag) {
			perror("malloc");
			exit(2);
		}
		memset(m[r].tag, 0xff, (part[r] / PAGE + 1) * sizeof(u64));
	}

	/* 1. the ring writer: page p of the ring (g = p * 4 KB) */
	for (p = 0; p < pages; p++) {
		u64 g = p * PAGE, a = ref_addr(layout, b0, b1, s, g), *t;

		/* the driver's function and the header macros agree with it */
		if (nvrec_ring_map_addr(&map, g) != a || nvrec_ring_map_addr(&map, g + 4095) != a + 4095) {
			fprintf(stderr, "FAIL addr g=0x%" PRIx64 ": driver 0x%" PRIx64 " model 0x%" PRIx64 "\n",
				g, nvrec_ring_map_addr(&map, g), a);
			failures++;
			goto out;
		}
		/* a page never straddles a stripe: byte 4095 follows byte 0 */
		if (ref_addr(layout, b0, b1, s, g + 4095) != a + 4095 || a % PAGE) {
			fprintf(stderr, "FAIL page 0x%" PRIx64 " not linear / aligned\n", g);
			failures++;
			goto out;
		}
		t = tag_at(m, a);
		if (!t || *t != NONE) {
			fprintf(stderr, "FAIL page %" PRIu64 " -> 0x%" PRIx64 ": %s\n", p, a,
				t ? "written twice" : "outside the allocated parts");
			failures++;
			goto out;
		}
		*t = p;
	}
	checks += pages;
	/* every page of both parts used (the parts are exact) */
	for (r = 0; r < 2; r++)
		for (p = 0; p < part[r] / PAGE; p++)
			CHECK(m[r].tag[p] != NONE, "memory %u page %" PRIu64 " never written", r, p);

	/* 2. the driver's PRP lists, 3. an SSD reading every slot through them */
	for (slot = 0; slot < slots; slot++) {
		u64 ldma = list_base + (u64)slot * per_list, ptr = ldma, *t;
		__le64 *list = lists + (size_t)slot * per_list / 8;
		u32 n = nvrec_prp_fill(list, ldma, &map, slot, chunk), left = ppc - 1, used = 0;

		CHECK(n <= per_list / 8, "slot %u: %u entries > stride %u", slot, n, per_list / 8);
		/* PRP1 = ADDR(slot * chunk) (hardware) -> page 0 of the slot */
		t = tag_at(m, ref_addr(layout, b0, b1, s, (u64)slot * chunk));
		CHECK(t && *t == (u64)slot * ppc, "slot %u: PRP1 page", slot);
		for (k = 1; left; ) {
			u64 idx = (ptr - ldma) / 8, e;

			CHECK(ptr >= ldma && ptr < ldma + per_list && idx < n,
			      "slot %u: list read at 0x%" PRIx64 " outside its %u entries", slot, ptr, n);
			e = le64_to_cpu(list[idx]);
			used++;
			if (ptr % PAGE == PAGE - 8 && left > 1) {
				/* last entry of a list page with more to come: the next page */
				CHECK(e % PAGE == 0 && e == ptr + 8, "slot %u: chain 0x%" PRIx64, slot, e);
				ptr = e;
				continue;
			}
			CHECK(e % PAGE == 0, "slot %u: entry 0x%" PRIx64 " not 4 KB aligned", slot, e);
			t = tag_at(m, e);
			CHECK(t && *t == (u64)slot * ppc + k, "slot %u page %u: entry 0x%" PRIx64 " holds ring page %" PRId64,
			      slot, k, e, t ? (int64_t)*t : -1);
			k++;
			left--;
			ptr += 8;
		}
		CHECK(used == n, "slot %u: the SSD used %u of %u entries", slot, used, n);
	}
	ret = 0;
out:
	for (r = 0; r < 2; r++)
		free(m[r].tag);
	free(lists);
	return ret;
}

static const char *lname(u32 l)
{
	return l == NVREC_RING_SPLIT ? "split" : l == NVREC_RING_MEM1 ? "mem1" : "single";
}

int main(void)
{
	/* chunk, slot counts (the reference designs' 1 GB rings, odd, tiny) */
	static const struct { u32 chunk, slots[4]; } cfg[] = {
		{ 64u << 10,  { 4096, 4095, 2, 3 } },
		{ 256u << 10, { 4096, 4095, 2048, 3 } },
		{ 512u << 10, { 2048, 2047, 1024, 2 } },
		{ 1u << 20,   { 1024, 1023, 512, 3 } },
		{ 4u << 20,   { 256, 255, 2, 3 } },
	};
	static const u32 layouts[] = { NVREC_RING_SINGLE, NVREC_RING_SPLIT, NVREC_RING_MEM1 };
	/* memory 0 (CMA in PS DDR: low 2 GB, or VCK190's DDR_CH1 at 0x500_0000_0000),
	 * memory 1: VCK190 LPDDR4 (DDR_CH2) / ZCU106 PL DDR4 */
	static const u64 mem0[] = { 0x40000000ull, 0x50000000000ull };
	static const u64 mem1[] = { 0x60000000000ull, 0x2000000000ull };
	unsigned c, j, l, si, b, runs = 0, bad = 0;

	/* the header macros = the definition, random 40-bit g, every stripe */
	srand(1);
	for (j = 0; j < 1000000; j++) {
		u64 g = ((u64)rand() << 20 ^ (u64)rand()) & 0xffffffffffull;
		u32 s = 12 + j % 11;

		if (NVREC_RING_MEM(g, s) != ((g >> s) & 1) ||
		    NVREC_RING_OFF(g, s) != (((g >> s) >> 1) << s) + (g & ((1ull << s) - 1))) {
			fprintf(stderr, "FAIL macros g=0x%" PRIx64 " s=%u\n", g, s);
			return 1;
		}
	}
	checks += 1000000;

	/* the stripe SET_RING uses: request (0 = default, CHUNK, 12..chunk),
	 * default (a shift or CHUNK), capped at the chunk; 0 = refused */
	{
		static const struct { u32 req, def, cs, want; } st[] = {
			{ 0, 12, 19, 12 }, { 0, 16, 19, 16 }, { 0, 16, 16, 16 },
			{ 0, 22, 19, 19 },              /* a 4 MB default on 512 KB chunks */
			{ 0, NVREC_STRIPE_SHIFT_CHUNK, 18, 18 },  /* zcu106_hpc0: chunk */
			{ 0, NVREC_STRIPE_SHIFT_CHUNK, 22, 22 },
			{ NVREC_STRIPE_SHIFT_CHUNK, 12, 19, 19 },
			{ 12, NVREC_STRIPE_SHIFT_CHUNK, 19, 12 },
			{ 19, 12, 19, 19 }, { 20, 12, 19, 0 },     /* stripe > chunk */
			{ 11, 12, 19, 0 }, { 1, 12, 19, 0 },       /* < 4 KB */
		};

		for (j = 0; j < sizeof(st) / sizeof(st[0]); j++) {
			u32 got = nvrec_ring_stripe(st[j].req, st[j].def, st[j].cs);

			checks++;
			if (got != st[j].want) {
				fprintf(stderr, "FAIL stripe req %u def %u chunk 2^%u: %u, want %u\n",
					st[j].req, st[j].def, st[j].cs, got, st[j].want);
				failures++;
			}
		}
	}

	/* whole-chunk stripes: the slot count the driver uses is even, and with
	 * it member m (= (start_chunk + c) mod 2 for chunk c) always writes
	 * memory m ^ (start_chunk & 1); an odd count would break the pairing */
	{
		u32 n, start, broke_odd = 0;

		for (n = 2; n <= 4097; n = n < 40 ? n + 1 : n * 2 + 1) {
			u32 eff = nvrec_ring_slots(n, NVREC_RING_SPLIT, 19, 19);

			checks++;
			if ((eff & 1) || eff > n || eff < 2 || n - eff > 1 ||
			    nvrec_ring_slots(n, NVREC_RING_SPLIT, 12, 19) != n ||
			    nvrec_ring_slots(n, NVREC_RING_SINGLE, 0, 19) != n ||
			    nvrec_ring_slots(n, NVREC_RING_MEM1, 0, 19) != n) {
				fprintf(stderr, "FAIL slots %u -> %u\n", n, eff);
				failures++;
			}
			for (start = 0; start < 4; start++) {
				u32 cnt[2] = { eff, n }, k;

				for (k = 0; k < 2; k++) {
					u64 ch, miss = 0;

					for (ch = 0; ch < 3ull * cnt[k] + 7; ch++) {
						u32 mem = (u32)((ch % cnt[k]) & 1);   /* slot parity */
						u32 member = (u32)((start + ch) % 2);

						if (mem != (member ^ (start & 1)))
							miss++;
					}
					checks++;
					if (k == 0 && miss) {
						fprintf(stderr, "FAIL pairing: %u slots, start %u\n", eff, start);
						failures++;
					}
					if (k == 1 && (n & 1) && miss)
						broke_odd++;
				}
			}
		}
		checks++;
		if (!broke_odd) {
			fprintf(stderr, "FAIL: odd slot counts never broke the pairing (model wrong)\n");
			failures++;
		}
	}

	for (c = 0; c < sizeof(cfg) / sizeof(cfg[0]); c++) {
		u32 chunk = cfg[c].chunk, cs = 0;
		u32 shifts[3];

		while ((1u << cs) < chunk)
			cs++;
		shifts[0] = 12;
		shifts[1] = 16;
		shifts[2] = cs;
		for (j = 0; j < 4; j++) {
			for (l = 0; l < 3; l++) {
				for (si = 0; si < 3; si++) {
					u32 s = shifts[si];

					if (layouts[l] != NVREC_RING_SPLIT && si)
						continue;       /* the stripe only matters split */
					if (si == 1 && s >= cs)
						continue;       /* 64 KB chunks: S = 16 is the chunk */
					for (b = 0; b < 2; b++) {
						int r = run(chunk, cfg[c].slots[j], layouts[l],
							    layouts[l] == NVREC_RING_SPLIT ? s : 0,
							    mem0[b], mem1[b]);

						runs++;
						if (r) {
							bad++;
							fprintf(stderr, "  ^ chunk %u KB, %u slots, %s, stripe %u KB, mem1 0x%" PRIx64 "\n",
								chunk >> 10, cfg[c].slots[j], lname(layouts[l]),
								layouts[l] == NVREC_RING_SPLIT ? 1u << (s - 10) : 0, mem1[b]);
						}
					}
				}
			}
		}
		printf("chunk %4u KB: PRP stride %u KB, rings of %u/%u/%u/%u slots: done\n", chunk >> 10,
		       1u << (nvrec_prp_shift(chunk) - 10), cfg[c].slots[0], cfg[c].slots[1],
		       cfg[c].slots[2], cfg[c].slots[3]);
	}
	printf("%u ring layouts, %lu checks, %lu failures: %s\n", runs, checks, failures,
	       bad || failures ? "FAIL" : "PASS");
	return bad || failures ? 1 : 0;
}
