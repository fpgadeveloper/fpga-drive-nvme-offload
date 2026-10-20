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

int ctl_open(const char *path, struct nvrec_info *info);

/* Fill g->members from a resolved target (disk names -> SSD indices).
 * lba_shift: out, the members' common LBA size. */
int ctl_members(const struct nvrec_info *info, const struct vol_target *t,
		struct nvrec_geometry *g, unsigned *lba_shift,
		char *err, size_t errlen);

/*
 * Ring sizing. Default: 256 MB of slots, i.e. slots = 256 MB / chunk clamped
 * to CTL_RING_MIN_SLOTS .. min(NVREC_RING_MAX_SLOTS, max_slots):
 * 1024 x 256 KB, 512 x 512 KB, 256 x 1 MB (and 256 x 2/4 MB = 512 MB/1 GB).
 * --buffers N overrides it.
 */
#define CTL_RING_DEF_BYTES      (256u << 20)
#define CTL_RING_MIN_SLOTS      256u
uint32_t ctl_default_slots(uint32_t chunk, uint32_t max_slots);

/* CMA the driver needs for a ring of slots x chunk: the ring (rounded up to
 * 2 MB) plus the per-slot PRP lists (4 KB per slot for chunks of 12 KB ..
 * 2 MB, 8/16 KB for 4 MB). prp_bytes: out, the PRP list part (may be NULL). */
uint64_t ctl_ring_cma_bytes(uint32_t chunk, uint32_t slots, uint64_t *prp_bytes);

/* ring: driver-allocated (CMA). Fails with a clear message (no ioctl) when
 * the ring exceeds NVREC_RING_MAX_BYTES or the kernel's whole CMA pool. */
int ctl_set_ring(int fd, uint32_t chunk, uint32_t slots, struct nvrec_ring *r);

struct ctl_run_opts {
	double stats;           /* live stats interval, 0 = off */
	double timeout;         /* abort when no command completes for this long */
	bool quiet;
	bool play;
	uint64_t expect_bytes;  /* for the progress percentage */
};

/* Wait for the run to end (SIGINT/SIGTERM -> STOP), print live stats,
 * return the final statistics. 0 = ended, -ETIMEDOUT = stalled (aborted),
 * -ENOLINK = the Host Accelerator stopped responding (run failed, final
 * statistics valid), other < 0 = ioctl error. */
int ctl_run(int fd, const struct nvrec_info *info, const struct ctl_run_opts *o,
	    struct nvrec_stats *final);

double ctl_cycles_to_us(const struct nvrec_info *info, uint64_t cycles);
void ctl_print_summary(const char *prog, const struct nvrec_info *info,
		       const struct nvrec_stats *st, double seconds);

/*
 * The machine-readable RESULT line: an app formats its own keys into line[]
 * ("k=v k=v ..."), ctl_result_stats() appends the keys both apps share,
 * ctl_print_result() prints "RESULT <line>" and, with json, the same keys as
 * one JSON object on the next line (numbers as numbers, comma lists as
 * arrays, anything else as a string).
 *
 * ctl_result_stats() appends: lat_min_us lat_count inflight_hwm=<ssd0>,<ssd1>..
 * ring_wait_ms lat_hist=<b0>,..,<b15> lat_bin0_log2; with CTL_RES_LAT also
 * lat_avg_us lat_max_us ring_hwm (nvrec has those among its own keys).
 * ctl_result_ring() appends ring_slots ring_bytes (the ring the driver set
 * up); both apps call it last, so these are the last keys of the line.
 */
#define CTL_RES_LAT             (1u << 0)
#define CTL_RESULT_MAX          2048
void ctl_result_stats(char *line, size_t len, const struct nvrec_info *info,
		      const struct nvrec_stats *st, unsigned flags);
void ctl_result_ring(char *line, size_t len, const struct nvrec_ring *r);
void ctl_print_result(const char *line, bool json);

#endif /* NVREC_CTL_H */
