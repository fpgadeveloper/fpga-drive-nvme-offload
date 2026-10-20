/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec_uapi.h -- user-space API of the nvrec kernel driver (/dev/nvrec).
 *
 * Shared by the kernel module (sw/nvrec-driver) and the apps (sw/nvrec-apps).
 * Fixed-width types, natural alignment and explicit padding: the layout is
 * identical for 32-bit and 64-bit user space. User pointers travel as __u64.
 * Names do not clash with include/nvrec_regs.h (the register map), so both
 * headers can be included together.
 *
 * The driver owns the NVMe SSDs behind the design's PCIe root ports (it binds
 * them instead of the stock nvme driver) and exposes:
 *
 *   /dev/nvrecXn1   one block device per SSD (namespace 1): filesystems,
 *                   mdadm, blkdiscard; I/O through the NVMe Host
 *                   Accelerator's software queue or the CPU command injector;
 *   /dev/nvrec      this control device: the hardware recorder / player.
 *
 * Recording model (docs/source/driver.md has the full description):
 *
 *   1. NVREC_IOC_SET_RING: the ring of chunk-sized slots in PS DDR. One chunk
 *      = one NVMe command. The ring must be physically contiguous (the
 *      hardware addresses slot s at ring base + s * chunk), so by default
 *      (addr = 0) the driver allocates it from CMA; an app may instead pass
 *      a 2 MB-hugepage mapping, accepted only if physically contiguous. The
 *      driver builds the PRP list of every slot once and programs the ring.
 *      The CPU never touches the sample data.
 *   2. NVREC_IOC_SET_GEOMETRY: stripe members (SSD, NSID, base LBA), the
 *      array chunk index of the first chunk and the run length. Array chunk
 *      A goes to member A mod N at LBA base[A mod N] + (A div N) * chunk/LBA
 *      -- the Linux md RAID0 layout when chunk = md chunk and base = the
 *      member's md data offset (docs/source/filesystem.md).
 *   3. NVREC_IOC_RECORD_START (or PLAY_START), then poll() / NVREC_IOC_WAIT
 *      until the run ends, NVREC_IOC_GET_STATS any time, NVREC_IOC_STOP to
 *      finish early (the open chunk is padded to a whole LBA, every command
 *      completes) or NVREC_IOC_ABORT.
 *   4. close() aborts a run that is still going and frees the ring.
 *
 * Exactly one process may hold /dev/nvrec open (-EBUSY otherwise).
 */

#ifndef NVREC_UAPI_H
#define NVREC_UAPI_H

#include <linux/types.h>
#ifdef __KERNEL__
#include <linux/ioctl.h>
#else
#include <sys/ioctl.h>
#endif

/*
 * 2: register map 1.1 -- nvrec_info.status (NVREC_STATUS_HA_DEAD),
 *    nvrec_stats.flags / run_fifo_hwm / ing_fifo_hwm / prefill_ns; the
 *    ha_* statistics of nvrec_ssd_stats are no longer read (always 0).
 */
#define NVREC_API_VERSION               2

#define NVREC_DEV_NAME                  "nvrec"         /* /dev/nvrec */
#define NVREC_DISK_PREFIX               "nvrec"         /* /dev/nvrec<ssd>n1 */

#define NVREC_MAX_SSD                   4               /* SSD slots reported */
#define NVREC_MAX_MEMBERS               2               /* stripe members (hardware) */

#define NVREC_HUGEPAGE                  (2u * 1024 * 1024)
#define NVREC_MIN_CHUNK                 (64u * 1024)    /* chunk: power of 2 */
#define NVREC_MAX_CHUNK                 (4u * 1024 * 1024)
#define NVREC_RING_MAX_SLOTS            1024            /* hardware slot table */
#define NVREC_RING_MAX_BYTES            (1ull << 30)

/* struct nvrec_info.caps */
#define NVREC_CAP_TPG                   (1u << 0)   /* test pattern generator */
#define NVREC_CAP_RECORD                (1u << 1)   /* fabric -> NVMe */
#define NVREC_CAP_PLAY                  (1u << 2)   /* NVMe -> fabric (ring reader) */
#define NVREC_CAP_CHECK                 (1u << 3)   /* fdrec_check sink/checker */
#define NVREC_CAP_INJECTOR              (1u << 4)   /* CPU command injector */
#define NVREC_CAP_SWQ                   (1u << 5)   /* IP software queue interface */

