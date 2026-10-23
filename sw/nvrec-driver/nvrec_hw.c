// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * nvrec_hw.c -- every register access of the nvrec driver: the nvrec_core
 * block (test pattern generator, ingest, ring writer/reader, command
 * builder, CPU command injector, statistics, checker) and the AMD NVMe Host
 * Accelerator (nvmeha, PG328) register space and software queue window.
 * The register map is include/nvrec_regs.h (docs/source/register_map.md).
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Host Accelerator configuration (register map 1.0 rev b): HARDWARE-ONLY
 * queues. Each SSD has ONE hardware SQ/CQ pair in the IP (NVMe QID 1), fed
 * by the command builder (recording/playback) and by the CPU command
 * injector (every CPU I/O: block device, filesystem), at most
 * NVREC_INJ_CQ_FIFO_DEPTH injected commands outstanding in total. The IP's
 * software queue interface (S_AXI) is not built in.
 *
 * Datapath width (register map 1.2): BEAT_BYTES (16, 32 or 64) is read at
 * probe (0 on a 1.0/1.1 bitstream = its 128-bit datapath, 16) and used for
 * the source/sink rate conversion; every beat counter is in those beats.
 * CONFIG.DRY (1.2) runs the fabric side only: no NVMe command is built.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/iopoll.h>
#include <linux/math64.h>
#include <linux/delay.h>

#include "nvrec.h"
#include "nvrec_regs.h"

#if NVREC_NVMEHA_NUM_SSD > NVREC_MAX_SSD
#error "nvrec_regs.h has more SSDs than the uapi reports"
#endif

static unsigned int ha_timeout_ms = 2000;
module_param(ha_timeout_ms, uint, 0444);
MODULE_PARM_DESC(ha_timeout_ms, "nvmeha SSD response-timeout status interval (ms, 0 = off)");

static unsigned int play_prefill_ms = 2000;
module_param(play_prefill_ms, uint, 0644);
MODULE_PARM_DESC(play_prefill_ms, "playback with the checker: wait up to this long for the ring to fill before the sink is enabled (ms, 0 = no prefill)");

static unsigned int stop_timeout_ms = 5000;
module_param(stop_timeout_ms, uint, 0644);
MODULE_PARM_DESC(stop_timeout_ms, "time allowed for the commands in flight to complete at stop/abort (ms)");

/* ------------------------------------------------------------------------ */

static inline u32 core_rd(struct nvrec_dev *nv, u32 off)
{
	return ioread32(nv->core + off);
}

static inline void core_wr(struct nvrec_dev *nv, u32 off, u32 v)
{
	iowrite32(v, nv->core + off);
}

/* 64-bit counter: reading LO latches HI */
static u64 core_rd64(struct nvrec_dev *nv, u32 lo)
{
	unsigned long flags;
	u32 l, h;

	spin_lock_irqsave(&nv->reg_lock, flags);
	l = core_rd(nv, lo);
	h = core_rd(nv, lo + 4);
	spin_unlock_irqrestore(&nv->reg_lock, flags);
	return ((u64)h << 32) | l;
}

static inline void core_wr64(struct nvrec_dev *nv, u32 lo, u64 v)
{
	core_wr(nv, lo, lower_32_bits(v));
	core_wr(nv, lo + 4, upper_32_bits(v));
}

/*
 * Host Accelerator registers. Register map 1.1 puts an AXI-Lite timeout guard
 * in front of them: once the evaluation-licensed core has stopped, a read
 * returns 0xFFFF_FFFF (OKAY) after ~164 us instead of hanging the CPU, and
 * nvrec_core reports STATE.HA_DEAD. After that the IP is never touched again.
 * Nothing periodic reads these registers (statistics come from nvrec_core).
 */
static u32 ha_rd(struct nvrec_dev *nv, u32 off)
{
	u32 v;

	if (nvrec_ha_is_dead(nv))
		return ~0u;
	v = ioread32(nv->ha + off);
	if (unlikely(v == ~0u))
		nvrec_hw_ha_dead(nv);	/* the guard's answer, or a real all-ones */
	return v;
}

static void ha_wr(struct nvrec_dev *nv, u32 off, u32 v)
{
	if (!nvrec_ha_is_dead(nv))
		iowrite32(v, nv->ha + off);
}

static bool hw_has_guard(struct nvrec_dev *nv)
{
	return nv->hw_version >= NVREC_VERSION_1_1;
}

/* register map 1.2: BEAT_BYTES register, CONFIG.DRY */
static bool hw_is_1_2(struct nvrec_dev *nv)
{
	return nv->hw_version >= NVREC_VERSION_1_2;
}

/* Latch "Host Accelerator dead": log once, stop touching it, disable the
 * SSDs from process context (no NVMe I/O is possible any more), wake the
 * run waiters so a recording fails at once. Any context. */
void nvrec_hw_mark_ha_dead(struct nvrec_dev *nv)
{
	if (test_and_set_bit(NVREC_HA_DEAD_BIT, &nv->ha_flags))
		return;
	dev_err(nv->dev,
		"Host Accelerator stopped responding (evaluation license expired?): NVMe I/O stopped; reload the bitstream (power-cycle the board) to continue\n");
	if (nv->irq_ha > 0)
		disable_irq_nosync(nv->irq_ha);
	schedule_work(&nv->ha_dead_work);
	wake_up_interruptible_all(&nv->wq);
}

/* Is the Host Accelerator dead? Asks nvrec_core (never the IP itself). */
bool nvrec_hw_ha_dead(struct nvrec_dev *nv)
{
	if (nvrec_ha_is_dead(nv))
		return true;
	if (hw_has_guard(nv) && (core_rd(nv, NVREC_STATE) & NVREC_STATE_HA_DEAD)) {
		nvrec_hw_mark_ha_dead(nv);
		return true;
	}
	return false;
}

