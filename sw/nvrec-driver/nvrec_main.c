// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * nvrec -- FPGA Drive NVMe-offload recorder driver
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Platform driver for the "opsero,nvrec" node (nvrec_core + the AMD NVMe
 * Host Accelerator) and the control device /dev/nvrec. The SSDs are claimed
 * by the PCI driver in nvrec_nvme.c and exposed as /dev/nvrecXn1 by
 * nvrec_blk.c. docs/source/driver.md describes the whole driver.
 *
 * Ring and cache coherency -- READ THIS BEFORE CHANGING ANY SYNC CALL:
 *
 *   The hardware addresses ring slot s at RING_BASE + s * chunk, so the ring
 *   is ONE physically contiguous region. By default the driver allocates it
 *   (dma_alloc_attrs from CMA, no kernel mapping: the CPU never reads or
 *   writes sample data). Two devices touch it: the fabric ring writer/reader
 *   through an S_AXI_HP port and the SSDs through the PCIe root ports' AXI
 *   master, neither cache coherent. A buffer from dma_alloc_attrs() has been
 *   cleaned and invalidated by the DMA API, and nothing on the CPU side
 *   touches it afterwards, so no per-chunk maintenance is needed.
 *
 *   An app may hand in its own 2 MB-hugepage ring instead (fdrec style); it
 *   is accepted only when the pages happen to be physically contiguous, and
 *   is mapped with dma_map_sgtable(DMA_BIDIRECTIONAL) -- a clean AND
 *   invalidate of every line, so no dirty line can later be evicted over
 *   fabric/SSD data. The app must not touch such a ring while it is
 *   registered (no cache maintenance is done for its CPU accesses).
 *
 *   The PRP lists are dma_alloc_coherent() memory (non-cacheable for this
 *   non-coherent device), written once at SET_RING; a wmb() orders them
 *   before the registers that point the hardware at them.
 *
 * Addresses: PRP1 = RING_BASE + slot * chunk is used by the SSD (PCI DMA
 * view) and by the ring writer (fabric view) alike, so SET_RING refuses a
 * system where the two views of DDR differ. A ring set up while no SSD is
 * live cannot be checked: it serves fabric-only (DRY) runs only.
 *
 * Split ring (register map 1.3, two ring ports): the ring can also be
 * striped over memory 0 (the CMA allocation above) and memory 1, a
 * second DDR behind the second ring port that the CPU never touches (the
 * device tree reserves it, no-map, "memory-region"): ring B is simply the
 * start of that region, nothing is allocated or mapped. Stripe i of
 * 2^stripe_shift bytes lives in memory i & 1 (nvrec_ring.h); the PRP list
 * entries (one per 4 KB page) follow the same address function, so an SSD
 * reads and writes both memories within one command when the stripe is
 * smaller than a chunk. The fabric/SSD-view check covers both memories.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/dma-mapping.h>
#include <linux/dma-direct.h>
#include <linux/scatterlist.h>
#include <linux/poll.h>
#include <linux/sched/signal.h>
#include <linux/ktime.h>
#include <linux/idr.h>
#include <linux/blkdev.h>
#include <linux/math64.h>

#define NVREC_PAGE_SZ	4096u

#include "nvrec.h"
#include "nvrec_regs.h"
#include "nvrec_ring.h"

static LIST_HEAD(nvrec_list);
static DEFINE_MUTEX(nvrec_list_lock);
static DEFINE_IDA(nvrec_ida);

/*
 * ring_split: the layout of a ring an app sets up without naming one
 * (nvrec_ring.flags = 0; nvrec_info.ring_default tells the apps):
 *   auto  split over both memories when the design can (two ring ports, a
 *         memory-1 region, memory 1 ready), except for single-SSD runs
 *   0     single ring in memory 0 (as driver 1.1)
 *   1     split whenever the design can, single-SSD runs too
 */
static int ring_split = -1;

static int ring_split_set(const char *val, const struct kernel_param *kp)
{
	if (sysfs_streq(val, "auto") || sysfs_streq(val, "-1"))
		ring_split = -1;
	else if (sysfs_streq(val, "0") || sysfs_streq(val, "single"))
		ring_split = 0;
	else if (sysfs_streq(val, "1") || sysfs_streq(val, "split"))
		ring_split = 1;
	else
		return -EINVAL;
	return 0;
}

static int ring_split_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%s\n", ring_split < 0 ? "auto" : ring_split ? "1" : "0");
}

static const struct kernel_param_ops ring_split_ops = {
	.set = ring_split_set,
	.get = ring_split_get,
};
module_param_cb(ring_split, &ring_split_ops, NULL, 0644);
MODULE_PARM_DESC(ring_split, "default ring layout: auto (split over both memories when the design can, not for single-SSD runs), 0 (single ring in PS DDR), 1 (split, single-SSD runs too)");

/*
 * stripe_kb: the default split-ring stripe: "auto" (or 0) = the board's
 * (device tree opsero,ring-stripe-chunk / opsero,ring-stripe-kb, else the
 * whole chunk), "chunk" = the whole chunk, or KB (a power of two, 4 ..
 * 4096), capped at the chunk at SET_RING.
 */
#define STRIPE_KB_AUTO		0u
#define STRIPE_KB_CHUNK		U32_MAX
static unsigned int stripe_kb = STRIPE_KB_AUTO;

static int stripe_kb_set(const char *val, const struct kernel_param *kp)
{
	unsigned int v;

	if (sysfs_streq(val, "auto")) {
		stripe_kb = STRIPE_KB_AUTO;
		return 0;
	}
	if (sysfs_streq(val, "chunk")) {
		stripe_kb = STRIPE_KB_CHUNK;
		return 0;
	}
	if (kstrtouint(val, 0, &v))
		return -EINVAL;
	if (v && (v < 4 || v > NVREC_MAX_CHUNK / 1024 || !is_power_of_2(v)))
		return -EINVAL;
	stripe_kb = v;
	return 0;
}

static int stripe_kb_get(char *buf, const struct kernel_param *kp)
{
	if (stripe_kb == STRIPE_KB_AUTO)
		return sysfs_emit(buf, "auto\n");
	if (stripe_kb == STRIPE_KB_CHUNK)
		return sysfs_emit(buf, "chunk\n");
	return sysfs_emit(buf, "%u\n", stripe_kb);
}

static const struct kernel_param_ops stripe_kb_ops = {
	.set = stripe_kb_set,
	.get = stripe_kb_get,
};
module_param_cb(stripe_kb, &stripe_kb_ops, NULL, 0644);
MODULE_PARM_DESC(stripe_kb, "default split-ring stripe: auto (the board's: device tree opsero,ring-stripe-chunk / opsero,ring-stripe-kb, else the whole chunk), chunk, or KB (power of two, 4..4096, capped at the chunk)");

/* ------------------------------------------------------------------------ */
/* SSD lookup (called by the PCI driver)                                    */

static struct device_node *pci_port_node(struct pci_dev *pdev)
{
	struct pci_host_bridge *hb = pci_find_host_bridge(pdev->bus);

	if (!hb)
		return NULL;
	if (hb->dev.parent && hb->dev.parent->of_node)
		return hb->dev.parent->of_node;
	return hb->dev.of_node;
}

/*
 * Which nvrec instance and SSD index owns this PCI device: the one whose
 * "opsero,ssd-ports" list contains the device's host bridge (root port)
 * node. -ENODEV: not ours (stays available to the stock nvme driver);
 * -EPROBE_DEFER: an nvrec node exists but has not probed yet.
 */
struct nvrec_dev *nvrec_find_for_pci(struct pci_dev *pdev, unsigned int *index)
{
	struct device_node *np = pci_port_node(pdev), *dt;
	struct nvrec_dev *nv;
	unsigned int i;

	mutex_lock(&nvrec_list_lock);
	list_for_each_entry(nv, &nvrec_list, node_list) {
		for (i = 0; i < nv->cfg.nr_ssd; i++) {
			if (np && nv->port_np[i] == np) {
				*index = i;
				mutex_unlock(&nvrec_list_lock);
				return nv;
			}
		}
	}
	mutex_unlock(&nvrec_list_lock);

