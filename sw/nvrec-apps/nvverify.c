// SPDX-License-Identifier: MIT
/*
 * nvverify -- verify a recording beat by beat (port of fpga-drive-recorder's
 * fdverify).
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Reads nvrec recordings (data at the header's header_size offset) and fdrec
 * recordings (data at 4096), or -- with --raw -- a byte range of a block
 * device recorded by "nvrec --raw" (no header). It streams the data with
 * large reads and checks every 16-byte beat of a test-pattern recording:
 *     upper == ~lower           (else: corrupted beat)
 *     lower == previous + 1     (else: discontinuity = dropped beats)
 * and compares the beat count and the number of missing beats with the
 * header's data_bytes and drop_count.
 *
 * Exit code 0 only on a clean file: complete header, size consistent, no
 * corrupted beats, no discontinuities, drop_count 0. 1 otherwise (2 for usage
 * or I/O errors).
 */

#define _GNU_SOURCE
#include <endian.h>
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
#include <sys/stat.h>

#include "nvrec_file.h"
#include "nvrec_common.h"

/* fpga-drive-recorder files: same leading fields, data at 4096 */
#define FDREC_FILE_MAGIC                "FDREC\0\0\0"
#define FDREC_FILE_HEADER_SIZE          4096

const char *prog_name = "nvverify";

#define CHUNK           (8u << 20)      /* read size */
#define BEAT            16u

static void usage(FILE *f)
{
	fprintf(f,
"Usage: nvverify [options] <file>\n"
"       nvverify [options] --raw --length <bytes> [--offset <bytes>] <blockdev>\n"
"\n"
"Verify an nvrec (or fdrec) recording: parse the header, then check every\n"
"16-byte beat of the test pattern (upper == ~lower, lower == previous + 1).\n"
"\n"
"Options:\n"
"  --raw              <blockdev> holds a raw recording (nvrec --raw): no header,\n"
"                     the first beat may have any sequence number\n"
"  --offset <bytes>   raw: start of the recording on the device (default 0)\n"
"  --length <bytes>   raw: bytes to check (required)\n"
"  --max-errors <n>   print at most n discontinuities and n corrupted beats\n"
"                     (default 20; all are still counted)\n"
"  --header-only      only parse and print the header\n"
"  --pattern          check the test pattern even if the header says the\n"
"                     source was not the test pattern generator\n"
"  -q, --quiet        no progress output\n"
"  -h, --help         this help\n"
"\n"
"Exit code: 0 = clean file (no dropped, missing or corrupted beats),\n"
"1 = problems found, 2 = usage or I/O error.\n");
}

static void print_time(const char *label, uint64_t ns)
{
	time_t t = (time_t)(ns / 1000000000ull);
	struct tm tm;
	char buf[64] = "-";

	if (ns && gmtime_r(&t, &tm))
		strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S UTC", &tm);
	printf("  %-15s %s (%" PRIu64 " ns)\n", label, buf, ns);
}

