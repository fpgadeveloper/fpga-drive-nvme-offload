// SPDX-License-Identifier: MIT
/*
 * nvplay -- play a recording back into the fabric sink with the hardware
 * NVMe command path: the command builder issues NVMe Reads into the ring,
 * the ring reader streams the chunks in order to the user_data_sink (the
 * reference design's fdrec_check checker).
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * The volume stays mounted (nothing is written): the file is synced, its
 * cluster run is read from the raw device and handed to the hardware.
 *
 * Exit codes: 0 = complete; with the checker also ERRORS = 0, UNDERFLOWS = 0
 *                 and GAP_BEATS = the recording's drop_count,
 *             2 = complete, but the checker found a problem,
 *             1 = error (incl. an incomplete playback),
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
#include <unistd.h>
#include <endian.h>
#include <sys/ioctl.h>

#include "nvrec_uapi.h"
#include "nvrec_file.h"
#include "nvrec_common.h"
#include "nvrec_vol.h"
#include "nvrec_ctl.h"

#define DEF_DEVICE      "/dev/nvrec"

const char *prog_name = "nvplay";

static void usage(FILE *f)
{
	fprintf(f,
"Usage: nvplay [options] <file>\n"
"       nvplay [options] --raw <blockdev> --length <bytes> [--offset <bytes>]\n"
"\n"
"Play a recording back into the fabric data sink (hardware NVMe reads, ring\n"
"reader, hardware checker).\n"
"\n"
"Options:\n"
"  --rate <bytes/s>      sink (checker) consumption rate (default: as is)\n"
"  --no-check            do not reset/enable the checker (custom sink)\n"
"  --buffers <n>         ring slots, 2..1024 (default: 256 MB of slots,\n"
"                        256 MB / chunk within 256..1024: 1024 x 256K,\n"
"                        512 x 512K, 256 x 1M)\n"
"  --qd <n>              NVMe reads in flight per SSD, 1..63 (default 32)\n"
"  --chunk <bytes>       raw mode: bytes per command (default 1M / md chunk)\n"
"  --raw <dev>           play raw LBAs of <dev>: --offset, --length\n"
"  --timeout <sec>       abort when no command completes for this long (default 10)\n"
"  --stats <sec>         live stats interval, 0 = off (default 1)\n"
"  --device <path>       control device (default %s)\n"
"  --json                also print the RESULT keys as one JSON object (next line)\n"
"  -q, --quiet           no live stats\n"
"  -h, --help            this help\n"
"\n"
"Exit code: 0 = clean playback, 2 = the checker found errors, gaps or\n"
"underflows, 1 = error, 5 = the Host Accelerator stopped responding\n"
"(evaluation license).\n", DEF_DEVICE);
}

int main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "rate", required_argument, NULL, 'r' },
		{ "no-check", no_argument, NULL, 'n' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "qd", required_argument, NULL, 'Q' },
		{ "chunk", required_argument, NULL, 'c' },
		{ "raw", no_argument, NULL, 'R' },
		{ "offset", required_argument, NULL, 'o' },
		{ "length", required_argument, NULL, 'l' },
		{ "timeout", required_argument, NULL, 't' },
		{ "stats", required_argument, NULL, 'S' },
		{ "device", required_argument, NULL, 'D' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "json", no_argument, NULL, 'J' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	const char *device = DEF_DEVICE, *input;
	struct ctl_run_opts ro = { .stats = 1.0, .timeout = 10.0, .play = true };
	uint64_t rate = 0, offset = 0, length = 0, v, data_bytes, drops = 0, array_off;
	uint32_t slots = 0, qd = 0, chunk = 0, data_off = 0, nch, last;
	bool rate_set = false, check = true, raw = false, json = false;
	struct nvrec_info info;
	struct nvrec_geometry g;
	struct nvrec_ring ring;
	struct nvrec_start start;
	struct nvrec_stats st;
	struct vol_target t;
	struct vol_mount mnt;
	char err[512], res[CTL_RESULT_MAX];
	unsigned lba_shift = 9;
	double seconds;
	int c, fd = -1, ret = 1, r;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		switch (c) {
		case 'r':
			if (parse_size(optarg, &rate) || !rate)
				return die_usage("invalid --rate '%s'", optarg), 1;
			rate_set = true;
			break;
		case 'n': check = false; break;
		case 'b':
			if (parse_size(optarg, &v) || v < 2 || v > NVREC_RING_MAX_SLOTS)
				return die_usage("--buffers must be 2..%d", NVREC_RING_MAX_SLOTS), 1;
			slots = (uint32_t)v;
			break;
		case 'Q':
			if (parse_size(optarg, &v) || v < 1 || v > 63)
				return die_usage("--qd must be 1..63"), 1;
			qd = (uint32_t)v;
			break;
		case 'c':
			if (parse_size(optarg, &v) || v < NVREC_MIN_CHUNK ||
			    v > NVREC_MAX_CHUNK || (v & (v - 1)))
				return die_usage("--chunk must be a power of two, 64K..4M"), 1;
			chunk = (uint32_t)v;
			break;
		case 'R': raw = true; break;
		case 'o':
			if (parse_size(optarg, &offset))
				return die_usage("invalid --offset"), 1;
			break;
		case 'l':
			if (parse_size(optarg, &length) || !length)
				return die_usage("invalid --length"), 1;
			break;
		case 't':
			if (parse_double(optarg, &ro.timeout) || ro.timeout < 0)
				return die_usage("invalid --timeout"), 1;
			break;
		case 'S':
			if (parse_double(optarg, &ro.stats) || ro.stats < 0)
				return die_usage("invalid --stats"), 1;
			break;
		case 'D': device = optarg; break;
		case 'q': ro.quiet = true; break;
		case 'J': json = true; break;
		case 'h': usage(stdout); return 0;
		default: usage(stderr); return 1;
		}
	}
	if (optind != argc - 1) {
		usage(stderr);
		return 1;
	}
	input = argv[optind];
	ctl_install_signals();

	if (raw) {
		if (!length)
			return die_usage("--raw needs --length"), 1;
		if (vol_resolve_target(input, &t, err, sizeof(err))) {
			err_msg("%s", err);
			return 1;
		}
		if (!chunk)
			chunk = t.md ? (uint32_t)t.chunk_bytes : (1u << 20);
		array_off = offset;
		data_bytes = length;
	} else {
		struct nvrec_file_header h;
		struct exfat_vol vol;
		struct exfat_file xf;
		uint64_t dev_off, alloc;
		int ffd = open(input, O_RDONLY | O_CLOEXEC);

		if (ffd < 0 || pread(ffd, &h, sizeof(h), 0) != (ssize_t)sizeof(h)) {
			perr("%s", input);
			return 1;
		}
		/* everything of the file on the media before reading the raw device */
		syncfs(ffd);
		close(ffd);
		if (memcmp(h.magic, NVREC_FILE_MAGIC, NVREC_FILE_MAGIC_LEN) ||
		    !(le32toh(h.flags) & NVREC_FILE_FLAG_COMPLETE)) {
			err_msg("%s: not a complete nvrec recording", input);
			return 1;
		}
		data_off = le32toh(h.header_size);
		data_bytes = le64toh(h.data_bytes);
		drops = le64toh(h.drop_count);
		chunk = le32toh(h.chunk_bytes);
		if (vol_find_mount(input, &mnt) || vol_resolve_target(mnt.source, &t, err, sizeof(err))) {
			err_msg("%s: cannot resolve its volume", input);
			return 1;
		}
		/* read-only peek at the mounted volume: the file's directory
		 * entry and clusters are on disk (syncfs above) and do not
		 * change while it is not written */
		if (exfat_open(&vol, t.dev, false, true, err, sizeof(err))) {
			err_msg("%s", err);
			return 1;
		}
		r = exfat_lookup(&vol, mnt.relpath, &xf);
		if (!r)
			r = exfat_extent(&vol, &xf, &dev_off, &alloc);
		exfat_close(&vol);
		if (r) {
			errno = -r;
			perr("%s: cannot locate its clusters", input);
			return 1;
		}
		array_off = dev_off + data_off;
		if (array_off % chunk) {
			err_msg("%s: data is not chunk aligned on the device", input);
			return 1;
		}
	}
	if (t.md && t.chunk_bytes != chunk) {
		err_msg("md chunk %" PRIu64 " != recording chunk %u", t.chunk_bytes, chunk);
		return 1;
	}

	fd = ctl_open(device, &info);
	if (fd < 0)
		return ctl_exit_code();
	memset(&g, 0, sizeof(g));
	if (ctl_members(&info, &t, &g, &lba_shift, err, sizeof(err))) {
		err_msg("%s", err);
		goto out;
	}
	/* whole LBAs only: a STOPped recording's last chunk is LBA-padded with
	 * zero beats, which the checker would count as errors */
	data_bytes &= ~((1ull << lba_shift) - 1);
	nch = (uint32_t)((data_bytes + chunk - 1) / chunk);
	last = (uint32_t)(data_bytes - (uint64_t)(nch - 1) * chunk);
	if (!nch) {
		err_msg("nothing to play");
		goto out;
	}
	if (rate_set) {
		struct nvrec_rate rr = { .rate_bps = rate };

		if (ioctl(fd, NVREC_IOC_SET_SINK_RATE, &rr) < 0) {
			perr("NVREC_IOC_SET_SINK_RATE");
			goto out;
		}
		rate = rr.rate_bps;
	}
	if (!slots) {
		slots = ctl_default_slots(chunk, info.max_slots);
	} else if (info.max_slots && slots > info.max_slots) {
		err_msg("--buffers %u exceeds the hardware slot table (%u)", slots, info.max_slots);
		goto out;
	}
	if (ctl_set_ring(fd, chunk, slots, &ring))
		goto out;
	if (!ro.quiet)
		fprintf(stderr, "nvplay: %s: %u x %u-byte chunks from array chunk %" PRIu64
			" over %u member(s), ring %u slots (%" PRIu64 " MB), qd %u\n",
			input, nch, chunk, (uint64_t)(array_off / chunk), g.nr_members,
			ring.slots, (uint64_t)ring.bytes >> 20, qd ? qd : 32);
	g.start_chunk = array_off / chunk;
	g.length_chunks = nch;
	g.last_chunk_bytes = last == chunk ? 0 : last;
	g.qd = qd;
	if (ioctl(fd, NVREC_IOC_SET_GEOMETRY, &g) < 0) {
		perr("NVREC_IOC_SET_GEOMETRY");
		goto out;
	}
	memset(&start, 0, sizeof(start));
	start.flags = check ? NVREC_START_CHECK : 0;
	if (ioctl(fd, NVREC_IOC_PLAY_START, &start) < 0) {
		perr("NVREC_IOC_PLAY_START");
		goto out;
	}
	ro.expect_bytes = data_bytes;
	r = ctl_run(fd, &info, &ro, &st);
	if (r == -ENOLINK) {
		ret = NVREC_EXIT_HA_DEAD;
		goto out;
	}
	if (r && r != -ETIMEDOUT)
		goto out;
	/* elapsed = streaming time (sink enabled -> last beat taken); the
	 * ring prefill before the sink is enabled is reported separately */
	seconds = st.elapsed_ns / 1e9;
	ctl_print_summary(prog_name, &info, &st, seconds);
	printf("nvplay: ring %u slots x %u bytes = %" PRIu64 " MB, high-water %u slots\n",
	       ring.slots, chunk, (uint64_t)ring.bytes >> 20, st.ring_hwm);
	if (st.prefill_ns)
		printf("nvplay: ring prefill before the sink was enabled: %.3f s (not in the time above)\n",
		       st.prefill_ns / 1e9);
	if (check)
		printf("nvplay: checker: %" PRIu64 " beats, %" PRIu64 " errors, %" PRIu64
		       " gaps (%" PRIu64 " beats missing, recording dropped %" PRIu64 "), %" PRIu64
		       " underflows\n", (uint64_t)st.chk_beats, (uint64_t)st.chk_errors,
		       (uint64_t)st.chk_gaps, (uint64_t)st.chk_gap_beats, drops,
		       (uint64_t)st.chk_underflows);
	snprintf(res, sizeof(res), "bytes=%" PRIu64 " seconds=%.3f sink_rate_bps=%" PRIu64
	       " beats=%" PRIu64 " errors=%" PRIu64 " gaps=%" PRIu64 " gap_beats=%" PRIu64
	       " drop_count=%" PRIu64 " underflows=%" PRIu64 " nvme_errors=%u complete=%d error=%d"
	       " prefill_seconds=%.3f",
	       (uint64_t)st.bytes, seconds, rate_set ? rate : 0, (uint64_t)st.chk_beats,
	       (uint64_t)st.chk_errors, (uint64_t)st.chk_gaps, (uint64_t)st.chk_gap_beats,
	       drops, (uint64_t)st.chk_underflows, st.cmd_errors,
	       st.state == NVREC_RUN_DONE && st.bytes == data_bytes, r, st.prefill_ns / 1e9);
	ctl_result_stats(res, sizeof(res), &info, &st, CTL_RES_LAT);
	ctl_result_ring(res, sizeof(res), &ring);
	ctl_print_result(res, json);
	if (r || st.cmd_errors || st.state != NVREC_RUN_DONE || st.bytes != data_bytes)
		ret = 1;
	else if (check && (st.chk_errors || st.chk_underflows || st.chk_gap_beats != drops ||
			   st.chk_beats != data_bytes / 16))
		ret = 2;
	else
		ret = 0;
out:
	if (fd >= 0)
		close(fd);
	return ret;
}