	dt = of_find_compatible_node(NULL, NULL, "opsero,nvrec");
	if (dt) {
		bool avail = of_device_is_available(dt);

		of_node_put(dt);
		mutex_lock(&nvrec_list_lock);
		if (avail && list_empty(&nvrec_list)) {
			mutex_unlock(&nvrec_list_lock);
			return ERR_PTR(-EPROBE_DEFER);
		}
		mutex_unlock(&nvrec_list_lock);
	}
	return ERR_PTR(-ENODEV);
}

/* ------------------------------------------------------------------------ */
/* Session state                                                            */

static bool nvrec_running(struct nvrec_dev *nv)
{
	return nv->state == NVREC_RUN_RECORD || nv->state == NVREC_RUN_PLAY;
}

static void nvrec_invalidate_members(struct nvrec_dev *nv, bool sync)
{
	unsigned int j;

	if (!nv->geo_valid)
		return;
	for (j = 0; j < nv->geo.nr_members; j++) {
		struct nvrec_ssd *s = nv->ssd[nv->geo.members[j].ssd];

		if (!s || !s->disk)
			continue;
		if (sync)
			sync_blockdev(s->disk->part0);
		invalidate_bdev(s->disk->part0);
	}
}

static void nvrec_snapshot(struct nvrec_dev *nv, u32 state)
{
	memset(&nv->final, 0, sizeof(nv->final));
	nvrec_hw_read_stats(nv, &nv->final);
	nv->stop_ns = ktime_get_ns();
	nv->final.elapsed_ns = nv->stop_ns - nv->start_ns;
	nv->final.state = state;
	nv->final_valid = true;
	nv->state = state;
}

/* Called with nv->lock: notice that the hardware finished on its own */
static void nvrec_stop_run(struct nvrec_dev *nv, bool abort);

static void nvrec_update_state(struct nvrec_dev *nv)
{
	/* a DRY run uses no NVMe path: a dead Host Accelerator does not end it */
	if (nvrec_running(nv) && !nv->run_dry && nvrec_hw_ha_dead(nv)) {
		dev_err(nv->dev, "run failed: the Host Accelerator stopped responding\n");
		nvrec_stop_run(nv, true);	/* -> NVREC_RUN_FAILED */
		return;
	}
	if (!nvrec_running(nv) || !nvrec_hw_finished(nv))
		return;
	nvrec_hw_tpg_enable(nv, false);
	nvrec_snapshot(nv, nvrec_hw_aborted(nv) ? NVREC_RUN_ABORTED : NVREC_RUN_DONE);
	nvrec_invalidate_members(nv, false);
}

/* nvrec_core interrupt: the run finished, was aborted or saw an error */
void nvrec_run_event(struct nvrec_dev *nv)
{
	wake_up_interruptible_all(&nv->wq);
}

static bool nvrec_run_finished(struct nvrec_dev *nv)
{
	return !nvrec_running(nv) || nvrec_hw_finished(nv) ||
	       (!nv->run_dry && nvrec_hw_ha_dead(nv));
}

/* The Host Accelerator is dead: every NVMe command path goes through it,
 * so disable the SSDs (stops their DMA, fails the block I/O at once) */
void nvrec_ha_dead_work(struct work_struct *work)
{
	struct nvrec_dev *nv = container_of(work, struct nvrec_dev, ha_dead_work);
	unsigned int i;

	mutex_lock(&nv->ssd_lock);
	for (i = 0; i < NVREC_MAX_SSD; i++)
		if (nv->ssd[i])
			nvrec_nvme_kill(nv->ssd[i], "Host Accelerator stopped responding");
	mutex_unlock(&nv->ssd_lock);
	wake_up_interruptible_all(&nv->wq);
}

/* Stop or abort a run; nv->lock held */
static void nvrec_stop_run(struct nvrec_dev *nv, bool abort)
{
	unsigned int j;
	int ret;

	if (!nvrec_running(nv))
		return;
	ret = nvrec_hw_stop(nv, abort);
	if (ret) {
		/* An SSD stopped answering: the commands in flight may still
		 * DMA into the ring. Disable the members before anything can
		 * unpin the ring. */
		dev_err(nv->dev, "run did not drain (%d): disabling the member SSDs\n", ret);
		for (j = 0; j < nv->geo.nr_members; j++) {
			struct nvrec_ssd *s = nv->ssd[nv->geo.members[j].ssd];

			if (s)
				nvrec_nvme_kill(s, "recorder commands did not complete");
		}
	}
	nvrec_snapshot(nv, ret ? NVREC_RUN_FAILED :
		       nvrec_hw_aborted(nv) ? NVREC_RUN_ABORTED : NVREC_RUN_DONE);
	nvrec_invalidate_members(nv, false);
}

/* An SSD is going away (PCI remove): end a run that uses it */
void nvrec_session_ssd_gone(struct nvrec_dev *nv, unsigned int index)
{
	unsigned int j;

	mutex_lock(&nv->lock);
	if (nvrec_running(nv) && nv->geo_valid)
		for (j = 0; j < nv->geo.nr_members; j++)
			if (nv->geo.members[j].ssd == index) {
				nvrec_stop_run(nv, true);
				break;
			}
	if (nv->geo_valid)
		for (j = 0; j < nv->geo.nr_members; j++)
			if (nv->geo.members[j].ssd == index)
				nv->geo_valid = false;
	mutex_unlock(&nv->lock);
}

/* ------------------------------------------------------------------------ */
/* Ring                                                                     */

static void nvrec_ring_free(struct nvrec_dev *nv)
{
	if (nv->ring_ours && nv->ring_cookie)
		dma_free_attrs(nv->dev, nv->ring_bytes, nv->ring_cookie,
			       nv->ring_dma, DMA_ATTR_NO_KERNEL_MAPPING);
	nv->ring_cookie = NULL;
	nv->ring_ours = false;
	if (nv->sgt_mapped)
		dma_unmap_sgtable(nv->dev, &nv->sgt, DMA_BIDIRECTIONAL, 0);
	nv->sgt_mapped = false;
	if (nv->sgt.sgl)
		sg_free_table(&nv->sgt);
	nv->sgt.sgl = NULL;
	if (nv->pages) {
		if (nv->npages)
			unpin_user_pages_dirty_lock(nv->pages, nv->npages, true);
		kvfree(nv->pages);
	}
	nv->pages = NULL;
	nv->npages = 0;
	if (nv->prp_lists)
		dma_free_coherent(nv->dev, nv->prp_lists_bytes, nv->prp_lists,
				  nv->prp_lists_dma);
	nv->prp_lists = NULL;
	nv->prp_lists_bytes = 0;
	nv->ring_dma = 0;
	nv->ring_bytes = 0;
	nv->ring_layout = 0;
	nv->stripe_shift = 0;
	nv->ring1_used = 0;
	nv->ring_ssd_ok = false;
	nv->slots = 0;
	nv->chunk = 0;
	nv->geo_valid = false;
}

/* The split ring and MEM1 rings are possible now (memory 1 ready) */
static bool nvrec_split_ok(struct nvrec_dev *nv)
{
	return (nv->caps & NVREC_CAP_SPLIT_RING) && nvrec_hw_mem1_ready(nv);
}

/* The layout of a ring set up without one (module parameter ring_split),
 * for a run over `members` SSDs (0 = fabric only) */
static u32 nvrec_ring_default(struct nvrec_dev *nv, unsigned int members)
{
	if (!nvrec_split_ok(nv) || !ring_split)
		return NVREC_RING_SINGLE;
	if (ring_split < 0 && members == 1)
		return NVREC_RING_SINGLE;
	return NVREC_RING_SPLIT;
}

/* The default stripe, log2 bytes or NVREC_STRIPE_SHIFT_CHUNK (the whole
 * chunk): module parameter stripe_kb, else the board's device tree
 * (opsero,ring-stripe-chunk, opsero,ring-stripe-kb), else the whole chunk */