static inline u32 qidx(struct nvrec_dev *nv, unsigned int ssd, unsigned int q)
{
	return ssd * nv->cfg.max_sq + q;
}

/* ------------------------------------------------------------------------ */
/* Configuration                                                            */

static void cfg_u32_array(struct device_node *np, const char *prop, u32 *dst,
			  unsigned int n)
{
	int cnt = of_property_count_u32_elems(np, prop);

	if (cnt <= 0)
		return;
	of_property_read_u32_array(np, prop, dst, min_t(unsigned int, cnt, n));
	if (cnt == 1)		/* one value for every SSD */
		while (--n)
			dst[n] = dst[0];
}

static int nvrec_hw_read_cfg(struct nvrec_dev *nv)
{
	struct device_node *np = nv->dev->of_node;
	struct nvrec_ha_cfg *c = &nv->cfg;
	unsigned int i;
	u64 v64;
	u32 v;

	c->nr_ssd = NVREC_NVMEHA_NUM_SSD;
	c->max_sq = NVREC_NVMEHA_NUM_SQ;
	for (i = 0; i < NVREC_MAX_SSD; i++) {
		c->nsw[i] = NVREC_NVMEHA_NUM_SW_SQ;
		c->nhw[i] = NVREC_NVMEHA_NUM_HW_SQ;
	}
	c->sq_depth = NVREC_NVMEHA_SQ_DEPTH;
	c->sq_base = NVREC_QWIN_SQ_BASE;
	c->cq_base = NVREC_QWIN_CQ_BASE;
	c->bar_offset = 0;

	/* Device-tree overrides (docs/source/driver.md, "Device tree"):
	 * for an IP rebuilt with other parameters, without recompiling */
	if (!of_property_read_u32(np, "opsero,ha-num-ssd", &v))
		c->nr_ssd = v;
	if (!of_property_read_u32(np, "opsero,ha-num-sq", &v))
		c->max_sq = v;
	cfg_u32_array(np, "opsero,ha-sw-queues", c->nsw, NVREC_MAX_SSD);
	cfg_u32_array(np, "opsero,ha-hw-queues", c->nhw, NVREC_MAX_SSD);
	if (!of_property_read_u32(np, "opsero,ha-sq-depth", &v))
		c->sq_depth = v;
	if (!of_property_read_u64(np, "opsero,ha-sq-base", &v64))
		c->sq_base = v64;
	if (!of_property_read_u64(np, "opsero,ha-cq-base", &v64))
		c->cq_base = v64;
	if (!of_property_read_u64(np, "opsero,ha-bar-offset", &v64))
		c->bar_offset = (s64)v64;

	if (!c->nr_ssd || c->nr_ssd > NVREC_MAX_SSD)
		return dev_err_probe(nv->dev, -EINVAL, "nvmeha: %u SSDs, driver supports 1..%u\n",
				     c->nr_ssd, NVREC_MAX_SSD);
	if (c->max_sq != 1 && c->max_sq != 2 && c->max_sq != 4)
		return dev_err_probe(nv->dev, -EINVAL, "nvmeha: C_MAX_SQ %u invalid\n", c->max_sq);
	for (i = 0; i < c->nr_ssd; i++) {
		if (c->nsw[i] + c->nhw[i] > c->max_sq || !c->nhw[i])
			return dev_err_probe(nv->dev, -EINVAL,
					     "nvmeha: SSD%u has %u SW + %u HW queues (C_MAX_SQ %u, >= 1 HW queue needed)\n",
					     i, c->nsw[i], c->nhw[i], c->max_sq);
		if (c->nsw[i])
			return dev_err_probe(nv->dev, -EINVAL,
					     "nvmeha: SSD%u has %u software queues: this build has no software queue interface (opsero,ha-sw-queues = <0>)\n",
					     i, c->nsw[i]);
	}
	if (c->sq_depth != 32 && c->sq_depth != 64)
		return dev_err_probe(nv->dev, -EINVAL, "nvmeha: SQ depth must be 32 or 64\n");
	/* The IP's queue base registers hold bits [31:12] only */
	if ((c->sq_base | c->cq_base) & ~(u64)0xFFFFF000u)
		return dev_err_probe(nv->dev, -EINVAL,
				     "nvmeha: queue window 0x%llx/0x%llx must be 4 KB aligned and below 4 GB\n",
				     c->sq_base, c->cq_base);
	/* injector CQE FIFO shared by all SSDs */
	c->inj_depth = max_t(u32, 1, NVREC_INJ_CQ_FIFO_DEPTH / c->nr_ssd);
	return 0;
}

/* ------------------------------------------------------------------------ */
/* Interrupts                                                               */

/* ha_interrupt: error status only (no software queues, so no CQ-available) */
static irqreturn_t nvrec_ha_irq(int irq, void *data)
{
	struct nvrec_dev *nv = data;
	u32 st;

	if (nvrec_hw_ha_dead(nv)) {
		disable_irq_nosync(irq);
		return IRQ_HANDLED;
	}
	st = ha_rd(nv, NVMEHA_INT_STATUS) & ha_rd(nv, NVMEHA_INT_ENABLE);
	if (!st || nvrec_ha_is_dead(nv))
		return nvrec_ha_is_dead(nv) ? IRQ_HANDLED : IRQ_NONE;
	dev_err_ratelimited(nv->dev, "nvmeha: error interrupt 0x%02x (command errors %u)\n",
			    st, ha_rd(nv, NVMEHA_CMD_ERR_COUNT));
	ha_wr(nv, NVMEHA_INT_STATUS, st);
	/* error bits that do not clear: mask them, they stay visible in sysfs */
	st = ha_rd(nv, NVMEHA_INT_STATUS) & st;
	if (st)
		ha_wr(nv, NVMEHA_INT_ENABLE, ha_rd(nv, NVMEHA_INT_ENABLE) & ~st);
	return IRQ_HANDLED;
}

