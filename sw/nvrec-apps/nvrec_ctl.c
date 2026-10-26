// SPDX-License-Identifier: MIT
/*
 * nvrec_ctl.c -- /dev/nvrec helpers shared by nvrec and nvplay.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <limits.h>
#include <sys/ioctl.h>

#include "nvrec_ctl.h"
#include "nvrec_common.h"

volatile sig_atomic_t ctl_stop_requested;

static void on_signal(int sig)
{
	(void)sig;
	ctl_stop_requested = 1;
}

void ctl_install_signals(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
}

bool ctl_ha_dead;

int ctl_open(const char *path, struct nvrec_info *info, bool fabric_only)
{
	int fd = open(path, O_RDWR | O_CLOEXEC);

	if (fd < 0) {
		perr("%s%s", path, errno == EBUSY ? " (another recorder/player is running)" : "");
		return -1;
	}
	if (ioctl(fd, NVREC_IOC_GET_INFO, info) < 0) {
		perr("NVREC_IOC_GET_INFO");
		close(fd);
		return -1;
	}
	if (info->api_version != NVREC_API_VERSION) {
		err_msg("driver API version %u, this app expects %u", info->api_version,
			NVREC_API_VERSION);
		close(fd);
		return -1;
	}
	if (!info->beat_bytes)
		info->beat_bytes = 16;
	if (fabric_only && !(info->caps & NVREC_CAP_DRY)) {
		err_msg("%s: this design (nvrec_core %u.%u) has no fabric-only mode: it needs register map 1.2",
			path, info->hw_version >> 16, info->hw_version & 0xffff);
		close(fd);
		return -1;
	}
	if ((info->status & NVREC_STATUS_HA_DEAD) && !fabric_only) {
		err_msg("%s", NVREC_HA_DEAD_MSG);
		ctl_ha_dead = true;
		close(fd);
		return -1;
	}
	return fd;
}

int ctl_members(const struct nvrec_info *info, const struct vol_target *t,
		struct nvrec_geometry *g, unsigned *lba_shift,
		char *err, size_t errlen)
{
	unsigned j, i;

	g->nr_members = t->nr_members;
	for (j = 0; j < t->nr_members; j++) {
		const struct nvrec_ssd_info *s = NULL;

		for (i = 0; i < info->nr_ssd && i < NVREC_MAX_SSD; i++)
			if (!strcmp(info->ssd[i].disk, t->m[j].disk) &&
			    info->ssd[i].state != NVREC_SSD_ABSENT)
				s = &info->ssd[i];
		if (!s) {
			snprintf(err, errlen, "%s: member %s is not an nvrec SSD (the hardware recorder only writes to /dev/nvrecXn1)",
				 t->dev, t->m[j].disk);
			return -ENODEV;
		}
		if (s->state != NVREC_SSD_LIVE) {
			snprintf(err, errlen, "%s is not live (controller failed)", s->disk);
			return -ENODEV;
		}
		if (j && s->lba_shift != *lba_shift) {
			snprintf(err, errlen, "members have different LBA sizes");
			return -EINVAL;
		}
		*lba_shift = s->lba_shift;
		if ((t->m[j].base_sector << 9) % (1ull << s->lba_shift)) {
			snprintf(err, errlen, "%s: member start sector %" PRIu64 " is not LBA aligned",
				 s->disk, t->m[j].base_sector);
			return -EINVAL;
		}
		g->members[j].ssd = s->index;
		g->members[j].nsid = s->nsid;
		g->members[j].base_lba = (t->m[j].base_sector << 9) >> s->lba_shift;
	}
	return 0;
}

int ctl_parse_ring(const char *s, uint32_t *layout)
{
	if (!strcmp(s, "auto"))
		*layout = 0;
	else if (!strcmp(s, "single"))
		*layout = NVREC_RING_SINGLE;
	else if (!strcmp(s, "split"))
		*layout = NVREC_RING_SPLIT;
	else if (!strcmp(s, "mem1"))
		*layout = NVREC_RING_MEM1;
	else
		return -1;
	return 0;
}

/* <KB> (4, 64, 4K, 64k: a power of two, 4 .. 4096) or "chunk" */
int ctl_parse_stripe(const char *s, uint32_t *stripe_kb)
{
	char *end;
	unsigned long v;

	if (!strcmp(s, "chunk")) {
		*stripe_kb = CTL_STRIPE_CHUNK;
		return 0;
	}
	errno = 0;
	v = strtoul(s, &end, 10);
	if (*end == 'K' || *end == 'k')
		end++;
	if (errno || end == s || *end || v < 4 || v > NVREC_MAX_CHUNK / 1024 || (v & (v - 1)))
		return -1;
	*stripe_kb = (uint32_t)v;
	return 0;
}

