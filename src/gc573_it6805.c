// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 IT6805 HDMI receiver, spec/hdmi-it6805.md: probe initialisation
 * and its X steps, the EDID RAM, power modes, and the poll with the video
 * and audio state machines and the stable entry that sets the output bus.
 * Section numbers below are that chapter's.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/minmax.h>
#include <linux/pci.h>
#include <linux/seq_file.h>
#include <linux/string.h>

#include "gc573.h"

#define IT			GC573_DEV_IT6805

/* 1.1 */
static const u8 gc573_it_id[4] = { 0x54, 0x49, 0x05, 0x68 };
#define GC573_IT_REV		0xb1

/* 3.3: flags polled every 10 ms, 5 reads per trigger, 6 re-triggers */
#define GC573_IT_CAL_POLL_MS	10
#define GC573_IT_CAL_READS	5
#define GC573_IT_CAL_RETRIGGERS	6
#define GC573_IT_CAL_PULSE_MS	10

/* 3.4 */
#define GC573_IT_F_MIN		25000
#define GC573_IT_F_MAX		70000
#define GC573_IT_F_DEFAULT	43000

/* 7.5: the stable entry runs in the 4th poll after the one that saw sync */
#define GC573_IT_DEBOUNCE_POLLS	4
/*
 * Driver limit: polls to wait at the end of DEBOUNCE for the entry
 * conditions (7.5) and the splitter unmute (hdmi-chips.md) before going
 * back to WAIT_SYNC.
 */
#define GC573_IT_ENTRY_WAIT	40

/* 8.2, 8.3: 5 pixel-counter samples 3 ms apart; reference on this unit */
#define GC573_IT_PCLK_SAMPLES	5
#define GC573_IT_PCLK_GAP_MS	3
#define GC573_IT_FREF_KHZ	23400

/* 10.1 rule b on the true clock; 10.2 1:b0 bit 0 */
#define GC573_IT_SINGLE_MAX_KHZ	170000
#define GC573_IT_B0_MIN_KHZ	25000

/* 11.1: WAIT_READY re-checks every 3rd poll, ON reads status every 4th */
#define GC573_IT_AUDIO_COUNT	2
#define GC573_IT_AUDIO_POLL	4

/* ---- X steps of the init (section 3) ---- */

/* 3.3: wait for both ports' calibration flags, with RD's retry rule */
static int gc573_it_cal_wait(struct gc573_hdmi *h)
{
	static const u8 flag[2] = { 0x08, 0x0d }, trig[2] = { 0x2a, 0x32 };
	static const u8 phy[2] = { 3, 7 };
	struct gc573_it6805 *it = &h->it;
	unsigned int reads = 0, retrig = 0, p;
	bool done[2] = { false, false };
	int ret;
	u8 v;

	for (;;) {
		for (p = 0; p < 2; p++) {
			if (done[p])
				continue;
			ret = gc573_chip_rd(h, IT, 0, flag[p], &v);
			if (ret)
				return ret;
			done[p] = v & 0x30;
		}
		if (done[0] && done[1])
			return 0;
		if (++reads < GC573_IT_CAL_READS) {
			gc573_chip_sleep(h, GC573_IT_CAL_POLL_MS);
			continue;
		}
		if (retrig == GC573_IT_CAL_RETRIGGERS)
			break;
		retrig++;
		it->cal_retrigger++;
		for (p = 0; p < 2 && !ret; p++)
			if (!done[p])
				ret = gc573_chip_mod(h, IT, 0, trig[p], 0x40, 0x40);
		gc573_chip_sleep(h, GC573_IT_CAL_PULSE_MS);
		for (p = 0; p < 2 && !ret; p++)
			if (!done[p])
				ret = gc573_chip_mod(h, IT, 0, trig[p], 0x40, 0x00);
		if (ret)
			return ret;
		reads = 0;
	}

	/* give up: per unfinished port clear 3:3a / 7:3a bit 7, pulse again */
	for (p = 0; p < 2; p++) {
		if (done[p])
			continue;
		dev_err(&h->gc->pdev->dev,
			"IT6805: port %u calibration did not finish\n", p);
		ret = gc573_chip_mod(h, IT, phy[p], 0x3a, 0x80, 0x00);
		if (!ret)
			ret = gc573_chip_mod(h, IT, 0, trig[p], 0x40, 0x40);
		gc573_chip_sleep(h, GC573_IT_CAL_PULSE_MS);
		if (!ret)
			ret = gc573_chip_mod(h, IT, 0, trig[p], 0x40, 0x00);
		if (ret)
			return ret;
	}
	return 0;
}

