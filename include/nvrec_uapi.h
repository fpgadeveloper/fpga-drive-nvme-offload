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
 *   1. NVREC_IOC_SET_RING: the ring of chunk-sized slots. One chunk = one
 *      NVMe command. The ring must be physically contiguous (the hardware
 *      addresses slot s at ring base + s * chunk), so by default (addr = 0)
 *      the driver allocates it from CMA; an app may instead pass a
 *      2 MB-hugepage mapping, accepted only if physically contiguous. The
 *      driver builds the PRP list of every slot once and programs the ring.
 *      The CPU never touches the sample data.
 *      Split ring (API 4, register map 1.3, NVREC_CAP_SPLIT_RING): on a
 *      design with two ring ports the ring can be striped over two memories
 *      -- memory 0 (PS DDR, CMA) and memory 1 (a second DDR the CPU does not
 *      use, reserved for the ring in the device tree) -- in stripes of
 *      2^stripe_shift bytes that alternate between them, so each memory
 *      carries half of the stream (NVREC_RING_SPLIT). NVREC_RING_MEM1 puts
 *      the whole ring in memory 1 (diagnostics).
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
 * Beats and words (register map 1.2): the fabric datapath is DATA_WIDTH
 * bits wide (128, 256 or 512); one transfer is a BEAT of
 * nvrec_info.beat_bytes = 16, 32 or 64 bytes. Every beat counter of
 * nvrec_stats (drop_count, beats_in/out, fifo_hwm, fifo_depth, chk_beats,
 * chk_errors, chk_gap_beats, ...) counts those fabric beats. The test
 * pattern is defined on 16-byte WORDS (a beat carries beat_bytes / 16 of
 * them): seq_next, chk_last_seq and nvrec_start.first_seq are word numbers.
 * Rates (NVREC_IOC_SET_RATE, SET_SINK_RATE) are in bytes/s at any width.
 *
 * Fabric-only runs (NVREC_START_DRY, register map 1.2, NVREC_CAP_DRY): no
 * NVMe command is built, no SSD is touched. A DRY record fills the ring
 * from the source and releases every slot as soon as it is filled; a DRY
 * playback streams the ring's slots (chunk c from slot c % slots) to the
 * sink. A DRY playback of length_chunks = slots right after a DRY record of
 * length_chunks = slots, with the same ring, plays that recording back: the
 * ring-resident test of the fabric/DDR path (nvplay --ring-only).
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
 * 3: register map 1.2 (driver 1.1) -- nvrec_info.beat_bytes from the
 *    hardware (16, 32 or 64; beat counters in those beats),
 *    nvrec_info.egr_fifo_depth, NVREC_START_DRY / NVREC_CAP_DRY,
 *    nr_members = 0 in NVREC_IOC_SET_GEOMETRY (DRY runs only),
 *    NVREC_RING_MAX_SLOTS 2048. Same structure layout as 2.
 * 4: register map 1.3 (driver 1.2) -- split ring: nvrec_ring.flags
 *    NVREC_RING_SINGLE / SPLIT / MEM1 (in: the layout, 0 = the driver's
 *    default; out: the layout used), nvrec_ring.stripe_shift (was
 *    reserved0), nvrec_ring.dma_addr1 (was reserved[0]);
 *    nvrec_info.ring_ports, ring1_base, ring1_bytes, ring_default,
 *    stripe_shift (were reserved), NVREC_CAP_SPLIT_RING,
 *    NVREC_STATUS_MEM1_DOWN; nvrec_stats.wr_port_stall[] / rd_port_wait[]
 *    (struct nvrec_stats grew by 32 bytes: NVREC_IOC_GET_STATS / STOP /
 *    ABORT have new numbers); NVREC_RING_MAX_SLOTS 4096. nvrec_info,
 *    nvrec_ring and the other structures keep their size.
 */
#define NVREC_API_VERSION               4

#define NVREC_DEV_NAME                  "nvrec"         /* /dev/nvrec */
#define NVREC_DISK_PREFIX               "nvrec"         /* /dev/nvrec<ssd>n1 */

#define NVREC_MAX_SSD                   4               /* SSD slots reported */
#define NVREC_MAX_MEMBERS               2               /* stripe members (hardware) */

#define NVREC_HUGEPAGE                  (2u * 1024 * 1024)
#define NVREC_MIN_CHUNK                 (64u * 1024)    /* chunk: power of 2 */
#define NVREC_MAX_CHUNK                 (4u * 1024 * 1024)
#define NVREC_RING_MAX_SLOTS            4096            /* largest hardware slot table
							 * (MAX_SLOTS: 4096 on the 1.3
							 * designs, 2048 on 1.2, 1024
							 * before) */
#define NVREC_RING_MAX_BYTES            (1ull << 30)    /* per memory: a single ring,
							 * each half of a split ring */
#define NVREC_RING_MAX_BYTES_SPLIT      (2ull << 30)    /* a split ring, both memories */