const char *ctl_ring_name(uint32_t layout)
{
	switch (layout) {
	case NVREC_RING_SINGLE: return "single";
	case NVREC_RING_SPLIT: return "split";
	case NVREC_RING_MEM1: return "mem1";
	default: return "auto";
	}
}

int ctl_ring_layout(const struct nvrec_info *info, uint32_t req, uint32_t stripe_kb,
		    unsigned members, uint32_t *layout)
{
	uint32_t l = req ? req : NVREC_RING_DEFAULT(info->ring_default, members);

	if (!l)
		l = NVREC_RING_SINGLE;
	if (l != NVREC_RING_SINGLE) {
		if (!(info->caps & NVREC_CAP_SPLIT_RING)) {
			err_msg("--ring %s: %s", ctl_ring_name(l), info->ring_ports < 2 ?
				"this design has one ring port (single ring only)" :
				"the driver has no memory-1 region (device tree memory-region)");
			return -1;
		}
		if (info->status & NVREC_STATUS_MEM1_DOWN) {
			err_msg("--ring %s: memory 1 is not ready (its memory controller did not calibrate: STATE.MEM1_READY = 0)",
				ctl_ring_name(l));
			return -1;
		}
	}
	if (stripe_kb && l != NVREC_RING_SPLIT) {
		err_msg("--stripe needs a split ring (the ring is %s)", ctl_ring_name(l));
		return -1;
	}
	*layout = l;
	return 0;
}

uint32_t ctl_default_slots(uint32_t chunk, uint32_t max_slots, uint32_t layout)
{
	uint32_t hi = NVREC_RING_MAX_SLOTS, s;

	if (max_slots && max_slots < hi)
		hi = max_slots;
	s = chunk ? (layout == NVREC_RING_SPLIT ? CTL_RING_DEF_BYTES_SPLIT : CTL_RING_DEF_BYTES) / chunk :
		CTL_RING_MIN_SLOTS;
	if (s < CTL_RING_MIN_SLOTS)
		s = CTL_RING_MIN_SLOTS;
	if (s > hi)
		s = hi;
	return s;
}

static uint32_t log2u(uint64_t v)
{
	uint32_t s = 0;

	while (v > 1) {
		v >>= 1;
		s++;
	}
	return s;
}

uint32_t ctl_stripe_shift(uint32_t stripe_kb, uint32_t chunk)
{
	if (!stripe_kb)
		return 0;
	if (stripe_kb == CTL_STRIPE_CHUNK)
		return log2u(chunk);
	return log2u((uint64_t)stripe_kb << 10);
}

uint64_t ctl_ring_cma_bytes(uint32_t chunk, uint32_t slots, uint32_t layout,
			    uint32_t stripe_shift, uint64_t *prp_bytes, uint64_t *mem1_bytes)
{
	uint64_t bytes = (uint64_t)chunk * slots, ring, total, part0, part1, prp = 0;
	uint32_t n = chunk / 4096 - 1, per_list = 4096, pages;

	bytes = (bytes + NVREC_HUGEPAGE - 1) / NVREC_HUGEPAGE * NVREC_HUGEPAGE;
	total = bytes / chunk * chunk;          /* the driver's slots x chunk */
	if (layout == NVREC_RING_SPLIT) {
		/* as the driver (nvrec_ring_part_bytes): memory 0 holds
		 * ceil(stripes / 2) stripes */
		part0 = ((total >> stripe_shift) + 1) / 2 << stripe_shift;
		part1 = total - part0;
		ring = (part0 + 4095) / 4096 * 4096;
	} else if (layout == NVREC_RING_MEM1) {
		part1 = total;
		ring = 0;
	} else {
		part1 = 0;
		ring = bytes;
	}
	/* as nvrec_prp_shift() in the driver: one list per slot of entries
	 * for pages 1..P-1, 512 per 4 KB, chained (511 + link on every page
	 * but the last) beyond that; the stride is a power of two */
	if (n + 1 > 2) {
		if (n > 512) {
			pages = (n - 1 + 510) / 511;
			while (per_list < 4096u * pages)
				per_list <<= 1;
		}
		prp = (bytes / chunk) * per_list;
	}
	if (prp_bytes)
		*prp_bytes = prp;
	if (mem1_bytes)
		*mem1_bytes = part1;
	return ring + prp;
}

