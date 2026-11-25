// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 HDMI front-end, spec/hdmi-chips.md: probe bring-up of the IT6805
 * and the splitter with the default EDID, the IT6805-side HPD line (GPIO
 * bit 2), the poll worker that runs both chips every 50 ms, and the input
 * state it publishes to the video device.
 *
 * Locking: h->lock serialises the chips and their state (poll worker,
 * debugfs). The video device may take it under vid.lock; the worker drops
 * it before it calls into the video device. The published input state
 * (h->in) is read and written under h->slock.
 */

#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/pci.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/v4l2-dv-timings.h>
#include <linux/workqueue.h>
#include <media/v4l2-dv-timings.h>

#include "gc573.h"

/* hdmi-chips.md "Control model": the next poll 50 ms after a cycle ends */
#define GC573_HDMI_POLL_MS		50
/* hdmi-chips.md GPIO bit 2: after load RD pulses 1, 10 ms, 0, 100 ms, 1 */
#define GC573_HPD_PULSE_HIGH_MS		10
#define GC573_HPD_PULSE_LOW_MS		100
/*
 * Driver limit: polls after the AV-mute release to wait for a valid FPGA
 * frame period (0x1010) before the lock is published without it.
 */
#define GC573_HDMI_PERIOD_WAIT		20
/* frame periods (0x1010) taken as valid: 5-121 Hz */
#define GC573_PERIOD_MIN		(GC573_IN_FRAME_PERIOD_HZ / 121)
#define GC573_PERIOD_MAX		(GC573_IN_FRAME_PERIOD_HZ / 5)

/*
 * Default EDID, hdmi-chips.md "Default EDID": LNX 0x5730 serial 0 "GC573
 * Linux", EDID 1.3, digital; preferred DTD 1920x1080p60 (148.5 MHz);
 * range 23-61 Hz, 15-68 kHz, 150 MHz. CTA-861 revision 3: underscan,
 * basic audio, YCbCr 4:4:4 and 4:2:2, one native DTD; VICs 16, 31, 34,
 * 33, 32, 4, 19, 2, 3, 17, 18, 1; LPCM 2 ch 48 kHz 16/20/24 bit; speakers
 * FL/FR; HDMI VSDB 1.0.0.0, 165 MHz, no deep colour; VCDB QY = QS = 1.
 * edid-decode --check passes without warnings (tests/cases/06-hdmi-edid.sh).
 * The native mode is signalled by the DTD count rather than the VIC 16
 * native flag, and the sRGB, underscan and VCDB scan bits are set: each
 * of these is an edid-decode warning otherwise.
 */
static const u8 gc573_default_edid[GC573_EDID_SIZE] = {
	0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00,
	0x31, 0xd8, 0x30, 0x57, 0x00, 0x00, 0x00, 0x00,
	0x01, 0x24, 0x01, 0x03, 0x80, 0xa0, 0x5a, 0x78,
	0x0e, 0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26,
	0x0f, 0x50, 0x54, 0x20, 0x00, 0x00, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3a,
	0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
	0x45, 0x00, 0x40, 0x84, 0x63, 0x00, 0x00, 0x1e,
	0x00, 0x00, 0x00, 0xfd, 0x00, 0x17, 0x3d, 0x0f,
	0x44, 0x0f, 0x00, 0x0a, 0x20, 0x20, 0x20, 0x20,
	0x20, 0x20, 0x00, 0x00, 0x00, 0xfc, 0x00, 0x47,
	0x43, 0x35, 0x37, 0x33, 0x20, 0x4c, 0x69, 0x6e,
	0x75, 0x78, 0x0a, 0x20, 0x00, 0x00, 0x00, 0x10,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xe4,
	0x02, 0x03, 0x24, 0xf1, 0x4c, 0x10, 0x1f, 0x22,
	0x21, 0x20, 0x04, 0x13, 0x02, 0x03, 0x11, 0x12,
	0x01, 0x23, 0x09, 0x04, 0x07, 0x83, 0x01, 0x00,
	0x00, 0x67, 0x03, 0x0c, 0x00, 0x10, 0x00, 0x00,
	0x21, 0xe2, 0x00, 0xca, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xba,
};

