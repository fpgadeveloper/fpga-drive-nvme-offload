// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * nvrec_blk.c -- /dev/nvrecXn1: a blk-mq block device per SSD namespace,
 * whose I/O goes through the NVMe Host Accelerator.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * One hardware context, requests become NVMe Read/Write/Flush/Dataset
 * Management commands with PRPs (one 4 KB PRP list per request, allocated
 * once per tag), submitted
 *   - through the IP's software SQ (S_AXI) when the drive granted enough I/O
 *     queues for the IP's software queue: completions arrive by ha_interrupt
 *     (nvrec_hw.c pops the CQE and calls nvrec_blk_complete());
 *   - through nvrec_core's CPU command injector onto the hardware SQ
 *     otherwise (IP built with C_NUM_SQ_SW = 0 for this SSD): one command in
 *     flight, completion by the nvrec_core interrupt.
 *
 * The queue depth is the number of software-queue credits (depth - 1, one
 * SQ entry is always empty), so the IP's credit counter can never underflow.
 * The CID of a command is its blk-mq tag (injector: tag | the injector CID
 * flag, so the command builder's CIDs on the hardware SQ cannot collide).
 */

#include <linux/module.h>
#include <linux/blkdev.h>
#include <linux/blk-mq.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

#include "nvrec.h"

#define NVREC_PAGE		4096u
#define NVREC_MAX_IO_BYTES	(1u << 20)	/* one PRP list page is enough */
#define NVREC_MAX_SEGS		(NVREC_MAX_IO_BYTES / NVREC_PAGE + 1)

struct nvrec_iod {
	struct nvrec_ssd *s;
	struct scatterlist sg[NVREC_MAX_SEGS];
	int nents;		/* mapped entries, 0 = no data mapping */
	enum dma_data_direction dir;
	__le64 *prp_list;	/* 4 KB, coherent; also the DSM range */
	dma_addr_t prp_dma;
	u16 status;		/* CQE status (15 bits) */
};

static blk_status_t nvrec_map_data(struct nvrec_ssd *s, struct request *rq,
				   struct nvrec_iod *iod, struct nvme_sqe *c)
{
	struct device *dev = &s->pdev->dev;
	struct scatterlist *sg;
	int length = blk_rq_payload_bytes(rq);
	u64 dma_addr;
	int dma_len, offset, i, n;

	iod->dir = rq_data_dir(rq) == WRITE ? DMA_TO_DEVICE : DMA_FROM_DEVICE;
	sg_init_table(iod->sg, NVREC_MAX_SEGS);
	n = blk_rq_map_sg(rq->q, rq, iod->sg);
	if (!n)
		return BLK_STS_IOERR;
	iod->nents = dma_map_sg_attrs(dev, iod->sg, n, iod->dir, DMA_ATTR_NO_WARN);
	if (!iod->nents)
		return BLK_STS_RESOURCE;

	/* PRPs: the queue's virt_boundary_mask guarantees that every segment
	 * but the first starts on a page and every segment but the last ends
	 * on one (same scheme as drivers/nvme/host/pci.c) */
	sg = iod->sg;
	dma_addr = sg_dma_address(sg);
	dma_len = sg_dma_len(sg);
	offset = dma_addr & (NVREC_PAGE - 1);
	c->prp1 = cpu_to_le64(dma_addr);
	length -= (NVREC_PAGE - offset);
	if (length <= 0)
		return BLK_STS_OK;
	dma_len -= (NVREC_PAGE - offset);
	if (dma_len) {
		dma_addr += (NVREC_PAGE - offset);
	} else {
		sg = sg_next(sg);
		dma_addr = sg_dma_address(sg);
		dma_len = sg_dma_len(sg);
	}
	if (length <= NVREC_PAGE) {
		c->prp2 = cpu_to_le64(dma_addr);
		return BLK_STS_OK;
	}
	i = 0;
	for (;;) {
		if (i == NVREC_PAGE / 8)
			goto bad;
		iod->prp_list[i++] = cpu_to_le64(dma_addr);
		dma_len -= NVREC_PAGE;
		dma_addr += NVREC_PAGE;
		length -= NVREC_PAGE;
		if (length <= 0)
			break;
		if (dma_len > 0)
			continue;
		if (dma_len < 0)
			goto bad;
		sg = sg_next(sg);
		dma_addr = sg_dma_address(sg);
		dma_len = sg_dma_len(sg);
	}
	c->prp2 = cpu_to_le64(iod->prp_dma);
	return BLK_STS_OK;
bad:
	WARN_ONCE(1, "nvrec: invalid SGL for payload %u nents %d\n",
		  blk_rq_payload_bytes(rq), iod->nents);
	dma_unmap_sg(dev, iod->sg, n, iod->dir);
	iod->nents = 0;
	return BLK_STS_IOERR;
}

static void nvrec_unmap_data(struct nvrec_ssd *s, struct nvrec_iod *iod)
{
	if (iod->nents) {
		dma_unmap_sg(&s->pdev->dev, iod->sg,
			     sg_nents(iod->sg), iod->dir);
		iod->nents = 0;
	}
}

static blk_status_t nvrec_queue_rq(struct blk_mq_hw_ctx *hctx,
				   const struct blk_mq_queue_data *bd)
{
	struct nvrec_ssd *s = hctx->queue->queuedata;
	struct request *rq = bd->rq;
	struct nvrec_iod *iod = blk_mq_rq_to_pdu(rq);
	unsigned int shift = s->lba_shift - SECTOR_SHIFT;
	bool inj = s->io_path == NVREC_PATH_INJECTOR;
	u16 cid = inj ? nvrec_hw_inj_cid(rq->tag) : rq->tag;
	struct nvme_sqe c;
	blk_status_t ret;
	u64 slba;
	u32 nlb;
	int err;

	if (unlikely(s->dead))
		return BLK_STS_IOERR;
	iod->nents = 0;
	iod->status = 0;

	switch (req_op(rq)) {
	case REQ_OP_FLUSH:
		nvme_sqe_set(&c, NVME_CMD_FLUSH, cid);
		c.nsid = cpu_to_le32(s->nsid);
		break;
	case REQ_OP_READ:
	case REQ_OP_WRITE:
		slba = blk_rq_pos(rq) >> shift;
		nlb = (blk_rq_bytes(rq) >> s->lba_shift);
		if (!nlb)
			return BLK_STS_IOERR;
		nvme_sqe_set(&c, req_op(rq) == REQ_OP_WRITE ? NVME_CMD_WRITE :
			     NVME_CMD_READ, cid);
		c.nsid = cpu_to_le32(s->nsid);
		c.cdw10 = cpu_to_le32(lower_32_bits(slba));
		c.cdw11 = cpu_to_le32(upper_32_bits(slba));
		c.cdw12 = cpu_to_le32((nlb - 1) |
				      ((rq->cmd_flags & REQ_FUA) ? NVME_RW_FUA : 0));
		ret = nvrec_map_data(s, rq, iod, &c);
		if (ret)
			return ret;
		break;
	case REQ_OP_DISCARD: {
		struct {
			__le32 cattr;
			__le32 nlb;
			__le64 slba;
		} *range = (void *)iod->prp_list;

		slba = blk_rq_pos(rq) >> shift;
		nlb = blk_rq_sectors(rq) >> shift;
		if (!nlb)
			return BLK_STS_IOERR;
		range->cattr = 0;
		range->nlb = cpu_to_le32(nlb);
		range->slba = cpu_to_le64(slba);
		nvme_sqe_set(&c, NVME_CMD_DSM, cid);
		c.nsid = cpu_to_le32(s->nsid);
		c.prp1 = cpu_to_le64(iod->prp_dma);
		c.cdw10 = 0;			/* one range */
		c.cdw11 = cpu_to_le32(NVME_DSM_AD);
		break;
	}
	default:
		return BLK_STS_NOTSUPP;
	}

	blk_mq_start_request(rq);
	atomic_inc(&s->inflight);
	err = inj ? nvrec_hw_inj_submit(s->nv, s->index, &c) : -EIO;
	if (err) {
		atomic_dec(&s->inflight);
		nvrec_unmap_data(s, iod);
		/* injector busy with the other SSD's command: retry later */
		return err == -EBUSY ? BLK_STS_RESOURCE : BLK_STS_IOERR;
	}
	return BLK_STS_OK;
}

/* Called from the IP / injector interrupt handlers with the raw CQE */
void nvrec_blk_complete(struct nvrec_ssd *s, const struct nvme_cqe *cqe)
{
	u16 cid = le16_to_cpu(cqe->cid);
	u16 tag = s->io_path == NVREC_PATH_INJECTOR ? cid & 0x7fff : cid;
	struct nvrec_iod *iod;
	struct request *rq;

	if (!s->tagset_ok || tag >= s->tagset.queue_depth) {
		dev_err_ratelimited(&s->pdev->dev, "completion with unexpected CID 0x%04x\n", cid);
		return;
	}
	rq = blk_mq_tag_to_rq(s->tagset.tags[0], tag);
	if (unlikely(!rq || !blk_mq_request_started(rq))) {
		dev_err_ratelimited(&s->pdev->dev, "completion for idle CID 0x%04x\n", cid);
		return;
	}
	iod = blk_mq_rq_to_pdu(rq);
	iod->status = le16_to_cpu(cqe->status) >> 1;
	if (!blk_mq_complete_request_remote(rq))
		blk_mq_complete_request(rq);
}

static void nvrec_complete_rq(struct request *rq)
{
	struct nvrec_iod *iod = blk_mq_rq_to_pdu(rq);
	struct nvrec_ssd *s = iod->s;
	blk_status_t st = BLK_STS_OK;

	nvrec_unmap_data(s, iod);
	atomic_dec(&s->inflight);
	if (iod->status) {
		u16 sc = iod->status & 0xff, sct = (iod->status >> 8) & 7;

		if (sct == 0 && sc == 0x80)
			st = BLK_STS_NOSPC;	/* LBA out of range */
		else if (sct == 2)
			st = BLK_STS_MEDIUM;
		else if (sct == 0 && sc == 0x01)
			st = BLK_STS_NOTSUPP;	/* invalid opcode */
		else
			st = BLK_STS_IOERR;
		dev_err_ratelimited(&s->pdev->dev, "I/O error: %s sector %llu: status 0x%04x (SCT %u SC 0x%02x)\n",
				    blk_op_str(req_op(rq)), blk_rq_pos(rq),
				    iod->status, sct, sc);
	}
	blk_mq_end_request(rq, st);
}

static enum blk_eh_timer_return nvrec_timeout(struct request *rq)
{
	struct nvrec_iod *iod = blk_mq_rq_to_pdu(rq);

	/* No per-command abort through the IP: give the controller up. This
	 * also completes rq (nvrec_blk_fail_all). */
	nvrec_nvme_kill(iod->s, "I/O command timed out");
	return BLK_EH_DONE;
}

static int nvrec_init_request(struct blk_mq_tag_set *set, struct request *rq,
			      unsigned int hctx_idx, unsigned int numa_node)
{
	struct nvrec_ssd *s = set->driver_data;
	struct nvrec_iod *iod = blk_mq_rq_to_pdu(rq);

	iod->s = s;
	iod->prp_list = dma_alloc_coherent(&s->pdev->dev, NVREC_PAGE,
					   &iod->prp_dma, GFP_KERNEL);
	return iod->prp_list ? 0 : -ENOMEM;
}

static void nvrec_exit_request(struct blk_mq_tag_set *set, struct request *rq,
			       unsigned int hctx_idx)
{
	struct nvrec_ssd *s = set->driver_data;
	struct nvrec_iod *iod = blk_mq_rq_to_pdu(rq);

	if (iod->prp_list)
		dma_free_coherent(&s->pdev->dev, NVREC_PAGE, iod->prp_list,
				  iod->prp_dma);
	iod->prp_list = NULL;
}

static const struct blk_mq_ops nvrec_mq_ops = {
	.queue_rq = nvrec_queue_rq,
	.complete = nvrec_complete_rq,
	.timeout = nvrec_timeout,
	.init_request = nvrec_init_request,
	.exit_request = nvrec_exit_request,
};

static bool nvrec_cancel_rq(struct request *rq, void *data)
{
	struct nvrec_iod *iod = blk_mq_rq_to_pdu(rq);

	if (blk_mq_request_completed(rq))
		return true;
	iod->status = 0x0006;	/* internal error (SCT 0, SC 6) */
	blk_mq_complete_request(rq);
	return true;
}

/* Controller gone: complete every outstanding request with an error */
void nvrec_blk_fail_all(struct nvrec_ssd *s)
{
	if (!s->tagset_ok)
		return;
	blk_mq_tagset_busy_iter(&s->tagset, nvrec_cancel_rq, NULL);
	blk_mq_tagset_wait_completed_request(&s->tagset);
}

/* /sys/block/nvrecXn1/nvrec/{ssd_index,model,serial,firmware,io_path,...} */
static struct nvrec_ssd *disk_ssd(struct device *dev)
{
	return dev_to_disk(dev)->queue->queuedata;
}

#define NVREC_DISK_ATTR(_name, _fmt, _expr)				\
static ssize_t _name##_show(struct device *dev,				\
			    struct device_attribute *attr, char *buf)	\
{									\
	struct nvrec_ssd *s = disk_ssd(dev);				\
	return sysfs_emit(buf, _fmt "\n", _expr);			\
}									\
static DEVICE_ATTR_RO(_name)