/* Injector completions: a level interrupt while its CQE FIFO is not empty */
static void nvrec_inj_drain(struct nvrec_dev *nv)
{
	while (core_rd(nv, NVREC_INJ_STATUS) & NVREC_INJ_STATUS_CQ_VALID) {
		struct nvme_cqe cqe;
		u32 dw[4], info;
		unsigned int ssd;
		int i;

		for (i = 0; i < 4; i++)
			dw[i] = core_rd(nv, NVREC_INJ_CQE(i));
		info = core_rd(nv, NVREC_INJ_CQ_INFO);
		core_wr(nv, NVREC_INJ_CQ_POP, 1);
		memcpy(&cqe, dw, sizeof(cqe));
		ssd = NVMEHA_M_TUSER_SSD(info);
		if (ssd < nv->cfg.nr_ssd && nv->ssd[ssd])
			nvrec_blk_complete(nv->ssd[ssd], &cqe);
		else
			dev_err_ratelimited(nv->dev, "injector: CQE for unknown SSD %u\n", ssd);
	}
}

static irqreturn_t nvrec_core_irq(int irq, void *data)
{
	struct nvrec_dev *nv = data;
	u32 st = core_rd(nv, NVREC_IRQ_STATUS) & core_rd(nv, NVREC_IRQ_ENABLE);

	if (!st)
		return IRQ_NONE;
	/* everything but INJ_CQE (a level) is W1C */
	if (st & ~NVREC_IRQ_INJ_CQE)
		core_wr(nv, NVREC_IRQ_STATUS, st & ~NVREC_IRQ_INJ_CQE);
	if (st & NVREC_IRQ_INJ_CQE) {
		spin_lock(&nv->inj_lock);
		nvrec_inj_drain(nv);
		spin_unlock(&nv->inj_lock);
	}
	if (st & NVREC_IRQ_UNEXPECTED_CQE)
		dev_warn_ratelimited(nv->dev, "recorder: CQE for a slot that was not in flight\n");
	if (st & NVREC_IRQ_HA_DEAD)
		nvrec_hw_mark_ha_dead(nv);
	if (st & (NVREC_IRQ_DONE | NVREC_IRQ_ABORTED | NVREC_IRQ_CMD_ERROR))
		nvrec_run_event(nv);
	return IRQ_HANDLED;
}

/* ------------------------------------------------------------------------ */
/* Probe                                                                    */

int nvrec_hw_probe(struct nvrec_dev *nv)
{
	struct platform_device *pdev = to_platform_device(nv->dev);
	struct device *dev = nv->dev;
	u32 id;
	int ret;

	nv->core = devm_platform_ioremap_resource_byname(pdev, "core");
	if (IS_ERR(nv->core))
		return dev_err_probe(dev, PTR_ERR(nv->core), "reg \"core\"\n");
	nv->ha = devm_platform_ioremap_resource_byname(pdev, "ha-lite");
	if (IS_ERR(nv->ha))
		return dev_err_probe(dev, PTR_ERR(nv->ha), "reg \"ha-lite\"\n");

	id = core_rd(nv, NVREC_ID);
	nv->hw_version = core_rd(nv, NVREC_VERSION);
	if (id != NVREC_ID_VALUE)
		return dev_err_probe(dev, -ENODEV,
				     "no nvrec_core at this address (ID 0x%08x, expected 0x%08x)\n",
				     id, NVREC_ID_VALUE);
	if ((nv->hw_version >> 16) != (NVREC_VERSION_EXPECTED >> 16))
		return dev_err_probe(dev, -ENODEV,
				     "unsupported nvrec_core VERSION 0x%08x (expected major %u)\n",
				     nv->hw_version, NVREC_VERSION_EXPECTED >> 16);
	if (!hw_has_guard(nv))
		dev_warn(dev, "nvrec_core v%u.%u has no Host Accelerator timeout guard: an expired evaluation core hangs the system on the next register access (update the bitstream to v1.1)\n",
			 nv->hw_version >> 16, nv->hw_version & 0xffff);
	nv->src_clk_hz = core_rd(nv, NVREC_SRC_CLK_HZ);
	nv->dp_clk_hz = core_rd(nv, NVREC_DP_CLK_HZ);
	/* bytes per fabric beat: the BEAT_BYTES register of map 1.2; offset
	 * 0x0BC is unmapped (reads 0) on 1.0/1.1, whose datapath is 128 bits */
	nv->beat_bytes = hw_is_1_2(nv) ? core_rd(nv, NVREC_BEAT_BYTES_REG) : 0;
	if (!nv->beat_bytes)
		nv->beat_bytes = NVREC_BEAT_BYTES_DEFAULT;
	if (nv->beat_bytes != 16 && nv->beat_bytes != 32 && nv->beat_bytes != 64)
		return dev_err_probe(dev, -ENODEV,
				     "unsupported nvrec_core BEAT_BYTES %u (expected 16, 32 or 64)\n",
				     nv->beat_bytes);
	nv->fifo_depth = core_rd(nv, NVREC_ING_FIFO_DEPTH);
	nv->egr_fifo_depth = core_rd(nv, NVREC_EGR_FIFO_DEPTH);

	ret = nvrec_hw_read_cfg(nv);
	if (ret)
		return ret;
	nv->cfg.max_slots = min_t(u32, core_rd(nv, NVREC_MAX_SLOTS), NVREC_RING_MAX_SLOTS);
	if (!nv->cfg.max_slots)
		nv->cfg.max_slots = NVREC_RING_MAX_SLOTS;

	nv->caps = NVREC_CAP_TPG | NVREC_CAP_RECORD | NVREC_CAP_PLAY |
		   NVREC_CAP_CHECK | NVREC_CAP_INJECTOR;
	if (hw_is_1_2(nv))
		nv->caps |= NVREC_CAP_DRY;

	nv->irq_core = platform_get_irq_byname(pdev, "core");
	if (nv->irq_core < 0)
		return nv->irq_core;
	nv->irq_ha = platform_get_irq_byname_optional(pdev, "ha");

	core_wr(nv, NVREC_IRQ_ENABLE, 0);
	if (nvrec_hw_ha_dead(nv))
		dev_err(dev, "the Host Accelerator is not answering: /dev/nvrec only reports the status, no SSD will be brought up\n");
	ha_wr(nv, NVMEHA_INT_ENABLE, 0);
	if (nv->hw_version && (core_rd(nv, NVREC_STATE) & NVREC_STATE_MASK) ==
	    NVREC_STATE_RUN) {
		/* left running by a previous load: stop it before the reset */
		dev_warn(dev, "recorder was running: aborting\n");
		nvrec_hw_stop(nv, true);
	}
	ret = nvrec_hw_soft_reset(nv);
	if (ret)
		return dev_err_probe(dev, ret, "GLOBAL_CTRL.SOFT_RST did not clear\n");
	core_wr(nv, NVREC_IRQ_STATUS, ~0u);

	ret = devm_request_irq(dev, nv->irq_core, nvrec_core_irq, 0,
			       dev_name(dev), nv);
	if (ret)
		return ret;
	if (nv->irq_ha > 0) {
		ret = devm_request_irq(dev, nv->irq_ha, nvrec_ha_irq, 0,
				       "nvmeha", nv);
		if (ret)
			return ret;
	}
	core_wr(nv, NVREC_IRQ_ENABLE, NVREC_IRQ_DONE | NVREC_IRQ_ABORTED |
		NVREC_IRQ_CMD_ERROR | NVREC_IRQ_INJ_CQE | NVREC_IRQ_UNEXPECTED_CQE |
		(hw_has_guard(nv) ? NVREC_IRQ_HA_DEAD : 0));
	return 0;
}

