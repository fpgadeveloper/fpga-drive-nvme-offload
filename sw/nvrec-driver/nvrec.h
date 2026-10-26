/* SPDX-License-Identifier: GPL-2.0-only OR MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec.h -- internal interfaces of the nvrec driver.
 *
 *   nvrec_main.c   platform driver ("opsero,nvrec"), /dev/nvrec, ring, sysfs
 *   nvrec_hw.c     the ONLY file touching nvrec_core and nvmeha registers
 *   nvrec_nvme.c   PCI driver for the SSDs: NVMe admin bring-up
 *   nvrec_blk.c    blk-mq block devices /dev/nvrecXn1
 */

#ifndef NVREC_H
#define NVREC_H

#include <linux/types.h>
#include <linux/device.h>
#include <linux/pci.h>
#include <linux/blk-mq.h>
#include <linux/miscdevice.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/io.h>

#include "nvrec_uapi.h"

#define NVREC_DRV_VERSION	"1.2"

/* ------------------------------------------------------------------------ */
/* NVMe definitions (NVM Express Base Specification 2.0; only what we use)  */

#define NVME_REG_CAP		0x0000
#define NVME_REG_VS		0x0008
#define NVME_REG_INTMS		0x000c
#define NVME_REG_CC		0x0014
#define NVME_REG_CSTS		0x001c
#define NVME_REG_AQA		0x0024
#define NVME_REG_ASQ		0x0028
#define NVME_REG_ACQ		0x0030
#define NVME_REG_DBS		0x1000

#define NVME_CAP_MQES(cap)	((cap) & 0xffff)
#define NVME_CAP_TIMEOUT(cap)	(((cap) >> 24) & 0xff)	/* 500 ms units */
#define NVME_CAP_STRIDE(cap)	(((cap) >> 32) & 0xf)
#define NVME_CAP_NSSRC(cap)	(((cap) >> 36) & 0x1)
#define NVME_CAP_CSS_NVM(cap)	(((cap) >> 37) & 0x1)
#define NVME_CAP_MPSMIN(cap)	(((cap) >> 48) & 0xf)

#define NVME_CC_ENABLE		(1u << 0)
#define NVME_CC_CSS_NVM		(0u << 4)
#define NVME_CC_MPS_4K		(0u << 7)
#define NVME_CC_AMS_RR		(0u << 11)
#define NVME_CC_SHN_NORMAL	(1u << 14)
#define NVME_CC_SHN_MASK	(3u << 14)
#define NVME_CC_IOSQES		(6u << 16)
#define NVME_CC_IOCQES		(4u << 20)
#define NVME_CSTS_RDY		(1u << 0)
#define NVME_CSTS_CFS		(1u << 1)
#define NVME_CSTS_SHST_MASK	(3u << 2)
#define NVME_CSTS_SHST_CMPLT	(2u << 2)

/* admin opcodes */
#define NVME_ADM_DELETE_SQ	0x00
#define NVME_ADM_CREATE_SQ	0x01
#define NVME_ADM_GET_LOG_PAGE	0x02
#define NVME_ADM_DELETE_CQ	0x04
#define NVME_ADM_CREATE_CQ	0x05
#define NVME_ADM_IDENTIFY	0x06
#define NVME_ADM_SET_FEATURES	0x09
#define NVME_ADM_GET_FEATURES	0x0a
/* NVM opcodes */
#define NVME_CMD_FLUSH		0x00
#define NVME_CMD_WRITE		0x01
#define NVME_CMD_READ		0x02
#define NVME_CMD_DSM		0x09

#define NVME_FEAT_NUM_QUEUES	0x07
#define NVME_FEAT_APST		0x0c	/* Autonomous Power State Transition */
#define NVME_APST_TABLE_BYTES	256	/* 32 entries x 8 bytes */
#define NVME_LOG_SMART		0x02	/* SMART / Health Information, 512 bytes */
#define NVME_NSID_ALL		0xffffffffu
#define NVME_ID_CNS_NS		0x00
#define NVME_ID_CNS_CTRL	0x01

#define NVME_RW_FUA		(1u << 30)	/* CDW12 */
#define NVME_DSM_AD		(1u << 2)	/* CDW11 */