/* 3.4 step 2: one factory-data read cycle (bank 1) */
static int gc573_it_otp(struct gc573_hdmi *h, u8 hi, u8 lo, u8 *a, u8 *b)
{
	int ret;

	ret = gc573_chip_wr(h, IT, 1, 0x50, hi);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 1, 0x51, lo);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 1, 0x54, 0x04);
	if (!ret)
		ret = gc573_chip_rd(h, IT, 1, 0x61, a);
	if (!ret)
		ret = gc573_chip_rd(h, IT, 1, 0x62, b);
	return ret;
}

/* 3.4 steps 3-5 and the trim formula; the trim is written by IT_TRIM */
static int gc573_it_factory(struct gc573_hdmi *h)
{
	struct gc573_it6805 *it = &h->it;
	u8 a, b, a2, b2, a0, b0, a1, b1, base = 0;
	u32 raw, f = 0;
	int ret;

	ret = gc573_it_otp(h, 0x00, 0x00, &a, &b);
	if (!ret)
		ret = gc573_it_otp(h, 0x00, 0x01, &a2, &b2);
	if (ret)
		return ret;
	if (a == 0xff && b == 0xff && a2 == 0x00 && b2 == 0x00)
		base = 0x04;

	ret = gc573_it_otp(h, base, 0xb0, &a0, &b0);
	if (!ret)
		ret = gc573_it_otp(h, base, 0xb1, &a1, &b1);
	if (ret)
		return ret;

	raw = (u32)a1 << 16 | (u32)b0 << 8 | a0;
	if ((b1 & 0xc0) == 0xc0)
		f = raw / 100;
	if (f < GC573_IT_F_MIN || f > GC573_IT_F_MAX) {
		dev_warn(&h->gc->pdev->dev,
			 "IT6805: factory value %06x (flags %02x) invalid, using %u kHz\n",
			 raw, b1, GC573_IT_F_DEFAULT);
		f = GC573_IT_F_DEFAULT;
	}
	it->f_khz = f;
	it->trim = clamp(((int)(6560000 / f) - 93) / 4, 3, 29);
	return 0;
}

/*
 * Section 4 steps 3-7: both EDID blocks into the RAM at 0xa8 (offsets 7f
 * and ff are not written), the checksums and the physical address into
 * the port registers. Port 1 is unused; it gets RD's 2.0.0.0.
 */
static int gc573_it_edid_load(struct gc573_hdmi *h)
{
	const u8 *e = h->edid;
	unsigned int i, off;
	u8 ck0 = 0, ck1 = 0;
	int ret = 0;

	for (i = 0x00; i < 0x7f && !ret; i++) {
		ret = gc573_chip_wr(h, GC573_DEV_IT_EDID, GC573_SEQ_NOBANK, i,
				    e[i]);
		ck0 -= e[i];
	}
	if (!ret)
		ret = gc573_chip_wr(h, IT, 0, 0xc9, ck0);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 4, 0xc9, ck0);
	for (i = 0x80; i < 0xff && !ret; i++) {
		ret = gc573_chip_wr(h, GC573_DEV_IT_EDID, GC573_SEQ_NOBANK, i,
				    e[i]);
		ck1 -= e[i];
	}
	if (ret)
		return ret;

	gc573_hdmi_edid_pa(h, &off);
	if (!off) {
		/* no HDMI VSDB: block-1 checksum only (UNVERIFIED, section 4) */
		ret = gc573_chip_wr(h, IT, 0, 0xca, ck1);
		return ret ?: gc573_chip_wr(h, IT, 4, 0xca, ck1);
	}

	ret = gc573_chip_wr(h, IT, 0, 0xc6, off);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 0, 0xc7, e[off]);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 0, 0xc8, e[off + 1]);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 0, 0xca, ck1);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 4, 0xc7, 0x20);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 4, 0xc8, 0x00);
	if (!ret)
		ret = gc573_chip_wr(h, IT, 4, 0xca,
				    (u8)(ck1 + e[off] + e[off + 1] - 0x20));
	return ret;
}

/* ---- stable entry (sections 7.6, 8, 10) ---- */