/* struct nvrec_ssd_info.io_path: how /dev/nvrecXn1 reaches the SSD */
#define NVREC_PATH_NONE                 0
#define NVREC_PATH_SWQ                  1           /* IP software SQ */
#define NVREC_PATH_INJECTOR             2           /* CPU injector -> hardware SQ */

/* struct nvrec_ssd_info.state */
#define NVREC_SSD_ABSENT                0           /* no SSD bound on this root port */
#define NVREC_SSD_LIVE                  1           /* controller up, I/O queues created */
#define NVREC_SSD_FAILED                2           /* controller disabled after an error */

struct nvrec_ssd_info {
	__u32 index;            /* SSD index in the IP (0 = SSD1 / first root port) */
	__u32 state;            /* NVREC_SSD_* */
	__u32 nsid;             /* namespace of the block device (1) */
	__u32 lba_shift;        /* log2(LBA size): 9 or 12 */
	__u64 nlba;             /* namespace size in LBAs */
	__u32 mdts_bytes;       /* max data transfer size (0 = no limit) */
	__u32 io_path;          /* NVREC_PATH_* */
	__u32 nr_io_queues;     /* I/O SQs the controller granted (Set Features NQ) */
	__u32 hw_queues;        /* I/O SQs created for the hardware interface */
	__u32 sw_queues;        /* I/O SQs created for the software interface */
	__u32 sq_depth;         /* entries per I/O SQ */
	__u32 vwc;              /* volatile write cache present */
	__u32 dsm;              /* Dataset Management (discard) supported */
	char  disk[32];         /* "nvrec0n1" */
	char  model[41];        /* Identify Controller, trimmed, NUL-terminated */
	char  serial[21];
	char  firmware[9];
	char  pci[13];          /* "0000:01:00.0" */
	__u64 reserved[4];
};

/* nvrec_info.status */
#define NVREC_STATUS_HA_DEAD            (1u << 0)   /* the NVMe Host Accelerator stopped
						     * responding (evaluation license
						     * expired?): no NVMe I/O until the
						     * bitstream is reloaded */

/* NVREC_IOC_GET_INFO */
struct nvrec_info {
	__u32 api_version;      /* NVREC_API_VERSION of the driver */
	__u32 hw_version;       /* nvrec_core VERSION: [31:16] major, [15:0] minor */
	__u64 src_clk_hz;       /* source clock (TPG, checker) */
	__u64 dp_clk_hz;        /* datapath clock (latency counters count it) */
	__u32 beat_bytes;       /* 16 */
	__u32 fifo_depth;       /* ingest FIFO depth in beats */
	__u32 caps;             /* NVREC_CAP_* */
	__u32 nr_ssd;           /* SSD slots in the IP (valid entries of ssd[]) */
	__u32 min_chunk;
	__u32 max_chunk;        /* min(NVREC_MAX_CHUNK, MDTS of the live SSDs) */
	__u32 max_slots;        /* hardware slot table size */
	__u32 max_qd;           /* largest per-SSD queue depth of the recorder */
	__u32 lat_bin0_log2;    /* latency histogram: bin 0 < 2^this dp_clk cycles */
	__u32 status;           /* NVREC_STATUS_* */
	struct nvrec_ssd_info ssd[NVREC_MAX_SSD];
	__u64 reserved[4];
};

/*
 * NVREC_IOC_SET_RING. addr = 0: the driver allocates bytes from CMA
 * (physically contiguous; the cma= kernel argument must leave room).
 * addr != 0: a 2 MB aligned hugepage mapping of bytes, accepted only if
 * physically contiguous. bytes: multiple of 2 MB, at most
 * NVREC_RING_MAX_BYTES; chunk: power of two in [NVREC_MIN_CHUNK,
 * NVREC_MAX_CHUNK], at most every live SSD's MDTS; slots = bytes / chunk
 * in 2..max_slots. Only while idle; bytes = 0 frees the ring.
 */
struct nvrec_ring {
	__u64 addr;             /* 0 = driver-allocated */
	__u64 bytes;
	__u32 chunk;            /* bytes per chunk = per NVMe command */
	__u32 flags;            /* must be 0 */
	__u32 slots;            /* out: bytes / chunk */
	__u32 reserved0;
	__u64 dma_addr;         /* out: ring bus address (diagnostics) */
	__u64 reserved[2];
};