int main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "max-errors", required_argument, NULL, 'm' },
		{ "header-only", no_argument, NULL, 'H' },
		{ "pattern", no_argument, NULL, 'P' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "raw", no_argument, NULL, 'R' },
		{ "offset", required_argument, NULL, 'o' },
		{ "length", required_argument, NULL, 'l' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	struct nvrec_file_header h;
	bool raw = false;
	uint64_t raw_off = 0, raw_len = 0;
	uint64_t max_err = 20, file_size, data_len, hdr_bytes, hdr_drops;
	uint64_t beats = 0, first = 0, expected = 0, gaps = 0, missing = 0;
	uint64_t backward = 0, corrupt = 0, printed_gaps = 0, printed_bad = 0;
	uint32_t flags, hsize;
	bool header_only = false, force_pattern = false, quiet = false;
	bool check, ok = true, have_prev = false;
	uint8_t *buf;
	double t0, tlast;
	struct stat st;
	int fd, c;
	uint64_t off;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		switch (c) {
		case 'm':
			if (parse_size(optarg, &max_err))
				return die_usage("invalid --max-errors '%s'", optarg), 2;
			break;
		case 'H':
			header_only = true;
			break;
		case 'P':
			force_pattern = true;
			break;
		case 'q':
			quiet = true;
			break;
		case 'R':
			raw = true;
			break;
		case 'o':
			if (parse_size(optarg, &raw_off))
				return die_usage("invalid --offset '%s'", optarg), 2;
			break;
		case 'l':
			if (parse_size(optarg, &raw_len) || !raw_len)
				return die_usage("invalid --length '%s'", optarg), 2;
			break;
		case 'h':
			usage(stdout);
			return 0;
		default:
			usage(stderr);
			return 2;
		}
	}
	if (optind != argc - 1) {
		usage(stderr);
		return 2;
	}

	fd = open(argv[optind], O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) < 0) {
		perr("%s", argv[optind]);
		return 2;
	}
	file_size = (uint64_t)st.st_size;
	if (raw) {
		/* a block device: st_size is 0, the range comes from the options */
		if (!raw_len) {
			err_msg("--raw needs --length");
			return 2;
		}
		if (raw_off % 4096 || raw_len % BEAT) {
			err_msg("--offset must be 4 KB aligned and --length a multiple of 16");
			return 2;
		}
		memset(&h, 0, sizeof(h));
		hsize = 0;
		flags = NVREC_FILE_FLAG_TPG | NVREC_FILE_FLAG_COMPLETE;
		hdr_bytes = raw_len;
		hdr_drops = 0;
		data_len = raw_len;
		printf("%s: raw, bytes %" PRIu64 "..%" PRIu64 "\n", argv[optind], raw_off,
		       raw_off + raw_len);
		goto data;
	}
	if (pread(fd, &h, sizeof(h), 0) != (ssize_t)sizeof(h)) {
		err_msg("%s: too short for a %d-byte header", argv[optind],
			NVREC_FILE_HEADER_BYTES);
		return 1;
	}
	if (memcmp(h.magic, NVREC_FILE_MAGIC, NVREC_FILE_MAGIC_LEN) &&
	    memcmp(h.magic, FDREC_FILE_MAGIC, NVREC_FILE_MAGIC_LEN)) {
		err_msg("%s: not an nvrec/fdrec recording (bad magic)", argv[optind]);
		return 1;
	}
	hsize = le32toh(h.header_size);
	flags = le32toh(h.flags);
	hdr_bytes = le64toh(h.data_bytes);
	hdr_drops = le64toh(h.drop_count);

	printf("%s:\n", argv[optind]);
	printf("  header          %.5s version %u, data at %u, %u-byte beats\n",
	       h.magic, le32toh(h.header_version), hsize, le32toh(h.beat_bytes));
	printf("  flags           0x%x (%s, %s)\n", flags,
	       flags & NVREC_FILE_FLAG_TPG ? "test pattern" : "user source",
	       flags & NVREC_FILE_FLAG_COMPLETE ? "complete" : "INCOMPLETE");
	printf("  design version  %u.%u\n", le32toh(h.design_version) >> 16,
	       le32toh(h.design_version) & 0xffff);
	printf("  target / host   %.32s / %.64s\n", h.target, h.hostname);
	printf("  src_clk_hz      %" PRIu64 "\n", (uint64_t)le64toh(h.src_clk_hz));
	printf("  rate_bps        %" PRIu64 "%s\n", (uint64_t)le64toh(h.rate_bps),
	       h.rate_bps ? "" : " (not set by the recorder)");
	print_time("start", le64toh(h.start_time_ns));
	print_time("stop", le64toh(h.stop_time_ns));
	printf("  data_bytes      %" PRIu64 "\n", hdr_bytes);
	printf("  drop_count      %" PRIu64 "\n", hdr_drops);
	printf("  first_seq       %" PRIu64 "\n", (uint64_t)le64toh(h.first_seq));
	if (!memcmp(h.magic, NVREC_FILE_MAGIC, NVREC_FILE_MAGIC_LEN)) {
		printf("  chunk / members %u bytes / %u, start chunk %" PRIu64 ", qd %u\n",
		       le32toh(h.chunk_bytes), le32toh(h.nr_members),
		       (uint64_t)le64toh(h.start_chunk), le32toh(h.qd));
		printf("  NVMe            %u errors, latency avg %.0f us, max %.0f us\n",
		       le32toh(h.cmd_errors), le64toh(h.lat_avg_ns) / 1e3,
		       le64toh(h.lat_max_ns) / 1e3);
		if (le32toh(h.cmd_errors)) {
			printf("PROBLEM: the recorder saw NVMe errors\n");
			ok = false;
		}
		if (le32toh(h.header_version) != NVREC_FILE_HEADER_VERSION ||
		    hsize < NVREC_FILE_HEADER_BYTES || hsize % 4096 ||
		    le32toh(h.beat_bytes) != BEAT) {
			err_msg("unsupported header (version/size/beat_bytes)");
			return 1;
		}
	} else if (le32toh(h.header_version) != 1 || hsize != FDREC_FILE_HEADER_SIZE ||
		   le32toh(h.beat_bytes) != BEAT) {
		err_msg("unsupported fdrec header (version/size/beat_bytes)");
		return 1;
	}
	if (!(flags & NVREC_FILE_FLAG_COMPLETE)) {
		printf("PROBLEM: header not finalized (recording interrupted?)\n");
		ok = false;
	}
	data_len = file_size > hsize ? file_size - hsize : 0;
	if ((flags & NVREC_FILE_FLAG_COMPLETE) && data_len != hdr_bytes) {
		printf("PROBLEM: file holds %" PRIu64 " data bytes, header says %" PRIu64 "\n",
		       data_len, hdr_bytes);
		ok = false;
	}
	if (data_len % BEAT) {
		printf("PROBLEM: data length %" PRIu64 " is not a multiple of %u\n",
		       data_len, BEAT);
		ok = false;
		data_len -= data_len % BEAT;
	}
	if (hdr_drops) {
		printf("PROBLEM: the recorder dropped %" PRIu64 " beats\n", hdr_drops);
		ok = false;
	}
	if (header_only)
		return ok ? 0 : 1;

