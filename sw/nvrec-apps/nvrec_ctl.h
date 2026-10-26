/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec_ctl.h -- /dev/nvrec helpers shared by nvrec and nvplay.
 */

#ifndef NVREC_CTL_H
#define NVREC_CTL_H

#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "nvrec_uapi.h"
#include "nvrec_vol.h"

extern volatile sig_atomic_t ctl_stop_requested;

/* Exit status of nvrec / nvplay when the NVMe Host Accelerator stopped
 * responding (evaluation license expired): distinct from 1 (failed) and
 * 2 (drops / checker errors). */
#define NVREC_EXIT_HA_DEAD      5
#define NVREC_HA_DEAD_MSG       "Host Accelerator stopped responding (evaluation license expired?): " \
				"reload the bitstream (power-cycle the board) to record again"
extern bool ctl_ha_dead;        /* set by ctl_open() / ctl_run() */
/* exit status for a failed ctl_open() / ctl_run() */
static inline int ctl_exit_code(void) { return ctl_ha_dead ? NVREC_EXIT_HA_DEAD : 1; }
void ctl_install_signals(void);

/* Open /dev/nvrec and read its info (beat_bytes 0 from an old driver -> 16).
 * fabric_only: a fabric-only (DRY) app, which works with a dead Host
 * Accelerator too; it also needs NVREC_CAP_DRY (register map >= 1.2). */
int ctl_open(const char *path, struct nvrec_info *info, bool fabric_only);

/* Fill g->members from a resolved target (disk names -> SSD indices).
 * lba_shift: out, the members' common LBA size. */
int ctl_members(const struct nvrec_info *info, const struct vol_target *t,
		struct nvrec_geometry *g, unsigned *lba_shift,
		char *err, size_t errlen);

/*
 * Ring layout (API 4, register map 1.3): --ring auto|single|split|mem1 and
 * --stripe <KB>|chunk. auto = the driver's default for the run's member
 * count (nvrec_info.ring_default: split over both memories on a design that
 * can, single otherwise and for single-SSD runs unless the driver's
 * ring_split parameter says 1). stripe_kb 0 = the driver's default
 * (nvrec_info.stripe_shift, at most the chunk; NVREC_STRIPE_SHIFT_CHUNK =
 * the whole chunk), CTL_STRIPE_CHUNK = one chunk (slot s in memory s & 1).
 */
#define CTL_STRIPE_CHUNK        UINT32_MAX
int ctl_parse_ring(const char *s, uint32_t *layout);     /* 0 = auto; -1 = invalid */
int ctl_parse_stripe(const char *s, uint32_t *stripe_kb); /* -1 = invalid */
const char *ctl_ring_name(uint32_t layout);              /* "single", "split", "mem1" */
/* The layout a run over `members` SSDs (0 = fabric only) uses: req (0 =
 * auto) resolved and checked against the design; -1 + message when the
 * design cannot (no second memory, memory 1 down) or --stripe does not fit. */
int ctl_ring_layout(const struct nvrec_info *info, uint32_t req, uint32_t stripe_kb,
		    unsigned members, uint32_t *layout);

/*
 * Ring sizing. Default: 512 MB of slots for a single ring, 1 GB for a split
 * ring (half in each memory), i.e. slots = bytes / chunk clamped to
 * CTL_RING_MIN_SLOTS .. min(NVREC_RING_MAX_SLOTS, max_slots): single
 * 2048 x 256 KB, 1024 x 512 KB, 512 x 1 MB, 256 x 2 MB / 4 MB; split
 * 4096 x 256 KB, 2048 x 512 KB, 1024 x 1 MB, 512 x 2 MB, 256 x 4 MB. A 1.2
 * bitstream (2048 slots) gets 2048 x 256 KB = 512 MB. --buffers N
 * overrides it.
 */
#define CTL_RING_DEF_BYTES      (512u << 20)
#define CTL_RING_DEF_BYTES_SPLIT (1024u << 20)
#define CTL_RING_MIN_SLOTS      256u
uint32_t ctl_default_slots(uint32_t chunk, uint32_t max_slots, uint32_t layout);

/* log2 of the stripe SET_RING gets for stripe_kb (0 = the driver's default:
 * 0) for this chunk */
uint32_t ctl_stripe_shift(uint32_t stripe_kb, uint32_t chunk);