struct nvrec_member {
	__u32 ssd;              /* SSD index (nvrec_ssd_info.index) */
	__u32 nsid;             /* namespace (must be the block device's) */
	__u64 base_lba;         /* LBA of member chunk 0 (md: the data offset) */
};

/*
 * NVREC_IOC_SET_GEOMETRY. Chunk c of a run (c = 0, 1, ...) is array chunk
 * A = start_chunk + c and goes to members[A % nr_members] at LBA
 * base_lba + (A / nr_members) * (chunk >> lba_shift). Every member must
 * use the same LBA size. Record: length_chunks = 0 runs until STOP (bounded
 * by nothing: only for raw-drive tests, needs NVREC_GEO_UNBOUNDED); the
 * driver checks that the run stays inside every namespace.
 * Playback: length_chunks != 0; last_chunk_bytes (multiple of the LBA size,
 * 0 = full chunk) trims the last chunk.
 */
#define NVREC_GEO_UNBOUNDED             (1u << 0)
#define NVREC_GEO_FUA                   (1u << 1)   /* FUA on every Write */

struct nvrec_geometry {
	__u32 nr_members;       /* 1 or 2 */
	__u32 flags;            /* NVREC_GEO_* */
	__u64 start_chunk;      /* array chunk index of the first chunk */
	__u32 length_chunks;    /* chunks in the run */
	__u32 last_chunk_bytes; /* playback only */
	__u32 qd;               /* recorder commands in flight per SSD, 0 = default */
	__u32 reserved0;
	struct nvrec_member members[NVREC_MAX_MEMBERS];
	__u64 reserved[2];
};

/* struct nvrec_start.flags */
#define NVREC_START_TPG                 (1u << 0)   /* record: reset + enable the TPG
						     * (else leave the source alone) */
#define NVREC_START_CHECK               (1u << 1)   /* play: reset + enable the checker */

/* NVREC_IOC_RECORD_START / NVREC_IOC_PLAY_START */
struct nvrec_start {
	__u32 flags;            /* in: NVREC_START_* */
	__u32 reserved0;
	__u64 first_seq;        /* out: TPG sequence of the first beat (0 after reset) */
	__u64 start_time_ns;    /* out: CLOCK_REALTIME at start */
	__u64 reserved[3];
};

/* struct nvrec_stats.state (driver view of the run) */
#define NVREC_RUN_IDLE                  0
#define NVREC_RUN_RECORD                1
#define NVREC_RUN_PLAY                  2
#define NVREC_RUN_DONE                  3   /* length reached / STOP: all completed */
#define NVREC_RUN_ABORTED               4
#define NVREC_RUN_FAILED                5   /* did not drain / Host Accelerator dead:
					     * member SSDs disabled */

#define NVREC_LAT_BINS                  16

/* struct nvrec_stats.flags */
#define NVREC_STATS_HA_DEAD             (1u << 0)   /* Host Accelerator stopped responding */

struct nvrec_ssd_stats {
	__u32 inflight;         /* recorder + injector commands in flight */
	__u32 inflight_hwm;
	__u32 credits;          /* hardware-interface credits now */
	__u32 issued;           /* SQEs accepted by the IP (nvrec_core count) */
	__u32 completed;        /* CQEs received */
	__u32 errors;           /* CQEs with status != 0 */
	__u32 ha_issued;        /* 0: the nvmeha statistics registers are not read
				 * in the stats path (sysfs ha_counters reads them) */
	__u32 ha_completed;     /* 0 */
	__u32 ha_errors;        /* 0 */
	__u32 reserved0;
};

