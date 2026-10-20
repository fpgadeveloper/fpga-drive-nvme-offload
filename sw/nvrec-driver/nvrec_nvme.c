// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * nvrec_nvme.c -- PCI driver for the NVMe SSDs behind the design's root
 * ports: controller bring-up and the admin queue.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Why not the stock nvme driver: an NVMe controller has one owner. Whoever
 * enables it creates the admin queue, negotiates the number of I/O queues
 * and creates them -- and resets the controller whenever it decides to,
 * which deletes every I/O queue. The NVMe Host Accelerator needs I/O queues
 * whose memory is ITS queue window, so this driver owns the controller and
 * gives Linux a block device through the IP instead (nvrec_blk.c).
 *
 * Bring-up (NVMe Base Specification 2.0, section 3.5.1):
 *   1. CC.EN = 0, wait CSTS.RDY = 0
 *   2. admin SQ/CQ in DDR (DMA-coherent), AQA/ASQ/ACQ
 *   3. CC = EN | NVM command set | 4 KB pages | IOSQES 6 | IOCQES 4,
 *      wait CSTS.RDY = 1
 *   4. Identify Controller (MDTS, VWC, ONCS, model/serial/firmware)
 *   5. Identify Namespace 1 (size, LBA format in use; metadata unsupported)
 *   6. Set Features Number of Queues: the queues the IP holds for this SSD
 *   7. program the SSD's BAR into the IP (doorbells), then for each IP queue
 *      q (software queues first, PG328): Create I/O CQ (qid q+1, physically
 *      contiguous, interrupts OFF: the IP watches its own CQ memory) and
 *      Create I/O SQ (qid q+1, CQID q+1), both at the IP's queue window.
 *
 * The admin queue is polled (admin commands are rare: bring-up, teardown),
 * so no MSI/INTx vector of the root port is used by this driver at all.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/of.h>
#include <linux/delay.h>
#include <linux/io-64-nonatomic-lo-hi.h>
#include <linux/dma-mapping.h>
#include <linux/sched/signal.h>
#include <linux/unaligned.h>

#include "nvrec.h"

#define NVREC_AQ_DEPTH		32
#define NVREC_ADMIN_TIMEOUT_MS	5000

static unsigned int admin_timeout_ms = NVREC_ADMIN_TIMEOUT_MS;
module_param(admin_timeout_ms, uint, 0644);
MODULE_PARM_DESC(admin_timeout_ms, "admin command timeout (ms)");

static inline u32 bar_rd(struct nvrec_ssd *s, u32 off)
{
	return readl(s->bar + off);
}

static inline void bar_wr(struct nvrec_ssd *s, u32 off, u32 v)
{
	writel(v, s->bar + off);
}

static int nvrec_wait_ready(struct nvrec_ssd *s, bool ready)
{
	unsigned long end = jiffies + msecs_to_jiffies(s->timeout_ms);
	u32 csts;

	for (;;) {
		csts = bar_rd(s, NVME_REG_CSTS);
		if (csts == ~0u)
			return -ENODEV;		/* link down / surprise removal */
		if (!!(csts & NVME_CSTS_RDY) == ready)
			return 0;
		if (ready && (csts & NVME_CSTS_CFS))
			return -EIO;
		if (time_after(jiffies, end))
			return -ETIMEDOUT;
		usleep_range(1000, 2000);
	}
}

static int nvrec_disable(struct nvrec_ssd *s)
{
	u32 cc = bar_rd(s, NVME_REG_CC);

	if (!(cc & NVME_CC_ENABLE) && !(bar_rd(s, NVME_REG_CSTS) & NVME_CSTS_RDY))
		return 0;
	if (cc & NVME_CC_ENABLE) {
		/* CC.EN 1->0 while RDY is still 0 is undefined: wait first */
		nvrec_wait_ready(s, true);
		bar_wr(s, NVME_REG_CC, cc & ~NVME_CC_ENABLE);
	}
	return nvrec_wait_ready(s, false);
}