/* CQE status (DW3[31:17]) */
#define NVME_CQE_STATUS(dw3)	(((dw3) >> 17) & 0x7fff)
#define NVME_CQE_PHASE(dw3)	((dw3) & 0x10000)
#define NVME_SC_DNR		0x4000	/* in the 15-bit status: bit 14 */

struct nvme_sqe {
	__le32 cdw0;		/* opcode [7:0], fuse, psdt, CID [31:16] */
	__le32 nsid;
	__le32 cdw2;
	__le32 cdw3;
	__le64 mptr;
	__le64 prp1;
	__le64 prp2;
	__le32 cdw10;
	__le32 cdw11;
	__le32 cdw12;
	__le32 cdw13;
	__le32 cdw14;
	__le32 cdw15;
};

struct nvme_cqe {
	__le32 dw0;		/* command specific */
	__le32 dw1;
	__le16 sq_head;
	__le16 sq_id;
	__le16 cid;
	__le16 status;		/* [0] phase, [15:1] status */
};

static inline void nvme_sqe_set(struct nvme_sqe *s, u8 opcode, u16 cid)
{
	memset(s, 0, sizeof(*s));
	s->cdw0 = cpu_to_le32(opcode | ((u32)cid << 16));
}

/* ------------------------------------------------------------------------ */

struct nvrec_dev;

/* Static configuration of the nvmeha instance (nvrec_regs.h + device tree) */
struct nvrec_ha_cfg {
	u32 nr_ssd;		/* C_MAX_SSD */
	u32 max_sq;		/* C_MAX_SQ: queue slots per SSD */
	u32 nsw[NVREC_MAX_SSD];	/* software SQs per SSD (ids 1..nsw) */
	u32 nhw[NVREC_MAX_SSD];	/* hardware SQs per SSD (ids nsw+1..) */
	u32 sq_depth;		/* C_SQ_DEPTH_SW = C_SQ_DEPTH_HW */
	u64 sq_base;		/* SSD0 SQ1 as the SSD sees it (PCIe address) */
	u64 cq_base;		/* SSD0 CQ1 */
	s64 bar_offset;		/* IP's view of an SSD BAR = CPU phys + offset */
	u32 inj_depth;		/* injector commands in flight per SSD */
	u32 max_slots;		/* MAX_SLOTS register */
	/* memory 1 of the split ring (register map 1.3): the device tree's
	 * memory-region (a no-map carve-out the CPU never uses) */
	phys_addr_t ring1_phys;
	u64 ring1_size;		/* 0 = no region */
	u32 stripe_kb;		/* opsero,ring-stripe-kb: the board's default
				 * stripe (0 = none given) */
	bool stripe_chunk;	/* opsero,ring-stripe-chunk: the board's default
				 * stripe is the whole chunk (wins over stripe_kb) */
};

/* One SSD = one PCIe device behind one of our root ports */
struct nvrec_ssd {
	struct nvrec_dev *nv;
	struct pci_dev *pdev;
	unsigned int index;		/* SSD index in the IP */
	u32 state;			/* NVREC_SSD_* */
	void __iomem *bar;
	u64 cap;
	u32 db_stride;			/* bytes */
	unsigned long timeout_ms;	/* CAP.TO */

	/* admin queue (DDR, coherent) */
	struct mutex admin_lock;
	struct nvme_sqe *asq;
	struct nvme_cqe *acq;
	dma_addr_t asq_dma, acq_dma;
	u16 aq_depth;
	u16 asq_tail;
	u16 acq_head;
	u16 acq_phase;
	u16 admin_cid;
	void *idbuf;			/* 4 KB identify buffer */
	dma_addr_t idbuf_dma;

	/* identify results */
	char model[41];
	char serial[21];
	char firmware[9];
	u32 mdts_bytes;			/* 0 = unlimited */
	u32 nn;				/* number of namespaces */
	u32 nsid;
	u32 lba_shift;
	u64 nlba;
	bool vwc;
	bool dsm;
	bool apsta;			/* APST supported (Identify APSTA) */
	u16 wctemp_k, cctemp_k;		/* warning / critical composite temperature, K */

	/* SMART log + feature data (DMA-coherent, 4 KB), under log_lock */
	struct mutex log_lock;
	void *logbuf;
	dma_addr_t logbuf_dma;
	int temp_c;			/* last composite temperature read */
	unsigned long temp_jiffies;	/* when (0 = never) */