void nvrec_hw_remove(struct nvrec_dev *nv)
{
	core_wr(nv, NVREC_IRQ_ENABLE, 0);
	ha_wr(nv, NVMEHA_INT_ENABLE, 0);
	nvrec_hw_soft_reset(nv);
}

/*
 * The queue window (where the IP's SQ/CQ memory appears to the SSDs) and the
 * interrupt enables. Runs before any SSD is brought up.
 */
int nvrec_hw_ha_init(struct nvrec_dev *nv)
{
	struct nvrec_ha_cfg *c = &nv->cfg;
	unsigned int n, m, bad = 0;
	u64 cycles;

	if (nvrec_hw_ha_dead(nv))
		return 0;	/* /dev/nvrec stays, reporting NVREC_STATUS_HA_DEAD */
	ha_wr(nv, NVMEHA_SQ1_BASE, (u32)c->sq_base);
	ha_wr(nv, NVMEHA_CQ1_BASE, (u32)c->cq_base);

	/* Cross-check the read-back bases (PG328 Table 9 indexing) */
	for (n = 0; n < c->nr_ssd; n++) {
		for (m = 0; m < c->max_sq; m++) {
			u32 i = qidx(nv, n, m), sq, cq;

			if (!i)
				continue;
			sq = ha_rd(nv, 0x0100 + i * 16);
			cq = ha_rd(nv, 0x0104 + i * 16);
			if ((sq != (u32)nvrec_hw_sq_addr(nv, n, m) ||
			     cq != (u32)nvrec_hw_cq_addr(nv, n, m)) && !bad++)
				dev_warn(nv->dev,
					 "nvmeha: SSD%u queue %u base reads back SQ 0x%08x CQ 0x%08x, expected 0x%08llx/0x%08llx\n",
					 n, m, sq, cq, nvrec_hw_sq_addr(nv, n, m),
					 nvrec_hw_cq_addr(nv, n, m));
		}
	}

	cycles = (u64)ha_timeout_ms * (nv->dp_clk_hz ? nv->dp_clk_hz : 250000000) / 1000;
	ha_wr(nv, NVMEHA_TIMEOUT, (u32)min_t(u64, cycles, U32_MAX));
	ha_wr(nv, NVMEHA_INT_STATUS, ~0u);
	/* SSD timeouts stay a status only: an idle-looking SQ during a long
	 * write burst is normal. HW_NO_CREDIT must never fire (nvrec_core
	 * holds SQEs until a credit is available). */
	ha_wr(nv, NVMEHA_INT_ENABLE, NVMEHA_INT_ADDR_ERR | NVMEHA_INT_HW_NO_CREDIT);
	/* no SSD yet, nothing in flight: start from full credits */
	core_wr(nv, NVREC_CREDIT_INIT, c->nhw[0] * (c->sq_depth - 1));
	core_wr(nv, NVREC_CTRL, NVREC_CTRL_CREDIT_RST);
	return 0;
}

/*
 * Queue q (0-based; software queues first, PG328) of SSD ssd, as the SSD
 * sees it: one 4 KB slot per queue, SSD-major.
 */
u64 nvrec_hw_sq_addr(struct nvrec_dev *nv, unsigned int ssd, unsigned int q)
{
	return nv->cfg.sq_base + (u64)qidx(nv, ssd, q) * NVREC_QWIN_QUEUE_STRIDE;
}