static u32 nvrec_stripe_default(struct nvrec_dev *nv)
{
	u32 kb = stripe_kb;

	if (kb == STRIPE_KB_AUTO) {
		if (nv->cfg.stripe_chunk || !nv->cfg.stripe_kb)
			return NVREC_STRIPE_SHIFT_CHUNK;
		kb = nv->cfg.stripe_kb;
	}
	if (kb == STRIPE_KB_CHUNK)
		return NVREC_STRIPE_SHIFT_CHUNK;
	if (kb < 4 || !is_power_of_2(kb) || kb > NVREC_MAX_CHUNK / 1024) {
		dev_warn_once(nv->dev, "opsero,ring-stripe-kb %u invalid (power of two, 4 .. %u): using the whole chunk\n",
			      kb, NVREC_MAX_CHUNK / 1024);
		return NVREC_STRIPE_SHIFT_CHUNK;
	}
	return ilog2(kb) + 10;
}

/* "chunk" or "<n> KB" for the probe line and sysfs */
static const char *nvrec_stripe_name(u32 shift, char *buf, size_t len)
{
	if (shift == NVREC_STRIPE_SHIFT_CHUNK)
		return "chunk";
	snprintf(buf, len, "%u KB", 1u << (shift - 10));
	return buf;
}

static const char *nvrec_layout_name(u32 layout)
{
	switch (layout) {
	case NVREC_RING_SINGLE: return "single";
	case NVREC_RING_SPLIT: return "split";
	case NVREC_RING_MEM1: return "mem1";
	default: return "none";
	}
}

/* SSD-side address of a physical address; ~0 when the SSDs disagree */
static u64 nvrec_ssd_addr(struct nvrec_dev *nv, phys_addr_t pa)
{
	u64 a = ~0ull;
	unsigned int i;

	for (i = 0; i < nv->cfg.nr_ssd; i++) {
		struct nvrec_ssd *s = nv->ssd[i];
		u64 v;

		if (!s || s->dead)
			continue;
		v = phys_to_dma(&s->pdev->dev, pa);
		if (a != ~0ull && v != a)
			return ~0ull;
		a = v;
	}
	return a;
}

/* User ring: pin, require physical contiguity, clean + invalidate */
static int nvrec_ring_user(struct nvrec_dev *nv, u64 addr, u64 bytes)
{
	unsigned long npages = bytes >> PAGE_SHIFT, done = 0, i;
	int ret;

	nv->pages = kvmalloc_array(npages, sizeof(*nv->pages), GFP_KERNEL);
	if (!nv->pages)
		return -ENOMEM;
	while (done < npages) {
		int n = min_t(unsigned long, npages - done, INT_MAX);

		ret = pin_user_pages_fast(addr + (done << PAGE_SHIFT), n,
					  FOLL_WRITE | FOLL_LONGTERM, nv->pages + done);
		if (ret <= 0)
			return ret ? ret : -EFAULT;
		done += ret;
		nv->npages = done;
	}
	for (i = 1; i < npages; i++)
		if (page_to_phys(nv->pages[i]) != page_to_phys(nv->pages[i - 1]) + PAGE_SIZE) {
			dev_err(nv->dev, "user ring is not physically contiguous (break at %lu KB); let the driver allocate it (addr = 0)\n",
				(i << PAGE_SHIFT) >> 10);
			return -EINVAL;
		}
	ret = sg_alloc_table_from_pages(&nv->sgt, nv->pages, npages, 0, bytes, GFP_KERNEL);
	if (ret)
		return ret;
	ret = dma_map_sgtable(nv->dev, &nv->sgt, DMA_BIDIRECTIONAL, 0);
	if (ret)
		return ret;
	nv->sgt_mapped = true;
	if (nv->sgt.nents != 1)
		return -EINVAL;		/* contiguous, so one DMA segment */
	nv->ring_dma = sg_dma_address(nv->sgt.sgl);
	return 0;
}

