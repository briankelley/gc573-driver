// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 HDMI splitter (ITE, chip ID 0x6663), spec/hdmi-splitter.md: init
 * with the reference clock from OTP, the RX EDID RAM, and the minimal
 * polling driver of section 10: RX event passes, the equaliser, and TX
 * port 1, which feeds the IT6805. Section numbers below are that
 * chapter's. Port 2 (probably HDMI OUT, unverified) is acknowledged only.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/seq_file.h>
#include <linux/string.h>

#include "gc573.h"

#define SP			GC573_DEV_SP
#define RX			GC573_DEV_SP_RX
#define TX1			GC573_DEV_SP_TX1
#define NB			GC573_SEQ_NOBANK

/* 2.1 */
static const u8 gc573_sp_id[4] = { 0x54, 0x49, 0x63, 0x66 };

/* 3.3 */
#define GC573_SP_RCLK_MIN	10000
#define GC573_SP_RCLK_MAX	34000
#define GC573_SP_RCLK_NOMINAL	22000
#define GC573_SP_RCLK_GATE_MS	99
#define GC573_SP_OTP_BASE	0x0b0
#define GC573_SP_OTP_BASE_ALT	0x4b0

/* 3.4: at most 32 reads, bit-6 pulse before each retry from the 4th */
#define GC573_SP_CAOF_READS	32
#define GC573_SP_CAOF_PULSE_FROM	4

/* 6.6 */
#define GC573_SP_EQ_ATTEMPTS	3
#define GC573_SP_EQ_MONITOR	6
#define GC573_SP_EQ_FIXED	0x9f
#define GC573_SP_BITERR_MAX	0x50

/* 7.3 */
#define GC573_SP_CLK_SAMPLES	10
#define GC573_SP_CLK_MAX	620999

/* 7.7: abort polls, 1 ms apart */
#define GC573_SP_ABORT_POLLS	200

/* 10 step 6 limit: video stable within 1 s of a full power-on, 1 repeat */
#define GC573_SP_TX1_WAIT_MS	1000
#define GC573_SP_TX1_REPOWERS	1

/* ---- X steps and variables ---- */

static u16 gc573_sp_word(struct gc573_hdmi *h, unsigned int lo,
			 unsigned int hi)
{
	return gc573_seq_rd(h, lo) | gc573_seq_rd(h, hi) << 8;
}

/* 3.3 step 2 */
static u16 gc573_sp_base(struct gc573_hdmi *h)
{
	u16 w0 = gc573_sp_word(h, GC573_SEQ_SP_INIT_OTP_W0_LO,
			       GC573_SEQ_SP_INIT_OTP_W0_HI);
	u16 w1 = gc573_sp_word(h, GC573_SEQ_SP_INIT_OTP_W1_LO,
			       GC573_SEQ_SP_INIT_OTP_W1_HI);

	return w0 == 0xffff && w1 == 0x0000 ? GC573_SP_OTP_BASE_ALT :
					      GC573_SP_OTP_BASE;
}

/* 3.3 steps 3, 4 (X rclk-compute, init row 53) */
static int gc573_sp_rclk(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	u16 a = gc573_sp_word(h, GC573_SEQ_SP_INIT_OTP_A_LO,
			      GC573_SEQ_SP_INIT_OTP_A_HI);
	u16 b = gc573_sp_word(h, GC573_SEQ_SP_INIT_OTP_B_LO,
			      GC573_SEQ_SP_INIT_OTP_B_HI);
	u8 c0, c1, c2;
	u32 rclk = 0;
	int ret;

	sp->otp_base = gc573_sp_base(h);
	if ((b >> 14) == 3)
		rclk = (a | (u32)(b & 0xff) << 16) / 100;
	if (rclk >= GC573_SP_RCLK_MIN && rclk <= GC573_SP_RCLK_MAX) {
		sp->rclk = rclk;
		return 0;
	}

	/* step 4: measure (S only; L) */
	ret = gc573_chip_mod(h, SP, 0, 0x11, 0x80, 0x80);
	if (ret)
		return ret;
	gc573_chip_sleep(h, GC573_SP_RCLK_GATE_MS);
	ret = gc573_chip_mod(h, SP, 0, 0x11, 0x80, 0x00);
	if (!ret)
		ret = gc573_chip_rd(h, SP, 0, 0x12, &c0);
	if (!ret)
		ret = gc573_chip_rd(h, SP, 0, 0x13, &c1);
	if (!ret)
		ret = gc573_chip_rd(h, SP, 0, 0x14, &c2);
	if (ret)
		return ret;
	rclk = (c0 | c1 << 8 | (u32)c2 << 16) / 100;
	sp->rclk_measured = true;
	dev_warn(&h->gc->pdev->dev,
		 "splitter: OTP words %04x %04x give no rclk, measured %u kHz\n",
		 a, b, rclk);
	if (rclk < GC573_SP_RCLK_MIN || rclk > GC573_SP_RCLK_MAX) {
		dev_warn(&h->gc->pdev->dev,
			 "splitter: rclk %u kHz out of range, using %u kHz\n",
			 rclk, GC573_SP_RCLK_NOMINAL);
		rclk = GC573_SP_RCLK_NOMINAL;
	}
	sp->rclk = rclk;
	return 0;
}

