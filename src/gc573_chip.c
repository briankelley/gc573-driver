// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 HDMI chips: bus-1 register access and the sequence engine.
 *
 * Access rules, spec/i2c.md and spec/hdmi-chips.md: the bank of each
 * banked device (0x90, 0x58, 0x70) is cached and a select is skipped when
 * unchanged; after a failed or retried transfer to a banked device its
 * bank register is rewritten and read back before the next banked access;
 * with the bus-1 adapter on (i2c_bus1), its lock is held across a
 * sequence, so an i2c-dev user never lands between a bank select and the
 * accesses that depend on it, and every device is back in bank 0 when the
 * lock is released. The lock is free between sequences and during their
 * delays (gc573_chip_sleep()): after an i2c-dev write in such a window,
 * which may have selected another bank, every bank is selected and read
 * back again before its next use.
 *
 * The engine runs one segment of a spec/seq table (src/gc573_seq.c, from
 * tools/gen-seq.py): W, M, R, D, P rows as the table header defines them,
 * X rows and variables through the chip files.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/moduleparam.h>
#include <linux/pci.h>

#include "gc573.h"

static unsigned int hdmi_trace;
module_param(hdmi_trace, uint, 0644);
MODULE_PARM_DESC(hdmi_trace,
		 "Log HDMI chip access: bit 0 sequence runs, bit 1 every transfer (default: 0)");

/* spec/hdmi-splitter.md 7.7: DDC completion poll, every 1 ms, 20 polls */
#define GC573_SEQ_POLL_US		1000
#define GC573_SEQ_POLL_TRIES		20

static struct gc573_chip_bank *gc573_chip_bankinfo(struct gc573_hdmi *h,
						   u8 dev)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(h->bank); i++)
		if (h->bank[i].dev == dev)
			return &h->bank[i];
	return NULL;
}

/* One transfer; marks the device's bank for a resync on error or retry. */
static int gc573_chip_xfer(struct gc573_hdmi *h, u8 dev, u8 reg, u8 *buf,
			   u16 len, bool rd)
{
	struct gc573_chip_bank *b;
	bool retried = false;
	int ret;

	ret = gc573_i2c1_transfer(h->gc, dev, reg, buf, len, rd, &retried);
	h->xfers++;
	if (retried)
		h->retries++;
	if (ret)
		h->xfer_errors++;
	if (ret || retried) {
		b = gc573_chip_bankinfo(h, dev);
		if (b) {
			b->cur = -1;
			b->resync = true;
		}
	}
	if (hdmi_trace & 2)
		dev_info(&h->gc->pdev->dev, "i2c %02x:%02x %s %*ph%s%s\n", dev,
			 reg, rd ? "rd" : "wr", len, buf,
			 retried ? " (retried)" : "", ret ? " FAILED" : "");
	return ret;
}

/* Select a bank: IT6805 by a plain write, the splitter by RMW (bits). */
int gc573_chip_bank(struct gc573_hdmi *h, u8 dev, u8 bank)
{
	struct gc573_chip_bank *b = gc573_chip_bankinfo(h, dev);
	bool resync;
	int ret;
	u8 v;

	if (!b || bank & ~b->mask)
		return -EINVAL;
	if (b->cur == bank && !b->resync)
		return 0;

	resync = b->resync;
	if (dev == GC573_DEV_IT6805) {
		/* bits 7:3 of 0x0f always read 0 (hdmi-it6805.md 1.3) */
		v = bank;
		ret = gc573_chip_xfer(h, dev, 0x0f, &v, 1, false);
	} else {
		ret = gc573_chip_xfer(h, dev, 0x0f, &v, 1, true);
		if (!ret) {
			v = (v & ~b->mask) | bank;
			ret = gc573_chip_xfer(h, dev, 0x0f, &v, 1, false);
		}
	}
	if (!ret && resync) {
		ret = gc573_chip_xfer(h, dev, 0x0f, &v, 1, true);
		if (!ret && (v & b->mask) != bank)
			ret = -EIO;
		if (!ret)
			h->resyncs++;
	}
	if (ret) {
		b->cur = -1;
		b->resync = true;
		dev_err_ratelimited(&h->gc->pdev->dev,
				    "HDMI: 0x%02x bank %u select failed: %d\n",
				    dev, bank, ret);
		return ret;
	}
	b->cur = bank;
	b->resync = false;
	return 0;
}

int gc573_chip_rd(struct gc573_hdmi *h, u8 dev, u8 bank, u8 reg, u8 *val)
{
	int ret = 0;

	if (bank != GC573_SEQ_NOBANK)
		ret = gc573_chip_bank(h, dev, bank);
	return ret ?: gc573_chip_xfer(h, dev, reg, val, 1, true);
}