/* IT6805-side HPD: GPIO bit 2, the HPD input of splitter TX port 1 */
void gc573_hdmi_hpd(struct gc573_hdmi *h, bool high)
{
	gc573_gpio_update(h->gc, GC573_GPIO_HPD, high ? GC573_GPIO_HPD : 0);
}

/* The EDID's HDMI physical address and its offset (0: no HDMI VSDB) */
u16 gc573_hdmi_edid_pa(struct gc573_hdmi *h, unsigned int *offset)
{
	unsigned int off = 0;
	u16 pa = 0xffff;

	if (h->edid_blocks > 1)
		pa = v4l2_get_edid_phys_addr(h->edid, h->edid_blocks * 128,
					     &off);
	*offset = off;
	return pa;
}

/* A detailed timing descriptor as V4L2 BT timings (pixel clock 0: none) */
static void gc573_edid_dtd(const u8 *d, struct v4l2_bt_timings *bt)
{
	u32 hblank = d[3] | (d[4] & 0x0f) << 8;
	u32 vblank = d[6] | (d[7] & 0x0f) << 8;

	memset(bt, 0, sizeof(*bt));
	bt->pixelclock = (u64)(d[0] | d[1] << 8) * 10000;
	bt->width = d[2] | (d[4] & 0xf0) << 4;
	bt->height = d[5] | (d[7] & 0xf0) << 4;
	bt->hfrontporch = d[8] | (d[11] & 0xc0) << 2;
	bt->hsync = d[9] | (d[11] & 0x30) << 4;
	bt->hbackporch = hblank - bt->hfrontporch - bt->hsync;
	bt->vfrontporch = d[10] >> 4 | (d[11] & 0x0c) << 2;
	bt->vsync = (d[10] & 0x0f) | (d[11] & 0x03) << 4;
	bt->vbackporch = vblank - bt->vfrontporch - bt->vsync;
	bt->interlaced = d[17] & 0x80 ? V4L2_DV_INTERLACED :
					V4L2_DV_PROGRESSIVE;
	/* digital separate sync: bit 2 V positive, bit 1 H positive */
	if ((d[17] & 0x18) == 0x18)
		bt->polarities = (d[17] & 0x04 ? V4L2_DV_VSYNC_POS_POL : 0) |
				 (d[17] & 0x02 ? V4L2_DV_HSYNC_POS_POL : 0);
}

static void gc573_edid_add_dtd(struct gc573_hdmi *h, const u8 *d)
{
	if (!(d[0] | d[1]) || h->edid_ndtd == ARRAY_SIZE(h->edid_dtd))
		return;
	gc573_edid_dtd(d, &h->edid_dtd[h->edid_ndtd++]);
}

/* The modes the EDID offers, for ENUM_DV_TIMINGS: CTA VICs and DTDs */
static void gc573_hdmi_edid_parse(struct gc573_hdmi *h)
{
	const u8 *e = h->edid, *c = h->edid + 128;
	unsigned int i, j, d;

	bitmap_zero(h->edid_vics, 256);
	h->edid_ndtd = 0;
	if (!h->edid_blocks)
		return;
	for (i = 54; i < 126; i += 18)
		gc573_edid_add_dtd(h, e + i);
	if (h->edid_blocks < 2 || c[0] != 0x02)
		return;
	d = c[2];
	for (i = 4; i < d && i < 127; i += 1 + (c[i] & 0x1f)) {
		if (c[i] >> 5 != 2)	/* video data block */
			continue;
		for (j = 1; j <= (c[i] & 0x1f) && i + j < d; j++) {
			u8 v = c[i + j];

			/* SVD: 129-192 carry the native flag in bit 7 */
			__set_bit(v >= 129 && v <= 192 ? v & 0x7f : v,
				  h->edid_vics);
		}
	}
	for (i = d; d >= 4 && i + 18 <= 127; i += 18)
		gc573_edid_add_dtd(h, c + i);
}

/* Does the EDID offer these timings (a preset)? */
bool gc573_hdmi_edid_offers(struct gc573 *gc, const struct v4l2_dv_timings *t)
{
	struct gc573_hdmi *h = &gc->hdmi;
	struct v4l2_dv_timings d = { .type = V4L2_DV_BT_656_1120 };
	unsigned int i;

	if ((t->bt.flags & V4L2_DV_FL_HAS_CEA861_VIC) &&
	    test_bit(t->bt.cea861_vic, h->edid_vics))
		return true;
	for (i = 0; i < h->edid_ndtd; i++) {
		d.bt = h->edid_dtd[i];
		if (v4l2_match_dv_timings(t, &d, t->bt.pixelclock / 500, false))
			return true;
	}
	return false;
}

