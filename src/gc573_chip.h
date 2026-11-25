/* SPDX-License-Identifier: GPL-2.0 */
/*
 * GC573 HDMI front-end: the HDMI splitter and the IT6805 receiver on I2C
 * bus 1 (spec/hdmi-chips.md, spec/hdmi-splitter.md, spec/hdmi-it6805.md).
 *
 * Register sequences come from the spec/seq tables through tools/gen-seq.py
 * (src/gc573_seq.c); gc573_chip.c runs them and gives the chip code its
 * register access, gc573_it6805.c and gc573_splitter.c hold the per-chip
 * procedures and state machines, gc573_hdmi.c the bring-up, the poll
 * worker and the input state the video device reads.
 */
#ifndef GC573_CHIP_H
#define GC573_CHIP_H

#include <linux/bitmap.h>
#include <linux/bits.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/types.h>
#include <linux/videodev2.h>
#include <linux/workqueue.h>

struct gc573;
struct seq_file;

/* ---- sequence engine ---- */

enum gc573_seq_opcode {
	GC573_SEQ_W,		/* write */
	GC573_SEQ_M,		/* read-modify-write: (old & ~mask) | (val & mask) */
	GC573_SEQ_R,		/* read; the value is kept for later rows */
	GC573_SEQ_D,		/* delay, arg = ms */
	GC573_SEQ_P,		/* poll until (reg & mask) == val */
	GC573_SEQ_X,		/* step in driver code, arg = enum gc573_seq_x */
};

#define GC573_SEQ_NOBANK	0xff
#define GC573_SEQ_F_BANKREG	BIT(0)	/* row is the device's bank register */
#define GC573_SEQ_F_READ	BIT(1)	/* write back the value read earlier */
#define GC573_SEQ_F_VAR		BIT(2)	/* value: variable arg */

struct gc573_seq_op {
	u8 op;
	u8 dev;			/* 8-bit I2C address */
	u8 bank;		/* GC573_SEQ_NOBANK: unbanked device */
	u8 reg;
	u8 mask;
	u8 val;
	u8 c1, c2;		/* conditions that must hold, 0 = none */
	u8 flags;
	u16 arg;
	u16 row;		/* row number in the spec table */
};

struct gc573_seq {
	const char *name;
	const struct gc573_seq_op *ops;
	unsigned int n;
};

/* condition the engine tests on a value read earlier in the same run */
struct gc573_seq_dcond {
	u8 dev, bank, reg, mask, val;
	bool eq;
};

#include "gc573_seq.h"

/* ---- devices on bus 1 (8-bit addresses), spec/hdmi-chips.md ---- */

#define GC573_DEV_IT6805	0x90
#define GC573_DEV_IT_EDID	0xa8	/* IT6805 EDID RAM (0:4b = a9) */
#define GC573_DEV_SP		0x58	/* splitter main block */
#define GC573_DEV_SP_RX		0x70	/* splitter RX core */
#define GC573_DEV_SP_TX1	0x6a	/* splitter TX port 1: IT6805 */
#define GC573_DEV_SP_TX2	0x6c	/* splitter TX port 2 */
#define GC573_DEV_SP_EDID	0xd8	/* splitter RX EDID RAM (70/0:4b = d9) */

#define GC573_EDID_SIZE		256	/* two blocks, both RAMs */

/* ---- IT6805, spec/hdmi-it6805.md ---- */

enum gc573_it_state {
	GC573_IT_NO_5V,		/* section 7.5 */
	GC573_IT_WAIT_SYNC,
	GC573_IT_DEBOUNCE,
	GC573_IT_STABLE,
};

enum gc573_it_power {
	GC573_IT_SAVING,	/* section 6 */
	GC573_IT_STANDBY,
	GC573_IT_NORMAL,
};

enum gc573_it_audio {
	GC573_AUD_OFF,		/* section 11.1 */
	GC573_AUD_WAIT_READY,
	GC573_AUD_ON,
};

/* What one stable entry measured and programmed (sections 8-10) */
struct gc573_it_mode {
	u16 htotal, hactive, hfp, hsync;
	u16 vtotal, vactive, vfp, vsync;
	bool interlaced, hpos, vpos;
	u8 rep;			/* pixel repetition factor, 0:1b[5:4] */
	u32 pclk_khz;		/* pixel counter, coarse */
	u8 avi[6];		/* AVI PB0-PB5: 2:14-2:19 */
	bool hdmi;		/* 0:13 bit 1 */
	u8 dc;			/* deep-colour code, 0:98[7:4] */
	bool dual, ddr;		/* output bus, section 10.1 */
};