/* 3.4 (X caof-wait, init row 94) */
static int gc573_sp_caof_wait(struct gc573_hdmi *h)
{
	unsigned int i;
	int ret;
	u8 v;

	for (i = 0; i < GC573_SP_CAOF_READS; i++) {
		if (i >= GC573_SP_CAOF_PULSE_FROM) {
			ret = gc573_chip_mod(h, RX, 0, 0x2a, 0x40, 0x40);
			if (!ret)
				ret = gc573_chip_mod(h, RX, 0, 0x2a, 0x40, 0x00);
			if (ret)
				return ret;
		}
		ret = gc573_chip_rd(h, RX, 0, 0x08, &v);
		if (ret)
			return ret;
		if (v & 0x30)
			return 0;
	}
	dev_err(&h->gc->pdev->dev, "splitter: RX offset calibration did not finish\n");
	ret = gc573_chip_mod(h, RX, 3, 0x3a, 0x80, 0x00);
	if (!ret)
		ret = gc573_chip_mod(h, RX, 0, 0x2a, 0x40, 0x40);
	return ret ?: gc573_chip_mod(h, RX, 0, 0x2a, 0x40, 0x00);
}

/* 6.5: one EDID block into the RX RAM, offsets 7f/ff left out */
static int gc573_sp_edid_block(struct gc573_hdmi *h, unsigned int from)
{
	unsigned int i;
	int ret = 0;

	for (i = from; i < from + 0x7f && !ret; i++)
		ret = gc573_chip_wr(h, GC573_DEV_SP_EDID, NB, i, h->edid[i]);
	return ret;
}

/* 7.3: TX port 1 clock (X tx-clock-measure, power-on row 14) */
static int gc573_sp_tx_clock(struct gc573_hdmi *h)
{
	unsigned int i, d, coarse, sum = 0, avg;
	u8 lo, hi;
	int ret;

	ret = gc573_chip_mod(h, TX1, NB, 0x07, 0x80, 0x80);
	if (ret)
		return ret;
	gc573_chip_sleep(h, 1);
	ret = gc573_chip_mod(h, TX1, NB, 0x07, 0x80, 0x00);
	if (!ret)
		ret = gc573_chip_rd(h, TX1, NB, 0x06, &lo);
	if (!ret)
		ret = gc573_chip_rd(h, TX1, NB, 0x07, &hi);
	if (ret)
		return ret;
	coarse = ((hi & 0x0f) << 8 | lo) * 2;
	for (d = 7; d && coarse >= (16U << (7 - d)); d--)
		;

	for (i = 0; i < GC573_SP_CLK_SAMPLES && !ret; i++) {
		ret = gc573_chip_mod(h, TX1, NB, 0x07, 0xf0, (8 | d) << 4);
		if (!ret)
			ret = gc573_chip_mod(h, TX1, NB, 0x07, 0xf0, d << 4);
		if (!ret)
			ret = gc573_chip_rd(h, TX1, NB, 0x06, &lo);
		if (!ret)
			ret = gc573_chip_rd(h, TX1, NB, 0x07, &hi);
		sum += ((hi & 0x0f) << 8 | lo) * 2;
	}
	if (ret)
		return ret;
	avg = max(sum / (GC573_SP_CLK_SAMPLES << d), 1U);
	h->sp.tx1_clk = (u64)h->sp.rclk * 4096 / avg;
	return 0;
}

/* 6.7: RX timing registers, informative (X timing-read) */
static int gc573_sp_timing_read(struct gc573_hdmi *h)
{
	unsigned int i;
	int ret = 0;

	for (i = 0; i < sizeof(h->sp.rx_timing) && !ret; i++)
		ret = gc573_chip_rd(h, RX, 0, 0x9b + i, &h->sp.rx_timing[i]);
	return ret;
}

int gc573_sp_x(struct gc573_hdmi *h, unsigned int x)
{
	switch (x) {
	case GC573_SEQ_X_SP_RCLK:
		return gc573_sp_rclk(h);
	case GC573_SEQ_X_SP_CAOF_WAIT:
		return gc573_sp_caof_wait(h);
	case GC573_SEQ_X_SP_EDID_BLOCK0:
		return gc573_sp_edid_block(h, 0x00);
	case GC573_SEQ_X_SP_EDID_BLOCK1:
		return gc573_sp_edid_block(h, 0x80);
	case GC573_SEQ_X_SP_TX_CLOCK:
		return gc573_sp_tx_clock(h);
	case GC573_SEQ_X_SP_TIMING_READ:
		return gc573_sp_timing_read(h);
	}
	return -EINVAL;
}