static int nvrec_set_ring(struct nvrec_dev *nv, struct nvrec_ring __user *uarg)
{
	struct nvrec_ring a;
	struct nvrec_ring_map map;
	phys_addr_t ring_pa;
	u32 n4k, per_list, i, layout, shift = 0, slots;
	u64 total, part0, part1;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if ((a.flags & ~NVREC_RING_LAYOUT_MASK) || hweight32(a.flags) > 1 || a.reserved[0])
		return -EINVAL;
	if (nvrec_running(nv))
		return -EBUSY;
	nvrec_ring_free(nv);
	if (!a.bytes)
		return 0;

	/* the layout: as asked, else the default for a 2-member / DRY run;
	 * an app's own (hugepage) ring is a single ring in memory 0 */
	layout = a.flags ? a.flags : a.addr ? NVREC_RING_SINGLE : nvrec_ring_default(nv, 2);
	if (layout != NVREC_RING_SINGLE) {
		if (a.addr)
			return -EINVAL;
		if (!(nv->caps & NVREC_CAP_SPLIT_RING)) {
			dev_err(nv->dev, "%s ring: %s\n", nvrec_layout_name(layout),
				nv->ring_ports < 2 ? "this design has one ring port" :
				"no memory-1 region in the device tree (memory-region)");
			return -EOPNOTSUPP;
		}
		if (!nvrec_hw_mem1_ready(nv)) {
			dev_err(nv->dev, "%s ring: memory 1 is not ready (STATE.MEM1_READY = 0: the memory controller did not calibrate)\n",
				nvrec_layout_name(layout));
			return -EIO;
		}
	}

	if (a.addr % NVREC_HUGEPAGE || a.bytes % NVREC_HUGEPAGE ||
	    a.bytes > (layout == NVREC_RING_SPLIT ? NVREC_RING_MAX_BYTES_SPLIT :
		       NVREC_RING_MAX_BYTES))
		return -EINVAL;
	if (!is_power_of_2(a.chunk) || a.chunk < NVREC_MIN_CHUNK ||
	    a.chunk > NVREC_MAX_CHUNK || a.chunk % nv->beat_bytes)
		return -EINVAL;
	if (a.bytes / a.chunk < 2 || a.bytes / a.chunk > nv->cfg.max_slots)
		return -EINVAL;
	if (layout == NVREC_RING_SPLIT) {
		/* stripe: 4 KB .. one chunk; the default is capped at the chunk */
		shift = nvrec_ring_stripe(a.stripe_shift, nvrec_stripe_default(nv), ilog2(a.chunk));
		if (!shift)
			return -EINVAL;
	} else if (a.stripe_shift) {
		return -EINVAL;
	}
	/* whole-chunk stripes: an even slot count keeps every SSD on one memory */
	slots = nvrec_ring_slots(a.bytes / a.chunk, layout, shift, ilog2(a.chunk));
	if (slots != a.bytes / a.chunk)
		dev_warn_once(nv->dev, "split ring with whole-chunk stripes: %llu slots rounded down to %u (an even count keeps each SSD on one memory)\n",
			      a.bytes / a.chunk, slots);
	/* the parts of the ring in each memory (slots x chunk bytes in all) */
	total = (u64)slots * a.chunk;
	part0 = nvrec_ring_part_bytes(layout, total, shift, 0);
	part1 = nvrec_ring_part_bytes(layout, total, shift, 1);
	if (part0 > NVREC_RING_MAX_BYTES || part1 > NVREC_RING_MAX_BYTES)
		return -EINVAL;
	if (part1 > nv->cfg.ring1_size) {
		dev_err(nv->dev, "%s ring: %llu MB of it in memory 1, the memory-1 region has %llu MB\n",
			nvrec_layout_name(layout), part1 >> 20, nv->cfg.ring1_size >> 20);
		return -ENOSPC;
	}
	for (i = 0; i < nv->cfg.nr_ssd; i++) {
		struct nvrec_ssd *s = nv->ssd[i];

		if (s && !s->dead && s->mdts_bytes && a.chunk > s->mdts_bytes) {
			dev_err(nv->dev, "chunk %u > MDTS %u of SSD%u\n",
				a.chunk, s->mdts_bytes, i);
			return -EINVAL;
		}
	}
	/* no live SSD: the SSD view of the ring cannot be checked, the ring
	 * serves DRY runs only (nvrec_start) */
	nv->ring_ssd_ok = nvrec_ssd_addr(nv, 0) != ~0ull;

	/* memory 0: the single ring (as given: 2 MB multiple) or ring A of a
	 * split ring (CMA); a MEM1 ring has none */
	nv->ring_bytes = layout == NVREC_RING_SINGLE ? a.bytes : PAGE_ALIGN(part0);
	if (a.addr) {
		ret = nvrec_ring_user(nv, a.addr, a.bytes);
	} else if (nv->ring_bytes) {
		nv->ring_cookie = dma_alloc_attrs(nv->dev, nv->ring_bytes, &nv->ring_dma,
						  GFP_KERNEL, DMA_ATTR_NO_KERNEL_MAPPING);
		nv->ring_ours = !!nv->ring_cookie;
		ret = nv->ring_cookie ? 0 : -ENOMEM;
		if (ret)
			dev_err(nv->dev, "cannot allocate a %llu MB ring%s (CMA too small? cma= kernel argument)\n",
				nv->ring_bytes >> 20, layout == NVREC_RING_SPLIT ? " A" : "");
	} else {
		ret = 0;
	}
	if (ret)
		goto err;
	if (nv->ring_bytes) {
		ring_pa = dma_to_phys(nv->dev, nv->ring_dma);
		if (nv->ring_ssd_ok && nvrec_ssd_addr(nv, ring_pa) != nv->ring_dma) {
			dev_err(nv->dev, "ring: fabric address 0x%llx and SSD address 0x%llx differ: unsupported address map\n",
				(u64)nv->ring_dma, nvrec_ssd_addr(nv, ring_pa));
			ret = -EIO;
			goto err;
		}
	}
	/* memory 1: the start of the reserved region, the same check */
	if (part1 && nv->ring_ssd_ok &&
	    nvrec_ssd_addr(nv, nv->cfg.ring1_phys) != nv->ring1_dma) {
		dev_err(nv->dev, "ring (memory 1): fabric address 0x%llx and SSD address 0x%llx differ: unsupported address map\n",
			(u64)nv->ring1_dma, nvrec_ssd_addr(nv, nv->cfg.ring1_phys));
		ret = -EIO;
		goto err;
	}

	nv->chunk = a.chunk;
	nv->slots = slots;
	nv->ring_layout = layout;
	nv->stripe_shift = shift;
	nv->ring1_used = part1;
	map.base0 = nv->ring_dma;
	map.base1 = nv->ring1_dma;
	map.layout = layout;
	map.shift = shift;

	/* PRP lists (memory 0): entries for pages 1..P-1 of every slot, each
	 * page where the address function puts it; a 4 KB list page holds
	 * 512 entries, longer lists chain through the last entry */
	n4k = a.chunk / NVREC_PAGE_SZ;
	nv->prp_shift = nvrec_prp_shift(a.chunk);
	per_list = 1u << nv->prp_shift;
	nv->prp_lists_bytes = n4k > 2 ? (size_t)nv->slots * per_list : 0;
	if (nv->prp_lists_bytes) {
		nv->prp_lists = dma_alloc_coherent(nv->dev, nv->prp_lists_bytes,
						   &nv->prp_lists_dma, GFP_KERNEL);
		if (!nv->prp_lists) {
			ret = -ENOMEM;
			goto err;
		}
		if (nv->ring_ssd_ok &&
		    nvrec_ssd_addr(nv, dma_to_phys(nv->dev, nv->prp_lists_dma)) !=
		    nv->prp_lists_dma) {
			ret = -EIO;
			goto err;
		}
		for (i = 0; i < nv->slots; i++)
			nvrec_prp_fill(nv->prp_lists + (size_t)i * per_list,
				       nv->prp_lists_dma + (u64)i * per_list, &map, i, a.chunk);
	}
	wmb();

	a.flags = layout;
	a.stripe_shift = shift;
	a.slots = nv->slots;
	a.dma_addr = nv->ring_dma;
	a.dma_addr1 = part1 ? nv->ring1_dma : 0;
	if (copy_to_user(uarg, &a, sizeof(a))) {
		ret = -EFAULT;
		goto err;
	}
	dev_dbg(nv->dev, "ring: %u slots x %u bytes, %s (stripe %u KB): memory 0 0x%llx + %llu MB (%s), memory 1 0x%llx + %llu MB, PRP lists 0x%llx%s\n",
		nv->slots, nv->chunk, nvrec_layout_name(layout), shift ? 1u << (shift - 10) : 0,
		(u64)nv->ring_dma, part0 >> 20, nv->ring_ours ? "CMA" : "user",
		(u64)(part1 ? nv->ring1_dma : 0), part1 >> 20,
		(u64)nv->prp_lists_dma, nv->ring_ssd_ok ? "" : ", no live SSD: DRY runs only");
	return 0;
err:
	nvrec_ring_free(nv);
	return ret;
}

static int nvrec_set_geometry(struct nvrec_dev *nv, struct nvrec_geometry __user *uarg)
{
	struct nvrec_geometry g;
	unsigned int j, k, shift = 0;

	if (copy_from_user(&g, uarg, sizeof(g)))
		return -EFAULT;
	if (nvrec_running(nv))
		return -EBUSY;
	if (!nv->chunk)
		return -ENXIO;		/* SET_RING first: the chunk size */
	if (g.flags & ~(NVREC_GEO_UNBOUNDED | NVREC_GEO_FUA))
		return -EINVAL;
	/* nr_members 0: no SSD, for fabric-only (DRY) runs (nvrec_start) */
	if (g.nr_members > NVREC_MAX_MEMBERS || g.nr_members > nv->cfg.nr_ssd)
		return -EINVAL;
	if (!g.length_chunks && !(g.flags & NVREC_GEO_UNBOUNDED))
		return -EINVAL;
	if (g.qd > nvrec_hw_max_qd())
		return -EINVAL;

	for (j = 0; j < g.nr_members; j++) {
		struct nvrec_member *m = &g.members[j];
		struct nvrec_ssd *s;
		u64 lpc, last, end;

		if (m->ssd >= nv->cfg.nr_ssd)
			return -EINVAL;
		for (k = 0; k < j; k++)
			if (g.members[k].ssd == m->ssd)
				return -EINVAL;
		s = nv->ssd[m->ssd];
		if (!s || s->dead || s->state != NVREC_SSD_LIVE)
			return -ENODEV;
		if (m->nsid != s->nsid)
			return -EINVAL;
		if (j && s->lba_shift != shift)
			return -EINVAL;		/* one LBA_SHIFT for all members */
		/* one NVMe command per chunk: the chunk must fit the drive's
		 * maximum data transfer size */
		if (s->mdts_bytes && nv->chunk > s->mdts_bytes) {
			dev_err(nv->dev,
				"chunk of %u bytes exceeds the maximum transfer size (MDTS) of %s (%u bytes): one NVMe command per chunk, use a chunk of at most %u bytes\n",
				nv->chunk, s->disk_name, s->mdts_bytes, s->mdts_bytes);
			return -EINVAL;
		}
		shift = s->lba_shift;
		if (nv->chunk & ((1u << shift) - 1))
			return -EINVAL;
		if (g.last_chunk_bytes & ((1u << shift) - 1) ||
		    g.last_chunk_bytes > nv->chunk)
			return -EINVAL;
		lpc = nv->chunk >> shift;
		if (!g.length_chunks)
			continue;
		/* last array chunk of the run that lands on member j */
		last = g.start_chunk + g.length_chunks - 1;
		k = (last % g.nr_members + g.nr_members - j) % g.nr_members;
		if (last < g.start_chunk + k)
			continue;		/* this member gets no chunk */
		last -= k;
		end = m->base_lba + (div_u64(last, g.nr_members) + 1) * lpc;
		if (end > s->nlba || end < m->base_lba) {
			dev_err(nv->dev, "member %u: run ends at LBA %llu, namespace has %llu\n",
				j, end, s->nlba);
			return -ERANGE;
		}
	}
	/* whole beats (an LBA is >= 512 bytes, so this holds for members) */
	if (g.last_chunk_bytes % nv->beat_bytes)
		return -EINVAL;
	nv->geo = g;
	nv->geo_valid = true;
	return 0;
}