/* CmaTotal / CmaFree of /proc/meminfo in bytes; 0 if unknown */
static void cma_info(uint64_t *total, uint64_t *avail)
{
	FILE *f = fopen("/proc/meminfo", "re");
	char line[128];
	unsigned long long kb;

	*total = *avail = 0;
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "CmaTotal: %llu kB", &kb) == 1)
			*total = (uint64_t)kb << 10;
		else if (sscanf(line, "CmaFree: %llu kB", &kb) == 1)
			*avail = (uint64_t)kb << 10;
	}
	fclose(f);
}

int ctl_set_ring(int fd, const struct nvrec_info *info, uint32_t chunk, uint32_t slots,
		 uint32_t layout, uint32_t stripe_kb, struct nvrec_ring *r)
{
	uint64_t need, prp, mem1, total, avail, max;
	uint32_t shift = layout == NVREC_RING_SPLIT ? ctl_stripe_shift(stripe_kb, chunk) : 0;
	int e;

	memset(r, 0, sizeof(*r));
	r->addr = 0;
	r->bytes = (uint64_t)chunk * slots;
	r->chunk = chunk;
	r->flags = layout;
	r->stripe_shift = shift;
	if (r->bytes % NVREC_HUGEPAGE)
		r->bytes = (r->bytes + NVREC_HUGEPAGE - 1) / NVREC_HUGEPAGE * NVREC_HUGEPAGE;
	if (stripe_kb && stripe_kb != CTL_STRIPE_CHUNK && (uint64_t)stripe_kb << 10 > chunk) {
		err_msg("--stripe %u KB is larger than the chunk (%u KB): use at most %u, or 'chunk'",
			stripe_kb, chunk >> 10, chunk >> 10);
		return -1;
	}
	max = layout == NVREC_RING_SPLIT ? NVREC_RING_MAX_BYTES_SPLIT : NVREC_RING_MAX_BYTES;
	if (r->bytes > max) {
		err_msg("%s ring of %u x %u bytes (%" PRIu64 " MB) is larger than the driver's %" PRIu64 " MB limit: use fewer --buffers",
			ctl_ring_name(layout), slots, chunk, (uint64_t)r->bytes >> 20, max >> 20);
		return -1;
	}
	/* the driver's default stripe for the estimate (it caps it at the chunk) */
	need = ctl_ring_cma_bytes(chunk, slots, layout,
				  shift ? shift : (info->stripe_shift < log2u(chunk) ?
						   info->stripe_shift : log2u(chunk)),
				  &prp, &mem1);
	if (mem1 > info->ring1_bytes) {
		err_msg("%s ring of %u x %u bytes puts %" PRIu64 " MB in memory 1, its region has %" PRIu64
			" MB: use fewer --buffers", ctl_ring_name(layout), slots, chunk, mem1 >> 20,
			(uint64_t)info->ring1_bytes >> 20);
		return -1;
	}
	cma_info(&total, &avail);
	if (total && need > total) {
		err_msg("%s ring of %u x %u bytes needs %" PRIu64 " MB of CMA (memory-0 part %" PRIu64
			" MB + PRP lists %" PRIu64 " KB) but the kernel's CMA pool is only %"
			PRIu64 " MB: use fewer --buffers or boot with a larger cma=",
			ctl_ring_name(layout), slots, chunk, (need + (1u << 20) - 1) >> 20,
			(need - prp) >> 20, prp >> 10, total >> 20);
		return -1;
	}
	if (ioctl(fd, NVREC_IOC_SET_RING, r) < 0) {
		e = errno;
		if (e == ENOMEM)
			err_msg("cannot allocate the ring: %u x %u bytes (%s) needs %" PRIu64
				" MB of contiguous CMA (memory-0 part %" PRIu64 " MB + PRP lists %" PRIu64
				" KB); CMA free %" PRIu64 " of %" PRIu64
				" MB: use fewer --buffers or boot with a larger cma=",
				slots, chunk, ctl_ring_name(layout), (need + (1u << 20) - 1) >> 20,
				(need - prp) >> 20, prp >> 10, avail >> 20, total >> 20);
		else
			perr("NVREC_IOC_SET_RING (%u x %u bytes, %s ring)", slots, chunk,
			     ctl_ring_name(layout));
		errno = e;
		return -1;
	}
	/* the ring is a whole number of 2 MB (rounded up above: chunks below
	 * 2 MB give a multiple of 2 MB / chunk slots), and the driver rounds an
	 * odd count of a whole-chunk split ring down to even (2 and 4 MB
	 * chunks): say so when the count used is not the one asked for */
	if (r->slots != slots)
		fprintf(stderr, "%s: note: %u ring slots asked for, %u used (%s)\n", prog_name, slots,
			r->slots, r->slots > slots ? "the ring is a whole number of 2 MB" :
			"a split ring with whole-chunk stripes uses an even count");
	return 0;
}