/* 8.1 timing registers and 8.2 pixel counter; X step of it-lock row 2 */
static int gc573_it_measure(struct gc573_hdmi *h)
{
	struct gc573_it_mode *m = &h->it.mode;
	u8 r[0xab - 0x98], hi, lo;
	unsigned int i, sum = 0;
	int ret = 0;

	for (i = 0; i < sizeof(r) && !ret; i++)
		ret = gc573_chip_rd(h, IT, 0, 0x98 + i, &r[i]);
	if (ret)
		return ret;
#define R(reg)	r[(reg) - 0x98]
	m->htotal = R(0x9b) + 256 * (R(0x9c) & 0x3f);
	m->hactive = R(0x9d) + 256 * (R(0x9e) & 0x3f);
	m->hfp = R(0xa0) + 256 * (R(0xa1) >> 4);
	m->hsync = R(0x9f) + 256 * (R(0xa1) & 1);
	m->vtotal = R(0xa2) + 256 * (R(0xa3) & 0x3f);
	m->vactive = R(0xa4) + 256 * (R(0xa5) & 0x3f);
	m->vfp = R(0xa7) + 256 * (R(0xa8) >> 4);
	m->vsync = R(0xa6) + 256 * (R(0xa8) & 1);
	m->interlaced = R(0x98) & BIT(1);
	m->hpos = R(0xaa) & BIT(5);
	m->vpos = R(0xaa) & BIT(6);
#undef R

	for (i = 0; i < GC573_IT_PCLK_SAMPLES && !ret; i++) {
		if (i)
			gc573_chip_sleep(h, GC573_IT_PCLK_GAP_MS);
		ret = gc573_chip_mod(h, IT, 0, 0x9a, 0x80, 0x00);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x9a, &hi);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x99, &lo);
		if (!ret)
			ret = gc573_chip_mod(h, IT, 0, 0x9a, 0x80, 0x80);
		sum += (hi & 7) << 8 | lo;
	}
	if (ret)
		return ret;
	m->pclk_khz = sum ? GC573_IT_FREF_KHZ * 2560 / sum : 0;

	/* inputs of the MODE rows that come before the table reads them */
	ret = gc573_chip_rd(h, IT, 0, 0x13, &hi);
	if (!ret)
		m->hdmi = hi & BIT(1);
	return ret;
}

static u8 gc573_it_avi_y(struct gc573_hdmi *h)
{
	return (h->it.mode.avi[1] >> 5) & 3;
}

/*
 * Section 10.1, first matching rule: a 4:2:0 -> dual SDR; b H <= 1920 and
 * clock <= 170 MHz -> single SDR; c H < 1920 and V < 2160 -> single SDR;
 * d -> dual DDR. H counts pixels (doubled for 4:2:0).
 */
static void gc573_it_bus(struct gc573_hdmi *h)
{
	struct gc573_it_mode *m = &h->it.mode;
	u8 y = gc573_it_avi_y(h);
	u32 hpix = m->hactive * (y == 3 ? 2 : 1);

	m->dual = true;
	m->ddr = false;
	if (y == 3)
		return;
	if ((hpix <= 1920 && m->pclk_khz <= GC573_IT_SINGLE_MAX_KHZ) ||
	    (hpix < 1920 && m->vactive < 2160)) {
		m->dual = false;
		return;
	}
	m->ddr = true;
}

/* 10.3: colour code at 0:6b[5:4] (input) and [3:2] (output). DVI: 1. */
static u8 gc573_it_colour(struct gc573_hdmi *h)
{
	return h->it.mode.hdmi ? gc573_it_avi_y(h) : 1;
}

int gc573_it6805_var(struct gc573_hdmi *h, unsigned int var, u8 *val)
{
	struct gc573_it_mode *m = &h->it.mode;
	u8 v;

	switch (var) {
	case GC573_SEQ_V_IT_B0:
		/* 10.2: pixel clock / repetition >= 25 MHz; 0:1b[5:4] */
		if (gc573_seq_last(h, ~0U, IT, 0, 0x1b, &v))
			m->rep = ((v >> 4) & 3) + 1;
		*val = m->pclk_khz / max_t(u8, m->rep, 1) >= GC573_IT_B0_MIN_KHZ;
		return 0;
	case GC573_SEQ_V_IT_DDR:
		/* rows 7-11 have read the AVI by now */
		for (v = 0; v < 5; v++)
			gc573_seq_last(h, ~0U, IT, 2, 0x15 + v, &m->avi[1 + v]);
		gc573_it_bus(h);
		*val = m->ddr ? 0x02 : 0x00;
		return 0;
	case GC573_SEQ_V_IT_OCOL:
		*val = gc573_it_colour(h) << 2;
		return 0;
	case GC573_SEQ_V_IT_BD:
		*val = m->dual ? 0x10 : 0x00;
		return 0;
	case GC573_SEQ_V_IT_C4:
		*val = m->dual && m->ddr ? 0x10 : 0x00;
		return 0;
	case GC573_SEQ_V_IT_ICOL:
		*val = gc573_it_colour(h) << 4;
		return 0;
	case GC573_SEQ_V_IT_DVI:
		*val = !m->hdmi;
		return 0;
	case GC573_SEQ_V_IT_DEPTH:
		/* 10.3 step 5 from 0:98[7:4] (row 58) */
		m->dc = gc573_seq_last(h, ~0U, IT, 0, 0x98, &v) ? v >> 4 : 0;
		*val = m->dc == 5 ? 1 : m->dc == 6 ? 2 : 0;
		return 0;
	}
	return -EINVAL;
}