/* Normal shutdown notification: the SSD commits its write cache */
static void nvrec_shutdown_ctrl(struct nvrec_ssd *s)
{
	unsigned long end = jiffies + msecs_to_jiffies(max(s->timeout_ms, 5000ul));
	u32 cc = bar_rd(s, NVME_REG_CC);

	if (!(cc & NVME_CC_ENABLE))
		return;
	bar_wr(s, NVME_REG_CC, (cc & ~NVME_CC_SHN_MASK) | NVME_CC_SHN_NORMAL);
	while ((bar_rd(s, NVME_REG_CSTS) & NVME_CSTS_SHST_MASK) != NVME_CSTS_SHST_CMPLT) {
		if (time_after(jiffies, end)) {
			dev_warn(&s->pdev->dev, "shutdown notification timed out\n");
			break;
		}
		msleep(10);
	}
}

/* ------------------------------------------------------------------------ */
/* Admin queue (polled)                                                     */

static int nvrec_admin(struct nvrec_ssd *s, struct nvme_sqe *sqe, u32 *result)
{
	unsigned long end;
	struct nvme_cqe cqe;
	u16 cid, st;
	int ret = 0;

	mutex_lock(&s->admin_lock);
	if (s->dead) {
		ret = -ENODEV;
		goto out;
	}
	cid = s->admin_cid++;
	sqe->cdw0 = cpu_to_le32((le32_to_cpu(sqe->cdw0) & 0xffff) | ((u32)cid << 16));
	memcpy(&s->asq[s->asq_tail], sqe, sizeof(*sqe));
	s->asq_tail = (s->asq_tail + 1) % s->aq_depth;
	wmb();		/* SQE in memory before the doorbell */
	bar_wr(s, NVME_REG_DBS, s->asq_tail);

	end = jiffies + msecs_to_jiffies(admin_timeout_ms);
	for (;;) {
		u16 status = le16_to_cpu(READ_ONCE(s->acq[s->acq_head].status));

		if ((status & 1) == s->acq_phase)
			break;
		if (time_after(jiffies, end)) {
			dev_err(&s->pdev->dev, "admin command 0x%02x (cid %u) timed out\n",
				le32_to_cpu(sqe->cdw0) & 0xff, cid);
			ret = -ETIMEDOUT;
			goto out;
		}
		usleep_range(20, 100);
	}
	dma_rmb();	/* rest of the CQE after the phase bit */
	cqe = s->acq[s->acq_head];
	if (++s->acq_head == s->aq_depth) {
		s->acq_head = 0;
		s->acq_phase ^= 1;
	}
	bar_wr(s, NVME_REG_DBS + s->db_stride, s->acq_head);

	st = le16_to_cpu(cqe.status) >> 1;
	if (le16_to_cpu(cqe.cid) != cid)
		dev_warn(&s->pdev->dev, "admin completion cid %u, expected %u\n",
			 le16_to_cpu(cqe.cid), cid);
	if (st) {
		dev_err(&s->pdev->dev, "admin command 0x%02x failed: status 0x%04x (SCT %u SC 0x%02x)\n",
			le32_to_cpu(sqe->cdw0) & 0xff, st, (st >> 8) & 7, st & 0xff);
		ret = -EIO;
	}
	if (result)
		*result = le32_to_cpu(cqe.dw0);
out:
	mutex_unlock(&s->admin_lock);
	return ret;
}

static int nvrec_identify(struct nvrec_ssd *s, u32 cns, u32 nsid)
{
	struct nvme_sqe c;

	nvme_sqe_set(&c, NVME_ADM_IDENTIFY, 0);
	c.nsid = cpu_to_le32(nsid);
	c.prp1 = cpu_to_le64(s->idbuf_dma);
	c.cdw10 = cpu_to_le32(cns);
	memset(s->idbuf, 0, SZ_4K);
	return nvrec_admin(s, &c, NULL);
}

