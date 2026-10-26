// SPDX-License-Identifier: MIT
/*
 * nvrec -- record the fabric data stream to a file on NVMe, the CPU out of
 * the data path: the fabric fills the ring, builds the NVMe Write commands
 * and the AMD NVMe Host Accelerator hands them to the SSD(s).
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * File mode (default), on an exFAT volume on /dev/nvrecXn1 or an md RAID0
 * of them (nvsetup-raid0.sh):
 *   1. create the file and preallocate it with ftruncate(): the kernel's
 *      exFAT driver allocates a contiguous cluster run (NoFatChain) on a
 *      volume with contiguous free space, without writing data;
 *   2. unmount the volume (nothing may cache or write it while the hardware
 *      writes underneath the block layer);
 *   3. read the file's cluster run from the raw device, map it to the
 *      hardware geometry (md chunk index, member data offsets);
 *   4. record; 5. write the header, set the exFAT ValidDataLength over the
 *      whole allocation; 6. remount and truncate the file to the recorded
 *      length.
 * docs/source/filesystem.md explains why each step is needed.
 *
 * Raw mode (--raw <dev>): record straight to LBAs of an unmounted nvrec disk
 * or md array (bring-up, benchmarks); check with nvverify --raw.
 *
 * Fabric-only mode (--no-write, register map 1.2): the hardware runs with
 * CONFIG.DRY -- the source fills the ring and every slot is released as soon
 * as it is filled, no NVMe command, no file, no SSD needed. It measures the
 * source -> ingest FIFO -> ring writer -> DDR path alone; statistics and the
 * RESULT line are those of a recording (bytes = bytes written into the ring).
 *
 * Exit codes: 0 = complete, no dropped beats and no NVMe error,
 *             2 = complete but beats were dropped,
 *             1 = error (NVMe error, stall, setup failure),
 *             5 = the Host Accelerator stopped responding (evaluation license).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <endian.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#include "nvrec_uapi.h"
#include "nvrec_file.h"
#include "nvrec_common.h"
#include "nvrec_vol.h"
#include "nvrec_ctl.h"

#ifndef NVREC_TARGET
#define NVREC_TARGET "unknown"
#endif

#define DEF_DEVICE      "/dev/nvrec"
#define DEF_CHUNK       (1u << 20)
#define DEF_TIMEOUT     10.0

const char *prog_name = "nvrec";

struct opts {
	const char *device;
	const char *output;     /* file, or the raw device with --raw */
	const char *target;
	bool raw;
	bool no_write;          /* fabric only (DRY): no file, no NVMe command */
	uint64_t offset;        /* raw: byte offset on the device */
	uint64_t size;
	uint64_t rate;
	bool rate_set;
	uint32_t chunk;
	bool chunk_set;
	uint32_t slots;         /* 0 = default: 512 MB of slots (1 GB split) */
	uint32_t ring;          /* --ring: NVREC_RING_*, 0 = auto */
	uint32_t stripe_kb;     /* --stripe: 0 = driver default, CTL_STRIPE_CHUNK */
	uint32_t qd;
	bool no_tpg;
	bool fua;
	bool force;
	double stats;
	double timeout;
	bool quiet;
	bool json;
};