/* 10.5 unblank value: single pixel W 1:c5 18, dual W 1:c6 00 */
static int gc573_it_unblank_value(struct gc573_hdmi *h)
{
	if (h->it.mode.dual)
		return gc573_chip_wr(h, IT, 1, 0xc6, 0x00);
	return gc573_chip_wr(h, IT, 1, 0xc5, 0x18);
}

int gc573_it6805_x(struct gc573_hdmi *h, unsigned int x)
{
	switch (x) {
	case GC573_SEQ_X_IT_CAL_WAIT:
		return gc573_it_cal_wait(h);
	case GC573_SEQ_X_IT_FACTORY_READ:
		return gc573_it_factory(h);
	case GC573_SEQ_X_IT_TRIM:
		return gc573_chip_mod(h, IT, 3, 0xaa, 0x1f, h->it.trim);
	case GC573_SEQ_X_IT_HPD_LOW:
		gc573_hdmi_hpd(h, false);
		return 0;
	case GC573_SEQ_X_IT_EDID_LOAD:
		return gc573_it_edid_load(h);
	case GC573_SEQ_X_IT_MEASURE:
		return gc573_it_measure(h);
	case GC573_SEQ_X_IT_DUAL:
		/* 10.2: dual pixel only, M 1:c0 01 01 */
		if (!h->it.mode.dual)
			return 0;
		return gc573_chip_mod(h, IT, 1, 0xc0, 0x01, 0x01);
	case GC573_SEQ_X_IT_UNBLANK:
		return gc573_it_unblank_value(h);
	}
	return -EINVAL;
}

/* ---- states ---- */

/* 10.5: outputs tristated (no stable video) */
static int gc573_it_tristate(struct gc573_hdmi *h)
{
	int ret = gc573_chip_wr(h, IT, 1, 0xc5, 0xff);

	return ret ?: gc573_chip_wr(h, IT, 1, 0xc6, 0xff);
}

/* 11.2 off: M 0:81 40 00; W 1:c7 7f */
static int gc573_it_audio_off(struct gc573_hdmi *h)
{
	int ret;

	h->it.audio = GC573_AUD_OFF;
	ret = gc573_chip_mod(h, IT, 0, 0x81, 0x40, 0x00);
	return ret ?: gc573_chip_wr(h, IT, 1, 0xc7, 0x7f);
}

/* 7.5 WAIT_SYNC entry: tristate, clear the stable flags */
static int gc573_it_wait_sync(struct gc573_hdmi *h)
{
	struct gc573_it6805 *it = &h->it;

	if (it->state == GC573_IT_STABLE)
		it->losses++;
	it->state = GC573_IT_WAIT_SYNC;
	it->released = false;
	it->recheck = false;
	return gc573_it_tristate(h);
}

/* 7.4: 0:05 bit 0, and the NO_5V poll of 0:13 */
static int gc573_it_5v(struct gc573_hdmi *h, bool on)
{
	struct gc573_it6805 *it = &h->it;
	int ret = 0;

	if (!on) {
		if (it->state == GC573_IT_STABLE)
			it->losses++;
		gc573_hdmi_hpd(h, false);
		ret = gc573_seq_run(h, &gc573_seq_it_unplug, 0);
		if (!ret)
			ret = gc573_seq_run(h, &gc573_seq_it_saving, 0);
		it->power = GC573_IT_SAVING;
		it->state = GC573_IT_NO_5V;
		it->normal_armed = false;
		it->sync = false;
		it->released = false;
		it->recheck = false;
		it->audio = GC573_AUD_OFF;
		return ret;
	}

	if (it->power == GC573_IT_SAVING) {
		ret = gc573_seq_run(h, &gc573_seq_it_standby, 0);
		if (ret)
			return ret;
		it->power = GC573_IT_STANDBY;
	}
	it->normal_armed = true;
	ret = gc573_it_wait_sync(h);
	gc573_hdmi_hpd(h, true);
	return ret;
}

/* 7.4 sync on: M 0:40 03 00, DEBOUNCE. Off: M 0:40 03 02, WAIT_SYNC. */
static int gc573_it_sync(struct gc573_hdmi *h, bool on)
{
	struct gc573_it6805 *it = &h->it;
	int ret;

	if (on == it->sync)
		return 0;
	it->sync = on;
	if (on) {
		it->state = GC573_IT_DEBOUNCE;
		it->debounce = GC573_IT_DEBOUNCE_POLLS;
		it->wait = 0;
		return gc573_chip_mod(h, IT, 0, 0x40, 0x03, 0x00);
	}
	ret = gc573_chip_mod(h, IT, 0, 0x40, 0x03, 0x02);
	if (!ret)
		ret = gc573_it_wait_sync(h);
	return ret ?: gc573_it_audio_off(h);
}

