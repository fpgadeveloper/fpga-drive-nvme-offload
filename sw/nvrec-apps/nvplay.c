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
 * Units: the checker counts fabric beats of THIS design (16, 32 or 64
 * bytes, nvrec_info.beat_bytes); the test pattern is numbered in 16-byte
 * words. A recording made with another beat size plays the same: its gaps
 * are compared with its drop_count in words (drop_count x its beat_bytes /
 * 16 = the checker's gap beats x this design's beat_bytes / 16).
 *
 * --ring-only (register map 1.2): the ring-resident test of the fabric
 * path, no SSD. A fabric-only (DRY) record of exactly one ring of test
 * pattern fills the ring (--fill-rate), then fabric-only playbacks stream
 * the ring to the checker at --rate (--passes times): the ring reader ->
 * egress FIFO -> sink path alone, against the DDR the ring lives in.
 *
 * Exit codes: 0 = complete; with the checker also ERRORS = 0, UNDERFLOWS = 0
 *                 and the gaps = the recording's drop_count,
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
#define DEF_FILL_RATE   2000000000ull   /* --ring-only: TPG rate of the fill */
#define WORD_BYTES      16u             /* one test-pattern word */
#define FDREC_MAGIC     "FDREC\0\0\0"   /* fpga-drive-recorder files */

const char *prog_name = "nvplay";

static void usage(FILE *f)
{
	fprintf(f,
"Usage: nvplay [options] <file>\n"
"       nvplay [options] --raw <blockdev> --length <bytes> [--offset <bytes>]\n"
"       nvplay [options] --ring-only [--fill-rate <bytes/s>] [--passes <n>]\n"
"\n"
"Play a recording back into the fabric data sink (hardware NVMe reads, ring\n"
"reader, hardware checker).\n"
"\n"
"Options:\n"
"  --rate <bytes/s>      sink (checker) consumption rate (default: as is; at\n"
"                        most src_clk x the fabric beat, e.g. 8000 MB/s on a\n"
"                        256-bit design)\n"
"  --no-check            do not reset/enable the checker (custom sink)\n"
"  --buffers <n>         ring slots, 2..4096, at most the hardware slot table\n"
"                        (default: 512 MB of slots, 1 GB for a split ring:\n"
"                        bytes / chunk within 256..4096, e.g. 1024 x 512K\n"
"                        single, 2048 x 512K split); a split ring with\n"
"                        whole-chunk stripes uses an even count (an odd one\n"
"                        is rounded down)\n"
"  --ring <layout>       auto (default: the driver's choice -- split on a design\n"
"                        with a second ring memory, single for one SSD), single\n"
"                        (PS DDR), split (striped over PS DDR and the second\n"
"                        memory) or mem1 (all in the second memory); map 1.3\n"
"  --stripe <KB>|chunk   split ring: stripe unit, a power of two from 4 KB to the\n"
"                        chunk (default: the driver's); 'chunk' = whole slots\n"
"  --qd <n>              NVMe reads in flight per SSD, 1..63 (default 32)\n"
"  --chunk <bytes>       raw / ring-only: bytes per chunk (default 1M or the md\n"
"                        chunk; ring-only: 1M or the drives' MDTS if smaller)\n"
"  --raw <dev>           play raw LBAs of <dev>: --offset, --length\n"
"  --ring-only           fabric only (register map 1.2), no SSD, no file: fill\n"
"                        the ring once from the test pattern generator (a\n"
"                        fabric-only record of exactly one ring), then stream\n"
"                        the ring to the checker at --rate; the checker must see\n"
"                        every beat of the ring in order, without underflow\n"
"  --fill-rate <bytes/s> ring-only: generator rate of the fill (default 2000MB;\n"
"                        the fill must not drop a beat)\n"
"  --passes <n>          ring-only: playbacks of the ring (default 1)\n"
"  --timeout <sec>       abort when no command completes (ring-only: no data\n"
"                        moves) for this long (default 10)\n"
"  --stats <sec>         live stats interval, 0 = off (default 1)\n"
"  --device <path>       control device (default %s)\n"
"  --json                also print the RESULT keys as one JSON object (next line)\n"
"  -q, --quiet           no live stats\n"
"  -h, --help            this help\n"
"\n"
"Counts are in fabric beats of this design (RESULT beat_bytes: 16, 32 or 64\n"
"bytes); the pattern is numbered in 16-byte words. Recordings made with\n"
"another beat size (nvrec or fdrec header, file_beat_bytes) play the same.\n"
"\n"
"Exit code: 0 = clean playback, 2 = the checker found errors, gaps or\n"
"underflows, 1 = error, 5 = the Host Accelerator stopped responding\n"
"(evaluation license).\n", DEF_DEVICE);
}