static void usage(FILE *f)
{
	fprintf(f,
"Usage: nvrec [options] --size <bytes> <file>\n"
"       nvrec [options] --size <bytes> --raw <blockdev> [--offset <bytes>]\n"
"       nvrec [options] --size <bytes> --no-write\n"
"\n"
"Record the FPGA fabric data stream with the hardware NVMe command path.\n"
"<file> is on a mounted exFAT volume on /dev/nvrecXn1 or on an md RAID0 of\n"
"them (nvsetup-raid0.sh). The volume is UNMOUNTED while recording and\n"
"remounted afterwards.\n"
"\n"
"Options:\n"
"  --size <bytes>        data to record (suffixes K/M/G/T = 1024^n, KB/MB/GB/TB\n"
"                        = 1000^n); the file is preallocated to this size\n"
"  --rate <bytes/s>      test pattern generator rate (default: leave as is; at\n"
"                        most src_clk x the fabric beat, e.g. 250 MHz x 32 B =\n"
"                        8000 MB/s on a 256-bit design: higher runs at the max)\n"
"  --chunk <bytes>       bytes per NVMe command (default: 1M or the drives'\n"
"                        MDTS, whichever is smaller; must equal the md chunk of\n"
"                        a RAID0 volume)\n"
"  --buffers <n>         ring slots of --chunk bytes in DDR, 2..4096, at most the\n"
"                        hardware slot table (default: 512 MB of slots, 1 GB\n"
"                        for a split ring: bytes / chunk within 256..4096, e.g.\n"
"                        1024 x 512K single, 2048 x 512K split); the ring (its\n"
"                        PS DDR part) and its PRP lists come from CMA (cma=\n"
"                        kernel argument); a split ring with whole-chunk\n"
"                        stripes uses an even count (an odd one is rounded\n"
"                        down: each SSD then writes one memory only)\n"
"  --ring <layout>       auto (default: the driver's choice -- split on a design\n"
"                        with a second ring memory, single for one SSD), single\n"
"                        (PS DDR), split (striped over PS DDR and the second\n"
"                        memory, half the load on each) or mem1 (all in the\n"
"                        second memory, diagnostics); register map 1.3\n"
"  --stripe <KB>|chunk   split ring: stripe unit, a power of two from 4 KB to the\n"
"                        chunk (default: the driver's, the whole chunk on VCK190\n"
"                        and ZCU106); 'chunk' = whole slots alternate\n"
"  --qd <n>              NVMe commands in flight per SSD, 1..63 (default 32)\n"
"  --no-tpg              do not touch the generator (user's own data source)\n"
"  --fua                 Force Unit Access on every write\n"
"  --force               overwrite an existing file\n"
"  --raw <dev>           record to raw LBAs of <dev> (not mounted); no file\n"
"  --offset <bytes>      raw: start offset on <dev>, chunk aligned (default 0)\n"
"  --no-write            fabric only (register map 1.2): the ring is filled and\n"
"                        released at once, no NVMe command, no file (give none);\n"
"                        --size counts the bytes written into the ring. Tests\n"
"                        the source -> FIFO -> ring -> DDR path alone\n"
"  --timeout <sec>       abort when no command completes (--no-write: no data\n"
"                        moves) for this long (default %.0f)\n"
"  --stats <sec>         live stats interval, 0 = off (default 1)\n"
"  --device <path>       control device (default %s)\n"
"  --target <name>       target name stored in the header (default %s)\n"
"  --json                also print the RESULT keys as one JSON object (next line)\n"
"  --print-target        print the default target name (the build's) and exit\n"
"  -q, --quiet           no live stats\n"
"  -h, --help            this help\n"
"\n"
"Ctrl-C stops early: the open chunk is padded and completed, the file is\n"
"truncated to what was recorded. Check a test-pattern recording with nvverify.\n"
"Counts are in fabric beats of the design (16, 32 or 64 bytes, RESULT\n"
"beat_bytes); the test pattern is numbered in 16-byte words.\n"
"\n"
"Exit code: 0 = complete with no dropped beats, 2 = beats were dropped,\n"
"1 = error, 5 = the Host Accelerator stopped responding (evaluation license).\n"
"The same with --no-write (never 5).\n",
		DEF_TIMEOUT, DEF_DEVICE, NVREC_TARGET);
}