const char *ctl_ring_describe(const struct nvrec_ring *r, char *buf, size_t len)
{
	if (r->flags == NVREC_RING_SPLIT && r->chunk && r->stripe_shift == log2u(r->chunk))
		snprintf(buf, len, "split over 2 memories, whole-chunk stripes (%u KB)", r->chunk >> 10);
	else if (r->flags == NVREC_RING_SPLIT)
		snprintf(buf, len, "split over 2 memories, %u KB stripes", r->stripe_shift >= 10 ?
			 1u << (r->stripe_shift - 10) : 0);
	else if (r->flags == NVREC_RING_MEM1)
		snprintf(buf, len, "single ring in memory 1");
	else
		snprintf(buf, len, "single ring in memory 0");
	return buf;
}

double ctl_cycles_to_us(const struct nvrec_info *info, uint64_t cycles)
{
	return info->dp_clk_hz ? (double)cycles * 1e6 / (double)info->dp_clk_hz : 0.0;
}

static void print_live(const struct nvrec_info *info, const struct nvrec_stats *st,
		       const struct ctl_run_opts *o, double t, uint64_t prev, double dt)
{
	unsigned i;
	uint32_t inflight = 0;

	for (i = 0; i < NVREC_MAX_SSD; i++)
		inflight += st->ssd[i].inflight;
	fprintf(stderr, "\r%7.1f s  %9.1f MB  %7.1f MB/s  %s%5.1f%%  inflight %3u  ring %4u/%-4u  drops %" PRIu64 "  err %u   ",
		t, st->bytes / 1e6, dt > 0 ? (st->bytes - prev) / dt / 1e6 : 0.0,
		o->play ? "play " : "", o->expect_bytes ? 100.0 * st->bytes / o->expect_bytes : 0.0,
		inflight, st->ring_fill, st->ring_hwm, (uint64_t)st->drop_count, st->cmd_errors);
	(void)info;
}

int ctl_run(int fd, const struct nvrec_info *info, const struct ctl_run_opts *o,
	    struct nvrec_stats *final)
{
	double t0 = now_s(), tlast = t0, tprog = t0;
	uint64_t last_bytes = 0, last_done = 0;
	bool live = !o->quiet && o->stats > 0 && isatty(2);
	bool stopping = false;