struct popts {
	const char *device;
	const char *input;
	uint64_t rate, fill_rate, offset, length;
	uint32_t slots, qd, chunk, passes;
	uint32_t ring, stripe_kb;       /* --ring (0 = auto), --stripe (0 = default) */
	bool rate_set, check, raw, ring_only, json;
	struct ctl_run_opts ro;
};

/* What the checker must have seen for a clean playback */
struct chk_expect {
	uint64_t beats;         /* beats the sink takes (this design's beats) */
	uint64_t drops;         /* the recording's drop_count, in its own beats */
	unsigned file_beat;     /* bytes per beat of the recording */
	uint64_t first_seq;     /* word number of the first word played */
	bool know_first;        /* first_seq is known (header / ring fill) */
};

/*
 * The checker's verdict. Sequence numbers are in 16-byte words, the counters
 * in beats of wpb words; CHK_LAST_SEQ is the seq of word 0 of the last good
 * beat, so (without pattern errors) the first word the sink saw is
 *     last + wpb - (beats + gap_beats) x wpb.
 * Gaps: the checker's GAP_BEATS (this design's beats) vs the recording's
 * drop_count (its beats), compared in words.
 */
static bool chk_verdict(const struct nvrec_info *info, const struct nvrec_stats *st,
			const struct chk_expect *e, bool complete, const char *what)
{
	uint64_t wpb = info->beat_bytes / WORD_BYTES, fwpb = e->file_beat / WORD_BYTES;
	uint64_t gap_words = st->chk_gap_beats * wpb, drop_words = e->drops * fwpb;
	uint64_t first_seen = st->chk_last_seq + wpb - (st->chk_beats + st->chk_gap_beats) * wpb;
	bool ok = true;

	if (st->chk_errors) {
		printf("PROBLEM%s: %" PRIu64 " beats failed the pattern check\n", what,
		       (uint64_t)st->chk_errors);
		ok = false;
	}
	if (st->chk_underflows) {
		printf("PROBLEM%s: %" PRIu64 " underflows: the stream ran dry (the data came slower than the sink rate)\n",
		       what, (uint64_t)st->chk_underflows);
		ok = false;
	}
	if (gap_words != drop_words) {
		printf("PROBLEM%s: gap beats %" PRIu64 " (%" PRIu64 " words) != the recording's drop_count %"
		       PRIu64 " (%" PRIu64 " words)\n", what, (uint64_t)st->chk_gap_beats, gap_words,
		       e->drops, drop_words);
		ok = false;
	}
	if (e->know_first && st->chk_beats && !st->chk_errors && first_seen != e->first_seq) {
		printf("PROBLEM%s: first word at the sink %" PRIu64 " != the recording's first_seq %" PRIu64 "\n",
		       what, first_seen, e->first_seq);
		ok = false;
	}
	if (complete && st->chk_beats != e->beats) {
		printf("PROBLEM%s: the sink took %" PRIu64 " beats, %" PRIu64 " were played\n", what,
		       (uint64_t)st->chk_beats, e->beats);
		ok = false;
	}
	return ok;
}