	/* I/O queues */
	u32 nr_io_queues;		/* granted by Set Features */
	u32 sw_queues, hw_queues;	/* created */
	u32 io_path;			/* NVREC_PATH_* */
	bool dead;			/* controller disabled after a failure */

	/* block device */
	struct blk_mq_tag_set tagset;
	bool tagset_ok;
	struct gendisk *disk;
	char disk_name[32];
	atomic_t inflight;
	spinlock_t inj_lock;
};

/* nvrec_core + nvmeha + the recorder session */
struct nvrec_dev {
	struct device *dev;
	void __iomem *core;		/* nvrec_core registers */
	void __iomem *ha;		/* nvmeha S_AXI_LITE */
	int irq_core;
	int irq_ha;
	struct nvrec_ha_cfg cfg;
	struct device_node *port_np[NVREC_MAX_SSD];	/* root port per SSD index */
	spinlock_t reg_lock;		/* 64-bit LO/HI counter pairs */
	spinlock_t inj_lock;		/* injector registers */

	u32 hw_version;
	unsigned long ha_flags;		/* NVREC_HA_DEAD_BIT */
	struct work_struct ha_dead_work;	/* disable the SSDs once the IP is dead */
	u32 src_clk_hz;
	u32 dp_clk_hz;
	u32 beat_bytes;			/* bytes per fabric beat: BEAT_BYTES (1.2), 16 before */
	u32 fifo_depth;			/* ingest FIFO, beats */
	u32 egr_fifo_depth;		/* egress FIFO, beats */
	u32 ring_ports;			/* RING_PORTS (1.3), 1 before */
	dma_addr_t ring1_dma;		/* memory-1 region as the fabric sees it */
	u32 caps;

	struct mutex ssd_lock;		/* ssd[] attach/detach */
	struct nvrec_ssd *ssd[NVREC_MAX_SSD];

	struct list_head node_list;	/* nvrec_list */
	int id;
	char name[16];

	/* /dev/nvrec session */
	struct miscdevice misc;
	struct mutex lock;		/* session: open, ring, geometry, start/stop */
	bool in_use;
	u32 state;			/* NVREC_STATE_* */
	wait_queue_head_t wq;
	u64 start_ns;			/* ktime at start */
	bool run_dry;			/* the current/last run is fabric-only (CONFIG.DRY) */
	u64 stop_ns;
	u64 prefill_ns;			/* playback: start -> sink enabled */
	struct nvrec_stats final;	/* snapshot at STOP/ABORT/DONE */
	bool final_valid;

	/* ring: one physically contiguous region per memory (nvrec_main.c) */
	bool ring_ours;			/* allocated by the driver (CMA) */
	void *ring_cookie;		/* dma_alloc_attrs() cookie */
	struct page **pages;		/* user ring: pinned pages */
	unsigned long npages;
	struct sg_table sgt;
	bool sgt_mapped;
	dma_addr_t ring_dma;		/* memory-0 part (0 for MEM1) */
	u64 ring_bytes;			/* memory-0 allocation (CMA / user) */
	u32 ring_layout;		/* NVREC_RING_SINGLE / SPLIT / MEM1, 0 = no ring */
	u32 stripe_shift;		/* SPLIT: log2 of the stripe, else 0 */
	u64 ring1_used;			/* bytes of memory 1 the ring uses */
	bool ring_ssd_ok;		/* fabric and SSD views of the ring were checked
					 * equal (a live SSD at SET_RING); else DRY only */
	u32 chunk;
	u32 slots;
	void *prp_lists;		/* coherent: one list (1 << prp_shift) per slot */
	dma_addr_t prp_lists_dma;
	size_t prp_lists_bytes;
	u32 prp_shift;

	/* geometry */
	struct nvrec_geometry geo;
	bool geo_valid;
};

/* ---- nvrec_hw.c --------------------------------------------------------- */
#define NVREC_HA_DEAD_BIT	0

/* The Host Accelerator stopped answering (evaluation license expired); known
 * without touching the IP. nvrec_hw_ha_dead() also asks nvrec_core. */