/* CMA the driver needs for a ring of slots x chunk: the part in memory 0
 * (the whole ring when single (rounded up to 2 MB), ring A when split,
 * nothing for mem1) plus the per-slot PRP lists (4 KB per slot for chunks of
 * 12 KB .. 2 MB, 8 KB for 4 MB), which are always in memory 0. stripe_shift:
 * the split stripe (log2). prp_bytes / mem1_bytes: out (may be NULL), the
 * PRP list part and the part in memory 1. */
uint64_t ctl_ring_cma_bytes(uint32_t chunk, uint32_t slots, uint32_t layout,
			    uint32_t stripe_shift, uint64_t *prp_bytes, uint64_t *mem1_bytes);

/* ring: driver-allocated (CMA, + memory 1). Fails with a clear message (no
 * ioctl) when the ring exceeds the driver's limits, the memory-1 region or
 * the kernel's whole CMA pool. layout: resolved (ctl_ring_layout). */
int ctl_set_ring(int fd, const struct nvrec_info *info, uint32_t chunk, uint32_t slots,
		 uint32_t layout, uint32_t stripe_kb, struct nvrec_ring *r);
/* "single ring in PS DDR" / "split over 2 memories, 4 KB stripes" / ... */
const char *ctl_ring_describe(const struct nvrec_ring *r, char *buf, size_t len);

struct ctl_run_opts {
	double stats;           /* live stats interval, 0 = off */
	double timeout;         /* abort when no command completes (DRY: no byte
				 * moves) for this long */
	bool quiet;
	bool play;
	bool dry;               /* fabric-only run (NVREC_START_DRY) */
	uint64_t expect_bytes;  /* for the progress percentage */
};

/* Wait for the run to end (SIGINT/SIGTERM -> STOP), print live stats,
 * return the final statistics. 0 = ended, -ETIMEDOUT = stalled (aborted),
 * -ENOLINK = the Host Accelerator stopped responding (run failed, final
 * statistics valid; never for a DRY run), other < 0 = ioctl error. */
int ctl_run(int fd, const struct nvrec_info *info, const struct ctl_run_opts *o,
	    struct nvrec_stats *final);

double ctl_cycles_to_us(const struct nvrec_info *info, uint64_t cycles);
/* dry: a fabric-only run (no command / latency line) */
void ctl_print_summary(const char *prog, const struct nvrec_info *info,
		       const struct nvrec_stats *st, double seconds, bool dry);
/* PCIe MaxPayload in force for the SSDs (bytes): the smallest value
 * programmed on an SSD or its root port (config space; needs root);
 * 0 = unknown. RESULT key mps (nvrec-mps sets it). */
unsigned ctl_pcie_mps(const struct nvrec_info *info);
/* the ring ports' wait times (register map 1.3, two ring ports only) */
void ctl_print_ports(const char *prog, const struct nvrec_info *info,
		     const struct nvrec_stats *st);

/*
 * The machine-readable RESULT line: an app formats its own keys into line[]
 * ("k=v k=v ..."), ctl_result_stats() appends the keys both apps share,
 * ctl_print_result() prints "RESULT <line>" and, with json, the same keys as
 * one JSON object on the next line (numbers as numbers, comma lists as
 * arrays, anything else as a string).
 *
 * ctl_result_stats() appends: lat_min_us lat_count inflight_hwm=<ssd0>,<ssd1>..
 * ring_wait_ms lat_hist=<b0>,..,<b15> lat_bin0_log2 wr_port_stall_ms=<p0>,<p1>
 * rd_port_wait_ms=<p0>,<p1> (register map 1.3: ms the ring writer / reader
 * waited for memory 0 / 1; 0 before) mps (PCIe MaxPayload in force, bytes,
 * 0 = unknown); with CTL_RES_LAT also lat_avg_us
 * lat_max_us ring_hwm (nvrec has those among its own keys).
 * ctl_result_ring() appends ring_slots ring_bytes ring=<single|split|mem1>
 * stripe_kb (0 unless split) ring_mem1_bytes (the ring the driver set up);
 * both apps call it last, so these are the last keys of the line.
 */
#define CTL_RES_LAT             (1u << 0)
#define CTL_RESULT_MAX          2048
void ctl_result_stats(char *line, size_t len, const struct nvrec_info *info,
		      const struct nvrec_stats *st, unsigned flags);
void ctl_result_ring(char *line, size_t len, const struct nvrec_ring *r);
void ctl_print_result(const char *line, bool json);

#endif /* NVREC_CTL_H */