static void print_checker(const struct nvrec_info *info, const struct nvrec_stats *st,
			  const struct chk_expect *e, const char *prefix)
{
	uint64_t wpb = info->beat_bytes / WORD_BYTES;

	printf("%schecker: %" PRIu64 " beats of %u bytes (expected %" PRIu64 "), %" PRIu64
	       " errors, %" PRIu64 " gaps (%" PRIu64 " beats = %" PRIu64 " words missing; recording dropped %"
	       PRIu64 " beats of %u bytes = %" PRIu64 " words), %" PRIu64 " underflows\n",
	       prefix, (uint64_t)st->chk_beats, info->beat_bytes, e->beats, (uint64_t)st->chk_errors,
	       (uint64_t)st->chk_gaps, (uint64_t)st->chk_gap_beats, (uint64_t)st->chk_gap_beats * wpb,
	       e->drops, e->file_beat, e->drops * (e->file_beat / WORD_BYTES),
	       (uint64_t)st->chk_underflows);
}

/*
 * --ring-only: fill the ring with one fabric-only record of exactly
 * ring.slots chunks (slot c holds chunk c, test pattern from word 0), then
 * play it back fabric-only (length = slots: every slot once, in order) with
 * the checker reset before each pass.
 */
static int play_ring_only(struct popts *o)
{
	struct nvrec_info info;
	struct nvrec_geometry g;
	struct nvrec_ring ring;
	struct nvrec_start fill_start, start;
	struct nvrec_stats fst, st, sum;
	struct nvrec_rate rr;
	struct ctl_run_opts ro = o->ro;
	struct chk_expect e;
	char res[CTL_RESULT_MAX], rdesc[64];
	uint64_t ring_data, fill_rate = o->fill_rate;
	double seconds = 0, prefill = 0;
	bool complete = true, check_ok = true;
	uint32_t chunk = o->chunk ? o->chunk : (1u << 20), slots = o->slots, p, done = 0, layout;
	int fd, r = 0, ret = 1;

	fd = ctl_open(o->device, &info, true);
	if (fd < 0)
		return ctl_exit_code();
	if (ctl_ring_layout(&info, o->ring, o->stripe_kb, 0, &layout))
		goto out;
	if (chunk > info.max_chunk) {
		if (o->chunk) {
			err_msg("--chunk %u exceeds the SSDs' maximum transfer size (%u)", chunk,
				info.max_chunk);
			goto out;
		}
		chunk = info.max_chunk;
	}
	if (o->check && !(info.caps & NVREC_CAP_CHECK)) {
		err_msg("%s has no checker: use --no-check", o->device);
		goto out;
	}
	if (!slots) {
		slots = ctl_default_slots(chunk, info.max_slots, layout);
	} else if (info.max_slots && slots > info.max_slots) {
		err_msg("--buffers %u exceeds the hardware slot table (%u)", slots, info.max_slots);
		goto out;
	}
	if (ctl_set_ring(fd, &info, chunk, slots, layout, o->stripe_kb, &ring))
		goto out;
	ring_data = (uint64_t)ring.slots * chunk;
	memset(&g, 0, sizeof(g));
	g.nr_members = 0;			/* no SSD */
	g.length_chunks = ring.slots;		/* exactly one ring */
	if (ioctl(fd, NVREC_IOC_SET_GEOMETRY, &g) < 0) {
		perr("NVREC_IOC_SET_GEOMETRY");
		goto out;
	}

	/* 1. fill: fabric-only record of one ring from the generator */
	rr.rate_bps = fill_rate;
	if (ioctl(fd, NVREC_IOC_SET_RATE, &rr) < 0) {
		perr("NVREC_IOC_SET_RATE");
		goto out;
	}
	fill_rate = rr.rate_bps;
	memset(&fill_start, 0, sizeof(fill_start));
	fill_start.flags = NVREC_START_TPG | NVREC_START_DRY;
	if (ioctl(fd, NVREC_IOC_RECORD_START, &fill_start) < 0) {
		perr("NVREC_IOC_RECORD_START (ring fill)");
		goto out;
	}
	ro.dry = true;
	ro.play = false;
	ro.quiet = true;
	ro.expect_bytes = ring_data;
	r = ctl_run(fd, &info, &ro, &fst);
	if (r || fst.state != NVREC_RUN_DONE || fst.bytes != ring_data) {
		err_msg("ring fill failed (%s: %" PRIu64 " of %" PRIu64 " bytes)",
			r ? strerror(-r) : "run did not complete", (uint64_t)fst.bytes, ring_data);
		goto out;
	}
	if (fst.drop_count) {
		err_msg("the ring fill dropped %" PRIu64 " beats at %.1f MB/s: lower --fill-rate",
			(uint64_t)fst.drop_count, fill_rate / 1e6);
		goto out;
	}
	if (!o->ro.quiet)
		fprintf(stderr, "nvplay: --ring-only: ring filled from the test pattern generator: %u x %u bytes (%"
			PRIu64 " MB, %s) at %.1f MB/s in %.3f s, 0 drops, %u-byte beats\n",
			ring.slots, chunk, ring_data >> 20, ctl_ring_describe(&ring, rdesc, sizeof(rdesc)),
			fill_rate / 1e6, fst.elapsed_ns / 1e9, info.beat_bytes);

	/* 2. playbacks of the ring: fabric only, every slot once, in order */
	if (o->rate_set) {
		rr.rate_bps = o->rate;
		if (ioctl(fd, NVREC_IOC_SET_SINK_RATE, &rr) < 0) {
			perr("NVREC_IOC_SET_SINK_RATE");
			goto out;
		}
		o->rate = rr.rate_bps;
	}
	memset(&e, 0, sizeof(e));
	e.beats = ring_data / info.beat_bytes;
	e.file_beat = info.beat_bytes;
	e.first_seq = fill_start.first_seq;
	e.know_first = true;
	memset(&sum, 0, sizeof(sum));
	ro = o->ro;
	ro.dry = true;
	ro.play = true;
	ro.expect_bytes = ring_data;
	for (p = 1; p <= o->passes && !ctl_stop_requested; p++) {
		char what[32];
		bool pass_complete;

		memset(&start, 0, sizeof(start));
		start.flags = (o->check ? NVREC_START_CHECK : 0) | NVREC_START_DRY;
		if (ioctl(fd, NVREC_IOC_PLAY_START, &start) < 0) {
			perr("NVREC_IOC_PLAY_START (ring only)");
			r = -errno;
			break;
		}
		r = ctl_run(fd, &info, &ro, &st);
		if (r && r != -ETIMEDOUT)
			break;
		done++;
		pass_complete = !r && st.state == NVREC_RUN_DONE && st.bytes == ring_data;
		complete = complete && pass_complete;
		seconds += st.elapsed_ns / 1e9;
		prefill += st.prefill_ns / 1e9;
		sum.bytes += st.bytes;
		sum.chk_beats += st.chk_beats;
		sum.chk_errors += st.chk_errors;
		sum.chk_gaps += st.chk_gaps;
		sum.chk_gap_beats += st.chk_gap_beats;
		sum.chk_underflows += st.chk_underflows;
		printf("nvplay: pass %u: %" PRIu64 " bytes in %.3f s, %.1f MB/s%s\n", p,
		       (uint64_t)st.bytes, st.elapsed_ns / 1e9,
		       st.elapsed_ns ? st.bytes / (st.elapsed_ns / 1e9) / 1e6 : 0.0,
		       pass_complete ? "" : " -- INCOMPLETE");
		if (o->check) {
			print_checker(&info, &st, &e, "nvplay:   ");
			snprintf(what, sizeof(what), " (pass %u)", p);
			if (!chk_verdict(&info, &st, &e, pass_complete, what))
				check_ok = false;
		}
		ctl_print_ports("nvplay", &info, &st);
		if (r)
			break;
	}
	if (done < o->passes)
		complete = false;

	printf("nvplay: ring only: %u of %u passes, %" PRIu64 " bytes in %.3f s, %.1f MB/s (fabric only: no NVMe command; %s)\n",
	       done, o->passes, (uint64_t)sum.bytes, seconds,
	       seconds > 0 ? sum.bytes / seconds / 1e6 : 0.0,
	       ctl_ring_describe(&ring, rdesc, sizeof(rdesc)));
	snprintf(res, sizeof(res), "bytes=%" PRIu64 " seconds=%.3f sink_rate_bps=%" PRIu64
		 " beats=%" PRIu64 " errors=%" PRIu64 " gaps=%" PRIu64 " gap_beats=%" PRIu64
		 " drop_count=0 underflows=%" PRIu64 " nvme_errors=0 complete=%d error=%d"
		 " prefill_seconds=%.3f beat_bytes=%u file_beat_bytes=%u ring_only=1 passes=%u"
		 " fill_rate_bps=%" PRIu64 " fill_seconds=%.3f",
		 (uint64_t)sum.bytes, seconds, o->rate_set ? o->rate : 0, (uint64_t)sum.chk_beats,
		 (uint64_t)sum.chk_errors, (uint64_t)sum.chk_gaps, (uint64_t)sum.chk_gap_beats,
		 (uint64_t)sum.chk_underflows, complete, r, prefill, info.beat_bytes, info.beat_bytes,
		 done, fill_rate, fst.elapsed_ns / 1e9);
	if (done)
		ctl_result_stats(res, sizeof(res), &info, &st, CTL_RES_LAT);
	ctl_result_ring(res, sizeof(res), &ring);
	ctl_print_result(res, o->json);
	if (!complete)
		ret = 1;
	else if (o->check && !check_ok)
		ret = 2;
	else
		ret = 0;
out:
	close(fd);
	return ret;
}