	for (;;) {
		struct nvrec_wait w = { .timeout_ms = 200 };
		struct nvrec_stats st;
		double now;
		int r = ioctl(fd, NVREC_IOC_WAIT, &w);

		if (r == 0)
			break;			/* run ended */
		if (errno != ETIMEDOUT && errno != EINTR) {
			perr("NVREC_IOC_WAIT");
			return -errno;
		}
		if (ctl_stop_requested && !stopping) {
			stopping = true;
			if (ioctl(fd, NVREC_IOC_STOP, final) < 0) {
				perr("NVREC_IOC_STOP");
				return -errno;
			}
			break;
		}
		if (ioctl(fd, NVREC_IOC_GET_STATS, &st) < 0) {
			perr("NVREC_IOC_GET_STATS");
			return -errno;
		}
		now = now_s();
		/* progress: NVMe completions; a DRY run has none, its bytes move */
		if ((o->dry ? st.bytes : st.cmds_done) != last_done) {
			last_done = o->dry ? st.bytes : st.cmds_done;
			tprog = now;
		} else if (o->timeout > 0 && now - tprog > o->timeout) {
			if (live)
				fputc('\n', stderr);
			if (o->dry)
				err_msg("stalled: no data moved for %.0f s, aborting", o->timeout);
			else
				err_msg("stalled: no NVMe command completed for %.0f s (in flight: %u + %u), aborting",
					o->timeout, st.ssd[0].inflight, st.ssd[1].inflight);
			ioctl(fd, NVREC_IOC_ABORT, final);
			if (!o->dry && (final->flags & NVREC_STATS_HA_DEAD)) {
				err_msg("%s", NVREC_HA_DEAD_MSG);
				ctl_ha_dead = true;
				return -ENOLINK;
			}
			return -ETIMEDOUT;
		}
		if (live && now - tlast >= o->stats) {
			print_live(info, &st, o, now - t0, last_bytes, now - tlast);
			last_bytes = st.bytes;
			tlast = now;
		}
	}
	if (live)
		fputc('\n', stderr);
	if (!stopping && ioctl(fd, NVREC_IOC_GET_STATS, final) < 0) {
		perr("NVREC_IOC_GET_STATS");
		return -errno;
	}
	if (!o->dry && (final->flags & NVREC_STATS_HA_DEAD)) {
		err_msg("%s", NVREC_HA_DEAD_MSG);
		ctl_ha_dead = true;
		return -ENOLINK;
	}
	return 0;
}

void ctl_print_summary(const char *prog, const struct nvrec_info *info,
		       const struct nvrec_stats *st, double seconds, bool dry)
{
	uint32_t hwm = 0;
	unsigned i;

	if (dry) {
		printf("%s: %" PRIu64 " bytes in %.2f s, %.1f MB/s; fabric only (DRY): no NVMe command, %u-byte beats\n",
		       prog, (uint64_t)st->bytes, seconds, seconds > 0 ? st->bytes / seconds / 1e6 : 0.0,
		       info->beat_bytes);
		ctl_print_ports(prog, info, st);
		return;
	}
	for (i = 0; i < NVREC_MAX_SSD; i++)
		if (st->ssd[i].inflight_hwm > hwm)
			hwm = st->ssd[i].inflight_hwm;
	printf("%s: %" PRIu64 " bytes in %.2f s, %.1f MB/s; %" PRIu64 " commands, %u errors, max %u in flight per SSD\n",
	       prog, (uint64_t)st->bytes, seconds, seconds > 0 ? st->bytes / seconds / 1e6 : 0.0,
	       (uint64_t)st->cmds_done, st->cmd_errors, hwm);
	printf("%s: command latency min %.0f / avg %.0f / max %.0f us; ring high-water %u slots, writer waited %.3f ms for a free slot\n",
	       prog, ctl_cycles_to_us(info, st->lat_count ? st->lat_min : 0),
	       ctl_cycles_to_us(info, st->lat_count ? st->lat_sum / st->lat_count : 0),
	       ctl_cycles_to_us(info, st->lat_max), st->ring_hwm,
	       ctl_cycles_to_us(info, st->ring_full_cycles) / 1e3);
	if (st->cmd_errors)
		printf("%s: last NVMe error: status 0x%04x on SSD%u (CID 0x%04x, SQ %u)\n",
		       prog, st->err_last_status & 0x7fff, (st->err_last_status >> 16) & 0x1f,
		       st->err_last_cid & 0xffff, st->err_last_cid >> 16);
	ctl_print_ports(prog, info, st);
}

void ctl_print_ports(const char *prog, const struct nvrec_info *info,
		     const struct nvrec_stats *st)
{
	if (info->ring_ports < 2)
		return;
	printf("%s: ring ports (memory 0 / 1): writer waited %.3f / %.3f ms, reader waited %.3f / %.3f ms\n",
	       prog, ctl_cycles_to_us(info, st->wr_port_stall[0]) / 1e3,
	       ctl_cycles_to_us(info, st->wr_port_stall[1]) / 1e3,
	       ctl_cycles_to_us(info, st->rd_port_wait[0]) / 1e3,
	       ctl_cycles_to_us(info, st->rd_port_wait[1]) / 1e3);
}