data:
	check = (flags & NVREC_FILE_FLAG_TPG) || force_pattern;
	if (!check) {
		printf("not a test-pattern recording: data not checked (use --pattern to force)\n");
		printf("RESULT %s\n", ok ? "PASS" : "FAIL");
		return ok ? 0 : 1;
	}

	buf = aligned_alloc(4096, CHUNK);
	if (!buf) {
		err_msg("out of memory");
		return 2;
	}
	posix_fadvise(fd, hsize, (off_t)data_len, POSIX_FADV_SEQUENTIAL);
	t0 = tlast = now_s();
	for (off = 0; off < data_len;) {
		size_t want = (size_t)((data_len - off) < CHUNK ? data_len - off : CHUNK);
		ssize_t n = pread(fd, buf, want, (off_t)(raw_off + hsize + off));
		size_t i;

		if (n <= 0) {
			perr("read at offset %" PRIu64, hsize + off);
			return 2;
		}
		n -= n % BEAT;
		if (!n) {
			err_msg("short read at offset %" PRIu64, hsize + off);
			return 2;
		}
		for (i = 0; i < (size_t)n; i += BEAT) {
			uint64_t lo, hi;

			memcpy(&lo, buf + i, 8);
			memcpy(&hi, buf + i + 8, 8);
			lo = le64toh(lo);
			hi = le64toh(hi);
			if (hi != ~lo) {
				/* do not trust lo: assume the expected value */
				if (printed_bad < max_err) {
					printf("CORRUPT beat %" PRIu64 " at file offset %" PRIu64
					       ": lower 0x%016" PRIx64 " upper 0x%016" PRIx64 "\n",
					       beats, hsize + off + i, lo, hi);
					printed_bad++;
				}
				corrupt++;
				if (!have_prev) {
					have_prev = true;
					first = 0;
				}
				expected++;
				beats++;
				continue;
			}
			if (!have_prev) {
				have_prev = true;
				first = lo;
			} else if (lo != expected) {
				if (printed_gaps < max_err) {
					if (lo > expected)
						printf("GAP at beat %" PRIu64 " (file offset %" PRIu64
						       "): expected %" PRIu64 ", found %" PRIu64
						       ", %" PRIu64 " beats missing\n",
						       beats, hsize + off + i, expected, lo,
						       lo - expected);
					else
						printf("BACKWARD at beat %" PRIu64 " (file offset %" PRIu64
						       "): expected %" PRIu64 ", found %" PRIu64 "\n",
						       beats, hsize + off + i, expected, lo);
					printed_gaps++;
				}
				gaps++;
				if (lo > expected)
					missing += lo - expected;
				else
					backward++;
			}
			expected = lo + 1;
			beats++;
		}
		off += (uint64_t)n;
		if (!quiet && isatty(2) && now_s() - tlast >= 1.0) {
			tlast = now_s();
			fprintf(stderr, "\r  %5.1f%%  %.0f MB/s   ", 100.0 * off / data_len,
				off / (tlast - t0) / 1e6);
		}
	}
	if (!quiet && isatty(2))
		fprintf(stderr, "\r%40s\r", "");
	free(buf);
	close(fd);

	printf("  beats           %" PRIu64 " (%" PRIu64 " bytes)\n", beats, beats * BEAT);
	printf("  first sequence  %" PRIu64 "%s\n", first,
	       !raw && beats && first != le64toh(h.first_seq) ? " (DIFFERS from header first_seq)" : "");
	printf("  last sequence   %" PRIu64 "\n", beats ? expected - 1 : 0);
	printf("  discontinuities %" PRIu64 "%s, beats missing %" PRIu64 "\n", gaps,
	       gaps > printed_gaps ? " (list capped)" : "", missing);
	printf("  corrupted beats %" PRIu64 "%s\n", corrupt,
	       corrupt > printed_bad ? " (list capped)" : "");

	if (!beats) {
		printf("PROBLEM: no data\n");
		ok = false;
	}
	if (!raw && beats && first != le64toh(h.first_seq)) {
		printf("PROBLEM: first beat %" PRIu64 " != header first_seq %" PRIu64
		       " (beats missing at the start)\n", first,
		       (uint64_t)le64toh(h.first_seq));
		ok = false;
	}
	if (corrupt || gaps)
		ok = false;
	/* The header's drop count is read when the last buffer completed, so it
	 * may include drops after the last recorded beat: it must cover what is
	 * missing, and be 0 when nothing is. */
	if (missing > hdr_drops) {
		printf("PROBLEM: %" PRIu64 " beats missing but the header reports only %" PRIu64
		       " dropped\n", missing, hdr_drops);
		ok = false;
	} else if (missing && missing != hdr_drops) {
		printf("note: header drop_count %" PRIu64 " >= %" PRIu64
		       " beats missing in the file (drops after the last recorded beat)\n",
		       hdr_drops, missing);
	} else if (missing) {
		printf("note: missing beats match the header drop_count exactly\n");
	}
	printf("RESULT %s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