NVREC_DISK_ATTR(ssd_index, "%u", s->index);
NVREC_DISK_ATTR(model, "%s", s->model);
NVREC_DISK_ATTR(serial, "%s", s->serial);
NVREC_DISK_ATTR(firmware, "%s", s->firmware);
NVREC_DISK_ATTR(nsid, "%u", s->nsid);
NVREC_DISK_ATTR(io_path, "%s", s->io_path == NVREC_PATH_SWQ ? "swq" :
		s->io_path == NVREC_PATH_INJECTOR ? "injector" : "none");
NVREC_DISK_ATTR(nr_io_queues, "%u", s->nr_io_queues);
NVREC_DISK_ATTR(mdts_bytes, "%u", s->mdts_bytes);
NVREC_DISK_ATTR(inflight_cmds, "%d", atomic_read(&s->inflight));
NVREC_DISK_ATTR(pci, "%s", pci_name(s->pdev));
NVREC_DISK_ATTR(dead, "%u", s->dead);
/* Identify Controller WCTEMP / CCTEMP in degrees C, 0 = not reported */
NVREC_DISK_ATTR(temperature_warn, "%d", s->wctemp_k ? (int)s->wctemp_k - 273 : 0);
NVREC_DISK_ATTR(temperature_crit, "%d", s->cctemp_k ? (int)s->cctemp_k - 273 : 0);