/* VIDIOC_G_EDID semantics as in other HDMI receivers; e->pad checked */
int gc573_hdmi_get_edid(struct gc573 *gc, struct v4l2_edid *e)
{
	struct gc573_hdmi *h = &gc->hdmi;
	int ret = 0;

	mutex_lock(&h->lock);
	if (!e->start_block && !e->blocks) {
		e->blocks = h->edid_blocks;
	} else if (!h->edid_blocks) {
		ret = -ENODATA;
	} else if (e->start_block >= h->edid_blocks || !e->blocks) {
		ret = -EINVAL;
	} else {
		e->blocks = min(e->blocks, h->edid_blocks - e->start_block);
		memcpy(e->edid, h->edid + e->start_block * 128,
		       e->blocks * 128);
	}
	mutex_unlock(&h->lock);
	return ret;
}

/* ---- published input ---- */

static bool gc573_period_valid(u32 period)
{
	return period >= GC573_PERIOD_MIN && period <= GC573_PERIOD_MAX;
}

/*
 * Detected timings: the IT6805 measurement (hdmi-it6805.md 8.1) with the
 * pixel clock from the FPGA frame period (8.3), matched to a CTA-861 or
 * VESA preset when one is within 0.5 %. CTA rates that come in 1000/1001
 * variants are told apart by the measured clock.
 */
static void gc573_hdmi_timings(struct gc573_hdmi *h, u32 period,
			       struct v4l2_dv_timings *t)
{
	static const struct v4l2_dv_timings_cap any = {
		.type = V4L2_DV_BT_656_1120,
		.reserved = { 0 },
		V4L2_INIT_BT_TIMINGS(1, 8192, 1, 8192, 1, 1200000000,
				     V4L2_DV_BT_STD_CEA861 | V4L2_DV_BT_STD_DMT |
				     V4L2_DV_BT_STD_CVT | V4L2_DV_BT_STD_GTF,
				     V4L2_DV_BT_CAP_PROGRESSIVE |
				     V4L2_DV_BT_CAP_INTERLACED |
				     V4L2_DV_BT_CAP_CUSTOM)
	};
	const struct gc573_it_mode *m = &h->it.mode;
	struct v4l2_bt_timings *bt = &t->bt;
	u32 mul = (m->avi[1] >> 5 & 3) == 3 ? 2 : 1;	/* 4:2:0: TMDS clocks */
	u64 frame = (u64)m->htotal * mul * m->vtotal, meas, red;
	struct v4l2_dv_timings p;

	memset(t, 0, sizeof(*t));
	t->type = V4L2_DV_BT_656_1120;
	bt->width = m->hactive * mul;
	bt->hfrontporch = m->hfp * mul;
	bt->hsync = m->hsync * mul;
	bt->hbackporch = (m->htotal - m->hactive - m->hfp - m->hsync) * mul;
	bt->height = m->vactive;
	bt->vfrontporch = m->vfp;
	bt->vsync = m->vsync;
	bt->vbackporch = m->vtotal - m->vactive - m->vfp - m->vsync;
	bt->interlaced = m->interlaced ? V4L2_DV_INTERLACED :
					 V4L2_DV_PROGRESSIVE;
	bt->polarities = (m->hpos ? V4L2_DV_HSYNC_POS_POL : 0) |
			 (m->vpos ? V4L2_DV_VSYNC_POS_POL : 0);
	if (gc573_period_valid(period))
		bt->pixelclock = div_u64(frame * GC573_IN_FRAME_PERIOD_HZ + period / 2,
					 period);
	else
		bt->pixelclock = (u64)m->pclk_khz * 1000 * mul;
	meas = bt->pixelclock;

	p = *t;
	if (!v4l2_find_dv_timings_cap(&p, &any, meas / 200, NULL, NULL))
		return;
	*t = p;
	if (!(bt->flags & V4L2_DV_FL_CAN_REDUCE_FPS))
		return;
	red = div_u64(bt->pixelclock * 1000, 1001);
	bt->flags |= V4L2_DV_FL_CAN_DETECT_REDUCED_FPS;
	if (abs_diff(meas, red) < abs_diff(meas, bt->pixelclock))
		bt->flags |= V4L2_DV_FL_REDUCED_FPS;
}

