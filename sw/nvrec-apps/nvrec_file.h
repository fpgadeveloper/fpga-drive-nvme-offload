/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec_file.h -- on-disk format of an NVMe-offload recording.
 *
 * Same idea as fpga-drive-recorder's fdrec_file.h, with one difference: the
 * hardware writes whole chunks at chunk-aligned array positions, so the data
 * starts at the first chunk boundary after the file's first 4 KB, not at a
 * fixed 4096:
 *
 *     offset 0             struct nvrec_file_header (4096 bytes)
 *     4096 .. data_offset  zero padding
 *     offset data_offset   beat 0, beat 1, ... (data_bytes bytes)
 *
 * header_size holds data_offset (a multiple of 4096, at most chunk + 4096 -
 * 4096). The first fields are laid out exactly like fdrec_file_header, so
 * tools that only read those keep working; nvverify reads both formats.
 * With the test pattern generator as the source, beat n carries
 * lower = first_seq + n (+ beats dropped before it), upper = ~lower.
 * Little-endian, packed, size checked at compile time.
 */

#ifndef NVREC_FILE_H
#define NVREC_FILE_H

#include <stdint.h>

#define NVREC_FILE_MAGIC                "NVREC\0\0\0"
#define NVREC_FILE_MAGIC_LEN            8
#define NVREC_FILE_HEADER_VERSION       1
#define NVREC_FILE_HEADER_BYTES         4096

#define NVREC_FILE_FLAG_TPG             (1u << 0)   /* source was the TPG */
#define NVREC_FILE_FLAG_COMPLETE        (1u << 1)   /* header written after the run */

struct nvrec_file_header {
	/* --- identical to fdrec_file_header --- */
	char     magic[8];          /* "NVREC\0\0\0" */
	uint32_t header_version;    /* NVREC_FILE_HEADER_VERSION */
	uint32_t header_size;       /* = data offset in the file */
	uint32_t beat_bytes;        /* 16 */
	uint32_t flags;             /* NVREC_FILE_FLAG_* */
	uint32_t design_version;    /* nvrec_core VERSION register */
	uint64_t src_clk_hz;
	uint64_t rate_bps;          /* 0 if not set by nvrec */
	uint64_t start_time_ns;     /* CLOCK_REALTIME at start */
	uint64_t stop_time_ns;
	uint64_t data_bytes;        /* beats * 16 */
	uint64_t drop_count;
	uint64_t first_seq;
	char     target[32];
	char     hostname[64];
	/* --- nvrec additions --- */
	uint32_t chunk_bytes;       /* NVMe command size of the run */
	uint32_t nr_members;        /* stripe members */
	uint64_t start_chunk;       /* array chunk index of the data start */
	uint32_t cmd_errors;        /* NVMe completions with an error */
	uint32_t qd;                /* commands in flight per SSD (setting) */
	uint64_t lat_avg_ns;        /* average command latency */
	uint64_t lat_max_ns;
	uint8_t  reserved[NVREC_FILE_HEADER_BYTES - 8 - 5 * 4 - 7 * 8 - 32 - 64 -
			  2 * 4 - 8 - 2 * 4 - 2 * 8];
} __attribute__((packed));

_Static_assert(sizeof(struct nvrec_file_header) == NVREC_FILE_HEADER_BYTES,
	       "nvrec_file_header must be 4096 bytes");

#endif /* NVREC_FILE_H */