struct gc573_it6805 {
	enum gc573_it_state state;
	enum gc573_it_power power;
	enum gc573_it_audio audio;
	bool normal_armed;	/* NORMAL at the next 0:05 bit 1 */
	bool first_poll;
	bool sync;		/* 0:19 bit 7 as last handled */
	unsigned int debounce;	/* polls left in DEBOUNCE */
	unsigned int wait;	/* polls waited at the end of DEBOUNCE */
	unsigned int audio_count;
	unsigned int audio_poll;
	bool audio_stored;
	u8 audio_st[3];		/* 0:b0-0:b2 when audio went on */
	bool param_ignore;	/* next 0:12 bit 7 is from the entry itself */
	bool recheck;		/* timing or AVI event while STABLE */
	bool released;		/* AV mute released since the entry */
	u8 avi_store[2];	/* 2:14, 2:15 */
	u8 r13, r14, r19, r4f;
	struct gc573_it_mode mode;
	u32 f_khz;		/* factory oscillator value, section 3.4 */
	u8 trim;
	u8 rev;
	unsigned int cal_retrigger;
	u32 entries, losses, releases, polls;
};

/* ---- splitter, spec/hdmi-splitter.md ---- */

enum gc573_tx1_state {
	GC573_TX1_OFF,		/* powered down or soft reset */
	GC573_TX1_PARTIAL,	/* partial power-on: no RX video */
	GC573_TX1_POWERED,	/* full power-on, waiting for video stable */
	GC573_TX1_ENABLED,	/* output enabled; unmute in the next poll */
	GC573_TX1_RUNNING,	/* unmuted */
};

enum gc573_eq_state {
	GC573_EQ_IDLE,		/* no lock */
	GC573_EQ_START,		/* search to start at the EQ step */
	GC573_EQ_SEARCH,	/* search running */
	GC573_EQ_CHECK,		/* codes applied, bit-error check due */
	GC573_EQ_DONE,
};

struct gc573_splitter {
	u32 rclk;		/* reference clock, kHz, section 3.3 */
	u16 otp_base;
	bool rclk_measured;
	u8 rev;			/* 58/0:15 */
	bool v5, clk, lock, scdt;	/* RX levels */
	u8 r13, r14, r19;
	u8 ev[8];		/* last RX event pass: 05-09, 10-12 */
	enum gc573_eq_state eq;
	bool eq_stored;
	u8 eq_code[3];		/* stored or applied codes */
	u8 eq_result[4];	/* d5-d7, d0 of the last search */
	unsigned int eq_attempts;
	bool eq_done;		/* 0x07 bit 4, 6 or 7 seen */
	unsigned int eq_monitor;
	u8 biterr[3][2];	/* ea, eb per channel, last check */
	enum gc573_tx1_state tx1;
	u8 tx1_lv;		/* 6a:03 */
	unsigned long tx1_since;	/* jiffies at the last full power-on */
	unsigned int tx1_repowers;
	u32 tx1_clk;		/* measured TX clock, kHz, section 7.3 */
	u8 afe[5];		/* 84, 88, 87, 89, 8b values of the AFE row */
	bool edid_loaded;
	bool src_hpd;		/* we raised the source HPD (70/3:ab = ca) */
	u8 avi[18];		/* RX bank 2 0x12-0x23 */
	u8 rx_timing[16];	/* RX 0x9b-0xaa at the last output enable */
	u32 link_errors, oe_runs, oe_fail, pll_recoveries, scdc_aborts;
	u32 polls;
	u32 level_changes;	/* a level moved between read and write-back */
};

/* ---- front-end ---- */

enum gc573_enc {
	GC573_ENC_709,
	GC573_ENC_601,
	GC573_ENC_2020,
};

/* Input state for the video device; written by the poll worker */
struct gc573_input {
	bool power;		/* 5 V at HDMI IN (splitter RX 0x13 bit 0) */
	bool signal;		/* TMDS clock at HDMI IN (0x13 bit 3) */
	bool locked;		/* stable, AV mute released, timings valid */
	struct v4l2_dv_timings timings;	/* detected, valid while locked */
	u32 period;		/* FPGA IN_FRAME_PERIOD (0x1010), 0: none */
	u32 fpga[3];		/* FPGA 0x1004, 0x1008, 0x100c */
	u8 colour;		/* AVI Y: 0 RGB, 1 4:2:2, 2 4:4:4, 3 4:2:0 */
	u8 vic;			/* AVI VIC */
	bool full_range;	/* RGB: Q; YCbCr: YQ */
	enum gc573_enc enc;	/* YCbCr colorimetry (AVI C, EC) */
	bool dvi;		/* DVI mode: no AVI, treated as full-range RGB */
	bool dual, ddr;		/* IT6805 output bus */
};