/* 7.4: upper clock bound (kHz); 84[2:0], 88 bit 2, 87[4:0], 89, 8b[3:0] */
static const struct {
	u32 max_khz;
	u8 v[5];
} gc573_sp_afe_rows[] = {
	{ 100000, { 3, 0x00, 0x03, 0x80, 0x3 } },
	{ 150000, { 4, 0x00, 0x03, 0x80, 0x3 } },
	{ 162000, { 4, 0x00, 0x09, 0x21, 0x9 } },
	{ 310000, { 4, 0x04, 0x09, 0x21, 0x9 } },
	{ 375000, { 4, 0x04, 0x0d, 0x25, 0xb } },
	{ U32_MAX, { 4, 0x04, 0x0e, 0x25, 0xd } },
};

/* 7.4: AFE row for the measured clock, scaled for deep colour (7.3) */
static void gc573_sp_afe(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	u32 clk = sp->tx1_clk;
	unsigned int i;
	u8 dc;

	if (gc573_seq_last(h, ~0U, RX, 0, 0x98, &dc)) {
		if (((dc >> 4) & 3) == 1)
			clk = clk * 5 / 4;
		else if (((dc >> 4) & 3) == 2)
			clk = clk * 3 / 2;
	}
	if (clk > GC573_SP_CLK_MAX)
		clk = 0;
	for (i = 0; clk > gc573_sp_afe_rows[i].max_khz; i++)
		;
	memcpy(sp->afe, gc573_sp_afe_rows[i].v, sizeof(sp->afe));
	if (clk > 310000)
		dev_warn_ratelimited(&h->gc->pdev->dev,
				     "splitter: TX clock %u kHz needs the HDMI 2.0 link (UNVERIFIED, 7.6)\n",
				     clk);
}

static u8 gc573_sp_csum(struct gc573_hdmi *h, unsigned int from)
{
	unsigned int i;
	u8 ck = 0;

	for (i = from; i < from + 0x7f; i++)
		ck -= h->edid[i];
	return ck;
}

int gc573_sp_var(struct gc573_hdmi *h, unsigned int var, u8 *val)
{
	struct gc573_splitter *sp = &h->sp;
	unsigned int off;
	u16 base;
	u8 v;

	switch (var) {
	case GC573_SEQ_V_BASE_HI:
	case GC573_SEQ_V_BASE_LO:
	case GC573_SEQ_V_BASE1_HI:
	case GC573_SEQ_V_BASE1_LO:
		base = gc573_sp_base(h);
		if (var == GC573_SEQ_V_BASE1_HI || var == GC573_SEQ_V_BASE1_LO)
			base++;
		*val = var == GC573_SEQ_V_BASE_HI || var == GC573_SEQ_V_BASE1_HI ?
		       base >> 8 : base & 0xff;
		return 0;
	case GC573_SEQ_V_RCLK10_0:
		*val = (sp->rclk * 10) & 0xff;
		return 0;
	case GC573_SEQ_V_RCLK10_1:
		*val = ((sp->rclk * 10) >> 8) & 0xff;
		return 0;
	case GC573_SEQ_V_RCLK10_2:
		*val = ((sp->rclk * 10) >> 16) & 0x03;
		return 0;
	case GC573_SEQ_V_RCLK_MHZ:
		*val = sp->rclk / 1000;
		return 0;
	case GC573_SEQ_V_RCLK_FRAC:
		*val = ((sp->rclk % 1000) * 32) / 125;
		return 0;
	case GC573_SEQ_V_PA_AB:
	case GC573_SEQ_V_PA_CD:
		/* 8.3: the image's own physical address; none: 00 */
		gc573_hdmi_edid_pa(h, &off);
		*val = off ? h->edid[off + (var == GC573_SEQ_V_PA_CD)] : 0;
		return 0;
	case GC573_SEQ_V_CSUM0:
		*val = gc573_sp_csum(h, 0x00);
		return 0;
	case GC573_SEQ_V_CSUM1:
		*val = gc573_sp_csum(h, 0x80);
		return 0;
	case GC573_SEQ_V_HDMI_SINK:
		gc573_hdmi_edid_pa(h, &off);
		*val = off ? BIT(6) : 0;
		return 0;
	case GC573_SEQ_V_EQ0:
	case GC573_SEQ_V_EQ1:
	case GC573_SEQ_V_EQ2:
		*val = sp->eq_code[var - GC573_SEQ_V_EQ0];
		return 0;
	case GC573_SEQ_V_AFE84:
		gc573_sp_afe(h);
		*val = sp->afe[0];
		return 0;
	case GC573_SEQ_V_AFE88:
		*val = sp->afe[1];
		return 0;
	case GC573_SEQ_V_AFE87:
		*val = sp->afe[2];
		return 0;
	case GC573_SEQ_V_AFE89:
		*val = sp->afe[3];
		return 0;
	case GC573_SEQ_V_AFE8B:
		*val = sp->afe[4];
		return 0;
	case GC573_SEQ_V_R14:
		if (!gc573_seq_last(h, ~0U, RX, 0, 0x14, &v))
			return -EINVAL;
		*val = (v & 1) << 6;
		return 0;
	case GC573_SEQ_V_HDMI:
		if (!gc573_seq_last(h, ~0U, RX, 0, 0x13, &v))
			return -EINVAL;
		*val = (v >> 1) & 1;
		return 0;
	}
	return -EINVAL;
}