/* composite temperature, degrees C: SMART log of the drive (admin queue,
 * not the recorder's path), read at most once a second */
static ssize_t temperature_show(struct device *dev, struct device_attribute *attr,
				char *buf)
{
	int t, ret = nvrec_nvme_temperature(disk_ssd(dev), &t);

	return ret ? ret : sysfs_emit(buf, "%d\n", t);
}
static DEVICE_ATTR_RO(temperature);

/* Autonomous Power State Transitions now: on / off / unsupported */
static ssize_t apst_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	bool on;
	int ret = nvrec_nvme_apst_get(disk_ssd(dev), &on);

	if (ret == -EOPNOTSUPP)
		return sysfs_emit(buf, "unsupported\n");
	return ret ? ret : sysfs_emit(buf, "%s\n", on ? "on" : "off");
}
static DEVICE_ATTR_RO(apst);

static struct attribute *nvrec_disk_attrs[] = {
	&dev_attr_ssd_index.attr,
	&dev_attr_model.attr,
	&dev_attr_serial.attr,
	&dev_attr_firmware.attr,
	&dev_attr_nsid.attr,
	&dev_attr_io_path.attr,
	&dev_attr_nr_io_queues.attr,
	&dev_attr_mdts_bytes.attr,
	&dev_attr_inflight_cmds.attr,
	&dev_attr_pci.attr,
	&dev_attr_dead.attr,
	&dev_attr_temperature.attr,
	&dev_attr_temperature_warn.attr,
	&dev_attr_temperature_crit.attr,
	&dev_attr_apst.attr,
	NULL,
};