/* Multi-byte read of an unbanked or already selected device (IDs) */
int gc573_chip_rdn(struct gc573_hdmi *h, u8 dev, u8 reg, u8 *buf, u16 len)
{
	return gc573_chip_xfer(h, dev, reg, buf, len, true);
}

int gc573_chip_wr(struct gc573_hdmi *h, u8 dev, u8 bank, u8 reg, u8 val)
{
	int ret = 0;

	if (bank != GC573_SEQ_NOBANK)
		ret = gc573_chip_bank(h, dev, bank);
	return ret ?: gc573_chip_xfer(h, dev, reg, &val, 1, false);
}

/* new = (old & ~mask) | (val & mask), written even when unchanged (RD) */
int gc573_chip_mod(struct gc573_hdmi *h, u8 dev, u8 bank, u8 reg, u8 mask,
		   u8 val)
{
	u8 v;
	int ret;

	ret = gc573_chip_rd(h, dev, bank, reg, &v);
	if (ret)
		return ret;
	v = (v & ~mask) | (val & mask);
	return gc573_chip_xfer(h, dev, reg, &v, 1, false);
}

void gc573_chip_begin(struct gc573_hdmi *h)
{
	unsigned int i;

	if (h->gc->i2c1_on)
		i2c_lock_bus(&h->gc->i2c1, I2C_LOCK_ROOT_ADAPTER);
	h->bus_held = true;
	/* an i2c-dev write while the bus was free: the bank cache is stale */
	if (h->gc->i2c1_ext_write) {
		h->gc->i2c1_ext_write = false;
		for (i = 0; i < ARRAY_SIZE(h->bank); i++) {
			h->bank[i].cur = -1;
			h->bank[i].resync = true;
		}
	}
}

/* RD's convention: every banked device back in bank 0 between sequences */
void gc573_chip_end(struct gc573_hdmi *h)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(h->bank); i++) {
		struct gc573_chip_bank *b = &h->bank[i];

		if (b->cur > 0 || b->resync)
			gc573_chip_bank(h, b->dev, 0);
	}
	h->bus_held = false;
	if (h->gc->i2c1_on)
		i2c_unlock_bus(&h->gc->i2c1, I2C_LOCK_ROOT_ADAPTER);
}

/*
 * Sequence delays: the bus is free while the chips wait (hdmi-splitter.md
 * 10 step 7), with every device back in bank 0 as other users expect.
 */
void gc573_chip_sleep(struct gc573_hdmi *h, unsigned int ms)
{
	bool held = h->bus_held;

	if (held)
		gc573_chip_end(h);
	fsleep(ms * USEC_PER_MSEC);
	if (held)
		gc573_chip_begin(h);
}

/* ---- engine ---- */

/* Value read by row idx of the current or last run */
u8 gc573_seq_rd(struct gc573_hdmi *h, unsigned int idx)
{
	if (WARN_ON(!h->run || idx >= h->run->n || !test_bit(idx, h->rdv)))
		return 0;
	return h->rd[idx];
}

/* Value of the last R row of dev/bank:reg before row index 'before' */
bool gc573_seq_last(struct gc573_hdmi *h, unsigned int before, u8 dev,
		    u8 bank, u8 reg, u8 *val)
{
	const struct gc573_seq_op *ops = h->run->ops;
	unsigned int j;

	for (j = min(before, h->run->n); j-- > 0; ) {
		const struct gc573_seq_op *op = &ops[j];

		if (op->op == GC573_SEQ_R && op->dev == dev &&
		    op->bank == bank && op->reg == reg && test_bit(j, h->rdv)) {
			*val = h->rd[j];
			return true;
		}
	}
	return false;
}

static bool gc573_seq_cond(struct gc573_hdmi *h, unsigned int i, u8 c,
			   unsigned long cond)
{
	const struct gc573_seq_dcond *d;
	u8 v;

	if (!c)
		return true;
	d = &gc573_seq_dconds[c];
	if (!d->dev)
		return cond & BIT(c);
	if (!gc573_seq_last(h, i, d->dev, d->bank, d->reg, &v))
		return false;
	return ((v & d->mask) == d->val) == d->eq;
}

static int gc573_seq_x(struct gc573_hdmi *h, unsigned int x)
{
	if (x <= GC573_SEQ_X_IT_UNBLANK)
		return gc573_it6805_x(h, x);
	return gc573_sp_x(h, x);
}

