/* SPDX-License-Identifier: GPL-2.0-only OR MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec_ring.h -- the ring address function of register map 1.3 and the
 * PRP lists built from it. Pure computation, no kernel API: nvrec_main.c
 * uses it, and the host unit test (tests/ring_test.c) compiles the very
 * same code against a model of the hardware.
 *
 * Before including it, a kernel file includes <linux/types.h> and
 * <asm/byteorder.h> (u32, u64, __le64, cpu_to_le64); the host test defines
 * those itself. nvrec_regs.h (NVREC_RING_MEM / NVREC_RING_OFF /
 * NVREC_RING_HALF_BYTES) and nvrec_uapi.h (NVREC_RING_*) come first.
 */

#ifndef NVREC_RING_H
#define NVREC_RING_H

#define NVREC_RING_PAGE         4096u   /* NVMe memory page (CC.MPS = 0) */
#define NVREC_PRP_PER_PAGE      512u    /* 8-byte entries per 4 KB list page */

/* Where the ring is: the bus addresses of its parts and the layout */
struct nvrec_ring_map {
	u64 base0;              /* memory 0 part (SINGLE, SPLIT) */
	u64 base1;              /* memory 1 part (SPLIT, MEM1) */
	u32 layout;             /* NVREC_RING_SINGLE / SPLIT / MEM1 */
	u32 shift;              /* SPLIT: stripe = 2^shift bytes */
};

/* Bus address of ring byte g (g = slot * chunk + offset): the hardware's
 * ADDR(g) of register map 1.3, "Ring addresses" */
static inline u64 nvrec_ring_map_addr(const struct nvrec_ring_map *m, u64 g)
{
	if (m->layout == NVREC_RING_MEM1)
		return m->base1 + g;
	if (m->layout != NVREC_RING_SPLIT)
		return m->base0 + g;
	return (NVREC_RING_MEM(g, m->shift) ? m->base1 : m->base0) +
	       NVREC_RING_OFF(g, m->shift);
}

/*
 * The stripe (log2 bytes) of a split ring of chunks of 2^chunk_shift bytes:
 * req = SET_RING's stripe_shift (0 = the default, NVREC_STRIPE_SHIFT_CHUNK =
 * one chunk, else 12 .. chunk_shift), def = the driver's default (a shift,
 * or NVREC_STRIPE_SHIFT_CHUNK), capped at the chunk. 0 = invalid request.
 */
static inline u32 nvrec_ring_stripe(u32 req, u32 def, u32 chunk_shift)
{
	if (!req)
		return def < chunk_shift ? def : chunk_shift;
	if (req == NVREC_STRIPE_SHIFT_CHUNK)
		return chunk_shift;
	if (req < NVREC_STRIPE_SHIFT_MIN || req > chunk_shift)
		return 0;
	return req;
}

/*
 * The slot count a ring uses: a split ring with whole-chunk stripes (shift
 * = chunk_shift) puts slot s in memory s & 1, and chunk c of a run in slot
 * c mod slots. With an even count the memory of chunk c is c & 1 and its
 * stripe member (start_chunk + c) mod 2, so member m always writes memory
 * m ^ (start_chunk & 1): each SSD touches one memory only. An odd count
 * puts one more slot in memory 0 and flips that pairing at every wrap, so
 * it is rounded down to even (never below 2). Other layouts keep it.
 */
static inline u32 nvrec_ring_slots(u32 slots, u32 layout, u32 shift, u32 chunk_shift)
{
	if (layout == NVREC_RING_SPLIT && shift == chunk_shift && (slots & 1) && slots > 2)
		slots--;
	return slots;
}

/* Bytes of a ring of ring_bytes (slots x chunk) in memory r = 0, 1 */
static inline u64 nvrec_ring_part_bytes(u32 layout, u64 ring_bytes, u32 shift,
					unsigned int r)
{
	if (layout == NVREC_RING_SPLIT)
		return NVREC_RING_HALF_BYTES((u64)r, ring_bytes, shift);
	if (layout == NVREC_RING_MEM1)
		return r ? ring_bytes : 0;
	return r ? 0 : ring_bytes;
}

/* log2 of the per-slot PRP list stride: N = P - 1 entries (pages 1..P-1 of
 * a slot), 512 per 4 KB list page; a longer list chains (511 entries + a
 * pointer on every page but the last), so it needs ceil((N - 1) / 511)
 * pages: 12 up to 2 MB chunks, 13 for 4 MB (1023 entries = 2 pages) */
static inline u32 nvrec_prp_shift(u32 chunk)
{
	u32 n = chunk / NVREC_RING_PAGE - 1, pages = 1, shift = 12;

	if (n > NVREC_PRP_PER_PAGE)
		pages = (n - 1 + NVREC_PRP_PER_PAGE - 2) / (NVREC_PRP_PER_PAGE - 1);
	while ((1u << (shift - 12)) < pages)
		shift++;
	return shift;
}

/*
 * The PRP list of slot `slot`: list = its CPU pointer, list_dma = its bus
 * address (PRP_LIST_BASE + (slot << prp_shift)). Entry k-1 = page k
 * (k = 1 .. P-1) of the slot at ADDR(slot * chunk + k * 4 KB); the last
 * entry of a full list page points to the next list page when more pages
 * follow. The hardware puts ADDR(slot * chunk) in PRP1 and list_dma in
 * PRP2. Returns the number of 8-byte entries written.
 */
static inline u32 nvrec_prp_fill(__le64 *list, u64 list_dma,
				 const struct nvrec_ring_map *m, u32 slot, u32 chunk)
{
	u32 n4k = chunk / NVREC_RING_PAGE, k, e = 0;
	u64 g0 = (u64)slot * chunk;

	for (k = 1; k < n4k; k++) {
		/* last entry of a list page, more to come: chain */
		if (e % NVREC_PRP_PER_PAGE == NVREC_PRP_PER_PAGE - 1 && k < n4k - 1) {
			list[e] = cpu_to_le64(list_dma + (u64)(e + 1) * 8);
			e++;
		}
		list[e++] = cpu_to_le64(nvrec_ring_map_addr(m, g0 + (u64)k * NVREC_RING_PAGE));
	}
	return e;
}

#endif /* NVREC_RING_H */