int main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "rate", required_argument, NULL, 'r' },
		{ "no-check", no_argument, NULL, 'n' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "ring", required_argument, NULL, 'G' },
		{ "stripe", required_argument, NULL, 'X' },
		{ "qd", required_argument, NULL, 'Q' },
		{ "chunk", required_argument, NULL, 'c' },
		{ "raw", no_argument, NULL, 'R' },
		{ "offset", required_argument, NULL, 'o' },
		{ "length", required_argument, NULL, 'l' },
		{ "ring-only", no_argument, NULL, 'O' },
		{ "fill-rate", required_argument, NULL, 'F' },
		{ "passes", required_argument, NULL, 'p' },
		{ "timeout", required_argument, NULL, 't' },
		{ "stats", required_argument, NULL, 'S' },
		{ "device", required_argument, NULL, 'D' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "json", no_argument, NULL, 'J' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	struct popts o = {
		.device = DEF_DEVICE, .fill_rate = DEF_FILL_RATE, .passes = 1, .check = true,
		.ro = { .stats = 1.0, .timeout = 10.0, .play = true },
	};
	uint64_t v, data_bytes, drops = 0, array_off, first_seq = 0;
	uint32_t slots, chunk, data_off = 0, nch, last, file_beat, layout;
	bool tpg = true, fill_set = false, passes_set = false;
	struct nvrec_info info;
	struct nvrec_geometry g;
	struct nvrec_ring ring;
	struct nvrec_start start;
	struct nvrec_stats st;
	struct vol_target t;
	struct vol_mount mnt;
	struct chk_expect e;
	char err[512], res[CTL_RESULT_MAX], rdesc[64];
	unsigned lba_shift = 9;
	double seconds;
	int c, fd = -1, ret = 1, r;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		switch (c) {
		case 'r':
			if (parse_size(optarg, &o.rate) || !o.rate)
				return die_usage("invalid --rate '%s'", optarg), 1;
			o.rate_set = true;
			break;
		case 'n': o.check = false; break;
		case 'b':
			if (parse_size(optarg, &v) || v < 2 || v > NVREC_RING_MAX_SLOTS)
				return die_usage("--buffers must be 2..%d", NVREC_RING_MAX_SLOTS), 1;
			o.slots = (uint32_t)v;
			break;
		case 'G':
			if (ctl_parse_ring(optarg, &o.ring))
				return die_usage("--ring must be auto, single, split or mem1"), 1;
			break;
		case 'X':
			if (ctl_parse_stripe(optarg, &o.stripe_kb))
				return die_usage("--stripe must be a power of two in KB, 4..4096, or 'chunk'"), 1;
			break;
		case 'Q':
			if (parse_size(optarg, &v) || v < 1 || v > 63)
				return die_usage("--qd must be 1..63"), 1;
			o.qd = (uint32_t)v;
			break;
		case 'c':
			if (parse_size(optarg, &v) || v < NVREC_MIN_CHUNK ||
			    v > NVREC_MAX_CHUNK || (v & (v - 1)))
				return die_usage("--chunk must be a power of two, 64K..4M"), 1;
			o.chunk = (uint32_t)v;
			break;
		case 'R': o.raw = true; break;
		case 'o':
			if (parse_size(optarg, &o.offset))
				return die_usage("invalid --offset"), 1;
			break;
		case 'l':
			if (parse_size(optarg, &o.length) || !o.length)
				return die_usage("invalid --length"), 1;
			break;
		case 'O': o.ring_only = true; break;
		case 'F':
			if (parse_size(optarg, &o.fill_rate) || !o.fill_rate)
				return die_usage("invalid --fill-rate '%s'", optarg), 1;
			fill_set = true;
			break;
		case 'p':
			if (parse_size(optarg, &v) || !v || v > 1000000)
				return die_usage("--passes must be 1..1000000"), 1;
			o.passes = (uint32_t)v;
			passes_set = true;
			break;
		case 't':
			if (parse_double(optarg, &o.ro.timeout) || o.ro.timeout < 0)
				return die_usage("invalid --timeout"), 1;
			break;
		case 'S':
			if (parse_double(optarg, &o.ro.stats) || o.ro.stats < 0)
				return die_usage("invalid --stats"), 1;
			break;
		case 'D': o.device = optarg; break;
		case 'q': o.ro.quiet = true; break;
		case 'J': o.json = true; break;
		case 'h': usage(stdout); return 0;
		default: usage(stderr); return 1;
		}
	}
	ctl_install_signals();
	if (o.ring_only) {
		if (optind != argc)
			return die_usage("--ring-only plays the ring: give no <file>"), 1;
		if (o.raw || o.offset || o.length || o.qd)
			return die_usage("--ring-only takes none of --raw, --offset, --length, --qd"), 1;
		return play_ring_only(&o);
	}
	if (fill_set || passes_set)
		return die_usage("--fill-rate and --passes need --ring-only"), 1;
	if (optind != argc - 1) {
		usage(stderr);
		return 1;
	}
	o.input = argv[optind];
	slots = o.slots;
	chunk = o.chunk;

	if (o.raw) {
		if (!o.length)
			return die_usage("--raw needs --length"), 1;
		if (vol_resolve_target(o.input, &t, err, sizeof(err))) {
			err_msg("%s", err);
			return 1;
		}
		if (!chunk)
			chunk = t.md ? (uint32_t)t.chunk_bytes : (1u << 20);
		array_off = o.offset;
		data_bytes = o.length;
		file_beat = 0;			/* no header: this design's beat */
	} else {
		struct nvrec_file_header h;
		struct exfat_vol vol;
		struct exfat_file xf;
		uint64_t dev_off, alloc;
		int ffd = open(o.input, O_RDONLY | O_CLOEXEC);

		if (ffd < 0 || pread(ffd, &h, sizeof(h), 0) != (ssize_t)sizeof(h)) {
			perr("%s", o.input);
			if (ffd >= 0)
				close(ffd);
			return 1;
		}
		/* everything of the file on the media before reading the raw device */
		syncfs(ffd);
		close(ffd);
		if (!memcmp(h.magic, FDREC_MAGIC, NVREC_FILE_MAGIC_LEN)) {
			err_msg("%s is an fpga-drive-recorder (fdrec) file: nvplay plays nvrec recordings (their data is chunk-aligned on the volume); nvverify checks both",
				o.input);
			return 1;
		}
		if (memcmp(h.magic, NVREC_FILE_MAGIC, NVREC_FILE_MAGIC_LEN) ||
		    !(le32toh(h.flags) & NVREC_FILE_FLAG_COMPLETE)) {
			err_msg("%s: not a complete nvrec recording", o.input);
			return 1;
		}
		file_beat = le32toh(h.beat_bytes);
		if (file_beat < WORD_BYTES || file_beat > 4096 || (file_beat & (file_beat - 1))) {
			err_msg("%s: unsupported beat_bytes %u in the header", o.input, file_beat);
			return 1;
		}
		tpg = le32toh(h.flags) & NVREC_FILE_FLAG_TPG;
		data_off = le32toh(h.header_size);
		data_bytes = le64toh(h.data_bytes);
		drops = le64toh(h.drop_count);
		first_seq = le64toh(h.first_seq);
		chunk = le32toh(h.chunk_bytes);
		if (vol_find_mount(o.input, &mnt) || vol_resolve_target(mnt.source, &t, err, sizeof(err))) {
			err_msg("%s: cannot resolve its volume", o.input);
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
			perr("%s: cannot locate its clusters", o.input);
			return 1;
		}
		array_off = dev_off + data_off;
		if (!chunk || array_off % chunk) {
			err_msg("%s: data is not chunk aligned on the device", o.input);
			return 1;
		}
	}
	if (t.md && t.chunk_bytes != chunk) {
		err_msg("md chunk %" PRIu64 " != recording chunk %u", t.chunk_bytes, chunk);
		return 1;
	}
	if (o.check && !tpg) {
		err_msg("%s was not recorded from the test pattern generator: the checker would flag every beat; use --no-check",
			o.input);
		return 1;
	}

	fd = ctl_open(o.device, &info, false);
	if (fd < 0)
		return ctl_exit_code();
	if (!file_beat)
		file_beat = info.beat_bytes;
	memset(&g, 0, sizeof(g));
	if (ctl_members(&info, &t, &g, &lba_shift, err, sizeof(err))) {
		err_msg("%s", err);
		goto out;
	}
	/* whole LBAs only: a STOPped recording's last chunk is LBA-padded with
	 * zero beats, which the checker would count as errors. An LBA (>= 512
	 * bytes) is a whole number of beats at every width. */
	data_bytes &= ~((1ull << lba_shift) - 1);
	nch = (uint32_t)((data_bytes + chunk - 1) / chunk);
	if (!nch) {
		err_msg("nothing to play");
		goto out;
	}
	last = (uint32_t)(data_bytes - (uint64_t)(nch - 1) * chunk);
	if (o.check && file_beat < info.beat_bytes && drops)
		fprintf(stderr, "nvplay: note: %s was recorded with %u-byte beats and has %" PRIu64
			" dropped beats; on this %u-byte datapath a gap that is not a whole beat is truncated in the gap count or counted as a bad beat\n",
			o.input, file_beat, drops, info.beat_bytes);
	if (o.rate_set) {
		struct nvrec_rate rr = { .rate_bps = o.rate };

		if (ioctl(fd, NVREC_IOC_SET_SINK_RATE, &rr) < 0) {
			perr("NVREC_IOC_SET_SINK_RATE");
			goto out;
		}
		o.rate = rr.rate_bps;
	}
	if (ctl_ring_layout(&info, o.ring, o.stripe_kb, g.nr_members, &layout))
		goto out;
	if (!slots) {
		slots = ctl_default_slots(chunk, info.max_slots, layout);
	} else if (info.max_slots && slots > info.max_slots) {
		err_msg("--buffers %u exceeds the hardware slot table (%u)", slots, info.max_slots);
		goto out;
	}
	if (ctl_set_ring(fd, &info, chunk, slots, layout, o.stripe_kb, &ring))
		goto out;
	if (!o.ro.quiet)
		fprintf(stderr, "nvplay: %s: %u x %u-byte chunks from array chunk %" PRIu64
			" over %u member(s), ring %u slots (%" PRIu64 " MB, %s), qd %u, %u-byte beats\n",
			o.input, nch, chunk, (uint64_t)(array_off / chunk), g.nr_members,
			ring.slots, (uint64_t)ring.bytes >> 20, ctl_ring_describe(&ring, rdesc, sizeof(rdesc)),
			o.qd ? o.qd : 32, info.beat_bytes);
	g.start_chunk = array_off / chunk;
	g.length_chunks = nch;
	g.last_chunk_bytes = last == chunk ? 0 : last;
	g.qd = o.qd;
	if (ioctl(fd, NVREC_IOC_SET_GEOMETRY, &g) < 0) {
		perr("NVREC_IOC_SET_GEOMETRY");
		goto out;
	}
	memset(&start, 0, sizeof(start));
	start.flags = o.check ? NVREC_START_CHECK : 0;
	if (ioctl(fd, NVREC_IOC_PLAY_START, &start) < 0) {
		perr("NVREC_IOC_PLAY_START");
		goto out;
	}
	o.ro.expect_bytes = data_bytes;
	r = ctl_run(fd, &info, &o.ro, &st);
	if (r == -ENOLINK) {
		ret = NVREC_EXIT_HA_DEAD;
		goto out;
	}
	if (r && r != -ETIMEDOUT)
		goto out;
	/* elapsed = streaming time (sink enabled -> last beat taken); the
	 * ring prefill before the sink is enabled is reported separately */
	seconds = st.elapsed_ns / 1e9;
	ctl_print_summary(prog_name, &info, &st, seconds, false);
	printf("nvplay: ring %u slots x %u bytes = %" PRIu64 " MB, %s, high-water %u slots\n",
	       ring.slots, chunk, (uint64_t)ring.bytes >> 20,
	       ctl_ring_describe(&ring, rdesc, sizeof(rdesc)), st.ring_hwm);
	if (st.prefill_ns)
		printf("nvplay: ring prefill before the sink was enabled: %.3f s (not in the time above)\n",
		       st.prefill_ns / 1e9);
	memset(&e, 0, sizeof(e));
	e.beats = data_bytes / info.beat_bytes;
	e.drops = drops;
	e.file_beat = file_beat;
	e.first_seq = first_seq;
	e.know_first = !o.raw;
	{
		bool complete = !r && st.state == NVREC_RUN_DONE && st.bytes == data_bytes;
		bool check_ok = true;

		if (o.check) {
			print_checker(&info, &st, &e, "nvplay: ");
			check_ok = chk_verdict(&info, &st, &e, complete, "");
		}
		snprintf(res, sizeof(res), "bytes=%" PRIu64 " seconds=%.3f sink_rate_bps=%" PRIu64
			 " beats=%" PRIu64 " errors=%" PRIu64 " gaps=%" PRIu64 " gap_beats=%" PRIu64
			 " drop_count=%" PRIu64 " underflows=%" PRIu64 " nvme_errors=%u complete=%d error=%d"
			 " prefill_seconds=%.3f beat_bytes=%u file_beat_bytes=%u ring_only=0 passes=1",
			 (uint64_t)st.bytes, seconds, o.rate_set ? o.rate : 0, (uint64_t)st.chk_beats,
			 (uint64_t)st.chk_errors, (uint64_t)st.chk_gaps, (uint64_t)st.chk_gap_beats,
			 drops, (uint64_t)st.chk_underflows, st.cmd_errors, complete, r,
			 st.prefill_ns / 1e9, info.beat_bytes, file_beat);
		ctl_result_stats(res, sizeof(res), &info, &st, CTL_RES_LAT);
		ctl_result_ring(res, sizeof(res), &ring);
		ctl_print_result(res, o.json);
		if (!complete || st.cmd_errors)
			ret = 1;
		else if (o.check && !check_ok)
			ret = 2;
		else
			ret = 0;
	}
out:
	if (fd >= 0)
		close(fd);
	return ret;
}