/* append printf output to the NUL-terminated line[len] (truncates) */
static void __attribute__((format(printf, 3, 4)))
res_add(char *line, size_t len, const char *fmt, ...)
{
	size_t n = strlen(line);
	va_list ap;

	if (n + 1 >= len)
		return;
	va_start(ap, fmt);
	vsnprintf(line + n, len - n, fmt, ap);
	va_end(ap);
}

/* PCIe MaxPayload (bytes) a function is programmed with: Device Control of
 * its PCI Express capability, from the config space in sysfs (beyond the
 * first 64 bytes it needs root, as the apps do); 0 = unknown */
static unsigned pci_mps(const char *bdf)
{
	const char *root = getenv("NVREC_PCI_SYSFS");     /* host tests */
	char path[PATH_MAX];
	uint8_t cfg[256];
	unsigned p, guard = 0;
	ssize_t n;
	int fd;

	snprintf(path, sizeof(path), "%s/%s/config", root ? root : "/sys/bus/pci/devices", bdf);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return 0;
	n = pread(fd, cfg, sizeof(cfg), 0);
	close(fd);
	if (n < 0x40 || !(cfg[0x06] & 0x10))   /* Status: capabilities list */
		return 0;
	for (p = cfg[0x34] & 0xfc; p >= 0x40 && p + 10 <= (unsigned)n && guard++ < 48;
	     p = cfg[p + 1] & 0xfc) {
		if (cfg[p] == 0x10) {               /* PCI Express capability */
			unsigned ctl = cfg[p + 8] | (unsigned)cfg[p + 9] << 8;

			return 128u << ((ctl >> 5) & 7);
		}
	}
	return 0;
}

unsigned ctl_pcie_mps(const struct nvrec_info *info)
{
	const char *root = getenv("NVREC_PCI_SYSFS");
	unsigned i, m, mps = 0;

	for (i = 0; i < info->nr_ssd && i < NVREC_MAX_SSD; i++) {
		char path[PATH_MAX], real[PATH_MAX];
		const char *pci = info->ssd[i].pci;

		if (info->ssd[i].state == NVREC_SSD_ABSENT || !pci[0])
			continue;
		/* the SSD, and the port above it (its parent in sysfs) */
		m = pci_mps(pci);
		snprintf(path, sizeof(path), "%s/%s", root ? root : "/sys/bus/pci/devices", pci);
		if (m && realpath(path, real)) {
			unsigned pm = pci_mps(basename(dirname(real)));

			if (!pm || pm < m)
				m = pm;
		}
		if (!m)
			return 0;
		if (!mps || m < mps)
			mps = m;
	}
	return mps;
}

void ctl_result_stats(char *line, size_t len, const struct nvrec_info *info,
		      const struct nvrec_stats *st, unsigned flags)
{
	unsigned i, nssd = info->nr_ssd < NVREC_MAX_SSD ? info->nr_ssd : NVREC_MAX_SSD;

	if (flags & CTL_RES_LAT)
		res_add(line, len, " lat_avg_us=%.0f lat_max_us=%.0f ring_hwm=%u",
			ctl_cycles_to_us(info, st->lat_count ? st->lat_sum / st->lat_count : 0),
			ctl_cycles_to_us(info, st->lat_max), st->ring_hwm);
	res_add(line, len, " lat_min_us=%.0f lat_count=%" PRIu64 " inflight_hwm=",
		ctl_cycles_to_us(info, st->lat_count ? st->lat_min : 0), (uint64_t)st->lat_count);
	for (i = 0; i < nssd; i++)
		res_add(line, len, "%s%u", i ? "," : "", st->ssd[i].inflight_hwm);
	if (!nssd)
		res_add(line, len, "0");
	res_add(line, len, " ring_wait_ms=%.3f lat_hist=",
		ctl_cycles_to_us(info, st->ring_full_cycles) / 1e3);
	for (i = 0; i < NVREC_LAT_BINS; i++)
		res_add(line, len, "%s%u", i ? "," : "", st->lat_hist[i]);
	res_add(line, len, " lat_bin0_log2=%u", info->lat_bin0_log2);
	/* register map 1.3: the time the ring writer / reader waited for each
	 * memory -- non-zero in clean runs too: compare the two ports and with
	 * the run time; 32-bit counters, saturate at 17179.886 ms (250 MHz) */
	res_add(line, len, " wr_port_stall_ms=%.3f,%.3f rd_port_wait_ms=%.3f,%.3f",
		ctl_cycles_to_us(info, st->wr_port_stall[0]) / 1e3,
		ctl_cycles_to_us(info, st->wr_port_stall[1]) / 1e3,
		ctl_cycles_to_us(info, st->rd_port_wait[0]) / 1e3,
		ctl_cycles_to_us(info, st->rd_port_wait[1]) / 1e3);
	res_add(line, len, " mps=%u", ctl_pcie_mps(info));
}