/* struct nvrec_info.caps */
#define NVREC_CAP_TPG                   (1u << 0)   /* test pattern generator */
#define NVREC_CAP_RECORD                (1u << 1)   /* fabric -> NVMe */
#define NVREC_CAP_PLAY                  (1u << 2)   /* NVMe -> fabric (ring reader) */
#define NVREC_CAP_CHECK                 (1u << 3)   /* fdrec_check sink/checker */
#define NVREC_CAP_INJECTOR              (1u << 4)   /* CPU command injector */
#define NVREC_CAP_SWQ                   (1u << 5)   /* IP software queue interface */
#define NVREC_CAP_DRY                   (1u << 6)   /* fabric-only runs (NVREC_START_DRY),
						     * register map >= 1.2 */
#define NVREC_CAP_SPLIT_RING            (1u << 7)   /* API 4: two ring ports (register map
						     * 1.3) AND a memory-1 region in the
						     * device tree: NVREC_RING_SPLIT and
						     * NVREC_RING_MEM1 rings (usable while
						     * memory 1 is ready: status) */

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
#define NVREC_STATUS_MEM1_DOWN          (1u << 1)   /* API 4: NVREC_CAP_SPLIT_RING, but
						     * memory 1 is not ready (STATE.
						     * MEM1_READY = 0: the PL DDR4
						     * controller did not calibrate): no
						     * split / MEM1 ring */

/* struct nvrec_ring.flags: the ring layout (API 4), one of */
#define NVREC_RING_SINGLE               (1u << 0)   /* one ring in memory 0 (as API 3) */
#define NVREC_RING_SPLIT                (1u << 1)   /* striped over memory 0 and 1 */
#define NVREC_RING_MEM1                 (1u << 2)   /* one ring in memory 1 (diagnostics) */
#define NVREC_RING_LAYOUT_MASK          (NVREC_RING_SINGLE | NVREC_RING_SPLIT | NVREC_RING_MEM1)
#define NVREC_STRIPE_SHIFT_MIN          12          /* 4 KB stripes */
#define NVREC_STRIPE_SHIFT_CHUNK        31          /* "one chunk": nvrec_info.stripe_shift
						     * when the default stripe is the whole
						     * chunk; accepted by SET_RING too */

/* nvrec_info.ring_default: the layout of a SET_RING with flags = 0 (the
 * driver's module parameter ring_split) for runs over 2 members and for
 * fabric-only runs [7:0], for runs over 1 member [15:8]. SET_RING itself
 * uses [7:0]; apps that know their member count pass the layout. */
#define NVREC_RING_DEFAULT(ring_default, members) \
	((__u32)(((members) == 1 ? (ring_default) >> 8 : (ring_default)) & 0xffu))

/* NVREC_IOC_GET_INFO */
struct nvrec_info {
	__u32 api_version;      /* NVREC_API_VERSION of the driver */
	__u32 hw_version;       /* nvrec_core VERSION: [31:16] major, [15:0] minor */
	__u64 src_clk_hz;       /* source clock (TPG, checker) */
	__u64 dp_clk_hz;        /* datapath clock (latency counters count it) */
	__u32 beat_bytes;       /* bytes per fabric beat: 16, 32 or 64 (BEAT_BYTES;
				 * 16 on register map 1.0/1.1) */
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
	__u32 egr_fifo_depth;   /* egress FIFO depth in beats (API 3) */
	__u32 ring_ports;       /* API 4: ring AXI4 masters (RING_PORTS): 1, or 2 =
				 * the hardware can split the ring */
	__u64 ring1_base;       /* API 4: memory-1 region for the ring (device
				 * tree memory-region), bus address; 0 = none */
	__u64 ring1_bytes;      /* API 4: its size (0 = no memory 1: single ring
				 * only); the memory-1 part of a ring must fit */
	__u32 ring_default;     /* API 4: NVREC_RING_DEFAULT() */
	__u32 stripe_shift;     /* API 4: the driver's default split-ring stripe,
				 * log2(bytes) (module parameter stripe_kb /
				 * device tree), used up to log2(chunk);
				 * NVREC_STRIPE_SHIFT_CHUNK = the whole chunk */
};