/* 7.7 DDC master abort after a completion timeout; the caller goes on */
int gc573_sp_ddc_abort(struct gc573_hdmi *h, u8 dev)
{
	unsigned int k, i;
	int ret;
	u8 v;

	h->sp.scdc_aborts++;
	dev_warn_ratelimited(&h->gc->pdev->dev,
			     "splitter: port 0x%02x DDC timeout, aborting\n", dev);
	ret = gc573_chip_rd(h, dev, NB, 0x2f, &v);
	if (!ret)
		ret = gc573_chip_mod(h, dev, NB, 0x35, 0x10, 0x10);
	if (!ret)
		ret = gc573_chip_mod(h, dev, NB, 0x35, 0x10, 0x00);
	if (!ret)
		ret = gc573_chip_mod(h, dev, NB, 0x28, 0x01, 0x01);
	if (!ret)
		ret = gc573_chip_mod(h, dev, NB, 0x28, 0x01, 0x00);
	for (k = 0; k < 2 && !ret; k++) {
		ret = gc573_chip_wr(h, dev, NB, 0x2e, 0x0f);
		for (i = 0; i < GC573_SP_ABORT_POLLS && !ret; i++) {
			fsleep(1000);
			ret = gc573_chip_rd(h, dev, NB, 0x2f, &v);
			if (v & 0xb8)
				break;
		}
	}
	return ret;
}

/* ---- port 1 ---- */

/* 7.2 power-down with port reset */
static int gc573_sp_tx1_down(struct gc573_hdmi *h)
{
	h->sp.tx1 = GC573_TX1_OFF;
	return gc573_seq_run(h, &gc573_seq_sp_tx1_power_down, 0);
}

/* 7.2 power-on: partial without RX video, full with it */
static int gc573_sp_tx1_up(struct gc573_hdmi *h, bool full)
{
	struct gc573_splitter *sp = &h->sp;
	int ret;

	ret = gc573_seq_run(h, &gc573_seq_sp_tx1_power_on_partial, 0);
	if (ret || !full) {
		sp->tx1 = ret ? GC573_TX1_OFF : GC573_TX1_PARTIAL;
		return ret;
	}
	ret = gc573_seq_run(h, &gc573_seq_sp_tx1_power_on_rest, 0);
	sp->tx1 = ret ? GC573_TX1_OFF : GC573_TX1_POWERED;
	sp->tx1_since = jiffies;
	return ret;
}

/* 6.4: source HPD high, only with 5 V and a loaded EDID */
static int gc573_sp_src_hpd(struct gc573_hdmi *h)
{
	int ret;
	u8 v;

	if (!h->sp.edid_loaded)
		return 0;
	ret = gc573_chip_rd(h, RX, 0, 0x13, &v);
	if (ret || !(v & BIT(0)))
		return ret;
	ret = gc573_seq_run(h, &gc573_seq_sp_hpd_high, 0);
	if (!ret)
		h->sp.src_hpd = true;
	return ret;
}

int gc573_sp_hpd_low(struct gc573_hdmi *h)
{
	h->sp.src_hpd = false;
	return gc573_seq_run(h, &gc573_seq_sp_hpd_low, 0);
}

/* Read a port's events 0x10-0x14 and write each back (7.1) */
static int gc573_sp_port_ack(struct gc573_hdmi *h, u8 dev, u8 *e)
{
	unsigned int i;
	int ret = 0;
	u8 v[5];

	for (i = 0; i < 5 && !ret; i++)
		ret = gc573_chip_rd(h, dev, NB, 0x10 + i, &v[i]);
	for (i = 0; i < 5 && !ret; i++)
		ret = gc573_chip_wr(h, dev, NB, 0x10 + i, v[i]);
	if (!ret && e)
		memcpy(e, v, sizeof(v));
	return ret;
}

