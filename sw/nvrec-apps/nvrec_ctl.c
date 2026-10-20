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

int ctl_open(const char *path, struct nvrec_info *info)
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
	if (info->status & NVREC_STATUS_HA_DEAD) {
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

uint32_t ctl_default_slots(uint32_t chunk, uint32_t max_slots)
{
	uint32_t hi = NVREC_RING_MAX_SLOTS, s;

	if (max_slots && max_slots < hi)
		hi = max_slots;
	s = chunk ? CTL_RING_DEF_BYTES / chunk : CTL_RING_MIN_SLOTS;
	if (s < CTL_RING_MIN_SLOTS)
		s = CTL_RING_MIN_SLOTS;
	if (s > hi)
		s = hi;
	return s;
}

uint64_t ctl_ring_cma_bytes(uint32_t chunk, uint32_t slots, uint64_t *prp_bytes)
{
	uint64_t ring = (uint64_t)chunk * slots, prp = 0;
	uint32_t n4k = chunk / 4096, per_list = 4096, lists;

	ring = (ring + NVREC_HUGEPAGE - 1) / NVREC_HUGEPAGE * NVREC_HUGEPAGE;
	/* as nvrec_set_ring() in the driver: one list per slot of entries for
	 * pages 1..P-1, 512 per 4 KB, chained (511 + link) beyond that; the
	 * stride is a power of two */
	if (n4k > 2) {
		if (n4k - 1 > 512) {
			lists = (n4k - 1 + 510) / 511;
			while (per_list < 4096u * lists)
				per_list <<= 1;
		}
		/* the driver's slots: bytes (2 MB rounded) / chunk */
		prp = (ring / chunk) * per_list;
	}
	if (prp_bytes)
		*prp_bytes = prp;
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

int ctl_set_ring(int fd, uint32_t chunk, uint32_t slots, struct nvrec_ring *r)
{
	uint64_t need, prp, total, avail;
	int e;

	memset(r, 0, sizeof(*r));
	r->addr = 0;
	r->bytes = (uint64_t)chunk * slots;
	r->chunk = chunk;
	if (r->bytes % NVREC_HUGEPAGE)
		r->bytes = (r->bytes + NVREC_HUGEPAGE - 1) / NVREC_HUGEPAGE * NVREC_HUGEPAGE;
	if (r->bytes > NVREC_RING_MAX_BYTES) {
		err_msg("ring of %u x %u bytes (%" PRIu64 " MB) is larger than the driver's %llu MB limit: use fewer --buffers",
			slots, chunk, (uint64_t)r->bytes >> 20, NVREC_RING_MAX_BYTES >> 20);
		return -1;
	}
	need = ctl_ring_cma_bytes(chunk, slots, &prp);
	cma_info(&total, &avail);
	if (total && need > total) {
		err_msg("ring of %u x %u bytes needs %" PRIu64 " MB of CMA (ring %" PRIu64
			" MB + PRP lists %" PRIu64 " KB) but the kernel's CMA pool is only %"
			PRIu64 " MB: use fewer --buffers or boot with a larger cma=",
			slots, chunk, (need + (1u << 20) - 1) >> 20, (uint64_t)r->bytes >> 20, prp >> 10,
			total >> 20);
		return -1;
	}
	if (ioctl(fd, NVREC_IOC_SET_RING, r) < 0) {
		e = errno;
		if (e == ENOMEM)
			err_msg("cannot allocate the ring: %u x %u bytes needs %" PRIu64
				" MB of contiguous CMA (ring %" PRIu64 " MB + PRP lists %" PRIu64
				" KB); CMA free %" PRIu64 " of %" PRIu64
				" MB: use fewer --buffers or boot with a larger cma=",
				slots, chunk, (need + (1u << 20) - 1) >> 20, (uint64_t)r->bytes >> 20,
				prp >> 10, avail >> 20, total >> 20);
		else
			perr("NVREC_IOC_SET_RING (%u x %u bytes)", slots, chunk);
		errno = e;
		return -1;
	}
	return 0;
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
		if (st.cmds_done != last_done) {
			last_done = st.cmds_done;
			tprog = now;
		} else if (o->timeout > 0 && now - tprog > o->timeout) {
			if (live)
				fputc('\n', stderr);
			err_msg("stalled: no NVMe command completed for %.0f s (in flight: %u + %u), aborting",
				o->timeout, st.ssd[0].inflight, st.ssd[1].inflight);
			ioctl(fd, NVREC_IOC_ABORT, final);
			if (final->flags & NVREC_STATS_HA_DEAD) {
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
	if (final->flags & NVREC_STATS_HA_DEAD) {
		err_msg("%s", NVREC_HA_DEAD_MSG);
		ctl_ha_dead = true;
		return -ENOLINK;
	}
	return 0;
}

void ctl_print_summary(const char *prog, const struct nvrec_info *info,
		       const struct nvrec_stats *st, double seconds)
{
	uint32_t hwm = 0;
	unsigned i;

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
}

void ctl_result_ring(char *line, size_t len, const struct nvrec_ring *r)
{
	res_add(line, len, " ring_slots=%u ring_bytes=%" PRIu64, r->slots, (uint64_t)r->bytes);
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