u64 nvrec_hw_cq_addr(struct nvrec_dev *nv, unsigned int ssd, unsigned int q)
{
	return nv->cfg.cq_base + (u64)qidx(nv, ssd, q) * NVREC_QWIN_QUEUE_STRIDE;
}

/* Tell the IP where SSD ssd's BAR0 is (it rings the doorbells there). The
 * root ports' BAR windows are at the same AXI address for the CPU and for
 * the IP's M_AXI_SSD, so the CPU physical address is used (+ DT offset). */
void nvrec_hw_ssd_attach(struct nvrec_dev *nv, unsigned int ssd, u64 bar_cpu)
{
	u64 a = bar_cpu + nv->cfg.bar_offset;

	ha_wr(nv, NVMEHA_SSD_PCIE_BASE_LO(ssd), lower_32_bits(a));
	ha_wr(nv, NVMEHA_SSD_PCIE_BASE_HI(ssd), upper_32_bits(a));
}

/*
 * Reload SSD ssd's hardware-interface credit counter (and clear its
 * in-flight counters) in nvrec_core, which mirrors the IP's queue state.
 * Only valid while nothing is in flight on THAT SSD: call it right after its
 * hardware queue was (re)created. Other SSDs are not touched (CTRL bits 6/7).
 */
void nvrec_hw_credit_reset(struct nvrec_dev *nv, unsigned int ssd)
{
	core_wr(nv, NVREC_CREDIT_INIT, nv->cfg.nhw[ssd] * (nv->cfg.sq_depth - 1));
	core_wr(nv, NVREC_CTRL, NVREC_CTRL_CREDIT_RST_SSD(ssd));
}

/* Flush every queue of an SSD in the IP (error recovery / detach) */
void nvrec_hw_ssd_flush(struct nvrec_dev *nv, unsigned int ssd)
{
	unsigned int m;
	u32 v;

	for (m = 0; m < nv->cfg.max_sq; m++) {
		u32 i = qidx(nv, ssd, m);
		unsigned int us = 0;

		if (nvrec_hw_ha_dead(nv))
			return;
		ha_wr(nv, 0x0108 + i * 16, 1);
		while (!((v = ha_rd(nv, 0x010C + i * 16)) & 1) || v == ~0u) {
			if (nvrec_ha_is_dead(nv))
				return;
			if (++us > 10000) {
				dev_warn(nv->dev, "nvmeha: SSD%u queue %u flush did not complete\n",
					 ssd, m);
				break;
			}
			udelay(1);
		}
		ha_wr(nv, 0x0108 + i * 16, 0);
	}
}

/* Injector CIDs: bit 15 set (the hardware forces it), so they cannot
 * collide with the command builder's slot CIDs on the hardware SQ */
u16 nvrec_hw_inj_cid(u16 tag)
{
	return NVREC_INJ_CID_TAG | tag;
}

/*
 * One SQE through the CPU command injector onto SSD ssd's hardware SQ.
 * BUSY means the previous SQE still waits for a credit: retry briefly,
 * then -EBUSY (the block layer requeues).
 */
int nvrec_hw_inj_submit(struct nvrec_dev *nv, unsigned int ssd,
			const struct nvme_sqe *sqe)
{
	const u32 *d = (const u32 *)sqe;
	unsigned long flags;
	u32 v;
	int i;

	spin_lock_irqsave(&nv->inj_lock, flags);
	if (readl_poll_timeout_atomic(nv->core + NVREC_INJ_STATUS, v,
				      !(v & NVREC_INJ_STATUS_BUSY), 1, 50)) {
		spin_unlock_irqrestore(&nv->inj_lock, flags);
		return -EBUSY;
	}
	for (i = 0; i < 16; i++)
		core_wr(nv, NVREC_INJ_SQE(i), d[i]);
	core_wr(nv, NVREC_INJ_CTRL, NVREC_INJ_CTRL_SUBMIT |
		(ssd << NVREC_INJ_CTRL_SSD_SHIFT) |
		(nv->cfg.nsw[ssd] << NVREC_INJ_CTRL_SQ_SHIFT));
	spin_unlock_irqrestore(&nv->inj_lock, flags);
	return 0;
}

/* nvmeha statistics, which: 0 issued, 1 completed, 2 error completions */
u32 nvrec_hw_ha_counter(struct nvrec_dev *nv, unsigned int ssd, int which)
{
	switch (which) {
	case 0: return ha_rd(nv, NVMEHA_SSD_ISSUED(ssd));
	case 1: return ha_rd(nv, NVMEHA_SSD_COMPLETED(ssd));
	default: return ha_rd(nv, NVMEHA_SSD_ERR_COMPL(ssd));
	}
}

u32 nvrec_hw_lat_bin0_log2(void)
{
	return NVREC_LAT_HIST_BIN0_LOG2;
}

u32 nvrec_hw_max_qd(void)
{
	return 63;	/* SSD_MAX_INFLIGHT range 1..63 */
}

/* ------------------------------------------------------------------------ */
/* Recorder datapath                                                        */

int nvrec_hw_soft_reset(struct nvrec_dev *nv)
{
	u32 v;

	core_wr(nv, NVREC_GLOBAL_CTRL, NVREC_GLOBAL_CTRL_SOFT_RST);
	return readl_poll_timeout(nv->core + NVREC_GLOBAL_CTRL, v,
				  !(v & NVREC_GLOBAL_CTRL_SOFT_RST), 1, 10000);
}

/* rate_bps = INC / 2^31 * SRC_CLK_HZ * BEAT_BYTES (TPG and checker alike) */
static u64 inc_to_rate(struct nvrec_dev *nv, u64 inc)
{
	if (inc > NVREC_TPG_RATE_INC_ONE)
		inc = NVREC_TPG_RATE_INC_ONE;
	return mul_u64_u64_div_u64(inc, (u64)nv->src_clk_hz * nv->beat_bytes, 1ull << 31);
}