static int gc573_seq_value(struct gc573_hdmi *h, unsigned int i,
			   const struct gc573_seq_op *op, u8 *v)
{
	if (op->flags & GC573_SEQ_F_READ)
		return gc573_seq_last(h, i, op->dev, op->bank, op->reg, v) ?
		       0 : -EINVAL;
	if (op->flags & GC573_SEQ_F_VAR) {
		if (op->arg >= GC573_SEQ_V_IT_B0)
			return gc573_it6805_var(h, op->arg, v);
		return gc573_sp_var(h, op->arg, v);
	}
	*v = op->val;
	return 0;
}

/*
 * Bank-register rows. IT6805 rows are plain writes of the bank number
 * (bits 7:3 read 0), so the cache may skip them. The splitter's M rows
 * select a bank; its W rows (init phases A, D, H) write the whole
 * register and are always sent.
 */
static int gc573_seq_bankreg(struct gc573_hdmi *h,
			     const struct gc573_seq_op *op)
{
	struct gc573_chip_bank *b = gc573_chip_bankinfo(h, op->dev);
	u8 v = op->val;
	int ret;

	if (!b)
		return -EINVAL;
	if (op->op == GC573_SEQ_M || op->dev == GC573_DEV_IT6805)
		return gc573_chip_bank(h, op->dev, v & b->mask);

	ret = gc573_chip_xfer(h, op->dev, 0x0f, &v, 1, false);
	if (!ret) {
		b->cur = op->val & b->mask;
		b->resync = false;
	}
	return ret;
}

/* P rows: DDC completion (hdmi-splitter.md 7.7), then the abort path */
static int gc573_seq_poll(struct gc573_hdmi *h, const struct gc573_seq_op *op)
{
	unsigned int tries;
	int ret;
	u8 v;

	for (tries = 0; tries < GC573_SEQ_POLL_TRIES; tries++) {
		fsleep(GC573_SEQ_POLL_US);
		ret = gc573_chip_rd(h, op->dev, op->bank, op->reg, &v);
		if (ret)
			return ret;
		if ((v & op->mask) == op->val)
			return 0;
	}
	return gc573_sp_ddc_abort(h, op->dev);
}

/*
 * Run a segment. cond: BIT(enum gc573_seq_cond) of the caller's flags;
 * the engine tests the other conditions itself. Stops at the first
 * failed row.
 */
int gc573_seq_run(struct gc573_hdmi *h, const struct gc573_seq *seq,
		  unsigned long cond)
{
	ktime_t t0 = ktime_get();
	unsigned int i, done = 0;
	int ret = 0;
	u8 v;

	if (WARN_ON(!h->bus_held || seq->n > GC573_SEQ_MAX_OPS))
		return -EINVAL;
	h->run = seq;
	bitmap_zero(h->rdv, GC573_SEQ_MAX_OPS);
	h->runs++;

	for (i = 0; i < seq->n && !ret; i++) {
		const struct gc573_seq_op *op = &seq->ops[i];

		if (!gc573_seq_cond(h, i, op->c1, cond) ||
		    !gc573_seq_cond(h, i, op->c2, cond))
			continue;
		done++;
		switch (op->op) {
		case GC573_SEQ_D:
			gc573_chip_sleep(h, op->arg);
			break;
		case GC573_SEQ_X:
			ret = gc573_seq_x(h, op->arg);
			break;
		case GC573_SEQ_R:
			ret = gc573_chip_rd(h, op->dev, op->bank, op->reg, &v);
			if (!ret) {
				h->rd[i] = v;
				__set_bit(i, h->rdv);
			}
			break;
		case GC573_SEQ_P:
			ret = gc573_seq_poll(h, op);
			break;
		case GC573_SEQ_W:
		case GC573_SEQ_M:
			if (op->flags & GC573_SEQ_F_BANKREG) {
				ret = gc573_seq_bankreg(h, op);
				break;
			}
			ret = gc573_seq_value(h, i, op, &v);
			if (ret)
				break;
			if (op->op == GC573_SEQ_W)
				ret = gc573_chip_wr(h, op->dev, op->bank, op->reg,
						    v);
			else
				ret = gc573_chip_mod(h, op->dev, op->bank,
						     op->reg, op->mask, v);
			break;
		default:
			ret = -EINVAL;
		}
		if (ret)
			dev_err_ratelimited(&h->gc->pdev->dev,
					    "HDMI: %s row %u failed: %d\n",
					    seq->name, op->row, ret);
	}
	if (hdmi_trace & 1)
		dev_info(&h->gc->pdev->dev, "HDMI: %s: %u of %u rows, %lld us%s\n",
			 seq->name, done, seq->n,
			 ktime_us_delta(ktime_get(), t0), ret ? ", failed" : "");
	return ret;
}