static inline bool nvrec_ha_is_dead(struct nvrec_dev *nv)
{
	return test_bit(NVREC_HA_DEAD_BIT, &nv->ha_flags);
}
bool nvrec_hw_ha_dead(struct nvrec_dev *nv);
void nvrec_hw_mark_ha_dead(struct nvrec_dev *nv);
bool nvrec_hw_mem1_ready(struct nvrec_dev *nv);	/* STATE.MEM1_READY (1.3, 2 ports) */

int nvrec_hw_probe(struct nvrec_dev *nv);	/* map, read IDs, config, reset */
void nvrec_hw_remove(struct nvrec_dev *nv);
int nvrec_hw_ha_init(struct nvrec_dev *nv);	/* queue window, IRQs */
u64 nvrec_hw_sq_addr(struct nvrec_dev *nv, unsigned int ssd, unsigned int q);
u64 nvrec_hw_cq_addr(struct nvrec_dev *nv, unsigned int ssd, unsigned int q);
void nvrec_hw_ssd_attach(struct nvrec_dev *nv, unsigned int ssd, u64 bar_cpu);
void nvrec_hw_credit_reset(struct nvrec_dev *nv, unsigned int ssd);
void nvrec_hw_ssd_flush(struct nvrec_dev *nv, unsigned int ssd);
int nvrec_hw_inj_submit(struct nvrec_dev *nv, unsigned int ssd,
			const struct nvme_sqe *sqe);
u16 nvrec_hw_inj_cid(u16 tag);
u32 nvrec_hw_ha_counter(struct nvrec_dev *nv, unsigned int ssd, int which);

/* recorder datapath */
u64 nvrec_hw_rate_get(struct nvrec_dev *nv);
u64 nvrec_hw_rate_set(struct nvrec_dev *nv, u64 rate_bps);
u64 nvrec_hw_sink_rate_set(struct nvrec_dev *nv, u64 rate_bps);
void nvrec_hw_tpg_enable(struct nvrec_dev *nv, bool on);
bool nvrec_hw_tpg_enabled(struct nvrec_dev *nv);
int nvrec_hw_soft_reset(struct nvrec_dev *nv);
int nvrec_hw_start(struct nvrec_dev *nv, bool play, u32 flags);	/* NVREC_START_* */
int nvrec_hw_stop(struct nvrec_dev *nv, bool abort);
bool nvrec_hw_finished(struct nvrec_dev *nv);	/* DONE / ABORTED / IDLE */
bool nvrec_hw_aborted(struct nvrec_dev *nv);
void nvrec_hw_read_stats(struct nvrec_dev *nv, struct nvrec_stats *st);
u64 nvrec_hw_seq_next(struct nvrec_dev *nv);
u32 nvrec_hw_lat_bin0_log2(void);
u32 nvrec_hw_max_qd(void);

/* ---- nvrec_nvme.c ------------------------------------------------------- */
int nvrec_nvme_register(void);
void nvrec_nvme_unregister(void);
void nvrec_nvme_kill(struct nvrec_ssd *s, const char *why);
int nvrec_nvme_temperature(struct nvrec_ssd *s, int *temp_c);	/* SMART, cached 1 s */
int nvrec_nvme_apst_get(struct nvrec_ssd *s, bool *enabled);	/* -EOPNOTSUPP: no APST */
/* platform side: SSD lookup by PCI device */
struct nvrec_dev *nvrec_find_for_pci(struct pci_dev *pdev, unsigned int *index);
void nvrec_ssd_detach_all(struct nvrec_dev *nv);

/* ---- nvrec_blk.c -------------------------------------------------------- */
int nvrec_blk_add(struct nvrec_ssd *s);
void nvrec_blk_remove(struct nvrec_ssd *s);
void nvrec_blk_complete(struct nvrec_ssd *s, const struct nvme_cqe *cqe);
void nvrec_blk_fail_all(struct nvrec_ssd *s);

/* ---- nvrec_main.c ------------------------------------------------------- */
void nvrec_run_event(struct nvrec_dev *nv);	/* core IRQ: run done/error */
void nvrec_ha_dead_work(struct work_struct *work);
void nvrec_session_ssd_gone(struct nvrec_dev *nv, unsigned int index);

#endif /* NVREC_H */