/* 7.6 */
static int gc573_it_entry(struct gc573_hdmi *h)
{
	struct gc573_it6805 *it = &h->it;
	struct device *dev = &h->gc->pdev->dev;
	struct gc573_it_mode *m = &it->mode;
	int ret;

	memset(m, 0, sizeof(*m));
	m->rep = 1;
	ret = gc573_seq_run(h, &gc573_seq_it_lock, 0);
	if (ret)
		return ret;

	it->state = GC573_IT_STABLE;
	it->entries++;
	it->released = false;
	it->recheck = false;
	it->param_ignore = true;
	/* rows 79-80 pulsed 0:8c bit 4: audio is in WAIT_READY (7.6 step 11) */
	it->audio = GC573_AUD_WAIT_READY;
	it->audio_count = GC573_IT_AUDIO_COUNT;
	h->lock_polls = 0;

	dev_info(dev,
		 "IT6805: stable: %ux%u%s total %ux%u, %u kHz, %s, AVI %*ph, %s%s\n",
		 m->hactive, m->vactive, m->interlaced ? "i" : "p", m->htotal,
		 m->vtotal, m->pclk_khz, m->hdmi ? "HDMI" : "DVI", 5,
		 &m->avi[1], m->dual ? "dual pixel" : "single pixel",
		 m->ddr ? " DDR" : "");
	if (!m->hdmi)
		dev_warn(dev, "IT6805: DVI input is untraced (open question 31)\n");
	return 0;
}

/* 7.7 release, then the unblank value again (UNVERIFIED rewrite, 7.7) */
static int gc573_it_release(struct gc573_hdmi *h)
{
	struct gc573_it6805 *it = &h->it;
	int ret;

	ret = gc573_chip_mod(h, IT, 1, 0xc5, 0x01, 0x01);
	if (!ret)
		ret = gc573_chip_mod(h, IT, 1, 0xc5, 0x01, 0x00);
	if (!ret && it->mode.dual)
		ret = gc573_chip_mod(h, IT, 1, 0xc5, 0x01, 0x01);
	if (!ret)
		ret = gc573_chip_mod(h, IT, 0, 0x4f, 0xa0, 0xa0);
	if (!ret)
		ret = gc573_chip_mod(h, IT, 0, 0x4f, 0xa0, 0x80);
	/* 10.5 unblank */
	if (!ret)
		ret = gc573_chip_mod(h, IT, 1, 0xc5, 0x80, 0x00);
	if (!ret)
		ret = gc573_chip_mod(h, IT, 1, 0xc6, 0x80, 0x00);
	if (!ret)
		ret = gc573_it_unblank_value(h);
	if (!ret) {
		it->released = true;
		it->releases++;
	}
	return ret;
}

/* 7.8: has the input changed under a STABLE entry? */
static int gc573_it_recheck(struct gc573_hdmi *h, bool *changed)
{
	struct gc573_it_mode *m = &h->it.mode;
	u8 r[0xa6 - 0x98], pb1;
	unsigned int i;
	int ret = 0;

	for (i = 0; i < sizeof(r) && !ret; i++)
		ret = gc573_chip_rd(h, IT, 0, 0x98 + i, &r[i]);
	if (!ret)
		ret = gc573_chip_rd(h, IT, 2, 0x15, &pb1);
	if (ret)
		return ret;
	*changed = m->htotal != r[0x9b - 0x98] + 256 * (r[0x9c - 0x98] & 0x3f) ||
		   m->hactive != r[0x9d - 0x98] + 256 * (r[0x9e - 0x98] & 0x3f) ||
		   m->vtotal != r[0xa2 - 0x98] + 256 * (r[0xa3 - 0x98] & 0x3f) ||
		   m->vactive != r[0xa4 - 0x98] + 256 * (r[0xa5 - 0x98] & 0x3f) ||
		   m->interlaced != !!(r[0] & BIT(1)) ||
		   (m->hdmi && ((pb1 ^ m->avi[1]) & 0x60));
	return 0;
}