/* Port 1 event pass, seq/splitter-tx1-hpd-event.tsv */
static int gc573_sp_port1_pass(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	int ret;
	u8 e[5];

	ret = gc573_sp_port_ack(h, TX1, e);
	if (ret)
		return ret;
	if (e[0] & BIT(0)) {
		ret = gc573_chip_rd(h, TX1, NB, 0x03, &sp->tx1_lv);
		if (!ret && (sp->tx1_lv & BIT(0))) {
			ret = gc573_sp_src_hpd(h);
			if (!ret)
				ret = gc573_sp_tx1_down(h);
			if (!ret)
				ret = gc573_sp_tx1_up(h, sp->scdt);
		} else if (!ret) {
			ret = gc573_sp_tx1_down(h);
		}
	}
	if (!ret && (e[0] & BIT(1))) {
		ret = gc573_chip_rd(h, TX1, NB, 0x03, &sp->tx1_lv);
		if (!ret && (sp->tx1_lv & BIT(1))) {
			ret = gc573_sp_tx1_down(h);
			if (!ret)
				ret = gc573_sp_tx1_up(h, sp->scdt);
			if (!ret)
				ret = gc573_sp_src_hpd(h);
			if (!ret)
				ret = gc573_chip_rd(h, TX1, NB, 0x03, &sp->tx1_lv);
		} else if (!ret) {
			ret = gc573_sp_tx1_down(h);
		}
	}
	/* 0x10 bit 7, video stable: the port step polls 0x03 while POWERED */
	return ret;
}

/* 7.5 */
static int gc573_sp_output_enable(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	u8 lv = 0, c0;
	int ret;

	sp->oe_runs++;
	ret = gc573_seq_run(h, &gc573_seq_sp_tx1_output_enable, 0);
	if (ret)
		return ret;
	gc573_seq_last(h, ~0U, TX1, NB, 0x03, &lv);
	sp->tx1_lv = lv;
	if (!(gc573_seq_rd(h, GC573_SEQ_SP_TX1_OUTPUT_ENABLE_LINK) & BIT(3)))
		sp->pll_recoveries++;
	if ((lv & 0x0f) != 0x0f) {
		sp->oe_fail++;
		dev_dbg(&h->gc->pdev->dev,
			"splitter: port 1 output enable: 03 = %02x, retrying\n", lv);
		return 0;
	}
	/* step 10: clear 0xc0 bit 1 if set (traced as reads only) */
	if (gc573_seq_last(h, ~0U, TX1, NB, 0xc0, &c0) && (c0 & BIT(1)))
		ret = gc573_chip_mod(h, TX1, NB, 0xc0, 0x02, 0x00);
	sp->tx1 = GC573_TX1_ENABLED;
	return ret;
}

/* 10 step 6 */
static int gc573_sp_tx1_step(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	int ret;

	switch (sp->tx1) {
	case GC573_TX1_POWERED:
		ret = gc573_chip_rd(h, TX1, NB, 0x03, &sp->tx1_lv);
		if (ret)
			return ret;
		/* HPD, video stable, input clock */
		if ((sp->tx1_lv & 0x85) == 0x85)
			return gc573_sp_output_enable(h);
		if (time_before(jiffies, sp->tx1_since +
				msecs_to_jiffies(GC573_SP_TX1_WAIT_MS)) ||
		    sp->tx1_repowers >= GC573_SP_TX1_REPOWERS)
			return 0;
		sp->tx1_repowers++;
		dev_dbg(&h->gc->pdev->dev,
			"splitter: port 1 not stable (03 = %02x), powering it again\n",
			sp->tx1_lv);
		ret = gc573_sp_tx1_down(h);
		return ret ?: gc573_sp_tx1_up(h, true);
	case GC573_TX1_ENABLED:
		/* step 11: unmute one poll cycle after the output enable */
		ret = gc573_seq_run(h, &gc573_seq_sp_tx1_unmute, 0);
		if (!ret) {
			sp->tx1 = GC573_TX1_RUNNING;
			sp->tx1_repowers = 0;
		}
		return ret;
	default:
		return 0;
	}
}

/* ---- RX ---- */

static int gc573_sp_5v(struct gc573_hdmi *h, bool on)
{
	struct gc573_splitter *sp = &h->sp;
	int ret;

	if (on) {
		ret = gc573_seq_run(h, &gc573_seq_sp_5v_on, 0);
		sp->v5 = true;
		return ret ?: gc573_sp_src_hpd(h);
	}
	/* RX power-down, then ports 0-3 down; stored EQ results go */
	sp->v5 = false;
	sp->src_hpd = false;
	sp->eq = GC573_EQ_IDLE;
	sp->eq_stored = false;
	sp->tx1 = GC573_TX1_OFF;
	ret = gc573_seq_run(h, &gc573_seq_sp_rx_power_down, 0);
	if (!ret)
		ret = gc573_seq_run(h, &gc573_seq_sp_tx0_power_down, 0);
	if (!ret)
		ret = gc573_seq_run(h, &gc573_seq_sp_tx1_power_down, 0);
	if (!ret)
		ret = gc573_seq_run(h, &gc573_seq_sp_tx2_power_down, 0);
	if (!ret)
		ret = gc573_seq_run(h, &gc573_seq_sp_tx3_power_down, 0);
	return ret;
}