/* NVREC_IOC_GET_STATS / STOP / ABORT */
struct nvrec_stats {
	__u32 state;            /* NVREC_RUN_* */
	__u32 hw_state;         /* nvrec_core STATE register (raw) */
	__u64 elapsed_ns;       /* since start (frozen when the run ended) */
	__u64 drop_count;       /* beats dropped while the record run accepted
				 * data (RUN_DROP_COUNT): pass/fail */
	__u64 beats_in;         /* beats offered by the source */
	__u64 beats_out;        /* beats the ring writer took */
	__u64 seq_next;         /* TPG next sequence number */
	__u32 fifo_hwm;         /* ingest FIFO high-water while the record run
				 * accepted data (RUN_FIFO_HWM), beats */
	__u32 fifo_depth;
	__u32 overflow;         /* ingest overflow (sticky) */
	__u32 cmd_errors;       /* recorder CQEs with status != 0 */
	__u64 chunks_filled;    /* chunks written into the ring */
	__u64 cmds_issued;      /* recorder SQEs accepted by the IP */
	__u64 cmds_done;        /* recorder CQEs received */
	__u64 chunks_released;  /* slots completed and released in order */
	__u64 bytes;            /* record: data bytes stored (no padding);
				 * play: bytes streamed to the sink */
	__u32 pad_bytes;        /* zero bytes added to the last chunk at STOP */
	__u32 unexpected_cqes;
	__u32 ring_fill;        /* slots in use now */
	__u32 ring_hwm;
	__u64 ring_full_cycles; /* dp_clk cycles the writer waited for a free slot */
	__u32 err_last_status;  /* [14:0] status, [20:16] SSD, [31] valid */
	__u32 err_last_cid;     /* [15:0] CID, [31:16] SQID */
	__u32 lat_min;          /* completion latency, dp_clk cycles */
	__u32 lat_max;
	__u64 lat_count;
	__u64 lat_sum;
	__u32 lat_hist[NVREC_LAT_BINS];  /* bin 0 < 2^lat_bin0_log2 cycles,
					  * bin i = [2^(b0+i-1), 2^(b0+i)), last = rest */
	struct nvrec_ssd_stats ssd[NVREC_MAX_SSD];
	/* checker (playback), 0 without NVREC_CAP_CHECK */
	__u64 chk_beats;
	__u64 chk_errors;
	__u64 chk_gaps;
	__u64 chk_gap_beats;
	__u64 chk_underflows;
	__u64 chk_last_seq;
	__u64 ing_drop_count;   /* ingest FIFO drops, sticky, counting on after
				 * the run (drop_count = RUN_DROP_COUNT) */
	__u32 flags;            /* NVREC_STATS_* */
	__u32 ing_fifo_hwm;     /* ING_FIFO_HWM: also counts the fill after the
				 * run when the source keeps running */
	__u64 prefill_ns;       /* playback with the checker: start -> sink
				 * enabled (ring prefill); elapsed_ns - prefill_ns
				 * is the streaming time */
	__u64 reserved[1];
};

/* NVREC_IOC_WAIT: block until the run has ended, or timeout */
struct nvrec_wait {
	__s32 timeout_ms;       /* in: < 0 forever, 0 poll */
	__u32 state;            /* out: NVREC_RUN_* */
};

/* NVREC_IOC_SET_RATE / SET_SINK_RATE: bytes/s; out: programmed (rounded) */
struct nvrec_rate {
	__u64 rate_bps;
};

#define NVREC_IOC_MAGIC                 0xBE

#define NVREC_IOC_GET_INFO      _IOR(NVREC_IOC_MAGIC, 0x00, struct nvrec_info)
#define NVREC_IOC_SET_RING      _IOWR(NVREC_IOC_MAGIC, 0x01, struct nvrec_ring)
#define NVREC_IOC_SET_GEOMETRY  _IOW(NVREC_IOC_MAGIC, 0x02, struct nvrec_geometry)
#define NVREC_IOC_RECORD_START  _IOWR(NVREC_IOC_MAGIC, 0x03, struct nvrec_start)
#define NVREC_IOC_PLAY_START    _IOWR(NVREC_IOC_MAGIC, 0x04, struct nvrec_start)
#define NVREC_IOC_WAIT          _IOWR(NVREC_IOC_MAGIC, 0x05, struct nvrec_wait)
#define NVREC_IOC_GET_STATS     _IOR(NVREC_IOC_MAGIC, 0x06, struct nvrec_stats)
#define NVREC_IOC_STOP          _IOR(NVREC_IOC_MAGIC, 0x07, struct nvrec_stats)
#define NVREC_IOC_ABORT         _IOR(NVREC_IOC_MAGIC, 0x08, struct nvrec_stats)
#define NVREC_IOC_SET_RATE      _IOWR(NVREC_IOC_MAGIC, 0x09, struct nvrec_rate)
#define NVREC_IOC_SET_SINK_RATE _IOWR(NVREC_IOC_MAGIC, 0x0A, struct nvrec_rate)

#endif /* NVREC_UAPI_H */