static void copy_trim(char *dst, const u8 *src, size_t n)
{
	memcpy(dst, src, n);
	dst[n] = 0;
	while (n && (dst[n - 1] == ' ' || dst[n - 1] == 0))
		dst[--n] = 0;
}

static int nvrec_identify_all(struct nvrec_ssd *s)
{
	const u8 *id = s->idbuf;
	u32 flbas, lbaf;
	u8 mdts;
	int ret;

	ret = nvrec_identify(s, NVME_ID_CNS_CTRL, 0);
	if (ret)
		return ret;
	copy_trim(s->serial, id + 4, 20);
	copy_trim(s->model, id + 24, 40);
	copy_trim(s->firmware, id + 64, 8);
	mdts = id[77];
	/* MDTS is in units of the minimum page size (CAP.MPSMIN, 4 KB here) */
	s->mdts_bytes = (mdts && mdts < 20) ? (4096u << mdts) : 0;
	if ((id[512] & 0xf) > 6 || (id[513] & 0xf) > 4) {
		dev_err(&s->pdev->dev, "controller requires SQE/CQE sizes 2^%u/2^%u\n",
			id[512] & 0xf, id[513] & 0xf);
		return -EINVAL;
	}
	s->nn = get_unaligned_le32(id + 516);
	s->dsm = get_unaligned_le16(id + 520) & (1u << 2);
	s->vwc = id[525] & 1;
	if (!s->nn) {
		dev_err(&s->pdev->dev, "controller has no namespace\n");
		return -ENODEV;
	}

	s->nsid = 1;
	ret = nvrec_identify(s, NVME_ID_CNS_NS, s->nsid);
	if (ret)
		return ret;
	s->nlba = get_unaligned_le64(id + 0);
	flbas = id[26] & 0xf;
	lbaf = get_unaligned_le32(id + 128 + 4 * flbas);
	s->lba_shift = (lbaf >> 16) & 0xff;
	if (!s->nlba) {
		dev_err(&s->pdev->dev, "namespace 1 is not active\n");
		return -ENODEV;
	}
	if (lbaf & 0xffff) {
		dev_err(&s->pdev->dev, "namespace 1 uses %u bytes of metadata per LBA: not supported (reformat it without metadata)\n",
			lbaf & 0xffff);
		return -EINVAL;
	}
	if (s->lba_shift < 9 || s->lba_shift > 12) {
		dev_err(&s->pdev->dev, "LBA size 2^%u not supported\n", s->lba_shift);
		return -EINVAL;
	}
	return 0;
}

static int nvrec_set_num_queues(struct nvrec_ssd *s, u32 want, u32 *granted)
{
	struct nvme_sqe c;
	u32 res;
	int ret;

	nvme_sqe_set(&c, NVME_ADM_SET_FEATURES, 0);
	c.cdw10 = cpu_to_le32(NVME_FEAT_NUM_QUEUES);
	c.cdw11 = cpu_to_le32((want - 1) | ((want - 1) << 16));
	ret = nvrec_admin(s, &c, &res);
	if (ret == -EIO) {
		/* Some controllers refuse a second Set Features NQ after a
		 * previous owner (or a previous load of this driver) already
		 * set it: ask what is in effect instead. */
		nvme_sqe_set(&c, NVME_ADM_GET_FEATURES, 0);
		c.cdw10 = cpu_to_le32(NVME_FEAT_NUM_QUEUES);
		ret = nvrec_admin(s, &c, &res);
	}
	if (ret)
		return ret;
	*granted = min((res & 0xffff) + 1, (res >> 16) + 1);
	return 0;
}