/* Colour format, range and colorimetry from the AVI InfoFrame (9.1) */
static void gc573_hdmi_colour(struct gc573_hdmi *h, struct gc573_input *in)
{
	const u8 *pb = h->it.mode.avi;
	u8 c = pb[2] >> 6, ec = (pb[3] >> 4) & 7, q = (pb[3] >> 2) & 3;

	in->dvi = !h->it.mode.hdmi;
	if (in->dvi) {
		/* open question 31: treat DVI as full-range RGB */
		in->colour = 0;
		in->full_range = true;
		in->enc = GC573_ENC_709;
		return;
	}
	in->colour = (pb[1] >> 5) & 3;
	in->vic = pb[4];
	if (!in->colour)
		/* Q: 1 limited, 2 full; default: full for IT formats (VIC < 2) */
		in->full_range = q == 2 || (q == 0 && in->vic < 2);
	else
		in->full_range = (pb[5] >> 6) == 1;	/* YQ */
	if (c == 1 || (c == 3 && (ec == 0 || ec == 2 || ec == 3)))
		in->enc = GC573_ENC_601;
	else if (c == 3 && (ec == 5 || ec == 6))
		in->enc = GC573_ENC_2020;
	else if (c == 0 && h->it.mode.vactive < 720)
		in->enc = GC573_ENC_601;
	else
		in->enc = GC573_ENC_709;
}

static void gc573_hdmi_log_lock(struct gc573_hdmi *h,
				const struct gc573_input *in)
{
	static const char * const colours[] = {
		"RGB", "YCbCr 4:2:2", "YCbCr 4:4:4", "YCbCr 4:2:0",
	};
	const struct v4l2_bt_timings *bt = &in->timings.bt;
	u32 mhz = in->period ? div_u64(1000ULL * GC573_IN_FRAME_PERIOD_HZ, in->period) : 0;

	dev_info(&h->gc->pdev->dev,
		 "HDMI: locked: %ux%u%s, %llu Hz pixel clock%s, frame period %#x (%u.%03u Hz), %s%s, %s range; FPGA 1004 %#x 1008 %#x 100c %#x\n",
		 bt->width, bt->height, bt->interlaced ? "i" : "p",
		 bt->pixelclock,
		 bt->flags & V4L2_DV_FL_REDUCED_FPS ? " x 1000/1001" : "",
		 in->period, mhz / 1000, mhz % 1000,
		 in->dvi ? "DVI, " : "", colours[in->colour],
		 in->full_range ? "full" : "limited", in->fpga[0], in->fpga[1],
		 in->fpga[2]);
}

/*
 * Publish the input state; h->lock held. Locked: IT6805 stable with the
 * AV mute released (hdmi-it6805.md 7.7, 7.10), and the FPGA measuring a
 * frame period, or GC573_HDMI_PERIOD_WAIT polls without one. Returns true
 * when the video device has to look: lock, loss, mode or power change.
 */
static bool gc573_hdmi_publish(struct gc573_hdmi *h)
{
	struct gc573 *gc = h->gc;
	struct gc573_input in = { };
	bool changed;
	u32 period;

	in.power = h->sp.r13 & BIT(0);
	in.signal = in.power && (h->sp.r13 & BIT(3));
	period = gc573_rd(gc, GC573_IN_FRAME_PERIOD);
	in.period = gc573_period_valid(period) ? period : 0;
	in.fpga[0] = gc573_rd(gc, GC573_IN_STATUS);
	in.fpga[1] = gc573_rd(gc, GC573_IN_WIDTH);
	in.fpga[2] = gc573_rd(gc, GC573_IN_HEIGHT);

	if (h->it.state == GC573_IT_STABLE && h->it.released) {
		if (h->lock_polls < GC573_HDMI_PERIOD_WAIT)
			h->lock_polls++;
		in.locked = in.period ||
			    h->lock_polls >= GC573_HDMI_PERIOD_WAIT;
	} else {
		h->lock_polls = 0;
	}
	if (in.locked) {
		/* the rate is part of the timings: measure it once per lock */
		if (h->in.locked && h->in.period)
			in.timings = h->in.timings;
		else
			gc573_hdmi_timings(h, in.period, &in.timings);
		gc573_hdmi_colour(h, &in);
		in.dual = h->it.mode.dual;
		in.ddr = h->it.mode.ddr;
	}

	spin_lock(&h->slock);
	changed = in.power != h->in.power || in.locked != h->in.locked ||
		  (in.locked &&
		   (!v4l2_match_dv_timings(&in.timings, &h->in.timings, 0,
					   true) ||
		    in.colour != h->in.colour ||
		    in.full_range != h->in.full_range ||
		    in.enc != h->in.enc || in.dvi != h->in.dvi));
	h->in = in;
	spin_unlock(&h->slock);

	if (changed && in.locked)
		gc573_hdmi_log_lock(h, &in);
	else if (changed)
		dev_info(&gc->pdev->dev, "HDMI: %s\n",
			 !in.power ? "no 5 V" :
			 !in.signal ? "5 V, no signal" : "signal, not locked");
	return changed;
}