/*
 * NVREC_IOC_SET_RING. addr = 0: the driver allocates the memory-0 part from
 * CMA (physically contiguous; the cma= kernel argument must leave room).
 * addr != 0: a 2 MB aligned hugepage mapping of bytes, accepted only if
 * physically contiguous, for a single ring in memory 0 only. bytes:
 * multiple of 2 MB, the whole ring (both memories when split); chunk:
 * power of two in [NVREC_MIN_CHUNK, NVREC_MAX_CHUNK], at most every live
 * SSD's MDTS; slots = bytes / chunk in 2..max_slots. Only while idle;
 * bytes = 0 frees the ring.
 *
 * Layout (flags, API 4; 0 = the driver's default, NVREC_RING_DEFAULT()):
 *   SINGLE  bytes <= NVREC_RING_MAX_BYTES in memory 0 (as API 3)
 *   SPLIT   needs NVREC_CAP_SPLIT_RING and memory 1 ready. Ring byte g
 *           (g = slot * chunk + offset) is in stripe i = g >> S (S =
 *           stripe_shift, 12 .. log2(chunk); NVREC_STRIPE_SHIFT_CHUNK =
 *           log2(chunk)), stripe i in memory i & 1 at
 *           ((i >> 1) << S) + (g & (2^S - 1)) from that memory's base: S = 12
 *           alternates every 4 KB, S = log2(chunk) puts slot s in memory
 *           s & 1. Memory 0 (CMA) holds ceil(stripes / 2) stripes, memory 1
 *           (the start of the memory-1 region) the rest: an even slot count
 *           (or S < log2(chunk)) is exactly half each. bytes <=
 *           NVREC_RING_MAX_BYTES_SPLIT, each part <= NVREC_RING_MAX_BYTES,
 *           the memory-1 part <= nvrec_info.ring1_bytes.
 *   MEM1    the whole ring at the start of the memory-1 region (no CMA):
 *           bytes <= nvrec_info.ring1_bytes.
 * The PRP lists are always in memory 0 (CMA, 4 KB per slot; 8/16 KB for
 * 4 MB chunks).
 */
struct nvrec_ring {
	__u64 addr;             /* 0 = driver-allocated */
	__u64 bytes;
	__u32 chunk;            /* bytes per chunk = per NVMe command */
	__u32 flags;            /* in: NVREC_RING_SINGLE / SPLIT / MEM1, or 0 = the
				 * driver's default; out: the layout used */
	__u32 slots;            /* out: bytes / chunk */
	__u32 stripe_shift;     /* API 4. in: SPLIT stripe, log2(bytes) in
				 * 12..log2(chunk), NVREC_STRIPE_SHIFT_CHUNK =
				 * one chunk, 0 = the driver's default
				 * (nvrec_info.stripe_shift, at most log2(chunk));
				 * out: the stripe used, 0 unless SPLIT */
	__u64 dma_addr;         /* out: bus address of the memory-0 part
				 * (diagnostics), 0 for MEM1 */
	__u64 dma_addr1;        /* API 4. out: bus address of the memory-1 part
				 * (SPLIT, MEM1), else 0 */
	__u64 reserved[1];
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
 * nr_members = 0 (API 3): no SSD; such a geometry only starts DRY runs.
 */
#define NVREC_GEO_UNBOUNDED             (1u << 0)
#define NVREC_GEO_FUA                   (1u << 1)   /* FUA on every Write */

struct nvrec_geometry {
	__u32 nr_members;       /* 1 or 2 (0: DRY runs only) */
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
#define NVREC_START_DRY                 (1u << 2)   /* fabric only (CONFIG.DRY): no NVMe
						     * command; needs NVREC_CAP_DRY */

/* NVREC_IOC_RECORD_START / NVREC_IOC_PLAY_START */
struct nvrec_start {
	__u32 flags;            /* in: NVREC_START_* */
	__u32 reserved0;
	__u64 first_seq;        /* out: TPG sequence (16-byte word number) of the
				 * first word recorded (0 after reset) */
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
	__u64 seq_next;         /* TPG next sequence number (words) */
	__u32 fifo_hwm;         /* ingest FIFO high-water while the record run
				 * accepted data (RUN_FIFO_HWM), beats */
	__u32 fifo_depth;
	__u32 overflow;         /* ingest overflow (sticky) */
	__u32 cmd_errors;       /* recorder CQEs with status != 0 */
	__u64 chunks_filled;    /* chunks written into the ring */
	__u64 cmds_issued;      /* recorder SQEs accepted by the IP */
	__u64 cmds_done;        /* recorder CQEs received */
	__u64 chunks_released;  /* slots completed and released in order */
	__u64 bytes;            /* record: data bytes stored (no padding) = beats
				 * x beat_bytes; DRY: bytes written into the ring;
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
	__u64 chk_last_seq;     /* word 0 of the last good beat (words) */
	__u64 ing_drop_count;   /* ingest FIFO drops, sticky, counting on after
				 * the run (drop_count = RUN_DROP_COUNT) */
	__u32 flags;            /* NVREC_STATS_* */
	__u32 ing_fifo_hwm;     /* ING_FIFO_HWM: also counts the fill after the
				 * run when the source keeps running */
	__u64 prefill_ns;       /* playback with the checker: start -> sink
				 * enabled (ring prefill); elapsed_ns - prefill_ns
				 * is the streaming time */
	/* API 4 (register map 1.3), per ring port p = memory p, dp_clk cycles
	 * since START, saturating at 0xFFFFFFFF (17 s at 250 MHz); 0 before 1.3 */
	__u32 wr_port_stall[2]; /* record: the ring writer's head beat waited
				 * for port p (WR_PORT_STALL) */
	__u32 rd_port_wait[2];  /* playback: the ring reader waited for read
				 * data of port p with room in the egress FIFO
				 * (RD_PORT_WAIT) */
	__u64 reserved[3];
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