static int nvrec_create_queue_pair(struct nvrec_ssd *s, unsigned int q)
{
	struct nvrec_dev *nv = s->nv;
	u32 depth = nv->cfg.sq_depth;
	u64 sq = nvrec_hw_sq_addr(nv, s->index, q);
	u64 cq = nvrec_hw_cq_addr(nv, s->index, q);
	u16 qid = q + 1;
	struct nvme_sqe c;
	int ret;

	if (depth > NVME_CAP_MQES(s->cap) + 1) {
		dev_err(&s->pdev->dev, "queue depth %u exceeds the controller's MQES %llu\n",
			depth, NVME_CAP_MQES(s->cap) + 1);
		return -EINVAL;
	}

	nvme_sqe_set(&c, NVME_ADM_CREATE_CQ, 0);
	c.prp1 = cpu_to_le64(cq);
	c.cdw10 = cpu_to_le32(((depth - 1) << 16) | qid);
	c.cdw11 = cpu_to_le32(1);		/* PC = 1, IEN = 0 */
	ret = nvrec_admin(s, &c, NULL);
	if (ret)
		return ret;

	nvme_sqe_set(&c, NVME_ADM_CREATE_SQ, 0);
	c.prp1 = cpu_to_le64(sq);
	c.cdw10 = cpu_to_le32(((depth - 1) << 16) | qid);
	c.cdw11 = cpu_to_le32(((u32)qid << 16) | 1);	/* CQID, PC = 1, urgent prio 0 */
	ret = nvrec_admin(s, &c, NULL);
	if (ret) {
		nvme_sqe_set(&c, NVME_ADM_DELETE_CQ, 0);
		c.cdw10 = cpu_to_le32(qid);
		nvrec_admin(s, &c, NULL);
		return ret;
	}
	dev_dbg(&s->pdev->dev, "qid %u (%s): SQ 0x%llx CQ 0x%llx depth %u\n", qid,
		q < nv->cfg.nsw[s->index] ? "software" : "hardware", sq, cq, depth);
	return 0;
}

static void nvrec_delete_queues(struct nvrec_ssd *s)
{
	unsigned int n = s->sw_queues + s->hw_queues, q;
	struct nvme_sqe c;

	for (q = n; q-- > 0;) {
		nvme_sqe_set(&c, NVME_ADM_DELETE_SQ, 0);
		c.cdw10 = cpu_to_le32(q + 1);
		nvrec_admin(s, &c, NULL);
		nvme_sqe_set(&c, NVME_ADM_DELETE_CQ, 0);
		c.cdw10 = cpu_to_le32(q + 1);
		nvrec_admin(s, &c, NULL);
	}
	s->sw_queues = s->hw_queues = 0;
}