static int parse_args(int argc, char **argv, struct opts *o)
{
	static const struct option lo[] = {
		{ "size", required_argument, NULL, 's' },
		{ "rate", required_argument, NULL, 'r' },
		{ "chunk", required_argument, NULL, 'c' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "ring", required_argument, NULL, 'G' },
		{ "stripe", required_argument, NULL, 'X' },
		{ "qd", required_argument, NULL, 'Q' },
		{ "no-tpg", no_argument, NULL, 'N' },
		{ "fua", no_argument, NULL, 'F' },
		{ "force", no_argument, NULL, 'f' },
		{ "raw", no_argument, NULL, 'R' },
		{ "offset", required_argument, NULL, 'o' },
		{ "no-write", no_argument, NULL, 'W' },
		{ "timeout", required_argument, NULL, 't' },
		{ "stats", required_argument, NULL, 'S' },
		{ "device", required_argument, NULL, 'D' },
		{ "target", required_argument, NULL, 'T' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "json", no_argument, NULL, 'J' },
		{ "print-target", no_argument, NULL, 'P' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	uint64_t v;
	int c;

	memset(o, 0, sizeof(*o));
	o->device = DEF_DEVICE;
	o->target = NVREC_TARGET;
	o->chunk = DEF_CHUNK;
	o->stats = 1.0;
	o->timeout = DEF_TIMEOUT;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		switch (c) {
		case 's':
			if (parse_size(optarg, &o->size) || !o->size)
				return die_usage("invalid --size '%s'", optarg);
			break;
		case 'r':
			if (parse_size(optarg, &o->rate))
				return die_usage("invalid --rate '%s'", optarg);
			o->rate_set = true;
			break;
		case 'c':
			if (parse_size(optarg, &v) || v < NVREC_MIN_CHUNK ||
			    v > NVREC_MAX_CHUNK || (v & (v - 1)))
				return die_usage("--chunk must be a power of two, 64K..4M");
			o->chunk = (uint32_t)v;
			o->chunk_set = true;
			break;
		case 'b':
			if (parse_size(optarg, &v) || v < 2 || v > NVREC_RING_MAX_SLOTS)
				return die_usage("--buffers must be 2..%d", NVREC_RING_MAX_SLOTS);
			o->slots = (uint32_t)v;
			break;
		case 'G':
			if (ctl_parse_ring(optarg, &o->ring))
				return die_usage("--ring must be auto, single, split or mem1");
			break;
		case 'X':
			if (ctl_parse_stripe(optarg, &o->stripe_kb))
				return die_usage("--stripe must be a power of two in KB, 4..4096, or 'chunk'");
			break;
		case 'Q':
			if (parse_size(optarg, &v) || v < 1 || v > 63)
				return die_usage("--qd must be 1..63");
			o->qd = (uint32_t)v;
			break;
		case 'N': o->no_tpg = true; break;
		case 'F': o->fua = true; break;
		case 'f': o->force = true; break;
		case 'R': o->raw = true; break;
		case 'W': o->no_write = true; break;
		case 'o':
			if (parse_size(optarg, &o->offset))
				return die_usage("invalid --offset '%s'", optarg);
			break;
		case 't':
			if (parse_double(optarg, &o->timeout) || o->timeout < 0)
				return die_usage("invalid --timeout '%s'", optarg);
			break;
		case 'S':
			if (parse_double(optarg, &o->stats) || o->stats < 0)
				return die_usage("invalid --stats '%s'", optarg);
			break;
		case 'D': o->device = optarg; break;
		case 'T': o->target = optarg; break;
		case 'q': o->quiet = true; break;
		case 'J': o->json = true; break;
		case 'P':
			printf("%s\n", NVREC_TARGET);
			exit(0);
		case 'h':
			usage(stdout);
			exit(0);
		default:
			usage(stderr);
			return -1;
		}
	}
	if (o->no_write) {
		if (optind != argc)
			return die_usage("--no-write creates no file: give no <file>");
		if (o->raw || o->force || o->fua || o->offset)
			return die_usage("--no-write takes none of --raw, --offset, --force, --fua");
		if (!o->size)
			return die_usage("--size is required (bytes to move into the ring)");
	} else {
		if (optind != argc - 1) {
			usage(stderr);
			return -1;
		}
		o->output = argv[optind];
	}
	if (!o->size)
		return die_usage("--size is required (the file is preallocated)");
	/* --buffers x chunk is checked once the chunk is known (md chunk,
	 * MDTS): pick_slots() */
	return 0;
}

static void fill_header(struct nvrec_file_header *h, const struct opts *o,
			const struct nvrec_info *info, const struct nvrec_start *start,
			const struct nvrec_stats *st, uint32_t data_off,
			uint64_t start_chunk, unsigned members, uint64_t stop_ns)
{
	char host[64] = "";

	memset(h, 0, sizeof(*h));
	memcpy(h->magic, NVREC_FILE_MAGIC, NVREC_FILE_MAGIC_LEN);
	h->header_version = htole32(NVREC_FILE_HEADER_VERSION);
	h->header_size = htole32(data_off);
	h->beat_bytes = htole32(info->beat_bytes);	/* the design's fabric beat */
	h->flags = htole32((o->no_tpg ? 0 : NVREC_FILE_FLAG_TPG) | NVREC_FILE_FLAG_COMPLETE);
	h->design_version = htole32(info->hw_version);
	h->src_clk_hz = htole64(info->src_clk_hz);
	h->rate_bps = htole64(o->rate_set ? o->rate : 0);
	h->start_time_ns = htole64(start->start_time_ns);
	h->stop_time_ns = htole64(stop_ns);
	h->data_bytes = htole64(st->bytes);
	h->drop_count = htole64(st->drop_count);
	h->first_seq = htole64(start->first_seq);
	/* NUL-padded, not necessarily NUL-terminated (as fdrec) */
	memcpy(h->target, o->target, strnlen(o->target, sizeof(h->target)));
	gethostname(host, sizeof(host) - 1);
	memcpy(h->hostname, host, strnlen(host, sizeof(h->hostname)));
	h->chunk_bytes = htole32(o->chunk);
	h->nr_members = htole32(members);
	h->start_chunk = htole64(start_chunk);
	h->cmd_errors = htole32(st->cmd_errors);
	h->qd = htole32(o->qd ? o->qd : 32);
	h->lat_avg_ns = htole64((uint64_t)(ctl_cycles_to_us(info, st->lat_count ?
						st->lat_sum / st->lat_count : 0) * 1e3));
	h->lat_max_ns = htole64((uint64_t)(ctl_cycles_to_us(info, st->lat_max) * 1e3));
}

/* ring slots: the default (512 MB of slots, 1 GB split) or --buffers within
 * the hardware (ctl_set_ring checks the sizes) */
static int pick_slots(struct opts *o, const struct nvrec_info *info, uint32_t layout)
{
	if (!o->slots) {
		o->slots = ctl_default_slots(o->chunk, info->max_slots, layout);
	} else if (info->max_slots && o->slots > info->max_slots) {
		err_msg("--buffers %u exceeds the hardware slot table (%u)", o->slots, info->max_slots);
		return -1;
	} else if ((uint64_t)o->chunk * o->slots > (layout == NVREC_RING_SPLIT ?
						      NVREC_RING_MAX_BYTES_SPLIT : NVREC_RING_MAX_BYTES)) {
		err_msg("%s ring of %u x %u bytes is larger than %llu MB: use fewer --buffers",
			ctl_ring_name(layout), o->slots, o->chunk,
			(layout == NVREC_RING_SPLIT ? NVREC_RING_MAX_BYTES_SPLIT : NVREC_RING_MAX_BYTES) >> 20);
		return -1;
	}
	return 0;
}

/*
 * --no-write: a fabric-only (DRY) record run. No file, no geometry members:
 * the hardware fills the ring slot by slot and releases each slot as soon as
 * it is filled, so the run measures the source -> ingest FIFO -> ring writer
 * -> DDR path alone. Same statistics and RESULT keys as a recording.
 */
static int record_dry(struct opts *o)
{
	struct nvrec_info info;
	struct nvrec_geometry g;
	struct nvrec_ring ring;
	struct nvrec_start start;
	struct nvrec_stats st;
	char res[CTL_RESULT_MAX], rdesc[64];
	uint64_t nchunks;
	uint32_t layout;
	double seconds;
	int fd, r, ret = 1;

	fd = ctl_open(o->device, &info, true);
	if (fd < 0)
		return ctl_exit_code();
	if (ctl_ring_layout(&info, o->ring, o->stripe_kb, 0, &layout))
		goto out;
	if (o->chunk > info.max_chunk) {
		/* SET_RING still checks the chunk against the live SSDs' MDTS */
		if (o->chunk_set) {
			err_msg("--chunk %u exceeds the SSDs' maximum transfer size (%u)", o->chunk,
				info.max_chunk);
			goto out;
		}
		o->chunk = info.max_chunk;
	}
	if (pick_slots(o, &info, layout))
		goto out;
	nchunks = (o->size + o->chunk - 1) / o->chunk;
	if (nchunks > UINT32_MAX) {
		err_msg("--size too large for one run");
		goto out;
	}
	if (o->rate_set) {
		struct nvrec_rate rr = { .rate_bps = o->rate };

		if (ioctl(fd, NVREC_IOC_SET_RATE, &rr) < 0) {
			perr("NVREC_IOC_SET_RATE");
			goto out;
		}
		o->rate = rr.rate_bps;
	}
	if (ctl_set_ring(fd, &info, o->chunk, o->slots, layout, o->stripe_kb, &ring))
		goto out;
	memset(&g, 0, sizeof(g));
	g.nr_members = 0;			/* no SSD */
	g.length_chunks = (uint32_t)nchunks;
	if (ioctl(fd, NVREC_IOC_SET_GEOMETRY, &g) < 0) {
		perr("NVREC_IOC_SET_GEOMETRY");
		goto out;
	}
	memset(&start, 0, sizeof(start));
	start.flags = (o->no_tpg ? 0 : NVREC_START_TPG) | NVREC_START_DRY;
	if (ioctl(fd, NVREC_IOC_RECORD_START, &start) < 0) {
		perr("NVREC_IOC_RECORD_START (fabric only)");
		goto out;
	}
	if (!o->quiet)
		fprintf(stderr, "nvrec: --no-write: %" PRIu64 " x %u-byte chunks into the ring (%u slots, %"
			PRIu64 " MB, %s), fabric only, %u-byte beats, nothing is written\n",
			nchunks, o->chunk, ring.slots, (uint64_t)ring.bytes >> 20,
			ctl_ring_describe(&ring, rdesc, sizeof(rdesc)), info.beat_bytes);
	{
		struct ctl_run_opts ro = {
			.stats = o->stats, .timeout = o->timeout, .quiet = o->quiet,
			.dry = true, .expect_bytes = nchunks * o->chunk,
		};

		r = ctl_run(fd, &info, &ro, &st);
	}
	if (r && r != -ETIMEDOUT)
		goto out;
	seconds = st.elapsed_ns / 1e9;
	ctl_print_summary(prog_name, &info, &st, seconds, true);
	printf("nvrec: dropped beats %" PRIu64 ", FIFO high-water during the run %u of %u beats\n",
	       (uint64_t)st.drop_count, st.fifo_hwm, st.fifo_depth);
	printf("nvrec: ring %u slots x %u bytes = %" PRIu64 " MB, %s (filled and released at once)\n",
	       ring.slots, o->chunk, (uint64_t)ring.bytes >> 20,
	       ctl_ring_describe(&ring, rdesc, sizeof(rdesc)));
	snprintf(res, sizeof(res), "bytes=%" PRIu64 " seconds=%.3f rate_bps=%" PRIu64
		 " drops=%" PRIu64 " fifo_hwm=%u fifo_depth=%u error=%d nvme_errors=%u"
		 " chunk=%u qd=0 members=0 ring_hwm=%u lat_avg_us=0 lat_max_us=0"
		 " data_offset=0 beat_bytes=%u no_write=1",
		 (uint64_t)st.bytes, seconds, o->rate_set ? o->rate : 0, (uint64_t)st.drop_count,
		 st.fifo_hwm, st.fifo_depth, r ? r : (st.state == NVREC_RUN_DONE ? 0 : -EIO),
		 st.cmd_errors, o->chunk, st.ring_hwm, info.beat_bytes);
	ctl_result_stats(res, sizeof(res), &info, &st, 0);
	ctl_result_ring(res, sizeof(res), &ring);
	ctl_print_result(res, o->json);
	if (r || st.state != NVREC_RUN_DONE) {
		err_msg("fabric-only run FAILED (%s)", r == -ETIMEDOUT ? "stalled" : "run did not complete");
		ret = 1;
	} else if (st.drop_count) {
		err_msg("WARNING: %" PRIu64 " beats were dropped: the fabric path did not keep up",
			(uint64_t)st.drop_count);
		ret = 2;
	} else {
		ret = 0;
	}
out:
	close(fd);
	return ret;
}

int main(int argc, char **argv)
{
	struct opts o;
	struct nvrec_info info;
	struct nvrec_geometry g;
	struct nvrec_ring ring;
	struct nvrec_start start;
	struct nvrec_stats st;
	struct vol_mount mnt;
	struct vol_target t;
	struct exfat_vol vol = { .fd = -1 };
	struct exfat_file xf;
	char err[512], res[CTL_RESULT_MAX], rdesc[64];
	bool unmounted = false;
	uint64_t dev_off = 0, alloc = 0, array_off, nchunks, prealloc = 0, stop_ns;
	uint32_t data_off = 0, layout;
	unsigned lba_shift = 9;
	double seconds;
	int fd = -1, ret = 1, r;

	if (parse_args(argc, argv, &o))
		return 1;
	ctl_install_signals();
	if (o.no_write)
		return record_dry(&o);

	/* ---- where does it go ---------------------------------------------- */
	if (o.raw) {
		if (vol_find_mount_of_dev(o.output, &mnt) == 0) {
			err_msg("%s is mounted at %s: unmount it first (raw mode overwrites LBAs)",
				o.output, mnt.mountpoint);
			return 1;
		}
		if (vol_resolve_target(o.output, &t, err, sizeof(err))) {
			err_msg("%s", err);
			return 1;
		}
	} else {
		if (vol_find_mount(o.output, &mnt)) {
			perr("%s: cannot find its filesystem", o.output);
			return 1;
		}
		if (strcmp(mnt.fstype, "exfat")) {
			err_msg("%s is on %s (%s), not exFAT: format the recording volume with nvsetup-raid0.sh",
				o.output, mnt.mountpoint, mnt.fstype);
			return 1;
		}
		if (vol_resolve_target(mnt.source, &t, err, sizeof(err))) {
			err_msg("%s", err);
			return 1;
		}
	}
	if (t.md && !o.chunk_set && t.chunk_bytes >= NVREC_MIN_CHUNK &&
	    t.chunk_bytes <= NVREC_MAX_CHUNK)
		o.chunk = (uint32_t)t.chunk_bytes;	/* follow the md chunk */
	if (t.md && t.chunk_bytes != o.chunk) {
		err_msg("%s has an md chunk of %" PRIu64 " bytes: use --chunk %" PRIu64
			" (one NVMe command must not span two members)",
			t.dev, t.chunk_bytes, t.chunk_bytes);
		return 1;
	}

	fd = ctl_open(o.device, &info, false);
	if (fd < 0)
		return ctl_exit_code();
	memset(&g, 0, sizeof(g));
	if (ctl_members(&info, &t, &g, &lba_shift, err, sizeof(err))) {
		err_msg("%s", err);
		goto out;
	}
	if (o.chunk > info.max_chunk && !o.chunk_set && !t.md) {
		/* default chunk above the SSDs' MDTS: one command per MDTS */
		fprintf(stderr, "nvrec: note: chunk clamped from %u to the SSDs' maximum transfer size %u\n",
			o.chunk, info.max_chunk);
		o.chunk = info.max_chunk;
	}
	if (o.chunk > info.max_chunk) {
		err_msg("--chunk %u exceeds the SSDs' maximum transfer size (%u)", o.chunk,
			info.max_chunk);
		goto out;
	}
	if (ctl_ring_layout(&info, o.ring, o.stripe_kb, g.nr_members, &layout))
		goto out;
	if (pick_slots(&o, &info, layout))
		goto out;
	nchunks = (o.size + o.chunk - 1) / o.chunk;
	if (nchunks > UINT32_MAX) {
		err_msg("--size too large for one run");
		goto out;
	}

	/* ---- preallocate, unmount, locate --------------------------------- */
	if (!o.raw) {
		int ffd;

		/* data starts at a chunk boundary at least 4 KB into the file:
		 * one chunk of slack covers any cluster alignment */
		prealloc = (uint64_t)o.chunk + nchunks * o.chunk;
		ffd = open(o.output, O_WRONLY | O_CREAT | O_CLOEXEC | (o.force ? O_TRUNC : O_EXCL), 0644);
		if (ffd < 0) {
			perr("%s%s", o.output, errno == EEXIST ? " (use --force to overwrite)" : "");
			goto out;
		}
		if (o.force && ftruncate(ffd, 0) < 0) {
			perr("truncate %s", o.output);
			close(ffd);
			goto out;
		}
		if (ftruncate(ffd, (off_t)prealloc) < 0) {
			perr("preallocate %" PRIu64 " bytes for %s", prealloc, o.output);
			close(ffd);
			unlink(o.output);
			goto out;
		}
		if (fsync(ffd) < 0) {
			perr("fsync %s", o.output);
			close(ffd);
			goto out;
		}
		close(ffd);

		r = vol_umount(&mnt);
		if (r) {
			errno = -r;
			perr("unmount %s (close every file and shell on it)", mnt.mountpoint);
			unlink(o.output);
			goto out;
		}
		unmounted = true;
		vol_flush_bdev(t.dev);
		if (exfat_open(&vol, t.dev, true, false, err, sizeof(err))) {
			err_msg("%s", err);
			goto out;
		}
		r = exfat_lookup(&vol, mnt.relpath, &xf);
		if (r) {
			errno = -r;
			perr("%s: not found on the raw volume", mnt.relpath);
			goto out;
		}
		r = exfat_extent(&vol, &xf, &dev_off, &alloc);
		if (r == -EFBIG) {
			err_msg("%s is not contiguous: the free space of the volume is fragmented (delete files or reformat with nvsetup-raid0.sh)",
				o.output);
			goto out_unlink;
		} else if (r) {
			errno = -r;
			perr("%s: cluster run", o.output);
			goto out;
		}
		if (dev_off % 4096) {
			err_msg("cluster heap is not 4 KB aligned: reformat with nvsetup-raid0.sh");
			goto out_unlink;
		}
		data_off = (uint32_t)((o.chunk - dev_off % o.chunk) % o.chunk);
		if (data_off < 4096)
			data_off += o.chunk;
		if (data_off + nchunks * o.chunk > alloc) {
			err_msg("internal: allocation %" PRIu64 " too small", alloc);
			goto out_unlink;
		}
		array_off = dev_off + data_off;
	} else {
		if (o.offset % o.chunk) {
			err_msg("--offset must be a multiple of --chunk");
			goto out;
		}
		array_off = o.offset;
	}
	if (array_off + nchunks * o.chunk > t.zone0_bytes) {
		err_msg("the recording would end at byte %" PRIu64 " of %s, beyond %" PRIu64
			" (end of the device or of the md RAID0 stripe zone)",
			array_off + nchunks * o.chunk, t.dev, t.zone0_bytes);
		goto out_unlink;
	}

	/* ---- record --------------------------------------------------------- */
	if (o.rate_set) {
		struct nvrec_rate rr = { .rate_bps = o.rate };

		if (ioctl(fd, NVREC_IOC_SET_RATE, &rr) < 0) {
			perr("NVREC_IOC_SET_RATE");
			goto out_unlink;
		}
		o.rate = rr.rate_bps;
	}
	if (ctl_set_ring(fd, &info, o.chunk, o.slots, layout, o.stripe_kb, &ring))
		goto out_unlink;
	g.start_chunk = array_off / o.chunk;
	g.length_chunks = (uint32_t)nchunks;
	g.qd = o.qd;
	g.flags = o.fua ? NVREC_GEO_FUA : 0;
	if (ioctl(fd, NVREC_IOC_SET_GEOMETRY, &g) < 0) {
		perr("NVREC_IOC_SET_GEOMETRY");
		goto out_unlink;
	}
	memset(&start, 0, sizeof(start));
	start.flags = o.no_tpg ? 0 : NVREC_START_TPG;
	if (ioctl(fd, NVREC_IOC_RECORD_START, &start) < 0) {
		perr("NVREC_IOC_RECORD_START");
		goto out_unlink;
	}
	if (!o.quiet)
		fprintf(stderr, "nvrec: %s: %" PRIu64 " x %u-byte chunks from array chunk %" PRIu64
			" over %u member(s), ring %u slots (%" PRIu64 " MB, %s), qd %u\n",
			o.raw ? t.dev : o.output, nchunks, o.chunk, (uint64_t)g.start_chunk,
			g.nr_members, ring.slots, (uint64_t)ring.bytes >> 20,
			ctl_ring_describe(&ring, rdesc, sizeof(rdesc)), o.qd ? o.qd : 32);
	{
		struct ctl_run_opts ro = {
			.stats = o.stats, .timeout = o.timeout, .quiet = o.quiet,
			.expect_bytes = o.size,
		};

		r = ctl_run(fd, &info, &ro, &st);
	}
	stop_ns = realtime_ns();
	seconds = st.elapsed_ns / 1e9;
	if (r == -ENOLINK) {
		/* Host Accelerator dead: the SSDs are disabled, the volume
		 * cannot be updated; report the run and leave */
		ctl_print_summary(prog_name, &info, &st, seconds, false);
		snprintf(res, sizeof(res), "bytes=%" PRIu64 " seconds=%.3f drops=%" PRIu64
			 " error=%d ha_dead=1 beat_bytes=%u no_write=0", (uint64_t)st.bytes, seconds,
			 (uint64_t)st.drop_count, r, info.beat_bytes);
		ctl_result_stats(res, sizeof(res), &info, &st, CTL_RES_LAT);
		ctl_result_ring(res, sizeof(res), &ring);
		ctl_print_result(res, o.json);
		err_msg("recording FAILED: %s", NVREC_HA_DEAD_MSG);
		ret = NVREC_EXIT_HA_DEAD;
		goto out;
	}
	if (r && r != -ETIMEDOUT)	/* a stall still finishes the file */
		goto out_unlink;
	/* close /dev/nvrec now: frees the ring */
	close(fd);
	fd = -1;

	/* ---- finish the file ---------------------------------------------- */
	if (!o.raw) {
		struct nvrec_file_header *h;
		uint8_t *buf;

		if (posix_memalign((void **)&buf, 4096, data_off)) {
			err_msg("out of memory");
			goto out;
		}
		memset(buf, 0, data_off);
		h = (struct nvrec_file_header *)buf;
		fill_header(h, &o, &info, &start, &st, data_off, g.start_chunk,
			    g.nr_members, stop_ns);
		/* the hardware wrote behind the page cache: drop it first */
		vol_flush_bdev(t.dev);
		if (pwrite(vol.fd, buf, data_off, (off_t)dev_off) != (ssize_t)data_off) {
			perr("write header");
			free(buf);
			goto out;
		}
		free(buf);
		if (exfat_set_valid_len(&vol, &xf, xf.data_len)) {
			err_msg("cannot set the file's valid data length");
			goto out;
		}
		exfat_close(&vol);
		vol_flush_bdev(t.dev);
		r = vol_remount(&mnt);
		if (r) {
			errno = -r;
			perr("remount %s on %s", mnt.source, mnt.mountpoint);
			goto out;
		}
		unmounted = false;
		if (truncate(o.output, (off_t)(data_off + st.bytes)) < 0) {
			perr("truncate %s", o.output);
			goto out;
		}
	}

	ctl_print_summary(prog_name, &info, &st, seconds, false);
	printf("nvrec: dropped beats %" PRIu64 ", FIFO high-water during the run %u of %u beats%s\n",
	       (uint64_t)st.drop_count, st.fifo_hwm, st.fifo_depth,
	       o.raw ? "" : "; file header + padding before the data");
	printf("nvrec: ring %u slots x %u bytes = %" PRIu64 " MB, %s, high-water %u slots\n",
	       ring.slots, o.chunk, (uint64_t)ring.bytes >> 20,
	       ctl_ring_describe(&ring, rdesc, sizeof(rdesc)), st.ring_hwm);
	/* one machine-readable line for scripts (nvbench.sh), fdrec-compatible keys */
	snprintf(res, sizeof(res), "bytes=%" PRIu64 " seconds=%.3f rate_bps=%" PRIu64
	       " drops=%" PRIu64 " fifo_hwm=%u fifo_depth=%u error=%d nvme_errors=%u"
	       " chunk=%u qd=%u members=%u ring_hwm=%u lat_avg_us=%.0f lat_max_us=%.0f"
	       " data_offset=%u beat_bytes=%u no_write=0",
	       (uint64_t)st.bytes, seconds, o.rate_set ? o.rate : 0, (uint64_t)st.drop_count, st.fifo_hwm,
	       st.fifo_depth, r ? r : (st.state == NVREC_RUN_DONE ? 0 : -EIO), st.cmd_errors,
	       o.chunk, o.qd ? o.qd : 32, g.nr_members, st.ring_hwm,
	       ctl_cycles_to_us(&info, st.lat_count ? st.lat_sum / st.lat_count : 0),
	       ctl_cycles_to_us(&info, st.lat_max), data_off, info.beat_bytes);
	ctl_result_stats(res, sizeof(res), &info, &st, 0);
	ctl_result_ring(res, sizeof(res), &ring);
	ctl_print_result(res, o.json);
	if (r || st.cmd_errors || st.state != NVREC_RUN_DONE) {
		err_msg("recording FAILED (%s)", r == -ETIMEDOUT ? "stalled" :
			st.cmd_errors ? "NVMe errors" : "run did not complete");
		ret = 1;
	} else if (st.drop_count) {
		err_msg("WARNING: %" PRIu64 " beats were dropped -- the recording is not valid",
			(uint64_t)st.drop_count);
		ret = 2;
	} else {
		ret = 0;
	}
	goto out;

out_unlink:
	/* setup failed after the file was created: remove it */
	if (!o.raw && prealloc) {
		exfat_close(&vol);
		if (unmounted && vol_remount(&mnt) == 0)
			unmounted = false;
		if (!unmounted)
			unlink(o.output);
	}
out:
	exfat_close(&vol);
	if (unmounted) {
		vol_flush_bdev(t.dev);
		if (vol_remount(&mnt))
			err_msg("could not remount %s on %s: mount it by hand", mnt.source,
				mnt.mountpoint);
	}
	if (fd >= 0)
		close(fd);
	return ret;
}