struct gc573_chip_bank {
	u8 dev;
	u8 mask;		/* bank bits of register 0x0f */
	s8 cur;			/* selected bank, -1 unknown */
	bool resync;		/* rewrite and read back before use */
};

struct gc573_hdmi {
	struct gc573 *gc;
	struct mutex lock;	/* chips and this state; taken under vid.lock */
	struct workqueue_struct *wq;
	struct delayed_work poll;
	bool polling;
	bool bus_held;		/* bus-1 adapter locked by us */
	bool failed;		/* bring-up failed: chips not driven */
	struct gc573_chip_bank bank[3];

	/* engine: values read in the current or last run */
	const struct gc573_seq *run;
	u8 rd[GC573_SEQ_MAX_OPS];
	DECLARE_BITMAP(rdv, GC573_SEQ_MAX_OPS);

	u8 edid[GC573_EDID_SIZE];
	unsigned int edid_blocks;	/* 0: no EDID (HPD stays low) */
	DECLARE_BITMAP(edid_vics, 256);	/* CTA VICs the EDID offers */
	struct v4l2_bt_timings edid_dtd[8];	/* its detailed timings */
	unsigned int edid_ndtd;

	struct gc573_it6805 it;
	struct gc573_splitter sp;

	/* published input state, also read by the ioctls */
	spinlock_t slock;
	struct gc573_input in;
	unsigned int lock_polls;	/* polls since the entry, for 0x1010 */
	u32 period_raw;			/* 0x1010 at the last poll */
	u32 fpga_rejects;		/* polls the FPGA measurement held a lock */

	/* statistics */
	u32 polls, poll_errors, xfers, xfer_errors, retries, resyncs, runs;
	u32 poll_ms_max;
};

/* gc573_chip.c */
void gc573_chip_begin(struct gc573_hdmi *h);
void gc573_chip_end(struct gc573_hdmi *h);
void gc573_chip_sleep(struct gc573_hdmi *h, unsigned int ms);
int gc573_chip_rd(struct gc573_hdmi *h, u8 dev, u8 bank, u8 reg, u8 *val);
int gc573_chip_rdn(struct gc573_hdmi *h, u8 dev, u8 reg, u8 *buf, u16 len);
int gc573_chip_wr(struct gc573_hdmi *h, u8 dev, u8 bank, u8 reg, u8 val);
int gc573_chip_mod(struct gc573_hdmi *h, u8 dev, u8 bank, u8 reg, u8 mask,
		   u8 val);
int gc573_chip_bank(struct gc573_hdmi *h, u8 dev, u8 bank);
int gc573_seq_run(struct gc573_hdmi *h, const struct gc573_seq *seq,
		  unsigned long cond);
u8 gc573_seq_rd(struct gc573_hdmi *h, unsigned int idx);
bool gc573_seq_last(struct gc573_hdmi *h, unsigned int before, u8 dev,
		    u8 bank, u8 reg, u8 *val);

/* gc573_it6805.c */
int gc573_it6805_init(struct gc573_hdmi *h);
int gc573_it6805_poll(struct gc573_hdmi *h);
int gc573_it6805_edid(struct gc573_hdmi *h);
int gc573_it6805_x(struct gc573_hdmi *h, unsigned int x);
int gc573_it6805_var(struct gc573_hdmi *h, unsigned int var, u8 *val);
void gc573_it6805_show(struct gc573_hdmi *h, struct seq_file *m);

/* gc573_splitter.c */
int gc573_sp_init(struct gc573_hdmi *h);
int gc573_sp_edid(struct gc573_hdmi *h, bool toggle);
int gc573_sp_hpd_low(struct gc573_hdmi *h);
int gc573_sp_poll(struct gc573_hdmi *h);
int gc573_sp_x(struct gc573_hdmi *h, unsigned int x);
int gc573_sp_ddc_abort(struct gc573_hdmi *h, u8 dev);
int gc573_sp_var(struct gc573_hdmi *h, unsigned int var, u8 *val);
void gc573_sp_show(struct gc573_hdmi *h, struct seq_file *m);

/* gc573_hdmi.c */
void gc573_hdmi_hpd(struct gc573_hdmi *h, bool high);
u16 gc573_hdmi_edid_pa(struct gc573_hdmi *h, unsigned int *offset);

#endif /* GC573_CHIP_H */