static int nvrec_ctrl_init(struct nvrec_ssd *s)
{
	struct device *dev = &s->pdev->dev;
	struct nvrec_dev *nv = s->nv;
	unsigned int nsw = nv->cfg.nsw[s->index], nhw = nv->cfg.nhw[s->index];
	unsigned int q;
	u32 need = nsw + nhw;
	int ret;

	s->cap = lo_hi_readq(s->bar + NVME_REG_CAP);
	if (s->cap == ~0ull)
		return -ENODEV;
	s->db_stride = 4u << NVME_CAP_STRIDE(s->cap);
	s->timeout_ms = max_t(unsigned long, NVME_CAP_TIMEOUT(s->cap), 1) * 500;
	if (NVME_CAP_STRIDE(s->cap)) {
		dev_err(dev, "doorbell stride %u bytes: the NVMe Host Accelerator assumes 4\n",
			s->db_stride);
		return -EINVAL;
	}
	/* The IP's doorbell master (M_AXI_SSD) has 32 address bits: a BAR0
	 * placed at or above 4 GB (e.g. a prefetchable BAR in the 64-bit
	 * window of the Versal root port) can never receive its doorbells */
	if ((u64)pci_resource_start(s->pdev, 0) + s->nv->cfg.bar_offset > U32_MAX - 0x1FFFull ||
	    (u64)pci_bus_address(s->pdev, 0) > U32_MAX - 0x1FFFull) {
		dev_err(dev, "BAR0 at %pa (bus 0x%llx) is at or above 4 GB: the NVMe Host Accelerator's doorbell master has 32 address bits; the root port must place BAR0 below 4 GB\n",
			&s->pdev->resource[0].start, (u64)pci_bus_address(s->pdev, 0));
		return -EINVAL;
	}
	if (NVME_CAP_MPSMIN(s->cap)) {
		dev_err(dev, "controller minimum page size %u KB > 4 KB\n",
			4u << NVME_CAP_MPSMIN(s->cap));
		return -EINVAL;
	}
	if (!NVME_CAP_CSS_NVM(s->cap)) {
		dev_err(dev, "controller does not support the NVM command set\n");
		return -EINVAL;
	}

	ret = nvrec_disable(s);
	if (ret) {
		dev_err(dev, "controller did not reset (CSTS 0x%08x): %d\n",
			bar_rd(s, NVME_REG_CSTS), ret);
		return ret;
	}

	s->aq_depth = min_t(u32, NVREC_AQ_DEPTH, NVME_CAP_MQES(s->cap) + 1);
	s->asq_tail = s->acq_head = 0;
	s->acq_phase = 1;
	memset(s->asq, 0, NVREC_AQ_DEPTH * sizeof(*s->asq));
	memset(s->acq, 0, NVREC_AQ_DEPTH * sizeof(*s->acq));
	bar_wr(s, NVME_REG_INTMS, ~0u);		/* polled admin: no interrupts */
	bar_wr(s, NVME_REG_AQA, (s->aq_depth - 1) | ((s->aq_depth - 1) << 16));
	lo_hi_writeq(s->asq_dma, s->bar + NVME_REG_ASQ);
	lo_hi_writeq(s->acq_dma, s->bar + NVME_REG_ACQ);
	bar_wr(s, NVME_REG_CC, NVME_CC_CSS_NVM | NVME_CC_MPS_4K | NVME_CC_AMS_RR |
	       NVME_CC_IOSQES | NVME_CC_IOCQES);
	bar_wr(s, NVME_REG_CC, NVME_CC_CSS_NVM | NVME_CC_MPS_4K | NVME_CC_AMS_RR |
	       NVME_CC_IOSQES | NVME_CC_IOCQES | NVME_CC_ENABLE);
	ret = nvrec_wait_ready(s, true);
	if (ret) {
		dev_err(dev, "controller did not become ready (CSTS 0x%08x): %d\n",
			bar_rd(s, NVME_REG_CSTS), ret);
		return ret;
	}

	ret = nvrec_identify_all(s);
	if (ret)
		return ret;

	ret = nvrec_set_num_queues(s, need, &s->nr_io_queues);
	if (ret)
		return ret;
	if (s->nr_io_queues < need) {
		dev_err(dev, "%s grants %u I/O queue(s); the design's NVMe Host Accelerator needs %u for SSD%u (%u software + %u hardware). Rebuild the IP with C_NUM_SQ_SW = 0 for this SSD: the block device then uses the CPU command injector on the hardware queue.\n",
			s->model, s->nr_io_queues, need, s->index, nsw, nhw);
		return -ENOSPC;
	}

	/* Doorbells: the IP rings them at BAR0 + 0x1000 + ... of this SSD */
	nvrec_hw_ssd_attach(nv, s->index, pci_resource_start(s->pdev, 0));

	for (q = 0; q < need; q++) {
		ret = nvrec_create_queue_pair(s, q);
		if (ret) {
			dev_err(dev, "Create I/O queue pair %u failed: %d\n", q + 1, ret);
			nvrec_delete_queues(s);
			return ret;
		}
		if (q < nsw)
			s->sw_queues++;
		else
			s->hw_queues++;
	}
	/* nvrec_core's credit counter of THIS SSD mirrors its fresh hardware
	 * queue: reload it (CTRL per-SSD credit reset, the other SSD's
	 * counters and in-flight commands are untouched). */
	nvrec_hw_credit_reset(nv, s->index);
	s->io_path = s->sw_queues ? NVREC_PATH_SWQ : NVREC_PATH_INJECTOR;
	return 0;
}