void gc573_hdmi_input(struct gc573 *gc, struct gc573_input *in)
{
	struct gc573_hdmi *h = &gc->hdmi;

	spin_lock(&h->slock);
	*in = h->in;
	spin_unlock(&h->slock);
}

/* ---- poll worker ---- */

static void gc573_hdmi_poll(struct work_struct *work)
{
	struct gc573_hdmi *h = container_of(to_delayed_work(work),
					    struct gc573_hdmi, poll);
	ktime_t t0 = ktime_get();
	bool changed;
	int r1, r2;
	u32 ms;

	mutex_lock(&h->lock);
	gc573_chip_begin(h);
	r1 = gc573_sp_poll(h);
	r2 = gc573_it6805_poll(h);
	gc573_chip_end(h);
	h->polls++;
	if (r1 || r2)
		h->poll_errors++;
	changed = gc573_hdmi_publish(h);
	ms = ktime_ms_delta(ktime_get(), t0);
	h->poll_ms_max = max(h->poll_ms_max, ms);
	mutex_unlock(&h->lock);

	if (changed)
		gc573_video_input_changed(h->gc);
	if (READ_ONCE(h->polling))
		queue_delayed_work(h->wq, &h->poll,
				   msecs_to_jiffies(GC573_HDMI_POLL_MS));
}

static void gc573_hdmi_stop_polling(struct gc573_hdmi *h)
{
	WRITE_ONCE(h->polling, false);
	cancel_delayed_work_sync(&h->poll);
}

/* ---- bring-up and teardown ---- */

/*
 * hdmi-chips.md "Bring-up order", hdmi-it6805.md 12: port 1 HPD low; the
 * IT6805 init with its EDID RAM (its 0xe0 access comes before the splitter
 * maps 0xe0); the splitter init and its EDID RAM; then RD's HPD pulse.
 * The source sees HPD only once the splitter has 5 V and the EDID (poll).
 * The FPGA init has waited >= 50 ms after the chip resets.
 */
static void gc573_hdmi_destroy_wq(void *data)
{
	struct gc573_hdmi *h = data;

	destroy_workqueue(h->wq);
	h->wq = NULL;
}

int gc573_hdmi_init(struct gc573 *gc)
{
	struct gc573_hdmi *h = &gc->hdmi;
	struct device *dev = &gc->pdev->dev;
	int ret;

	h->gc = gc;
	mutex_init(&h->lock);
	spin_lock_init(&h->slock);
	INIT_DELAYED_WORK(&h->poll, gc573_hdmi_poll);
	h->bank[0] = (struct gc573_chip_bank){ GC573_DEV_IT6805, 0x07, -1 };
	h->bank[1] = (struct gc573_chip_bank){ GC573_DEV_SP, 0x01, -1 };
	h->bank[2] = (struct gc573_chip_bank){ GC573_DEV_SP_RX, 0x03, -1 };
	memcpy(h->edid, gc573_default_edid, sizeof(h->edid));
	h->edid_blocks = 2;
	gc573_hdmi_edid_parse(h);

	gc573_hdmi_hpd(h, false);
	mutex_lock(&h->lock);
	gc573_chip_begin(h);
	ret = gc573_it6805_init(h);
	if (!ret)
		ret = gc573_sp_init(h);
	if (!ret) {
		ret = gc573_sp_edid(h, false);
		if (ret)
			dev_err(dev, "splitter EDID load failed: %d\n", ret);
	}
	gc573_chip_end(h);
	mutex_unlock(&h->lock);
	if (ret) {
		h->failed = true;
		return ret;
	}

	gc573_hdmi_hpd(h, true);
	msleep(GC573_HPD_PULSE_HIGH_MS);
	gc573_hdmi_hpd(h, false);
	msleep(GC573_HPD_PULSE_LOW_MS);
	gc573_hdmi_hpd(h, true);

	h->wq = alloc_ordered_workqueue("gc573-hdmi-%s", 0, pci_name(gc->pdev));
	if (!h->wq)
		return -ENOMEM;
	return devm_add_action_or_reset(dev, gc573_hdmi_destroy_wq, h);
}