/* INC = rate_bps * 2^31 / (SRC_CLK_HZ * BEAT_BYTES), capped at one beat per clock */
static u32 rate_to_inc(struct nvrec_dev *nv, u64 rate_bps)
{
	u64 max = (u64)nv->src_clk_hz * nv->beat_bytes;
	u64 inc;

	if (!max)
		return 0;
	if (rate_bps > max)
		rate_bps = max;
	inc = mul_u64_u64_div_u64(rate_bps, 1ull << 31, max);
	return (u32)min_t(u64, inc, NVREC_TPG_RATE_INC_ONE);
}

u64 nvrec_hw_rate_get(struct nvrec_dev *nv)
{
	return inc_to_rate(nv, core_rd(nv, NVREC_TPG_RATE_INC));
}

u64 nvrec_hw_rate_set(struct nvrec_dev *nv, u64 rate_bps)
{
	core_wr(nv, NVREC_TPG_RATE_INC, rate_to_inc(nv, rate_bps));
	return nvrec_hw_rate_get(nv);
}

u64 nvrec_hw_sink_rate_set(struct nvrec_dev *nv, u64 rate_bps)
{
	core_wr(nv, NVREC_CHK_RATE_INC, rate_to_inc(nv, rate_bps));
	return inc_to_rate(nv, core_rd(nv, NVREC_CHK_RATE_INC));
}

void nvrec_hw_tpg_enable(struct nvrec_dev *nv, bool on)
{
	core_wr(nv, NVREC_TPG_CTRL, on ? NVREC_TPG_CTRL_ENABLE : 0);
}

bool nvrec_hw_tpg_enabled(struct nvrec_dev *nv)
{
	return core_rd(nv, NVREC_TPG_CTRL) & NVREC_TPG_CTRL_ENABLE;
}

u64 nvrec_hw_seq_next(struct nvrec_dev *nv)
{
	return core_rd64(nv, NVREC_TPG_SEQ_NEXT_LO);
}

/* Ring + geometry + run configuration (latched by the hardware at START).
 * A DRY run may have no member (nr_members 0): nothing NVMe is used. */
static void nvrec_hw_program(struct nvrec_dev *nv, bool play, bool dry)
{
	const struct nvrec_geometry *g = &nv->geo;
	struct nvrec_ssd *s0 = g->nr_members ? nv->ssd[g->members[0].ssd] : NULL;
	u32 cfg = 0, qd = g->qd ? g->qd : 32;
	unsigned int j;

	core_wr64(nv, NVREC_RING_BASE_LO, nv->ring_dma);
	core_wr(nv, NVREC_NUM_CHUNKS, nv->slots);
	core_wr(nv, NVREC_CHUNK_SIZE, nv->chunk);
	core_wr64(nv, NVREC_PRP_LIST_BASE_LO, nv->prp_lists_dma);
	core_wr(nv, NVREC_PRP_LIST_SHIFT, nv->prp_shift);
	core_wr(nv, NVREC_LBA_SHIFT, s0 ? s0->lba_shift : 9);
	core_wr64(nv, NVREC_START_CHUNK_LO, g->start_chunk);
	core_wr(nv, NVREC_LENGTH_CHUNKS, g->length_chunks);
	core_wr(nv, NVREC_LAST_CHUNK_BYTES, play ? g->last_chunk_bytes : 0);
	for (j = 0; j < g->nr_members; j++) {
		const struct nvrec_member *m = &g->members[j];

		core_wr(nv, NVREC_MEMBER_NSID(j), m->nsid);
		core_wr(nv, NVREC_MEMBER_SEL(j),
			(m->ssd << NVREC_MEMBER_SEL_SSD_SHIFT) |
			(nv->cfg.nsw[m->ssd] << NVREC_MEMBER_SEL_SQ_SHIFT));
		core_wr64(nv, NVREC_MEMBER_BASE_LBA_LO(j), m->base_lba);
		core_wr(nv, NVREC_SSD_MAX_INFLIGHT(m->ssd), min_t(u32, qd, 63));
	}
	/*
	 * Clear the in-flight high-water of EVERY SSD slot, not only the
	 * members: the run statistics (and the apps' "max N in flight per
	 * SSD") report all slots, and a slot left out of a single-drive run
	 * would otherwise show its value from an earlier run.
	 */
	for (j = 0; j < nv->cfg.nr_ssd && j < NVREC_NVMEHA_NUM_SSD; j++)
		core_wr(nv, NVREC_SSD_INFLIGHT_HWM(j), 0);
	if (play)
		cfg |= NVREC_CONFIG_MODE_PLAY;
	if (g->flags & NVREC_GEO_FUA)
		cfg |= NVREC_CONFIG_FUA;
	if (dry)
		cfg |= NVREC_CONFIG_DRY;
	cfg |= (g->nr_members << NVREC_CONFIG_N_MEMBERS_SHIFT) & NVREC_CONFIG_N_MEMBERS_MASK;
	core_wr(nv, NVREC_CONFIG, cfg);
}

/*
 * Start a run. SOFT_RST first (FIFO, counters, ring state; credits are kept),
 * then the configuration, then START. Record with NVREC_START_TPG: the
 * generator is enabled last, so the first beat it emits (sequence 0) is the
 * first beat recorded. Playback with NVREC_START_CHECK: the checker is reset
 * and enabled before data reaches it. NVREC_START_DRY: CONFIG.DRY, the
 * fabric side only (no NVMe command, so a dead Host Accelerator is no
 * obstacle).
 */