/* 6.6 apply, seq/splitter-rx-eq-apply.tsv */
static int gc573_sp_eq_apply(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	int first = -1, c, ret;
	bool valid[3];
	u8 d0;

	ret = gc573_seq_run(h, &gc573_seq_sp_eq_read, 0);
	if (ret)
		return ret;
	sp->eq_result[0] = gc573_seq_rd(h, GC573_SEQ_SP_EQ_READ_D5);
	sp->eq_result[1] = gc573_seq_rd(h, GC573_SEQ_SP_EQ_READ_D6);
	sp->eq_result[2] = gc573_seq_rd(h, GC573_SEQ_SP_EQ_READ_D7);
	sp->eq_result[3] = gc573_seq_rd(h, GC573_SEQ_SP_EQ_READ_D0);
	d0 = sp->eq_result[3];
	for (c = 0; c < 3; c++) {
		valid[c] = ((d0 >> (2 * c)) & 3) == 3;
		if (valid[c] && first < 0)
			first = c;
	}
	for (c = 0; c < 3; c++) {
		if (first < 0)
			sp->eq_code[c] = GC573_SP_EQ_FIXED;
		else
			sp->eq_code[c] = (sp->eq_result[valid[c] ? c : first] &
					  0x7f) | 0x80;
	}
	ret = gc573_seq_run(h, &gc573_seq_sp_eq_write, 0);
	if (first >= 0) {
		sp->eq_stored = true;
		sp->eq = GC573_EQ_CHECK;
	} else {
		dev_warn_ratelimited(&h->gc->pdev->dev,
				     "splitter: EQ search found no valid channel (d0 = %02x), attempt %u\n",
				     d0, sp->eq_attempts);
		sp->eq = sp->eq_attempts < GC573_SP_EQ_ATTEMPTS ?
			 GC573_EQ_START : GC573_EQ_DONE;
	}
	return ret;
}

/* 6.6 step 4, seq/splitter-rx-biterr.tsv */
static int gc573_sp_biterr(struct gc573_hdmi *h)
{
	static const u8 idx[3][2] = {
		{ GC573_SEQ_SP_BITERR_EA0, GC573_SEQ_SP_BITERR_EB0 },
		{ GC573_SEQ_SP_BITERR_EA1, GC573_SEQ_SP_BITERR_EB1 },
		{ GC573_SEQ_SP_BITERR_EA2, GC573_SEQ_SP_BITERR_EB2 },
	};
	struct gc573_splitter *sp = &h->sp;
	unsigned int c;
	int ret;

	ret = gc573_seq_run(h, &gc573_seq_sp_biterr, 0);
	if (ret)
		return ret;
	for (c = 0; c < 3; c++) {
		u8 ea = gc573_seq_rd(h, idx[c][0]);
		u8 eb = gc573_seq_rd(h, idx[c][1]);

		sp->biterr[c][0] = ea;
		sp->biterr[c][1] = eb;
		if (!(eb & BIT(7)) || ea > GC573_SP_BITERR_MAX)
			dev_warn_ratelimited(&h->gc->pdev->dev,
					     "splitter: channel %u bit-error check failed (%02x %02x)\n",
					     c, ea, eb);
	}
	return 0;
}

/* 4.2 step 2: the EQ step of every cycle */
static int gc573_sp_eq_step(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	bool done = sp->eq_done;
	int ret;

	sp->eq_done = false;
	ret = gc573_chip_rd(h, RX, 0, 0x14, &sp->r14);
	if (!ret)
		ret = gc573_chip_rd(h, RX, 0, 0x13, &sp->r13);
	if (ret)
		return ret;
	sp->lock = (sp->r14 & 0x38) == 0x38;

	switch (sp->eq) {
	case GC573_EQ_START:
		if (!(sp->r13 & BIT(4)))
			return 0;
		sp->eq_attempts++;
		sp->eq = GC573_EQ_SEARCH;
		return gc573_seq_run(h, &gc573_seq_sp_eq_search, 0);
	case GC573_EQ_SEARCH:
		return done ? gc573_sp_eq_apply(h) : 0;
	case GC573_EQ_CHECK:
		if (!sp->lock)
			return 0;
		sp->eq = GC573_EQ_DONE;
		sp->eq_monitor = 0;
		return gc573_sp_biterr(h);
	case GC573_EQ_DONE:
		if (!sp->lock || ++sp->eq_monitor < GC573_SP_EQ_MONITOR)
			return 0;
		sp->eq_monitor = 0;
		return gc573_sp_biterr(h);
	default:
		return 0;
	}
}

/* 6.7 AVI, informative: port 1 bypasses the RX colour converter */
static int gc573_sp_avi(struct gc573_hdmi *h)
{
	unsigned int i;
	int ret = 0;

	for (i = 0; i < sizeof(h->sp.avi) && !ret; i++)
		ret = gc573_chip_rd(h, RX, 2, 0x12 + i, &h->sp.avi[i]);
	return ret;
}