/* Fatal controller error: stop all DMA, fail outstanding block I/O */
void nvrec_nvme_kill(struct nvrec_ssd *s, const char *why)
{
	if (s->dead)
		return;
	dev_err(&s->pdev->dev, "disabling controller: %s\n", why);
	s->dead = true;
	s->state = NVREC_SSD_FAILED;
	/* With the Host Accelerator dead the SSD's writes into the IP's queue
	 * window may be stuck in the root port; a BAR read could then wait
	 * behind them (PCIe ordering). Disable the controller write-only. */
	if (nvrec_ha_is_dead(s->nv))
		bar_wr(s, NVME_REG_CC, NVME_CC_CSS_NVM | NVME_CC_MPS_4K | NVME_CC_AMS_RR |
		       NVME_CC_IOSQES | NVME_CC_IOCQES);
	else
		bar_wr(s, NVME_REG_CC, bar_rd(s, NVME_REG_CC) & ~NVME_CC_ENABLE);
	nvrec_hw_ssd_flush(s->nv, s->index);
	nvrec_blk_fail_all(s);
}

/* ------------------------------------------------------------------------ */
/* PCI driver                                                               */

static void nvrec_ssd_free(struct nvrec_ssd *s)
{
	struct device *dev = &s->pdev->dev;

	if (s->idbuf)
		dma_free_coherent(dev, SZ_4K, s->idbuf, s->idbuf_dma);
	if (s->asq)
		dma_free_coherent(dev, NVREC_AQ_DEPTH * sizeof(*s->asq), s->asq, s->asq_dma);
	if (s->acq)
		dma_free_coherent(dev, NVREC_AQ_DEPTH * sizeof(*s->acq), s->acq, s->acq_dma);
	kfree(s);
}

static int nvrec_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct device *dev = &pdev->dev;
	struct nvrec_ssd *s;
	struct nvrec_dev *nv;
	unsigned int index;
	int ret;

	nv = nvrec_find_for_pci(pdev, &index);
	if (IS_ERR(nv))
		return PTR_ERR(nv);
	if (nvrec_hw_ha_dead(nv)) {
		dev_err(dev, "not bringing the SSD up: the Host Accelerator is not responding (evaluation license expired?)\n");
		return -ENOLINK;
	}

	s = kzalloc(sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;
	s->nv = nv;
	s->pdev = pdev;
	s->index = index;
	s->state = NVREC_SSD_FAILED;
	mutex_init(&s->admin_lock);
	spin_lock_init(&s->inj_lock);
	atomic_set(&s->inflight, 0);
	snprintf(s->disk_name, sizeof(s->disk_name), NVREC_DISK_PREFIX "%un1", index);

	ret = pcim_enable_device(pdev);
	if (ret)
		goto err_free;
	pci_set_master(pdev);
	s->bar = pcim_iomap_region(pdev, 0, "nvrec");
	if (IS_ERR(s->bar)) {
		ret = PTR_ERR(s->bar);
		s->bar = NULL;
		goto err_free;
	}
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (ret)
		goto err_free;

	s->asq = dma_alloc_coherent(dev, NVREC_AQ_DEPTH * sizeof(*s->asq), &s->asq_dma, GFP_KERNEL);
	s->acq = dma_alloc_coherent(dev, NVREC_AQ_DEPTH * sizeof(*s->acq), &s->acq_dma, GFP_KERNEL);
	s->idbuf = dma_alloc_coherent(dev, SZ_4K, &s->idbuf_dma, GFP_KERNEL);
	if (!s->asq || !s->acq || !s->idbuf) {
		ret = -ENOMEM;
		goto err_free;
	}

	mutex_lock(&nv->ssd_lock);
	if (nv->ssd[index]) {
		mutex_unlock(&nv->ssd_lock);
		dev_err(dev, "SSD index %u already taken\n", index);
		ret = -EBUSY;
		goto err_free;
	}
	nv->ssd[index] = s;		/* completions may arrive from now on */
	mutex_unlock(&nv->ssd_lock);

	ret = nvrec_ctrl_init(s);
	if (ret)
		goto err_detach;

	s->state = NVREC_SSD_LIVE;
	pci_set_drvdata(pdev, s);
	ret = nvrec_blk_add(s);
	if (ret)
		goto err_queues;

	dev_info(dev, "SSD%u: %s (%s, fw %s): %llu x %u-byte LBAs (%llu GB), MDTS %u KB, DSTRD %llu, %u I/O queues granted, %u SW + %u HW queues in the IP, block I/O via %s -> /dev/%s\n",
		 index, s->model, s->serial, s->firmware, s->nlba, 1u << s->lba_shift,
		 (s->nlba << s->lba_shift) / 1000000000ull, s->mdts_bytes / 1024,
		 NVME_CAP_STRIDE(s->cap), s->nr_io_queues, s->sw_queues, s->hw_queues,
		 s->io_path == NVREC_PATH_SWQ ? "the IP software queue" : "the CPU command injector",
		 s->disk_name);
	return 0;

err_queues:
	nvrec_delete_queues(s);
err_detach:
	nvrec_disable(s);
	nvrec_hw_ssd_flush(nv, index);
	mutex_lock(&nv->ssd_lock);
	nv->ssd[index] = NULL;
	mutex_unlock(&nv->ssd_lock);
err_free:
	pci_set_drvdata(pdev, NULL);
	nvrec_ssd_free(s);
	return ret;
}