int nvrec_hw_start(struct nvrec_dev *nv, bool play, u32 flags)
{
	bool dry = flags & NVREC_START_DRY;
	int ret;
	u32 v;

	if (!dry && nvrec_hw_ha_dead(nv))
		return -ENOLINK;
	ret = nvrec_hw_soft_reset(nv);
	if (ret)
		return ret;
	nv->prefill_ns = 0;
	nvrec_hw_program(nv, play, dry);
	core_wr(nv, NVREC_IRQ_STATUS, NVREC_IRQ_DONE | NVREC_IRQ_ABORTED |
		NVREC_IRQ_CMD_ERROR | NVREC_IRQ_OVERFLOW | NVREC_IRQ_UNEXPECTED_CQE);
	if (play && (flags & NVREC_START_CHECK)) {
		core_wr(nv, NVREC_CHK_CTRL, NVREC_CHK_CTRL_RESET);
		readl_poll_timeout(nv->core + NVREC_CHK_CTRL, v,
				   !(v & NVREC_CHK_CTRL_RESET), 1, 10000);
		core_wr(nv, NVREC_CHK_CTRL, 0);
	}
	core_wr(nv, NVREC_CTRL, NVREC_CTRL_START);
	if (play && dry && (flags & NVREC_START_CHECK)) {
		/*
		 * DRY: every chunk counts as completed at START, the reader
		 * streams the ring at once. Enable the sink once the egress
		 * FIFO holds half its depth (the reader is running and the
		 * sink starts with headroom), as fdrec does after priming.
		 */
		u32 want = max_t(u32, nv->egr_fifo_depth / 2, 1);
		unsigned long end = jiffies + msecs_to_jiffies(100);
		u64 t0 = ktime_get_ns();

		/* ~16-64 us at the fabric rate; 100 ms = something is stuck */
		while (core_rd(nv, NVREC_EGR_FIFO_LEVEL) < want &&
		       !nvrec_hw_finished(nv) && time_before(jiffies, end))
			usleep_range(5, 10);
		nv->prefill_ns = ktime_get_ns() - t0;
		core_wr(nv, NVREC_CHK_CTRL, NVREC_CHK_CTRL_ENABLE);
	} else if (play && (flags & NVREC_START_CHECK)) {
		/*
		 * Prefill: the reader streams the chunks IN ORDER, and early
		 * on the SSD completes them out of order with latency spikes
		 * of several ms (QD 32), so a sink that starts consuming at
		 * once starves (bring-up 2026-10-16: ~137k underflow ticks at
		 * 1 GB/s, none at 500 MB/s). The checker holds tready low
		 * while disabled: let the ring fill (every slot read, or the
		 * whole playback), then enable the sink -- what a real
		 * DAC-like sink must do as well.
		 */
		u32 want = min_t(u32, nv->slots, nv->geo.length_chunks);
		unsigned long end = jiffies + msecs_to_jiffies(play_prefill_ms);
		u64 t0 = ktime_get_ns();

		while (play_prefill_ms && core_rd64(nv, NVREC_CMDS_DONE_LO) < want &&
		       !nvrec_hw_finished(nv) && !nvrec_hw_ha_dead(nv) &&
		       time_before(jiffies, end))
			usleep_range(200, 400);
		/* the caller starts the run clock after this: the reported
		 * elapsed time is the streaming time, the prefill separate */
		nv->prefill_ns = ktime_get_ns() - t0;
		core_wr(nv, NVREC_CHK_CTRL, NVREC_CHK_CTRL_ENABLE);
	}
	if (!play && (flags & NVREC_START_TPG))
		core_wr(nv, NVREC_TPG_CTRL, NVREC_TPG_CTRL_ENABLE);
	return 0;
}

static u32 hw_state(struct nvrec_dev *nv)
{
	return core_rd(nv, NVREC_STATE) & NVREC_STATE_MASK;
}

bool nvrec_hw_finished(struct nvrec_dev *nv)
{
	u32 st = hw_state(nv);

	/* Playback into the checker: DONE means the last chunk entered the
	 * egress FIFO; the run is over once the sink has taken it all, so
	 * the final statistics count every beat. */
	if (st == NVREC_STATE_DONE &&
	    (core_rd(nv, NVREC_CONFIG) & NVREC_CONFIG_MODE_PLAY) &&
	    (core_rd(nv, NVREC_CHK_CTRL) & NVREC_CHK_CTRL_ENABLE)) {
		u32 v;

		/* the egress FIFO (128 KB) drains in < 2 ms at >= 100 MB/s:
		 * wait for it here rather than on the next wake-up, so the
		 * run's end time is exact (callers may be atomic) */
		if (readl_poll_timeout_atomic(nv->core + NVREC_EGR_FIFO_LEVEL, v,
					      !v, 10, 2000))
			return false;
		udelay(5);	/* CDC + checker pipeline, counter snapshot */
	}
	return st == NVREC_STATE_DONE || st == NVREC_STATE_ABORTED ||
	       st == NVREC_STATE_IDLE;
}

bool nvrec_hw_aborted(struct nvrec_dev *nv)
{
	return hw_state(nv) == NVREC_STATE_ABORTED;
}

/*
 * End a run. Record STOP: the source is stopped first, the writer stores
 * what is in the FIFO, pads the open chunk to a whole LBA and every command
 * completes -> DONE. ABORT: no new command, in-flight commands complete ->
 * ABORTED. Either way the SSDs may DMA into the ring until the state is
 * final, so the ring must not be freed before this returns 0. -ETIMEDOUT:
 * an SSD stopped answering; the caller must disable it (CC.EN = 0).
 */