static int nvrec_start(struct nvrec_dev *nv, struct nvrec_start __user *uarg, bool play)
{
	struct nvrec_start a;
	bool dry;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (a.flags & ~(NVREC_START_TPG | NVREC_START_CHECK | NVREC_START_DRY))
		return -EINVAL;
	dry = a.flags & NVREC_START_DRY;
	if (play && !(nv->caps & NVREC_CAP_PLAY))
		return -EOPNOTSUPP;
	if (dry && !(nv->caps & NVREC_CAP_DRY))
		return -EOPNOTSUPP;	/* register map < 1.2 */
	if (nvrec_running(nv))
		return -EBUSY;
	if (!nv->slots || !nv->geo_valid)
		return -ENXIO;
	if (play && !nv->geo.length_chunks)
		return -EINVAL;
	/* a ring in memory 1: never with CONFIG.SPLIT / MEM1 while it is down */
	if (nv->ring_layout != NVREC_RING_SINGLE && !nvrec_hw_mem1_ready(nv)) {
		dev_err(nv->dev, "%s ring: memory 1 is not ready (STATE.MEM1_READY = 0)\n",
			nvrec_layout_name(nv->ring_layout));
		return -EIO;
	}
	if (!dry) {
		/* NVMe runs: members, a ring checked against the SSDs' view */
		if (!nv->geo.nr_members)
			return -EINVAL;
		if (!nv->ring_ssd_ok) {
			dev_err(nv->dev, "the ring was set up while no SSD was live: set it up again\n");
			return -ENXIO;
		}
		if (nvrec_hw_ha_dead(nv))
			return -ENOLINK;
	}

	/* The hardware writes behind the block layer's back: commit and drop
	 * whatever the page cache of the member devices holds */
	nvrec_invalidate_members(nv, true);

	nv->run_dry = dry;	/* fabric only: a dead Host Accelerator does not end it */
	ret = nvrec_hw_start(nv, play, a.flags);
	if (ret)
		return ret;
	nv->start_ns = ktime_get_ns();
	nv->final_valid = false;
	nv->state = play ? NVREC_RUN_PLAY : NVREC_RUN_RECORD;

	a.first_seq = (a.flags & NVREC_START_TPG) ? 0 : nvrec_hw_seq_next(nv);
	a.start_time_ns = ktime_get_real_ns();
	if (copy_to_user(uarg, &a, sizeof(a)))
		return -EFAULT;		/* the run keeps going; STOP ends it */
	return 0;
}

static void nvrec_get_stats(struct nvrec_dev *nv, struct nvrec_stats *st)
{
	nvrec_update_state(nv);
	if (nv->final_valid && !nvrec_running(nv)) {
		*st = nv->final;
		return;
	}
	memset(st, 0, sizeof(*st));
	nvrec_hw_read_stats(nv, st);
	st->state = nv->state;
	if (nvrec_running(nv))
		st->elapsed_ns = ktime_get_ns() - nv->start_ns;
}

static int nvrec_wait(struct nvrec_dev *nv, struct nvrec_wait __user *uarg)
{
	struct nvrec_wait a;
	long t;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (a.timeout_ms) {
		mutex_unlock(&nv->lock);
		if (a.timeout_ms < 0) {
			/* the core interrupt wakes us; re-check every 100 ms
			 * in case it is not wired */
			do {
				t = wait_event_interruptible_timeout(nv->wq,
					nvrec_run_finished(nv), msecs_to_jiffies(100));
			} while (t == 0);
		} else {
			t = wait_event_interruptible_timeout(nv->wq,
				nvrec_run_finished(nv), msecs_to_jiffies(a.timeout_ms));
		}
		mutex_lock(&nv->lock);
		if (t < 0)
			return -EINTR;
	}
	nvrec_update_state(nv);
	a.state = nv->state;
	if (copy_to_user(uarg, &a, sizeof(a)))
		return -EFAULT;
	return nvrec_running(nv) ? -ETIMEDOUT : 0;
}

static void nvrec_fill_info(struct nvrec_dev *nv, struct nvrec_info *info)
{
	unsigned int i;

	memset(info, 0, sizeof(*info));
	info->api_version = NVREC_API_VERSION;
	info->hw_version = nv->hw_version;
	info->src_clk_hz = nv->src_clk_hz;
	info->dp_clk_hz = nv->dp_clk_hz;
	info->beat_bytes = nv->beat_bytes;
	info->fifo_depth = nv->fifo_depth;
	info->egr_fifo_depth = nv->egr_fifo_depth;
	info->caps = nv->caps;
	info->nr_ssd = nv->cfg.nr_ssd;
	info->min_chunk = NVREC_MIN_CHUNK;
	info->max_chunk = NVREC_MAX_CHUNK;
	info->max_slots = nv->cfg.max_slots;
	info->max_qd = nvrec_hw_max_qd();
	info->lat_bin0_log2 = nvrec_hw_lat_bin0_log2();
	info->status = nvrec_hw_ha_dead(nv) ? NVREC_STATUS_HA_DEAD : 0;
	info->ring_ports = nv->ring_ports;
	if (nv->caps & NVREC_CAP_SPLIT_RING) {
		info->ring1_base = nv->ring1_dma;
		info->ring1_bytes = nv->cfg.ring1_size;
		if (!nvrec_hw_mem1_ready(nv))
			info->status |= NVREC_STATUS_MEM1_DOWN;
	}
	info->ring_default = nvrec_ring_default(nv, 2) | (nvrec_ring_default(nv, 1) << 8);
	info->stripe_shift = nvrec_stripe_default(nv);

	mutex_lock(&nv->ssd_lock);
	for (i = 0; i < nv->cfg.nr_ssd; i++) {
		struct nvrec_ssd_info *d = &info->ssd[i];
		struct nvrec_ssd *s = nv->ssd[i];

		d->index = i;
		if (!s) {
			d->state = NVREC_SSD_ABSENT;
			continue;
		}
		d->state = s->dead ? NVREC_SSD_FAILED : s->state;
		d->nsid = s->nsid;
		d->lba_shift = s->lba_shift;
		d->nlba = s->nlba;
		d->mdts_bytes = s->mdts_bytes;
		d->io_path = s->io_path;
		d->nr_io_queues = s->nr_io_queues;
		d->hw_queues = s->hw_queues;
		d->sw_queues = s->sw_queues;
		d->sq_depth = nv->cfg.sq_depth;
		d->vwc = s->vwc;
		d->dsm = s->dsm;
		strscpy(d->disk, s->disk_name, sizeof(d->disk));
		strscpy(d->model, s->model, sizeof(d->model));
		strscpy(d->serial, s->serial, sizeof(d->serial));
		strscpy(d->firmware, s->firmware, sizeof(d->firmware));
		strscpy(d->pci, pci_name(s->pdev), sizeof(d->pci));
		if (s->mdts_bytes && s->mdts_bytes < info->max_chunk)
			info->max_chunk = s->mdts_bytes;
	}
	mutex_unlock(&nv->ssd_lock);
}

/* ------------------------------------------------------------------------ */
/* /dev/nvrec                                                               */