static const struct attribute_group nvrec_disk_group = {
	.name = "nvrec",
	.attrs = nvrec_disk_attrs,
};

static const struct attribute_group *nvrec_disk_groups[] = {
	&nvrec_disk_group,
	NULL,
};

static const struct block_device_operations nvrec_bdev_ops = {
	.owner = THIS_MODULE,
};

int nvrec_blk_add(struct nvrec_ssd *s)
{
	u32 lbs = 1u << s->lba_shift;
	u32 max_io = NVREC_MAX_IO_BYTES;
	struct queue_limits lim = { };
	struct gendisk *disk;
	int ret;

	if (s->mdts_bytes && s->mdts_bytes < max_io)
		max_io = s->mdts_bytes;

	memset(&s->tagset, 0, sizeof(s->tagset));
	s->tagset.ops = &nvrec_mq_ops;
	s->tagset.nr_hw_queues = 1;
	s->tagset.queue_depth = s->io_path == NVREC_PATH_SWQ ?
				s->nv->cfg.sq_depth - 1 : s->nv->cfg.inj_depth;
	s->tagset.numa_node = dev_to_node(&s->pdev->dev);
	s->tagset.cmd_size = sizeof(struct nvrec_iod);
	s->tagset.flags = BLK_MQ_F_SHOULD_MERGE;
	s->tagset.driver_data = s;
	s->tagset.timeout = 30 * HZ;
	ret = blk_mq_alloc_tag_set(&s->tagset);
	if (ret)
		return ret;
	s->tagset_ok = true;

	lim.logical_block_size = lbs;
	lim.physical_block_size = lbs;
	lim.io_min = lbs;
	lim.max_hw_sectors = max_io >> SECTOR_SHIFT;
	lim.max_segments = NVREC_MAX_SEGS;
	lim.virt_boundary_mask = NVREC_PAGE - 1;
	lim.dma_alignment = 3;
	if (s->vwc)
		lim.features |= BLK_FEAT_WRITE_CACHE | BLK_FEAT_FUA;
	if (s->dsm) {
		lim.max_hw_discard_sectors = min_t(u64, (u64)U32_MAX << (s->lba_shift - SECTOR_SHIFT),
						   UINT_MAX);
		lim.discard_granularity = lbs;
		lim.max_discard_segments = 1;
	}

	disk = blk_mq_alloc_disk(&s->tagset, &lim, s);
	if (IS_ERR(disk)) {
		ret = PTR_ERR(disk);
		goto err_tagset;
	}
	disk->fops = &nvrec_bdev_ops;
	disk->private_data = s;
	disk->minors = 0;
	strscpy(disk->disk_name, s->disk_name, DISK_NAME_LEN);
	set_capacity(disk, s->nlba << (s->lba_shift - SECTOR_SHIFT));
	s->disk = disk;
	ret = device_add_disk(&s->pdev->dev, disk, nvrec_disk_groups);
	if (ret)
		goto err_disk;
	return 0;

err_disk:
	put_disk(disk);
	s->disk = NULL;
err_tagset:
	blk_mq_free_tag_set(&s->tagset);
	s->tagset_ok = false;
	return ret;
}

void nvrec_blk_remove(struct nvrec_ssd *s)
{
	if (s->disk) {
		del_gendisk(s->disk);
		put_disk(s->disk);
		s->disk = NULL;
	}
	if (s->tagset_ok) {
		blk_mq_free_tag_set(&s->tagset);
		s->tagset_ok = false;
	}
}