/* 11.1 */
static int gc573_it_audio_step(struct gc573_hdmi *h)
{
	struct gc573_it6805 *it = &h->it;
	u8 b9, s19, e10, st[3];
	unsigned int i;
	int ret = 0;

	switch (it->audio) {
	case GC573_AUD_OFF:
		return 0;
	case GC573_AUD_WAIT_READY:
		if (it->audio_count) {
			it->audio_count--;
			return 0;
		}
		it->audio_count = GC573_IT_AUDIO_COUNT;
		ret = gc573_chip_rd(h, IT, 0, 0xb9, &b9);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x19, &s19);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x10, &e10);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0xb1, &st[1]);
		if (ret)
			return ret;
		if (b9 & 0xc0)
			dev_dbg_ratelimited(&h->gc->pdev->dev,
					    "IT6805: 0:b9 = %02x, audio logic reset untraced: skipped\n",
					    b9);
		if (!(s19 & BIT(7)) || !(st[1] & BIT(7)) || (e10 & BIT(7)))
			return 0;
		/* 11.2 on */
		ret = gc573_chip_mod(h, IT, 0, 0x86, 0x01, 0x01);
		if (!ret)
			ret = gc573_chip_wr(h, IT, 1, 0xc7, 0x00);
		it->audio = GC573_AUD_ON;
		it->audio_poll = 0;
		it->audio_stored = false;
		return ret;
	case GC573_AUD_ON:
		if (++it->audio_poll % GC573_IT_AUDIO_POLL)
			return 0;
		for (i = 0; i < 3 && !ret; i++)
			ret = gc573_chip_rd(h, IT, 0, 0xb0 + i, &st[i]);
		if (ret)
			return ret;
		if (!it->audio_stored) {
			memcpy(it->audio_st, st, sizeof(st));
			it->audio_stored = true;
			return gc573_chip_mod(h, IT, 0, 0x8c, 0x08,
					      (st[2] & BIT(1)) << 2);
		}
		if (!((st[0] ^ it->audio_st[0]) & 0xf0) &&
		    st[1] == it->audio_st[1] &&
		    !((st[2] ^ it->audio_st[2]) & BIT(1)))
			return 0;
		/* REQUEST, then WAIT_READY in the same poll */
		ret = gc573_it_audio_off(h);
		if (!ret)
			ret = gc573_chip_mod(h, IT, 0, 0x8c, 0x10, 0x10);
		if (!ret)
			ret = gc573_chip_mod(h, IT, 0, 0x8c, 0x10, 0x00);
		it->audio = GC573_AUD_WAIT_READY;
		it->audio_count = GC573_IT_AUDIO_COUNT;
		return ret;
	}
	return 0;
}

/* Read an event register and write back (value & keep): 7.3 */
static int gc573_it_ack(struct gc573_hdmi *h, u8 reg, u8 keep, u8 *val)
{
	int ret = gc573_chip_rd(h, IT, 0, reg, val);

	return ret ?: gc573_chip_wr(h, IT, 0, reg, *val & keep);
}