static long nvrec_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct nvrec_dev *nv = f->private_data;
	void __user *uarg = (void __user *)arg;
	int ret = 0;

	mutex_lock(&nv->lock);
	switch (cmd) {
	case NVREC_IOC_GET_INFO: {
		struct nvrec_info *info = kmalloc(sizeof(*info), GFP_KERNEL);

		if (!info) {
			ret = -ENOMEM;
			break;
		}
		nvrec_fill_info(nv, info);
		if (copy_to_user(uarg, info, sizeof(*info)))
			ret = -EFAULT;
		kfree(info);
		break;
	}
	case NVREC_IOC_SET_RING:
		ret = nvrec_set_ring(nv, uarg);
		break;
	case NVREC_IOC_SET_GEOMETRY:
		ret = nvrec_set_geometry(nv, uarg);
		break;
	case NVREC_IOC_RECORD_START:
		ret = nvrec_start(nv, uarg, false);
		break;
	case NVREC_IOC_PLAY_START:
		ret = nvrec_start(nv, uarg, true);
		break;
	case NVREC_IOC_WAIT:
		ret = nvrec_wait(nv, uarg);
		break;
	case NVREC_IOC_GET_STATS:
	case NVREC_IOC_STOP:
	case NVREC_IOC_ABORT: {
		struct nvrec_stats st;

		if (cmd != NVREC_IOC_GET_STATS) {
			nvrec_update_state(nv);
			nvrec_stop_run(nv, cmd == NVREC_IOC_ABORT);
		}
		nvrec_get_stats(nv, &st);
		if (copy_to_user(uarg, &st, sizeof(st)))
			ret = -EFAULT;
		break;
	}
	case NVREC_IOC_SET_RATE:
	case NVREC_IOC_SET_SINK_RATE: {
		struct nvrec_rate r;

		if (copy_from_user(&r, uarg, sizeof(r))) {
			ret = -EFAULT;
			break;
		}
		if (cmd == NVREC_IOC_SET_RATE) {
			r.rate_bps = nvrec_hw_rate_set(nv, r.rate_bps);
		} else {
			if (!r.rate_bps) {
				ret = -EINVAL;
				break;
			}
			r.rate_bps = nvrec_hw_sink_rate_set(nv, r.rate_bps);
		}
		if (copy_to_user(uarg, &r, sizeof(r)))
			ret = -EFAULT;
		break;
	}
	default:
		ret = -ENOTTY;
	}
	mutex_unlock(&nv->lock);
	return ret;
}

static int nvrec_open(struct inode *inode, struct file *f)
{
	struct miscdevice *misc = f->private_data;
	struct nvrec_dev *nv = container_of(misc, struct nvrec_dev, misc);
	int ret = 0;

	mutex_lock(&nv->lock);
	if (nv->in_use)
		ret = -EBUSY;
	else
		nv->in_use = true;
	mutex_unlock(&nv->lock);
	if (ret)
		return ret;
	f->private_data = nv;
	return nonseekable_open(inode, f);
}

static int nvrec_release(struct inode *inode, struct file *f)
{
	struct nvrec_dev *nv = f->private_data;

	mutex_lock(&nv->lock);
	nvrec_update_state(nv);
	nvrec_stop_run(nv, true);
	nvrec_ring_free(nv);
	nv->in_use = false;
	mutex_unlock(&nv->lock);
	return 0;
}

/* POLLIN once the run has finished (done, error, stopped) */
static __poll_t nvrec_poll(struct file *f, struct poll_table_struct *wait)
{
	struct nvrec_dev *nv = f->private_data;
	__poll_t mask = 0;

	poll_wait(f, &nv->wq, wait);
	if (nvrec_run_finished(nv))
		mask |= EPOLLIN | EPOLLRDNORM;
	return mask;
}

static const struct file_operations nvrec_fops = {
	.owner = THIS_MODULE,
	.open = nvrec_open,
	.release = nvrec_release,
	.poll = nvrec_poll,
	.unlocked_ioctl = nvrec_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
};

/* ------------------------------------------------------------------------ */
/* sysfs: /sys/class/misc/nvrec/<attr>                                      */

static struct nvrec_dev *to_nv(struct device *dev)
{
	struct miscdevice *misc = dev_get_drvdata(dev);

	return container_of(misc, struct nvrec_dev, misc);
}

#define NVREC_STAT_ATTR(_name, _expr)					\
static ssize_t _name##_show(struct device *dev,				\
			    struct device_attribute *attr, char *buf)	\
{									\
	struct nvrec_dev *nv = to_nv(dev);				\
	struct nvrec_stats st;						\
	mutex_lock(&nv->lock);						\
	nvrec_get_stats(nv, &st);					\
	mutex_unlock(&nv->lock);					\
	return sysfs_emit(buf, "%llu\n", (unsigned long long)(_expr));	\
}									\
static DEVICE_ATTR_RO(_name)

NVREC_STAT_ATTR(state, st.state);
NVREC_STAT_ATTR(hw_state, st.hw_state);
NVREC_STAT_ATTR(drop_count, st.drop_count);
NVREC_STAT_ATTR(beats_in, st.beats_in);
NVREC_STAT_ATTR(beats_out, st.beats_out);
NVREC_STAT_ATTR(seq_next, st.seq_next);
NVREC_STAT_ATTR(chunks_filled, st.chunks_filled);
NVREC_STAT_ATTR(cmds_issued, st.cmds_issued);
NVREC_STAT_ATTR(cmds_done, st.cmds_done);
NVREC_STAT_ATTR(cmd_errors, st.cmd_errors);
NVREC_STAT_ATTR(unexpected_cqes, st.unexpected_cqes);
NVREC_STAT_ATTR(bytes, st.bytes);
NVREC_STAT_ATTR(err_last_status, st.err_last_status);
NVREC_STAT_ATTR(ring_fill, st.ring_fill);
NVREC_STAT_ATTR(ring_hwm, st.ring_hwm);
NVREC_STAT_ATTR(ring_full_cycles, st.ring_full_cycles);
NVREC_STAT_ATTR(fifo_hwm, st.fifo_hwm);
NVREC_STAT_ATTR(overflow, st.overflow);
NVREC_STAT_ATTR(lat_min_cycles, st.lat_count ? st.lat_min : 0);
NVREC_STAT_ATTR(lat_max_cycles, st.lat_max);
NVREC_STAT_ATTR(lat_avg_cycles, st.lat_count ? div64_u64(st.lat_sum, st.lat_count) : 0);
/* register map 1.3: which memory held the run up (dp_clk cycles, saturating) */
NVREC_STAT_ATTR(wr_port_stall0, st.wr_port_stall[0]);
NVREC_STAT_ATTR(wr_port_stall1, st.wr_port_stall[1]);
NVREC_STAT_ATTR(rd_port_wait0, st.rd_port_wait[0]);
NVREC_STAT_ATTR(rd_port_wait1, st.rd_port_wait[1]);

/* live, not the last run's snapshot: asks nvrec_core (never the IP) */
static ssize_t ha_dead_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", nvrec_hw_ha_dead(to_nv(dev)));
}
static DEVICE_ATTR_RO(ha_dead);

#define NVREC_RO_ATTR(_name, _fmt, ...)					\
static ssize_t _name##_show(struct device *dev,				\
			    struct device_attribute *attr, char *buf)	\
{									\
	struct nvrec_dev *nv = to_nv(dev);				\
	return sysfs_emit(buf, _fmt "\n", __VA_ARGS__);			\
}									\
static DEVICE_ATTR_RO(_name)

NVREC_RO_ATTR(src_clk_hz, "%u", nv->src_clk_hz);
NVREC_RO_ATTR(dp_clk_hz, "%u", nv->dp_clk_hz);
NVREC_RO_ATTR(fifo_depth, "%u", nv->fifo_depth);
NVREC_RO_ATTR(egr_fifo_depth, "%u", nv->egr_fifo_depth);
NVREC_RO_ATTR(beat_bytes, "%u", nv->beat_bytes);
NVREC_RO_ATTR(version, "%u.%u", nv->hw_version >> 16, nv->hw_version & 0xffff);
NVREC_RO_ATTR(ring_slots, "%u", nv->slots);
NVREC_RO_ATTR(chunk_bytes, "%u", nv->chunk);
NVREC_RO_ATTR(max_slots, "%u", nv->cfg.max_slots);
/* split ring: the design (ring_ports, the memory-1 region) and the ring
 * set up now (ring_split: single / split / mem1 / none, its stripe) */