int nvrec_hw_stop(struct nvrec_dev *nv, bool abort)
{
	int ret;
	u32 v;

	nvrec_hw_tpg_enable(nv, false);
	if (!nvrec_hw_finished(nv))
		core_wr(nv, NVREC_CTRL, abort ? NVREC_CTRL_ABORT : NVREC_CTRL_STOP);
	/* a dead Host Accelerator completes nothing: do not wait long
	 * (a DRY run has no command in flight, it only flushes the writer) */
	ret = readl_poll_timeout(nv->core + NVREC_STATE, v,
				 (v & NVREC_STATE_MASK) == NVREC_STATE_DONE ||
				 (v & NVREC_STATE_MASK) == NVREC_STATE_ABORTED ||
				 (v & NVREC_STATE_MASK) == NVREC_STATE_IDLE,
				 100, (nvrec_hw_ha_dead(nv) && !nv->run_dry ? 100 :
				       stop_timeout_ms) * 1000ul);
	core_wr(nv, NVREC_CHK_CTRL, 0);
	return ret;
}

void nvrec_hw_read_stats(struct nvrec_dev *nv, struct nvrec_stats *st)
{
	unsigned int k, n;

	st->hw_state = core_rd(nv, NVREC_STATE);
	/* pass/fail: drops while the run accepted data (RUN_DROP_COUNT);
	 * the ingest counter keeps counting while the source runs on */
	st->drop_count = core_rd64(nv, NVREC_RUN_DROP_COUNT_LO);
	st->ing_drop_count = core_rd64(nv, NVREC_ING_DROP_COUNT_LO);
	st->beats_in = core_rd64(nv, NVREC_ING_BEATS_IN_LO);
	st->beats_out = core_rd64(nv, NVREC_ING_BEATS_OUT_LO);
	st->seq_next = core_rd64(nv, NVREC_TPG_SEQ_NEXT_LO);
	/* the in-run high-water mark (1.1); ING_FIFO_HWM also sees the FIFO
	 * fill up after the run when the source keeps running */
	st->ing_fifo_hwm = core_rd(nv, NVREC_ING_FIFO_HWM);
	st->fifo_hwm = hw_has_guard(nv) ? core_rd(nv, NVREC_RUN_FIFO_HWM) : st->ing_fifo_hwm;
	st->flags = nvrec_hw_ha_dead(nv) ? NVREC_STATS_HA_DEAD : 0;
	st->prefill_ns = nv->prefill_ns;
	st->fifo_depth = nv->fifo_depth;
	st->overflow = !!(core_rd(nv, NVREC_ING_STATUS) & NVREC_ING_STATUS_OVERFLOW);
	st->chunks_filled = core_rd64(nv, NVREC_CHUNKS_FILLED_LO);
	st->cmds_issued = core_rd64(nv, NVREC_CMDS_ISSUED_LO);
	st->cmds_done = core_rd64(nv, NVREC_CMDS_DONE_LO);
	st->cmd_errors = core_rd(nv, NVREC_CMD_ERRORS);
	st->unexpected_cqes = core_rd(nv, NVREC_UNEXPECTED_CQES);
	st->bytes = core_rd64(nv, NVREC_BYTES_LO);
	st->ring_fill = core_rd(nv, NVREC_RING_FILL);
	st->ring_hwm = core_rd(nv, NVREC_RING_HWM);
	st->err_last_status = core_rd(nv, NVREC_ERR_LAST_STATUS);
	st->err_last_cid = core_rd(nv, NVREC_ERR_LAST_CID);
	st->chunks_released = core_rd64(nv, NVREC_CHUNKS_RELEASED_LO);
	st->pad_bytes = core_rd(nv, NVREC_PAD_BYTES);
	st->ring_full_cycles = core_rd64(nv, NVREC_RING_FULL_CYCLES_LO);
	st->lat_min = core_rd(nv, NVREC_LAT_MIN);
	st->lat_max = core_rd(nv, NVREC_LAT_MAX);
	st->lat_count = core_rd(nv, NVREC_LAT_COUNT);
	st->lat_sum = core_rd64(nv, NVREC_LAT_SUM_LO);
	for (k = 0; k < NVREC_LAT_BINS && k < NVREC_LAT_HIST_BINS; k++)
		st->lat_hist[k] = core_rd(nv, NVREC_LAT_HIST(k));
	for (n = 0; n < nv->cfg.nr_ssd && n < NVREC_NVMEHA_NUM_SSD; n++) {
		struct nvrec_ssd_stats *d = &st->ssd[n];

		d->inflight = core_rd(nv, NVREC_SSD_INFLIGHT(n));
		d->inflight_hwm = core_rd(nv, NVREC_SSD_INFLIGHT_HWM(n));
		d->credits = core_rd(nv, NVREC_SSD_CREDITS(n));
		d->issued = core_rd(nv, NVREC_SSD_ISSUED(n));
		d->completed = core_rd(nv, NVREC_SSD_COMPLETED(n));
		d->errors = core_rd(nv, NVREC_SSD_ERRORS(n));
		/* ha_*: not read here -- the stats path never touches the
		 * Host Accelerator (sysfs ha_counters does, on request) */
	}
	st->chk_beats = core_rd64(nv, NVREC_CHK_BEATS_LO);
	st->chk_errors = core_rd64(nv, NVREC_CHK_ERRORS_LO);
	st->chk_gaps = core_rd64(nv, NVREC_CHK_GAPS_LO);
	st->chk_gap_beats = core_rd64(nv, NVREC_CHK_GAP_BEATS_LO);
	st->chk_underflows = core_rd64(nv, NVREC_CHK_UNDERFLOWS_LO);
	st->chk_last_seq = core_rd64(nv, NVREC_CHK_LAST_SEQ_LO);
}