/*
 * Remove: polling stops, then the source and port 1 HPD go low so the
 * source sees the capture card leave (a design choice; RD writes nothing
 * at unload, hdmi-chips.md "Driver notes").
 */
static void gc573_hdmi_stop(void *data)
{
	struct gc573_hdmi *h = data;

	gc573_hdmi_stop_polling(h);
	mutex_lock(&h->lock);
	gc573_chip_begin(h);
	gc573_sp_hpd_low(h);
	gc573_chip_end(h);
	mutex_unlock(&h->lock);
	gc573_hdmi_hpd(h, false);
}

/* After the video device exists: start polling, stop it first at remove */
int gc573_hdmi_start(struct gc573 *gc)
{
	struct gc573_hdmi *h = &gc->hdmi;

	h->polling = true;
	queue_delayed_work(h->wq, &h->poll, 0);
	return devm_add_action_or_reset(&gc->pdev->dev, gc573_hdmi_stop, h);
}

/* Reboot: no chip access, only make sure the worker is gone */
void gc573_hdmi_shutdown(struct gc573 *gc)
{
	if (gc->hdmi.wq)
		gc573_hdmi_stop_polling(&gc->hdmi);
}

/* ---- debugfs ---- */

static int gc573_hdmi_debugfs_show(struct seq_file *m, void *unused)
{
	struct gc573 *gc = m->private;
	struct gc573_hdmi *h = &gc->hdmi;
	struct gc573_input in;

	mutex_lock(&h->lock);
	seq_printf(m, "hdmi: polling %d failed %d polls %u poll_errors %u poll_ms_max %u xfers %u xfer_errors %u retries %u resyncs %u runs %u lock_polls %u gpio %#010x\n",
		   h->polling, h->failed, h->polls, h->poll_errors,
		   h->poll_ms_max, h->xfers, h->xfer_errors, h->retries,
		   h->resyncs, h->runs, h->lock_polls,
		   gc573_rd(gc, GC573_GPIO));
	gc573_it6805_show(h, m);
	gc573_sp_show(h, m);
	mutex_unlock(&h->lock);

	gc573_hdmi_input(gc, &in);
	seq_printf(m, "input: power %d signal %d locked %d period %#x fpga %#x %#x %#x colour %u vic %u full_range %d enc %u dvi %d dual %d ddr %d\n",
		   in.power, in.signal, in.locked, in.period, in.fpga[0],
		   in.fpga[1], in.fpga[2], in.colour, in.vic, in.full_range,
		   in.enc, in.dvi, in.dual, in.ddr);
	if (in.locked)
		seq_printf(m, "timings: %ux%u%s pixelclock %llu flags %#x vic %u h %u/%u/%u v %u/%u/%u pol %#x\n",
			   in.timings.bt.width, in.timings.bt.height,
			   in.timings.bt.interlaced ? "i" : "p",
			   in.timings.bt.pixelclock, in.timings.bt.flags,
			   in.timings.bt.cea861_vic, in.timings.bt.hfrontporch,
			   in.timings.bt.hsync, in.timings.bt.hbackporch,
			   in.timings.bt.vfrontporch, in.timings.bt.vsync,
			   in.timings.bt.vbackporch, in.timings.bt.polarities);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(gc573_hdmi_debugfs);

void gc573_hdmi_debugfs(struct gc573 *gc)
{
	debugfs_create_file("hdmi", 0444, gc->debugfs, gc,
			    &gc573_hdmi_debugfs_fops);
}