/* 6.2 RX event pass: read 05-1d, write back 05-11, act, write back 12 */
static int gc573_sp_rx_pass(struct gc573_hdmi *h)
{
	static const u8 regs[] = {
		0x05, 0x06, 0x07, 0x08, 0x09, 0x10, 0x11, 0x12,
		0x13, 0x14, 0x15, 0x19, 0x1a, 0x1b, 0x1d,
	};
	struct gc573_splitter *sp = &h->sp;
	u8 v[ARRAY_SIZE(regs)], e05, e06, e10, e12;
	unsigned long cond;
	unsigned int i;
	int ret = 0;

	for (i = 0; i < ARRAY_SIZE(regs) && !ret; i++)
		ret = gc573_chip_rd(h, RX, 0, regs[i], &v[i]);
	for (i = 0; i < 7 && !ret; i++)
		ret = gc573_chip_wr(h, RX, 0, regs[i], v[i]);
	if (ret)
		return ret;
	memcpy(sp->ev, v, sizeof(sp->ev));
	e05 = v[0];
	e06 = v[1];
	e10 = v[5];
	e12 = v[7];
	sp->r13 = v[8];
	sp->r14 = v[9];
	sp->r19 = v[11];

	if (e05 & BIT(0))
		ret = gc573_sp_5v(h, sp->r13 & BIT(0));
	if (!ret && (e05 & BIT(2))) {
		sp->clk = sp->r13 & BIT(3);
		ret = gc573_seq_run(h, sp->clk ? &gc573_seq_sp_clock_stable :
					    &gc573_seq_sp_clock_lost, 0);
	}
	if (e05 & BIT(5))
		sp->link_errors++;
	if (!ret && (e06 & BIT(0))) {
		if (sp->r13 & BIT(7)) {
			cond = sp->eq_stored ? BIT(GC573_SEQ_C_EQ_STORED) : 0;
			ret = gc573_seq_run(h, &gc573_seq_sp_lock, cond);
			sp->eq = sp->eq_stored ? GC573_EQ_CHECK : GC573_EQ_START;
			sp->eq_attempts = 0;
		} else {
			cond = sp->eq != GC573_EQ_SEARCH ?
			       BIT(GC573_SEQ_C_NO_EQ_SEARCH) : 0;
			ret = gc573_seq_run(h, &gc573_seq_sp_lock_lost, cond);
			sp->eq = GC573_EQ_IDLE;
		}
	}
	if (v[2] & (BIT(4) | BIT(6) | BIT(7)))
		sp->eq_done = true;
	if (!ret && (e10 & BIT(1))) {
		if (sp->r19 & BIT(7)) {
			cond = e10 & BIT(2) ? BIT(GC573_SEQ_C_RX10_2) : 0;
			ret = gc573_seq_run(h, &gc573_seq_sp_scdt_on_a, cond);
			if (!ret)
				ret = gc573_chip_rd(h, TX1, NB, 0x03, &sp->tx1_lv);
			if (!ret && (sp->tx1_lv & BIT(0)))
				ret = gc573_sp_tx1_up(h, true);
			if (!ret)
				ret = gc573_seq_run(h, &gc573_seq_sp_scdt_on_b, 0);
			sp->scdt = true;
		} else {
			ret = gc573_seq_run(h, &gc573_seq_sp_scdt_off, 0);
			sp->scdt = false;
			sp->tx1 = GC573_TX1_OFF;
		}
	} else if (!ret && (e10 & BIT(2))) {
		ret = gc573_chip_mod(h, RX, 0, 0x40, 0x03, 0x00);
	}
	if (!ret && (e12 & BIT(7)))
		ret = gc573_seq_run(h, &gc573_seq_sp_ack_12_7, 0);
	if (!ret && (e12 & BIT(0)))
		ret = gc573_sp_avi(h);
	return ret ?: gc573_chip_wr(h, RX, 0, 0x12, e12);
}

/* One poll cycle, section 10 */
int gc573_sp_poll(struct gc573_hdmi *h)
{
	struct gc573_splitter *sp = &h->sp;
	int ret;
	u8 sum;

	sp->polls++;
	ret = gc573_chip_rd(h, SP, 0, 0x05, &sum);
	if (!ret && (sum & BIT(4)))
		ret = gc573_sp_rx_pass(h);
	if (!ret && (sum & (BIT(5) | BIT(6))))
		ret = gc573_seq_run(h, &gc573_seq_sp_main_event, 0);
	if (!ret && (sum & BIT(1)))
		ret = gc573_sp_port1_pass(h);
	if (!ret && (sum & BIT(2)))
		ret = gc573_sp_port_ack(h, GC573_DEV_SP_TX2, NULL);
	if (!ret)
		ret = gc573_sp_eq_step(h);
	if (!ret)
		ret = gc573_sp_tx1_step(h);
	return ret;
}

/*
 * EDID RAM load (6.5, 8.3). toggle: the source saw HPD high, so take it
 * low first, then run RD's change toggle (RX power-down, 500 ms) and raise
 * it again with 5 V. Bus held.
 */