NVREC_RO_ATTR(ring_ports, "%u", nv->ring_ports);
NVREC_RO_ATTR(ring1_base, "0x%llx", (nv->caps & NVREC_CAP_SPLIT_RING) ? (u64)nv->ring1_dma : 0ull);
NVREC_RO_ATTR(ring1_bytes, "%llu", (nv->caps & NVREC_CAP_SPLIT_RING) ? nv->cfg.ring1_size : 0ull);
NVREC_RO_ATTR(ring_split, "%s", nvrec_layout_name(nv->ring_layout));
NVREC_RO_ATTR(ring_stripe_kb, "%u", nv->stripe_shift ? 1u << (nv->stripe_shift - 10) : 0);

/* the default stripe of a split ring: "chunk" or the KB (module parameter
 * stripe_kb, device tree), before the cap at the chunk */
static ssize_t ring_stripe_default_show(struct device *dev, struct device_attribute *attr,
					char *buf)
{
	u32 shift = nvrec_stripe_default(to_nv(dev));

	if (shift == NVREC_STRIPE_SHIFT_CHUNK)
		return sysfs_emit(buf, "chunk\n");
	return sysfs_emit(buf, "%u\n", 1u << (shift - 10));
}
static DEVICE_ATTR_RO(ring_stripe_default);

/* live: memory 1 usable (STATE.MEM1_READY; 0 without a second ring port) */
static ssize_t mem1_ready_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", nvrec_hw_mem1_ready(to_nv(dev)));
}
static DEVICE_ATTR_RO(mem1_ready);

static ssize_t lat_hist_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct nvrec_dev *nv = to_nv(dev);
	struct nvrec_stats st;
	int k, len = 0;

	mutex_lock(&nv->lock);
	nvrec_get_stats(nv, &st);
	mutex_unlock(&nv->lock);
	for (k = 0; k < NVREC_LAT_BINS; k++)
		len += sysfs_emit_at(buf, len, "%s%u", k ? " " : "", st.lat_hist[k]);
	return len + sysfs_emit_at(buf, len, "\n");
}
static DEVICE_ATTR_RO(lat_hist);

/* log2 of the width of latency histogram bin 0 (dp_clk cycles) */
static ssize_t lat_bin0_log2_show(struct device *dev, struct device_attribute *attr,
				  char *buf)
{
	return sysfs_emit(buf, "%u\n", nvrec_hw_lat_bin0_log2());
}
static DEVICE_ATTR_RO(lat_bin0_log2);

/* per SSD: highest commands in flight (SSD_INFLIGHT_HWM, cleared at
 * SET_GEOMETRY), of the running or the last run like the other stats */
#define NVREC_SSD_HWM_ATTR(_n)						\
static ssize_t ssd##_n##_inflight_hwm_show(struct device *dev,		\
		struct device_attribute *attr, char *buf)		\
{									\
	struct nvrec_dev *nv = to_nv(dev);				\
	struct nvrec_stats st;						\
	mutex_lock(&nv->lock);						\
	nvrec_get_stats(nv, &st);					\
	mutex_unlock(&nv->lock);					\
	return sysfs_emit(buf, "%u\n", st.ssd[_n].inflight_hwm);	\
}									\
static DEVICE_ATTR_RO(ssd##_n##_inflight_hwm)

NVREC_SSD_HWM_ATTR(0);
NVREC_SSD_HWM_ATTR(1);
NVREC_SSD_HWM_ATTR(2);
NVREC_SSD_HWM_ATTR(3);
static_assert(NVREC_MAX_SSD == 4);

/* per SSD: "ssdN <issued> <completed> <errors>" of the IP's statistics */
static ssize_t ha_counters_show(struct device *dev, struct device_attribute *attr,
				char *buf)
{
	struct nvrec_dev *nv = to_nv(dev);
	unsigned int n;
	int len = 0;

	for (n = 0; n < nv->cfg.nr_ssd; n++)
		len += sysfs_emit_at(buf, len, "ssd%u %u %u %u\n", n,
				     nvrec_hw_ha_counter(nv, n, 0),
				     nvrec_hw_ha_counter(nv, n, 1),
				     nvrec_hw_ha_counter(nv, n, 2));
	return len;
}
static DEVICE_ATTR_RO(ha_counters);

static ssize_t rate_bps_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	return sysfs_emit(buf, "%llu\n", nvrec_hw_rate_get(to_nv(dev)));
}

static ssize_t rate_bps_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	u64 v;
	int ret = kstrtou64(buf, 0, &v);

	if (ret)
		return ret;
	nvrec_hw_rate_set(to_nv(dev), v);
	return count;
}
static DEVICE_ATTR_RW(rate_bps);

static ssize_t tpg_enable_show(struct device *dev, struct device_attribute *attr,
			       char *buf)
{
	return sysfs_emit(buf, "%u\n", nvrec_hw_tpg_enabled(to_nv(dev)));
}

static ssize_t tpg_enable_store(struct device *dev, struct device_attribute *attr,
				const char *buf, size_t count)
{
	bool on;
	int ret = kstrtobool(buf, &on);

	if (ret)
		return ret;
	nvrec_hw_tpg_enable(to_nv(dev), on);
	return count;
}
static DEVICE_ATTR_RW(tpg_enable);

static struct attribute *nvrec_attrs[] = {
	&dev_attr_state.attr,
	&dev_attr_hw_state.attr,
	&dev_attr_drop_count.attr,
	&dev_attr_beats_in.attr,
	&dev_attr_beats_out.attr,
	&dev_attr_seq_next.attr,
	&dev_attr_chunks_filled.attr,
	&dev_attr_cmds_issued.attr,
	&dev_attr_cmds_done.attr,
	&dev_attr_cmd_errors.attr,
	&dev_attr_unexpected_cqes.attr,
	&dev_attr_bytes.attr,
	&dev_attr_err_last_status.attr,
	&dev_attr_ring_fill.attr,
	&dev_attr_ring_hwm.attr,
	&dev_attr_ring_full_cycles.attr,
	&dev_attr_fifo_hwm.attr,
	&dev_attr_fifo_depth.attr,
	&dev_attr_egr_fifo_depth.attr,
	&dev_attr_beat_bytes.attr,
	&dev_attr_overflow.attr,
	&dev_attr_ha_dead.attr,
	&dev_attr_lat_min_cycles.attr,
	&dev_attr_lat_max_cycles.attr,
	&dev_attr_lat_avg_cycles.attr,
	&dev_attr_wr_port_stall0.attr,
	&dev_attr_wr_port_stall1.attr,
	&dev_attr_rd_port_wait0.attr,
	&dev_attr_rd_port_wait1.attr,
	&dev_attr_lat_hist.attr,
	&dev_attr_lat_bin0_log2.attr,
	&dev_attr_ssd0_inflight_hwm.attr,
	&dev_attr_ssd1_inflight_hwm.attr,
	&dev_attr_ssd2_inflight_hwm.attr,
	&dev_attr_ssd3_inflight_hwm.attr,
	&dev_attr_ha_counters.attr,
	&dev_attr_src_clk_hz.attr,
	&dev_attr_dp_clk_hz.attr,
	&dev_attr_version.attr,
	&dev_attr_ring_slots.attr,
	&dev_attr_chunk_bytes.attr,
	&dev_attr_max_slots.attr,
	&dev_attr_ring_ports.attr,
	&dev_attr_ring1_base.attr,
	&dev_attr_ring1_bytes.attr,
	&dev_attr_ring_split.attr,
	&dev_attr_ring_stripe_kb.attr,
	&dev_attr_ring_stripe_default.attr,
	&dev_attr_mem1_ready.attr,
	&dev_attr_rate_bps.attr,
	&dev_attr_tpg_enable.attr,
	NULL,
};