/* One poll cycle, 7.2 */
int gc573_it6805_poll(struct gc573_hdmi *h)
{
	struct gc573_it6805 *it = &h->it;
	u8 e05, e06, e08, e09, e10, e11, e12, e1d, v, s15;
	enum gc573_it_state st0 = it->state;
	bool entered, changed;
	int ret = 0;

	it->polls++;
	/* 1 */
	if (it->first_poll) {
		ret = gc573_chip_mod(h, IT, 0, 0x6e, 0x02, 0x02);
		if (ret)
			return ret;
		it->first_poll = false;
	}

	/*
	 * 2, the DRM check, is left out: it reads 6:10 for RD's DRM state,
	 * which nothing uses (9.2); step 4 acknowledges 0:12 bit 5 anyway.
	 */

	if (st0 != GC573_IT_NO_5V) {
		/* 3 */
		ret = gc573_it_ack(h, 0x05, 0xff, &e05);
		if (!ret)
			ret = gc573_it_ack(h, 0x06, 0xff, &e06);
		if (!ret)
			ret = gc573_it_ack(h, 0x08, 0xff, &e08);
		if (!ret)
			ret = gc573_it_ack(h, 0x09, 0xff, &e09);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x13, &it->r13);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x14, &it->r14);
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x15, &s15);
		if (ret)
			return ret;
		if (e05 & BIT(0))
			ret = gc573_it_5v(h, it->r13 & BIT(0));
		if (!ret && (e05 & BIT(1)) && it->normal_armed) {
			ret = gc573_seq_run(h, &gc573_seq_it_normal, 0);
			it->power = GC573_IT_NORMAL;
			it->normal_armed = false;
		}
		if (!ret && (e08 & BIT(0)) && it->state >= GC573_IT_DEBOUNCE)
			ret = gc573_it_wait_sync(h);
		if (!ret && (e08 & BIT(7)))
			ret = gc573_chip_mod(h, IT, 0, 0x4c, 0x80, 0x80);
		if (ret)
			return ret;

		/* 4 */
		ret = gc573_it_ack(h, 0x10, 0xff, &e10);
		if (!ret)
			ret = gc573_it_ack(h, 0x11, 0xbf, &e11);
		if (!ret)
			ret = gc573_it_ack(h, 0x12, 0x7f, &e12);
		if (!ret)
			ret = gc573_it_ack(h, 0x1d, 0xff, &e1d);
		if (!ret)
			ret = gc573_it_ack(h, 0xd4, 0xff, &v);
		if (!ret)
			ret = gc573_it_ack(h, 0xd5, 0xff, &v);
		if (ret)
			return ret;
		if ((e10 & BIT(1)) && it->state != GC573_IT_NO_5V) {
			ret = gc573_chip_rd(h, IT, 0, 0x19, &it->r19);
			if (!ret)
				ret = gc573_it_sync(h, it->r19 & BIT(7));
		}
		if (!ret && (e10 & BIT(4)) && it->state == GC573_IT_STABLE) {
			/* 7.7 AV mute on */
			ret = gc573_chip_mod(h, IT, 0, 0x4f, 0xa0, 0xa0);
			if (!ret)
				ret = gc573_chip_mod(h, IT, 1, 0xc5, 0x80, 0x80);
			it->released = false;
		}
		if (!ret && (e12 & BIT(0))) {
			ret = gc573_chip_rd(h, IT, 2, 0x14, &v);
			if (!ret)
				ret = gc573_chip_rd(h, IT, 2, 0x15, &e11);
			if (!ret && it->state == GC573_IT_STABLE &&
			    (v != it->avi_store[0] || e11 != it->avi_store[1]))
				it->recheck = true;
			it->avi_store[0] = v;
			it->avi_store[1] = e11;
		}
		if (!ret && (e12 & BIT(7))) {
			ret = gc573_chip_rd(h, IT, 0, 0x1a, &v);
			if (!ret)
				ret = gc573_chip_rd(h, IT, 0, 0x1b, &v);
			if (!ret)
				ret = gc573_chip_wr(h, IT, 0, 0x12, 0x80);
			if (!ret && it->state == GC573_IT_STABLE) {
				if (it->param_ignore)
					it->param_ignore = false;
				else
					it->recheck = true;
			}
		}
		if (!ret && (e1d & BIT(3)))
			ret = gc573_chip_rd(h, IT, 0, 0xd6, &v);
		if (ret)
			return ret;
	}

	/* 5: port-1 5 V, written back alone */
	ret = gc573_it_ack(h, 0x0a, 0x01, &v);
	if (ret)
		return ret;

	/* 6 */
	entered = it->state != st0;
	switch (it->state) {
	case GC573_IT_NO_5V:
	case GC573_IT_WAIT_SYNC:
		if (it->state == GC573_IT_NO_5V) {
			ret = gc573_chip_rd(h, IT, 0, 0x13, &it->r13);
			if (!ret && (it->r13 & BIT(0)))
				ret = gc573_it_5v(h, true);
		}
		if (!ret && it->state == GC573_IT_WAIT_SYNC) {
			ret = gc573_chip_rd(h, IT, 0, 0x19, &it->r19);
			if (!ret && (it->r19 & BIT(7))) {
				it->sync = false;
				ret = gc573_it_sync(h, true);
			}
		}
		/* link-mode check: written back alone, no MHL on GC573 */
		if (!ret)
			ret = gc573_it_ack(h, 0x07, 0x08, &v);
		break;
	case GC573_IT_DEBOUNCE:
		if (entered)
			break;
		if (it->debounce && --it->debounce)
			break;
		/*
		 * 7.5 driver rule: 5 V, clock bits 3/4 and symbol lock, and
		 * (hdmi-chips.md cross-chip rule) the splitter TX port 1
		 * unmuted, so the entry reads the input's HDMI mode.
		 */
		if ((it->r13 & 0x19) == 0x19 && (it->r14 & 0x38) == 0x38 &&
		    h->sp.tx1 == GC573_TX1_RUNNING) {
			ret = gc573_it_entry(h);
		} else if (++it->wait >= GC573_IT_ENTRY_WAIT) {
			dev_dbg(&h->gc->pdev->dev,
				"IT6805: no stable entry: 13=%02x 14=%02x splitter port 1 state %u\n",
				it->r13, it->r14, h->sp.tx1);
			it->sync = false;
			ret = gc573_it_wait_sync(h);
		}
		break;
	case GC573_IT_STABLE:
		if (entered)
			break;
		if (it->recheck) {
			it->recheck = false;
			ret = gc573_it_recheck(h, &changed);
			if (!ret && changed) {
				dev_info(&h->gc->pdev->dev,
					 "IT6805: input changed while stable\n");
				ret = gc573_it_entry(h);
				break;
			}
		}
		if (!ret)
			ret = gc573_chip_rd(h, IT, 0, 0x4f, &it->r4f);
		if (!ret && (it->r4f & BIT(5))) {
			ret = gc573_chip_rd(h, IT, 0, 0xaa, &v);
			if (!ret && !(v & BIT(3)))
				ret = gc573_it_release(h);
		}
		break;
	}
	if (ret)
		return ret;

	/* 7; 8 (RD's lock-report reads) is left out: reads for its log */
	return gc573_it_audio_step(h);
}