int gc573_sp_edid(struct gc573_hdmi *h, bool toggle)
{
	struct gc573_splitter *sp = &h->sp;
	int ret = 0;

	sp->edid_loaded = false;
	if (toggle)
		ret = gc573_sp_hpd_low(h);
	if (!ret)
		ret = gc573_seq_run(h, &gc573_seq_sp_edid_load, 0);
	if (!ret && toggle) {
		ret = gc573_seq_run(h, &gc573_seq_sp_edid_toggle, 0);
		sp->eq = GC573_EQ_IDLE;
		sp->eq_stored = false;
	}
	if (ret)
		return ret;
	sp->edid_loaded = h->edid_blocks > 0;
	if (toggle)
		ret = gc573_sp_src_hpd(h);
	return ret ?: gc573_seq_run(h, &gc573_seq_sp_edid_end,
				    toggle ? BIT(GC573_SEQ_C_EDID_TOGGLE) : 0);
}

/* Probe: ID and init table (3.2). Bus held. */
int gc573_sp_init(struct gc573_hdmi *h)
{
	struct device *dev = &h->gc->pdev->dev;
	struct gc573_splitter *sp = &h->sp;
	u8 id[4];
	int ret;

	memset(sp, 0, sizeof(*sp));
	/* phase A: bank 0, ID by two 2-byte reads, revision */
	ret = gc573_chip_wr(h, SP, NB, 0x0f, 0x00);
	if (!ret)
		ret = gc573_chip_bank(h, SP, 0);
	if (!ret)
		ret = gc573_chip_rdn(h, SP, 0x00, id, 2);
	if (!ret)
		ret = gc573_chip_rdn(h, SP, 0x02, id + 2, 2);
	if (ret)
		return dev_err_probe(dev, ret, "splitter (I2C 0x58): ID read failed\n");
	if (memcmp(id, gc573_sp_id, sizeof(id)))
		return dev_err_probe(dev, -ENODEV,
				     "splitter (I2C 0x58): wrong ID %*ph\n", 4, id);
	ret = gc573_chip_rd(h, SP, 0, 0x15, &sp->rev);
	if (ret)
		return dev_err_probe(dev, ret, "splitter: revision read failed\n");
	dev_info(dev, "I2C bus 1 0x58 (splitter): id %*ph rev %#04x\n", 4, id,
		 sp->rev);
	ret = gc573_seq_run(h, &gc573_seq_sp_init, 0);
	if (ret)
		return dev_err_probe(dev, ret, "splitter init failed\n");

	dev_info(dev, "splitter rev %#04x: rclk %u kHz (%s, OTP record %#05x)\n",
		 sp->rev, sp->rclk, sp->rclk_measured ? "measured" : "OTP",
		 sp->otp_base);
	return 0;
}

void gc573_sp_show(struct gc573_hdmi *h, struct seq_file *m)
{
	static const char * const tx1[] = {
		"OFF", "PARTIAL", "POWERED", "ENABLED", "RUNNING",
	};
	static const char * const eq[] = {
		"IDLE", "START", "SEARCH", "CHECK", "DONE",
	};
	struct gc573_splitter *sp = &h->sp;

	seq_printf(m, "splitter: rev %#04x rclk %u kHz%s otp_base %#05x edid_loaded %d src_hpd %d polls %u\n",
		   sp->rev, sp->rclk, sp->rclk_measured ? " (measured)" : "",
		   sp->otp_base, sp->edid_loaded, sp->src_hpd, sp->polls);
	seq_printf(m, "splitter: rx 5v %d clk %d lock %d scdt %d 13 %02x 14 %02x 19 %02x last events %*ph link_errors %u\n",
		   sp->v5, sp->clk, sp->lock, sp->scdt, sp->r13, sp->r14,
		   sp->r19, (int)sizeof(sp->ev), sp->ev, sp->link_errors);
	seq_printf(m, "splitter: eq %s stored %d codes %*ph result %*ph attempts %u biterr %02x%02x %02x%02x %02x%02x\n",
		   eq[sp->eq], sp->eq_stored, 3, sp->eq_code, 4, sp->eq_result,
		   sp->eq_attempts, sp->biterr[0][1], sp->biterr[0][0],
		   sp->biterr[1][1], sp->biterr[1][0], sp->biterr[2][1],
		   sp->biterr[2][0]);
	seq_printf(m, "splitter: tx1 %s 03 %02x clk %u kHz afe %*ph repowers %u output_enable %u failed %u pll_recoveries %u scdc_aborts %u\n",
		   tx1[sp->tx1], sp->tx1_lv, sp->tx1_clk, 5, sp->afe,
		   sp->tx1_repowers, sp->oe_runs, sp->oe_fail,
		   sp->pll_recoveries, sp->scdc_aborts);
	seq_printf(m, "splitter: avi %*ph rx timing %*ph\n",
		   (int)sizeof(sp->avi), sp->avi, (int)sizeof(sp->rx_timing),
		   sp->rx_timing);
}