static void nvrec_pci_remove(struct pci_dev *pdev)
{
	struct nvrec_ssd *s = pci_get_drvdata(pdev);
	struct nvrec_dev *nv;

	if (!s)
		return;
	nv = s->nv;
	nvrec_session_ssd_gone(nv, s->index);	/* abort a run that uses it */
	nvrec_blk_remove(s);			/* drains block I/O */
	if (!s->dead) {
		nvrec_delete_queues(s);
		nvrec_shutdown_ctrl(s);
	}
	if (!nvrec_ha_is_dead(nv))	/* else disabled write-only already */
		nvrec_disable(s);
	nvrec_hw_ssd_flush(nv, s->index);
	mutex_lock(&nv->ssd_lock);
	nv->ssd[s->index] = NULL;
	mutex_unlock(&nv->ssd_lock);
	pci_set_drvdata(pdev, NULL);
	nvrec_ssd_free(s);
}

static void nvrec_pci_shutdown(struct pci_dev *pdev)
{
	struct nvrec_ssd *s = pci_get_drvdata(pdev);

	if (s && !s->dead)
		nvrec_shutdown_ctrl(s);
}

/*
 * Every NVMe-class device; probe returns -ENODEV for those that are not
 * behind one of our root ports, so they stay available to the stock driver.
 */
static const struct pci_device_id nvrec_pci_ids[] = {
	{ PCI_DEVICE_CLASS(PCI_CLASS_STORAGE_EXPRESS, 0xffffff) },
	{ }
};
MODULE_DEVICE_TABLE(pci, nvrec_pci_ids);

static struct pci_driver nvrec_pci_driver = {
	.name = "nvrec-nvme",
	.id_table = nvrec_pci_ids,
	.probe = nvrec_pci_probe,
	.remove = nvrec_pci_remove,
	.shutdown = nvrec_pci_shutdown,
};

int nvrec_nvme_register(void)
{
	return pci_register_driver(&nvrec_pci_driver);
}

void nvrec_nvme_unregister(void)
{
	pci_unregister_driver(&nvrec_pci_driver);
}