/* Probe: ID, init table, 5 V evaluation (3.2, 3.6). Bus held. */
int gc573_it6805_init(struct gc573_hdmi *h)
{
	struct device *dev = &h->gc->pdev->dev;
	struct gc573_it6805 *it = &h->it;
	u8 id[5], v;
	unsigned int i;
	int ret;

	memset(it, 0, sizeof(*it));
	/* bank 0 before the ID (i2c.md) */
	ret = gc573_chip_bank(h, IT, 0);
	for (i = 0; i < sizeof(id) && !ret; i++)
		ret = gc573_chip_rd(h, IT, 0, i, &id[i]);
	if (ret)
		return dev_err_probe(dev, ret, "IT6805 (I2C 0x90): ID read failed\n");
	if (memcmp(id, gc573_it_id, sizeof(gc573_it_id)))
		return dev_err_probe(dev, -ENODEV, "IT6805 (I2C 0x90): wrong ID %*ph\n",
				     4, id);
	it->rev = id[4];
	dev_info(dev, "I2C bus 1 0x90 (IT6805): id %*ph rev %#04x\n", 4, id,
		 it->rev);
	if (it->rev != GC573_IT_REV)
		dev_warn(dev, "IT6805 revision %#04x: init path untested (spec: %#04x)\n",
			 it->rev, GC573_IT_REV);

	ret = gc573_seq_run(h, &gc573_seq_it_init, 0);
	if (ret)
		return dev_err_probe(dev, ret, "IT6805 init failed\n");

	/* 3.6 */
	ret = gc573_chip_rd(h, IT, 0, 0x13, &v);
	if (!ret && (v & BIT(0))) {
		ret = gc573_seq_run(h, &gc573_seq_it_standby, 0);
		it->power = GC573_IT_STANDBY;
		it->normal_armed = true;
		it->state = GC573_IT_WAIT_SYNC;
		if (!ret)
			ret = gc573_it_tristate(h);
	} else if (!ret) {
		ret = gc573_seq_run(h, &gc573_seq_it_unplug, 0);
		if (!ret)
			ret = gc573_seq_run(h, &gc573_seq_it_saving, 0);
		it->power = GC573_IT_SAVING;
		it->state = GC573_IT_NO_5V;
	}
	if (ret)
		return dev_err_probe(dev, ret, "IT6805 5 V evaluation failed\n");
	it->r13 = v;
	it->first_poll = true;
	it->audio = GC573_AUD_OFF;

	dev_info(dev, "IT6805 rev %#04x: factory %u kHz, trim %#04x, 5 V %s\n",
		 it->rev, it->f_khz, it->trim, v & BIT(0) ? "present" : "absent");
	return 0;
}

/* Section 4 at runtime: EDID control off, RAM and registers, pulses */
int gc573_it6805_edid(struct gc573_hdmi *h)
{
	return gc573_seq_run(h, &gc573_seq_it_edid, 0);
}

void gc573_it6805_show(struct gc573_hdmi *h, struct seq_file *m)
{
	static const char * const states[] = {
		"NO_5V", "WAIT_SYNC", "DEBOUNCE", "STABLE",
	};
	static const char * const powers[] = { "SAVING", "STANDBY", "NORMAL" };
	static const char * const audio[] = { "OFF", "WAIT_READY", "ON" };
	struct gc573_it6805 *it = &h->it;
	struct gc573_it_mode *md = &it->mode;

	seq_printf(m, "it6805: rev %#04x factory %u kHz trim %#04x cal_retrigger %u\n",
		   it->rev, it->f_khz, it->trim, it->cal_retrigger);
	seq_printf(m, "it6805: state %s power %s audio %s armed %d sync %d debounce %u wait %u released %d polls %u entries %u losses %u releases %u\n",
		   states[it->state], powers[it->power], audio[it->audio],
		   it->normal_armed, it->sync, it->debounce, it->wait,
		   it->released, it->polls, it->entries, it->losses,
		   it->releases);
	seq_printf(m, "it6805: 13 %02x 14 %02x 19 %02x 4f %02x avi_store %02x %02x\n",
		   it->r13, it->r14, it->r19, it->r4f, it->avi_store[0],
		   it->avi_store[1]);
	seq_printf(m, "it6805: mode %ux%u%s total %ux%u hfp %u hs %u vfp %u vs %u pol %c%c rep %u pclk %u kHz %s dc %u avi %*ph bus %s%s\n",
		   md->hactive, md->vactive, md->interlaced ? "i" : "p",
		   md->htotal, md->vtotal, md->hfp, md->hsync, md->vfp,
		   md->vsync, md->hpos ? '+' : '-', md->vpos ? '+' : '-',
		   md->rep, md->pclk_khz, md->hdmi ? "HDMI" : "DVI", md->dc, 6,
		   md->avi, md->dual ? "dual" : "single",
		   md->ddr ? " DDR" : " SDR");
}