/* ssdN_inflight_hwm only for the SSD slots of the IP */
static umode_t nvrec_attr_visible(struct kobject *kobj, struct attribute *a, int i)
{
	struct nvrec_dev *nv = to_nv(kobj_to_dev(kobj));
	static struct attribute *const hwm[] = {
		&dev_attr_ssd0_inflight_hwm.attr, &dev_attr_ssd1_inflight_hwm.attr,
		&dev_attr_ssd2_inflight_hwm.attr, &dev_attr_ssd3_inflight_hwm.attr,
	};
	unsigned int n;

	for (n = 0; n < ARRAY_SIZE(hwm); n++)
		if (a == hwm[n])
			return n < nv->cfg.nr_ssd ? a->mode : 0;
	return a->mode;
}

static const struct attribute_group nvrec_group = {
	.attrs = nvrec_attrs,
	.is_visible = nvrec_attr_visible,
};
__ATTRIBUTE_GROUPS(nvrec);

/* ------------------------------------------------------------------------ */
/* Platform driver                                                          */

static int nvrec_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct nvrec_dev *nv;
	unsigned int i;
	char ring[128], sbuf[16];
	int ret, id;

	nv = devm_kzalloc(dev, sizeof(*nv), GFP_KERNEL);
	if (!nv)
		return -ENOMEM;
	nv->dev = dev;
	spin_lock_init(&nv->reg_lock);
	spin_lock_init(&nv->inj_lock);
	mutex_init(&nv->ssd_lock);
	mutex_init(&nv->lock);
	init_waitqueue_head(&nv->wq);
	INIT_WORK(&nv->ha_dead_work, nvrec_ha_dead_work);
	nv->state = NVREC_RUN_IDLE;

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (ret)
		return ret;
	ret = nvrec_hw_probe(nv);
	if (ret)
		return ret;
	/* memory 1 as the fabric (and, checked at SET_RING, the SSDs) see it */
	if (nv->caps & NVREC_CAP_SPLIT_RING)
		nv->ring1_dma = phys_to_dma(dev, nv->cfg.ring1_phys);

	for (i = 0; i < nv->cfg.nr_ssd; i++)
		nv->port_np[i] = of_parse_phandle(dev->of_node, "opsero,ssd-ports", i);
	if (!nv->port_np[0])
		dev_warn(dev, "no \"opsero,ssd-ports\": no SSD will be claimed\n");

	ret = nvrec_hw_ha_init(nv);
	if (ret)
		goto err_np;

	id = ida_alloc(&nvrec_ida, GFP_KERNEL);
	if (id < 0) {
		ret = id;
		goto err_np;
	}
	nv->id = id;
	if (id)
		snprintf(nv->name, sizeof(nv->name), NVREC_DEV_NAME "%d", id);
	else
		strscpy(nv->name, NVREC_DEV_NAME, sizeof(nv->name));
	nv->misc.minor = MISC_DYNAMIC_MINOR;
	nv->misc.name = nv->name;
	nv->misc.fops = &nvrec_fops;
	nv->misc.parent = dev;
	nv->misc.groups = nvrec_groups;
	ret = misc_register(&nv->misc);
	if (ret)
		goto err_ida;

	platform_set_drvdata(pdev, nv);
	mutex_lock(&nvrec_list_lock);
	list_add_tail(&nv->node_list, &nvrec_list);
	mutex_unlock(&nvrec_list_lock);

	if (nv->caps & NVREC_CAP_SPLIT_RING)
		snprintf(ring, sizeof(ring), "ring ports %u, mem1 0x%llx %llu MB%s, default ring %s, stripe %s",
			 nv->ring_ports, (u64)nv->ring1_dma, nv->cfg.ring1_size >> 20,
			 nvrec_hw_mem1_ready(nv) ? "" : " NOT READY (STATE.MEM1_READY = 0)",
			 nvrec_layout_name(nvrec_ring_default(nv, 2)),
			 nvrec_stripe_name(nvrec_stripe_default(nv), sbuf, sizeof(sbuf)));
	else
		snprintf(ring, sizeof(ring), "ring ports %u%s, single ring", nv->ring_ports,
			 nv->ring_ports > 1 ? " but no memory-1 region (memory-region)" : "");
	dev_info(dev, "/dev/%s: driver %s, nvrec_core v%u.%u, src_clk %u Hz, dp_clk %u Hz, beat %u bytes, FIFO %u/%u beats (ingest/egress), %u ring slots%s, %s; nvmeha: %u SSDs x %u queues (SQ window 0x%llx, CQ window 0x%llx)%s\n",
		 nv->name, NVREC_DRV_VERSION, nv->hw_version >> 16, nv->hw_version & 0xffff,
		 nv->src_clk_hz, nv->dp_clk_hz, nv->beat_bytes, nv->fifo_depth,
		 nv->egr_fifo_depth, nv->cfg.max_slots,
		 (nv->caps & NVREC_CAP_DRY) ? ", DRY" : "", ring,
		 nv->cfg.nr_ssd, nv->cfg.max_sq, nv->cfg.sq_base, nv->cfg.cq_base,
		 ", hardware queues, CPU I/O via the injector");
	return 0;

err_ida:
	ida_free(&nvrec_ida, nv->id);
err_np:
	for (i = 0; i < NVREC_MAX_SSD; i++)
		of_node_put(nv->port_np[i]);
	nvrec_hw_remove(nv);
	cancel_work_sync(&nv->ha_dead_work);
	return ret;
}

/* Unbind the SSDs from this instance before the hardware goes */
void nvrec_ssd_detach_all(struct nvrec_dev *nv)
{
	unsigned int i;

	for (i = 0; i < NVREC_MAX_SSD; i++) {
		struct pci_dev *pdev = NULL;

		mutex_lock(&nv->ssd_lock);
		if (nv->ssd[i])
			pdev = pci_dev_get(nv->ssd[i]->pdev);
		mutex_unlock(&nv->ssd_lock);
		if (pdev) {
			device_release_driver(&pdev->dev);
			pci_dev_put(pdev);
		}
	}
}

static void nvrec_remove(struct platform_device *pdev)
{
	struct nvrec_dev *nv = platform_get_drvdata(pdev);
	unsigned int i;

	mutex_lock(&nvrec_list_lock);
	list_del(&nv->node_list);
	mutex_unlock(&nvrec_list_lock);
	misc_deregister(&nv->misc);
	nvrec_ssd_detach_all(nv);
	mutex_lock(&nv->lock);
	nvrec_stop_run(nv, true);
	nvrec_ring_free(nv);
	mutex_unlock(&nv->lock);
	nvrec_hw_remove(nv);
	cancel_work_sync(&nv->ha_dead_work);
	for (i = 0; i < NVREC_MAX_SSD; i++)
		of_node_put(nv->port_np[i]);
	ida_free(&nvrec_ida, nv->id);
}

static const struct of_device_id nvrec_of_match[] = {
	{ .compatible = "opsero,nvrec" },
	{ }
};
MODULE_DEVICE_TABLE(of, nvrec_of_match);

static struct platform_driver nvrec_platform_driver = {
	.driver = {
		.name = "nvrec",
		.of_match_table = nvrec_of_match,
	},
	.probe = nvrec_probe,
	.remove = nvrec_remove,
};

static int __init nvrec_init(void)
{
	int ret = platform_driver_register(&nvrec_platform_driver);

	if (ret)
		return ret;
	ret = nvrec_nvme_register();
	if (ret)
		platform_driver_unregister(&nvrec_platform_driver);
	return ret;
}

static void __exit nvrec_exit(void)
{
	nvrec_nvme_unregister();
	platform_driver_unregister(&nvrec_platform_driver);
}

module_init(nvrec_init);
module_exit(nvrec_exit);

MODULE_AUTHOR("Opsero Electronic Design Inc.");
MODULE_DESCRIPTION("FPGA Drive NVMe-offload recorder: NVMe Host Accelerator host driver, block devices and hardware recorder control");
MODULE_LICENSE("Dual MIT/GPL");
MODULE_VERSION(NVREC_DRV_VERSION);