void ctl_result_ring(char *line, size_t len, const struct nvrec_ring *r)
{
	uint64_t total = (uint64_t)r->slots * r->chunk, mem1 = 0;

	if (r->flags == NVREC_RING_MEM1)
		mem1 = total;
	else if (r->flags == NVREC_RING_SPLIT)
		mem1 = total - (((total >> r->stripe_shift) + 1) / 2 << r->stripe_shift);
	res_add(line, len, " ring_slots=%u ring_bytes=%" PRIu64 " ring=%s stripe_kb=%u ring_mem1_bytes=%" PRIu64,
		r->slots, (uint64_t)r->bytes, r->slots ? ctl_ring_name(r->flags) : "none",
		r->flags == NVREC_RING_SPLIT && r->stripe_shift >= 10 ? 1u << (r->stripe_shift - 10) : 0,
		mem1);
}

static bool is_number(const char *s, size_t n)
{
	char tmp[64], *end;

	if (!n || n >= sizeof(tmp))
		return false;
	memcpy(tmp, s, n);
	tmp[n] = 0;
	/* JSON numbers only: no hex, inf, nan, leading '+' or '.' */
	if (!(tmp[0] == '-' || (tmp[0] >= '0' && tmp[0] <= '9')) ||
	    strpbrk(tmp, "xXiInN"))
		return false;
	strtod(tmp, &end);
	return *end == 0;
}

static void json_str(const char *s, size_t n)
{
	size_t i;

	putchar('"');
	for (i = 0; i < n; i++) {
		unsigned char c = (unsigned char)s[i];

		if (c == '"' || c == '\\')
			printf("\\%c", c);
		else if (c < 0x20)
			printf("\\u%04x", c);
		else
			putchar(c);
	}
	putchar('"');
}

void ctl_print_result(const char *line, bool json)
{
	const char *p = line;
	bool first = true;

	printf("RESULT %s\n", line);
	if (!json)
		return;
	putchar('{');
	while (*p) {
		const char *tok = p, *eq, *v, *e;
		size_t tl;

		while (*p && *p != ' ')
			p++;
		tl = (size_t)(p - tok);
		while (*p == ' ')
			p++;
		eq = memchr(tok, '=', tl);
		if (!tl || !eq)
			continue;
		v = eq + 1;
		e = tok + tl;
		printf("%s", first ? "" : ",");
		first = false;
		json_str(tok, (size_t)(eq - tok));
		putchar(':');
		if (is_number(v, (size_t)(e - v))) {
			fwrite(v, 1, (size_t)(e - v), stdout);
		} else if (memchr(v, ',', (size_t)(e - v))) {
			/* comma list: an array of numbers, else a string */
			const char *a = v, *c;
			bool nums = true;

			for (a = v; a < e; a = c + 1) {
				c = memchr(a, ',', (size_t)(e - a));
				if (!c)
					c = e;
				if (!is_number(a, (size_t)(c - a)))
					nums = false;
			}
			if (nums) {
				putchar('[');
				for (a = v; a < e; a++)
					putchar(*a);
				putchar(']');
			} else {
				json_str(v, (size_t)(e - v));
			}
		} else {
			json_str(v, (size_t)(e - v));
		}
	}
	printf("}\n");
}
